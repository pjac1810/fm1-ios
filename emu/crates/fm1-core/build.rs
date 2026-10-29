// `native_jit`: the hosts the block compiler emits native code for (src/jit.rs): AArch64 on
// macOS, Linux and Android, x86-64 on macOS, Linux and Windows.
fn main() {
    println!("cargo::rustc-check-cfg=cfg(native_jit)");
    let arch = std::env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_default();
    let os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    // FM1-iOS: FM1_FORCE_INTERPRETER=1 builds the interpreter-only core that iOS gets anyway
    // (iOS forbids writable executable memory), so it can be tested on any host.
    println!("cargo::rerun-if-env-changed=FM1_FORCE_INTERPRETER");
    if std::env::var_os("FM1_FORCE_INTERPRETER").is_some() {
        return;
    }
    if matches!((arch.as_str(), os.as_str()), ("aarch64", "macos" | "linux" | "android") | ("x86_64", "linux" | "windows" | "macos")) {
        println!("cargo::rustc-cfg=native_jit");
    }
}
