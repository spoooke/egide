# Mnémosyne

Time Machine backup reminders for a Mac backed up to an external disk plugged in by hand. Égide on the Mac follows Time Machine, Égide on the iPhone shows the last backup and reminds when the next one is due. Time Machine's automatic backups stay on: macOS backs up shortly after the disk is plugged in, and does nothing while it is away.

## What macOS allows without administrator rights

Behaviour seen on macOS 27 (`tmutil` 4.0.0), without sudo or Full Disk Access.

| Command | Without sudo | What it gives |
| --- | --- | --- |
| `tmutil destinationinfo -X` | yes | `Destinations`: one entry per disk with `ID`, `Name`, `Kind`, `QuotaGB`, `LastDestination` (1 for the last one used), and `MountPoint` only while it is plugged in |
| `tmutil status -X` | yes | `Running`, `Percent` (-1 when idle); during a backup `BackupPhase` (`Starting`, `PreparingSourceVolumes`, `Copying`…), `DestinationID`, and `Progress` with `Percent` (0 to 1), `TimeRemaining`, `bytes`, `totalBytes` |
| `tmutil startbackup --auto [--destination id]` | yes | Starts a backup. Exits with 0 even when backupd refuses: follow `status` and the log |
| `tmutil latestbackup`, `listbackups`, `machinedirectory` | no | Root and Full Disk Access |
| `setdestination`, `enable`, `disable`, `setquota`, `delete`… | no | Root and Full Disk Access; they change the settings, Mnemosyne never runs them |

The backup volume itself and `/Library/Preferences/com.apple.TimeMachine.plist` cannot be read without Full Disk Access.

## Last backup date

It comes from backupd's log, read with `/usr/bin/log show --info` (in zsh, `log` is a builtin). One backup at a time, in this order:

1. `BackupDispatching`: « Backup requested to destination with ID … » (System Settings, `--destination`) or « Backup requested to next destination in rotation » (macOS on its own, `--auto` alone);
2. `MountedDestinationManager`: « Mounting destination <ID> for backing up »;
3. `BackupDispatching`: « Backup succeeded » followed by « Elapsed time: … », or « Backup failed: BACKUP_FAILED_… (n) ».

Any process may write to this subsystem. A success counts only when it comes from `/System/Library/CoreServices/TimeMachine/backupd` and its backup went to a disk set in Time Machine. « No such destination » is not a failure: with a disk plugged in by hand, it is the usual state.

## Organisation

- No separate Mac app or menu bar icon: Mnemosyne is a tool in Égide on the Mac and runs with it.
- `Modules/MnemosyneKit`: `Sources/Shared` (due date, format exchanged with Argos), `Sources/macOS` (tmutil, log, « Sauvegarder maintenant », report to the Argos server on `127.0.0.1:8787` with the agent token, like Héphaïstos), `Sources/iOS` (Égide tab, reads `GET /api/mnemosyne`).
- Due date: monthly by default, or weekly on a chosen day (skipped when it falls less than 4 days after the backup), always counted from the last successful backup. Reminders on the due date, then 2 and 7 days later.
- History: Égide on the Mac keeps the last 50 backups it read in the log (start, end, outcome, disk), since the log only holds a few days, and sends them with each report. Both apps show the gap since the previous backup and any delay past the reminder.
- Argos server: `POST /api/mnemosyne` (agent token, from this Mac only), `GET /api/mnemosyne` and `POST /api/mnemosyne/backup` (app token; refused unless the Mac saw the disk in the last 3 minutes).
- iPhone reminders are local notifications scheduled by Égide from the last known date, so they show up with the Mac off. ntfy only reports a failed backup.
- Choosing the disk needs administrator rights: Mnemosyne opens System Settings › General › Time Machine instead of asking for the password.

---

# Mnémosyne

Rappel des sauvegardes Time Machine d'un Mac sauvegardé sur un disque externe branché à la main. Égide sur le Mac suit Time Machine, Égide sur l'iPhone affiche la dernière sauvegarde et prévient quand la suivante est due. Les sauvegardes automatiques de Time Machine restent actives : macOS sauvegarde peu après le branchement, et ne fait rien tant que le disque est absent.

## Ce que macOS permet sans droits administrateur

Comportement observé sur macOS 27 (`tmutil` 4.0.0), sans sudo ni accès complet au disque.

| Commande | Sans sudo | Ce qu'on en tire |
| --- | --- | --- |
| `tmutil destinationinfo -X` | oui | `Destinations` : une entrée par disque avec `ID`, `Name`, `Kind`, `QuotaGB`, `LastDestination` (1 pour le dernier utilisé), et `MountPoint` seulement quand il est branché |
| `tmutil status -X` | oui | `Running`, `Percent` (-1 au repos) ; pendant une sauvegarde `BackupPhase` (`Starting`, `PreparingSourceVolumes`, `Copying`…), `DestinationID`, et `Progress` avec `Percent` (de 0 à 1), `TimeRemaining`, `bytes`, `totalBytes` |
| `tmutil startbackup --auto [--destination id]` | oui | Lance une sauvegarde. Code de sortie 0 même si backupd refuse : suivre `status` et le journal |
| `tmutil latestbackup`, `listbackups`, `machinedirectory` | non | Root et accès complet au disque |
| `setdestination`, `enable`, `disable`, `setquota`, `delete`… | non | Root et accès complet au disque ; ils changent le réglage, Mnémosyne ne les lance jamais |

Le volume de sauvegarde et `/Library/Preferences/com.apple.TimeMachine.plist` ne sont pas lisibles sans l'accès complet au disque.

## Date de la dernière sauvegarde

Elle vient du journal de backupd, lu avec `/usr/bin/log show --info` (dans zsh, `log` est une commande interne). Une sauvegarde à la fois, dans cet ordre :

1. `BackupDispatching` : « Backup requested to destination with ID … » (Réglages Système, `--destination`) ou « Backup requested to next destination in rotation » (macOS de lui-même, `--auto` seul) ;
2. `MountedDestinationManager` : « Mounting destination <ID> for backing up » ;
3. `BackupDispatching` : « Backup succeeded » suivi de « Elapsed time: … », ou « Backup failed: BACKUP_FAILED_… (n) ».

N'importe quel programme peut écrire dans ce sous-système. Une réussite ne compte que si elle vient de `/System/Library/CoreServices/TimeMachine/backupd` et que sa sauvegarde est allée sur un disque réglé dans Time Machine. « Disque introuvable » n'est pas un échec : avec un disque branché à la main, c'est l'état normal.

## Organisation

- Pas d'app Mac à part ni d'icône dans la barre des menus : Mnémosyne est un outil d'Égide sur le Mac et tourne avec lui.
- `Modules/MnemosyneKit` : `Sources/Shared` (échéance, format échangé avec Argos), `Sources/macOS` (tmutil, journal, « Sauvegarder maintenant », envoi au serveur Argos par `127.0.0.1:8787` avec le jeton de l'agent, comme Héphaïstos), `Sources/iOS` (onglet d'Égide, lit `GET /api/mnemosyne`).
- Échéance : mensuelle par défaut, ou chaque semaine le jour choisi (sauté s'il tombe moins de 4 jours après la sauvegarde), toujours comptée depuis la dernière sauvegarde réussie. Rappels à l'échéance, puis 2 et 7 jours après.
- Historique : Égide sur le Mac garde les 50 dernières sauvegardes lues dans le journal (début, fin, résultat, disque), puisque le journal ne garde que quelques jours, et les envoie avec chaque rapport. Les deux apps montrent l'écart avec la précédente et le retard sur le rappel.
- Serveur Argos : `POST /api/mnemosyne` (jeton des agents, depuis ce Mac seulement), `GET /api/mnemosyne` et `POST /api/mnemosyne/backup` (jeton des apps ; refusé si le Mac n'a pas vu le disque dans les 3 dernières minutes).
- Les rappels de l'iPhone sont des notifications locales programmées par Égide depuis la dernière date connue : ils arrivent Mac éteint. ntfy ne signale qu'une sauvegarde échouée.
- Le choix du disque demande les droits administrateur : Mnémosyne ouvre Réglages Système › Général › Time Machine au lieu de demander le mot de passe.
