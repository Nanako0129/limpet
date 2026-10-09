import Foundation

/// The profile's exclude rules as rclone itself compiled them, so excluded churn
/// (build output, worktrees) never reaches `DirtySet` (limpet-plan.md L9.2 S1).
/// Built from `rclone lsf --dump filters <the profile's rule sources> <empty dir>`:
/// rclone turns the globs into regexes; this type only walks rclone's first-match
/// order (fs/filter/rules.go `include`, filter.go `IncludeDirectory`). A wrongly
/// dropped included path waits for the next full run; a wrongly kept excluded
/// path costs a no-op batch, never an upload, because every batch applies the
/// real filters in rclone.
struct ExcludeOracle {
    struct Rule {
        let include: Bool
        let regex: NSRegularExpression

        func matches(_ s: String) -> Bool {
            regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }
    }

    let fileRules: [Rule]
    let dirRules: [Rule]

    /// Parses rclone's `--- start filters ---` … `--- end filters ---` block.
    /// nil when the block is missing or a regex does not compile, so the caller
    /// drops nothing rather than guessing.
    init?(dump: String) {
        var file: [Rule] = [], dir: [Rule] = []
        var section: Int?  // 0 = file rules, 1 = directory rules
        var sawEnd = false
        for line in dump.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            switch line {
            case "--- File filter rules ---": section = 0; continue
            case "--- Directory filter rules ---": section = 1; continue
            case "--- end filters ---": sawEnd = true; section = nil; continue
            default: break
            }
            guard let section, line.count > 2, line.hasPrefix("+ ") || line.hasPrefix("- ") else { continue }
            guard let regex = try? NSRegularExpression(pattern: String(line.dropFirst(2))) else { return nil }
            let rule = Rule(include: line.hasPrefix("+ "), regex: regex)
            if section == 0 { file.append(rule) } else { dir.append(rule) }
        }
        guard sawEnd else { return nil }
        fileRules = file
        dirRules = dir
    }

    /// rclone's verdict for a root-relative path: skipped when an ancestor
    /// directory ("a/", "a/b/") is excluded by the directory rules (rclone never
    /// walks into it), or when the first matching file rule excludes it. No
    /// matching rule means included, as in rclone.
    /// `isDir`: the path is a directory (a directory event), so rclone's own
    /// directory check applies to it too — `rm -rf build` reports `build`.
    func isExcluded(_ relativePath: String, isDir: Bool = false) -> Bool {
        var ancestor = ""
        let components = relativePath.split(separator: "/")
        for component in isDir ? components[...] : components.dropLast() {
            ancestor += component + "/"
            if Self.firstMatch(dirRules, ancestor) == false { return true }
        }
        return !isDir && Self.firstMatch(fileRules, relativePath) == false
    }

    private static func firstMatch(_ rules: [Rule], _ s: String) -> Bool? {
        rules.first { $0.matches(s) }?.include
    }
}

/// What a finished run tells `DirtySet` (classified from the run's own log
/// lines by the watcher, limpet-plan.md L9.2 S2).
enum RunOutcome: Equatable {
    case success
    /// rclone finished but some objects failed. `deletesSkipped`: rclone logged
    /// "not deleting files as there were IO errors" — it skips EVERY delete of
    /// the run on any error (fs/sync/sync.go:992-1012).
    case objectErrors(failedPaths: Set<String>, deletesSkipped: Bool)
    /// Anything else: nothing about this run's entries is known.
    case runFailed
}

/// Paths that changed and are not yet on the remote, coalesced by path
/// (limpet-plan.md L9.2 S1). N events for one path are one entry; the watcher
/// hands ready entries to rclone in batches. Pure: no clock, no I/O — the
/// caller passes `now` and an `exists` check.
struct DirtySet {
    /// A path must be quiet this long before it is uploaded, so a file being
    /// written is not uploaded once per write (and mostly not mid-write, L9.1).
    static let quiet: TimeInterval = 10
    /// …but a file that never goes quiet (an appended log) is still uploaded
    /// at least this often.
    static let maxDelay: TimeInterval = 300
    /// More dirty entries than this under one directory become one subtree
    /// entry for the directory: one rclone rule instead of hundreds.
    static let collapseChildren = 200
    /// More entries than this in total: the set gives up and a full run covers
    /// everything (today's behaviour for a mass change).
    static let fullRunThreshold = 5000
    /// A path that failed in this many batches is dropped; the next full run
    /// retries it. Keeps one bad file from pinning every batch.
    static let giveUpFailures = 3

    struct Entry: Equatable {
        var firstSeen: TimeInterval
        var lastSeen: TimeInterval
        var firstEventId: UInt64
        /// `+ /p/**` rather than `+ /p`: a directory event (a moved directory
        /// reports only itself, S0 E4) or a collapsed directory.
        var subtree: Bool
        var generation = 0
        var failures = 0
        var inFlight = false
    }

    struct BatchItem: Equatable {
        let path: String
        let subtree: Bool
        let generation: Int
    }

    private(set) var entries: [String: Entry] = [:]
    private(set) var fullRequired = false
    private(set) var fullRequiredSince: TimeInterval?
    private(set) var fullRunStartedAt: TimeInterval?
    private(set) var highestEventId: UInt64 = 0
    /// Paths dropped after `giveUpFailures`; the watcher logs them once.
    private(set) var gaveUp: [String] = []
    private var childCount: [String: Int] = [:]

    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// Records one FSEvents event for a root-relative path ("" = the root
    /// itself). `gap`: MustScanSubDirs, UserDropped, KernelDropped,
    /// EventIdsWrapped or RootChanged — the event stream lost detail.
    mutating func note(_ path: String, isDirEvent: Bool, gap: Bool, eventId: UInt64, now: TimeInterval) {
        highestEventId = max(highestEventId, eventId)
        if gap || path.isEmpty { return requireFullRun(now: now) }
        // A required full run that has not started yet starts after this
        // event, so it covers it; nothing to store.
        if fullRequired && fullRunStartedAt == nil { return }

        if let covering = coveringSubtree(of: path) {
            touch(covering, eventId: eventId, now: now, subtree: false)
            return
        }
        if entries[path] != nil {
            touch(path, eventId: eventId, now: now, subtree: isDirEvent)
        } else {
            entries[path] = Entry(firstSeen: now, lastSeen: now, firstEventId: eventId, subtree: isDirEvent)
            childCount[Self.parent(of: path), default: 0] += 1
        }
        if isDirEvent { absorbDescendants(of: path) }
        let parent = Self.parent(of: path)
        if !parent.isEmpty, childCount[parent, default: 0] > Self.collapseChildren {
            collapse(into: parent, now: now)
        } else if parent.isEmpty, childCount[""] ?? 0 > Self.collapseChildren {
            return requireFullRun(now: now)
        }
        if entries.count > Self.fullRunThreshold { requireFullRun(now: now) }
    }

    private func coveringSubtree(of path: String) -> String? {
        var p = Self.parent(of: path)
        while !p.isEmpty {
            if entries[p]?.subtree == true { return p }
            p = Self.parent(of: p)
        }
        return nil
    }

    private mutating func touch(_ path: String, eventId: UInt64, now: TimeInterval, subtree: Bool) {
        guard var e = entries[path] else { return }
        e.lastSeen = now
        e.firstEventId = min(e.firstEventId, eventId)
        e.generation += 1
        e.subtree = e.subtree || subtree
        entries[path] = e
    }

    private mutating func remove(_ path: String) {
        guard entries.removeValue(forKey: path) != nil else { return }
        let parent = Self.parent(of: path)
        childCount[parent, default: 1] -= 1
        if childCount[parent] == 0 { childCount.removeValue(forKey: parent) }
    }

    /// Folds every idle entry below `dir` into `dir`'s entry (which must exist).
    /// In-flight entries finish on their own; the subtree re-covers them.
    private mutating func absorbDescendants(of dir: String) {
        let prefix = dir + "/"
        for (path, e) in entries where path.hasPrefix(prefix) && !e.inFlight {
            entries[dir]!.firstSeen = min(entries[dir]!.firstSeen, e.firstSeen)
            entries[dir]!.firstEventId = min(entries[dir]!.firstEventId, e.firstEventId)
            remove(path)
        }
    }

    private mutating func collapse(into dir: String, now: TimeInterval) {
        if entries[dir] == nil {
            entries[dir] = Entry(firstSeen: now, lastSeen: now, firstEventId: highestEventId, subtree: true)
            childCount[Self.parent(of: dir), default: 0] += 1
        } else {
            entries[dir]!.subtree = true
            entries[dir]!.lastSeen = now
            entries[dir]!.generation += 1
        }
        absorbDescendants(of: dir)
    }

    private mutating func requireFullRun(now: TimeInterval) {
        fullRequired = true
        fullRequiredSince = now
        for (path, e) in entries where !e.inFlight { remove(path) }
    }

    func isReady(_ e: Entry, now: TimeInterval) -> Bool {
        !e.inFlight && (now - e.lastSeen >= Self.quiet || now - e.firstSeen >= Self.maxDelay)
    }

    /// When the earliest idle entry becomes ready; nil when there is none.
    func nextWakeup(now: TimeInterval) -> TimeInterval? {
        entries.values.filter { !$0.inFlight }
            .map { min($0.lastSeen + Self.quiet, $0.firstSeen + Self.maxDelay) }
            .min()
    }

    /// Up to `limit` ready entries, oldest first, marked in flight.
    mutating func takeBatch(now: TimeInterval, limit: Int) -> [BatchItem] {
        let ready = entries.filter { isReady($0.value, now: now) }
            .sorted { ($0.value.firstSeen, $0.key) < ($1.value.firstSeen, $1.key) }
            .prefix(limit)
        return ready.map { path, e in
            entries[path]!.inFlight = true
            return BatchItem(path: path, subtree: e.subtree, generation: e.generation)
        }
    }

    /// Whether `path` (an entry) carries one of the failed paths.
    private static func carries(_ path: String, subtree: Bool, of failed: Set<String>) -> Bool {
        failed.contains(path) || (subtree && failed.contains { $0.hasPrefix(path + "/") })
    }

    mutating func finish(_ batch: [BatchItem], outcome: RunOutcome, exists: (String) -> Bool) {
        for item in batch {
            guard var e = entries[item.path] else { continue }
            e.inFlight = false
            entries[item.path] = e
            switch outcome {
            case .runFailed:
                continue
            case .success:
                if e.generation == item.generation { remove(item.path) }
            case .objectErrors(let failed, let deletesSkipped):
                if Self.carries(item.path, subtree: e.subtree, of: failed) {
                    e.failures += 1
                    entries[item.path] = e
                    if e.failures >= Self.giveUpFailures {
                        gaveUp.append(item.path)
                        remove(item.path)
                    }
                } else if deletesSkipped && (e.subtree || !exists(item.path)) {
                    continue  // its delete was skipped: retry, no failure counted
                } else if e.generation == item.generation {
                    remove(item.path)
                }
            }
        }
    }

    mutating func fullRunStarted(at time: TimeInterval) {
        fullRunStartedAt = time
    }

    mutating func fullRunFinished(outcome: RunOutcome, exists: (String) -> Bool) {
        guard let startedAt = fullRunStartedAt else { return }
        fullRunStartedAt = nil
        guard outcome != .runFailed else { return }
        if let since = fullRequiredSince, since <= startedAt {
            fullRequired = false
            fullRequiredSince = nil
        }
        var failed: Set<String> = []
        var deletesSkipped = false
        if case .objectErrors(let f, let d) = outcome { failed = f; deletesSkipped = d }
        for (path, e) in entries where !e.inFlight && e.lastSeen < startedAt {
            if deletesSkipped && (e.subtree || !exists(path)) { continue }
            remove(path)
        }
        for path in failed where coveringSubtree(of: path) == nil {
            if entries[path] == nil {
                entries[path] = Entry(firstSeen: startedAt, lastSeen: startedAt, firstEventId: highestEventId, subtree: false)
                childCount[Self.parent(of: path), default: 0] += 1
            }
            entries[path]!.failures = max(entries[path]!.failures, 1)
        }
    }

    /// The FSEvents id up to which everything is on the remote: nil while a
    /// full run is required (a restart must run it), else one below the
    /// oldest event any live entry still carries.
    var checkpoint: UInt64? {
        if fullRequired { return nil }
        guard let oldest = entries.values.map(\.firstEventId).min() else { return highestEventId }
        return oldest == 0 ? 0 : oldest - 1
    }

    mutating func clearGaveUp() { gaveUp.removeAll() }
}
