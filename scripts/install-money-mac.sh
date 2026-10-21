#!/bin/zsh
# Compile et installe l'app Pactole (nom de code : Money) du Mac dans ~/Applications (relancer pour la mettre à jour).
# Compilation hors du dossier du projet : le Bureau synchronisé par iCloud fait échouer la signature.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="$HOME/Library/Caches/money-build"
xcodegen generate --quiet
xcodebuild -project Egide.xcodeproj -scheme PactoleMac -configuration Release -derivedDataPath "$BUILD" -allowProvisioningUpdates -quiet
pkill -x Money 2>/dev/null || true # ancien nom
pkill -x Pactole 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Money.app" "$HOME/Applications/Pactole.app"
ditto --norsrc --noextattr "$BUILD/Build/Products/Release/Pactole.app" "$HOME/Applications/Pactole.app"
open "$HOME/Applications/Pactole.app"
echo "Pactole installée : ~/Applications/Pactole.app (Réglages › Synchro avec le Mac pour choisir le dossier iCloud Drive)."
