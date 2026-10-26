#!/bin/bash
# Installe l'agent Argos sur un PC Linux (avec Tailscale), ou le met à jour, ou le retire.
#   sudo ./install-linux.sh               installation (questionnaire)
#   sudo ./install-linux.sh --update      nouvelle version de l'agent (elle arrive aussi toute seule)
#   sudo ./install-linux.sh --uninstall   retire l'agent et son service
# L'agent est téléchargé depuis le serveur Argos du Mac, via Tailscale, avec le jeton des agents
# (menu ♥ du Mac > « Copier le jeton des agents ») ; son empreinte SHA-256 est vérifiée.
# Aucun secret dans ce script : le jeton est demandé à l'installation et rangé dans /etc/heartbit (lisible par root seul).
set -euo pipefail

BIN=/usr/local/bin/heartbit-agent
CONF=/etc/heartbit
UNIT=/etc/systemd/system/heartbit-agent.service

step() { printf '\n\033[1m→ %s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
die() { printf '\n\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
ask_yes() { local a; read -r -p "  $1 [${2:-o}] " a; a=${a:-${2:-o}}; [[ $a == [oOyY]* ]]; }

[[ $(uname -s) == Linux ]] || die "Ce script est pour Linux (Mac : install-mac.sh, Windows : install.ps1)."
[[ $EUID -eq 0 ]] || die "Lance-le avec sudo : sudo $0 $*"
command -v systemctl >/dev/null || die "systemd est nécessaire pour lancer l'agent au démarrage."

case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "Processeur non pris en charge : $(uname -m)" ;;
esac

TMP_AGENT="" TMP_HEADERS=""
trap 'rm -f "$TMP_AGENT" "$TMP_HEADERS"' EXIT

download_agent() { # serveur, fichier jeton : télécharge, vérifie l'empreinte, installe
  local server=$1 token_file=$2 want got
  TMP_AGENT=$(mktemp) TMP_HEADERS=$(mktemp)
  local tmp=$TMP_AGENT headers=$TMP_HEADERS
  curl -fsS --proto =https -D "$headers" -o "$tmp" \
    -H "Authorization: Bearer $(tr -d '[:space:]' < "$token_file")" \
    "$server/api/agent/download?os=linux&arch=$ARCH" || die "Téléchargement impossible : serveur injoignable ou jeton refusé."
  want=$(awk 'tolower($1) == "x-agent-sha256:" { print tolower($2) }' "$headers" | tr -d '\r')
  got=$(sha256sum "$tmp" | cut -d' ' -f1)
  [[ -n $want ]] || die "Le serveur n'a pas donné l'empreinte de l'agent : mets Argos à jour sur le Mac (install-mac.sh --update)."
  [[ $got == "$want" ]] || die "Empreinte SHA-256 incorrecte (${got:0:12}… au lieu de ${want:0:12}…) : fichier rejeté."
  install -m 755 "$tmp" "$BIN"
  info "Agent vérifié (SHA-256 ${got:0:12}…) et installé : $BIN"
}

write_unit() { # serveur
  cat > "$UNIT" <<EOF
[Unit]
Description=Argos agent
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
ExecStart=$BIN -server $1 -token-file $CONF/agent-token -watch
Restart=always
Nice=10

[Install]
WantedBy=multi-user.target
EOF
}

android_notes() { # serveur
  step "Android"
  info "Hermès, Muse et Pactole n'existent que sur iPhone. Sur Android :"
  info "1. Installe Tailscale et connecte-toi au même compte."
  info "2. Dashboard Argos : Chrome > $1 > ⋮ > « Installer l'application », puis colle le jeton (menu ♥ du Mac > « Copier le jeton »)."
  info "3. Alertes : installe ntfy et abonne-toi au sujet affiché dans Argos > Alertes."
}

install() {
  printf '\033[1mÉgide — installation sur ce PC Linux\033[0m\n'
  step "Questionnaire"
  info "Ordinateur : Linux $ARCH, « $(hostname) »"
  local phone=iphone
  ask_yes "Ton téléphone est-il un iPhone ? (sinon Android)" o || phone=android
  info "Sur un PC, seul l'agent Argos est disponible (Hermès, Muse et Pactole sont pour Mac et iPhone)."
  ask_yes "Installer l'agent Argos (surveillance de la sécurité de ce PC) ?" o || exit 0

  step "Tailscale"
  # No remote installer run as root from here: Tailscale comes from its official package, installed by the user.
  command -v tailscale >/dev/null || die "Tailscale est nécessaire. Installe-le en suivant https://tailscale.com/download/linux,
  puis relance ce script."
  if ! tailscale status >/dev/null 2>&1; then
    info "Connexion à Tailscale : ouvre le lien affiché et connecte-toi avec le même compte que le Mac."
    tailscale up
  fi
  info "Tailscale : connecté"

  step "Agent Argos"
  local server token
  read -r -p "  Adresse du dashboard Argos (ex. https://mon-mac.tailnet.ts.net) : " server
  server=${server%/}
  [[ $server == https://* ]] || die "Adresse https:// attendue (Tailscale)."
  read -r -s -p "  Jeton des agents (menu ♥ du Mac > « Copier le jeton des agents ») : " token; echo
  [[ -n $token ]] || die "Jeton vide."
  install -d -m 700 "$CONF"
  (umask 077; printf '%s\n' "$token" > "$CONF/agent-token")
  unset token
  printf 'SERVER=%s\nPHONE=%s\n' "$server" "$phone" > "$CONF/install.env"
  download_agent "$server" "$CONF/agent-token"
  write_unit "$server"
  systemctl daemon-reload
  systemctl enable --now heartbit-agent >/dev/null
  info "Service heartbit-agent actif : ce PC apparaît dans Argos d'ici une minute."
  [[ $phone == android ]] && android_notes "$server"
  printf '\n✅ Installation terminée. Les mises à jour de l’agent arrivent toutes seules.\n'
}

update() {
  [[ -f $CONF/install.env ]] || die "Rien d'installé par ce script : lance-le sans option."
  # shellcheck source=/dev/null
  source "$CONF/install.env"
  step "Mise à jour de l'agent"
  download_agent "$SERVER" "$CONF/agent-token"
  systemctl restart heartbit-agent
  printf '\n✅ Agent à jour.\n'
}

uninstall() {
  step "Désinstallation"
  ask_yes "Retirer l'agent Argos de ce PC ? (Tailscale reste installé)" n || exit 0
  systemctl disable --now heartbit-agent 2>/dev/null || true
  rm -f "$UNIT" "$BIN" "$BIN.old" "$BIN.new"
  systemctl daemon-reload
  rm -rf "$CONF"
  printf '\n✅ Agent retiré. Supprime ce PC dans le dashboard Argos si tu ne le surveilles plus.\n'
}

case "${1:-}" in
  "") install ;;
  --update) update ;;
  --uninstall) uninstall ;;
  -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "Option inconnue : $1 (voir --help)" ;;
esac
