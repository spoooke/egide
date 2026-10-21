#!/bin/sh
# Point d'entrée Mac et Linux : détecte le système et lance le bon installateur (mêmes options).
#   installer/install.sh [--update | --uninstall | --import <archive>]
# Windows : install.ps1 (voir installer/README.md).
dir=$(cd "$(dirname "$0")" && pwd)
case "$(uname -s)" in
  Darwin) exec "$dir/install-mac.sh" "$@" ;;
  Linux) exec sudo bash "$dir/install-linux.sh" "$@" ;;
  *) echo "Système non pris en charge ici. Windows : powershell -ExecutionPolicy Bypass -File install.ps1" >&2; exit 1 ;;
esac
