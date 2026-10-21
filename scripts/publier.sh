#!/bin/zsh
# Prépare une version publique d'Égide, sans l'historique de développement :
#   scripts/publier.sh <version> [branche, main par défaut]
#   ex. scripts/publier.sh 0.2
# Copie le code de la branche (identifiants Apple renommés en com.spoooke) dans la copie publique (EGIDE_PUBLIC, ~/Desktop/Perso/Soft/Egide-public par défaut),
# cherche d'abord les mots interdits listés hors du dépôt (EGIDE_INTERDITS, ~/.config/egide/publier-interdits),
# s'arrête au moindre résultat, puis crée le commit « Version <version> » et l'étiquette v<version>.
# Rien n'est poussé : la commande à lancer est affichée à la fin.
set -euo pipefail
cd "$(dirname "$0")/.."

[[ $# -ge 1 ]] || { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
version=$1 branche=${2:-main}
public=${EGIDE_PUBLIC:-$HOME/Desktop/Perso/Soft/Egide-public}
interdits=${EGIDE_INTERDITS:-$HOME/.config/egide/publier-interdits}

[[ $version =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "Version invalide : chiffres et points (ex. 0.2)."; exit 1; }
git rev-parse --verify --quiet "$branche^{commit}" >/dev/null || { echo "Branche introuvable : $branche"; exit 1; }
[[ -d $public/.git ]] || { echo "Copie publique introuvable : $public (un dépôt git, avec spoooke/egide comme origin)."; exit 1; }
[[ -z $(git -C "$public" status --porcelain) ]] || { echo "La copie publique a des changements en cours : $public"; exit 1; }
! git -C "$public" rev-parse --verify --quiet "refs/tags/v$version" >/dev/null || { echo "La version v$version existe déjà."; exit 1; }
# La liste reste hors du dépôt : publiée, elle dévoilerait justement ce qu'elle protège.
[[ -s $interdits ]] || { echo "Liste des mots interdits absente ou vide : $interdits"; exit 1; }

export_dir=$(mktemp -d)
trap 'rm -rf "$export_dir"' EXIT
git archive "$branche" | tar -x -C "$export_dir"

# Identifiants Apple : la copie publique prend un préfixe neutre, les apps installées gardent le leur.
prefixe=$(sed -n 's/^  bundleIdPrefix: *//p' "$export_dir/project.yml")
if [[ -n $prefixe && $prefixe != com.spoooke ]]; then
  grep -rlIF "$prefixe" "$export_dir" | while read -r f; do sed -i '' "s/${prefixe//./\\.}/com.spoooke/g" "$f"; done
fi

# Une expression par ligne (grep -E, sans casse) ; lignes vides et commentaires ignorés.
motifs=$(grep -vE '^[[:space:]]*(#|$)' "$interdits")
if trouve=$(grep -rniE -f <(print -r -- "$motifs") "$export_dir" 2>/dev/null); then
  echo "Publication arrêtée, mots interdits trouvés :"
  print -r -- "${trouve//$export_dir\//}" | cut -c1-160
  exit 1
fi

rsync -a --delete --exclude .git "$export_dir/" "$public/"
git -C "$public" add -A
if git -C "$public" diff --cached --quiet; then
  echo "Rien de nouveau depuis la dernière version publique."
  exit 0
fi
git -C "$public" commit -q -m "Version $version"
git -C "$public" tag "v$version"
echo "Version $version prête dans $public ($(git -C "$public" diff --stat HEAD~1 | tail -1 | sed 's/^ *//'))."
echo "Pour la publier : git -C \"$public\" push origin main --tags"
