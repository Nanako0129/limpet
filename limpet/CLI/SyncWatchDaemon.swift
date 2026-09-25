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
enum SyncWatchDaemon {
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
            runChild: { completion in
                DispatchQueue.global(qos: .utility).async {
                    let code = runSyncChild(
                        profile: profile,
                        service: .shared,
                        log: { appendProfileLogLine($0, profile: profile) },
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
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
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
