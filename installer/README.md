# Installer

| | Script | |
|---|---|---|
| Mac | `install.sh` → `install-mac.sh` | Argos, Hermès, Muse, Pactole, Héphaïstos, iphone-refresh, Égide on the iPhone |
| Linux | `install.sh` → `install-linux.sh` | Argos agent (systemd) |
| Windows | `install.ps1` | Argos agent (startup task) |

Each script asks a few questions first (which apps, iPhone or Android) and takes `--update` and `--uninstall`. No secrets in the scripts: tokens are asked for or created on the spot.

Chaque script pose d'abord quelques questions (quelles apps, iPhone ou Android) et accepte `--update` et `--uninstall`. Aucun secret dans les scripts : les jetons sont demandés ou créés sur place.

Moving to a new Mac / changer de Mac: `export-mac.sh` on the old one, then `install-mac.sh --import <archive>` on the new one.
