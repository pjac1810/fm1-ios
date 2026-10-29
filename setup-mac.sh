#!/bin/bash
# Tout en un, sur un Mac avec Xcode : outils manquants, téléchargement du projet, construction.
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/pjac1810/fm1-ios/main/setup-mac.sh)"
set -e
echo "==> FM-1 pour iPhone : préparation"

# Xcode complet (et non les seuls outils en ligne de commande)
if ! xcode-select -p 2>/dev/null | grep -q "Xcode"; then
  XCODE=$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1)
  if [ -z "$XCODE" ]; then echo "Xcode est introuvable dans Applications."; exit 1; fi
  echo "==> Sélection de $XCODE (mot de passe de session demandé)"
  sudo xcode-select -s "$XCODE/Contents/Developer"
fi
if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
  echo "==> Premier lancement d'Xcode : licence et composants (mot de passe de session demandé)"
  sudo xcodebuild -license accept
  sudo xcodebuild -runFirstLaunch
fi

# Rust
if ! command -v cargo >/dev/null && [ ! -x "$HOME/.cargo/bin/cargo" ]; then
  echo "==> Installation de Rust"
  curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
fi
export PATH="$HOME/.cargo/bin:$PATH"

# Homebrew et XcodeGen
if ! command -v brew >/dev/null && [ ! -x /opt/homebrew/bin/brew ] && [ ! -x /usr/local/bin/brew ]; then
  echo "==> Installation de Homebrew (mot de passe de session demandé)"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && eval "$("$b" shellenv)"; done
command -v xcodegen >/dev/null || brew install xcodegen

# Le projet
mkdir -p "$HOME/Documents"
cd "$HOME/Documents"
if [ -d fm1-ios/.git ]; then
  git -C fm1-ios pull --ff-only
else
  git clone https://github.com/pjac1810/fm1-ios
fi
cd fm1-ios
./build.sh
open App/FM1.xcodeproj
echo
echo "==> Prêt : le projet est ouvert dans Xcode."
