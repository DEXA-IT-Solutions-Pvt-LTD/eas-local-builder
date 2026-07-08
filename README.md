# ssheas

Self-hosted, drop-in replacement for **EAS cloud build compute**. Same
`eas-cli`, same credentials, same `eas.json` profiles — the only thing
that changes is *where the build runs*: your own server instead of
Expo's paid build queue.

> For architecture details, verified benchmarks, known issues already
> fixed, and security notes, see [TECHNICAL_NOTES.md](TECHNICAL_NOTES.md).

## Summary

`ssheas` mirrors `eas build`'s own syntax (`--platform`, `--profile`).
In remote mode it tars your project, streams it over SSH into a
throwaway directory on your build server, builds it there in a
disposable Docker container, copies the finished artifact back to your
machine, then deletes the remote copy. Nothing of your source persists
on the server between builds. Available for macOS/Linux (`ssheas`) and
Windows (`ssheas.ps1`).

Android only — iOS/macOS builds require real Apple hardware and are out
of scope for this Linux-container-based tool.

## Installation

**macOS / Linux:**
```bash
git clone https://github.com/DEXA-IT-Solutions-Pvt-LTD/eas-local-builder.git
cd eas-local-builder
./install.sh
```

**Windows (PowerShell):**
```powershell
git clone https://github.com/DEXA-IT-Solutions-Pvt-LTD/eas-local-builder.git
cd eas-local-builder
.\install.ps1
```

Both installers clone/update the repo to a fixed location and register
a `ssheas` command in your shell profile, so it works as a plain word
from any directory in any new terminal. Safe to re-run later to pick up
updates — idempotent, won't duplicate the profile entry.

Requires `git`, `ssh`, `scp`, and `tar` — all already present on
macOS/Linux, and bundled with Windows 10 (1803+) / 11 by default (if
`ssh`/`scp` are missing: **Settings → Apps → Optional Features → Add a
feature → OpenSSH Client**). No Docker needed on your machine — the
build runs on the server.

**One-time server setup** (someone needs to do this once per build
server):
```bash
git clone https://github.com/DEXA-IT-Solutions-Pvt-LTD/eas-local-builder.git
cd eas-local-builder
docker build -t admini-eas-builder:latest .
```
Requires Docker Engine on the server.

## Setup — configuring credentials

Use the built-in `config` subcommand — no text editor needed:

```bash
ssheas config set EXPO_TOKEN <your Expo access token>
ssheas config set SSHEAS_REMOTE_HOST ubuntu@your-server-host
ssheas config set SSHEAS_REMOTE_KEY ~/keys/your-server-key.pem
```

(Windows: same commands, just via `ssheas` in PowerShell after
`install.ps1`, or `ssheas.ps1` if running without the installer.)

This writes to a `.env` file next to the script. Once set, `--remote`/
`--key` never need to be typed again — though passing them explicitly
on the command line always overrides the saved config.

Other config actions:
```bash
ssheas config list           # show current values (secrets masked)
ssheas config get KEY        # print one value raw
ssheas config remove KEY     # delete an entry
```

Get an `EXPO_TOKEN` at
`https://expo.dev/accounts/[account]/settings/access-tokens`.

## Usage

Run from inside the Expo project directory you want to build, same as
real `eas build`:

**Remote mode (recommended)** — builds on your configured server:
```bash
cd ~/Admini-Mobile-App-Client
ssheas build --platform android --profile preview
```
The artifact and its full build log land in `./ssheas-output/` next to
wherever you ran the command.

**Local mode** — drop `--remote`/`--key` (and don't set them in config)
to build directly on the machine you're running on instead of over SSH.
Only useful if you're running `ssheas` directly on a machine that
already has the Docker image built (e.g. on the server itself):
```bash
cd ~/Admini-Mobile-App-Client
ssheas build --platform android --profile preview
```
Output stays local to that machine, in `./output/` and `./logs/` next
to the `ssheas` script.

**Getting logs on failure**: build output streams live to your terminal
either way. In remote mode the log is also copied back automatically
to `./ssheas-output/logs/`, pass or fail — no separate SSH session
needed to see what went wrong.

## Commands & flags reference

### `ssheas build`

```
ssheas build --platform <android|ios> [--profile <name>] [options]
```

| Flag | Description | Default |
|---|---|---|
| `--platform` | `android` or `ios` (`ios` is not supported — needs macOS/Xcode) | *(required)* |
| `--profile` | `eas.json` build profile to use | `preview` |
| `--project-dir` | Path to the Expo project | current directory |
| `--remote` | SSH target, e.g. `ubuntu@your-server-host` — enables remote mode | *(from config, or unset = local mode)* |
| `--key` | Path to SSH identity file (`.pem`) | *(from config)* |
| `--remote-dir` | Path to this repo on the server, relative to your home dir there | `eas-local-builder` (or config) |
| `--out` | Local dir to copy the artifact into | `./ssheas-output` |

`--profile` maps directly to `eas.json` — e.g. `preview` typically
builds an installable `.apk`, `production` a Play Store `.aab`. The
output file extension is picked automatically to match.

### `ssheas config`

```
ssheas config <list|get|set|remove> [args]
```

| Action | Usage |
|---|---|
| `list` | `ssheas config list` — show all saved values (secrets masked) |
| `get` | `ssheas config get KEY` — print one value raw |
| `set` | `ssheas config set KEY VALUE` — save/update a value |
| `remove` | `ssheas config remove KEY` (alias: `rm`) — delete a value |

Recognized keys: `EXPO_TOKEN`, `SSHEAS_REMOTE_HOST`,
`SSHEAS_REMOTE_KEY`, `SSHEAS_REMOTE_DIR`.

## More detail

See [TECHNICAL_NOTES.md](TECHNICAL_NOTES.md) for the architecture
diagram, EAS-cloud-vs-this comparison, verified build benchmarks,
security model, known issues already hit and fixed, and open
follow-ups.
