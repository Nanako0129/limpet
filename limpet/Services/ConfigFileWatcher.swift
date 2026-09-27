import Foundation
import CryptoKit

/// Tracks content hashes of files limpet itself just wrote under
/// `~/.config/limpet`, so `ConfigFileWatcher` can distinguish an external
/// edit from an echo of its own write and skip reconciling on self-writes.
///
/// Content hash (not mtime) is the guard: an mtime-only check is not robust
/// against a rewrite that lands in the same second, which is common when the
/// app writes a profile file and the watcher's FSEvents latency window fires
/// shortly after.
final class ConfigSelfWriteRegistry {
    static let shared = ConfigSelfWriteRegistry()

    /// Pending self-write hashes → the time each was noted. Self-bounding:
    /// entries are never guaranteed to be consumed (FSEvents coalesce, and each
    /// `save()` rewrites EVERY profile file so rapid self-writes can leave
    /// hashes no matching event ever claims). Two bounds keep this from growing
    /// without limit — a 30s TTL (far larger than the ~1s debounce + FSEvents
    /// latency, so a legitimate echo is never evicted before it arrives) and a
    /// 512-entry hard cap evicting oldest-first.
    private var pending: [String: Date] = [:]
    private let lock = NSLock()

    /// Entries older than this are evicted on the next mutation.
    private let ttl: TimeInterval = 30
    /// Hard cap on retained entries; oldest are evicted first once exceeded.
    private let maxEntries = 512

    private init() {}

    /// SHA-256 hex digest of file content.
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Record that limpet itself just wrote content with this hash — the
    /// next matching FSEvent should be treated as an echo, not an external edit.
    func noteSelfWrite(contentHash: String) {
        lock.lock()
        defer { lock.unlock() }
        pending[contentHash] = Date()
        evictStaleLocked(now: Date())
    }

    /// Returns true (and CONSUMES the entry) if this content hash matches a
    /// recently self-written file. Consuming avoids a stale hash silently
    /// suppressing a later, genuinely external edit that happens to produce
    /// identical bytes (e.g. a hand-edit that toggles a field back to the
    /// value limpet itself last wrote). Also opportunistically evicts stale
    /// entries so an unconsumed hash can never accumulate.
    func consumeIfSelfWrite(contentHash: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let hit = pending.removeValue(forKey: contentHash) != nil
        evictStaleLocked(now: Date())
        return hit
    }

    /// Evict entries past their TTL, then enforce the entry cap by removing the
    /// oldest first. Caller must hold `lock`.
    private func evictStaleLocked(now: Date) {
        for (hash, noted) in pending where now.timeIntervalSince(noted) > ttl {
            pending.removeValue(forKey: hash)
        }
        guard pending.count > maxEntries else { return }
        let overflow = pending.count - maxEntries
        let oldest = pending.sorted { $0.value < $1.value }.prefix(overflow)
        for (hash, _) in oldest {
            pending.removeValue(forKey: hash)
        }
    }
}

/// Cross-process counterpart to `ConfigSelfWriteRegistry` (limpet-plan.md
/// L6.1 change A). `ConfigSelfWriteRegistry` only works within one process, so
/// it cannot suppress a reconcile the running GUI app would otherwise do in
/// response to a write made by the SEPARATE `limpet` CLI process (e.g.
/// `limpet profile set`, which already reconciles launchd itself). The CLI's
/// write closure notes a marker file — named by the content hash it is ABOUT
/// to write — under `directory` BEFORE writing the profile file; the watcher
/// consumes (reads and deletes) a matching marker on a registry miss and, on a
/// hit, still refreshes the in-memory profile but skips install/uninstall.
///
/// `directory` is `private(set)` and overridable only through `withDirectory`,
/// so a self-test can redirect every marker read/write to an isolated temp
/// root for the duration of one test without ever touching the real path.
enum CLIWriteMarker {
    static private(set) var directory = "\(LimpetPaths.home)/.local/state/limpet/cli-writes"

    /// Markers older than this are stale (a crashed CLI, or a marker no
    /// matching FSEvent ever arrived to consume) and are removed on sight.
    static let maxAge: TimeInterval = 600

    /// Run `body` with `directory` redirected to `dir`, restoring the previous
    /// value afterward — the ONLY way `directory` changes, so self-test
    /// isolation can never leak into a later test or the real path.
    static func withDirectory<T>(_ dir: String, _ body: () -> T) -> T {
        let previous = directory
        directory = dir
        defer { directory = previous }
        return body()
    }

    /// Record that the CLI is about to write content hashing to `contentHash`.
    /// Called BEFORE the profile file itself is written, so a watcher FSEvent
    /// racing the write can never arrive before the marker exists.
    static func note(contentHash: String, now: Date = Date()) {
        let fm = FileManager.default
        guard (try? fm.createDirectory(
            atPath: directory, withIntermediateDirectories: true)) != nil else { return }
        let path = "\(directory)/\(contentHash)"
        try? "\(now.timeIntervalSince1970)".write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Removes every stale (>`maxAge`) marker, then consumes (reads and
    /// deletes) a fresh marker matching `hash`, if any. Returns whether one
    /// was consumed.
    ///
    /// Only considers files whose NAME is a marker this type could have
    /// written — exactly 64 lowercase hex characters, `note`'s
    /// `ConfigSelfWriteRegistry.hash` format (code-review finding 6). Anything
    /// else in the directory is left alone entirely, never read or deleted:
    /// `note`'s own atomic write (`String.write(toFile:atomically:true,…)`)
    /// briefly creates a differently-named temp file in this SAME directory
    /// before renaming it into place, and the previous version's blanket
    /// "unparseable → delete" cleanup could race that temp file out from under
    /// the write it belongs to.
    static func consume(hash: String, now: Date = Date()) -> Bool {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return false }
        for file in files where isMarkerFilename(file) {
            let path = "\(directory)/\(file)"
            guard let content = try? String(contentsOfFile: path, encoding: .utf8),
                  let noted = TimeInterval(content) else {
                try? fm.removeItem(atPath: path)  // marker-named, but not our content; drop it
                continue
            }
            if now.timeIntervalSince1970 - noted > maxAge {
                try? fm.removeItem(atPath: path)
            }
        }
        let markerPath = "\(directory)/\(hash)"
        guard isMarkerFilename(hash), fm.fileExists(atPath: markerPath) else { return false }
        try? fm.removeItem(atPath: markerPath)
        return true
    }

    /// True iff `name` is exactly 64 lowercase hex characters — the shape of
    /// every hash `ConfigSelfWriteRegistry.hash` produces, and so the only
    /// shape a name `note()` ever gives a FINISHED marker file.
    private static func isMarkerFilename(_ name: String) -> Bool {
        name.count == 64 && name.allSatisfy { "0123456789abcdef".contains($0) }
    }
}

/// Watches `~/.config/limpet` for external edits to `*.profile.json` and
/// `settings.json` and routes debounced changes through the SAME reconcile
/// path the in-app Save button uses — never a bare in-memory struct swap.
///
/// Reuses `DirectoryWatcher`'s FSEvents+debounce PATTERN but is intentionally
/// a separate, lighter type rather than a subclass/reuse of `DirectoryWatcher`
/// itself — that class is tuned for sync-triggering (debounce plus metadata
/// filtering), the wrong shape for config, which needs a
/// short debounce and self-write suppression instead.
final class ConfigFileWatcher {
    private var stream: FSEventStreamRef?
    private let watchedDirectory: String
    /// `suppressReconcile` is true for a write the CLI marked as its own
    /// (limpet-plan.md L6.1 change A): the caller must still refresh its
    /// in-memory profile, but make no install/uninstall/launchctl call, since
    /// the CLI process already reconciled launchd for this write.
    private let onProfileChange: (_ path: String, _ suppressReconcile: Bool) -> Void
    private let onSettingsChange: () -> Void
    private let debounceInterval: TimeInterval

    private var debounceTimer: DispatchSourceTimer?
    private let debounceQueue = DispatchQueue(label: "com.limpet.config-watcher.debounce")
    /// Paths seen since the last debounce fired; coalesced on each reset.
    private var pendingPaths: Set<String> = []

    /// - Parameters:
    ///   - watchedDirectory: defaults to the real `~/.config/limpet`; overridable for tests.
    ///   - debounceInterval: short (~1s) — config edits are small, hand-typed files, not a
    ///     sync-triggering directory where 15s debounce avoids reacting to every intermediate write.
    init(
        watchedDirectory: String = "\(LimpetPaths.home)/.config/limpet",
        debounceInterval: TimeInterval = 1.0,
        onProfileChange: @escaping (_ path: String, _ suppressReconcile: Bool) -> Void,
        onSettingsChange: @escaping () -> Void
    ) {
        self.watchedDirectory = watchedDirectory
        self.debounceInterval = debounceInterval
        self.onProfileChange = onProfileChange
        self.onSettingsChange = onSettingsChange
    }

    deinit { stop() }

    /// Start watching. No-op if already started or the directory doesn't exist yet
    /// (the app ensures it exists at launch via `ConfigSchemaInstaller.writeSchemas()`).
    func start() {
        guard stream == nil else { return }
        guard FileManager.default.fileExists(atPath: watchedDirectory) else { return }

        let pathsToWatch = [watchedDirectory] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)

        guard let stream = FSEventStreamCreate(
            nil,
            configWatcherCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            debounceInterval,
            flags
        ) else {
            print("ConfigFileWatcher: Failed to create FSEventStream")
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

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

    /// Forwards to the shared self-write registry. Kept as an instance method
    /// so callers holding a `ConfigFileWatcher` reference (rather than the
    /// registry singleton) have a natural place to note a write.
    func noteSelfWrite(contentHash: String) {
        ConfigSelfWriteRegistry.shared.noteSelfWrite(contentHash: contentHash)
    }

    fileprivate func handleEvents(_ eventPaths: [String]) {
        let inScope = eventPaths.filter {
            $0 == watchedDirectory || $0.hasPrefix(watchedDirectory + "/")
        }
        guard !inScope.isEmpty else { return }

        debounceQueue.async { [weak self] in
            guard let self else { return }
            self.pendingPaths.formUnion(inScope)
            self.resetDebounceTimer()
        }
    }

    private func resetDebounceTimer() {
        debounceTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: debounceQueue)
        timer.schedule(deadline: .now() + debounceInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let paths = self.pendingPaths
            self.pendingPaths.removeAll()
            self.debounceTimer = nil
            DispatchQueue.main.async {
                self.processChangedPaths(Array(paths))
            }
        }
        debounceTimer = timer
        timer.resume()
    }

    private func processChangedPaths(_ paths: [String]) {
        for path in paths {
            // A half-written file (partial JSON) either fails `classifyWrite`'s
            // read/decode-adjacent hash check trivially (still reconciles — the
            // hash just won't match a self-write or a CLI marker) or the
            // downstream decode in `applyExternalProfileEdit`/
            // `applyExternalSettingsEdit` fails and is skipped there; either way
            // the next complete-write event reconciles.
            switch Self.classifyWrite(forFileAt: path) {
            case .skip: continue
            case .cliWrite: classify(path, suppressReconcile: true)
            case .external: classify(path, suppressReconcile: false)
            }
        }
    }

    private func classify(_ path: String, suppressReconcile: Bool) {
        let filename = (path as NSString).lastPathComponent
        if filename.hasSuffix(".profile.json") {
            onProfileChange(path, suppressReconcile)
        } else if filename == "settings.json" {
            onSettingsChange()
        }
        // Anything else under ~/.config/limpet (derived {shortId}.json, the
        // exclude filter, schema/) is not an authoritative agent-editable
        // surface and is intentionally ignored here.
    }

    /// Whether — and why — a changed file should be reconciled: the writer of
    /// a file under `~/.config/limpet` (limpet-plan.md L6.1 change A).
    enum WriteOrigin: Equatable {
        /// limpet's own in-process write (`ConfigSelfWriteRegistry` hit), or a
        /// missing/unreadable file (e.g. deleted, or caught mid-write). Do
        /// nothing.
        case skip
        /// The CLI's own write (a fresh `CLIWriteMarker` hit): refresh the
        /// in-memory profile, but make no install/uninstall/launchctl call —
        /// the CLI process already reconciled launchd for this write.
        case cliWrite
        /// Neither of the above: a hand edit, or a genuinely external tool.
        /// Reconcile normally.
        case external
    }

    /// Pure, directly-testable classification: reads the file at `path`,
    /// hashes its content, and checks the in-process self-write registry
    /// FIRST (a hit ends the check — markers are not even read) and only on a
    /// miss consults `CLIWriteMarker`.
    static func classifyWrite(forFileAt path: String) -> WriteOrigin {
        guard let data = FileManager.default.contents(atPath: path) else { return .skip }
        let hash = ConfigSelfWriteRegistry.hash(data)
        if ConfigSelfWriteRegistry.shared.consumeIfSelfWrite(contentHash: hash) {
            return .skip
        }
        if CLIWriteMarker.consume(hash: hash) {
            return .cliWrite
        }
        return .external
    }

    /// Legacy bool view of `classifyWrite`, kept only because it reads more
    /// directly in a plain self-write-suppression test (AC-5): `true` unless
    /// the write should be skipped entirely. Touches `CLIWriteMarker` exactly
    /// like `classifyWrite` — a caller in a self-test MUST wrap it in
    /// `CLIWriteMarker.withDirectory` to avoid ever reading the real path.
    static func shouldReconcile(forFileAt path: String) -> Bool {
        classifyWrite(forFileAt: path) != .skip
    }
}

// MARK: - FSEvents Callback

private func configWatcherCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let clientCallBackInfo = clientCallBackInfo else { return }

    let watcher = Unmanaged<ConfigFileWatcher>.fromOpaque(clientCallBackInfo).takeUnretainedValue()

    guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }

    watcher.handleEvents(paths)
}
