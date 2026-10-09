import Foundation

/// The profile's exclude rules as rclone itself compiled them, so excluded churn
/// (build output, worktrees) never reaches `DirtySet` (limpet-plan.md L9.2 S1).
/// Built from `rclone lsf --dump filters <the profile's rule sources> <empty dir>`:
/// rclone turns the globs into regexes; this type only walks rclone's first-match
/// order (fs/filter/rules.go `include`, filter.go `IncludeDirectory`).
///
/// It may only err towards "included": rclone's regexes are Go RE2 and are
/// re-compiled here with ICU, so a dump using syntax whose meaning differs
/// between the two is refused (nil), and a path holding a line terminator is
/// never called excluded. A wrongly dropped included path would wait for the
/// next full run. A wrongly kept excluded path is meant to cost only a no-op
/// batch, because batches apply the real filters in rclone — unverified until
/// L9.2 S2's batch fixture.
final class ExcludeOracle {
    struct Rule {
        let include: Bool
        let regex: NSRegularExpression

        func matches(_ s: NSString) -> Bool {
            regex.firstMatch(in: s as String, range: NSRange(location: 0, length: s.length)) != nil
        }
    }

    let fileRules: [Rule]
    let dirRules: [Rule]
    /// Directory verdicts by "a/b/": one burst of events shares its ancestors,
    /// so each is matched once (an uncached walk measured ~320 µs per event).
    private var dirVerdicts: [String: Bool] = [:]

    /// Parses rclone's `--- start filters ---` … `--- end filters ---` block.
    /// Only the file and directory sections are rules for paths; any other
    /// section (e.g. `--- Metadata filter rules ---`) is skipped. nil when the
    /// end marker is missing, a regex does not compile, or a regex uses syntax
    /// that RE2 and ICU read differently — the caller then drops nothing.
    init?(dump: String) {
        var file: [Rule] = [], dir: [Rule] = []
        var section: Int?  // 0 = file rules, 1 = directory rules, nil = skip
        var sawEnd = false
        for line in dump.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("--- ") && line.hasSuffix(" ---") {
                switch line {
                case "--- File filter rules ---": section = 0
                case "--- Directory filter rules ---": section = 1
                case "--- end filters ---": sawEnd = true; section = nil
                default: section = nil
                }
                continue
            }
            guard let section, line.count > 2, line.hasPrefix("+ ") || line.hasPrefix("- ") else { continue }
            let pattern = String(line.dropFirst(2))
            guard !Self.readsDifferently(pattern),
                  let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            let rule = Rule(include: line.hasPrefix("+ "), regex: regex)
            if section == 0 { file.append(rule) } else { dir.append(rule) }
        }
        guard sawEnd else { return nil }
        fileRules = file
        dirRules = dir
    }

    /// Anything outside what rclone's glob translation emits, read alike by
    /// RE2 and ICU: any `(?` group or flag (`(?i)` from --ignore-case folds
    /// case differently), a backslash before a letter or digit (`\w \d \s \b`
    /// are ASCII in RE2, Unicode in ICU; rclone only escapes punctuation), and
    /// `&&` / `--` / a nested `[` inside a bracket expression (ICU set
    /// operations and POSIX classes, literal or ASCII in RE2).
    static func readsDifferently(_ pattern: String) -> Bool {
        if pattern.contains("(?") { return true }
        var inBracket = false, escaped = false
        var previous: Character = " "
        for c in pattern {
            defer { previous = escaped ? " " : c }
            if escaped {
                escaped = false
                if c.isASCII && (c.isLetter || c.isNumber) { return true }
                continue
            }
            if c == "\\" { escaped = true; continue }
            if inBracket {
                if c == "]" { inBracket = false }
                else if c == "[" || (c == "&" && previous == "&") || (c == "-" && previous == "-") { return true }
            } else if c == "[" {
                inBracket = true
            }
        }
        return false
    }

    /// rclone's verdict for a root-relative path: skipped when an ancestor
    /// directory ("a/", "a/b/") is excluded by the directory rules (rclone never
    /// walks into it), or when the first matching file rule excludes it. No
    /// matching rule means included, as in rclone. `isDir`: the path is a
    /// directory (a directory event), so the directory check applies to it
    /// too — `rm -rf build` reports `build`.
    func isExcluded(_ relativePath: String, isDir: Bool = false) -> Bool {
        if relativePath.unicodeScalars.contains(where: { "\n\r\u{85}\u{2028}\u{2029}".unicodeScalars.contains($0) }) {
            return false  // ICU's `.` and `$` treat these unlike RE2
        }
        var ancestor = ""
        let components = relativePath.split(separator: "/")
        for component in isDir ? components[...] : components.dropLast() {
            ancestor += component + "/"
            if !dirIncluded(ancestor) { return true }
        }
        return !isDir && Self.firstMatch(fileRules, relativePath as NSString) == false
    }

    private func dirIncluded(_ dir: String) -> Bool {
        if let cached = dirVerdicts[dir] { return cached }
        if dirVerdicts.count >= 20_000 { dirVerdicts.removeAll() }  // unique run/temp dir names
        let included = Self.firstMatch(dirRules, dir as NSString) ?? true
        dirVerdicts[dir] = included
        return included
    }

    private static func firstMatch(_ rules: [Rule], _ s: NSString) -> Bool? {
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
/// caller passes `now`, FSEvents ids and an `exists` check. Coverage by a full
/// run is decided by event id (an event with an id at or below the id taken
/// when the run started happened before it), never by wall-clock time.
struct DirtySet {
    /// A path must be quiet this long before it is uploaded, so a file being
    /// written is not uploaded once per write (and mostly not mid-write, L9.1).
    static let quiet: TimeInterval = 10
    /// …but a file that never goes quiet (an appended log) is still uploaded
    /// at least this often — and at most about this often.
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
        var lastEventId: UInt64
        /// A directory event (a moved directory reports only itself, S0 E4) or
        /// a collapsed directory. The batch then needs both `+ /p` and
        /// `+ /p/**` (the path may be a file again by then).
        var subtree: Bool
        var generation = 0
        var failures = 0
        var inFlight = false
        /// The first note while in flight: the next upload's clock and the
        /// entry's first event start here when it is kept, so `maxDelay` keeps
        /// throttling a never-quiet file and it does not pin the checkpoint.
        var notedInFlightAt: TimeInterval?
        var notedInFlightEventId: UInt64?
        /// Re-noted from a full run's failure: its change has no event a resume
        /// would replay, so no checkpoint may be saved while it is live.
        var unreplayable = false
    }

    struct BatchItem: Equatable {
        let path: String
        let subtree: Bool
        let generation: Int
    }

    private(set) var entries: [String: Entry] = [:]
    /// The event id at which the pending full run became required.
    private(set) var fullRequiredEventId: UInt64?
    var fullRequired: Bool { fullRequiredEventId != nil }
    private(set) var fullRunStartEventId: UInt64?
    private(set) var highestEventId: UInt64 = 0
    /// Paths dropped after `giveUpFailures`; the watcher logs them once.
    private(set) var gaveUp: [String] = []
    private var childCount: [String: Int] = [:]
    /// Entries strictly below each directory, so a directory event scans the
    /// set only when it has something to absorb.
    private var descendantCount: [String: Int] = [:]

    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    private static func ancestors(of path: String) -> [String] {
        var out: [String] = []
        var p = parent(of: path)
        while !p.isEmpty { out.append(p); p = parent(of: p) }
        return out
    }

    /// Raises the stream position the checkpoint may advance to when no entry
    /// is live. Callers pass only ids whose events are all noted already: the
    /// current id when a `sinceNow` stream starts (its catch-up full run covers
    /// what came before), the resumed checkpoint for a `sinceWhen` stream, and
    /// a callback's highest id after noting every event of that callback
    /// (excluded ones included) — during a replay only after `HistoryDone`.
    mutating func advance(toEventId id: UInt64) {
        highestEventId = max(highestEventId, id)
    }

    /// Records one FSEvents event for a root-relative path ("" = the root
    /// itself). `gap`: MustScanSubDirs, UserDropped, KernelDropped,
    /// EventIdsWrapped or RootChanged — the event stream lost detail.
    mutating func note(_ path: String, isDirEvent: Bool, gap: Bool, eventId: UInt64, now: TimeInterval) {
        highestEventId = max(highestEventId, eventId)
        if gap || path.isEmpty { return requireFullRun(eventId: eventId) }
        // A required full run that has not started yet starts after this
        // event, so it covers it; nothing to store.
        if fullRequired && fullRunStartEventId == nil { return }

        if let covering = coveringSubtree(of: path) {
            touch(covering, eventId: eventId, now: now, subtree: false)
            return
        }
        if entries[path] != nil {
            touch(path, eventId: eventId, now: now, subtree: isDirEvent)
        } else {
            insert(path, Entry(firstSeen: now, lastSeen: now, firstEventId: eventId, lastEventId: eventId, subtree: isDirEvent))
        }
        if isDirEvent { absorbDescendants(of: path) }
        let parent = Self.parent(of: path)
        if childCount[parent, default: 0] > Self.collapseChildren {
            if parent.isEmpty { return requireFullRun(eventId: eventId) }
            collapse(into: parent, now: now, eventId: eventId)
        }
        if entries.count > Self.fullRunThreshold { requireFullRun(eventId: eventId) }
    }

    private func coveringSubtree(of path: String) -> String? {
        Self.ancestors(of: path).first { entries[$0]?.subtree == true }
    }

    private mutating func insert(_ path: String, _ entry: Entry) {
        entries[path] = entry
        childCount[Self.parent(of: path), default: 0] += 1
        for a in Self.ancestors(of: path) { descendantCount[a, default: 0] += 1 }
    }

    private mutating func remove(_ path: String) {
        guard entries.removeValue(forKey: path) != nil else { return }
        let parent = Self.parent(of: path)
        childCount[parent, default: 1] -= 1
        if childCount[parent] == 0 { childCount.removeValue(forKey: parent) }
        for a in Self.ancestors(of: path) {
            descendantCount[a, default: 1] -= 1
            if descendantCount[a] == 0 { descendantCount.removeValue(forKey: a) }
        }
    }

    private mutating func touch(_ path: String, eventId: UInt64, now: TimeInterval, subtree: Bool) {
        guard var e = entries[path] else { return }
        e.lastSeen = now
        e.firstEventId = min(e.firstEventId, eventId)
        e.lastEventId = max(e.lastEventId, eventId)
        e.generation += 1
        e.subtree = e.subtree || subtree
        if e.inFlight && e.notedInFlightAt == nil { e.notedInFlightAt = now; e.notedInFlightEventId = eventId }
        entries[path] = e
    }

    /// Folds every idle entry below `dir` into `dir`'s entry (which must exist).
    /// In-flight entries finish on their own; the subtree re-covers them.
    private mutating func absorbDescendants(of dir: String) {
        guard descendantCount[dir, default: 0] > 0 else { return }
        let prefix = dir + "/"
        let absorbed = entries.filter { $0.key.hasPrefix(prefix) && !$0.value.inFlight }
        for (path, e) in absorbed {
            entries[dir]!.firstSeen = min(entries[dir]!.firstSeen, e.firstSeen)
            entries[dir]!.firstEventId = min(entries[dir]!.firstEventId, e.firstEventId)
            entries[dir]!.lastEventId = max(entries[dir]!.lastEventId, e.lastEventId)
            remove(path)
        }
    }

    private mutating func collapse(into dir: String, now: TimeInterval, eventId: UInt64) {
        if entries[dir] == nil {
            insert(dir, Entry(firstSeen: now, lastSeen: now, firstEventId: eventId, lastEventId: eventId, subtree: true))
        } else {
            touch(dir, eventId: eventId, now: now, subtree: true)
        }
        absorbDescendants(of: dir)
    }

    /// A full run must cover everything up to `eventId` (a gap, an overflow,
    /// or a watcher start without a usable checkpoint). Idle entries are
    /// dropped: that run starts after them.
    mutating func requireFullRun(eventId: UInt64) {
        // Raised while a full run is in flight: that run never clears it,
        // whatever the id says (RootChanged carries id 0; replays are unsorted).
        let floor = fullRunStartEventId.map { $0 + 1 } ?? 0
        fullRequiredEventId = max(fullRequiredEventId ?? 0, eventId, floor)
        highestEventId = max(highestEventId, eventId)
        for (path, e) in entries where !e.inFlight { remove(path) }
    }

    func isReady(_ e: Entry, now: TimeInterval) -> Bool {
        !e.inFlight && (now - e.lastSeen >= Self.quiet || now - e.firstSeen >= Self.maxDelay)
    }

    /// When the earliest idle entry becomes ready; nil when there is none.
    func nextWakeup(now: TimeInterval) -> TimeInterval? {
        entries.values.filter { !$0.inFlight }
            .map { max(now, min($0.lastSeen + Self.quiet, $0.firstSeen + Self.maxDelay)) }
            .min()
    }

    /// Up to `limit` ready entries, oldest first, marked in flight.
    mutating func takeBatch(now: TimeInterval, limit: Int) -> [BatchItem] {
        let ready = entries.filter { isReady($0.value, now: now) }
            .sorted { ($0.value.firstSeen, $0.key) < ($1.value.firstSeen, $1.key) }
            .prefix(limit)
        return ready.map { path, e in
            entries[path]!.inFlight = true
            entries[path]!.notedInFlightAt = nil
            entries[path]!.notedInFlightEventId = nil
            return BatchItem(path: path, subtree: e.subtree, generation: e.generation)
        }
    }

    /// Whether an entry covers one of the failed paths. A subtree entry, and a
    /// file entry whose path is gone (the batch also sends `+ /p/**`), cover
    /// everything below them.
    private static func carries(_ path: String, coversBelow: Bool, of failed: Set<String>) -> Bool {
        failed.contains(path) || (coversBelow && failed.contains { $0.hasPrefix(path + "/") })
    }

    /// An entry this run may have finished: dropped if nothing new arrived
    /// while it was in flight, else kept with a fresh upload clock.
    private mutating func settle(_ path: String, generation: Int) {
        guard var e = entries[path] else { return }
        if e.generation == generation { return remove(path) }
        e.failures = 0
        e.unreplayable = false
        e.firstSeen = e.notedInFlightAt ?? e.lastSeen
        e.firstEventId = e.notedInFlightEventId ?? e.firstEventId
        e.notedInFlightAt = nil
        e.notedInFlightEventId = nil
        entries[path] = e
    }

    mutating func finish(_ batch: [BatchItem], outcome: RunOutcome, exists: (String) -> Bool) {
        for item in batch {
            guard entries[item.path] != nil else { continue }
            entries[item.path]!.inFlight = false
            switch outcome {
            case .runFailed:
                entries[item.path]!.notedInFlightAt = nil
                entries[item.path]!.notedInFlightEventId = nil
            case .success:
                settle(item.path, generation: item.generation)
            case .objectErrors(let failed, let deletesSkipped):
                var e = entries[item.path]!
                let gone = !exists(item.path)
                if Self.carries(item.path, coversBelow: e.subtree || gone, of: failed) {
                    e.failures += 1
                    e.notedInFlightAt = nil
                    e.notedInFlightEventId = nil
                    entries[item.path] = e
                    // New content noted during the run was never tried: keep it.
                    if e.failures >= Self.giveUpFailures && e.generation == item.generation {
                        gaveUp.append(item.path)
                        remove(item.path)
                    }
                } else if deletesSkipped && (e.subtree || gone) {
                    // Its delete was skipped: retry, no failure counted.
                    e.failures = 0
                    e.notedInFlightAt = nil
                    e.notedInFlightEventId = nil
                    entries[item.path] = e
                } else {
                    settle(item.path, generation: item.generation)
                }
            }
        }
    }

    /// `startEventId`: FSEvents' current id when the full run started.
    mutating func fullRunStarted(startEventId: UInt64) {
        fullRunStartEventId = startEventId
        highestEventId = max(highestEventId, startEventId)
    }

    mutating func fullRunFinished(outcome: RunOutcome, exists: (String) -> Bool) {
        guard let start = fullRunStartEventId else { return }
        fullRunStartEventId = nil
        guard outcome != .runFailed else { return }
        if let required = fullRequiredEventId, required <= start {
            fullRequiredEventId = nil
        }
        var failed: Set<String> = []
        var deletesSkipped = false
        if case .objectErrors(let f, let d) = outcome { failed = f; deletesSkipped = d }
        for (path, e) in entries where !e.inFlight {
            if e.lastEventId <= start {
                if deletesSkipped && (e.subtree || !exists(path)) { continue }
                remove(path)
            } else {
                // Its events up to `start` are covered; only later ones are not.
                entries[path]!.firstEventId = max(e.firstEventId, start + 1)
            }
        }
        // Through `note`, so collapse and the size limit apply (a mass failure,
        // e.g. an S4 block, becomes a full-run requirement, not 6,000 entries).
        for path in failed {
            note(path, isDirEvent: false, gap: false, eventId: start, now: 0)
            let carrier = entries[path] != nil ? path : coveringSubtree(of: path)
            if let carrier {
                entries[carrier]!.failures = max(entries[carrier]!.failures, 1)
                entries[carrier]!.unreplayable = true
            }
        }
    }

    /// The FSEvents id up to which everything is on the remote: nil while a
    /// full run is required or a full run's failure is pending (a restart must
    /// run a full run), else one below the oldest event any live entry still
    /// carries, else the stream position.
    var checkpoint: UInt64? {
        if fullRequired || entries.values.contains(where: \.unreplayable) { return nil }
        guard let oldest = entries.values.map(\.firstEventId).min() else { return highestEventId }
        return oldest == 0 ? 0 : oldest - 1
    }

    mutating func clearGaveUp() { gaveUp.removeAll() }
}
