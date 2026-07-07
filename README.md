# admini-eas-local-builder

Self-hosted, containerized replacement for EAS cloud build *compute*. Uses
`eas build --local` inside an ephemeral, resource-capped Docker container so
credentials/signing still go through Expo, but the build itself runs on our
own hardware instead of Expo's paid build queue.

## Why this exists

EAS cloud billing is driven by build minutes. This setup keeps using Expo for
what it's good at (credential/keystore management via `EXPO_TOKEN`) while
running the actual compute locally or on our own server — for free, on
demand, without a long-lived build machine sitting idle.

## What it does NOT solve

- **iOS/macOS builds** — require real macOS + Xcode. This is a Linux
  container; iOS builds are out of scope here and stay on EAS cloud (or a
  Mac you own / an EC2 Mac instance).
- **Credential storage** — deliberately left to Expo. We don't manage
  keystores ourselves.
- **SDK/toolchain version drift** — every Expo SDK bump may require bumping
  `ANDROID_PLATFORM_VERSION` / `ANDROID_BUILD_TOOLS_VERSION` /
  `ANDROID_CMDLINE_TOOLS_VERSION` build args in the `Dockerfile`. This is the
  main ongoing maintenance cost of this approach vs. EAS cloud.

## Architecture

```
run-build.sh (host)
  -> flock              # serializes builds, one at a time
  -> timeout 1h         # kills hung builds
  -> docker run --rm    # ephemeral, resource-capped container
       -> build.sh (container entrypoint)
            -> copies /source (ro mount) into writable /workspace
            -> npm install
            -> eas build --local --platform android
            -> artifact written to /output (bind-mounted back to host)
```

The project source is mounted **read-only**; `build.sh` copies it into the
container's own filesystem before building, so your working tree's
`node_modules` / build caches are never touched or polluted.

Gradle and npm caches persist across runs in named Docker volumes
(`admini-eas-gradle-cache`, `admini-eas-npm-cache`) to avoid re-downloading
dependencies on every build.

## Setup

```bash
docker build -t admini-eas-builder:latest .
```

## Usage

```bash
cp .env.example .env   # fill in EXPO_TOKEN
export $(grep -v '^#' .env | xargs)
./scripts/run-build.sh /home/bennyhinn/projects/Admini-Mobile-App-Client android
```

Artifacts land in `./output/`. Each run writes a full log to
`./logs/build-<timestamp>-<platform>.log` (streamed live to your terminal
too via `tee`), and while a build is running you can tail it from another
shell with `tail -f logs/build-*.log` or `docker logs -f <container-name>`
(the container name is printed at build start).

## Testing locally before shipping to any server

This is designed to be built and verified entirely on a local machine first.
Docker gives environment parity, so once a build succeeds locally, shipping
to a server is just: install Docker there, `docker build` the same
`Dockerfile`, copy `scripts/`, done.

### Before running this on a shared/production server

- **Network-isolate the container.** `run-build.sh` currently uses Docker's
  default bridge network (fine on a laptop). On a server that also runs
  production services (databases, internal APIs), put the build container on
  a dedicated Docker network with no route to those services, while still
  allowing outbound internet access (needed to reach Expo's API).
- **Re-tune resource limits** (`--memory`, `--cpus` in `run-build.sh`) against
  that server's actual free capacity, not a laptop's.
- **Scope and rotate `EXPO_TOKEN`** — treat it as a secret with account-level
  reach; keep it out of shell history and logs.

## Security notes

- Build containers execute arbitrary code from the project's dependency tree
  (npm postinstall scripts, Gradle plugins). Treat them as untrusted.
- `EXPO_TOKEN` is injected at container runtime via `-e`, never baked into
  the image.
