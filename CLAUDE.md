# limpet Development Guidelines

## Project Overview

limpet is a macOS menu bar application that provides Google Drive-style background folder sync using rclone. It syncs a local folder one-way with any of rclone's 70+ supported cloud providers (Dropbox, OneDrive, Google Drive, S3, SFTP, etc.).

### Key Features
- **Multi-profile support**: Configure multiple sync pairs (local folder ↔ cloud remote)
- **One-way sync**: Upload (local → remote) or download (remote → local), your choice per profile
- **Background sync via launchd**: Scheduled syncs run automatically at configurable intervals
- **Real-time file monitoring**: FSEvents-based directory watching triggers syncs on local changes
- **External drive support**: Auto-detects when external drives are mounted/unmounted
- **Live progress tracking**: Parses rclone JSON logs for real-time transfer progress
- **macOS notifications**: Batch notifications for file changes with "Open Directory" action

### Sync Modes

| Mode | rclone Command | Description |
|------|----------------|-------------|
| One-Way Upload | `rclone sync local remote` | Local is authoritative, uploads to remote |
| One-Way Download | `rclone sync remote local` | Remote is authoritative, downloads to local |

### Additional rclone Flags

The per-profile `additionalRcloneFlags` field (free text, `Any additional rclone flags`
in the UI) is appended to the generated sync script's rclone invocation. The
script builds that invocation as a bash argv array and runs it directly — never
through `eval` — so `additionalRcloneFlags` is split on whitespace (`read -r -a`)
into literal argv elements with **no shell quoting or expansion**. Write flags
as `--flag=value` (e.g. `--exclude=*.tmp --bwlimit=5M`); a flag's value cannot
contain a space, because there is no quoting syntax left to express one. A
value containing a quote (`"`/`'`), a backtick, `$`, or a token starting with
`~` is refused before rclone ever runs (`exit 64`, logged as `Refusing to
sync: ...`) instead of being passed through — quoting or expanding it would
otherwise reach rclone as literal, meaningless text (e.g. `--exclude "*.tmp"`
would arrive as the single token `"*.tmp"`, quotes included, matching nothing).

### How It Works
1. User configures a profile: local path, rclone remote, and sync interval
2. limpet generates a shell script and launchd plist for scheduled syncs
3. LogWatcher monitors the sync log file for state changes and progress
4. DirectoryWatcher monitors the local folder for file changes (triggers immediate sync)
5. NotificationService batches and displays file change notifications

## Architecture

```
limpet/
├── Models/           # Data models and state types
├── Services/         # Business logic and background services
├── Views/            # SwiftUI views
├── Assets.xcassets/  # App icons and images
└── LimpetApp.swift # App entry point and AppDelegate
```

### Models/

| File | Purpose |
|------|---------|
| `SyncProfile.swift` | Profile model with sync paths, remote config, computed file paths |
| `SyncState.swift` | Sync state enum, progress struct, file change model, `SyncLogPatterns` for log parsing |
| `RcloneLogEntry.swift` | JSON models for parsing rclone `--use-json-log` output |
| `Settings.swift` | Global app settings (debug logging toggle) |

### Services/

| File | Purpose |
|------|---------|
| `SyncManager.swift` | Central orchestrator - manages all profile states, log watchers, directory watchers |
| `ProfileStore.swift` | File-backed, file-authoritative profile persistence — reads/writes per-profile `{shortId}.profile.json` files (see "File-Backed Configuration" below); dual-writes the legacy `syncProfiles` UserDefaults blob write-only |
| `SyncSetupService.swift` | Generates sync scripts, launchd plists, manages agent install/uninstall |
| `LogWatcher.swift` | FSEvents + polling hybrid file watcher for rclone log files |
| `LogParser.swift` | Parses plain text and JSON log lines into typed `ParsedLogEvent` |
| `DirectoryWatcher.swift` | FSEvents-based directory monitoring with debouncing |
| `ConfigFileWatcher.swift` | FSEvents watcher on `~/.config/limpet` for external profile/settings edits; self-write suppression via `ConfigSelfWriteRegistry` |
| `ConfigReconciler.swift` | `SyncManager.reconcileAction` (shared launchd install/uninstall/reinstall delta logic) and `SyncManager.applyExternalCreateIfNeeded`/`ExternalCreateOutcome` (create-from-file decision) |
| `AppSettingsFileStore.swift` | Reads/writes `~/.config/limpet/settings.json` — an enumerated safe-key mirror of `LimpetSettings` |
| `ConfigSchemaInstaller.swift` | Copies the committed JSON Schemas into `~/.config/limpet/schema/` at launch |
| `ConfigSelfTest.swift` | `#if DEBUG` host self-test suite (`limpet --self-test`) — round-trip, migration + migration-integrity, reconcile-delta, self-write, isolated-login, external-create, and CLI assertions |
| `NotificationService.swift` | Batched macOS notifications with action support |

### CLI/

| File | Purpose |
|------|---------|
| `LimpetCLI.swift` | Headless `limpet` CLI — `CLICommand`, `parse`/`execute`/`run` (pure over `CLIEnvironment`), `doctorChecks`, `resolveProfile`, `applyProfileAssignment` (bounded `profile set` key set); mutating commands (`profile create`/`show`/`set`/`enable`/`disable`/`delete`, `sync`, `install`/`reinstall`) drive `ProfileStore.writeProfileFile` + `SyncSetupService`; dispatched from `LimpetApp.init` before SwiftUI/`SyncManager` |
| `CLIShimInstaller.swift` | Writes/refreshes the `~/.local/bin/limpet` shim on every launch; marker-guarded so it never clobbers a non-limpet file |

### File-Backed Configuration

`~/.config/limpet/` is the editable, authoritative surface for limpet's
configuration: an external agent or human can hand-edit these files and the
running app applies the change live, without a restart.

| Path | Contents | Notes |
|------|----------|-------|
| `profiles/{shortId}.profile.json` | Full `SyncProfile`, including `isEnabled`, `isMuted` | NEW authoritative file. Written by `ProfileStore.save()` (encodes the whole model, so any new `SyncProfile` field flows in automatically); read by `ProfileStore.load()` (file-authoritative). References `../schema/profile.schema.json` via `$schema`. |
| `profiles/{shortId}.json` | Derived, script-only subset | `SyncSetupService.generateProfileConfig`'s output, rewritten on every install and consumed by the sync shell script. Its key set changes only with the script: L4 added `maxDelete`, which is computed at install time from the remote's rclone.conf section. The app does not read it back; only `limpet doctor` reads it, to warn when `maxDelete` is stale. |
| `settings.json` | Enumerated safe subset of `LimpetSettings` (`debugLoggingEnabled`, `launchAtLogin`) | Written by `AppSettingsFileStore`. |
| `schema/profile.schema.json`, `schema/settings.schema.json` | Committed JSON Schemas | Copied out of the app bundle by `ConfigSchemaInstaller` at every launch. Kept in lockstep with `SyncProfile.CodingKeys` by the fail-closed `scripts/check-schema-in-sync.sh`, run locally and in CI. |

**Live apply, not a struct swap.** A single `ConfigFileWatcher` (FSEvents,
~1s debounce) watches the whole `~/.config/limpet` directory. Every edit —
from the UI's Save button or an external file write — routes through the SAME
reconcile path (`SyncManager.applyExternalProfileEdit` /
`applyExternalSettingsEdit`), which mirrors the reinstall/enable/disable
decision `ProfileDetailView.saveProfile` used to compute inline (now shared
via `SyncManager.reconcileAction`, `ConfigReconciler.swift`). A watcher that
only swapped the in-memory struct would leave a running launchd agent stale
after an external edit — this is why the file, not memory, is authoritative,
and why both paths share one decision function.

**Creation via file, not just editing.** Dropping a NEW `*.profile.json` whose
`id` is UNKNOWN to `ProfileStore` creates that profile — this is no longer
silently ignored. `applyExternalProfileEdit` routes an unknown-but-decodable id
to `SyncManager.applyExternalCreateIfNeeded` (`ConfigReconciler.swift`): the
profile is persisted unless it is refused (see **Refused values** below), and
the launchd agent is installed only when it's `isEnabled && isValid`, so an
agent can stage a profile and flip it on in a second edit. A drop refused for
overlap is moved to `profiles/refused/<stem>.<UTC timestamp>.json`, where no
`*.profile.json` scanner and no file watcher sees it; a drop that fails to
decode (including an F4-refused value) stays where it is and is ignored. A dropped file whose basename isn't the canonical
`{shortId}.profile.json` is rewritten to the canonical name and the original
pruned (the canonical write notes its own hash in `ConfigSelfWriteRegistry`, so
this can never loop). See `ConfigSelfTest`'s AC-C1–AC-C4 for the exact
enabled/disabled/garbage/canonicalize matrix.

**Threat model — this is a conscious acceptance, not an oversight.** Creating and
installing a launchd agent from a dropped file is the deliberate goal: an agent or
a human edits files under `~/.config/limpet` to set limpet up. It does not
widen the trust boundary. Every writer of `~/.config/limpet/profiles/` already
runs as the user, and a same-user process can write a `~/Library/LaunchAgents/*.plist`
and `launchctl load` it directly — limpet adds no privilege the attacker lacked.
The profile files are credential-free by enforcement, not convention: an
`rcloneRemote` that could carry a credential (on-the-fly backend, connection
string) is refused at decode and at every write (see **Refused values** below).
Secrets live elsewhere. s3/b2 remotes created by limpet (`limpet remote add` or
the wizard) keep theirs in the login keychain, service `limpet`, in an item
whose only trusted application is `/usr/bin/security`; every rclone invocation
receives it through `RcloneConfigService.secretEnvironment` as an
`RCLONE_CONFIG_<NAME>_…` variable, and limpet never writes it to rclone.conf,
profile JSON, the sync script, a log or UserDefaults (rclone 1.75.1 at `-vv`
logs such a variable as `secret_access_key=XXX` — measured 2026-09-26;
`--dump auth` was not measured). Any process running as the user
can read that item through `/usr/bin/security` without a prompt — that is the
price of launchd reading it without one (limpet-plan.md L4 F2). Every other
remote's secrets sit in `~/.config/rclone/rclone.conf`, where rclone's
`obscure` is reversible encoding, not encryption. So a malicious drop can
point a profile at an existing remote and schedule an agent, but it gains no
credential that a same-user process could not already read.

**Refused values (limpet-plan.md L4 F4/F6).** An `rcloneRemote` that starts
with `:` (an on-the-fly backend) or contains `,` or `=` (a connection string)
can carry a credential in plain text, so it is refused by the decoder, by every
profile write (`ProfileStore.writeProfileFile`/`add`/`update`), by
`SyncSetupService.install` and by the watcher before every run — a dropped
file carrying one simply does not load. `transfers` outside 1–64 is refused
the same way (and `profile set` refuses a leading zero). Two profiles whose
remote paths on the same remote are equal or nested (`SyncProfile.overlapError`)
may not both sync: a profile that is enabled (or being installed, or running)
is compared only with profiles that are enabled AND have an installed agent,
so a disabled profile never blocks, and the installed one wins over one that
was never installed. The overlap is refused at `profile create`/`profile
set`/`profile enable` (exit 65, nothing written), at file-drop create
(`applyExternalCreateIfNeeded` → `.refusedOverlap`, file moved aside), by
`install`, and by the watcher, which re-reads every profile file before each
run and logs `Refusing to sync: …` into the profile log instead of running.
The app's edit paths (Save, the wizard, enable/disable, an external edit)
check F4 and the overlap BEFORE persisting (`SyncManager.profileChangeRefusal`
/ `applyProfileChange`) and show refusals and install errors in the UI
(`profileErrors`, the detail view's and wizard's error text) instead of only
printing them. A refused external edit of an existing profile file (or one
that is JSON with the profile's id but no longer decodes) is rolled back: the
last accepted profile is written back through the self-write path and the
refused content is copied to `profiles/refused/`, both named in
`profileErrors`. A wizard retry after a failed install updates the profile
the first attempt saved instead of creating a second one.

**Delete limit (limpet-plan.md L4 F6).** For remotes that keep no deleted
versions — s3 `provider = Mega` (MEGA S4) and `Cloudflare` (R2) always, any
other s3 provider unless the profile sets `remoteVersioning: true` — the
derived config carries `maxDelete` (profile field, default 100;
`SyncSetupService.maxDeleteArgument`) and the script adds `--max-delete N`.
rclone 1.75.1 then deletes at most N files and exits 7 (measured); the script
turns that into exit 76 only when the run's own output also contains `Got
fatal error on delete: --max-delete threshold reached`. On 76 the watcher
writes `profiles/{shortId}.delete-limit` and refuses every later run —
including after a respawn, login or reinstall — while staying alive and idle.
`limpet profile clear-delete-limit <name|shortId>` or the menu's red octagon
button removes the marker and sends the watcher SIGUSR1. B2 is not limited
(it hides instead of deleting); `limpet doctor` warns when a B2 bucket has no
`daysFromHidingToDeleting` lifecycle rule. `maxDelete` is decided when the
profile is INSTALLED; after changing a remote's provider (or the profile's
`remoteVersioning`) in rclone.conf directly, run `limpet reinstall
<name|shortId>`. `limpet doctor` warns when the installed value differs from
what the current rclone.conf section gives.

**No unprompted keychain dialogs.** Before any `security` call,
`KeychainSecretStore` asks a lock-status provider (production:
`SecKeychainGetStatus`, unverified that it can never prompt). While the login
keychain is locked nothing reads it: the watcher logs `Keychain locked — open
limpet and click "Allow keychain access"`, starts no rclone and waits for its
next trigger; the menu shows "Allow keychain access", the only action that
may raise the system unlock dialog, which then sends the waiting watchers
SIGUSR1.

**Self-write suppression.** `ConfigSelfWriteRegistry` tracks the content hash
of every file limpet itself writes; `ConfigFileWatcher.shouldReconcile`
drops an FSEvent whose file content hash matches a just-noted self-write, so
the app never reacts to its own writes.

**Launch-at-login isolation.** `settings.json`'s `launchAtLogin` key is
read-write via `SMAppService.register`/`unregister`, applied through
`SettingsReconciler` in a path ISOLATED from every other safe key and from all
profile state — a thrown `SMAppService` error can never corrupt profile
reconcile or another setting.

**Migration.** `MigrationV3BlobToPerProfileFiles` (`MigrationRunner.swift`)
moves the legacy `syncProfiles` UserDefaults blob to per-profile files on
first launch. The blob is retained as a write-only mirror for one release
(rollback safety) — `ProfileStore.load()` only reads it back when NO
per-profile file exists yet, so the mirror can never create a split-brain.
`writeProfileFiles` returns a `WriteResult` and debug-logs an integrity mismatch
when the number of files accounted for on disk is fewer than the profiles in the
source blob, so a silent partial migration is observable.

**Testing.** limpet has no XCTest target (Option A — see `docs/` if this
changes). `ConfigSelfTest.swift` (`#if DEBUG`) runs as `limpet --self-test`
and exits non-zero on any failed assertion; `scripts/check-schema-in-sync.sh`
is the separate, fail-closed schema-drift gate.

### Views/

| File | Purpose |
|------|---------|
| `MenuBarView.swift` | Menu bar dropdown with profile status, recent changes, quick actions |
| `SettingsView.swift` | Settings window with profile list and detail editor |
| `AppSettingsView.swift` | Global app settings — launch at login, debug logging |
| `ProfileListView.swift` | Sidebar list of profiles with add/delete controls |
| `StatusHeaderView.swift` | Header showing current sync state and progress |
| `SyncProgressDetailView.swift` | Detailed per-file transfer progress during sync |
| `RecentChangesView.swift` | List of recently synced files |
| `SetupWizardView.swift` | New-profile creation wizard |

## Agent-Editable Configuration & CLI

`~/.config/limpet/` (see **File-Backed Configuration** above) and the
headless `limpet` CLI together make limpet fully scriptable by an agent —
bootstrapping a new sync, checking health, and introspecting profiles, all
without opening the app UI.

### Bootstrapping a profile by dropping a file

A `*.profile.json` written into `~/.config/limpet/profiles/` with a NEW,
well-formed `id` CREATES that profile (see **Creation via file, not just
editing** above) — an agent no longer has to go through the UI to start a
sync. Validate the file against `~/.config/limpet/schema/profile.schema.json`
before writing it; the schema's top-level `description` documents the
creation behavior. Only FIVE keys are required — `id`, `name`, `rcloneRemote`,
`remotePath`, `localSyncPath` — so an agent can author a minimal profile and
let every other field take its default (the decoder fills `syncDirection=localToRemote`,
`syncIntervalMinutes=5`, `isEnabled=false`, …, all mirrored
from the memberwise-init defaults; an app-written file that emits every key
still round-trips unchanged). A profile is created when the file decodes
(which already refuses the F4 values and a `transfers` outside 1–64), `id` is
a well-formed UUID, and it does not overlap an enabled, installed profile
(then the file is moved to `profiles/refused/`); the launchd agent installs (i.e.
the sync actually starts running) only when the profile is also `isEnabled`
and `isValid` (non-empty `name`/`rcloneRemote`/`remotePath`/`localSyncPath`) —
so an agent can stage a profile disabled, then flip `isEnabled` in a follow-up
edit once it's confident the fields are correct.

### The `limpet` CLI

limpet installs a shim at `~/.local/bin/limpet` on every launch
(`CLIShimInstaller`, called from `AppDelegate.applicationDidFinishLaunching`)
that `exec`s the running app's binary with whatever subcommand you pass —
**`~/.local/bin` must be on `PATH`** for the bare `limpet` command to
resolve (matches the existing `~/.local/bin/limpet-sync.sh` convention). The
shim is idempotent and marker-guarded: it refreshes on every launch (so it
survives a `brew upgrade`/app move) but is never written over a file that
isn't limpet's own.

**Inspect** (read-only):

| Command | Purpose |
|---------|---------|
| `limpet doctor` | Health report: rclone found + version, config schemas installed, per-profile derived-config presence, a stale installed `maxDelete` (warn), launchd agent loaded (enabled profiles), stale lock files, remote reachability (a keychain-backed remote reads its secret without ever prompting), B2 bucket without a `daysFromHidingToDeleting` rule (warn). Exits non-zero iff any check is `[fail]`; `[warn]` never fails the run. |
| `limpet status [name\|shortId]` | One tab-separated line per profile (or a single one): `enabled=`, `agent=loaded\|unloaded\|n/a`, `running=` (lock present), `last=started\|completed\|failed\|none` (from the log tail via the shared `SyncLogPatterns`). |
| `limpet profiles` | List every profile: name, shortId, mode, `enabled=`, `remote=` — no secrets. (`profile list` is an alias.) |
| `limpet profile show <name\|shortId>` | Print one profile's FULL config as pretty, sorted-key JSON — the same shape as its `.profile.json`, so an agent can `show` → edit → `profile create`/`profile set` round-trip. No secrets (credentials live in `rclone.conf` or the login keychain). |
| `limpet logs <name\|shortId> [--follow]` | Print (or `tail -f`) that profile's sync log. |
| `limpet test-remote <name\|shortId>` | Probe one profile's remote with `rclone lsd` under a hard timeout; prints `reachable: <remote>` or the real rclone stderr. |
| `limpet listremotes` | `rclone listremotes`, passthrough. |

**Configure** (mutating — headless-capable, no running app required):

| Command | Purpose |
|---------|---------|
| `limpet profile create --from <file>` / `... create -` | Create a profile from a `.profile.json` file (or stdin `-`). Validates by decoding (a bad file — including an F4-refused remote or `transfers` outside 1–64 — exits `65` with the decode error, the feedback an agent needs); refuses a colliding `id`/`shortId` (`1`) and an overlap with an enabled, installed profile (`65`); writes the authoritative file, then installs the launchd agent iff `isEnabled && isValid` — the SAME persist-then-install rule as the file-watcher create path (`applyExternalCreateIfNeeded`). |
| `limpet profile enable <name\|shortId>` | Set `isEnabled=true`, rewrite the file, install the agent. |
| `limpet profile disable <name\|shortId>` | Set `isEnabled=false`, rewrite the file, uninstall the agent. |
| `limpet profile set <name\|shortId> <key> <value> [<key> <value> …]` | Edit fields on an existing profile from a BOUNDED key set (mirrors `SyncProfile.CodingKeys` minus `id`/`isEnabled`; positional `key value` pairs), rewrite the authoritative `.profile.json`, then drive the launchd delta `SyncManager.reconcileAction` dictates (reinstall as needed). Validates ALL assignments against a copy first — an unknown key or invalid value exits `65` and writes nothing. Use `enable`/`disable` for `isEnabled`. |
| `limpet profile delete <name\|shortId>` | Uninstall the agent and remove the `.profile.json`. |
| `limpet profile clear-delete-limit <name\|shortId>` | Remove the persistent `{shortId}.delete-limit` marker a `--max-delete` trip left (exit 76), then send the watcher SIGUSR1. Check the remote first: up to `maxDelete` files were already deleted in the run that tripped. |
| `limpet install <name\|shortId>` | Install an already-enabled profile's launchd agent (idempotent; runs `SyncSetupService.install`). Complements `profile enable`, which early-returns without installing when the profile is ALREADY enabled — so `install` re-creates an agent that went missing. Refuses a disabled or incomplete profile. Never flips `isEnabled`. |
| `limpet reinstall <name\|shortId>` | Regenerate script+plist and reinstall the agent (uninstall → install), i.e. the settings-save reinstall path. Works for any sync mode. Refuses a disabled profile. |
| `limpet remote add <name> --type s3\|b2 --access-key-id <id> [--provider <p>] [--endpoint <https url>] [--region <r>]` | Create a keychain-backed remote through `RcloneConfigService.addKeychainRemote`, the same function the wizard uses. The secret is read from stdin — a no-echo prompt on a terminal, otherwise one line from the pipe — never from an argument. Writes the non-secret section plus `limpet_keychain = true` to rclone.conf (appended; nothing else rewritten) and stores the secret with `/usr/bin/security -i` (`add-generic-password -s limpet -a <name> -T /usr/bin/security`, secret hex-encoded on stdin). Names are `[A-Za-z0-9_]+` and may not collide case-insensitively with any rclone.conf section; endpoints must be https; `--provider Mega --region <r>` derives `s3.<r>.megas4.com`. |

**Operate:**

| Command | Purpose |
|---------|---------|
| `limpet sync <name\|shortId>` | Run one sync now and BLOCK until it finishes, returning the script's exit code — exactly what the app's `triggerManualSync` runs (`bash <sharedScript> <configPath>`), lock-file-guarded against a concurrent scheduled run. |

`<name|shortId>` resolution tries an exact `shortId` match first, then a
case-insensitive `name` match; an unmatched (or ambiguous) target exits
non-zero with a greppable `error: no profile matches "<target>"`.

**The mutating commands operate through the file-backed config, so they work
whether or not the menu-bar app is running:** they write the authoritative
`.profile.json` and drive `SyncSetupService` install/uninstall directly (the
launchd delta chosen by the shared `SyncManager.reconcileAction`). When the app
IS running, its `ConfigFileWatcher` also sees the write and reconciles — the two
converge on identical files and one loaded agent, so running both is redundant,
not conflicting. Profile files stay credential-free (secrets live in
`~/.config/rclone/rclone.conf` or, for keychain-backed remotes, the login
keychain), so no profile file the CLI writes carries a credential.

**Dispatch and safety.** `LimpetCLI.dispatch` is checked at the very top of
`LimpetApp.init` — before `--self-test`, before `MigrationRunner`,
or `SyncManager()` — and `exit()`s the process
before any of that runs. A CLI invocation NEVER opens a window and NEVER
starts a background watcher or timer; `dispatch` returns `nil` (falling
through to the normal app launch) for a bare launch and for `-`-prefixed args
(`--self-test`, macOS's `-psn_…`), except `-h`/`--help`.

**Pure core / impure shell.** `LimpetCLI.parse`/`execute`/`run`/`doctorChecks`
are pure over an injected `CLIEnvironment` (rclone invocation, profile reads +
writes, install/uninstall, sync-script run, `launchctl`, stdio) — `ConfigSelfTest`'s
AC-CLI1–AC-CLI6 drive the full dispatch/doctor/resolution/shim-install AND the
create/enable/disable/delete/sync side-effect routing against spies, with no real
process/filesystem/launchd touched. Every real `rclone` invocation runs through a
hard-timeout watchdog (mirrors `RcloneLocator`'s login-shell probe), since
SMB/WebDAV remotes can hang past their own timeouts.

**Privacy.** The CLI's output goes to the invoking terminal only —
`test-remote`/`profiles` printing a remote name to stdout is fine, and nothing
from a CLI invocation is ever sent anywhere else.

## Data Flow

### Sync Monitoring Pipeline
```
launchd triggers sync script
        ↓
Script writes to log file (~/.local/log/limpet-sync-{shortId}.log)
        ↓
LogWatcher detects file changes (FSEvents + polling fallback)
        ↓
LogParser parses lines → ParsedLogEvent (syncStarted, stats, fileChange, syncCompleted, etc.)
        ↓
SyncManager updates state dictionaries (profileStates, profileProgress, etc.)
        ↓
SwiftUI views react to @Published changes
```

### File Change Detection Pipeline
```
User modifies file in local sync folder
        ↓
DirectoryWatcher receives FSEvents callback
        ↓
Filters out metadata files (.DS_Store, ._*, .tmp, etc.)
        ↓
Debounces rapid changes (15 second window)
        ↓
SyncManager.triggerManualSync() called
        ↓
Sync script executed → log written → monitoring pipeline picks up
```

## Key Design Patterns

### Multi-Profile State Management

SyncManager maintains parallel dictionaries keyed by profile UUID:

```swift
@Published private(set) var profileStates: [UUID: SyncState] = [:]
@Published private(set) var profileProgress: [UUID: SyncProgress] = [:]
@Published private(set) var profileErrors: [UUID: String] = [:]
private var logWatchers: [UUID: LogWatcher] = [:]
private var directoryWatchers: [UUID: DirectoryWatcher] = [:]
```

This allows independent state tracking per profile while maintaining a single source of truth.

### @MainActor Thread Safety

SyncManager is marked `@MainActor` to ensure all state mutations happen on the main thread:

```swift
@MainActor
final class SyncManager: ObservableObject {
    // All @Published properties are safely mutated on main thread
}
```

Background work (process execution, file I/O) happens on dispatch queues with results marshaled back to main actor.

### Hybrid File Monitoring

LogWatcher uses FSEvents as primary mechanism with polling fallback:

1. **FSEvents**: Low-latency file change detection via `DispatchSource.makeFileSystemObjectSource`
2. **Polling fallback**: Timer-based check every 2.5-5 seconds catches missed events
3. **Inode tracking**: Detects file replacement (atomic writes) and reopens file handle

### Centralized Log Pattern Matching

`SyncLogPatterns` enum in `SyncState.swift` provides single source of truth for log parsing:

```swift
SyncLogPatterns.isSyncStarted(message)
SyncLogPatterns.isSyncCompleted(message)
SyncLogPatterns.isSyncFailed(message)
SyncLogPatterns.extractExitCode(from: message)
SyncLogPatterns.cleanErrorMessage(message)
```

Used by both `LogParser` and `SyncManager` for consistent behavior.

## Critical Rules

### 1. Threading & Main Thread Safety
**NEVER access @State, @Binding, @Published, or any UI-related properties from a background thread.**

When dispatching work to background threads:
1. Capture ALL needed values from state properties BEFORE dispatching
2. Use explicit `self.` when updating state from within closures
3. ALWAYS update UI state on the main thread via `DispatchQueue.main.async`

```swift
// CORRECT
func doBackgroundWork() {
    // Capture values on main thread FIRST
    let capturedValue = self.someStateProperty
    let capturedPath = self.localSyncPath

    DispatchQueue.global(qos: .userInitiated).async {
        // Use captured values, not state properties
        let result = process(capturedPath)

        // Update UI on main thread
        DispatchQueue.main.async {
            self.isLoading = false
            self.result = result
        }
    }
}

// WRONG - will cause freezing/crashes
func doBackgroundWork() {
    DispatchQueue.global(qos: .userInitiated).async {
        let path = self.localSyncPath  // BAD: accessing @State from background
        // ...
        isLoading = false  // BAD: updating @State from background
    }
}
```

### 2. Process Execution
- Always run external processes (rclone, shell commands) on background threads
- Use `Process` with pipes for stdout/stderr
- Set `readabilityHandler` for real-time output streaming
- Remember to nil out handlers after process completes

### 3. SwiftUI Best Practices
- Use `.controlSize(.small)` or `.controlSize(.mini)` for inline spinners in buttons
- Avoid `scaleEffect()` for sizing ProgressView - it causes layout issues
- Keep views focused and extract complex logic into helper functions
- Use `@State` for view-local state, `@ObservedObject` for shared state

### 4. File Operations
- Use FileManager for local file operations
- Handle errors gracefully with user-friendly messages
- Create directories with `withIntermediateDirectories: true`
- Always check if files/directories exist before operations

### 5. Error Handling
- Provide actionable error messages to users
- Log detailed errors for debugging
- Offer recovery actions when possible (e.g., "Retry Sync" button)
- **Clear cached errors** when config changes or fix operations start:
  ```swift
  syncManager.clearError(for: profile.id)
  ```

### 6. State Consistency
- When updating profile configuration, clear related cached state:
  ```swift
  // Profile paths changed - clear any stale errors
  syncManager.clearError(for: profile.id)
  // Restart watchers with new paths
  syncManager.refreshSettings()
  ```
- Use `SyncLogPatterns` for all log message categorization to maintain consistency

## Debugging

### Enable Debug Logging
In Settings, toggle "Debug Logging" to enable verbose output. Debug messages are written via `LimpetSettings.debugLog()` and appear in the sync log files.

### Inspect launchd Agents
```bash
# List limpet agents
launchctl list | grep limpet

# Check agent status
launchctl print gui/$(id -u)/com.nanako.limpet.watch.{shortId}

# View agent definition
cat ~/Library/LaunchAgents/com.nanako.limpet.watch.*.plist
```

### View Sync Logs
```bash
# Tail live log
tail -f ~/.local/log/limpet-sync-{shortId}.log

# View profile config
cat ~/.config/limpet/profiles/{shortId}.json
```

### Lock Files
If sync appears stuck, check for stale lock files:
```bash
ls -la /tmp/limpet-sync-*.lock
```

The app automatically cleans stale locks on startup.

## Build & Test

```bash
# Build the project
xcodebuild -scheme limpet -destination 'platform=macOS' build

# Build with verbose output
xcodebuild -scheme limpet -destination 'platform=macOS' build 2>&1 | xcbeautify

# Run the app
open ~/Library/Developer/Xcode/DerivedData/limpet-*/Build/Products/Debug/limpet.app
```

## Key Files Reference

| File | Purpose |
|------|---------|
| `SyncProfile.swift` | Profile model with computed paths (configPath, logPath, plistPath, etc.) |
| `SyncSetupService.swift` | Script generation, launchd management, profile installation |
| `SyncManager.swift` | Central state manager, LogWatcher/DirectoryWatcher coordination |
| `SettingsView.swift` | Main settings UI with profile editing |
| `ProfileStore.swift` | File-backed profile persistence — authoritative `{shortId}.profile.json` per profile, write-only blob mirror (see "File-Backed Configuration") |
| `ConfigFileWatcher.swift` | Live-apply watcher for `~/.config/limpet` (profiles + settings); routes an unknown-id `.profile.json` to create-via-file |
| `LimpetCLI.swift` | Headless `limpet` CLI: inspect (`doctor`/`status`/`profiles`/`profile show`/`logs`/`test-remote`/`listremotes`), configure (`profile create`/`set`/`enable`/`disable`/`delete`, `install`/`reinstall`), operate (`sync`); dispatched from `LimpetApp.init` (see "Agent-Editable Configuration & CLI") |
| `CLIShimInstaller.swift` | Installs the `~/.local/bin/limpet` shim (`~/.local/bin` must be on `PATH`) |
| `SyncLogPatterns` | Centralized log message pattern matching (includes `isOutOfSyncError`) |
| `Settings.swift` | Global settings (debug logging toggle) |

## Generated Files (per profile)

| Path | Purpose |
|------|---------|
| `~/.config/limpet/profiles/{shortId}.json` | Profile config |
| `~/.config/limpet/profiles/{shortId}-exclude.txt` | Exclude filter (user-editable) |
| `~/.local/bin/limpet-sync.sh` | Shared sync script (all profiles) |
| `~/Library/LaunchAgents/com.nanako.limpet.watch.{shortId}.plist` | launchd schedule |
| `~/.local/log/limpet-sync-{shortId}.log` | Sync logs |
| `/tmp/limpet-sync-{shortId}.lock` | Lock file (prevents concurrent syncs) |
