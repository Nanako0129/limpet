import Foundation

/// A sync profile representing a single rclone remote/target configuration
struct SyncProfile: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String                    // Display name (e.g., "Work", "Personal")
    var rcloneRemote: String            // e.g., "synology-kaiju:"
    var remotePath: String              // e.g., "Kaiju"
    var localSyncPath: String           // e.g., "/Volumes/SeagateHD/Kaiju"
    var drivePathToMonitor: String      // e.g., "/Volumes/SeagateHD" (empty if not external)
    var syncIntervalMinutes: Int        // default: 15
    var additionalRcloneFlags: String   // optional extra flags
    var isEnabled: Bool                 // whether scheduled sync is active
    var isMuted: Bool                   // whether notifications are muted for this profile
    var syncDirection: SyncDirection    // direction for one-way sync

    // Fallback remote (used when primary remote is unreachable)
    var fallbackRemote: String          // e.g., "synology-sftp" (empty = no fallback)
    var fallbackRemotePath: String      // e.g., "/volume1/Kaiju" (empty = same as primary remotePath)
    /// True when primary and fallback remotes use different rclone wire types (e.g. smb vs sftp).
    /// When true, the sync script swaps the full REMOTE reference on fallback activation instead of
    /// using env-var overrides, to avoid NFD/NFC filename-encoding divergence between wire types.
    /// Populated at install/save time. Defaults to false for profiles created before this field existed.
    var fallbackRequiresCacheRebuild: Bool

    /// Short ID for file naming (first 8 chars of UUID)
    var shortId: String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    // MARK: - Computed Paths

    /// Shared script path (single script for all profiles)
    static var sharedScriptPath: String {
        "\(NSHomeDirectory())/.local/bin/synctray-sync.sh"
    }

    /// Profile config directory
    static var configDirectory: String {
        "\(NSHomeDirectory())/.config/synctray/profiles"
    }

    /// Profile-specific config file (JSON)
    var configPath: String {
        "\(Self.configDirectory)/\(shortId).json"
    }

    /// NEW authoritative per-profile file carrying the FULL `SyncProfile`
    /// (including fields the derived `configPath` JSON omits: `isEnabled`,
    /// `isMuted`). This is the external-agent-editable
    /// surface; `configPath` remains the derived, frozen subset the sync
    /// script reads and stays byte-for-byte unchanged.
    var profileFilePath: String {
        "\(Self.configDirectory)/\(shortId).profile.json"
    }

    /// Profile-specific launchd plist
    var plistPath: String {
        "\(NSHomeDirectory())/Library/LaunchAgents/com.synctray.sync.\(shortId).plist"
    }

    /// Profile-specific log file
    var logPath: String {
        "\(NSHomeDirectory())/.local/log/synctray-sync-\(shortId).log"
    }

    /// Profile-specific exclude filter file
    var filterFilePath: String {
        "\(Self.configDirectory)/\(shortId)-exclude.txt"
    }

    var launchdLabel: String {
        "com.synctray.sync.\(shortId)"
    }

    var lockFilePath: String {
        "/tmp/synctray-sync-\(shortId).lock"
    }

    // MARK: - Full Remote Path

    /// Full remote path for rclone (e.g., "synology-kaiju:Kaiju")
    var fullRemotePath: String {
        if remotePath.isEmpty {
            return rcloneRemote.hasSuffix(":") ? rcloneRemote : "\(rcloneRemote):"
        }
        let remote = rcloneRemote.hasSuffix(":") ? String(rcloneRemote.dropLast()) : rcloneRemote
        return "\(remote):\(remotePath)"
    }

    // MARK: - Fallback

    /// Whether a fallback remote is configured
    var hasFallback: Bool {
        !fallbackRemote.isEmpty
    }

    /// Full fallback remote path for rclone (e.g., "synology-sftp:/volume1/Kaiju")
    var fullFallbackRemotePath: String {
        let path = fallbackRemotePath.isEmpty ? remotePath : fallbackRemotePath
        let remote = fallbackRemote.hasSuffix(":") ? String(fallbackRemote.dropLast()) : fallbackRemote
        if path.isEmpty {
            return "\(remote):"
        }
        return "\(remote):\(path)"
    }

    // MARK: - Validation

    var isValid: Bool {
        !name.isEmpty && !rcloneRemote.isEmpty && !remotePath.isEmpty && !localSyncPath.isEmpty
    }

    // MARK: - Local Directory Inspection

    /// Counts items in a local directory that a user would recognise as "their files",
    /// ignoring SyncTray's own state folder and pure macOS metadata noise.
    ///
    /// Used to warn before pointing a sync at a folder that already has content: on the
    /// first sync SyncTray merges the local folder with the remote, which can produce
    /// duplicates, unexpected overwrites, or hard-to-undo deletions.
    static func meaningfulItemCount(at path: String) -> Int {
        guard !path.isEmpty else { return 0 }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return 0 }
        guard let contents = try? fm.contentsOfDirectory(atPath: path) else { return 0 }

        let ignored: Set<String> = [".DS_Store", ".localized"]
        return contents.filter { name in
            !name.hasPrefix(".synctray") && !ignored.contains(name)
        }.count
    }

    // MARK: - Initializers

    init(
        id: UUID = UUID(),
        name: String = "",
        rcloneRemote: String = "",
        remotePath: String = "",
        localSyncPath: String = "",
        drivePathToMonitor: String = "",
        syncIntervalMinutes: Int = 5,
        additionalRcloneFlags: String = "",
        isEnabled: Bool = false,
        isMuted: Bool = false,
        syncDirection: SyncDirection = .localToRemote,
        fallbackRemote: String = "",
        fallbackRemotePath: String = "",
        fallbackRequiresCacheRebuild: Bool = false
    ) {
        self.id = id
        self.name = name
        self.rcloneRemote = rcloneRemote
        self.remotePath = remotePath
        self.localSyncPath = localSyncPath
        self.drivePathToMonitor = drivePathToMonitor
        self.syncIntervalMinutes = syncIntervalMinutes
        self.additionalRcloneFlags = additionalRcloneFlags
        self.isEnabled = isEnabled
        self.isMuted = isMuted
        self.syncDirection = syncDirection
        self.fallbackRemote = fallbackRemote
        self.fallbackRemotePath = fallbackRemotePath
        self.fallbackRequiresCacheRebuild = fallbackRequiresCacheRebuild
    }

    /// Create a new profile with default values
    static func newProfile() -> SyncProfile {
        SyncProfile(name: "New Profile")
    }
}

// MARK: - Codable (backwards compatibility)

extension SyncProfile {
    enum CodingKeys: String, CodingKey {
        case id, name, rcloneRemote, remotePath, localSyncPath
        case drivePathToMonitor, syncIntervalMinutes, additionalRcloneFlags
        case isEnabled, isMuted, syncDirection
        case fallbackRemote, fallbackRemotePath, fallbackRequiresCacheRebuild
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        rcloneRemote = try container.decode(String.self, forKey: .rcloneRemote)
        remotePath = try container.decode(String.self, forKey: .remotePath)
        localSyncPath = try container.decode(String.self, forKey: .localSyncPath)
        // Optional-with-default so an agent (or dropped file) can author a
        // MINIMAL profile — id/name/remote/paths are the only truly-required
        // keys. These three mirror the memberwise-init defaults exactly, so an
        // app-written file (which always emits them) round-trips unchanged.
        drivePathToMonitor = try container.decodeIfPresent(String.self, forKey: .drivePathToMonitor) ?? ""
        syncIntervalMinutes = try container.decodeIfPresent(Int.self, forKey: .syncIntervalMinutes) ?? 5
        additionalRcloneFlags = try container.decodeIfPresent(String.self, forKey: .additionalRcloneFlags) ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        // Backwards compatibility: default to false if not present
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        // Backwards compatibility: default to localToRemote if not present
        syncDirection = try container.decodeIfPresent(SyncDirection.self, forKey: .syncDirection) ?? .localToRemote
        // Backwards compatibility: fallback remote defaults to empty (disabled)
        fallbackRemote = try container.decodeIfPresent(String.self, forKey: .fallbackRemote) ?? ""
        fallbackRemotePath = try container.decodeIfPresent(String.self, forKey: .fallbackRemotePath) ?? ""
        // Backwards compatibility: defaults to false (preserves env-var-override behaviour for old profiles)
        fallbackRequiresCacheRebuild = try container.decodeIfPresent(
            Bool.self, forKey: .fallbackRequiresCacheRebuild) ?? false
    }
}

// MARK: - Hashable

extension SyncProfile: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
