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
    case remoteAdd(RemoteAddRequest)
    case help
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
    /// Run `launchctl` with `args`. Returns `(exitCode, stdout)`.
    var runLaunchctl: (_ args: [String]) -> (Int32, String)
    /// Whether the JSON schema files are installed under the config directory.
    var schemaFilesPresent: () -> Bool
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
      install <name|id>            Install an enabled profile's launchd agent (idempotent)
      reinstall <name|id>          Regenerate script+plist and reinstall the agent
      remote add <name> --type s3|b2 --access-key-id <id> [--provider <p>] [--endpoint <https url>] [--region <r>]
                                   Add a remote whose secret lives in the login keychain;
                                   the secret is read from stdin (no-echo prompt on a terminal)

    Operate:
      sync <name|id>                          Ask the profile's watcher to sync now (returns immediately)
      watch <name|id>                         Run as the profile's realtime watcher (launchd only; never exits)

    profile set keys: name, rcloneRemote, remotePath, localSyncPath,
      drivePathToMonitor, additionalRcloneFlags,
      syncDirection (localToRemote|remoteToLocal), syncIntervalMinutes,
      transfers, isMuted. Use enable/disable for isEnabled.

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
            values["provider"] = flags["--provider"]
            values["region"] = flags["--region"]
            values["endpoint"] = flags["--endpoint"]
            // MEGA S4's endpoints are s3.<region>.megas4.com (rclone 1.75.1's own list).
            if flags["--provider"] == "Mega", values["endpoint"] == nil, let region = flags["--region"] {
                values["endpoint"] = "s3.\(region).megas4.com"
            }
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
        case .remoteAdd(let request):
            return runRemoteAdd(request, env: env)
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
            // Spawns a real, non-terminating `tail -f` — not fake-injectable via
            // `CLIEnvironment`, so the self-test only exercises resolve +
            // exists-check above for this command.
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
            proc.arguments = ["-f", profile.logPath]
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
    /// `started` / `completed` / `failed` / `none`.
    static func lastLogEvent(inFileAt path: String, read: (String) -> String?) -> String {
        guard let contents = read(path) else { return "none" }
        // Scan bottom-up for the most recent recognised lifecycle line.
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            let message = String(line)
            if SyncLogPatterns.isSyncCompleted(message) { return "completed" }
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
        if let reason = SyncProfile.overlapError(profile, among: existing) {
            env.stderr("error: \(reason)\n")
            return 65
        }

        guard env.writeProfile(profile) else {
            env.stderr("error: failed to write profile file\n")
            return 1
        }

        // Persist-always, install-iff-ready — the SAME rule the file-watcher
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
        guard let profile = resolveProfile(target, in: env.readProfiles()) else {
            env.stderr("error: no profile matches \"\(target)\"\n")
            return 1
        }
        guard profile.isEnabled != enabled else {
            env.stdout("\(profile.shortId) already \(enabled ? "enabled" : "disabled")\n")
            return 0
        }

        var updated = profile
        updated.isEnabled = enabled
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
        if let reason = updated.validationError ?? SyncProfile.overlapError(updated, among: all) {
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
            guard let n = int(value), n >= 1 else { return "transfers must be an integer ≥ 1" }
            profile.transfers = n

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
            runLaunchctl: { args in CLIEnvironment.runProcess(launchPath: "/bin/launchctl", args: args) },
            schemaFilesPresent: {
                ConfigSchemaInstaller.schemaResourceFilenames.allSatisfy {
                    FileManager.default.fileExists(atPath: "\(ConfigSchemaInstaller.schemaDirectory())/\($0)")
                }
            },
            writeProfile: { profile in
                ProfileStore.writeProfileFile(profile, in: SyncProfile.configDirectory) != nil
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
