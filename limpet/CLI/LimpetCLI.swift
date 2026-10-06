import Foundation

/// Where `profile create` reads the profile JSON from.
enum CreateSource: Equatable {
    case file(String)
    case stdin
}

/// One `key value` assignment for `profile set`. A named struct (rather than a
/// bare tuple) so `CLICommand` stays `Equatable` — an array of labelled tuples
/// isn't `Equatable`-synthesizable.
struct ProfileAssignment: Equatable {
    let key: String
    let value: String
}

/// `limpet remote add` arguments. The secret is deliberately NOT here: it is
/// never an argument, only read from stdin (limpet-plan.md L4 F2).
struct RemoteAddRequest: Equatable {
    let name: String
    let type: String
    let values: [String: String]
}

/// Parsed CLI subcommand — the pure, testable result of `LimpetCLI.parse`.
enum CLICommand: Equatable {
    case doctor
    case testRemote(String)
    case logs(target: String, follow: Bool)
    case listRemotes
    case profiles
    case status(target: String?)
    case sync(String)
    case watch(String)
    case reinstall(String)
    case install(String)
    case profileCreate(CreateSource)
    case profileShow(String)
    case profileDelete(String)
    case profileSet(target: String, assignments: [ProfileAssignment])
    case profileSetEnabled(target: String, enabled: Bool)
    case profileClearDeleteLimit(String)
    case remoteAdd(RemoteAddRequest)
    case trashList(target: String, date: String?)
    case trashRestore(target: String, relativePath: String, date: String?, force: Bool)
    case help
}

/// The newest trashed version of a restore target found in a `rclone lsf -R`
/// listing (limpet-plan.md L6.2 item 5).
struct TrashMatch: Equatable {
    /// The `YYYY-MM-DD` folder it was found under.
    let date: String
    /// Its path relative to the LISTED root (includes the date folder when
    /// the listing covered the whole trash root, i.e. no fixed `--date`).
    let entry: String
    /// The 6-digit `HHMMSS` suffix rclone inserted.
    let suffix: String
    /// Whether this matched the `<name>.rclonelink` form — a symlink stored
    /// as a plain content object because the remote has no native symlink
    /// support (code-review finding 2 on 87bbf67). Restore needs this to
    /// recreate a real local symlink instead of a regular file carrying the
    /// link target as text.
    let isSymlink: Bool
}

/// A `parse` failure — carries the usage message printed to stderr.
struct CLIUsageError: Error, Equatable {
    let message: String
}

/// One line of a `doctor` health report. A typed result (rather than parallel
/// status strings) so `run`/the self-test can derive the exit code by asking
/// "does any check have status `.fail`" instead of re-parsing printed text.
struct DoctorCheck: Equatable {
    enum Status: String { case ok, warn, fail }

    let name: String
    let status: Status
    let detail: String

    /// Greppable single-line rendering, e.g. `[ok] rclone: /opt/homebrew/bin/rclone (v1.66.0)`.
    var line: String { "[\(status.rawValue)] \(name): \(detail)" }
}

/// Every impure operation the CLI touches, injected so `execute`/`doctorChecks`
/// are pure over `env` and fully exercisable by `ConfigSelfTest` with fakes —
/// no real `Process`, `FileManager`, or stdio needed to test dispatch logic.
struct CLIEnvironment {
    /// Run rclone with `args`, hard-killed after `timeout` seconds if still
    /// running. Returns `(exitCode, stdout, stderr)`. `remote` names the remote
    /// the command touches, so a keychain-backed one gets its secret through
    /// the F3 helper (`nil` for `version`/`listremotes`).
    var runRclone: (_ args: [String], _ remote: String?, _ timeout: TimeInterval) -> (Int32, String, String)
    /// Read every profile from the file-authoritative profiles directory.
    var readProfiles: () -> [SyncProfile]
    var fileExists: (String) -> Bool
    /// Whether a directory entry exists at the path WITHOUT following a final
    /// symlink (lstat), so a dangling symlink counts as existing. `trash
    /// restore` uses it so a symlink at the destination is never looked through.
    var itemExists: (String) -> Bool
    /// realpath(3) of an existing path (every symlink resolved), or `nil` when
    /// it cannot be resolved (missing, dangling symlink, no permission).
    var realPath: (String) -> String?
    /// Run `launchctl` with `args`. Returns `(exitCode, stdout)`.
    var runLaunchctl: (_ args: [String]) -> (Int32, String)
    /// Whether the JSON schema files are installed under the config directory.
    var schemaFilesPresent: () -> Bool
    /// The rclone.conf section of a remote (`type` included), or `nil`.
    var remoteSection: (_ remoteName: String) -> [String: String]?
    /// Persist a profile's authoritative `{shortId}.profile.json`. Returns
    /// `true` on success. Same byte format the app writes (`ProfileStore`).
    var writeProfile: (SyncProfile) -> Bool
    /// Install (generate script/plist/derived-config and load the launchd
    /// agent). Returns an error message on failure, or `nil` on success.
    var installProfile: (SyncProfile) -> String?
    /// Uninstall (unload the agent, remove the derived files). Returns an
    /// error message on failure, or `nil`.
    var uninstallProfile: (SyncProfile) -> String?
    /// Delete the authoritative `{shortId}.profile.json`.
    var deleteProfileFile: (SyncProfile) -> Void
    /// Remove a file (the delete-limit marker). Returns whether it succeeded.
    var removeFile: (String) -> Bool
    /// Move/rename a local file or symlink from `from` to `to`. With
    /// `replace`, an existing item at `to` is replaced atomically; without it
    /// the move fails if ANY item appears at `to`, even one created after an
    /// earlier existence check (CodeRabbit, PR #10). On failure `to` is left
    /// untouched. Used by `trash restore`'s temp-name-then-rename.
    var moveFile: (_ from: String, _ to: String, _ replace: Bool) -> Bool
    /// Read all of stdin (for `profile create -`). `nil` on read failure.
    var readStdin: () -> String?
    /// Read a file's contents as UTF-8 text. `nil` if missing/unreadable.
    var readFile: (String) -> String?
    /// Read a secret: a no-echo prompt on a TTY, else one line of stdin.
    /// Never from argv (limpet-plan.md L4 F2).
    var readSecret: (_ prompt: String) -> String?
    /// `RcloneConfigService.addKeychainRemote` — the one creation path shared
    /// with the wizard. Returns an error message or `nil`.
    var addKeychainRemote: (_ name: String, _ type: String, _ values: [String: String], _ secret: String) -> String?
    var stdout: (String) -> Void
    var stderr: (String) -> Void
}

/// Headless `limpet` CLI, dispatched from `LimpetApp.init` exactly like
/// the existing `--self-test` intercept: parsed early, run, and `exit()`ed
/// before the SwiftUI app, `SyncManager`, watchers, or timers ever start. It
/// NEVER opens a window and NEVER launches background work — see `dispatch`.
///
/// Pure core / impure shell: `parse`, `execute`, `run`, `doctorChecks`, and
/// `resolveProfile` operate entirely over their arguments/injected `env`, so
/// `ConfigSelfTest` drives the full dispatch + doctor-aggregation logic with
/// fakes. Only `CLIEnvironment.production()` and `dispatch` touch real
/// process/filesystem state.
enum LimpetCLI {
    static let usage = """
    usage: limpet <command> [args]

    Inspect:
      doctor                       Run a health check and print a report
      status [name|id]             Show live state for one or all profiles
      profiles                     List configured limpet profiles
      profile show <name|id>       Print one profile's full config as JSON
      logs <name|id> [--follow]    Print or tail a profile's sync log
      test-remote <name|id>        Probe a profile's remote reachability
      listremotes                  List configured rclone remotes

    Configure:
      profile create --from <file> Create a profile from a .profile.json file
      profile create -             Create a profile from JSON on stdin
      profile enable <name|id>     Enable a profile (install its launchd agent)
      profile disable <name|id>    Disable a profile (unload its agent)
      profile delete <name|id>     Delete a profile and its launchd agent
      profile set <name|id> <key> <value> [<key> <value> ...]
                                   Edit fields on an existing profile and reconcile
      profile clear-delete-limit <name|id>
                                   Resume a profile stopped by --max-delete, and sync now
      install <name|id>            Install an enabled profile's launchd agent (idempotent)
      reinstall <name|id>          Regenerate script+plist and reinstall the agent
      remote add <name> --type s3|b2 --access-key-id <id> [--provider <p>] [--endpoint <https url>] [--region <r>]
                                   Add a remote whose secret lives in the login keychain;
                                   the secret is read from stdin (no-echo prompt on a terminal)
      trash restore <name|id> <relative-path> [--date YYYY-MM-DD] [--force]
                                   Restore the newest (or one dated) trashed version of a file

    Operate:
      sync <name|id>                          Ask the profile's watcher to sync now (returns immediately)
      watch <name|id>                         Run as the profile's realtime watcher (launchd only; never exits)
      trash list <name|id> [--date YYYY-MM-DD] List a profile's trashed (deleted/overwritten) files

    profile set keys: name, rcloneRemote, remotePath, localSyncPath,
      drivePathToMonitor, additionalRcloneFlags,
      syncDirection (localToRemote|remoteToLocal), syncIntervalMinutes,
      transfers, isMuted, maxDelete, remoteVersioning, trashDays.
      Use enable/disable for isEnabled.

    trash list/restore work on any profile whose remotePath has a parent
    (the trash root is a path formula, independent of trashDays/syncDirection/
    remoteVersioning), so they keep reaching OLD trash after trash was turned
    off or the profile changed — see CLAUDE.md's Delete-limit/Trash sections.

    Profiles author JSON against schema/profile.schema.json under the config
    directory; the same file an agent can drop in or edit directly.
    """

    // MARK: - Entry point

    /// Returns the process exit code when `arguments` names a CLI invocation, or
    /// `nil` to fall through to the GUI. A bare first token (not `-`-prefixed) is
    /// ALWAYS treated as a subcommand and routed through `execute` — an unknown
    /// one prints usage and exits non-zero (EX_USAGE) rather than silently
    /// launching the GUI and hanging the terminal (the bug this guards against).
    /// `nil` is returned only for a no-argument launch and for `-`-prefixed args
    /// (`--self-test`, and macOS's own `-psn_…`/`-NS…` GUI arguments), which the
    /// GUI/self-test path handles — except `-h`/`--help`, routed to `execute`.
    static func dispatch(arguments: [String]) -> Int32? {
        let argv = Array(arguments.dropFirst())
        guard let first = argv.first else { return nil }        // no args → normal GUI launch
        if first.hasPrefix("-"), first != "-h", first != "--help" {
            return nil                                          // other flags → GUI/self-test path
        }
        // `-`-prefixed `-h`/`--help`, or any bare token, IS a subcommand.
        return execute(argv, env: .production())
    }

    // MARK: - Pure core

    /// Parse `argv` (program name already stripped) into a `CLICommand`.
    static func parse(_ argv: [String]) -> Result<CLICommand, CLIUsageError> {
        guard let command = argv.first else {
            return .failure(CLIUsageError(message: usage))
        }
        let rest = Array(argv.dropFirst())

        switch command {
        case "doctor":
            return .success(.doctor)

        case "test-remote":
            guard let target = rest.first else {
                return .failure(CLIUsageError(message: "usage: limpet test-remote <name|shortId>"))
            }
            return .success(.testRemote(target))

        case "logs":
            guard let target = rest.first(where: { !$0.hasPrefix("--") }) else {
                return .failure(CLIUsageError(message: "usage: limpet logs <name|shortId> [--follow]"))
            }
            return .success(.logs(target: target, follow: rest.contains("--follow")))

        case "listremotes":
            return .success(.listRemotes)

        case "profiles":
            return .success(.profiles)

        case "status":
            return .success(.status(target: rest.first(where: { !$0.hasPrefix("-") })))

        case "sync":
            guard let target = rest.first(where: { !$0.hasPrefix("-") }) else {
                return .failure(CLIUsageError(message: "usage: limpet sync <name|shortId>"))
            }
            return .success(.sync(target))

        case "watch":
            guard let target = rest.first(where: { !$0.hasPrefix("-") }) else {
                return .failure(CLIUsageError(message: "usage: limpet watch <name|shortId>"))
            }
            return .success(.watch(target))

        case "reinstall", "install":
            guard let target = rest.first(where: { !$0.hasPrefix("-") }) else {
                return .failure(CLIUsageError(message: "usage: limpet \(command) <name|shortId>"))
            }
            switch command {
            case "reinstall": return .success(.reinstall(target))
            default: return .success(.install(target))
            }

        case "profile":
            return parseProfile(rest)

        case "remote":
            return parseRemote(rest)

        case "trash":
            return parseTrash(rest)

        case "help", "-h", "--help":
            return .success(.help)

        default:
            return .failure(CLIUsageError(message: usage))
        }
    }

    /// Parse the `profile <subcommand>` group.
    private static func parseProfile(_ rest: [String]) -> Result<CLICommand, CLIUsageError> {
        guard let sub = rest.first else {
            return .failure(CLIUsageError(message: "usage: limpet profile <create|enable|disable|delete|set|list> ..."))
        }
        let args = Array(rest.dropFirst())

        switch sub {
        case "list":
            return .success(.profiles)

        case "show":
            guard let target = args.first(where: { !$0.hasPrefix("-") }) else {
                return .failure(CLIUsageError(message: "usage: limpet profile show <name|shortId>"))
            }
            return .success(.profileShow(target))

        case "set":
            // `profile set <target> <key> <value> [<key> <value> ...]` — the
            // remaining tokens after the target are positional key/value pairs
            // (so a value may contain `=`, unlike a `--set key=value` form).
            let setUsage = CLIUsageError(message: "usage: limpet profile set <name|shortId> <key> <value> [<key> <value> ...]")
            guard let target = args.first else { return .failure(setUsage) }
            let pairTokens = Array(args.dropFirst())
            guard !pairTokens.isEmpty, pairTokens.count % 2 == 0 else {
                return .failure(setUsage)
            }
            var assignments: [ProfileAssignment] = []
            var idx = 0
            while idx < pairTokens.count {
                assignments.append(ProfileAssignment(key: pairTokens[idx], value: pairTokens[idx + 1]))
                idx += 2
            }
            return .success(.profileSet(target: target, assignments: assignments))

        case "create":
            // `--from <file>` reads a file; a bare `-` reads stdin.
            if let idx = args.firstIndex(of: "--from"), idx + 1 < args.count {
                return .success(.profileCreate(.file(args[idx + 1])))
            }
            if args.contains("-") {
                return .success(.profileCreate(.stdin))
            }
            return .failure(CLIUsageError(message: "usage: limpet profile create --from <file.profile.json> | -  (stdin)"))

        case "enable", "disable":
            guard let target = args.first(where: { !$0.hasPrefix("-") }) else {
                return .failure(CLIUsageError(message: "usage: limpet profile \(sub) <name|shortId>"))
            }
            return .success(.profileSetEnabled(target: target, enabled: sub == "enable"))

        case "delete":
            guard let target = args.first(where: { !$0.hasPrefix("-") }) else {
                return .failure(CLIUsageError(message: "usage: limpet profile delete <name|shortId>"))
            }
            return .success(.profileDelete(target))

        case "clear-delete-limit":
            guard let target = args.first(where: { !$0.hasPrefix("-") }) else {
                return .failure(CLIUsageError(message: "usage: limpet profile clear-delete-limit <name|shortId>"))
            }
            return .success(.profileClearDeleteLimit(target))

        default:
            return .failure(CLIUsageError(message: "unknown 'profile' subcommand: \(sub)\n" + usage))
        }
    }

    /// Parse `remote add <name> --type s3|b2 --access-key-id <id> [--provider
    /// <p>] [--endpoint <e>] [--region <r>]`. There is no flag for the secret,
    /// and a flag that looks like one is refused with a pointer to stdin.
    private static func parseRemote(_ rest: [String]) -> Result<CLICommand, CLIUsageError> {
        let usage = CLIUsageError(message: "usage: limpet remote add <name> --type s3|b2 --access-key-id <id> "
            + "[--provider <p>] [--endpoint <https url>] [--region <r>]  (the secret is read from stdin)")
        guard rest.first == "add", rest.count >= 2, !rest[1].hasPrefix("-") else { return .failure(usage) }
        let name = rest[1]
        var flags: [String: String] = [:]
        var idx = 2
        while idx < rest.count {
            let flag = rest[idx]
            if flag.lowercased().contains("secret") || flag == "--key" || flag == "--password" {
                return .failure(CLIUsageError(
                    message: "error: the secret is never an argument; pipe it on stdin or type it at the prompt"))
            }
            guard ["--type", "--provider", "--endpoint", "--region", "--access-key-id"].contains(flag),
                  idx + 1 < rest.count, flags[flag] == nil else { return .failure(usage) }
            flags[flag] = rest[idx + 1]
            idx += 2
        }
        guard let type = flags["--type"], let keyId = flags["--access-key-id"] else { return .failure(usage) }
        var values: [String: String] = [:]
        switch type {
        case "s3":
            values["access_key_id"] = keyId
            // A known provider in any case is written in the wizard's spelling.
            values["provider"] = flags["--provider"].map { given in
                RemoteProvider.s3Compatible.requiredFields.first { $0.key == "provider" }?.options?
                    .first { $0.value.caseInsensitiveCompare(given) == .orderedSame }?.value ?? given
            }
            values["region"] = flags["--region"]
            values["endpoint"] = flags["--endpoint"]
            // A MEGA S4 endpoint is derived from --region by the shared creation
            // function (RcloneConfigService.withDerivedEndpoint).
        case "b2":
            guard flags["--provider"] == nil, flags["--endpoint"] == nil, flags["--region"] == nil else {
                return .failure(CLIUsageError(message: "error: --provider/--endpoint/--region apply to --type s3 only"))
            }
            values["account"] = keyId
        default:
            return .failure(usage)
        }
        return .success(.remoteAdd(RemoteAddRequest(name: name, type: type, values: values)))
    }

    /// Parse `trash list <name|id> [--date D]` / `trash restore <name|id>
    /// <relative-path> [--date D] [--force]`. Value validation (path shape,
    /// date shape) happens in `run`, before any rclone call — never here.
    private static func parseTrash(_ rest: [String]) -> Result<CLICommand, CLIUsageError> {
        guard let sub = rest.first else {
            return .failure(CLIUsageError(message: "usage: limpet trash <list|restore> ..."))
        }
        var args = Array(rest.dropFirst())
        var date: String?
        if let idx = args.firstIndex(of: "--date"), idx + 1 < args.count {
            date = args[idx + 1]
            args.removeSubrange(idx...(idx + 1))
        }
        let force = args.contains("--force")
        args.removeAll { $0 == "--force" }

        switch sub {
        case "list":
            guard let target = args.first else {
                return .failure(CLIUsageError(message: "usage: limpet trash list <name|shortId> [--date YYYY-MM-DD]"))
            }
            return .success(.trashList(target: target, date: date))

        case "restore":
            guard args.count == 2 else {
                return .failure(CLIUsageError(
                    message: "usage: limpet trash restore <name|shortId> <relative-path> [--date YYYY-MM-DD] [--force]"))
            }
            return .success(.trashRestore(target: args[0], relativePath: args[1], date: date, force: force))

        default:
            return .failure(CLIUsageError(message: "unknown 'trash' subcommand: \(sub)"))
        }
    }

    /// Parse + dispatch, printing usage via `env.stderr` on a parse failure.
    /// The single entry point both `dispatch` (real env) and the self-test
    /// (fake env) exercise for the unknown/absent-subcommand case.
    static func execute(_ argv: [String], env: CLIEnvironment) -> Int32 {
        switch parse(argv) {
        case .success(let command):
            return run(command, env: env)
        case .failure(let error):
            env.stderr(error.message + "\n")
            return 64  // EX_USAGE
        }
    }

    static func run(_ command: CLICommand, env: CLIEnvironment) -> Int32 {
        switch command {
        case .doctor:
            return runDoctor(env: env)
        case .testRemote(let target):
            return runTestRemote(target, env: env)
        case .logs(let target, let follow):
            return runLogs(target, follow: follow, env: env)
        case .listRemotes:
            return runListRemotes(env: env)
        case .profiles:
            return runProfiles(env: env)
        case .status(let target):
            return runStatus(target, env: env)
        case .sync(let target):
            return runSync(target, env: env)
        case .watch(let target):
            return runWatch(target, env: env)
        case .reinstall(let target):
            return runReinstall(target, env: env)
        case .install(let target):
            return runInstall(target, env: env)
        case .profileCreate(let source):
            return runProfileCreate(source, env: env)
        case .profileShow(let target):
            return runProfileShow(target, env: env)
        case .profileDelete(let target):
            return runProfileDelete(target, env: env)
        case .profileSet(let target, let assignments):
            return runProfileSet(target, assignments: assignments, env: env)
        case .profileSetEnabled(let target, let enabled):
            return runProfileSetEnabled(target, enabled: enabled, env: env)
        case .profileClearDeleteLimit(let target):
            return runClearDeleteLimit(target, env: env)
        case .remoteAdd(let request):
            return runRemoteAdd(request, env: env)
        case .trashList(let target, let date):
            return runTrashList(target, date: date, env: env)
        case .trashRestore(let target, let relativePath, let date, let force):
            return runTrashRestore(target, relativePath: relativePath, date: date, force: force, env: env)
        case .help:
            env.stdout(Self.usage + "\n")
            return 0
        }
    }

    /// Resolve `target` against `profiles`: exact `shortId` match first, then a
    /// case-insensitive `name` match. Returns `nil` when nothing matches AND when
    /// the name is ambiguous (matches >1 profile) — callers treat both as "no
    /// profile matches". An ambiguous name is therefore indistinguishable from an
    /// absent one; disambiguate with the profile's shortId.
    static func resolveProfile(_ target: String, in profiles: [SyncProfile]) -> SyncProfile? {
        if let byShortId = profiles.first(where: { $0.shortId == target }) {
            return byShortId
        }
        let byName = profiles.filter { $0.name.caseInsensitiveCompare(target) == .orderedSame }
        return byName.count == 1 ? byName.first : nil
    }

    // MARK: - doctor

    private static func runDoctor(env: CLIEnvironment) -> Int32 {
        let checks = doctorChecks(env: env)
        for check in checks { env.stdout(check.line + "\n") }
        return checks.contains { $0.status == .fail } ? 1 : 0
    }

    /// Build the full doctor report against `env`. Exposed (not `private`) so
    /// `ConfigSelfTest` can assert the exact status matrix against fakes.
    static func doctorChecks(env: CLIEnvironment) -> [DoctorCheck] {
        var checks: [DoctorCheck] = []

        let (rcloneExit, rcloneOut, _) = env.runRclone(["version"], nil, 5)
        if rcloneExit == 0 {
            let version = rcloneOut.split(separator: "\n").first.map(String.init) ?? "unknown"
            checks.append(DoctorCheck(name: "rclone", status: .ok, detail: version))
        } else {
            checks.append(DoctorCheck(name: "rclone", status: .fail, detail: "not found"))
        }

        checks.append(
            env.schemaFilesPresent()
                ? DoctorCheck(name: "config schemas", status: .ok, detail: "installed")
                : DoctorCheck(name: "config schemas", status: .warn, detail: "not installed")
        )

        let profiles = env.readProfiles()
        if profiles.isEmpty {
            checks.append(DoctorCheck(name: "profiles", status: .warn, detail: "none configured"))
        }
        for profile in profiles {
            checks.append(contentsOf: doctorChecks(for: profile, env: env))
        }

        return checks
    }

    private static func doctorChecks(for profile: SyncProfile, env: CLIEnvironment) -> [DoctorCheck] {
        let label = "profile \"\(profile.name)\" (\(profile.shortId))"
        var checks: [DoctorCheck] = []

        checks.append(
            env.fileExists(profile.configPath)
                ? DoctorCheck(name: label, status: .ok, detail: "derived config present")
                : DoctorCheck(name: label, status: .fail, detail: "derived config missing")
        )

        // maxDelete is decided at install time from the remote's rclone.conf
        // section; a provider changed there since is not picked up until a
        // reinstall. Warn (never fail) when they disagree.
        let remoteName = String(profile.rcloneRemote.prefix { $0 != ":" })
        if env.fileExists(profile.configPath), let derived = env.readFile(profile.configPath),
           let config = (try? JSONSerialization.jsonObject(with: Data(derived.utf8))) as? [String: Any] {
            let installed = config["maxDelete"] as? Int ?? 0
            let current = SyncSetupService.maxDeleteArgument(for: profile, remoteSection: env.remoteSection(remoteName))
            if installed != current {
                checks.append(DoctorCheck(name: label, status: .warn,
                    detail: "installed with maxDelete \(installed), but the remote's current rclone.conf section "
                        + "gives \(current); run 'limpet reinstall \(profile.shortId)'"))
            }
        }

        if profile.isEnabled {
            let (_, launchctlOut) = env.runLaunchctl(["print", "gui/\(getuid())/\(profile.launchdLabel)"])
            checks.append(
                launchctlOut.isEmpty
                    ? DoctorCheck(name: label, status: .fail, detail: "launchd agent not loaded")
                    : DoctorCheck(name: label, status: .ok, detail: "launchd agent loaded")
            )
        }

        checks.append(
            env.fileExists(profile.lockFilePath)
                ? DoctorCheck(name: label, status: .warn, detail: "stale lock file present")
                : DoctorCheck(name: label, status: .ok, detail: "no stale lock")
        )

        let (remoteExit, _, remoteErr) = env.runRclone(["lsd", profile.fullRemotePath], profile.fullRemotePath, 5)
        checks.append(
            remoteExit == 0
                ? DoctorCheck(name: label, status: .ok, detail: "remote reachable")
                : DoctorCheck(name: label, status: .fail, detail: "remote unreachable: \(remoteErr)")
        )

        // limpet-plan.md L4 F6, B2: warn (never fail) when the bucket has no
        // daysFromHidingToDeleting lifecycle rule. The output shape is rclone
        // 1.75.1's own `rclone backend help b2` example (`[]` when there are no
        // rules, else objects with "daysFromHidingToDeleting": N); it was not
        // measured against a live bucket here.
        if env.remoteSection(remoteName)?["type"] == "b2" {
            let bucket = profile.remotePath.split(separator: "/").first.map(String.init) ?? ""
            let (code, rules, _) = env.runRclone(
                ["backend", "lifecycle", "\(remoteName):\(bucket)"], profile.fullRemotePath, 10)
            let advice = "use a bucket-scoped application key without deleteFiles"
            if code != 0 {
                checks.append(DoctorCheck(name: label, status: .warn,
                    detail: "could not read the B2 lifecycle rules of \(bucket); \(advice)"))
            } else if rules.range(of: #""daysFromHidingToDeleting"\s*:\s*[1-9]"#, options: .regularExpression) == nil {
                checks.append(DoctorCheck(name: label, status: .warn,
                    detail: "B2 bucket \(bucket) has no daysFromHidingToDeleting lifecycle rule, so deleted "
                        + "and overwritten files are kept as hidden versions indefinitely; \(advice)"))
            }
        }

        return checks
    }

    // MARK: - test-remote

    private static func runTestRemote(_ target: String, env: CLIEnvironment) -> Int32 {
        guard let profile = resolveProfile(target, in: env.readProfiles()) else {
            env.stderr("error: no profile matches \"\(target)\"\n")
            return 1
        }

        // Prints the remote name to the user's own terminal — fine.
        let (exit, _, err) = env.runRclone(["lsd", profile.fullRemotePath], profile.fullRemotePath, 10)
        if exit == 0 {
            env.stdout("reachable: \(profile.fullRemotePath)\n")
            return 0
        } else {
            env.stderr("unreachable: \(err.isEmpty ? "rclone exited \(exit)" : err)\n")
            return 1
        }
    }

    // MARK: - logs

    private static func runLogs(_ target: String, follow: Bool, env: CLIEnvironment) -> Int32 {
        guard let profile = resolveProfile(target, in: env.readProfiles()) else {
            env.stderr("error: no profile matches \"\(target)\"\n")
            return 1
        }
        guard env.fileExists(profile.logPath) else {
            env.stderr("error: no log file at \(profile.logPath)\n")
            return 1
        }

        if follow {
            // Spawns a real, non-terminating `tail -F` (follows the NAME, so it
            // survives the script rotating the log to `.1`) — not fake-injectable via
            // `CLIEnvironment`, so the self-test only exercises resolve +
            // exists-check above for this command.
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
            proc.arguments = ["-F", profile.logPath]
            try? proc.run()
            proc.waitUntilExit()
            return 0
        }

        if let contents = try? String(contentsOfFile: profile.logPath, encoding: .utf8) {
            env.stdout(contents)
        }
        return 0
    }

    // MARK: - listremotes

    private static func runListRemotes(env: CLIEnvironment) -> Int32 {
        let (exit, out, err) = env.runRclone(["listremotes"], nil, 10)
        if exit == 0 {
            env.stdout(out)
            return 0
        } else {
            env.stderr(err.isEmpty ? "error: rclone listremotes failed\n" : err)
            return 1
        }
    }

    // MARK: - profiles

    private static func runProfiles(env: CLIEnvironment) -> Int32 {
        let profiles = env.readProfiles()
        guard !profiles.isEmpty else {
            env.stdout("no profiles configured\n")
            return 0
        }
        for profile in profiles {
            env.stdout(
                "\(profile.name)\t\(profile.shortId)"
                    + "\tenabled=\(profile.isEnabled)\tremote=\(profile.rcloneRemote)\n"
            )
        }
        return 0
    }

    // MARK: - status

    private static func runStatus(_ target: String?, env: CLIEnvironment) -> Int32 {
        let all = env.readProfiles()
        let profiles: [SyncProfile]
        if let target {
            guard let match = resolveProfile(target, in: all) else {
                env.stderr("error: no profile matches \"\(target)\"\n")
                return 1
            }
            profiles = [match]
        } else {
            profiles = all
        }

        guard !profiles.isEmpty else {
            env.stdout(target == nil ? "no profiles configured\n" : "")
            return 0
        }

        for profile in profiles {
            let agent: String
            if !profile.isEnabled {
                agent = "n/a"
            } else {
                let (_, out) = env.runLaunchctl(["print", "gui/\(getuid())/\(profile.launchdLabel)"])
                agent = out.isEmpty ? "unloaded" : "loaded"
            }
            let running = env.fileExists(profile.lockFilePath)
            let last = env.fileExists(profile.logPath)
                ? lastLogEvent(inFileAt: profile.logPath, read: env.readFile)
                : "none"
            env.stdout(
                "\(profile.name)\t\(profile.shortId)"
                    + "\tenabled=\(profile.isEnabled)\tagent=\(agent)"
                    + "\trunning=\(running)\tlast=\(last)\n"
            )
        }
        return 0
    }

    /// Derive the last sync outcome from a log file's tail using the shared
    /// `SyncLogPatterns` — the SAME matchers `LogParser`/`SyncManager` use, so
    /// the CLI can never disagree with the app on what a log line means. Returns
    /// `started` / `completed` / `failed` / `retrying` (exit 77, limpet-plan.md
    /// L9.1) / `none`.
    static func lastLogEvent(inFileAt path: String, read: (String) -> String?) -> String {
        guard let contents = read(path) else { return "none" }
        // Scan bottom-up for the most recent recognised lifecycle line.
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            let message = String(line)
            if SyncLogPatterns.isSyncCompleted(message) { return "completed" }
            if SyncLogPatterns.isSourceChangedRetry(message) { return "retrying" }
            if SyncLogPatterns.isSyncFailed(message) { return "failed" }
            if SyncLogPatterns.isSyncStarted(message) { return "started" }
        }
        return "none"
    }

    // MARK: - sync

    /// Ask the profile's launchd-owned `limpet watch` process to sync now —
    /// the CLI never runs rclone or the sync script itself (limpet-plan.md
    /// L3(c)); `launchctl kill`'s exit status IS the liveness check. Returns
    /// immediately (does not wait for the sync to finish): unlike the old
    /// direct-run behavior, the actual sync happens in the watcher process,
    /// asynchronously — `limpet logs <id> --follow` or `limpet status` are how
    /// to observe it.
    private static func runSync(_ target: String, env: CLIEnvironment) -> Int32 {
        guard let profile = resolveProfile(target, in: env.readProfiles()) else {
            env.stderr("error: no profile matches \"\(target)\"\n")
            return 1
        }
        let (exitCode, _) = env.runLaunchctl(["kill", "SIGUSR1", "gui/\(getuid())/\(profile.launchdLabel)"])
        if exitCode == 0 {
            env.stdout("sync requested for \"\(profile.name)\" (\(profile.shortId)) — see: limpet logs \(profile.shortId)\n")
            return 0
        } else {
            env.stderr("error: no watcher running for \"\(profile.name)\" (\(profile.shortId))\n")
            return 1
        }
    }

    // MARK: - watch

    /// Run as `<profile>`'s realtime watcher — the single owner of that
    /// profile's sync scheduling (limpet-plan.md L3). NEVER returns: it parks
    /// the calling thread in `dispatchMain()` via `SyncWatchDaemon.run`. Only
    /// `resolveProfile` runs through the (fakeable) `env` here; the daemon
    /// itself always talks to the real filesystem/launchd, so this branch is
    /// exercised in the self-test only up to argument parsing/resolution —
    /// never actually invoked with `run(_: .watch, ...)`, which would hang.
    private static func runWatch(_ target: String, env: CLIEnvironment) -> Int32 {
        guard let profile = resolveProfile(target, in: env.readProfiles()) else {
            env.stderr("error: no profile matches \"\(target)\"\n")
            return 1
        }
        SyncWatchDaemon.run(profile: profile)
    }

    // MARK: - install / reinstall

    /// Install the launchd agent for an already-persisted, enabled profile —
    /// idempotent, and the complement to `profile enable` (which early-returns
    /// without installing when the profile is ALREADY enabled, so it can't
    /// re-create an agent that went missing). Never flips `isEnabled`.
    private static func runInstall(_ target: String, env: CLIEnvironment) -> Int32 {
        guard let profile = resolveProfile(target, in: env.readProfiles()) else {
            env.stderr("error: no profile matches \"\(target)\"\n")
            return 1
        }
        guard profile.isEnabled else {
            env.stderr("error: \"\(profile.name)\" is disabled; run 'limpet profile enable \(profile.shortId)' first\n")
            return 1
        }
        guard profile.isValid else {
            env.stderr("error: \"\(profile.name)\" is incomplete (name/remote/paths); fix it with 'limpet profile set' first\n")
            return 1
        }
        if let err = env.installProfile(profile) {
            env.stderr("error: install failed: \(err)\n")
            return 1
        }
        env.stdout("installed \(profile.name) (\(profile.shortId))\n")
        return 0
    }

    /// Regenerate the script/plist and reinstall the agent (uninstall → install)
    /// — the settings-save reinstall path.
    private static func runReinstall(_ target: String, env: CLIEnvironment) -> Int32 {
        guard let profile = resolveProfile(target, in: env.readProfiles()) else {
            env.stderr("error: no profile matches \"\(target)\"\n")
            return 1
        }
        guard profile.isEnabled else {
            env.stderr("error: \"\(profile.name)\" is disabled; run 'limpet profile enable \(profile.shortId)' first\n")
            return 1
        }
        guard profile.isValid else {
            env.stderr("error: \"\(profile.name)\" is incomplete (name/remote/paths); fix it with 'limpet profile set' first\n")
            return 1
        }
        // Uninstall is cleanup — a failure here is non-fatal (mirrors delete),
        // since the following install regenerates every file anyway.
        if let err = env.uninstallProfile(profile) {
            env.stderr("warning: uninstall reported: \(err)\n")
        }
        if let err = env.installProfile(profile) {
            env.stderr("error: reinstall failed: \(err)\n")
            return 1
        }
        env.stdout("reinstalled \(profile.name) (\(profile.shortId))\n")
        return 0
    }

    // MARK: - profile create

    private static func runProfileCreate(_ source: CreateSource, env: CLIEnvironment) -> Int32 {
        let raw: String?
        switch source {
        case .file(let path):
            raw = env.readFile(path)
            if raw == nil { env.stderr("error: cannot read \(path)\n"); return 66 }  // EX_NOINPUT
        case .stdin:
            raw = env.readStdin()
            if raw == nil { env.stderr("error: cannot read profile JSON from stdin\n"); return 66 }
        }

        guard let data = raw?.data(using: .utf8) else {
            env.stderr("error: profile JSON is not valid UTF-8\n")
            return 65  // EX_DATAERR
        }
        let profile: SyncProfile
        do {
            profile = try JSONDecoder().decode(SyncProfile.self, from: data)
        } catch {
            env.stderr("error: invalid profile JSON: \(error)\n")
            return 65
        }

        let existing = env.readProfiles()
        if existing.contains(where: { $0.id == profile.id || $0.shortId == profile.shortId }) {
            env.stderr("error: profile \(profile.shortId) already exists; edit its file or use 'profile enable/disable'\n")
            return 1
        }
        // F6: decode already refused F4 values; overlap needs the other profiles.
        if let reason = SyncProfile.overlapError(
            profile, among: existing, isInstalled: { env.fileExists($0.plistPath) }) {
            env.stderr("error: \(reason)\n")
            return 65
        }

        guard env.writeProfile(profile) else {
            env.stderr("error: failed to write profile file\n")
            return 1
        }

        // Persist unless refused (above), install-iff-ready — the SAME rule the file-watcher
        // create path applies (`SyncManager.applyExternalCreateIfNeeded`).
        guard profile.isEnabled, profile.isValid else {
            env.stdout("created \(profile.name) (\(profile.shortId)) — not installed (disabled or incomplete)\n")
            return 0
        }
        if let err = env.installProfile(profile) {
            env.stderr("created \(profile.shortId) but install failed: \(err)\n")
            return 1
        }
        env.stdout("created \(profile.name) (\(profile.shortId)) — installed\n")
        return 0
    }

    // MARK: - profile show

    /// Print one profile's FULL config as pretty JSON — the same shape as the
    /// authoritative `.profile.json`, so an agent can `profile show` → edit →
    /// `profile create`/`profile set` round-trip. Stable key order (sorted) so a
    /// diff between two shows is meaningful.
    private static func runProfileShow(_ target: String, env: CLIEnvironment) -> Int32 {
        guard let profile = resolveProfile(target, in: env.readProfiles()) else {
            env.stderr("error: no profile matches \"\(target)\"\n")
            return 1
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(profile),
              let json = String(data: data, encoding: .utf8) else {
            env.stderr("error: failed to encode profile \(profile.shortId)\n")
            return 1
        }
        env.stdout(json + "\n")
        return 0
    }

    // MARK: - profile delete

    private static func runProfileDelete(_ target: String, env: CLIEnvironment) -> Int32 {
        guard let profile = resolveProfile(target, in: env.readProfiles()) else {
            env.stderr("error: no profile matches \"\(target)\"\n")
            return 1
        }
        if let err = env.uninstallProfile(profile) {
            env.stderr("warning: uninstall reported: \(err)\n")
        }
        env.deleteProfileFile(profile)
        env.stdout("deleted \(profile.name) (\(profile.shortId))\n")
        return 0
    }

    // MARK: - profile enable / disable

    private static func runProfileSetEnabled(_ target: String, enabled: Bool, env: CLIEnvironment) -> Int32 {
        let all = env.readProfiles()
        guard let profile = resolveProfile(target, in: all) else {
            env.stderr("error: no profile matches \"\(target)\"\n")
            return 1
        }
        guard profile.isEnabled != enabled else {
            env.stdout("\(profile.shortId) already \(enabled ? "enabled" : "disabled")\n")
            return 0
        }

        var updated = profile
        updated.isEnabled = enabled
        // F6: enabling makes the profile take part in the overlap rule; refuse
        // BEFORE the enabled flag is persisted.
        if let reason = SyncProfile.overlapError(
            updated, among: all, isInstalled: { env.fileExists($0.plistPath) }) {
            env.stderr("error: \(reason)\n")
            return 65
        }
        guard env.writeProfile(updated) else {
            env.stderr("error: failed to write profile file\n")
            return 1
        }

        // Reuse the single source of truth for the launchd delta.
        let action = SyncManager.reconcileAction(from: profile, to: updated)
        if let err = applyLaunchdReconcile(action, current: profile, updated: updated, env: env) {
            env.stderr("\(enabled ? "enabled" : "disabled") \(profile.shortId) but launchd step failed: \(err)\n")
            return 1
        }
        env.stdout("\(enabled ? "enabled" : "disabled") \(profile.name) (\(profile.shortId))\n")
        return 0
    }

    /// Apply the launchd side effect a `ProfileReconcileAction` implies, over the
    /// injected `env` closures — the SINGLE place the CLI turns a reconcile delta
    /// into install/uninstall calls, shared by `profile enable/disable` and
    /// `profile set` so they can never route a delta differently. A `.reinstall`
    /// is an uninstall of the OLD profile then an install of the NEW one — the
    /// same order the app's settings-save path uses. Returns an error message
    /// or `nil`.
    private static func applyLaunchdReconcile(
        _ action: ProfileReconcileAction,
        current: SyncProfile,
        updated: SyncProfile,
        env: CLIEnvironment
    ) -> String? {
        switch action {
        case .none:
            return nil
        case .install:
            return env.installProfile(updated)
        case .uninstall:
            return env.uninstallProfile(current)
        case .reinstall:
            if let err = env.uninstallProfile(current) { return err }
            return env.installProfile(updated)
        }
    }

    // MARK: - profile set

    /// Edit fields on an existing profile headlessly, rewrite the authoritative
    /// `.profile.json`, and drive the correct launchd reconcile
    /// (`SyncManager.reconcileAction`). The key set is bounded and enumerated in
    /// `applyProfileAssignment`; an unknown key or invalid value is a greppable
    /// `error:` and rewrites NOTHING (all assignments are validated against a copy
    /// before any write).
    private static func runProfileSet(_ target: String, assignments: [ProfileAssignment], env: CLIEnvironment) -> Int32 {
        let all = env.readProfiles()
        guard let original = resolveProfile(target, in: all) else {
            env.stderr("error: no profile matches \"\(target)\"\n")
            return 1
        }

        // Validate + apply against a copy first — a bad key/value never touches disk.
        var updated = original
        for assignment in assignments {
            if let err = applyProfileAssignment(&updated, key: assignment.key, value: assignment.value) {
                env.stderr("error: \(err)\n")
                return 65  // EX_DATAERR
            }
        }
        // F4/F6 on the result as a whole: the overlap depends on remote and path together.
        if let reason = updated.validationError
            ?? SyncProfile.overlapError(updated, among: all, isInstalled: { env.fileExists($0.plistPath) }) {
            env.stderr("error: \(reason)\n")
            return 65
        }

        guard updated != original else {
            env.stdout("no changes for \(original.name) (\(original.shortId))\n")
            return 0
        }

        guard env.writeProfile(updated) else {
            env.stderr("error: failed to write profile file\n")
            return 1
        }

        let action = SyncManager.reconcileAction(from: original, to: updated)
        if let err = applyLaunchdReconcile(action, current: original, updated: updated, env: env) {
            env.stderr("updated \(original.shortId) but launchd step failed: \(err)\n")
            return 1
        }

        let changed = assignments.map { $0.key }.joined(separator: ", ")
        env.stdout("updated \(updated.name) (\(updated.shortId)) — \(changed)\n")
        return 0
    }

    /// Apply one `key`→`value` assignment to `profile` in place. Returns an error
    /// message (unknown key, or a value that fails validation) or `nil` on
    /// success. The key set MIRRORS `SyncProfile.CodingKeys` minus two
    /// deliberately-excluded keys: `id` (immutable) and `isEnabled` (use
    /// enable/disable). Pure — no I/O — so the
    /// self-test drives the whole matrix without touching disk.
    static func applyProfileAssignment(_ profile: inout SyncProfile, key: String, value: String) -> String? {
        func bool(_ raw: String) -> Bool? {
            switch raw.lowercased() {
            case "true", "1", "yes", "on": return true
            case "false", "0", "no", "off": return false
            default: return nil
            }
        }
        func int(_ raw: String) -> Int? { Int(raw) }
        func requireNonEmpty() -> String? {
            value.isEmpty ? "\(key) cannot be empty" : nil
        }

        switch key {
        // Required strings (empty would break isValid — reject explicitly).
        case "name": if let e = requireNonEmpty() { return e }; profile.name = value
        case "rcloneRemote": if let e = requireNonEmpty() { return e }; profile.rcloneRemote = value
        case "remotePath": if let e = requireNonEmpty() { return e }; profile.remotePath = value
        case "localSyncPath": if let e = requireNonEmpty() { return e }; profile.localSyncPath = value

        // Optional strings.
        case "drivePathToMonitor": profile.drivePathToMonitor = value
        case "additionalRcloneFlags": profile.additionalRcloneFlags = value

        // Ints (with range validation where the model clamps).
        case "syncIntervalMinutes":
            guard let n = int(value), n >= 1 else { return "syncIntervalMinutes must be an integer ≥ 1" }
            profile.syncIntervalMinutes = n
        case "transfers":
            // 1–64, digits only, no leading zero (bash reads `08` as octal).
            guard let first = value.first, first != "0", value.allSatisfy(\.isASCII),
                  value.allSatisfy(\.isNumber), let n = int(value), (1...64).contains(n) else {
                return "transfers must be a whole number from 1 to 64 without a leading zero"
            }
            profile.transfers = n
        case "maxDelete":
            guard let n = int(value), n >= 1 else { return "maxDelete must be an integer ≥ 1" }
            profile.maxDelete = n
        case "trashDays":
            // 0...365, matching SyncProfile.validationError's rule (0 = off).
            guard let n = int(value), (0...365).contains(n) else {
                return "trashDays must be an integer from 0 to 365"
            }
            profile.trashDays = n
        case "remoteVersioning":
            guard let b = bool(value) else { return "remoteVersioning must be true or false" }
            profile.remoteVersioning = b

        // Bools.
        case "isMuted":
            guard let b = bool(value) else { return "isMuted must be true or false" }
            profile.isMuted = b

        // Enums.
        case "syncDirection":
            guard let d = SyncDirection(rawValue: value) else {
                return "syncDirection must be one of: \(SyncDirection.allCases.map(\.rawValue).joined(separator: "|"))"
            }
            profile.syncDirection = d

        // Explicitly excluded keys — greppable, with the right command to use.
        case "id":
            return "id is immutable and cannot be changed"
        case "isEnabled":
            return "use 'limpet profile enable|disable' to change isEnabled"

        default:
            return "unknown key \"\(key)\" (see 'limpet help' for the profile set key list)"
        }
        return nil
    }

    // MARK: - profile clear-delete-limit

    /// Remove the persistent delete-limit marker (limpet-plan.md L4 F6), then
    /// ask the watcher to sync now — the same SIGUSR1 request `limpet sync` sends.
    private static func runClearDeleteLimit(_ target: String, env: CLIEnvironment) -> Int32 {
        guard let profile = resolveProfile(target, in: env.readProfiles()) else {
            env.stderr("error: no profile matches \"\(target)\"\n")
            return 1
        }
        let marker = profile.deleteLimitMarkerPath
        guard env.fileExists(marker) else {
            env.stdout("no delete limit is set for \(profile.name) (\(profile.shortId))\n")
            return 0
        }
        guard env.removeFile(marker) else {
            env.stderr("error: could not remove \(marker)\n")
            return 1
        }
        let (exitCode, _) = env.runLaunchctl(["kill", "SIGUSR1", "gui/\(getuid())/\(profile.launchdLabel)"])
        env.stdout("cleared the delete limit for \(profile.name) (\(profile.shortId)); "
            + (exitCode == 0 ? "sync requested\n" : "no watcher running, it syncs when its agent next starts\n"))
        return 0
    }

    // MARK: - remote add

    /// Create a keychain-backed remote through the SAME function the wizard
    /// uses (`RcloneConfigService.addKeychainRemote`). The secret comes from
    /// `readSecret` only and is never printed.
    private static func runRemoteAdd(_ request: RemoteAddRequest, env: CLIEnvironment) -> Int32 {
        guard let secret = env.readSecret("Secret for \(request.name): "), !secret.isEmpty else {
            env.stderr("error: no secret given (type it at the prompt, or pipe one line on stdin)\n")
            return 66  // EX_NOINPUT
        }
        if let error = env.addKeychainRemote(request.name, request.type, request.values, secret) {
            env.stderr("error: \(error)\n")
            return 1
        }
        env.stdout("added \(request.type) remote \(request.name): secret stored in the login keychain "
            + "(service \(KeychainSecretStore.service)), rclone.conf has no secret\n")
        if request.type == "b2" {
            env.stdout("note: use a bucket-scoped application key without the deleteFiles capability\n")
        }
        return 0
    }

    // MARK: - trash

    /// F6/limpet-plan.md L6.2 item 5: refused BEFORE any rclone call — empty,
    /// absolute, or carrying an empty/`.`/`..` component (any of which could
    /// escape `localSyncPath` on restore, or address something outside the
    /// trash tree).
    static func validateTrashRelativePath(_ path: String) -> String? {
        guard !path.isEmpty, !path.hasPrefix("/") else {
            return "path must be a non-empty, non-absolute relative path"
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return "path must not contain an empty, \".\" or \"..\" component"
        }
        return nil
    }

    /// `validateTrashRelativePath` is syntax only: a SYMLINK already inside
    /// `localSyncPath` (`sub -> /outside`) lets `sub/file` pass it, and the
    /// temp `copyto` and final rename both address paths through that link
    /// (CodeRabbit, PR #10). Measured 2026-09-28, rclone 1.75.1: today only
    /// the `links` option of the `:local,links:` destination stops the copy
    /// ("need \".rclonelink\" suffix to refer to symlink", exit 1, nothing
    /// written); a plain local destination DOES write through the link. That
    /// is incidental, not a guarantee, so containment is checked here, before
    /// any rclone call. The destination's
    /// PARENT is resolved against the real filesystem and must lie inside the
    /// resolved `localSyncPath`. Components that do not exist yet cannot be
    /// links, so the nearest EXISTING ancestor is what gets resolved; an
    /// existing entry that cannot be resolved (a dangling symlink) is refused.
    /// The destination entry itself is not resolved here — a symlink there is
    /// never followed (see `runTrashRestore`). Returns an error, or `nil`.
    static func trashRestoreContainmentError(
        localSyncPath: String, relativePath: String, env: CLIEnvironment
    ) -> String? {
        func resolve(_ path: String) -> String? {
            var existing = path
            var missing: [String] = []
            while !existing.isEmpty, existing != "/", !env.itemExists(existing) {
                missing.insert((existing as NSString).lastPathComponent, at: 0)
                existing = (existing as NSString).deletingLastPathComponent
            }
            guard let real = env.realPath(existing) else { return nil }
            return missing.reduce(real) { ($0 as NSString).appendingPathComponent($1) }
        }
        let target = (localSyncPath as NSString).appendingPathComponent(relativePath)
        guard let root = resolve(localSyncPath),
              let parent = resolve((target as NSString).deletingLastPathComponent) else {
            return "cannot resolve the real path of \(target)'s directory"
        }
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"
        guard parent == root || parent.hasPrefix(rootPrefix) else {
            return "\(relativePath) resolves outside \(localSyncPath) (through a symlink); refusing to restore there"
        }
        return nil
    }

    /// `--date` must be exactly `YYYY-MM-DD` — refused before any rclone call.
    static func validateTrashDate(_ date: String?) -> String? {
        guard let date else { return nil }
        guard date.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else {
            return "--date must match YYYY-MM-DD"
        }
        return nil
    }

    /// Whether `candidate` is `original` with rclone's `--suffix -HHMMSS
    /// --suffix-keep-extension` (a literal `-` + exactly 6 digits) inserted at
    /// one `.` boundary of `original`, or at its very end. Tries EVERY dot
    /// boundary rather than re-deriving rclone's own extension-split rule
    /// (limpet-plan.md L6.2 item 5, measured 2026-09-28: `a.tar.gz` splits at
    /// the FIRST dot -> `a-100003.tar.gz`, but `x.min.js` splits at the LAST
    /// dot -> `x.min-100003.js`) — only one boundary can produce a match
    /// against a real rclone-generated name. Returns the 6-digit suffix.
    static func trashSuffixMatch(candidate: String, original: String) -> String? {
        var boundaries: [String.Index] = [original.endIndex]
        boundaries.append(contentsOf: original.indices.filter { original[$0] == "." })
        for pos in boundaries {
            let prefix = String(original[original.startIndex..<pos])
            let ext = String(original[pos...])
            let marker = "\(prefix)-"
            guard candidate.hasPrefix(marker), candidate.hasSuffix(ext),
                  candidate.count >= marker.count + ext.count else { continue }
            let start = candidate.index(candidate.startIndex, offsetBy: marker.count)
            let end = candidate.index(candidate.endIndex, offsetBy: -ext.count)
            guard start <= end else { continue }
            let digits = String(candidate[start..<end])
            guard digits.count == 6, digits.allSatisfy(\.isNumber) else { continue }
            return digits
        }
        return nil
    }

    /// The newest trashed version of `dirComponent`/`baseName` (or its
    /// `.rclonelink` form, for a symlink on a remote without native symlink
    /// support) in a `rclone lsf -R` `listing`. When `dateFixed` is `nil` each
    /// line is `<date>/<relative path>` (a whole-root listing); otherwise
    /// every line is relative to that one date's folder already. Ties broken
    /// by date (lexicographic `YYYY-MM-DD` sorts chronologically), then by the
    /// highest 6-digit suffix. Pure — the self-test drives it over fixture
    /// text without touching rclone.
    static func newestTrashMatch(
        listing: String, dateFixed: String?, dirComponent: String, baseName: String
    ) -> TrashMatch? {
        var best: TrashMatch?
        // Plain name first, so a same-suffix collision (unlikely: a 6-digit
        // stamp is exact) prefers the non-symlink form; either candidate that
        // actually matches is scored against `best` the same way.
        let candidates: [(name: String, isSymlink: Bool)] = [(baseName, false), ("\(baseName).rclonelink", true)]
        for rawLine in listing.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            let date: String
            let relativeToDate: String
            if let dateFixed {
                date = dateFixed
                relativeToDate = line
            } else {
                guard let slash = line.firstIndex(of: "/") else { continue }
                let candidateDate = String(line[line.startIndex..<slash])
                guard candidateDate.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else {
                    continue
                }
                date = candidateDate
                relativeToDate = String(line[line.index(after: slash)...])
            }
            guard (relativeToDate as NSString).deletingLastPathComponent == dirComponent else { continue }
            let entryName = (relativeToDate as NSString).lastPathComponent
            for candidate in candidates {
                guard let suffix = trashSuffixMatch(candidate: entryName, original: candidate.name) else { continue }
                let match = TrashMatch(date: date, entry: line, suffix: suffix, isSymlink: candidate.isSymlink)
                if best == nil || isNewerTrashMatch(match, than: best!) { best = match }
                break
            }
        }
        return best
    }

    private static func isNewerTrashMatch(_ a: TrashMatch, than b: TrashMatch) -> Bool {
        if a.date != b.date { return a.date > b.date }
        return (Int(a.suffix) ?? -1) > (Int(b.suffix) ?? -1)
    }

    /// `lsf -R` over a whole trash root can be a large listing; generous but
    /// not unbounded (code-review finding 3 on 87bbf67: the old 20s cap was
    /// arbitrary for a possibly-large `.limpet-trash`).
    private static let trashListTimeout: TimeInterval = 600
    /// A restored file can be arbitrarily large (it is exactly a file the
    /// profile once synced); effectively no limit rather than the old
    /// arbitrary 60s (code-review finding 3 on 87bbf67).
    private static let trashRestoreTimeout: TimeInterval = 86400

    private static func runTrashList(_ target: String, date: String?, env: CLIEnvironment) -> Int32 {
        guard let profile = resolveProfile(target, in: env.readProfiles()) else {
            env.stderr("error: no profile matches \"\(target)\"\n")
            return 1
        }
        if let err = validateTrashDate(date) {
            env.stderr("error: \(err)\n")
            return 65
        }
        // Finding 4: list/restore use the path FORMULA alone (ignoring
        // trashDays/direction/versioning), so they keep working to inspect
        // old trash after the profile changed or trash was switched off.
        guard let root = SyncSetupService.trashRootPath(for: profile) else {
            env.stdout("\(profile.name) (\(profile.shortId)) can have no trash root: remotePath \"\(profile.remotePath)\" has no parent\n")
            return 0
        }
        let listPath = date.map { "\(root)/\($0)" } ?? root
        let (exit, out, err) = env.runRclone(["lsf", "-R", listPath], profile.rcloneRemote, trashListTimeout)
        guard exit == 0 else {
            env.stderr(err.isEmpty ? "error: rclone lsf failed (exit \(exit))\n" : err)
            return 1
        }
        env.stdout(out)
        return 0
    }

    private static func runTrashRestore(
        _ target: String, relativePath: String, date: String?, force: Bool, env: CLIEnvironment
    ) -> Int32 {
        guard let profile = resolveProfile(target, in: env.readProfiles()) else {
            env.stderr("error: no profile matches \"\(target)\"\n")
            return 1
        }
        if let err = validateTrashRelativePath(relativePath) {
            env.stderr("error: \(err)\n")
            return 65
        }
        if let err = validateTrashDate(date) {
            env.stderr("error: \(err)\n")
            return 65
        }
        if let err = trashRestoreContainmentError(
            localSyncPath: profile.localSyncPath, relativePath: relativePath, env: env) {
            env.stderr("error: \(err)\n")
            return 65
        }
        // Finding 4: path formula alone, same reasoning as runTrashList.
        guard let root = SyncSetupService.trashRootPath(for: profile) else {
            env.stderr("error: \(profile.name) (\(profile.shortId)) can have no trash root: "
                + "remotePath \"\(profile.remotePath)\" has no parent\n")
            return 1
        }
        let localTarget = (profile.localSyncPath as NSString).appendingPathComponent(relativePath)
        // lstat, not stat: a symlink at the destination (dangling or not) is
        // an existing entry. rclone only ever writes the temp name, and the
        // final rename replaces the link itself, so the link is never followed.
        guard force || !env.itemExists(localTarget) else {
            env.stderr("error: \(localTarget) already exists; pass --force to overwrite\n")
            return 1
        }
        let listPath = date.map { "\(root)/\($0)" } ?? root
        let (listExit, listing, listErr) = env.runRclone(["lsf", "-R", listPath], profile.rcloneRemote, trashListTimeout)
        guard listExit == 0 else {
            env.stderr(listErr.isEmpty ? "error: rclone lsf failed (exit \(listExit))\n" : listErr)
            return 1
        }
        let dirComponent = (relativePath as NSString).deletingLastPathComponent
        let baseName = (relativePath as NSString).lastPathComponent
        guard let match = Self.newestTrashMatch(
            listing: listing, dateFixed: date, dirComponent: dirComponent, baseName: baseName) else {
            env.stderr("error: no trashed version of \(relativePath) found\n")
            return 1
        }
        let sourcePath = "\(listPath)/\(match.entry)"

        // Restore to a TEMP name in the same directory, then rename into
        // place on success — a failed copyto must never leave a partial file
        // at `localTarget` (code-review finding 3 on 87bbf67).
        let tempTarget = "\(localTarget).limpet-restore-tmp"
        // Never delete whatever sits at the temp path: it may be the user's own
        // file. limpet removes its temp on every failure path, so an existing
        // one is not ours to discard (CodeRabbit, PR #10); --force does not
        // bypass this.
        guard !env.itemExists(tempTarget) else {
            env.stderr("error: \(tempTarget) already exists; refusing to overwrite it — move or delete it, then retry\n")
            return 1
        }

        // A `.rclonelink` MATCH is a symlink stored as a plain content object
        // (the remote has no native symlink support) — `rclone copyto` alone
        // writes that content literally, as a regular file. Measured
        // 2026-09-28: destination `":local,links:<path>.rclonelink"` (an
        // rclone "connection string" override, LOCAL side only — the source
        // is read as a plain object, never itself touched by `--links`) makes
        // the local backend strip the suffix and create a REAL symlink at
        // `<path>`, pointing at the object's text content:
        //   rclone --config /dev/null copyto <src>/l-100003.txt.rclonelink \
        //     ":local,links:<dst>/l.txt.rclonelink"
        //   -> creates a real symlink <dst>/l.txt -> a.tar.gz
        // A plain (non-symlink) restore uses the same destination form
        // without the suffix; that also measured as an ordinary file copy
        // (the `links` local-backend option only changes `.rclonelink`
        // handling), so one destination shape covers both cases uniformly.
        let destinationArg = match.isSymlink ? ":local,links:\(tempTarget).rclonelink" : ":local,links:\(tempTarget)"
        let (copyExit, _, copyErr) = env.runRclone(["copyto", sourcePath, destinationArg], profile.rcloneRemote, trashRestoreTimeout)
        guard copyExit == 0 else {
            _ = env.removeFile(tempTarget)
            env.stderr(copyErr.isEmpty ? "error: restore failed (exit \(copyExit))\n" : copyErr)
            return 1
        }
        guard env.moveFile(tempTarget, localTarget, force) else {
            _ = env.removeFile(tempTarget)
            env.stderr("error: restored to \(tempTarget) but could not move it into place at \(localTarget)\n")
            return 1
        }
        env.stdout("restored \(relativePath) from \(sourcePath) to \(localTarget)\n")
        return 0
    }
}

// MARK: - Production environment

extension CLIEnvironment {
    /// The real `CLIEnvironment`: actual `Process` invocations, actual
    /// filesystem reads, actual stdio. Built off `@MainActor` — the CLI never
    /// touches `ProfileStore`/`SyncManager`, only the `nonisolated`
    /// `ProfileStore.profilesOnDisk(in:)` file read.
    static func production() -> CLIEnvironment {
        CLIEnvironment(
            runRclone: { args, remote, timeout in
                var environment = ProcessInfo.processInfo.environment
                if let remote {
                    // F3: never start rclone without the remote's secret.
                    var keychainError = ""
                    guard let merged = RcloneConfigService.shared.processEnvironment(
                        forRemote: remote, log: { keychainError = $0 }) else {
                        return (78, "", keychainError)  // EX_CONFIG
                    }
                    environment = merged
                }
                return CLIEnvironment.runRcloneProcess(args: args, environment: environment, timeout: timeout)
            },
            readProfiles: { ProfileStore.profilesOnDisk(in: SyncProfile.configDirectory) },
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            itemExists: CLIEnvironment.lstatExists,
            realPath: CLIEnvironment.resolvedRealPath,
            runLaunchctl: { args in CLIEnvironment.runProcess(launchPath: "/bin/launchctl", args: args) },
            schemaFilesPresent: {
                ConfigSchemaInstaller.schemaResourceFilenames.allSatisfy {
                    FileManager.default.fileExists(atPath: "\(ConfigSchemaInstaller.schemaDirectory())/\($0)")
                }
            },
            remoteSection: { RcloneConfigService.shared.section(named: $0) },
            writeProfile: { profile in
                // limpet-plan.md L6.1 change A: note the marker BEFORE writing,
                // hashing the SAME bytes `writeProfileFile` is about to write —
                // only the CLI's write closure does this (ProfileStore itself
                // stays marker-free for the app's own writes), so the running
                // app's ConfigFileWatcher can tell "the CLI already reconciled
                // this" from "a hand edit, reconcile normally". A refused
                // profile hashes to `nil` and notes nothing, matching
                // `writeProfileFile`'s own refusal a line below.
                let hash = ProfileStore.encodedProfileFileData(profile).map(ConfigSelfWriteRegistry.hash)
                if let hash { CLIWriteMarker.note(contentHash: hash) }
                let wrote = ProfileStore.writeProfileFile(profile, in: SyncProfile.configDirectory) != nil
                // A marker for a write that never happened would let a later
                // identical hand edit skip its reconcile (CodeRabbit, PR #9).
                if !wrote, let hash { _ = CLIWriteMarker.consume(hash: hash) }
                return wrote
            },
            installProfile: { profile in
                do { try SyncSetupService.shared.install(profile: profile); return nil }
                catch { return "\(error)" }
            },
            uninstallProfile: { profile in
                do { try SyncSetupService.shared.uninstall(profile: profile); return nil }
                catch { return "\(error)" }
            },
            deleteProfileFile: { profile in
                let path = "\(SyncProfile.configDirectory)/\(profile.shortId).profile.json"
                try? FileManager.default.removeItem(atPath: path)
                try? FileManager.default.removeItem(atPath: profile.filterFilePath)
            },
            removeFile: { (try? FileManager.default.removeItem(atPath: $0)) != nil },
            moveFile: { from, to, replace in
                replace ? CLIEnvironment.moveReplacing(from, to) : CLIEnvironment.moveNoReplace(from, to)
            },
            readStdin: {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                return String(data: data, encoding: .utf8)
            },
            readFile: { try? String(contentsOfFile: $0, encoding: .utf8) },
            readSecret: { prompt in
                guard isatty(STDIN_FILENO) != 0 else { return readLine(strippingNewline: true) }
                var buffer = [CChar](repeating: 0, count: 1024)
                defer { for i in buffer.indices { buffer[i] = 0 } }
                guard readpassphrase(prompt, &buffer, buffer.count, RPP_ECHO_OFF) != nil else { return nil }
                return String(cString: buffer)
            },
            addKeychainRemote: { name, type, values, secret in
                do {
                    try RcloneConfigService.shared.addKeychainRemote(name: name, type: type, values: values, secret: secret)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            },
            stdout: { FileHandle.standardOutput.write(Data($0.utf8)) },
            stderr: { FileHandle.standardError.write(Data($0.utf8)) }
        )
    }

    /// `moveFile` for production. The old remove-then-move lost BOTH files
    /// when the move failed (CodeRabbit, PR #10). An existing destination
    /// entry (lstat, so a dangling symlink too) is replaced with rename(2),
    /// which swaps the directory entry atomically: on failure nothing
    /// changed, and neither side's symlink is followed. `moveItem` only when
    /// no entry exists (it refuses to overwrite one that appeared meanwhile).
    /// `FileManager.replaceItemAt` was measured unsuitable 2026-09-28 (macOS
    /// 27): it throws whenever the destination OR the source is a symlink
    /// (dangling or not), so a forced restore over a symlink, or of a
    /// symlink, could never succeed; and it REPLACED a non-empty directory
    /// with a file (the directory and its contents gone). rename(2)
    /// measured: file over symlink replaces the link (target untouched),
    /// file over dangling symlink, symlink over file, missing source ->
    /// ENOENT with the destination intact, file over a non-empty directory
    /// -> EISDIR with it intact.
    static func moveReplacing(_ from: String, _ to: String) -> Bool {
        if lstatExists(to) { return rename(from, to) == 0 }
        return (try? FileManager.default.moveItem(atPath: from, toPath: to)) != nil
    }

    /// Atomic move that never replaces: renamex_np(RENAME_EXCL) fails with
    /// EEXIST if any item (a dangling symlink included) exists at `to`.
    static func moveNoReplace(_ from: String, _ to: String) -> Bool {
        renamex_np(from, to, UInt32(RENAME_EXCL)) == 0
    }

    /// `itemExists` for production: lstat, so a dangling symlink exists.
    static func lstatExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// `realPath` for production: realpath(3); `nil` on any failure.
    static func resolvedRealPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Run rclone at its located path with a hard process-level watchdog —
    /// mirrors `RcloneLocator.resolveViaLoginShell`'s timeout pattern, since
    /// SMB/WebDAV remotes can hang past rclone's own `--timeout`.
    fileprivate static func runRcloneProcess(
        args: [String], environment: [String: String], timeout: TimeInterval
    ) -> (Int32, String, String) {
        guard let rclonePath = RcloneLocator.resolve() else {
            return (127, "", "rclone not found")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: rclonePath)
        proc.arguments = args
        proc.environment = environment
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do {
            try proc.run()
        } catch {
            return (-1, "", "\(error)")
        }

        let watchdog = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        // Drain stdout and stderr CONCURRENTLY. Reading one to EOF before the
        // other deadlocks when the child fills the still-unread pipe's ~64 KB
        // buffer — exactly what an unreachable remote does to stderr, the very
        // buffer test-remote/doctor need. (RcloneLocator sidesteps this by
        // nulling stderr; here we need it, so we drain both at once.)
        var errData = Data()
        let errGroup = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: errGroup) {
            errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        errGroup.wait()
        proc.waitUntilExit()
        watchdog.cancel()

        return (
            proc.terminationStatus,
            String(decoding: outData, as: UTF8.self),
            String(decoding: errData, as: UTF8.self)
        )
    }

    fileprivate static func runProcess(launchPath: String, args: [String], timeout: TimeInterval = 10) -> (Int32, String) {
        if SelfTestGuard.refuses(launchPath, args) { return (1, "") }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        // stderr → /dev/null: callers use only stdout + the exit code, and an
        // unread stderr Pipe can deadlock if the child fills its buffer.
        // nullDevice removes both the unread read and the deadlock.
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return (-1, "")
        }
        // Watchdog so a wedged child (e.g. a hung launchctl) can't block forever.
        let watchdog = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        watchdog.cancel()
        return (proc.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
