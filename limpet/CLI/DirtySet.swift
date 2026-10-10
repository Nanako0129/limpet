import CoreServices
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

    /// Whether rclone's dump holds an include (`+`) file or directory rule. A
    /// profile whose exclude file includes something cannot run batches: that
    /// rule matches before the batch's own rules (limpet-plan.md L9.2).
    static func dumpHasIncludeRule(_ dump: String) -> Bool {
        var inRules = false
        for line in dump.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("--- ") && line.hasSuffix(" ---") {
                inRules = line == "--- File filter rules ---" || line == "--- Directory filter rules ---"
            } else if inRules && line.hasPrefix("+ ") {
                return true
            }
        }
        return false
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
    /// item carries is not counted against anyone; see `finish`).
    static let giveUpFailures = 3
    /// A failing path that keeps changing gets this many extra tries (its new
    /// content was never tried), then is given up anyway, so it cannot pin
    /// every batch.
    static let giveUpFailuresWhileChanging = 5

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
    /// nothing) cannot be pinned on anyone: the batch is handled as `.runFailed`
    /// (every item kept, nothing counted) and a full run is owed. S2's
    /// classifier maps unattributable error lines to `.runFailed` itself; this
    /// is DirtySet's guard for the same.
    mutating func finish(_ batch: [BatchItem], outcome: RunOutcome, exists: (String) -> Bool) {
        var outcome = outcome
        var gone: Set<String> = [], carriers: Set<String> = []
        if case .objectErrors(let failed, _) = outcome {
            var carriedFailures: Set<String> = []
            for item in batch {
                guard let e = entries[item.path] else { continue }
                if !e.subtree && !exists(item.path) { gone.insert(item.path) }
                let covered = Self.scope(of: item.path, subtree: e.subtree || gone.contains(item.path))
                let mine = Self.carried(by: covered.path, coversBelow: covered.subtree, of: failed)
                if !mine.isEmpty { carriers.insert(item.path); carriedFailures.formUnion(mine) }
            }
            if failed.isEmpty || !failed.isSubset(of: carriedFailures) {
                raiseOwed()
                outcome = .runFailed
            }
        }
        for item in batch {
            guard let e = entries[item.path] else { continue }
            entries[item.path]!.inFlight = false
            let changed = e.generation != item.generation
            switch outcome {
            case .runFailed:
                requeue(item.path, changed: changed, uploaded: false)
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

// MARK: - Batch filter file and run classification (limpet-plan.md L9.2 S2)

extension DirtySet {
    /// Scalars whose name rclone filters in a different form than the bytes on
    /// disk (its Standard encoding on macOS, lib/encoder): control characters
    /// and DEL become U+2401–U+241F / U+2421, and those symbols or the quote
    /// rune U+201B in a name get quoted. Measured with rclone 1.75.1: raw rules
    /// for a tab or U+201B match nothing; raw rules for U+2400, U+2420, U+FF0E
    /// and U+FF0F do match, so those are fine. Such a path is synced through
    /// its nearest clean ancestor (`scope`).
    static func rcloneReencodes(_ path: String) -> Bool {
        path.unicodeScalars.contains { s in
            (0x01...0x1F).contains(s.value) || s.value == 0x7F || (0x2401...0x241F).contains(s.value)
                || s.value == 0x2421 || s.value == 0x201B
        }
    }

    /// What a batch item actually covers: the item, or — for a path rclone
    /// re-encodes — its nearest clean ancestor as a subtree. Used both to write
    /// the filter and to attribute failures (each with its own lstat of a gone
    /// path, so a path recreated mid-run can make a failure unattributed,
    /// which only costs a full run). An empty path means the root; the watcher
    /// is to turn such a path into a full run instead (limpet-plan.md L9.2 S2b).
    static func scope(of path: String, subtree: Bool) -> (path: String, subtree: Bool) {
        var p = path
        var sub = subtree
        while rcloneReencodes(p) {
            p = parent(of: p)
            sub = true
        }
        return (p, sub)
    }

    /// One rclone glob that matches `path`: `\` before `\ * ? [ ]`
    /// (fs/filter/glob.go); `{` and `}` as `?` (any one character), because
    /// rclone's directory-glob derivation gives up on `{{`, `}}`, `{…{` and
    /// `{…/…}` even when escaped (`tooHardRe`, measured) and would then walk
    /// every directory — matching a few extra same-named siblings is harmless; trailing whitespace bracketed,
    /// because rclone trims each filter-file line with Go's strings.TrimSpace
    /// (which also takes U+0085, U+00A0 and the Unicode space separators).
    /// Works on scalars, so a combining mark cannot hide a metacharacter.
    static func globEscaped(_ path: String) -> String {
        var scalars = Array(path.unicodeScalars)
        var trailing: [Unicode.Scalar] = []
        while let last = scalars.last, last.properties.isWhitespace {
            trailing.insert(scalars.removeLast(), at: 0)
        }
        var out = ""
        for scalar in scalars {
            if scalar == "{" || scalar == "}" { out += "?"; continue }
            if "\\*?[]".unicodeScalars.contains(scalar) { out.unicodeScalars.append("\\") }
            out.unicodeScalars.append(scalar)
        }
        for scalar in trailing {
            out += "["
            out.unicodeScalars.append(scalar)
            out += "]"
        }
        return out
    }

    /// The batch's filter file, read by rclone after the profile's rules:
    /// `+ /p` and `+ /p.rclonelink` (a symlink under `--links`) for every item,
    /// `+ /p/**` too for a subtree entry or a path that is gone (lstat), and a
    /// final `- **`. A path rclone re-encodes is replaced by its nearest
    /// ancestor without such a scalar, as a subtree (`scope`); `+ /**` only as
    /// a fallback for a root scope, which the watcher is to replace with a full
    /// run (L9.2 S2b).
    static func filterRules(for batch: [BatchItem], exists: (String) -> Bool) -> String {
        var lines: [String] = []
        for item in batch {
            let (path, subtree) = scope(of: item.path, subtree: item.subtree || !exists(item.path))
            if path.isEmpty {
                lines.append("+ /**")
                continue
            }
            let glob = "/" + globEscaped(path)
            lines.append("+ " + glob)
            lines.append("+ /" + globEscaped(path + ".rclonelink"))
            if subtree { lines.append("+ " + glob + "/**") }
        }
        lines.append("- **")
        return lines.joined(separator: "\n") + "\n"
    }
}

extension RunOutcome {
    /// What a finished run did, from its exit code and its own part of the
    /// profile log (rclone 1.75.1 `--use-json-log` lines).
    /// - Exit 0 is success only if the script logged `Sync completed
    ///   successfully` (an unmounted drive exits 0 without running rclone).
    /// - Exit 1, 5, 6 or 77 whose error/critical lines are all per-object failures
    ///   (`objectType` ending `.Object`) or rclone's own follow-ups is
    ///   `.objectErrors`, with the failures of the LAST attempt only (a path
    ///   that failed in attempt 1 and succeeded in attempt 2 is fine).
    ///   Follow-ups: `Attempt …` and `Can't retry any of the errors …` with no
    ///   object; `not deleting files|directories as there were IO errors`
    ///   (an `.Fs` objectType), which sets `deletesSkipped`.
    /// - Everything else — any other code (75/76/78/79 …), any other error
    ///   line, a `{` line that is not JSON, or no named object — is `.runFailed`.
    static func classify(exitCode: Int32, runLog: String) -> RunOutcome {
        if exitCode == 0 {
            return runLog.contains(" - Sync completed successfully") ? .success : .runFailed
        }
        // 5 is rclone's exit when the last error was retryable. Read by line
        // shape like 1 and 6: one object that keeps failing names itself and
        // must be countable and given up. Accepted (not measured): an outage
        // that starts mid-transfer also names the in-flight objects, so they
        // can be given up to the owed full run, which retries them.
        // 77 is the script's "only files changing during upload" (L9.1): its
        // lines name those files, so they are charged like any object error.
        guard exitCode == 1 || exitCode == 5 || exitCode == 6 || exitCode == 77 else { return .runFailed }
        var attempt: Set<String> = [], lastFailedAttempt: Set<String> = []
        var attemptSkipped = false, lastSkipped = false
        for line in runLog.split(separator: "\n") where line.hasPrefix("{") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return .runFailed }
            guard let level = json["level"] as? String, level == "error" || level == "critical" else { continue }
            let message = json["msg"] as? String ?? ""
            let type = json["objectType"] as? String ?? ""
            let object = json["object"] as? String
            if type.hasSuffix(".Object"), let object, !object.isEmpty {
                attempt.insert(object)
            } else if type.hasSuffix(".Fs"),
                      message.hasPrefix("not deleting files as there were IO errors")
                        || message.hasPrefix("not deleting directories as there were IO errors") {
                attemptSkipped = true
            } else if object == nil, message.hasPrefix("Attempt ") {
                // The end of one attempt: its failures are what counts so far
                // (none after `Attempt N/M succeeded`).
                let failedAttempt = message.contains(" failed with ")
                lastFailedAttempt = failedAttempt ? attempt : []
                lastSkipped = failedAttempt && attemptSkipped
                attempt = []
                attemptSkipped = false
            } else if object == nil, message.hasPrefix("Can't retry any of the errors") {
                continue
            } else {
                return .runFailed
            }
        }
        let failed = attempt.isEmpty ? lastFailedAttempt : attempt
        let skipped = attempt.isEmpty ? lastSkipped : attemptSkipped
        return failed.isEmpty ? .runFailed : .objectErrors(failedPaths: failed, deletesSkipped: skipped)
    }
}

// MARK: - Incremental planner (limpet-plan.md L9.2 S2b)

/// Decides what the watcher runs next in incremental mode: a full run (asked
/// for, required by the set, or owed and its backoff elapsed) before a batch
/// of ready paths, with retry delays after failures and gate refusals. Pure:
/// the caller passes `now` (monotonic seconds) and FSEvents ids.
struct IncrementalPlanner {
    enum Run: Equatable {
        case full
        case batch([DirtySet.BatchItem])
    }

    var dirty = DirtySet()
    /// A full run was asked for: watcher start (catch-up), the periodic timer,
    /// "Sync now", the source coming back, or a rules change.
    private(set) var fullRequested = true
    let batchLimit: Int
    private(set) var inFlight: Run?
    private var batchFailures = 0
    private var fullFailures = 0
    private var refusals = 0
    /// A gate refusal only spaces out the wake timer (no polling while a gate
    /// keeps refusing); a trigger whose gates pass may still run.
    private var wakeNotBefore: TimeInterval = 0
    private(set) var batchNotBefore: TimeInterval = 0
    private(set) var fullNotBefore: TimeInterval = 0
    /// When the current owe began or its last failed full run ended.
    private(set) var owedSince: TimeInterval?

    init(batchLimit: Int) {
        self.batchLimit = max(1, batchLimit)
    }

    /// Retry delay after `n` failures in a row: 30 s doubling, at most 30 min.
    static func retryDelay(_ n: Int) -> TimeInterval {
        n <= 0 ? 0 : min(30 * pow(2, Double(min(n, 16) - 1)), 1800)
    }

    /// The owed full run's wait after `n` full runs in a row ended with object
    /// errors (limpet-plan.md contract): `min(30 s × 2^max(n−1, 0), 30 min)`
    /// while n ≤ 7; past that only the periodic full run serves it (nil).
    static func owedDelay(_ n: Int) -> TimeInterval? {
        n > 7 ? nil : min(30 * pow(2, Double(max(n - 1, 0))), 1800)
    }

    /// An explicit request ("Sync now", source back, periodic, a refused batch)
    /// runs at once; if it fails, the failure delay doubles from where it was.
    mutating func requestFull() {
        fullRequested = true
        fullNotBefore = 0
    }

    private var fullWanted: Bool { fullRequested || dirty.fullRequired }

    private func owedDue(_ now: TimeInterval) -> Bool {
        guard dirty.fullRunOwed, let since = owedSince, let wait = Self.owedDelay(dirty.owedFullRunFailures) else { return false }
        return now >= max(since + wait, fullNotBefore)
    }

    /// The run to start now, or nil. `currentEventId` is FSEvents' current id,
    /// read only when a full run starts.
    mutating func next(now: TimeInterval, currentEventId: () -> UInt64) -> Run? {
        guard inFlight == nil else { return nil }
        if dirty.fullRunOwed && owedSince == nil { owedSince = now }
        if (fullWanted && now >= fullNotBefore) || owedDue(now) {
            dirty.fullRunStarted(startEventId: currentEventId())
            inFlight = .full
            refusals = 0
            wakeNotBefore = 0
            return .full
        }
        guard now >= batchNotBefore else { return nil }
        let items = dirty.takeBatch(now: now, limit: batchLimit)
        guard !items.isEmpty else { return nil }
        inFlight = .batch(items)
        refusals = 0
        wakeNotBefore = 0
        return .batch(items)
    }

    /// When `next` could return something, for the wake timer; nil = nothing
    /// pending (a new event or request will wake the watcher).
    func nextWake(now: TimeInterval) -> TimeInterval? {
        guard inFlight == nil else { return nil }
        var times: [TimeInterval] = []
        if fullWanted { times.append(fullNotBefore) }
        if dirty.fullRunOwed, let wait = Self.owedDelay(dirty.owedFullRunFailures) {
            times.append(max((owedSince ?? now) + wait, fullNotBefore))
        }
        if let ready = dirty.nextWakeup(now: now) { times.append(max(ready, batchNotBefore)) }
        return times.min().map { max($0, now, wakeNotBefore) }
    }

    /// The started run ended. `exists`: lstat relative to the root.
    mutating func finished(_ outcome: RunOutcome, now: TimeInterval, exists: (String) -> Bool) {
        guard let run = inFlight else { return }
        inFlight = nil
        switch run {
        case .full:
            dirty.fullRunFinished(outcome: outcome, exists: exists)
            if outcome == .runFailed {
                fullFailures += 1
                fullNotBefore = now + Self.retryDelay(fullFailures)
            } else {
                fullFailures = 0
                fullNotBefore = 0
                fullRequested = false
            }
            owedSince = dirty.fullRunOwed ? now : nil
        case .batch(let items):
            dirty.finish(items, outcome: outcome, exists: exists)
            // Object errors are charged to their paths (given up after a few);
            // only a run that failed as a whole delays every batch.
            if outcome == .runFailed {
                batchFailures += 1
                batchNotBefore = now + Self.retryDelay(batchFailures)
            } else {
                batchFailures = 0
                batchNotBefore = 0
            }
            if dirty.fullRunOwed && owedSince == nil { owedSince = now }
        }
    }

    /// A gate refused to start anything (source missing, delete limit,
    /// overlap, lingering group): the wake timer waits 30 s doubling to 30 min.
    mutating func refused(now: TimeInterval) {
        refusals += 1
        wakeNotBefore = now + Self.retryDelay(refusals)
    }
}

// MARK: - FSEvents to DirtySet, and the watcher glue (limpet-plan.md L9.2 S2b)

/// One FSEvents event as `DirtySet.note` needs it.
struct FSEventNote: Equatable {
    let path: String
    let isDir: Bool
    let gap: Bool
    let maybeSymlink: Bool

    /// nil: outside `root` (FSEvents can report other paths on the volume),
    /// HistoryDone, or an ordinary event for the root itself. `root` is the canonical (realpath) sync root, the form
    /// FSEvents reports. MustScanSubDirs for a path is a directory event for
    /// it; for the root, or UserDropped/KernelDropped/EventIdsWrapped/
    /// RootChanged, a gap.
    static func convert(path: String, flags: UInt32, root: String) -> FSEventNote? {
        func has(_ flag: Int) -> Bool { flags & UInt32(flag) != 0 }
        if has(kFSEventStreamEventFlagHistoryDone) { return nil }
        let rel: String
        if path == root || path == root + "/" { rel = "" }
        else if path.hasPrefix(root + "/") { rel = String(path.dropFirst(root.count + 1)) }
        else { return nil }
        let mustScan = has(kFSEventStreamEventFlagMustScanSubDirs)
        let gap = has(kFSEventStreamEventFlagUserDropped) || has(kFSEventStreamEventFlagKernelDropped)
            || has(kFSEventStreamEventFlagEventIdsWrapped) || has(kFSEventStreamEventFlagRootChanged)
            || (mustScan && rel.isEmpty)
        // An ordinary event for the root itself (its own attributes, xattrs, a
        // Finder tag) changes nothing to sync; only a gap there means rescan.
        // Seen live: creating the root reports it with Created/IsDir/Xattr.
        if rel.isEmpty && !gap { return nil }
        let isFile = has(kFSEventStreamEventFlagItemIsFile)
        let isDir = has(kFSEventStreamEventFlagItemIsDir) || mustScan
        let isLink = has(kFSEventStreamEventFlagItemIsSymlink)
        return FSEventNote(path: rel, isDir: isDir, gap: gap, maybeSymlink: isLink || !(isFile || isDir))
    }
}

/// Connects the watcher's scheduler hooks, FSEvents and the sync script to
/// `IncrementalPlanner` (limpet-plan.md L9.2 S2b). All I/O is injected so the
/// self-test drives it; the daemon passes the real primitives. Main queue only.
final class IncrementalDriver {
    struct IO {
        /// Monotonic seconds.
        var now: () -> TimeInterval
        var currentEventId: () -> UInt64
        /// lstat of a root-relative path.
        var exists: (String) -> Bool
        /// Writes the batch filter text; returns its path, or nil on failure.
        var writeFilter: (String) -> String?
        var removeFilter: (String) -> Void
        var logSize: () -> UInt64
        /// The profile log from `offset` (the whole file if it shrank: rotation).
        var readLog: (_ offset: UInt64) -> String
        /// Arm the wake timer for this monotonic time, or cancel it (nil).
        var scheduleWake: (TimeInterval?) -> Void
        /// Whether the profile's exclude file changed since the watcher started.
        var excludeFileChanged: () -> Bool
        var log: (String) -> Void
    }

    private(set) var planner: IncrementalPlanner
    private let oracle: ExcludeOracle?
    /// The canonical (realpath) sync root, the form FSEvents reports.
    let root: String
    private let io: IO
    private var pending: IncrementalPlanner.Run?
    private var running: (run: IncrementalPlanner.Run, logOffset: UInt64, filterPath: String?)?
    /// The exclude rules changed: the watcher restarts (when idle) so a fresh
    /// start rebuilds the oracle and runs its catch-up full run.
    private(set) var restartRequested = false

    init(planner: IncrementalPlanner, oracle: ExcludeOracle?, root: String, io: IO) {
        self.planner = planner
        self.oracle = oracle
        self.root = root
        self.io = io
        self.planner.dirty.advance(toEventId: io.currentEventId())
    }

    /// Scheduler hook, after its gates passed: whether there is a run to start.
    func prepareRun() -> Bool {
        guard !restartRequested else { return false }
        pending = planner.next(now: io.now(), currentEventId: io.currentEventId)
        if pending == nil { rearm() }
        return pending != nil
    }

    /// For the run `prepareRun` chose: the script's extra arguments and
    /// environment. nil if the batch filter could not be written (the run is
    /// then recorded as failed and nothing is spawned).
    func startRun() -> (arguments: [String], environment: [String: String])? {
        guard let run = pending else { return ([], [:]) }
        pending = nil
        let offset = io.logSize()
        guard case .batch(let items) = run else {
            running = (run, offset, nil)
            return ([], [:])
        }
        guard let path = io.writeFilter(DirtySet.filterRules(for: items, exists: io.exists)) else {
            io.log("Batch not started: could not write its filter file")
            running = (run, offset, nil)
            runEnded(exitCode: 1)
            return nil
        }
        running = (run, offset, path)
        return ([path], ["LIMPET_BATCH_ITEMS": String(items.count)])
    }

    func runEnded(exitCode: Int32) {
        guard let r = running else { return }
        running = nil
        if let path = r.filterPath { io.removeFilter(path) }
        // Always classified: an exit 0 counts only with the script's completion
        // line (an unmounted drive exits 0 without running rclone).
        let outcome = RunOutcome.classify(exitCode: exitCode, runLog: io.readLog(r.logOffset))
        planner.finished(outcome, now: io.now(), exists: io.exists)
        // The script refused the batch (exit 64: a flag, variable or rclone.conf
        // setting that changes what a batch would sync). Retrying the batch cannot
        // help; a full run carries its paths.
        if exitCode == 64, case .batch = r.run { planner.requestFull() }
        if !planner.dirty.gaveUp.isEmpty {
            io.log("Gave up on \(planner.dirty.gaveUp.count) path(s) after repeated failed batches; the next full run retries them")
            planner.dirty.clearGaveUp()
        }
        rearm()
    }

    /// Scheduler hook: a gate refused to start anything.
    func refused() {
        planner.refused(now: io.now())
        rearm()
    }

    func requestFull() {
        planner.requestFull()
        rearm()
    }

    /// One FSEvents callback's events (path, flags, id), in delivery order.
    func events(_ events: [(path: String, flags: UInt32, id: UInt64)]) {
        if io.excludeFileChanged() {
            if !restartRequested { io.log("Exclude rules changed: restarting the watcher") }
            restartRequested = true
            return
        }
        let now = io.now()
        var highest: UInt64 = 0
        for event in events {
            highest = max(highest, event.id)
            guard let n = FSEventNote.convert(path: event.path, flags: event.flags, root: root) else { continue }
            if !n.gap && !n.path.isEmpty, oracle?.isExcluded(n.path, isDir: n.isDir, maybeSymlink: n.maybeSymlink) == true { continue }
            // A path whose first component rclone re-encodes has no clean
            // ancestor to batch (`DirtySet.scope` is the root): a full run.
            let rootOnly = !n.path.isEmpty && DirtySet.scope(of: n.path, subtree: n.isDir).path.isEmpty
            planner.dirty.note(n.path, isDirEvent: n.isDir, gap: n.gap || rootOnly, eventId: event.id, now: now)
        }
        planner.dirty.advance(toEventId: highest)
        rearm()
    }

    private func rearm() {
        io.scheduleWake(planner.nextWake(now: io.now()))
    }
}
