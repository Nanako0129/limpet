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
        recheckTimer.setEventHandler { startWatcherIfNeeded() }
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
                    let code = runChildProcess(
                        scriptPath: SyncProfile.sharedScriptPath,
                        configPath: profile.configPath
                    )
                    DispatchQueue.main.async { completion(code) }
                }
            },
            now: { Date().timeIntervalSinceReferenceDate },
            scheduleAfter: { seconds, action in
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: action)
            },
            logSourceMissing: { appendSourceMissingLine(profile: profile) }
        )
    }

    /// Run the shared sync script as a child. stdout/stderr go to
    /// `/dev/null` — the script already tees rclone's output into the
    /// profile log itself (`tee -a "$LOG_FILE"`), so piping the child's
    /// stdout through here too would duplicate every line (limpet-plan.md
    /// v2→v3 disposition #6).
    private static func runChildProcess(scriptPath: String, configPath: String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath, configPath]
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

    /// Append the fixed `YYYY-MM-DD HH:MM:SS - Source missing: <path>` line to
    /// the PROFILE log — the file `LogWatcher`/the GUI reads — never the
    /// separate launchd stdout log, so a missing source is visible in the
    /// same place every other sync outcome is (limpet-plan.md L3(a)).
    private static func appendSourceMissingLine(profile: SyncProfile) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(formatter.string(from: Date())) - Source missing: \(profile.localSyncPath)\n"
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
