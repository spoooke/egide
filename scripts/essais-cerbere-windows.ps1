# Essais de Cerbère sur Windows : compile Tests/Windows avec le moteur (Shared, Commun, Windows) et la fabrique de
# programmes Windows des essais du Mac, puis les lance. Tout est fabriqué sur place ; rien n'est téléchargé.
# Usage : powershell -ExecutionPolicy Bypass -File scripts\essais-cerbere-windows.ps1
$ErrorActionPreference = 'Stop'
$racine = Split-Path -Parent $PSScriptRoot
$kit = Join-Path $racine 'Modules\CerbereKit'
$sources = @(Get-ChildItem (Join-Path $kit 'Sources\Shared'), (Join-Path $kit 'Sources\Commun'), (Join-Path $kit 'Sources\Windows'), (Join-Path $kit 'Tests\Windows') -Filter *.swift) +
           @(Get-Item (Join-Path $kit 'Tests\FabriqueWindows.swift'))
$sortie = Join-Path $env:TEMP 'cerbere-essais'
New-Item -ItemType Directory -Force $sortie | Out-Null
$exe = Join-Path $sortie 'essais.exe'
& swiftc -Onone -swift-version 5 -module-name essais -o $exe @($sources.FullName)
if ($LASTEXITCODE -ne 0) { throw "échec de la compilation des essais" }
& $exe
exit $LASTEXITCODE
