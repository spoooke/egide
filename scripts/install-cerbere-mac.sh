#!/bin/zsh
# Compile et installe l'app Mac de Cerbère (audit de sécurité statique avant d'installer) dans ~/Applications ; relancer pour la mettre à jour.
# L'outil en ligne de commande s'installe à part : scripts/install-cerbere.sh.
# Compilation hors du dossier du projet : le Bureau synchronisé par iCloud fait échouer la signature.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="$HOME/Library/Caches/cerbere-mac-build"
xcodegen generate --quiet
xcodebuild -project Egide.xcodeproj -scheme CerbereMac -configuration Release -derivedDataPath "$BUILD" -allowProvisioningUpdates -quiet
pkill -x Cerbere 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Cerbère.app"
ditto --norsrc --noextattr "$BUILD/Build/Products/Release/Cerbere.app" "$HOME/Applications/Cerbère.app"
open "$HOME/Applications/Cerbère.app"
echo "Cerbère installée : ~/Applications/Cerbère.app (rapports dans ~/Library/Application Support/Cerbere/rapports)."
