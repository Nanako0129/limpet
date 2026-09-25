import Foundation
import AppKit
import Combine
import ServiceManagement

@MainActor
final class SyncManager: ObservableObject {
    @Published private(set) var currentState: SyncState = .idle
    @Published private(set) var lastSyncTime: Date?
    @Published private(set) var recentChanges: [FileChange] = []
    /// Profiles with an in-flight app-initiated ("Sync Now" / directory-watch) run.
    /// Per-profile so one hung profile no longer blocks manual syncs for all others.
    @Published private(set) var manualSyncingProfiles: Set<UUID> = []

    /// True while any profile has an app-initiated sync in flight.
    /// Computed from `manualSyncingProfiles` so existing view bindings keep working;
    /// SwiftUI re-reads it whenever the published set changes.
    var isManualSyncRunning: Bool { !manualSyncingProfiles.isEmpty }

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
    private var directoryWatchers: [UUID: DirectoryWatcher] = [:]
    /// Watches ~/.config/synctray for external edits to *.profile.json and
    /// settings.json and routes them through the reconcile path below.
    private var configFileWatcher: ConfigFileWatcher?
    // What last kicked off a sync per profile (manual | directory_watch | startup), consumed
    // and cleared by the `.syncStarted` handler to attribute `sync.trigger`. Absent = scheduled.
    private var pendingSyncTrigger: [UUID: String] = [:]
    private let logParser = LogParser()
    private let notificationService = NotificationService.shared
    private let setupService = SyncSetupService.shared

    private var heartbeatTimer: DispatchSourceTimer?
    private var primaryRecoveryTimer: DispatchSourceTimer?
    // Profiles with an in-flight primary-recovery remount, so we don't stack remounts.
    private var recoveringToPrimary: Set<UUID> = []
    // Consecutive successful primary probes per profile. We only remount back onto the
    // primary after the primary has been reachable for several probes in a row, so a
    // flapping primary can't trigger a remount storm (every remount is an unmount+mount,
    // which surfaces a macOS "Server connections interrupted" dialog for a Stream mount).
    private var primaryRecoveryStreak: [UUID: Int] = [:]
    // Probes are 120s apart, so 3 in a row means ~6 minutes of stable primary.
    private let primaryRecoveryRequiredStreak = 3
    private var workspaceObserver: NSObjectProtocol?
    private var currentSyncChanges: [UUID: [FileChange]] = [:]
    private var cancellables = Set<AnyCancellable>()

    /// Track the last error message per profile (for correlating with syncFailed events)
    private var lastSeenErrorMessage: [UUID: String] = [:]

    /// Track sync start times per profile for duration measurement
    private var syncStartTimes: [UUID: Date] = [:]

    /// Track check phase: once totalChecks > 0 and checksDone < totalChecks, phase is active
    private var checkPhaseStartTimes: [UUID: Date] = [:]
    private var checkPhaseReported: Set<UUID> = []

    /// Profiles where we're monitoring an externally-started sync
    private var monitoringExternalSyncs: Set<UUID> = []

    /// Timers polling for sync completion
    private var syncCompletionPollers: [UUID: DispatchSourceTimer] = [:]

    private let maxRecentChanges = 20

    init(profileStore: ProfileStore? = nil) {
        self.profileStore = profileStore ?? ProfileStore()
        setupWorkspaceObserver()
        setupProfileObserver()
        cleanupStaleLockFiles()
        setupService.refreshSharedScriptIfChanged()  // Propagate script template updates
        detectAndResumeRunningSyncs()  // After cleanup, detect external syncs
        checkInitialState()
        startWatchingAllProfiles()
        // Report active profile count and configuration snapshot for telemetry
        TelemetryService.shared.recordProfileCount(self.profileStore.enabledProfiles.count)
        TelemetryService.shared.recordAllProfileConfigurations(self.profileStore.profiles)
        startSessionHeartbeat()
        refreshSettingsFile()
        startConfigWatcher()
    }

    deinit {
        configFileWatcher?.stop()
        configFileWatcher = nil

        // Cancel heartbeat timer
        heartbeatTimer?.cancel()
        heartbeatTimer = nil

        // Cancel primary-recovery monitor
        primaryRecoveryTimer?.cancel()
        primaryRecoveryTimer = nil

        // Cancel all sync completion pollers
        for timer in syncCompletionPollers.values {
            timer.cancel()
        }
        syncCompletionPollers.removeAll()

        // Stop all directory watchers
        for watcher in directoryWatchers.values {
            watcher.stop()
        }
        directoryWatchers.removeAll()

        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - Public Methods

    func refreshSettings() {
        startWatchingAllProfiles()
        checkInitialState()
    }

    /// Trigger manual sync for all enabled profiles, or a specific profile
    func triggerManualSync(for profile: SyncProfile? = nil) {
        let profilesToSync: [SyncProfile]
        if let profile = profile {
            // Skip if this specific profile is paused
            guard !isPaused(for: profile.id) else {
                SyncTraySettings.debugLog("Skipping manual sync for paused profile: \(profile.name)")
                return
            }
            // Per-profile guard: don't double-trigger a profile that's already
            // running an app-initiated sync (a different profile hanging no
            // longer blocks this one).
            guard !manualSyncingProfiles.contains(profile.id) else { return }
            profilesToSync = [profile]
        } else {
            // Filter out paused profiles and any already mid-sync
            profilesToSync = profileStore.enabledProfiles.filter {
                !isPaused(for: $0.id) && !manualSyncingProfiles.contains($0.id)
            }
        }

        guard !profilesToSync.isEmpty else {
            // Only surface "not configured" when there genuinely are no enabled
            // profiles — not when they're simply all mid-sync already.
            if profileStore.enabledProfiles.isEmpty {
                currentState = .notConfigured
            }
            return
        }

        let syncingIds = profilesToSync.map { $0.id }
        manualSyncingProfiles.formUnion(syncingIds)

        Task {
            // Run all profile syncs in parallel for better performance
            await withTaskGroup(of: Void.self) { group in
                for profile in profilesToSync {
                    group.addTask {
                        await self.runSyncScript(for: profile)
                    }
                }
            }
            await MainActor.run {
                manualSyncingProfiles.subtract(syncingIds)
            }
        }
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

    /// Enable/disable scheduled sync for a profile
    func setProfileEnabled(_ profile: SyncProfile, enabled: Bool) {
        var updatedProfile = profile
        updatedProfile.isEnabled = enabled
        profileStore.update(updatedProfile)

        if enabled {
            do {
                try setupService.install(profile: updatedProfile)
                startWatching(profile: updatedProfile)
            } catch {
                print("Failed to install profile: \(error)")
            }
        } else {
            do {
                try setupService.uninstall(profile: updatedProfile)
                stopWatching(profileId: profile.id)
            } catch {
                print("Failed to uninstall profile: \(error)")
            }
        }

        updateAggregateState()
    }

    // MARK: - External Config Reconcile

    /// Start watching `~/.config/synctray` for external edits. No-op if the
    /// directory doesn't exist yet (the app ensures it exists at launch via
    /// `ConfigSchemaInstaller.writeSchemas()`, called before `SyncManager` is created).
    private func startConfigWatcher() {
        let watcher = ConfigFileWatcher(
            onProfileChange: { [weak self] path in
                Task { @MainActor in self?.applyExternalProfileEdit(fromFileAt: path) }
            },
            onSettingsChange: { [weak self] in
                Task { @MainActor in self?.applyExternalSettingsEdit() }
            }
        )
        watcher.start()
        configFileWatcher = watcher
    }

    /// Rewrite `settings.json` from the current `SyncTraySettings` state.
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
    func applyExternalProfileEdit(fromFileAt path: String) {
        guard let data = FileManager.default.contents(atPath: path),
              let updatedProfile = try? JSONDecoder().decode(SyncProfile.self, from: data) else {
            SyncTraySettings.debugLog("[ConfigFileWatcher] Failed to decode external profile edit at \(path); skipping")
            return
        }

        guard let currentProfile = profileStore.profile(for: updatedProfile.id) else {
            applyExternalProfileCreate(decoded: updatedProfile, sourcePath: path)
            return
        }

        let action = Self.reconcileAction(from: currentProfile, to: updatedProfile)

        profileStore.update(updatedProfile)
        clearError(for: updatedProfile.id)

        switch action {
        case .none:
            break

        case .install:
            do {
                try setupService.install(profile: updatedProfile)
                startWatching(profile: updatedProfile)
            } catch {
                print("Failed to install externally-edited profile: \(error)")
            }

        case .uninstall:
            do {
                try setupService.uninstall(profile: updatedProfile)
                stopWatching(profileId: updatedProfile.id)
            } catch {
                print("Failed to uninstall externally-edited profile: \(error)")
            }

        case .reinstall:
            do {
                try setupService.uninstall(profile: updatedProfile)
            } catch {
                // Ignore uninstall errors, matching ProfileDetailView.reinstallSync.
            }
            do {
                try setupService.install(profile: updatedProfile)
                startWatching(profile: updatedProfile)
            } catch {
                print("Failed to reinstall externally-edited profile: \(error)")
            }
        }

        updateAggregateState()
        TelemetryService.shared.recordExternalConfigEdit(kind: "profile")
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
    /// FSEvent is a no-op (`ConfigFileWatcher.shouldReconcile` returns false for
    /// a missing file), so this can never loop.
    private func applyExternalProfileCreate(decoded: SyncProfile, sourcePath: String) {
        let outcome = Self.applyExternalCreateIfNeeded(
            decoded: decoded,
            isKnownId: false,
            persist: { [weak self] profile in
                self?.profileStore.add(profile)
                self?.clearError(for: profile.id)

                let canonicalFilename = "\(profile.shortId).profile.json"
                let sourceFilename = (sourcePath as NSString).lastPathComponent
                if sourceFilename != canonicalFilename {
                    try? FileManager.default.removeItem(atPath: sourcePath)
                }
            },
            install: { [weak self] profile in
                do {
                    try self?.setupService.install(profile: profile)
                    self?.startWatching(profile: profile)
                } catch {
                    print("Failed to install newly-created external profile: \(error)")
                }
            }
        )

        guard outcome != .ignored else { return }

        updateAggregateState()
        TelemetryService.shared.recordExternalConfigEdit(kind: "profile", action: "create")
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
                    SyncTraySettings.debugLoggingEnabled = value
                case .telemetryEnabled:
                    SyncTraySettings.telemetryEnabled = value
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

        TelemetryService.shared.recordExternalConfigEdit(kind: "settings")
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

    /// Pause syncing for a specific profile (stops directory watcher, blocks manual/scheduled syncs)
    func pauseProfile(_ profileId: UUID) {
        guard let profile = profileStore.profile(for: profileId) else { return }

        pausedProfiles.insert(profileId)

        // Stop directory watcher for this profile
        directoryWatchers[profileId]?.stop()
        directoryWatchers.removeValue(forKey: profileId)

        // Actually stop scheduled syncs. Previously pause only set an in-memory
        // flag, so launchd kept firing the sync script every interval — the
        // "paused" profile still hammered the remote and the spinner never
        // rested. Unload the agent so no new runs start.
        setupService.unloadAgent(for: profile)

        // Terminate any in-flight run for this profile and clear its lock, so a
        // hung/slow sync can't keep holding the lock and block a later resume.
        terminateRunningSync(for: profile)

        // Close any open telemetry span so it isn't later reported as abandoned.
        TelemetryService.shared.recordSyncSkipped(
            profileId: profileId,
            profileName: profile.name,
            reason: "paused"
        )

        // Update profile state to paused
        profileStates[profileId] = .paused
        profileProgress[profileId] = nil
        logWatchers[profileId]?.setActivelySyncing(false)

        updateAggregateState()

        SyncTraySettings.debugLog("Paused profile: \(profile.name)")
        TelemetryService.shared.recordProfileStateChange(
            profileId: profileId,
            profileName: profile.name,
            action: "paused"
        )
    }

    /// Terminate any running sync process for `profile` (identified via its lock
    /// file PID) and remove the lock so a killed/stale run can't block the next
    /// start. Best-effort: signals the process group (launchd runs each job as
    /// its own group leader) so the bash script and its rclone child both stop.
    /// Safe to call when nothing is running.
    private func terminateRunningSync(for profile: SyncProfile) {
        if let pid = detectRunningSyncPID(for: profile) {
            // Negative PID targets the whole process group; fall back to the
            // single process if it isn't a group leader.
            if kill(-pid, SIGTERM) != 0 {
                kill(pid, SIGTERM)
            }
        }
        // Stop any external-sync completion poller watching this profile.
        syncCompletionPollers[profile.id]?.cancel()
        syncCompletionPollers.removeValue(forKey: profile.id)
        monitoringExternalSyncs.remove(profile.id)
        // Remove the lock file so the next run isn't blocked by a stale lock.
        try? FileManager.default.removeItem(atPath: profile.lockFilePath)
    }

    /// Resume syncing for a specific profile (restarts directory watcher)
    func resumeProfile(_ profileId: UUID) {
        guard let profile = profileStore.profile(for: profileId),
              profile.isEnabled else { return }

        pausedProfiles.remove(profileId)

        // Reload the launchd agent that pause unloaded so scheduled syncs run
        // again. (No-op if it somehow never unloaded.)
        setupService.loadAgent(for: profile)

        // Restart directory watcher for this profile
        startWatchingDirectory(for: profile)

        // Reset state to idle (or check drive mount status)
        if !profile.drivePathToMonitor.isEmpty &&
           !FileManager.default.fileExists(atPath: profile.drivePathToMonitor) {
            profileStates[profileId] = .driveNotMounted
        } else {
            profileStates[profileId] = .idle
        }

        updateAggregateState()

        SyncTraySettings.debugLog("Resumed profile: \(profile.name)")
        TelemetryService.shared.recordProfileStateChange(
            profileId: profileId,
            profileName: profile.name,
            action: "resumed"
        )
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
    private func readLastErrorFromLog(_ logPath: String) -> String? {
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

    /// Detect running syncs at startup and start monitoring them
    private func detectAndResumeRunningSyncs() {
        var resumedCount = 0
        for profile in profileStore.enabledProfiles {
            if let pid = detectRunningSyncPID(for: profile) {
                profileStates[profile.id] = .syncing
                monitoringExternalSyncs.insert(profile.id)
                startPollingForSyncCompletion(profile: profile, pid: pid)
                resumedCount += 1
            }
        }
        if resumedCount > 0 {
            TelemetryService.shared.recordResumedExternalSync(
                profileId: UUID(), // aggregate event
                profileName: "all",
                count: resumedCount
            )
        }
        updateAggregateState()
    }

    /// Poll until the sync process exits
    private func startPollingForSyncCompletion(profile: SyncProfile, pid: Int32) {
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
           let error = readLastErrorFromLog(profile.logPath) {
            profileStates[profileId] = .error("Sync failed")
            profileErrors[profileId] = error
        } else {
            profileStates[profileId] = .idle
            lastSyncTime = Date()
        }

        updateAggregateState()
    }

    /// Clean up stale lock files on app startup
    /// Removes /tmp lock files where the PID is no longer running
    private func cleanupStaleLockFiles() {
        let fm = FileManager.default
        var staleLockCount = 0

        // Clean up SyncTray's /tmp lock files
        for profile in profileStore.profiles {
            let lockPath = profile.lockFilePath
            guard fm.fileExists(atPath: lockPath) else { continue }

            // Read PID and check if process is still running
            if let pidString = try? String(contentsOfFile: lockPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               let pid = Int32(pidString) {
                // kill with signal 0 checks if process exists without sending a signal
                if kill(pid, 0) != 0 {
                    // Process not running - remove stale lock
                    try? fm.removeItem(atPath: lockPath)
                    staleLockCount += 1
                }
            } else {
                // Could not read/parse PID - remove the lock file
                try? fm.removeItem(atPath: lockPath)
                staleLockCount += 1
            }
        }

        if staleLockCount > 0 {
            TelemetryService.shared.recordStaleLockCleanup(count: staleLockCount, lockType: "synctray")
        }
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
        for id in directoryWatchers.keys where !enabledProfileIds.contains(id) {
            directoryWatchers[id]?.stop()
            directoryWatchers.removeValue(forKey: id)
        }

        // Add watchers only for profiles that don't already have them
        for profile in profileStore.enabledProfiles {
            if logWatchers[profile.id] == nil {
                startWatching(profile: profile)
            }
            if directoryWatchers[profile.id] == nil {
                startWatchingDirectory(for: profile)
            }
        }
    }

    private func startWatching(profile: SyncProfile) {
        let watcher = LogWatcher(logPath: profile.logPath)
        watcher.profileName = profile.name
        watcher.delegate = self
        watcher.startWatching()
        logWatchers[profile.id] = watcher

        // If a sync is already running (detected at startup), use faster polling
        if profileStates[profile.id] == .syncing {
            watcher.setActivelySyncing(true)
        } else {
            profileStates[profile.id] = .idle
        }
    }

    /// Start watching a profile's local sync directory for file changes
    private func startWatchingDirectory(for profile: SyncProfile) {
        guard !profile.localSyncPath.isEmpty else { return }
        guard FileManager.default.fileExists(atPath: profile.localSyncPath) else { return }

        let profileId = profile.id
        let profileName = profile.name
        let watchPath = profile.localSyncPath
        let shortId = String(profileId.uuidString.prefix(8))
        SyncTraySettings.debugLog("Starting watcher for '\(profileName)' [id:\(shortId)] at: \(watchPath)")

        let watcher = DirectoryWatcher(
            paths: [watchPath],
            debounceInterval: 5.0,
            debugLabel: "\(profileName) [\(shortId)]"
        ) { [weak self] in
            Task { @MainActor in
                SyncTraySettings.debugLog("Change callback fired for '\(profileName)' [id:\(shortId)] -> triggering sync")
                self?.handleDirectoryChange(for: profileId)
            }
        }
        watcher.profileName = profileName
        watcher.start()
        directoryWatchers[profile.id] = watcher
    }

    /// Handle file system changes detected by DirectoryWatcher
    private func handleDirectoryChange(for profileId: UUID) {
        // Skip if profile is paused
        if isPaused(for: profileId) {
            SyncTraySettings.debugLog("DirectoryWatcher: Skipping sync for \(profileId.uuidString.prefix(8)) - profile paused")
            return
        }

        // Skip if profile is already syncing (avoid duplicate work)
        if profileStates[profileId] == .syncing {
            SyncTraySettings.debugLog("DirectoryWatcher: Skipping sync for \(profileId.uuidString.prefix(8)) - already syncing")
            return
        }

        // Skip if drive not mounted
        if profileStates[profileId] == .driveNotMounted {
            SyncTraySettings.debugLog("DirectoryWatcher: Skipping sync for \(profileId.uuidString.prefix(8)) - drive not mounted")
            return
        }

        // Get profile and verify it's still valid
        guard let profile = profileStore.profile(for: profileId),
              profile.isEnabled else {
            SyncTraySettings.debugLog("DirectoryWatcher: Skipping sync for \(profileId.uuidString.prefix(8)) - profile not found or disabled")
            return
        }

        SyncTraySettings.debugLog("DirectoryWatcher: Triggering sync for '\(profile.name)' (path: \(profile.localSyncPath))")

        TelemetryService.shared.recordDirectoryWatchTrigger(
            profileId: profileId,
            profileName: profile.name
        )

        // Trigger sync for this specific profile
        // Note: Lock file in sync script handles concurrent sync prevention
        Task {
            await runSyncScript(for: profile, trigger: "directory_watch")
        }
    }

    private func stopWatching(profileId: UUID) {
        logWatchers[profileId]?.stopWatching()
        logWatchers.removeValue(forKey: profileId)

        directoryWatchers[profileId]?.stop()
        directoryWatchers.removeValue(forKey: profileId)

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

        var affectedCount = 0
        for profile in profileStore.enabledProfiles {
            let drivePath = profile.drivePathToMonitor
            guard !drivePath.isEmpty else { continue }

            if drivePath.hasPrefix(volumePath) || volumePath == drivePath {
                affectedCount += 1
                notificationService.resetDriveNotMountedState(for: profile.id)
                if profileStates[profile.id] == .driveNotMounted {
                    profileStates[profile.id] = .idle
                }

                // Restart directory watcher for this profile (path is now available)
                directoryWatchers[profile.id]?.stop()
                directoryWatchers.removeValue(forKey: profile.id)
                startWatchingDirectory(for: profile)
            }
        }

        if affectedCount > 0 {
            TelemetryService.shared.recordVolumeEvent(event: "mounted", affectedProfiles: affectedCount)
        }

        updateAggregateState()
    }

    private func handleVolumeUnmount(_ notification: Notification) {
        guard let volumePath = (notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path else {
            return
        }

        var affectedCount = 0
        for profile in profileStore.enabledProfiles {
            let drivePath = profile.drivePathToMonitor
            guard !drivePath.isEmpty else { continue }

            if drivePath.hasPrefix(volumePath) || volumePath == drivePath {
                affectedCount += 1
                profileStates[profile.id] = .driveNotMounted
                if !isNotificationsMuted(for: profile.id) {
                    notificationService.notifyDriveNotMounted(profileId: profile.id, profileName: profile.name)
                }
            }
        }

        if affectedCount > 0 {
            TelemetryService.shared.recordVolumeEvent(event: "unmounted", affectedProfiles: affectedCount)
        }

        updateAggregateState()
    }

    private func runSyncScript(for profile: SyncProfile, trigger: String = "manual") async {
        // Remember what kicked this off so the `.syncStarted` log event (parsed from the
        // sync log, decoupled from here) can attribute `sync.trigger`. A launchd/scheduled
        // run never calls this method, so an absent entry means "scheduled".
        pendingSyncTrigger[profile.id] = trigger

        // Check if profile is paused
        if isPaused(for: profile.id) {
            SyncTraySettings.debugLog("Skipping sync script for paused profile: \(profile.name)")
            return
        }

        // Check if drive is mounted
        if !profile.drivePathToMonitor.isEmpty &&
           !FileManager.default.fileExists(atPath: profile.drivePathToMonitor) {
            await MainActor.run {
                profileStates[profile.id] = .driveNotMounted
                if !isNotificationsMuted(for: profile.id) {
                    notificationService.notifyDriveNotMounted(profileId: profile.id, profileName: profile.name)
                }
                updateAggregateState()
            }
            return
        }

        guard FileManager.default.fileExists(atPath: SyncProfile.sharedScriptPath) else {
            await MainActor.run {
                profileStates[profile.id] = .error("Script not found")
                TelemetryService.shared.recordSyncPreconditionFailure(
                    profileId: profile.id,
                    profileName: profile.name,
                    reason: "script_not_found"
                )
                updateAggregateState()
            }
            return
        }

        guard FileManager.default.fileExists(atPath: profile.configPath) else {
            await MainActor.run {
                profileStates[profile.id] = .error("Config not found")
                TelemetryService.shared.recordSyncPreconditionFailure(
                    profileId: profile.id,
                    profileName: profile.name,
                    reason: "config_not_found"
                )
                updateAggregateState()
            }
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [SyncProfile.sharedScriptPath, profile.configPath]

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in
                    continuation.resume()
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } catch {
            print("Failed to run sync script for \(profile.name): \(error)")
        }
    }

    private func processLogEvent(_ event: ParsedLogEvent, profileId: UUID) {
        let profile = profileStore.profile(for: profileId)
        let profileName = profile?.name ?? "Unknown"
        let syncDirectoryPath = profile?.localSyncPath ?? ""

        switch event.type {
        case .syncStarted:
            profileStates[profileId] = .syncing
            profileErrors[profileId] = nil  // Clear previous error on new sync
            lastSeenErrorMessage[profileId] = nil  // Clear last seen error
            profileProgress[profileId] = nil  // Reset progress for new sync
            currentSyncChanges[profileId] = []
            syncStartTimes[profileId] = Date()  // Record start time for duration tracking
            checkPhaseStartTimes.removeValue(forKey: profileId)  // Reset check phase tracking
            checkPhaseReported.remove(profileId)
            logWatchers[profileId]?.setActivelySyncing(true)  // Increase polling frequency
            // Don't send notification - the menu bar icon updates to show syncing state
            notificationService.clearPendingChanges(for: profileId)
            TelemetryService.shared.recordSyncStarted(
                profileId: profileId,
                profileName: profileName,
                syncMode: "sync",
                syncDirection: profile?.syncDirection,
                // An app-initiated run recorded its cause in runSyncScript; a bare
                // launchd/scheduled run left none, so default to "scheduled".
                trigger: pendingSyncTrigger.removeValue(forKey: profileId) ?? "scheduled"
            )

        case .syncCompleted:
            profileStates[profileId] = .idle
            profileErrors[profileId] = nil  // Clear error on success
            lastSeenErrorMessage[profileId] = nil
            profileProgress[profileId] = nil  // Clear progress when sync completes
            logWatchers[profileId]?.setActivelySyncing(false)  // Reduce polling frequency
            lastSyncTime = event.timestamp
            let changesCount = currentSyncChanges[profileId]?.count ?? 0
            // Report telemetry for successful sync
            let completedDuration = syncStartTimes[profileId].map { Date().timeIntervalSince($0) } ?? 0
            syncStartTimes[profileId] = nil
            TelemetryService.shared.recordSyncCompleted(
                profileId: profileId,
                profileName: profileName,
                mode: "sync",
                duration: completedDuration,
                filesChanged: changesCount
            )
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
                syncStartTimes[profileId] = nil
                logWatchers[profileId]?.setActivelySyncing(false)  // Reduce polling frequency
                currentSyncChanges[profileId] = nil  // Only clear this profile's changes
                // Reset to idle since this isn't a real error
                profileStates[profileId] = .idle
                break
            }

            profileStates[profileId] = .error("Exit code \(exitCode)")
            profileProgress[profileId] = nil  // Clear progress on failure
            lastSeenErrorMessage[profileId] = nil
            logWatchers[profileId]?.setActivelySyncing(false)  // Reduce polling frequency
            // Report telemetry for failed sync
            let failedDuration = syncStartTimes[profileId].map { Date().timeIntervalSince($0) } ?? 0
            syncStartTimes[profileId] = nil
            TelemetryService.shared.recordSyncFailed(
                profileId: profileId,
                profileName: profileName,
                mode: "sync",
                duration: failedDuration,
                filesChanged: currentSyncChanges[profileId]?.count ?? 0,
                exitCode: exitCode,
                errorMessage: message ?? profileErrors[profileId]
            )
            // Only use the syncFailed message if we don't already have a more specific error
            if profileErrors[profileId] == nil, let msg = message {
                profileErrors[profileId] = msg
            }
            let errorDescription = profileErrors[profileId] ?? message ?? "Exit code \(exitCode)"
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

            TelemetryService.shared.recordSyncError(
                profileId: profileId,
                profileName: profileName,
                errorMessage: message
            )

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
            // Only emit telemetry/notification on state transition, not every poll
            if previousState != .driveNotMounted {
                TelemetryService.shared.recordDriveNotMounted(
                    profileId: profileId,
                    profileName: profileName
                )
                if !isNotificationsMuted(for: profileId) {
                    notificationService.notifyDriveNotMounted(profileId: profileId, profileName: profileName)
                }
            }

        case .syncSkipped(let reason):
            // A scheduled run exited early without syncing (remote failed the
            // pre-flight reachability check). "Starting sync" already set the
            // profile to `.syncing` and opened a telemetry span; close both here
            // so the profile returns to rest instead of appearing to sync for
            // 11–37 min until the next run abandons the stale span.
            logWatchers[profileId]?.setActivelySyncing(false)
            profileProgress[profileId] = nil
            syncStartTimes[profileId] = nil
            checkPhaseStartTimes.removeValue(forKey: profileId)
            checkPhaseReported.remove(profileId)
            // Only downgrade from `.syncing`; never clobber a real error,
            // paused, or driveNotMounted state.
            if profileStates[profileId] == .syncing {
                profileStates[profileId] = .idle
            }
            TelemetryService.shared.recordSyncSkipped(
                profileId: profileId,
                profileName: profileName,
                reason: reason
            )

        case .syncAlreadyRunning:
            TelemetryService.shared.recordSyncContention(
                profileId: profileId,
                profileName: profileName
            )

        case .fileChange(var change):
            change.profileName = profileName
            if currentSyncChanges[profileId] == nil {
                currentSyncChanges[profileId] = []
            }
            currentSyncChanges[profileId]?.append(change)
            addRecentChange(change)
            TelemetryService.shared.recordFileOperation(
                profileName: profileName,
                operation: change.operation.rawValue,
                filePath: change.path
            )
            // Only send notification if not muted
            if !isNotificationsMuted(for: profileId) {
                notificationService.notifyFileChange(change, profileId: profileId, syncDirectoryPath: syncDirectoryPath)
            }

        case .stats(let stats):
            if let bytes = stats.bytes, let totalBytes = stats.totalBytes, totalBytes > 0 {
                let checksDone = stats.checks ?? 0
                let totalChecks = stats.totalChecks ?? 0

                // Track check phase duration (listing/comparison phase)
                if totalChecks > 0 && checksDone < totalChecks && checkPhaseStartTimes[profileId] == nil {
                    checkPhaseStartTimes[profileId] = Date()
                    checkPhaseReported.remove(profileId)
                }
                if totalChecks > 0 && checksDone >= totalChecks && !checkPhaseReported.contains(profileId),
                   let checkStart = checkPhaseStartTimes[profileId] {
                    let checkDuration = Date().timeIntervalSince(checkStart)
                    TelemetryService.shared.recordCheckPhaseDuration(
                        profileName: profileName,
                        syncMode: "sync",
                        durationSeconds: checkDuration,
                        checksCompleted: checksDone,
                        totalChecks: totalChecks
                    )
                    checkPhaseReported.insert(profileId)
                    checkPhaseStartTimes.removeValue(forKey: profileId)
                }

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

        updateAggregateState()
    }

    private func addRecentChange(_ change: FileChange) {
        recentChanges.insert(change, at: 0)
        if recentChanges.count > maxRecentChanges {
            recentChanges = Array(recentChanges.prefix(maxRecentChanges))
        }
    }


    /// Start a 5-minute session heartbeat for availability monitoring
    private func startSessionHeartbeat() {
        heartbeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 300, repeating: 300)  // every 5 minutes
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let enabled = self.profileStore.enabledProfiles.count
                let syncing = self.profileStates.values.filter { $0 == .syncing }.count
                let paused = self.pausedProfiles.count
                let errors = self.profileStates.values.filter {
                    if case .error = $0 { return true }; return false
                }.count
                TelemetryService.shared.recordSessionHeartbeat(
                    enabledProfiles: enabled,
                    syncingProfiles: syncing,
                    pausedProfiles: paused,
                    errorProfiles: errors
                )
            }
        }
        heartbeatTimer = timer
        timer.resume()
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
    nonisolated func logWatcher(_ watcher: LogWatcher, didReceiveNewLines lines: [String]) {
        // Process synchronously when already on main thread for immediate state updates
        // This fixes the race condition where UI renders before state is updated
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                processLogLinesForWatcher(watcher, lines: lines)
            }
        } else {
            Task { @MainActor in
                self.processLogLinesForWatcher(watcher, lines: lines)
            }
        }
    }

    /// Process log lines for a watcher (must be called on main actor)
    private func processLogLinesForWatcher(_ watcher: LogWatcher, lines: [String]) {
        guard let profileId = profileId(for: watcher) else { return }

        for line in lines {
            if let event = logParser.parse(line: line) {
                processLogEvent(event, profileId: profileId)
            }
        }
    }
}
