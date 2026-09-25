import Foundation
import AppKit

/// Service for managing rclone configuration (remotes)
final class RcloneConfigService: Sendable {  // every stored property is an immutable Sendable value
    static let shared = RcloneConfigService()

    /// Path to rclone configuration file
    private let configPath: String
    /// `nil` = locate rclone as usual. Set only by `ConfigSelfTest` (a stub).
    private let rclonePath: String?
    /// Where keychain-backed remotes keep their secret (limpet-plan.md L4 F2).
    let keychain: KeychainSecretStore

    /// Everything is injectable so `ConfigSelfTest` works on a scratch
    /// rclone.conf, a stub rclone and a stub/throwaway keychain — never the
    /// user's real ones.
    init(
        configPath: String = "\(NSHomeDirectory())/.config/rclone/rclone.conf",
        rclonePath: String? = nil,
        keychain: KeychainSecretStore = KeychainSecretStore()
    ) {
        self.configPath = configPath
        self.rclonePath = rclonePath
        self.keychain = keychain
    }

    // MARK: - Rclone Path

    private func findRclonePath() -> String? {
        rclonePath ?? RcloneLocator.resolve()
    }

    /// Check if rclone is installed
    func isRcloneInstalled() -> Bool {
        findRclonePath() != nil
    }

    /// Get rclone version string
    func getRcloneVersion() -> String? {
        guard let rclonePath = findRclonePath() else { return nil }

        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: rclonePath)
        process.arguments = ["version"]
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                // First line contains version: "rclone v1.65.0"
                return output.components(separatedBy: "\n").first
            }
        } catch {
            return nil
        }

        return nil
    }

    // MARK: - Remote Management

    /// List all configured remotes
    func listRemotes() -> [String] {
        guard let rclonePath = findRclonePath() else { return [] }

        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: rclonePath)
        process.arguments = ["listremotes"]
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                return output.components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        } catch {
            return []
        }

        return []
    }

    /// Check if a remote name already exists
    func remoteExists(_ name: String) -> Bool {
        let remoteName = name.hasSuffix(":") ? name : "\(name):"
        return listRemotes().contains(remoteName)
    }

    /// F4 (limpet-plan.md L4): a line break in a name or value would start a
    /// new rclone.conf line — an injected key or a whole injected section.
    private static func refuseLineBreaks(_ config: RemoteConfiguration) throws {
        let fields = [config.name, config.oauthToken ?? ""] + config.values.flatMap { [$0.key, $0.value] }
        if fields.contains(where: { $0.contains("\n") || $0.contains("\r") }) {
            throw ConfigError.invalidRemote("names and values must not contain line breaks")
        }
    }

    /// Add a new remote to rclone config
    func addRemote(_ config: RemoteConfiguration) throws {
        try Self.refuseLineBreaks(config)
        if config.provider.isKeychainBacked {
            // The wizard's s3/b2 remotes take the same creation path as `limpet remote add`.
            let (values, secret) = Self.splitKeychainSecret(config)
            try addKeychainRemote(name: config.name, type: config.provider.rcloneType, values: values, secret: secret)
            return
        }
        // Ensure config directory exists
        let configDir = (configPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: configDir,
            withIntermediateDirectories: true
        )

        // Read existing config
        var existingConfig = ""
        if FileManager.default.fileExists(atPath: configPath) {
            existingConfig = try String(contentsOfFile: configPath, encoding: .utf8)
        }

        // Check for duplicate
        if existingConfig.contains("[\(config.name)]") {
            throw ConfigError.remoteAlreadyExists(config.name)
        }

        // Obscure password before writing
        var configToWrite = config
        obscurePasswordFields(&configToWrite)

        // Generate new section
        let newSection = configToWrite.generateConfigSection()

        // Append to config
        let newConfig = existingConfig.isEmpty
            ? newSection
            : "\(existingConfig)\n\n\(newSection)"

        try newConfig.write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    /// Read configuration for an existing remote from rclone.conf
    /// Returns a RemoteConfiguration pre-populated with the remote's current settings.
    func readRemoteConfig(name: String) -> RemoteConfiguration? {
        guard var values = section(named: name), let type = values.removeValue(forKey: "type") else {
            return nil
        }

        let provider = providerFromRcloneType(type, values: values)
        var config = RemoteConfiguration(name: name, provider: provider)

        // Copy values (overriding defaults)
        for (key, value) in values {
            config.values[key] = value
        }

        // Extract OAuth token if present
        if let token = values["token"] {
            config.oauthToken = token
            config.values.removeValue(forKey: "token")
        }

        return config
    }

    /// Every `key = value` of the `[name]` section of this service's rclone.conf,
    /// `type` included, or `nil` when there is no such section.
    func section(named name: String) -> [String: String]? {
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return nil }
        return Self.section(named: name, in: content)
    }

    static func section(named name: String, in content: String) -> [String: String]? {
        var inSection = false
        var values: [String: String] = [:]
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                if inSection { break }
                inSection = trimmed == "[\(name)]"
                continue
            }
            if inSection, let eqRange = trimmed.range(of: " = ") {
                values[String(trimmed[..<eqRange.lowerBound])] = String(trimmed[eqRange.upperBound...])
            }
        }
        return inSection ? values : nil
    }

    static func sectionNames(in content: String) -> [String] {
        content.components(separatedBy: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count > 2 else { return nil }
            return String(trimmed.dropFirst().dropLast())
        }
    }

    /// Map rclone type string to RemoteProvider
    private func providerFromRcloneType(_ type: String, values: [String: String]) -> RemoteProvider {
        switch type {
        case "drive":
            return .googleDrive
        case "dropbox":
            return .dropbox
        case "onedrive":
            return .oneDrive
        case "webdav":
            if isSynologyRemote(values: values) {
                return .synology
            }
            return .webdav
        case "sftp":
            return .sftp
        case "smb":
            return .smb
        case "s3":
            return .s3Compatible  // F5: never rewritten as webdav on edit
        case "b2":
            return .b2
        default:
            return .webdav
        }
    }

    /// Detect whether a WebDAV remote is a Synology NAS based on config values
    private func isSynologyRemote(values: [String: String]) -> Bool {
        if let vendor = values["vendor"], vendor == "synology" {
            return true
        }
        guard let url = values["url"]?.lowercased() else { return false }
        // Synology DSM ports
        if url.contains(":5005") || url.contains(":5006") || url.contains(":5001") {
            return true
        }
        // Synology QuickConnect
        if url.contains("quickconnect.to") {
            return true
        }
        // Synology DDNS domains
        if url.contains(".synology.me") || url.contains(".dsm.") {
            return true
        }
        return false
    }

    /// Update an existing remote (delete old config section, write new one)
    func updateRemote(_ config: RemoteConfiguration) throws {
        try Self.refuseLineBreaks(config)
        if config.provider.isKeychainBacked {
            // Rotation is delete then add (F2): the secret must be entered again.
            // Everything checkable is checked BEFORE the old remote is deleted.
            let (values, secret) = Self.splitKeychainSecret(config)
            if let reason = Self.keychainRemoteError(
                name: config.name, type: config.provider.rcloneType, values: values, secret: secret) {
                throw ConfigError.invalidRemote(reason)
            }
            try deleteRemote(config.name)
            try addKeychainRemote(name: config.name, type: config.provider.rcloneType, values: values, secret: secret)
            return
        }
        // Delete the existing remote first
        try deleteRemote(config.name)

        // Ensure config directory exists
        let configDir = (configPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: configDir,
            withIntermediateDirectories: true
        )

        // Read existing config (after deletion)
        var existingConfig = ""
        if FileManager.default.fileExists(atPath: configPath) {
            existingConfig = try String(contentsOfFile: configPath, encoding: .utf8)
        }

        // Obscure password before writing
        var configToWrite = config
        obscurePasswordFields(&configToWrite)

        // Generate new section
        let newSection = configToWrite.generateConfigSection()

        // Append to config
        let newConfig = existingConfig.isEmpty
            ? newSection
            : "\(existingConfig)\n\n\(newSection)"

        try newConfig.write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    /// Delete a remote from rclone config, and its keychain item when it is
    /// keychain-backed (F7: no secret is left behind for a remote that is gone).
    func deleteRemote(_ name: String) throws {
        guard let rclonePath = findRclonePath() else {
            throw ConfigError.rcloneNotFound
        }
        // Read before the section is gone.
        let wasKeychainBacked = section(named: name)?[Self.keychainMarker] == "true"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: rclonePath)
        process.arguments = ["config", "delete", name]

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw ConfigError.deleteFailed(name)
        }
        if wasKeychainBacked, let error = keychain.delete(account: name) {
            throw ConfigError.keychainFailed("remote deleted, but its keychain item was not: \(error)")
        }
    }

    // MARK: - Keychain-backed remotes (limpet-plan.md L4)

    /// rclone.conf marker of a keychain-backed remote. Measured 2026-09-26 with
    /// rclone 1.75.1 on a scratch --config: an unknown `limpet_keychain = true`
    /// key in a `type = local` and a `type = s3` section produced no error and
    /// no warning at default verbosity or -vv (`lsf`, `backend features`).
    static let keychainMarker = "limpet_keychain"

    /// The only options each keychain-backed type may carry in rclone.conf.
    /// Anything else (the secret itself, `no_check_certificate`, `hard_delete`,
    /// …) is refused rather than written.
    static let keychainRemoteOptions: [String: Set<String>] = [
        "s3": ["provider", "access_key_id", "endpoint", "region"],
        "b2": ["account"],
    ]

    /// F3: the variable rclone reads the secret from. rclone upper-cases the
    /// remote name (measured 2026-09-26, rclone 1.75.1 -vv: remote `m_low`
    /// took an option from `RCLONE_CONFIG_M_LOW_…`; remote `m-dash` did NOT
    /// take one from `RCLONE_CONFIG_M_DASH_…`), and keychain-backed names are
    /// `[A-Za-z0-9_]+`, so the mapping is unambiguous.
    static func secretVariable(remote: String, type: String) -> String? {
        switch type {
        case "s3": return "RCLONE_CONFIG_\(remote.uppercased())_SECRET_ACCESS_KEY"
        case "b2": return "RCLONE_CONFIG_\(remote.uppercased())_KEY"
        default: return nil
        }
    }

    /// F3 — THE secret-injection helper every rclone invocation that touches a
    /// remote goes through. `remoteSpec` is `name`, `name:` or `name:path`.
    /// Returns the variables to merge into the child's environment — empty for
    /// a remote without the marker, which then runs exactly as before — or
    /// `nil` after logging exactly one fixed-format line, in which case the
    /// caller must not start rclone. The sync script never touches the keychain.
    func secretEnvironment(forRemote remoteSpec: String, log: (String) -> Void) -> [String: String]? {
        let name = String(remoteSpec.prefix { $0 != ":" })
        guard let values = section(named: name), values[Self.keychainMarker] == "true" else { return [:] }
        guard KeychainSecretStore.isValidAccount(name),
              let variable = Self.secretVariable(remote: name, type: values["type"] ?? "") else {
            log("Keychain-backed remote \"\(name)\" is not a supported s3/b2 remote; rclone was not started")
            return nil
        }
        switch keychain.read(account: name) {
        case .found(let secret):
            return [variable: secret]
        case .notFound:
            log("Keychain secret not found for remote \"\(name)\" (service \(KeychainSecretStore.service)); rclone was not started")
        case .failed(let status):
            log("Keychain read failed for remote \"\(name)\" (security exit \(status)); rclone was not started")
        case .timedOut:
            log("Keychain read timed out after \(Int(keychain.timeout))s for remote \"\(name)\"; rclone was not started")
        }
        return nil
    }

    /// `secretEnvironment` merged over this process's environment — what a
    /// call site assigns to `Process.environment`. `nil` = do not start rclone.
    func processEnvironment(forRemote remoteSpec: String, log: (String) -> Void) -> [String: String]? {
        secretEnvironment(forRemote: remoteSpec, log: log).map {
            ProcessInfo.processInfo.environment.merging($0) { _, secret in secret }
        }
    }

    /// F2/F4/F5/F7 — the ONE creation path for keychain-backed remotes, shared
    /// by the wizard (through `addRemote`) and `limpet remote add`. Writes a
    /// non-secret section plus the `limpet_keychain = true` marker, and puts the
    /// secret only in the keychain (via `KeychainSecretStore`, i.e.
    /// `/usr/bin/security -i`). https endpoints only, never
    /// `no_check_certificate` (F7). The section is APPENDED, so no other
    /// section of rclone.conf is rewritten and the file keeps its permissions.
    func addKeychainRemote(name: String, type: String, values: [String: String], secret: String) throws {
        if let reason = Self.keychainRemoteError(name: name, type: type, values: values, secret: secret) {
            throw ConfigError.invalidRemote(reason)
        }

        let existing = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        // Case-insensitive: rclone upper-cases the name into the variable name.
        if Self.sectionNames(in: existing).contains(where: { $0.lowercased() == name.lowercased() }) {
            throw ConfigError.remoteAlreadyExists(name)
        }

        if let error = keychain.store(account: name, secret: secret) {
            throw ConfigError.keychainFailed(error)
        }
        let lines = ["[\(name)]", "type = \(type)"]
            + values.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }
            + ["\(Self.keychainMarker) = true"]
        do {
            try appendSection(lines.joined(separator: "\n"), existing: existing)
        } catch {
            _ = keychain.delete(account: name)  // no orphaned secret
            throw error
        }
    }

    /// Every check on a keychain-backed remote that needs no rclone.conf read.
    private static func keychainRemoteError(
        name: String, type: String, values: [String: String], secret: String
    ) -> String? {
        guard KeychainSecretStore.isValidAccount(name) else {
            return "a keychain-backed remote name may only contain letters, digits and _"
        }
        guard let allowed = keychainRemoteOptions[type] else { return "type must be s3 or b2" }
        for (key, value) in values {
            guard allowed.contains(key) else { return "option \(key) is not supported for a \(type) remote" }
            guard !value.contains("\n"), !value.contains("\r") else {
                return "option \(key) must not contain a line break"
            }
        }
        if let endpoint = values["endpoint"], endpoint.contains("://"),
           !endpoint.lowercased().hasPrefix("https://") {
            return "endpoint must use https"
        }
        guard !secret.isEmpty, !secret.contains("\n"), !secret.contains("\r") else {
            return "the secret must be one non-empty line"
        }
        return nil
    }

    /// The wizard keeps the secret in `values` like any password field; pull it
    /// out (and the marker read back on edit) so it can only go to the keychain.
    private static func splitKeychainSecret(_ config: RemoteConfiguration) -> (values: [String: String], secret: String) {
        var values = config.values.filter { !$0.value.isEmpty }
        let secret = config.provider.secretKey.flatMap { values.removeValue(forKey: $0) } ?? ""
        values.removeValue(forKey: keychainMarker)
        return (values, secret)
    }

    private func appendSection(_ section: String, existing: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            atPath: (configPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: configPath) {
            guard fm.createFile(atPath: configPath, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw ConfigError.configWriteFailed
            }
        }
        let separator = existing.isEmpty ? "" : (existing.hasSuffix("\n") ? "\n" : "\n\n")
        guard let handle = FileHandle(forWritingAtPath: configPath) else { throw ConfigError.configWriteFailed }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((separator + section + "\n").utf8))
    }

    /// Test connection to a remote path (e.g. "synology:" or "synology:Kaiju")
    func testConnection(_ remotePath: String) async -> Result<Void, ConfigError> {
        guard let rclonePath = findRclonePath() else {
            return .failure(.rcloneNotFound)
        }

        // Check if remote has no_check_certificate set
        let remoteName = remotePath.replacingOccurrences(of: ":", with: "").split(separator: "/").first.map(String.init) ?? remotePath.replacingOccurrences(of: ":", with: "")
        let skipCert = readRemoteConfig(name: remoteName)?.values["no_check_certificate"] == "true"

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()

                process.executableURL = URL(fileURLWithPath: rclonePath)
                let remote = remotePath.contains(":") ? remotePath : "\(remotePath):"
                var keychainError = ""
                guard let environment = self.processEnvironment(forRemote: remote, log: { keychainError = $0 }) else {
                    continuation.resume(returning: .failure(.connectionFailed(keychainError)))
                    return
                }
                process.environment = environment
                var args = ["lsd", remote, "--contimeout", "10s"]
                if skipCert {
                    args.append("--no-check-certificate")
                }
                process.arguments = args
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()

                    if process.terminationStatus == 0 {
                        continuation.resume(returning: .success(()))
                    } else {
                        let error = String(data: data, encoding: .utf8) ?? "Connection failed"
                        continuation.resume(returning: .failure(.connectionFailed(error)))
                    }
                } catch {
                    continuation.resume(returning: .failure(.connectionFailed(error.localizedDescription)))
                }
            }
        }
    }

    // MARK: - OAuth Flow

    /// Start OAuth flow for a provider
    /// Opens system browser and runs rclone authorize to capture token
    func startOAuthFlow(
        for provider: RemoteProvider,
        completion: @escaping (Result<String, ConfigError>) -> Void
    ) {
        guard let rclonePath = findRclonePath() else {
            completion(.failure(.rcloneNotFound))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: rclonePath)
            process.arguments = ["authorize", provider.rcloneType]
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()

                // Capture output in background
                var outputData = Data()
                var errorData = Data()

                outputPipe.fileHandleForReading.readabilityHandler = { handle in
                    outputData.append(handle.availableData)
                }

                errorPipe.fileHandleForReading.readabilityHandler = { handle in
                    errorData.append(handle.availableData)
                }

                process.waitUntilExit()

                // Clean up handlers
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil

                if process.terminationStatus == 0 {
                    let output = String(data: outputData, encoding: .utf8) ?? ""

                    // Extract token from output
                    // rclone outputs: Paste the following into your remote machine --->
                    // {"access_token":"...","token_type":"Bearer",...}
                    // <---End paste
                    if let token = self.extractToken(from: output) {
                        DispatchQueue.main.async {
                            completion(.success(token))
                        }
                    } else {
                        DispatchQueue.main.async {
                            completion(.failure(.tokenExtractionFailed))
                        }
                    }
                } else {
                    let error = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                    DispatchQueue.main.async {
                        completion(.failure(.oauthFailed(error)))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(.oauthFailed(error.localizedDescription)))
                }
            }
        }
    }

    /// Extract OAuth token JSON from rclone authorize output
    private func extractToken(from output: String) -> String? {
        // Look for JSON token between markers
        let lines = output.components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{") && trimmed.contains("access_token") {
                return trimmed
            }
        }

        // Alternative: look for token between paste markers
        if let startRange = output.range(of: "--->"),
           let endRange = output.range(of: "<---")
        {
            let tokenRange = startRange.upperBound..<endRange.lowerBound
            let tokenSection = String(output[tokenRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Find JSON in the section
            if let jsonStart = tokenSection.range(of: "{"),
               let jsonEnd = tokenSection.range(of: "}", options: .backwards)
            {
                let json = String(tokenSection[jsonStart.lowerBound...jsonEnd.upperBound])
                return json
            }
        }

        return nil
    }

    // MARK: - Password Obscuring

    /// Obscure password fields in a RemoteConfiguration before writing to config.
    /// Skips values that are already obscured (read back from an existing config).
    private func obscurePasswordFields(_ config: inout RemoteConfiguration) {
        for field in config.provider.requiredFields where field.type == .password {
            guard let value = config.values[field.key], !value.isEmpty else { continue }
            // If the value can be revealed, it's already obscured — don't double-obscure
            if isAlreadyObscured(value) { continue }
            if let obscured = obscurePassword(value) {
                config.values[field.key] = obscured
            }
        }
    }

    /// Check if a password string is already in rclone's obscured format
    private func isAlreadyObscured(_ value: String) -> Bool {
        guard let rclonePath = findRclonePath() else { return false }

        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: rclonePath)
        process.arguments = ["reveal", value]
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Obscure a password using rclone (for secure storage in config)
    func obscurePassword(_ password: String) -> String? {
        guard let rclonePath = findRclonePath() else { return nil }

        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: rclonePath)
        process.arguments = ["obscure", password]
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    // MARK: - List Remote Contents

    /// List folders at the root of a remote
    func listFolders(remote: String) async -> Result<[String], ConfigError> {
        guard let rclonePath = findRclonePath() else {
            return .failure(.rcloneNotFound)
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()

                process.executableURL = URL(fileURLWithPath: rclonePath)
                let remotePath = remote.hasSuffix(":") ? remote : "\(remote):"
                var keychainError = ""
                guard let environment = self.processEnvironment(forRemote: remotePath, log: { keychainError = $0 }) else {
                    continuation.resume(returning: .failure(.connectionFailed(keychainError)))
                    return
                }
                process.environment = environment
                let remoteName = remote.replacingOccurrences(of: ":", with: "")
                let skipCert = self.readRemoteConfig(name: remoteName)?.values["no_check_certificate"] == "true"
                var args = ["lsd", remotePath]
                if skipCert {
                    args.append("--no-check-certificate")
                }
                process.arguments = args
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    if process.terminationStatus == 0 {
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        if let output = String(data: data, encoding: .utf8) {
                            // Parse lsd output format: "     -1 2000-01-01 01:00:00        -1 FolderName"
                            // Format: size date time count name (with variable whitespace)
                            let folders = output.components(separatedBy: "\n")
                                .compactMap { line -> String? in
                                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                                    guard !trimmed.isEmpty else { return nil }
                                    // Match: -1 YYYY-MM-DD HH:MM:SS -1 FolderName
                                    // (size) (date) (time) (count) (name)
                                    let pattern = #"^-?\d+\s+\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\s+-?\d+\s+(.+)$"#
                                    if let regex = try? NSRegularExpression(pattern: pattern),
                                       let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
                                       let folderRange = Range(match.range(at: 1), in: trimmed) {
                                        return String(trimmed[folderRange])
                                    }
                                    return nil
                                }
                            continuation.resume(returning: .success(folders))
                        } else {
                            continuation.resume(returning: .success([]))
                        }
                    } else {
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        let error = String(data: data, encoding: .utf8) ?? "Unknown error"
                        continuation.resume(returning: .failure(.connectionFailed(error)))
                    }
                } catch {
                    continuation.resume(returning: .failure(.connectionFailed(error.localizedDescription)))
                }
            }
        }
    }

    // MARK: - Errors

    enum ConfigError: LocalizedError {
        case rcloneNotFound
        case remoteAlreadyExists(String)
        case deleteFailed(String)
        case connectionFailed(String)
        case oauthFailed(String)
        case tokenExtractionFailed
        case configWriteFailed
        case invalidRemote(String)
        case keychainFailed(String)

        var errorDescription: String? {
            switch self {
            case .rcloneNotFound:
                return "rclone is not installed. Please install it with: brew install rclone"
            case .remoteAlreadyExists(let name):
                return "A remote named '\(name)' already exists"
            case .deleteFailed(let name):
                return "Failed to delete remote '\(name)'"
            case .connectionFailed(let error):
                return "Connection failed: \(error)"
            case .oauthFailed(let error):
                return "Authentication failed: \(error)"
            case .tokenExtractionFailed:
                return "Failed to extract authentication token"
            case .configWriteFailed:
                return "Failed to write rclone configuration"
            case .invalidRemote(let reason):
                return "Invalid remote: \(reason)"
            case .keychainFailed(let reason):
                return "Keychain: \(reason)"
            }
        }
    }
}
