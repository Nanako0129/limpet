import SwiftUI
import AppKit

// MARK: - Profile Detail View

struct ProfileDetailView: View {
    let profile: SyncProfile
    @ObservedObject var profileStore: ProfileStore
    @ObservedObject var syncManager: SyncManager

    // Editable fields (local state)
    @State private var name: String = ""
    @State private var rcloneRemote: String = ""
    @State private var remotePath: String = ""
    @State private var localSyncPath: String = ""
    @State private var isExternalDrive: Bool = false
    @State private var syncIntervalMinutes: Int = 5
    @State private var additionalRcloneFlags: String = ""
    @State private var syncDirection: SyncDirection = .localToRemote

    // UI State
    @State private var showAdvanced: Bool = false
    @State private var isInstalling: Bool = false
    @State private var installError: String?
    @State private var showingUninstallConfirm: Bool = false
    @State private var showingReinstallConfirm: Bool = false
    @State private var availableRemotes: [String] = []
    @State private var isLoadingRemotes: Bool = false
    @State private var useTextInputForFolder: Bool = false
    @State private var remotesError: String?
    @State private var availableFolders: [String] = []
    @State private var isLoadingFolders: Bool = false
    @State private var foldersError: String?

    // Alert for sync already in progress
    @State private var showingSyncInProgressAlert: Bool = false

    // Setup wizard for reconfiguring the profile
    @State private var showingReconfigureWizard: Bool = false

    // Add remote sheet — tracks which picker opened it
    @State private var addRemoteTarget: AddRemoteTarget?

    enum AddRemoteTarget: Identifiable {
        case primary
        var id: Self { self }
    }

    // Edit remote sheet — tracks which picker opened it and the remote name
    @State private var editRemoteTarget: EditRemoteTarget?

    enum EditRemoteTarget: Identifiable {
        case primary(String)
        var id: String {
            switch self {
            case .primary(let name): return "primary-\(name)"
            }
        }
        var remoteName: String {
            switch self {
            case .primary(let name): return name
            }
        }
    }

    // Delete remote confirmation
    @State private var deleteRemoteConfirmName: String?
    @State private var showingDeleteRemoteConfirm: Bool = false

    // Non-empty local folder confirmation (warns about local/remote merge on first sync)
    @State private var showingNonEmptyDirConfirm: Bool = false
    @State private var pendingLocalSyncPath: String = ""
    @State private var pendingLocalSyncItemCount: Int = 0

    private let setupService = SyncSetupService.shared

    // MARK: - Computed Properties

    /// Check if a sync is currently running for this profile. The watcher
    /// process is the sole thing that ever runs a sync (see limpet-plan.md
    /// L3); this view only ever observes that fact through the profile log,
    /// which `SyncManager`'s `LogWatcher` already parses into `.syncing`.
    private var isSyncRunningForProfile: Bool {
        syncManager.state(for: profile.id) == .syncing
    }

    private var computedDrivePath: String {
        guard isExternalDrive, localSyncPath.hasPrefix("/Volumes/") else { return "" }
        let components = localSyncPath.split(separator: "/")
        if components.count >= 2 {
            return "/Volumes/\(components[1])"
        }
        return ""
    }

    private var hasChanges: Bool {
        name != profile.name ||
        rcloneRemote != profile.rcloneRemote ||
        remotePath != profile.remotePath ||
        localSyncPath != profile.localSyncPath ||
        computedDrivePath != profile.drivePathToMonitor ||
        syncIntervalMinutes != profile.syncIntervalMinutes ||
        additionalRcloneFlags != profile.additionalRcloneFlags ||
        syncDirection != profile.syncDirection
    }

    private var canInstall: Bool {
        !rcloneRemote.isEmpty && !localSyncPath.isEmpty && !remotePath.isEmpty
    }

    /// Trim surrounding whitespace and leading/trailing slashes so "/volume1/Kaiju/" and
    /// "volume1/Kaiju" compare equal — path-convention noise, not a real directory change.
    private func normalizedRemotePath(_ path: String) -> String {
        path.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private var isInstalled: Bool {
        setupService.isInstalled(profile: profile)
    }

    /// Returns true if this profile uses an external drive that is currently unplugged
    private var isExternalDriveUnplugged: Bool {
        let drivePath = profile.drivePathToMonitor
        guard !drivePath.isEmpty else { return false }
        return !FileManager.default.fileExists(atPath: drivePath)
    }

    /// Returns true if paths have changed, so the new path combination needs its
    /// first sync run (with visible output) rather than waiting for the next
    /// scheduled run.
    private var pathsNeedInitialSync: Bool {
        let pathsChanged = rcloneRemote != profile.rcloneRemote ||
                          remotePath != profile.remotePath ||
                          localSyncPath != profile.localSyncPath

        return pathsChanged && canInstall
    }

    /// Returns the number of items in the local directory (excluding hidden .limpet folder)
    private var localDirectoryItemCount: Int {
        SyncProfile.meaningfulItemCount(at: localSyncPath)
    }

    /// Returns true if local directory exists and has files that will be uploaded
    private var localDirectoryHasContent: Bool {
        localDirectoryItemCount > 0
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Profile Name
                    profileNameSection

                    Divider().padding(.vertical, 4)

                    sectionHeader("Automatic Sync", icon: "calendar.badge.clock")
                    scheduledSyncSection

                    Divider().padding(.vertical, 4)

                    // Configuration
                    sectionHeader("Sync Configuration", icon: "arrow.triangle.2.circlepath")
                    syncConfigurationSection

                    Divider().padding(.vertical, 4)

                    // Advanced Options
                    Button(action: { withAnimation { showAdvanced.toggle() } }) {
                        HStack {
                            sectionHeader("Advanced Options", icon: "gearshape.2")
                            Spacer()
                            Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)

                    if showAdvanced {
                        advancedSectionContent
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                .padding(.top, 12)
            }

            // Fixed footer with Save/Revert buttons
            Divider()
            actionButtons
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .onAppear {
            loadProfileValues()
            loadRcloneRemotes()
        }
        .onChange(of: profile.id) { _ in
            loadProfileValues()
        }
        .onChange(of: rcloneRemote) { newRemote in
            // Auto-fetch folders when a remote is selected
            if !newRemote.isEmpty {
                loadRemoteFolders()
            } else {
                availableFolders = []
            }
        }
        .alert("Uninstall Scheduled Sync?", isPresented: $showingUninstallConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Uninstall", role: .destructive) { uninstallSync() }
        } message: {
            Text("This will remove the sync script and stop automatic syncing for \"\(profile.name)\".")
        }
        .alert("Reinstall Scheduled Sync?", isPresented: $showingReinstallConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Reinstall", role: .destructive) { reinstallSync() }
        } message: {
            Text(reinstallConfirmMessage)
        }
        .alert("Sync Already Running", isPresented: $showingSyncInProgressAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("A sync is already in progress for this profile. Please wait for it to complete before starting another sync.")
        }
        .sheet(isPresented: $showingReconfigureWizard) {
            SetupWizardView(profileStore: profileStore, editing: profile)
        }
        .sheet(item: $addRemoteTarget) { _ in
            AddRemoteSheet { newRemoteName in
                loadRcloneRemotes()
                rcloneRemote = newRemoteName.hasSuffix(":") ? String(newRemoteName.dropLast()) : newRemoteName
            }
        }
        .sheet(item: $editRemoteTarget) { target in
            AddRemoteSheet(editing: target.remoteName) { _ in
                loadRcloneRemotes()
            }
        }
        .alert("Delete Remote?", isPresented: $showingDeleteRemoteConfirm) {
            Button("Cancel", role: .cancel) {
                deleteRemoteConfirmName = nil
            }
            Button("Delete", role: .destructive) {
                if let name = deleteRemoteConfirmName {
                    performDeleteRemote(name)
                }
                deleteRemoteConfirmName = nil
            }
        } message: {
            if let name = deleteRemoteConfirmName {
                Text("Delete remote \"\(name)\"? This cannot be undone. Any profiles using this remote will need to be reconfigured.")
            }
        }
        .alert("This Folder Is Not Empty", isPresented: $showingNonEmptyDirConfirm) {
            Button("Cancel", role: .cancel) {
                pendingLocalSyncPath = ""
                pendingLocalSyncItemCount = 0
            }
            Button("Use This Folder", role: .destructive) {
                localSyncPath = pendingLocalSyncPath
                pendingLocalSyncPath = ""
                pendingLocalSyncItemCount = 0
            }
        } message: {
            Text(nonEmptyDirWarningMessage)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.headline)
            .foregroundColor(.primary)
    }

    @ViewBuilder
    private func syncDirectionCard(
        direction: SyncDirection,
        isSelected: Bool,
        title: String,
        subtitle: String,
        description: String,
        leftIcon: String,
        rightIcon: String
    ) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                syncDirection = direction
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.body)
                            .foregroundStyle(Color.accentColor)
                    }
                }

                // Visual direction indicator
                HStack(spacing: 4) {
                    Image(systemName: leftIcon)
                        .font(.caption)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                    Image(systemName: rightIcon)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var profileNameSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Profile Name")
                .font(.subheadline.weight(.medium))
            TextField("e.g., Work, Personal, Photos", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
        }
    }

    private var syncConfigurationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Remote Name
            VStack(alignment: .leading, spacing: 4) {
                Text("Remote Name")
                    .font(.subheadline.weight(.medium))
                Text("The rclone remote to sync with")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    if isLoadingRemotes {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 150)
                    } else if !availableRemotes.isEmpty {
                        Picker("", selection: $rcloneRemote) {
                            Text("Select...").tag("")
                            ForEach(availableRemotes, id: \.self) { remote in
                                Text(remote).tag(remote)
                            }
                        }
                        .labelsHidden()
                    } else {
                        TextField("e.g., synology", text: $rcloneRemote)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200)
                    }

                    Button(action: { addRemoteTarget = .primary }) {
                        Image(systemName: "plus")
                    }
                    .help("Setup a new remote")

                    Button(action: loadRcloneRemotes) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh remotes list")

                    if !rcloneRemote.isEmpty {
                        Button(action: {
                            let name = rcloneRemote.hasSuffix(":") ? String(rcloneRemote.dropLast()) : rcloneRemote
                            editRemoteTarget = .primary(name)
                        }) {
                            Image(systemName: "pencil")
                        }
                        .help("Edit this remote's configuration")

                        Button(action: {
                            let name = rcloneRemote.hasSuffix(":") ? String(rcloneRemote.dropLast()) : rcloneRemote
                            deleteRemoteConfirmName = name
                            showingDeleteRemoteConfirm = true
                        }) {
                            Image(systemName: "trash")
                        }
                        .help("Delete this remote")
                    }

                    Spacer()
                }

                if let error = remotesError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if availableRemotes.isEmpty && !isLoadingRemotes {
                    Text("No remotes configured yet. Click + to create one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Remote Folder
            VStack(alignment: .leading, spacing: 4) {
                Text("Remote Folder")
                    .font(.subheadline.weight(.medium))
                Text("The folder path on the remote to sync")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    if isLoadingFolders {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if useTextInputForFolder {
                        // Custom text input mode
                        TextField("e.g., home/Documents", text: $remotePath)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        // Folder picker mode (default)
                        Picker("", selection: $remotePath) {
                            Text("Select folder...").tag("")
                            ForEach(availableFolders, id: \.self) { folder in
                                Text(folder).tag(folder)
                            }
                        }
                        .labelsHidden()
                        .disabled(availableFolders.isEmpty)
                    }

                    // Toggle between picker and text input
                    Button(action: { useTextInputForFolder.toggle() }) {
                        Image(systemName: useTextInputForFolder ? "list.bullet" : "pencil")
                    }
                    .help(useTextInputForFolder ? "Switch to folder picker" : "Enter custom path")
                    Spacer()
                }

                if let error = foldersError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if availableFolders.isEmpty && !isLoadingFolders && !rcloneRemote.isEmpty && !useTextInputForFolder {
                    Label("No folders found. Use custom path if needed.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Local Folder
            VStack(alignment: .leading, spacing: 4) {
                Text("Local Folder")
                    .font(.subheadline.weight(.medium))
                Text("The folder on your Mac that will be synced with the remote")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("/Volumes/MyDrive/MyFolder", text: $localSyncPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse...") {
                        browseForFolder(title: "Select Local Sync Directory") { path in
                            confirmLocalPathSelection(path)
                        }
                    }
                    Button(action: { openLocalFolderInFinder() }) {
                        Image(systemName: "folder")
                    }
                    .disabled(!localFolderExists)
                    .help("Open in Finder")
                }

                // External drive toggle
                if localSyncPath.hasPrefix("/Volumes/") {
                    Toggle(isOn: $isExternalDrive) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("External drive")
                                .font(.subheadline)
                            Text("Skip sync when drive is disconnected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .padding(.top, 8)
                }
            }

            // Sync Direction
            VStack(alignment: .leading, spacing: 8) {
                Text("Direction")
                    .font(.subheadline.weight(.medium))

                HStack(spacing: 12) {
                    // Local → Remote
                    syncDirectionCard(
                        direction: .localToRemote,
                        isSelected: syncDirection == .localToRemote,
                        title: "Upload",
                        subtitle: "Local → Remote",
                        description: "Send local files to cloud",
                        leftIcon: "folder.fill",
                        rightIcon: "cloud.fill"
                    )

                    // Remote → Local
                    syncDirectionCard(
                        direction: .remoteToLocal,
                        isSelected: syncDirection == .remoteToLocal,
                        title: "Download",
                        subtitle: "Remote → Local",
                        description: "Get cloud files to local",
                        leftIcon: "cloud.fill",
                        rightIcon: "folder.fill"
                    )
                }

                // Warning about one-way sync deleting files
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    if syncDirection == .localToRemote {
                        Text("Files on remote that don't exist locally will be deleted")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text("Local files that don't exist on remote will be deleted")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.top, 4)
            }

            // Warning when paths changed and need initial sync
            if pathsNeedInitialSync {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Initial sync required")
                                .font(.subheadline.weight(.medium))
                            Text("These paths haven't been synced before. Saving will run an initial sync to establish the baseline.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if localDirectoryHasContent {
                        HStack(spacing: 8) {
                            Image(systemName: firstSyncEffect.icon)
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Local folder contains \(localDirectoryItemCount) item\(localDirectoryItemCount == 1 ? "" : "s")")
                                    .font(.subheadline.weight(.medium))
                                Text("On the first sync, \(firstSyncEffect.headline).")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1))
                .clipShape(.rect(cornerRadius: 6))
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.15), in: .rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sync Interval")
                    .font(.subheadline.weight(.medium))
                Text("How often to run the sync (in minutes)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Picker("", selection: $syncIntervalMinutes) {
                        Text("1 minute").tag(1)
                        Text("2 minutes").tag(2)
                        Text("5 minutes").tag(5)
                        Text("10 minutes").tag(10)
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                        Text("1 hour").tag(60)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
                    Spacer()
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    private var scheduledSyncSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Status - check local resync state first, then syncManager state
            HStack {
                if isInstalled {
                    let state = syncManager.state(for: profile.id)
                    switch state {
                    case .paused:
                        Label("Paused", systemImage: "pause.circle.fill")
                            .foregroundColor(.gray)
                    case .error:
                        Label("Error", systemImage: "exclamationmark.circle.fill")
                            .foregroundColor(.red)
                    case .syncing:
                        // Distinguish between external (detected on app open) vs active syncs
                        if syncManager.isMonitoringExternalSync(for: profile.id) {
                            Label("Sync in Progress", systemImage: "eye.circle.fill")
                                .foregroundColor(.blue)
                        } else {
                            Label("Syncing", systemImage: "arrow.triangle.2.circlepath")
                                .foregroundColor(.blue)
                        }
                    default:
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        if isExternalDriveUnplugged {
                            Text("(External drive unplugged)")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                } else {
                    Label("Not Installed", systemImage: "circle.dashed")
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            // Sync progress indicator
            if syncManager.state(for: profile.id) == .syncing {
                HStack {
                    if let progress = syncManager.profileProgress[profile.id] {
                        SyncProgressDetailView(progress: progress)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Starting sync...")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                    }

                    Spacer()

                    // Mute notifications button
                    Button(action: {
                        if syncManager.isNotificationsMuted(for: profile.id) {
                            syncManager.unmuteNotifications(for: profile.id)
                        } else {
                            syncManager.muteNotifications(for: profile.id)
                        }
                    }) {
                        Image(systemName: syncManager.isNotificationsMuted(for: profile.id)
                              ? "bell.slash.fill"
                              : "bell.fill")
                            .foregroundColor(syncManager.isNotificationsMuted(for: profile.id)
                                             ? .orange
                                             : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(syncManager.isNotificationsMuted(for: profile.id)
                          ? "Unmute profile notifications"
                          : "Mute profile notifications")
                }
            }

            // Last sync error from rclone (hide during an active sync)
            if isInstalled, !isSyncRunningForProfile, let lastError = syncManager.lastError(for: profile.id) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Last sync error:", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.red)
                    Text(lastError)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(4)

                    // Action button for common (retryable) errors
                    if let errorAction = detectErrorAction(from: lastError) {
                        HStack(spacing: 8) {
                            Button(action: {
                                if isSyncRunningForProfile {
                                    showingSyncInProgressAlert = true
                                    return
                                }
                                handleErrorAction(errorAction)
                            }) {
                                if isSyncRunningForProfile {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text(errorAction.progressText)
                                } else {
                                    Label(errorAction.buttonText, systemImage: errorAction.icon)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isSyncRunningForProfile)
                            .help(errorAction.helpText)
                        }
                    }

                }
            }

            // Info about generated files
            if isInstalled {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Generated files:")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)
                    filePathLink(label: "Script", path: SyncProfile.sharedScriptPath)
                    filePathLink(label: "Config", path: profile.configPath)
                    filePathLink(label: "Exclude Filter", path: profile.filterFilePath)
                    filePathLink(label: "Schedule", path: profile.plistPath)
                    filePathLink(label: "Log", path: profile.logPath)
                }
            }

            // Error message
            if let error = installError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            // Buttons
            HStack {
                if isInstalled {
                    Button(action: {
                        // Double-check at action time in case state changed
                        if isSyncRunningForProfile {
                            showingSyncInProgressAlert = true
                            return
                        }
                        // Don't sync if paused
                        if syncManager.isPaused(for: profile.id) {
                            return
                        }
                        // The lock file belongs to the launchd-owned watcher now —
                        // the GUI never touches it (see limpet-plan.md L3(c)).
                        syncManager.triggerManualSync(for: profile)
                    }) {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSyncRunningForProfile || syncManager.isPaused(for: profile.id))

                    // Pause/Resume button
                    Button(action: {
                        syncManager.togglePause(for: profile.id)
                    }) {
                        Label(
                            syncManager.isPaused(for: profile.id) ? "Resume" : "Pause",
                            systemImage: syncManager.isPaused(for: profile.id) ? "play.fill" : "pause.fill"
                        )
                    }
                    .disabled(isSyncRunningForProfile)

                    Button(action: { showingUninstallConfirm = true }) {
                        Label("Uninstall", systemImage: "trash")
                    }
                    .disabled(isSyncRunningForProfile)

                    Button(action: { showingReinstallConfirm = true }) {
                        Label("Reinstall", systemImage: "arrow.clockwise")
                    }
                    .disabled(!canInstall || isInstalling || isSyncRunningForProfile)
                } else {
                    Button(action: installSync) {
                        if isInstalling {
                            ProgressView()
                                .controlSize(.small)
                            Text("Installing...")
                        } else {
                            Label("Install Scheduled Sync", systemImage: "plus.circle")
                        }
                    }
                    .disabled(!canInstall || isInstalling)
                    .buttonStyle(.borderedProminent)
                    .opacity(canInstall ? 1.0 : 0.5)
                }
                Spacer()
            }

            // Show why install is disabled
            if !canInstall && !isInstalled {
                VStack(alignment: .leading, spacing: 2) {
                    if rcloneRemote.isEmpty {
                        Label("Select an rclone remote", systemImage: "exclamationmark.circle")
                    }
                    if remotePath.isEmpty {
                        Label("Enter the folder path on the remote", systemImage: "exclamationmark.circle")
                    }
                    if localSyncPath.isEmpty {
                        Label("Select a local folder", systemImage: "exclamationmark.circle")
                    }
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.15), in: .rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var advancedSectionContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sync Interval")
                    .font(.subheadline.weight(.medium))
                Text("How often to run the sync")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("", selection: $syncIntervalMinutes) {
                    Text("1 minute").tag(1)
                    Text("2 minutes").tag(2)
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                }
                .pickerStyle(.menu)
                .frame(width: 150, alignment: .leading)
            }

            Divider()

            // Additional rclone flags
            VStack(alignment: .leading, spacing: 4) {
                Text("Additional rclone Flags")
                    .font(.subheadline.weight(.medium))
                Text("Extra flags to pass to the rclone sync command. Whitespace-separated; write them as --flag=value (e.g. --exclude=*.tmp), no quotes — a flag's value cannot contain a space, and quotes/$/backticks/~ are refused.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("--dry-run --verbose", text: $additionalRcloneFlags)
                    .textFieldStyle(.roundedBorder)
            }

            Divider()

            // Reconfigure Remote
            VStack(alignment: .leading, spacing: 4) {
                Text("Reconfigure Profile")
                    .font(.subheadline.weight(.medium))
                Text("Use the setup wizard to change remote settings or re-authenticate")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(action: { showingReconfigureWizard = true }) {
                    Label("Open Setup Wizard", systemImage: "wand.and.stars")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.15), in: .rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var actionButtons: some View {
        HStack {
            if hasChanges {
                Text("You have unsaved changes")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            Spacer()

            Button("Revert") {
                loadProfileValues()
            }
            .disabled(!hasChanges)

            Button("Save") {
                saveProfile()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!hasChanges)
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Actions

    private func loadProfileValues() {
        name = profile.name
        rcloneRemote = profile.rcloneRemote
        remotePath = profile.remotePath
        localSyncPath = profile.localSyncPath
        isExternalDrive = !profile.drivePathToMonitor.isEmpty
        syncIntervalMinutes = profile.syncIntervalMinutes
        additionalRcloneFlags = profile.additionalRcloneFlags
        syncDirection = profile.syncDirection

        // Show text input if the path contains "/" (nested path) or is a custom path
        // that won't be in the folder picker dropdown
        useTextInputForFolder = profile.remotePath.contains("/")
    }

    /// Build a profile from the current form state
    private func buildProfileFromForm() -> SyncProfile {
        var updatedProfile = profile
        updatedProfile.name = name
        updatedProfile.rcloneRemote = rcloneRemote
        updatedProfile.remotePath = remotePath
        updatedProfile.localSyncPath = localSyncPath
        updatedProfile.drivePathToMonitor = computedDrivePath
        updatedProfile.syncIntervalMinutes = syncIntervalMinutes
        updatedProfile.additionalRcloneFlags = additionalRcloneFlags
        updatedProfile.syncDirection = syncDirection
        return updatedProfile
    }

    private func saveProfile() {
        let updatedProfile = buildProfileFromForm()
        let currentProfile = profile

        // Delegates to the SAME delta helper `applyExternalProfileEdit` uses,
        // so the Save button and an external file edit can never drift on
        // "what work does this change need" (see plan Decisions).
        let needsReinstall = isInstalled
            && SyncManager.reconcileAction(from: currentProfile, to: updatedProfile) == .reinstall

        // Refuse BEFORE persisting (review finding 6): a refused edit must
        // leave the stored profile and the running agent as they were.
        if let reason = SyncManager.profileChangeRefusal(
            updatedProfile, others: profileStore.profiles, isInstalled: SyncProfile.agentInstalled) {
            installError = "Not saved: \(reason)"
            return
        }

        profileStore.update(updatedProfile)

        // Clear any cached error since config changed
        syncManager.clearError(for: profile.id)

        // Only reinstall if sync-related settings changed
        if needsReinstall {
            reinstallSync()
        }
    }

    private func performDeleteRemote(_ name: String) {
        // Capture state values before dispatching to background
        let capturedRcloneRemote = rcloneRemote

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let nameWithoutColon = name.hasSuffix(":") ? String(name.dropLast()) : name
                try RcloneConfigService.shared.deleteRemote(name)
                let clearRclone = capturedRcloneRemote == nameWithoutColon || capturedRcloneRemote == "\(nameWithoutColon):"

                DispatchQueue.main.async {
                    // Clear selection if the deleted remote was selected
                    if clearRclone {
                        rcloneRemote = ""
                        availableFolders = []
                    }
                    loadRcloneRemotes()
                }
            } catch {
                DispatchQueue.main.async {
                    installError = "Failed to delete remote: \(error.localizedDescription)"
                }
            }
        }
    }

    private func loadRcloneRemotes() {
        isLoadingRemotes = true
        remotesError = nil

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let pipe = Pipe()

            let rclonePath = RcloneLocator.resolve()

            guard let path = rclonePath else {
                DispatchQueue.main.async {
                    isLoadingRemotes = false
                    remotesError = "rclone not found. Install with: brew install rclone"
                }
                return
            }

            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["listremotes"]
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""

                let remotes = output
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .map { $0.hasSuffix(":") ? String($0.dropLast()) : $0 }

                DispatchQueue.main.async {
                    availableRemotes = remotes
                    isLoadingRemotes = false
                    if remotes.isEmpty {
                        remotesError = "No remotes configured. Run: rclone config"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    isLoadingRemotes = false
                    remotesError = "Failed to list remotes: \(error.localizedDescription)"
                }
            }
        }
    }

    private func loadRemoteFolders() {
        guard !rcloneRemote.isEmpty else { return }

        isLoadingFolders = true
        foldersError = nil
        availableFolders = []

        // Captured on the main thread (CLAUDE.md Critical Rule #1).
        let capturedRemote = rcloneRemote
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let pipe = Pipe()

            let rclonePath = RcloneLocator.resolve()

            guard let path = rclonePath else {
                DispatchQueue.main.async {
                    isLoadingFolders = false
                    foldersError = "rclone not found"
                }
                return
            }

            process.executableURL = URL(fileURLWithPath: path)
            var keychainError = ""
            guard let environment = RcloneConfigService.shared.processEnvironment(
                forRemote: capturedRemote, log: { keychainError = $0 }) else {
                DispatchQueue.main.async {
                    isLoadingFolders = false
                    foldersError = keychainError
                }
                return
            }
            process.environment = environment
            let remoteName = capturedRemote.replacingOccurrences(of: ":", with: "")
            let skipCert = RcloneConfigService.shared.readRemoteConfig(name: remoteName)?.values["no_check_certificate"] == "true"
            var args = ["lsd", "\(capturedRemote):"]
            if skipCert {
                args.append("--no-check-certificate")
            }
            process.arguments = args
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()

                guard process.terminationStatus == 0 else {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let errorOutput = String(data: data, encoding: .utf8) ?? "Unknown error"
                    DispatchQueue.main.async {
                        isLoadingFolders = false
                        foldersError = "Failed to list folders: \(errorOutput)"
                    }
                    return
                }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""

                let folders = output
                    .components(separatedBy: .newlines)
                    .compactMap { line -> String? in
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return nil }
                        let components = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                        return components.last
                    }

                DispatchQueue.main.async {
                    availableFolders = folders.sorted()
                    isLoadingFolders = false
                    if folders.isEmpty {
                        foldersError = "No folders found on remote (or remote is empty)"
                    }

                    // If current path doesn't match any folder, switch to text input
                    if !self.remotePath.isEmpty && !folders.contains(self.remotePath) {
                        self.useTextInputForFolder = true
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    isLoadingFolders = false
                    foldersError = "Failed to list folders: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Install from the live form — the ordinary path.
    ///
    /// A distinct zero-argument overload rather than a default argument on
    /// `installSync(using:)`: this function is passed by REFERENCE
    /// (`Button(action: installSync)`), and a Swift function reference does
    /// NOT apply default arguments, so a single defaulted-parameter version
    /// has type `(SyncProfile?) -> Void` at those call sites and fails to
    /// convert to the `() -> Void` a `Button` action wants.
    private func installSync() {
        installSync(using: nil)
    }

    /// - Parameter overrideProfile: when non-nil, install exactly this
    ///   profile instead of rebuilding one from the live form.
    private func installSync(using overrideProfile: SyncProfile?) {
        isInstalling = true
        installError = nil

        // Build profile from current form state (no need to save first) —
        // unless an explicit override was supplied.
        let currentProfile = overrideProfile ?? buildProfileFromForm()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // 1. Initialize paths (create local dir) BEFORE the agent can
                // possibly load, so the watcher's very first catch-up sync
                // never race the directory into existence.
                if let error = setupService.initializeSyncPaths(for: currentProfile) {
                    DispatchQueue.main.async {
                        isInstalling = false
                        installError = error
                    }
                    return
                }

                // 2. Install script, config, plist, and load the launchd
                // agent (KeepAlive+RunAtLoad). The watcher process this
                // starts is the SOLE thing that ever runs a sync — see
                // limpet-plan.md L3 — so there is no separate "run the first
                // sync from the GUI" step here: RunAtLoad makes the watcher's
                // own startup catch-up sync do that, and its progress shows
                // up through the normal log-watching pipeline below.
                try setupService.install(profile: currentProfile)

                DispatchQueue.main.async {
                    var enabledProfile = currentProfile
                    enabledProfile.isEnabled = true
                    profileStore.update(enabledProfile)
                    syncManager.refreshSettings()  // LogWatcher now watching
                    isInstalling = false
                }
            } catch {
                DispatchQueue.main.async {
                    isInstalling = false
                    installError = error.localizedDescription
                }
            }
        }
    }

    private func uninstallSync() {
        guard let currentProfile = profileStore.profile(for: profile.id) else { return }

        do {
            try setupService.uninstall(profile: currentProfile)

            // Update profile to mark as disabled
            var disabledProfile = currentProfile
            disabledProfile.isEnabled = false
            profileStore.update(disabledProfile)
            syncManager.refreshSettings()
        } catch {
            installError = error.localizedDescription
        }
    }

    /// Confirmation alert message for Reinstall.
    private var reinstallConfirmMessage: String {
        "This removes the current schedule and recreates it. If verification fails, the schedule won't run until you fix the configuration."
    }

    /// - Parameter overrideProfile: forwarded to `installSync(using:)` — see
    ///   its doc comment. The uninstall half already reads the
    ///   currently-persisted profile from `profileStore`, so only the
    ///   install half needed a form-bypass.
    private func reinstallSync(using overrideProfile: SyncProfile? = nil) {
        guard let currentProfile = profileStore.profile(for: profile.id) else { return }

        do {
            try setupService.uninstall(profile: currentProfile)
        } catch {
            // Ignore uninstall errors
        }
        installSync(using: overrideProfile)
    }

    // MARK: - File Dialogs

    /// Applies a newly chosen local sync path, first warning the user if the folder
    /// already contains files — on the first sync those files are reconciled with the
    /// remote (merged, overwritten, or deleted depending on mode), which can surprise.
    private func confirmLocalPathSelection(_ path: String) {
        let count = SyncProfile.meaningfulItemCount(at: path)
        // Re-selecting the folder that's already configured is expected to hold synced
        // files — only warn when pointing at a *different* non-empty folder.
        if count > 0 && path != profile.localSyncPath {
            pendingLocalSyncPath = path
            pendingLocalSyncItemCount = count
            showingNonEmptyDirConfirm = true
        } else {
            localSyncPath = path
        }
    }

    /// Describes what the first sync will do to a non-empty local folder, tailored to
    /// the current direction so warnings match actual behaviour. Drives both the
    /// picker confirmation dialog and the inline "folder not empty" banner so they
    /// tell one consistent story.
    private var firstSyncEffect: (icon: String, headline: String, detail: String) {
        switch syncDirection {
        case .localToRemote:
            return (
                "arrow.up.circle.fill",
                "files here will be uploaded, and remote files missing here may be deleted",
                "One-way upload makes the remote match this folder. Files that exist only on the remote can be deleted to mirror your local copy."
            )
        case .remoteToLocal:
            return (
                "exclamationmark.triangle.fill",
                "files here may be overwritten or deleted to match the remote",
                "One-way download makes this folder match the remote. Files here that aren't on the remote can be deleted, and any that differ will be overwritten — this can be hard to undo."
            )
        }
    }

    /// Detailed warning shown when a user points the sync at a folder that already
    /// contains files. Names the folder and describes the mode-specific first-sync effect.
    private var nonEmptyDirWarningMessage: String {
        let count = pendingLocalSyncItemCount
        let itemWord = count == 1 ? "item" : "items"
        let folderName = URL(fileURLWithPath: pendingLocalSyncPath).lastPathComponent
        return """
        \"\(folderName)\" already contains \(count) \(itemWord).

        \(firstSyncEffect.detail)

        Only continue if that's what you intend.
        """
    }

    /// Whether the local folder currently entered in the form exists on disk.
    /// False when the path is empty or missing (e.g. external drive disconnected),
    /// which disables the "Open in Finder" button instead of opening nothing.
    private var localFolderExists: Bool {
        var isDirectory: ObjCBool = false
        return !localSyncPath.isEmpty
            && FileManager.default.fileExists(atPath: localSyncPath, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Opens the local sync folder in Finder.
    /// Uses the form's current value so the button follows unsaved edits.
    private func openLocalFolderInFinder() {
        guard localFolderExists else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: localSyncPath))
    }

    private func browseForFolder(title: String, completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            completion(url.path)
        }
    }

    @ViewBuilder
    private func filePathLink(label: String, path: String) -> some View {
        let displayPath = path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        HStack(spacing: 4) {
            Text("• \(label):")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(displayPath)
                .font(.caption)
                .foregroundColor(.gray)
                .textSelection(.enabled)
                .onTapGesture {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
                .help("Click to open, or select to copy path")
        }
    }

    // MARK: - Error Action Handling

    enum ErrorAction {
        case retrySync

        var buttonText: String {
            switch self {
            case .retrySync:
                return "Retry Sync"
            }
        }

        var progressText: String {
            switch self {
            case .retrySync:
                return "Syncing..."
            }
        }

        var icon: String {
            switch self {
            case .retrySync:
                return "arrow.clockwise"
            }
        }

        var helpText: String {
            switch self {
            case .retrySync:
                return "Try running the sync again"
            }
        }
    }

    private func detectErrorAction(from error: String) -> ErrorAction? {
        // Network/transient errors - just retry
        if error.contains("connection") || error.contains("timeout") || error.contains("network") {
            return .retrySync
        }

        return nil
    }

    private func handleErrorAction(_ action: ErrorAction) {
        switch action {
        case .retrySync:
            syncManager.triggerManualSync(for: profile)
        }
    }

}

/// Browse folders on an rclone remote and pick one directly, instead of guessing the
/// path layout (which differs by protocol — e.g. SFTP vs SMB rooting on the same NAS).
/// Navigable: tap a folder to descend, use the breadcrumb to go back, "Use This Folder"
/// to select the current path. Lists via `rclone lsf --dirs-only` so names with spaces
/// parse correctly (unlike the older whitespace-split parser).
struct RemoteFolderBrowserSheet: View {
    let remoteName: String
    let initialPath: String
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var currentPath: String
    @State private var folders: [String] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    init(remoteName: String, initialPath: String, onSelect: @escaping (String) -> Void) {
        self.remoteName = remoteName
        self.initialPath = initialPath
        self.onSelect = onSelect
        _currentPath = State(initialValue: initialPath.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")))
    }

    private var bareRemote: String {
        remoteName.hasSuffix(":") ? String(remoteName.dropLast()) : remoteName
    }

    private var displayPath: String {
        currentPath.isEmpty ? "\(bareRemote): (root)" : "\(bareRemote):\(currentPath)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Browse \(bareRemote)").font(.headline)
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
            }

            // Breadcrumb
            HStack(spacing: 4) {
                Button("Root") { currentPath = ""; loadFolders() }.buttonStyle(.link)
                let parts = currentPath.split(separator: "/").map(String.init)
                ForEach(Array(parts.enumerated()), id: \.offset) { idx, part in
                    Text("/").foregroundStyle(.secondary)
                    Button(part) {
                        currentPath = parts[0...idx].joined(separator: "/")
                        loadFolders()
                    }.buttonStyle(.link)
                }
                Spacer()
            }
            .font(.caption)
            .lineLimit(1)

            Divider()

            // Folder list
            Group {
                if let err = errorMessage {
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(err).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if folders.isEmpty && !isLoading {
                    Text("No subfolders here — use this folder, or go back.")
                        .font(.caption).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(folders, id: \.self) { folder in
                                Button(action: {
                                    currentPath = currentPath.isEmpty ? folder : "\(currentPath)/\(folder)"
                                    loadFolders()
                                }) {
                                    HStack {
                                        Image(systemName: "folder.fill").foregroundStyle(.blue)
                                        Text(folder).lineLimit(1)
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.vertical, 4).padding(.horizontal, 6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Text(displayPath).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Button("Use This Folder") {
                    onSelect(currentPath)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(currentPath.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 440, height: 480)
        .onAppear { loadFolders() }
    }

    private func loadFolders() {
        guard !bareRemote.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        folders = []
        let remote = bareRemote
        let path = currentPath
        DispatchQueue.global(qos: .userInitiated).async {
            guard let rclone = RcloneLocator.resolve() else {
                DispatchQueue.main.async { self.isLoading = false; self.errorMessage = "rclone not found" }
                return
            }
            var keychainError = ""
            guard let environment = RcloneConfigService.shared.processEnvironment(
                forRemote: remote, log: { keychainError = $0 }) else {
                DispatchQueue.main.async { self.isLoading = false; self.errorMessage = keychainError }
                return
            }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: rclone)
            proc.environment = environment
            let skipCert = RcloneConfigService.shared.readRemoteConfig(name: remote)?.values["no_check_certificate"] == "true"
            var args = ["lsf", "\(remote):\(path)", "--dirs-only", "--contimeout", "5s", "--timeout", "15s"]
            if skipCert { args.append("--no-check-certificate") }
            proc.arguments = args
            let pipe = Pipe(); let errPipe = Pipe()
            proc.standardOutput = pipe; proc.standardError = errPipe
            do {
                try proc.run()
                proc.waitUntilExit()
                let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if proc.terminationStatus != 0 {
                    let e = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    DispatchQueue.main.async {
                        self.isLoading = false
                        self.errorMessage = e.contains("directory not found")
                            ? "This folder doesn't exist on the remote."
                            : (e.isEmpty ? "Couldn't list folders (remote unreachable?)." : e)
                    }
                    return
                }
                let dirs = out.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
                    .sorted()
                DispatchQueue.main.async { self.folders = dirs; self.isLoading = false }
            } catch {
                DispatchQueue.main.async { self.isLoading = false; self.errorMessage = error.localizedDescription }
            }
        }
    }
}
