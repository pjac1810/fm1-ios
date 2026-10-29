//! What the app does, without the phone: boot a package, run the emulation thread, pull audio
//! at the device's pace from another thread, press keys, read the screen, take the flash save.
//!   FM1_FORCE_INTERPRETER=1 cargo run --release -p fm1-ios --example simulate -- FM-1_015.fwsc
use fm1_ios::*;
use std::time::{Duration, Instant};

fn main() {
    let path = std::env::args().nth(1).expect("a .fwsc package");
    let pkg = std::fs::read(&path).unwrap();
    let mut id = [0 as std::os::raw::c_char; 32];
    let n = unsafe { fm1ios_package_identity(pkg.as_ptr(), pkg.len(), id.as_mut_ptr(), id.len()) };
    let ident: String = id[..n.max(0) as usize].iter().map(|&c| c as u8 as char).collect();
    println!("package identity: {ident}");
    let code = unsafe { fm1ios_boot(pkg.as_ptr(), pkg.len(), std::ptr::null(), 0, std::ptr::null(), 0, 240) };
    println!("boot: {code}");
    fm1ios_set_buffer(2048);
    fm1ios_pot(900);
    assert_eq!(fm1ios_start(), 0);
    // the audio device: 256 frames every 5.8 ms
    let audio = std::thread::spawn(|| {
        let (mut l, mut r) = (vec![0f32; 256], vec![0f32; 256]);
        let t0 = Instant::now();
        let mut peaks = vec![0f32; 12];
        let mut k = 0u64;
        while t0.elapsed() < Duration::from_secs(12) {
            unsafe { fm1ios_pull(l.as_mut_ptr(), r.as_mut_ptr(), 256) };
            let sec = (t0.elapsed().as_secs() as usize).min(11);
            for v in l.iter().chain(r.iter()) { peaks[sec] = peaks[sec].max(v.abs()); }
            k += 1;
            let due = t0 + Duration::from_secs_f64(k as f64 * 256.0 / 44100.0);
            if let Some(d) = due.checked_duration_since(Instant::now()) { std::thread::sleep(d) }
        }
        peaks
    });
    let t0 = Instant::now();
    let at = |s: f64| { let d = Duration::from_secs_f64(s); if let Some(w) = d.checked_sub(t0.elapsed()) { std::thread::sleep(w) } };
    at(4.0); for k in [21, 25, 28] { fm1ios_key(k, 1) }   // C E G
    at(6.0); for k in [21, 25, 28] { fm1ios_key(k, 0) }
    at(7.0); fm1ios_enc(6, 3);                              // PRESETS +3
    at(8.0); unsafe { fm1ios_midi([0x91u8, 57, 100].as_ptr(), 3) };
    at(9.5); unsafe { fm1ios_midi([0x81u8, 57, 0].as_ptr(), 3) };
    let peaks = audio.join().unwrap();
    let mut st = Fm1Stats { speed: 0.0, underruns: 0, emu_ms: 0, buffered: 0, halted: 0, running: 0 };
    unsafe { fm1ios_stats(&mut st) };
    fm1ios_stop();
    println!("peak per second: {}", peaks.iter().map(|p| format!("{p:.2}")).collect::<Vec<_>>().join(" "));
    println!("speed {:.2}x, underruns {}, emulated {} ms, halted {}", st.speed, st.underruns, st.emu_ms, st.halted);
    let mut lcd = vec![0u16; 240 * 240];
    let rev = unsafe { fm1ios_lcd(lcd.as_mut_ptr()) };
    println!("screen revision {rev}");
    let mut rgb = Vec::new();
    for px in &lcd { rgb.extend([((px >> 11) & 31) as u8 * 8, ((px >> 5) & 63) as u8 * 4, (px & 31) as u8 * 8]); }
    std::fs::write(std::env::temp_dir().join("fm1ios_lcd.rgb"), rgb).unwrap();
    let mut len = 0usize;
    let p = unsafe { fm1ios_take_save(&mut len) };
    println!("flash save: {} records", len / 4100);
    unsafe { fm1ios_free(p, len) };
    // the panel
    let (w, h) = (fm1ios_panel_width(), fm1ios_panel_height());
    let img = unsafe { fm1ios_panel_draw(lcd.as_ptr(), std::ptr::null()) };
    let bytes = unsafe { std::slice::from_raw_parts(img, (w * h * 4) as usize) };
    std::fs::write(std::env::temp_dir().join("fm1ios_panel.rgba"), bytes).unwrap();
    println!("panel {w}x{h}; hit at the PLAY button: {}", fm1ios_panel_hit(906.0 + 4.0 * 58.0 + 20.0, 232.0 + 76.0 + 30.0));
}
