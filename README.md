# limpet

limpet is a macOS menu bar app that mirrors a local folder to a remote
target, one-way (local → remote), using [rclone](https://rclone.org/) as
the sync engine. Any remote rclone supports can be the destination.

## What it does today

- **One-way local → remote mirroring.** Each profile syncs a local
  directory to a remote path via `rclone sync`; the remote always ends up
  matching the local source.
- **Menu bar status.** The menu bar icon shows idle / syncing / error /
  drive-not-mounted state, live transfer progress, and a list of recently
  synced files.
- **Multiple profiles.** Any number of local-folder → remote pairs, each
  with its own schedule, enable/disable state, and notification muting.
- **Background runs via launchd.** Each enabled profile installs a
  `~/Library/LaunchAgents` agent that runs the sync on an interval, so
  syncing continues while the app isn't the active window.
- **Headless CLI.** A `limpet` shim at `~/.local/bin/limpet` exposes the
  same profile management, health checks, and manual sync as the GUI, so a
  script or agent can drive it without opening a window.
- **File-backed, editable configuration.** Profiles and settings live as
  JSON under `~/.config/limpet/`, validated against a committed JSON
  Schema; hand-editing a file live-applies through the same reconcile path
  the GUI's Save button uses.

> **Realtime watching is a work in progress.** Right now, real-time
> FSEvents-based triggering only runs while the menu bar app is open; the
> launchd agent falls back to interval polling once the app is closed. A
> planned change moves ownership of scheduling and watching into the
> per-profile launchd agent itself, so real-time sync keeps working with
> the app closed.

## Requirements

- macOS 13.0 or later
- [rclone](https://rclone.org/), installed and with at least one remote
  configured (`brew install rclone`, then `rclone config`)

limpet auto-detects rclone from Homebrew, `/usr/local/bin`, `/usr/bin`, and
common nix install locations.

## Building from source

There is no signed release and no Homebrew cask yet, so build it yourself:

```bash
git clone https://github.com/Nanako0129/limpet.git
cd limpet
xcodebuild -project limpet.xcodeproj -scheme limpet \
  -configuration Debug CODE_SIGNING_ALLOWED=NO -derivedDataPath build build
open build/Build/Products/Debug/limpet.app
```

The built app is unsigned.

## The `limpet` CLI

The app installs a `limpet` shim at `~/.local/bin/limpet` on every launch
(add `~/.local/bin` to your `PATH`). It works whether or not the GUI app is
running, since every mutating command goes through the same file-backed
config the GUI reads and writes.

| Command | Purpose |
| --- | --- |
| `limpet doctor` | Health check: rclone found, schemas installed, agents loaded, stale locks, remote reachability. |
| `limpet status [name\|id]` | One line per profile: enabled, agent loaded, running, last result. |
| `limpet profiles` | List profiles (no secrets). |
| `limpet profile show <name\|id>` | Print a profile's full config as JSON. |
| `limpet logs <name\|id> [--follow]` | Print or tail a profile's sync log. |
| `limpet test-remote <name\|id>` | Probe a profile's remote reachability. |
| `limpet listremotes` | Passthrough to `rclone listremotes`. |
| `limpet profile create --from <file>` / `-` | Create a profile from a `.profile.json` file or stdin. |
| `limpet profile enable` / `disable` / `delete <name\|id>` | Enable, disable, or delete a profile. |
| `limpet profile set <name\|id> <key> <value> ...` | Edit fields on an existing profile. |
| `limpet install` / `reinstall <name\|id>` | (Re)install a profile's launchd agent. |
| `limpet sync <name\|id>` | Run a sync now and block until it finishes. |

## File locations

| Path | Contents |
| --- | --- |
| `~/.local/bin/limpet` | CLI shim |
| `~/.local/bin/limpet-sync.sh` | Shared sync script (all profiles) |
| `~/.config/limpet/profiles/{shortId}.profile.json` | Authoritative profile (editable) |
| `~/.config/limpet/profiles/{shortId}.json` | Derived, script-only config |
| `~/.config/limpet/settings.json` | App settings (editable) |
| `~/.config/limpet/schema/*.schema.json` | JSON Schemas for the files above |
| `~/.local/log/limpet-sync-{shortId}.log` | Per-profile sync log |
| `/tmp/limpet-sync-{shortId}.lock` | Lock file (prevents overlapping runs) |
| `~/Library/LaunchAgents/com.nanako.limpet.watch.{shortId}.plist` | Per-profile launchd agent |

## What limpet deliberately doesn't do

limpet mirrors in one direction and nothing else. There is no two-way
sync, no version history or restore, no fallback remote, no mount mode,
no Finder extension, no auto-update, and no telemetry.

## Development

```bash
xcodebuild -project limpet.xcodeproj -scheme limpet \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

There's no XCTest target; `limpet --self-test` (Debug builds only) runs
the assertion suite covering profile persistence, migration, the config
reconciler, and the CLI. `scripts/check-schema-in-sync.sh` is a
fail-closed check that the committed JSON Schema stays in lockstep with
the `SyncProfile` model.

## License

MIT — see [LICENSE](LICENSE).
