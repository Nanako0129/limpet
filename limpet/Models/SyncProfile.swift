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
    var transfers: Int                  // rclone --transfers (checkers = 2x this); default: 16

    /// Short ID for file naming (first 8 chars of UUID)
    var shortId: String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    // MARK: - Computed Paths

    /// Shared script path (single script for all profiles)
    static var sharedScriptPath: String {
        "\(NSHomeDirectory())/.local/bin/limpet-sync.sh"
    }

    /// Profile config directory
    static var configDirectory: String {
        "\(NSHomeDirectory())/.config/limpet/profiles"
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
        "\(NSHomeDirectory())/Library/LaunchAgents/com.nanako.limpet.watch.\(shortId).plist"
    }

    /// Profile-specific log file
    var logPath: String {
        "\(NSHomeDirectory())/.local/log/limpet-sync-\(shortId).log"
    }

    /// Profile-specific exclude filter file
    var filterFilePath: String {
        "\(Self.configDirectory)/\(shortId)-exclude.txt"
    }

    var launchdLabel: String {
        "com.nanako.limpet.watch.\(shortId)"
    }

    var lockFilePath: String {
        "/tmp/limpet-sync-\(shortId).lock"
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

    // MARK: - Validation

    var isValid: Bool {
        !name.isEmpty && !rcloneRemote.isEmpty && !remotePath.isEmpty && !localSyncPath.isEmpty
    }

    /// F4 (limpet-plan.md L4): an rclone remote spec starting with `:` is an
    /// on-the-fly backend, and a `,` or `=` is a connection-string parameter.
    /// Either can carry a credential in plain text, so neither may ever land
    /// in profile JSON, a derived config or a log. The message never echoes
    /// the value, since the value may be exactly that credential.
    static func remoteSpecError(_ remote: String) -> String? {
        guard remote.hasPrefix(":") || remote.contains(",") || remote.contains("=") else { return nil }
        return "rcloneRemote must name a configured rclone remote; on-the-fly backends (leading ':') "
            + "and connection strings (',' or '=') are refused because they can carry credentials in plain text"
    }

    /// Field-level refusal shared by every seam a profile crosses: decode,
    /// every profile write, `SyncSetupService.install` and the watcher before
    /// each run. `nil` means acceptable.
    var validationError: String? {
        Self.remoteSpecError(rcloneRemote)
    }

    /// F6 (limpet-plan.md L4): two profiles syncing equal or nested paths on
    /// the same remote delete each other's files (each one's `rclone sync`
    /// removes what only the other one uploaded). Remote names compare
    /// case-insensitively (a false match only refuses, it never deletes);
    /// paths compare by `/`-separated components, so `a/b`, `a/b/` and `a//b`
    /// are the same path and `a/bc` does not nest under `a/b`.
    static func overlapError(_ profile: SyncProfile, among others: [SyncProfile]) -> String? {
        let mine = profile.remoteLocation
        for other in others where other.id != profile.id {
            let theirs = other.remoteLocation
            guard mine.remote == theirs.remote,
                  mine.components.starts(with: theirs.components)
                    || theirs.components.starts(with: mine.components) else { continue }
            return "remote path \(profile.fullRemotePath) overlaps profile \"\(other.name)\" (\(other.shortId)) "
                + "at \(other.fullRemotePath); two syncs on equal or nested remote paths delete each other's files"
        }
        return nil
    }

    private var remoteLocation: (remote: String, components: [Substring]) {
        let name = rcloneRemote.hasSuffix(":") ? String(rcloneRemote.dropLast()) : rcloneRemote
        return (name.lowercased(), remotePath.split(separator: "/"))
    }

    // MARK: - Local Directory Inspection

    /// Counts items in a local directory that a user would recognise as "their files",
    /// ignoring limpet's own state folder and pure macOS metadata noise.
    ///
    /// Used to warn before pointing a sync at a folder that already has content: on the
    /// first sync limpet merges the local folder with the remote, which can produce
    /// duplicates, unexpected overwrites, or hard-to-undo deletions.
    static func meaningfulItemCount(at path: String) -> Int {
        guard !path.isEmpty else { return 0 }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return 0 }
        guard let contents = try? fm.contentsOfDirectory(atPath: path) else { return 0 }

        let ignored: Set<String> = [".DS_Store", ".localized"]
        return contents.filter { name in
            !name.hasPrefix(".limpet") && !ignored.contains(name)
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
        transfers: Int = 16
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
        self.transfers = transfers
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
        case isEnabled, isMuted, syncDirection, transfers
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
        // Backwards compatibility: default to 16 if not present.
        transfers = try container.decodeIfPresent(Int.self, forKey: .transfers) ?? 16

        // F4: a refused value never becomes a SyncProfile, so it can never be
        // written back out, installed, or run by a watcher.
        if let error = validationError {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: [], debugDescription: error))
        }
    }
}

// MARK: - Hashable

extension SyncProfile: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
