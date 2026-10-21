#!/bin/zsh
# Enregistre (ou met à jour) Égide dans le service commun de renouvellement iPhone (~/Desktop/Perso/Soft/iphone-refresh).
# À relancer après une modification du projet : le renouvellement compile une copie des sources.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet
"$HOME/Library/Application Support/iPhoneRefresh/bin/iphone-refresh" register \
  Egide "$PWD" . Egide.xcodeproj Egide com.spoooke.egide Egide
