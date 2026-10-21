#!/bin/zsh
# Recopie Pactole, Héphaïstos, Cerbère et Iris dans leurs dépôts à part (vitrines), à côté d'EGIDE.
# Égide reste la source : on modifie ici, puis on relance ce script et on commite dans chaque dépôt.
#   scripts/exporter-vitrines.sh [pactole|hephaistos|cerbere|iris]…   (sans argument : les quatre)
# Le README et l'historique de chaque dépôt ne sont jamais touchés ; les onglets iPhone restent dans Égide.
set -euo pipefail
cd "$(dirname "$0")/.."
EGIDE=$PWD
RACINE=${VITRINES:-$EGIDE/..}

copier() { # copier <dépôt> <chemin>…
  local depot=$1; shift
  for chemin in "$@"; do
    mkdir -p "$depot/$(dirname "$chemin")"
    rsync -a --delete --exclude .DS_Store "$EGIDE/$chemin" "$depot/$(dirname "$chemin")/"
  done
}

installeur() { # installeur <dépôt> <script d'Égide> <nom du projet>
  sed "s/Egide\.xcodeproj/$3.xcodeproj/" "$EGIDE/scripts/$2" > "$1/scripts/$2"
  chmod +x "$1/scripts/$2"
}

entete() { # entete <nom> : début commun des project.yml (signature locale, sans équipe Apple)
  cat <<YML
name: $1
options:
  bundleIdPrefix: com.spoooke
  deploymentTarget:
    iOS: "26.0"
    macOS: "26.0"
  createIntermediateGroups: true
  developmentLanguage: fr
settings:
  base:
    SWIFT_VERSION: "6.0"
    MARKETING_VERSION: "0.1.0"
    CURRENT_PROJECT_VERSION: "1"
    CODE_SIGN_STYLE: Manual
    CODE_SIGN_IDENTITY: "-"

targets:
  EgideUI:
    type: framework
    platform: auto
    supportedDestinations: [iOS, macOS]
    sources: [Modules/EgideUI/Sources]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.spoooke.egide.EgideUI
        GENERATE_INFOPLIST_FILE: YES
        SKIP_INSTALL: YES
YML
}

gitignore() {
  [[ -f $1/.gitignore ]] || printf '.DS_Store\nxcuserdata/\nDerivedData/\nbuild/\n*.xcodeproj/\n' > "$1/.gitignore"
}

pactole() {
  local d=$RACINE/Pactole
  # Anciens noms (avant le 19/10/2026) : MoneyKit et MoneyMac sont devenus PactoleKit et PactoleMac.
  rm -rf "$d/Modules/MoneyKit" "$d/MoneyMac"
  copier "$d" Modules/EgideUI/Sources Modules/PactoleKit/Sources Modules/PactoleKit/Tests PactoleMac
  mkdir -p "$d/scripts"
  cp scripts/make-money-icon.swift "$d/scripts/"
  installeur "$d" install-money-mac.sh Pactole
  gitignore "$d"
  { entete Pactole; cat <<'YML'
  PactoleKit:
    type: framework
    platform: auto
    supportedDestinations: [iOS, macOS]
    sources: [Modules/PactoleKit/Sources]
    dependencies:
      - target: EgideUI
        embed: false
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.spoooke.egide.PactoleKit
        GENERATE_INFOPLIST_FILE: YES
        SKIP_INSTALL: YES
  PactoleKitTests:
    type: bundle.unit-test
    platform: macOS
    sources: [Modules/PactoleKit/Tests]
    dependencies: [{ target: PactoleKit }]
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
  PactoleMac:
    type: application
    platform: macOS
    sources:
      - path: PactoleMac
        excludes: ["Resources/money-icon.svg"]
    dependencies:
      - target: PactoleKit
      - target: EgideUI
    info:
      path: PactoleMac/Info.plist
      properties:
        CFBundleLocalizations: [fr]
        LSApplicationCategoryType: public.app-category.finance
        CFBundleDocumentTypes:
          - CFBundleTypeName: Reçu
            CFBundleTypeRole: Viewer
            LSHandlerRank: Alternate
            LSItemContentTypes: [com.adobe.pdf, public.image, public.plain-text, public.html, com.apple.mail.email]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.spoooke.money
        PRODUCT_NAME: Pactole
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_CFBundleDisplayName: Pactole
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        ENABLE_HARDENED_RUNTIME: NO

schemes:
  PactoleMac:
    build:
      targets:
        PactoleMac: all
    test:
      targets: [PactoleKitTests]
YML
  } > "$d/project.yml"
}

hephaistos() {
  local d=$RACINE/Hephaistos
  copier "$d" Modules/EgideUI/Sources Modules/HephaistosKit/Sources/Shared Modules/HephaistosKit/Sources/macOS \
    Modules/HephaistosKit/Tests HephaistosMac
  mkdir -p "$d/scripts"
  cp scripts/make-hephaistos-icon.swift "$d/scripts/"
  installeur "$d" install-hephaistos-mac.sh Hephaistos
  gitignore "$d"
  { entete Hephaistos; cat <<'YML'
  HephaistosKit:
    type: framework
    platform: macOS
    sources:
      - Modules/HephaistosKit/Sources/Shared
      - Modules/HephaistosKit/Sources/macOS
    dependencies:
      - target: EgideUI
        embed: false
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.spoooke.egide.HephaistosKit
        GENERATE_INFOPLIST_FILE: YES
        SKIP_INSTALL: YES
  HephaistosKitTests:
    type: bundle.unit-test
    platform: macOS
    sources: [Modules/HephaistosKit/Tests]
    dependencies: [{ target: HephaistosKit }]
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
  HephaistosMac:
    type: application
    platform: macOS
    sources:
      - path: HephaistosMac
        excludes: ["Resources/hephaistos-icon.svg"]
    dependencies:
      - target: HephaistosKit
      - target: EgideUI
    info:
      path: HephaistosMac/Info.plist
      properties:
        CFBundleLocalizations: [fr]
        LSApplicationCategoryType: public.app-category.utilities
        LSUIElement: true
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.spoooke.hephaistos
        PRODUCT_NAME: Hephaistos
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_CFBundleDisplayName: Héphaïstos
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        ENABLE_HARDENED_RUNTIME: NO

schemes:
  HephaistosMac:
    build:
      targets:
        HephaistosMac: all
    test:
      targets: [HephaistosKitTests]
YML
  } > "$d/project.yml"
}

cerbere() {
  local d=$RACINE/Cerbere
  copier "$d" Modules/EgideUI/Sources Modules/CerbereKit/Sources/Shared Modules/CerbereKit/Sources/Interface \
    Modules/CerbereKit/Sources/macOS Modules/CerbereKit/Tests CerbereCLI CerbereMac
  mkdir -p "$d/scripts"
  cp scripts/make-cerbere-icon.swift "$d/scripts/"
  installeur "$d" install-cerbere.sh Cerbere
  installeur "$d" install-cerbere-mac.sh Cerbere
  gitignore "$d"
  { entete Cerbere; cat <<'YML'
  CerbereKit:
    type: framework
    platform: macOS
    sources:
      - Modules/CerbereKit/Sources/Shared
      - Modules/CerbereKit/Sources/Interface
      - Modules/CerbereKit/Sources/macOS
    dependencies:
      - target: EgideUI
        embed: false
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.spoooke.egide.CerbereKit
        GENERATE_INFOPLIST_FILE: YES
        SKIP_INSTALL: YES
  CerbereKitTests:
    type: bundle.unit-test
    platform: macOS
    sources: [Modules/CerbereKit/Tests]
    dependencies: [{ target: CerbereKit }]
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
  cerbere:
    type: tool
    platform: macOS
    sources: [CerbereCLI, Modules/CerbereKit/Sources/Shared, Modules/CerbereKit/Sources/macOS]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.spoooke.cerbere.cli
        ENABLE_HARDENED_RUNTIME: NO
  CerbereMac:
    type: application
    platform: macOS
    sources:
      - path: CerbereMac
        excludes: ["Resources/cerbere-icon.svg"]
    dependencies:
      - target: CerbereKit
      - target: EgideUI
    info:
      path: CerbereMac/Info.plist
      properties:
        CFBundleLocalizations: [fr]
        LSApplicationCategoryType: public.app-category.developer-tools
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.spoooke.cerbere
        PRODUCT_NAME: Cerbere
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_CFBundleDisplayName: Cerbère
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        ENABLE_HARDENED_RUNTIME: NO

schemes:
  Cerbere:
    build:
      targets:
        cerbere: all
    test:
      targets: [CerbereKitTests]
  CerbereMac:
    build:
      targets:
        CerbereMac: all
YML
  } > "$d/project.yml"
}

iris() {
  local d=$RACINE/Iris
  copier "$d" Modules/EgideUI/Sources Modules/IrisKit/Sources Modules/IrisKit/Tests Modules/IrisKit/iris-icon.svg
  gitignore "$d"
  { entete Iris; cat <<'YML'
  IrisKit:
    type: framework
    platform: iOS
    sources: [Modules/IrisKit/Sources]
    dependencies:
      - target: EgideUI
        embed: false
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.spoooke.egide.IrisKit
        GENERATE_INFOPLIST_FILE: YES
        SKIP_INSTALL: YES
  IrisKitTests:
    type: bundle.unit-test
    platform: iOS
    sources: [Modules/IrisKit/Tests]
    dependencies: [{ target: IrisKit }]
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES

schemes:
  Iris:
    build:
      targets:
        IrisKit: all
    test:
      targets: [IrisKitTests]
YML
  } > "$d/project.yml"
}

vitrines=($@)
(( $# )) || vitrines=(pactole hephaistos cerbere iris)
for vitrine in $vitrines; do
  $vitrine
  echo "$vitrine exporté"
done
