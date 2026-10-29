//! Offline speed of the stock firmware with a 5-note chord held (no pacing).
//!   cargo run --release -p fm1-ios --example chord -- FM-1_015.fwsc [seconds_before] [seconds_chord]
use fm1_web::*;
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let pkg = std::fs::read(&a[1]).unwrap();
    let warm: f64 = a.get(2).map_or(2.5, |s| s.parse().unwrap());
    let len: f64 = a.get(3).map_or(4.0, |s| s.parse().unwrap());
    let p = fm1_alloc(pkg.len() as u32);
    unsafe { std::ptr::copy_nonoverlapping(pkg.as_ptr(), p, pkg.len()) };
    assert_eq!(fm1_boot_fwsc(p, pkg.len() as u32, std::ptr::null_mut(), 0, 240), 0);
    fm1_pot(900);
    let q = |s: f64| (s * 44100.0 / 128.0) as usize;
    for _ in 0..q(warm) { fm1_render(128, 4_800_000); }
    for k in [21, 25, 28, 32, 35] { fm1_key(k, 1); }
    let t = std::time::Instant::now();
    let mut peak = 0f32;
    for _ in 0..q(len) {
        fm1_render(128, 4_800_000);
        let l = unsafe { std::slice::from_raw_parts(fm1_out_l(), 128) };
        for v in l { peak = peak.max(v.abs()) }
    }
    let el = t.elapsed().as_secs_f64();
    println!("chord: {len:.1}s audio in {el:.2}s = {:.2}x realtime (peak {peak:.2})", len / el);
}
