#!/bin/zsh
# Installe la suite Égide sur ce Mac, ou la met à jour, ou la retire.
#   installer/install-mac.sh                          installation (questionnaire)
#   installer/install-mac.sh --import <archive>       installation + reprise des données de l'ancien Mac (export-mac.sh)
#   installer/install-mac.sh --update                 met à jour ce qui est installé (sources + recompilation)
#   installer/install-mac.sh --uninstall              retire les apps et services (les données restent)
# Les sources viennent des dépôts privés GitHub (gh). Aucun secret dans ce script : les jetons sont créés
# sur place ou repris de l'archive d'export.
set -euo pipefail

STATE_DIR="$HOME/Library/Application Support/Egide"
STATE="$STATE_DIR/install.env"
REFRESH_STORE="$HOME/Library/Application Support/iPhoneRefresh"
HEARTBIT="$HOME/Library/Application Support/Heartbit"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

step() { print -P "\n%B→ $*%b"; }
info() { print "  $*"; }
die() { print -P "\n%F{red}✗ $*%f" >&2; exit 1; }
ask_yes() { # question, défaut (o/n)
  local answer
  read "answer?  $1 [${2:-o}] "
  answer=${answer:-${2:-o}}
  [[ $answer == [oOyY]* ]]
}
pause() { read "?  $1 Appuie sur Entrée quand c'est fait. "; }

# Sources : dossiers existants (Bureau synchronisé par iCloud), sinon clones dans ~/Developer.
if [[ -z ${EGIDE_SRC:-} ]]; then
  if [[ -d "$HOME/Desktop/Perso/Soft/EGIDE/.git" ]]; then EGIDE_SRC="$HOME/Desktop/Perso/Soft"; else EGIDE_SRC="$HOME/Developer"; fi
fi
repo_dir() { # dossier local de chaque dépôt (même organisation que sur l'ancien Mac)
  case $1 in
    Egide) print "$EGIDE_SRC/EGIDE" ;;
    Argos) print "$EGIDE_SRC/Argos/argos" ;;
    *) print "$EGIDE_SRC/$1" ;;
  esac
}
fetch_repo() { # nom du dépôt spoooke/<nom> : clone, ou mise à jour s'il est déjà là
  local dir=$(repo_dir $1)
  if [[ -d "$dir/.git" ]]; then
    if [[ -n $(git -C "$dir" status --porcelain) ]]; then
      info "$1 : modifications locales en cours, pas de mise à jour ($dir)"
    else
      git -C "$dir" pull --ff-only --quiet && info "$1 : à jour ($dir)"
    fi
  else
    mkdir -p "${dir:h}"
    # Égide se développe dans le dépôt privé egide-dev ; spoooke/egide n'en est que la copie publique.
    local depot=$1
    [[ $1 == Egide ]] && depot=egide-dev
    gh repo clone "spoooke/$depot" "$dir" -- --quiet && info "$1 : téléchargé dans $dir"
  fi
}

# ---------------------------------------------------------------------------------------------- prérequis

prerequisites() {
  step "Prérequis"
  [[ $(uname -s) == Darwin ]] || die "Ce script est pour macOS (Windows : install.ps1, Linux : install-linux.sh)."

  if [[ ! -d /Applications/Xcode.app ]]; then
    die "Xcode est nécessaire pour compiler les apps. Installe-le depuis l'App Store, ouvre-le une fois
  (composants iOS compris), ajoute ton identifiant Apple dans Xcode > Réglages > Comptes, puis relance ce script."
  fi
  if ! security find-certificate -c "Apple Development" >/dev/null 2>&1; then
    die "Aucun certificat de signature. Dans Xcode > Réglages > Comptes, choisis ton identifiant Apple >
  « Gérer les certificats… » > + > « Apple Development », puis relance ce script."
  fi
  info "Xcode et certificat de signature : OK"

  # Homebrew's installer is a remote script: the user runs it, never this script.
  command -v brew >/dev/null || die "Homebrew est nécessaire (gh, XcodeGen, Go, Tailscale). Installe-le en suivant
  https://brew.sh, puis relance ce script."
  local tools=()
  for t in gh xcodegen go; do command -v $t >/dev/null || tools+=($t); done
  (( ${#tools} )) && { info "Installation de ${tools[*]}"; brew install --quiet ${tools[@]}; }
  info "Homebrew, gh, XcodeGen, Go : OK"

  if [[ ! -d /Applications/Tailscale.app ]]; then
    info "Installation de Tailscale"
    brew install --quiet --cask tailscale
  fi
  if ! /Applications/Tailscale.app/Contents/MacOS/Tailscale status >/dev/null 2>&1; then
    open -a Tailscale
    pause "Connecte-toi à Tailscale (icône dans la barre des menus) avec le même compte que d'habitude."
  fi
  info "Tailscale : $(/Applications/Tailscale.app/Contents/MacOS/Tailscale status --json 2>/dev/null \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null || print '?')"

  if ! gh auth status >/dev/null 2>&1; then
    info "Connexion à GitHub (dépôts privés spoooke/…)"
    gh auth login --hostname github.com --git-protocol https --web
  fi
  info "GitHub : connecté"
}

# ---------------------------------------------------------------------------------------------- questionnaire

questionnaire() {
  step "Questionnaire"
  info "Ordinateur : Mac $(sw_vers -productVersion) ($(uname -m)), « $(scutil --get ComputerName) »"
  PHONE=iphone
  ask_yes "Ton téléphone est-il un iPhone ? (sinon Android)" o || PHONE=android
  WANT_ARGOS=0 WANT_HERMES=0 WANT_MUSE=0 WANT_MONEY=0 WANT_HEPHAISTOS=0 WANT_EGIDE=0
  ask_yes "Argos : serveur, agent et icône de la barre des menus (sécurité du parc) ?" o && WANT_ARGOS=1
  ask_yes "Hermès : agent du Mac (contrôle du Mac depuis l'iPhone) ?" o && WANT_HERMES=1
  ask_yes "Muse : app Mac (idées, synchro avec l'iPhone) ?" o && WANT_MUSE=1
  [[ $PHONE == iphone ]] && ask_yes "Égide sur l'iPhone (et son renouvellement automatique tous les 7 jours) ?" o && WANT_EGIDE=1
  ask_yes "Pactole : app Mac (dépenses, reste de la semaine dans la barre des menus) ?" o && WANT_MONEY=1
  ask_yes "Héphaïstos : app Mac (température du Mac dans la barre des menus, alerte s'il chauffe) ?" o && WANT_HEPHAISTOS=1
  mkdir -p "$STATE_DIR"
  cat > "$STATE" <<EOF
PHONE=$PHONE
WANT_ARGOS=$WANT_ARGOS
WANT_HERMES=$WANT_HERMES
WANT_MUSE=$WANT_MUSE
WANT_MONEY=$WANT_MONEY
WANT_HEPHAISTOS=$WANT_HEPHAISTOS
WANT_EGIDE=$WANT_EGIDE
EGIDE_SRC="$EGIDE_SRC"
EOF
}

# ---------------------------------------------------------------------------------------------- import

import_archive() { # archive produite par export-mac.sh sur l'ancien Mac
  local archive=$1
  step "Reprise des données de l'ancien Mac"
  [[ -f $archive ]] || die "Archive introuvable : $archive"
  if [[ -f "$archive.sha256" ]]; then
    (cd "${archive:h}" && shasum -a 256 -c "${archive:t}.sha256" >/dev/null) || die "Empreinte SHA-256 différente : archive abîmée ou modifiée."
    info "Empreinte SHA-256 vérifiée"
  else
    info "Pas de fichier .sha256 à côté de l'archive : empreinte non vérifiée."
    ask_yes "Continuer quand même ?" n || exit 1
  fi
  local tmp=$(mktemp -d)
  tar -xzf "$archive" -C "$tmp"
  if [[ -d "$tmp/argos/data" ]]; then
    if [[ -d "$HEARTBIT/data" ]] && ! ask_yes "Argos a déjà des données sur ce Mac. Les remplacer par celles de l'archive ?" n; then
      info "Données d'Argos gardées"
    else
      mkdir -p "$HEARTBIT"; chmod 700 "$HEARTBIT"
      rm -rf "$HEARTBIT/data"
      cp -R "$tmp/argos/data" "$HEARTBIT/data"
      chmod 700 "$HEARTBIT/data"
      info "Argos : jetons, appareils, réseaux, historique et alertes repris"
    fi
  fi
  if [[ -f "$tmp/iphone-refresh/config.env" && ! -f "$REFRESH_STORE/config.env" ]]; then
    mkdir -p "$REFRESH_STORE"
    cp "$tmp/iphone-refresh/config.env" "$REFRESH_STORE/config.env"
    info "iphone-refresh : iPhone, équipe et canal ntfy repris"
  fi
  rm -rf "$tmp"
  ask_yes "Supprimer l'archive maintenant (elle contient les jetons d'Argos) ?" o && rm -f "$archive" "$archive.sha256" && info "Archive supprimée"
}

# ---------------------------------------------------------------------------------------------- composants

install_argos() {
  step "Argos (serveur, agent, app de la barre des menus)"
  fetch_repo Argos
  "$(repo_dir Argos)/scripts/install-mac.sh"
}

install_hermes() {
  step "Hermès (agent du Mac)"
  fetch_repo Hermes
  zsh "$(repo_dir Hermes)/scripts/build-mac.sh" >/dev/null
  info "Hermès installé dans ~/Applications. Au premier lancement, autorise l'enregistrement de l'écran
  et l'accessibilité (Réglages Système > Confidentialité et sécurité)."
}

install_muse() {
  step "Muse (app Mac)"
  fetch_repo Muse
  local dir=$(repo_dir Muse) build="$HOME/Library/Caches/muse-build"
  # Compilation hors du dossier du projet : le Bureau synchronisé par iCloud fait échouer la signature.
  (cd "$dir" && xcodegen generate --quiet && xcodebuild -project Muse.xcodeproj -scheme MuseMac -configuration Release \
    -derivedDataPath "$build" -allowProvisioningUpdates -quiet)
  pkill -x Muse 2>/dev/null || true
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Muse.app"
  ditto --norsrc --noextattr "$build/Build/Products/Release/Muse.app" "$HOME/Applications/Muse.app"
  info "Muse installée dans ~/Applications. Dans Muse > Synchro, choisis le dossier iCloud Drive des idées."
}

install_money() {
  step "Pactole (app Mac)"
  fetch_repo Egide
  "$(repo_dir Egide)/scripts/install-money-mac.sh" >/dev/null
  info "Pactole installée dans ~/Applications. Dans Pactole > Réglages > Synchro avec l'iPhone, choisis le même dossier iCloud Drive que sur l'iPhone."
}

install_hephaistos() {
  step "Héphaïstos (app Mac)"
  fetch_repo Egide
  "$(repo_dir Egide)/scripts/install-hephaistos-mac.sh" >/dev/null
  info "Héphaïstos installée dans ~/Applications : température dans la barre des menus.
  Pour la lancer à l'ouverture de session : clic sur la température > Alertes et réglages > « Lancer à l'ouverture de session ».
  Avec Argos sur ce Mac, elle apparaît aussi dans Égide > Héphaïstos sur l'iPhone."
}

install_egide() {
  step "Égide sur l'iPhone"
  fetch_repo iphone-refresh
  fetch_repo Egide
  while ! xcrun devicectl list devices 2>/dev/null | grep -q "physical"; do
    pause "Branche l'iPhone au Mac (câble), déverrouille-le et touche « Se fier à cet ordinateur »."
  done
  (cd "$(repo_dir iphone-refresh)" && ./install.sh)
  "$(repo_dir Egide)/scripts/register-iphone-refresh.sh"
  "$REFRESH_STORE/bin/iphone-refresh" now Egide >/dev/null
  info "Compilation et installation d'Égide en cours (1 à 2 min) ; suivi : iphone-refresh log"
}

android_notes() {
  step "Android"
  local url=$(cat "$HEARTBIT/data/dashboard-url" 2>/dev/null || print "https://<nom-du-mac>.<tailnet>.ts.net")
  info "Hermès, Muse et Pactole n'existent que sur iPhone. Sur Android :"
  info "1. Installe Tailscale et connecte-toi au même compte."
  info "2. Dashboard Argos : Chrome > $url > ⋮ > « Installer l'application », puis colle le jeton (menu ♥ > « Copier le jeton »)."
  info "3. Alertes : installe ntfy et abonne-toi au sujet affiché dans Argos > Alertes."
}

run_components() {
  (( WANT_ARGOS )) && install_argos
  (( WANT_HERMES )) && install_hermes
  (( WANT_MUSE )) && install_muse
  (( ${WANT_MONEY:-0} )) && install_money
  (( ${WANT_HEPHAISTOS:-0} )) && install_hephaistos
  (( WANT_EGIDE )) && install_egide
  [[ $PHONE == android ]] && android_notes
  return 0
}

# ---------------------------------------------------------------------------------------------- désinstallation

uninstall() {
  step "Désinstallation"
  ask_yes "Retirer les apps et services Égide de ce Mac ? Les données (Argos, idées, réglages) restent." n || exit 0
  [[ -f "$STATE" ]] && source "$STATE"
  local argos=$(repo_dir Argos)
  if [[ -x "$argos/scripts/uninstall-mac.sh" ]]; then "$argos/scripts/uninstall-mac.sh"; fi
  pkill -f "Applications/Hermes.app/Contents/MacOS/Hermes" 2>/dev/null || true
  pkill -x Muse 2>/dev/null || true
  pkill -x Money 2>/dev/null || true; pkill -x Pactole 2>/dev/null || true
  pkill -x Hephaistos 2>/dev/null || true
  rm -rf "$HOME/Applications/Hermes.app" "$HOME/Applications/Muse.app" "$HOME/Applications/Money.app" "$HOME/Applications/Pactole.app" \
    "$HOME/Applications/Héphaïstos.app"
  # L'inscription d'Héphaïstos à l'ouverture de session disparaît avec l'app (macOS la retire de lui-même).
  if [[ -x "$REFRESH_STORE/bin/iphone-refresh" ]]; then
    "$REFRESH_STORE/bin/iphone-refresh" unregister Egide >/dev/null || true
    launchctl bootout "gui/$UID/com.spooke.iphone-refresh" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/com.spooke.iphone-refresh.plist" /opt/homebrew/bin/iphone-refresh
    rm -rf "$REFRESH_STORE/bin" "$REFRESH_STORE/src"
  fi
  rm -f "$STATE"
  print "\n✅ Apps et services retirés. Égide reste sur l'iPhone jusqu'à l'expiration de sa signature (7 jours)."
  print "   Données conservées : $HEARTBIT/data, $HOME/Library/Application Support/Swiftview, dossier de synchro de Muse."
}

# ---------------------------------------------------------------------------------------------- principal

MODE=install IMPORT=""
while (( $# )); do
  case $1 in
    --update) MODE=update ;;
    --uninstall) MODE=uninstall ;;
    --import) shift; IMPORT=${1:-}; [[ -n $IMPORT ]] || die "--import demande le chemin de l'archive." ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Option inconnue : $1 (voir --help)" ;;
  esac
  shift
done

case $MODE in
  uninstall) uninstall ;;
  update)
    [[ -f "$STATE" ]] || die "Rien d'installé par ce script sur ce Mac : lance-le sans option."
    source "$STATE"
    prerequisites
    run_components
    print "\n✅ Mise à jour terminée." ;;
  install)
    print -P "%BÉgide — installation sur ce Mac%b"
    prerequisites
    questionnaire
    [[ -n $IMPORT ]] && import_archive "$IMPORT"
    run_components
    print "\n✅ Installation terminée. Mise à jour plus tard : installer/install-mac.sh --update" ;;
esac
