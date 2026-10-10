import Foundation

/// Watches directories for file system changes using FSEvents
/// Calls the onChange handler with debouncing to avoid triggering too many syncs
final class DirectoryWatcher {
    typealias ChangeHandler = () -> Void
    /// Raw events for incremental sync (limpet-plan.md L9.2 S2b): path, flags, id.
    typealias EventsHandler = ([(path: String, flags: UInt32, id: UInt64)]) -> Void

    private var stream: FSEventStreamRef?
    private let paths: [String]
    private let onChange: ChangeHandler
    private let onEvents: EventsHandler?
    private let sinceWhen: FSEventStreamEventId
    private let debounceInterval: TimeInterval
    private let debugLabel: String

    private var debounceTimer: DispatchSourceTimer?
    private let debounceQueue = DispatchQueue(label: "com.limpet.directory-watcher.debounce")

    /// Create a directory watcher
    /// - Parameters:
    ///   - paths: Directories to watch
    ///   - debounceInterval: Time to wait after last change before triggering (default 15 seconds)
    ///   - debugLabel: Label for debug logging to identify this watcher
    ///   - onChange: Called when changes are detected (after debounce)
    ///   - onEvents: when set, every in-scope event (no metadata filter, no
    ///     debounce) is delivered with its flags and id on the main queue
    ///     instead of `onChange`.
    ///   - sinceWhen: the stream's start (replay from a saved id, L9.2 S3).
    init(paths: [String], debounceInterval: TimeInterval = 15.0, debugLabel: String = "",
         sinceWhen: FSEventStreamEventId = FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
         onEvents: EventsHandler? = nil, onChange: @escaping ChangeHandler) {
        self.paths = paths
        self.debounceInterval = debounceInterval
        self.debugLabel = debugLabel
        self.sinceWhen = sinceWhen
        self.onEvents = onEvents
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    /// Start watching the directories
    func start() {
        guard stream == nil else { return }
        guard !paths.isEmpty else { return }

        // Filter to only existing directories
        let existingPaths = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existingPaths.isEmpty else { return }

        let pathsToWatch = existingPaths as CFArray

        // Context to pass self to the callback
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        // Create the event stream
        // Using a latency of 1.0 second - FSEvents will batch events within this window
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)

        guard let stream = FSEventStreamCreate(
            nil,
            directoryWatcherCallback,
            &context,
            pathsToWatch,
            sinceWhen,
            1.0,  // Latency - FSEvents batches events within this window
            flags
        ) else {
            print("DirectoryWatcher: Failed to create FSEventStream")
            return
        }

        self.stream = stream

        // Schedule on a background queue
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    /// Stop watching
    func stop() {
        debounceTimer?.cancel()
        debounceTimer = nil

        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    /// Called when file system events are received
    fileprivate func handleEvents(_ eventPaths: [String], flags: [UInt32], ids: [UInt64]) {
        if let onEvents {
            let events = zip(eventPaths, zip(flags, ids)).compactMap { path, rest -> (path: String, flags: UInt32, id: UInt64)? in
                let inScope = paths.contains { path == $0 || path.hasPrefix($0 + "/") }
                return inScope ? (path, rest.0, rest.1) : nil
            }
            guard !events.isEmpty else { return }
            DispatchQueue.main.async { onEvents(events) }
            return
        }
        let label = debugLabel.isEmpty ? "unknown" : debugLabel
        LimpetSettings.debugLog("[\(label)] FSEvents callback - watching: \(self.paths.joined(separator: ", "))")
        LimpetSettings.debugLog("[\(label)] FSEvents received \(eventPaths.count) raw paths:")
        for path in eventPaths.prefix(5) {
            LimpetSettings.debugLog("[\(label)]   RAW: \(path)")
        }

        // Keep only paths inside the watched directories; FSEvents can deliver
        // events for other directories on the same volume. A path that no longer
        // exists is a delete and must trigger a sync. There is deliberately no
        // "phantom path" filter here: the old one dropped any event whose file
        // name also existed in a sibling directory, which swallowed real deletes
        // of README.md, index.js and the like, while a spurious trigger only costs
        // one rclone run that finds nothing to transfer.
        let pathsInScope = eventPaths.filter { eventPath in
            let matchesWatchedPath = self.paths.contains { watchedPath in
                eventPath == watchedPath || eventPath.hasPrefix(watchedPath + "/")
            }
            if !matchesWatchedPath {
                LimpetSettings.debugLog("[\(label)]   FILTERED OUT: \(eventPath) (not in watched paths)")
            }
            return matchesWatchedPath
        }

        if pathsInScope.isEmpty {
            LimpetSettings.debugLog("[\(label)] No paths in scope after filtering")
            return
        }

        LimpetSettings.debugLog("[\(label)] \(pathsInScope.count) paths in scope:")
        for path in pathsInScope.prefix(5) {
            LimpetSettings.debugLog("[\(label)]   -> \(path)")
        }
        if pathsInScope.count > 5 {
            LimpetSettings.debugLog("[\(label)]   ... and \(pathsInScope.count - 5) more")
        }

        // Filter out irrelevant changes (e.g., .DS_Store updates during browsing)
        let relevantChanges = pathsInScope.filter { path in
            let filename = (path as NSString).lastPathComponent

            // Ignore macOS metadata files - they change frequently and aren't user data
            if filename.hasPrefix("._") || filename == ".DS_Store" || filename == ".fseventsd" {
                return false
            }

            // Ignore temporary files
            if filename.hasSuffix(".tmp") || filename.hasSuffix(".temp") || filename.hasPrefix("~$") {
                return false
            }

            // Ignore our own sync-related files
            if filename == ".limpet-check" || filename.hasPrefix(".limpet") {
                return false
            }

            return true
        }

        if relevantChanges.isEmpty {
            LimpetSettings.debugLog("[\(label)] All events filtered out (metadata/temp files)")
            return
        }

        LimpetSettings.debugLog("[\(label)] \(relevantChanges.count) relevant -> starting debounce timer")

        // Debounce: reset timer on each change
        debounceQueue.async { [weak self] in
            self?.resetDebounceTimer()
        }
    }

    private func resetDebounceTimer() {
        // Cancel existing timer
        debounceTimer?.cancel()

        // Create new timer
        let timer = DispatchSource.makeTimerSource(queue: debounceQueue)
        timer.schedule(deadline: .now() + debounceInterval)
        timer.setEventHandler { [weak self] in
            self?.debounceTimer = nil
            DispatchQueue.main.async {
                self?.onChange()
            }
        }
        debounceTimer = timer
        timer.resume()
    }
}

// MARK: - FSEvents Callback

private func directoryWatcherCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let clientCallBackInfo = clientCallBackInfo else { return }

    let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(clientCallBackInfo).takeUnretainedValue()

    // Convert paths to Swift array
    guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
    let flags = (0..<numEvents).map { eventFlags[$0] }
    let ids = (0..<numEvents).map { eventIds[$0] }

    watcher.handleEvents(paths, flags: flags, ids: ids)
}
