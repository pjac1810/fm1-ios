//! FM1-iOS: the host the iPhone app links.
//!
//! The emulated FM-1 (fm1-web's machine: the JieLi chip, both CPU cores, screen, keys, knobs,
//! audio, flash) runs here on its own thread, a step ahead of the audio device. It fills a
//! lock-free ring of stereo samples that the audio callback empties (`fm1ios_pull`, the only
//! call made on the real-time thread: no lock, no allocation). Everything else that touches the
//! machine (keys, encoders, MIDI, the MASTER pot) is queued and applied by the emulation thread,
//! so the machine is only ever touched by one thread, as fm1-web expects.
//!
//! The screen, the LEDs and the flash are copied out by the emulation thread: the screen when it
//! changes (at most every 15 ms), the flash's changed 4 KiB sectors when the firmware has
//! written it (checked once a second, and on stop), in the same records `fm1_flash_restore`
//! takes back at the next boot, and that the browser emulator's `.fm1save` backups hold.
//!
//! iOS gives an app no writable executable memory, so the CPU core runs interpreted there
//! (fm1-core without `native_jit`).

use std::cell::UnsafeCell;
use std::os::raw::c_char;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, AtomicUsize, Ordering::*};
use std::sync::{Mutex, OnceLock};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use fm1_web as web;

/// Frames in the audio ring (a power of two): 370 ms at 44.1 kHz, far more than ever buffered.
const RING: usize = 1 << 14;
/// Frames the machine renders per step (as an AudioWorklet quantum).
const QUANTUM: usize = 128;
pub const SAMPLE_RATE: u32 = 44_100;
const SECTOR: usize = 4096;
const LCD_PIXELS: usize = 240 * 240;
const NLEDS: usize = 41;

// ------------------------------------------------------------------------------- the ring --

/// Single producer (the emulation thread), single consumer (the audio callback).
struct Ring {
    l: UnsafeCell<Box<[f32]>>,
    r: UnsafeCell<Box<[f32]>>,
    /// frames written / read since the start (wrapping); slot = count % RING
    w: AtomicUsize,
    rd: AtomicUsize,
}

// SAFETY: the producer only writes slots in [w, rd + RING), the consumer only reads slots in
// [rd, w); the counters are published with release / acquire ordering.
unsafe impl Sync for Ring {}

impl Ring {
    fn new() -> Ring {
        Ring {
            l: UnsafeCell::new(vec![0.0; RING].into_boxed_slice()),
            r: UnsafeCell::new(vec![0.0; RING].into_boxed_slice()),
            w: AtomicUsize::new(0),
            rd: AtomicUsize::new(0),
        }
    }

    fn filled(&self) -> usize {
        self.w.load(Acquire).wrapping_sub(self.rd.load(Acquire))
    }

    /// Producer: append what fits; returns the frames taken.
    fn push(&self, l: &[f32], r: &[f32]) -> usize {
        let w = self.w.load(Relaxed);
        let free = RING - w.wrapping_sub(self.rd.load(Acquire));
        let n = l.len().min(r.len()).min(free);
        // SAFETY: slots [w, w + n) are free (see the Sync impl).
        unsafe {
            let (dl, dr) = (&mut *self.l.get(), &mut *self.r.get());
            for i in 0..n {
                let k = (w + i) & (RING - 1);
                dl[k] = l[i];
                dr[k] = r[i];
            }
        }
        self.w.store(w.wrapping_add(n), Release);
        n
    }

    /// Consumer: up to `n` frames into `l` / `r`; returns how many there were.
    fn pull(&self, l: &mut [f32], r: &mut [f32]) -> usize {
        let rd = self.rd.load(Relaxed);
        let have = self.w.load(Acquire).wrapping_sub(rd);
        let n = l.len().min(r.len()).min(have);
        // SAFETY: slots [rd, rd + n) are filled (see the Sync impl).
        unsafe {
            let (sl, sr) = (&*self.l.get(), &*self.r.get());
            for i in 0..n {
                let k = (rd + i) & (RING - 1);
                l[i] = sl[k];
                r[i] = sr[k];
            }
        }
        self.rd.store(rd.wrapping_add(n), Release);
        n
    }

    /// Drop what is buffered (the consumer's side: only while nothing else pulls).
    fn drain(&self) {
        self.rd.store(self.w.load(Acquire), Release);
    }
}

// ------------------------------------------------------------------------- shared state --

enum Cmd {
    Key(u32, bool),
    Enc(u32, i32),
    Pot(u32),
    Midi(u8),
    Analog(u32, u32),
}

struct Shared {
    ring: Ring,
    cmds: Mutex<Vec<Cmd>>,
    /// the emulation thread keeps running while set
    run: AtomicBool,
    booted: AtomicBool,
    halted: AtomicBool,
    /// frames the thread keeps buffered ahead of the audio device
    target: AtomicUsize,
    mhz: AtomicU32,
    lcd: Mutex<(u32, Vec<u16>)>,
    leds: Mutex<[f32; NLEDS]>,
    /// the latest flash records not yet taken, and a request for one now
    save: Mutex<Option<Vec<u8>>>,
    save_now: AtomicBool,
    // statistics
    frames: AtomicU64,
    busy_ns: AtomicU64,
    underruns: AtomicU64,
    speed_milli: AtomicU32,
    emu_ms: AtomicU32,
}

fn shared() -> &'static Shared {
    static S: OnceLock<Shared> = OnceLock::new();
    S.get_or_init(|| Shared {
        ring: Ring::new(),
        cmds: Mutex::new(Vec::new()),
        run: AtomicBool::new(false),
        booted: AtomicBool::new(false),
        halted: AtomicBool::new(false),
        target: AtomicUsize::new(1024),
        mhz: AtomicU32::new(240),
        lcd: Mutex::new((0, vec![0; LCD_PIXELS])),
        leds: Mutex::new([0.0; NLEDS]),
        save: Mutex::new(None),
        save_now: AtomicBool::new(false),
        frames: AtomicU64::new(0),
        busy_ns: AtomicU64::new(0),
        underruns: AtomicU64::new(0),
        speed_milli: AtomicU32::new(0),
        emu_ms: AtomicU32::new(0),
    })
}

static THREAD: Mutex<Option<JoinHandle<()>>> = Mutex::new(None);

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

fn queue(c: Cmd) {
    lock(&shared().cmds).push(c);
}

// ------------------------------------------------------------------- the emulation thread --

#[cfg(target_vendor = "apple")]
fn raise_priority() {
    extern "C" {
        fn pthread_set_qos_class_self_np(qos: u32, relative_priority: i32) -> i32;
    }
    // QOS_CLASS_USER_INTERACTIVE: the scheduler keeps it on a performance core
    unsafe { pthread_set_qos_class_self_np(0x21, 0) };
}
#[cfg(not(target_vendor = "apple"))]
fn raise_priority() {}

/// The flash's sectors that differ from what the package booted with, as restore records:
/// a little-endian u32 offset, then the 4096 bytes.
fn changed_sectors() -> Vec<u8> {
    let len = web::fm1_flash_len() as usize;
    let (now, base) = (web::fm1_flash(), web::fm1_flash_base());
    if now.is_null() || base.is_null() {
        return Vec::new();
    }
    // SAFETY: both buffers are the machine's, `len` long, and only this thread touches it.
    let (now, base) = unsafe { (std::slice::from_raw_parts(now, len), std::slice::from_raw_parts(base, len)) };
    let mut out = Vec::new();
    for at in (0..len).step_by(SECTOR) {
        if now[at..at + SECTOR] != base[at..at + SECTOR] {
            out.extend_from_slice(&(at as u32).to_le_bytes());
            out.extend_from_slice(&now[at..at + SECTOR]);
        }
    }
    out
}

struct Watch {
    lcd_rev: u32,
    ui_at: Instant,
    flash_rev: u32,
    flash_at: Instant,
    speed_at: Instant,
    speed_frames: u64,
}

impl Watch {
    fn new() -> Watch {
        let past = Instant::now() - Duration::from_secs(2);
        Watch { lcd_rev: u32::MAX, ui_at: past, flash_rev: web::fm1_flash_revision(), flash_at: Instant::now(),
            speed_at: Instant::now(), speed_frames: 0 }
    }

    /// Copy out the screen and LEDs, the flash when it changed, and the speed.
    fn tick(&mut self, s: &Shared, last: bool) {
        let now = Instant::now();
        if now.duration_since(self.ui_at) >= Duration::from_millis(15) || last {
            self.ui_at = now;
            let rev = web::fm1_lcd_revision();
            let fb = web::fm1_lcd();
            if rev != self.lcd_rev && !fb.is_null() {
                self.lcd_rev = rev;
                // SAFETY: the machine's 240x240 framebuffer, touched only by this thread.
                let src = unsafe { std::slice::from_raw_parts(fb, LCD_PIXELS) };
                let mut g = lock(&s.lcd);
                g.0 = rev;
                g.1.copy_from_slice(src);
            }
            // SAFETY: fm1_leds returns 41 floats.
            let leds = unsafe { std::slice::from_raw_parts(web::fm1_leds(), NLEDS) };
            lock(&s.leds).copy_from_slice(leds);
            s.emu_ms.store(web::fm1_ms(), Relaxed);
        }
        let forced = s.save_now.load(Relaxed);
        if forced || last || now.duration_since(self.flash_at) >= Duration::from_secs(1) {
            self.flash_at = now;
            let rev = web::fm1_flash_revision();
            if rev != self.flash_rev && web::fm1_flash_busy() == 0 {
                self.flash_rev = rev;
                *lock(&s.save) = Some(changed_sectors());
            }
            if web::fm1_flash_busy() == 0 {
                s.save_now.store(false, Relaxed);
            }
        }
        let el = now.duration_since(self.speed_at);
        if el >= Duration::from_millis(500) {
            let frames = s.frames.load(Relaxed);
            let busy = s.busy_ns.swap(0, Relaxed);
            let emulated = (frames - self.speed_frames) as f64 / SAMPLE_RATE as f64;
            // how much faster than real time the machine could run: emulated time per busy time
            if busy > 0 {
                s.speed_milli.store((emulated / (busy as f64 * 1e-9) * 1000.0).min(1e9) as u32, Relaxed);
            }
            self.speed_at = now;
            self.speed_frames = frames;
        }
    }
}

fn run_loop() {
    raise_priority();
    let s = shared();
    let mhz = s.mhz.load(Relaxed);
    // the run budget of one step: 20 ms of emulated time (fm1_render stops as soon as the
    // step's frames are there; the budget only bounds a firmware that produces no audio)
    let budget = (mhz as u64 * 1_000_000 / 50).min(u32::MAX as u64) as u32;
    let mut watch = Watch::new();
    let mut cmds = Vec::new();
    while s.run.load(Acquire) {
        std::mem::swap(&mut cmds, &mut *lock(&s.cmds));
        for c in cmds.drain(..) {
            match c {
                Cmd::Key(id, down) => web::fm1_key(id, down as u32),
                Cmd::Enc(e, clicks) => web::fm1_enc(e, clicks),
                Cmd::Pot(v) => web::fm1_pot(v),
                Cmd::Midi(b) => web::fm1_midi(b as u32),
                Cmd::Analog(i, v) => web::fm1_analog(i, v),
            }
        }
        if s.ring.filled() + QUANTUM > s.target.load(Relaxed) {
            watch.tick(s, false);
            std::thread::sleep(Duration::from_micros(500));
            continue;
        }
        let t0 = Instant::now();
        web::fm1_render(QUANTUM as u32, budget);
        s.busy_ns.fetch_add(t0.elapsed().as_nanos() as u64, Relaxed);
        // SAFETY: fm1_render filled QUANTUM frames of each.
        let (l, r) = unsafe {
            (std::slice::from_raw_parts(web::fm1_out_l(), QUANTUM), std::slice::from_raw_parts(web::fm1_out_r(), QUANTUM))
        };
        s.ring.push(l, r);
        s.frames.fetch_add(QUANTUM as u64, Relaxed);
        if web::fm1_halted() != 0 {
            s.halted.store(true, Release);
            break;
        }
        watch.tick(s, false);
    }
    watch.tick(s, true);
}

// ---------------------------------------------------------------------------- the C API --

/// The library's version (NUL-terminated).
#[no_mangle]
pub extern "C" fn fm1ios_version() -> *const c_char {
    concat!("fm1-ios ", env!("CARGO_PKG_VERSION"), "\0").as_ptr() as *const c_char
}

/// The sample rate the machine renders at (44100).
#[no_mangle]
pub extern "C" fn fm1ios_sample_rate() -> u32 {
    SAMPLE_RATE
}

/// The identity an update package carries (`FM-1_015` for M-VAVE's V15) into `out` (`cap`
/// bytes, NUL-terminated). Returns its length, or -1 when the bytes are no FM-1 package.
///
/// # Safety
/// `pkg` must point to `len` readable bytes and `out` to `cap` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn fm1ios_package_identity(pkg: *const u8, len: usize, out: *mut c_char, cap: usize) -> i32 {
    if pkg.is_null() || out.is_null() || cap == 0 {
        return -1;
    }
    let bytes = std::slice::from_raw_parts(pkg, len);
    let Ok(u) = fm1_soc::fwsc::unpack(bytes) else { return -1 };
    let id = u.identity.as_bytes();
    let n = id.len().min(cap - 1);
    std::ptr::copy_nonoverlapping(id.as_ptr() as *const c_char, out, n);
    *out.add(n) = 0;
    n as i32
}

/// Boot an update package (.fwsc), as a firmware update and power-on would: the machine is
/// replaced. `sectors` (may be null): the flash records a previous run saved for this exact
/// package; `syx` (may be null): a DX7 32-voice bank for the firmware's patch library. `mhz`:
/// the emulated CPU clock (240 as on the chip). Stops the emulation thread first; start it again
/// with `fm1ios_start`.
///
/// Returns 0 booted; 1 not an FM-1 package (nothing booted); 2 booted, but the saved sectors
/// were refused (the firmware starts as new); 3 booted, but the bank was refused; 4 booted, but
/// this firmware takes no DX7 bank.
///
/// # Safety
/// Each non-null pointer must point to its length of readable bytes.
#[no_mangle]
pub unsafe extern "C" fn fm1ios_boot(pkg: *const u8, len: usize, sectors: *const u8, sectors_len: usize,
    syx: *const u8, syx_len: usize, mhz: u32) -> i32 {
    fm1ios_stop();
    let s = shared();
    s.booted.store(false, Release);
    s.halted.store(false, Release);
    if pkg.is_null() || len == 0 || len > u32::MAX as usize {
        return 1;
    }
    let copy = |p: *const u8, n: usize| {
        let d = web::fm1_alloc(n as u32);
        std::ptr::copy_nonoverlapping(p, d, n);
        d
    };
    let mhz = mhz.clamp(10, 1000);
    if web::fm1_boot_fwsc(copy(pkg, len), len as u32, std::ptr::null_mut(), 0, mhz) != 0 {
        return 1;
    }
    let mut code = 0;
    if !sectors.is_null() && sectors_len > 0 && web::fm1_flash_restore(copy(sectors, sectors_len), sectors_len as u32) != 0 {
        code = 2;
    }
    if !syx.is_null() && syx_len > 0 {
        match web::fm1_load_syx(copy(syx, syx_len), syx_len as u32) {
            0 => {}
            2 => code = 4,
            _ => code = 3,
        }
    }
    s.mhz.store(mhz, Relaxed);
    s.ring.drain();
    *lock(&s.save) = None;
    s.save_now.store(false, Relaxed);
    lock(&s.cmds).clear();
    *lock(&s.lcd) = (0, vec![0; LCD_PIXELS]);
    s.booted.store(true, Release);
    code
}

/// Start (or keep) the emulation thread. Returns 0, or 1 when nothing is booted.
#[no_mangle]
pub extern "C" fn fm1ios_start() -> i32 {
    let s = shared();
    if !s.booted.load(Acquire) {
        return 1;
    }
    let mut t = lock(&THREAD);
    if t.is_none() {
        s.run.store(true, Release);
        *t = std::thread::Builder::new().name("fm1-emulation".into()).stack_size(4 << 20).spawn(run_loop).ok();
    }
    0
}

/// Stop the emulation thread (the machine keeps its state; the flash is checked a last time,
/// so `fm1ios_take_save` has the latest).
#[no_mangle]
pub extern "C" fn fm1ios_stop() {
    let s = shared();
    s.run.store(false, Release);
    if let Some(t) = lock(&THREAD).take() {
        let _ = t.join();
    }
}

#[no_mangle]
pub extern "C" fn fm1ios_is_running() -> u32 {
    lock(&THREAD).is_some() as u32
}

/// How many frames the emulation keeps ready ahead of the audio device (256..8192; default
/// 1024, 23 ms). More is safer on a slow phone, less answers keys sooner.
#[no_mangle]
pub extern "C" fn fm1ios_set_buffer(frames: u32) {
    shared().target.store((frames as usize).clamp(256, RING / 2), Relaxed);
}

/// The audio callback's call: `frames` frames into `l` and `r` (non-interleaved floats).
/// Real-time safe: no lock, no allocation. Missing frames are silence (and counted).
///
/// # Safety
/// `l` and `r` must each point to `frames` writable floats.
#[no_mangle]
pub unsafe extern "C" fn fm1ios_pull(l: *mut f32, r: *mut f32, frames: u32) -> u32 {
    let n = frames as usize;
    if l.is_null() || r.is_null() || n == 0 {
        return 0;
    }
    let (l, r) = (std::slice::from_raw_parts_mut(l, n), std::slice::from_raw_parts_mut(r, n));
    let s = shared();
    let got = s.ring.pull(l, r);
    if got < n {
        l[got..].fill(0.0);
        r[got..].fill(0.0);
        if s.run.load(Relaxed) && s.booted.load(Relaxed) && s.frames.load(Relaxed) > 0 {
            s.underruns.fetch_add(1, Relaxed);
        }
    }
    got as u32
}

/// A key or button down / up: matrix id 0..13 the buttons (OCT-, OCT+, FX, SCL, ENV, LFO, EDIT,
/// GLO, HOME, SAVE, ARP, SEQ, PLAY, REC), 14..40 the 27 note keys from F.
#[no_mangle]
pub extern "C" fn fm1ios_key(id: u32, down: u32) {
    queue(Cmd::Key(id, down != 0));
}

/// Turn matrix encoder `enc` (0 SELECT, 1 ALGORITHM, 2..5 KNOB1..4, 6 PRESETS) by `clicks`.
#[no_mangle]
pub extern "C" fn fm1ios_enc(enc: u32, clicks: i32) {
    queue(Cmd::Enc(enc, clicks));
}

/// The MASTER pot, 0..1023.
#[no_mangle]
pub extern "C" fn fm1ios_pot(value: u32) {
    queue(Cmd::Pot(value.min(1023)));
}

/// An ADC channel (the FM-1's MASTER pot is channel 4).
#[no_mangle]
pub extern "C" fn fm1ios_analog(idx: u32, value: u32) {
    queue(Cmd::Analog(idx, value.min(1023)));
}

/// Bytes into the MIDI IN jack (31250 baud: they reach the firmware a byte time apart).
///
/// # Safety
/// `bytes` must point to `len` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn fm1ios_midi(bytes: *const u8, len: usize) {
    if bytes.is_null() {
        return;
    }
    let b = std::slice::from_raw_parts(bytes, len);
    let mut q = lock(&shared().cmds);
    q.extend(b.iter().map(|&x| Cmd::Midi(x)));
}

/// Copy the 240x240 RGB565 screen into `dst` (57600 u16); returns its revision (0: no frame
/// yet), which changes whenever the firmware drew.
///
/// # Safety
/// `dst` must point to 57600 writable u16.
#[no_mangle]
pub unsafe extern "C" fn fm1ios_lcd(dst: *mut u16) -> u32 {
    let g = lock(&shared().lcd);
    if !dst.is_null() {
        std::ptr::copy_nonoverlapping(g.1.as_ptr(), dst, LCD_PIXELS);
    }
    g.0
}

/// The screen's revision only.
#[no_mangle]
pub extern "C" fn fm1ios_lcd_revision() -> u32 {
    lock(&shared().lcd).0
}

/// The 41 LED levels (0..1) of the last screen copy.
///
/// # Safety
/// `dst` must point to 41 writable floats.
#[no_mangle]
pub unsafe extern "C" fn fm1ios_leds(dst: *mut f32) {
    if !dst.is_null() {
        std::ptr::copy_nonoverlapping(lock(&shared().leds).as_ptr(), dst, NLEDS);
    }
}

/// Check the flash for changes now instead of within the second.
#[no_mangle]
pub extern "C" fn fm1ios_request_save() {
    shared().save_now.store(true, Relaxed);
}

/// The flash records saved since the last call (to keep for the next `fm1ios_boot` of this
/// package), or null when nothing changed. Free them with `fm1ios_free`.
///
/// # Safety
/// `len` must point to a writable usize.
#[no_mangle]
pub unsafe extern "C" fn fm1ios_take_save(len: *mut usize) -> *mut u8 {
    let Some(v) = lock(&shared().save).take() else {
        if !len.is_null() {
            *len = 0;
        }
        return std::ptr::null_mut();
    };
    let mut b = v.into_boxed_slice();
    if !len.is_null() {
        *len = b.len();
    }
    let p = b.as_mut_ptr();
    std::mem::forget(b);
    p
}

/// Free what `fm1ios_take_save` returned.
///
/// # Safety
/// `p` / `len` must be exactly what `fm1ios_take_save` returned.
#[no_mangle]
pub unsafe extern "C" fn fm1ios_free(p: *mut u8, len: usize) {
    if !p.is_null() {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(p, len)));
    }
}

#[repr(C)]
pub struct Fm1Stats {
    /// how much faster than real time the emulation runs (1.0 = just in time; below 1 the
    /// sound drops out)
    pub speed: f32,
    /// audio callbacks that found the ring short
    pub underruns: u64,
    /// emulated milliseconds since boot
    pub emu_ms: u32,
    /// frames ready in the ring
    pub buffered: u32,
    /// 1 when the firmware stopped (crashed)
    pub halted: u32,
    pub running: u32,
}

/// # Safety
/// `out` must point to a writable Fm1Stats.
#[no_mangle]
pub unsafe extern "C" fn fm1ios_stats(out: *mut Fm1Stats) {
    if out.is_null() {
        return;
    }
    let s = shared();
    *out = Fm1Stats {
        speed: s.speed_milli.load(Relaxed) as f32 / 1000.0,
        underruns: s.underruns.load(Relaxed),
        emu_ms: s.emu_ms.load(Relaxed),
        buffered: s.ring.filled() as u32,
        halted: s.halted.load(Relaxed) as u32,
        running: fm1ios_is_running(),
    };
}

// --------------------------------------------------- the front panel (main thread only) --
// fm1-web's drawing of the FM-1's face (the same as the emulator's window and web page): the
// app shows it and hit-tests touches against it. Independent of the machine.

#[no_mangle]
pub extern "C" fn fm1ios_panel_width() -> u32 {
    web::panel_width()
}

#[no_mangle]
pub extern "C" fn fm1ios_panel_height() -> u32 {
    web::panel_height()
}

/// Draw the panel with this screen (57600 RGB565) and these 41 LED levels; returns the RGBA
/// bytes (width * height * 4), valid until the next call.
///
/// # Safety
/// `lcd` must point to 57600 u16 and `leds` to 41 floats (either may be null: kept as is).
#[no_mangle]
pub unsafe extern "C" fn fm1ios_panel_draw(lcd: *const u16, leds: *const f32) -> *const u8 {
    if !lcd.is_null() {
        std::ptr::copy_nonoverlapping(lcd, web::panel_lcd(), LCD_PIXELS);
    }
    if !leds.is_null() {
        std::ptr::copy_nonoverlapping(leds, web::panel_leds(), NLEDS);
    }
    web::panel_draw()
}

/// The panel's drawing state: kind 0 key / button `i` held (v 0/1), 1 encoder `i`'s clicks (its
/// pointer's angle), 2 the pot's value, 3 encoder `i`'s glow (frames left).
#[no_mangle]
pub extern "C" fn fm1ios_panel_set(kind: u32, i: u32, v: i32) {
    web::panel_set(kind, i, v);
}

/// What is at panel point (x, y): -1 nothing, 0..6 an encoder (panel order: SELECT, PRESETS,
/// ALGORITHM, KNOB1..4), 7 the MASTER pot, 100 + id a button or key.
#[no_mangle]
pub extern "C" fn fm1ios_panel_hit(x: f32, y: f32) -> i32 {
    web::panel_hit(x, y)
}

/// The matrix encoder of panel encoder `i`.
#[no_mangle]
pub extern "C" fn fm1ios_panel_enc_id(i: u32) -> u32 {
    web::panel_enc_id(i)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ring_keeps_order_across_the_wrap() {
        let r = Ring::new();
        let mut next = 0f32;
        let mut want = 0f32;
        for _ in 0..1000 {
            let l: Vec<f32> = (0..300).map(|i| next + i as f32).collect();
            let n = r.push(&l, &l);
            next += n as f32;
            let (mut a, mut b) = (vec![0.0; 250], vec![0.0; 250]);
            let got = r.pull(&mut a, &mut b);
            for i in 0..got {
                assert_eq!(a[i], want);
                assert_eq!(b[i], want);
                want += 1.0;
            }
        }
        assert!(r.filled() <= RING);
    }
}
