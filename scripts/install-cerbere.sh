#!/bin/zsh
# Compile et installe l'outil en ligne de commande de Cerbère (audit de sécurité statique) dans ~/.local/bin ; relancer pour le mettre à jour.
#   cerbere <lien https | pypi:nom | dossier | archive | app | image disque | paquet | fichier> [--sortie <dossier>] [--garder] [--sans-ia] [--apercu] [--modele <nom>] [--lots <n>] [--gatekeeper] [--reputation]
# Compilation hors du dossier du projet : le Bureau synchronisé par iCloud fait échouer la signature.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="$HOME/Library/Caches/cerbere-build"
xcodegen generate --quiet
xcodebuild -project Egide.xcodeproj -scheme Cerbere -configuration Release -derivedDataPath "$BUILD" -quiet
mkdir -p "$HOME/.local/bin"
install -m 755 "$BUILD/Build/Products/Release/cerbere" "$HOME/.local/bin/cerbere"
echo "Cerbère installé : ~/.local/bin/cerbere (rapports dans ~/Library/Application Support/Cerbere/rapports)."
# Règles YARA (phase 6) : yara n'est jamais installé par ce script (installation validée à part, par Homebrew).
if [[ ! -x /opt/homebrew/bin/yara && ! -x /usr/local/bin/yara ]]; then
  echo "Note : yara absent, les règles YARA ne seront pas appliquées (brew install yara)."
fi

# Relais : « cerbere --relais », lancé à l'ouverture de session. Il attend les audits demandés depuis Égide sur
# l'iPhone, par le serveur Argos de ce Mac (127.0.0.1). Sans Argos installé, il ne fait rien.
#   scripts/install-cerbere.sh --relais      : tool and relay, no question asked.
#   scripts/install-cerbere.sh --sans-relais : l'outil seul, et le relais est retiré s'il était installé.
# With no option, an installed relay is kept; otherwise it is only added after the user answers yes.
LABEL=com.spoooke.cerbere.relais
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
if [[ "${1:-}" == "--sans-relais" ]]; then
  rm -f "$PLIST"
  echo "Relais retiré : les audits demandés depuis l'iPhone attendront."
  exit 0
fi
if [[ ! -f $PLIST && "${1:-}" != "--relais" ]]; then
  reponse=""
  [[ -t 0 ]] && { read "reponse?Lancer aussi le relais à chaque ouverture de session (audits demandés depuis l'iPhone) ? [o/N] " || true; }
  if [[ $reponse != [oOyY]* ]]; then
    echo "Relais non installé (scripts/install-cerbere.sh --relais pour l'ajouter)."
    exit 0
  fi
fi
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/Cerbere"
cat > "$PLIST" <<PLIST_FIN
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$HOME/.local/bin/cerbere</string><string>--relais</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <!-- Priorité normale : en tâche de fond, macOS bride le processeur et les règles prennent 2 min 40 au lieu de 20 s. -->
  <key>ProcessType</key><string>Standard</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/Cerbere/relais.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/Cerbere/relais.log</string>
</dict>
</plist>
PLIST_FIN
launchctl bootstrap "gui/$UID" "$PLIST"
echo "Relais lancé ($LABEL) : journal dans ~/Library/Logs/Cerbere/relais.log."
