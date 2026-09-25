import Foundation
import Security

/// Creates, reads and deletes the secrets of keychain-backed rclone remotes
/// (limpet-plan.md L4 F2/F3/F7): generic-password items with service `limpet`
/// and account = the rclone remote name.
///
/// F2: items are created ONLY through `/usr/bin/security add-generic-password
/// -s limpet -a <name> -T /usr/bin/security`, never `SecItemAdd` and never
/// `-A`. An item the app created itself would trust the app's own code
/// signature, which a rebuild or an upgrade changes, and a launchd-started
/// watcher would then block on a prompt nobody sees. Every read goes through
/// `/usr/bin/security` too, the one application the item trusts.
///
/// The add command reaches `security` on stdin via `security -i`, with the
/// secret hex-encoded (`-X`), so the secret never appears in any argv.
/// Measured 2026-09-26 against a throwaway keychain made with
/// `security create-keychain` under the scratchpad (never the login keychain):
/// `security -i` accepted that line on stdin and exited 0; `find-generic-password
/// -w` read back a secret containing a space, `"`, `'` and `$` unchanged; a
/// double-quoted keychain path containing a space worked; `dump-keychain -a`
/// listed `/usr/bin/security` as the ONLY application of the decrypt entry; a
/// duplicate add exited 45; find and delete of a missing item exited 44.
///
/// Injectable (`securityPath`, `keychainPath`, `timeout`) so `ConfigSelfTest`
/// runs against a stub binary or a throwaway keychain, never the login one.
struct KeychainSecretStore {
    static let service = "limpet"
    /// The only application trusted to read an item without a prompt.
    static let trustedApplication = "/usr/bin/security"

    var securityPath = "/usr/bin/security"
    var keychainPath = "\(NSHomeDirectory())/Library/Keychains/login.keychain-db"
    /// F3: a hung `security` (e.g. waiting on an invisible prompt) must not
    /// wedge the watcher.
    var timeout: TimeInterval = 10
    /// "No unprompted keychain dialogs" (limpet-plan.md L4, user requirement
    /// 2026-09-26): asked before EVERY `security` call. Anything but
    /// `.unlocked` means no call at all, because reading from a locked keychain
    /// raises the system unlock dialog. Injectable; the self-test never uses
    /// the production provider.
    var lockStatus: @Sendable (_ keychainPath: String) -> LockStatus = KeychainSecretStore.systemLockStatus

    enum LockStatus: Equatable {
        case unlocked
        case locked
        /// The status query itself failed: treated as locked.
        case unknown
    }

    /// The one log line (and GUI message) for a locked keychain.
    static let lockedMessage = "Keychain locked — open limpet and click \"Allow keychain access\""

    enum ReadResult: Equatable {
        case found(String)
        case notFound
        case failed(Int32)
        case timedOut
        case locked
    }

    /// Production lock-status provider: `SecKeychainOpen` + `SecKeychainGetStatus`
    /// on the keychain path, which only reads the unlock state.
    ///
    /// UNVERIFIED: that this never raises a dialog was NOT measured. On
    /// 2026-09-26 keychain work on the development machine raised dialogs for
    /// the user, and every keychain call there stopped; the user checks it
    /// live (lock the login keychain, confirm no dialog within two sync
    /// cycles). `security show-keychain-info` is known to prompt and is not used.
    @Sendable static func systemLockStatus(_ keychainPath: String) -> LockStatus {
        if realKeychainForbidden { return .unknown }
        var keychain: SecKeychain?
        guard SecKeychainOpen(keychainPath, &keychain) == errSecSuccess, let keychain else { return .unknown }
        var status: SecKeychainStatus = 0
        guard SecKeychainGetStatus(keychain, &status) == errSecSuccess else { return .unknown }
        return status & SecKeychainStatus(kSecUnlockStateStatus) != 0 ? .unlocked : .locked
    }

    /// The ONE path allowed to raise a keychain dialog: the user clicked
    /// "Allow keychain access" in the menu. `SecKeychainUnlock` without a
    /// password asks the system to show its unlock dialog. UNVERIFIED on the
    /// development machine for the same reason as `systemLockStatus`. Blocks
    /// until the user answers; call it off the main thread. Returns whether
    /// the keychain is unlocked afterwards.
    static func requestUnlock(keychainPath: String) -> Bool {
        if realKeychainForbidden { return false }
        var keychain: SecKeychain?
        guard SecKeychainOpen(keychainPath, &keychain) == errSecSuccess, let keychain,
              SecKeychainUnlock(keychain, 0, nil, false) == errSecSuccess else { return false }
        return systemLockStatus(keychainPath) == .unlocked
    }

    /// `[A-Za-z0-9_]+`: the account doubles as the rclone remote name, which is
    /// upper-cased into `RCLONE_CONFIG_<NAME>_…`, and is written into the
    /// `security -i` command line unquoted.
    static func isValidAccount(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_"
        }
    }

    /// Create the item. Returns an error message, or `nil` on success.
    func add(account: String, secret: String) -> String? {
        guard Self.isValidAccount(account) else { return "invalid keychain account name" }
        guard !secret.isEmpty else { return "the secret is empty" }
        guard !keychainPath.contains("\""), !keychainPath.contains("\n") else {
            return "unsupported keychain path"
        }
        let hex = secret.utf8.map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -s \(Self.service) -a \(account) "
            + "-T \(Self.trustedApplication) -X \(hex) \"\(keychainPath)\"\n"
        switch run(["-i"], stdin: command) {
        case .exited(0, _): break
        case .exited(let status, _): return "security add-generic-password failed (exit \(status))"
        case .timedOut: return "security add-generic-password timed out"
        case .locked: return Self.lockedMessage
        }
        // `security -i`'s exit status is not trusted as proof of success (review
        // finding 7). Its failure semantics were NOT measured beyond two cases on
        // a throwaway keychain before keychain measurements stopped on
        // 2026-09-26: a duplicate add exited 45, and two commands whose FIRST
        // failed exited 0. So the item is read back and compared; the secret is
        // never printed.
        guard read(account: account) == .found(secret) else {
            return "the keychain item could not be read back after adding it"
        }
        return nil
    }

    /// Rotation is delete then add (F2): an existing item's ACL is never edited.
    func store(account: String, secret: String) -> String? {
        delete(account: account) ?? add(account: account, secret: secret)
    }

    /// Delete the item. A missing item (exit 44) is not an error.
    func delete(account: String) -> String? {
        switch run(["delete-generic-password", "-s", Self.service, "-a", account, keychainPath]) {
        case .exited(0, _), .exited(44, _): return nil
        case .exited(let status, _): return "security delete-generic-password failed (exit \(status))"
        case .timedOut: return "security delete-generic-password timed out"
        case .locked: return Self.lockedMessage
        }
    }

    func read(account: String) -> ReadResult {
        switch run(["find-generic-password", "-s", Self.service, "-a", account, "-w", keychainPath]) {
        case .exited(0, let output):
            var secret = String(decoding: output, as: UTF8.self)
            if secret.hasSuffix("\n") { secret.removeLast() }
            return .found(secret)
        case .exited(44, _): return .notFound
        case .exited(let status, _): return .failed(status)
        case .timedOut: return .timedOut
        case .locked: return .locked
        }
    }

    private enum RunResult {
        case exited(Int32, Data)
        case timedOut
        case locked
    }

    /// Set by `ConfigSelfTest.run()`: while true, the real `/usr/bin/security`
    /// is never started, whatever a test injects. The self-test drives only a
    /// fake runner; this makes a test that forgot to inject one fail instead
    /// of raising keychain dialogs on the machine running it.
    nonisolated(unsafe) static var realKeychainForbidden = false

    private func run(_ arguments: [String], stdin: String? = nil) -> RunResult {
        if Self.realKeychainForbidden, securityPath == Self.trustedApplication {
            return .exited(-1, Data())
        }
        // No `security` call on anything but an unlocked keychain: it would
        // raise the unlock dialog (limpet-plan.md L4, "No unprompted keychain dialogs").
        guard lockStatus(keychainPath) == .unlocked else { return .locked }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: securityPath)
        process.arguments = arguments
        // stdin is always a pipe, so `security` never reads the terminal. The
        // whole command is in the pipe buffer before the child starts and this
        // process still holds the read end, so the write can neither block nor
        // raise SIGPIPE.
        let input = Pipe()
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? input.fileHandleForWriting.close()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return .exited(-1, Data())
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return .timedOut
        }
        return .exited(process.terminationStatus, output.fileHandleForReading.readDataToEndOfFile())
    }
}
