#!/bin/bash
# Builds the emulator engine for iOS and writes the Xcode project. Run on a Mac:
#   ./build.sh
# Needs: Xcode (with its command-line tools), Rust (https://rustup.rs) and XcodeGen (brew install xcodegen).
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"

command -v xcodebuild >/dev/null || { echo "Xcode est nécessaire (App Store)."; exit 1; }
command -v cargo >/dev/null || { echo "Rust est nécessaire : curl https://sh.rustup.rs -sSf | sh"; exit 1; }
command -v xcodegen >/dev/null || { echo "XcodeGen est nécessaire : brew install xcodegen"; exit 1; }

echo "==> Cibles Rust pour iPhone et simulateur"
rustup target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin

export IPHONEOS_DEPLOYMENT_TARGET=16.0
cd "$ROOT/emu"

# Optimisation guidée par profil (PGO) : le moteur est d'abord compilé avec des compteurs et
# joue 6 s du firmware V15 (accord de 5 notes) sur ce Mac (même processeur ARM que l'iPhone),
# puis recompilé pour l'iPhone en sachant quels chemins de l'interpréteur sont chauds.
# FM1_NO_PGO=1 ./build.sh pour s'en passer.
PGO_FLAGS=""
if [ -z "${FM1_NO_PGO:-}" ] && [ "$(uname -m)" = "arm64" ]; then
  echo "==> Profil d'exécution (PGO)"
  rustup component add llvm-tools >/dev/null 2>&1 || true
  PROFDATA=$(ls "$(rustc --print sysroot)"/lib/rustlib/*/bin/llvm-profdata 2>/dev/null | head -1)
  PGO_DIR="$ROOT/emu/target/pgo"
  rm -rf "$PGO_DIR" && mkdir -p "$PGO_DIR"
  if [ -n "$PROFDATA" ] \
     && FM1_FORCE_INTERPRETER=1 RUSTFLAGS="-Cprofile-generate=$PGO_DIR -Ctarget-cpu=apple-m1" \
        cargo build --release -p fm1-ios --example chord --target aarch64-apple-darwin --target-dir target/pgo-gen \
     && target/pgo-gen/aarch64-apple-darwin/release/examples/chord "$ROOT/App/Resources/Firmware/FM-1_015.fwsc" 2.0 6.0 \
     && "$PROFDATA" merge -o "$PGO_DIR/fm1.profdata" "$PGO_DIR"/*.profraw; then
    PGO_FLAGS="-Cprofile-use=$PGO_DIR/fm1.profdata -Cllvm-args=-pgo-warn-mismatch=false"
  else
    echo "    (profil indisponible : compilation sans PGO)"
  fi
fi

for target in aarch64-apple-ios aarch64-apple-ios-sim; do
  echo "==> Moteur FM-1 pour $target"
  CPU=""
  # les iPhone récents (puce A14 et suivantes, comme les Mac M1)
  [ "$target" = "aarch64-apple-ios" ] && CPU="-Ctarget-cpu=apple-a14"
  RUSTFLAGS="$CPU $PGO_FLAGS" cargo build --release --lib -p fm1-ios --target "$target"
done

echo "==> FM1Engine.xcframework"
OUT="$ROOT/App/Frameworks/FM1Engine.xcframework"
rm -rf "$OUT"
mkdir -p "$ROOT/App/Frameworks"
xcodebuild -create-xcframework \
  -library target/aarch64-apple-ios/release/libfm1_ios.a -headers crates/fm1-ios/include \
  -library target/aarch64-apple-ios-sim/release/libfm1_ios.a -headers crates/fm1-ios/include \
  -output "$OUT"

echo "==> Projet Xcode"
cd "$ROOT/App"
xcodegen generate

echo
echo "Terminé. Ouvrez App/FM1.xcodeproj, choisissez votre équipe dans Signing & Capabilities,"
echo "branchez l'iPhone et lancez (⌘R)."
