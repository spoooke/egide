# Compile cerbere.exe, l'outil en ligne de commande de Cerbère pour Windows, avec Swift pour Windows.
# Mêmes sources que l'outil du Mac (CerbereCLI + CerbereKit), sauf la partie propre au Mac :
#   Sources/Shared + Sources/Commun + Sources/Windows.
# Usage : powershell -ExecutionPolicy Bypass -File scripts\build-cerbere-windows.ps1 [-Sortie <dossier>] [-Debug]
param(
    [string]$Sortie = (Join-Path $env:LOCALAPPDATA 'Cerbere\bin'),
    [switch]$Debug
)
$ErrorActionPreference = 'Stop'

$racine = Split-Path -Parent $PSScriptRoot
$kit = Join-Path $racine 'Modules\CerbereKit\Sources'
$sources = @(Get-ChildItem (Join-Path $racine 'CerbereCLI') -Filter *.swift) +
           @(Get-ChildItem (Join-Path $kit 'Shared'), (Join-Path $kit 'Commun'), (Join-Path $kit 'Windows') -Filter *.swift)

$swiftc = Get-Command swiftc -ErrorAction SilentlyContinue
if (-not $swiftc) { throw "swiftc introuvable : installer Swift pour Windows (swift.org), puis rouvrir le terminal." }

New-Item -ItemType Directory -Force $Sortie | Out-Null
$exe = Join-Path $Sortie 'cerbere.exe'
[string[]]$optim = if ($Debug) { '-Onone', '-g' } else { '-O' }
Write-Host "Compilation de $($sources.Count) fichiers vers $exe..."
& $swiftc.Source @optim -swift-version 6 -module-name cerbere -o $exe @($sources.FullName)
if ($LASTEXITCODE -ne 0) { throw "échec de la compilation" }
# L'éditeur de liens laisse une bibliothèque d'import inutile pour un programme.
Remove-Item (Join-Path $Sortie 'cerbere.lib'), (Join-Path $Sortie 'cerbere.exp') -ErrorAction SilentlyContinue
Write-Host "cerbere.exe prêt : $exe"
