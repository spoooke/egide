#!/bin/zsh
# À lancer sur l'ANCIEN Mac avant de changer de Mac : rassemble ce qu'on ne peut pas retrouver ailleurs.
#   installer/export-mac.sh
# Produit ~/Egide-migration-AAAAMMJJ.tar.gz (+ .sha256), à copier sur le nouveau Mac (AirDrop, clé USB)
# puis à donner à install-mac.sh --import. L'archive contient les jetons d'Argos : elle reste hors du Bureau
# et de Documents (synchronisés avec iCloud) et doit être supprimée après l'import.
set -euo pipefail

STAMP=$(date +%Y%m%d)
OUT="$HOME/Egide-migration-$STAMP.tar.gz"
HEARTBIT="$HOME/Library/Application Support/Heartbit"
REFRESH="$HOME/Library/Application Support/iPhoneRefresh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
umask 077

echo "→ Données d'Argos (jetons, appareils, réseaux, historique, réglages ntfy)"
if [[ -d "$HEARTBIT/data" ]]; then
  mkdir -p "$TMP/argos"
  # Sans les agents compilés (recompilés sur le nouveau Mac) ni l'adresse du dashboard (recalculée).
  rsync -a --exclude agents --exclude dashboard-url "$HEARTBIT/data/" "$TMP/argos/data/"
else
  echo "  (Argos n'est pas installé sur ce Mac)"
fi

echo "→ Réglages d'iphone-refresh (iPhone, équipe de signature, canal ntfy des rappels)"
if [[ -f "$REFRESH/config.env" ]]; then
  mkdir -p "$TMP/iphone-refresh"
  cp "$REFRESH/config.env" "$TMP/iphone-refresh/config.env"
else
  echo "  (iphone-refresh n'est pas installé sur ce Mac)"
fi

# Pas exporté, volontairement :
# - la clé Hermès du Mac (puce de sécurité, impossible à copier) : nouvel appairage depuis Égide ;
# - l'identifiant d'appareil de l'agent Argos : le nouveau Mac apparaît comme un nouvel appareil ;
# - les idées de Muse : déjà dans le dossier de synchro iCloud Drive.
cat > "$TMP/LISEZMOI.txt" <<EOF
Migration Égide du $(date '+%d/%m/%Y %H:%M') depuis « $(scutil --get ComputerName) ».
Contient les jetons d'Argos : ne pas partager, supprimer après l'import.
Import : installer/install-mac.sh --import $(basename "$OUT")
EOF

tar -czf "$OUT" -C "$TMP" .
chmod 600 "$OUT"
(cd "$(dirname "$OUT")" && shasum -a 256 "$(basename "$OUT")" > "$(basename "$OUT").sha256")

echo
echo "✅ Archive : $OUT"
echo "   Empreinte : $(cut -d' ' -f1 "$OUT.sha256")"
echo "   Copie l'archive et son .sha256 sur le nouveau Mac (AirDrop ou clé USB, pas par iCloud ni par mail)."
