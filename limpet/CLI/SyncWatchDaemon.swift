import Foundation

/// `limpet watch <profileId>` — the launchd-owned realtime scheduler for one
/// profile (limpet-plan.md L3). Run as a `KeepAlive=true, RunAtLoad=true`
/// LaunchAgent (see `SyncSetupService.generateLaunchdPlist`), this process is
/// the SOLE owner of that profile's sync scheduling: a catch-up sync at
/// start, FSEvents-triggered syncs (debounced by the reused `DirectoryWatcher`),
/// a periodic safety sync every `syncIntervalMinutes`, and a SIGUSR1 "sync
/// now" request from the GUI or `limpet sync`. The GUI app never runs rclone
/// or the sync script itself, and never touches the lock file — see
/// `SyncManager.triggerManualSync` and the static grep self-test in
/// `ConfigSelfTest`.
/// Thread-safe state for the currently-running (or currently-spawning) sync
/// child (limpet-plan.md L6.1 change B, code-review finding 7).
/// `runSyncChild`/`runChildProcess` run on a background global queue; the
/// SIGTERM/SIGINT handler runs on `.main` — this is the one piece of state
/// both sides touch, so it needs its own lock rather than living as a plain
/// var on either side.
///
/// A PID recorded only AFTER `Process.run()` returns leaves a window — SIGTERM
/// arriving between spawn and the PID being stored finds nothing to kill, and
/// exits anyway, orphaning the just-spawned group (finding 7). Closing that
/// window needs a third state, `.spawning`, bracketing the window itself, plus
/// a `terminating` flag: if termination is requested while `.spawning`, the
/// HANDLER does not exit — `spawned(pid:)` does, immediately after storing the
/// PID, since it is the first code to actually know the PID.
///
/// Every method here is a PURE decision under one lock acquisition — neither
/// `killpg` nor `exit` is called from inside this type. That is deliberate:
/// it lets a self-test drive the exact state machine (`beginSpawning` →
/// `requestTermination` → `spawned`) and assert the decision it returns,
/// without a test process ever calling real `exit()` on itself. The actual
/// `killpg`/`exit` side effects live in `SyncWatchDaemon`'s callers, which
/// only code review and the plan's live check cover — see `AC-L61-7`.
final class RunningChildState {
    private enum State { case idle, spawning, running(pid_t) }
    private var state: State = .idle
    private var terminating = false
    private let lock = NSLock()

    init() {}

    /// Call immediately BEFORE spawning.
    func beginSpawning() {
        lock.lock()
        state = .spawning
        lock.unlock()
    }

    /// What `spawned(pid:)` decided: `.ok` (nothing pending) or
    /// `.killAndExitNow(pid)` — a termination arrived while `.spawning`, and
    /// this is the first point a PID was known to kill.
    enum SpawnOutcome: Equatable { case ok, killAndExitNow(pid_t) }

    /// Call immediately after `Process.run()` either succeeds (`pid` given) or
    /// throws (`pid == nil`).
    func spawned(pid: pid_t?) -> SpawnOutcome {
        lock.lock()
        let mustFinishTermination = terminating && pid != nil
        state = pid.map(State.running) ?? .idle
        lock.unlock()
        if mustFinishTermination, let pid {
            return .killAndExitNow(pid)
        }
        return .ok
    }

    /// Call after the child has exited normally (`waitUntilExit()` returned).
    func cleared() {
        lock.lock()
        state = .idle
        lock.unlock()
    }

    enum TerminationAction: Equatable {
        /// Nothing running or about to run — exit now.
        case exitNow
        /// A child is running with this PID — kill its group, then exit.
        case killAndExit(pid_t)
        /// A child is mid-spawn; do NOT exit — `spawned(pid:)` will decide to
        /// kill and exit once the PID is known.
        case wait
    }

    /// The SIGTERM/SIGINT handler's decision, computed and recorded under one
    /// lock acquisition so it can never race `spawned(pid:)`.
    func requestTermination() -> TerminationAction {
        lock.lock()
        defer { lock.unlock() }
        terminating = true
        switch state {
        case .idle: return .exitNow
        case .spawning: return .wait
        case .running(let pid): return .killAndExit(pid)
        }
    }
}

enum SyncWatchDaemon {
    private static let runningChild = RunningChildState()

    /// Send SIGTERM to the process group led by `pid` — the running sync
    /// child is its OWN process-group leader (measured live, see `run`'s
    /// comment), so this reaches the script, rclone and tee together. Not
    /// private, and taking a bare `pid_t` rather than reading `runningChild`
    /// itself, so a self-test can drive it against a process group IT
    /// spawned, without a real `limpet watch` process.
    static func terminateChildProcessGroup(pid: pid_t) {
        killpg(pid, SIGTERM)
    }

    /// The SIGTERM/SIGINT handler body: forward to the running child's process
    /// group, if any, and exit AT ONCE — see `run`'s comment on why this never
    /// waits. Does NOT exit when a child is mid-spawn (`.wait`): `spawned(pid:)`
    /// finishes that job instead, once it actually has a PID to kill.
    private static func terminateRunningChildAndExit() {
        switch runningChild.requestTermination() {
        case .exitNow:
            exit(0)
        case .killAndExit(let pid):
            terminateChildProcessGroup(pid: pid)
            exit(0)
        case .wait:
            break
        }
    }

    /// Runs forever. Everything here dispatches onto the main queue (matching
    /// `DirectoryWatcher`'s own `DispatchQueue.main.async` callback), so the
    /// scheduler's state is only ever mutated from one thread; `dispatchMain()`
    /// keeps that queue alive and this function never returns.
    static func run(profile: SyncProfile) -> Never {
        let scheduler = SyncWatchScheduler(runner: productionRunner(for: profile))

        // SIGUSR1 = "sync now". The default action for SIGUSR1 terminates the
        // process outright — under launchd's KeepAlive=true that would just
        // restart the watcher, which would then run its OWN catch-up sync and
        // make it look like the manual request "worked" without the request
        // ever having been handled. Ignore the default action FIRST, then
        // attach a dispatch source (the ordering the plan calls out), so
        // `handleAction` runs instead of the process dying.
        signal(SIGUSR1, SIG_IGN)
        let signalSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        signalSource.setEventHandler { scheduler.trigger() }
        signalSource.resume()

        // limpet-plan.md L6.1 change B, root cause 2: `launchctl unload` sends
        // this process SIGTERM, but `Process`'s child (the sync script) is its
        // own process-group leader (measured live: watcher pgid 24762,
        // script/rclone/tee pgid 61291) — killing only this process leaves the
        // script/rclone/tee running, reparented to launchd, still holding the
        // lock. Forward SIGTERM to the child's process group and exit AT ONCE:
        // no waiting, so `launchctl unload`/`load` timing (already synchronous
        // from the CLI's side) is unchanged. This CAN interrupt rclone mid-delete
        // (unmeasured, and wrong to assume otherwise — a SIGTERM has no reason to
        // respect rclone's transfer/delete phase boundary, and a profile's
        // `additionalRcloneFlags` can set `--delete-during`, which interleaves
        // deletes with transfers instead of phasing them): an interrupted run may
        // therefore have deleted only PART of what it meant to delete this pass.
        // That is still safe, by construction rather than by measurement — this
        // is a one-way sync (`syncDirection`), so `rclone sync` only ever deletes
        // a copy on the NON-authoritative side that is already absent from the
        // authoritative side; a delete interrupted partway through never removes
        // anything the user still has anywhere. The next watcher's catch-up sync
        // simply re-evaluates the same diff and completes whatever this run
        // didn't get to. Same handling for SIGINT (manual `kill`/Ctrl-C during
        // interactive debugging).
        var terminationSources: [DispatchSourceSignal] = []
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let terminationSource = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            terminationSource.setEventHandler { terminateRunningChildAndExit() }
            terminationSource.resume()
            terminationSources.append(terminationSource)  // kept alive: `run` never returns
        }

        // Periodic safety sync every profile interval.
        let intervalSeconds = TimeInterval(max(profile.syncIntervalMinutes, 1) * 60)
        let periodicTimer = DispatchSource.makeTimerSource(queue: .main)
        periodicTimer.schedule(deadline: .now() + intervalSeconds, repeating: intervalSeconds)
        periodicTimer.setEventHandler { scheduler.trigger() }
        periodicTimer.resume()

        // FSEvents on the local path, reusing `DirectoryWatcher` at the 5s
        // debounce the plan specifies. `DirectoryWatcher.start()` is already a
        // no-op when the path doesn't exist, so a missing source simply never
        // gets a stream — `startWatcherIfNeeded` (below, on the same 30s
        // recheck as the missing-source log) starts it the moment the path
        // appears, without needing its own separate poll loop.
        var directoryWatcher: DirectoryWatcher?
        func startWatcherIfNeeded() {
            guard directoryWatcher == nil,
                  FileManager.default.fileExists(atPath: profile.localSyncPath) else { return }
            let watcher = DirectoryWatcher(
                paths: [profile.localSyncPath],
                debounceInterval: 5.0,
                debugLabel: "watch-\(profile.shortId)"
            ) { scheduler.trigger() }
            watcher.start()
            directoryWatcher = watcher
        }
        startWatcherIfNeeded()

        let recheckTimer = DispatchSource.makeTimerSource(queue: .main)
        recheckTimer.schedule(deadline: .now() + 30, repeating: 30)
        // Catch-up sync whenever the source goes from missing to present (e.g. an
        // external drive remounted, or the folder was moved back). Tracking the
        // transition rather than only the first watcher start also covers a source
        // that disappears and returns while the watcher is already running; without
        // it, changes made meanwhile would wait for the periodic safety sync.
        var sourceWasMissing = !FileManager.default.fileExists(atPath: profile.localSyncPath)
        recheckTimer.setEventHandler {
            let exists = FileManager.default.fileExists(atPath: profile.localSyncPath)
            startWatcherIfNeeded()
            if exists && sourceWasMissing { scheduler.trigger() }
            sourceWasMissing = !exists
        }
        recheckTimer.resume()

        // Catch-up sync at start.
        scheduler.trigger()

        dispatchMain()
    }

    /// Wires `SchedulerRunner`'s closures to real process/filesystem/clock
    /// primitives for `profile`.
    private static func productionRunner(for profile: SyncProfile) -> SchedulerRunner {
        SchedulerRunner(
            sourceExists: { FileManager.default.fileExists(atPath: profile.localSyncPath) },
            runChild: { mayLog, completion in
                DispatchQueue.global(qos: .utility).async {
                    let code = runSyncChild(
                        profile: profile,
                        service: .shared,
                        // Throttled: a locked keychain fails every ~5 s trigger alike.
                        // mayLog touches scheduler state, which lives on main.
                        log: { if DispatchQueue.main.sync(execute: mayLog) { appendProfileLogLine($0, profile: profile) } },
                        spawn: { environment in
                            runChildProcess(
                                scriptPath: SyncProfile.sharedScriptPath,
                                configPath: profile.configPath,
                                environment: environment)
                        })
                    DispatchQueue.main.async { completion(code) }
                }
            },
            now: { Date().timeIntervalSinceReferenceDate },
            scheduleAfter: { seconds, action in
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: action)
            },
            logSourceMissing: { appendProfileLogLine("Source missing: \(profile.localSyncPath)", profile: profile) },
            refusalReason: { refusalReason(for: profile, profilesDirectory: SyncProfile.configDirectory) },
            logRefusal: { appendProfileLogLine("Refusing to sync: \($0)", profile: profile) },
            deleteLimitReached: { FileManager.default.fileExists(atPath: profile.deleteLimitMarkerPath) },
            recordDeleteLimit: {
                FileManager.default.createFile(
                    atPath: profile.deleteLimitMarkerPath,
                    contents: Data("rclone stopped at --max-delete; remove this file (or run 'limpet profile clear-delete-limit \(profile.shortId)') to sync again\n".utf8))
            }
        )
    }

    /// F4/F6 gate the watcher asks before every run (limpet-plan.md L4). Re-reads
    /// every profile file each time: a profile created or edited since this
    /// watcher started must be seen. Not private so `ConfigSelfTest` drives the
    /// exact production closure against a scratch profiles directory.
    static func refusalReason(
        for profile: SyncProfile,
        profilesDirectory: String,
        isInstalled: (SyncProfile) -> Bool = SyncProfile.agentInstalled
    ) -> String? {
        // A running watcher syncs, whatever the flag in its copy says.
        var running = profile
        running.isEnabled = true
        return profile.validationError ?? SyncProfile.overlapError(
            running, among: ProfileStore.profilesOnDisk(in: profilesDirectory), isInstalled: isInstalled)
    }

    /// What `runSyncChild` returns when the remote's secret could not be read.
    static let secretUnavailableExitCode: Int32 = 78  // EX_CONFIG

    /// F3 (limpet-plan.md L4): the sync script child — and therefore rclone —
    /// starts only with the environment the secret-injection helper returns.
    /// On a keychain failure the helper has already logged its one line and
    /// nothing is spawned. The script itself never touches the keychain.
    static func runSyncChild(
        profile: SyncProfile,
        service: RcloneConfigService,
        log: (String) -> Void,
        spawn: ([String: String]) -> Int32
    ) -> Int32 {
        guard let environment = service.processEnvironment(forRemote: profile.rcloneRemote, log: log) else {
            return secretUnavailableExitCode
        }
        return spawn(environment)
    }

    /// Run the shared sync script as a child. stdout/stderr go to
    /// `/dev/null` — the script already tees rclone's output into the
    /// profile log itself (`tee -a "$LOG_FILE"`), so piping the child's
    /// stdout through here too would duplicate every line (limpet-plan.md
    /// v2→v3 disposition #6).
    private static func runChildProcess(scriptPath: String, configPath: String, environment: [String: String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath, configPath]
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        runningChild.beginSpawning()
        do {
            try process.run()
        } catch {
            _ = runningChild.spawned(pid: nil)
            return -1
        }
        // finding 7: SIGTERM/SIGINT arriving between `beginSpawning()` above and
        // this call finds `.spawning` and returns `.wait` (does not exit) from
        // `requestTermination`; THIS call is the one that finishes the job, since
        // it is the first point a PID is actually known.
        switch runningChild.spawned(pid: process.processIdentifier) {
        case .ok:
            break
        case .killAndExitNow(let pid):
            terminateChildProcessGroup(pid: pid)
            exit(0)
        }
        process.waitUntilExit()
        runningChild.cleared()
        return process.terminationStatus
    }

    /// Append a fixed `YYYY-MM-DD HH:MM:SS - <message>` line (e.g. `Source
    /// missing: <path>`) to the PROFILE log — the file `LogWatcher`/the GUI
    /// reads — never the separate launchd stdout log, so the watcher's own
    /// outcomes are visible in the same place every sync outcome is
    /// (limpet-plan.md L3(a)).
    private static func appendProfileLogLine(_ message: String, profile: SyncProfile) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(formatter.string(from: Date())) - \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        let fm = FileManager.default
        let logDir = (profile.logPath as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: profile.logPath) {
            fm.createFile(atPath: profile.logPath, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: profile.logPath) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    }
}
