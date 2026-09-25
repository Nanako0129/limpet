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
    @State private var isRunningResync: Bool = false
    @State private var resyncOutputLines: [String] = []  // Circular buffer for output
    @State private var showResyncOutput: Bool = false

    // Maximum lines to keep in output buffer (prevents memory issues with large syncs)
    private let maxOutputLines = 100
    @State private var useTextInputForFolder: Bool = false
    @State private var remotesError: String?
    @State private var availableFolders: [String] = []
    @State private var isLoadingFolders: Bool = false
    @State private var foldersError: String?

    // File monitoring for resumed syncs
    @State private var logFileMonitor: DispatchSourceFileSystemObject?
    @State private var logFileDescriptor: Int32 = -1

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

    /// Check if a sync is currently running for this profile (via any method)
    private var isSyncRunningForProfile: Bool {
        // Local resync started by this view
        if isRunningResync { return true }

        // SyncManager detected sync (includes external monitoring via lock file)
        if syncManager.state(for: profile.id) == .syncing { return true }

        return false
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
            checkForRunningInitialSync()
        }
        .onDisappear {
            stopLogFileMonitor()
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
                if isRunningResync {
                    // Local resync in progress (runs directly, not via launchd)
                    Label("Syncing", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundColor(.blue)
                } else if isInstalled {
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
            if isRunningResync || syncManager.state(for: profile.id) == .syncing {
                HStack {
                    if let progress = syncManager.profileProgress[profile.id] {
                        SyncProgressDetailView(progress: progress)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(isRunningResync ? "Starting initial sync..." : "Starting sync...")
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

            // Last sync error from rclone (hide during active resync operations)
            if isInstalled, !isRunningResync, let lastError = syncManager.lastError(for: profile.id) {
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

            // Show resync output if available (hide when detailed progress is shown)
            if showResyncOutput && !resyncOutputLines.isEmpty && syncManager.profileProgress[profile.id] == nil {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Sync output:")
                            .font(.caption.weight(.medium))
                        Spacer()
                        Text("\(resyncOutputLines.count) lines")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        // Open log file button
                        Button(action: {
                            let logPath = profile.logPath
                            if FileManager.default.fileExists(atPath: logPath) {
                                NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
                            } else {
                                // Fallback to regular log if initial log was cleaned up
                                NSWorkspace.shared.open(URL(fileURLWithPath: profile.logPath))
                            }
                        }) {
                            Image(systemName: "doc.text")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Open log file")
                        Button(action: { showResyncOutput = false }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Close output panel")
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(resyncOutputLines.enumerated()), id: \.offset) { index, line in
                                    Text(line)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(index)
                                }
                            }
                            .padding(8)
                            .textSelection(.enabled)
                        }
                        .frame(maxHeight: 200)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(4)
                        .onChange(of: resyncOutputLines.count) { _ in
                            // Auto-scroll to bottom when new content arrives
                            if let lastIndex = resyncOutputLines.indices.last {
                                withAnimation(.easeOut(duration: 0.1)) {
                                    proxy.scrollTo(lastIndex, anchor: .bottom)
                                }
                            }
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
                        // Clean up stale lock file if exists but process not running
                        let lockPath = profile.lockFilePath
                        if FileManager.default.fileExists(atPath: lockPath) {
                            try? FileManager.default.removeItem(atPath: lockPath)
                        }
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
                Text("Extra flags to pass to the rclone sync command")
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
            let remoteName = rcloneRemote.replacingOccurrences(of: ":", with: "")
            let skipCert = RcloneConfigService.shared.readRemoteConfig(name: remoteName)?.values["no_check_certificate"] == "true"
            var args = ["lsd", "\(rcloneRemote):"]
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
                // 1. Install script, config, and launchd plist (DO NOT load agent yet)
                // We always defer loading so LogWatcher is set up first
                try setupService.install(profile: currentProfile, loadAgent: false)

                // 2. Initialize paths (create dir and check files)
                if let error = setupService.initializeSyncPaths(for: currentProfile) {
                    DispatchQueue.main.async {
                        isInstalling = false
                        installError = error
                    }
                    return
                }

                DispatchQueue.main.async {
                    // 3. Update profile and refresh settings FIRST (creates LogWatcher)
                    // This ensures LogWatcher is watching BEFORE the agent starts
                    var enabledProfile = currentProfile
                    enabledProfile.isEnabled = true
                    profileStore.update(enabledProfile)
                    syncManager.refreshSettings()  // LogWatcher now ready

                    // 4. Run the first sync now (with visible output), then load the
                    // agent for scheduled runs. runResync handles clearing
                    // isInstalling and loading the agent on completion.
                    runResync(loadAgentOnCompletion: true)
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

    private func runResync(loadAgentOnCompletion: Bool = false) {
        // Clear installing state so resync output panel is visible
        isInstalling = false
        isRunningResync = true
        resyncOutputLines = ["Starting initial sync..."]  // Clear and start fresh
        showResyncOutput = true

        // Clear any cached error and set syncing state (updates menu bar icon)
        syncManager.clearError(for: profile.id)
        syncManager.setSyncing(for: profile.id, isSyncing: true)

        // Automatically mute notifications for initial sync (resync)
        // This prevents notification spam when many files are being synced for the first time
        syncManager.muteNotifications(for: profile.id)

        // Capture all values from main thread before going to background
        let currentProfile = profile
        let capturedRcloneRemote = rcloneRemote
        let capturedRemotePath = remotePath
        let capturedLocalSyncPath = localSyncPath
        let capturedAdditionalFlags = additionalRcloneFlags
        let capturedFilterPath = profile.filterFilePath  // Exclude filter file
        let capturedLockPath = profile.lockFilePath  // Lock file to prevent concurrent scheduled syncs
        let capturedMaxLines = maxOutputLines
        let syncLogPath = profile.logPath  // Use main log file (same as scheduled syncs)
        let capturedSyncDirection = syncDirection

        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default

            // Ensure log directory exists (append to existing log, don't truncate)
            let logDir = (syncLogPath as NSString).deletingLastPathComponent
            try? fileManager.createDirectory(atPath: logDir, withIntermediateDirectories: true)

            // Create file if it doesn't exist
            if !fileManager.fileExists(atPath: syncLogPath) {
                fileManager.createFile(atPath: syncLogPath, contents: nil)
            }

            // Helper to write to log file (appends)
            let writeToLog: (String) -> Void = { content in
                if let data = (content + "\n").data(using: .utf8),
                   let handle = FileHandle(forWritingAtPath: syncLogPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            }

            // Track bytes written for periodic truncation
            var bytesWritten: Int64 = 0
            var lastTruncateTime = Date()
            let maxLogSize: Int64 = 10_000_000  // ~10MB (increased to reduce truncation frequency)
            let truncateInterval: TimeInterval = 30

            let process = Process()
            let pipe = Pipe()
            let errorPipe = Pipe()

            // Find rclone
            let rclonePath = RcloneLocator.resolve()

            guard let path = rclonePath else {
                let errMsg = "Error: rclone not found. Install with: brew install rclone"
                writeToLog(errMsg)
                try? fileManager.removeItem(atPath: syncLogPath)
                DispatchQueue.main.async {
                    self.isRunningResync = false
                    self.resyncOutputLines = [errMsg]
                    self.syncManager.setSyncing(for: currentProfile.id, isSyncing: false)
                }
                return
            }

            // Build the sync command — direction determines source/destination
            let fullRemotePath = "\(capturedRcloneRemote):\(capturedRemotePath)"
            var arguments: [String]

            if capturedSyncDirection == .localToRemote {
                // Upload: local is source, remote is destination
                arguments = ["sync", capturedLocalSyncPath, fullRemotePath, "--verbose", "--use-json-log", "--stats", "2s"]
            } else {
                // Download: remote is source, local is destination
                arguments = ["sync", fullRemotePath, capturedLocalSyncPath, "--verbose", "--use-json-log", "--stats", "2s"]
            }

            // Add filter file if it exists (excludes ._* files, .DS_Store, etc.)
            if fileManager.fileExists(atPath: capturedFilterPath) {
                arguments.append(contentsOf: ["--filter-from", capturedFilterPath])
            }

            // Add --no-check-certificate if configured for this remote
            if RcloneConfigService.shared.readRemoteConfig(name: capturedRcloneRemote)?.values["no_check_certificate"] == "true" {
                arguments.append("--no-check-certificate")
            }

            // Add any additional flags from profile
            if !capturedAdditionalFlags.isEmpty {
                let extraFlags = capturedAdditionalFlags.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                arguments.append(contentsOf: extraFlags)
            }

            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = errorPipe

            let cmdLine = "Running: rclone \(arguments.joined(separator: " "))"
            writeToLog(cmdLine)
            DispatchQueue.main.async {
                self.resyncOutputLines = [cmdLine, ""]
            }

            do {
                try process.run()

                // Create lock file with process PID to prevent concurrent scheduled syncs
                let pid = process.processIdentifier
                try? "\(pid)".write(toFile: capturedLockPath, atomically: true, encoding: .utf8)

                // Read output in batches to reduce UI updates and lag
                let outputHandle = pipe.fileHandleForReading
                let errorHandle = errorPipe.fileHandleForReading
                var outputBuffer = ""
                var lastUpdateTime = Date()
                let updateInterval: TimeInterval = 2.0  // Update UI every 2 seconds (reduced from 0.5s)
                let bufferLock = NSLock()

                let flushBuffer = {
                    bufferLock.lock()
                    let lines = outputBuffer.components(separatedBy: "\n").filter { !$0.isEmpty }
                    let rawContent = outputBuffer
                    outputBuffer = ""
                    bufferLock.unlock()

                    if !lines.isEmpty {
                        // Write to log file (append raw content)
                        if let data = rawContent.data(using: .utf8),
                           let handle = FileHandle(forWritingAtPath: syncLogPath) {
                            handle.seekToEndOfFile()
                            handle.write(data)
                            bytesWritten += Int64(data.count)
                            handle.closeFile()
                        }

                        // Periodically truncate log file if it's getting too large
                        let now = Date()
                        if bytesWritten > maxLogSize && now.timeIntervalSince(lastTruncateTime) > truncateInterval {
                            if let content = try? String(contentsOfFile: syncLogPath, encoding: .utf8) {
                                let logLines = content.components(separatedBy: "\n")
                                let truncated = logLines.suffix(100000).joined(separator: "\n")
                                // Use non-atomic write to preserve inode (prevents LogWatcher from losing track)
                                try? truncated.write(toFile: syncLogPath, atomically: false, encoding: .utf8)
                            }
                            bytesWritten = 0
                            lastTruncateTime = now
                        }

                        DispatchQueue.main.async {
                            // Circular buffer: append new lines, keep only last maxOutputLines
                            self.resyncOutputLines.append(contentsOf: lines)
                            if self.resyncOutputLines.count > capturedMaxLines {
                                self.resyncOutputLines.removeFirst(self.resyncOutputLines.count - capturedMaxLines)
                            }
                        }
                    }
                }

                outputHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                        bufferLock.lock()
                        outputBuffer += str
                        let now = Date()
                        let shouldFlush = now.timeIntervalSince(lastUpdateTime) >= updateInterval
                        if shouldFlush { lastUpdateTime = now }
                        bufferLock.unlock()

                        if shouldFlush { flushBuffer() }
                    }
                }

                errorHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                        bufferLock.lock()
                        outputBuffer += str
                        let now = Date()
                        let shouldFlush = now.timeIntervalSince(lastUpdateTime) >= updateInterval
                        if shouldFlush { lastUpdateTime = now }
                        bufferLock.unlock()

                        if shouldFlush { flushBuffer() }
                    }
                }

                process.waitUntilExit()

                // Remove lock file now that process has finished
                try? fileManager.removeItem(atPath: capturedLockPath)

                outputHandle.readabilityHandler = nil
                errorHandle.readabilityHandler = nil

                // Flush any remaining buffered output
                flushBuffer()

                // Read any remaining data
                let remainingOutput = outputHandle.readDataToEndOfFile()
                let remainingError = errorHandle.readDataToEndOfFile()

                DispatchQueue.main.async {
                    if let str = String(data: remainingOutput, encoding: .utf8), !str.isEmpty {
                        let lines = str.components(separatedBy: "\n").filter { !$0.isEmpty }
                        self.resyncOutputLines.append(contentsOf: lines)
                        if self.resyncOutputLines.count > capturedMaxLines {
                            self.resyncOutputLines.removeFirst(self.resyncOutputLines.count - capturedMaxLines)
                        }
                    }
                    if let str = String(data: remainingError, encoding: .utf8), !str.isEmpty {
                        let lines = str.components(separatedBy: "\n").filter { !$0.isEmpty }
                        self.resyncOutputLines.append(contentsOf: lines)
                        if self.resyncOutputLines.count > capturedMaxLines {
                            self.resyncOutputLines.removeFirst(self.resyncOutputLines.count - capturedMaxLines)
                        }
                    }

                    let exitCode = process.terminationStatus
                    if exitCode == 0 {
                        self.appendOutputLine("")
                        self.appendOutputLine("✓ Resync completed successfully!")

                        // Load the launchd agent now that resync is complete
                        // Note: We don't trigger a follow-up sync here because rclone's
                        // "all files changed" safety check will fail it anyway. The scheduled
                        // sync will handle this naturally - the first few syncs may fail with
                        // this transient error, but subsequent syncs will work once the
                        // listing files stabilize.
                        if loadAgentOnCompletion {
                            self.setupService.loadAgent(for: currentProfile)
                            self.appendOutputLine("✓ Scheduled sync is now active.")
                        }

                        // Clear any errors and set to idle - resync was successful
                        self.syncManager.clearError(for: currentProfile.id)
                        self.syncManager.setSyncing(for: currentProfile.id, isSyncing: false)
                        self.syncManager.refreshSettings()
                    } else {
                        self.appendOutputLine("")
                        self.appendOutputLine("✗ Resync failed with exit code \(exitCode)")

                        // Still load the agent even on failure so scheduled syncs can retry
                        if loadAgentOnCompletion {
                            self.setupService.loadAgent(for: currentProfile)
                        }

                        // Clear syncing state (will show error from log if any)
                        self.syncManager.setSyncing(for: currentProfile.id, isSyncing: false)
                    }

                    self.isRunningResync = false
                }
            } catch {
                let errMsg = "Error running rclone: \(error.localizedDescription)"
                writeToLog(errMsg)
                DispatchQueue.main.async {
                    self.appendOutputLine(errMsg)
                    self.syncManager.setSyncing(for: currentProfile.id, isSyncing: false)
                    self.isRunningResync = false
                }
            }
        }
    }

    /// Helper to append a single line to the output buffer with circular buffer logic
    private func appendOutputLine(_ line: String) {
        resyncOutputLines.append(line)
        if resyncOutputLines.count > maxOutputLines {
            resyncOutputLines.removeFirst(resyncOutputLines.count - maxOutputLines)
        }
    }

    /// Helper to append multiple lines to the output buffer with circular buffer logic
    private func appendOutputLines(_ lines: [String]) {
        resyncOutputLines.append(contentsOf: lines)
        if resyncOutputLines.count > maxOutputLines {
            resyncOutputLines.removeFirst(resyncOutputLines.count - maxOutputLines)
        }
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

    // MARK: - Initial Sync Resume Support

    /// Check if there's a running initial sync that we should resume monitoring
    /// Note: SyncManager handles detection and state management via lock file.
    /// This method handles the log tailing UI for initial syncs started by this view.
    private func checkForRunningInitialSync() {
        let syncLogPath = profile.logPath

        // Check if initial log exists (indicates an initial sync was started by this view)
        guard FileManager.default.fileExists(atPath: syncLogPath) else { return }

        // Check if SyncManager detected a running sync for this profile
        // SyncManager uses lock file detection which is more reliable than pgrep
        guard syncManager.state(for: profile.id) == .syncing else {
            // No running sync - clean up stale log file
            try? FileManager.default.removeItem(atPath: syncLogPath)
            return
        }

        // Resume showing the output panel for the initial sync
        isRunningResync = true
        showResyncOutput = true

        // Load existing content and start tailing
        startTailingLogFile(at: syncLogPath)
    }

    /// Start tailing a log file for resumed sync monitoring
    private func startTailingLogFile(at path: String) {
        // Read existing content
        if let existingContent = try? String(contentsOfFile: path, encoding: .utf8) {
            let lines = existingContent.components(separatedBy: "\n").filter { !$0.isEmpty }
            resyncOutputLines = Array(lines.suffix(maxOutputLines))
        }

        // Open file for monitoring
        logFileDescriptor = open(path, O_RDONLY)
        guard logFileDescriptor >= 0 else { return }

        // Seek to end of file so we only get new content
        lseek(logFileDescriptor, 0, SEEK_END)

        // Create dispatch source for file changes
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: logFileDescriptor,
            eventMask: [.write, .extend],
            queue: DispatchQueue.global(qos: .userInitiated)
        )

        // Capture the file descriptor for the closures
        let fd = logFileDescriptor

        source.setEventHandler {
            // Read new content
            var buffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = read(fd, &buffer, buffer.count)

            if bytesRead > 0 {
                if let newContent = String(bytes: buffer[0..<bytesRead], encoding: .utf8) {
                    let lines = newContent.components(separatedBy: "\n").filter { !$0.isEmpty }
                    if !lines.isEmpty {
                        DispatchQueue.main.async { [self] in
                            self.appendOutputLines(lines)
                        }
                    }
                }
            }
        }

        source.setCancelHandler {
            if fd >= 0 {
                close(fd)
            }
        }

        logFileMonitor = source
        source.resume()

        // Also start a timer to check if rclone is still running
        startSyncCompletionMonitor()
    }

    /// Monitor for sync completion (when sync process exits)
    /// Uses lock file check which is more reliable than pgrep
    private func startSyncCompletionMonitor() {
        // Capture needed values for background check
        let lockPath = profile.lockFilePath

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 5) { [self] in
            // Check if sync is still running via lock file
            let isRunning = self.checkSyncRunningViaLockFile(at: lockPath)

            if !isRunning {
                DispatchQueue.main.async {
                    self.handleResumedSyncCompletion()
                }
            } else {
                // Keep checking
                self.startSyncCompletionMonitor()
            }
        }
    }

    /// Check if sync is running via lock file (can be called from background)
    private func checkSyncRunningViaLockFile(at lockPath: String) -> Bool {
        guard FileManager.default.fileExists(atPath: lockPath),
              let pidStr = try? String(contentsOfFile: lockPath, encoding: .utf8)
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(pidStr) else {
            return false
        }
        // Check if process is still running
        return kill(pid, 0) == 0
    }

    /// Handle completion of a resumed sync
    private func handleResumedSyncCompletion() {
        stopLogFileMonitor()

        // Update state
        appendOutputLine("")
        appendOutputLine("✓ Sync completed")

        isRunningResync = false
        syncManager.setSyncing(for: profile.id, isSyncing: false)
        syncManager.refreshSettings()
    }

    /// Stop the log file monitor
    private func stopLogFileMonitor() {
        logFileMonitor?.cancel()
        logFileMonitor = nil
    }

    /// Write content to the initial sync log file
    private func writeToInitialLog(_ content: String) {
        let logPath = profile.logPath
        let fileManager = FileManager.default

        // Create log directory if needed
        let logDir = (logPath as NSString).deletingLastPathComponent
        if !fileManager.fileExists(atPath: logDir) {
            try? fileManager.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        }

        // Append to log file
        if let data = content.data(using: .utf8) {
            if fileManager.fileExists(atPath: logPath) {
                if let handle = FileHandle(forWritingAtPath: logPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                fileManager.createFile(atPath: logPath, contents: data)
            }
        }
    }

    /// Truncate log file to keep only the last N lines (prevents unbounded growth)
    private func truncateInitialLogIfNeeded() {
        let logPath = profile.logPath
        let maxLogLines = 100000  // ~10MB of text (increased to reduce truncation frequency)

        guard let content = try? String(contentsOfFile: logPath, encoding: .utf8) else { return }
        let lines = content.components(separatedBy: "\n")

        if lines.count > maxLogLines {
            let truncated = lines.suffix(maxLogLines).joined(separator: "\n")
            // Use non-atomic write to preserve inode (prevents LogWatcher from losing track)
            try? truncated.write(toFile: logPath, atomically: false, encoding: .utf8)
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
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: rclone)
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
