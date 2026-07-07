# Windows PowerShell counterpart to `ssheas` (bash). Same flags, same
# behavior: tars the project, streams it to a throwaway dir on the Linux
# build server over SSH, triggers the build there, copies the artifact (and
# log) back, then deletes the remote copy.
# Name: ssh + self-hosted + eas.
#
# Only --remote mode is supported here — building locally would require
# Docker + the Android SDK on Windows itself, which defeats the point.
#
# Requires: tar.exe and OpenSSH client (ssh.exe/scp.exe), both bundled with
# Windows 10 (1803+) / Windows 11 by default. If missing: Settings > Apps >
# Optional Features > Add "OpenSSH Client".
#
# Usage:
#   $env:EXPO_TOKEN = "<token>"
#   .\ssheas.ps1 build --platform android --profile preview `
#     --remote ubuntu@your-server-host `
#     --key C:\keys\admini-build-server.pem
#
# Tip: run from inside the mobile app project directory, same as real
# `eas build` — or pass --project-dir explicitly.
#
# Tip: create a .env file next to this script to avoid retyping
# --remote/--key/--remote-dir every time:
#   EXPO_TOKEN=<token>
#   SSHEAS_REMOTE_HOST=ubuntu@your-server-host
#   SSHEAS_REMOTE_KEY=C:\keys\admini-build-server.pem
# Then just: .\ssheas.ps1 build --platform android --profile preview
#
# Tip: run install.ps1 once to register a `ssheas` command so you don't
# need the full path at all.

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$EnvFile = Join-Path $ScriptDir ".env"
$ProjectDir = (Get-Location).Path
$Platform = "android"
$Profile_ = "preview"
$RemoteHost = ""
$RemoteKey = ""
$RemoteDir = "eas-local-builder"
$OutDir = ".\ssheas-output"

function Show-Usage {
    Write-Host @"
Usage: ssheas build --platform <android|ios> --remote <user@host> --key <path> [options]
       ssheas config <list|get|set|remove> [args]

  --platform     android (ios needs macOS/Xcode -- not supported here)
  --profile      eas.json build profile to use (default: preview)
  --project-dir  path to the Expo project (default: current directory)
  --remote       ssh target, e.g. ubuntu@your-server-host
  --key          path to SSH identity file (.pem)
  --remote-dir   path to eas-local-builder on the server (default: eas-local-builder)
  --out          local dir to copy the artifact into (default: .\ssheas-output)

Example:
  `$env:EXPO_TOKEN = "..."
  ssheas build --platform android --profile preview ``
    --remote ubuntu@your-server-host --key C:\keys\admini-build-server.pem

Config (manage .env next to this script, so you don't retype flags every run):
  ssheas config list
  ssheas config get EXPO_TOKEN
  ssheas config set EXPO_TOKEN <value>
  ssheas config set SSHEAS_REMOTE_HOST ubuntu@your-server-host
  ssheas config set SSHEAS_REMOTE_KEY C:\keys\admini-build-server.pem
  ssheas config remove EXPO_TOKEN
"@
    exit 1
}

function Mask-Value {
    param([string]$Value)
    if ($Value.Length -le 8) { return "********" }
    return "$($Value.Substring(0,4))...$($Value.Substring($Value.Length - 4))"
}

function Read-EnvLines {
    if (-not (Test-Path $EnvFile)) { return @() }
    return Get-Content $EnvFile | Where-Object { $_ -match '^[^#=]+=' }
}

function Config-List {
    $lines = Read-EnvLines
    if ($lines.Count -eq 0) {
        Write-Host "No .env file yet at $EnvFile (use: ssheas config set KEY VALUE)"
        return
    }
    Write-Host "Config in ${EnvFile}:"
    foreach ($line in $lines) {
        $key, $value = $line -split '=', 2
        if ($key -match 'TOKEN|SECRET|PASSWORD') {
            Write-Host "  $key=$(Mask-Value $value)"
        } else {
            Write-Host "  $key=$value"
        }
    }
}

function Config-Get {
    param([string]$Key)
    if (-not $Key) { Write-Error "Usage: ssheas config get KEY"; exit 1 }
    $line = Read-EnvLines | Where-Object { $_ -match "^$([regex]::Escape($Key))=" } | Select-Object -Last 1
    if (-not $line) { Write-Error "$Key not set in $EnvFile"; exit 1 }
    ($line -split '=', 2)[1]
}

function Config-Set {
    param([string]$Key, [string]$Value)
    if (-not $Key -or -not $Value) { Write-Error "Usage: ssheas config set KEY VALUE"; exit 1 }
    $lines = @(Read-EnvLines)
    $found = $false
    $newLines = @(foreach ($line in $lines) {
        $existingKey = ($line -split '=', 2)[0]
        if ($existingKey -eq $Key) { $found = $true; "$Key=$Value" } else { $line }
    })
    if (-not $found) { $newLines += "$Key=$Value" }
    Set-Content -Path $EnvFile -Value $newLines
    Write-Host "==> Set $Key in $EnvFile"
}

function Config-Remove {
    param([string]$Key)
    if (-not $Key) { Write-Error "Usage: ssheas config remove KEY"; exit 1 }
    $lines = @(Read-EnvLines) | Where-Object { ($_ -split '=', 2)[0] -ne $Key }
    Set-Content -Path $EnvFile -Value $lines
    Write-Host "==> Removed $Key from $EnvFile (if it was set)"
}

if ($args.Count -gt 0 -and $args[0] -eq "config") {
    switch ($args[1]) {
        "list"          { Config-List }
        "get"           { Config-Get $args[2] }
        "set"           { Config-Set $args[2] $args[3] }
        "remove"        { Config-Remove $args[2] }
        "rm"            { Config-Remove $args[2] }
        default         { Show-Usage }
    }
    exit 0
}

if ($args.Count -eq 0 -or $args[0] -ne "build") { Show-Usage }

$i = 1
while ($i -lt $args.Count) {
    switch ($args[$i]) {
        "--platform"    { $Platform = $args[$i + 1]; $i += 2 }
        "--profile"     { $Profile_ = $args[$i + 1]; $i += 2 }
        "--project-dir" { $ProjectDir = $args[$i + 1]; $i += 2 }
        "--remote"      { $RemoteHost = $args[$i + 1]; $i += 2 }
        "--key"         { $RemoteKey = $args[$i + 1]; $i += 2 }
        "--remote-dir"  { $RemoteDir = $args[$i + 1]; $i += 2 }
        "--out"         { $OutDir = $args[$i + 1]; $i += 2 }
        "-h"            { Show-Usage }
        "--help"        { Show-Usage }
        default {
            Write-Error "unknown flag '$($args[$i])'"
            Show-Usage
        }
    }
}

if (-not (Test-Path (Join-Path $ProjectDir "eas.json"))) {
    Write-Error "'$ProjectDir' doesn't look like an Expo project (no eas.json found). Run this from inside your project directory, or pass --project-dir."
    exit 1
}

# Auto-load .env next to this script for anything not already set via env
# var or flag — EXPO_TOKEN, and optionally SSHEAS_REMOTE_HOST /
# SSHEAS_REMOTE_KEY / SSHEAS_REMOTE_DIR so --remote/--key/--remote-dir
# don't need to be typed on every single run.
if (Test-Path $EnvFile) {
    Get-Content $EnvFile | ForEach-Object {
        if ($_ -match '^\s*([^#=][^=]*)=(.*)$') {
            $name = $matches[1].Trim()
            if (-not [System.Environment]::GetEnvironmentVariable($name)) {
                [System.Environment]::SetEnvironmentVariable($name, $matches[2].Trim())
            }
        }
    }
}
if (-not $env:EXPO_TOKEN) {
    Write-Error "EXPO_TOKEN env var is required. Set `$env:EXPO_TOKEN = '...' or create a .env file next to this script."
    exit 1
}

if (-not $RemoteHost) { $RemoteHost = $env:SSHEAS_REMOTE_HOST }
if (-not $RemoteKey) { $RemoteKey = $env:SSHEAS_REMOTE_KEY }
if ($RemoteDir -eq "eas-local-builder" -and $env:SSHEAS_REMOTE_DIR) { $RemoteDir = $env:SSHEAS_REMOTE_DIR }

if (-not $RemoteHost) {
    Write-Error "This Windows script only supports --remote mode. Pass --remote <user@host> --key <path>, or set SSHEAS_REMOTE_HOST/SSHEAS_REMOTE_KEY in .env."
    exit 1
}
if ($Platform -eq "ios") {
    Write-Error "iOS builds require macOS/Xcode -- not possible via this builder."
    exit 1
}

foreach ($tool in @("ssh", "scp", "tar")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Error "'$tool' was not found on PATH. Install the Windows OpenSSH Client (Settings > Optional Features) -- tar.exe ships with Windows 10 1803+ / 11 by default."
        exit 1
    }
}

$SshOpts = @("-o", "ConnectTimeout=10")
if ($RemoteKey) { $SshOpts += @("-i", $RemoteKey) }

$Stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$BuildId = "remote-win-$Stamp-$PID"
$RemoteSrc = "/tmp/eas-local-remote-src/$BuildId"
$RemoteMarker = "/tmp/eas-local-remote-src/$BuildId.marker"
$LocalTar = Join-Path ([System.IO.Path]::GetTempPath()) "$BuildId.tar.gz"

function Remove-RemoteCopy {
    & ssh @SshOpts $RemoteHost "rm -rf '$RemoteSrc' '$RemoteMarker'" 2>$null | Out-Null
}

try {
    Write-Host "==> Packaging project"
    Push-Location $ProjectDir
    & tar -czf $LocalTar --exclude=node_modules --exclude=.git --exclude=android/build --exclude=android/app/build --exclude=ios/build --exclude=.expo .
    $tarExit = $LASTEXITCODE
    Pop-Location
    if ($tarExit -ne 0) { throw "tar failed with exit code $tarExit" }

    Write-Host "==> Streaming archive to $RemoteHost`:$RemoteSrc"
    & ssh @SshOpts $RemoteHost "mkdir -p '$RemoteSrc' && touch '$RemoteMarker'"
    if ($LASTEXITCODE -ne 0) { throw "failed to create remote temp dir" }

    & scp @SshOpts $LocalTar "${RemoteHost}:$RemoteSrc/src.tar.gz"
    if ($LASTEXITCODE -ne 0) { throw "failed to upload archive to server" }

    & ssh @SshOpts $RemoteHost "tar xzf '$RemoteSrc/src.tar.gz' -C '$RemoteSrc' && rm '$RemoteSrc/src.tar.gz'"
    if ($LASTEXITCODE -ne 0) { throw "failed to extract archive on server" }

    Write-Host "==> Triggering build on $RemoteHost (this streams live -- a real build takes ~15-20 min)"
    & ssh @SshOpts $RemoteHost "EXPO_TOKEN='$($env:EXPO_TOKEN)' '$RemoteDir/scripts/run-build.sh' '$RemoteSrc' '$Platform' '$Profile_'"
    $BuildStatus = $LASTEXITCODE

    Write-Host "==> Fetching log"
    $RemoteLog = & ssh @SshOpts $RemoteHost "find '$RemoteDir/logs' -maxdepth 1 -type f -newer '$RemoteMarker' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-"
    if ($RemoteLog) {
        $LogsDir = Join-Path $OutDir "logs"
        New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null
        & scp @SshOpts "${RemoteHost}:$RemoteLog" $LogsDir
        Write-Host "==> Log saved to $(Join-Path $LogsDir (Split-Path -Leaf $RemoteLog))"
    }

    if ($BuildStatus -ne 0) {
        Write-Error "Remote build FAILED (exit $BuildStatus). See log above."
        exit $BuildStatus
    }

    Write-Host "==> Finding artifact"
    $RemoteArtifact = & ssh @SshOpts $RemoteHost "find '$RemoteDir/output' -maxdepth 1 -type f -newer '$RemoteMarker' -printf '%T@ %p\n' | sort -rn | head -1 | cut -d' ' -f2-"
    if (-not $RemoteArtifact) {
        Write-Error "build reported success but no new artifact was found in $RemoteDir/output"
        exit 1
    }

    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    & scp @SshOpts "${RemoteHost}:$RemoteArtifact" $OutDir
    Write-Host "==> Done. Artifact: $(Join-Path $OutDir (Split-Path -Leaf $RemoteArtifact))"
}
finally {
    Remove-RemoteCopy
    if (Test-Path $LocalTar) { Remove-Item $LocalTar -Force -ErrorAction SilentlyContinue }
}
