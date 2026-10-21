#!/bin/zsh
# Ajoute un module (un onglet) à Égide en une commande :
#   scripts/new-module.sh <Nom> "<Titre affiché>" <symbole SF> [version Swift, 6.0 par défaut]
#   ex. scripts/new-module.sh Agenda "Agenda" calendar
# Crée Modules/<Nom>Kit (sources + tests), l'ajoute à project.yml et à Egide/App/Module.swift,
# puis régénère le projet. Il reste à écrire le contenu de l'onglet dans <Nom>RootView.
set -euo pipefail
cd "$(dirname "$0")/.."

[[ $# -ge 3 ]] || { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
name=$1 title=$2 symbol=$3 swift=${4:-6.0}
[[ $name =~ ^[A-Z][A-Za-z0-9]*$ ]] || { echo "Nom invalide : lettres sans accent, majuscule au début (ex. Agenda)."; exit 1; }
id=${(L)name[1]}${name[2,-1]}   # identifiant du cas Swift et des liens egide://<id>
kit=${name}Kit
[[ ! -e Modules/$kit ]] || { echo "Modules/$kit existe déjà."; exit 1; }

mkdir -p Modules/$kit/Sources Modules/$kit/Tests
# Bouton « Précédent » : identique dans tous les modules.
cp Modules/CerbereKit/Sources/iOS/HomeButton.swift Modules/$kit/Sources/

cat > Modules/$kit/Sources/$kit.swift <<EOF
import SwiftUI

/// Onglet $title d'Égide.
public enum $kit {
    public static let title = "$title"
    public static let systemImage = "$symbol"
}

/// Écran ouvert par un lien egide://$id/…
public enum ${name}Route: Equatable {
    case home

    public init(path: [String]) {
        self = .home
    }
}

/// Écran racine de l'onglet. \`path\` : chemin du dernier lien egide://$id/… reçu ;
/// \`request\` change à chaque lien, même identique au précédent.
public struct ${name}RootView: View {
    private let path: [String]
    private let request: Int
    private let onHome: (@MainActor @Sendable () -> Void)?

    /// \`onHome\` : bouton « Précédent » vers l'accueil d'Égide.
    public init(path: [String] = [], request: Int = 0, onHome: (@MainActor @Sendable () -> Void)? = nil) {
        self.path = path
        self.request = request
        self.onHome = onHome
    }

    public var body: some View {
        NavigationStack {
            ContentUnavailableView($kit.title, systemImage: $kit.systemImage,
                                   description: Text("Contenu de l'onglet à écrire."))
                .navigationTitle($kit.title)
                .toolbar { HomeToolbarItem(action: onHome) }
        }
    }
}

// Services pour l'app : résumé de l'Accueil, sauvegarde globale.
extension $kit {
    /// Une ligne sous la tuile de l'Accueil (nil : rien à afficher).
    @MainActor
    public static func summary() async -> String? { nil }

    /// Données du module pour la sauvegarde globale (nil : rien à sauvegarder). Jamais de secret.
    @MainActor
    public static func backup() throws -> Data? { nil }

    /// Restaure les données de backup() ; renvoie un compte rendu court.
    @MainActor
    public static func restore(_ data: Data) throws -> String { "rien à restaurer" }
}
EOF

cat > Modules/$kit/Tests/${kit}Tests.swift <<EOF
import Testing
@testable import $kit

struct ${kit}Tests {
    @Test func routes() {
        #expect(${name}Route(path: []) == .home)
    }
}
EOF

python3 - "$name" "$id" "$kit" "$swift" <<'PY'
import re, sys
name, ident, kit, swift = sys.argv[1:]

# project.yml : dépendance de l'app, cibles du module, tests dans le schéma.
p = 'project.yml'; s = open(p).read()
deps = re.findall(r'^      - target: \w+Kit\n', s, re.M)
last_dep = deps[-1]
s = s.replace(last_dep, last_dep + f'      - target: {kit}\n', 1)
version = '' if swift == '6.0' else f'''
    settings:
      base:
        SWIFT_VERSION: "{swift}"'''
targets = f'''  {kit}:
    templates: [Kit]{version}
  {kit}Tests:
    templates: [KitTests]
    sources: [Modules/{kit}/Tests]
    dependencies: [{{ target: {kit} }}]{version}

schemes:'''
s = s.replace('\nschemes:', '\n' + targets, 1)
s = re.sub(r'(test:\n\s+targets: \[)([^\]]*)\]', lambda m: f'{m.group(1)}{m.group(2)}, {kit}Tests]', s, count=1)
open(p, 'w').write(s)

# Egide/App/Module.swift : import, cas de l'énumération, une ligne par switch (copiée du dernier module).
p = 'Egide/App/Module.swift'; s = open(p).read()
imports = re.findall(r'^import \w+Kit\n', s, re.M)
s = s.replace(imports[-1], imports[-1] + f'import {kit}\n', 1)
m = re.search(r'^(    case )([\w, ]+)$', s, re.M)
cases = [c.strip() for c in m.group(2).split(',')]
last = cases[-1]
s = s[:m.start()] + m.group(1) + ', '.join(cases + [ident]) + s[m.end():]
last_kit = re.search(rf'case \.{last}: (\w+)Kit\.title', s).group(1)
lines = []
for line in s.split('\n'):
    lines.append(line)
    if re.match(rf'\s+case \.{last}: ', line):
        lines.append(line.replace(f'.{last}:', f'.{ident}:').replace(last_kit, name))
open(p, 'w').write('\n'.join(lines))
PY

xcodegen generate --quiet
echo "Module $title ajouté : Modules/$kit, onglet egide://$id."
echo "À faire : le contenu de ${name}RootView, puis xcodebuild test et scripts/register-iphone-refresh.sh."
