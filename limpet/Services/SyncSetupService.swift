import Foundation

/// Service for generating and managing sync scripts and launchd configuration
final class SyncSetupService {
    static let shared = SyncSetupService()

    private init() {}

    // MARK: - Constants

    /// Legacy access-check file name.
    ///
    /// limpet no longer uses rclone's `--check-access` (which required a
    /// sentinel file to be uploaded to the remote). Access is now verified by a
    /// read-only pre-flight in the sync script that mutates nothing. This constant
    /// is retained only so leftover files from older versions can be cleaned up.
    static let checkFileName = ".limpet-check"

    /// Default content for the exclude filter file (uses rclone filter-from format)
    /// Each exclude rule must be prefixed with "- "
    private static let defaultExcludeFilter = """
        # macOS metadata
        - ._*
        - .DS_Store
        - .fseventsd

        # Windows thumbs/previews
        - Thumbs.db
        - Thumbs.db:Encryptable
        - ehthumbs.db
        - desktop.ini

        # Synology system folders
        - #recycle/**
        - #snapshot/**
        - @eadir/**

        # Other temp/junk
        - *.tmp
        - *.temp
        - ~$*

        # rclone partial transfer files (prevents cascading .partial.partial... issue)
        - *.partial

        # limpet legacy access-check sentinel (no longer used; excluded so it is never synced)
        - .limpet-check

        # Build/dependency artifacts not worth syncing
        - target/**
        - .build/**
        - node_modules/**
        - .venv/**
        - __pycache__/**
        - DerivedData/**
        """

    // MARK: - Rclone Path Helper

    private func findRclonePath() -> String? {
        RcloneLocator.resolve()
    }

    // MARK: - Public Methods (Profile-based)

    /// Check if a profile's scheduled sync is currently installed
    func isInstalled(profile: SyncProfile) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: profile.plistPath) && fm.fileExists(atPath: profile.configPath)
            && fm.fileExists(atPath: SyncProfile.sharedScriptPath)
    }

    /// Check if a profile's launchd agent is currently loaded
    func isLoaded(profile: SyncProfile) -> Bool {
        let result = runCommand("/bin/launchctl", arguments: ["list", profile.launchdLabel])
        return result.exitCode == 0
    }

    /// Rewrite the shared sync script if the installed copy differs from the
    /// current template. The script is normally only written on profile
    /// install/save, so without this an app update would leave already-installed
    /// profiles running the old script until the next re-save.
    /// Called once at app startup. No-op when no profile has been installed yet.
    func refreshSharedScriptIfChanged() {
        let path = SyncProfile.sharedScriptPath
        guard FileManager.default.fileExists(atPath: path) else { return }

        let current = generateSyncScript()
        let onDisk = try? String(contentsOfFile: path, encoding: .utf8)
        guard onDisk != current else { return }

        do {
            try current.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: path)
            LimpetSettings.debugLog("Refreshed shared sync script (template changed)")
        } catch {
            print("Failed to refresh shared sync script: \(error)")
        }
    }

    /// Generate and install the sync script and launchd plist for a profile
    /// - Parameters:
    ///   - profile: The sync profile to install
    ///   - loadAgent: Whether to load the launchd agent immediately (default: true).
    ///                Set to false if you need to run resync first to avoid race conditions.
    ///   - executablePath: The running app's own executable path. Overridable so
    ///     `ConfigSelfTest` can exercise the translocation guard without a real
    ///     translocated launch; the app never needs to pass this itself.
    ///   - otherProfiles: every profile on disk, read fresh per install, for the
    ///     F6 overlap refusal. Overridable for `ConfigSelfTest`.
    func install(
        profile: SyncProfile,
        loadAgent: Bool = true,
        executablePath: String = Bundle.main.executablePath ?? "",
        otherProfiles: [SyncProfile] = ProfileStore.profilesOnDisk(in: SyncProfile.configDirectory),
        isInstalled: (SyncProfile) -> Bool = SyncProfile.agentInstalled
    ) throws {
        // F4/F6 (limpet-plan.md L4) come FIRST, before anything is written. The
        // self-test relies on this order: it calls install with a refused profile
        // AND a translocated executable path, so if this check ever went missing
        // the translocation guard below still stops install before it touches a
        // real file, and the test sees the wrong error instead of side effects.
        if let reason = profile.validationError
            ?? SyncProfile.overlapError(profile, among: otherProfiles, isInstalled: isInstalled) {
            throw SetupError.refusedProfile(reason)
        }

        // Refuse a translocated launch outright — see `CLIShimInstaller.isTranslocated`.
        // AppTranslocation is a randomized, non-persistent Gatekeeper mount; an agent
        // whose shim was refreshed from it would work until the mount disappears.
        guard !CLIShimInstaller.isTranslocated(executablePath) else {
            throw SetupError.translocatedApp
        }

        // Validate required settings
        guard !profile.rcloneRemote.isEmpty else {
            throw SetupError.missingRcloneRemote
        }
        guard !profile.localSyncPath.isEmpty else {
            throw SetupError.missingLocalPath
        }
        guard !profile.remotePath.isEmpty else {
            throw SetupError.missingRemotePath
        }

        // Refresh the CLI shim before writing the plist below, so the plist's
        // ProgramArguments always points at a shim that execs the CURRENT
        // executable path. Never point an agent at a file limpet doesn't own.
        guard SyncSetupService.canWriteShim(at: CLIShimInstaller.shimPath) else {
            throw SetupError.shimNotOwned
        }
        guard CLIShimInstaller.install(executablePath: executablePath) else {
            throw SetupError.shimInstallFailed
        }

        // Create directories if needed
        try createDirectories(for: profile)

        // Generate and write the shared script (only if it doesn't exist or needs update)
        let script = generateSyncScript()
        try script.write(toFile: SyncProfile.sharedScriptPath, atomically: true, encoding: .utf8)

        // Make script executable
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: SyncProfile.sharedScriptPath
        )

        // Generate and write profile config JSON
        let config = generateProfileConfig(for: profile)
        try config.write(toFile: profile.configPath, atomically: true, encoding: .utf8)

        // Generate and write exclude filter (preserves existing user edits)
        try writeExcludeFilter(for: profile)

        // Generate and write plist
        let plist = generateLaunchdPlist(for: profile)
        try plist.write(toFile: profile.plistPath, atomically: true, encoding: .utf8)

        // Load the launchd agent (unless deferred for resync)
        if loadAgent {
            _ = runCommand("/bin/launchctl", arguments: ["load", profile.plistPath])
        }
    }

    /// Load the launchd agent for a profile (used after deferred install)
    /// - Returns: true if agent loaded successfully
    @discardableResult
    func loadAgent(for profile: SyncProfile) -> Bool {
        let plistPath = profile.plistPath
        print("[limpet] loadAgent called for plist: \(plistPath)")
        print("[limpet] plist exists: \(FileManager.default.fileExists(atPath: plistPath))")

        let result = runCommand("/bin/launchctl", arguments: ["load", plistPath])
        print("[limpet] launchctl load exit code: \(result.exitCode), output: \(result.output)")
        return result.exitCode == 0
    }

    /// Unload the launchd agent WITHOUT removing any files. Used by pause so a
    /// paused profile stops firing scheduled syncs; resume calls `loadAgent`.
    @discardableResult
    func unloadAgent(for profile: SyncProfile) -> Bool {
        let result = runCommand("/bin/launchctl", arguments: ["unload", profile.plistPath])
        print("[limpet] launchctl unload exit code: \(result.exitCode), output: \(result.output)")
        return result.exitCode == 0
    }

    /// Uninstall the sync configuration for a profile
    func uninstall(profile: SyncProfile) throws {
        // Unload the launchd agent first
        _ = runCommand("/bin/launchctl", arguments: ["unload", profile.plistPath])

        // Remove profile-specific files
        let fm = FileManager.default

        if fm.fileExists(atPath: profile.plistPath) {
            try fm.removeItem(atPath: profile.plistPath)
        }

        if fm.fileExists(atPath: profile.configPath) {
            try fm.removeItem(atPath: profile.configPath)
        }

        if fm.fileExists(atPath: profile.filterFilePath) {
            try fm.removeItem(atPath: profile.filterFilePath)
        }

        // The lock file belongs to the launchd-owned watcher, never the GUI
        // (limpet-plan.md L3(c)) — not touched here even on uninstall. The
        // agent was already unloaded above, so nothing can still be holding
        // it; a leftover lock is harmless and the next install's script run
        // reclaims it via its own atomic stale-lock check.

        // Note: We don't remove the shared script as other profiles may use it
        // Note: We don't remove log files to preserve history
    }

    /// Reload the launchd agent for a profile
    func reload(profile: SyncProfile) {
        _ = runCommand("/bin/launchctl", arguments: ["unload", profile.plistPath])
        _ = runCommand("/bin/launchctl", arguments: ["load", profile.plistPath])
    }

    /// Update just the profile config (without reinstalling the script)
    func updateConfig(for profile: SyncProfile) throws {
        let config = generateProfileConfig(for: profile)
        try config.write(toFile: profile.configPath, atomically: true, encoding: .utf8)
    }

    /// Initializes sync paths by creating the local directory and removing any
    /// obsolete `.limpet-check` files left behind by older versions.
    /// - Returns: nil on success, error message on failure
    func initializeSyncPaths(for profile: SyncProfile) -> String? {
        let fileManager = FileManager.default

        // 1. Local directory. For localToRemote it is the source of truth: creating a
        // missing one would hand the watcher an empty source, and the first sync would
        // delete everything on the remote. So refuse instead. For remoteToLocal it is
        // the destination, and creating it is correct.
        if !fileManager.fileExists(atPath: profile.localSyncPath) {
            if profile.syncDirection == .localToRemote {
                return "Local folder does not exist: \(profile.localSyncPath). "
                    + "limpet will not create a source folder, because syncing an empty "
                    + "source would delete everything on the remote."
            }
            do {
                try fileManager.createDirectory(
                    atPath: profile.localSyncPath, withIntermediateDirectories: true)
            } catch {
                return "Failed to create local directory: \(error.localizedDescription)"
            }
        }

        // 2. Remove any obsolete .limpet-check files (best-effort).
        //    limpet no longer relies on rclone --check-access, so nothing is
        //    written to the remote — access is verified read-only in the sync script.
        cleanupLegacyCheckFiles(for: profile)

        return nil  // Success
    }

    /// Best-effort, recursive removal of the legacy `.limpet-check` access-check file
    /// from the local and remote trees (root and all nested directories).
    ///
    /// limpet previously uploaded this sentinel so rclone's `--check-access`
    /// could verify both sides were mounted. That mechanism has been replaced by a
    /// read-only pre-flight in the sync script, so the file is now obsolete. limpet
    /// only ever wrote one at each root, but we scan the whole tree to also catch any
    /// copies a user (or an older/manual setup) may have scattered into subdirectories.
    ///
    /// Safe to call repeatedly; never throws. The remote deletion lists the remote, so
    /// call this from a background context.
    func cleanupLegacyCheckFiles(for profile: SyncProfile, rclonePath: String? = nil) {
        let fileManager = FileManager.default

        // Local: remove every .limpet-check at any depth under the sync root.
        if let enumerator = fileManager.enumerator(atPath: profile.localSyncPath) {
            for case let relativePath as String in enumerator
            where (relativePath as NSString).lastPathComponent == Self.checkFileName {
                let fullPath = (profile.localSyncPath as NSString).appendingPathComponent(relativePath)
                try? fileManager.removeItem(atPath: fullPath)
            }
        }

        // Remote: delete every .limpet-check at any depth. Skip if we can't resolve a
        // path/remote. The `--include <basename>` filter matches the file at any level and
        // (because an include is present) rclone implicitly excludes everything else, so no
        // user data is ever touched.
        guard let rclonePath = rclonePath ?? findRclonePath(),
              !profile.rcloneRemote.isEmpty, !profile.remotePath.isEmpty else { return }

        let remoteRoot = "\(profile.rcloneRemote):\(profile.remotePath)"
        let skipCert = RcloneConfigService.shared.readRemoteConfig(name: profile.rcloneRemote)?.values["no_check_certificate"] == "true"
        // F3: best-effort cleanup — a keychain read failure just skips it.
        guard let environment = RcloneConfigService.shared.processEnvironment(
            forRemote: profile.rcloneRemote, log: { LimpetSettings.debugLog($0) }) else { return }
        _ = runRcloneSimple(
            rclonePath: rclonePath,
            args: ["delete", remoteRoot, "--include", Self.checkFileName],
            skipCert: skipCert,
            environment: environment)
    }

    /// Run rclone with given args, return exit code (or -1 on launch failure).
    /// Adds connection/operation timeouts so unreachable remotes fail within ~15s.
    private func runRcloneSimple(rclonePath: String, args: [String], skipCert: Bool, environment: [String: String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: rclonePath)
        process.environment = environment
        var fullArgs = args + ["--contimeout", "5s", "--timeout", "15s", "--retries", "1", "--low-level-retries", "1"]
        if skipCert { fullArgs.append("--no-check-certificate") }
        process.arguments = fullArgs
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    // MARK: - Legacy Methods (for backward compatibility during migration)

    /// Check if the legacy single-profile scheduled sync is installed
    func isLegacyInstalled() -> Bool {
        let plistPath = "\(NSHomeDirectory())/Library/LaunchAgents/com.nanako.limpet.watch.plist"
        let scriptPath = "\(NSHomeDirectory())/.local/bin/limpet-sync.sh"

        // Check if it's the old-style script (without config file support)
        if FileManager.default.fileExists(atPath: scriptPath),
            let content = try? String(contentsOfFile: scriptPath, encoding: .utf8)
        {
            // Old scripts have hardcoded REMOTE= values, new ones read from config
            return content.contains("REMOTE=\"") && !content.contains("CONFIG_FILE=")
        }

        return FileManager.default.fileExists(atPath: plistPath)
    }

    /// Uninstall legacy single-profile configuration
    func uninstallLegacy() throws {
        let plistPath = "\(NSHomeDirectory())/Library/LaunchAgents/com.nanako.limpet.watch.plist"

        _ = runCommand("/bin/launchctl", arguments: ["unload", plistPath])

        let fm = FileManager.default
        if fm.fileExists(atPath: plistPath) {
            try fm.removeItem(atPath: plistPath)
        }
        // Don't remove the script path since we'll reuse it
    }

    // MARK: - Script Generation

    /// Whether generated scripts honour `RCLONE_BIN` from the environment: Debug
    /// builds only. The self-test runs only in Debug, so it can exercise the
    /// Release variant through `generateSyncScript(honorRcloneBinOverride:
    /// false)` but cannot observe this constant's Release value itself.
    static let honorsRcloneBinOverride: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    /// Generate the shared sync script that reads config from JSON
    /// Generate the shared sync script. Not private — `ConfigSelfTest` reads
    /// this text directly to assert its exit-code/flag shape (limpet-plan.md
    /// L3(b)) without writing it to disk.
    func generateSyncScript(honorRcloneBinOverride: Bool = SyncSetupService.honorsRcloneBinOverride) -> String {
        // Carried from L4.0 (limpet-plan.md L4): an RCLONE_BIN from the
        // environment exists only for the self-test's stub rclone. A shipped
        // script must never run whatever binary an environment variable names,
        // so outside Debug builds the variable is cleared before the search.
        let rcloneBinSelection = honorRcloneBinOverride
            ? #"if [[ -z "${RCLONE_BIN:-}" || ! -x "$RCLONE_BIN" ]]; then"#
            : #"RCLONE_BIN=""; if true; then"#
        return """
            #!/bin/bash
            # limpet Sync Script
            # This script reads profile configuration from a JSON file
            # DO NOT EDIT - This file is managed by limpet

            export PATH="/usr/sbin:/usr/bin:/bin:$PATH"

            CONFIG_FILE="$1"

            if [[ -z "$CONFIG_FILE" || ! -f "$CONFIG_FILE" ]]; then
                echo "Error: Config file not specified or not found: $CONFIG_FILE"
                exit 1
            fi

            # Parse JSON config using Python (available on all macOS)
            parse_json() {
                python3 -c "import json,sys; d=json.load(open('$CONFIG_FILE')); print(d.get('$1', '$2'))"
            }

            REMOTE=$(parse_json "remote" "")
            LOCAL_PATH=$(parse_json "localPath" "")
            LOG_FILE=$(parse_json "logPath" "")
            LOCK_FILE=$(parse_json "lockFile" "")
            DRIVE_PATH=$(parse_json "drivePath" "")
            ADDITIONAL_FLAGS=$(parse_json "additionalFlags" "")
            FILTER_FILE=$(parse_json "filterPath" "")
            SYNC_DIRECTION=$(parse_json "syncDirection" "localToRemote")
            REMOTE_PATH=$(parse_json "remotePath" "")
            TRANSFERS=$(parse_json "transfers" "16")

            if [[ -z "$REMOTE" || -z "$LOCAL_PATH" ]]; then
                echo "Error: Invalid config - missing remote or localPath"
                exit 1
            fi

            # additionalFlags is whitespace-separated and passed to rclone as literal
            # argv elements (documented in CLAUDE.md and the profile schema) — never
            # re-parsed as shell syntax, so there is no quoting or expansion left for
            # a flag to use. A quoted flag like `--exclude "*.tmp"` would otherwise
            # reach rclone as the single literal token `"*.tmp"` (quotes included),
            # which matches nothing and silently starts syncing files meant to be
            # excluded; `--log-file ~/x.log` would create a directory literally named
            # `~`. Refuse instead of doing either silently: a quote, $, backtick, or
            # a token starting with ~ exits 64 before rclone is ever invoked. Write
            # flags as --flag=value, e.g. --exclude=*.tmp.
            # `transfers` reaches bash arithmetic below, which would run command
            # substitutions inside an array subscript (`a[$(cmd)]`); accept digits only.
            if [[ ! "$TRANSFERS" =~ ^[0-9]+$ ]]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Refusing to sync: transfers must be a whole number" >> "$LOG_FILE"
                exit 64
            fi
            CHECKERS=$((TRANSFERS * 2))

            # maxDelete (0 = no limit) is written by limpet from an Int; anything
            # else in the derived config is refused rather than passed on.
            MAX_DELETE=$(parse_json "maxDelete" "0")
            if [[ ! "$MAX_DELETE" =~ ^(0|[1-9][0-9]*)$ ]]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Refusing to sync: maxDelete must be a whole number" >> "$LOG_FILE"
                exit 64
            fi

            # `read -r -a` only consumes the first line, so a flag after a newline would
            # be dropped silently (turning `--exclude=*.tmp` + newline + `--dry-run` into
            # a real sync). Refuse instead.
            if [[ "$ADDITIONAL_FLAGS" == *$'\\n'* || "$ADDITIONAL_FLAGS" == *$'\\r'* ]]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Refusing to sync: additionalRcloneFlags contains a line break; put all flags on one line" >> "$LOG_FILE"
                exit 64
            fi

            if [[ -n "$ADDITIONAL_FLAGS" ]]; then
                read -r -a ADDITIONAL_FLAGS_ARRAY <<< "$ADDITIONAL_FLAGS"
            else
                ADDITIONAL_FLAGS_ARRAY=()
            fi
            for flag_token in "${ADDITIONAL_FLAGS_ARRAY[@]}"; do
                if [[ "$flag_token" == *'"'* || "$flag_token" == *"'"* || "$flag_token" == *'`'* || "$flag_token" == *'$'* || "$flag_token" == '~'* ]]; then
                    echo "$(date '+%Y-%m-%d %H:%M:%S') - Refusing to sync: additionalRcloneFlags contains quotes, dollar signs, backticks or ~, which limpet passes to rclone literally. Write flags as --flag=value without quotes, e.g. --exclude=*.tmp" >> "$LOG_FILE"
                    exit 64
                fi
                # --dump headers/bodies/auth writes request contents to the log; for a
                # native B2 remote --dump auth includes the application key (Basic auth).
                # Not measured, since no network is used in tests; refused for every remote.
                if [[ "$flag_token" == --dump* ]]; then
                    echo "$(date '+%Y-%m-%d %H:%M:%S') - Refusing to sync: additionalRcloneFlags contains --dump, which can write credentials into the log" >> "$LOG_FILE"
                    exit 64
                fi
            done

            # Find rclone binary. Cover the common package-manager locations,
            # including nix-darwin's system and per-user profiles which live outside
            # Homebrew's dirs (issue #53). $USER can be unset under launchd, so derive
            # it. Fall back to a PATH lookup for any other install layout.
            RCLONE_USER="${USER:-$(id -un)}"
            # Debug builds honor an RCLONE_BIN already set in the environment (the
            # self-test's stub); other builds always search the candidates below.
            \(rcloneBinSelection)
                RCLONE_BIN=""
                RCLONE_CANDIDATES=(
                    /opt/homebrew/bin/rclone
                    /usr/local/bin/rclone
                    /run/current-system/sw/bin/rclone
                    "/etc/profiles/per-user/$RCLONE_USER/bin/rclone"
                    "$HOME/.nix-profile/bin/rclone"
                    /usr/bin/rclone
                )
                for path in "${RCLONE_CANDIDATES[@]}"; do
                    if [[ -x "$path" ]]; then
                        RCLONE_BIN="$path"
                        break
                    fi
                done
            fi

            if [[ -z "$RCLONE_BIN" ]]; then
                RCLONE_BIN=$(command -v rclone 2>/dev/null || true)
            fi

            if [[ -z "$RCLONE_BIN" ]]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: rclone not found" >> "$LOG_FILE"
                exit 1
            fi

            # Helper: check if a remote has no_check_certificate set in rclone config
            check_no_cert() {
                local remote_name="$1"
                local rclone_conf="$HOME/.config/rclone/rclone.conf"
                if [[ -f "$rclone_conf" ]]; then
                    local in_section=false
                    while IFS= read -r line; do
                        if [[ "$line" == "[$remote_name]" ]]; then
                            in_section=true
                        elif [[ "$line" =~ ^\\[.+\\]$ ]] && $in_section; then
                            break
                        elif $in_section && [[ "$line" == *"no_check_certificate"*"="*"true"* ]]; then
                            echo "--no-check-certificate"
                            return
                        fi
                    done < "$rclone_conf"
                fi
            }

            REMOTE_NAME="${REMOTE%%:*}"
            NO_CHECK_CERT=$(check_no_cert "$REMOTE_NAME")

            # Check if drive is mounted (if configured)
            if [[ -n "$DRIVE_PATH" && ! -d "$DRIVE_PATH" ]]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Drive not mounted, skipping sync" >> "$LOG_FILE"
                exit 0
            fi

            # Acquire the lock ATOMICALLY. `set -o noclobber` makes the '>'
            # redirection fail if the file already exists, so the check and the
            # write are a single atomic step — closing the check-then-write
            # (TOCTOU) race where two launchd/manual runs could both pass the
            # old `[[ -f ]]` test and start concurrently. The PID is still stored
            # as the file's contents, so the app's lock readers are unchanged.
            acquire_lock() {
                ( set -o noclobber; echo $$ > "$LOCK_FILE" ) 2>/dev/null
            }

            if ! acquire_lock; then
                PID=$(cat "$LOCK_FILE" 2>/dev/null)
                if [[ -n "$PID" ]] && ps -p "$PID" > /dev/null 2>&1; then
                    echo "$(date '+%Y-%m-%d %H:%M:%S') - Sync already running (PID $PID), skipping" >> "$LOG_FILE"
                    exit 75
                fi
                # Lock owner is gone — reclaim the stale lock and retry once.
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Removing stale lock (PID ${PID:-unknown} not running)" >> "$LOG_FILE"
                rm -f "$LOCK_FILE"
                if ! acquire_lock; then
                    echo "$(date '+%Y-%m-%d %H:%M:%S') - Could not acquire lock, skipping" >> "$LOG_FILE"
                    exit 75
                fi
            fi
            trap 'rm -f "$LOCK_FILE"' EXIT

            # A missing local source must NEVER be silently created (upstream
            # unconditionally recreated the source directory here, so a moved
            # or unmounted source became an empty one and the next sync
            # deleted the entire remote). Log and bail instead; the watcher's
            # own missing-source recheck starts syncing again once the path
            # comes back.
            if [[ ! -d "$LOCAL_PATH" ]]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Source missing: $LOCAL_PATH" >> "$LOG_FILE"
                exit 2
            fi

            # One-way sync. Built as an argv array and run directly — never a
            # string re-interpreted by the shell (a value like `~/Data$old` in
            # LOCAL_PATH/REMOTE/FILTER_FILE must never be re-expanded, or `$old`
            # collapses to empty and the wrong directory gets synced/deleted).
            if [[ "$SYNC_DIRECTION" == "localToRemote" ]]; then
                # Local is source, remote is destination (backup/upload)
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting sync (local → remote)" >> "$LOG_FILE"
                cmd=("$RCLONE_BIN" sync "$LOCAL_PATH" "$REMOTE" --verbose --use-json-log --stats 2s --filter-from "$FILTER_FILE" --links --fast-list --transfers "$TRANSFERS" --checkers "$CHECKERS")
            else
                # Remote is source, local is destination (download/mirror)
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting sync (remote → local)" >> "$LOG_FILE"
                cmd=("$RCLONE_BIN" sync "$REMOTE" "$LOCAL_PATH" --verbose --use-json-log --stats 2s --filter-from "$FILTER_FILE" --links --fast-list --transfers "$TRANSFERS" --checkers "$CHECKERS")
            fi

            if [[ -n "$NO_CHECK_CERT" ]]; then
                cmd+=("$NO_CHECK_CERT")
            fi

            if [[ "$MAX_DELETE" != "0" ]]; then
                cmd+=(--max-delete "$MAX_DELETE")
            fi

            # additionalFlags was already validated and split into
            # ADDITIONAL_FLAGS_ARRAY above; append its tokens as-is.
            if [[ ${#ADDITIONAL_FLAGS_ARRAY[@]} -gt 0 ]]; then
                cmd+=("${ADDITIONAL_FLAGS_ARRAY[@]}")
            fi

            # This run's own output, so the delete-limit check below reads only
            # this run and never an older run's lines in the profile log.
            RUN_OUTPUT=$(mktemp "${TMPDIR:-/tmp}/limpet-run.XXXXXX") || {
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Refusing to sync: could not create a temporary file" >> "$LOG_FILE"
                exit 1
            }
            trap 'rm -f "$LOCK_FILE" "$RUN_OUTPUT"' EXIT

            # Run sync command
            "${cmd[@]}" 2>&1 | tee -a "$LOG_FILE" "$RUN_OUTPUT"

            EXIT_CODE=${PIPESTATUS[0]}

            # --max-delete tripped: stop for good (exit 76, the watcher then keeps
            # a persistent marker). Measured 2026-09-26 with rclone 1.75.1, local to
            # local, 5 files removed from the source, --max-delete 2: exit 7, exactly
            # 2 files deleted, each refused delete logged as "Got fatal error on
            # delete: --max-delete threshold reached" (text and JSON log alike).
            # Exit 7 is every fatal error, so the code AND the message must match.
            if [[ $EXIT_CODE -eq 7 ]] && grep -qF -- 'Got fatal error on delete: --max-delete threshold reached' "$RUN_OUTPUT"; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Delete limit reached: rclone stopped at --max-delete $MAX_DELETE; limpet will not sync this profile again until the limit is cleared (limpet profile clear-delete-limit, or the menu)" >> "$LOG_FILE"
                EXIT_CODE=76
            fi

            if [[ $EXIT_CODE -eq 0 ]]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Sync completed successfully" >> "$LOG_FILE"
            else
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Sync failed with exit code $EXIT_CODE" >> "$LOG_FILE"
            fi

            echo "" >> "$LOG_FILE"

            exit "$EXIT_CODE"
            """
    }

    /// `--max-delete` for `profile`, or 0 for none (limpet-plan.md L4 F6): only
    /// where a wrong delete cannot be undone. MEGA S4 and Cloudflare R2 keep no
    /// deleted versions, so always; any other s3 provider (AWS, MinIO, Other)
    /// unless the user states versioning is on. B2 hides instead of deleting,
    /// and other remote types keep today's behaviour. `remoteSection` is the
    /// remote's rclone.conf section (`nil` = not found = no limit).
    static func maxDeleteArgument(for profile: SyncProfile, remoteSection: [String: String]?) -> Int {
        guard remoteSection?["type"] == "s3" else { return 0 }
        let neverVersioned = ["Mega", "Cloudflare"].contains(remoteSection?["provider"] ?? "")
        return neverVersioned || !profile.remoteVersioning ? profile.maxDelete : 0
    }

    /// Generate profile-specific JSON config.
    /// Not private — `ConfigSelfTest` calls this directly to verify the
    /// derived config's key set stays frozen (AC-2) without going through
    /// the side-effecting `install(profile:)` (which touches launchd).
    /// `rcloneConfig` is where the remote's type/provider is read for
    /// `maxDelete`; the self-test passes a scratch one.
    func generateProfileConfig(for profile: SyncProfile, rcloneConfig: RcloneConfigService = .shared) -> String {
        let remoteSection = rcloneConfig.section(named: String(profile.rcloneRemote.prefix { $0 != ":" }))
        let config: [String: Any] = [
            "profileId": profile.id.uuidString,
            "name": profile.name,
            "remote": profile.fullRemotePath,
            "localPath": profile.localSyncPath,
            "logPath": profile.logPath,
            "lockFile": profile.lockFilePath,
            "drivePath": profile.drivePathToMonitor,
            "additionalFlags": profile.additionalRcloneFlags,
            "filterPath": profile.filterFilePath,
            "syncIntervalMinutes": profile.syncIntervalMinutes,
            "syncDirection": profile.syncDirection.rawValue,
            "remotePath": profile.remotePath,
            "transfers": profile.transfers,
            "maxDelete": Self.maxDeleteArgument(for: profile, remoteSection: remoteSection),
        ]

        if let data = try? JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted, .sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        {
            return json
        }
        return "{}"
    }

    /// Generate the per-profile LaunchAgent plist. Not private — `ConfigSelfTest`
    /// calls this directly to verify its shape without touching real launchd
    /// (AC for limpet-plan.md L3(c)).
    ///
    /// `KeepAlive=true` + `RunAtLoad=true` and NO `StartInterval`: the agent
    /// runs `limpet watch <shortId>` as a long-lived process that is the SOLE
    /// owner of this profile's scheduling — see `SyncWatchDaemon`. launchd
    /// restarts it if it ever exits, which doubles as the "watcher crashed"
    /// recovery path. stdout/stderr go to a separate `limpet-launchd-*.log`,
    /// never the profile log the GUI reads — the watcher's child processes
    /// already tee their own output into the profile log themselves.
    ///
    /// `ProgramArguments[0]` points at the `~/.local/bin/limpet` CLI shim
    /// (`CLIShimInstaller`), never the app's own executable path directly.
    /// The app bundle can move after install, or macOS can run it once from a
    /// randomized, non-persistent App Translocation path — either way a path
    /// baked into the plist would eventually stop resolving and silently kill
    /// realtime sync. The shim is a stable, `exec`-refreshed indirection:
    /// `install(profile:)` refreshes it right before writing this plist, so
    /// launchd always resolves through a file that gets rewritten to point at
    /// wherever the app currently lives. The shim's `exec` (not fork) is what
    /// lets `launchctl kill SIGUSR1 gui/<uid>/<label>` keep reaching the
    /// watcher process — it inherits the agent's PID.
    func generateLaunchdPlist(
        for profile: SyncProfile,
        shimPath: String = CLIShimInstaller.shimPath
    ) -> String {
        let logDir = (profile.logPath as NSString).deletingLastPathComponent
        let launchdLogPath = logDir + "/limpet-launchd-\(profile.shortId).log"
        let path = "/opt/homebrew/bin:/usr/local/bin:/run/current-system/sw/bin:"
            + "/etc/profiles/per-user/\(NSUserName())/bin:\(NSHomeDirectory())/.nix-profile/bin:/usr/bin:/bin"

        // Serialized rather than templated, so every string value (the shim path in
        // particular, which may contain `&` or `<`) is XML-escaped and the plist stays
        // loadable wherever the app lives.
        let plist: [String: Any] = [
            "Label": profile.launchdLabel,
            "ProgramArguments": [shimPath, "watch", profile.shortId],
            "KeepAlive": true,
            "RunAtLoad": true,
            "StandardOutPath": launchdLogPath,
            "StandardErrorPath": launchdLogPath,
            "EnvironmentVariables": ["PATH": path],
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
              let xml = String(data: data, encoding: .utf8) else {
            // Only reachable if the dictionary above held a non-plist type.
            preconditionFailure("launchd plist for \(profile.shortId) failed to serialize")
        }
        return xml
    }

    // MARK: - Helpers

    /// Whether `install(profile:)` may (re)write the CLI shim at `shimPath`:
    /// true when nothing is there yet, or when what's there already carries
    /// limpet's ownership marker. Exposed (static, no side effects) so
    /// `ConfigSelfTest` can verify the guard against a temp path instead of
    /// the real `~/.local/bin/limpet`.
    static func canWriteShim(at shimPath: String) -> Bool {
        !FileManager.default.fileExists(atPath: shimPath) || CLIShimInstaller.ownsExistingShim(at: shimPath)
    }

    private func createDirectories(for profile: SyncProfile) throws {
        let fm = FileManager.default

        // Create ~/.local/bin if needed
        let binDir = (SyncProfile.sharedScriptPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: binDir) {
            try fm.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        }

        // Create ~/.local/log if needed
        let logDir = (profile.logPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: logDir) {
            try fm.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        }

        // Create ~/.config/limpet/profiles if needed
        if !fm.fileExists(atPath: SyncProfile.configDirectory) {
            try fm.createDirectory(
                atPath: SyncProfile.configDirectory, withIntermediateDirectories: true)
        }

        // LaunchAgents directory should already exist, but just in case
        let agentsDir = (profile.plistPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: agentsDir) {
            try fm.createDirectory(atPath: agentsDir, withIntermediateDirectories: true)
        }
    }

    /// Write the exclude filter file for a profile (only if it doesn't exist)
    private func writeExcludeFilter(for profile: SyncProfile) throws {
        let filterPath = profile.filterFilePath
        // Only create if it doesn't exist (preserve user edits)
        if !FileManager.default.fileExists(atPath: filterPath) {
            try Self.defaultExcludeFilter.write(
                toFile: filterPath, atomically: true, encoding: .utf8)
        }
    }

    private func runCommand(_ command: String, arguments: [String]) -> (
        output: String, exitCode: Int32
    ) {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ("", -1)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        return (output, process.terminationStatus)
    }

    // MARK: - Errors

    enum SetupError: LocalizedError {
        case missingRcloneRemote
        case missingLocalPath
        case missingRemotePath
        case scriptGenerationFailed
        case plistGenerationFailed
        case translocatedApp
        case shimNotOwned
        case shimInstallFailed
        case refusedProfile(String)

        var errorDescription: String? {
            switch self {
            case .missingRcloneRemote:
                return "Rclone remote is required"
            case .missingLocalPath:
                return "Local sync path is required"
            case .missingRemotePath:
                return "Remote folder path is required"
            case .scriptGenerationFailed:
                return "Failed to generate sync script"
            case .plistGenerationFailed:
                return "Failed to generate launchd plist"
            case .translocatedApp:
                return "limpet is running from a temporary, randomized location (macOS App "
                    + "Translocation) and can't install a reliable background sync agent from "
                    + "here. Move limpet.app to /Applications and relaunch it, then try again."
            case .shimNotOwned:
                return "~/.local/bin/limpet already exists and wasn't created by limpet, so it "
                    + "won't be overwritten. Move or remove that file, then try again."
            case .shimInstallFailed:
                return "Failed to write the limpet CLI shim at ~/.local/bin/limpet"
            case .refusedProfile(let reason):
                return "Refusing to install: \(reason)"
            }
        }
    }
}
