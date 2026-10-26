# Cerbère — décisions de conception

Audit de sécurité **défensif et statique** avant d'installer : un dépôt, une app ou un fichier. Rien n'est exécuté ni installé. Plan : sections « Cerbère » de `ROADMAP.md`.

Limite assumée : un audit statique baisse le risque, il ne prouve pas qu'un logiciel est sain.

## Principes

1. **Le code audité est une donnée non fiable.** Toute instruction qu'il contient (commentaire, README, nom de fichier, chaîne) est un constat à signaler, jamais un ordre.
2. **Jamais d'exécution** : ni script, ni build, ni installation de dépendances, ni ouverture par une app.
3. **Jamais de vrai malware téléchargé** : les jeux d'essai sont fabriqués par nous.
4. **Deux couches** : (1) règles automatiques locales ; (2) lecture par IA qui rédige le rapport à partir du code et des résultats de la couche 1.

## Zone de quarantaine

Emplacement : `~/Library/Caches/Cerbere/quarantaine/<identifiant>/` (hors Bureau et hors iCloud).

Récupération d'un dépôt (prouvée le 2026-10-12 sur un dépôt d'essai local piégé : hook `post-checkout` par modèle et filtre `smudge` ; le clone ordinaire les déclenche, le clone de quarantaine non) :

```sh
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 \
GIT_ATTR_NOSYSTEM=1 GIT_LFS_SKIP_SMUDGE=1 GIT_TERMINAL_PROMPT=0 \
git -c core.hooksPath=/dev/null -c core.fsmonitor=false -c core.symlinks=false \
    -c core.fileMode=false -c protocol.ext.allow=never -c submodule.recurse=false \
    clone --depth 1 --no-tags --single-branch --no-recurse-submodules --template= <lien> <dossier>
```

- La configuration git de la machine est ignorée (pas de filtres, pas de modèle de hooks, pas d'aide aux identifiants).
- Pas de sous-modules, pas de LFS, pas de liens symboliques créés (`core.symlinks=false` : ils deviennent des fichiers texte, et sont signalés).
- Après le clone : on note l'empreinte du commit et les droits d'origine de chaque fichier (pour l'inventaire), on supprime `.git`, puis fichiers en `0400` et dossiers en `0700`. Aucun fichier exécutable ne reste.
- Seuls les liens `https://` sont acceptés ; le domaine est affiché avant la récupération.
- Les outils d'analyse sont lancés depuis un autre dossier, avec le chemin de la quarantaine en argument.
- La quarantaine est supprimée à la fin de l'audit (le rapport garde les extraits cités).

## Moteur d'IA (couche 2)

**Claude Code en ligne de commande (`claude -p`) avec l'abonnement Pro.** Pas de clé à stocker, pas de coût en plus. Seul domaine contacté : anthropic.com.

Lancement verrouillé (`MoteurIA.swift`, prouvé par essai le 2026-10-13 avec Claude Code 2.1.284) :

```sh
claude -p --safe-mode --tools "" --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
  --setting-sources "" --disable-slash-commands --no-chrome --no-session-persistence \
  --permission-mode dontAsk --permission-prompts none --model sonnet \
  --system-prompt "<consignes de Cerbère>" --output-format stream-json --verbose
```

- `--tools ""` : aucun outil (ni commandes, ni lecture ou écriture de fichiers, ni web). `--strict-mcp-config` avec une liste vide : aucun connecteur.
- `--safe-mode`, `--setting-sources ""`, `--disable-slash-commands` : réglages, `CLAUDE.md`, hooks, extensions et compétences de la machine ignorés. `--system-prompt` remplace les consignes de Claude Code par les nôtres.
- `--no-session-persistence` : la conversation, donc le code audité, n'est pas gardée sur le disque.
- Lancé depuis un dossier vide créé pour l'occasion (dossier temporaire, jamais la quarantaine), avec un environnement réduit (`HOME`, `USER`, `PATH`) et les envois annexes coupés (`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, `DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING`, `DISABLE_AUTOUPDATER`). Le message passe par l'entrée standard.
- Contrôle à chaque appel : claude déclare au lancement ses outils, connecteurs, commandes et compétences ; si une seule liste n'est pas vide, si le dossier n'est pas le bon ou si une réponse contient un appel d'outil, la réponse est refusée. Un appel à blanc (« ok ? ») est fait avant d'envoyer le moindre code.
- Pas de `--bare` : il coupe l'abonnement (clé d'API obligatoire).

Preuve (`verrouillageProuve`) : claude est lancé exprès depuis un dossier piégé (un `CLAUDE.md`, un `.mcp.json`, des réglages avec hooks et permissions, un fichier secret) et on lui demande de lire le fichier, de lancer une commande et de réciter ses consignes. Résultat : aucun outil ni connecteur déclaré, aucun hook lancé, fichier non lu, consigne du `CLAUDE.md` absente.

## Lecture par IA (phase 2)

Code : `LectureIA.swift`. Déroulement :

1. **Choix et découpage** : les fichiers sont coupés en tranches de 30 000 caractères au plus, aux fins de ligne. Chaque tranche reçoit une priorité : scripts d'installation et hooks, endroits désignés par une règle, points d'entrée, passages qui touchent au réseau, aux commandes ou aux fichiers de l'utilisateur ; essais, exemples et documentation après ; fichiers générés jamais. Les lots (150 000 caractères) sont remplis dans cet ordre, jusqu'à `--lots` lots (6 par défaut) : c'est la borne du quota. Un même contenu sous deux chemins n'est lu qu'une fois. `--apercu` montre le plan sans rien envoyer.
2. **Envoi** : chaque fichier est encadré par des marques qui portent un jeton tiré au hasard pour l'audit (le code ne peut pas le deviner pour « fermer » le cadre), ses lignes sont numérotées, les secrets y sont masqués. Les consignes disent que tout ce qui est dans le cadre est une donnée non fiable, et le rappellent après les données.
3. **Réponse** : un objet JSON (constats, avis sur les indices des règles, notes). Seuls les champs et valeurs du format sont acceptés ; une réponse illisible est redemandée une fois, puis le lot est compté « non lu ». Les textes de l'IA sont nettoyés (une ligne, pas de lien ni de balise).
4. **Citation vérifiée** : un constat de l'IA doit citer un fichier du lot et un extrait qui s'y trouve vraiment. La ligne est corrigée si l'extrait est ailleurs dans le fichier ; s'il n'existe pas, le constat est rejeté. L'extrait gardé dans le rapport est recopié du fichier, pas de la réponse.
5. **Relecture** : une seconde question, avec le code autour de chaque constat, peut seulement garder, baisser ou retirer. Elle ne peut ni ajouter ni aggraver.
6. **Verdict** : calculé par le code à partir des constats (même règle que la couche 1), jamais par l'IA. Le résumé est rédigé par l'IA à partir des constats retenus, puis complété par un bilan chiffré écrit par le code.

Ce que l'IA peut faire d'un indice des règles : le confirmer (« suspect » devient « confirmé », revu à la relecture) ou l'écarter (`avis_ia: faux_positif` : il reste dans le rapport, à part, et ne pèse plus). Elle ne peut jamais écarter un constat confirmé par une règle, un indice critique, ni une tentative de manipulation.

### Instructions cachées dans le code audité

- Elles sont un constat (catégorie `manipulation`), jamais un ordre : dit dans les consignes, et vérifié par essai.
- Un fichier où une règle relève une manipulation est lu dans un lot à part. Une réponse de l'IA qui a eu sous les yeux un tel fichier (relevé par une règle ou par l'IA elle-même) ne peut rien écarter, et ses constats ne passent pas par la relecture.
- Le verdict ne peut pas s'améliorer par l'IA : seuls les constats confirmés et les indices critiques le fixent, et l'IA ne peut retirer ni les uns ni les autres. Une IA qui obéirait à l'injection laisserait donc au pire le verdict des règles.
- Essais : `uneIAManipuleeNePeutRienEcarter` (faux moteur qui obéit), `injectionsLeVerdictNeBougePas` (vrai moteur : un paquet qui envoie la clé SSH reste « ne pas installer » avec une injection visible puis une injection écrite pour échapper aux règles, fausse fin de données et fausse consigne de Cerbère ; la manipulation est signalée).

Les essais réels consomment le quota et contactent anthropic.com : ils ne tournent que sur demande, `TEST_RUNNER_CERBERE_ESSAIS_IA=1 xcodebuild … test`. Les autres utilisent un faux moteur.

Limites : l'IA lit des passages choisis, pas tout un gros dépôt (le rapport dit combien de fichiers ont été lus en entier et en partie) ; chaque lot est lu sans les autres, un comportement réparti sur plusieurs fichiers peut lui échapper ; une injection assez habile pour tromper l'IA sans être relevée peut lui faire manquer un constat, mais pas effacer ceux des règles.

## Confidentialité

- La couche 1 est toujours locale : rien ne sort du Mac.
- Couche 2 **sans demander** : dépôt public récupéré par un lien `https` (le clone se fait sans identifiants : un dépôt privé échoue) ou paquet PyPI.
- Couche 2 **après accord, à chaque audit** : dossier local, archive, app, fichier. L'outil annonce le nombre de fichiers et la taille, et attend un « o » tapé au clavier ; sans terminal, rien n'est envoyé. `--sans-ia` coupe la couche 2.
- Secrets en dur (`Secrets.swift`) : clés AWS, GitHub, Anthropic et OpenAI, Slack, Google, Stripe, npm, PyPI, jetons JWT et Bearer, identifiants dans une adresse, jetons de webhook, clés privées (bloc entier), et affectations du type `mot_de_passe = "…"`. Ils sont remplacés par `«secret masqué»` avant tout envoi (les numéros de ligne ne bougent pas) et signalés par la règle `sec.en-dur`, avec un extrait déjà masqué.
- Base de réputation et Gatekeeper (phase 4) : seulement après accord, à chaque audit (voir « App ou fichier »).
- Vulnérabilités connues (phase 6, `api.osv.dev`) : écosystème, nom et version des dépendances seulement ; sans demander pour un dépôt public ou un paquet PyPI, après accord à chaque audit pour un élément du Mac.

## Format du rapport

Deux fichiers par audit : `rapport.json` (source, lu par l'app Mac et par Égide) et `rapport.md` (rendu lisible, produit à partir du JSON).

```json
{
  "version": 1,
  "cible": { "type": "depot | app | fichier", "source": "https://…", "commit": "…", "empreinte": "sha256…" },
  "date": "2026-10-12T14:00:00Z",
  "verdict": "ne_pas_installer | risque | rien_de_grave | incomplet",
  "resume": "Deux ou trois phrases.",
  "constats": [
    {
      "id": "C1",
      "gravite": "critique | elevee | moyenne | faible | info",
      "statut": "confirme | suspect",
      "categorie": "reseau | obfuscation | secrets | persistance | installation | dependances | manipulation | autre",
      "titre": "…",
      "fichier": "chemin/relatif",
      "lignes": [12, 18],
      "extrait": "preuve citée, tronquée",
      "explication": "ce que fait le code et pourquoi c'est un problème",
      "origine": "regle | ia",
      "regle": "obf.telecharge-execute",
      "avis_ia": "confirme | faux_positif",
      "note_ia": "raison donnée par l'IA"
    }
  ],
  "reseau": {
    "domaines": [ { "nom": "example.org", "fichiers": ["README.md"], "occurrences": 3 } ],
    "adresses": []
  },
  "fichiers_analyses": 214,
  "non_analyse": [ { "fichier": "…", "raison": "binaire, trop gros, illisible…" } ],
  "couches": { "regles": true, "ia": true, "gatekeeper": true, "reputation": true, "yara": true, "vulnerabilites": true },
  "ia": { "modele": "sonnet", "fichiers_lus": 46, "fichiers_en_partie": 11, "fichiers_lisibles": 775, "lots": 10, "lots_echoues": 0,
          "citations_introuvables": 0, "retires_a_la_relecture": 2, "secrets_masques": 0, "manipulation": false }
}
```

- `couches.gatekeeper`, `couches.reputation` et `couches.vulnerabilites` n'existent que si la vérification a été demandée et faite ; `couches.yara` dit si les règles YARA ont été appliquées (absent avant la phase 6). Pour une app, `cible.empreinte` est celle de son programme principal. Un `fichier` qui finit par `[signature]`, `[imports]`, `[chaînes]`, `[contenu]` ou `[macros]` est une fiche de Cerbère (phase 4) ; `archive.zip!/dedans` est un fichier d'un conteneur imbriqué.
- `avis_ia`, `note_ia` et `ia` n'existent que si la lecture par IA a eu lieu. Un constat `faux_positif` est gardé, rangé à la fin (« Écartés par la lecture par IA »), et ne compte pas dans le verdict.

- **confirmé** : le comportement se lit directement dans le code cité. **suspect** : indice qui demande une vérification.
- **Verdict** : `ne_pas_installer` dès un constat critique confirmé ; `risque` pour un constat élevé confirmé ou un critique suspect ; `rien_de_grave` sinon ; `incomplet` si une part importante n'a pas pu être analysée.
- `reseau` relève tous les domaines et adresses IP cités dans des URL, même sans constat : c'est la liste de ce que le code peut contacter.
- La catégorie `manipulation` sert aux instructions cachées destinées à l'IA ou à l'auditeur.
- Le Markdown commence par le verdict, puis les constats par gravité décroissante (confirmés avant suspects), puis ce qui n'a pas été analysé.

## App Mac (phase 3)

Code : `CerbereMac` (SwiftUI, cible `CerbereMac` de `project.yml`), installée dans `~/Applications/Cerbère.app` par `scripts/install-cerbere-mac.sh`. Elle utilise `CerbereKit` tel quel : mêmes règles, même lecture par IA, mêmes rapports que l'outil en ligne de commande, rangés au même endroit.

- **Saisie** : lien `https`, `pypi:nom`, ou dossier / archive glissé (ou choisi). Rien n'est contacté à la saisie : la carte « Avant de lancer » nomme le domaine de récupération et dit si le code partira à anthropic.com.
- **Audit** : hors du fil principal. `Audit.auditer(…, annulation:, ia:, suivi:)` ; `Avancement` donne l'étape (récupération, règles, lecture, relecture, résumé) et le nombre de lots lus. `Annulation` interrompt git, bsdtar, le téléchargement PyPI et `claude` ; l'audit finit par `ErreurCerbere.annule`, la quarantaine est supprimée, aucun rapport n'est écrit.
- **Accord** : pour un dossier ou une archive du Mac, l'audit s'arrête après les règles et montre `LectureIA.apercu` (fichiers, taille du texte, lots, secrets masqués). Sans « Envoyer », rien ne part ; l'accord ne vaut que pour cet audit. « Sans IA » coupe la couche 2 ; le nombre de lots borne le quota.
- **Affichage** : tout ce qui vient du code audité (noms de fichiers, extraits, domaines) et de l'IA passe par `Text(verbatim:)` après `montrable` (caractères de contrôle, invisibles ou d'inversion du sens remplacés). Ni Markdown, ni HTML, ni lien cliquable. Le PDF est du texte mis en page, sans lien.
- **Historique** : `Historique.lire` relit `rapport.json` dans chaque dossier de rapports. **Comparaison** (`Comparaison`) : verdict avant et après, constats apparus et disparus, nouveaux domaines. Un constat est reconnu d'une version à l'autre par sa règle (ou sa catégorie pour l'IA), son fichier et le texte cité : les numéros de ligne bougent. Les constats écartés par l'IA ne comptent pas. Deux audits ont la même cible si `cleCible` est égale (lien sans `.git`, paquet PyPI sans version, chemin).

## App ou fichier (phase 4)

`cerbere <app | image disque | paquet | archive | fichier> [--gatekeeper] [--reputation]`. La cible est reconnue à son contenu (premiers et derniers octets), pas à son nom (`Quarantaine.nature`).

Principe : tout ce qui n'est pas du texte devient une **fiche** lisible, écrite par Cerbère et ajoutée à l'inventaire. Les règles de la phase 1 et la lecture par IA de la phase 2 lisent les fiches comme des fichiers : mêmes constats cités à la ligne, même vérification des citations, mêmes défenses contre les instructions cachées (une chaîne d'un binaire reste une donnée non fiable).

| Cible | Code | Ce qui est fait, sans rien lancer |
| --- | --- | --- |
| App | `Signature.swift`, `Embarques.swift` | `codesign -d` et `codesign --verify --deep --strict` sur l'app elle-même (la copie de quarantaine ne recrée pas ses liens internes, la vérification y échouerait) ; `codesign --verify -R="anchor apple generic"` : sans cette remontée jusqu'à Apple, les noms des certificats ne prouvent rien ; droits demandés ; `Info.plist` ; agents et démons de lancement ; plists binaires réécrits en texte |
| Image disque | `Ouverture.swift` | `hdiutil attach -readonly -nobrowse -noautoopen -noautofsck -owners off -mountrandom <dossier de quarantaine>` : lecture seule, cachée du Finder, rien ne s'ouvre ; apps examinées sur le volume, copie, puis `hdiutil detach` dans tous les cas |
| Paquet | `Ouverture.swift` (`Paquet`) | certificats lus dans la table du paquet (`xar --dump-toc`) ; `pkgutil --expand-full` développe le paquet et sa charge sans rien installer ; scripts `preinstall` / `postinstall` et fiche `Distribution` lus comme du texte |
| Programme compilé | `Binaires.swift` | `otool -L`, `nm -u`, `strings -a` sur la copie de quarantaine : fiches `[imports]` et `[chaînes]` ; 25 programmes au plus, les principaux d'abord |
| PDF | `Documents.swift` | lu octet par octet ici même : `/JavaScript`, `/OpenAction`, `/Launch`, `/EmbeddedFile`, `/SubmitForm` ; flux compressés ouverts en mémoire ; code JavaScript recopié dans la fiche `[contenu]` |
| Document Office | `Documents.swift` | conteneur OLE lu ici même, macros VBA décompressées (format MS-OVBA) dans la fiche `[macros]` ; format récent : c'est une archive, ouverte comme telle |
| Conteneur imbriqué | `Ouverture.swift` | archive, paquet ou image rangé dans la cible : ouvert dans `<chemin>!/`, trois niveaux au plus, 40 conteneurs au plus ; `bsdtar` avec plafond de taille par fichier et de durée |

Gravité retenue :
- **Contenu modifié après la signature** : critique confirmé (« ne pas installer »). Sur une copie sortie d'une archive, seulement élevé et suspect : l'extraction peut fausser la vérification.
- **App sans signature, signature locale (ad hoc), certificat qui ne remonte pas à Apple, paquet non signé** : élevé confirmé (« risqué ») : macOS lui-même refuserait de l'ouvrir. Pour un programme seul, une signature locale est seulement « faible » (normal pour un outil compilé sur place).
- **Macro lancée à l'ouverture et qui lance des commandes** : critique suspect (« risqué »).
- Une fonction importée est une capacité, pas une preuve : `bin.capacites` est une information ; seules quelques fonctions rares donnent une alerte.

### Ce qui sort du Mac

Rien par défaut. Deux vérifications, chacune avec un accord donné pour l'audit en cours (option de l'outil, interrupteur de l'app remis à zéro après chaque audit) :

- **Gatekeeper** (`--gatekeeper`) : `spctl --assess` (et `pkgutil --check-signature` pour un paquet). C'est la preuve de la notarisation, mais macOS peut interroger Apple pour répondre. Sans accord, Cerbère s'en tient à ce qui est local : `codesign`, et la présence d'un ticket agrafé.
- **Réputation** (`--reputation`, `Reputation.swift`) : `GET https://www.virustotal.com/api/v3/files/<SHA-256>`. Seule l'empreinte part (ni fichier, ni nom, ni chemin), vers ce seul domaine, sans redirection ni cookie. Empreintes envoyées : le fichier audité, puis le programme principal de chaque app, quatre au plus. La clé personnelle est dans le trousseau (`cerbere --cle-virustotal`, saisie masquée), jamais dans un fichier ni un rapport. Cinq antivirus ou plus : critique confirmé ; un à quatre : moyen suspect (fausses alertes fréquentes) ; inconnu : information, ni bon ni mauvais signe.

Dans l'app Mac, la carte « Vérifications en ligne » n'apparaît que pour une app ou un fichier du Mac ; ses deux interrupteurs sont remis à zéro dès qu'un audit est lancé, et la clé VirusTotal est saisie dans un champ masqué puis rangée dans le trousseau (`CleReputation`).

La lecture par IA d'une app ou d'un fichier demande le même accord que pour un dossier : ce qui part, ce sont ses fichiers texte et les fiches (secrets masqués).

Essais réels le 2026-10-14 sur Stats (app notarisée d'un éditeur hors App Store) :

- `--gatekeeper` : « accepté », source « Notarized Developer ID », en 2 s.
- `--reputation` : une empreinte envoyée, « connu de VirusTotal, sans alerte » (0 antivirus sur 63), en 2 s. La clé n'apparaît ni dans le rapport ni dans les dossiers de Cerbère. Attention en la saisissant : collée hors de la question de `cerbere --cle-virustotal`, elle finit en clair dans le Terminal et dans `~/.zsh_history` (à regénérer si ça arrive).
- Lecture par IA dans l'app Mac : aperçu de 76 fichiers (382 ko, 3 lots, 2 secrets masqués), environ 1 min 45, aucun lot en échec ; l'IA écarte 14 constats sur 46, dont les 12 « élevée » des règles (scripts d'installation et de désinstallation de Stats, assistant des ventilateurs), et laisse 3 points moyens réels (bibliothèques d'autres éditeurs acceptées, assistant administrateur, pas d'icône dans le Dock). Les 2 « secrets » masqués étaient des jetons lus dans le trousseau par un script, pas des clés écrites en dur.

Limites : le code machine n'est désassemblé qu'autour des appels sensibles (phase 6) : un programme peut cacher ses appels et chiffrer ses textes ; les macros Excel 4 (XLM), les PDF chiffrés et les documents protégés par mot de passe ne sont pas lus (et le sont dits) ; une image disque chiffrée ou avec licence à accepter n'est pas montée ; monter une image fait lire son système de fichiers par macOS (comme un double-clic, l'ouverture en moins).

Essais : `Modules/CerbereKit/Tests/AppFichierTests.swift`, cibles fabriquées par `Fabrique.swift` avec les outils du système (`cc`, `codesign`, `pkgbuild`, `hdiutil`, `ditto`, `textutil`) : app signée sur place, modifiée après signature, sans signature ; paquet dont le script écrirait un témoin s'il était lancé ; image disque ; quatre archives l'une dans l'autre ; PDF avec JavaScript en clair et compressé ; document à macros ; faux serveur de réputation qui garde les requêtes reçues.

## Rétro-ingénierie avancée (phase 6)

Décisions validées le 2026-10-14 :
- **Désassembleur** : `objdump` de LLVM (`/usr/bin/objdump`, fourni avec les outils de développement d'Apple). Rien à installer ; il lit les programmes Mac, Linux et Windows (Intel et ARM).
- **YARA** : `yara` installé par Homebrew, avec des règles écrites par nous seulement (pas de jeu de règles téléchargé).
- **Vulnérabilités connues** : base OSV (`api.osv.dev`) ; seuls l'écosystème, le nom et la version de chaque dépendance partent. Sans demander pour un dépôt public ou un paquet PyPI (ses dépendances sont déjà publiques), après accord à chaque audit pour le reste.

### Programmes Windows (`Windows.swift`)

Le format PE est lu ici même, octet par octet, sans recopier le fichier en mémoire : architecture, type (console, fenêtres, pilote), sections et désordre de leurs octets (entropie), fonctions importées par DLL, signature Authenticode présente ou non (elle n'est pas vérifiée sur un Mac), programme .NET, données ajoutées après la dernière section. Fiche `[imports]` ; les textes UTF-16 (que `strings` ne lit pas) rejoignent la fiche `[chaînes]`.

| Règle | Gravité | Ce qui la déclenche |
| --- | --- | --- |
| `win.injection` | élevée, suspect | mémoire réservée et écrite dans un autre programme, puis fil lancé dedans |
| `win.creusement` | élevée, suspect | programme vidé puis réécrit (`NtUnmapViewOfSection` + `WriteProcessMemory` + `SetThreadContext`) |
| `win.telecharge-execute` | moyenne, suspect | de quoi télécharger et de quoi lancer |
| `win.clavier`, `win.mots-de-passe` | moyenne, suspect | suivi du clavier ; déchiffrement des secrets de Windows ou des navigateurs |
| `win.empaquete` | moyenne, suspect | section d'un outil connu (UPX, ASPack, MPRESS, Themida, VMProtect…) ou section au contenu désordonné (entropie > 7,2) : le vrai code n'est pas lisible |
| `win.anti-analyse`, `win.sans-signature` | faible | recherche d'un débogueur ; pas de signature |
| `win.surplus` | info | 64 Ko ou plus après la dernière section (installateurs, ou charge cachée) |

Un programme .NET est signalé comme non désassemblé (son code est un langage intermédiaire).

### Désassemblage ciblé (`Desassemblage.swift`)

`objdump -d` (avec `--macho` pour un programme Mac, qui nomme lui-même les fonctions importées et les textes cités), sur la copie de quarantaine, pour les six programmes principaux. Seuls les passages qui appellent une fonction sensible sont gardés (lancer une commande, charger du code, agir sur un autre programme, droits d'administrateur, clavier et écran, trousseau, démarrage automatique, réseau…) : les 8 instructions avant l'appel et les 4 après, dans la même fonction, et les textes qu'elles citent. Pour un programme Windows, Cerbère retrouve lui-même la fonction appelée (table d'import) et le texte cité (ASCII ou UTF-16). Fiche `[code]` : 80 passages au plus, 5 par fonction appelée ; au-delà de 64 Mo de sortie, le programme est désassemblé en partie (et c'est dit).

- `bin.commande` (moyenne, suspect) : un texte est passé à une fonction qui lance des commandes : c'est sans doute la commande lancée.
- Les règles et la lecture par IA lisent la fiche comme un texte : un `curl … | sh` écrit dans un programme et passé à `system` est relevé.

Limites : pour un programme Linux, les textes cités ne sont pas retrouvés (seules les fonctions appelées le sont) ; un appel indirect (adresse calculée, fonction chargée par `dlsym` ou `GetProcAddress`) n'est pas suivi ; un programme compressé ou chiffré ne montre que son décompresseur.

Essais : `DesassemblageTests` (programme Windows fabriqué octet par octet par `FabriqueWindows.swift`, programme Mac compilé par `cc` ; aucun n'est lancé). Vérifié le 2026-10-14 sur des apps du Mac (`--sans-ia`) : Calculatrice 5 s, Discord 9 s ; dans Tailscale, les passages qui demandent les droits d'administrateur et l'ouverture à la connexion sont bien isolés.

### Règles YARA (`Yara.swift`)

`yara` 4.5.8, installé par Homebrew le 2026-10-14 (`/opt/homebrew/bin/yara`, sinon `/usr/local/bin/yara`). Les règles sont écrites par nous, dans le code (`Yara.regles`), et recopiées dans un fichier provisoire hors de la quarantaine au moment de l'audit. Aucun module de YARA n'est chargé (pas d'analyseur de format en plus) : seulement des chaînes et des conditions. `yara -w -N -r -s -X -p 4 -a 300 -z 400000000` sur la quarantaine entière, binaires compris ; seuls les fichiers de l'inventaire sont retenus dans sa réponse (un nom de fichier piégé ne peut pas en inventer un).

| Règle | Gravité | Ce qui est cherché |
| --- | --- | --- |
| `yara.xor` | moyenne, suspect | adresse ou commande (`http://`, `cmd.exe`, `powershell.exe`, `/bin/sh`, `osascript -e`, `/Library/LaunchAgents`…) chiffrée octet par octet (XOR, toutes les clés) |
| `yara.base64` | moyenne, suspect | commande encodée en base64 (ou base64 d'UTF-16) dans un fichier binaire |
| `yara.programme-cache` | élevée, suspect | programme Windows complet au milieu d'un fichier qui n'en est pas un (ni archive, ni programme) |
| `yara.mineur` | élevée, suspect | groupe de minage (`stratum+tcp://`…) ou réglages de XMRig |
| `yara.rancon` | élevée, suspect | phrase d'un message de rançon (les mots « bitcoin », « .onion », « decrypt » seuls ne suffisent pas : tout navigateur les contient) |
| `yara.outil-attaque` | élevée, suspect | textes de Mimikatz, Cobalt Strike, Meterpreter |
| `yara.navigateurs` | moyenne, suspect | fichiers des mots de passe et cookies de Chrome, Edge, Brave… nommés ensemble (binaire) |
| `yara.portefeuilles` | élevée, suspect | deux portefeuilles de cryptomonnaie ou plus (extensions MetaMask, Phantom…, Exodus, Electrum…) (binaire) |

- Un texte caché (XOR, base64) est remis en clair en mémoire dans une fiche `<fichier> [caché]` : les règles et la lecture par IA la lisent, et son domaine rejoint la liste de ce que le code peut contacter. Une adresse remise en clair n'est gardée que si elle est courte et finit par une vraie extension de domaine (le dictionnaire de compression de Firefox en contient une fausse).
- Dans un fichier texte, la ligne est retrouvée ; dans la documentation, la gravité baisse d'un cran.
- `couches.yara` dit si les règles ont été appliquées ; sans `yara`, le résumé le dit (« brew install yara »).

Vérifié le 2026-10-14 sur Calculatrice, Discord, Tailscale, Steam, Firefox, UTM et Battle.net (`--sans-ia`, de 5 s à 75 s) : rien de grave ; restent dans Firefox l'import des mots de passe des autres navigateurs (`yara.navigateurs`, c'est sa fonction), et dans Steam les commandes réellement écrites dans le programme (`launchctl remove…`, `defaults read…`, `bin.commande`).

### Vulnérabilités connues des dépendances (`Dependances.swift`, `Vulnerabilites.swift`)

Dépendances à version exacte, lues dans les fichiers de verrouillage (rien n'est installé ni résolu) : `package-lock.json`, `npm-shrinkwrap.json`, `yarn.lock`, `pnpm-lock.yaml` (npm) ; `requirements*.txt` épinglé (`==`), `poetry.lock`, `uv.lock`, `pdm.lock`, `Pipfile.lock` (PyPI) ; `Cargo.lock` (crates.io, paquets publiés seulement) ; `go.mod` (Go, sans le « v ») ; `Gemfile.lock` (RubyGems) ; `composer.lock` (Packagist) ; `Package.resolved` (Swift, nommé par l'adresse du dépôt). Le projet lui-même n'est jamais envoyé (racine d'un `package-lock.json`, paquet « editable » d'`uv.lock`, crate sans registre). Pour `pypi:nom`, le paquet audité est ajouté (nom et version). 3 000 dépendances au plus.

- **Ce qui part** : `POST https://api.osv.dev/v1/querybatch` avec, pour chaque dépendance, `{"package":{"ecosystem","name"},"version"}` et rien d'autre ; puis `GET /v1/vulns/<identifiant>` pour le détail des failles trouvées (200 au plus, paquets malveillants d'abord). Même garde que VirusTotal : un seul domaine, sans redirection, sans cookie.
- **Quand** : sans demander pour un lien public ou un paquet PyPI, donc aussi depuis l'iPhone (`--sans-vulnerabilites` pour s'en passer) ; pour un élément du Mac, seulement avec `--vulnerabilites` (ou l'interrupteur de la carte « Avant de lancer » de l'app Mac, remis à zéro après chaque audit), accord qui ne vaut que pour cet audit.
- `dep.malveillant` (critique, confirmé → « ne pas installer ») : identifiant `MAL-` (base des paquets malveillants d'OpenSSF) ou avis GitHub intitulé « Malicious code in … ».
- `dep.faille` (confirmé, catégorie `dependances`) : une par dépendance touchée, moyenne si une faille est critique ou élevée, faible sinon ; l'extrait cite les identifiants (CVE), leur gravité et la version qui corrige. Une faille n'est pas une malveillance : le verdict n'en dépend pas.
- Les textes de la base (intitulés, versions) sont nettoyés : une ligne, sans lien ni balise.
- Base injoignable : noté dans « non analysé », l'audit continue.

Essais : `VulnerabilitesTests` (dix formats de verrouillage, fausse base qui garde les requêtes : rien d'autre que écosystème, nom et version ; sans accord, rien ne part). Essai réel le 2026-10-14 (accord de l'utilisateur pour cet envoi) : liste fabriquée de 4 dépendances (lodash 4.17.15, event-stream 3.3.6, requests 2.19.0, gin 1.6.0), 4 touchées, versions corrigées données. `event-stream 3.3.6` y est un avis de faille critique (GHSA-mh6f-8j2x-4483), pas une fiche `MAL-` : il ressort comme faille.

## Affichage : à savoir (phase 7)

- Pastille « Vu dans le code » (statut `confirme`) : rouge plein seulement pour élevé et critique, neutre sinon.
- Pas de `.textSelection` dans les vues macOS des rapports et du journal : sur macOS 27, un texte sélectionnable coupé par le bord d'une zone qui défile fait boucler l'accessibilité jusqu'au plantage dès qu'un outil lit l'écran (VoiceOver, lecture d'écran). Trouvé le 2026-10-14 par élimination ; pour copier, l'export.

## Expliqué simplement (phase 7)

Code : `Neophyte.swift`, champ `neophyte` du rapport (`en_bref`, `a_savoir`, `que_faire`, `modele`, `date`), carte `CarteExplication` (Mac et iPhone), section « Expliqué simplement » du Markdown et du PDF.

- L'IA redit le rapport pour quelqu'un qui n'y connaît rien : deux à quatre phrases, cinq points « à savoir » au plus, quatre conseils au plus, en tutoyant, sans jargon.
- Elle ne reçoit que le rapport : verdict, résumé, titre et explication des constats retenus (30 au plus), noms des fichiers, nombre de constats écartés, domaines cités. **Jamais d'extrait de code.** Ces textes sont encadrés par un jeton et marqués « donnée non fiable » (un titre peut venir du logiciel audité).
- Le verdict reste celui du code, affiché au-dessus ; les consignes interdisent de le contredire ou de le rendre plus rassurant. Réponse nettoyée comme le reste (une ligne, ni lien ni balise) et affichée en texte brut.
- Mac : bouton « Expliquer simplement » sous le résumé, à la demande (environ 30 s, appel à blanc compris) ; pour un élément du Mac, une alerte nomme anthropic.com et ce qui part, et rien ne part sans « Envoyer ». Le rapport (`rapport.json`, `rapport.md`) est réécrit avec l'explication.
- iPhone : le relais la prépare à la fin de chaque audit demandé depuis l'iPhone (lien public ou PyPI, avec lecture par IA), car l'iPhone ne peut pas la demander après coup sans nouvelle route sur le serveur Argos ; elle est repliée sous le résumé. Un échec ne bloque pas le rapport.
- Essai réel le 2026-10-14 dans l'app Mac sur le rapport de `github.com/Graphify-Labs/graphify` (accord de l'utilisateur) : explication jugée claire par l'utilisateur.

## Travail en cours (phase 7)

Code : `Journal.swift` (`JournalAudit`, `JournalLu`), fenêtre `CerbereMac/VueTravail.swift`.

- Chaque audit écrit son journal dans `~/Library/Caches/Cerbere/journal/<horodatage>-<id>.jsonl` (droits `0600`, une ligne JSON par événement) : app Mac, outil `cerbere` et relais de l'iPhone. Rien n'en sort du Mac. Journaux de plus de 24 h effacés ; 5000 lignes au plus par audit.
- Contenu : étapes, inventaire, constats des règles (au-dessus d'« info »), chaque lot envoyé à l'IA (fichiers et lignes), sa réponse (constats proposés, avis sur les règles, citations rejetées) ou son échec, décisions de la relecture, verdict, accord attendu ou refusé, explication simple (relais). Jamais le contenu des fichiers.
- Fenêtre « Travail en cours » (menu Fenêtre, ⌘J, ligne de la barre latérale, lien « Voir le travail en détail » pendant un audit) : en cours d'abord, puis les dernières 24 h ; relu chaque seconde, défilement qui suit la fin (décochable), constats critiques et élevés en couleur, texte brut (`montrable`). Un journal sans fin dont le programme s'est arrêté est marqué « interrompu ».
- La barre latérale signale les audits en cours ailleurs (iPhone, outil) et l'historique se met à jour quand l'un d'eux finit.

## Vérification ciblée d'un constat (phase 7)

Code : `Verifications.swift`, champ `verification` d'un constat (`conclusion`, `explication`, `effet`, `modele`, `date`), `BlocVerification` (Mac et iPhone).

- Sur l'app Mac : « Vérifier ce point » sur chaque constat suspect (au-dessus d'« info », non écarté), et « Vérifier les élevés » pour tous les élevés et critiques encore à trancher.
- La cible est récupérée de nouveau en quarantaine (même recette, rien n'est lancé, copie supprimée), puis l'IA reçoit, par fichier (cinq constats au plus par appel, trois appels à la fois) : environ 60 lignes de part et d'autre du passage (secrets masqués), la liste des noms de fichiers, les 60 premières lignes du README, le constat et l'avis de la première lecture. Tout est encadré par un jeton, « donnée non fiable ».
- Conclusion de l'IA : faux positif, à surveiller ou grave, avec une explication simple et la ligne citée. **L'effet est décidé par le code** :
  - « grave » ou « faux positif » sans citation retrouvée dans le code → « à surveiller », rien ne change ;
  - « grave » → confirmé, compte dans le verdict ;
  - « faux positif » → écarté, sauf pour un constat critique, une tentative de manipulation, ou tout fichier où une manipulation a été relevée (refusé, reste suspect) ;
  - cible changée depuis l'audit (commit, version PyPI, empreinte) → conclusion notée sans rien changer, sauf si le passage cité se retrouve identique aux mêmes lignes.
- Verdict recalculé par le code ; l'explication simple, devenue fausse, est retirée (à redemander). Rapport réécrit, journal dans « Travail en cours ».
- Constat vu dans le code (moyen ou faible) : l'IA dit « normal » (rien ne change), « à surveiller » ou « grave » (relevé en élevée) ; jamais écarté. Un « normal » sur un suspect vaut un faux positif.
- Accord : lien public ou PyPI sans demander (nouveau téléchargement depuis le même site) ; élément du Mac après une alerte qui nomme anthropic.com et ce qui part.
- Essai réel le 2026-10-14 sur les 7 élevés du rapport de graphify (accord de l'utilisateur) : 7 faux positifs bien expliqués (tests et exemples), mais notés sans effet car le dépôt avait changé ; d'où la règle « passage identique ».

## Version Windows (phase 8)

Décidé le 2026-10-17 : Cerbère sur le PC, en Swift pour Windows, avec le même moteur que sur le Mac. Étape 1 faite : l'outil `cerbere.exe` (mêmes cibles, mêmes rapports, même journal).

Rangement de `Modules/CerbereKit/Sources` :

| Dossier | Contenu | Compilé pour |
| --- | --- | --- |
| `Shared` | rapport, historique, lien avec l'iPhone | iPhone, Mac, Windows |
| `Commun` | le moteur : quarantaine, règles, programmes, documents, YARA, OSV, IA, journal | Mac, Windows |
| `macOS` | signatures (`codesign`, `spctl`), images disque et paquets, `otool`/`nm`/`strings`, trousseau, relais | Mac |
| `Windows` | Authenticode, gestionnaire d'identifiants, droits NTFS, SHA-256 et décompression en Swift | Windows |

Le moteur ne passe que par `Plateforme` (une version par système) pour ce qui change : emplacements, outils, droits, empreintes, signatures. Un fichier n'est jamais à moitié Mac : pas de `#if os` dans `Commun`.

Ce qui diffère sur Windows :

- **Emplacements** : tout dans `%LOCALAPPDATA%\Cerbere` (`quarantaine`, `journal`, `rapports`, `bin`, `outils`).
- **Quarantaine** : la racine reçoit une liste d'accès écrite en entier (rien d'hérité) : le compte seul, contrôle total sur les dossiers, lecture, écriture et suppression sur les fichiers, **sans le droit d'exécuter**. Les fichiers sont en plus en lecture seule.
- **Clone** : git pour Windows, même recette ; `NUL` remplace `/dev/null`, le `PATH` contient les dossiers de git (transport https, `upload-pack`).
- **Archives** : `tar.exe` (bsdtar intégré à Windows). Pas de plafond de taille par fichier (pas d'`ulimit`) : seule la durée est bornée.
- **Programmes** : textes lus en Swift (pas de `strings`), désassemblage par `llvm-objdump` livré avec Swift. Un programme du Mac n'a pas ses fonctions importées lues.
- **Signature Authenticode** (programme seul, `.msi`, ou jusqu'à 8 programmes d'une archive), par PowerShell, en lecture seule, le chemin passé par une variable d'environnement. Sans accord : le nom du signataire lu dans le fichier (rien ne sort). Avec `--authenticode` (accord pour l'audit) : la vérification de Windows, qui dit si le fichier a été modifié depuis la signature ; Windows peut alors interroger l'autorité de certification.
- **Clé VirusTotal** : gestionnaire d'identifiants de Windows (`Cerbere/virustotal`), saisie masquée.
- **Non pris en charge** : images disque et paquets du Mac (signalés « non analysé »), signature des apps du Mac (leur contenu est lu comme un dossier), relais de l'iPhone.
- **YARA** : `yara64.exe` à placer dans `%LOCALAPPDATA%\Cerbere\outils` (sinon le rapport le dit).
- **IA** : `%USERPROFILE%\.local\bin\claude.exe`, même verrouillage que sur le Mac. Pas encore installé sur le PC : l'outil le dit et s'en tient aux règles.

Compilation : `scripts\build-cerbere-windows.ps1` (environ 2 min 30). Essais : `scripts\essais-cerbere-windows.ps1`, jeux fabriqués sur place (rien de téléchargé).

Essais réels le 2026-10-17 sur le PC (Windows 11 Famille, Swift 6.4.1), développés depuis le Mac par SSH via Tailscale :

- Piège git (filtre `smudge` et hook `post-checkout` par modèle, dans une configuration globale) : lancé par un clone ordinaire, pas par le clone de quarantaine.
- Une copie de `whoami.exe` dans la quarantaine refuse de se lancer ; la quarantaine se supprime malgré la lecture seule.
- SHA-256 identique à `certutil` ; flux PDF compressé lu ; programme Windows fabriqué (injection, téléchargement puis lancement) ; signataire de `git.exe` lu sans rien envoyer.
- `cerbere.exe` sur un dossier, une archive zip, un programme et un dépôt public (`https://github.com/pallets/itsdangerous`, 6 s, OSV compris) : mêmes rapports que sur le Mac.

À savoir : Smart App Control bloque tout programme sans signature reconnue, donc le compilateur Swift et `cerbere.exe`. Il a été désactivé sur ce PC par l'utilisateur.

## Dans Égide sur l'iPhone (phase 5)

L'iPhone ne récupère ni n'analyse rien : il demande l'audit au Mac et relit le rapport. Tout passe par le serveur Argos (Tailscale, jeton d'Argos).

```
iPhone (Égide › Cerbère)  ──demande──▶  serveur Argos du Mac  ◀──toutes les 10 s──  cerbere --relais (ce Mac)
        ◀──────── liste, avancement, rapport ────────┘                 └── audit avec CerbereKit, rapport rendu
```

- **Ce qu'on peut demander** (`CibleDistante`, `Sources/Shared/Distant.swift`) : un lien `https` vers un site public, ou `pypi:nom`. Refusés : chemin du Mac, `file:`, `http:`, adresse IP, nom local (`.local`, `.ts.net`…), identifiants ou port dans le lien, nom de domaine non ASCII. Le lien est ramené à l'adresse du dépôt (sans paramètres ; sur GitHub et GitLab, sans la page ouverte), une page `pypi.org/project/nom` devient `pypi:nom`. Le contrôle est fait trois fois : iPhone, serveur (`validCerbTarget`), relais.
- **Confidentialité** : ce qui passe est exactement ce qui part à l'IA sans demander (dépôt public, paquet PyPI). Un élément du Mac ne peut pas être audité par ce chemin : il demanderait un accord, qui ne se donne que sur le Mac.
- **Partage** : l'extension `EgidePartage` (« Égide » dans la feuille de partage de Safari ou de GitHub) ouvre `egide://cerbere/audit?lien=…`. Elle ne contacte rien. Le lien remplit le champ de Cerbère et s'arrête là : la demande ne part qu'avec « Envoyer au Mac », après la carte « Avant d'envoyer » (lien retenu, domaine contacté par le Mac, envoi à anthropic.com). N'importe quelle app peut ouvrir un lien `egide://` : c'est pour cela que rien n'est envoyé tout seul. Pas de nouveau schéma d'URL (`muse://` reste celui des raccourcis de Muse).
- **Serveur Argos** (`cmd/server/cerbere.go`, dépôt Argos) : il garde la file et les rapports, il ne récupère ni n'exécute rien. Routes de l'iPhone (jeton d'Argos) : `GET` et `POST /api/cerbere/audits`, `GET` et `DELETE /api/cerbere/audits/{id}`. Routes du relais (jeton des agents **et** appel venu de ce Mac seulement, sans `X-Forwarded-For`) : `POST /api/cerbere/next`, `…/audits/{id}/progress`, `…/audits/{id}/result`. Le jeton des agents est aussi sur les autres ordinateurs : sans cette limite, l'un d'eux pourrait déposer un faux rapport rassurant. Un audit à la fois, 5 demandes en attente au plus (borne du quota), 30 audits gardés, rapport de 4 Mo au plus, audit perdu après 45 min.
- **Relais** (`Relais.swift`, `cerbere --relais`, service `com.spoooke.cerbere.relais` installé par `scripts/install-cerbere.sh` sur accord : `--relais` ou « o » à la question) : mêmes règles et même lecture par IA que l'outil (modèle `sonnet`, 6 lots), rapport rangé avec les autres (visible dans l'app Mac). Il annonce l'étape en cours toutes les 3 s et y apprend l'annulation demandée depuis l'iPhone (git et `claude` interrompus, rien n'est gardé). Une erreur est rendue sur une ligne, bornée à 200 caractères (le message de git vient du site distant).
- **Notification** : ntfy, comme les alertes d'Argos. Elle ne porte que le verdict (« Cerbère : rapport prêt », « Risqué ») : ni le lien audité ni un mot du rapport ne passent par ntfy.
- **Affichage** : `Sources/Interface/Affichage.swift` est partagé par l'app Mac et l'iPhone (`CarteConstat`, `Extrait`, `montrable`) : texte brut, ni Markdown, ni lien, rien de cliquable venu du code audité ou de l'IA.

Essais : `DistantTests` (liens acceptés et refusés, relais avec un faux serveur : cible du Mac jamais auditée, annulation, erreur bornée) et `cerbere_test.go` côté serveur (file, annulation, relance, routes du relais refusées à une autre machine).

Limites : l'ouverture d'Égide depuis l'extension de partage passe par un usage toléré mais non garanti par Apple (si elle cesse de marcher : copier le lien et « Coller » dans Cerbère) ; un nom public qui pointerait vers une adresse du réseau local n'est pas détecté (le clone échouerait, ou un dépôt du réseau local serait lu : jamais un fichier du Mac) ; les rapports gardés par le serveur sont en clair dans son dossier de données, comme ceux du Mac.

## Couche 1 : règles automatiques (phase 1)

Code : `Modules/CerbereKit` (Swift, sans dépendance externe). Outil : `cerbere <lien https | pypi:nom | dossier | archive | app | image disque | paquet | fichier> [--sortie <dossier>] [--garder] [--sans-ia] [--apercu] [--modele <nom>] [--lots <n>] [--gatekeeper] [--reputation]`, installé par `scripts/install-cerbere.sh` dans `~/.local/bin`. Rapports dans `~/Library/Application Support/Cerbere/rapports/`. Code de sortie : 1 si le verdict est « ne pas installer », 2 en cas d'erreur, 0 sinon.

| Famille | Fichier | Ce qui est cherché |
| --- | --- | --- |
| Inventaire | `Inventaire.swift` | exécutables compilés (Mach-O, ELF, Windows, WebAssembly…), exécutable ou archive sous un nom anodin, liens symboliques qui sortent du dépôt, sous-modules |
| Réseau | `Regles.swift`, `Analyses.swift` | shell inversé, webhooks de messagerie, envoi des variables d'environnement, services de dépôt anonyme ou de tunnel, IP publique en dur, Tor, liens raccourcis ; relevé de tous les hôtes |
| Code caché ou téléchargé | `Regles.swift`, `Analyses.swift` | `curl … \| sh`, code décodé puis exécuté, PowerShell encodé, texte reconstruit octet par octet, obfuscateur, caractères invisibles, blocs base64 décodés sur place, lignes géantes |
| Secrets | `Regles.swift`, `Secrets.swift` | secrets écrits en dur (masqués) ; trousseau, données de navigateur, portefeuilles, clés SSH et GPG, fichiers d'identifiants, fausse demande de mot de passe, clavier, écran, presse-papiers |
| Persistance | `Regles.swift` | agents de lancement, démarrage du shell, tâches planifiées, services Linux, clés Windows, éléments de connexion, protections affaiblies |
| Installation et dépendances | `Installation.swift` | scripts npm (`postinstall`…), `setup.py`, tâche d'éditeur à l'ouverture, scripts de paquet, phases de script Xcode ; dépendances hors registre, non bornées, non épinglées, noms proches d'un paquet connu, autre index Python |
| Manipulation | `Regles.swift` | texte qui s'adresse à l'auditeur ou à l'IA (« ignore les instructions… ») : signalé, jamais suivi |

Règles de prudence :
- Une règle ne met « confirmé » que si la ligne citée suffit (shell inversé, `curl … | sh`, exécutable déguisé), et seulement dans un script de commandes (shell, PowerShell, Dockerfile, Makefile) : ailleurs, la même ligne peut n'être qu'une chaîne dans un essai. Tout le reste est « suspect » : c'est la lecture par IA (phase 2) qui tranchera.
- Dans la documentation, un constat baisse d'un cran et devient « suspect » (une consigne d'installation n'est pas du code lancé). Exception : la manipulation, jamais atténuée.
- Trois occurrences gardées par règle et par fichier, les autres comptées.
- Les blocs encodés sont décodés en mémoire pour être lus, jamais écrits ni lancés.

Archives et paquets Python (`Pypi.swift`, `Quarantaine.extraire`) :
- `cerbere pypi:<nom>` lit la fiche du paquet sur pypi.org, télécharge la wheel et l'archive source de la dernière version depuis files.pythonhosted.org (aucun autre domaine, redirections comprises), vérifie leur empreinte SHA-256, puis les ouvre dans `wheel/` et `sdist/`. Rien n'est installé : ni `pip`, ni `setup.py`.
- Une archive est extraite par `/usr/bin/bsdtar` dans un dossier provisoire (chemins absolus et `..` refusés), puis passe par la copie de quarantaine : liens notés et jamais recréés, fichiers en lecture seule.
- Auditer le dépôt ne suffit pas : ce qui est installé, c'est l'archive du registre. Pour comparer, garder les deux quarantaines (`--garder`) et comparer les empreintes des fichiers.

Limites connues : un très gros fichier de données ralentit l'audit (les règles tournent en parallèle par fichier, pas à l'intérieur d'un fichier) ; les dépendances listées dans la fiche d'une wheel (`Requires-Dist`), `pyproject.toml`, `Cargo.toml` et `Gemfile` donnent des plages, pas des versions : seuls les fichiers de verrouillage (et `go.mod`) servent à chercher les failles connues (phase 6) ; les règles reconnaissent des formes connues, un code écrit pour les éviter passera (d'où la phase 2).

Cerbère audité par lui-même se signale : ses règles et ses jeux d'essai contiennent les motifs qu'il cherche. Aucune exception n'est faite pour un chemin, ce serait une porte de sortie pour un dépôt piégé.

Jeux d'essai : `Modules/CerbereKit/Tests/Jeux.swift` écrit de faux dépôts dans un dossier temporaire (domaines en `.invalid`, adresses 203.0.113.x réservées à la documentation). Rien n'est téléchargé, rien n'est exécuté.
