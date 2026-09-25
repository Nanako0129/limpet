import Foundation

/// Installs a small `~/.local/bin/limpet` shim that `exec`s the currently
/// running app's binary — parallel to `SyncSetupService`'s shared sync-script
/// write (`~/.local/bin/limpet-sync.sh`), but kept in `CLI/` since it's a
/// distinct distribution concern (making the headless CLI reachable by name)
/// rather than part of the sync-agent install/uninstall lifecycle.
///
/// Regenerated on every app launch (see `AppDelegate.applicationDidFinishLaunching`)
/// so the `exec` target stays correct after a `brew upgrade` or the app bundle
/// moving — the same rationale as the Finder-extension re-registration. An
/// ownership marker line guards against ever clobbering a file limpet didn't
/// create: a shim file missing the marker is left untouched.
enum CLIShimInstaller {
    /// First line of every shim limpet writes. Presence of this EXACT line
    /// is the "we own this file" signal `install()` checks before overwriting.
    static let ownershipMarker = "#!/bin/sh\n# Managed by limpet — safe to delete; regenerated on next launch."

    static var shimPath: String {
        "\(NSHomeDirectory())/.local/bin/limpet"
    }

    /// Whether `path` runs through macOS's App Translocation
    /// (`.../AppTranslocation/<random>/...`) — a randomized, non-persistent
    /// mount Gatekeeper uses for an unmoved, quarantined app. A shim `exec`ing
    /// a path under here will start working and then, the moment the mount
    /// disappears (reboot, app relaunch from its real location), point at
    /// nothing. Exposed so `ConfigSelfTest` can assert the guard without a
    /// real translocated launch.
    static func isTranslocated(_ path: String) -> Bool {
        path.contains("/AppTranslocation/")
    }

    /// Write (or refresh) the shim. No-op, logged, when a file already exists
    /// at `shimPath` that lacks the ownership marker — that's a user's own
    /// file and must never be overwritten. Also a no-op, logged, when
    /// `executablePath` is an App Translocation path — see `isTranslocated`.
    ///
    /// - Parameter shimPath: overridable so `ConfigSelfTest` can target an
    ///   isolated temp path instead of the real `~/.local/bin/limpet`.
    @discardableResult
    static func install(
        executablePath: String = Bundle.main.executablePath ?? "",
        shimPath: String = CLIShimInstaller.shimPath
    ) -> Bool {
        guard !executablePath.isEmpty else { return false }
        guard !isTranslocated(executablePath) else {
            LimpetSettings.debugLog("[CLIShimInstaller] \(executablePath) is an App Translocation path; skipping shim write")
            return false
        }

        let fm = FileManager.default
        let binDir = (shimPath as NSString).deletingLastPathComponent

        if fm.fileExists(atPath: shimPath) {
            guard ownsExistingShim(at: shimPath) else {
                LimpetSettings.debugLog("[CLIShimInstaller] \(shimPath) exists without our marker; leaving untouched")
                return false
            }
        } else {
            guard (try? fm.createDirectory(atPath: binDir, withIntermediateDirectories: true)) != nil else {
                return false
            }
        }

        // With no arguments, print CLI usage instead of `exec`ing the app binary
        // bare — a bare launch starts the GUI/menu-bar app, which is surprising
        // for a command typed in a terminal. `open -a limpet` remains the way
        // to launch the app. Any subcommand is forwarded verbatim.
        // Single-quoted for the shell: inside '...' nothing is special, so a path with
        // `"`, `$` or backticks is passed through literally instead of breaking the
        // shim or being expanded. The shim is what each LaunchAgent executes.
        let quoted = shellSingleQuoted(executablePath)
        let script = """
        \(ownershipMarker)
        if [ "$#" -eq 0 ]; then
          exec \(quoted) help
        fi
        exec \(quoted) "$@"
        """

        do {
            try script.write(toFile: shimPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shimPath)
            return true
        } catch {
            LimpetSettings.debugLog("[CLIShimInstaller] Failed to write shim at \(shimPath): \(error)")
            return false
        }
    }

    /// POSIX single-quoting: wrap in '...' and turn each embedded `'` into `'\\''`.
    static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Whether the file at `path` carries limpet's ownership marker as its
    /// first line. Exposed for the self-test's non-clobber assertion.
    static func ownsExistingShim(at path: String) -> Bool {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return contents.hasPrefix(ownershipMarker)
    }
}
