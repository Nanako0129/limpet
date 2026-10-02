import Foundation
import AppKit
import Combine
import ServiceManagement

@MainActor
final class SyncManager: ObservableObject {
    @Published private(set) var currentState: SyncState = .idle
    @Published private(set) var lastSyncTime: Date?
    @Published private(set) var recentChanges: [FileChange] = []

    /// True while any profile is actively syncing. The launchd-owned `limpet
    /// watch` process is the SOLE thing that ever runs a sync (see
    /// limpet-plan.md L3) — this app only ever observes that fact through the
    /// profile log via `LogWatcher`/`processLogEvent`, exactly like a
    /// scheduled or FSEvents-triggered run, so there is no separate
    /// "app-initiated" tracking set to maintain.
    var isManualSyncRunning: Bool { profileStates.values.contains(.syncing) }

    /// Sync progress per profile (keyed by profile ID)
    @Published private(set) var profileProgress: [UUID: SyncProgress] = [:]

    /// Aggregate sync progress (first syncing profile's progress) - for menu bar icon
    var syncProgress: SyncProgress? {
        // Find the first profile that is currently syncing and has progress
        for (profileId, state) in profileStates {
            if state == .syncing, let progress = profileProgress[profileId] {
                return progress
            }
        }
        return nil
    }

    /// State per profile (keyed by profile ID)
    @Published private(set) var profileStates: [UUID: SyncState] = [:]

    /// Last error message per profile (for display in UI)
    @Published private(set) var profileErrors: [UUID: String] = [:]

    /// Paused profiles (session-only, not persisted - resets on app restart)
    @Published private(set) var pausedProfiles: Set<UUID> = []

    let profileStore: ProfileStore

    private var logWatchers: [UUID: LogWatcher] = [:]
    /// Watches ~/.config/limpet for external edits to *.profile.json and
    /// settings.json and routes them through the reconcile path below.
    private var configFileWatcher: ConfigFileWatcher?
    private let logParser = LogParser()
    private let notificationService = NotificationService.shared
    private let setupService = SyncSetupService.shared

    private var workspaceObserver: NSObjectProtocol?
    /// Per-run count of reported file changes (its only reader is the count at
    /// completion — L6.3 change 2 replaced the unbounded array that held them).
    private var currentSyncChanges: [UUID: Int] = [:]
    private var cancellables = Set<AnyCancellable>()

    /// Track the last error message per profile (for correlating with syncFailed events)
    private var lastSeenErrorMessage: [UUID: String] = [:]

    /// Profiles where we're monitoring an externally-started sync
    private var monitoringExternalSyncs: Set<UUID> = []

    /// Cache for `shouldReportFileChange`'s `hasTrashRoot` (code-review
    /// finding 6 on 87bbf67): populated only by `startWatching`, which runs
    /// at launch and whenever a profile's watching (re)starts — i.e. after
    /// any reinstall-worthy field change (`rcloneRemote`, `remotePath`,
    /// `syncDirection`, `remoteVersioning`, `trashDays` among them, per
    /// `ConfigReconciler.reconcileAction`). Never recomputed per file-change
    /// event; removed by `stopWatching` so a deleted profile leaves nothing
    /// behind.
    private var trashRootCache: [UUID: Bool] = [:]

    /// Timers polling for sync completion
    private var syncCompletionPollers: [UUID: DispatchSourceTimer] = [:]

    private let maxRecentChanges = 20

    init(profileStore: ProfileStore? = nil) {
        self.profileStore = profileStore ?? ProfileStore()
        setupWorkspaceObserver()
        setupProfileObserver()
        setupService.refreshSharedScriptIfChanged()  // Propagate script template updates
        checkInitialState()
        startWatchingAllProfiles()
        refreshSettingsFile()
        startConfigWatcher()
    }

    deinit {
        configFileWatcher?.stop()
        configFileWatcher = nil

        // Cancel all sync completion pollers
        for timer in syncCompletionPollers.values {
            timer.cancel()
        }
        syncCompletionPollers.removeAll()

        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - Public Methods

    func refreshSettings() {
        startWatchingAllProfiles()
        checkInitialState()
    }

    /// Trigger a sync now for `profile` (or every enabled, non-paused profile)
    /// by signalling ITS launchd-owned `limpet watch` process — the SOLE
    /// thing that ever runs a sync (limpet-plan.md L3). The app never runs
    /// rclone or the sync script itself, and never touches the lock file;
    /// `launchctl kill`'s exit status is itself the liveness check.
    func triggerManualSync(for profile: SyncProfile? = nil) {
        let profilesToSync: [SyncProfile]
        if let profile = profile {
            guard !isPaused(for: profile.id) else {
                LimpetSettings.debugLog("Skipping manual sync for paused profile: \(profile.name)")
                return
            }
            profilesToSync = [profile]
        } else {
            profilesToSync = profileStore.enabledProfiles.filter { !isPaused(for: $0.id) }
        }

        guard !profilesToSync.isEmpty else {
            if profileStore.enabledProfiles.isEmpty {
                currentState = .notConfigured
            }
            return
        }

        for profile in profilesToSync {
            sendSyncNowSignal(to: profile)
        }
    }

    /// Whether an enabled profile needs a keychain secret while the login
    /// keychain is locked — its watcher then waits instead of reading (and
    /// raising a dialog). Drives the menu's "Allow keychain access" button.
    var isKeychainAccessNeeded: Bool {
        let service = RcloneConfigService.shared
        return !keychainBackedEnabledProfiles.isEmpty
            && service.keychain.lockStatus(service.keychain.keychainPath) != .unlocked
    }

    private var keychainBackedEnabledProfiles: [SyncProfile] {
        profileStore.enabledProfiles.filter {
            RcloneConfigService.shared.section(named: String($0.rcloneRemote.prefix { $0 != ":" }))?[
                RcloneConfigService.keychainMarker] == "true"
        }
    }

    /// The user clicked "Allow keychain access": the only path that may raise
    /// a keychain dialog (the system unlock prompt). Afterwards the waiting
    /// watchers are asked to sync now.
    func allowKeychainAccess() {
        let path = RcloneConfigService.shared.keychain.keychainPath
        let profiles = keychainBackedEnabledProfiles
        DispatchQueue.global(qos: .userInitiated).async {
            let unlocked = KeychainSecretStore.requestUnlock(keychainPath: path)
            DispatchQueue.main.async {
                if unlocked {
                    for profile in profiles { self.sendSyncNowSignal(to: profile) }
                }
                self.objectWillChange.send()
            }
        }
    }

    /// Whether `profile` is stopped by the persistent delete-limit marker
    /// (limpet-plan.md L4 F6).
    func isDeleteLimitReached(for profile: SyncProfile) -> Bool {
        FileManager.default.fileExists(atPath: profile.deleteLimitMarkerPath)
    }

    /// The menu action twin of `limpet profile clear-delete-limit`: remove the
    /// marker, then send the watcher the same "sync now" request.
    func clearDeleteLimit(for profile: SyncProfile) {
        do {
            try FileManager.default.removeItem(atPath: profile.deleteLimitMarkerPath)
        } catch {
            profileErrors[profile.id] = "could not clear the delete limit: \(error.localizedDescription)"
            return
        }
        clearError(for: profile.id)
        sendSyncNowSignal(to: profile)
        objectWillChange.send()
    }

    /// `launchctl kill SIGUSR1 gui/<uid>/<label>` — addressed by label, not
    /// PID, so this never races a launchd respawn. A non-zero exit means no
    /// watcher is currently loaded for that profile; reported to the user as
    /// such rather than silently doing nothing.
    private func sendSyncNowSignal(to profile: SyncProfile) {
        let exitCode = runLaunchctl(["kill", "SIGUSR1", "gui/\(getuid())/\(profile.launchdLabel)"])
        if exitCode != 0 {
            profileErrors[profile.id] = "no watcher running"
            LimpetSettings.debugLog(
                "Sync now for '\(profile.name)': no watcher running (launchctl kill exit \(exitCode))")
        }
    }

    /// Run `/bin/launchctl` with `args`, discarding output — every caller here
    /// only needs the exit code. Mirrors `SyncSetupService.runCommand`.
    private func runLaunchctl(_ args: [String]) -> Int32 {
        if SelfTestGuard.refuses("/bin/launchctl", args) { return 1 }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    func openLogFile(for profile: SyncProfile? = nil) {
        let logPath: String
        if let profile = profile {
            logPath = profile.logPath
        } else if let firstEnabled = profileStore.enabledProfiles.first {
            logPath = firstEnabled.logPath
        } else {
            return
        }

        if FileManager.default.fileExists(atPath: logPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
        }
    }

    func openSyncDirectory(for profile: SyncProfile? = nil) {
        let syncPath: String
        if let profile = profile {
            syncPath = profile.localSyncPath
        } else if let firstEnabled = profileStore.enabledProfiles.first {
            syncPath = firstEnabled.localSyncPath
        } else {
            return
        }

        if !syncPath.isEmpty && FileManager.default.fileExists(atPath: syncPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: syncPath))
        }
    }

    func openFileInFinder(_ change: FileChange) {
        // Try to find the file in any of the enabled profiles
        for profile in profileStore.enabledProfiles {
            let fullPath = (profile.localSyncPath as NSString).appendingPathComponent(change.path)
            let url = URL(fileURLWithPath: fullPath)

            if FileManager.default.fileExists(atPath: fullPath) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return
            }
        }

        // File might have been deleted, try the first profile's path
        if let profile = profileStore.enabledProfiles.first {
            let fullPath = (profile.localSyncPath as NSString).appendingPathComponent(change.path)
            let parentDir = (fullPath as NSString).deletingLastPathComponent
            if FileManager.default.fileExists(atPath: parentDir) {
                NSWorkspace.shared.open(URL(fileURLWithPath: parentDir))
            }
        }
    }

    func enableLoginItem() {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.register()
                objectWillChange.send()  // Notify SwiftUI to update UI
                refreshSettingsFile()
            } catch {
                print("Failed to register login item: \(error)")
            }
        }
    }

    func disableLoginItem() {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.unregister()
                objectWillChange.send()  // Notify SwiftUI to update UI
                refreshSettingsFile()
            } catch {
                print("Failed to unregister login item: \(error)")
            }
        }
    }

    var isLoginItemEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    // MARK: - Profile Management

    /// Enable/disable scheduled sync for a profile. Refused changes and
    /// install/uninstall failures are shown through `profileErrors`, and a
    /// refused enable persists nothing (review finding 6).
    func setProfileEnabled(_ profile: SyncProfile, enabled: Bool) {
        var updatedProfile = profile
        updatedProfile.isEnabled = enabled
        applyProfileChange(from: profile, to: updatedProfile)
        updateAggregateState()
    }

    /// Production wiring of `applyProfileChange` (ConfigReconciler.swift).
    private func applyProfileChange(from current: SyncProfile, to updated: SyncProfile) {
        clearError(for: updated.id)
        Self.applyProfileChange(
            from: current,
            to: updated,
            others: profileStore.profiles,
            isInstalled: SyncProfile.agentInstalled,
            persist: { profileStore.update($0) },
            install: { [self] in try installAndWatch($0) },
            uninstall: { [self] in try uninstallAndStopWatching($0) },
            reportError: { [self] message in
                profileErrors[updated.id] = message
                LimpetSettings.debugLog("[\(updated.shortId)] \(message)")
            }
        )
    }

    private func installAndWatch(_ profile: SyncProfile) throws {
        try setupService.install(profile: profile)
        startWatching(profile: profile)
    }

    private func uninstallAndStopWatching(_ profile: SyncProfile) throws {
        try setupService.uninstall(profile: profile)
        stopWatching(profileId: profile.id)
    }

    // MARK: - External Config Reconcile

    /// Start watching `~/.config/limpet` for external edits. No-op if the
    /// directory doesn't exist yet (the app ensures it exists at launch via
    /// `ConfigSchemaInstaller.writeSchemas()`, called before `SyncManager` is created).
    private func startConfigWatcher() {
        let watcher = ConfigFileWatcher(
            onProfileChange: { [weak self] path, suppressReconcile in
                Task { @MainActor in
                    self?.applyExternalProfileEdit(fromFileAt: path, suppressReconcile: suppressReconcile)
                }
            },
            onSettingsChange: { [weak self] in
                Task { @MainActor in self?.applyExternalSettingsEdit() }
            }
        )
        watcher.start()
        configFileWatcher = watcher
    }

    /// Rewrite `settings.json` from the current `LimpetSettings` state.
    /// Call after any UI-driven change to a safe key so the file stays in
    /// sync with the app (the write notes its own hash, so the watcher
    /// ignores the FSEvent it produces).
    func refreshSettingsFile() {
        AppSettingsFileStore.writeSettingsFile(isLoginItemEnabled: isLoginItemEnabled)
    }

    /// Apply an external edit to a `*.profile.json` file, routing through the
    /// SAME install/uninstall/reinstall reconcile the Save button uses —
    /// never a bare in-memory struct swap, so the running launchd agent is
    /// never left stale.
    ///
    /// A decode failure (half-written file) is a silent no-op — a half-written
    /// file will complete and re-trigger. A file carrying an UNKNOWN, decodable
    /// id is not ignored: it CREATES the profile (see `applyExternalProfileCreate`
    /// / `SyncManager.applyExternalCreateIfNeeded`), so an agent can bootstrap a
    /// new sync purely by dropping a file.
    ///
    /// - Parameter suppressReconcile: true when `ConfigFileWatcher` matched this
    ///   write to a `CLIWriteMarker` (limpet-plan.md L6.1 change A) — the `limpet`
    ///   CLI process already installed/uninstalled/reinstalled for this exact
    ///   write, so `install`/`uninstall` below are replaced with no-ops; `persist`
    ///   still runs, refreshing `profileStore.profiles` (and, through its
    ///   `$profiles` sink, `logWatchers`) so the running app's in-memory state
    ///   never drifts from the file the CLI just wrote. Without this, the CLI's
    ///   `launchctl load`/`unload` and this app's own reconcile would race and
    ///   double-reload the same agent for one edit.
    func applyExternalProfileEdit(fromFileAt path: String, suppressReconcile: Bool = false) {
        guard let data = FileManager.default.contents(atPath: path) else { return }
        let (install, uninstall) = Self.reconcileClosures(
            suppressReconcile: suppressReconcile,
            setupInstall: { [self] in try setupService.install(profile: $0) },
            setupUninstall: { [self] in try setupService.uninstall(profile: $0) },
            watchStart: { [self] in startWatching(profile: $0) },
            watchStop: { [self] in stopWatching(profileId: $0.id) }
        )
        let outcome = Self.applyExternalEdit(
            data: data,
            path: path,
            known: { [self] in profileStore.profile(for: $0) },
            others: profileStore.profiles,
            isInstalled: SyncProfile.agentInstalled,
            persist: { [self] profile in
                clearError(for: profile.id)
                profileStore.update(profile)
            },
            install: install,
            uninstall: uninstall,
            reportError: { [self] id, message in
                profileErrors[id] = message
                print(message)
                LimpetSettings.debugLog("[ConfigFileWatcher] \(message)")
            })
        switch outcome {
        case .create(let profile):
            applyExternalProfileCreate(decoded: profile, sourcePath: path, suppressReconcile: suppressReconcile)
        case .ignored:
            LimpetSettings.debugLog("[ConfigFileWatcher] \(path) is not a complete profile yet; skipping")
        case .applied, .restored:
            break
        }
        updateAggregateState()
    }

    /// Wires `applyExternalCreateIfNeeded`'s persist/install closures to the
    /// production primitives — the SAME `profileStore.add`/`setupService.install`
    /// the in-app "create profile" flow and the `.install` reconcile branch
    /// use, so a file-bootstrapped profile can never drift from an
    /// in-app-created one.
    ///
    /// `persist` also canonicalizes the file: if the dropped file's basename
    /// isn't `{shortId}.profile.json`, the differently-named source is removed
    /// AFTER `profileStore.add` writes the canonical file (which notes its own
    /// content hash in `ConfigSelfWriteRegistry`) — the resulting missing-source
    /// FSEvent is a no-op (`ConfigFileWatcher.classifyWrite` returns `.skip` for
    /// a missing file), so this can never loop.
    private func applyExternalProfileCreate(decoded: SyncProfile, sourcePath: String, suppressReconcile: Bool = false) {
        let outcome = Self.applyExternalCreateIfNeeded(
            decoded: decoded,
            isKnownId: false,
            existing: profileStore.profiles,
            isInstalled: SyncProfile.agentInstalled,
            persist: { [weak self] profile in
                self?.profileStore.add(profile)
                self?.clearError(for: profile.id)

                let canonicalFilename = "\(profile.shortId).profile.json"
                let sourceFilename = (sourcePath as NSString).lastPathComponent
                if sourceFilename != canonicalFilename {
                    try? FileManager.default.removeItem(atPath: sourcePath)
                }
            },
            // suppressReconcile (limpet-plan.md L6.1 change A): a `limpet
            // profile create` from the CLI already installed the agent itself,
            // through the SAME `SyncSetupService.install` — the shared
            // `reconcileClosures` dispatch (finding 5) skips `setupInstall` on a
            // marked write but always runs `watchStart`. `persist` above already
            // starts a `LogWatcher` for the new profile via `profileStore.add`'s
            // `$profiles` sink, so this `watchStart` is a harmless re-assignment,
            // not a second install/launchctl call.
            install: { [weak self] profile in
                guard let self else { return }
                do {
                    try Self.reconcileClosures(
                        suppressReconcile: suppressReconcile,
                        setupInstall: { try self.setupService.install(profile: $0) },
                        setupUninstall: { _ in },  // unreachable: create never uninstalls
                        watchStart: { self.startWatching(profile: $0) },
                        watchStop: { _ in }  // unreachable: create never stops watching
                    ).install(profile)
                } catch {
                    print("Failed to install newly-created external profile: \(error)")
                }
            },
            quarantine: { reason in
                let moved = Self.quarantineRefusedDrop(at: sourcePath)
                let message = "Refused dropped profile \(decoded.shortId): \(reason); "
                    + (moved.map { "moved it to \($0)" } ?? "could not move \(sourcePath) aside")
                print(message)
                LimpetSettings.debugLog(message)
            }
        )

        guard outcome != .ignored, outcome != .refusedOverlap else { return }

        updateAggregateState()
    }

    /// Apply an external edit to `settings.json`. Safe keys apply directly;
    /// `launchAtLogin` goes through `SettingsReconciler`'s ISOLATED path so an
    /// `SMAppService` failure can never corrupt anything else.
    func applyExternalSettingsEdit() {
        let safeSettings = AppSettingsFileStore.readSafeSettings()

        SettingsReconciler.apply(
            safeSettings: safeSettings,
            applySafeKey: { key, value in
                switch key {
                case .debugLoggingEnabled:
                    LimpetSettings.debugLoggingEnabled = value
                case .launchAtLogin:
                    break  // handled by the isolated path below
                }
            },
            currentLoginItemEnabled: { [weak self] in self?.isLoginItemEnabled ?? false },
            applyLoginItem: { [weak self] enabled in
                guard let self else { return }
                if #available(macOS 13.0, *) {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                }
                self.objectWillChange.send()
            }
        )
    }

    /// Get state for a specific profile
    func state(for profileId: UUID) -> SyncState {
        profileStates[profileId] ?? .idle
    }

    /// Get last error message for a specific profile
    /// Only returns errors detected during this session (not persisted across app restarts)
    func lastError(for profileId: UUID) -> String? {
        return profileErrors[profileId]
    }

    /// Clear the cached error for a profile (call when config changes or fix is attempted)
    func clearError(for profileId: UUID) {
        profileErrors[profileId] = nil
        if case .error = profileStates[profileId] {
            profileStates[profileId] = .idle
        }
        updateAggregateState()
    }

    /// Set the syncing state for a profile (used by views running direct resyncs)
    func setSyncing(for profileId: UUID, isSyncing: Bool) {
        if isSyncing {
            profileStates[profileId] = .syncing
            profileErrors[profileId] = nil
        } else {
            profileStates[profileId] = .idle
        }
        updateAggregateState()
    }

    /// Returns true if we're monitoring an externally-started sync for this profile
    func isMonitoringExternalSync(for profileId: UUID) -> Bool {
        monitoringExternalSyncs.contains(profileId)
    }


    /// Mute file change notifications for a profile (persisted)
    func muteNotifications(for profileId: UUID) {
        guard var profile = profileStore.profile(for: profileId) else { return }
        profile.isMuted = true
        profileStore.update(profile)
    }

    /// Unmute notifications for a profile (persisted)
    func unmuteNotifications(for profileId: UUID) {
        guard var profile = profileStore.profile(for: profileId) else { return }
        profile.isMuted = false
        profileStore.update(profile)
    }

    /// Check if notifications are muted for a profile
    func isNotificationsMuted(for profileId: UUID) -> Bool {
        profileStore.profile(for: profileId)?.isMuted ?? false
    }

    // MARK: - Pause/Resume

    /// Check if a profile is paused
    func isPaused(for profileId: UUID) -> Bool {
        pausedProfiles.contains(profileId)
    }

    /// Check if all enabled profiles are paused
    var isAllPaused: Bool {
        let enabledIds = Set(profileStore.enabledProfiles.map { $0.id })
        guard !enabledIds.isEmpty else { return false }
        return enabledIds.isSubset(of: pausedProfiles)
    }

    /// Pause syncing for a specific profile (blocks manual syncs, stops the
    /// launchd-owned watcher so no further scheduled/FSEvents/manual run can
    /// start). The GUI never signals or touches the watcher's lock file
    /// directly here — `launchctl unload` stops the whole KeepAlive process,
    /// which owns that lock for the run it may have had in flight.
    func pauseProfile(_ profileId: UUID) {
        guard let profile = profileStore.profile(for: profileId) else { return }

        pausedProfiles.insert(profileId)

        // Actually stop scheduled syncs. Previously pause only set an in-memory
        // flag, so launchd kept firing the sync script every interval — the
        // "paused" profile still hammered the remote and the spinner never
        // rested. Unload the agent so no new runs start.
        setupService.unloadAgent(for: profile)

        // Stop any external-sync completion poller watching this profile.
        syncCompletionPollers[profile.id]?.cancel()
        syncCompletionPollers.removeValue(forKey: profile.id)
        monitoringExternalSyncs.remove(profile.id)

        // Update profile state to paused
        profileStates[profileId] = .paused
        profileProgress[profileId] = nil
        logWatchers[profileId]?.setActivelySyncing(false)

        updateAggregateState()

        LimpetSettings.debugLog("Paused profile: \(profile.name)")
    }

    /// Resume syncing for a specific profile (reloads its launchd watcher).
    func resumeProfile(_ profileId: UUID) {
        guard let profile = profileStore.profile(for: profileId),
              profile.isEnabled else { return }

        pausedProfiles.remove(profileId)

        // Reload the launchd agent that pause unloaded — RunAtLoad means this
        // starts a fresh watcher, which runs its own catch-up sync.
        setupService.loadAgent(for: profile)

        // Reset state to idle (or check drive mount status)
        if !profile.drivePathToMonitor.isEmpty &&
           !FileManager.default.fileExists(atPath: profile.drivePathToMonitor) {
            profileStates[profileId] = .driveNotMounted
        } else {
            profileStates[profileId] = .idle
        }

        updateAggregateState()

        LimpetSettings.debugLog("Resumed profile: \(profile.name)")
    }

    /// Pause all enabled profiles
    func pauseAllProfiles() {
        for profile in profileStore.enabledProfiles {
            pauseProfile(profile.id)
        }
    }

    /// Resume all paused profiles
    func resumeAllProfiles() {
        // Create a copy since we're modifying the set while iterating
        let profilesToPause = pausedProfiles
        for profileId in profilesToPause {
            resumeProfile(profileId)
        }
    }

    /// Toggle pause state for a specific profile
    func togglePause(for profileId: UUID) {
        if isPaused(for: profileId) {
            resumeProfile(profileId)
        } else {
            pauseProfile(profileId)
        }
    }

    /// Toggle pause state for all profiles
    func togglePauseAll() {
        if isAllPaused {
            resumeAllProfiles()
        } else {
            pauseAllProfiles()
        }
    }

    /// Read the last error message from a log file
    /// Static so the self-test can drive it (it uses no instance state).
    nonisolated static func readLastErrorFromLog(_ logPath: String) -> String? {
        guard FileManager.default.fileExists(atPath: logPath),
              let data = FileManager.default.contents(atPath: logPath),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        // Look for error lines in reverse order (most recent first)
        let lines = content.components(separatedBy: .newlines).reversed()
        var errorMessages: [String] = []
        var criticalErrors: [String] = []  // Track critical/actionable errors separately
        var foundFailedMarker = false

        for line in lines {
            // Stop when we hit a sync start marker (previous run)
            if SyncLogPatterns.isSyncStarted(line) && foundFailedMarker {
                break
            }

            // If the most recent sync was successful, there's no error to show
            if SyncLogPatterns.isSyncCompleted(line) {
                return nil
            }

            // The watchdog writes this BEFORE it SIGTERMs the group and appends the
            // `Sync failed with exit code 79` line only after the group is gone, and
            // the lock can vanish in between: this line alone is the failure of the
            // current run (seen before any completion line in this reverse scan).
            if SyncLogPatterns.isSyncStalled(line) {
                return "Sync stalled"
            }

            // Mark that we found the failure point
            if SyncLogPatterns.isSyncFailed(line) {
                foundFailedMarker = true
                continue
            }

            // Only collect errors after we found the failure marker
            guard foundFailedMarker else { continue }

            // Extract error message from line (supports CRITICAL and JSON formats)
            guard let rawMsg = SyncLogPatterns.extractErrorMessage(from: line) else { continue }

            // Clean up ANSI codes
            var msg = SyncLogPatterns.stripANSICodes(rawMsg)

            // Transient "all files were changed" error should not be shown
            if SyncLogPatterns.isTransientAllFilesChangedError(msg) {
                continue
            }

            // Clean up error message prefixes
            msg = SyncLogPatterns.cleanErrorMessage(msg)

            guard !msg.isEmpty else { continue }

            // Track critical/actionable errors separately (they're more useful to show)
            if SyncLogPatterns.isCriticalError(msg) && !criticalErrors.contains(msg) {
                criticalErrors.append(msg)
            } else if !errorMessages.contains(msg) {
                errorMessages.append(msg)
            }

            // Stop after finding enough errors
            if criticalErrors.count >= 1 || errorMessages.count >= 2 {
                break
            }
        }

        // Prefer critical errors over general errors
        let bestError = criticalErrors.first ?? errorMessages.first

        if let error = bestError {
            // Truncate if too long
            if error.count > 300 {
                return String(error.prefix(300)) + "..."
            }
            return error
        }

        return nil
    }

    // MARK: - Private Methods

    /// Check if a sync is currently running for this profile via lock file
    /// Returns the PID if found, nil otherwise
    private func detectRunningSyncPID(for profile: SyncProfile) -> Int32? {
        let lockPath = profile.lockFilePath
        guard FileManager.default.fileExists(atPath: lockPath),
              let pidStr = try? String(contentsOfFile: lockPath, encoding: .utf8)
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(pidStr),
              kill(pid, 0) == 0 else {
            return nil
        }
        return pid
    }

    /// Poll until the sync process exits. code-review finding 1: cancels any
    /// existing poller for this profile FIRST — `startWatching` (the lock check
    /// at (re)start) and `.syncAlreadyRunning` (a lock-held log line, finding 3)
    /// can both want to start one for the same profile; without this, the
    /// second call replaces `syncCompletionPollers[id]` and leaks the first
    /// timer, which keeps firing (and can later race the real completion) —
    /// this is the single choke point that makes every caller safe to call
    /// unconditionally, rather than relying on each caller's own
    /// `monitoringExternalSyncs` check to be perfectly race-free.
    private func startPollingForSyncCompletion(profile: SyncProfile, pid: Int32) {
        syncCompletionPollers[profile.id]?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 3, repeating: 3.0)

        let profileId = profile.id
        let lockPath = profile.lockFilePath

        timer.setEventHandler { [weak self] in
            // Check if process exited or lock file removed
            if kill(pid, 0) != 0 || !FileManager.default.fileExists(atPath: lockPath) {
                timer.cancel()
                DispatchQueue.main.async {
                    self?.handleExternalSyncCompleted(profileId: profileId)
                }
            }
        }

        syncCompletionPollers[profile.id] = timer
        timer.resume()
    }

    /// Handle when an externally-monitored sync completes
    private func handleExternalSyncCompleted(profileId: UUID) {
        syncCompletionPollers[profileId]?.cancel()
        syncCompletionPollers.removeValue(forKey: profileId)
        monitoringExternalSyncs.remove(profileId)

        // Determine success/failure from log
        if let profile = profileStore.profile(for: profileId),
           let error = Self.readLastErrorFromLog(profile.logPath) {
            profileStates[profileId] = .error("Sync failed")
            profileErrors[profileId] = error
        } else {
            profileStates[profileId] = .idle
            lastSyncTime = Date()
        }

        updateAggregateState()
    }

    private func setupProfileObserver() {
        profileStore.$profiles
            .sink { [weak self] _ in
                self?.startWatchingAllProfiles()
                self?.updateAggregateState()
            }
            .store(in: &cancellables)
    }

    private func startWatchingAllProfiles() {
        let enabledProfileIds = Set(profileStore.enabledProfiles.map { $0.id })

        // Remove watchers for profiles that are no longer enabled
        // (Don't touch watchers for profiles that are still enabled - avoids interrupting active syncs)
        for id in logWatchers.keys where !enabledProfileIds.contains(id) {
            logWatchers[id]?.stopWatching()
            logWatchers.removeValue(forKey: id)
        }

        // Add watchers only for profiles that don't already have them
        for profile in profileStore.enabledProfiles {
            if logWatchers[profile.id] == nil {
                startWatching(profile: profile)
            }
        }
    }

    /// (limpet-plan.md L6.1 change C, root cause 3.) Runs a lock-file check
    /// EVERY time a profile's watching (re)starts — at launch (via
    /// `setupProfileObserver`'s `$profiles` sink, which fires synchronously with
    /// the already-loaded profiles as soon as it subscribes in `init`) and again
    /// whenever `startWatchingAllProfiles` rebuilds a `LogWatcher` after a
    /// `.reinstall` reconcile tore one down — so a sync already in flight is
    /// never mistaken for idle until it happens to log a line. This one check
    /// used to be duplicated by a separate `detectAndResumeRunningSyncs` called
    /// once at the end of `init`; that duplicate leaked a `syncCompletionPollers`
    /// timer every launch (code-review finding 1) and was deleted, since this
    /// function already covers it — `startPollingForSyncCompletion` itself now
    /// also cancels any prior timer for the profile, so no caller here needs to
    /// be perfectly race-free on its own.
    private func startWatching(profile: SyncProfile) {
        let watcher = LogWatcher(logPath: profile.logPath)
        watcher.delegate = self
        watcher.startWatching()
        logWatchers[profile.id] = watcher
        trashRootCache[profile.id] = Self.resolveHasTrashRoot(for: profile)

        if let pid = detectRunningSyncPID(for: profile) {
            profileStates[profile.id] = .syncing
            watcher.setActivelySyncing(true)
            if !monitoringExternalSyncs.contains(profile.id) {
                monitoringExternalSyncs.insert(profile.id)
                startPollingForSyncCompletion(profile: profile, pid: pid)
            }
        } else if profileStates[profile.id] == .syncing {
            // A caller elsewhere (e.g. a manual "sync now") already marked this
            // profile syncing before this (re)start — keep polling fast rather
            // than resetting to idle underneath it.
            watcher.setActivelySyncing(true)
        } else {
            profileStates[profile.id] = .idle
        }
    }

    private func stopWatching(profileId: UUID) {
        logWatchers[profileId]?.stopWatching()
        logWatchers.removeValue(forKey: profileId)
        trashRootCache.removeValue(forKey: profileId)
        // Same cleanup as pauseProfile: a poller left behind here would keep
        // the id in monitoringExternalSyncs and block the poller for the sync
        // the next startWatching finds (CodeRabbit, PR #9).
        syncCompletionPollers[profileId]?.cancel()
        syncCompletionPollers.removeValue(forKey: profileId)
        monitoringExternalSyncs.remove(profileId)

        profileStates.removeValue(forKey: profileId)
    }

    private func checkInitialState() {
        if profileStore.profiles.isEmpty {
            currentState = .notConfigured
            return
        }

        // Check each enabled profile
        for profile in profileStore.enabledProfiles {
            // Don't override state for profiles that are currently syncing
            if profileStates[profile.id] == .syncing {
                continue
            }

            if !profile.drivePathToMonitor.isEmpty &&
               !FileManager.default.fileExists(atPath: profile.drivePathToMonitor) {
                profileStates[profile.id] = .driveNotMounted
            } else {
                profileStates[profile.id] = .idle
            }
        }

        updateAggregateState()
    }

    /// Update the aggregate state (worst state wins)
    private func updateAggregateState() {
        if profileStore.profiles.isEmpty {
            currentState = .notConfigured
            return
        }

        if profileStore.enabledProfiles.isEmpty {
            currentState = .idle
            return
        }

        // Priority: error > syncing > driveNotMounted > paused > idle
        var hasError = false
        var hasSyncing = false
        var hasDriveNotMounted = false
        var hasPaused = false
        var errorMessage: String?

        for state in profileStates.values {
            switch state {
            case .error(let msg):
                hasError = true
                errorMessage = msg
            case .syncing:
                hasSyncing = true
            case .driveNotMounted:
                hasDriveNotMounted = true
            case .paused:
                hasPaused = true
            default:
                break
            }
        }

        if hasError {
            currentState = .error(errorMessage ?? "Unknown error")
        } else if hasSyncing {
            currentState = .syncing
        } else if hasDriveNotMounted {
            currentState = .driveNotMounted
        } else if hasPaused && isAllPaused {
            // Only show paused aggregate state if ALL profiles are paused
            currentState = .paused
        } else {
            currentState = .idle
        }
    }

    private func setupWorkspaceObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleVolumeMount(notification)
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleVolumeUnmount(notification)
            }
        }
    }

    private func handleVolumeMount(_ notification: Notification) {
        guard let volumePath = (notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path else {
            return
        }

        for profile in profileStore.enabledProfiles {
            let drivePath = profile.drivePathToMonitor
            guard !drivePath.isEmpty else { continue }

            if drivePath.hasPrefix(volumePath) || volumePath == drivePath {
                notificationService.resetDriveNotMountedState(for: profile.id)
                if profileStates[profile.id] == .driveNotMounted {
                    profileStates[profile.id] = .idle
                }
            }
        }

        updateAggregateState()
    }

    private func handleVolumeUnmount(_ notification: Notification) {
        guard let volumePath = (notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path else {
            return
        }

        for profile in profileStore.enabledProfiles {
            let drivePath = profile.drivePathToMonitor
            guard !drivePath.isEmpty else { continue }

            if drivePath.hasPrefix(volumePath) || volumePath == drivePath {
                profileStates[profile.id] = .driveNotMounted
                if !isNotificationsMuted(for: profile.id) {
                    notificationService.notifyDriveNotMounted(profileId: profile.id, profileName: profile.name)
                }
            }
        }

        updateAggregateState()
    }

    /// Pure text for a `syncFailed` exit code (limpet-plan.md L5.1 finding 2):
    /// 76 is the script's dedicated delete-limit-trip code
    /// (`SyncSetupService.maxDeleteArgument` / AC-L4-11); every other code
    /// keeps the prior generic text. (No 64 case: a refusal exits before the
    /// script writes "Sync failed with exit code", so it never reaches here.)
    static func exitCodeErrorText(_ exitCode: Int) -> String {
        switch exitCode {
        case 76:
            return "Delete limit reached"
        case 79:
            // L6.3 watchdog: `SyncWatchDaemon` stopped a run with no log output
            // for 30 min and wrote `Sync failed with exit code 79`. (78 is
            // `secretUnavailableExitCode`, which never reaches the log, so it
            // stays unmapped.)
            return "Sync stalled"
        default:
            return "Exit code \(exitCode)"
        }
    }

    /// Pure state transition for the three events the source-missing clear
    /// path depends on (AC-L5-2 drives this directly, since standing up a
    /// full SyncManager needs a real profile store, workspace observers and
    /// config watchers). Not a general reducer — `processLogEvent` above
    /// still owns every other side effect (progress, errors, notifications)
    /// for these same cases; this only extracts the `profileStates` write so
    /// it can be exercised headlessly.
    static func reduceProfileState(_ current: SyncState, for eventType: ParsedLogEvent.EventType) -> SyncState {
        switch eventType {
        case .syncStarted, .syncAlreadyRunning:
            return .syncing
        case .syncCompleted:
            return .idle
        case .sourceMissing(let path):
            return .error("Source missing: \(path)")
        default:
            return current
        }
    }

    /// Whether a parsed file-change belongs in Recent Changes/notifications
    /// (limpet-plan.md L6.2 item 4b; code-review finding 1/8 on 87bbf67 fixed
    /// the two bugs below). `false` only when `hasTrashRoot` AND the change is
    /// flagged `mayBeTrashArtifact` — set by `SyncLogPatterns.mayBeTrashArtifact`
    /// for exactly the two log lines that are ambiguous between a genuine
    /// change and the trash mechanism's own backup-move step (a bare
    /// `Deleted`, and `Moved (server-side) to: ...`), never for the trash
    /// mechanism's OWN unambiguous delete report (`Moved into backup dir`) or
    /// for a genuine `Renamed from "..."` line. Finding 1 (P1): the previous
    /// version keyed this off `operation == .deleted` alone, which ALSO
    /// matched `Moved into backup dir` (mapped to the same `.deleted` case),
    /// so a trash profile's real deletes were dropped along with the
    /// ambiguous ones and never shown at all. Finding 8: a rename is
    /// similarly ambiguous when it could be either a real `--track-renames`
    /// rename (a profile's `additionalRcloneFlags` can set that) or a
    /// Move-capable backend's backup-dir move — since rclone's own JSON log
    /// line is textually identical for both, a trash-enabled profile cannot
    /// tell them apart and suppresses both, same as the bare `Deleted`
    /// ambiguity; a non-trash profile is unaffected either way. Pure so it is
    /// testable without a full `SyncManager`.
    nonisolated static func shouldReportFileChange(_ change: FileChange, hasTrashRoot: Bool) -> Bool {
        !(hasTrashRoot && change.mayBeTrashArtifact)
    }

    /// One rclone.conf section read — the actual computation `trashRootCache`
    /// exists to avoid repeating per file-change event (code-review finding 6
    /// on 87bbf67). Called only from `startWatching`.
    nonisolated private static func resolveHasTrashRoot(for profile: SyncProfile) -> Bool {
        let remoteSection = RcloneConfigService.shared.section(named: String(profile.rcloneRemote.prefix { $0 != ":" }))
        return SyncSetupService.trashRoot(for: profile, remoteSection: remoteSection) != nil
    }

    /// `updateAggregate: false` lets a batch caller apply many events and call
    /// `updateAggregateState` once afterwards (L6.3 change 1).
    private func processLogEvent(_ event: ParsedLogEvent, profileId: UUID, updateAggregate: Bool = true) {
        let profile = profileStore.profile(for: profileId)
        let profileName = profile?.name ?? "Unknown"
        let syncDirectoryPath = profile?.localSyncPath ?? ""

        switch event.type {
        case .syncStarted:
            profileStates[profileId] = Self.reduceProfileState(profileStates[profileId] ?? .idle, for: event.type)
            profileErrors[profileId] = nil  // Clear previous error on new sync
            lastSeenErrorMessage[profileId] = nil  // Clear last seen error
            profileProgress[profileId] = nil  // Reset progress for new sync
            currentSyncChanges[profileId] = 0
            logWatchers[profileId]?.setActivelySyncing(true)  // Increase polling frequency
            // Don't send notification - the menu bar icon updates to show syncing state
            notificationService.clearPendingChanges(for: profileId)

        case .syncCompleted:
            profileStates[profileId] = Self.reduceProfileState(profileStates[profileId] ?? .idle, for: event.type)
            profileErrors[profileId] = nil  // Clear error on success
            lastSeenErrorMessage[profileId] = nil
            profileProgress[profileId] = nil  // Clear progress when sync completes
            logWatchers[profileId]?.setActivelySyncing(false)  // Reduce polling frequency
            lastSyncTime = event.timestamp
            let changesCount = currentSyncChanges[profileId] ?? 0
            if !isNotificationsMuted(for: profileId) {
                notificationService.notifySyncCompleted(
                    changesCount: changesCount,
                    profileId: profileId,
                    profileName: profileName,
                    syncDirectoryPath: syncDirectoryPath
                )
            } else {
                // Still clean up pending state even when muted
                notificationService.clearPendingChanges(for: profileId)
            }
            currentSyncChanges[profileId] = nil

        case .syncFailed(let exitCode, let message):
            // Check if the error message (or the last seen error) is a transient one
            let errorToCheck = message ?? lastSeenErrorMessage[profileId]
            if let msg = errorToCheck, SyncLogPatterns.isTransientAllFilesChangedError(msg) {
                // Transient "all files were changed" - just clear state, don't show error
                profileProgress[profileId] = nil
                lastSeenErrorMessage[profileId] = nil
                logWatchers[profileId]?.setActivelySyncing(false)  // Reduce polling frequency
                currentSyncChanges[profileId] = nil  // Only clear this profile's changes
                // Reset to idle since this isn't a real error
                profileStates[profileId] = .idle
                break
            }

            profileStates[profileId] = .error(Self.exitCodeErrorText(exitCode))
            profileProgress[profileId] = nil  // Clear progress on failure
            lastSeenErrorMessage[profileId] = nil
            logWatchers[profileId]?.setActivelySyncing(false)  // Reduce polling frequency
            // Only use the syncFailed message if we don't already have a more specific error
            if profileErrors[profileId] == nil, let msg = message {
                profileErrors[profileId] = msg
            }
            let errorDescription = profileErrors[profileId] ?? message ?? Self.exitCodeErrorText(exitCode)
            if !isNotificationsMuted(for: profileId) {
                notificationService.notifySyncError(
                    "Sync failed: \(errorDescription)",
                    profileId: profileId,
                    profileName: profile?.name
                )
            }
            currentSyncChanges[profileId] = nil

        case .errorMessage(let message):
            // Track all error messages so we can correlate with syncFailed events
            lastSeenErrorMessage[profileId] = message

            // Transient "all files were changed" error should not be stored as a displayed error
            if SyncLogPatterns.isTransientAllFilesChangedError(message) {
                break
            }

            // Prefer critical/actionable errors over file-level errors
            // Critical errors tell us what to do (e.g., "out of sync", "resync")
            // File-level errors (e.g., "Path1 file not found") are less actionable
            let isCriticalError = SyncLogPatterns.isCriticalError(message)
            let existingIsCritical = profileErrors[profileId].map {
                SyncLogPatterns.isCriticalError($0)
            } ?? false

            // Store error if: no existing error, OR new error is critical and existing isn't
            if profileErrors[profileId] == nil || (isCriticalError && !existingIsCritical) {
                profileErrors[profileId] = message
            }

        case .driveNotMounted:
            let previousState = profileStates[profileId]
            profileStates[profileId] = .driveNotMounted
            // Only notify on state transition, not every poll
            if previousState != .driveNotMounted {
                if !isNotificationsMuted(for: profileId) {
                    notificationService.notifyDriveNotMounted(profileId: profileId, profileName: profileName)
                }
            }

        case .syncAlreadyRunning:
            // limpet-plan.md L6.1 change C, root cause 3: a lock-held skip line
            // means a sync IS running (elsewhere, or from before this app/watcher
            // pairing started watching) — show it, through the same pure reducer
            // `.syncStarted`/`.syncCompleted` use.
            profileStates[profileId] = Self.reduceProfileState(profileStates[profileId] ?? .idle, for: event.type)
            // code-review finding 3: without a poller, this sticks at `.syncing`
            // forever if the lock holder dies without ever writing a completion
            // line — more likely now that change B's SIGTERM handler can end a
            // run abruptly. `monitoringExternalSyncs` makes this a no-op when a
            // poller for this profile is already running.
            if !monitoringExternalSyncs.contains(profileId),
               let profile, let pid = detectRunningSyncPID(for: profile) {
                monitoringExternalSyncs.insert(profileId)
                startPollingForSyncCompletion(profile: profile, pid: pid)
            }

        case .sourceMissing(let path):
            // Menu only (L5.0) — no notification. Clears through the existing
            // path: the watcher's 30s recheck runs a sync once the source
            // returns, and .syncStarted below overwrites this unconditionally.
            profileStates[profileId] = Self.reduceProfileState(profileStates[profileId] ?? .idle, for: event.type)

        case .fileChange(var change):
            // Code-review finding 6 on 87bbf67: only even LOOK at
            // `hasTrashRoot` when the change is flagged ambiguous — for every
            // other change (the vast majority of log lines) `shouldReportFileChange`
            // returns true regardless, so there is nothing to gain by reading
            // `trashRootCache` at all. When it IS ambiguous, `trashRootCache`
            // is a lookup, not a computation: populated by `startWatching`
            // only when a profile's watching (re)starts (launch, or a
            // reinstall-worthy field change), never per file-change event.
            if change.mayBeTrashArtifact,
               !Self.shouldReportFileChange(change, hasTrashRoot: trashRootCache[profileId] ?? false) {
                break
            }
            change.profileName = profileName
            currentSyncChanges[profileId, default: 0] += 1
            addRecentChange(change)
            // Only send notification if not muted
            if !isNotificationsMuted(for: profileId) {
                notificationService.notifyFileChange(change, profileId: profileId, syncDirectoryPath: syncDirectoryPath)
            }

        case .stats(let stats):
            if let bytes = stats.bytes, let totalBytes = stats.totalBytes, totalBytes > 0 {
                let checksDone = stats.checks ?? 0
                let totalChecks = stats.totalChecks ?? 0

                profileProgress[profileId] = SyncProgress(
                    bytesTransferred: Int64(bytes),
                    totalBytes: Int64(totalBytes),
                    eta: stats.eta,
                    speed: stats.speed,
                    transfersDone: stats.transfers ?? 0,
                    totalTransfers: stats.totalTransfers ?? 0,
                    checksDone: checksDone,
                    totalChecks: totalChecks,
                    elapsedTime: stats.elapsedTime,
                    errors: stats.errors ?? 0,
                    transferringFiles: stats.transferring ?? [],
                    listedCount: stats.listed
                )
            }

        case .unknown:
            break
        }

        if updateAggregate { updateAggregateState() }
    }

    private func addRecentChange(_ change: FileChange) {
        recentChanges.insert(change, at: 0)
        if recentChanges.count > maxRecentChanges {
            recentChanges = Array(recentChanges.prefix(maxRecentChanges))
        }
    }


    /// Find which profile a log watcher belongs to
    private func profileId(for watcher: LogWatcher) -> UUID? {
        for (id, w) in logWatchers {
            if w === watcher {
                return id
            }
        }
        return nil
    }
}

// MARK: - LogWatcherDelegate

extension SyncManager: LogWatcherDelegate {
    /// `LogWatcher` always calls this on the main queue (one FIFO
    /// `DispatchQueue.main.async` per batch), so batches apply in order.
    nonisolated func logWatcher(_ watcher: LogWatcher, didReceiveNewLines lines: [String]) {
        MainActor.assumeIsolated {
            processLogLinesForWatcher(watcher, lines: lines)
        }
    }

    /// Pure batch reducer (AC-L63-1): every `.stats` event except the LAST one
    /// in the batch is dropped (each only overwrites `profileProgress`); all
    /// other events keep their order, and the kept stats event keeps its slot.
    nonisolated static func coalesceLogEvents(_ events: [ParsedLogEvent]) -> [ParsedLogEvent] {
        func isStats(_ e: ParsedLogEvent) -> Bool { if case .stats = e.type { return true }; return false }
        let lastStats = events.lastIndex(where: isStats)
        return events.enumerated().compactMap { i, e in (isStats(e) && i != lastStats) ? nil : e }
    }

    /// Cheap pre-parse filter (L6.3): every rclone JSON stats line except the last
    /// in the batch is dropped BEFORE JSON decoding, since `coalesceLogEvents`
    /// would drop its event anyway. A stats line is a line starting with `{` that
    /// contains `"stats":{` — checked against real rclone 1.75.1 `--use-json-log
    /// --stats 1s` output (2026-10-03: the stats entry carries `"stats":{"bytes":`);
    /// a file name containing that text appears escaped (`\"stats\":{`) in other
    /// entries, so it cannot match. Order and every other line are unchanged.
    nonisolated static func dropSupersededStatsLines(_ lines: [String]) -> [String] {
        func isStats(_ l: String) -> Bool { l.hasPrefix("{") && l.contains("\"stats\":{") }
        guard let last = lines.lastIndex(where: isStats) else { return lines }
        return lines.enumerated().compactMap { i, l in (i != last && isStats(l)) ? nil : l }
    }

    /// Process a batch for a watcher (must be called on main actor): parse,
    /// coalesce, apply in order, recompute the aggregate once.
    private func processLogLinesForWatcher(_ watcher: LogWatcher, lines: [String]) {
        guard let profileId = profileId(for: watcher) else { return }

        let events = Self.dropSupersededStatsLines(lines).compactMap { logParser.parse(line: $0) }
        for event in Self.coalesceLogEvents(events) {
            processLogEvent(event, profileId: profileId, updateAggregate: false)
        }
        updateAggregateState()
    }
}
