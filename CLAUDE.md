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
| `LogWatcher.swift` | FSEvents + polling hybrid log tailer; every stored property is owned by its serial `pollQueue`, batches reach the main queue once per second (see "GUI responsiveness, log rotation and the stalled-sync watchdog") |
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
| `DirtySet.swift` | limpet-plan.md L9.2 S1, not wired yet: `ExcludeOracle` (the profile's exclude rules as rclone compiled them via `--dump filters`, walked in rclone's first-match order) and `DirtySet` (FSEvents paths coalesced by path: quiet 10 s / max 300 s readiness, collapse > 200 children into a subtree entry, > 5,000 entries or a gap flag → full run required, per-object failure give-up after 3, checkpoint from each entry's first event id). Pure; self-tests AC-L92-S1a–e |

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
decode (including an F4-refused value) stays where it is and is ignored until
the next full `ProfileStore.save()` (a profile delete), whose orphan prune
moves it to `profiles/refused/` instead of deleting it — the prune removes
only files that decode. A dropped file whose basename isn't the canonical
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
versions — s3 `provider = Mega` (MEGA S4) and `Cloudflare` (R2), in any case, always, any
other s3 provider unless the profile sets `remoteVersioning: true` — the
derived config carries `maxDelete` (profile field, default 100;
`SyncSetupService.maxDeleteArgument`) and the script adds `--max-delete N`.
rclone 1.75.1 then deletes at most N files and exits 7 (measured); the script
turns that into exit 76 only when the run's own output also contains the
substring `--max-delete threshold reached` — broadened in limpet-plan.md L6.2
from the delete-only phrasing `Got fatal error on delete: --max-delete
threshold reached`, because a trash-enabled profile's OVERWRITES also count
toward `--max-delete` and trip a different message with no "Got fatal error
on delete" line at all (`Cancelling sync due to fatal error: --max-delete
threshold reached`, measured 2026-09-28 with `--disable Move`, the S4-path
fallback — see **Trash** below). On 76 the watcher
writes `profiles/{shortId}.delete-limit` and refuses every later run —
including after a respawn, login or reinstall — while staying alive and idle.
`limpet profile clear-delete-limit <name|shortId>` or the menu's red octagon
button removes the marker and sends the watcher SIGUSR1. A clear is not a
bypass: the next run still carries `--max-delete N`, so with more than N
deletions pending it deletes N and trips again (measured live on S4
2026-09-26 with N=2: draining the backlog after a trip took two clears).
This is intended — each clear releases one batch. B2 is not limited
(it hides instead of deleting); `limpet doctor` warns when a B2 bucket has no
`daysFromHidingToDeleting` lifecycle rule. `maxDelete` is decided when the
profile is INSTALLED; after changing a remote's provider (or the profile's
`remoteVersioning`) in rclone.conf directly, run `limpet reinstall
<name|shortId>`. `limpet doctor` warns when the installed value differs from
what the current rclone.conf section gives.

**Trash — recoverable deletes and overwrites (limpet-plan.md L6.2, with fixes
from an internal code review of the first version, commit 87bbf67).** For a
`localToRemote` profile whose remote keeps no deleted versions (the same test
`maxDeleteArgument` uses, factored into
`SyncSetupService.remoteKeepsNoDeletedVersions`), a positive `trashDays`
profile field (plain default 14; 0 disables it; 0–365) turns on a recycle bin.
The trash root's PATH FORMULA — `<remote>:<parent>/.limpet-trash/<leaf>` from
`remotePath`, so a profile whose `remotePath` has no parent (syncing straight
into a bucket root) can have no trash root at all (there is nowhere to put a
`.limpet-trash` SIBLING without it becoming part of what gets
synced/deleted) — lives in `SyncSetupService.trashRootPath(for:)`, which
ignores `trashDays`/`syncDirection`/`remoteVersioning` on purpose:
`trashRootPath` is what `limpet trash list`/`trash restore` call, so they keep
working to inspect and restore OLD trash after the profile's direction or
versioning changed, or after trash was switched off (`trashDays` set to 0) —
**a trash whose profile no longer actively uses it is never purged
automatically; deleting it is on the user.** `SyncSetupService.trashRoot(for:
remoteSection:)` layers the "is trash currently ACTIVE" checks
(`syncDirection == .localToRemote`, `trashDays > 0`,
`remoteKeepsNoDeletedVersions`) on top of `trashRootPath` and is what
`generateProfileConfig` calls to write `trashRoot`/`trashDays` into the
derived config the script and `SyncManager` read — the sync and the purge use
`trashRoot`; `trash list`/`trash restore` use `trashRootPath` directly.

The generated script adds `--backup-dir "<root>/$(date +%F)" --suffix
"-$(date +%H%M%S)" --suffix-keep-extension` when a root is present (both
dates captured once per run) — every version is kept, not one per day:
measured 2026-09-28 with `--suffix-keep-extension`, `a.tar.gz` →
`a-100003.tar.gz` (extension split at the FIRST dot), `x.min.js` →
`x.min-100003.js` (split at the LAST dot), `Makefile` → `Makefile-100003`, and
a symlink `l.txt` → symlink `l-100003.txt` (LOCAL backend; a remote without
native symlink support instead stores the link as a `.rclonelink` CONTENT
object carrying the target as text — see restore, below) — rclone's own
extension-split rule differs by name, which is why restore tries every `.`
boundary instead of re-deriving it. On the **S4 path** (no server-side Move,
measured with `--disable Move`): an overwrite logs `Copied (server-side copy)
to: <backup>` + `Deleted` (both for the ORIGINAL object, before the new
content uploads); a real delete logs the same `Copied (server-side copy) to:
<backup>` + `Deleted` PLUS `Moved into backup dir`. `Copied (server-side
copy) to: …` is unconditionally never a reportable change (a normal
same-remote copy never gets a " to:" suffix). `Moved (server-side) to: …` IS
restored to `.renamed` — a profile's `additionalRcloneFlags` can set
`--track-renames`, so this line can be a genuine rename, and limpet does not
forbid that flag. Both this line and the bare `Deleted` line are flagged
`FileChange.mayBeTrashArtifact` by `SyncLogPatterns.mayBeTrashArtifact(_:)`,
because BOTH are ambiguous — measured for reference on a Move-capable
backend, a backup-dir move ALSO logs `Moved (server-side) to: …` for both an
overwrite's and a delete's backup step, textually identical to a real
`--track-renames` rename — while `Moved into backup dir` (the trash
mechanism's own, unambiguous delete report) and `Renamed from "..."` (the
OTHER `--track-renames` message, never produced by any backup-dir path) are
never flagged. `SyncManager.shouldReportFileChange(_:hasTrashRoot:)` drops a
change only when `mayBeTrashArtifact && hasTrashRoot`, so a real delete shows
exactly once (via `Moved into backup dir`, never suppressed) and an S4-path
overwrite never shows as a deletion (its bare `Deleted` line IS suppressed) —
a trash-enabled profile also cannot distinguish a genuine `--track-renames`
rename from a Move-capable backend's backup move, and suppresses both, same
as the `Deleted` ambiguity; a profile without trash is unaffected either way,
since `hasTrashRoot` gates the whole filter off. This fixed a P1 in the first
version of this feature: it keyed the filter off `operation == .deleted`
alone, which ALSO matched `Moved into backup dir` (mapped to the same
`.deleted` case as the ambiguous bare `Deleted`), so every delete on a trash
profile — real ones included — was silently dropped and never shown at all.
`SyncManager` caches `hasTrashRoot` per profile in `trashRootCache`, populated
only by `startWatching` (at launch, and whenever a profile's watching
(re)starts after a reinstall-worthy field change) — the per-file-change
lookup is a dictionary read, and even that is skipped entirely unless the
change is flagged `mayBeTrashArtifact` in the first place. Because overwrites
count toward `--max-delete` too (see the broadened exit-76 detection above),
a profile whose trash root is set gets `maxDelete` bumped to 5000 in the
derived config when its STORED value is still the default 100
(`maxDeleteArgument`; the file on disk is never rewritten) — the limit is now
a "stop and look" alarm for a mass change, not the only line of defense,
since the trash makes deletes recoverable.

Before the sync, the script purges trash folders older than `trashDays`, once
per LOCAL day (a `<shortId>.trash-purged` stamp file beside the profile's
derived config), skipped when the run is ANY form of a dry run — the bare
`--dry-run`, `-n`, `--dry-run=true`, or `--dry-run=<anything but exactly
"false">` (rclone's own bool-flag parsing treats a non-"false" value as
true). `rclone lsf --dirs-only <root>` (with `$NO_CHECK_CERT` if the remote
needs it — the SAME flag the sync itself adds — but NEVER the profile's own
`additionalRcloneFlags`: a purge must never be shaped by a profile's filters
or extra flags) lists candidate folders; only an entry matching
`^[0-9]{4}-[0-9]{2}-[0-9]{2}/$` EXACTLY and older (by string comparison) than
`date -v-<trashDays>d +%F` is purged with `rclone purge <root>/<entry>`
(`$NO_CHECK_CERT` again, never `additionalRcloneFlags`) — nothing else is
ever purged. If `lsf` itself fails (non-zero exit), the script logs one line
and does NOT write the stamp, so a later run the same day (the periodic
safety sync, a manual "sync now", the next login) retries instead of waiting
until tomorrow; a `purge` failure for one entry logs one line without failing
the sync or blocking the rest of the loop. The script accepts `trashDays` only
as exactly 0-365 (exit 64 otherwise, before rclone), and if `date -v-<N>d`
still yields no cutoff it logs `Trash purge skipped: could not compute the
cutoff date` and skips the purge without writing the stamp. Two profiles
sharing a parent get disjoint roots (`.limpet-trash/Datarget`, `.limpet-trash/side-project`), and
a profile's own sync never lists its trash (it sits outside `remotePath`).

`limpet trash list <name|shortId> [--date YYYY-MM-DD]` lists a profile's
trashed files (`rclone lsf -R`, restricted to one date's folder when `--date`
is given; 600s timeout — a whole trash root's listing can be large). `limpet
trash restore <name|shortId> <relative-path> [--date D] [--force]` restores
the newest version (or the newest at one `--date`): before any rclone call it
refuses (exit 65) an empty/absolute `relative-path` or one with an
empty/`.`/`..` component, and a `--date` not matching
`^[0-9]{4}-[0-9]{2}-[0-9]{2}$`. Because that check is syntax only, it also
refuses (exit 65, before any rclone call) a path whose destination DIRECTORY
resolves outside `localSyncPath` through a symlink
(`LimpetCLI.trashRestoreContainmentError`: realpath(3) of the nearest
existing ancestor of the destination's parent, compared with the resolved
`localSyncPath`; an existing ancestor that cannot be resolved, i.e. a dangling
symlink, is refused too). It refuses (without calling rclone) to overwrite an
existing local entry unless `--force` is given; existence is checked with
lstat (`CLIEnvironment.itemExists`), so a symlink at the destination,
dangling or not, counts as existing and is never followed: with `--force`
the link itself is replaced. Matching
(`LimpetCLI.newestTrashMatch`/`trashSuffixMatch`) tries EVERY `.` boundary of
the original name (plus its end) rather than re-deriving rclone's own
extension split, and also tries `<name>.rclonelink` for a symlink on a remote
without native symlink support; ties are broken by the newest date, then the
highest 6-digit suffix. A `.rclonelink` match restores as a REAL local
symlink, not a regular file containing the target as text: `rclone copyto`
alone would write the object's literal bytes; measured 2026-09-28, giving the
destination as an rclone "connection string" override —
`":local,links:<path>.rclonelink"` (LOCAL side only; the source is read as a
plain object, `--links` never applied there) — makes the local backend strip
the suffix and create a real symlink at `<path>` pointing at the object's
text content. A plain (non-symlink) restore uses the same destination form
without the suffix, which measured as an ordinary file copy, so one
destination shape covers both. The restore always copies to a temp name in
`localSyncPath` (`<target>.limpet-restore-tmp`) and renames into place only
on success (no effective timeout — a restored file can be arbitrarily large),
so a failed copy never leaves a partial file at the real destination. The
rename (`CLIEnvironment.moveReplacing`) replaces an existing entry with
rename(2), atomically, so a failed `--force` move leaves the existing file
untouched; never remove-then-move (which lost both) and never
`FileManager.replaceItemAt` (measured 2026-09-28: throws whenever either side
is a symlink, and replaced a non-empty directory with a file). Restore
uses the same keychain secret environment as a sync (`env.runRclone`, which
injects it via `RcloneConfigService`).

**Source-missing GUI state (limpet-plan.md L5.0).** When a profile's local
source directory disappears, the watcher (`SyncWatchDaemon`) and the generated
sync script both write `Source missing: <path>` into the profile log —
the ONLY place the GUI ever learns about a sync outcome, since the app never
runs syncs itself. `SyncLogPatterns.isSourceMissing` matches that line (both
writers produce the identical text) → `LogParser` emits
`ParsedLogEvent.sourceMissing(path)` → `SyncManager.processLogEvent` sets
`profileStates[id] = .error("Source missing: <path>")`, shown as a red
`exclamationmark.triangle.fill` with "Error: Source missing: <path>". No
notification is sent for this state (menu only). It clears through the
existing sync pipeline, not a special case: the watcher's 30s recheck runs a
sync once the source returns, whose `Starting sync` line sets `.syncing`
unconditionally (overwriting any prior state, including this error) and whose
completion sets `.idle`. `SyncManager.reduceProfileState` is the pure
transition function for these three cases, extracted so it can be driven
without a full `SyncManager`.

**A (re)started watcher checks the lock, not stale state (limpet-plan.md
L6.1 change C).** `SyncManager.startWatching(profile:)` runs whenever a
profile's `LogWatcher` (re)starts — at launch, and again whenever
`startWatchingAllProfiles` rebuilds one after `.reinstall` tore it down.
Before this it defaulted the new state to `.idle` unless
`profileStates[profile.id]` already read `.syncing` — a value only
`detectAndResumeRunningSyncs` sets, and only once, at app launch — so a
sync already in flight when watching (re)starts later showed Idle until
the run happened to log a line (measured live 2026-09-27). `startWatching`
now runs the SAME lock-file check (`detectRunningSyncPID`) launch does: if a
sync currently holds the profile's lock, it sets `.syncing` and starts the
existing completion poller, guarded by `monitoringExternalSyncs` so an
already-detected, already-polled sync never gets a second poller.
Separately, the sync script's lock-held skip line (`.syncAlreadyRunning`,
previously a silent `break` in `processLogEvent`) now routes through
`SyncManager.reduceProfileState` like every other state transition, so a
lock the script itself observed also shows as `.syncing` in the menu.

**The watcher forwards SIGTERM/SIGINT to the sync child's process group
(limpet-plan.md L6.1 change B).** `SyncWatchDaemon.run` originally handled
only `SIGUSR1` ("sync now"); `launchctl unload` sends `SIGTERM`, and with no
handler that took the default action (terminate the watcher). The sync
child is spawned with Foundation `Process`, which makes it its OWN
process-group leader — measured live: watcher pgid 24762, script/rclone/tee
pgid 61291, a different group — so killing only the watcher left the
script, rclone and tee running under launchd (reparented to pid 1), still
holding the profile's lock, while the very next watcher (started right
after by `KeepAlive`/the CLI's reinstall sequence) logged `Sync already
running … skipping` every ~10s until the orphan finished on its own. `run`
now attaches a `SIGTERM`/`SIGINT` `DispatchSource` (`SIG_IGN` first, exactly
like the existing `SIGUSR1` pattern) whose handler sends `SIGTERM` to the
CHILD'S PROCESS GROUP (`SyncWatchDaemon.terminateChildProcessGroup(pid:)`,
`killpg(childPid, SIGTERM)`) and calls `exit(0)` immediately — no waiting, so
`launchctl unload`/`load` timing is unchanged. This CAN interrupt rclone
mid-delete (unmeasured, and not assumed otherwise — a SIGTERM has no reason
to respect rclone's transfer/delete phase boundary, and a profile's
`additionalRcloneFlags` can set `--delete-during`, interleaving deletes with
transfers). That is still safe by construction, not by measurement: this is
a one-way sync, so `rclone sync` only ever deletes a copy on the
NON-authoritative side that is already absent from the authoritative side —
a delete interrupted partway through never removes anything the user still
has anywhere, and the next watcher's catch-up sync re-evaluates the same
diff and completes whatever didn't finish. The running child's PID and
spawn state cross from the background queue that spawns it
(`runChildProcess`) to the main-queue signal handler through a small
`NSLock`-guarded state machine (`RunningChildState`) with a `.spawning` case
specifically for the SIGTERM-between-spawn-and-PID-known race (code-review
finding 7): if termination is requested while `.spawning`, the signal
handler does not exit — `spawned(pid:)` does, the moment it actually has a
PID to kill.

**`SyncSetupService.install` surfaces a `launchctl load` failure (limpet-plan.md
L6.1 change B).** `install` previously discarded `launchctl load`'s exit
status (`_ = runCommand(...)`), so a load failure (a malformed plist, a
stale label collision) silently left a profile with no running watcher.
`install` now takes an injectable `loadCommand` closure (default:
`runLaunchctlLoad`, `runCommand("/bin/launchctl", ["load", plistPath])`
factored out for this seam and for self-test injection) and throws
`SetupError.launchAgentLoadFailed(exitCode:output:)` on a non-zero exit —
callers already surface a thrown install error (CLI stderr via
`installProfile`, the app's `profileErrors` via
`applyProfileChange`/`applyExternalProfileEdit`), so no caller needed a
change.

**Recent Changes only reports rclone's own success lines (limpet-plan.md
L5.1 finding 3).** `RcloneLogEntry.fileChange` (`RcloneLogEntry.swift`) is the
only seam a `--use-json-log` line becomes a `FileChange` shown in the menu's
Recent Changes list. It requires `level == "info"` and matches only rclone's
own success message text (verified live against rclone 1.75.1, 2026-09-26,
`rclone sync --use-json-log -v` between local temp dirs): any other
`Copied (…)` — `Copied (new)`, `Copied (server-side copy)` (a 300 MiB
local→local new file) — -> `.copied`, matched with `contains` so a prefixed
variant is not dropped; `Copied (replaced existing)` and `Updated modification time in
destination` -> `.updated`; `Deleted` -> `.deleted`; `Moved (server-side)
to: ...` and `Renamed from "..."` (both lines are emitted per rename under
`--track-renames`) -> `.renamed`. An `error`-level line mentioning "delete" or
"copy" with an `object` set — e.g. rclone's `Got fatal error on delete:
--max-delete threshold reached` (the same line that maps to exit 76, see
**Delete limit** above) or a `Failed to copy: ...` failure — no longer yields
a `FileChange`; previously any line containing those substrings did, so a
delete-limit trip showed the refused files as "Deleted" in the UI while they
were still on the remote.

**Exit-code text (limpet-plan.md L5.1 finding 2).** `SyncManager.exitCodeErrorText`
is the single pure mapping from a `syncFailed` exit code to the text shown in
`profileStates[id] = .error(...)` and, when no more specific error message is
available, in the failure notification: 76 (the delete-limit trip, see
**Delete limit** above) -> "Delete limit reached"; every other code keeps
the prior generic "Exit code N"; 79 (the stalled-sync watchdog's code, see
**GUI responsiveness, log rotation and the stalled-sync watchdog** below) ->
"Sync stalled". A refusal (exit 64) is not mapped: the
script exits before writing "Sync failed with exit code", so the GUI never
sees that code — showing a refusal in the menu is open work.

**Source changed mid-upload (limpet-plan.md L9.1).** A localToRemote run whose
only error lines are rclone's `corrupted on transfer` / `source file is being
updated` (a file appended while it uploaded; rclone's follow-up `Attempt N/M
failed` and `not deleting ... IO errors` lines are ignored) exits 77 and logs
`Source changed during upload (N/20); retrying in 30 s`. rclone 1.75.1
exits 1 for the first and 6 for the second, so both codes qualify. The count lives in
`profiles/{shortId}.source-changed` (removed by any other outcome); from the 20th
in a row on, the run keeps rclone's code (1 or 6) and the counter is not reset, so
a genuine persistent corruption stays red. The
watcher reruns once 30 s after a 77 (`SyncWatchScheduler.sourceChangedExitCode`).
The GUI treats 77 as idle on both completion paths (`processLogEvent`'s
`.syncFailed` clears `profileErrors`; `readLastErrorFromLog` returns nil), with
no notification. Self-tests AC-L91-A/B/C/C2.

**GUI responsiveness, log rotation and the stalled-sync watchdog
(limpet-plan.md L6.3, plan v1-v3).** Three defects found by reading the code
(none is claimed to be THE cause of the multi-day menu freeze; the decisive
check is the user running the app for 3+ days, plan A1) and one watchdog.

*`LogWatcher` threading contract.* `pollQueue` OWNS every stored property: file
handle, dispatch source, poll and flush timers, read offset, partial-line
buffer, inode and the pending batch. `startWatching`/`stopWatching` hop onto it
with `sync` (a caller on main returns only after setup/teardown is complete);
`setActivelySyncing` uses `async`; `deinit` tears down with
`pollQueue.sync` unless already on the queue (`DispatchSpecificKey`). Reads, the
poll tick, `reopenFile` and the flush all run on that queue only, and the
source's cancel handler (queued on the same queue) closes the handle it
captured, so a stop never closes a handle mid-read. Lines are accumulated and
delivered at most once per second (flush timer on `pollQueue`); a line that
matches started, completed, failed or the lock-skip pattern
(`LogWatcher.isTransitionLine`) flushes at once. Each batch is posted with
`DispatchQueue.main.async` from `pollQueue` — one FIFO channel, never a `Task`
per batch — so batches apply in order; `LogWatcherDelegate` is therefore always
called on the main queue. `SyncManager.processLogLinesForWatcher` parses the
batch, `SyncManager.coalesceLogEvents` drops every `.stats` event except the
last (each only overwrites `profileProgress`; the others keep their order), and
`updateAggregateState` runs once per batch (`processLogEvent(updateAggregate:)`).
Reads keep their unterminated tail as BYTES (`pendingBytes`) and decode only up
to the last newline, so a read ending inside a multibyte character cannot drop
the line (AC-L63-9). Before parsing, `SyncManager.dropSupersededStatsLines`
discards every raw rclone JSON stats line but the last in the batch (a line
starting `{` containing `"stats":{`, checked against captured rclone 1.75.1
output); `LogParser` compiles its regexes once. The startup replay of the last
50 lines is gone (it was already inert: it ran
before `logWatchers[id]` was set); the initial state comes from the lock check
in `startWatching(profile:)`. The watcher NEVER creates or truncates the log:
a missing path keeps the poll timer running and keeps no handle; when the file
appears it is opened at offset 0. An existing file at start is tailed from its
end. `reopenFile` is idempotent (it re-reads the inode and returns when it is
already `lastKnownInode`), so the poll tick and the source event cannot both
reset the offset. Only `stopWatching` (and `start()`, which begins with a stop)
stops polling outright; `setActivelySyncing` replaces the poll timer with one
of the other interval, so a missing path keeps being polled until a stop.

*Bounded per-run memory.* `SyncManager.currentSyncChanges` is a per-profile
`Int` (its only reader was the count). `NotificationService` keeps at most the
first 50 pending changes plus a true total (`pendingChangeCounts`, so "N files
synced" stays right) and pushes the batch timer back at most once per second
instead of once per change; the batch can therefore fire up to a second sooner
than 2 s after the last change.

*Log rotation (generated script).* After the lock is held and before the trash
purge, a log over 20 MB (`stat -f %z`) is moved with `mv -f "$LOG_FILE"
"$LOG_FILE.1" && : >> "$LOG_FILE"` (one old generation; the new file exists at
once, so a watcher takes the inode-change path). Worst case on disk: 2 x 20 MB
plus one run's output. `limpet logs` and `limpet status` read only the current
file, so `status` right after a rotation reports `last=` from the new file.

*Purge stats lines.* The trash purge now runs `rclone lsf` and `rclone purge`
with `--stats 1m --stats-one-line --stats-log-level NOTICE` and appends their
stderr to `$LOG_FILE`: a per-object purge of a large day folder can be silent
for hours, and the watchdog reads silence as a stall. Measured 2026-10-03
(local backend): with `--stats 5s` it writes one stderr line per interval, e.g.
`2026/10/03 03:28:49 NOTICE:           0 B / 0 B, -, 0 B/s, ETA -`;
`--stats-one-line` is required because the multi-line format also prints
continuation lines such as `Deleted:  106 (files), 0 (dirs), 0 B (freed)`.
`LogParser` returns nil for that line (no `YYYY-MM-DD HH:MM:SS - ` prefix), so
it is never a stats, change or failure event (AC-L63-6).

*Stalled-sync watchdog (`SyncWatchDaemon.runChildProcess`).* While the sync
script runs, the profile log is checked every 60 s. Progress = the size grew or
the inode changed. With none for 30 min it appends `Sync stalled: no log output
for 30 min - stopping it`, sends SIGTERM to the child's process group, and
after a 30 s grace sends SIGKILL. Escalation is keyed on the process GROUP, not
the bash child: after the SIGTERM `runChildProcess` polls `killpg(pgid, 0)`
every second and returns only when the group is gone, and only then appends
`Sync failed with exit code 79` and returns 79 (`SyncManager.exitCodeErrorText`
-> "Sync stalled", the menu turns red; not 78, which is already
`secretUnavailableExitCode` and stays unmapped). It never touches `runningChild`'s
termination state, so the watcher stays up and the scheduler carries on, and a
SIGTERM to the watcher during the escalation still forwards to the group. The
decision is the pure `SyncWatchDaemon.watchdogDecision` (`.wait`/`.exited`/
`.terminate`/`.kill`/`.done`/`.giveUp`, AC-L63-3), and it also reports whether the
log progressed, so that comparison lives in one place (`LogFileStat`, shared with
`LogWatcher`). Every time value comes from one clock, system uptime (`monotonicNow()`,
the same family as the `DispatchTime` waits; documented by Apple not to advance
during sleep, not measured here); a wall clock
would make a healthy run look stalled after the Mac sleeps. If bash exits on its
own just as a check times out, the decision is `.exited`: its own status is
returned and no stall is logged. If the group is still alive 60 s after SIGKILL
(a process in uninterruptible sleep survives it) with bash reaped, one line says
so and the run is finished as stalled (79) anyway; that group is remembered
(`SyncWatchDaemon.lingeringGroup`) and every later `runChildProcess` refuses
to start a script while `killpg(group, 0)` still finds it (one `Sync not
started: …` line, returns 79), so a woken-up old rclone can never run beside a
new one; the first run after the group is gone proceeds normally. The block lasts at most
1 h (`lingeringGroupMaxAge`): a dead group's pgid can be reused by an unrelated
process, so after that one `Sync resuming: …` line is logged and runs resume.
Not covered: the record lives only in the watcher process, so a watcher restart
forgets it. The stall line is written
BEFORE the SIGTERM and the `exit code 79` line only after the group is gone, and
the lock can vanish in between, so `SyncManager.readLastErrorFromLog` treats
`Sync stalled:` as the failure of the current run (returns "Sync stalled");
`LogParser` still yields `.unknown` for it.

What the watchdog does NOT catch: its progress signal is log growth, and
rclone's own `--stats` lines keep the log growing while rclone is stuck retrying
a dead network. It catches only a SILENT stall (a frozen process tree, like the
2026-09-29 case), not a network-stuck rclone. Known limit, not solved. The
thresholds are injectable
(`WatchdogTimings`) from the self-test only, never from a profile field. Limit:
a frozen or suspended WATCHER process is not covered. Observed in the A5 run
(AC-L63-8): bash's EXIT trap runs on SIGTERM and removes the lock, so the next
run started without needing the stale-PID path. A SIGSTOP'd stub died once the
group leader was gone unless it also ignored SIGHUP (likely the POSIX
orphaned-group SIGHUP+SIGCONT rule, not separately verified), so the test stub
ignores TERM and HUP.

**Wizard remote creation (limpet-plan.md L5.1 finding 1).**
`SetupWizardView.advanceToNextStep` returns early while `createRemote`'s
`isLoading` is still true, so a second trigger (e.g. Return key plus a click)
cannot start a second `addRemote` for the same in-progress remote. When
`addRemote` throws `RcloneConfigService.ConfigError.remoteAlreadyExists`, the
wizard shows "A remote named '<name>' already exists. Go Back and choose it
from the list of existing remotes." — the Welcome step's "Existing Remote"
picker is what that refers to. Unobserved until exercised in the running GUI
(SwiftUI view; no self-test).

**Menu display (limpet-plan.md L5.1 finding 4).**
`MenuBarView.statusColor(for:)` returns `.gray` for any profile with
`isEnabled == false` before switching on its sync state, so a disabled
profile (including a freshly-created blank one, which defaults to `.idle`)
never shows the green dot. `StatusHeaderView`'s "Last sync" formatter uses
`dateTimeStyle = .named`: with the default `.numeric`, `RelativeDateTimeFormatter`
renders every gap under one second as "in 0s" / `0秒後` (measured on macOS
2026-09-26 for 0, -0.5 and -0.99 s; `lastSyncTime` is never in the future),
while `.named` says "now" / `現在`, matches `.numeric` from one second to
under a day, and names longer gaps ("yesterday" / `昨天`, "last wk." / `上週`).
Neither change has a self-test (SwiftUI views); both are unobserved until
exercised in the running GUI.

**No unprompted keychain dialogs.** Before any `security` call,
`KeychainSecretStore` asks a lock-status provider (production:
`SecKeychainGetStatus`). While the login
keychain is locked nothing reads it: the watcher logs `Keychain locked — open
limpet and click "Allow keychain access"` (like every keychain line, at most
once per 30 s, the refusal and source-missing throttle), starts no rclone and
waits for its next trigger; the menu shows "Allow keychain access", the only action that
may raise the system unlock dialog, which then sends the waiting watchers
SIGUSR1. Observed live 2026-09-26 with the login keychain locked: no limpet
dialog appeared, the watcher logged the line above, the menu showed "Allow
keychain access", and after the user unlocked it the pending file uploaded (19 s after the
locked line; the unlock moment itself was not timed).
That is one end-to-end observation of this path; that `SecKeychainGetStatus`
can never prompt was not measured on its own.

**Self-write suppression.** `ConfigSelfWriteRegistry` tracks the content hash
of every file limpet itself writes; `ConfigFileWatcher.classifyWrite` (the
production dispatch and the self-test's AC-5 both call it directly — the
`shouldReconcile` bool wrapper this used to go through was dead code and was
removed, code-review finding 10) drops an FSEvent whose file content hash
matches a just-noted self-write, so the app never reacts to its own writes.

**Cross-process self-write suppression (limpet-plan.md L6.1 change A).**
`ConfigSelfWriteRegistry` is per-process, so it cannot recognize a write made
by the SEPARATE `limpet` CLI process — without more, the running app's
`ConfigFileWatcher` would see every CLI-driven profile write as an external
edit and reconcile launchd a second time, on top of the reconcile the CLI
command (`profile set`/`create`/`enable`/`disable`) already did itself
(measured live 2026-09-27: every CLI edit reinstalled/reloaded the agent
twice). `CLIWriteMarker` (`ConfigFileWatcher.swift`) closes that gap: the
CLI's `writeProfile` closure (`LimpetCLI.swift`, the ONLY caller — `ProfileStore`
itself stays marker-free) hashes the exact bytes it is about to write
(`ProfileStore.encodedProfileFileData`) and drops a marker file named by that
hash under `CLIWriteMarker.directory` (`<LimpetPaths.home>/.local/state/limpet/cli-writes`)
BEFORE writing the profile file, so a racing FSEvent can never arrive first.
`ConfigFileWatcher.classifyWrite` returns a three-way `WriteOrigin`: the
in-process registry is checked FIRST (a hit is `.skip`, and the marker is
never even read); on a miss, a matching marker is consumed (read and deleted)
and the origin is `.cliWrite`; otherwise `.external`. Markers older than 10
minutes are swept on every check, so a crashed CLI can't suppress a later,
genuinely external edit forever. On `.cliWrite`,
`SyncManager.applyExternalProfileEdit`/`applyExternalProfileCreate` still run
`persist` (so `profileStore.profiles`, and through its `$profiles` sink the
`LogWatcher` wiring, stays current); the install/uninstall closures they build
via `SyncManager.reconcileClosures` (code-review finding 5) skip ONLY the
`SyncSetupService`/launchctl calls the CLI process already made — the in-app
`LogWatcher`/`profileStates` bookkeeping (`startWatching`/`stopWatching`)
always runs regardless, so a CLI `profile disable` of a syncing or errored
profile can't leave that bookkeeping stale (finding 2; the first version of
this fix no-op'd BOTH halves).
`CLIWriteMarker.directory` is `private(set)`, changed only through
`withDirectory(_:_:)` (redirect for a closure, restore after) — the self-test's
only way to point it at an isolated temp dir instead of the real path.

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

### Versioning, Sparkle updates and the watcher self-restart (limpet-plan.md L7.1)

**Version wiring.** `Info.plist` carries `CFBundleShortVersionString = $(MARKETING_VERSION)` and
`CFBundleVersion = $(CURRENT_PROJECT_VERSION)`. `project.pbxproj` sets `MARKETING_VERSION = 1.0.1`
(Debug and Release) and leaves `CURRENT_PROJECT_VERSION = 1` locally; CI overrides it in L7.2 (commit count).

**Sparkle (SwiftPM, `upToNextMajor` from 2.9.0, pinned in the committed
`limpet.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`; `.gitignore` carves that one path out).**
- Xcode 27 embeds `Sparkle.framework` into `Contents/Frameworks` by itself from the linked package product. An explicit
  "Embed Frameworks" phase with a `productRef` failed here (`Sparkle-product ... no such file`), so there is none. If a
  future Xcode stops embedding it, the app crashes at launch: check `Contents/Frameworks/Sparkle.framework` in the bundle.
- The Run Script phase `Remove Sparkle XPC Services` runs after that and deletes `Sparkle.framework/Versions/B/XPCServices`
  (limpet is not sandboxed; the script runs `set -e`, declares that path as its output, and fails the build if it still
  exists; checked on the unsigned Release build). The target sets `ENABLE_USER_SCRIPT_SANDBOXING = NO`: CI's
  Xcode 26.6 runs user scripts in a sandbox that denied the `rm` (`Sandbox: rm deny file-write-unlink …/XPCServices`,
  PR #14 CI 2026-10-03), while local Xcode 27 allowed it; the `set -e` check is what turned that into a failed build. Because Xcode already signed the framework, the script re-seals the outer framework with
  `$EXPANDED_CODE_SIGN_IDENTITY` when one is set (verified with an ad-hoc identity: `codesign --verify --deep --strict` passes);
  unsigned CI builds skip it and L7.2 re-signs everything inside out.
- Info.plist: `SUFeedURL` = the `appcast.xml` RELEASE ASSET of the latest release (not a file on main),
  `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` YES, `SUEnableInstallerLauncherService` NO,
  `SUPublicEDKey = $(SPARKLE_PUBLIC_ED_KEY)`, `SUEnableJavaScript` unset (default). The build setting
  `SPARKLE_PUBLIC_ED_KEY` holds limpet's own public key (`NFj325uc…`); its private half lives in the login keychain under
  account `limpet` (`generate_keys --account limpet`; the default account is Syrtis's key) and in Environment `release` as
  `SPARKLE_PRIVATE_KEY`.
- **The updater exists only in the GUI.** `UpdaterState.shared.start()` (`LimpetApp.swift`) creates the
  `SPUStandardUpdaterController` from `AppDelegate.applicationDidFinishLaunching`, i.e. after `LimpetCLI.dispatch` and the
  `--self-test` check in `LimpetApp.init` have returned. Never put it in a stored property of `LimpetApp`: those run before
  `init`, so every CLI call and every `limpet watch` agent would start Sparkle. The menu item "Check for Updates..."
  (`MenuBarView`) is disabled while `canCheckForUpdates` is false. There is no self-test for this (the self-test never
  builds an updater), so placement is guarded by this rule. `start()` is compiled out of Debug builds (`#if !DEBUG`), so a
  dev build never polls the release feed and its menu item stays disabled. The controller gets a minimal user-driver
  delegate (`GentleReminders`, `supportsGentleScheduledUpdateReminders = true`), no custom UI.

**Watcher self-restart.** At the top of every run attempt (before the delete-limit, refusal and source-missing gates:
with no child running, restarting is always safe), `SyncWatchScheduler` calls `SchedulerRunner.restartForUpdate`.
Production reads `CFBundleVersion` from disk ONCE (`bundleVersionOnDisk`: the Info.plist next to the executable's
`Contents/MacOS`, never cached `Bundle.main.infoDictionary`) and passes it to the pure `SyncWatchDaemon.restartDecision`
(AC-L71-1) with the startup version, by string equality; `busy` is a stalled group still alive (`lingeringGroup` +
`processGroupExists`), which the scheduler cannot see. The startup version falls back to the loaded
`Bundle.main.infoDictionary` value if the disk read fails, so self-restart is never disabled for the process life.
Different and not busy -> append `Watcher restarting for the updated app (<old> -> <new>)` to the profile
log and `exit(0)` without spawning (launchd KeepAlive starts the new binary); missing plist, or busy ->
spawn. The exit path writes no other file. At startup `SyncWatchDaemon.startUp` calls
`refreshSharedScriptIfChanged()` BEFORE the catch-up run, so the new watcher always runs the matching `limpet-sync.sh`
(AC-L71-2); an old watcher writes nothing, so it can never put an old template back.

**Entitlements.** `limpet.entitlements` and `CODE_SIGN_ENTITLEMENTS` are gone (the file was dead); hardened runtime stays on.
Never add `disable-library-validation` or `allow-dyld-environment-variables`.

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
| `limpet status [name\|shortId]` | One tab-separated line per profile (or a single one): `enabled=`, `agent=loaded\|unloaded\|n/a`, `running=` (lock present), `last=started\|completed\|failed\|retrying\|none` (from the log tail via the shared `SyncLogPatterns`). |
| `limpet profiles` | List every profile: name, shortId, mode, `enabled=`, `remote=` — no secrets. (`profile list` is an alias.) |
| `limpet profile show <name\|shortId>` | Print one profile's FULL config as pretty, sorted-key JSON — the same shape as its `.profile.json`, so an agent can `show` → edit → `profile create`/`profile set` round-trip. No secrets (credentials live in `rclone.conf` or the login keychain). |
| `limpet logs <name\|shortId> [--follow]` | Print (or `tail -F`, which follows the name across rotation) that profile's sync log. |
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
| `limpet remote add <name> --type s3\|b2 --access-key-id <id> [--provider <p>] [--endpoint <https url>] [--region <r>]` | Create a keychain-backed remote through `RcloneConfigService.addKeychainRemote`, the same function the wizard uses. The secret is read from stdin — a no-echo prompt on a terminal, otherwise one line from the pipe — never from an argument. Writes the non-secret section plus `limpet_keychain = true` to rclone.conf (appended; nothing else rewritten) and stores the secret with `/usr/bin/security -i` (`add-generic-password -s limpet -a <name> -T /usr/bin/security`, secret hex-encoded on stdin). Names are `[A-Za-z0-9_]+` and may not collide case-insensitively with any rclone.conf section; endpoints must be https; `--provider Mega --region <r>` derives `s3.<r>.megas4.com`; a known `--provider` in any case (`mega`) is written in the wizard's spelling (`Mega`). |
| `limpet trash restore <name\|shortId> <relative-path> [--date YYYY-MM-DD] [--force]` | Restore the newest (or one dated) trashed version of a file into `localSyncPath` (see **Trash** above). Refuses before any rclone call on a bad path/date or a destination directory that resolves outside `localSyncPath` through a symlink; refuses to overwrite an existing local entry (a symlink included, never followed) without `--force`. |

**Operate:**

| Command | Purpose |
|---------|---------|
| `limpet sync <name\|shortId>` | Send the running watcher SIGUSR1 (`launchctl kill SIGUSR1 gui/$(id -u)/<launchdLabel>`) to ask it to sync now, and return immediately — it does NOT block until the sync finishes. On success prints `sync requested for "<name>" (<shortId>) — see: limpet logs <shortId>` and exits 0; if the agent isn't loaded prints `error: no watcher running for "<name>" (<shortId>)` to stderr and exits 1. Use `limpet logs <name\|shortId> --follow` to watch the run it triggered. |
| `limpet trash list <name\|shortId> [--date YYYY-MM-DD]` | List a profile's trashed (deleted/overwritten) files (see **Trash** above). Works on any profile whose `remotePath` has a parent, regardless of `trashDays`/`syncDirection`/`remoteVersioning` — old trash stays inspectable after the profile changed or trash was turned off. Exits 0 printing "can have no trash root: remotePath ... has no parent" only when `remotePath` itself has no parent. |

`<name|shortId>` resolution tries an exact `shortId` match first, then a
case-insensitive `name` match; an unmatched (or ambiguous) target exits
non-zero with a greppable `error: no profile matches "<target>"`.

**The mutating commands operate through the file-backed config, so they work
whether or not the menu-bar app is running:** they write the authoritative
`.profile.json` and drive `SyncSetupService` install/uninstall directly (the
launchd delta chosen by the shared `SyncManager.reconcileAction`). When the app
IS running, its `ConfigFileWatcher` sees the write, recognises it as a CLI write
through `CLIWriteMarker`, and refreshes its in-memory state without a second
launchd reconcile (see "Cross-process self-write suppression" above). Profile files stay credential-free (secrets live in
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

1. **FSEvents**: Low-latency file change detection via `DispatchSource.makeFileSystemObjectSource`, on the watcher's own serial queue (not `.main`)
2. **Polling fallback**: Timer-based check every 2.5-5 seconds catches missed events; the same tick also handles a log path that is missing, deleted or being rotated
3. **Inode tracking**: Detects file replacement (rotation) and reopens the new file at offset 0

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

## Releasing

A tag `v*` runs `.github/workflows/release.yml`: a Developer ID signed, notarized `Limpet-<ver>.dmg`, `limpet.app.tar.gz`
(the Homebrew cask's input), `sha256.txt`, and a signed Sparkle feed `appcast.xml`, published as GitHub Release
assets. The scripts are in `scripts/release/`: the signing, notarization, DMG, verification and appcast scripts are adapted from Syrtis (each header credits it); `bump_cask.sh` is limpet's own.

| Job | Runs | Secrets | Does |
|-----|------|---------|------|
| `gate` | tags only, ubuntu | none | `MARKETING_VERSION` is plain X.Y.Z without leading zeros (no prereleases: there is no beta channel) and strictly newer than the latest release (so the feed at `releases/latest` never moves back), tag == `v` + `MARKETING_VERSION` (`project_version.sh`), `release-notes/<tag>.md` non-empty, `$GITHUB_SHA` is an ancestor of `origin/main`, and a green push run of `ci.yml` on that SHA (`check_ci_gate.sh`, waits up to 30 min) |
| `build` | tag or dry run, `macos-26` + Xcode 26.6 | none, `contents: read` | `xcodebuild` Release with `CODE_SIGNING_ALLOWED=NO`, `CURRENT_PROJECT_VERSION=$(git rev-list --count HEAD)` (`MARKETING_VERSION` stays the project's; `gate` already required the tag to match); asserts `CFBundleVersion`, `CFBundleShortVersionString` and Sparkle present (no-`XPCServices` is checked by `verify_signed_app.sh`); uploads a tar of the unsigned app |
| `sign` | tag or dry run, Environment `release` | all of them | resolves Sparkle itself (`xcodebuild -resolvePackageDependencies`, never executes anything from the build artifact), signs/notarizes/staples the app, DMG, `verify_signed_*`, generates and verifies `appcast.xml` |
| `publish` | tags only, Environment `release`, `contents: write` | none used | `gh release create` with the four assets and `release-notes/<tag>.md`; pushes nothing to the repository |
| `tap` | tags only, Environment `release`, `contents: read` | `HOMEBREW_TAP_LIMPET_DEPLOY_KEY` | hashes `limpet.app.tar.gz` downloaded from the PUBLISHED release (what Homebrew fetches; not the 1-day artifact, so a late re-run works), clones `Nanako0129/homebrew-tap` over SSH (GitHub's ed25519 host key pinned, `StrictHostKeyChecking=yes`), runs `scripts/release/bump_cask.sh` on `Casks/limpet.rb` (validates X.Y.Z without leading zeros and the sha; an older version than the cask's is a no-op, never a downgrade; keeps the file mode), requires `Casks/limpet.rb` to be the only changed file, commits `limpet <ver>` and pushes to the tap's `main`; a failed clone, or a push rejected because the tap moved (Syrtis pushed in between), starts over from a fresh clone after 30/45 s (3 attempts); any other push error (key, permission, host key) fails at once with git's message. This classification is by git's output text and is unverified until a real tap push (the first stable release after L8.2). Idempotent: a cask already at this version and sha exits 0, so re-run just this job after a failed push |

**One run at a time.** The workflow has a single `concurrency` group, so a second tag's `sign` starts only
after the first run finished; the feed is seeded from the latest release, so overlapping runs would drop each other's item. GitHub keeps one pending run per group: a third run arriving cancels the waiting one. Re-run a cancelled tag only if no newer version has been released since; otherwise the gate refuses it (not newer than Latest) and that version is simply skipped.

**Secrets and variables.** Environment `release` only (never repository secrets): secrets `DEVELOPER_ID_P12` (base64),
`DEVELOPER_ID_P12_PASSWORD`, `NOTARY_KEY_P8` (raw PEM), `SPARKLE_PRIVATE_KEY`, `HOMEBREW_TAP_LIMPET_DEPLOY_KEY` (write deploy key of the tap; it can rewrite every cask there, Syrtis's too, an accepted risk); variables `APPLE_TEAM_ID`, `NOTARY_KEY_ID`,
`NOTARY_ISSUER_ID`. The Environment's deployment policy admits `main` and tags `v*`; `sign` also refuses any other ref
in-job. `sign` fails on an empty value for any of its seven (the four signing secrets and three variables); the `tap` job checks its own deploy key.

**The feed is a release asset.** `SUFeedURL` is `https://github.com/Nanako0129/limpet/releases/latest/download/appcast.xml`.
Each release generates the feed from the previous release's `appcast.xml` (kept items stay verbatim, at most five
versions), so nothing is committed to `main`. `make_appcast.sh` takes the Sparkle `bin` directory as an argument and fails
unless the feed carries Sparkle's feed signature (`SURequireSignedFeed=YES` in the app).
`verify_appcast.sh` checks `sparkle:version == CFBundleVersion` and that the item's signature verifies with the app's own
`SUPublicEDKey` (OpenSSL 3), because `generate_appcast` only warns on a key mismatch.

**Cut a release.**
1. Set `MARKETING_VERSION` to `X.Y.Z` in both configurations of `limpet.xcodeproj/project.pbxproj`.
2. Add `release-notes/vX.Y.Z.md` (becomes the GitHub Release body and the Sparkle item's notes).
3. Merge through a PR and wait for CI on the merge commit.
4. Tag the merge commit `vX.Y.Z` and push the tag, then approve the `release` Environment for `sign`, `publish` and `tap`. The run holds the workflow's single concurrency group until all three are given, so approve promptly: a third tag would cancel a second one waiting behind it.
5. Homebrew users get it with `brew install --cask nanako0129/tap/limpet`; installed copies update through Sparkle (`auto_updates true`).

**Dry run.** Actions, Release, Run workflow on `main`: builds, signs, notarizes, verifies and generates the appcast, then
uploads artifact `signed` (1 day) and publishes nothing. Check the DMG with
`spctl -a -vv -t open --context context:primary-signature <dmg>` and `xcrun stapler validate <dmg>`.

**Runner.** `ci.yml` and `release.yml` both use `macos-26` with `DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer`;
change them together. Actions are pinned by SHA and Dependabot (weekly, minor and patch only) keeps them current; it does
not cover Sparkle (no root `Package.swift`). Upgrade Sparkle by hand: change the requirement in Xcode, then refresh the
committed `Package.resolved` (`xcodebuild -resolvePackageDependencies`) and review the diff. Never add `actions/cache` or a
self-hosted runner to the release workflow.

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
| `~/.config/limpet/profiles/{shortId}-exclude.txt` | Exclude filter (user-editable; kept across uninstall/reinstall, removed only when the profile is deleted) |
| `~/.local/bin/limpet-sync.sh` | Shared sync script (all profiles) |
| `~/Library/LaunchAgents/com.nanako.limpet.watch.{shortId}.plist` | launchd schedule |
| `~/.local/log/limpet-sync-{shortId}.log` | Sync logs |
| `/tmp/limpet-sync-{shortId}.lock` | Lock file (prevents concurrent syncs) |
