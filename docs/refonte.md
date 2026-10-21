# Refonte d'Égide

Décidée le 19 octobre 2026. Deux buts : une seule app Égide sur le Mac comme sur l'iPhone, et un dépôt public qui serve de portfolio pour le développement macOS et iOS.

## Ce qui change

Aujourd'hui l'iPhone a une app à onglets, mais le Mac a une app par outil : Pactole, Héphaïstos, Cerbère, chacune avec sa fenêtre et parfois son icône dans la barre des menus. Après la refonte :

- **une app Égide sur le Mac**, avec une colonne d'outils à gauche et un accueil qui résume chaque outil ;
- **une seule icône dans la barre des menus** : la température du Mac, avec en menu la semaine de Pactole et l'accès aux onglets ;
- la même interface, revue, sur l'iPhone.

Les couleurs ne bougent pas : bleu `#3F74D9`, texte `#1E2B45`, fond blanc vers bleu pâle, cartes blanches (`EgideTheme`). La mise en page s'inspire d'un tableau de bord vu sur Instagram (colonne d'icônes détachée du bord, grandes cartes, une information principale par carte), sans reprendre ses tuiles de chiffres ni ses étiquettes colorées.

## Étapes

| | Contenu | État |
|---|---|---|
| 1 | Cible `EgideMac` : fenêtre, accueil, barre des menus. Héphaïstos, Pactole et Cerbère branchés tels quels | fait, branche `refonte/egide-mac` |
| 2 | Écran principal de chaque outil dans la nouvelle mise en page : Pactole en deux colonnes avec ses actions dans l'en-tête, Cerbère avec son historique en carte, Héphaïstos en deux colonnes | fait |
| 2 bis | Écrans secondaires de Pactole : en-tête dans la page (Retour, titre en grand). Reste : les flèches de mois du bilan et le + des frais fixes sont encore dans la barre de titre | fait |
| 3 | Muse, Iris et Argos sur le Mac. Muse : nouvel appareil de la synchro (choisir le dossier dans Synchro). Iris : les scans copiés par l'iPhone, par genre, avec Coup d'œil. Argos : connexion directe au serveur local | fait |
| 3 bis | Muse et Argos dans la mise en page Mac : en-tête et actions dans la page. Argos en deux colonnes, l'état d'ensemble en phrases au lieu des quatre tuiles de chiffres. Écrans secondaires de Pactole, Muse et Argos : même en-tête (`egideTitre`, EgideUI) | fait |
| 3 ter | Hermès : onglet en lecture seule (agent en marche ou non, iPhone autorisés avec leur empreinte, dernières sessions) et bouton qui ouvre le panneau de l'agent. Appairer et révoquer restent dans l'agent : lui seul a le droit d'enregistrer l'écran et garde la clé du Mac | fait |
| 4 | Accueil iPhone comme celui du Mac : la date en titre, les outils sur une bande, une carte par outil (la première en grand), les outils sans nouvelles regroupés sur une ligne. Les écrans des outils gardent la navigation iPhone | fait |
| 4 bis | Argos en Swift 6 (dates et formats sûrs entre fils). Hermès : la connexion et le scanner de QR code corrigés, mais le module reste en Swift 5 | fait |
| 4 ter | Hermès en Swift 6 : réécrire RemoteClient et VideoView (état partagé entre le fil réseau et l'écran), à tester sur l'iPhone avec l'agent | |
| 4 quater | Noms : MoneyKit → PactoleKit, MoneyMac → PactoleMac, types `Money…` → `Pactole…`. Gardés exprès : le nom de la base (« Money »), les clés « money. », la classe `MoneyTombstone` (entité SwiftData), l'identifiant `com.spoooke.money` et le lien `egide://money`. Le script des vitrines retire les anciens dossiers du dépôt Pactole | fait |
| 5 | Retirer les apps Mac Pactole, Héphaïstos et Cerbère une fois Égide Mac validé au quotidien | |
| 6 | Préparation du dépôt public : historique vérifié (aucun secret ; trois éléments personnels retirés du code actuel : employeur, ville, adresse Tailscale), README en français, mode démo (`-egide.demo YES`) et captures anonymes dans `docs/captures` | fait |
| 6 bis | Publier : copie propre sans historique (recommandé) ou historique réécrit. Vérifier aussi le dépôt vitrine Pactole, qui a reçu les mêmes sources | |

## Points à garder en tête

- **Données.** La base de Pactole (`~/Library/Application Support/Money.store`) et les rapports de Cerbère sont déjà à un endroit commun : Égide Mac les lit sans migration. Les préférences, elles, dépendaient de l'identifiant de chaque app ; Égide les recopie au premier lancement (`Reprise` dans `EgideMac/EtatEgide.swift`).
- **Pendant la transition**, ne pas laisser tourner Égide Mac en même temps que Pactole : les deux synchroniseraient le même dossier iCloud. Pour un essai à côté des anciennes apps, lancer avec `-egide.repriseFaite YES`, qui saute la reprise des réglages (donc la synchro).
- **Muse** : Égide Mac a sa propre base (`Muse.store`), distincte de l'app Muse Mac (`default.store`) ; les deux se rejoignent par le dossier de synchro.
- **Héphaïstos** envoie ses mesures au serveur Argos ; deux apps lancées en même temps envoient deux fois.
- **Captures publiques** : uniquement en mode démo. Pas de montant, de nom de dépôt audité ni de nom de machine réels.
- **Icône Mac** : pour l'instant, l'icône iPhone redimensionnée. À redessiner au format Mac.

## Compiler

```bash
xcodegen generate
xcodebuild -project Egide.xcodeproj -scheme EgideMac -derivedDataPath /tmp/egide-build build
```

Sur un dossier synchronisé (Bureau dans iCloud), la signature échoue si les produits sont rangés dans le dossier du projet : d'où le `-derivedDataPath` hors du dépôt.
