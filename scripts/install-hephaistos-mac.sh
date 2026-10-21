#!/bin/zsh
# Compile et installe Héphaïstos (températures du Mac dans la barre des menus) dans ~/Applications ; relancer pour la mettre à jour.
# Compilation hors du dossier du projet : le Bureau synchronisé par iCloud fait échouer la signature.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="$HOME/Library/Caches/hephaistos-build"
xcodegen generate --quiet
xcodebuild -project Egide.xcodeproj -scheme HephaistosMac -configuration Release -derivedDataPath "$BUILD" -allowProvisioningUpdates -quiet
pkill -x Hephaistos 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Héphaïstos.app"
ditto --norsrc --noextattr "$BUILD/Build/Products/Release/Hephaistos.app" "$HOME/Applications/Héphaïstos.app"
open "$HOME/Applications/Héphaïstos.app"
echo "Héphaïstos installée : ~/Applications/Héphaïstos.app (température dans la barre des menus, lancée à l'ouverture de session)."
