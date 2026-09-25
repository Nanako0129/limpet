import Foundation

/// The direction for one-way sync mode
enum SyncDirection: String, Codable, CaseIterable, Identifiable {
    /// Local folder is source, remote is destination (upload/backup)
    case localToRemote = "localToRemote"

    /// Remote is source, local folder is destination (download/mirror)
    case remoteToLocal = "remoteToLocal"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .localToRemote:
            return "Local → Remote"
        case .remoteToLocal:
            return "Remote → Local"
        }
    }

    var description: String {
        switch self {
        case .localToRemote:
            return "Upload local changes to remote (backup)"
        case .remoteToLocal:
            return "Download remote to local (mirror)"
        }
    }

    var iconName: String {
        switch self {
        case .localToRemote:
            return "arrow.up.to.line"
        case .remoteToLocal:
            return "arrow.down.to.line"
        }
    }
}
