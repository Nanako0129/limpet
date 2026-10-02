import Foundation

/// Delivery contract (limpet-plan.md L6.3 R1): `didReceiveNewLines` is ALWAYS
/// called on the main queue, via `DispatchQueue.main.async` posted from the
/// watcher's single serial queue, so batches N and N+1 are applied in order.
protocol LogWatcherDelegate: AnyObject {
    func logWatcher(_ watcher: LogWatcher, didReceiveNewLines lines: [String])
}

/// Tails one profile log.
///
/// Threading contract (limpet-plan.md L6.3 R1): `pollQueue` OWNS every stored
/// property below except `delegate` (set once before `startWatching`) — the
/// file handle, dispatch source, poll/flush timers, read offset, line buffer,
/// inode and the pending batch. Public entry points hop onto the queue
/// (`startWatching`/`stopWatching` with `sync`, so a caller on main returns
/// only once setup/teardown is complete; `updateLogPath`/`setActivelySyncing`
/// with `async`). Reads and handle closes are serialized on that queue, so a
/// stop can never close a handle mid-read. Nothing here runs on main except
/// the delegate callback.
///
/// The watcher NEVER creates or truncates the log (R6): the script, the
/// watcher daemon's `appendProfileLogLine` and `tee -a` create it. A path
/// that does not exist keeps the poll timer running; when the file appears it
/// is opened at offset 0.
final class LogWatcher {
    private var logPath: String
    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var lastReadPosition: UInt64 = 0
    private var lineBuffer: String = ""  // Buffer for partial lines between reads
    private var lastKnownInode: UInt64 = 0  // 0 = never opened; survives a brief ENOENT

    private var pendingLines: [String] = []
    private var flushTimer: DispatchSourceTimer?
    private var lastFlush = Date.distantPast

    private var pollTimer: DispatchSourceTimer?
    private var isActivelySyncing: Bool = false
    private let pollQueue = DispatchQueue(label: "com.limpet.logwatcher.poll", qos: .utility)
    private let queueKey = DispatchSpecificKey<Void>()
    private let heartbeatInterval: TimeInterval
    private let activePollingInterval: TimeInterval
    private let flushInterval: TimeInterval

    weak var delegate: LogWatcherDelegate?

    /// The intervals are injectable only for the self-test; production uses the defaults.
    init(logPath: String, heartbeatInterval: TimeInterval = 5.0, activePollingInterval: TimeInterval = 2.5,
         flushInterval: TimeInterval = 1.0) {
        self.logPath = logPath
        self.heartbeatInterval = heartbeatInterval
        self.activePollingInterval = activePollingInterval
        self.flushInterval = flushInterval
        pollQueue.setSpecific(key: queueKey, value: ())
    }

    // MARK: - Public entry points (hop onto pollQueue)

    func startWatching() {
        pollQueue.sync { start() }
    }

    func stopWatching() {
        pollQueue.sync { stop() }
    }

    func updateLogPath(_ path: String) {
        pollQueue.async { [weak self] in
            guard let self else { return }
            self.stop()
            self.logPath = path
            self.start()
        }
    }

    /// Adjust polling frequency based on sync activity
    func setActivelySyncing(_ active: Bool) {
        pollQueue.async { [weak self] in
            guard let self, self.isActivelySyncing != active else { return }
            self.isActivelySyncing = active
            if self.pollTimer != nil { self.startPollTimer() }
        }
    }

    /// Test hook: run one poll tick now (the same routine the timer runs).
    func pollNowForTesting() {
        pollQueue.sync { pollForChanges() }
    }

    /// Test hook: run `block` on the watcher's queue (e.g. to read its state).
    func onQueueForTesting<T>(_ block: () -> T) -> T {
        pollQueue.sync(execute: block)
    }

    // MARK: - Everything below runs on pollQueue only

    private func start() {
        stop()
        lineBuffer = ""
        lastKnownInode = 0
        lastReadPosition = 0
        // An existing file is tailed from its end (only new content matters;
        // the initial state comes from SyncManager's lock check). A missing
        // one is not created — the poll tick opens it at offset 0 when it appears.
        if let stat = statLog() {
            openFile(atOffset: stat.size, inode: stat.inode)
        }
        startPollTimer()
    }

    private func stop() {
        pollTimer?.cancel()
        pollTimer = nil
        flushTimer?.cancel()
        flushTimer = nil
        pendingLines = []
        closeFile()
        lineBuffer = ""
    }

    /// Cancel the source; its cancel handler (queued on pollQueue, so after any
    /// in-flight read) closes the handle it captured.
    private func closeFile() {
        source?.cancel()
        source = nil
        fileHandle = nil
    }

    private func statLog() -> (size: UInt64, inode: UInt64)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logPath) else { return nil }
        return (attributes[.size] as? UInt64 ?? 0,
                (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
    }

    private func openFile(atOffset offset: UInt64, inode: UInt64) {
        closeFile()
        guard let handle = FileHandle(forReadingAtPath: logPath) else {
            LimpetSettings.debugLog("LogWatcher: Failed to open file: \(logPath)")
            return
        }
        fileHandle = handle
        lineBuffer = ""
        lastReadPosition = offset
        lastKnownInode = inode
        handle.seek(toFileOffset: offset)

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: handle.fileDescriptor,
            eventMask: [.extend, .write, .rename, .delete],
            queue: pollQueue
        )
        newSource.setEventHandler { [weak self] in self?.handleFileChange() }
        newSource.setCancelHandler { try? handle.close() }
        source = newSource
        newSource.resume()
    }

    /// Reopen the log after it was replaced (e.g. rotated). Idempotent: a
    /// second request (poll AND source) finds the inode already current.
    private func reopenFile() {
        guard let stat = statLog(), stat.inode != lastKnownInode else { return }
        LimpetSettings.debugLog("LogWatcher: reopening at offset 0, inode \(lastKnownInode) -> \(stat.inode)")
        openFile(atOffset: 0, inode: stat.inode)
        handleFileChange()
    }

    private func startPollTimer() {
        pollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        let interval = isActivelySyncing ? activePollingInterval : heartbeatInterval
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.pollForChanges() }
        pollTimer = timer
        timer.resume()
    }

    /// The one shared tick: covers a path that never existed, was deleted, is
    /// mid-rotation, or was replaced, as well as missed source events.
    private func pollForChanges() {
        guard let stat = statLog() else {
            // Missing path: drop the handle, keep polling (never create it).
            if fileHandle != nil { closeFile() }
            return
        }
        if fileHandle == nil {
            // Appeared (or reappeared). A different file starts at 0; the same
            // inode resumes where it was (handleFileChange handles truncation).
            let sameFile = lastKnownInode != 0 && stat.inode == lastKnownInode
            openFile(atOffset: sameFile ? min(lastReadPosition, stat.size) : 0, inode: stat.inode)
            handleFileChange()
            return
        }
        if stat.inode != lastKnownInode {
            reopenFile()
        } else if stat.size != lastReadPosition {
            handleFileChange()
        }
    }

    private func handleFileChange() {
        guard let handle = fileHandle else { return }
        guard let stat = statLog() else {
            closeFile()  // path vanished; the poll tick reopens when it returns
            return
        }
        if stat.inode != lastKnownInode {
            reopenFile()
            return
        }
        if stat.size < lastReadPosition {
            // Truncated: restart from the beginning
            lastReadPosition = 0
            lineBuffer = ""
        }

        handle.seek(toFileOffset: lastReadPosition)
        let newData = handle.readDataToEndOfFile()
        lastReadPosition = handle.offsetInFile

        guard !newData.isEmpty, let content = String(data: newData, encoding: .utf8) else { return }

        var lines = (lineBuffer + content).components(separatedBy: "\n")
        // If content doesn't end with newline, last element is partial - buffer it
        if !content.hasSuffix("\n") && !lines.isEmpty {
            lineBuffer = lines.removeLast()
        } else {
            lineBuffer = ""
        }

        let completeLines = lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !completeLines.isEmpty else { return }

        pendingLines.append(contentsOf: completeLines)
        if completeLines.contains(where: Self.isTransitionLine) {
            flush()
        } else {
            scheduleFlush()
        }
    }

    /// Lines whose state change must not wait for the coalescing interval.
    static func isTransitionLine(_ line: String) -> Bool {
        SyncLogPatterns.isSyncStarted(line) || SyncLogPatterns.isSyncCompleted(line)
            || SyncLogPatterns.isSyncFailed(line) || SyncLogPatterns.isSyncAlreadyRunning(line)
    }

    /// At most one delivery per `flushInterval` for ordinary lines.
    private func scheduleFlush() {
        guard flushTimer == nil else { return }
        let wait = max(0, lastFlush.addingTimeInterval(flushInterval).timeIntervalSinceNow)
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + wait)
        timer.setEventHandler { [weak self] in self?.flush() }
        flushTimer = timer
        timer.resume()
    }

    private func flush() {
        flushTimer?.cancel()
        flushTimer = nil
        guard !pendingLines.isEmpty else { return }
        let batch = pendingLines
        pendingLines = []
        lastFlush = Date()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.logWatcher(self, didReceiveNewLines: batch)
        }
    }

    deinit {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            stop()
        } else {
            pollQueue.sync { stop() }
        }
    }
}
