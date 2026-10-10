import Foundation

/// Root of every per-user path limpet writes (LaunchAgents plists, the shim
/// and sync script, ~/.config/limpet, ~/.local/log, rclone.conf). The self-test
/// points it at a temp directory before running anything, so no test can write
/// into the real home: on 2026-09-27 a self-test called the real `install()`
/// and left eight plists in ~/Library/LaunchAgents and rewrote the live shim
/// (limpet-plan.md L6.1). `NSHomeDirectory()` ignores `$HOME` (measured), so
/// redirecting the environment is not an option.
enum LimpetPaths {
    nonisolated(unsafe) static var home = NSHomeDirectory()
}

/// Set by `ConfigSelfTest.run()`: while active, a `launchctl` subcommand that
/// changes launchd state is refused and recorded instead of run, and the
/// self-test fails if anything was recorded. `list` and `print` only read.
enum SelfTestGuard {
    nonisolated(unsafe) static var active = false
    nonisolated(unsafe) static var violations: [String] = []

    /// true = do not spawn `executable`.
    static func refuses(_ executable: String, _ arguments: [String]) -> Bool {
        guard active, (executable as NSString).lastPathComponent == "launchctl" else { return false }
        if let sub = arguments.first, sub == "list" || sub == "print" { return false }
        violations.append("launchctl " + arguments.joined(separator: " "))
        return true
    }
}

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
    /// rclone `--max-delete` for this profile when its remote does not keep
    /// deleted versions (limpet-plan.md L4 F6); default 100.
    var maxDelete: Int
    /// The user's statement that the remote keeps deleted versions (bucket
    /// versioning on). Lifts `--max-delete` for AWS/MinIO/Other s3 remotes;
    /// never for MEGA S4 or Cloudflare R2, which have none.
    var remoteVersioning: Bool
    /// Days a deleted/overwritten file is kept under `.limpet-trash` on a
    /// remote that keeps no deleted versions (limpet-plan.md L6.2); 0 = off.
    /// Only takes effect when `syncDirection == .localToRemote`, the remote
    /// keeps no deleted versions, and `remotePath` has a parent — resolved
    /// once, in `SyncSetupService.generateProfileConfig`/`trashRoot(for:remoteSection:)`.
    var trashDays: Int
    /// limpet-plan.md L9.2: sync only the paths FSEvents reported (batches),
    /// with a full run as the safety net, instead of a full diff per change.
    /// Default false; see `incrementalIneligibility`.
    var incrementalSync: Bool

    /// Short ID for file naming (first 8 chars of UUID)
    var shortId: String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    // MARK: - Computed Paths

    /// Shared script path (single script for all profiles)
    static var sharedScriptPath: String {
        "\(LimpetPaths.home)/.local/bin/limpet-sync.sh"
    }

    /// Profile config directory
    static var configDirectory: String {
        "\(LimpetPaths.home)/.config/limpet/profiles"
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
        "\(LimpetPaths.home)/Library/LaunchAgents/com.nanako.limpet.watch.\(shortId).plist"
    }

    /// Profile-specific log file
    var logPath: String {
        "\(LimpetPaths.home)/.local/log/limpet-sync-\(shortId).log"
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

    /// Persistent "delete limit reached" marker (limpet-plan.md L4 F6). Written
    /// by the watcher when a run exits 76 and checked before EVERY run, so a
    /// KeepAlive respawn, a login or a reinstall never syncs again until
    /// `limpet profile clear-delete-limit` or the menu action removes it.
    var deleteLimitMarkerPath: String {
        "\(Self.configDirectory)/\(shortId).delete-limit"
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
        if let error = Self.remoteSpecError(rcloneRemote) { return error }
        if maxDelete < 1 { return "maxDelete must be at least 1" }
        if !(0...365).contains(trashDays) { return "trashDays must be between 0 and 365" }
        // Carried from L4.0: 1–64. A leading zero never survives JSON decoding
        // (measured: JSONDecoder rejects `08` and `010`), and `profile set`
        // refuses one itself, because bash reads `08` as octal.
        if !(1...64).contains(transfers) { return "transfers must be between 1 and 64" }
        return nil
    }

    /// F6 (limpet-plan.md L4): two profiles syncing equal or nested paths on
    /// the same remote delete each other's files (each one's `rclone sync`
    /// removes what only the other one uploaded). Remote names compare
    /// case-insensitively (a false match only refuses, it never deletes);
    /// paths compare by `/`-separated components, so `a/b`, `a/b/` and `a//b`
    /// are the same path and `a/bc` does not nest under `a/b`.
    ///
    /// Only profiles that can sync take part: `profile` itself must be
    /// enabled, and it is compared only with others that are enabled AND have
    /// an installed agent (`isInstalled`). The installed one wins: a second,
    /// overlapping profile that is enabled on disk but was never installed (a
    /// refused create, or a file dropped while the app was closed) cannot
    /// block the running one, and its own install is refused.
    static func overlapError(
        _ profile: SyncProfile, among others: [SyncProfile], isInstalled: (SyncProfile) -> Bool
    ) -> String? {
        guard profile.isEnabled else { return nil }
        let mine = profile.remoteLocation
        for other in others where other.id != profile.id && other.isEnabled && isInstalled(other) {
            let theirs = other.remoteLocation
            guard mine.remote == theirs.remote,
                  mine.components.starts(with: theirs.components)
                    || theirs.components.starts(with: mine.components) else { continue }
            return "remote path \(profile.fullRemotePath) overlaps profile \"\(other.name)\" (\(other.shortId)) "
                + "at \(other.fullRemotePath); two syncs on equal or nested remote paths delete each other's files"
        }
        return nil
    }

    /// Production `isInstalled` for `overlapError`: the agent's plist exists.
    static func agentInstalled(_ profile: SyncProfile) -> Bool {
        FileManager.default.fileExists(atPath: profile.plistPath)
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
        transfers: Int = 16,
        maxDelete: Int = 100,
        remoteVersioning: Bool = false,
        trashDays: Int = 14,
        incrementalSync: Bool = false
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
        self.maxDelete = maxDelete
        self.remoteVersioning = remoteVersioning
        self.trashDays = trashDays
        self.incrementalSync = incrementalSync
    }

    /// Flags a batch must not run with: include rules or a file list widen or
    /// replace the batch's own `- **`; --delete-excluded would delete everything
    /// outside it; age filters, --hash-filter and --exclude-if-present change a
    /// path's verdict without any FSEvent; --local-encoding and
    /// --local-unicode-normalization change the names rclone filters on;
    /// --error-on-no-transfer fails every no-op batch; a bare `--` would turn the
    /// batch's own trailing flags into arguments; the log flags would take
    /// rclone's JSON error lines out of the profile log the watcher classifies. A single-dash token whose
    /// letters include `f` (`-f`, `-vf…`) is the short --filter. The generated
    /// script refuses a batch carrying any of them as well (same list).
    static let batchRefusedFlags: Set<String> = [
        "--include", "--include-from", "--filter", "--filter-from", "--files-from",
        "--files-from-raw", "--files-from0", "--delete-excluded", "--min-age", "--max-age",
        "--hash-filter", "--exclude-if-present", "--local-encoding",
        "--local-unicode-normalization", "--error-on-no-transfer", "--",
        "--log-file", "--log-level", "--use-json-log", "--syslog", "--log-systemd",
    ]

    /// The RCLONE_<FLAG> environment variables for `batchRefusedFlags` (rclone
    /// reads any flag from one), plus RCLONE_CONFIG_LOCAL_<OPT> for the two
    /// local-backend options (measured, rclone 1.75.1: they rename files too).
    /// The script and `refusedEnvironmentVariable` apply the same rule to them.
    static var batchRefusedEnvironment: [String] {
        batchRefusedFlags.subtracting(["--"]).sorted()
            .map { "RCLONE_" + $0.dropFirst(2).uppercased().replacingOccurrences(of: "-", with: "_") }
            + ["RCLONE_CONFIG_LOCAL_ENCODING", "RCLONE_CONFIG_LOCAL_UNICODE_NORMALIZATION"]
    }

    /// The first of `batchRefusedEnvironment` set in `environment` (empty
    /// included: the variable is there), except RCLONE_DELETE_EXCLUDED=false —
    /// the one value the flag check passes too (`--delete-excluded=false`).
    /// nil = batches may run. The generated script applies the same rule.
    static func refusedEnvironmentVariable(in environment: [String: String]) -> String? {
        batchRefusedEnvironment.first { name in
            guard let value = environment[name] else { return false }
            return !(name == "RCLONE_DELETE_EXCLUDED" && value == "false")
        }
    }

    /// Whether one additionalRcloneFlags token makes a batch unsafe. A single
    /// dash is judged on the raw token (a value such as `_drafts/**` is no
    /// flag); a long flag on its name with `_` read as `-`, as rclone does.
    static func refusesBatch(_ token: String) -> Bool {
        let raw = String(token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        if raw.hasPrefix("-") && !raw.hasPrefix("--") { return raw.dropFirst().contains("f") }
        let name = raw.replacingOccurrences(of: "_", with: "-")
        if name == "--delete-excluded" { return !token.hasSuffix("=false") }
        return batchRefusedFlags.contains(name)
    }

    /// Why this profile must use full syncs although `incrementalSync` is on,
    /// or nil when batches may run (limpet-plan.md L9.2 S2). A batch adds its
    /// own `--filter-from` after the profile's rules and ends in `- **`, so a
    /// flag in `batchRefusedFlags` would widen, break or silently skip it. The profile's
    /// exclude file is checked separately (its rclone dump must hold no `+`
    /// rule), because that needs rclone.
    var incrementalIneligibility: String? {
        guard incrementalSync else { return "incrementalSync is off" }
        guard syncDirection == .localToRemote else { return "incremental sync needs localToRemote" }
        for token in additionalRcloneFlags.split(whereSeparator: \.isWhitespace).map(String.init) where Self.refusesBatch(token) {
            return "additionalRcloneFlags \(token) changes what a batch would sync"
        }
        return nil
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
        case maxDelete, remoteVersioning, trashDays, incrementalSync
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
        maxDelete = try container.decodeIfPresent(Int.self, forKey: .maxDelete) ?? 100
        remoteVersioning = try container.decodeIfPresent(Bool.self, forKey: .remoteVersioning) ?? false
        // Backwards compatibility: default 14 (limpet-plan.md L6.2), matching
        // the memberwise-init default so an app-written file round-trips.
        trashDays = try container.decodeIfPresent(Int.self, forKey: .trashDays) ?? 14
        incrementalSync = try container.decodeIfPresent(Bool.self, forKey: .incrementalSync) ?? false

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
