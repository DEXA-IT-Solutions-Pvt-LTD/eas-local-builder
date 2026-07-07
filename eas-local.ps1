# Windows PowerShell counterpart to `eas-local` (bash). Same flags, same
# behavior: tars the project, streams it to a throwaway dir on the Linux
# build server over SSH, triggers the build there, copies the artifact (and
# log) back, then deletes the remote copy.
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
#   .\eas-local.ps1 build --platform android --profile preview `
#     --remote ubuntu@ec2-13-203-69-0.ap-south-1.compute.amazonaws.com `
#     --key C:\keys\Admini_t3.pem
#
# Tip: run from inside the mobile app project directory, same as real
# `eas build` — or pass --project-dir explicitly.

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = (Get-Location).Path
$Platform = "android"
$Profile_ = "preview"
$RemoteHost = ""
$RemoteKey = ""
$RemoteDir = "eas-local-builder"
$OutDir = ".\eas-local-output"

function Show-Usage {
    Write-Host @"
Usage: eas-local.ps1 build --platform <android|ios> --remote <user@host> --key <path> [options]

  --platform     android (ios needs macOS/Xcode -- not supported here)
  --profile      eas.json build profile to use (default: preview)
  --project-dir  path to the Expo project (default: current directory)
  --remote       ssh target, e.g. ubuntu@ec2-13-203-69-0.ap-south-1.compute.amazonaws.com
  --key          path to SSH identity file (.pem)
  --remote-dir   path to eas-local-builder on the server (default: eas-local-builder)
  --out          local dir to copy the artifact into (default: .\eas-local-output)

Example:
  `$env:EXPO_TOKEN = "..."
  .\eas-local.ps1 build --platform android --profile preview ``
    --remote ubuntu@ec2-13-203-69-0.ap-south-1.compute.amazonaws.com --key C:\keys\Admini_t3.pem
"@
    exit 1
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

# Auto-load .env next to this script if EXPO_TOKEN wasn't already set.
if (-not $env:EXPO_TOKEN) {
    $envFile = Join-Path $ScriptDir ".env"
    if (Test-Path $envFile) {
        Get-Content $envFile | ForEach-Object {
            if ($_ -match '^\s*([^#=][^=]*)=(.*)$') {
                [System.Environment]::SetEnvironmentVariable($matches[1].Trim(), $matches[2].Trim())
            }
        }
    }
}
if (-not $env:EXPO_TOKEN) {
    Write-Error "EXPO_TOKEN env var is required. Set `$env:EXPO_TOKEN = '...' or create a .env file next to this script."
    exit 1
}

if (-not $RemoteHost) {
    Write-Error "This Windows script only supports --remote mode. Pass --remote <user@host> --key <path>."
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
        New-Item -ItemType Directory -Force -Path (Join-Path $OutDir "logs") | Out-Null
        & scp @SshOpts "${RemoteHost}:$RemoteLog" (Join-Path $OutDir "logs\")
        Write-Host "==> Log saved to $(Join-Path $OutDir "logs\$(Split-Path -Leaf $RemoteLog)")"
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
    & scp @SshOpts "${RemoteHost}:$RemoteArtifact" "$OutDir\"
    Write-Host "==> Done. Artifact: $(Join-Path $OutDir (Split-Path -Leaf $RemoteArtifact))"
}
finally {
    Remove-RemoteCopy
    if (Test-Path $LocalTar) { Remove-Item $LocalTar -Force -ErrorAction SilentlyContinue }
}
