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
    private var currentSyncChanges: [UUID: [FileChange]] = [:]
    private var cancellables = Set<AnyCancellable>()

    /// Track the last error message per profile (for correlating with syncFailed events)
    private var lastSeenErrorMessage: [UUID: String] = [:]

    /// Profiles where we're monitoring an externally-started sync
    private var monitoringExternalSyncs: Set<UUID> = []

    /// Timers polling for sync completion
    private var syncCompletionPollers: [UUID: DispatchSourceTimer] = [:]

    private let maxRecentChanges = 20

    init(profileStore: ProfileStore? = nil) {
        self.profileStore = profileStore ?? ProfileStore()
        setupWorkspaceObserver()
        setupProfileObserver()
        setupService.refreshSharedScriptIfChanged()  // Propagate script template updates
        detectAndResumeRunningSyncs()  // Detect a sync the watcher already has in flight
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
            install: { [self] profile in
                try setupService.install(profile: profile)
                startWatching(profile: profile)
            },
            uninstall: { [self] profile in
                try setupService.uninstall(profile: profile)
                stopWatching(profileId: profile.id)
            },
            reportError: { [self] message in
                profileErrors[updated.id] = message
                LimpetSettings.debugLog("[\(updated.shortId)] \(message)")
            }
        )
    }

    // MARK: - External Config Reconcile

    /// Start watching `~/.config/limpet` for external edits. No-op if the
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
    func applyExternalProfileEdit(fromFileAt path: String) {
        guard let data = FileManager.default.contents(atPath: path),
              let updatedProfile = try? JSONDecoder().decode(SyncProfile.self, from: data) else {
            LimpetSettings.debugLog("[ConfigFileWatcher] Failed to decode external profile edit at \(path); skipping")
            return
        }

        guard let currentProfile = profileStore.profile(for: updatedProfile.id) else {
            applyExternalProfileCreate(decoded: updatedProfile, sourcePath: path)
            return
        }

        applyProfileChange(from: currentProfile, to: updatedProfile)
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
    /// FSEvent is a no-op (`ConfigFileWatcher.shouldReconcile` returns false for
    /// a missing file), so this can never loop.
    private func applyExternalProfileCreate(decoded: SyncProfile, sourcePath: String) {
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
            install: { [weak self] profile in
                do {
                    try self?.setupService.install(profile: profile)
                    self?.startWatching(profile: profile)
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
        for profile in profileStore.enabledProfiles {
            if let pid = detectRunningSyncPID(for: profile) {
                profileStates[profile.id] = .syncing
                monitoringExternalSyncs.insert(profile.id)
                startPollingForSyncCompletion(profile: profile, pid: pid)
            }
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

    private func startWatching(profile: SyncProfile) {
        let watcher = LogWatcher(logPath: profile.logPath)
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

    private func stopWatching(profileId: UUID) {
        logWatchers[profileId]?.stopWatching()
        logWatchers.removeValue(forKey: profileId)

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
            logWatchers[profileId]?.setActivelySyncing(true)  // Increase polling frequency
            // Don't send notification - the menu bar icon updates to show syncing state
            notificationService.clearPendingChanges(for: profileId)

        case .syncCompleted:
            profileStates[profileId] = .idle
            profileErrors[profileId] = nil  // Clear error on success
            lastSeenErrorMessage[profileId] = nil
            profileProgress[profileId] = nil  // Clear progress when sync completes
            logWatchers[profileId]?.setActivelySyncing(false)  // Reduce polling frequency
            lastSyncTime = event.timestamp
            let changesCount = currentSyncChanges[profileId]?.count ?? 0
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

            profileStates[profileId] = .error("Exit code \(exitCode)")
            profileProgress[profileId] = nil  // Clear progress on failure
            lastSeenErrorMessage[profileId] = nil
            logWatchers[profileId]?.setActivelySyncing(false)  // Reduce polling frequency
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
            break

        case .fileChange(var change):
            change.profileName = profileName
            if currentSyncChanges[profileId] == nil {
                currentSyncChanges[profileId] = []
            }
            currentSyncChanges[profileId]?.append(change)
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

        updateAggregateState()
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
