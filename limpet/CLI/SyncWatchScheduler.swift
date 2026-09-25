import Foundation

/// Everything `SyncWatchScheduler` needs from the outside world, injected so
/// the scheduler itself is a pure state machine — `ConfigSelfTest` drives it
/// with a synchronous fake runner and a virtual clock, with no real process,
/// timer, or filesystem touched. See limpet-plan.md L3.
struct SchedulerRunner {
    /// Whether the profile's local source path currently exists. Checked
    /// before every run attempt (including a post-backoff retry) — if it
    /// stops existing between one run and the next, that run is skipped.
    var sourceExists: () -> Bool
    /// Run the sync script child, and call `completion` with its exit code
    /// once it finishes. Asynchronous by signature so a real run doesn't have
    /// to block whatever queue the scheduler operates on; the self-test's
    /// fakes are free to call `completion` synchronously and immediately.
    var runChild: (_ completion: @escaping (Int32) -> Void) -> Void
    /// Monotonic-ish wall-clock seconds. Production uses the real clock; the
    /// self-test uses a `VirtualClock`.
    var now: () -> TimeInterval
    /// Schedule `action` to run after `seconds`. Production dispatches onto
    /// the main queue; the self-test's `VirtualClock` fires it once advanced
    /// past the deadline.
    var scheduleAfter: (_ seconds: TimeInterval, _ action: @escaping () -> Void) -> Void
    /// Called when a run attempt finds the source path missing — already
    /// throttled to at most once per `missingSourceRecheckInterval` by the
    /// scheduler, so this closure just needs to append the log line.
    var logSourceMissing: () -> Void
}

/// Pure idle/running/(running+pending) scheduler for one profile's realtime
/// watcher (limpet-plan.md L3). Owns none of its own timers or processes —
/// every side effect goes through the injected `SchedulerRunner` — so the
/// exact rerun-count rules below are fully unit-testable:
///
/// - Any `trigger()` while a run is in flight (FSEvents change, the periodic
///   safety timer, or a manual SIGUSR1) coalesces into a single `pending`
///   flag; when that run's child exits 0 or 1, pending causes EXACTLY one
///   more run, never a pile-up of reruns for N triggers.
/// - A child exit of 75 (the sync script's lock-held code) is never retried
///   immediately — it schedules a fixed backoff instead, so two watchers (a
///   manual `bash script.sh` run and the launchd-owned watcher) racing the
///   same lock settle into a steady 1-in-`backoffInterval` retry cadence
///   rather than a hot loop.
/// - A missing source path never runs the child; it logs (at most once per
///   `missingSourceRecheckInterval`) and stays idle, so a moved/unmounted
///   source can't turn into an empty-directory sync (see the plan's L3(a)/(b)
///   for why: an upstream bug let exactly this delete a whole remote).
final class SyncWatchScheduler {
    enum State: Equatable {
        case idle
        case running(pending: Bool)
        case backoff(pending: Bool)
    }

    private(set) var state: State = .idle
    /// Number of times `runner.runChild` has actually been invoked — what the
    /// self-test's "exact run counts" assertions read.
    private(set) var runCount = 0

    private let runner: SchedulerRunner
    private let backoffInterval: TimeInterval
    private let missingSourceRecheckInterval: TimeInterval
    private var lastMissingSourceLogAt: TimeInterval?

    init(
        runner: SchedulerRunner,
        backoffInterval: TimeInterval = 10,
        missingSourceRecheckInterval: TimeInterval = 30
    ) {
        self.runner = runner
        self.backoffInterval = backoffInterval
        self.missingSourceRecheckInterval = missingSourceRecheckInterval
    }

    /// Request a sync: from FSEvents (already debounced upstream by
    /// `DirectoryWatcher`), the periodic safety timer, a manual SIGUSR1
    /// request, or the initial catch-up sync at watcher start.
    func trigger() {
        switch state {
        case .idle:
            startRun()
        case .running:
            state = .running(pending: true)
        case .backoff:
            state = .backoff(pending: true)
        }
    }

    private func startRun() {
        guard runner.sourceExists() else {
            maybeLogSourceMissing()
            return  // stays .idle — no run, per limpet-plan.md L3(a).
        }
        state = .running(pending: false)
        runCount += 1
        runner.runChild { [weak self] code in
            self?.handleExit(code: code)
        }
    }

    private func handleExit(code: Int32) {
        if code == 75 {
            let pending = currentPending()
            state = .backoff(pending: pending)
            runner.scheduleAfter(backoffInterval) { [weak self] in
                self?.retryAfterBackoff()
            }
            return
        }

        // Any other exit (0 = success, everything else = a real failure the
        // script already logged) — the scheduler doesn't distinguish success
        // from a non-75 failure: either way, a pending trigger earns exactly
        // one rerun, otherwise the profile goes idle.
        if currentPending() {
            startRun()
        } else {
            state = .idle
        }
    }

    private func retryAfterBackoff() {
        guard runner.sourceExists() else {
            maybeLogSourceMissing()
            state = .idle
            return
        }
        state = .running(pending: currentPending())
        runCount += 1
        runner.runChild { [weak self] code in
            self?.handleExit(code: code)
        }
    }

    private func currentPending() -> Bool {
        switch state {
        case .running(let pending): return pending
        case .backoff(let pending): return pending
        case .idle: return false
        }
    }

    private func maybeLogSourceMissing() {
        let now = runner.now()
        if let last = lastMissingSourceLogAt, now - last < missingSourceRecheckInterval { return }
        lastMissingSourceLogAt = now
        runner.logSourceMissing()
    }
}
