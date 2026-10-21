<#
Installe l'agent Argos sur un PC Windows (avec Tailscale), ou le met à jour, ou le retire.
Dans PowerShell ouvert en administrateur :
  powershell -ExecutionPolicy Bypass -File .\install.ps1              installation (questionnaire)
  powershell -ExecutionPolicy Bypass -File .\install.ps1 -Update      nouvelle version de l'agent (elle arrive aussi toute seule)
  powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall   retire l'agent et sa tâche de démarrage
L'agent est téléchargé depuis le serveur Argos du Mac, via Tailscale, avec le jeton des agents
(menu ♥ du Mac > « Copier le jeton des agents ») ; son empreinte SHA-256 est vérifiée.
Aucun secret dans ce script : le jeton est demandé à l'installation et rangé dans C:\ProgramData\Heartbit
(lisible par SYSTEM et les administrateurs seulement).
#>
[CmdletBinding()]
param([switch]$Update, [switch]$Uninstall)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue' # téléchargement bien plus rapide sans barre de progression

$Dir = 'C:\ProgramData\Heartbit'
$Exe = Join-Path $Dir 'heartbit-agent.exe'
$TokenFile = Join-Path $Dir 'agent-token'
$State = Join-Path $Dir 'install.json'
$TaskName = 'Heartbit Agent'
$Tailscale = 'C:\Program Files\Tailscale\tailscale.exe'
$Arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }

function Step($Text) { Write-Host "`n→ $Text" -ForegroundColor Cyan }
function Info($Text) { Write-Host "  $Text" }
function Fail($Text) { Write-Host "`n✗ $Text" -ForegroundColor Red; exit 1 }
function Ask-Yes($Question, $Default = 'o') {
    $answer = Read-Host "  $Question [$Default]"
    if (-not $answer) { $answer = $Default }
    return $answer -match '^[oOyY]'
}

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail "Ouvre PowerShell en administrateur (clic droit > Exécuter en tant qu'administrateur), puis relance le script."
}

function Invoke-Quiet([scriptblock]$Command) {
    # Commande externe dont les erreurs sont attendues (tâche absente…) : PowerShell 5.1 en ferait
    # une exception avec ErrorActionPreference = Stop. $LASTEXITCODE reste disponible après l'appel.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Command 2>$null | Out-Null } finally { $ErrorActionPreference = $previous }
}

function Protect-Folder {
    # Héritage coupé : SYSTEM et Administrateurs seulement (SID, valables quelle que soit la langue de Windows).
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    icacls $Dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
}

function Stop-Agent {
    Invoke-Quiet { schtasks /End /TN $TaskName }
    Get-Process heartbit-agent -ErrorAction SilentlyContinue | Stop-Process -Force
}

function Install-Agent($Server) {
    # Télécharge l'agent, vérifie son empreinte SHA-256 annoncée par le serveur, puis le met en place.
    $tmp = Join-Path $Dir 'heartbit-agent.download'
    $token = (Get-Content $TokenFile -Raw).Trim()
    try {
        $response = Invoke-WebRequest -UseBasicParsing -PassThru -OutFile $tmp `
            -Uri "$Server/api/agent/download?os=windows&arch=$Arch" -Headers @{ Authorization = "Bearer $token" }
    } catch {
        Remove-Item $tmp -ErrorAction SilentlyContinue
        Fail "Téléchargement impossible : serveur injoignable ou jeton refusé ($($_.Exception.Message))."
    }
    $want = [string]($response.Headers['X-Agent-Sha256'] | Select-Object -First 1)
    $got = (Get-FileHash $tmp -Algorithm SHA256).Hash.ToLower()
    if (-not $want) {
        Remove-Item $tmp
        Fail "Le serveur n'a pas donné l'empreinte de l'agent : mets Argos à jour sur le Mac (install-mac.sh --update)."
    }
    if ($got -ne $want.ToLower()) {
        Remove-Item $tmp
        Fail "Empreinte SHA-256 incorrecte ($($got.Substring(0,12))… au lieu de $($want.Substring(0,12))…) : fichier rejeté."
    }
    Stop-Agent
    Move-Item -Force $tmp $Exe
    Info "Agent vérifié (SHA-256 $($got.Substring(0,12))…) et installé : $Exe"
}

function Register-Agent($Server) {
    # Même tâche que celle décrite dans le README d'Argos : au démarrage, en SYSTEM.
    schtasks /Create /TN $TaskName /SC ONSTART /RU SYSTEM /RL HIGHEST /F `
        /TR "$Exe -server $Server -token-file $TokenFile -watch" | Out-Null
    schtasks /Run /TN $TaskName | Out-Null
}

function Show-AndroidNotes($Server) {
    Step 'Android'
    Info 'Hermès, Muse et Money n''existent que sur iPhone. Sur Android :'
    Info '1. Installe Tailscale et connecte-toi au même compte.'
    Info "2. Dashboard Argos : Chrome > $Server > ⋮ > « Installer l'application », puis colle le jeton (menu ♥ du Mac > « Copier le jeton »)."
    Info '3. Alertes : installe ntfy et abonne-toi au sujet affiché dans Argos > Alertes.'
}

function Install-All {
    Write-Host 'Égide — installation sur ce PC Windows' -ForegroundColor White
    Step 'Questionnaire'
    Info "Ordinateur : Windows $([Environment]::OSVersion.Version) ($Arch), « $env:COMPUTERNAME »"
    $phone = if (Ask-Yes 'Ton téléphone est-il un iPhone ? (sinon Android)') { 'iphone' } else { 'android' }
    Info 'Sur un PC, seul l''agent Argos est disponible (Hermès, Muse et Money sont pour Mac et iPhone).'
    if (-not (Ask-Yes 'Installer l''agent Argos (surveillance de la sécurité de ce PC) ?')) { exit 0 }

    Step 'Tailscale'
    if (-not (Test-Path $Tailscale)) {
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Fail 'winget introuvable : installe « App Installer » depuis le Microsoft Store.' }
        Info 'Installation de Tailscale (winget)'
        winget install --id Tailscale.Tailscale --exact --silent --accept-source-agreements --accept-package-agreements | Out-Null
    }
    Invoke-Quiet { & $Tailscale status }
    if ($LASTEXITCODE -ne 0) {
        Info 'Connecte-toi à Tailscale (icône près de l''horloge) avec le même compte que le Mac.'
        Read-Host '  Appuie sur Entrée quand c''est fait' | Out-Null
    }
    Info 'Tailscale : connecté'

    Step 'Agent Argos'
    $server = (Read-Host '  Adresse du dashboard Argos (ex. https://mon-mac.tailnet.ts.net)').TrimEnd('/')
    if ($server -notmatch '^https://') { Fail 'Adresse https:// attendue (Tailscale).' }
    $secure = Read-Host '  Jeton des agents (menu ♥ du Mac > « Copier le jeton des agents »)' -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr).Trim() }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if (-not $token) { Fail 'Jeton vide.' }

    Protect-Folder
    [IO.File]::WriteAllText($TokenFile, $token)
    Remove-Variable token
    @{ server = $server; phone = $phone } | ConvertTo-Json | Set-Content $State
    Install-Agent $server
    Register-Agent $server
    Info 'Tâche « Heartbit Agent » active : ce PC apparaît dans Argos d''ici une minute.'
    if ($phone -eq 'android') { Show-AndroidNotes $server }
    Write-Host "`n✅ Installation terminée. Les mises à jour de l'agent arrivent toutes seules." -ForegroundColor Green
}

function Update-Agent {
    if (-not (Test-Path $State)) { Fail 'Rien d''installé par ce script : lance-le sans option.' }
    $config = Get-Content $State -Raw | ConvertFrom-Json
    Step 'Mise à jour de l''agent'
    Install-Agent $config.server
    Register-Agent $config.server
    Write-Host "`n✅ Agent à jour." -ForegroundColor Green
}

function Uninstall-Agent {
    Step 'Désinstallation'
    if (-not (Ask-Yes 'Retirer l''agent Argos de ce PC ? (Tailscale reste installé)' 'n')) { exit 0 }
    Stop-Agent
    Invoke-Quiet { schtasks /Delete /TN $TaskName /F }
    Remove-Item -Recurse -Force $Dir -ErrorAction SilentlyContinue
    Write-Host "`n✅ Agent retiré. Supprime ce PC dans le dashboard Argos si tu ne le surveilles plus." -ForegroundColor Green
}

if ($Uninstall) { Uninstall-Agent } elseif ($Update) { Update-Agent } else { Install-All }
