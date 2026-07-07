# admini-eas-local-builder

Self-hosted replacement for **EAS cloud build compute**. Same `eas-cli`,
same credentials, same `eas.json` profiles — the only thing that changes is
*where the build runs*: our own server instead of Expo's paid build queue.

## TL;DR — try it in 3 commands

If you already know `eas build`, you already know this. From inside the
mobile app project directory:

```bash
export EXPO_TOKEN=<your Expo access token>
/path/to/eas-local-builder/eas-local build --platform android --profile preview
# ... same eas-cli output you already know ...
# APK lands in /path/to/eas-local-builder/output/
```

No new flags, no new mental model. `eas-local` is a thin wrapper that mirrors
`eas build`'s own syntax (`--platform`, `--profile`) and runs it inside a
disposable Docker container on our infrastructure instead of Expo's.

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
builds today. Verified runs on `ec2-13-203-69-0.ap-south-1.compute.amazonaws.com`:

| Profile      | Output                          | Size   | Build time |
|--------------|----------------------------------|--------|------------|
| `preview`    | installable `.apk`               | 110 MB | ~19 min    |
| `production` | Play Store `.aab`                | 62 MB  | ~20 min    |

Both used real project source, real signing credentials pulled from Expo,
and produced artifacts an `eas build --local` run would have produced
identically — just without the EAS cloud queue or bill.

## Architecture

```
eas-local build --platform android --profile preview     (what you type)
  │
  ▼
scripts/run-build.sh (host)
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
            → artifact written to /output (bind-mounted back to host)
```

Your project's actual `node_modules`/`.gradle`/git history are never
touched — the container works on a throwaway copy. Gradle and npm caches
persist across builds in named Docker volumes so dependencies aren't
re-downloaded every time.

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

## Setup (one-time, per machine/server)

```bash
git clone https://github.com/DEXA-IT-Solutions-Pvt-LTD/eas-local-builder.git
cd eas-local-builder
docker build -t admini-eas-builder:latest .
```

Requires Docker Engine. Nothing else — the image bundles Node, JDK 17,
Android SDK cmdline-tools, and `eas-cli`.

## Usage

**Recommended — the `eas-local` wrapper**, run from inside the mobile app
project directory (same as real `eas build`):

```bash
export EXPO_TOKEN=<token>
cd ~/Admini-Mobile-App-Client
/path/to/eas-local-builder/eas-local build --platform android --profile preview
```

Tip: `alias eas-local=/path/to/eas-local-builder/eas-local` makes it a
literal drop-in swap for `eas` in daily use.

`--profile` maps directly to `eas.json` build profiles — `preview` (default)
builds an installable `.apk`, `production` builds a Play Store `.aab`. The
output file extension is picked automatically to match.

**Underlying script** (what `eas-local` calls), if you need to pass an
explicit path instead of running from inside the project:

```bash
./scripts/run-build.sh /path/to/project android preview
```

Artifacts land in `./output/`. Each run writes a full log to
`./logs/build-<timestamp>-<platform>.log` (streamed live to your terminal
too), and while a build is running you can tail it from another shell with
`tail -f logs/build-*.log` or `docker logs -f <container-name>` (the
container name is printed at build start).

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
- [ ] Decide on a recurring source-sync method (currently a one-off rsync
      for testing) vs. `git clone` per build
