# One-time installer for Windows: clones/updates eas-local-builder to a
# fixed location and registers a `ssheas` function in your PowerShell
# profile, so you can run `ssheas build ...` from any directory instead
# of typing the full path to ssheas.ps1 every time.
#
# Usage (run once, from any PowerShell prompt):
#   git clone https://github.com/DEXA-IT-Solutions-Pvt-LTD/eas-local-builder.git
#   cd eas-local-builder
#   .\install.ps1
#
# Safe to re-run later to pick up updates (git pull) — it won't duplicate
# the profile entry.

$ErrorActionPreference = "Stop"

$RepoUrl = "https://github.com/DEXA-IT-Solutions-Pvt-LTD/eas-local-builder.git"
$InstallDir = Join-Path $env:LOCALAPPDATA "eas-local-builder"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Error "git is required. Install Git for Windows: https://git-scm.com/download/win"
    exit 1
}

# If this script is already being run from inside a real clone (not a
# stray copy), install in place instead of re-cloning to LOCALAPPDATA.
if (Test-Path (Join-Path $ScriptDir ".git")) {
    $InstallDir = $ScriptDir
    Write-Host "==> Running from an existing clone at $InstallDir -- installing in place"
} elseif (Test-Path (Join-Path $InstallDir ".git")) {
    Write-Host "==> Updating existing install at $InstallDir"
    Push-Location $InstallDir
    git pull --ff-only
    Pop-Location
} else {
    Write-Host "==> Cloning to $InstallDir"
    git clone $RepoUrl $InstallDir
}

$ScriptPath = Join-Path $InstallDir "ssheas.ps1"
if (-not (Test-Path $ScriptPath)) {
    Write-Error "ssheas.ps1 not found at $ScriptPath -- something's wrong with the clone."
    exit 1
}

# --- Register a `ssheas` function in the PowerShell profile ---
if (-not (Test-Path $PROFILE)) {
    New-Item -ItemType File -Path $PROFILE -Force | Out-Null
}

$MarkerStart = "# >>> ssheas (eas-local-builder) >>>"
$MarkerEnd = "# <<< ssheas (eas-local-builder) <<<"
$FunctionBlock = @"
$MarkerStart
function ssheas { & '$ScriptPath' @args }
$MarkerEnd
"@

$existing = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
if ($existing -and $existing.Contains($MarkerStart)) {
    Write-Host "==> Profile already has a ssheas function -- leaving it as-is."
    Write-Host "    (If the install path changed, edit $PROFILE manually.)"
} else {
    Add-Content -Path $PROFILE -Value "`n$FunctionBlock"
    Write-Host "==> Added 'ssheas' function to your PowerShell profile: $PROFILE"
}

# --- .env scaffold ---
$EnvFile = Join-Path $InstallDir ".env"
$EnvExample = Join-Path $InstallDir ".env.example"
if (-not (Test-Path $EnvFile) -and (Test-Path $EnvExample)) {
    Copy-Item $EnvExample $EnvFile
    Write-Host "==> Created $EnvFile from .env.example"
    Write-Host "    Fill in EXPO_TOKEN / SSHEAS_REMOTE_HOST / SSHEAS_REMOTE_KEY before first use."
}

Write-Host ""
Write-Host "==> Done. This only takes effect in NEW PowerShell windows."
Write-Host "    Either open a new PowerShell window, or run: . `$PROFILE"
Write-Host "    Then, from inside any Expo project directory:"
Write-Host "        ssheas build --platform android --profile preview"
Write-Host ""
Write-Host "    Note: if you use both Windows PowerShell and PowerShell 7, each has"
Write-Host "    its own profile -- re-run this script from whichever one you'll use."
