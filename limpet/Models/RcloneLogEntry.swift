import Foundation

struct RcloneLogEntry: Codable {
    let level: String
    let msg: String
    let time: String
    let object: String?
    let objectType: String?
    let stats: RcloneStats?
    let source: String?
    let size: Int?

    enum CodingKeys: String, CodingKey {
        case level, msg, time, object, source, size
        case objectType = "objectType"
        case stats
    }
}

struct RcloneStats: Codable {
    let bytes: Int?
    let checks: Int?
    let deletedDirs: Int?
    let deletes: Int?
    let elapsedTime: Double?
    let errors: Int?
    let eta: Int?
    let fatalError: Bool?
    let renames: Int?
    let retryError: Bool?
    let speed: Double?
    let totalBytes: Int?
    let totalChecks: Int?
    let totalTransfers: Int?
    let transferTime: Double?
    let transfers: Int?

    // Per-file transfer progress (active transfers)
    let transferring: [TransferringFile]?
    // Files currently being checked
    let checking: [String]?
    // Last error message
    let lastError: String?
    // Number of files listed during scan phase
    let listed: Int?
}

/// Per-file transfer progress information from rclone stats
struct TransferringFile: Codable, Identifiable, Equatable {
    let name: String
    let size: Int64?
    let bytes: Int64?
    let percentage: Int?
    let speed: Double?
    let speedAvg: Double?
    let eta: Int?

    var id: String { name }

    /// The filename component of the path
    var fileName: String {
        (name as NSString).lastPathComponent
    }

    /// The directory component of the path
    var directory: String {
        let dir = (name as NSString).deletingLastPathComponent
        return dir.isEmpty ? "/" : dir
    }

    /// Format the progress line for display
    /// Example: "44% /11.2Gi, 4.2Mi/s, 24m51s"
    var formattedProgress: String {
        var parts: [String] = []

        // Percentage
        if let pct = percentage {
            parts.append("\(pct)%")
        }

        // Size (total)
        if let totalSize = size, totalSize > 0 {
            let sizeStr = ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
            parts.append("/\(sizeStr)")
        }

        // Speed
        if let spd = speed ?? speedAvg, spd > 0 {
            let speedStr = ByteCountFormatter.string(fromByteCount: Int64(spd), countStyle: .file)
            parts.append("\(speedStr)/s")
        }

        // ETA
        if let etaSecs = eta, etaSecs > 0 {
            parts.append(SyncFormatters.formatETAWithSeconds(etaSecs))
        }

        return parts.joined(separator: ", ")
    }

    /// Truncate filename to fit in available space
    func truncatedName(maxLength: Int = 40) -> String {
        guard maxLength > 0 else { return "" }
        guard name.count > maxLength else { return name }

        // Try to show the meaningful part (usually the filename)
        let components = name.components(separatedBy: "/")
        if let fileName = components.last, fileName.count <= maxLength {
            let prefixLength = maxLength - fileName.count - 3  // -3 for "…/"
            if prefixLength > 0 {
                let pathPrefix = String(name.prefix(prefixLength))
                return "\(pathPrefix)…/\(fileName)"
            }
            // Not enough room for path prefix, fall through to middle truncation
        }

        // Just truncate from the middle
        let halfLen = (maxLength - 1) / 2
        let start = name.prefix(halfLen)
        let end = name.suffix(halfLen)
        return "\(start)…\(end)"
    }
}

extension RcloneLogEntry {
    var date: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: time) {
            return date
        }
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: time)
    }

    var fileChange: FileChange? {
        // Strip ANSI codes from msg before parsing
        let cleanMsg = stripANSICodes(msg)

        // First, try with the object field (standard rclone format)
        if let objectPath = object, !objectPath.isEmpty {
            if let operation = parseOperation(from: cleanMsg, level: level) {
                return FileChange(
                    timestamp: date ?? Date(),
                    path: objectPath,
                    operation: operation
                )
            }
        }

        return nil
    }

    private func stripANSICodes(_ text: String) -> String {
        // Remove ANSI escape codes like \u001b[36m, \u001b[0m, etc.
        let pattern = #"\u{001B}\[[0-9;]*[A-Za-z]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    /// Maps a single rclone `--use-json-log` line to a FileChange operation.
    ///
    /// Only `level == "info"` lines count — an `error` line (e.g. a failed copy
    /// or the max-delete threshold message) mentioning "delete"/"copy" and
    /// carrying an `object` must never be reported as a completed change
    /// (limpet-plan.md L5 finding 3). Within info lines, only rclone's own
    /// success message text is matched, verified live against rclone 1.75.1
    /// (2026-09-26, `rclone sync --use-json-log -v` between local temp dirs;
    /// see the L5.1 fix commit for the exact lines observed):
    /// "Copied (new)" -> .copied; "Copied (replaced existing)" and
    /// "Updated modification time in destination" -> .updated; "Deleted"
    /// -> .deleted; "Moved (server-side) to: ..." and "Renamed from \"...\""
    /// (both emitted per rename under `--track-renames`) -> .renamed.
    private func parseOperation(from message: String, level: String) -> FileChange.Operation? {
        guard level == "info" else { return nil }

        if message.hasPrefix("Copied (new)") {
            return .copied
        }
        if message.hasPrefix("Copied (replaced existing)") {
            return .updated
        }
        if message.hasPrefix("Updated modification time in destination") {
            return .updated
        }
        if message == "Deleted" {
            return .deleted
        }
        if message.hasPrefix("Moved (server-side) to:") || message.hasPrefix("Renamed from") {
            return .renamed
        }

        return nil
    }
}
