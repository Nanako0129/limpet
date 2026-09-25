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

    /// Review finding 6: what a profile change must pass BEFORE anything is
    /// persisted — F4 field validation and the F6 overlap rule.
    nonisolated static func profileChangeRefusal(
        _ updated: SyncProfile, others: [SyncProfile], isInstalled: (SyncProfile) -> Bool
    ) -> String? {
        updated.validationError ?? SyncProfile.overlapError(updated, among: others, isInstalled: isInstalled)
    }

    /// Apply an edit or an enable/disable of an EXISTING profile: refuse before
    /// persisting (nothing written, the old agent keeps running), then persist,
    /// then drive the launchd delta `reconcileAction` picks. Every refusal and
    /// every install/uninstall error goes to `reportError` instead of only
    /// being printed. Pure over its closures so `ConfigSelfTest` checks the
    /// order; `applyExternalProfileEdit` and `setProfileEnabled` use it.
    /// Returns whether the change was persisted.
    @discardableResult
    static func applyProfileChange(
        from current: SyncProfile,
        to updated: SyncProfile,
        others: [SyncProfile],
        isInstalled: (SyncProfile) -> Bool,
        persist: (SyncProfile) -> Void,
        install: (SyncProfile) throws -> Void,
        uninstall: (SyncProfile) throws -> Void,
        reportError: (String) -> Void
    ) -> Bool {
        if let reason = profileChangeRefusal(updated, others: others, isInstalled: isInstalled) {
            reportError("Not saved: \(reason)")
            return false
        }
        persist(updated)
        do {
            switch reconcileAction(from: current, to: updated) {
            case .none:
                break
            case .install:
                try install(updated)
            case .uninstall:
                try uninstall(updated)
            case .reinstall:
                try? uninstall(current)  // cleanup; the install below regenerates everything
                try install(updated)
            }
        } catch {
            reportError("Saved, but the background sync was not updated: \(error.localizedDescription)")
        }
        return true
    }

    /// Move a refused dropped profile file to `<profiles>/refused/<stem>.<UTC
    /// timestamp>.json`, so that neither `ProfileStore.load`, the watcher's
    /// re-read (both list `*.profile.json` directly in `profiles/`) nor
    /// `ConfigFileWatcher` (which reacts to a `.profile.json` suffix anywhere
    /// below `~/.config/limpet`) ever sees it again. Returns the new path, or
    /// `nil` if the move failed.
    nonisolated static func quarantineRefusedDrop(at path: String, now: Date = Date()) -> String? {
        let destination = refusedDestination(for: path, now: now)
        do {
            try FileManager.default.createDirectory(
                atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try FileManager.default.moveItem(atPath: path, toPath: destination)
            return destination
        } catch {
            return nil
        }
    }

    /// Where a refused profile file's content goes: `<dir>/refused/<stem>.<UTC
    /// timestamp>.json`, a name no `*.profile.json` scanner or watcher matches.
    nonisolated static func refusedDestination(for path: String, now: Date) -> String {
        let refusedDir = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent("refused")
        var stem = (path as NSString).lastPathComponent
        for suffix in [".profile.json", ".json"] where stem.hasSuffix(suffix) {
            stem = String(stem.dropLast(suffix.count))
            break
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return (refusedDir as NSString).appendingPathComponent("\(stem).\(formatter.string(from: now)).json")
    }

    /// Outcome of an external write to a `*.profile.json` (second review, finding 1).
    enum ExternalEditOutcome: Equatable {
        /// An edit of a known profile, accepted and applied.
        case applied
        /// An edit of a known profile that was refused or no longer decodes:
        /// the file holds the last accepted profile again, and the refused
        /// content was copied to `refusedCopy` (nil if that write failed).
        case restored(refusedCopy: String?)
        /// A decodable file with an unknown id: a create, for the caller.
        case create(SyncProfile)
        /// Not a JSON object with a known id (e.g. caught mid-write): nothing done.
        case ignored
    }

    /// Apply an external write to a profile file. A refused edit of a KNOWN
    /// profile — F4/F6/`transfers`, or content that no longer decodes although
    /// it is JSON carrying the profile's id — must not stay on disk, where the
    /// other profile's watcher would read it, this profile's watcher would
    /// keep the old values, and the next launch would load it without a
    /// reinstall. So the last accepted in-memory profile (`known`) is written
    /// back through `ProfileStore.writeProfileFile`, i.e. the self-write path
    /// `ConfigFileWatcher` ignores, a differently named file carrying that id
    /// is removed, the refused content is copied under `profiles/refused/`,
    /// and `reportError` names both. Text that is not a JSON object (a
    /// half-written file) is left alone; the completed write re-triggers.
    static func applyExternalEdit(
        data: Data,
        path: String,
        known: (UUID) -> SyncProfile?,
        others: [SyncProfile],
        isInstalled: (SyncProfile) -> Bool,
        persist: (SyncProfile) -> Void,
        install: (SyncProfile) throws -> Void,
        uninstall: (SyncProfile) throws -> Void,
        reportError: (UUID, String) -> Void,
        now: Date = Date()
    ) -> ExternalEditOutcome {
        let decoded = try? JSONDecoder().decode(SyncProfile.self, from: data)
        let rawId = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["id"] as? String
        guard let id = decoded?.id ?? rawId.flatMap(UUID.init(uuidString:)), let current = known(id) else {
            return decoded.map { .create($0) } ?? .ignored
        }
        var messages: [String] = []
        if let decoded, applyProfileChange(
            from: current, to: decoded, others: others, isInstalled: isInstalled,
            persist: persist, install: install, uninstall: uninstall, reportError: { messages.append($0) }) {
            messages.forEach { reportError(id, $0) }  // e.g. an install error after persisting
            return .applied
        }

        let fm = FileManager.default
        let directory = (path as NSString).deletingLastPathComponent
        let copy = refusedDestination(for: path, now: now)
        let copied = (try? fm.createDirectory(
            atPath: (copy as NSString).deletingLastPathComponent, withIntermediateDirectories: true)) != nil
            && fm.createFile(atPath: copy, contents: data)
        let restoredName = ProfileStore.writeProfileFile(current, in: directory)
        if let restoredName, (path as NSString).lastPathComponent != restoredName {
            try? fm.removeItem(atPath: path)
        }
        let reason = messages.first ?? "Not saved: the edited file no longer decodes as a valid profile"
        reportError(id, "\(reason). "
            + (restoredName != nil ? "Restored \(current.shortId).profile.json to the last accepted profile"
                                   : "Could NOT restore \(current.shortId).profile.json")
            + (copied ? "; the refused content is in \(copy)" : "; the refused content could not be copied aside"))
        return .restored(refusedCopy: copied ? copy : nil)
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
