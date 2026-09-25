import Foundation

/// The install/uninstall work a profile-config delta implies.
enum ProfileReconcileAction: Equatable {
    /// Nothing sync/mount-related changed (e.g. only the display name).
    case none
    /// Was disabled, is now enabled — install the launchd agent.
    case install
    /// Was enabled, is now disabled — uninstall the launchd agent.
    case uninstall
    /// Still enabled, but a field that needs a fresh script/plist/agent changed.
    case reinstall
}

/// Outcome of considering an external `*.profile.json` write against an
/// UNKNOWN profile id — i.e. a potential CREATE, not an edit.
enum ExternalCreateOutcome: Equatable {
    /// Persisted AND the launchd agent installed (the profile was
    /// `isEnabled && isValid`).
    case createdAndInstalled
    /// Persisted only — created but not enabled/complete enough to install.
    /// An agent can flip `isEnabled`/fill in the remaining fields in a later
    /// edit, which then hits the ordinary known-id `.install` reconcile.
    case createdOnly
    /// Not a create: decode failed upstream, or the id was already known (the
    /// caller's existing edit path handles that case instead).
    case ignored
    /// A create that would sync an equal or nested remote path of an existing
    /// profile (F6, limpet-plan.md L4): neither persisted nor installed.
    case refusedOverlap
}

extension SyncManager {
    /// Decide whether an external `*.profile.json` drop bootstraps a NEW
    /// profile, and dispatch the persist/install side effects via injected
    /// closures — the SAME pure-decision-plus-injected-closure idiom as
    /// `reconcileAction`/`applyWarmReconcileIfNeeded` below, so this is
    /// spy-testable without a real `ProfileStore`/launchd.
    ///
    /// - `decoded == nil` (decode failed upstream) OR `isKnownId` → `.ignored`;
    ///   the caller's existing decode-failure/known-id-edit path handles it.
    /// - decoded, unknown id, `isEnabled && isValid` → `persist` then
    ///   `install`, exactly once each → `.createdAndInstalled`.
    /// - decoded, unknown id, otherwise → `persist` only → `.createdOnly`.
    /// - decoded, unknown id, remote path equal to or nested with one of
    ///   `existing` (enabled and installed) → neither; `quarantine` moves the
    ///   dropped file out of the scanned set → `.refusedOverlap` (F6).
    static func applyExternalCreateIfNeeded(
        decoded: SyncProfile?,
        isKnownId: Bool,
        existing: [SyncProfile],
        isInstalled: (SyncProfile) -> Bool,
        persist: (SyncProfile) -> Void,
        install: (SyncProfile) -> Void,
        quarantine: (_ reason: String) -> Void
    ) -> ExternalCreateOutcome {
        guard let profile = decoded, !isKnownId else { return .ignored }

        if let reason = SyncProfile.overlapError(profile, among: existing, isInstalled: isInstalled) {
            quarantine(reason)
            return .refusedOverlap
        }

        persist(profile)

        guard profile.isEnabled, profile.isValid else { return .createdOnly }

        install(profile)
        return .createdAndInstalled
    }

    /// Move a refused dropped profile file to `<profiles>/refused/<stem>.<UTC
    /// timestamp>.json`, so that neither `ProfileStore.load`, the watcher's
    /// re-read (both list `*.profile.json` directly in `profiles/`) nor
    /// `ConfigFileWatcher` (which reacts to a `.profile.json` suffix anywhere
    /// below `~/.config/limpet`) ever sees it again. Returns the new path, or
    /// `nil` if the move failed.
    nonisolated static func quarantineRefusedDrop(at path: String, now: Date = Date()) -> String? {
        let fm = FileManager.default
        let refusedDir = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent("refused")
        var stem = (path as NSString).lastPathComponent
        for suffix in [".profile.json", ".json"] where stem.hasSuffix(suffix) {
            stem = String(stem.dropLast(suffix.count))
            break
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let destination = (refusedDir as NSString).appendingPathComponent("\(stem).\(formatter.string(from: now)).json")
        do {
            try fm.createDirectory(atPath: refusedDir, withIntermediateDirectories: true)
            try fm.moveItem(atPath: path, toPath: destination)
            return destination
        } catch {
            return nil
        }
    }

    /// Decide what reconcile work a profile edit requires, given the
    /// previously-installed profile and the new (edited) profile values.
    ///
    /// Pure — no I/O, no side effects. This is the SINGLE source of truth for
    /// "what work does this delta need": both the Save button
    /// (`ProfileDetailView.saveProfile`) and the external-edit watcher
    /// (`SyncManager.applyExternalProfileEdit`) call this so they can never
    /// drift apart (see plan Decisions — a watcher-only copy of this logic
    /// would leave live-edited profiles stale).
    nonisolated static func reconcileAction(from current: SyncProfile, to updated: SyncProfile) -> ProfileReconcileAction {
        if current.isEnabled != updated.isEnabled {
            return updated.isEnabled ? .install : .uninstall
        }
        guard updated.isEnabled else { return .none }

        let needsReinstall =
            current.rcloneRemote != updated.rcloneRemote ||
            current.remotePath != updated.remotePath ||
            current.localSyncPath != updated.localSyncPath ||
            current.syncIntervalMinutes != updated.syncIntervalMinutes ||
            current.additionalRcloneFlags != updated.additionalRcloneFlags ||
            current.syncDirection != updated.syncDirection ||
            current.transfers != updated.transfers ||
            current.maxDelete != updated.maxDelete ||
            current.remoteVersioning != updated.remoteVersioning

        return needsReinstall ? .reinstall : .none
    }
}

/// Applies a `settings.json` edit, ISOLATING the launch-at-login
/// (`SMAppService`) call from every other safe-key application so a thrown
/// error there can never corrupt state already applied by this reconcile —
/// or any other state, since this type never touches profile data at all.
///
/// Dependency-injected (rather than calling `SMAppService` directly) so
/// `ConfigSelfTest` can exercise the isolation guarantee by injecting a
/// failing `applyLoginItem` closure, without needing a real, possibly-signed
/// login-item registration to succeed or fail in a controlled way.
enum SettingsReconciler {
    static func apply(
        safeSettings: [AppSettingsFileStore.SafeKey: Bool],
        applySafeKey: (AppSettingsFileStore.SafeKey, Bool) -> Void,
        currentLoginItemEnabled: () -> Bool,
        applyLoginItem: (Bool) throws -> Void
    ) {
        for key in AppSettingsFileStore.SafeKey.allCases where key != .launchAtLogin {
            if let value = safeSettings[key] {
                applySafeKey(key, value)
            }
        }

        guard let desiredLoginItem = safeSettings[.launchAtLogin],
              desiredLoginItem != currentLoginItemEnabled() else { return }

        do {
            try applyLoginItem(desiredLoginItem)
        } catch {
            // ISOLATED: a failure here must not affect anything applied above,
            // or any profile state — this method never touches profiles.
            LimpetSettings.debugLog("[SettingsReconciler] launch-at-login edit failed: \(error)")
        }
    }
}
