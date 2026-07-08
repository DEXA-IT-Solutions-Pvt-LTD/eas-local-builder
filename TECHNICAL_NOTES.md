# admini-eas-local-builder — Technical Notes

> For everyday usage (install, config, running builds, flag reference),
> see [README.md](README.md). This file is the deeper engineering
> record: architecture, verification results, known issues already
> fixed, security notes, and open follow-ups.

Self-hosted replacement for **EAS cloud build compute**. Same `eas-cli`,
same credentials, same `eas.json` profiles — the only thing that changes is
*where the build runs*: our own server instead of Expo's paid build queue.

## TL;DR — try it in one command

If you already know `eas build`, you already know this. From inside the
mobile app project directory, on **your own laptop** — nothing needs to be
pre-installed or pre-copied to the server:

```bash
export EXPO_TOKEN=<your Expo access token>
/path/to/eas-local-builder/ssheas build --platform android --profile preview \
  --remote ubuntu@your-server-host \
  --key ~/keys/admini-build-server.pem
# ... same eas-cli output you already know, streamed live ...
# APK lands in ./ssheas-output/ on YOUR machine
```

No new flags beyond pointing at the server, no new mental model. `ssheas`
mirrors `eas build`'s own syntax (`--platform`, `--profile`) and, in
`--remote` mode, tars your project, streams it over SSH into a throwaway
directory on the server, builds it there in a disposable Docker container,
copies the artifact back to your machine, then deletes the remote copy.
Nothing of your source persists on the server between builds.

## Why this exists

EAS cloud billing is metered by build minutes. Every Android build we run
costs money regardless of who triggers it or how often. This project keeps
using Expo for the part that actually needs a trusted third party —
credential and keystore management, via `EXPO_TOKEN` — while running the
actual compute (the part that costs money) on hardware we already pay for.

Net effect: same builds, same signing, same `eas.json` config, effectively
free compute.

## Status: working, verified on our production server

This isn't a proposal — it's built, tested, and producing real signed
builds today. Verified runs on `your-server-host`:

| Profile      | Mode   | Output              | Size   | Build time |
|--------------|--------|---------------------|--------|------------|
| `preview`    | local  | installable `.apk`  | 110 MB | ~19 min    |
| `production` | local  | Play Store `.aab`   | 62 MB  | ~20 min    |
| `preview`    | remote | installable `.apk`  | 110 MB | ~19 min (tar/scp overhead negligible on top) |

All three used real project source, real signing credentials pulled from
Expo, and produced artifacts an `eas build --local` run would have produced
identically — just without the EAS cloud queue or bill. The remote run
confirmed the full tar → stream → build → copy-back → cleanup loop end to
end, including the artifact landing on the *triggering* machine rather than
the server.

## Architecture

```
ssheas build --platform android --profile preview --remote ... --key ...
  (run on YOUR laptop, inside the project directory)
  │
  ├─ tar czf project (excludes node_modules, .git, build/) ──ssh──▶ /tmp/ssheas-remote-src/<id>/  (server, throwaway)
  │
  ▼ (ssh) triggers on the server:
  scripts/run-build.sh
    ├─ flock            serializes builds — two runs never race the shared cache
    ├─ timeout 1h        kills a hung build instead of leaving it running forever
    └─ docker run --rm --memory=8g --cpus=4   (ephemeral, resource-capped)
         │
         ▼
       scripts/build.sh (container entrypoint)
         ├─ copies /source (read-only mount) into writable /workspace
         ├─ git init (source is copied without .git for a clean sandbox;
         │            eas build needs *a* repo to fingerprint the build)
         ├─ npm install
         └─ eas build --local --platform android --profile preview
              → pulls signing credentials from Expo via EXPO_TOKEN
              → same eas-cli / @expo/build-tools code path as EAS cloud
              → artifact written to server's ./output/
  │
  ◀─ scp artifact back to YOUR laptop's ./ssheas-output/
  │
  └─ rm -rf the /tmp/ssheas-remote-src/<id>/ copy on the server
```

Your project's actual `node_modules`/`.gradle`/git history are never
touched locally either — only a filtered tar of the source leaves your
machine. Gradle and npm caches persist across builds in named Docker
volumes *on the server* so dependencies aren't re-downloaded every time,
but the project source itself never lingers there between builds.

(If you're working directly on the server instead of from a laptop, drop
`--remote`/`--key` and it runs against a local path exactly as before —
see "Local mode" below.)

## EAS cloud vs. this

| | EAS cloud | admini-eas-local-builder |
|---|---|---|
| Cost | Billed per build minute | Free (uses hardware we already pay for) |
| Credentials/signing | Managed by Expo | Still managed by Expo — unchanged |
| `eas.json` profiles | Used as-is | Used as-is, same file |
| Android builds | ✅ | ✅ |
| iOS builds | ✅ (Expo's macOS workers) | ❌ — needs real macOS + Xcode, out of scope here |
| Build queueing | Automatic | `flock` — one at a time, per host |
| Hung build protection | Automatic | `timeout`, default 1h |
| SDK/toolchain upgrades | Expo's problem | Ours — bump versions in `Dockerfile` when Expo SDK bumps |
| Network isolation from other services | N/A (dedicated infra) | Our responsibility on a shared server (see below) |

## Setup

**On your laptop (for `--remote` mode — the recommended path):** nothing
beyond having `ssh`/`scp`/`tar` and a copy of this repo for the `ssheas`
script itself:

```bash
git clone https://github.com/DEXA-IT-Solutions-Pvt-LTD/eas-local-builder.git
```

- **macOS/Linux**: `ssh`/`scp`/`tar` are already there. Use `ssheas`.
- **Windows**: use `ssheas.ps1` (PowerShell) instead — same flags, same
  behavior. It needs `tar.exe` and the OpenSSH client, both bundled with
  Windows 10 (1803+) / Windows 11 by default. If `ssh`/`scp` aren't found:
  **Settings → Apps → Optional Features → Add a feature → OpenSSH Client**.
  See "Usage (Windows)" below.

No Docker required locally in either case — the build runs on the server.

**On the server (one-time):**

```bash
git clone https://github.com/DEXA-IT-Solutions-Pvt-LTD/eas-local-builder.git
cd eas-local-builder
docker build -t admini-eas-builder:latest .
```

Requires Docker Engine on the server. The image bundles Node, JDK 17,
Android SDK cmdline-tools, and `eas-cli` — already built and live on
`your-server-host` as of this writing.

## Usage

### One-time setup: `install.sh`

Instead of typing the full path to `ssheas` every time, run the installer
once — it clones this repo to a fixed location (`$XDG_DATA_HOME` or
`~/.local/share/eas-local-builder`) and registers a `ssheas` shell
function in `~/.bashrc`/`~/.zshrc`:

```bash
git clone https://github.com/DEXA-IT-Solutions-Pvt-LTD/eas-local-builder.git
cd eas-local-builder
./install.sh
```

It also scaffolds a `.env` for you to fill in via `ssheas config set` (see
below). Safe to re-run later — it won't duplicate the rc file entry, and
pulls updates if run again against an existing install. Takes effect in
new shell sessions (or run `source ~/.bashrc`).

**Remote mode (recommended)** — run from your laptop, inside the mobile
app project directory, same as real `eas build`:

```bash
export EXPO_TOKEN=<token>
cd ~/Admini-Mobile-App-Client
ssheas build --platform android --profile preview \
  --remote ubuntu@your-server-host \
  --key ~/keys/admini-build-server.pem
```

(Without `install.sh`, replace `ssheas` above with the full path:
`/path/to/eas-local-builder/ssheas`.)

**Skip retyping `--remote`/`--key` every time**: either create a `.env`
file next to the `ssheas` script by hand (copy `.env.example`), or use the
built-in `config` subcommand — no text editor needed:

```bash
/path/to/eas-local-builder/ssheas config set EXPO_TOKEN <token>
/path/to/eas-local-builder/ssheas config set SSHEAS_REMOTE_HOST user@your-server-host
/path/to/eas-local-builder/ssheas config set SSHEAS_REMOTE_KEY ~/keys/build-server.pem
```

Then the whole thing collapses to:

```bash
cd ~/Admini-Mobile-App-Client
/path/to/eas-local-builder/ssheas build --platform android --profile preview
```

Any of `--remote`/`--key`/`--remote-dir` passed explicitly on the command
line still override `.env` — this is just a default, not a lock-in.

**Managing config**: `ssheas config list` shows current values (secrets
like `EXPO_TOKEN` are masked), `ssheas config get KEY` prints one value
raw, and `ssheas config remove KEY` deletes an entry. All of these just
read/write the `.env` file next to the script — nothing fancier.

Your project is tarred (excluding `node_modules`, `.git`, build output
dirs), streamed to a throwaway directory on the server, built there, and
the artifact is scp'd back to `./ssheas-output/` on your machine. The
remote copy is deleted afterward — nothing lingers on the server between
builds except the Docker image and its warm dependency caches.

**Local mode** — if you're working directly on the server (or any machine
with the image already built there), drop `--remote`/`--key` and it builds
against a local path instead:

```bash
cd ~/Admini-Mobile-App-Client
/path/to/eas-local-builder/ssheas build --platform android --profile preview
```

No `export EXPO_TOKEN=...` needed here if a `.env` already exists next to
`ssheas` (there's one set up on the server already) — both `ssheas`
and `scripts/run-build.sh` auto-load it when `EXPO_TOKEN` isn't already in
the environment. An explicitly exported `EXPO_TOKEN` always takes priority
over `.env`, so this doesn't get in the way of using a different token
when you need to.

In both modes, `--profile` maps directly to `eas.json` build profiles —
`preview` (default) builds an installable `.apk`, `production` builds a
Play Store `.aab`. The output file extension is picked automatically to
match.

**Underlying script** (what `ssheas` calls in local mode), if you need
to pass an explicit path instead of running from inside the project:

```bash
./scripts/run-build.sh /path/to/project android preview
```

## Usage (Windows)

`ssheas.ps1` is the PowerShell counterpart to `ssheas` — same flags,
same remote-mode behavior (only remote mode is supported on Windows; local
mode would need Docker + the Android SDK installed on Windows itself,
which defeats the point).

### One-time setup: `install.ps1`

Instead of typing the full path to `ssheas.ps1` every time, run the
installer once — it clones this repo to a fixed location and registers an
`ssheas` function in your PowerShell profile, so `ssheas` works as a
plain command from any directory in any new PowerShell window:

```powershell
git clone https://github.com/DEXA-IT-Solutions-Pvt-LTD/eas-local-builder.git
cd eas-local-builder
.\install.ps1
```

It also scaffolds a `.env` from `.env.example` for you to fill in
(`EXPO_TOKEN`, `SSHEAS_REMOTE_HOST`, `SSHEAS_REMOTE_KEY`). Safe to
re-run later — it won't duplicate the profile entry, and updates the clone
via `git pull` if run again from `LOCALAPPDATA`. If Windows PowerShell
and PowerShell 7 are both in use, each has its own profile — re-run
`install.ps1` from whichever one you'll actually use `ssheas` in.

If your execution policy blocks running the installer (`... cannot be
loaded because running scripts is disabled ...`), run once:
`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

After setup, from inside any Expo project directory:

```powershell
ssheas build --platform android --profile preview
```

(with `.env` filled in — otherwise pass `--remote`/`--key` explicitly, see
below.)

### Without the installer

From PowerShell, inside the mobile app project directory:

```powershell
$env:EXPO_TOKEN = "<token>"
cd C:\path\to\Admini-Mobile-App-Client
C:\path\to\eas-local-builder\ssheas.ps1 build --platform android --profile preview `
  --remote ubuntu@your-server-host `
  --key C:\keys\admini-build-server.pem
```

Same result as the bash version: project tarred, streamed to a throwaway
directory on the server, built there, artifact and log copied back to
`.\ssheas-output\` on the Windows machine, remote copy deleted after.

**Skip retyping `--remote`/`--key` every time**: either create a `.env`
file next to `ssheas.ps1` by hand (copy `.env.example`), or use the
built-in `config` subcommand:

```powershell
ssheas config set EXPO_TOKEN <token>
ssheas config set SSHEAS_REMOTE_HOST ubuntu@your-server-host
ssheas config set SSHEAS_REMOTE_KEY C:\keys\admini-build-server.pem
```

Then the command collapses to just:

```powershell
cd C:\path\to\Admini-Mobile-App-Client
C:\path\to\eas-local-builder\ssheas.ps1 build --platform android --profile preview
```

Any explicit `--remote`/`--key` flags on the command line still override
`.env`. `ssheas config list` / `ssheas config get KEY` / `ssheas config
remove KEY` work the same as the bash version.

> **Verified with PowerShell 7 on Linux against the real server** — both the
> failure path (bad build profile: error surfaced live, log auto-fetched)
> and a full successful build (110MB APK + log landed correctly locally,
> remote source cleaned up afterward) were run end-to-end and two real bugs
> were found and fixed this way (`$env:TEMP` doesn't exist outside Windows;
> a trailing backslash on the scp destination misplaced the artifact).
> **Not yet run on an actual Windows machine, though** — the remote-side
> commands are identical regardless of client OS since they run over SSH,
> but a native Windows run is still worth doing once before the live TL
> demo. If `tar`/`ssh`/`scp` throw errors there, confirm the OpenSSH Client
> optional feature is installed (Settings → Apps → Optional Features).

## Getting logs — including on failure

The build output streams live to your terminal in both modes, so if
something fails you see the error immediately without doing anything extra.

- **Local mode**: the full log is also saved on disk at
  `logs/build-<timestamp>-<platform>.log`, success or failure. While a build
  is running you can tail it from another shell with `tail -f logs/build-*.log`
  or `docker logs -f <container-name>` (the container name is printed at
  build start).
- **Remote mode**: `ssheas` automatically copies the log back to your
  machine into `./ssheas-output/logs/` after every run — pass or fail —
  so you don't need a separate SSH session to read the full error. The
  server also keeps its own copy at `~/eas-local-builder/logs/` if you do
  want to dig in directly there.

Either way, a failure exits non-zero and prints the log location, so
scripting around this (e.g. CI, or a "did it work" check) is straightforward.

### Server-side retention

`run-build.sh`'s server-side `output/` and `logs/` directories are never
cleared by the copy-back step (only the tarred *source* copy under
`/tmp/eas-local-remote-src/` is deleted after each remote build) — so
without pruning, every build's artifact and log would accumulate on the
server forever. Each run now deletes anything older than
`RETENTION_DAYS` (default 3) from both directories before starting,
using `find ... -mtime +N`, and logs exactly what it removed rather than
pruning silently. Override per-run with `RETENTION_DAYS=<n>` in the
environment. Verified with synthetically-aged files (`touch -d`): files
older than the window were removed, files inside the window and
`.gitkeep` were preserved.

### Build duration tracking

`run-build.sh` times each build from right after the `flock` lock is
acquired (so queueing time behind another build isn't counted) to when
the container exits, success or failure. It prints the duration in the
final status line and appends a row to
`~/eas-local-builder/logs/build-history.csv`
(`timestamp_utc,platform,profile,status,duration_seconds,duration_human`),
creating the file with a header on first use. This gives a simple way to
track build-time trends over time (e.g. after bumping CPU/memory limits,
or after native dependency changes) without needing to grep timestamps
out of individual log files. Verified via a fast local failure (missing
Docker image): duration and CSV row both recorded correctly.

To check on a build that's currently running without waiting for it to
finish, compare `docker inspect -f '{{.State.StartedAt}}' <container>`
against the current time — this is how we've confirmed live progress
during real builds without disturbing the running process.

## What it does NOT solve

- **iOS/macOS builds** — require real macOS + Xcode. Out of scope for this
  Linux container; keep using EAS cloud for iOS (or a Mac you own / an EC2
  Mac instance).
- **Credential storage** — deliberately left to Expo; we never manage
  keystores ourselves.
- **SDK/toolchain version drift** — every Expo SDK bump may require bumping
  `ANDROID_PLATFORM_VERSION` / `ANDROID_BUILD_TOOLS_VERSION` /
  `ANDROID_CMDLINE_TOOLS_VERSION` build args in the `Dockerfile`. This is the
  main ongoing maintenance cost of this approach vs. EAS cloud.

## Issues we already hit and fixed

Documented here so they don't get re-debugged from scratch:

1. **"Would you like us to run git init?" hang** — `eas build` requires a
   git repo to fingerprint the build. Since source is copied in without
   `.git` for a clean sandbox, this prompted interactively with no stdin
   and hung. Fixed: `build.sh` auto-commits a snapshot non-interactively
   when `.git` is missing.
2. **"detected dubious ownership in repository"** — `cp -a` preserves the
   host's file ownership, which trips git's safe-directory guard inside the
   container. Fixed: `git config --global --add safe.directory` for the
   workspace — safe here since it's a disposable, single-use copy.
3. **Gradle daemon OOM-killed mid-build** — Metro, the Kotlin compiler, and
   the Gradle daemon were competing for a 4GB container memory cap and the
   daemon got killed. Fixed: raised the cap to 8GB.
4. **Keystore credentials printed in plaintext in build logs** — on an
   internal failure, `eas-cli`'s build plugin printed its full subprocess
   command line, which embeds a base64 job payload containing the keystore
   and passwords fetched from Expo. Fixed: `run-build.sh` pipes all output
   through a filter that redacts any long base64-looking run before it
   touches disk or terminal. The exposed log from the one incident where
   this happened was deleted from the server.

## Before running this on a shared/production server

- **Network-isolate the container.** Currently uses Docker's default bridge
  network. On a server that also runs other production services (databases,
  internal APIs), put the build container on a dedicated Docker network
  with no route to those services, while still allowing outbound internet
  access (needed to reach Expo's API). **Not yet done** — tracked as a
  follow-up.
- **Re-tune resource limits** (`--memory`, `--cpus` in `run-build.sh`)
  against that server's actual free capacity.
- **Scope and rotate `EXPO_TOKEN`** — treat it as a secret with
  account-level reach; keep it out of shell history and logs.

## Security notes

- Build containers execute arbitrary code from the project's dependency
  tree (npm postinstall scripts, Gradle plugins). Treat them as untrusted.
- `EXPO_TOKEN` is injected at container runtime via `-e`, never baked into
  the image.
- See "Issues we already hit and fixed" above re: credential redaction in
  logs — this is handled, but any *unfiltered* `eas build --local` output
  (e.g. running it directly, outside these scripts) should be treated as
  potentially containing secrets.

## Open follow-ups

- [ ] Network-isolate the build container from other production services
- [ ] Publish the image to GHCR so servers can `docker pull` instead of
      `docker build` (image contains no secrets, safe to make public)
- [x] ~~Decide on a recurring source-sync method~~ — resolved: `ssheas
      --remote` tars and streams the project fresh per build, so nothing
      persists on the server between builds. No sync step needed.
