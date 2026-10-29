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
rustup target add aarch64-apple-ios aarch64-apple-ios-sim

export IPHONEOS_DEPLOYMENT_TARGET=16.0
cd "$ROOT/emu"
for target in aarch64-apple-ios aarch64-apple-ios-sim; do
  echo "==> Moteur FM-1 pour $target"
  cargo build --release --lib -p fm1-ios --target "$target"
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
