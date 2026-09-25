import Foundation

/// Supported remote storage providers for the setup wizard
enum RemoteProvider: String, Codable, CaseIterable, Identifiable {
    case googleDrive = "drive"
    case dropbox = "dropbox"
    case oneDrive = "onedrive"
    case synology = "synology"  // Synology uses WebDAV but has distinct UI
    case smb = "smb"
    case webdav = "webdav"
    case sftp = "sftp"
    /// S3-compatible object storage — MEGA S4, Cloudflare R2, AWS, MinIO,
    /// Backblaze B2's S3 API, others. Keychain-backed (limpet-plan.md L4).
    case s3Compatible = "s3"
    /// Backblaze B2 through rclone's native b2 backend. Keychain-backed.
    case b2 = "b2"

    var id: String { rawValue }

    /// Whether the remote's secret lives in the login keychain instead of
    /// rclone.conf (limpet-plan.md L4 F2): created only through
    /// `RcloneConfigService.addKeychainRemote`.
    var isKeychainBacked: Bool { secretKey != nil }

    /// The rclone option holding the secret, which is never written to
    /// rclone.conf for these providers.
    var secretKey: String? {
        switch self {
        case .s3Compatible: return "secret_access_key"
        case .b2: return "key"
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .googleDrive:
            return "Google Drive"
        case .dropbox:
            return "Dropbox"
        case .oneDrive:
            return "OneDrive"
        case .synology:
            return "Synology NAS"
        case .smb:
            return "SMB / CIFS"
        case .webdav:
            return "WebDAV"
        case .sftp:
            return "SFTP"
        case .s3Compatible:
            return "S3-compatible"
        case .b2:
            return "Backblaze B2"
        }
    }

    var iconName: String {
        switch self {
        case .googleDrive:
            return "externaldrive.badge.icloud"
        case .dropbox:
            return "shippingbox"
        case .oneDrive:
            return "cloud"
        case .synology:
            return "externaldrive.connected.to.line.below"
        case .smb:
            return "folder.badge.gearshape"
        case .webdav:
            return "server.rack"
        case .sftp:
            return "terminal"
        case .s3Compatible:
            return "cube.box"
        case .b2:
            return "archivebox"
        }
    }

    /// The rclone type identifier for this provider
    var rcloneType: String {
        switch self {
        case .googleDrive:
            return "drive"
        case .dropbox:
            return "dropbox"
        case .oneDrive:
            return "onedrive"
        case .synology, .webdav:
            return "webdav"
        case .smb:
            return "smb"
        case .sftp:
            return "sftp"
        case .s3Compatible:
            return "s3"
        case .b2:
            return "b2"
        }
    }

    /// Whether this provider uses OAuth for authentication
    var usesOAuth: Bool {
        switch self {
        case .googleDrive, .dropbox, .oneDrive:
            return true
        case .synology, .smb, .webdav, .sftp, .s3Compatible, .b2:
            return false
        }
    }

    /// Required configuration fields for this provider
    var requiredFields: [ProviderField] {
        switch self {
        case .googleDrive:
            return [
                ProviderField(key: "scope", label: "Access Level", type: .dropdown, options: [
                    FieldOption(value: "drive", label: "Full access (read/write)"),
                    FieldOption(value: "drive.readonly", label: "Read only"),
                    FieldOption(value: "drive.file", label: "File access only")
                ], defaultValue: "drive")
            ]
        case .dropbox:
            return []  // OAuth only, no additional fields
        case .oneDrive:
            return [
                ProviderField(key: "drive_type", label: "Drive Type", type: .dropdown, options: [
                    FieldOption(value: "personal", label: "Personal"),
                    FieldOption(value: "business", label: "Business"),
                    FieldOption(value: "documentLibrary", label: "SharePoint")
                ], defaultValue: "personal")
            ]
        case .synology:
            return [
                ProviderField(key: "url", label: "NAS Address", type: .text,
                              placeholder: "https://your-nas.local:5006",
                              helpText: "WebDAV URL (usually port 5005 for HTTP, 5006 for HTTPS)"),
                ProviderField(key: "user", label: "Username", type: .text),
                ProviderField(key: "pass", label: "Password", type: .password),
                ProviderField(key: "vendor", label: "Vendor", type: .hidden, defaultValue: "other")
            ]
        case .smb:
            return [
                ProviderField(key: "host", label: "Host", type: .text,
                              placeholder: "192.168.1.100 or nas.local"),
                ProviderField(key: "user", label: "Username", type: .text),
                ProviderField(key: "pass", label: "Password", type: .password,
                              isOptional: true),
                ProviderField(key: "port", label: "Port", type: .number,
                              placeholder: "445", defaultValue: "445")
            ]
        case .webdav:
            return [
                ProviderField(key: "url", label: "WebDAV URL", type: .text,
                              placeholder: "https://example.com/remote.php/dav"),
                ProviderField(key: "user", label: "Username", type: .text),
                ProviderField(key: "pass", label: "Password", type: .password),
                ProviderField(key: "vendor", label: "Server Type", type: .dropdown, options: [
                    FieldOption(value: "other", label: "Generic WebDAV"),
                    FieldOption(value: "nextcloud", label: "Nextcloud"),
                    FieldOption(value: "owncloud", label: "ownCloud"),
                    FieldOption(value: "sharepoint", label: "SharePoint Online")
                ], defaultValue: "other")
            ]
        case .sftp:
            return [
                ProviderField(key: "host", label: "Host", type: .text,
                              placeholder: "nas.example.com"),
                ProviderField(key: "port", label: "Port", type: .number,
                              placeholder: "22", defaultValue: "22"),
                ProviderField(key: "user", label: "Username", type: .text),
                ProviderField(key: "pass", label: "Password", type: .password,
                              helpText: "Leave empty if using SSH key",
                              isOptional: true),
                // Disable remote shell hash verification by default.
                // rclone otherwise runs `md5sum <path>` via SSH; on Synology and similar systems
                // SFTP exposes shares via bind-mount paths (e.g., /Kaiju) but the real filesystem
                // requires /volume1/Kaiju, so md5sum fails and sync aborts with "corrupted on transfer".
                // Falling back to size+modtime comparison is sufficient.
                ProviderField(key: "disable_hashcheck", label: "Disable Hash Check",
                              type: .hidden, defaultValue: "true")
            ]
        case .s3Compatible:
            return [
                ProviderField(key: "provider", label: "Provider", type: .dropdown, options: [
                    FieldOption(value: "Mega", label: "MEGA S4"),
                    FieldOption(value: "Cloudflare", label: "Cloudflare R2"),
                    FieldOption(value: "AWS", label: "Amazon S3"),
                    FieldOption(value: "Minio", label: "MinIO"),
                    FieldOption(value: "Other", label: "Other (incl. Backblaze B2 S3 API)")
                ], defaultValue: "Mega"),
                ProviderField(key: "access_key_id", label: "Access Key ID", type: .text),
                ProviderField(key: "secret_access_key", label: "Secret Access Key", type: .password,
                              helpText: "Stored in your login keychain, never in rclone.conf. "
                                + "When editing, enter it again."),
                ProviderField(key: "endpoint", label: "Endpoint", type: .text,
                              placeholder: "s3.ap-tokyo-1.megas4.com",
                              helpText: "https only. Leave empty for Amazon S3.",
                              isOptional: true),
                ProviderField(key: "region", label: "Region", type: .text,
                              placeholder: "ap-tokyo-1", isOptional: true)
            ]
        case .b2:
            return [
                ProviderField(key: "account", label: "Application Key ID", type: .text),
                ProviderField(key: "key", label: "Application Key", type: .password,
                              helpText: "Stored in your login keychain, never in rclone.conf. Use a "
                                + "bucket-scoped key without the deleteFiles capability.")
            ]
        }
    }

    /// Optional configuration fields for this provider
    var optionalFields: [ProviderField] {
        switch self {
        case .googleDrive:
            return [
                ProviderField(key: "root_folder_id", label: "Root Folder ID", type: .text,
                              helpText: "Optional: Limit access to a specific folder")
            ]
        case .dropbox:
            return []
        case .oneDrive:
            return [
                ProviderField(key: "drive_id", label: "Drive ID", type: .text,
                              helpText: "Optional: Specific drive to access")
            ]
        case .synology, .webdav:
            return [
                ProviderField(key: "no_check_certificate", label: "Skip certificate verification",
                              type: .boolean,
                              helpText: "Allow self-signed or mismatched SSL certificates (insecure)")
            ]
        case .smb:
            return [
                ProviderField(key: "domain", label: "Domain", type: .text,
                              placeholder: "WORKGROUP",
                              helpText: "Domain name for NTLM authentication",
                              defaultValue: "WORKGROUP")
            ]
        case .sftp:
            return [
                ProviderField(key: "key_file", label: "SSH Key Path", type: .file,
                              helpText: "Path to private key file (e.g., ~/.ssh/id_rsa)")
            ]
        case .s3Compatible, .b2:
            // Deliberately nothing: no certificate-skip option for these types (F7).
            return []
        }
    }
}

/// A configuration field for a remote provider
struct ProviderField: Identifiable {
    var id: String { key }
    let key: String
    let label: String
    let type: FieldType
    var placeholder: String?
    var helpText: String?
    var options: [FieldOption]?
    var defaultValue: String?
    /// When true, validation skips this field even though it's in requiredFields
    var isOptional: Bool = false

    enum FieldType {
        case text
        case password
        case number
        case dropdown
        case file
        case boolean
        case hidden
    }
}

/// An option for dropdown fields
struct FieldOption: Identifiable {
    var id: String { value }
    let value: String
    let label: String
}

/// Configuration values for creating a remote
struct RemoteConfiguration {
    var name: String
    var provider: RemoteProvider
    var values: [String: String]

    /// Token from OAuth flow (for OAuth providers)
    var oauthToken: String?

    init(name: String, provider: RemoteProvider) {
        self.name = name
        self.provider = provider
        self.values = [:]

        // Set default values
        for field in provider.requiredFields {
            if let defaultValue = field.defaultValue {
                values[field.key] = defaultValue
            }
        }
    }

    /// Generate rclone config section content
    func generateConfigSection() -> String {
        var lines: [String] = []
        lines.append("[\(name)]")
        lines.append("type = \(provider.rcloneType)")

        for (key, value) in values where !value.isEmpty {
            lines.append("\(key) = \(value)")
        }

        if let token = oauthToken {
            lines.append("token = \(token)")
        }

        return lines.joined(separator: "\n")
    }

    /// Validate that all required fields are filled
    func validate() -> [String] {
        var errors: [String] = []

        if name.isEmpty {
            errors.append("Remote name is required")
        }

        if name.contains(":") || name.contains(" ") {
            errors.append("Remote name cannot contain ':' or spaces")
        }

        if provider.isKeychainBacked, !name.isEmpty, !KeychainSecretStore.isValidAccount(name) {
            errors.append("Remote name may only contain letters, digits and _")
        }

        for field in provider.requiredFields where field.type != .hidden && !field.isOptional {
            if let value = values[field.key], !value.isEmpty {
                continue
            }
            errors.append("\(field.label) is required")
        }

        if provider.usesOAuth && oauthToken == nil {
            errors.append("Authentication required (click 'Authenticate' to sign in)")
        }

        return errors
    }
}
