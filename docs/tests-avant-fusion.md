# Tests avant de fusionner la refonte

Branche `refonte/egide-mac`. On coche au fil des jours, sur les vraies machines. Quand tout est coché, la branche est fusionnée dans `main`, puis `scripts/publier.sh` prépare la version publique.

Égide Mac est déjà installé depuis cette branche (`~/Applications/Égide.app`). Pour l'iPhone, il faut d'abord y installer Égide depuis la branche : c'est l'étape 1 de la partie iPhone.

## Sur le Mac

**Démarrage**
- [ ] Après un redémarrage du Mac, Égide se lance seul, sans fenêtre, avec le bouclier dans la barre des menus.
- [ ] Le menu du bouclier affiche la température et la semaine de Pactole ; ses boutons ouvrent le bon onglet.
- [ ] Pactole et Héphaïstos ne se relancent pas d'eux-mêmes.

**Pactole**
- [ ] Une dépense saisie sur l'iPhone apparaît sur le Mac (la synchro reprise de l'ancienne app marche).
- [ ] Une dépense saisie sur le Mac apparaît sur l'iPhone.
- [ ] Un reçu PDF glissé sur la fenêtre ouvre la saisie pré-remplie.
- [ ] « Ajouter un relevé… » lit le relevé du mois et propose le rapprochement.
- [ ] Les écrans secondaires (Semaines, Bilan du mois, Réglages…) s'ouvrent et le bouton Retour ramène à Pactole.

**Héphaïstos**
- [ ] « Essayer l'alerte » envoie une notification.
- [ ] Sur l'iPhone, l'onglet Héphaïstos montre une température récente : c'est maintenant Égide qui l'envoie au serveur Argos.

**Muse**
- [ ] Dans Muse › Synchro, choisir le dossier iCloud Drive des idées : les idées de l'iPhone arrivent sur le Mac.
- [ ] Une idée créée sur le Mac arrive sur l'iPhone.
- [ ] Ensuite seulement, retirer Muse de l'ouverture de session et le couper dans Réglages Système › Barre des menus.

**Iris**
- [ ] Choisir le dossier où l'iPhone copie les scans : ils apparaissent, rangés par genre.
- [ ] Un clic ouvre le Coup d'œil, un double-clic ouvre le PDF.

**Cerbère**
- [ ] Un audit lancé depuis un lien GitHub va au bout et rejoint l'historique.
- [ ] « Travail en cours » (⌘J) affiche le journal.
- [ ] L'accueil montre les derniers audits.

**Argos**
- [ ] La liste des machines est à jour ; une fiche s'ouvre et le bouton Retour ramène à la liste.
- [ ] Réseau local et Historique s'ouvrent.
- [ ] Le scan du réseau continue alors que l'icône d'Argos est masquée (la date du dernier scan avance).

**Hermès**
- [ ] L'onglet affiche l'agent en marche et l'iPhone autorisé.
- [ ] « Ouvrir le panneau d'Hermès » ouvre le panneau de l'agent.

**Mode démo**
- [ ] `open ~/Applications/Égide.app --args -egide.demo YES` : rien de personnel à l'écran, et en relançant normalement, les vraies données sont intactes.

## Sur l'iPhone

1. [ ] Installer Égide depuis la branche (Xcode ou iphone-refresh).
2. [ ] Le nouvel accueil s'affiche : date, bande d'outils, cartes ; chaque carte ouvre son outil.
3. [ ] Argos : Face ID, liste des machines, fiche d'une machine (les dates s'affichent : leur lecture a changé avec Swift 6).
4. [ ] Hermès : connexion au Mac, vidéo et gestes, en local puis par Tailscale. La mise en route de la connexion a changé : à tester plusieurs fois, y compris Mac éteint (le message d'erreur doit arriver).
5. [ ] Pactole : saisie, Raccourci Apple Pay, lecture d'un reçu.
6. [ ] Muse, Iris, Cerbère, Héphaïstos : chaque onglet s'ouvre et affiche ses données.

## Après les tests

- Ce qui ne marche pas : le noter ici, on corrige sur la branche, on reteste la ligne.
- Tout est coché : fusion de `refonte/egide-mac` dans `main`, puis `scripts/publier.sh 0.2`, puis `git push` sur egide-dev et sur egide.
