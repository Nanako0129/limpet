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
///
/// Confined to the watcher's main queue (its cache is unsynchronized).
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
    /// `&&` / `--` / a nested `[` / a leading `:` inside a bracket expression
    /// (ICU set operations and property classes, literal or ASCII in RE2).
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
                previous = "["
                continue
            }
            if inBracket && previous == "[" && c == ":" { return true }  // [:alpha:] is a Unicode property in ICU
        }
        return false
    }

    /// rclone's verdict for a root-relative path: skipped when an ancestor
    /// directory ("a/", "a/b/") is excluded by the directory rules (rclone never
    /// walks into it), or when the first matching file rule excludes it. No
    /// matching rule means included, as in rclone. `isDir`: the path is a
    /// directory (a directory event), so the directory check applies to it
    /// too — `rm -rf build` reports `build`.
    ///
    /// `maybeSymlink`: the sync runs with `--links`, under which rclone filters
    /// a symlink as `<name>.rclonelink` (measured, rclone 1.75.1), so the path
    /// counts as excluded only if that name is excluded too. Pass false only
    /// when FSEvents says the item is a regular file or directory.
    func isExcluded(_ relativePath: String, isDir: Bool = false, maybeSymlink: Bool = true) -> Bool {
        if relativePath.unicodeScalars.contains(where: { "\n\u{0B}\u{0C}\r\u{85}\u{2028}\u{2029}".unicodeScalars.contains($0) }) {
            return false  // ICU's `.` and `$` treat these unlike RE2
        }
        var ancestor = ""
        let components = relativePath.split(separator: "/")
        for component in components.dropLast() {
            ancestor += component + "/"
            if !dirIncluded(ancestor) { return true }
        }
        let linkExcluded = { !maybeSymlink || Self.firstMatch(self.fileRules, (relativePath + ".rclonelink") as NSString) == false }
        if isDir { return !dirIncluded(ancestor + (components.last.map(String.init) ?? "") + "/") && linkExcluded() }
        return Self.firstMatch(fileRules, relativePath as NSString) == false && linkExcluded()
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
/// Used from the watcher's main queue only.
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
    /// retries it. Keeps one bad file from pinning every batch (a failure no
    /// item carries is bounded by `giveUpUnattributed` instead).
    static let giveUpFailures = 3
    /// A failing path that keeps changing gets this many extra tries (its new
    /// content was never tried), then is given up anyway, so it cannot pin
    /// every batch.
    static let giveUpFailuresWhileChanging = 5
    /// Batches in a row that failed with a failure no item carries: past this
    /// the entry is given up to the owed full run, so a recurring unpinnable
    /// failure cannot hold the same items at the head of the queue forever.
    static let giveUpUnattributed = 5

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
        /// Consecutive batches this entry was in that failed unattributed.
        var unattributedFailures = 0
        var inFlight = false
        /// The first note while in flight: the next upload's clock and the
        /// entry's first event start here when it is kept, so `maxDelay` keeps
        /// throttling a never-quiet file and it does not pin the checkpoint.
        var notedInFlightAt: TimeInterval?
        /// The lowest event id folded in while in flight (notes, absorbed
        /// descendants): the entry's first event if it is kept.
        var notedInFlightEventId: UInt64?
    }

    /// S2 turns each item into `+ /p` and `+ /p.rclonelink` (a symlink under
    /// `--links`), plus `+ /p/**` for a subtree entry or a path that is gone.
    struct BatchItem: Equatable {
        let path: String
        let subtree: Bool
        let generation: Int
    }

    private(set) var entries: [String: Entry] = [:]
    /// The event id at which the pending full run became required.
    private(set) var fullRequiredEventId: UInt64?
    var fullRequired: Bool { fullRequiredEventId != nil }
    /// Raised while a full run was in flight: that run never clears it,
    /// whatever the ids say (RootChanged carries id 0; replays are unsorted).
    private var requiredDuringRun = false
    /// A full run is owed but not urgent: a full run reported failed objects
    /// or skipped deletes, or a batch gave up on a path or reported a failure
    /// no item carries. The checkpoint is nil meanwhile. Cleared only by a full
    /// run without errors that started after it was raised. When S2 runs it
    /// (its backoff from `owedFullRunFailures`) is S2's contract, recorded in
    /// limpet-plan.md L9.2.
    private(set) var fullRunOwed = false
    /// Full runs in a row that ended with object errors; S2 derives the owed
    /// run's backoff from it (contract in limpet-plan.md). Only a clean full run
    /// resets it — never a batch.
    private(set) var owedFullRunFailures = 0
    private var owedDuringRun = false
    private(set) var fullRunStartEventId: UInt64?
    /// What an empty set's checkpoint may claim: raised only by `advance` and
    /// by a covering full run, never by `note` (an unsorted replay delivers
    /// higher ids before lower ones).
    private(set) var streamPosition: UInt64 = 0
    /// Paths given up (`giveUpFailures`, or `giveUpFailuresWhileChanging` for
    /// one that kept changing); the watcher logs them once.
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
        streamPosition = max(streamPosition, id)
    }

    /// Records one FSEvents event for a root-relative path ("" = the root
    /// itself). `gap`: UserDropped, KernelDropped, EventIdsWrapped or
    /// RootChanged — the stream lost detail for everything. MustScanSubDirs for
    /// a path is passed as a directory event for that path (a subtree entry),
    /// or as a gap when the path is the root.
    mutating func note(_ path: String, isDirEvent: Bool, gap: Bool, eventId: UInt64, now: TimeInterval) {
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
        if e.inFlight {
            if e.notedInFlightAt == nil { e.notedInFlightAt = now }
            e.notedInFlightEventId = min(e.notedInFlightEventId ?? eventId, eventId)
        }
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
            if entries[dir]!.inFlight {
                entries[dir]!.notedInFlightEventId = min(entries[dir]!.notedInFlightEventId ?? e.firstEventId, e.firstEventId)
            }
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
        if fullRunStartEventId != nil { requiredDuringRun = true }
        fullRequiredEventId = max(fullRequiredEventId ?? 0, eventId)
        // Every idle entry goes, so the set is back under the limits that
        // raised this. If that run skips deletes (rclone skips them all when any
        // object fails), they wait for a full run that does not skip them
        // (`fullRunOwed`); entries still live at its end are kept for batches.
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

    /// The failed paths an entry carries: its own path, `<p>.rclonelink`
    /// (rclone's name for a symlink under `--links`), and — for a subtree entry
    /// or a path that is gone (the batch also sends `+ /p/**`) — anything below.
    private static func carried(by path: String, coversBelow: Bool, of failed: Set<String>) -> Set<String> {
        var mine = failed.intersection([path, path + ".rclonelink"])
        if coversBelow {
            let below = path + "/"
            mine.formUnion(failed.lazy.filter { $0.hasPrefix(below) })
        }
        return mine
    }

    /// The one place an entry leaves flight and stays in the set: when it was
    /// noted again during the run, its upload clock restarts from that note
    /// (so maxDelay keeps throttling a never-quiet file); `uploaded` (the run
    /// finished the content it took) also moves its first event there.
    private mutating func requeue(_ path: String, changed: Bool, uploaded: Bool) {
        guard var e = entries[path] else { return }
        if changed {
            e.firstSeen = e.notedInFlightAt ?? e.lastSeen
            if uploaded { e.firstEventId = e.notedInFlightEventId ?? e.firstEventId }
        }
        e.notedInFlightAt = nil
        e.notedInFlightEventId = nil
        entries[path] = e
    }

    /// `exists` must not follow symlinks (lstat): a dangling link still exists.
    /// A failure that no item of this batch carries (or `.objectErrors` naming
    /// nothing) cannot be pinned on anyone: every item is kept uncounted, as
    /// for `.runFailed`, a full run is owed, and an item in `giveUpUnattributed`
    /// such batches in a row is given up to that full run.
    mutating func finish(_ batch: [BatchItem], outcome: RunOutcome, exists: (String) -> Bool) {
        guard !batch.isEmpty else { return }
        var outcome = outcome
        var gone: Set<String> = [], carriers: Set<String> = []
        var unattributed = false
        if case .objectErrors(let failed, _) = outcome {
            var carriedFailures: Set<String> = []
            for item in batch {
                guard let e = entries[item.path] else { continue }
                if !e.subtree && !exists(item.path) { gone.insert(item.path) }
                let mine = Self.carried(by: item.path, coversBelow: e.subtree || gone.contains(item.path), of: failed)
                if !mine.isEmpty { carriers.insert(item.path); carriedFailures.formUnion(mine) }
            }
            if failed.isEmpty || !failed.isSubset(of: carriedFailures) {
                unattributed = true
                raiseOwed()
                outcome = .runFailed
            }
        }
        for item in batch {
            guard let e = entries[item.path] else { continue }
            entries[item.path]!.inFlight = false
            entries[item.path]!.unattributedFailures = unattributed ? e.unattributedFailures + 1 : 0
            let changed = e.generation != item.generation
            switch outcome {
            case .runFailed:
                if unattributed && entries[item.path]!.unattributedFailures >= Self.giveUpUnattributed {
                    gaveUp.append(item.path)
                    remove(item.path)
                } else {
                    requeue(item.path, changed: changed, uploaded: false)
                }
            case .success:
                done(item.path, changed: changed)
            case .objectErrors(_, let deletesSkipped):
                if carriers.contains(item.path) {
                    entries[item.path]!.failures += 1
                    // New content noted during the run was never tried: keep it,
                    // up to `giveUpFailuresWhileChanging`.
                    if entries[item.path]!.failures >= (changed ? Self.giveUpFailuresWhileChanging : Self.giveUpFailures) {
                        gaveUp.append(item.path)
                        raiseOwed()
                        remove(item.path)
                    } else {
                        requeue(item.path, changed: changed, uploaded: false)
                    }
                } else if deletesSkipped && (e.subtree || gone.contains(item.path)) {
                    // Its delete was skipped because of another item's failure:
                    // retry, no failure counted.
                    entries[item.path]!.failures = 0
                    requeue(item.path, changed: changed, uploaded: false)
                } else {
                    done(item.path, changed: changed)
                }
            }
        }
    }

    /// An owe raised while a full run is in flight is not cleared by that
    /// run's success (the same rule as `requiredDuringRun`).
    private mutating func raiseOwed() {
        fullRunOwed = true
        if fullRunStartEventId != nil { owedDuringRun = true }
    }

    /// The run finished this entry as taken: dropped, or kept with a fresh
    /// clock if it changed meanwhile.
    private mutating func done(_ path: String, changed: Bool) {
        guard changed else { return remove(path) }
        entries[path]!.failures = 0
        requeue(path, changed: true, uploaded: true)
    }

    /// `startEventId`: FSEvents' current id when the full run started.
    mutating func fullRunStarted(startEventId: UInt64) {
        fullRunStartEventId = startEventId
    }

    /// `.success` and `.objectErrors` both cover every change made before the
    /// run started; its failed objects are left to the owed full run. Entries
    /// that may carry a delete the run skipped stay, so a later batch can retry
    /// the delete (rclone skips it again if anything in that batch fails).
    /// `exists`: lstat, as in `finish`.
    mutating func fullRunFinished(outcome: RunOutcome, exists: (String) -> Bool) {
        guard let start = fullRunStartEventId else { return }
        fullRunStartEventId = nil
        defer { requiredDuringRun = false; owedDuringRun = false }  // the next run starts after it
        guard outcome != .runFailed else { return }
        if let required = fullRequiredEventId, required <= start, !requiredDuringRun {
            fullRequiredEventId = nil
        }
        var deletesSkipped = false
        if case .objectErrors(_, let skipped) = outcome {
            deletesSkipped = skipped
            fullRunOwed = true
            owedFullRunFailures += 1
        } else {
            fullRunOwed = owedDuringRun
            owedFullRunFailures = 0
        }
        streamPosition = max(streamPosition, start)
        for (path, e) in entries where !e.inFlight {
            if deletesSkipped && (e.subtree || !exists(path)) { continue }
            if e.lastEventId <= start {
                remove(path)
            } else {
                // Its events up to `start` are covered; only later ones are not.
                entries[path]!.firstEventId = max(e.firstEventId, start == .max ? start : start + 1)
            }
        }
    }

    /// The FSEvents id up to which everything is on the remote: nil while a
    /// full run is required or owed (a restart must run one first; S3 deletes
    /// its file then), else one below the oldest event any live entry still
    /// carries, else the stream position.
    var checkpoint: UInt64? {
        if fullRequired || fullRunOwed { return nil }
        guard let oldest = entries.values.map(\.firstEventId).min() else { return streamPosition }
        return oldest == 0 ? 0 : oldest - 1
    }

    mutating func clearGaveUp() { gaveUp.removeAll() }
}
