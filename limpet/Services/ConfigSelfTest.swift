import Foundation

#if DEBUG

/// Host self-test suite for the file-backed configuration system.
///
/// limpet deliberately has no XCTest target (see CLAUDE.md — Option A:
/// script/host-check based tests). This runs as `limpet --self-test`,
/// printing one `AC-n <slug>: PASS`/`FAIL <reason>` line per acceptance
/// criterion and exiting non-zero if any assertion failed. `checks.yaml`
/// greps these EXACT strings — do not change them without updating both.
///
/// Everything here runs against temp directories and isolated `UserDefaults`
/// suites under `$TMPDIR/limpet-selftest/` — never the real
/// `~/.config/limpet` or `UserDefaults.standard` — so running the self-test
/// can never corrupt a real install.
///
/// `@MainActor`: `ProfileStore` is MainActor-isolated, and this suite
/// constructs isolated `ProfileStore` instances directly. `LimpetApp.init()`
/// (the sole caller) is itself MainActor-isolated (SwiftUI's `App` protocol),
/// so calling `run()` synchronously from there is a same-actor call.
@MainActor
enum ConfigSelfTest {
    /// Root directory for this run's isolated fixtures.
    /// Fixed at `$TMPDIR/limpet-selftest` (not a per-run UUID subdirectory)
    /// because `checks.yaml`'s AC-9 check greps this EXACT path after the
    /// process exits.
    static var selfTestRoot: String {
        let tmpDir = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        return tmpDir.hasSuffix("/") ? "\(tmpDir)limpet-selftest" : "\(tmpDir)/limpet-selftest"
    }

    /// Names, sizes and modification times of every limpet-owned entry in the
    /// real home, compared before and after a run by AC-GUARD.
    private static func realHomeFingerprint(_ home: String) -> Set<String> {
        let fm = FileManager.default
        var out = Set<String>()
        func add(_ path: String) {
            guard let a = try? fm.attributesOfItem(atPath: path) else { return }
            let size = (a[.size] as? NSNumber)?.int64Value ?? -1
            let mtime = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            out.insert("\(path) \(size) \(mtime)")
        }
        let agents = "\(home)/Library/LaunchAgents"
        for name in (try? fm.contentsOfDirectory(atPath: agents)) ?? [] where name.hasPrefix("com.nanako.limpet") {
            add("\(agents)/\(name)")
        }
        let bin = "\(home)/.local/bin"
        for name in (try? fm.contentsOfDirectory(atPath: bin)) ?? [] where name.hasPrefix("limpet") {
            add("\(bin)/\(name)")
        }
        for dir in ["\(home)/.config/limpet", "\(home)/.local/state/limpet"] {
            add(dir)
            if let e = fm.enumerator(atPath: dir) {
                for case let rel as String in e { add("\(dir)/\(rel)") }
            }
        }
        add("\(home)/.config/rclone/rclone.conf")
        return out
    }

    /// Run every self-test. Returns 0 if all passed, 1 otherwise.
    static func run() -> Int32 {
        // No self-test may reach a real keychain (see makeSecurityStub).
        KeychainSecretStore.realKeychainForbidden = true
        // No self-test may write the real home or change launchd state: every
        // per-user path resolves under a temp home, and launchctl load/unload/
        // kill/bootstrap/bootout are refused and recorded (SelfTestGuard).
        let realHome = NSHomeDirectory()
        let before = realHomeFingerprint(realHome)
        SelfTestGuard.active = true
        // Start clean so a previous run's leftovers can't mask a real failure.
        try? FileManager.default.removeItem(atPath: selfTestRoot)
        try? FileManager.default.createDirectory(atPath: selfTestRoot, withIntermediateDirectories: true)
        LimpetPaths.home = "\(selfTestRoot)/home"
        try? FileManager.default.createDirectory(atPath: LimpetPaths.home, withIntermediateDirectories: true)

        var allPassed = true
        let checks: [() -> Bool] = [
            testProfileFileFullFields,
            testDerivedJSONFrozen,
            testReconcileDelta,
            testPartialDecode,
            testSelfWriteSuppression,
            testMigrationV3,
            testFileAuthoritativeReads,
            testSettingsSafeKeys,
            testSchemaInstalledAndReferenced,
            testIsolatedLaunchAtLogin,
            testDeleteDurable,
            testMigrationIntegrity,
            testExternalCreateEnabled,
            testExternalCreateDisabledNoInstall,
            testExternalCreateGarbageIgnored,
            testExternalCreateCanonicalNoLoop,
            testCLIArgParsing,
            testCLIDispatchGate,
            testCLIWriteCommands,
            testCLILifecycleCommands,
            testCLIProfileSetAndShow,
            testDoctorPureChecks,
            testCLIResolveAndList,
            testShimInstallIdempotentNonClobber,
            testWatchScheduler,
            testGeneratedScriptText,
            testGeneratedScriptNoEval,
            testGeneratedScriptRunsWithoutExpandingConfigValues,
            testGeneratedScriptPropagatesRcloneExitCode,
            testGeneratedScriptRefusesQuotedAdditionalFlags,
            testGeneratedScriptAcceptsFlagEqualsValueForm,
            testGeneratedPlistShape,
            testMissingSourceIsNotCreated,
            testScriptRefusesNonNumericTransfers,
            testScriptRefusesMultilineFlags,
            testScriptRefusesDumpFlags,
            testShimQuotesHostilePath,
            testTransfersChangeReinstalls,
            testTranslocatedAppRefused,
            testInstallRefusesNonOwnedShim,
            testRemoteSpecRefusedAtDecodeAndWrite,
            testRemoteSpecRefusedAtCLI,
            testRefusedAtInstall,
            testOverlapRefused,
            testWatcherRefusesBeforeEveryRun,
            testKeychainRemoteCreatedThroughSecurityOnly,
            testKeychainRemoteRefusals,
            testSecretInjectionHelper,
            testCLIRemoteAdd,
            testWizardProvidersRemapAndRoute,
            testScriptMapsMaxDeleteTo76,
            testMaxDeleteOnlyForNonVersionedProviders,
            testWatcherStopsAtDeleteLimit,
            testCLIClearDeleteLimit,
            testDoctorWarnsB2WithoutLifecycle,
            testTransfersRange,
            testRefusedDropQuarantined,
            testOverlapOnlyAmongEnabledInstalled,
            testProfileChangeRefusedBeforePersist,
            testKeychainRemoteEditDeleteConsistency,
            testKeychainLockedNoRead,
            testDoctorWarnsStaleMaxDelete,
            testRefusedExternalEditRestored,
            testWizardRetryKeepsProfileId,
            testPruneKeepsUndecodableFile,
            testEditKeepsNonSecretRequiredErrors,
            testKeychainLockedLogThrottled,
            testKeychainLargeOutputDrained,
            testSourceMissingParses,
            testSourceMissingClearsOnRecheck,
            testRcloneLogEntryFileChangeMapping,
            testExitCodeErrorText,
            testCLIWriteMarkerClassification,
            testAppWritesLeaveMarkerDirEmpty,
            testReconcileClosuresDispatch,
            testCLIWriteClassifiedThroughRealWriter,
            testSyncAlreadyRunningSetsSyncing,
            testInstallThrowsOnLaunchctlLoadFailure,
            testTerminateChildProcessGroupKillsRealGroup,
            testSpawnTerminationRaceClosesWithoutOrphan,
            testCLIWriteMarkerIgnoresNonHashFilenames,
            testInstallRefreshesLoadedAgentAndCleansUpFailure,
            testConfigFileWatcherRealDispatchOnCLIMarkerHit,
            testTrashRootDerivation,
            testTrashDaysChangeReinstalls,
            testTrashPurge,
            testTrashExitSeventySix,
            testTrashBackupNamingAndRestore,
            testTrashRestoreValidationAndNewestMatch,
            testRealDeleteSurfacesOnceOverwriteSurfacesZero,
            testTrashCommandsUsePathFormulaIgnoringActiveRule,
            testTrashRestoreRclonelinkSymlinkAndAtomicRename,
            testTrashPurgeCertFlagsFailureAndDryRunVariants,
            testTrashRestoreSymlinkContainment,
            testForcedRestoreReplaceIsAtomic,
            testCoalesceLogEventsAndFIFODelivery,
            testExitCodeErrorTextStalled,
            testWatchdogDecision,
            testScriptLogRotation,
            testLogWatcherRotationAndStop,
            testLogWatcherMissingPathNeverCreated,
            testPurgeStatsLineIsInertAndFlagged,
            testStartupTailStaysIdle,
            testLogWatcherSplitMultibyteLine,
            testStalledLineIsAFailureMarker,
            testStalledSyncWatchdogEndToEnd,
            testWatcherSelfRestartDecision,
            testWatcherStartupRefreshesStaleScript,
        ]

        for check in checks {
            if !check() { allPassed = false }
        }

        // AC-GUARD: the run left the real home and launchd alone.
        let after = realHomeFingerprint(realHome)
        let changed = before.symmetricDifference(after).sorted()
        if !report("AC-GUARD", "real-home-and-launchd-untouched",
                   changed.isEmpty && SelfTestGuard.violations.isEmpty,
                   "(changed: \(changed.prefix(5)); refused launchctl: \(SelfTestGuard.violations.prefix(5)))") {
            allPassed = false
        }
        return allPassed ? 0 : 1
    }

    // MARK: - Helpers

    private static func report(_ id: String, _ slug: String, _ passed: Bool, _ detail: String = "") -> Bool {
        if passed {
            print("\(id) \(slug): PASS")
        } else {
            print("\(id) \(slug): FAIL \(detail)")
        }
        return passed
    }

    private static func sampleProfile(
        id: UUID = UUID(),
        name: String = "SelfTest Profile",
        isEnabled: Bool = true,
        isMuted: Bool = true
    ) -> SyncProfile {
        SyncProfile(
            id: id,
            name: name,
            rcloneRemote: "selftest-fixture-remote:",
            remotePath: "SelfTest",
            localSyncPath: "/tmp/limpet-selftest-local",
            syncIntervalMinutes: 15,
            isEnabled: isEnabled,
            isMuted: isMuted
        )
    }

    // MARK: - AC-1 — profile file carries full fields

    private static func testProfileFileFullFields() -> Bool {
        let dir = "\(selfTestRoot)/ac1-profiles"
        let store = ProfileStore(
            profilesDirectory: dir,
            defaults: UserDefaults(suiteName: "com.nanako.limpet.selftest.ac1.\(UUID().uuidString)")!
        )
        let profile = sampleProfile()
        store.add(profile)

        let path = "\(dir)/\(profile.shortId).profile.json"
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return report("AC-1", "profile-file-full-fields", false, "(file not written or not valid JSON at \(path))")
        }

        let hasKeys = json["isEnabled"] != nil && json["isMuted"] != nil
        guard hasKeys else {
            return report("AC-1", "profile-file-full-fields", false, "(missing isEnabled/isMuted)")
        }

        // Round-trip: decode back and compare to the original struct (also
        // covers the "encode -> file -> decode" half of AC-4's round-trip test).
        guard let decoded = try? JSONDecoder().decode(SyncProfile.self, from: data), decoded == profile else {
            return report("AC-1", "profile-file-full-fields", false, "(round-trip decode mismatch)")
        }

        return report("AC-1", "profile-file-full-fields", true)
    }

    // MARK: - AC-2 — derived {shortId}.json stays frozen

    private static func testDerivedJSONFrozen() -> Bool {
        let profile = sampleProfile()
        // A scratch rclone.conf, so the self-test never reads the user's real one.
        let json = SyncSetupService.shared.generateProfileConfig(
            for: profile, rcloneConfig: RcloneConfigService(configPath: "\(selfTestRoot)/ac2-absent-rclone.conf"))

        let forbidden = ["\"isEnabled\"", "\"isMuted\""]
        for key in forbidden where json.contains(key) {
            return report("AC-2", "derived-json-frozen", false, "(unexpectedly contains \(key))")
        }

        let requiredFrozenKeys = ["\"profileId\"", "\"remote\"", "\"localPath\"", "\"syncIntervalMinutes\"", "\"maxDelete\""]
        for key in requiredFrozenKeys where !json.contains(key) {
            return report("AC-2", "derived-json-frozen", false, "(missing frozen key \(key))")
        }

        return report("AC-2", "derived-json-frozen", true)
    }

    // MARK: - AC-3 — reconcile delta selection

    private static func testReconcileDelta() -> Bool {
        let base = sampleProfile(isEnabled: true)

        var toDisabled = base
        toDisabled.isEnabled = false
        guard SyncManager.reconcileAction(from: base, to: toDisabled) == .uninstall else {
            return report("AC-3", "reconcile-delta", false, "(isEnabled true->false expected .uninstall)")
        }

        var fromDisabled = base
        fromDisabled.isEnabled = false
        guard SyncManager.reconcileAction(from: fromDisabled, to: base) == .install else {
            return report("AC-3", "reconcile-delta", false, "(isEnabled false->true expected .install)")
        }

        var intervalChanged = base
        intervalChanged.syncIntervalMinutes = base.syncIntervalMinutes + 5
        guard SyncManager.reconcileAction(from: base, to: intervalChanged) == .reinstall else {
            return report("AC-3", "reconcile-delta", false, "(syncIntervalMinutes change expected .reinstall)")
        }

        var directionChanged = base
        directionChanged.syncDirection = base.syncDirection == .localToRemote ? .remoteToLocal : .localToRemote
        guard SyncManager.reconcileAction(from: base, to: directionChanged) == .reinstall else {
            return report("AC-3", "reconcile-delta", false, "(syncDirection change expected .reinstall)")
        }

        var nameChanged = base
        nameChanged.name = "\(base.name) (renamed)"
        guard SyncManager.reconcileAction(from: base, to: nameChanged) == .none else {
            return report("AC-3", "reconcile-delta", false, "(name-only change expected .none)")
        }

        return report("AC-3", "reconcile-delta", true)
    }

    // MARK: - AC-4 — forgiving decoder on partial JSON

    private static func testPartialDecode() -> Bool {
        // Only the five truly-required keys — the minimal profile an agent can
        // author against profile.schema.json. drivePathToMonitor /
        // syncIntervalMinutes / additionalRcloneFlags / isEnabled are now
        // optional-with-default and deliberately OMITTED here.
        let requiredOnly: [String: Any] = [
            "id": UUID().uuidString,
            "name": "Partial",
            "rcloneRemote": "remote:",
            "remotePath": "Path",
            "localSyncPath": "/tmp/limpet-selftest-partial",
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: requiredOnly) else {
            return report("AC-4", "partial-decode", false, "(failed to build fixture JSON)")
        }

        guard let decoded = try? JSONDecoder().decode(SyncProfile.self, from: data) else {
            return report("AC-4", "partial-decode", false, "(decode threw on minimal JSON)")
        }

        let defaultsApplied = decoded.isMuted == false
            // Newly-optional keys fall back to their memberwise-init defaults.
            && decoded.drivePathToMonitor == ""
            && decoded.syncIntervalMinutes == 5
            && decoded.additionalRcloneFlags == ""
            && decoded.isEnabled == false

        guard defaultsApplied else {
            return report("AC-4", "partial-decode", false, "(defaults not applied correctly)")
        }

        // A profile.json carrying keys this build no longer has (the removed
        // "syncMode" field, and legacy mount-mode fields) must decode without
        // throwing — unknown keys are simply ignored by Codable's keyed
        // container, never crashing on an old file.
        var legacyFields = requiredOnly
        legacyFields["syncMode"] = "bisync"
        legacyFields["mountBackend"] = "nfs"
        guard let legacyData = try? JSONSerialization.data(withJSONObject: legacyFields),
              (try? JSONDecoder().decode(SyncProfile.self, from: legacyData)) != nil else {
            return report("AC-4", "partial-decode", false, "(legacy syncMode/mountBackend keys were not ignored safely)")
        }

        return report("AC-4", "partial-decode", true)
    }

    // MARK: - AC-5 — self-write suppression

    private static func testSelfWriteSuppression() -> Bool {
        let dir = "\(selfTestRoot)/ac5-selfwrite"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // `classifyWrite` also consults `CLIWriteMarker`; redirect it to an
        // isolated, empty temp dir so this test never touches the real
        // `~/.local/state/limpet/cli-writes` (no marker here is ever expected to
        // match, but the directory listing itself must stay off the real path).
        let markerDir = "\(dir)/cli-writes"

        return CLIWriteMarker.withDirectory(markerDir) {
            let selfWrittenPath = "\(dir)/self-written.profile.json"
            let selfWrittenContent = Data("{\"marker\":\"self-write\"}".utf8)
            guard (try? selfWrittenContent.write(to: URL(fileURLWithPath: selfWrittenPath))) != nil else {
                return report("AC-5", "self-write-suppression", false, "(failed to write fixture)")
            }
            ConfigSelfWriteRegistry.shared.noteSelfWrite(contentHash: ConfigSelfWriteRegistry.hash(selfWrittenContent))

            guard ConfigFileWatcher.classifyWrite(forFileAt: selfWrittenPath) == .skip else {
                return report("AC-5", "self-write-suppression", false, "(a noted self-write was NOT suppressed)")
            }

            // A genuinely external write (different, un-noted content) must still reconcile.
            let externalPath = "\(dir)/external.profile.json"
            let externalContent = Data("{\"marker\":\"external-write\"}".utf8)
            guard (try? externalContent.write(to: URL(fileURLWithPath: externalPath))) != nil else {
                return report("AC-5", "self-write-suppression", false, "(failed to write external fixture)")
            }
            guard ConfigFileWatcher.classifyWrite(forFileAt: externalPath) == .external else {
                return report("AC-5", "self-write-suppression", false, "(an external write was incorrectly suppressed)")
            }

            return report("AC-5", "self-write-suppression", true)
        }
    }

    // MARK: - AC-6 — migration v3 (blob -> per-profile files, blob retained)

    private static func testMigrationV3() -> Bool {
        let dir = "\(selfTestRoot)/ac6-migration"
        try? FileManager.default.removeItem(atPath: dir)

        let ids = [UUID(), UUID()]
        let dicts: [[String: Any]] = ids.map { id in
            [
                "id": id.uuidString,
                "name": "Migrated \(id.uuidString.prefix(4))",
                "rcloneRemote": "remote:",
                "remotePath": "Path",
                "localSyncPath": "/tmp/limpet-selftest-migrated",
                "drivePathToMonitor": "",
                "syncIntervalMinutes": 15,
                "additionalRcloneFlags": "",
                "isEnabled": true,
            ]
        }

        let testDefaults = UserDefaults(suiteName: "com.nanako.limpet.selftest.ac6.\(UUID().uuidString)")!
        do {
            try MigrationRunner.writeProfileDicts(dicts, to: testDefaults)
        } catch {
            return report("AC-6", "migration-v3", false, "(failed to seed test blob: \(error))")
        }

        let migration = MigrationV3BlobToPerProfileFiles(profilesDirectoryOverride: dir)
        do {
            try migration.migrateUserDefaults(testDefaults)
        } catch {
            return report("AC-6", "migration-v3", false, "(migration threw: \(error))")
        }

        let writtenFiles = (try? FileManager.default.contentsOfDirectory(atPath: dir))?
            .filter { $0.hasSuffix(".profile.json") } ?? []
        guard writtenFiles.count == ids.count else {
            return report("AC-6", "migration-v3", false, "(expected \(ids.count) profile files, found \(writtenFiles.count))")
        }

        guard MigrationRunner.readProfileDicts(from: testDefaults) != nil else {
            return report("AC-6", "migration-v3", false, "(blob was not retained after migration)")
        }

        return report("AC-6", "migration-v3", true)
    }

    // MARK: - AC-7 — file-authoritative reads, blob write-only mirror

    private static func testFileAuthoritativeReads() -> Bool {
        let dir = "\(selfTestRoot)/ac7-authoritative"
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let fileProfile = sampleProfile(name: "From File")
        guard let data = try? JSONEncoder().encode(fileProfile) else {
            return report("AC-7", "file-authoritative-reads", false, "(failed to encode fixture)")
        }
        try? data.write(to: URL(fileURLWithPath: "\(dir)/\(fileProfile.shortId).profile.json"))

        // Seed the blob with DIFFERENT data than the file, so a pass here can
        // only mean the file (not the blob) was read.
        let testDefaults = UserDefaults(suiteName: "com.nanako.limpet.selftest.ac7.\(UUID().uuidString)")!
        let blobOnlyProfile = sampleProfile(name: "From Blob (should be ignored)")
        if let blobData = try? JSONEncoder().encode([blobOnlyProfile]) {
            testDefaults.set(blobData, forKey: ProfileStore.profilesKey)
        }

        let store = ProfileStore(profilesDirectory: dir, defaults: testDefaults)
        guard store.profiles.count == 1, store.profiles.first?.id == fileProfile.id else {
            return report("AC-7", "file-authoritative-reads", false, "(load() did not read from the per-profile file)")
        }

        // save() must still dual-write the blob (write-only mirror).
        var mutated = fileProfile
        mutated.name = "Mutated"
        store.update(mutated)
        guard testDefaults.data(forKey: ProfileStore.profilesKey) != nil else {
            return report("AC-7", "file-authoritative-reads", false, "(save() did not dual-write the blob)")
        }

        return report("AC-7", "file-authoritative-reads", true)
    }

    // MARK: - AC-8 / AC-9 — settings.json safe keys, no secrets

    private static func testSettingsSafeKeys() -> Bool {
        guard let path = AppSettingsFileStore.writeSettingsFile(isLoginItemEnabled: true, directory: selfTestRoot) else {
            return report("AC-8", "settings-safe-keys", false, "(writeSettingsFile failed)")
        }

        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return report("AC-8", "settings-safe-keys", false, "(settings.json unreadable)")
        }

        let expectedKeys = AppSettingsFileStore.SafeKey.allCases.map(\.rawValue) + ["$schema"]
        for key in expectedKeys where json[key] == nil {
            return report("AC-8", "settings-safe-keys", false, "(missing key \(key))")
        }

        let readBack = AppSettingsFileStore.readSafeSettings(at: path)
        guard readBack[.launchAtLogin] == true else {
            return report("AC-8", "settings-safe-keys", false, "(readSafeSettings did not round-trip launchAtLogin)")
        }

        return report("AC-8", "settings-safe-keys", true)
    }

    // MARK: - AC-10 — schema installed and referenced

    private static func testSchemaInstalledAndReferenced() -> Bool {
        let installed = ConfigSchemaInstaller.writeSchemas(base: selfTestRoot)
        guard installed.count == ConfigSchemaInstaller.schemaResourceFilenames.count else {
            return report("AC-10", "schema-installed-and-referenced", false, "(expected \(ConfigSchemaInstaller.schemaResourceFilenames.count) schema files, installed \(installed.count))")
        }

        for filename in ConfigSchemaInstaller.schemaResourceFilenames {
            let path = "\(ConfigSchemaInstaller.schemaDirectory(base: selfTestRoot))/\(filename)"
            guard FileManager.default.fileExists(atPath: path) else {
                return report("AC-10", "schema-installed-and-referenced", false, "(missing installed schema at \(path))")
            }
        }

        // settings.json (written in testSettingsSafeKeys, same selfTestRoot) must reference its schema.
        let settingsPath = "\(selfTestRoot)/settings.json"
        guard let settingsData = FileManager.default.contents(atPath: settingsPath),
              let settingsJSON = try? JSONSerialization.jsonObject(with: settingsData) as? [String: Any],
              (settingsJSON["$schema"] as? String)?.isEmpty == false else {
            return report("AC-10", "schema-installed-and-referenced", false, "(settings.json missing $schema)")
        }

        // A profile file (from AC-1's directory) must also reference its schema.
        let profile = sampleProfile()
        let profileDir = "\(selfTestRoot)/ac10-profiles"
        let store = ProfileStore(
            profilesDirectory: profileDir,
            defaults: UserDefaults(suiteName: "com.nanako.limpet.selftest.ac10.\(UUID().uuidString)")!
        )
        store.add(profile)
        let profilePath = "\(profileDir)/\(profile.shortId).profile.json"
        guard let profileData = FileManager.default.contents(atPath: profilePath),
              let profileJSON = try? JSONSerialization.jsonObject(with: profileData) as? [String: Any],
              (profileJSON["$schema"] as? String)?.isEmpty == false else {
            return report("AC-10", "schema-installed-and-referenced", false, "(profile file missing $schema)")
        }

        return report("AC-10", "schema-installed-and-referenced", true)
    }

    // MARK: - AC-12 — isolated launch-at-login

    private static func testIsolatedLaunchAtLogin() -> Bool {
        enum InjectedFailure: Error { case simulatedSMAppServiceFailure }

        var appliedSafeKeys: [AppSettingsFileStore.SafeKey: Bool] = [:]
        var profileStateTouched = false  // SettingsReconciler must NEVER set this.

        SettingsReconciler.apply(
            safeSettings: [
                .debugLoggingEnabled: true,
                .launchAtLogin: true,
            ],
            applySafeKey: { key, value in
                appliedSafeKeys[key] = value
                // A real profile-touching bug would show up here if someone
                // ever wired profile access into this closure.
            },
            currentLoginItemEnabled: { false },
            applyLoginItem: { _ in
                throw InjectedFailure.simulatedSMAppServiceFailure
            }
        )

        guard profileStateTouched == false else {
            return report("AC-12", "isolated-launch-at-login", false, "(profile state was touched despite the isolation boundary)")
        }

        guard appliedSafeKeys[.debugLoggingEnabled] == true else {
            return report("AC-12", "isolated-launch-at-login", false, "(other safe keys were not applied despite the login-item failure)")
        }

        // launchAtLogin itself must NOT have been recorded via applySafeKey —
        // it is handled exclusively by the isolated applyLoginItem path.
        guard appliedSafeKeys[.launchAtLogin] == nil else {
            return report("AC-12", "isolated-launch-at-login", false, "(launchAtLogin was applied outside the isolated path)")
        }

        return report("AC-12", "isolated-launch-at-login", true)
    }

    // MARK: - AC-19 — delete is durable under file-authoritative load

    /// Regression guard: `delete(id:)` must remove the profile's
    /// `.profile.json`, otherwise the file-authoritative `load()` resurrects a
    /// deleted profile on the next launch (and reinstalls its launchd agent if
    /// enabled). Asserts (a) the file exists after add, (b) it's gone after
    /// delete, and (c) a fresh store over the same directory loads zero profiles.
    private static func testDeleteDurable() -> Bool {
        let dir = "\(selfTestRoot)/ac19-delete"
        let suite = "com.nanako.limpet.selftest.ac19.\(UUID().uuidString)"

        let store = ProfileStore(
            profilesDirectory: dir,
            defaults: UserDefaults(suiteName: suite)!
        )
        let profile = sampleProfile(name: "To Be Deleted")
        store.add(profile)

        let path = "\(dir)/\(profile.shortId).profile.json"
        guard FileManager.default.fileExists(atPath: path) else {
            return report("AC-19", "delete-durable", false, "(profile file not written on add at \(path))")
        }

        store.delete(id: profile.id)

        guard !FileManager.default.fileExists(atPath: path) else {
            return report("AC-19", "delete-durable", false, "(profile file still present after delete)")
        }

        // A fresh store over the same directory must load nothing — proving the
        // delete is durable under file-authority, not just an in-memory removal.
        let reloaded = ProfileStore(
            profilesDirectory: dir,
            defaults: UserDefaults(suiteName: suite)!
        )
        guard reloaded.profiles.isEmpty else {
            return report("AC-19", "delete-durable", false, "(deleted profile resurrected on reload: \(reloaded.profiles.count) profile(s))")
        }

        return report("AC-19", "delete-durable", true)
    }

    // MARK: - AC-22 — migration integrity (files written == profiles in blob)

    /// A silent partial migration (a source profile that never got a
    /// `.profile.json`) must be observable. `writeProfileFiles` returns a
    /// `WriteResult` whose `isComplete` is false when a source profile is dropped
    /// (missing/invalid `id`). Asserts a full blob is complete and a blob with an
    /// invalid entry is flagged incomplete with the right counts.
    private static func testMigrationIntegrity() -> Bool {
        let dir = "\(selfTestRoot)/ac22-integrity"
        try? FileManager.default.removeItem(atPath: dir)

        func dict(id: String) -> [String: Any] {
            ["id": id, "name": "P-\(id.prefix(4))", "rcloneRemote": "r:", "remotePath": "P",
             "localSyncPath": "/tmp/x", "drivePathToMonitor": "", "syncIntervalMinutes": 15,
             "additionalRcloneFlags": "", "isEnabled": true]
        }

        // Happy path: every profile accounted for.
        let full = [dict(id: UUID().uuidString), dict(id: UUID().uuidString)]
        guard let complete = try? MigrationV3BlobToPerProfileFiles.writeProfileFiles(from: full, to: dir) else {
            return report("AC-22", "migration-integrity", false, "(writeProfileFiles threw on full blob)")
        }
        guard complete.isComplete, complete.written == full.count, complete.accountedFor == full.count else {
            return report("AC-22", "migration-integrity", false, "(full blob not complete: \(complete))")
        }

        // Partial: one dict has no `id` → dropped → integrity mismatch observable.
        let partialDir = "\(selfTestRoot)/ac22-partial"
        try? FileManager.default.removeItem(atPath: partialDir)
        let partial: [[String: Any]] = [dict(id: UUID().uuidString), ["name": "no-id"]]
        guard let incomplete = try? MigrationV3BlobToPerProfileFiles.writeProfileFiles(from: partial, to: partialDir) else {
            return report("AC-22", "migration-integrity", false, "(writeProfileFiles threw on partial blob)")
        }
        guard !incomplete.isComplete, incomplete.expected == 2, incomplete.accountedFor == 1 else {
            return report("AC-22", "migration-integrity", false, "(partial blob not flagged incomplete: \(incomplete))")
        }

        return report("AC-22", "migration-integrity", true)
    }

    // MARK: - AC-C1 — external create: enabled + valid → persist+install, .createdAndInstalled

    private static func testExternalCreateEnabled() -> Bool {
        let profile = sampleProfile(isEnabled: true)
        var persistCalls = 0
        var installCalls = 0

        let outcome = SyncManager.applyExternalCreateIfNeeded(
            decoded: profile,
            isKnownId: false,
            existing: [],
            isInstalled: { _ in true },
            persist: { _ in persistCalls += 1 },
            install: { _ in installCalls += 1 },
            quarantine: { _ in }
        )

        guard outcome == .createdAndInstalled else {
            return report("AC-C1", "external-create-enabled", false, "(expected .createdAndInstalled, got \(outcome))")
        }
        guard persistCalls == 1, installCalls == 1 else {
            return report("AC-C1", "external-create-enabled", false, "(persist=\(persistCalls) install=\(installCalls), expected 1/1)")
        }

        return report("AC-C1", "external-create-enabled", true)
    }

    // MARK: - AC-C2 — external create: disabled OR !isValid → .createdOnly, install never

    private static func testExternalCreateDisabledNoInstall() -> Bool {
        func run(_ profile: SyncProfile) -> (ExternalCreateOutcome, Int, Int) {
            var persistCalls = 0
            var installCalls = 0
            let outcome = SyncManager.applyExternalCreateIfNeeded(
                decoded: profile, isKnownId: false,
                existing: [],
                isInstalled: { _ in true },
                persist: { _ in persistCalls += 1 },
                install: { _ in installCalls += 1 },
                quarantine: { _ in }
            )
            return (outcome, persistCalls, installCalls)
        }

        let disabled = sampleProfile(isEnabled: false)
        let (disabledOutcome, disabledPersist, disabledInstall) = run(disabled)
        guard disabledOutcome == .createdOnly, disabledPersist == 1, disabledInstall == 0 else {
            return report(
                "AC-C2", "external-create-disabled-noinstall", false,
                "(disabled: outcome=\(disabledOutcome) persist=\(disabledPersist) install=\(disabledInstall))")
        }

        var invalid = sampleProfile(isEnabled: true)
        invalid.name = ""  // fails isValid
        let (invalidOutcome, invalidPersist, invalidInstall) = run(invalid)
        guard invalidOutcome == .createdOnly, invalidPersist == 1, invalidInstall == 0 else {
            return report(
                "AC-C2", "external-create-disabled-noinstall", false,
                "(invalid: outcome=\(invalidOutcome) persist=\(invalidPersist) install=\(invalidInstall))")
        }

        return report("AC-C2", "external-create-disabled-noinstall", true)
    }

    // MARK: - AC-C3 — external create: undecodable/malformed-UUID → .ignored, no spy fires

    private static func testExternalCreateGarbageIgnored() -> Bool {
        var persistCalls = 0
        var installCalls = 0
        let outcome = SyncManager.applyExternalCreateIfNeeded(
            decoded: nil, isKnownId: false,
            existing: [],
            isInstalled: { _ in true },
            persist: { _ in persistCalls += 1 },
            install: { _ in installCalls += 1 },
            quarantine: { _ in }
        )
        guard outcome == .ignored, persistCalls == 0, installCalls == 0 else {
            return report(
                "AC-C3", "external-create-garbage-ignored", false,
                "(decoded=nil: outcome=\(outcome) persist=\(persistCalls) install=\(installCalls))")
        }

        // Also cover the upstream decode itself: a garbage/malformed-UUID payload
        // must fail to decode (this is what `applyExternalProfileEdit`'s
        // `JSONDecoder` call sees before it ever reaches the create dispatch).
        let garbageJSON: [String: Any] = ["id": "not-a-uuid", "name": "Garbage"]
        guard let data = try? JSONSerialization.data(withJSONObject: garbageJSON) else {
            return report("AC-C3", "external-create-garbage-ignored", false, "(failed to build garbage fixture)")
        }
        let decoded = try? JSONDecoder().decode(SyncProfile.self, from: data)
        guard decoded == nil else {
            return report("AC-C3", "external-create-garbage-ignored", false, "(malformed-UUID payload unexpectedly decoded)")
        }

        return report("AC-C3", "external-create-garbage-ignored", true)
    }

    // MARK: - AC-C4 — external create: differently-named file canonicalizes, no reconcile loop

    private static func testExternalCreateCanonicalNoLoop() -> Bool {
        let dir = "\(selfTestRoot)/ac-c4-create"
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Disabled: exercises persist/canonicalize only, no real launchd install.
        let profile = sampleProfile(isEnabled: false)
        let sourcePath = "\(dir)/weird-name.profile.json"
        guard let data = try? JSONEncoder().encode(profile) else {
            return report("AC-C4", "external-create-canonical-no-loop", false, "(failed to encode fixture)")
        }
        guard (try? data.write(to: URL(fileURLWithPath: sourcePath))) != nil else {
            return report("AC-C4", "external-create-canonical-no-loop", false, "(failed to write fixture source file)")
        }

        let outcome = SyncManager.applyExternalCreateIfNeeded(
            decoded: profile,
            isKnownId: false,
            existing: [],
            isInstalled: { _ in true },
            persist: { p in
                let store = ProfileStore(
                    profilesDirectory: dir,
                    defaults: UserDefaults(suiteName: "com.nanako.limpet.selftest.acc4.\(UUID().uuidString)")!
                )
                store.add(p)
                let canonicalFilename = "\(p.shortId).profile.json"
                let sourceFilename = (sourcePath as NSString).lastPathComponent
                if sourceFilename != canonicalFilename {
                    try? FileManager.default.removeItem(atPath: sourcePath)
                }
            },
            install: { _ in },
            quarantine: { _ in }
        )
        guard outcome == .createdOnly else {
            return report("AC-C4", "external-create-canonical-no-loop", false, "(expected .createdOnly, got \(outcome))")
        }

        let canonicalPath = "\(dir)/\(profile.shortId).profile.json"
        guard FileManager.default.fileExists(atPath: canonicalPath) else {
            return report("AC-C4", "external-create-canonical-no-loop", false, "(canonical file not written at \(canonicalPath))")
        }
        guard !FileManager.default.fileExists(atPath: sourcePath) else {
            return report("AC-C4", "external-create-canonical-no-loop", false, "(source file still present at \(sourcePath))")
        }

        guard let canonicalData = FileManager.default.contents(atPath: canonicalPath) else {
            return report("AC-C4", "external-create-canonical-no-loop", false, "(canonical file unreadable)")
        }
        let hash = ConfigSelfWriteRegistry.hash(canonicalData)
        guard ConfigSelfWriteRegistry.shared.consumeIfSelfWrite(contentHash: hash) else {
            return report(
                "AC-C4", "external-create-canonical-no-loop", false,
                "(canonical write's hash not consumable from the self-write registry — reconcile loop would fire)")
        }

        return report("AC-C4", "external-create-canonical-no-loop", true)
    }

    // MARK: - CLI self-test helpers

    /// Build a `CLIEnvironment` with inert defaults, overridable per test —
    /// mirrors `sampleProfile`'s role for the Enabler-1 tests above.
    private static func fakeCLIEnvironment(
        runRclone: @escaping (_ args: [String], _ remote: String?, _ timeout: TimeInterval) -> (Int32, String, String) = { _, _, _ in (0, "", "") },
        readProfiles: @escaping () -> [SyncProfile] = { [] },
        fileExists: @escaping (String) -> Bool = { _ in false },
        // nil -> same answer as `fileExists`, so existing fakes that stub
        // `fileExists` for `trash restore`'s overwrite check keep working.
        itemExists: ((String) -> Bool)? = nil,
        // Identity: every fake path "exists" as itself, so the containment
        // check is inert unless a test passes the real resolver.
        realPath: @escaping (String) -> String? = { $0 },
        runLaunchctl: @escaping (_ args: [String]) -> (Int32, String) = { _ in (0, "") },
        schemaFilesPresent: @escaping () -> Bool = { true },
        remoteSection: @escaping (String) -> [String: String]? = { _ in nil },
        writeProfile: @escaping (SyncProfile) -> Bool = { _ in true },
        installProfile: @escaping (SyncProfile) -> String? = { _ in nil },
        uninstallProfile: @escaping (SyncProfile) -> String? = { _ in nil },
        deleteProfileFile: @escaping (SyncProfile) -> Void = { _ in },
        removeFile: @escaping (String) -> Bool = { _ in true },
        moveFile: @escaping (String, String, Bool) -> Bool = { _, _, _ in true },
        readStdin: @escaping () -> String? = { nil },
        readFile: @escaping (String) -> String? = { _ in nil },
        readSecret: @escaping (String) -> String? = { _ in nil },
        addKeychainRemote: @escaping (String, String, [String: String], String) -> String? = { _, _, _, _ in nil },
        stdout: @escaping (String) -> Void = { _ in },
        stderr: @escaping (String) -> Void = { _ in }
    ) -> CLIEnvironment {
        CLIEnvironment(
            runRclone: runRclone,
            readProfiles: readProfiles,
            fileExists: fileExists,
            itemExists: itemExists ?? fileExists,
            realPath: realPath,
            runLaunchctl: runLaunchctl,
            schemaFilesPresent: schemaFilesPresent,
            remoteSection: remoteSection,
            writeProfile: writeProfile,
            installProfile: installProfile,
            uninstallProfile: uninstallProfile,
            deleteProfileFile: deleteProfileFile,
            removeFile: removeFile,
            moveFile: moveFile,
            readStdin: readStdin,
            readFile: readFile,
            readSecret: readSecret,
            addKeychainRemote: addKeychainRemote,
            stdout: stdout,
            stderr: stderr
        )
    }

    // MARK: - AC-CLI5 — dispatch gate: bare tokens are subcommands, flags/no-args fall to the GUI

    /// Guards the real `dispatch` gate, not just the pure `execute` core: an
    /// unknown bare subcommand must return usage+non-zero, NEVER `nil` (which
    /// would launch the GUI and hang a terminal — the bug this test locks down).
    private static func testCLIDispatchGate() -> Bool {
        if LimpetCLI.dispatch(arguments: ["limpet"]) != nil {
            return report("AC-CLI5", "cli-dispatch-gate", false, "(no-args did not fall through to GUI)")
        }
        if LimpetCLI.dispatch(arguments: ["limpet", "--self-test"]) != nil {
            return report("AC-CLI5", "cli-dispatch-gate", false, "(--self-test did not fall through to GUI/self-test path)")
        }
        if LimpetCLI.dispatch(arguments: ["limpet", "-psn_0_12345"]) != nil {
            return report("AC-CLI5", "cli-dispatch-gate", false, "(macOS -psn_ GUI arg did not fall through)")
        }
        guard let bogus = LimpetCLI.dispatch(arguments: ["limpet", "bogus"]), bogus != 0 else {
            return report("AC-CLI5", "cli-dispatch-gate", false, "(unknown subcommand fell through to GUI instead of usage+non-zero)")
        }
        guard LimpetCLI.dispatch(arguments: ["limpet", "help"]) == 0 else {
            return report("AC-CLI5", "cli-dispatch-gate", false, "(help did not exit 0)")
        }
        guard LimpetCLI.dispatch(arguments: ["limpet", "--help"]) == 0 else {
            return report("AC-CLI5", "cli-dispatch-gate", false, "(--help did not exit 0)")
        }
        return report("AC-CLI5", "cli-dispatch-gate", true, "")
    }

    // MARK: - AC-CLI6 — write commands: create / enable / disable / delete / sync route to the right side effect

    /// Drives the mutating subcommands through `execute` with spied closures —
    /// asserting each triggers the SINGLE correct side effect: create persists +
    /// installs an enabled profile, an id collision refuses without writing,
    /// enable/disable route via the shared `reconcileAction` to install vs.
    /// uninstall, delete uninstalls + removes the file, and `sync` runs the
    /// script for a sync profile.
    private static func testCLIWriteCommands() -> Bool {
        let id = UUID()
        let enabled = sampleProfile(id: id, name: "CLIWrite", isEnabled: true)
        guard let json = try? JSONEncoder().encode(enabled),
              let jsonStr = String(data: json, encoding: .utf8) else {
            return report("AC-CLI6", "cli-write-commands", false, "(could not encode sample profile)")
        }

        // create (stdin) → writes + installs an enabled+valid profile.
        var wrote = false, installed = false
        let createEnv = fakeCLIEnvironment(
            readProfiles: { [] },
            writeProfile: { _ in wrote = true; return true },
            installProfile: { _ in installed = true; return nil },
            readStdin: { jsonStr }
        )
        guard LimpetCLI.execute(["profile", "create", "-"], env: createEnv) == 0, wrote, installed else {
            return report("AC-CLI6", "cli-write-commands", false, "(create did not write+install, exit/wrote/installed=\(wrote)/\(installed))")
        }

        // create with a colliding id → refuses, no write.
        var wroteOnCollision = false
        let collideEnv = fakeCLIEnvironment(
            readProfiles: { [enabled] },
            writeProfile: { _ in wroteOnCollision = true; return true },
            readStdin: { jsonStr }
        )
        guard LimpetCLI.execute(["profile", "create", "-"], env: collideEnv) != 0, !wroteOnCollision else {
            return report("AC-CLI6", "cli-write-commands", false, "(create did not refuse a colliding id)")
        }

        // enable a disabled profile → reconcile .install → installProfile fires.
        let disabled = sampleProfile(id: UUID(), name: "ToEnable", isEnabled: false)
        var enableInstalled = false
        let enableEnv = fakeCLIEnvironment(
            readProfiles: { [disabled] },
            installProfile: { _ in enableInstalled = true; return nil },
            uninstallProfile: { _ in "should-not-be-called" }
        )
        guard LimpetCLI.execute(["profile", "enable", disabled.shortId], env: enableEnv) == 0, enableInstalled else {
            return report("AC-CLI6", "cli-write-commands", false, "(enable did not install)")
        }

        // disable an enabled profile → reconcile .uninstall → uninstallProfile fires.
        var disableUninstalled = false
        let disableEnv = fakeCLIEnvironment(
            readProfiles: { [enabled] },
            installProfile: { _ in "should-not-be-called" },
            uninstallProfile: { _ in disableUninstalled = true; return nil }
        )
        guard LimpetCLI.execute(["profile", "disable", enabled.shortId], env: disableEnv) == 0, disableUninstalled else {
            return report("AC-CLI6", "cli-write-commands", false, "(disable did not uninstall)")
        }

        // delete → uninstall + deleteProfileFile both fire.
        var delUninstalled = false, delRemoved = false
        let deleteEnv = fakeCLIEnvironment(
            readProfiles: { [enabled] },
            uninstallProfile: { _ in delUninstalled = true; return nil },
            deleteProfileFile: { _ in delRemoved = true }
        )
        guard LimpetCLI.execute(["profile", "delete", enabled.shortId], env: deleteEnv) == 0, delUninstalled, delRemoved else {
            return report("AC-CLI6", "cli-write-commands", false, "(delete did not uninstall+remove)")
        }


        // sync signals the watcher via `launchctl kill SIGUSR1` — it never
        // runs the script itself (limpet-plan.md L3(c)).
        var killArgs: [String] = []
        let syncEnv = fakeCLIEnvironment(
            readProfiles: { [enabled] },
            runLaunchctl: { args in killArgs = args; return (0, "") }
        )
        guard LimpetCLI.execute(["sync", enabled.shortId], env: syncEnv) == 0,
              killArgs == ["kill", "SIGUSR1", "gui/\(getuid())/\(enabled.launchdLabel)"] else {
            return report("AC-CLI6", "cli-write-commands", false, "(sync did not launchctl kill SIGUSR1: got \(killArgs))")
        }

        // No watcher running (non-zero launchctl kill) → exits non-zero, greppable.
        var syncStderr = ""
        let noWatcherEnv = fakeCLIEnvironment(
            readProfiles: { [enabled] },
            runLaunchctl: { _ in (1, "") },
            stderr: { syncStderr += $0 }
        )
        guard LimpetCLI.execute(["sync", enabled.shortId], env: noWatcherEnv) != 0,
              syncStderr.contains("no watcher running") else {
            return report("AC-CLI6", "cli-write-commands", false, "(sync with no watcher did not report it)")
        }

        return report("AC-CLI6", "cli-write-commands", true)
    }

    // MARK: - AC-CLI7 — lifecycle: reinstall/install parse + side-effect routing

    /// Drives the agent-first lifecycle commands through parse + `execute` with
    /// spied closures: reinstall does uninstall→install for an enabled profile
    /// and refuses a disabled one; install runs installProfile for an enabled
    /// profile and refuses a disabled one.
    private static func testCLILifecycleCommands() -> Bool {
        // Parse.
        guard case .success(.reinstall("s")) = LimpetCLI.parse(["reinstall", "s"]),
              case .success(.install("s")) = LimpetCLI.parse(["install", "s"]) else {
            return report("AC-CLI7", "cli-lifecycle-commands", false, "(lifecycle commands did not parse)")
        }

        let testProfile = sampleProfile(id: UUID(), name: "TestProfile", isEnabled: true)

        // reinstall (enabled) → uninstall THEN install both fire.
        var reUninstalled = false, reInstalled = false
        let reinstallEnv = fakeCLIEnvironment(
            readProfiles: { [testProfile] },
            installProfile: { _ in reInstalled = true; return nil },
            uninstallProfile: { _ in reUninstalled = true; return nil }
        )
        guard LimpetCLI.execute(["reinstall", testProfile.shortId], env: reinstallEnv) == 0, reUninstalled, reInstalled else {
            return report("AC-CLI7", "cli-lifecycle-commands", false, "(reinstall did not uninstall+install)")
        }

        // install (enabled) → installProfile fires, uninstall does NOT.
        var installFired = false
        let installEnv = fakeCLIEnvironment(
            readProfiles: { [testProfile] },
            installProfile: { _ in installFired = true; return nil },
            uninstallProfile: { _ in "should-not-be-called" }
        )
        guard LimpetCLI.execute(["install", testProfile.shortId], env: installEnv) == 0, installFired else {
            return report("AC-CLI7", "cli-lifecycle-commands", false, "(install did not run installProfile)")
        }

        // install/reinstall refuse a disabled profile (no install fires).
        let disabled = sampleProfile(id: UUID(), name: "Disabled", isEnabled: false)
        var disabledInstallFired = false
        let disabledEnv = fakeCLIEnvironment(
            readProfiles: { [disabled] },
            installProfile: { _ in disabledInstallFired = true; return nil }
        )
        guard LimpetCLI.execute(["install", disabled.shortId], env: disabledEnv) != 0,
              LimpetCLI.execute(["reinstall", disabled.shortId], env: disabledEnv) != 0,
              !disabledInstallFired else {
            return report("AC-CLI7", "cli-lifecycle-commands", false, "(install/reinstall did not refuse a disabled profile)")
        }

        return report("AC-CLI7", "cli-lifecycle-commands", true)
    }

    // MARK: - AC-CLI8 — profile set: assignment matrix, reconcile routing, profile show round-trip

    /// Exercises the keystone `profile set` end to end: the pure
    /// `applyProfileAssignment` matrix (valid fields, invalid values, unknown key,
    /// the three excluded keys), then `execute` for the write + reconcile routing
    /// (a reinstall-triggering field on an enabled profile drives uninstall→install;
    /// an invalid value writes NOTHING), and finally `profile show` producing JSON
    /// that decodes back to the same profile.
    private static func testCLIProfileSetAndShow() -> Bool {
        // Parse: positional key/value pairs; odd count fails.
        guard case .success(.profileSet(target: "work", assignments: let a)) = LimpetCLI.parse(
            ["profile", "set", "work", "isMuted", "true", "syncDirection", "remoteToLocal"]
        ), a == [ProfileAssignment(key: "isMuted", value: "true"), ProfileAssignment(key: "syncDirection", value: "remoteToLocal")] else {
            return report("AC-CLI8", "cli-profile-set-and-show", false, "(profile set did not parse into pairs)")
        }
        guard case .failure = LimpetCLI.parse(["profile", "set", "work", "isMuted"]) else {
            return report("AC-CLI8", "cli-profile-set-and-show", false, "(odd pair count did not fail to parse)")
        }

        // applyProfileAssignment matrix.
        var p = sampleProfile(id: UUID(), name: "Base", isEnabled: true)
        guard LimpetCLI.applyProfileAssignment(&p, key: "syncDirection", value: "remoteToLocal") == nil,
              p.syncDirection == .remoteToLocal else {
            return report("AC-CLI8", "cli-profile-set-and-show", false, "(valid syncDirection assignment failed)")
        }
        guard LimpetCLI.applyProfileAssignment(&p, key: "syncIntervalMinutes", value: "8") == nil, p.syncIntervalMinutes == 8 else {
            return report("AC-CLI8", "cli-profile-set-and-show", false, "(valid syncIntervalMinutes assignment failed)")
        }
        guard LimpetCLI.applyProfileAssignment(&p, key: "isMuted", value: "yes") == nil, p.isMuted == true else {
            return report("AC-CLI8", "cli-profile-set-and-show", false, "(valid bool assignment failed)")
        }
        // trashDays: 0...365, matching SyncProfile.validationError (code-review
        // follow-up, finding C: `profile set <p> trashDays N` used to be
        // rejected as an unknown key).
        guard LimpetCLI.applyProfileAssignment(&p, key: "trashDays", value: "30") == nil, p.trashDays == 30 else {
            return report("AC-CLI8", "cli-profile-set-and-show", false, "(valid trashDays assignment failed)")
        }
        guard LimpetCLI.applyProfileAssignment(&p, key: "trashDays", value: "0") == nil, p.trashDays == 0 else {
            return report("AC-CLI8", "cli-profile-set-and-show", false, "(trashDays=0, the off value, was rejected)")
        }
        guard LimpetCLI.applyProfileAssignment(&p, key: "trashDays", value: "366") != nil else {
            return report("AC-CLI8", "cli-profile-set-and-show", false, "(out-of-range trashDays was accepted)")
        }
        guard LimpetCLI.applyProfileAssignment(&p, key: "trashDays", value: "-1") != nil else {
            return report("AC-CLI8", "cli-profile-set-and-show", false, "(negative trashDays was accepted)")
        }
        // Invalid values.
        guard LimpetCLI.applyProfileAssignment(&p, key: "syncIntervalMinutes", value: "0") != nil else {
            return report("AC-CLI8", "cli-profile-set-and-show", false, "(out-of-range syncIntervalMinutes was accepted)")
        }
        guard LimpetCLI.applyProfileAssignment(&p, key: "syncDirection", value: "bogus") != nil else {
            return report("AC-CLI8", "cli-profile-set-and-show", false, "(invalid enum value was accepted)")
        }
        guard LimpetCLI.applyProfileAssignment(&p, key: "name", value: "") != nil else {
            return report("AC-CLI8", "cli-profile-set-and-show", false, "(empty required string was accepted)")
        }
        // The removed "syncMode" key (bisync/mount) is no longer a valid `profile set` key.
        guard LimpetCLI.applyProfileAssignment(&p, key: "syncMode", value: "sync") != nil else {
            return report("AC-CLI8", "cli-profile-set-and-show", false, "(removed \"syncMode\" key was accepted)")
        }
        // Unknown + excluded keys.
        for badKey in ["totallyBogus", "id", "isEnabled", "fallbackRequiresCacheRebuild"] {
            guard LimpetCLI.applyProfileAssignment(&p, key: badKey, value: "x") != nil else {
                return report("AC-CLI8", "cli-profile-set-and-show", false, "(key \"\(badKey)\" was not rejected)")
            }
        }

        // execute: a reinstall-triggering field on an enabled profile → write + uninstall→install.
        let enabled = sampleProfile(id: UUID(), name: "Enabled", isEnabled: true)
        var written: SyncProfile?, reUninstalled = false, reInstalled = false
        let setEnv = fakeCLIEnvironment(
            readProfiles: { [enabled] },
            writeProfile: { written = $0; return true },
            installProfile: { _ in reInstalled = true; return nil },
            uninstallProfile: { _ in reUninstalled = true; return nil }
        )
        guard LimpetCLI.execute(["profile", "set", enabled.shortId, "syncIntervalMinutes", "42"], env: setEnv) == 0,
              written?.syncIntervalMinutes == 42, reUninstalled, reInstalled else {
            return report("AC-CLI8", "cli-profile-set-and-show", false, "(profile set did not write + reinstall)")
        }

        // execute: an invalid value writes NOTHING and exits non-zero.
        var wroteOnInvalid = false
        let invalidEnv = fakeCLIEnvironment(readProfiles: { [enabled] }, writeProfile: { _ in wroteOnInvalid = true; return true })
        guard LimpetCLI.execute(["profile", "set", enabled.shortId, "syncDirection", "bogus"], env: invalidEnv) != 0, !wroteOnInvalid else {
            return report("AC-CLI8", "cli-profile-set-and-show", false, "(invalid profile set value still wrote the file)")
        }

        // profile show → JSON that decodes back to the same profile.
        var shown = ""
        let showEnv = fakeCLIEnvironment(readProfiles: { [enabled] }, stdout: { shown += $0 })
        guard LimpetCLI.execute(["profile", "show", enabled.shortId], env: showEnv) == 0,
              let data = shown.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SyncProfile.self, from: data),
              decoded == enabled else {
            return report("AC-CLI8", "cli-profile-set-and-show", false, "(profile show JSON did not round-trip)")
        }

        return report("AC-CLI8", "cli-profile-set-and-show", true)
    }

    // MARK: - AC-CLI1 — arg parsing: unknown/absent → usage error; known commands route correctly

    private static func testCLIArgParsing() -> Bool {
        guard case .failure = LimpetCLI.parse([]) else {
            return report("AC-CLI1", "cli-arg-parsing", false, "(parse([]) did not fail)")
        }
        guard case .failure = LimpetCLI.parse(["bogus"]) else {
            return report("AC-CLI1", "cli-arg-parsing", false, "(parse([\"bogus\"]) did not fail)")
        }

        var stderrOutput = ""
        let execEnv = fakeCLIEnvironment(stderr: { stderrOutput += $0 })
        let exitCode = LimpetCLI.execute(["bogus"], env: execEnv)
        guard exitCode != 0 else {
            return report("AC-CLI1", "cli-arg-parsing", false, "(execute([\"bogus\"]) returned exit 0)")
        }
        guard !stderrOutput.isEmpty else {
            return report("AC-CLI1", "cli-arg-parsing", false, "(no usage message printed to stderr on parse failure)")
        }

        guard case .success(.doctor) = LimpetCLI.parse(["doctor"]) else {
            return report("AC-CLI1", "cli-arg-parsing", false, "(\"doctor\" did not parse to .doctor)")
        }
        guard case .success(.testRemote("work")) = LimpetCLI.parse(["test-remote", "work"]) else {
            return report("AC-CLI1", "cli-arg-parsing", false, "(\"test-remote work\" did not parse correctly)")
        }
        guard case .success(.logs(target: "work", follow: true)) = LimpetCLI.parse(["logs", "work", "--follow"]) else {
            return report("AC-CLI1", "cli-arg-parsing", false, "(\"logs work --follow\" did not parse correctly)")
        }
        guard case .success(.listRemotes) = LimpetCLI.parse(["listremotes"]) else {
            return report("AC-CLI1", "cli-arg-parsing", false, "(\"listremotes\" did not parse to .listRemotes)")
        }
        guard case .success(.profiles) = LimpetCLI.parse(["profiles"]) else {
            return report("AC-CLI1", "cli-arg-parsing", false, "(\"profiles\" did not parse to .profiles)")
        }

        var capturedArgs: [String] = []
        let listEnv = fakeCLIEnvironment(runRclone: { args, _, _ in
            capturedArgs = args
            return (0, "remote1:\nremote2:\n", "")
        })
        _ = LimpetCLI.run(.listRemotes, env: listEnv)
        guard capturedArgs == ["listremotes"] else {
            return report("AC-CLI1", "cli-arg-parsing", false, "(listremotes did not invoke rclone listremotes, got \(capturedArgs))")
        }

        return report("AC-CLI1", "cli-arg-parsing", true)
    }

    // MARK: - AC-CLI2 — doctor: correct DoctorCheck statuses + exit code derivation

    private static func testDoctorPureChecks() -> Bool {
        // rclone present + schema present + no profiles → no .fail check.
        let healthyEnv = fakeCLIEnvironment(
            runRclone: { args, _, _ in args.first == "version" ? (0, "rclone v1.66.0", "") : (0, "", "") },
            readProfiles: { [] },
            schemaFilesPresent: { true }
        )
        let healthyChecks = LimpetCLI.doctorChecks(env: healthyEnv)
        guard !healthyChecks.contains(where: { $0.status == .fail }) else {
            return report("AC-CLI2", "doctor-pure-checks", false, "(healthy env produced a .fail check: \(healthyChecks))")
        }
        guard healthyChecks.contains(where: { $0.name == "rclone" && $0.status == .ok }) else {
            return report("AC-CLI2", "doctor-pure-checks", false, "(rclone check not .ok in healthy env)")
        }

        // rclone absent → .fail, exit non-zero.
        let noRcloneEnv = fakeCLIEnvironment(runRclone: { _, _, _ in (127, "", "not found") })
        let noRcloneChecks = LimpetCLI.doctorChecks(env: noRcloneEnv)
        guard noRcloneChecks.contains(where: { $0.name == "rclone" && $0.status == .fail }) else {
            return report("AC-CLI2", "doctor-pure-checks", false, "(rclone-absent env did not produce a .fail rclone check)")
        }
        guard LimpetCLI.run(.doctor, env: noRcloneEnv) != 0 else {
            return report("AC-CLI2", "doctor-pure-checks", false, "(rclone-absent doctor run did not exit non-zero)")
        }

        // schema missing → .warn only, exit still 0.
        let noSchemaEnv = fakeCLIEnvironment(
            runRclone: { args, _, _ in args.first == "version" ? (0, "rclone v1.66.0", "") : (0, "", "") },
            schemaFilesPresent: { false }
        )
        let noSchemaChecks = LimpetCLI.doctorChecks(env: noSchemaEnv)
        guard noSchemaChecks.contains(where: { $0.name == "config schemas" && $0.status == .warn }) else {
            return report("AC-CLI2", "doctor-pure-checks", false, "(schema-missing env did not produce a .warn schema check)")
        }
        guard LimpetCLI.run(.doctor, env: noSchemaEnv) == 0 else {
            return report("AC-CLI2", "doctor-pure-checks", false, "(schema-missing (warn-only) doctor run should still exit 0)")
        }

        // Per-profile: derived config missing → .fail, exit non-zero.
        let profile = sampleProfile(isEnabled: false)
        let missingConfigEnv = fakeCLIEnvironment(
            runRclone: { args, _, _ in args.first == "version" ? (0, "rclone v1.66.0", "") : (0, "", "") },
            readProfiles: { [profile] },
            fileExists: { _ in false },
            schemaFilesPresent: { true }
        )
        let missingConfigChecks = LimpetCLI.doctorChecks(env: missingConfigEnv)
        guard missingConfigChecks.contains(where: { $0.status == .fail && $0.detail.contains("derived config missing") }) else {
            return report("AC-CLI2", "doctor-pure-checks", false, "(missing derived config did not produce a .fail check)")
        }
        guard LimpetCLI.run(.doctor, env: missingConfigEnv) != 0 else {
            return report("AC-CLI2", "doctor-pure-checks", false, "(missing-derived-config doctor run did not exit non-zero)")
        }

        // Derived config present → no .fail for that profile.
        let presentConfigEnv = fakeCLIEnvironment(
            runRclone: { args, _, _ in args.first == "version" ? (0, "rclone v1.66.0", "") : (0, "", "") },
            readProfiles: { [profile] },
            fileExists: { path in path == profile.configPath },
            schemaFilesPresent: { true }
        )
        let presentConfigChecks = LimpetCLI.doctorChecks(env: presentConfigEnv)
        guard !presentConfigChecks.contains(where: { $0.status == .fail }) else {
            return report(
                "AC-CLI2", "doctor-pure-checks", false,
                "(present-config env unexpectedly produced a .fail check: \(presentConfigChecks))")
        }

        // Stale lock present → .warn only, exit still 0.
        let staleLockEnv = fakeCLIEnvironment(
            runRclone: { args, _, _ in args.first == "version" ? (0, "rclone v1.66.0", "") : (0, "", "") },
            readProfiles: { [profile] },
            fileExists: { path in path == profile.configPath || path == profile.lockFilePath },
            schemaFilesPresent: { true }
        )
        let staleLockChecks = LimpetCLI.doctorChecks(env: staleLockEnv)
        guard staleLockChecks.contains(where: { $0.status == .warn && $0.detail.contains("stale lock") }) else {
            return report("AC-CLI2", "doctor-pure-checks", false, "(stale lock did not produce a .warn check)")
        }
        guard LimpetCLI.run(.doctor, env: staleLockEnv) == 0 else {
            return report("AC-CLI2", "doctor-pure-checks", false, "(stale-lock-only (warn) doctor run should still exit 0)")
        }

        return report("AC-CLI2", "doctor-pure-checks", true)
    }

    // MARK: - AC-CLI3 — resolution precedence + unmatched error + profiles output

    private static func testCLIResolveAndList() -> Bool {
        let workProfile = sampleProfile(id: UUID(), name: "Work", isEnabled: true)
        let personalProfile = sampleProfile(id: UUID(), name: "Personal", isEnabled: false)
        let all = [workProfile, personalProfile]

        guard LimpetCLI.resolveProfile(workProfile.shortId, in: all)?.id == workProfile.id else {
            return report("AC-CLI3", "cli-resolve-and-list", false, "(shortId resolution failed)")
        }
        guard LimpetCLI.resolveProfile("WORK", in: all)?.id == workProfile.id else {
            return report("AC-CLI3", "cli-resolve-and-list", false, "(case-insensitive name resolution failed)")
        }
        guard LimpetCLI.resolveProfile("nope", in: all) == nil else {
            return report("AC-CLI3", "cli-resolve-and-list", false, "(unmatched target unexpectedly resolved)")
        }

        var stderrOutput = ""
        let unmatchedEnv = fakeCLIEnvironment(readProfiles: { all }, stderr: { stderrOutput += $0 })
        let exitCode = LimpetCLI.run(.testRemote("nope"), env: unmatchedEnv)
        guard exitCode != 0, stderrOutput.contains("no profile matches"), stderrOutput.contains("nope") else {
            return report(
                "AC-CLI3", "cli-resolve-and-list", false,
                "(unmatched test-remote target did not exit non-zero with a greppable error)")
        }

        var stdoutOutput = ""
        let profilesEnv = fakeCLIEnvironment(readProfiles: { all }, stdout: { stdoutOutput += $0 })
        _ = LimpetCLI.run(.profiles, env: profilesEnv)
        for expected in [workProfile.name, workProfile.shortId, "enabled=true", workProfile.rcloneRemote] {
            guard stdoutOutput.contains(expected) else {
                return report("AC-CLI3", "cli-resolve-and-list", false, "(profiles output missing \"\(expected)\")")
            }
        }

        return report("AC-CLI3", "cli-resolve-and-list", true)
    }

    // MARK: - AC-CLI4 — shim install: writes exec shim, idempotent, never clobbers a foreign file

    private static func testShimInstallIdempotentNonClobber() -> Bool {
        let binDir = "\(selfTestRoot)/ac-cli4-bin"
        try? FileManager.default.removeItem(atPath: binDir)
        let shimPath = "\(binDir)/limpet"

        guard CLIShimInstaller.install(executablePath: "/tmp/fake-limpet-binary", shimPath: shimPath) else {
            return report("AC-CLI4", "shim-install-idempotent-nonclobber", false, "(install failed on an absent shim path)")
        }
        guard let contents = try? String(contentsOfFile: shimPath, encoding: .utf8),
              contents.contains("exec '/tmp/fake-limpet-binary' \"$@\"") else {
            return report("AC-CLI4", "shim-install-idempotent-nonclobber", false, "(shim content missing exec line)")
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: shimPath),
              let perms = attrs[.posixPermissions] as? NSNumber, perms.uint16Value & 0o111 != 0 else {
            return report("AC-CLI4", "shim-install-idempotent-nonclobber", false, "(shim not executable)")
        }

        guard CLIShimInstaller.install(executablePath: "/tmp/fake-limpet-binary-v2", shimPath: shimPath) else {
            return report("AC-CLI4", "shim-install-idempotent-nonclobber", false, "(re-install over our own shim failed)")
        }
        guard let refreshed = try? String(contentsOfFile: shimPath, encoding: .utf8),
              refreshed.contains("/tmp/fake-limpet-binary-v2") else {
            return report("AC-CLI4", "shim-install-idempotent-nonclobber", false, "(re-install did not refresh the exec path)")
        }

        let foreignPath = "\(binDir)/foreign-limpet"
        let foreignContent = "#!/bin/sh\necho not ours\n"
        try? foreignContent.write(toFile: foreignPath, atomically: true, encoding: .utf8)
        guard CLIShimInstaller.install(executablePath: "/tmp/should-not-appear", shimPath: foreignPath) == false else {
            return report("AC-CLI4", "shim-install-idempotent-nonclobber", false, "(install returned true over a foreign file)")
        }
        guard let foreignAfter = try? String(contentsOfFile: foreignPath, encoding: .utf8), foreignAfter == foreignContent else {
            return report("AC-CLI4", "shim-install-idempotent-nonclobber", false, "(foreign file was modified)")
        }

        return report("AC-CLI4", "shim-install-idempotent-nonclobber", true)
    }

    // MARK: - AC-W1 — SyncWatchScheduler: exact rerun counts (limpet-plan.md L3)

    /// A deterministic fake clock/queue for `SchedulerRunner.scheduleAfter`:
    /// records `(fireAt, action)` pairs instead of touching a real timer, and
    /// `advance(by:)` fires everything due, in fire-order, including actions
    /// scheduled by an action that just fired — exactly what lets the "runner
    /// returns 75 repeatedly while the clock advances 60s" case simulate a
    /// full minute of 10s backoffs in a single synchronous call.
    private final class VirtualClock {
        private(set) var now: TimeInterval = 0
        private var scheduled: [(fireAt: TimeInterval, action: () -> Void)] = []

        func scheduleAfter(_ seconds: TimeInterval, _ action: @escaping () -> Void) {
            scheduled.append((now + seconds, action))
        }

        func advance(by seconds: TimeInterval) {
            let target = now + seconds
            while true {
                guard let nextIndex = scheduled.indices
                    .filter({ scheduled[$0].fireAt <= target })
                    .min(by: { scheduled[$0].fireAt < scheduled[$1].fireAt })
                else { break }
                let entry = scheduled.remove(at: nextIndex)
                now = entry.fireAt
                entry.action()
            }
            now = target
        }
    }

    /// Builds a `SchedulerRunner` whose `runChild` calls `completion`
    /// SYNCHRONOUSLY and immediately with whatever `exitCode()` currently
    /// returns — the scheduler is pure, so no dispatch queue or real process
    /// is needed to drive it deterministically.
    private static func fakeSchedulerRunner(
        sourceExists: @escaping () -> Bool = { true },
        exitCode: @escaping () -> Int32,
        clock: VirtualClock,
        onLogSourceMissing: (() -> Void)? = nil
    ) -> SchedulerRunner {
        SchedulerRunner(
            sourceExists: sourceExists,
            runChild: { _, completion in completion(exitCode()) },
            now: { clock.now },
            scheduleAfter: { seconds, action in clock.scheduleAfter(seconds, action) },
            logSourceMissing: { onLogSourceMissing?() },
            refusalReason: { nil },
            logRefusal: { _ in },
            deleteLimitReached: { false },
            recordDeleteLimit: { true }
        )
    }

    private static func testWatchScheduler() -> Bool {
        // Case 1: trigger during a run -> exactly 1 rerun. `runChild` here
        // does NOT call completion synchronously — it captures it, so the
        // test can trigger() a SECOND time while genuinely still "running"
        // before manually finishing the first run.
        do {
            var pendingCompletions: [(Int32) -> Void] = []
            let clock = VirtualClock()
            let runner = SchedulerRunner(
                sourceExists: { true },
                runChild: { _, completion in pendingCompletions.append(completion) },
                now: { clock.now },
                scheduleAfter: { s, a in clock.scheduleAfter(s, a) },
                logSourceMissing: {},
                refusalReason: { nil },
                logRefusal: { _ in },
                deleteLimitReached: { false },
                recordDeleteLimit: { true }
            )
            let scheduler = SyncWatchScheduler(runner: runner)
            scheduler.trigger()  // run 1 starts, held open
            guard pendingCompletions.count == 1 else {
                return report("AC-W1", "watch-scheduler", false, "(expected run 1 to start immediately)")
            }
            scheduler.trigger()  // trigger while running -> sets pending
            let firstCompletion = pendingCompletions.removeFirst()
            firstCompletion(0)  // run 1 exits 0 -> pending causes exactly 1 rerun
            guard scheduler.runCount == 2, pendingCompletions.count == 1 else {
                return report(
                    "AC-W1", "watch-scheduler", false,
                    "(trigger-during-run: expected exactly 1 rerun, runCount=\(scheduler.runCount))")
            }
            pendingCompletions.removeFirst()(0)  // finish run 2 cleanly
            guard scheduler.runCount == 2, scheduler.state == .idle else {
                return report("AC-W1", "watch-scheduler", false, "(trigger-during-run: did not settle idle at 2 runs)")
            }
        }

        // Case 2: 5 triggers during a run -> still exactly 1 rerun (coalesced).
        do {
            var pendingCompletions: [(Int32) -> Void] = []
            let clock = VirtualClock()
            let runner = SchedulerRunner(
                sourceExists: { true },
                runChild: { _, completion in pendingCompletions.append(completion) },
                now: { clock.now },
                scheduleAfter: { s, a in clock.scheduleAfter(s, a) },
                logSourceMissing: {},
                refusalReason: { nil },
                logRefusal: { _ in },
                deleteLimitReached: { false },
                recordDeleteLimit: { true }
            )
            let scheduler = SyncWatchScheduler(runner: runner)
            scheduler.trigger()
            for _ in 0..<5 { scheduler.trigger() }
            pendingCompletions.removeFirst()(0)
            guard scheduler.runCount == 2, pendingCompletions.count == 1 else {
                return report(
                    "AC-W1", "watch-scheduler", false,
                    "(5-triggers-during-run: expected exactly 1 rerun, runCount=\(scheduler.runCount))")
            }
            pendingCompletions.removeFirst()(0)
            guard scheduler.runCount == 2 else {
                return report("AC-W1", "watch-scheduler", false, "(5-triggers-during-run: extra rerun happened)")
            }
        }

        // Case 3: a manual sync-now (also just `trigger()`) during a run -> 1 rerun.
        // Same mechanism as case 1 — SIGUSR1 and FSEvents both funnel into the
        // same `trigger()`, so this is the identical assertion under the name
        // the plan uses for it.
        do {
            var pendingCompletions: [(Int32) -> Void] = []
            let clock = VirtualClock()
            let runner = SchedulerRunner(
                sourceExists: { true },
                runChild: { _, completion in pendingCompletions.append(completion) },
                now: { clock.now },
                scheduleAfter: { s, a in clock.scheduleAfter(s, a) },
                logSourceMissing: {},
                refusalReason: { nil },
                logRefusal: { _ in },
                deleteLimitReached: { false },
                recordDeleteLimit: { true }
            )
            let scheduler = SyncWatchScheduler(runner: runner)
            scheduler.trigger()          // run 1 (e.g. FSEvents)
            scheduler.trigger()          // manual "sync now" while running
            pendingCompletions.removeFirst()(1)  // exit 1 (a real failure) still reruns once
            guard scheduler.runCount == 2 else {
                return report("AC-W1", "watch-scheduler", false, "(manual-during-run: expected exactly 1 rerun)")
            }
            pendingCompletions.removeFirst()(0)
        }

        // Case 4: a trigger while idle -> 1 run (the debounce itself is
        // `DirectoryWatcher`'s, already exercised upstream of `trigger()`).
        do {
            let clock = VirtualClock()
            let scheduler = SyncWatchScheduler(
                runner: fakeSchedulerRunner(exitCode: { 0 }, clock: clock))
            scheduler.trigger()
            guard scheduler.runCount == 1, scheduler.state == .idle else {
                return report("AC-W1", "watch-scheduler", false, "(trigger-while-idle: expected exactly 1 run)")
            }
        }

        // Case 5: runner returns 75 repeatedly while the clock advances 60s ->
        // runs <= 60/10 + 1 (fixed 10s backoff between retries, never a hot loop).
        do {
            let clock = VirtualClock()
            let scheduler = SyncWatchScheduler(
                runner: fakeSchedulerRunner(exitCode: { 75 }, clock: clock))
            scheduler.trigger()  // run 1 at t=0
            clock.advance(by: 60)
            guard scheduler.runCount <= 7, scheduler.runCount >= 2 else {
                return report(
                    "AC-W1", "watch-scheduler", false,
                    "(exit-75-backoff: expected 2...7 runs over 60s at a 10s backoff, got \(scheduler.runCount))")
            }
        }

        // Case 6: a missing source path never runs the child.
        do {
            let clock = VirtualClock()
            var missingLogCount = 0
            let scheduler = SyncWatchScheduler(
                runner: fakeSchedulerRunner(
                    sourceExists: { false },
                    exitCode: { 0 },
                    clock: clock,
                    onLogSourceMissing: { missingLogCount += 1 }))
            scheduler.trigger()
            scheduler.trigger()
            clock.advance(by: 5)
            scheduler.trigger()
            guard scheduler.runCount == 0 else {
                return report("AC-W1", "watch-scheduler", false, "(missing-source: expected 0 runs, got \(scheduler.runCount))")
            }
            guard missingLogCount >= 1 else {
                return report("AC-W1", "watch-scheduler", false, "(missing-source: expected at least one source-missing log)")
            }
        }

        return report("AC-W1", "watch-scheduler", true)
    }

    // MARK: - AC-W2 — generated sync script text (limpet-plan.md L3(b))

    private static func testGeneratedScriptText() -> Bool {
        let script = SyncSetupService.shared.generateSyncScript()

        guard script.contains("--links") else {
            return report("AC-W2", "watch-script-text", false, "(missing --links)")
        }
        guard script.contains("exit 75") else {
            return report("AC-W2", "watch-script-text", false, "(missing exit 75 in the lock-held branch)")
        }
        guard script.contains("exit 2") else {
            return report("AC-W2", "watch-script-text", false, "(missing exit 2 for a missing source)")
        }
        guard !script.contains(#"mkdir -p "$LOCAL_PATH""#) else {
            return report("AC-W2", "watch-script-text", false, "(still unconditionally creates $LOCAL_PATH)")
        }
        guard !script.lowercased().contains("hard-delete"), !script.lowercased().contains("hard_delete") else {
            return report("AC-W2", "watch-script-text", false, "(contains a hard-delete flag)")
        }

        return report("AC-W2", "watch-script-text", true)
    }

    // MARK: - AC-W9 — the generated script never hands a config value to eval

    /// Static guard for the P1 fixed here: `eval "$RCLONE_CMD"` re-expanded any
    /// `$`/backtick/`"`/`\` in LOCAL_PATH, REMOTE or FILTER_FILE (all sourced from
    /// the per-profile JSON). The rclone command must be an argv array run directly.
    private static func testGeneratedScriptNoEval() -> Bool {
        let script = SyncSetupService.shared.generateSyncScript()
        guard !script.contains("eval") else {
            return report("AC-W9", "watch-script-no-eval", false, "(script still contains eval)")
        }
        return report("AC-W9", "watch-script-no-eval", true)
    }

    // MARK: - AC-W10 — a hostile LOCAL_PATH reaches rclone literally, never expanded

    /// Behavioral counterpart to AC-W9. Writes the generated script and a profile
    /// config into scratch dirs, with a local source directory whose name contains
    /// `$HOME`, a backtick and a double quote, and a fake `rclone` (injected via the
    /// `RCLONE_BIN` env var the script now honors before its hardcoded candidate
    /// paths) that records its argv one per line. Runs the script with `/bin/bash`
    /// and asserts the recorded source argument is the literal directory path with
    /// no shell expansion. Never touches real rclone, ~/.config, ~/.local or launchd.
    private static func testGeneratedScriptRunsWithoutExpandingConfigValues() -> Bool {
        let fm = FileManager.default
        let root = (selfTestRoot as NSString).appendingPathComponent("ac-w10-no-eval")
        try? fm.removeItem(atPath: root)
        try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)

        // A directory name containing shell metacharacters that `eval` would have
        // re-expanded: `$HOME` (command/variable expansion), a backtick (command
        // substitution) and a double quote (breaks out of the quoted string).
        let hostileName = "Data$HOME`x`\"q"
        let localPath = (root as NSString).appendingPathComponent(hostileName)
        do {
            try fm.createDirectory(atPath: localPath, withIntermediateDirectories: true)
        } catch {
            return report("AC-W10", "watch-script-no-expand", false, "(fixture setup failed: \(error))")
        }

        let scriptPath = (root as NSString).appendingPathComponent("limpet-sync.sh")
        let configPath = (root as NSString).appendingPathComponent("profile.json")
        let filterPath = (root as NSString).appendingPathComponent("exclude.txt")
        let logPath = (root as NSString).appendingPathComponent("sync.log")
        let lockPath = (root as NSString).appendingPathComponent("sync.lock")
        let rcloneStubPath = (root as NSString).appendingPathComponent("rclone-stub.sh")
        let argvPath = (root as NSString).appendingPathComponent("recorded-argv.txt")

        let script = SyncSetupService.shared.generateSyncScript()
        let config: [String: Any] = [
            "remote": "selftest-fixture-remote:SelfTest",
            "localPath": localPath,
            "logPath": logPath,
            "lockFile": lockPath,
            "drivePath": "",
            "additionalFlags": "",
            "filterPath": filterPath,
            "syncDirection": "localToRemote",
            "remotePath": "SelfTest",
            "transfers": 4,
        ]
        // The stub records argv one per line and exits 0. Real rclone is never invoked.
        let rcloneStub = """
            #!/bin/sh
            for arg in "$@"; do
                printf '%s\\n' "$arg"
            done > "\(argvPath)"
            exit 0
            """

        do {
            try "".write(toFile: filterPath, atomically: true, encoding: .utf8)
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
            let configData = try JSONSerialization.data(withJSONObject: config)
            try configData.write(to: URL(fileURLWithPath: configPath))
            try rcloneStub.write(toFile: rcloneStubPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rcloneStubPath)
        } catch {
            return report("AC-W10", "watch-script-no-expand", false, "(fixture setup failed: \(error))")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath, configPath]
        var env = ProcessInfo.processInfo.environment
        env["RCLONE_BIN"] = rcloneStubPath
        process.environment = env
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            return report("AC-W10", "watch-script-no-expand", false, "(could not run script: \(error))")
        }
        process.waitUntilExit()
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            return report("AC-W10", "watch-script-no-expand", false,
                          "(script exited \(process.terminationStatus): \(stderr))")
        }
        guard let argvData = try? String(contentsOfFile: argvPath, encoding: .utf8) else {
            return report("AC-W10", "watch-script-no-expand", false, "(rclone stub was never invoked)")
        }
        let argv = argvData.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard argv.contains(localPath) else {
            return report("AC-W10", "watch-script-no-expand", false,
                          "(local path argument was expanded; recorded argv: \(argv))")
        }
        return report("AC-W10", "watch-script-no-expand", true)
    }

    // MARK: - AC-W11 — the script's own exit code is rclone's, not always 0

    /// The script used to always exit 0 (its last command was an unconditional
    /// `echo`), so `SyncWatchScheduler`/`SyncWatchDaemon` — and a plain
    /// `limpet sync` / `bash limpet-sync.sh` caller — could never see a real
    /// rclone failure in the process exit status, only in the log text. Runs
    /// the script against a fake `rclone` that exits 7 and asserts the script
    /// itself exits 7 (missing-source's 2 and lock-held's 75 are untouched by
    /// this change and already covered by AC-W2 / the scheduler's own tests).
    private static func testGeneratedScriptPropagatesRcloneExitCode() -> Bool {
        let fm = FileManager.default
        let root = (selfTestRoot as NSString).appendingPathComponent("ac-w11-exit-code")
        try? fm.removeItem(atPath: root)
        try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)

        let localPath = (root as NSString).appendingPathComponent("source")
        do {
            try fm.createDirectory(atPath: localPath, withIntermediateDirectories: true)
        } catch {
            return report("AC-W11", "watch-script-exit-code", false, "(fixture setup failed: \(error))")
        }

        let scriptPath = (root as NSString).appendingPathComponent("limpet-sync.sh")
        let configPath = (root as NSString).appendingPathComponent("profile.json")
        let filterPath = (root as NSString).appendingPathComponent("exclude.txt")
        let logPath = (root as NSString).appendingPathComponent("sync.log")
        let lockPath = (root as NSString).appendingPathComponent("sync.lock")
        let rcloneStubPath = (root as NSString).appendingPathComponent("rclone-stub.sh")

        let script = SyncSetupService.shared.generateSyncScript()
        let config: [String: Any] = [
            "remote": "selftest-fixture-remote:SelfTest",
            "localPath": localPath,
            "logPath": logPath,
            "lockFile": lockPath,
            "drivePath": "",
            "additionalFlags": "",
            "filterPath": filterPath,
            "syncDirection": "localToRemote",
            "remotePath": "SelfTest",
            "transfers": 4,
        ]
        // A stub that always fails with a distinctive, non-75/non-2 exit code.
        let rcloneStub = """
            #!/bin/sh
            exit 7
            """

        do {
            try "".write(toFile: filterPath, atomically: true, encoding: .utf8)
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
            let configData = try JSONSerialization.data(withJSONObject: config)
            try configData.write(to: URL(fileURLWithPath: configPath))
            try rcloneStub.write(toFile: rcloneStubPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rcloneStubPath)
        } catch {
            return report("AC-W11", "watch-script-exit-code", false, "(fixture setup failed: \(error))")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath, configPath]
        var env = ProcessInfo.processInfo.environment
        env["RCLONE_BIN"] = rcloneStubPath
        process.environment = env
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            return report("AC-W11", "watch-script-exit-code", false, "(could not run script: \(error))")
        }
        process.waitUntilExit()
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 7 else {
            return report("AC-W11", "watch-script-exit-code", false,
                          "(expected exit 7, got \(process.terminationStatus): \(stderr))")
        }
        return report("AC-W11", "watch-script-exit-code", true)
    }

    // MARK: - AC-W12 — a quoted/hostile additionalRcloneFlags is refused, not passed through

    /// Regression found by /code-review on the array-based rebuild: `read -r -a`
    /// passes quotes, `$` and `~` in additionalFlags to rclone LITERALLY, where the
    /// old `eval` form used to interpret them — so `--exclude "*.tmp"` used to reach
    /// rclone as the two shell-parsed tokens `--exclude` and `*.tmp`, but now arrives
    /// as `--exclude` and the single literal token `"*.tmp"` (quotes included),
    /// which matches nothing and silently starts syncing files meant to be excluded.
    /// The script now refuses (exit 64) before ever invoking rclone whenever a
    /// token contains a quote, backtick, `$`, or starts with `~`.
    private static func testGeneratedScriptRefusesQuotedAdditionalFlags() -> Bool {
        let fm = FileManager.default
        let root = (selfTestRoot as NSString).appendingPathComponent("ac-w12-refuse-flags")
        try? fm.removeItem(atPath: root)
        try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)

        let localPath = (root as NSString).appendingPathComponent("source")
        do {
            try fm.createDirectory(atPath: localPath, withIntermediateDirectories: true)
        } catch {
            return report("AC-W12", "watch-script-refuses-quoted-flags", false, "(fixture setup failed: \(error))")
        }

        let scriptPath = (root as NSString).appendingPathComponent("limpet-sync.sh")
        let configPath = (root as NSString).appendingPathComponent("profile.json")
        let filterPath = (root as NSString).appendingPathComponent("exclude.txt")
        let logPath = (root as NSString).appendingPathComponent("sync.log")
        let lockPath = (root as NSString).appendingPathComponent("sync.lock")
        let rcloneStubPath = (root as NSString).appendingPathComponent("rclone-stub.sh")
        let argvPath = (root as NSString).appendingPathComponent("recorded-argv.txt")

        let script = SyncSetupService.shared.generateSyncScript()
        let config: [String: Any] = [
            "remote": "selftest-fixture-remote:SelfTest",
            "localPath": localPath,
            "logPath": logPath,
            "lockFile": lockPath,
            "drivePath": "",
            "additionalFlags": "--exclude \"*.tmp\"",
            "filterPath": filterPath,
            "syncDirection": "localToRemote",
            "remotePath": "SelfTest",
            "transfers": 4,
        ]
        let rcloneStub = """
            #!/bin/sh
            for arg in "$@"; do
                printf '%s\\n' "$arg"
            done > "\(argvPath)"
            exit 0
            """

        do {
            try "".write(toFile: filterPath, atomically: true, encoding: .utf8)
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
            let configData = try JSONSerialization.data(withJSONObject: config)
            try configData.write(to: URL(fileURLWithPath: configPath))
            try rcloneStub.write(toFile: rcloneStubPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rcloneStubPath)
        } catch {
            return report("AC-W12", "watch-script-refuses-quoted-flags", false, "(fixture setup failed: \(error))")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath, configPath]
        var env = ProcessInfo.processInfo.environment
        env["RCLONE_BIN"] = rcloneStubPath
        process.environment = env
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            return report("AC-W12", "watch-script-refuses-quoted-flags", false, "(could not run script: \(error))")
        }
        process.waitUntilExit()
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 64 else {
            return report("AC-W12", "watch-script-refuses-quoted-flags", false,
                          "(expected exit 64, got \(process.terminationStatus): \(stderr))")
        }
        guard !fm.fileExists(atPath: argvPath) else {
            return report("AC-W12", "watch-script-refuses-quoted-flags", false, "(rclone stub was invoked)")
        }
        guard let logText = try? String(contentsOfFile: logPath, encoding: .utf8),
              logText.contains("Refusing to sync") else {
            return report("AC-W12", "watch-script-refuses-quoted-flags", false, "(no refusal line in the log)")
        }
        return report("AC-W12", "watch-script-refuses-quoted-flags", true)
    }

    // MARK: - AC-W13 — a well-formed --flag=value additionalRcloneFlags still works

    /// Positive counterpart to AC-W12: flags written the documented way
    /// (`--flag=value`, no quotes/spaces inside a value) must still reach rclone,
    /// unmodified, as their own argv elements.
    private static func testGeneratedScriptAcceptsFlagEqualsValueForm() -> Bool {
        let fm = FileManager.default
        let root = (selfTestRoot as NSString).appendingPathComponent("ac-w13-flag-equals-value")
        try? fm.removeItem(atPath: root)
        try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)

        let localPath = (root as NSString).appendingPathComponent("source")
        do {
            try fm.createDirectory(atPath: localPath, withIntermediateDirectories: true)
        } catch {
            return report("AC-W13", "watch-script-accepts-flag-equals-value", false, "(fixture setup failed: \(error))")
        }

        let scriptPath = (root as NSString).appendingPathComponent("limpet-sync.sh")
        let configPath = (root as NSString).appendingPathComponent("profile.json")
        let filterPath = (root as NSString).appendingPathComponent("exclude.txt")
        let logPath = (root as NSString).appendingPathComponent("sync.log")
        let lockPath = (root as NSString).appendingPathComponent("sync.lock")
        let rcloneStubPath = (root as NSString).appendingPathComponent("rclone-stub.sh")
        let argvPath = (root as NSString).appendingPathComponent("recorded-argv.txt")

        let script = SyncSetupService.shared.generateSyncScript()
        let config: [String: Any] = [
            "remote": "selftest-fixture-remote:SelfTest",
            "localPath": localPath,
            "logPath": logPath,
            "lockFile": lockPath,
            "drivePath": "",
            "additionalFlags": "--exclude=*.tmp --bwlimit=5M",
            "filterPath": filterPath,
            "syncDirection": "localToRemote",
            "remotePath": "SelfTest",
            "transfers": 4,
        ]
        let rcloneStub = """
            #!/bin/sh
            for arg in "$@"; do
                printf '%s\\n' "$arg"
            done > "\(argvPath)"
            exit 0
            """

        do {
            try "".write(toFile: filterPath, atomically: true, encoding: .utf8)
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
            let configData = try JSONSerialization.data(withJSONObject: config)
            try configData.write(to: URL(fileURLWithPath: configPath))
            try rcloneStub.write(toFile: rcloneStubPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rcloneStubPath)
        } catch {
            return report("AC-W13", "watch-script-accepts-flag-equals-value", false, "(fixture setup failed: \(error))")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath, configPath]
        var env = ProcessInfo.processInfo.environment
        env["RCLONE_BIN"] = rcloneStubPath
        process.environment = env
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            return report("AC-W13", "watch-script-accepts-flag-equals-value", false, "(could not run script: \(error))")
        }
        process.waitUntilExit()
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            return report("AC-W13", "watch-script-accepts-flag-equals-value", false,
                          "(script exited \(process.terminationStatus): \(stderr))")
        }
        guard let argvData = try? String(contentsOfFile: argvPath, encoding: .utf8) else {
            return report("AC-W13", "watch-script-accepts-flag-equals-value", false, "(rclone stub was never invoked)")
        }
        // split(separator:) already drops the trailing empty element from the
        // stub's final trailing newline, so `suffix(2)` is the last two real args.
        let argv = argvData.split(separator: "\n").map(String.init)
        // The last two argv elements must be exactly these two literal tokens —
        // proof the flags reached rclone as their own elements, untouched.
        guard argv.count >= 2, Array(argv.suffix(2)) == ["--exclude=*.tmp", "--bwlimit=5M"] else {
            return report("AC-W13", "watch-script-accepts-flag-equals-value", false,
                          "(unexpected argv tail: \(argv))")
        }
        return report("AC-W13", "watch-script-accepts-flag-equals-value", true)
    }

    // MARK: - AC-W3 — generated launchd plist shape (limpet-plan.md L3(c))

    // MARK: - AC-W8 — the shim passes a hostile executable path through literally

    /// The shim is what every LaunchAgent executes, so a path containing shell
    /// metacharacters must neither break it nor be expanded. Runs the generated shim
    /// with /bin/sh against a fake executable inside such a directory.
    private static func testShimQuotesHostilePath() -> Bool {
        let fm = FileManager.default
        let root = (selfTestRoot as NSString).appendingPathComponent("shim-quote")
        try? fm.removeItem(atPath: root)
        let marker = (root as NSString).appendingPathComponent("expanded")
        let hostileDir = (root as NSString).appendingPathComponent("a\"b$(touch \(marker))`x`c'd")
        let fakeExe = (hostileDir as NSString).appendingPathComponent("limpet")
        let shim = (root as NSString).appendingPathComponent("limpet-shim")
        do {
            try fm.createDirectory(atPath: hostileDir, withIntermediateDirectories: true)
            try "#!/bin/sh\nprintf '%s|' \"$@\"\n".write(toFile: fakeExe, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeExe)
        } catch {
            return report("AC-W8", "shim-quotes-hostile-path", false, "(fixture setup failed: \(error))")
        }
        guard CLIShimInstaller.install(executablePath: fakeExe, shimPath: shim) else {
            return report("AC-W8", "shim-quotes-hostile-path", false, "(shim was not written)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [shim, "watch", "ab12cd34"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch {
            return report("AC-W8", "shim-quotes-hostile-path", false, "(could not run shim: \(error))")
        }
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0, output == "watch|ab12cd34|" else {
            return report("AC-W8", "shim-quotes-hostile-path", false,
                          "(status \(process.terminationStatus), output \(output.debugDescription))")
        }
        guard !fm.fileExists(atPath: marker) else {
            return report("AC-W8", "shim-quotes-hostile-path", false, "(command substitution in the path was executed)")
        }
        return report("AC-W8", "shim-quotes-hostile-path", true)
    }

    // MARK: - Script fixture shared by AC-W14/AC-W15

    /// Runs the generated sync script once against a stub rclone, with `overrides`
    /// merged into a minimal valid profile config. Returns nil if the fixture could
    /// not be set up; otherwise the script's exit status, whether the stub ran, and
    /// the profile log text.
    private static func runScriptFixture(
        name: String, overrides: [String: Any], stubTail: String = "exit 0\n", extraEnvironment: [String: String] = [:]
    ) -> (status: Int32, stubRan: Bool, log: String, argv: [String])? {
        let fm = FileManager.default
        let root = (selfTestRoot as NSString).appendingPathComponent(name)
        try? fm.removeItem(atPath: root)
        let localPath = (root as NSString).appendingPathComponent("source")
        let scriptPath = (root as NSString).appendingPathComponent("limpet-sync.sh")
        let configPath = (root as NSString).appendingPathComponent("profile.json")
        let filterPath = (root as NSString).appendingPathComponent("exclude.txt")
        let logPath = (root as NSString).appendingPathComponent("sync.log")
        let stubPath = (root as NSString).appendingPathComponent("rclone-stub.sh")
        let ranPath = (root as NSString).appendingPathComponent("stub-ran")
        let argvPath = (root as NSString).appendingPathComponent("stub-argv")
        var config: [String: Any] = [
            "remote": "selftest-fixture-remote:SelfTest",
            "localPath": localPath,
            "logPath": logPath,
            "lockFile": (root as NSString).appendingPathComponent("sync.lock"),
            "drivePath": "",
            "additionalFlags": "",
            "filterPath": filterPath,
            "syncDirection": "localToRemote",
            "remotePath": "SelfTest",
            "transfers": 4,
        ]
        config.merge(overrides) { _, new in new }
        do {
            try fm.createDirectory(atPath: localPath, withIntermediateDirectories: true)
            try "".write(toFile: filterPath, atomically: true, encoding: .utf8)
            try SyncSetupService.shared.generateSyncScript().write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try JSONSerialization.data(withJSONObject: config).write(to: URL(fileURLWithPath: configPath))
            try ("#!/bin/sh\ntouch \"\(ranPath)\"\nprintf '%s\\n' \"$@\" > \"\(argvPath)\"\n" + stubTail)
                .write(toFile: stubPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubPath)
        } catch {
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath, configPath]
        var env = ProcessInfo.processInfo.environment
        env["RCLONE_BIN"] = stubPath
        env.merge(extraEnvironment) { _, new in new }
        process.environment = env
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        let argv = ((try? String(contentsOfFile: argvPath, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        return (process.terminationStatus, fm.fileExists(atPath: ranPath), log, argv)
    }

    /// Like `runScriptFixture`, but the stub rclone RECORDS every invocation
    /// (appending, not overwriting) — needed for the trash purge, which can
    /// call the stub more than once (`lsf --dirs-only`, zero or more `purge`,
    /// then the sync itself). `stubBody` is the stub's own branching logic
    /// (may test `"$1"`/`"$@"`). `reset: false` reuses a previous call's
    /// fixture directory (so its `<shortId>.trash-purged` stamp survives) —
    /// only the invocations log is always fresh, so `invocations` reflects
    /// just THIS call.
    private static func runScriptFixtureAppending(
        name: String, overrides: [String: Any], stubBody: String, reset: Bool = true,
        extraEnvironment: [String: String] = [:]
    ) -> (status: Int32, log: String, invocations: [[String]])? {
        let fm = FileManager.default
        let root = (selfTestRoot as NSString).appendingPathComponent(name)
        if reset { try? fm.removeItem(atPath: root) }
        let localPath = (root as NSString).appendingPathComponent("source")
        let scriptPath = (root as NSString).appendingPathComponent("limpet-sync.sh")
        let configPath = (root as NSString).appendingPathComponent("profile.json")
        let filterPath = (root as NSString).appendingPathComponent("exclude.txt")
        let logPath = (root as NSString).appendingPathComponent("sync.log")
        let stubPath = (root as NSString).appendingPathComponent("rclone-stub.sh")
        let invocationsPath = (root as NSString).appendingPathComponent("invocations.log")
        try? fm.removeItem(atPath: invocationsPath)
        var config: [String: Any] = [
            "remote": "selftest-fixture-remote:SelfTest",
            "localPath": localPath,
            "logPath": logPath,
            "lockFile": (root as NSString).appendingPathComponent("sync.lock"),
            "drivePath": "",
            "additionalFlags": "",
            "filterPath": filterPath,
            "syncDirection": "localToRemote",
            "remotePath": "SelfTest",
            "transfers": 4,
        ]
        config.merge(overrides) { _, new in new }
        do {
            try fm.createDirectory(atPath: localPath, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: filterPath) {
                try "".write(toFile: filterPath, atomically: true, encoding: .utf8)
            }
            try SyncSetupService.shared.generateSyncScript().write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try JSONSerialization.data(withJSONObject: config).write(to: URL(fileURLWithPath: configPath))
            try ("#!/bin/sh\nprintf '%s\\t' \"$@\" >> \"\(invocationsPath)\"\nprintf '\\n' >> \"\(invocationsPath)\"\n" + stubBody)
                .write(toFile: stubPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubPath)
        } catch {
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath, configPath]
        var env = ProcessInfo.processInfo.environment
        env["RCLONE_BIN"] = stubPath
        env.merge(extraEnvironment) { _, new in new }
        process.environment = env
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        let invocations = ((try? String(contentsOfFile: invocationsPath, encoding: .utf8)) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.split(separator: "\t", omittingEmptySubsequences: true).map(String.init) }
        return (process.terminationStatus, log, invocations)
    }

    // MARK: - AC-W16 — --dump flags are refused (they can log credentials)

    private static func testScriptRefusesDumpFlags() -> Bool {
        for flags in ["--dump auth", "--dump=headers", "--bwlimit=5M --dump-headers"] {
            guard let result = runScriptFixture(name: "ac-w16-dump", overrides: ["additionalFlags": flags]) else {
                return report("AC-W16", "script-refuses-dump-flags", false, "(fixture setup failed)")
            }
            guard result.status == 64, !result.stubRan, result.log.contains("contains --dump") else {
                return report("AC-W16", "script-refuses-dump-flags", false,
                              "(\(flags): status \(result.status), stubRan \(result.stubRan))")
            }
        }
        return report("AC-W16", "script-refuses-dump-flags", true)
    }

    // MARK: - AC-W14 — `transfers` is never evaluated as shell arithmetic

    /// bash arithmetic evaluates command substitutions inside an array subscript, so
    /// a non-numeric `transfers` in the derived config must be refused, not computed.
    private static func testScriptRefusesNonNumericTransfers() -> Bool {
        let marker = (selfTestRoot as NSString).appendingPathComponent("ac-w14-executed")
        try? FileManager.default.removeItem(atPath: marker)
        guard let result = runScriptFixture(
            name: "ac-w14-transfers", overrides: ["transfers": "a[$(touch \(marker))]"]) else {
            return report("AC-W14", "script-refuses-non-numeric-transfers", false, "(fixture setup failed)")
        }
        guard !FileManager.default.fileExists(atPath: marker) else {
            return report("AC-W14", "script-refuses-non-numeric-transfers", false, "(command in transfers was executed)")
        }
        guard result.status == 64, !result.stubRan, result.log.contains("transfers must be a whole number") else {
            return report("AC-W14", "script-refuses-non-numeric-transfers", false,
                          "(status \(result.status), stubRan \(result.stubRan))")
        }
        return report("AC-W14", "script-refuses-non-numeric-transfers", true)
    }

    // MARK: - AC-W15 — multi-line additionalRcloneFlags are refused, not truncated

    /// `read -r -a` reads one line only; a flag after a newline (here `--dry-run`)
    /// would be dropped and the run would be a real sync. Must exit 64 instead.
    private static func testScriptRefusesMultilineFlags() -> Bool {
        guard let result = runScriptFixture(
            name: "ac-w15-multiline", overrides: ["additionalFlags": "--exclude=*.tmp\n--dry-run"]) else {
            return report("AC-W15", "script-refuses-multiline-flags", false, "(fixture setup failed)")
        }
        guard result.status == 64, !result.stubRan, result.log.contains("line break") else {
            return report("AC-W15", "script-refuses-multiline-flags", false,
                          "(status \(result.status), stubRan \(result.stubRan))")
        }
        return report("AC-W15", "script-refuses-multiline-flags", true)
    }

    // MARK: - AC-W4 — a missing localToRemote source is refused, never created

    /// Creating a missing source would hand the watcher an empty directory, and the
    /// first sync would delete everything on the remote. Only the localToRemote branch
    /// is exercised: it returns before `cleanupLegacyCheckFiles`, which would run rclone.
    private static func testMissingSourceIsNotCreated() -> Bool {
        var profile = sampleProfile()
        profile.localSyncPath = (selfTestRoot as NSString).appendingPathComponent("missing-source")
        profile.syncDirection = .localToRemote
        try? FileManager.default.removeItem(atPath: profile.localSyncPath)

        let error = SyncSetupService.shared.initializeSyncPaths(for: profile)
        guard error != nil else {
            return report("AC-W4", "missing-source-not-created", false, "(expected an error for a missing source)")
        }
        guard !FileManager.default.fileExists(atPath: profile.localSyncPath) else {
            return report("AC-W4", "missing-source-not-created", false, "(the missing source directory was created)")
        }
        return report("AC-W4", "missing-source-not-created", true)
    }

    // MARK: - AC-W5 — changing only `transfers` reinstalls the agent

    private static func testTransfersChangeReinstalls() -> Bool {
        let current = sampleProfile()
        var updated = current
        updated.transfers = current.transfers + 8
        let action = SyncManager.reconcileAction(from: current, to: updated)
        return report("AC-W5", "transfers-change-reinstalls", action == .reinstall, "(got \(action))")
    }

    private static func testGeneratedPlistShape() -> Bool {
        let profile = sampleProfile()
        // A fake shim path distinct from the real ~/.local/bin/limpet, so this
        // assertion is meaningless unless ProgramArguments actually carries the
        // value passed in (and not, say, the app's own executable path).
        let fakeShimPath = "/tmp/limpet-selftest-shim/limpet"
        let plist = SyncSetupService.shared.generateLaunchdPlist(for: profile, shimPath: fakeShimPath)

        // Match the key together with its value: a bare `contains("<true/>")` is also
        // satisfied by RunAtLoad's value and would pass with KeepAlive set to false.
        guard plist.range(of: #"<key>KeepAlive</key>\s*<true/>"#, options: .regularExpression) != nil else {
            return report("AC-W3", "watch-plist-shape", false, "(missing KeepAlive true)")
        }
        guard plist.range(of: #"<key>RunAtLoad</key>\s*<true/>"#, options: .regularExpression) != nil else {
            return report("AC-W3", "watch-plist-shape", false, "(missing RunAtLoad)")
        }
        // A shim path with XML-special characters must still yield a valid plist that
        // round-trips to the exact path (the plist is serialized, not templated), AND
        // ProgramArguments[0] must be exactly the shim path — never the app binary.
        let oddPath = "/tmp/a&b<c>/limpet-shim/limpet"
        let oddXML = SyncSetupService.shared.generateLaunchdPlist(for: profile, shimPath: oddPath)
        guard let parsed = try? PropertyListSerialization.propertyList(
                  from: Data(oddXML.utf8), options: [], format: nil) as? [String: Any],
              let args = parsed["ProgramArguments"] as? [String],
              args == [oddPath, "watch", profile.shortId] else {
            return report("AC-W3", "watch-plist-shape", false, "(plist with an XML-special shim path did not round-trip)")
        }
        guard let fakeParsed = try? PropertyListSerialization.propertyList(
                  from: Data(plist.utf8), options: [], format: nil) as? [String: Any],
              let fakeArgs = fakeParsed["ProgramArguments"] as? [String],
              fakeArgs == [fakeShimPath, "watch", profile.shortId] else {
            return report(
                "AC-W3", "watch-plist-shape", false,
                "(ProgramArguments is not exactly [shimPath, \"watch\", shortId])")
        }
        guard !plist.contains("StartInterval") else {
            return report("AC-W3", "watch-plist-shape", false, "(still has StartInterval)")
        }

        return report("AC-W3", "watch-plist-shape", true)
    }

    // MARK: - AC-W6 — App Translocation refuses install / shim write

    /// A translocated executable path must be refused both by the shim
    /// installer (called on every GUI launch) and by the guard
    /// `SyncSetupService.install(profile:)` checks before doing anything else.
    /// Exercises the pure, no-side-effect `isTranslocated` predicate plus
    /// `CLIShimInstaller.install` against a temp path — never the real
    /// ~/.local/bin/limpet, and `install(profile:)` itself is never called
    /// here since it also touches real ~/Library/LaunchAgents paths.
    private static func testTranslocatedAppRefused() -> Bool {
        let translocatedPath = "/private/tmp/AppTranslocation/ABCDEF12-3456/d/limpet.app/Contents/MacOS/limpet"
        guard CLIShimInstaller.isTranslocated(translocatedPath) else {
            return report("AC-W6", "translocated-app-refused", false, "(isTranslocated didn't flag a translocated path)")
        }
        guard !CLIShimInstaller.isTranslocated("/Applications/limpet.app/Contents/MacOS/limpet") else {
            return report("AC-W6", "translocated-app-refused", false, "(isTranslocated false-positived on a normal path)")
        }

        let shimDir = "\(selfTestRoot)/ac-w6-shim"
        try? FileManager.default.removeItem(atPath: shimDir)
        let shimPath = "\(shimDir)/limpet"
        guard CLIShimInstaller.install(executablePath: translocatedPath, shimPath: shimPath) == false else {
            return report("AC-W6", "translocated-app-refused", false, "(shim install did not refuse a translocated executable path)")
        }
        guard !FileManager.default.fileExists(atPath: shimPath) else {
            return report("AC-W6", "translocated-app-refused", false, "(shim was written despite a translocated executable path)")
        }

        return report("AC-W6", "translocated-app-refused", true)
    }

    // MARK: - AC-W7 — install() refuses to write over a non-owned shim

    /// `SyncSetupService.install(profile:)` must never point a LaunchAgent at
    /// a file it doesn't own. `canWriteShim` is the exact guard `install`
    /// checks before calling `CLIShimInstaller.install` — verified here
    /// against a temp path with a foreign (unmarked) file, never the real
    /// ~/.local/bin/limpet.
    private static func testInstallRefusesNonOwnedShim() -> Bool {
        let shimDir = "\(selfTestRoot)/ac-w7-shim"
        try? FileManager.default.removeItem(atPath: shimDir)
        try? FileManager.default.createDirectory(atPath: shimDir, withIntermediateDirectories: true)
        let shimPath = "\(shimDir)/limpet"

        guard SyncSetupService.canWriteShim(at: shimPath) else {
            return report("AC-W7", "install-refuses-nonowned-shim", false, "(refused an absent shim path)")
        }

        let foreignContent = "#!/bin/sh\necho not ours\n"
        try? foreignContent.write(toFile: shimPath, atomically: true, encoding: .utf8)
        guard SyncSetupService.canWriteShim(at: shimPath) == false else {
            return report("AC-W7", "install-refuses-nonowned-shim", false, "(allowed writing over a foreign, unmarked file)")
        }

        try? "\(CLIShimInstaller.ownershipMarker)\necho ours\n".write(toFile: shimPath, atomically: true, encoding: .utf8)
        guard SyncSetupService.canWriteShim(at: shimPath) else {
            return report("AC-W7", "install-refuses-nonowned-shim", false, "(refused a file limpet owns)")
        }

        return report("AC-W7", "install-refuses-nonowned-shim", true)
    }

    // MARK: - L4 validation fixtures (limpet-plan.md L4 F4/F6)

    /// A connection string carrying a recognisable fake secret, so every
    /// assertion below can also check the value never reached a file or output.
    private static let connectionStringSecret = "SEKRET-connstr-7f3a"
    private static var connectionStringRemote: String {
        ":s3,access_key_id=AKID,secret_access_key=\(connectionStringSecret):bucket"
    }
    private static let translocatedExecutable =
        "/private/tmp/AppTranslocation/ABCDEF12-3456/d/limpet.app/Contents/MacOS/limpet"

    /// JSON for `profile` with `rcloneRemote` replaced — built from a dict so a
    /// refused value can be written without going through the (refusing) encoder.
    private static func profileJSON(_ profile: SyncProfile, rcloneRemote: String) -> String {
        let dict: [String: Any] = [
            "id": profile.id.uuidString, "name": profile.name, "rcloneRemote": rcloneRemote,
            "remotePath": profile.remotePath, "localSyncPath": profile.localSyncPath, "isEnabled": true,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - AC-L4-1 — refused remote specs never decode, never get written

    private static func testRemoteSpecRefusedAtDecodeAndWrite() -> Bool {
        let id = "AC-L4-1", slug = "remote-spec-refused-at-decode-and-write"
        let base = sampleProfile()
        for refused in [connectionStringRemote, ":local:", "myremote,x=y:", "a=b"] {
            let json = profileJSON(base, rcloneRemote: refused)
            if (try? JSONDecoder().decode(SyncProfile.self, from: Data(json.utf8))) != nil {
                return report(id, slug, false, "(\(refused.debugDescription) decoded)")
            }
        }
        for accepted in ["b2-home", "b2-home:", "limpet_test_s4"] {
            let json = profileJSON(base, rcloneRemote: accepted)
            guard (try? JSONDecoder().decode(SyncProfile.self, from: Data(json.utf8))) != nil else {
                return report(id, slug, false, "(\(accepted.debugDescription) was refused)")
            }
        }

        // Write seam: a profile built in memory (bypassing decode) is never written.
        let dir = "\(selfTestRoot)/ac-l4-1"
        try? FileManager.default.removeItem(atPath: dir)
        var bad = base
        bad.rcloneRemote = connectionStringRemote
        guard ProfileStore.writeProfileFile(bad, in: dir) == nil,
              !FileManager.default.fileExists(atPath: "\(dir)/\(bad.shortId).profile.json") else {
            return report(id, slug, false, "(writeProfileFile wrote a connection-string profile)")
        }
        // The app's store keeps it out of memory too, so the blob mirror never gets it.
        let defaults = UserDefaults(suiteName: "com.nanako.limpet.selftest.l4-1.\(UUID().uuidString)")!
        let store = ProfileStore(profilesDirectory: dir, defaults: defaults)
        store.add(bad)
        let blob = defaults.data(forKey: ProfileStore.profilesKey).map { String(decoding: $0, as: UTF8.self) } ?? ""
        guard store.profiles.isEmpty, !blob.contains(connectionStringSecret) else {
            return report(id, slug, false, "(ProfileStore.add kept a connection-string profile)")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L4-2 — CLI profile create / set refuse a connection string

    private static func testRemoteSpecRefusedAtCLI() -> Bool {
        let id = "AC-L4-2", slug = "remote-spec-refused-at-cli"
        let existing = sampleProfile(name: "Existing")
        var output = "", wrote = false, installed = false
        let env = fakeCLIEnvironment(
            readProfiles: { [existing] },
            writeProfile: { _ in wrote = true; return true },
            installProfile: { _ in installed = true; return nil },
            readStdin: { profileJSON(sampleProfile(name: "New"), rcloneRemote: connectionStringRemote) },
            stdout: { output += $0 },
            stderr: { output += $0 }
        )
        guard LimpetCLI.execute(["profile", "create", "-"], env: env) == 65, !wrote, !installed else {
            return report(id, slug, false, "(profile create accepted a connection string)")
        }
        guard LimpetCLI.execute(["profile", "set", existing.shortId, "rcloneRemote", connectionStringRemote], env: env) == 65,
              !wrote, !installed else {
            return report(id, slug, false, "(profile set accepted a connection string)")
        }
        guard !output.contains(connectionStringSecret) else {
            return report(id, slug, false, "(the refused value was echoed to stdout/stderr)")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L4-3 — install and a reconcile-driven reinstall refuse before any side effect

    /// `install` is called with a TRANSLOCATED executable path on purpose: F4/F6
    /// run before the translocation guard, so a passing run throws
    /// `.refusedProfile`, and a regression throws `.translocatedApp` instead —
    /// either way nothing real under ~/.local or ~/Library is ever written.
    private static func testRefusedAtInstall() -> Bool {
        let id = "AC-L4-3", slug = "refused-at-install"
        func installError(_ profile: SyncProfile, others: [SyncProfile]) -> Error? {
            do {
                try SyncSetupService.shared.install(
                    profile: profile, loadAgent: false,
                    executablePath: translocatedExecutable, otherProfiles: others, isInstalled: { _ in true })
                return nil
            } catch { return error }
        }
        func isRefusal(_ error: Error?) -> Bool {
            if case .refusedProfile? = error as? SyncSetupService.SetupError { return true }
            return false
        }
        var bad = sampleProfile()
        bad.rcloneRemote = connectionStringRemote
        let badError = installError(bad, others: [])
        guard isRefusal(badError), !"\(badError!)".contains(connectionStringSecret) else {
            return report(id, slug, false, "(install did not refuse a connection string: \(String(describing: badError)))")
        }
        let first = sampleProfile(name: "First")
        var nested = sampleProfile(name: "Nested")
        nested.remotePath = first.remotePath + "/inner"
        guard isRefusal(installError(nested, others: [first])) else {
            return report(id, slug, false, "(install did not refuse an overlapping profile)")
        }

        // Reconcile-driven reinstall: `limpet reinstall` routes uninstall → install;
        // the install step is the real one, so the refusal surfaces as a failed reinstall.
        var reinstallErr = ""
        let env = fakeCLIEnvironment(
            readProfiles: { [bad] },
            installProfile: { profile in
                installError(profile, others: []).map { "\($0)" }
            },
            stderr: { reinstallErr += $0 }
        )
        guard LimpetCLI.execute(["reinstall", bad.shortId], env: env) == 1,
              reinstallErr.contains("refusedProfile") else {
            return report(id, slug, false, "(reinstall of a connection-string profile was not refused: \(reinstallErr))")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L4-4 — overlapping remote paths refused at create, set and file drop

    private static func testOverlapRefused() -> Bool {
        let id = "AC-L4-4", slug = "overlap-refused"
        let first = sampleProfile(name: "First")  // selftest-fixture-remote: / SelfTest

        // The pure rule: equal, nested (either way), trailing/double slashes and
        // remote-name case all overlap; a sibling prefix or another remote does not.
        func overlaps(remote: String, path: String) -> Bool {
            var other = sampleProfile(name: "Other")
            other.rcloneRemote = remote
            other.remotePath = path
            return SyncProfile.overlapError(other, among: [first], isInstalled: { _ in true }) != nil
        }
        let expectOverlap = [("selftest-fixture-remote:", "SelfTest"), ("selftest-fixture-remote", "SelfTest/"),
                             ("SELFTEST-fixture-remote:", "SelfTest//a"), ("selftest-fixture-remote:", "")]
        for (remote, path) in expectOverlap where !overlaps(remote: remote, path: path) {
            return report(id, slug, false, "(\(remote)\(path) was not seen as overlapping)")
        }
        for (remote, path) in [("selftest-fixture-remote:", "SelfTest2"), ("other-remote:", "SelfTest")]
        where overlaps(remote: remote, path: path) {
            return report(id, slug, false, "(\(remote)\(path) was wrongly seen as overlapping)")
        }
        guard SyncProfile.overlapError(first, among: [first], isInstalled: { _ in true }) == nil else {
            return report(id, slug, false, "(a profile overlapped with itself)")
        }

        // CLI create.
        var wrote = false, installed = false
        var nested = sampleProfile(name: "Nested")
        nested.remotePath = "SelfTest/inner"
        guard let nestedJSON = try? JSONEncoder().encode(nested) else {
            return report(id, slug, false, "(could not encode fixture)")
        }
        let createEnv = fakeCLIEnvironment(
            readProfiles: { [first] },
            fileExists: { $0 == first.plistPath },
            writeProfile: { _ in wrote = true; return true },
            installProfile: { _ in installed = true; return nil },
            readStdin: { String(decoding: nestedJSON, as: UTF8.self) }
        )
        guard LimpetCLI.execute(["profile", "create", "-"], env: createEnv) == 65, !wrote, !installed else {
            return report(id, slug, false, "(profile create accepted an overlapping profile)")
        }

        // CLI profile set: moving a disjoint profile under the first one.
        var disjoint = sampleProfile(name: "Disjoint")
        disjoint.remotePath = "Elsewhere"
        let setEnv = fakeCLIEnvironment(
            readProfiles: { [first, disjoint] },
            fileExists: { $0 == first.plistPath },
            writeProfile: { _ in wrote = true; return true },
            installProfile: { _ in installed = true; return nil },
            uninstallProfile: { _ in installed = true; return nil }
        )
        guard LimpetCLI.execute(["profile", "set", disjoint.shortId, "remotePath", "SelfTest/moved"], env: setEnv) == 65,
              !wrote, !installed else {
            return report(id, slug, false, "(profile set accepted an overlapping remotePath)")
        }

        // File drop.
        var persisted = 0, dropInstalled = 0, quarantined = 0
        let outcome = SyncManager.applyExternalCreateIfNeeded(
            decoded: nested, isKnownId: false, existing: [first], isInstalled: { _ in true },
            persist: { _ in persisted += 1 }, install: { _ in dropInstalled += 1 },
            quarantine: { _ in quarantined += 1 })
        guard outcome == .refusedOverlap, persisted == 0, dropInstalled == 0, quarantined == 1 else {
            return report(id, slug, false, "(file drop: \(outcome), persist=\(persisted) install=\(dropInstalled))")
        }
        return report(id, slug, true)
    }

    // MARK: - L4 keychain fixtures (limpet-plan.md L4 F2/F3/F5/F7)

    /// Run a tool with a hard timeout; returns (status, stdout). Status -9 = timed out.
    private static func runTool(_ path: String, _ args: [String], timeout: TimeInterval = 20) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = Pipe()
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        guard (try? process.run()) != nil else { return (-1, "") }
        guard done.wait(timeout: .now() + timeout) == .success else { process.terminate(); return (-9, "") }
        return (process.terminationStatus, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    /// A FAKE `security` (a shell script). No self-test ever runs the real
    /// `/usr/bin/security` or touches any real keychain, throwaway ones
    /// included: on 2026-09-26 keychain operations on this machine raised
    /// login-keychain dialogs for the user, so the real behaviour (ACL, prompt
    /// freedom) is verified live by the verifier, not here.
    ///
    /// Behaviour: every call appends its argv (space-joined) to `<dir>/calls`
    /// and writes it to `<dir>/argv`; `-i` saves its stdin to `<dir>/add-stdin`
    /// and stores the hex `-X` value (decoded) in `<dir>/stored`;
    /// `delete-generic-password` removes it (44 if absent); `find-generic-password`
    /// answers per `<dir>/mode`: `found` (prints `secret`), `missing` (44),
    /// `error` (51), `hang` (sleeps 5 s), anything else = print `stored` (44
    /// if absent). A file `<dir>/fail-<first argument>` makes that call exit 51;
    /// `<dir>/corrupt-add` makes `-i` store something other than the secret.
    private static func makeSecurityStub(in dir: String, secret: String, mode: String = "found") -> String? {
        let stub = "\(dir)/security-stub"
        let body = """
            #!/bin/sh
            D="\(dir)"
            printf '%s\\n' "$@" > "$D/argv"
            echo "$*" >> "$D/calls"
            input=$(cat)
            [ -f "$D/fail-$1" ] && exit 51
            mode=$(cat "$D/mode")
            case "$1" in
              -i)
                printf '%s\\n' "$input" > "$D/add-stdin"
                [ "$mode" = hang ] && { sleep 5; exit 0; }
                hex=$(printf '%s\\n' "$input" | sed -n 's/.* -X \\([0-9a-f]*\\) .*/\\1/p')
                [ -f "$D/corrupt-add" ] && hex=00
                printf '%s' "$hex" | xxd -r -p > "$D/stored"
                exit 0 ;;
              delete-generic-password)
                [ -f "$D/stored" ] || exit 44
                rm -f "$D/stored"; exit 0 ;;
              find-generic-password)
                case "$mode" in
                  found) printf '%s\\n' '\(secret)'; exit 0 ;;
                  missing) exit 44 ;;
                  error) exit 51 ;;
                  hang) sleep 5; exit 0 ;;
                esac
                [ -f "$D/stored" ] || exit 44
                cat "$D/stored"; printf '\\n'; exit 0 ;;
            esac
            exit 0
            """
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try body.write(toFile: stub, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub)
            try mode.write(toFile: "\(dir)/mode", atomically: true, encoding: .utf8)
        } catch { return nil }
        return stub
    }

    // MARK: - AC-L4-6 — keychain remote: created through `security -i` with -T /usr/bin/security only, secret nowhere else

    /// Fake-driven (see `makeSecurityStub`): what is asserted is the exact
    /// command limpet hands to `security`, not the keychain's reaction to it.
    /// That the resulting item's ACL lists only /usr/bin/security, and that a
    /// launchd-started read raises no dialog, is verified live by the verifier.
    private static func testKeychainRemoteCreatedThroughSecurityOnly() -> Bool {
        let id = "AC-L4-6", slug = "keychain-remote-created-through-security-only"
        let fm = FileManager.default
        let dir = "\(selfTestRoot)/ac-l4-6"
        try? fm.removeItem(atPath: dir)
        let secret = "SEKRET-l4-6 \"q'$x"
        guard let stub = makeSecurityStub(in: dir, secret: "unused", mode: "store") else {
            return report(id, slug, false, "(fixture setup failed)")
        }
        let keychainPath = "\(dir)/fake.keychain-db"   // only ever passed to the fake
        let confPath = "\(dir)/rclone.conf"
        let existingSection = "[existing]\ntype = local\n"
        let rcloneStub = "\(dir)/rclone-stub"
        do {
            try existingSection.write(toFile: confPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: confPath)
            try "#!/bin/sh\nexit 0\n".write(toFile: rcloneStub, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rcloneStub)
        } catch {
            return report(id, slug, false, "(fixture setup failed: \(error))")
        }
        let store = KeychainSecretStore(securityPath: stub, keychainPath: keychainPath, lockStatus: { _ in .unlocked })
        let service = RcloneConfigService(configPath: confPath, rclonePath: rcloneStub, keychain: store)
        do {
            try service.addKeychainRemote(
                name: "limpet_test_st", type: "s3",
                values: ["provider": "Mega", "access_key_id": "AKIDSELFTEST",
                         "endpoint": "s3.ap-tokyo-1.megas4.com", "region": "ap-tokyo-1"],
                secret: secret)
        } catch {
            return report(id, slug, false, "(addKeychainRemote threw: \(error))")
        }

        // rclone.conf: the non-secret section + marker, appended; nothing else changed.
        let conf = (try? String(contentsOfFile: confPath, encoding: .utf8)) ?? ""
        let expected = existingSection + "\n[limpet_test_st]\ntype = s3\naccess_key_id = AKIDSELFTEST\n"
            + "endpoint = s3.ap-tokyo-1.megas4.com\nprovider = Mega\nregion = ap-tokyo-1\nlimpet_keychain = true\n"
        guard conf == expected else {
            return report(id, slug, false, "(unexpected rclone.conf: \(conf.replacingOccurrences(of: secret, with: "<SECRET>").debugDescription))")
        }
        let perms = (try? fm.attributesOfItem(atPath: confPath)[.posixPermissions] as? NSNumber)?.intValue
        guard perms == 0o600 else {
            return report(id, slug, false, "(rclone.conf permissions changed to \(String(describing: perms)))")
        }

        // The command handed to security: -T /usr/bin/security, never -A, the
        // secret only hex-encoded on stdin, never in any argv.
        let hex = secret.utf8.map { String(format: "%02x", $0) }.joined()
        let addStdin = (try? String(contentsOfFile: "\(dir)/add-stdin", encoding: .utf8)) ?? ""
        let calls = (try? String(contentsOfFile: "\(dir)/calls", encoding: .utf8)) ?? ""
        guard addStdin == "add-generic-password -s limpet -a limpet_test_st -T /usr/bin/security "
                + "-X \(hex) \"\(keychainPath)\"\n",
              calls.components(separatedBy: "\n").contains("-i"),
              !calls.contains(secret), !calls.contains(hex), !calls.contains(" -A") else {
            return report(id, slug, false, "(unexpected security interaction: calls=\(calls.debugDescription))")
        }
        guard store.read(account: "limpet_test_st") == .found(secret) else {
            return report(id, slug, false, "(fake keychain read-back did not return the secret)")
        }

        // F3: the helper maps it to the s3 variable.
        guard service.secretEnvironment(forRemote: "limpet_test_st:bucket/path", log: { _ in })
                == ["RCLONE_CONFIG_LIMPET_TEST_ST_SECRET_ACCESS_KEY": secret] else {
            return report(id, slug, false, "(helper did not return the s3 secret variable)")
        }

        // F5: the secret is in no profile JSON and no script; the script never touches the keychain.
        var profile = sampleProfile()
        profile.rcloneRemote = "limpet_test_st:"
        let profileJSON = (try? JSONEncoder().encode(profile)).map { String(decoding: $0, as: UTF8.self) } ?? secret
        let script = SyncSetupService.shared.generateSyncScript()
        guard !profileJSON.contains(secret), !script.contains(secret),
              !script.contains("security"), !script.lowercased().contains("keychain"),
              !script.contains("eval") else {
            return report(id, slug, false, "(secret, keychain access or eval found in profile JSON / script)")
        }

        // F7: deleting the remote deletes its keychain item.
        do { try service.deleteRemote("limpet_test_st") } catch {
            return report(id, slug, false, "(deleteRemote threw: \(error))")
        }
        guard store.read(account: "limpet_test_st") == .notFound else {
            return report(id, slug, false, "(keychain item survived deleteRemote)")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L4-7 — keychain remote refusals: nothing written, no keychain item

    private static func testKeychainRemoteRefusals() -> Bool {
        let id = "AC-L4-7", slug = "keychain-remote-refusals"
        let dir = "\(selfTestRoot)/ac-l4-7"
        try? FileManager.default.removeItem(atPath: dir)
        guard let stub = makeSecurityStub(in: dir, secret: "unused") else {
            return report(id, slug, false, "(fixture setup failed)")
        }
        let confPath = "\(dir)/rclone.conf"
        let original = "[Limpet_Taken]\ntype = local\n"
        try? original.write(toFile: confPath, atomically: true, encoding: .utf8)
        let service = RcloneConfigService(
            configPath: confPath, rclonePath: "/usr/bin/false",
            keychain: KeychainSecretStore(securityPath: stub, keychainPath: "\(dir)/unused.keychain-db", lockStatus: { _ in .unlocked }))
        let good: [String: String] = ["provider": "Mega", "access_key_id": "AKID"]
        let refused: [(String, String, [String: String], String)] = [
            ("bad-name", "s3", good, "s"),                                          // name charset
            ("limpet_taken", "s3", good, "s"),                                      // case-insensitive collision
            ("ok_name", "webdav", [:], "s"),                                        // type
            ("ok_name", "s3", good.merging(["no_check_certificate": "true"]) { $1 }, "s"),  // F7
            ("ok_name", "s3", good.merging(["secret_access_key": "x"]) { $1 }, "s"),        // secret in conf
            ("ok_name", "s3", good.merging(["endpoint": "http://s3.example.com"]) { $1 }, "s"),  // F7 https
            ("ok_name", "s3", good.merging(["region": "x\ntype = local"]) { $1 }, "s"),       // F4 newline
            ("ok_name", "s3", good, ""),                                            // empty secret
            ("ok_name", "s3", good, "two\nlines"),
        ]
        for (name, type, values, secret) in refused {
            if (try? service.addKeychainRemote(name: name, type: type, values: values, secret: secret)) != nil {
                return report(id, slug, false, "(accepted name=\(name) type=\(type) values=\(values.keys.sorted()))")
            }
        }
        let conf = (try? String(contentsOfFile: confPath, encoding: .utf8)) ?? ""
        guard conf == original, !FileManager.default.fileExists(atPath: "\(dir)/argv") else {
            return report(id, slug, false, "(a refused remote still wrote rclone.conf or ran security)")
        }

        // The existing (non-keychain) addRemote path refuses line breaks too (F4).
        var webdav = RemoteConfiguration(name: "plain_webdav", provider: .webdav)
        webdav.values["url"] = "https://dav.example.com"
        webdav.values["user"] = "me\n[injected]\ntype = local"
        if (try? service.addRemote(webdav)) != nil ||
            (try? String(contentsOfFile: confPath, encoding: .utf8)) != original {
            return report(id, slug, false, "(addRemote wrote a value containing a line break)")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L4-8 — the secret-injection helper (F3)

    private static func testSecretInjectionHelper() -> Bool {
        let id = "AC-L4-8", slug = "secret-injection-helper"
        let dir = "\(selfTestRoot)/ac-l4-8"
        try? FileManager.default.removeItem(atPath: dir)
        let secret = "SEKRET-stub-9c1"
        guard let stub = makeSecurityStub(in: dir, secret: secret) else {
            return report(id, slug, false, "(fixture setup failed)")
        }
        let confPath = "\(dir)/rclone.conf"
        try? """
            [plain]
            type = local

            [ks3]
            type = s3
            provider = Mega
            limpet_keychain = true

            [kb2]
            type = b2
            account = KEYID
            limpet_keychain = true
            """.write(toFile: confPath, atomically: true, encoding: .utf8)
        let keychainPath = "\(dir)/k.keychain-db"
        let service = RcloneConfigService(
            configPath: confPath, rclonePath: "/usr/bin/false",
            keychain: KeychainSecretStore(securityPath: stub, keychainPath: keychainPath, timeout: 0.5, lockStatus: { _ in .unlocked }))
        func setMode(_ mode: String) { try? mode.write(toFile: "\(dir)/mode", atomically: true, encoding: .utf8) }

        // Non-keychain remote: empty env, security never runs.
        var logs: [String] = []
        guard service.secretEnvironment(forRemote: "plain:x", log: { logs.append($0) }) == [:], logs.isEmpty,
              !FileManager.default.fileExists(atPath: "\(dir)/argv") else {
            return report(id, slug, false, "(non-keychain remote did not get an empty env without a keychain read)")
        }
        // Found: s3 and b2 variable names, read through find-generic-password -w on the given keychain.
        guard service.secretEnvironment(forRemote: "ks3:", log: { logs.append($0) })
                == ["RCLONE_CONFIG_KS3_SECRET_ACCESS_KEY": secret],
              service.secretEnvironment(forRemote: "kb2", log: { logs.append($0) }) == ["RCLONE_CONFIG_KB2_KEY": secret],
              logs.isEmpty else {
            return report(id, slug, false, "(s3/b2 variable names wrong, or a log line on success)")
        }
        let argv = (try? String(contentsOfFile: "\(dir)/argv", encoding: .utf8)) ?? ""
        guard argv == ["find-generic-password", "-s", "limpet", "-a", "kb2", "-w", keychainPath].joined(separator: "\n") + "\n" else {
            return report(id, slug, false, "(unexpected security argv: \(argv.debugDescription))")
        }
        // Failures: exactly one line each, no env, and the watcher spawns nothing.
        for (mode, phrase) in [("missing", "not found"), ("error", "read failed"), ("hang", "timed out")] {
            setMode(mode)
            var lines: [String] = []
            var spawned = 0
            let code = SyncWatchDaemon.runSyncChild(
                profile: SyncProfile(name: "p", rcloneRemote: "ks3:", remotePath: "b", localSyncPath: "/tmp/x"),
                service: service, log: { lines.append($0) }, spawn: { _ in spawned += 1; return 0 })
            guard code == SyncWatchDaemon.secretUnavailableExitCode, spawned == 0,
                  lines.count == 1, lines[0].contains(phrase), !lines[0].contains(secret) else {
                return report(id, slug, false, "(\(mode): code=\(code) spawned=\(spawned) lines=\(lines))")
            }
        }
        // And on success the watcher's child gets the variable merged into its environment.
        setMode("found")
        var childEnvironment: [String: String] = [:]
        _ = SyncWatchDaemon.runSyncChild(
            profile: SyncProfile(name: "p", rcloneRemote: "kb2:", remotePath: "b", localSyncPath: "/tmp/x"),
            service: service, log: { _ in }, spawn: { childEnvironment = $0; return 0 })
        guard childEnvironment["RCLONE_CONFIG_KB2_KEY"] == secret, childEnvironment["PATH"] != nil else {
            return report(id, slug, false, "(watcher child environment missing the secret or the inherited environment)")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L4-9 — limpet remote add: secret from stdin only, same creation function

    private static func testCLIRemoteAdd() -> Bool {
        let id = "AC-L4-9", slug = "cli-remote-add"
        let argv = ["remote", "add", "limpet_test_s4", "--type", "s3", "--provider", "Mega",
                    "--region", "ap-tokyo-1", "--access-key-id", "AKID"]
        guard case .success(.remoteAdd(let request)) = LimpetCLI.parse(argv),
              request == RemoteAddRequest(name: "limpet_test_s4", type: "s3", values: [
                "access_key_id": "AKID", "provider": "Mega", "region": "ap-tokyo-1"]) else {
            return report(id, slug, false, "(remote add did not parse as expected)")
        }
        // Internal review F9: a known provider in another case is written canonically.
        var lower = argv
        lower[lower.firstIndex(of: "Mega")!] = "mega"
        guard case .success(.remoteAdd(let lowered)) = LimpetCLI.parse(lower), lowered == request,
              case .success(.remoteAdd(let unknown)) = LimpetCLI.parse(
                ["remote", "add", "n", "--type", "s3", "--provider", "Wasabi", "--access-key-id", "k"]),
              unknown.values["provider"] == "Wasabi" else {
            return report(id, slug, false, "(--provider mega not normalized to Mega, or an unknown provider changed)")
        }
        for bad in [argv + ["--secret", "x"], argv + ["--secret-access-key=x"], ["remote", "add", "n", "--type", "s3"],
                    ["remote", "add", "n", "--type", "b2", "--access-key-id", "k", "--endpoint", "e"]] {
            guard case .failure = LimpetCLI.parse(bad) else {
                return report(id, slug, false, "(accepted \(bad))")
            }
        }
        let secret = "SEKRET-cli-5d2"
        var output = "", created: (String, String, [String: String], String)?
        let env = fakeCLIEnvironment(
            readSecret: { _ in secret },
            addKeychainRemote: { created = ($0, $1, $2, $3); return nil },
            stdout: { output += $0 }, stderr: { output += $0 })
        guard LimpetCLI.execute(argv, env: env) == 0, created?.0 == "limpet_test_s4", created?.1 == "s3",
              created?.2 == request.values, created?.3 == secret, !output.contains(secret) else {
            return report(id, slug, false, "(remote add did not hand the stdin secret to the creation function)")
        }
        var calledWithoutSecret = false
        let noSecretEnv = fakeCLIEnvironment(readSecret: { _ in nil },
                                             addKeychainRemote: { _, _, _, _ in calledWithoutSecret = true; return nil })
        guard LimpetCLI.execute(argv, env: noSecretEnv) == 66, !calledWithoutSecret else {
            return report(id, slug, false, "(remote add without a secret did not stop before creating)")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L4-10 — s3/b2 providers: read back as themselves, wizard routes to the keychain path

    private static func testWizardProvidersRemapAndRoute() -> Bool {
        let id = "AC-L4-10", slug = "s3-b2-remap-and-wizard-route"
        let dir = "\(selfTestRoot)/ac-l4-10"
        try? FileManager.default.removeItem(atPath: dir)
        guard let stub = makeSecurityStub(in: dir, secret: "unused", mode: "store") else {
            return report(id, slug, false, "(fixture setup failed)")
        }
        let confPath = "\(dir)/rclone.conf"
        let original = "[s4]\ntype = s3\naccess_key_id = AKID\nprovider = Mega\nlimpet_keychain = true\n\n"
            + "[bb]\ntype = b2\naccount = KEYID\nlimpet_keychain = true\n"
        let rcloneStub = "\(dir)/rclone-stub"
        try? original.write(toFile: confPath, atomically: true, encoding: .utf8)
        try? "#!/bin/sh\ntouch \"\(dir)/rclone-ran\"\nexit 0\n".write(toFile: rcloneStub, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rcloneStub)
        let service = RcloneConfigService(
            configPath: confPath, rclonePath: rcloneStub,
            keychain: KeychainSecretStore(securityPath: stub, keychainPath: "\(dir)/k.keychain-db", lockStatus: { _ in .unlocked }))

        // F5 remap: an existing s3/b2 remote edits as itself, never as webdav.
        guard let s4 = service.readRemoteConfig(name: "s4"), s4.provider == .s3Compatible,
              s4.generateConfigSection().contains("type = s3"),
              let bb = service.readRemoteConfig(name: "bb"), bb.provider == .b2,
              bb.generateConfigSection().contains("type = b2") else {
            return report(id, slug, false, "(s3/b2 section was not read back as s3/b2)")
        }

        // Editing without re-entering the secret rewrites the section in place
        // (here: to identical text), never runs rclone and never touches the keychain.
        if (try? service.updateRemote(s4)) == nil ||
            (try? String(contentsOfFile: confPath, encoding: .utf8)) != original ||
            FileManager.default.fileExists(atPath: "\(dir)/rclone-ran") ||
            FileManager.default.fileExists(atPath: "\(dir)/calls") {
            return report(id, slug, false, "(an edit without a secret did not stay in place and off the keychain)")
        }

        // The wizard's addRemote takes the keychain path: secret out of rclone.conf,
        // marker in, and the secret reaches security on stdin (hex), never in argv.
        let secret = "SEKRET-wizard-41e"
        var config = RemoteConfiguration(name: "wizard_s4", provider: .s3Compatible)
        config.values["access_key_id"] = "AKIDW"
        config.values["endpoint"] = "https://s3.ap-tokyo-1.megas4.com"
        config.values["secret_access_key"] = secret
        do { try service.addRemote(config) } catch {
            return report(id, slug, false, "(wizard addRemote threw: \(error))")
        }
        let conf = (try? String(contentsOfFile: confPath, encoding: .utf8)) ?? ""
        let hex = secret.utf8.map { String(format: "%02x", $0) }.joined()
        let calls = (try? String(contentsOfFile: "\(dir)/calls", encoding: .utf8)) ?? ""
        let argv = calls.components(separatedBy: "\n").contains("-i") && !calls.contains(secret) ? "-i\n" : calls
        let stdin = (try? String(contentsOfFile: "\(dir)/add-stdin", encoding: .utf8)) ?? ""
        guard conf.hasPrefix(original), !conf.contains(secret),
              conf.hasSuffix("[wizard_s4]\ntype = s3\naccess_key_id = AKIDW\nendpoint = https://s3.ap-tokyo-1.megas4.com\n"
                  + "provider = Mega\nlimpet_keychain = true\n"),
              argv == "-i\n", !argv.contains(secret), !argv.contains(hex),
              stdin.hasPrefix("add-generic-password -s limpet -a wizard_s4 -T /usr/bin/security -X \(hex) "),
              !stdin.contains(secret) else {
            return report(id, slug, false, "(wizard route: conf=\(conf.replacingOccurrences(of: secret, with: "<SECRET>").debugDescription) argv=\(argv.debugDescription))")
        }
        var badName = RemoteConfiguration(name: "bad-name", provider: .b2)
        badName.values["account"] = "k"
        badName.values["key"] = "s"
        guard badName.validate().contains(where: { $0.contains("letters, digits") }) else {
            return report(id, slug, false, "(wizard validate accepted a keychain name with '-')")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L4-11 — exit 76 only when rclone's exit code AND its max-delete message match

    private static func testScriptMapsMaxDeleteTo76() -> Bool {
        let id = "AC-L4-11", slug = "script-maps-max-delete-to-76"
        // The exact line rclone 1.75.1 logged per refused delete (measured 2026-09-26).
        let tripped = "echo '{\"level\":\"error\",\"msg\":\"Got fatal error on delete: --max-delete threshold reached\",\"object\":\"f3.txt\"}' >&2\n"
        let otherFatal = "echo '{\"level\":\"error\",\"msg\":\"Fatal error received - not attempting retries\"}' >&2\n"
        let cases: [(String, String, Int32)] = [
            ("ac-l4-11-a", tripped + "exit 7\n", 76),     // code + message → 76
            ("ac-l4-11-b", otherFatal + "exit 7\n", 7),   // same code, no message → 7
            ("ac-l4-11-c", tripped + "exit 1\n", 1),      // message, other code → 1
        ]
        for (name, tail, expected) in cases {
            guard let result = runScriptFixture(name: name, overrides: ["maxDelete": 5], stubTail: tail) else {
                return report(id, slug, false, "(fixture setup failed)")
            }
            guard result.status == expected,
                  result.log.contains("Delete limit reached") == (expected == 76) else {
                return report(id, slug, false, "(\(name): status \(result.status), expected \(expected))")
            }
        }
        // --max-delete N reaches rclone when set, and is absent at 0.
        guard let on = runScriptFixture(name: "ac-l4-11-on", overrides: ["maxDelete": 5]),
              let off = runScriptFixture(name: "ac-l4-11-off", overrides: ["maxDelete": 0]),
              let bad = runScriptFixture(name: "ac-l4-11-bad", overrides: ["maxDelete": "5 --dry-run"]) else {
            return report(id, slug, false, "(fixture setup failed)")
        }
        guard let flag = on.argv.firstIndex(of: "--max-delete"), on.argv.indices.contains(flag + 1),
              on.argv[flag + 1] == "5", !off.argv.contains("--max-delete") else {
            return report(id, slug, false, "(--max-delete argv wrong: on=\(on.argv) off=\(off.argv))")
        }
        guard bad.status == 64, !bad.stubRan else {
            return report(id, slug, false, "(a non-numeric maxDelete was not refused: \(bad.status))")
        }
        // Review finding 10: a large run keeps only the matching lines on disk.
        // The stub prints ~1 MB, then the tripped line, then measures the
        // script's temp file(s) while the script is still running.
        let tmp = "\(selfTestRoot)/ac-l4-11-tmp"
        try? FileManager.default.removeItem(atPath: tmp)
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let sizeFile = "\(selfTestRoot)/ac-l4-11-tmp-size"
        let large = "i=0; while [ $i -lt 20000 ]; do echo '{\"level\":\"info\",\"msg\":\"Copied (new)\",\"object\":\"some/long/path/file-'$i'.dat\"}'; i=$((i+1)); done\n"
            + tripped + "sleep 1\ncat \"\(tmp)\"/limpet-run.* | wc -c > \"\(sizeFile)\"\nexit 7\n"
        guard let big = runScriptFixture(name: "ac-l4-11-large", overrides: ["maxDelete": 5], stubTail: large,
                                         extraEnvironment: ["TMPDIR": tmp]),
              let size = Int(((try? String(contentsOfFile: sizeFile, encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return report(id, slug, false, "(large-output fixture failed)")
        }
        guard big.status == 76, size < 4096 else {
            return report(id, slug, false, "(large output: status \(big.status), temp file \(size) bytes)")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L4-12 — --max-delete only where a delete cannot be undone

    private static func testMaxDeleteOnlyForNonVersionedProviders() -> Bool {
        let id = "AC-L4-12", slug = "max-delete-only-non-versioned"
        var profile = sampleProfile()
        profile.maxDelete = 42
        var versioned = profile
        versioned.remoteVersioning = true
        let matrix: [([String: String]?, SyncProfile, Int)] = [
            (["type": "s3", "provider": "Mega"], profile, 42),
            (["type": "s3", "provider": "Mega"], versioned, 42),        // S4 has no versioning
            (["type": "s3", "provider": "mega"], versioned, 42),        // in any case (internal review F9)
            (["type": "s3", "provider": "CLOUDFLARE"], versioned, 42),
            (["type": "s3", "provider": "Cloudflare"], versioned, 42),  // nor has R2
            (["type": "s3", "provider": "AWS"], profile, 42),
            (["type": "s3", "provider": "AWS"], versioned, 0),
            (["type": "s3", "provider": "Minio"], versioned, 0),
            (["type": "s3", "provider": "Other"], profile, 42),
            (["type": "b2"], profile, 0),
            (["type": "webdav"], profile, 0),
            (nil, profile, 0),
        ]
        for (section, candidate, expected) in matrix
        where SyncSetupService.maxDeleteArgument(for: candidate, remoteSection: section) != expected {
            return report(id, slug, false, "(\(String(describing: section)) versioning=\(candidate.remoteVersioning) expected \(expected))")
        }
        // A hand-edited `provider = mega` still gets the derived MEGA S4 endpoint.
        guard RcloneConfigService.withDerivedEndpoint(
                type: "s3", values: ["provider": "mega", "region": "ap-tokyo-1"])["endpoint"] == "s3.ap-tokyo-1.megas4.com" else {
            return report(id, slug, false, "(provider = mega got no derived endpoint)")
        }
        // Wired into the derived config from the remote's rclone.conf section.
        let confPath = "\(selfTestRoot)/ac-l4-12-rclone.conf"
        try? "[s4]\ntype = s3\nprovider = Mega\n\n[bb]\ntype = b2\n".write(toFile: confPath, atomically: true, encoding: .utf8)
        let service = RcloneConfigService(configPath: confPath)
        func derivedMaxDelete(_ remote: String) -> Int? {
            var p = profile
            p.rcloneRemote = remote
            let json = SyncSetupService.shared.generateProfileConfig(for: p, rcloneConfig: service)
            let dict = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
            return dict?["maxDelete"] as? Int
        }
        guard derivedMaxDelete("s4:") == 42, derivedMaxDelete("bb:") == 0, derivedMaxDelete("absent:") == 0 else {
            return report(id, slug, false, "(derived maxDelete wrong)")
        }
        // maxDelete is at least 1 at decode, write and profile set.
        var zero = profile
        zero.maxDelete = 0
        guard zero.validationError != nil,
              LimpetCLI.applyProfileAssignment(&zero, key: "maxDelete", value: "0") != nil,
              LimpetCLI.applyProfileAssignment(&zero, key: "maxDelete", value: "250") == nil, zero.maxDelete == 250,
              LimpetCLI.applyProfileAssignment(&zero, key: "remoteVersioning", value: "true") == nil, zero.remoteVersioning,
              SyncManager.reconcileAction(from: profile, to: versioned) == .reinstall else {
            return report(id, slug, false, "(maxDelete/remoteVersioning validation or reconcile wrong)")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L4-13 — the watcher stops for good at the delete limit

    private static func testWatcherStopsAtDeleteLimit() -> Bool {
        let id = "AC-L4-13", slug = "watcher-stops-at-delete-limit"
        func scheduler(marker: @escaping () -> Bool, record: @escaping () -> Bool,
                       clock: VirtualClock, runs: @escaping () -> Void) -> SyncWatchScheduler {
            SyncWatchScheduler(runner: SchedulerRunner(
                sourceExists: { true },
                runChild: { _, completion in runs(); completion(SyncWatchScheduler.deleteLimitExitCode) },
                now: { clock.now },
                scheduleAfter: { s, a in clock.scheduleAfter(s, a) },
                logSourceMissing: {},
                refusalReason: { nil },
                logRefusal: { _ in },
                deleteLimitReached: marker,
                recordDeleteLimit: record))
        }
        // A run exits 76 → marker written → no further run for any number of triggers.
        let clock = VirtualClock()
        var marker = false, runs = 0
        let first = scheduler(marker: { marker }, record: { marker = true; return true }, clock: clock, runs: { runs += 1 })
        first.trigger()
        for _ in 0..<20 { first.trigger() }
        clock.advance(by: 3600)
        first.trigger()
        guard runs == 1, marker, first.state == .idle else {
            return report(id, slug, false, "(after a 76: runs=\(runs) marker=\(marker))")
        }
        // A new scheduler (a respawned watcher) with the marker present runs 0 times.
        var respawnRuns = 0
        let respawned = scheduler(marker: { marker }, record: { true }, clock: clock, runs: { respawnRuns += 1 })
        for _ in 0..<5 { respawned.trigger() }
        guard respawnRuns == 0 else {
            return report(id, slug, false, "(respawned watcher ran \(respawnRuns) time(s) with the marker present)")
        }
        // Cleared (marker removed) + "sync now" → it runs again.
        marker = false
        respawned.trigger()
        guard respawnRuns == 1 else {
            return report(id, slug, false, "(did not run after the marker was cleared)")
        }
        // The marker cannot be written → still stopped for the life of the process.
        var unwrittenRuns = 0
        let unwritten = scheduler(marker: { false }, record: { false }, clock: clock, runs: { unwrittenRuns += 1 })
        for _ in 0..<5 { unwritten.trigger() }
        guard unwrittenRuns == 1 else {
            return report(id, slug, false, "(ran \(unwrittenRuns) time(s) after a 76 whose marker could not be written)")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L71-1 — watcher self-restart decision (limpet-plan.md L7 S3, finding 12)

    private static func testWatcherSelfRestartDecision() -> Bool {
        let id = "AC-L71-1", slug = "watcher-self-restart-decision"
        typealias D = SyncWatchDaemon
        guard D.restartDecision(startVersion: "5", onDiskVersion: "5", busy: false) == .spawn,
              D.restartDecision(startVersion: "5", onDiskVersion: "6", busy: false) == .exit,
              D.restartDecision(startVersion: "5", onDiskVersion: nil, busy: false) == .spawn,
              D.restartDecision(startVersion: nil, onDiskVersion: "6", busy: false) == .spawn,
              D.restartDecision(startVersion: "5", onDiskVersion: "6", busy: true) == .spawn,  // lingering stalled group
              D.restartDecision(startVersion: "5", onDiskVersion: "05", busy: false) == .exit else {
            return report(id, slug, false, "(pure decision table wrong)")
        }
        // Fresh read from disk: a fake `.app/Contents/{MacOS,Info.plist}` rewritten between reads.
        let contents = "\(selfTestRoot)/restart-fake.app/Contents"
        let exe = "\(contents)/MacOS/limpet"
        try? FileManager.default.createDirectory(atPath: "\(contents)/MacOS", withIntermediateDirectories: true)
        func writePlist(_ v: String) {
            (["CFBundleVersion": v] as NSDictionary).write(toFile: "\(contents)/Info.plist", atomically: true)
        }
        guard D.bundleVersionOnDisk(executablePath: exe) == nil else {
            return report(id, slug, false, "(missing plist did not read as nil)")
        }
        writePlist("7")
        let first = D.bundleVersionOnDisk(executablePath: exe)
        writePlist("8")
        guard first == "7", D.bundleVersionOnDisk(executablePath: exe) == "8" else {
            return report(id, slug, false, "(version not re-read from disk: \(String(describing: first)))")
        }
        // Through the scheduler: differs + idle -> restart hook, no spawn; same -> spawn.
        func drive(disk: String?, deleteLimit: Bool = false) -> (runs: Int, restarts: Int) {
            var runs = 0, restarts = 0
            let clock = VirtualClock()
            let sch = SyncWatchScheduler(runner: SchedulerRunner(
                sourceExists: { true },
                runChild: { _, completion in runs += 1; completion(0) },
                now: { clock.now },
                scheduleAfter: { s, a in clock.scheduleAfter(s, a) },
                logSourceMissing: {},
                refusalReason: { nil },
                logRefusal: { _ in },
                deleteLimitReached: { deleteLimit },
                recordDeleteLimit: { true },
                restartForUpdate: {
                    guard D.restartDecision(startVersion: "7", onDiskVersion: disk, busy: false) == .exit else { return false }
                    restarts += 1
                    return true
                }))
            sch.trigger()
            return (runs, restarts)
        }
        let same = drive(disk: "7"), diff = drive(disk: "8"), missing = drive(disk: nil)
        let gated = drive(disk: "8", deleteLimit: true)  // restart wins over the delete-limit gate
        guard same == (1, 0), diff == (0, 1), missing == (1, 0), gated == (0, 1) else {
            return report(id, slug, false, "(scheduler wiring: same=\(same) diff=\(diff) missing=\(missing) gated=\(gated))")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L71-2 — watcher start replaces a stale limpet-sync.sh before the first run

    private static func testWatcherStartupRefreshesStaleScript() -> Bool {
        let id = "AC-L71-2", slug = "watcher-start-refreshes-stale-script"
        let fm = FileManager.default
        let path = SyncProfile.sharedScriptPath
        guard path.hasPrefix(LimpetPaths.home) else {
            return report(id, slug, false, "(script path \(path) is outside the isolated home)")
        }
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? "#!/bin/bash\n# stale template\n".write(toFile: path, atomically: true, encoding: .utf8)
        let current = SyncSetupService.shared.generateSyncScript()
        var seenAtFirstRun: String?
        var runs = 0
        let clock = VirtualClock()
        let sch = SyncWatchScheduler(runner: SchedulerRunner(
            sourceExists: { true },
            runChild: { _, completion in
                runs += 1
                if seenAtFirstRun == nil { seenAtFirstRun = try? String(contentsOfFile: path, encoding: .utf8) }
                completion(0)
            },
            now: { clock.now },
            scheduleAfter: { s, a in clock.scheduleAfter(s, a) },
            logSourceMissing: {},
            refusalReason: { nil },
            logRefusal: { _ in },
            deleteLimitReached: { false },
            recordDeleteLimit: { true }))
        SyncWatchDaemon.startUp(scheduler: sch, refreshScript: { SyncSetupService.shared.refreshSharedScriptIfChanged() })
        guard runs == 1, seenAtFirstRun == current else {
            return report(id, slug, false, "(runs=\(runs); script at first run \(seenAtFirstRun == current ? "current" : "STALE"))")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L4-14 — limpet profile clear-delete-limit

    private static func testCLIClearDeleteLimit() -> Bool {
        let id = "AC-L4-14", slug = "cli-clear-delete-limit"
        let profile = sampleProfile()
        guard case .success(.profileClearDeleteLimit(profile.shortId)) =
                LimpetCLI.parse(["profile", "clear-delete-limit", profile.shortId]) else {
            return report(id, slug, false, "(did not parse)")
        }
        var removed: [String] = [], killed: [[String]] = []
        func env(markerExists: Bool, removeSucceeds: Bool) -> CLIEnvironment {
            fakeCLIEnvironment(
                readProfiles: { [profile] },
                fileExists: { $0 == profile.deleteLimitMarkerPath && markerExists },
                runLaunchctl: { killed.append($0); return (0, "") },
                removeFile: { removed.append($0); return removeSucceeds })
        }
        guard LimpetCLI.execute(["profile", "clear-delete-limit", profile.shortId], env: env(markerExists: true, removeSucceeds: true)) == 0,
              removed == [profile.deleteLimitMarkerPath],
              killed == [["kill", "SIGUSR1", "gui/\(getuid())/\(profile.launchdLabel)"]] else {
            return report(id, slug, false, "(clear did not remove the marker and signal the watcher: \(removed) \(killed))")
        }
        removed = []; killed = []
        guard LimpetCLI.execute(["profile", "clear-delete-limit", profile.shortId], env: env(markerExists: true, removeSucceeds: false)) == 1,
              killed.isEmpty else {
            return report(id, slug, false, "(a failed removal still signalled the watcher)")
        }
        removed = []; killed = []
        guard LimpetCLI.execute(["profile", "clear-delete-limit", profile.shortId], env: env(markerExists: false, removeSucceeds: true)) == 0,
              removed.isEmpty, killed.isEmpty else {
            return report(id, slug, false, "(no marker: something was removed or signalled)")
        }
        guard profile.deleteLimitMarkerPath == "\(SyncProfile.configDirectory)/\(profile.shortId).delete-limit" else {
            return report(id, slug, false, "(unexpected marker path \(profile.deleteLimitMarkerPath))")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L4-15 — doctor warns (never fails) on a B2 bucket without daysFromHidingToDeleting

    private static func testDoctorWarnsB2WithoutLifecycle() -> Bool {
        let id = "AC-L4-15", slug = "doctor-warns-b2-without-lifecycle"
        var profile = sampleProfile(isEnabled: false)
        profile.rcloneRemote = "bb:"
        profile.remotePath = "bucket/sub"
        func checks(lifecycleOutput: String) -> ([DoctorCheck], [[String]]) {
            var calls: [[String]] = []
            let env = fakeCLIEnvironment(
                runRclone: { args, _, _ in
                    calls.append(args)
                    if args.first == "version" { return (0, "rclone v1.75.1", "") }
                    return args.first == "backend" ? (0, lifecycleOutput, "") : (0, "", "")
                },
                readProfiles: { [profile] },
                fileExists: { $0 == profile.configPath },
                remoteSection: { $0 == "bb" ? ["type": "b2"] : nil })
            return (LimpetCLI.doctorChecks(env: env), calls)
        }
        let (noRule, calls) = checks(lifecycleOutput: "[]\n")
        guard calls.contains(["backend", "lifecycle", "bb:bucket"]),
              noRule.contains(where: { $0.status == .warn && $0.detail.contains("daysFromHidingToDeleting") }),
              !noRule.contains(where: { $0.status == .fail }) else {
            return report(id, slug, false, "(no warning for a bucket without a rule: \(noRule.map(\.line)))")
        }
        let (withRule, _) = checks(lifecycleOutput: "[\n    {\n        \"daysFromHidingToDeleting\": 1,\n        \"fileNamePrefix\": \"\"\n    }\n]\n")
        guard !withRule.contains(where: { $0.detail.contains("daysFromHidingToDeleting") }) else {
            return report(id, slug, false, "(warned although the rule exists)")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L4-16 — transfers 1–64, no leading zero (carried from L4.0)

    /// The companion carried item, RCLONE_BIN honoured only in Debug builds, has
    /// no test here: the self-test itself only runs in Debug, and running the
    /// Release script variant far enough to see which rclone it picks would run
    /// the real rclone installed on the machine against the real rclone.conf.
    private static func testTransfersRange() -> Bool {
        let id = "AC-L4-16", slug = "transfers-range"
        func decodes(_ transfers: Any) -> Bool {
            let dict: [String: Any] = ["id": UUID().uuidString, "name": "t", "rcloneRemote": "r:",
                                       "remotePath": "p", "localSyncPath": "/tmp/x", "transfers": transfers]
            guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return false }
            return (try? JSONDecoder().decode(SyncProfile.self, from: data)) != nil
        }
        guard decodes(1), decodes(64), !decodes(0), !decodes(65), !decodes(-3) else {
            return report(id, slug, false, "(decode range wrong)")
        }
        var profile = sampleProfile()
        for bad in ["08", "0", "65", "+5", "5 ", "\u{0663}", ""] {
            if LimpetCLI.applyProfileAssignment(&profile, key: "transfers", value: bad) == nil {
                return report(id, slug, false, "(profile set accepted transfers \(bad.debugDescription))")
            }
        }
        guard LimpetCLI.applyProfileAssignment(&profile, key: "transfers", value: "64") == nil, profile.transfers == 64 else {
            return report(id, slug, false, "(profile set refused transfers 64)")
        }
        // The Release script variant (no RCLONE_BIN override) must at least be valid bash.
        let releaseScript = "\(selfTestRoot)/ac-l4-16-release.sh"
        try? SyncSetupService.shared.generateSyncScript(honorRcloneBinOverride: false)
            .write(toFile: releaseScript, atomically: true, encoding: .utf8)
        guard runTool("/bin/bash", ["-n", releaseScript]).0 == 0 else {
            return report(id, slug, false, "(the Release script variant is not valid bash)")
        }
        var tooMany = sampleProfile()
        tooMany.transfers = 100
        guard ProfileStore.writeProfileFile(tooMany, in: "\(selfTestRoot)/ac-l4-16") == nil else {
            return report(id, slug, false, "(a transfers value of 100 was written)")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L4-17 — a refused dropped file is moved out of the scanned set

    /// Review finding 3: a dropped profile refused for overlap used to stay in
    /// profiles/, where the running profile's watcher (which re-reads every
    /// file) and the next app launch saw it again.
    private static func testRefusedDropQuarantined() -> Bool {
        let id = "AC-L4-17", slug = "refused-drop-quarantined"
        let dir = "\(selfTestRoot)/ac-l4-17/profiles"
        try? FileManager.default.removeItem(atPath: "\(selfTestRoot)/ac-l4-17")
        let a = sampleProfile(name: "A")
        var b = sampleProfile(name: "B")
        b.remotePath = a.remotePath + "/inside"
        let dropPath = "\(dir)/b-drop.profile.json"
        guard ProfileStore.writeProfileFile(a, in: dir) != nil,
              let bData = try? JSONEncoder().encode(b), (try? bData.write(to: URL(fileURLWithPath: dropPath))) != nil else {
            return report(id, slug, false, "(fixture setup failed)")
        }
        let aInstalled: (SyncProfile) -> Bool = { $0.id == a.id }
        var movedTo: String?
        let outcome = SyncManager.applyExternalCreateIfNeeded(
            decoded: b, isKnownId: false, existing: [a], isInstalled: aInstalled,
            persist: { _ in }, install: { _ in },
            quarantine: { _ in movedTo = SyncManager.quarantineRefusedDrop(at: dropPath) })
        guard outcome == .refusedOverlap, let movedTo,
              FileManager.default.fileExists(atPath: movedTo), !FileManager.default.fileExists(atPath: dropPath),
              movedTo.hasPrefix("\(dir)/refused/b-drop."), !movedTo.hasSuffix(".profile.json") else {
            return report(id, slug, false, "(dropped file not moved aside: \(String(describing: movedTo)))")
        }
        guard ProfileStore.profilesOnDisk(in: dir).map(\.id) == [a.id] else {
            return report(id, slug, false, "(the refused profile is still loaded from profiles/)")
        }
        // A's watcher still runs.
        var runs = 0
        let clock = VirtualClock()
        let scheduler = SyncWatchScheduler(runner: SchedulerRunner(
            sourceExists: { true },
            runChild: { _, completion in runs += 1; completion(0) },
            now: { clock.now },
            scheduleAfter: { s, act in clock.scheduleAfter(s, act) },
            logSourceMissing: {},
            refusalReason: { SyncWatchDaemon.refusalReason(for: a, profilesDirectory: dir, isInstalled: aInstalled) },
            logRefusal: { _ in },
            deleteLimitReached: { false },
            recordDeleteLimit: { true }))
        scheduler.trigger()
        guard runs == 1 else {
            return report(id, slug, false, "(A's watcher did not run after B was refused)")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L4-18 — only enabled (and installed) profiles take part in the overlap rule

    /// Review finding 4: a disabled profile must not block an enabled one, and
    /// enabling an overlapping disabled profile must be refused.
    private static func testOverlapOnlyAmongEnabledInstalled() -> Bool {
        let id = "AC-L4-18", slug = "overlap-only-enabled-installed"
        let running = sampleProfile(name: "Running")                 // enabled, installed
        let disabled = sampleProfile(name: "Disabled", isEnabled: false)
        var fresh = sampleProfile(name: "Fresh")                      // enabled, same path
        fresh.remotePath = running.remotePath
        let installed: (SyncProfile) -> Bool = { $0.id == running.id }

        // Disabled / never-installed profiles do not block.
        guard SyncProfile.overlapError(fresh, among: [disabled], isInstalled: { _ in true }) == nil,
              SyncProfile.overlapError(fresh, among: [running], isInstalled: { _ in false }) == nil,
              SyncProfile.overlapError(disabled, among: [running], isInstalled: installed) == nil else {
            return report(id, slug, false, "(a disabled or not-installed profile took part)")
        }
        var wrote = false
        guard let freshJSON = try? JSONEncoder().encode(fresh) else {
            return report(id, slug, false, "(could not encode fixture)")
        }
        let createEnv = fakeCLIEnvironment(
            readProfiles: { [disabled] }, fileExists: { _ in true },
            writeProfile: { _ in wrote = true; return true },
            readStdin: { String(decoding: freshJSON, as: UTF8.self) })
        guard LimpetCLI.execute(["profile", "create", "-"], env: createEnv) == 0, wrote else {
            return report(id, slug, false, "(a disabled overlapping profile blocked create)")
        }

        // Enabling the overlapping disabled profile is refused before anything is written.
        var enableWrote = false, enableInstalled = false
        let enableEnv = fakeCLIEnvironment(
            readProfiles: { [running, disabled] }, fileExists: { $0 == running.plistPath },
            writeProfile: { _ in enableWrote = true; return true },
            installProfile: { _ in enableInstalled = true; return nil })
        guard LimpetCLI.execute(["profile", "enable", disabled.shortId], env: enableEnv) == 65,
              !enableWrote, !enableInstalled else {
            return report(id, slug, false, "(enabling an overlapping profile was not refused before writing)")
        }
        // And install (reached by every other enable path) refuses it too.
        var enabledNow = disabled
        enabledNow.isEnabled = true
        do {
            try SyncSetupService.shared.install(
                profile: enabledNow, loadAgent: false, executablePath: translocatedExecutable,
                otherProfiles: [running], isInstalled: installed)
            return report(id, slug, false, "(install did not throw)")
        } catch SyncSetupService.SetupError.refusedProfile {
        } catch {
            return report(id, slug, false, "(install threw \(error), not refusedProfile)")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L4-19 — edits and enables are refused before anything is persisted

    /// Review finding 6: the edit/enable path (`applyProfileChange`, used by
    /// applyExternalProfileEdit and setProfileEnabled) must validate BEFORE
    /// persisting, and report refusals and install errors instead of printing.
    private static func testProfileChangeRefusedBeforePersist() -> Bool {
        let id = "AC-L4-19", slug = "profile-change-refused-before-persist"
        let running = sampleProfile(name: "Running")
        var current = sampleProfile(name: "Mine")
        current.remotePath = "Elsewhere"
        struct Failed: Error {}
        func apply(_ updated: SyncProfile, installThrows: Bool = false) -> ([String], [String]) {
            var events: [String] = [], errors: [String] = []
            SyncManager.applyProfileChange(
                from: current, to: updated, others: [running, current],
                isInstalled: { $0.id == running.id },
                persist: { _ in events.append("persist") },
                install: { _ in events.append("install"); if installThrows { throw Failed() } },
                uninstall: { _ in events.append("uninstall") },
                reportError: { errors.append($0) })
            return (events, errors)
        }
        var overlapping = current
        overlapping.remotePath = running.remotePath + "/sub"
        var connectionString = current
        connectionString.rcloneRemote = connectionStringRemote
        for refused in [overlapping, connectionString] {
            let (events, errors) = apply(refused)
            guard events.isEmpty, errors.count == 1, errors[0].hasPrefix("Not saved"),
                  !errors[0].contains(connectionStringSecret) else {
                return report(id, slug, false, "(refused change: events=\(events) errors=\(errors))")
            }
        }
        var moved = current
        moved.remotePath = "Elsewhere2"
        guard apply(moved).0 == ["persist", "uninstall", "install"], apply(moved).1.isEmpty else {
            return report(id, slug, false, "(valid change not persisted then reinstalled: \(apply(moved)))")
        }
        let (events, errors) = apply(moved, installThrows: true)
        guard events == ["persist", "uninstall", "install"], errors.count == 1, errors[0].hasPrefix("Saved, but") else {
            return report(id, slug, false, "(install error not reported: \(events) \(errors))")
        }
        // install treats the profile it installs as enabled (the detail view
        // installs before flipping the flag), so a disabled one is checked too.
        var disabledOverlap = overlapping
        disabledOverlap.isEnabled = false
        do {
            try SyncSetupService.shared.install(
                profile: disabledOverlap, loadAgent: false, executablePath: translocatedExecutable,
                otherProfiles: [running], isInstalled: { $0.id == running.id })
            return report(id, slug, false, "(install of a disabled overlapping profile did not throw)")
        } catch SyncSetupService.SetupError.refusedProfile {
        } catch {
            return report(id, slug, false, "(install threw \(error), not refusedProfile)")
        }
        // Likewise a running watcher, whatever the flag in its own copy says.
        let dir = "\(selfTestRoot)/ac-l4-19-profiles"
        try? FileManager.default.removeItem(atPath: dir)
        guard ProfileStore.writeProfileFile(running, in: dir) != nil,
              SyncWatchDaemon.refusalReason(
                for: disabledOverlap, profilesDirectory: dir, isInstalled: { $0.id == running.id }) != nil else {
            return report(id, slug, false, "(a watcher whose copy says disabled skipped the overlap rule)")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L4-20 — keychain remote: edit in place, verified add, never half-deleted

    /// Review findings 5, 7 and 9, all through the fake `security`.
    private static func testKeychainRemoteEditDeleteConsistency() -> Bool {
        let id = "AC-L4-20", slug = "keychain-remote-edit-delete-consistency"
        let fm = FileManager.default
        let dir = "\(selfTestRoot)/ac-l4-20"
        try? fm.removeItem(atPath: dir)
        guard let stub = makeSecurityStub(in: dir, secret: "unused", mode: "store") else {
            return report(id, slug, false, "(fixture setup failed)")
        }
        let confPath = "\(dir)/rclone.conf", rcloneStub = "\(dir)/rclone-stub"
        try? "[before]\ntype = local\n".write(toFile: confPath, atomically: true, encoding: .utf8)
        try? "#!/bin/sh\n[ -f \"\(dir)/rclone-fail\" ] && exit 1\nexit 0\n".write(toFile: rcloneStub, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rcloneStub)
        let store = KeychainSecretStore(securityPath: stub, keychainPath: "\(dir)/fake.keychain-db", lockStatus: { _ in .unlocked })
        let service = RcloneConfigService(configPath: confPath, rclonePath: rcloneStub, keychain: store)
        func conf() -> String { (try? String(contentsOfFile: confPath, encoding: .utf8)) ?? "" }
        func flag(_ name: String, _ on: Bool) {
            if on { fm.createFile(atPath: "\(dir)/\(name)", contents: nil) } else { try? fm.removeItem(atPath: "\(dir)/\(name)") }
        }

        // Finding 9: the shared creation function derives the MEGA S4 endpoint.
        do {
            try service.addKeychainRemote(name: "kr", type: "s3",
                values: ["provider": "Mega", "region": "ap-tokyo-1", "access_key_id": "AKID1"], secret: "old-secret")
        } catch { return report(id, slug, false, "(add threw \(error))") }
        guard conf().hasSuffix("[kr]\ntype = s3\naccess_key_id = AKID1\nendpoint = s3.ap-tokyo-1.megas4.com\n"
                + "provider = Mega\nregion = ap-tokyo-1\nlimpet_keychain = true\n") else {
            return report(id, slug, false, "(MEGA S4 endpoint not derived by addKeychainRemote: \(conf().debugDescription))")
        }
        // A section in the middle of the file, to see the edit keep its place.
        try? ("[before]\ntype = local\n\n[kr]\ntype = s3\naccess_key_id = AKID1\nendpoint = s3.ap-tokyo-1.megas4.com\n"
            + "provider = Mega\nregion = ap-tokyo-1\nlimpet_keychain = true\n\n[after]\ntype = local\n")
            .write(toFile: confPath, atomically: true, encoding: .utf8)
        guard store.read(account: "kr") == .found("old-secret") else {
            return report(id, slug, false, "(fixture secret not stored)")
        }
        var edit = RemoteConfiguration(name: "kr", provider: .s3Compatible)
        edit.values = ["provider": "Mega", "region": "ap-tokyo-1", "access_key_id": "AKID2", "limpet_keychain": "true"]

        // Finding 5: a non-secret edit rewrites the section where it stands and keeps the secret.
        do { try service.updateRemote(edit) } catch { return report(id, slug, false, "(in-place edit threw \(error))") }
        let edited = "[before]\ntype = local\n\n[kr]\ntype = s3\naccess_key_id = AKID2\nendpoint = s3.ap-tokyo-1.megas4.com\n"
            + "provider = Mega\nregion = ap-tokyo-1\nlimpet_keychain = true\n\n[after]\ntype = local\n"
        guard conf() == edited, store.read(account: "kr") == .found("old-secret") else {
            return report(id, slug, false, "(in-place edit wrong: \(conf().debugDescription))")
        }
        // A new secret whose add fails, or whose read-back does not match (finding 7):
        // rclone.conf untouched, the error says to re-enter the secret.
        edit.values["secret_access_key"] = "new-secret"
        edit.values["access_key_id"] = "AKID3"
        for failure in ["fail--i", "corrupt-add"] {
            flag(failure, true)
            defer { flag(failure, false) }
            do {
                try service.updateRemote(edit)
                return report(id, slug, false, "(\(failure): update did not fail)")
            } catch {
                guard "\(error)".contains("re-enter"), conf() == edited else {
                    return report(id, slug, false, "(\(failure): \(error), conf changed=\(conf() != edited))")
                }
            }
        }
        do { try service.updateRemote(edit) } catch { return report(id, slug, false, "(rotation threw \(error))") }
        guard store.read(account: "kr") == .found("new-secret"), conf().contains("access_key_id = AKID3") else {
            return report(id, slug, false, "(rotation did not store the new secret and update the section)")
        }

        // deleteRemote is never half-done.
        flag("fail-delete-generic-password", true)
        let failedDelete = (try? service.deleteRemote("kr")) == nil
        flag("fail-delete-generic-password", false)
        guard failedDelete, store.read(account: "kr") == .found("new-secret"), conf().contains("[kr]") else {
            return report(id, slug, false, "(a failed item delete left a half-deleted remote)")
        }
        flag("rclone-fail", true)
        let failedSection = (try? service.deleteRemote("kr")) == nil
        flag("rclone-fail", false)
        guard failedSection, store.read(account: "kr") == .found("new-secret") else {
            return report(id, slug, false, "(a failed section delete did not restore the secret)")
        }
        guard (try? service.deleteRemote("kr")) != nil, store.read(account: "kr") == .notFound else {
            return report(id, slug, false, "(a clean delete did not remove the item)")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L4-21 — a locked keychain is never read (no unprompted dialogs)

    /// limpet-plan.md L4 "No unprompted keychain dialogs": with the injected
    /// lock-status provider saying locked (or unknown), no `security` call is
    /// made at all, no rclone starts, and each attempt logs exactly the one
    /// fixed line. The production provider (SecKeychainGetStatus) is never
    /// called here; that it cannot prompt is for the user to check live.
    private static func testKeychainLockedNoRead() -> Bool {
        let id = "AC-L4-21", slug = "keychain-locked-no-read"
        let dir = "\(selfTestRoot)/ac-l4-21"
        try? FileManager.default.removeItem(atPath: dir)
        guard let stub = makeSecurityStub(in: dir, secret: "SEKRET-locked-2b7", mode: "found") else {
            return report(id, slug, false, "(fixture setup failed)")
        }
        let confPath = "\(dir)/rclone.conf"
        try? "[ks3]\ntype = s3\nprovider = Mega\nlimpet_keychain = true\n\n[plain]\ntype = local\n"
            .write(toFile: confPath, atomically: true, encoding: .utf8)
        let statusFile = "\(dir)/lock-status"
        let store = KeychainSecretStore(
            securityPath: stub, keychainPath: "\(dir)/fake.keychain-db",
            lockStatus: { _ in
                switch (try? String(contentsOfFile: statusFile, encoding: .utf8)) ?? "" {
                case "unlocked": return .unlocked
                case "locked": return .locked
                default: return .unknown
                }
            })
        let service = RcloneConfigService(configPath: confPath, rclonePath: "/usr/bin/false", keychain: store)
        let profile = SyncProfile(name: "p", rcloneRemote: "ks3:", remotePath: "b", localSyncPath: "/tmp/x")
        for status in ["locked", "unknown"] {
            try? status.write(toFile: statusFile, atomically: true, encoding: .utf8)
            var lines: [String] = [], spawned = 0
            for _ in 0..<2 {
                let code = SyncWatchDaemon.runSyncChild(
                    profile: profile, service: service, log: { lines.append($0) }, spawn: { _ in spawned += 1; return 0 })
                guard code == SyncWatchDaemon.secretUnavailableExitCode else {
                    return report(id, slug, false, "(\(status): exit \(code))")
                }
            }
            guard spawned == 0, lines == [KeychainSecretStore.lockedMessage, KeychainSecretStore.lockedMessage],
                  lines[0] == "Keychain locked — open limpet and click \"Allow keychain access\"",
                  !FileManager.default.fileExists(atPath: "\(dir)/calls") else {
                return report(id, slug, false, "(\(status): spawned=\(spawned) lines=\(lines) security called=\(FileManager.default.fileExists(atPath: "\(dir)/calls")))")
            }
            // Writes are refused the same way, before any security call.
            guard store.add(account: "ks3", secret: "x") == KeychainSecretStore.lockedMessage,
                  store.delete(account: "ks3") == KeychainSecretStore.lockedMessage,
                  !FileManager.default.fileExists(atPath: "\(dir)/calls") else {
                return report(id, slug, false, "(\(status): a keychain write reached security)")
            }
        }
        // A remote without the marker never asks the keychain at all.
        guard service.secretEnvironment(forRemote: "plain:", log: { _ in }) == [:] else {
            return report(id, slug, false, "(a non-keychain remote was affected by the lock)")
        }
        // Unlocked: normal read, the child starts with the secret.
        try? "unlocked".write(toFile: statusFile, atomically: true, encoding: .utf8)
        var childEnvironment: [String: String] = [:]
        _ = SyncWatchDaemon.runSyncChild(
            profile: profile, service: service, log: { _ in }, spawn: { childEnvironment = $0; return 0 })
        guard childEnvironment["RCLONE_CONFIG_KS3_SECRET_ACCESS_KEY"] == "SEKRET-locked-2b7" else {
            return report(id, slug, false, "(unlocked: the secret was not read)")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L4-22 — doctor warns when the installed maxDelete is stale (review 2b, deferred)

    private static func testDoctorWarnsStaleMaxDelete() -> Bool {
        let id = "AC-L4-22", slug = "doctor-warns-stale-max-delete"
        var profile = sampleProfile(isEnabled: false)
        profile.rcloneRemote = "s4:"
        func warnings(derivedMaxDelete: Int, provider: String) -> [DoctorCheck] {
            let env = fakeCLIEnvironment(
                runRclone: { args, _, _ in args.first == "version" ? (0, "rclone v1.75.1", "") : (0, "", "") },
                readProfiles: { [profile] },
                fileExists: { $0 == profile.configPath },
                remoteSection: { $0 == "s4" ? ["type": "s3", "provider": provider] : nil },
                readFile: { $0 == profile.configPath ? "{\"maxDelete\": \(derivedMaxDelete)}" : nil })
            return LimpetCLI.doctorChecks(env: env).filter { $0.detail.contains("limpet reinstall") }
        }
        // Installed as Mega (100), now still Mega → quiet; changed to AWS with versioning
        // → the current section gives 0 → warn; installed 0 while it is now Mega → warn.
        profile.remoteVersioning = true
        guard warnings(derivedMaxDelete: 100, provider: "Mega").isEmpty,
              warnings(derivedMaxDelete: 100, provider: "AWS").first?.status == .warn,
              warnings(derivedMaxDelete: 0, provider: "Mega").first?.status == .warn else {
            return report(id, slug, false, "(stale maxDelete warning wrong)")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L4-23 — a refused external edit is rolled back, its content kept aside

    /// Second review, finding 1: an external edit making A overlap B, or one
    /// that no longer decodes, must not stay in A's file.
    private static func testRefusedExternalEditRestored() -> Bool {
        let id = "AC-L4-23", slug = "refused-external-edit-restored"
        let fm = FileManager.default
        let dir = "\(selfTestRoot)/ac-l4-23/profiles"
        try? fm.removeItem(atPath: "\(selfTestRoot)/ac-l4-23")
        var a = sampleProfile(name: "A")
        a.remotePath = "PathA"
        var b = sampleProfile(name: "B")
        b.remotePath = "PathB"
        let derivedA = "\(dir)/\(a.shortId).json"
        guard ProfileStore.writeProfileFile(a, in: dir) != nil, ProfileStore.writeProfileFile(b, in: dir) != nil,
              fm.createFile(atPath: derivedA, contents: Data("{\"remotePath\":\"PathA\"}".utf8)) else {
            return report(id, slug, false, "(fixture setup failed)")
        }
        let aPath = "\(dir)/\(a.shortId).profile.json"
        var events: [String] = [], errors: [(UUID, String)] = []
        func apply(_ data: Data) -> SyncManager.ExternalEditOutcome {
            SyncManager.applyExternalEdit(
                data: data, path: aPath, known: { $0 == a.id ? a : ($0 == b.id ? b : nil) },
                others: [a, b], isInstalled: { _ in true },
                persist: { _ in events.append("persist") }, install: { _ in events.append("install") },
                uninstall: { _ in events.append("uninstall") }, reportError: { errors.append(($0, $1)) })
        }
        func fileProfile() -> SyncProfile? {
            fm.contents(atPath: aPath).flatMap { try? JSONDecoder().decode(SyncProfile.self, from: $0) }
        }

        // A edited to overlap B.
        var overlapping = a
        overlapping.remotePath = "PathB/inside"
        guard let edit = try? JSONEncoder().encode(overlapping), (try? edit.write(to: URL(fileURLWithPath: aPath))) != nil,
              case .restored(let copy?) = apply(edit) else {
            return report(id, slug, false, "(overlapping edit was not restored)")
        }
        guard events.isEmpty, fileProfile() == a, fileProfile()?.remotePath == "PathA",
              fm.contents(atPath: copy) == edit, copy.hasPrefix("\(dir)/refused/"),
              fm.contents(atPath: derivedA) == Data("{\"remotePath\":\"PathA\"}".utf8),
              errors.count == 1, errors[0].0 == a.id, errors[0].1.contains("Restored"), errors[0].1.contains(copy) else {
            return report(id, slug, false, "(overlap: events=\(events) errors=\(errors.map(\.1)))")
        }
        // B's watcher still runs: A's file no longer overlaps it.
        guard SyncWatchDaemon.refusalReason(for: b, profilesDirectory: dir, isInstalled: { _ in true }) == nil else {
            return report(id, slug, false, "(B's watcher still refuses)")
        }

        // An edit that no longer decodes (F4 value) is rolled back the same way.
        errors = []
        let undecodable = Data(profileJSON(a, rcloneRemote: connectionStringRemote).utf8)
        try? undecodable.write(to: URL(fileURLWithPath: aPath))
        guard case .restored(let copy2?) = apply(undecodable), fileProfile() == a,
              fm.contents(atPath: copy2) == undecodable, events.isEmpty,
              errors.count == 1, errors[0].1.contains("no longer decodes"),
              !errors[0].1.contains(connectionStringSecret) else {
            return report(id, slug, false, "(undecodable edit not restored: \(errors.map(\.1)))")
        }
        // A half-written file is left alone; an acceptable edit applies.
        let partial = Data("{\"id\": \"\(a.id.uuidString)\", \"na".utf8)
        guard apply(partial) == .ignored else {
            return report(id, slug, false, "(a half-written file was not ignored)")
        }
        var renamed = a
        renamed.name = "A renamed"
        guard let ok = try? JSONEncoder().encode(renamed), apply(ok) == .applied, events == ["persist"] else {
            return report(id, slug, false, "(an acceptable edit was not applied: \(events))")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L4-24 — a wizard retry installs the same profile, never a second one

    private static func testWizardRetryKeepsProfileId() -> Bool {
        let id = "AC-L4-24", slug = "wizard-retry-keeps-profile-id"
        func build(_ existing: SyncProfile?) -> SyncProfile {
            SetupWizardView.profileToSave(
                existing: existing, name: "W", remote: "r", remotePath: "p", localPath: "/tmp/w",
                drivePath: "", interval: 5, direction: .localToRemote)
        }
        let first = build(nil)
        let retry = build(first)
        guard first.isEnabled, retry.id == first.id, retry.isEnabled else {
            return report(id, slug, false, "(retry got id \(retry.id), first \(first.id))")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L4-25 — a full save moves an undecodable profile file aside, never deletes it

    /// Internal review F1: `profilesOnDisk` skips a file that does not decode,
    /// so the orphan prune of a full `save()` used to delete it while its
    /// launchd agent stayed installed. A genuine (decodable) orphan is still removed.
    private static func testPruneKeepsUndecodableFile() -> Bool {
        let id = "AC-L4-25", slug = "prune-moves-undecodable-aside"
        let fm = FileManager.default
        let dir = "\(selfTestRoot)/ac-l4-25/profiles"
        try? fm.removeItem(atPath: "\(selfTestRoot)/ac-l4-25")
        let valid = sampleProfile(name: "Valid")
        let doomed = sampleProfile(name: "Doomed")
        let invalidDict: [String: Any] = [
            "id": UUID().uuidString, "name": "Invalid", "rcloneRemote": "selftest-fixture-remote:",
            "remotePath": "Invalid", "localSyncPath": "/tmp/limpet-selftest-local", "transfers": 128,
        ]
        let invalidPath = "\(dir)/invalid.profile.json"
        guard ProfileStore.writeProfileFile(valid, in: dir) != nil, ProfileStore.writeProfileFile(doomed, in: dir) != nil,
              let invalid = try? JSONSerialization.data(withJSONObject: invalidDict),
              (try? invalid.write(to: URL(fileURLWithPath: invalidPath))) != nil,
              (try? JSONDecoder().decode(SyncProfile.self, from: invalid)) == nil else {
            return report(id, slug, false, "(fixture setup failed)")
        }
        let store = ProfileStore(
            profilesDirectory: dir,
            defaults: UserDefaults(suiteName: "com.nanako.limpet.selftest.l4-25.\(UUID().uuidString)")!)
        guard Set(store.profiles.map(\.id)) == [valid.id, doomed.id] else {
            return report(id, slug, false, "(fixture load: \(store.profiles.map(\.name)))")
        }
        store.delete(id: doomed.id)  // a full save(): writes Valid, prunes the rest
        store.save()                 // and once more with nothing to delete
        let refused = (try? fm.contentsOfDirectory(atPath: "\(dir)/refused")) ?? []
        guard !fm.fileExists(atPath: invalidPath), refused.count == 1, refused[0].hasPrefix("invalid."),
              fm.contents(atPath: "\(dir)/refused/\(refused[0])") == invalid else {
            return report(id, slug, false, "(undecodable file not kept under refused/: refused=\(refused))")
        }
        guard fm.fileExists(atPath: "\(dir)/\(valid.shortId).profile.json"),
              !fm.fileExists(atPath: "\(dir)/\(doomed.shortId).profile.json") else {
            return report(id, slug, false, "(valid file lost or genuine orphan not removed)")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L4-26 — editing a keychain remote drops only the secret's own "is required"

    /// Internal review F2: the edit-mode filter matched the secret label by
    /// prefix, and b2's "Application Key" is a prefix of "Application Key ID
    /// is required", so a b2 section without `account` could be saved.
    private static func testEditKeepsNonSecretRequiredErrors() -> Bool {
        let id = "AC-L4-26", slug = "edit-remote-secret-filter-exact"
        var b2 = RemoteConfiguration(name: "kb", provider: .b2)
        guard AddRemoteSheet.editBlockingErrors(b2) == ["Application Key ID is required"] else {
            return report(id, slug, false, "(b2 without account: \(AddRemoteSheet.editBlockingErrors(b2)))")
        }
        b2.values["account"] = "KEYID"
        var s3 = RemoteConfiguration(name: "ks", provider: .s3Compatible)
        s3.values["access_key_id"] = "AKID"
        guard AddRemoteSheet.editBlockingErrors(b2).isEmpty, AddRemoteSheet.editBlockingErrors(s3).isEmpty else {
            return report(id, slug, false, "(an empty secret blocked an edit: b2=\(AddRemoteSheet.editBlockingErrors(b2)) s3=\(AddRemoteSheet.editBlockingErrors(s3)))")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L4-27 — a locked keychain logs once per throttle window, not once per trigger

    /// Internal review F6: `secretEnvironment`'s lines were written on every
    /// trigger (~5 s while files change), unlike refusal and source-missing
    /// lines. The run now asks the scheduler's `mayLog`, throttled per kind.
    /// Wired as in `SyncWatchDaemon.productionRunner`, minus its main-queue hop.
    private static func testKeychainLockedLogThrottled() -> Bool {
        let id = "AC-L4-27", slug = "keychain-locked-log-throttled"
        let dir = "\(selfTestRoot)/ac-l4-27"
        try? FileManager.default.removeItem(atPath: dir)
        guard let stub = makeSecurityStub(in: dir, secret: "unused", mode: "found") else {
            return report(id, slug, false, "(fixture setup failed)")
        }
        let confPath = "\(dir)/rclone.conf"
        try? "[ks3]\ntype = s3\nprovider = Mega\nlimpet_keychain = true\n"
            .write(toFile: confPath, atomically: true, encoding: .utf8)
        let store = KeychainSecretStore(
            securityPath: stub, keychainPath: "\(dir)/fake.keychain-db", lockStatus: { _ in .locked })
        let service = RcloneConfigService(configPath: confPath, rclonePath: "/usr/bin/false", keychain: store)
        let profile = SyncProfile(name: "p", rcloneRemote: "ks3:", remotePath: "b", localSyncPath: "/tmp/x")
        var lines: [String] = [], refusals = 0, spawned = 0
        let clock = VirtualClock()
        let scheduler = SyncWatchScheduler(runner: SchedulerRunner(
            sourceExists: { true },
            runChild: { mayLog, completion in
                completion(SyncWatchDaemon.runSyncChild(
                    profile: profile, service: service,
                    log: { if mayLog() { lines.append($0) } },
                    spawn: { _ in spawned += 1; return 0 }))
            },
            now: { clock.now },
            scheduleAfter: { s, a in clock.scheduleAfter(s, a) },
            logSourceMissing: {},
            refusalReason: { nil },
            logRefusal: { _ in refusals += 1 },
            deleteLimitReached: { false },
            recordDeleteLimit: { true }))
        for _ in 0..<4 {              // four debounced triggers, 5 s apart
            scheduler.trigger()
            clock.advance(by: 5)
        }
        guard scheduler.runCount == 4, lines == [KeychainSecretStore.lockedMessage], spawned == 0 else {
            return report(id, slug, false, "(within the window: runs=\(scheduler.runCount) lines=\(lines.count) spawned=\(spawned))")
        }
        clock.advance(by: 30)
        scheduler.trigger()
        guard lines.count == 2, spawned == 0, refusals == 0, scheduler.state == .idle,
              !FileManager.default.fileExists(atPath: "\(dir)/calls") else {
            return report(id, slug, false, "(after the window: lines=\(lines.count) spawned=\(spawned) state=\(scheduler.state))")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L4-28 — output larger than the pipe buffer is drained, not timed out

    /// CodeRabbit PR #6: stdout was read only after `security` exited, so an
    /// output over the ~64 KB pipe buffer blocked the child until the timeout.
    private static func testKeychainLargeOutputDrained() -> Bool {
        let id = "AC-L4-28", slug = "keychain-large-output-drained"
        let dir = "\(selfTestRoot)/ac-l4-28"
        try? FileManager.default.removeItem(atPath: dir)
        let big = String(repeating: "a", count: 200_000)
        guard let stub = makeSecurityStub(in: dir, secret: big, mode: "found") else {
            return report(id, slug, false, "(fixture setup failed)")
        }
        let store = KeychainSecretStore(
            securityPath: stub, keychainPath: "\(dir)/fake.keychain-db", timeout: 3, lockStatus: { _ in .unlocked })
        let result = store.read(account: "big")
        guard result == .found(big) else {
            let shape: String
            if case .found(let s) = result { shape = "found(\(s.count) chars)" } else { shape = "\(result)" }
            return report(id, slug, false, "(read returned \(shape))")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L4-5 — the watcher refuses before every run (catch-up, trigger, SIGUSR1, retry)

    /// Drives `SyncWatchScheduler` with the PRODUCTION refusal closure
    /// (`SyncWatchDaemon.refusalReason`) over a scratch profiles directory: the
    /// overlapping profile file appears only after a first, allowed run, so the
    /// gate must be re-evaluated per attempt, not once at start.
    private static func testWatcherRefusesBeforeEveryRun() -> Bool {
        let id = "AC-L4-5", slug = "watcher-refuses-before-every-run"
        let dir = "\(selfTestRoot)/ac-l4-5-profiles"
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let mine = sampleProfile(name: "Mine")

        var childRuns = 0, refusalLogs = 0, exitCode: Int32 = 75
        let clock = VirtualClock()
        let runner = SchedulerRunner(
            sourceExists: { true },
            runChild: { _, completion in childRuns += 1; completion(exitCode) },
            now: { clock.now },
            scheduleAfter: { s, a in clock.scheduleAfter(s, a) },
            logSourceMissing: {},
            refusalReason: { SyncWatchDaemon.refusalReason(for: mine, profilesDirectory: dir, isInstalled: { _ in true }) },
            logRefusal: { _ in refusalLogs += 1 },
            deleteLimitReached: { false },
            recordDeleteLimit: { true }
        )
        let scheduler = SyncWatchScheduler(runner: runner)
        scheduler.trigger()  // catch-up: allowed, exits 75 → backoff
        guard childRuns == 1 else {
            return report(id, slug, false, "(catch-up run did not start: \(childRuns))")
        }
        // Another profile on the same remote path appears on disk.
        var twin = sampleProfile(name: "Twin")
        twin.remotePath = mine.remotePath
        guard ProfileStore.writeProfileFile(twin, in: dir) != nil else {
            return report(id, slug, false, "(fixture write failed)")
        }
        exitCode = 0
        clock.advance(by: 11)          // post-backoff retry
        scheduler.trigger()            // FSEvents / periodic
        scheduler.trigger()            // SIGUSR1 goes through the same trigger()
        clock.advance(by: 60)
        guard childRuns == 1, refusalLogs >= 1, scheduler.state == .idle else {
            return report(id, slug, false, "(overlap: childRuns=\(childRuns) logs=\(refusalLogs) state=\(scheduler.state))")
        }

        // A refused field value (built in memory; decode would never produce it).
        var bad = sampleProfile(name: "Bad")
        bad.rcloneRemote = connectionStringRemote
        var badRuns = 0
        let badScheduler = SyncWatchScheduler(runner: SchedulerRunner(
            sourceExists: { true },
            runChild: { _, completion in badRuns += 1; completion(0) },
            now: { clock.now },
            scheduleAfter: { s, a in clock.scheduleAfter(s, a) },
            logSourceMissing: {},
            refusalReason: { SyncWatchDaemon.refusalReason(for: bad, profilesDirectory: "\(dir)-empty", isInstalled: { _ in true }) },
            logRefusal: { _ in },
            deleteLimitReached: { false },
            recordDeleteLimit: { true }
        ))
        badScheduler.trigger()
        badScheduler.trigger()
        guard badRuns == 0 else {
            return report(id, slug, false, "(connection-string profile ran \(badRuns) time(s))")
        }

        // Regression: a pending rerun that finds the source gone must leave the
        // scheduler idle, so the next trigger (source back) runs again.
        var present = true, pendingCompletion: ((Int32) -> Void)?, runs = 0
        let stuckScheduler = SyncWatchScheduler(runner: SchedulerRunner(
            sourceExists: { present },
            runChild: { _, completion in runs += 1; pendingCompletion = completion },
            now: { clock.now },
            scheduleAfter: { s, a in clock.scheduleAfter(s, a) },
            logSourceMissing: {},
            refusalReason: { nil },
            logRefusal: { _ in },
            deleteLimitReached: { false },
            recordDeleteLimit: { true }
        ))
        stuckScheduler.trigger()
        stuckScheduler.trigger()       // pending
        present = false
        pendingCompletion?(0)          // pending rerun finds no source
        present = true
        stuckScheduler.trigger()
        guard runs == 2 else {
            return report(id, slug, false, "(scheduler stuck after a missing-source rerun: runs=\(runs), state=\(stuckScheduler.state))")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L5-1 — source-missing line parses to .sourceMissing(path)

    /// The watcher (SyncWatchDaemon.appendProfileLogLine) and the generated
    /// script (SyncSetupService) write the identical "Source missing: <path>"
    /// line; both must parse to the same event, and an ordinary line must not.
    private static func testSourceMissingParses() -> Bool {
        let id = "AC-L5-1", slug = "source-missing-parses"
        let parser = LogParser()

        func missingPath(_ line: String) -> String?? {
            guard let event = parser.parse(line: line) else { return .some(nil) }
            guard case .sourceMissing(let path) = event.type else { return .some(nil) }
            return .some(path)
        }

        let watcherLine = "2026-09-26 12:00:00 - Source missing: /some/path"
        guard case .some(.some("/some/path")) = missingPath(watcherLine) else {
            return report(id, slug, false, "(watcher line did not parse to .sourceMissing(\"/some/path\"))")
        }

        let scriptLine = "2026-09-26 12:00:01 - Source missing: /some/path"
        guard case .some(.some("/some/path")) = missingPath(scriptLine) else {
            return report(id, slug, false, "(script line did not parse to .sourceMissing(\"/some/path\"))")
        }

        // The path is user text: one that contains another matcher's phrase
        // must still parse as source-missing, not as that phrase.
        let trickyLine = "2026-09-26 12:00:03 - Source missing: /Volumes/Backup/Sync Complete"
        guard case .some(.some("/Volumes/Backup/Sync Complete")) = missingPath(trickyLine) else {
            return report(id, slug, false, "(a path containing \"Sync Complete\" did not parse as .sourceMissing)")
        }

        let normalLine = "2026-09-26 12:00:02 - Starting sync (local → remote)"
        guard case .some(.none) = missingPath(normalLine) else {
            return report(id, slug, false, "(a normal line was mismatched as .sourceMissing)")
        }

        return report(id, slug, true)
    }

    // MARK: - AC-L5-2 — source-missing clears through .syncStarted / .syncCompleted

    /// Drives the exact reducer `SyncManager.processLogEvent` uses for these
    /// three cases (`SyncManager.reduceProfileState`) — extracted because a
    /// full `SyncManager` needs a real profile store, workspace observer and
    /// config watcher to construct. Confirms `.syncStarted` overwrites an
    /// `.error` state unconditionally, so the watcher's 30s recheck clears the
    /// source-missing error once the source returns.
    private static func testSourceMissingClearsOnRecheck() -> Bool {
        let id = "AC-L5-2", slug = "source-missing-clears-on-recheck"

        var state: SyncState = .idle
        state = SyncManager.reduceProfileState(state, for: .sourceMissing("/some/path"))
        guard state == .error("Source missing: /some/path") else {
            return report(id, slug, false, "(sourceMissing did not produce .error: \(state))")
        }

        state = SyncManager.reduceProfileState(state, for: .syncStarted)
        guard state == .syncing else {
            return report(id, slug, false, "(syncStarted did not overwrite .error with .syncing: \(state))")
        }

        state = SyncManager.reduceProfileState(state, for: .syncCompleted)
        guard state == .idle else {
            return report(id, slug, false, "(syncCompleted did not produce .idle: \(state))")
        }

        return report(id, slug, true)
    }

    // MARK: - AC-L51-1 — RcloneLogEntry.fileChange only reports real success lines

    private static func testRcloneLogEntryFileChangeMapping() -> Bool {
        let id = "AC-L51-1", slug = "rclone-log-entry-file-change-mapping"

        func entry(level: String, msg: String, object: String?) -> RcloneLogEntry {
            RcloneLogEntry(
                level: level, msg: msg, time: "2026-09-26T10:19:00.000000+08:00",
                object: object, objectType: "*local.Object", stats: nil, source: nil, size: nil
            )
        }

        // Success lines, verified live against rclone 1.75.1 (2026-09-26,
        // `rclone sync --use-json-log -v` between local temp dirs under the
        // scratchpad — see the L5.1 fix commit for the exact lines observed).
        let successCases: [(String, FileChange.Operation)] = [
            ("Copied (new)", .copied),
            ("Copied (replaced existing)", .updated),
            ("Copied (server-side copy)", .copied),
            ("Updated modification time in destination", .updated),
            ("Deleted", .deleted),
            ("Renamed from \"a.txt\"", .renamed),
            // limpet-plan.md L6.2 item 4b: the trash mechanism's own,
            // UNAMBIGUOUS delete report (SyncManager separately drops the
            // AMBIGUOUS bare "Deleted" line above for a trash-enabled profile
            // — see testRealDeleteSurfacesOnceOverwriteSurfacesZero, AC-L62-7,
            // code-review finding 1 on 87bbf67).
            ("Moved into backup dir", .deleted),
            // Code-review finding 8 on 87bbf67: restored — a profile's
            // additionalRcloneFlags CAN set --track-renames, so this line can
            // be a genuine rename; it is ALSO a Move-capable backend's
            // backup-dir move, so `mayBeTrashArtifact` (checked below) rather
            // than the operation mapping itself carries the ambiguity.
            ("Moved (server-side) to: a-renamed.txt", .renamed),
        ]
        for (msg, expected) in successCases {
            let e = entry(level: "info", msg: msg, object: "a.txt")
            guard let change = e.fileChange, change.operation == expected else {
                return report(id, slug, false, "(\"\(msg)\" did not map to .\(expected))")
            }
        }

        // limpet-plan.md L6.2 item 4b (measured 2026-09-28, --disable Move):
        // "Copied (server-side copy) to: ..." is ALWAYS a backup-dir move,
        // unconditionally — a normal same-remote copy never gets a " to:"
        // suffix (that only appears when the destination name differs from
        // the source's).
        let backupCopy = entry(level: "info", msg: "Copied (server-side copy) to: a-100001.txt", object: "a.txt")
        guard backupCopy.fileChange == nil else {
            return report(id, slug, false, "(a backup-dir \"Copied (server-side copy) to:\" line was reported as a change)")
        }

        // mayBeTrashArtifact: true for exactly the two ambiguous lines, false
        // for everything else (code-review finding 1/8 on 87bbf67).
        let deletedEntry = entry(level: "info", msg: "Deleted", object: "a.txt")
        let movedIntoBackupEntry = entry(level: "info", msg: "Moved into backup dir", object: "a.txt")
        let movedServerSideEntry = entry(level: "info", msg: "Moved (server-side) to: a-renamed.txt", object: "a.txt")
        let renamedFromEntry = entry(level: "info", msg: "Renamed from \"a.txt\"", object: "b.txt")
        guard deletedEntry.fileChange?.mayBeTrashArtifact == true,
              movedServerSideEntry.fileChange?.mayBeTrashArtifact == true,
              movedIntoBackupEntry.fileChange?.mayBeTrashArtifact == false,
              renamedFromEntry.fileChange?.mayBeTrashArtifact == false else {
            return report(id, slug, false, "(mayBeTrashArtifact wrong on one of the four lines)")
        }

        // The max-delete error line (measured 2026-09-26, AC-L4-11) must never
        // be reported as a deletion — this was the live defect (L5 finding 3).
        let maxDeleteError = entry(
            level: "error",
            msg: "Got fatal error on delete: --max-delete threshold reached",
            object: "del5.txt"
        )
        guard maxDeleteError.fileChange == nil else {
            return report(id, slug, false, "(max-delete error line produced a FileChange)")
        }

        // A generic copy failure with an object must also yield nothing.
        let copyFailure = entry(
            level: "error",
            msg: "Failed to copy: failed to open source object: permission denied",
            object: "bad.txt"
        )
        guard copyFailure.fileChange == nil else {
            return report(id, slug, false, "(\"Failed to copy: …\" error line produced a FileChange)")
        }

        // A non-info level mentioning "Deleted" must not count either.
        let nonInfoDeleted = entry(level: "debug", msg: "Deleted", object: "c.txt")
        guard nonInfoDeleted.fileChange == nil else {
            return report(id, slug, false, "(a non-info \"Deleted\" line produced a FileChange)")
        }

        return report(id, slug, true)
    }

    // MARK: - AC-L51-2 — exit-code text mapping

    private static func testExitCodeErrorText() -> Bool {
        let id = "AC-L51-2", slug = "exit-code-error-text"

        let cases: [(Int, String)] = [
            (76, "Delete limit reached"),
            (64, "Exit code 64"),
            (1, "Exit code 1"),
            (7, "Exit code 7"),
        ]
        for (code, expected) in cases {
            let text = SyncManager.exitCodeErrorText(code)
            guard text == expected else {
                return report(id, slug, false, "(exit code \(code) mapped to \"\(text)\", expected \"\(expected)\")")
            }
        }

        return report(id, slug, true)
    }

    // MARK: - AC-L61-1 — CLIWriteMarker + ConfigFileWatcher.classifyWrite

    /// limpet-plan.md L6.1 change A. Drives `CLIWriteMarker.note`/`consume` and
    /// `ConfigFileWatcher.classifyWrite` directly, always inside
    /// `CLIWriteMarker.withDirectory` pointed at an isolated temp dir under
    /// `selfTestRoot` — this NEVER reads or writes the real
    /// `~/.local/state/limpet/cli-writes` (a hard limit for this repo).
    private static func testCLIWriteMarkerClassification() -> Bool {
        let id = "AC-L61-1", slug = "cli-write-marker-classification"
        let dir = "\(selfTestRoot)/ac-l61-1"
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let markerDir = "\(dir)/cli-writes"
        let fm = FileManager.default

        return CLIWriteMarker.withDirectory(markerDir) {
            // (a) a CLI write (marker noted, then the file written) is classified
            // .cliWrite, and consuming it is one-shot: classifying the same
            // content again (marker gone, no self-write registry entry either)
            // is .external.
            let cliPath = "\(dir)/cli-written.profile.json"
            let cliContent = Data("{\"marker\":\"cli-write\"}".utf8)
            let cliHash = ConfigSelfWriteRegistry.hash(cliContent)
            CLIWriteMarker.note(contentHash: cliHash)
            guard (try? cliContent.write(to: URL(fileURLWithPath: cliPath))) != nil else {
                return report(id, slug, false, "(failed to write cli fixture)")
            }
            guard ConfigFileWatcher.classifyWrite(forFileAt: cliPath) == .cliWrite else {
                return report(id, slug, false, "(a marked CLI write was not classified .cliWrite)")
            }
            guard ConfigFileWatcher.classifyWrite(forFileAt: cliPath) == .external else {
                return report(id, slug, false, "(a consumed marker was matched a second time)")
            }

            // (b) the SAME content with no marker at all is .external.
            let externalPath = "\(dir)/external.profile.json"
            let externalContent = Data("{\"marker\":\"external-write\"}".utf8)
            guard (try? externalContent.write(to: URL(fileURLWithPath: externalPath))) != nil else {
                return report(id, slug, false, "(failed to write external fixture)")
            }
            guard ConfigFileWatcher.classifyWrite(forFileAt: externalPath) == .external else {
                return report(id, slug, false, "(an unmarked write was not classified .external)")
            }

            // (c) a marker older than the 10-minute TTL is ignored AND removed
            // on the next consult, even for content that was never re-checked.
            let stalePath = "\(dir)/stale.profile.json"
            let staleContent = Data("{\"marker\":\"stale\"}".utf8)
            let staleHash = ConfigSelfWriteRegistry.hash(staleContent)
            CLIWriteMarker.note(contentHash: staleHash, now: Date().addingTimeInterval(-700))
            guard (try? staleContent.write(to: URL(fileURLWithPath: stalePath))) != nil else {
                return report(id, slug, false, "(failed to write stale fixture)")
            }
            guard fm.fileExists(atPath: "\(markerDir)/\(staleHash)") else {
                return report(id, slug, false, "(stale marker fixture was not written)")
            }
            guard ConfigFileWatcher.classifyWrite(forFileAt: stalePath) == .external else {
                return report(id, slug, false, "(a marker older than 10 minutes was still honored)")
            }
            guard !fm.fileExists(atPath: "\(markerDir)/\(staleHash)") else {
                return report(id, slug, false, "(a stale marker was not removed)")
            }

            // (d) the in-process self-write registry is checked FIRST: a hit
            // there ends the check without even reading a matching marker —
            // the marker must still be sitting there afterward, unconsumed.
            let bothPath = "\(dir)/both.profile.json"
            let bothContent = Data("{\"marker\":\"self-write-and-marker\"}".utf8)
            let bothHash = ConfigSelfWriteRegistry.hash(bothContent)
            ConfigSelfWriteRegistry.shared.noteSelfWrite(contentHash: bothHash)
            CLIWriteMarker.note(contentHash: bothHash)
            guard (try? bothContent.write(to: URL(fileURLWithPath: bothPath))) != nil else {
                return report(id, slug, false, "(failed to write both-markers fixture)")
            }
            guard ConfigFileWatcher.classifyWrite(forFileAt: bothPath) == .skip else {
                return report(id, slug, false, "(a self-write registry hit did not win over a CLI marker)")
            }
            guard fm.fileExists(atPath: "\(markerDir)/\(bothHash)") else {
                return report(id, slug, false, "(the CLI marker was consumed even though the registry hit first)")
            }

            return report(id, slug, true)
        }
    }

    // MARK: - AC-L61-2 — ProfileStore's own writes never touch CLIWriteMarker

    /// limpet-plan.md L6.1 change A: "ProfileStore.writeProfileFile stays
    /// marker-free for the app's own writes". Mutation-check: temporarily add
    /// a `CLIWriteMarker.note(...)` call inside `ProfileStore.writeProfileFile`
    /// (using the default, ambient `CLIWriteMarker.directory` — exactly what
    /// this test redirects), rebuild, and confirm this assertion FAILS; then
    /// revert.
    private static func testAppWritesLeaveMarkerDirEmpty() -> Bool {
        let id = "AC-L61-2", slug = "app-writes-leave-marker-dir-empty"
        let dir = "\(selfTestRoot)/ac-l61-2"
        try? FileManager.default.removeItem(atPath: dir)
        let profilesDir = "\(dir)/profiles"
        let markerDir = "\(dir)/cli-writes"
        let fm = FileManager.default

        return CLIWriteMarker.withDirectory(markerDir) {
            let store = ProfileStore(
                profilesDirectory: profilesDir,
                defaults: UserDefaults(suiteName: "com.nanako.limpet.selftest.ac-l61-2.\(UUID().uuidString)")!)

            var profile = sampleProfile(name: "AppWrite")
            store.add(profile)
            profile.name = "AppWrite renamed"
            store.update(profile)
            store.save()

            let markerFiles = (try? fm.contentsOfDirectory(atPath: markerDir)) ?? []
            guard markerFiles.isEmpty else {
                return report(id, slug, false, "(ProfileStore.add/update/save left marker(s): \(markerFiles))")
            }
            return report(id, slug, true)
        }
    }

    // MARK: - AC-L61-3 — reconcileClosures: the ONE place a marker hit skips launchd, never watch bookkeeping

    /// limpet-plan.md L6.1 change A, code-review findings 2 and 5. Exercises
    /// the extracted `SyncManager.reconcileClosures` directly — the ONE
    /// production seam that decides, given `suppressReconcile`, which of the
    /// four closures (`setupInstall`/`setupUninstall`/`watchStart`/
    /// `watchStop`) run — instead of a test-local re-implementation of that
    /// dispatch (finding 5's complaint about the previous version of this
    /// test). `applyExternalProfileEdit`/`applyExternalProfileCreate` build
    /// their real closures from the SAME function, so this is production logic,
    /// not a parallel copy that could silently drift from it.
    ///
    /// Finding 2: on a suppressed write, `setupInstall`/`setupUninstall` (the
    /// `SyncSetupService`/launchctl calls the CLI already made) must NOT fire,
    /// but `watchStart`/`watchStop` (the in-app `LogWatcher`/`profileStates`
    /// bookkeeping) MUST fire regardless — the previous version no-op'd the
    /// whole `install`/`uninstall` closure, so a CLI `profile disable` of a
    /// syncing/errored profile left `logWatchers`/`profileStates` stale.
    private static func testReconcileClosuresDispatch() -> Bool {
        let id = "AC-L61-3", slug = "reconcile-closures-dispatch"

        struct Spies {
            var setupInstall = 0, setupUninstall = 0, watchStart = 0, watchStop = 0
        }
        func run(suppressReconcile: Bool, invoke: (
            (install: (SyncProfile) throws -> Void, uninstall: (SyncProfile) throws -> Void)
        ) throws -> Void) rethrows -> Spies {
            var spies = Spies()
            let closures = SyncManager.reconcileClosures(
                suppressReconcile: suppressReconcile,
                setupInstall: { _ in spies.setupInstall += 1 },
                setupUninstall: { _ in spies.setupUninstall += 1 },
                watchStart: { _ in spies.watchStart += 1 },
                watchStop: { _ in spies.watchStop += 1 })
            try invoke(closures)
            return spies
        }
        let profile = sampleProfile(name: "Reconcile")

        // Suppressed install: setupInstall skipped, watchStart still runs.
        guard let suppressedInstall = try? run(suppressReconcile: true, invoke: { try $0.install(profile) }),
              suppressedInstall.setupInstall == 0, suppressedInstall.watchStart == 1 else {
            return report(id, slug, false, "(suppressed install ran the wrong closures)")
        }
        // Suppressed uninstall: setupUninstall skipped, watchStop still runs.
        guard let suppressedUninstall = try? run(suppressReconcile: true, invoke: { try $0.uninstall(profile) }),
              suppressedUninstall.setupUninstall == 0, suppressedUninstall.watchStop == 1 else {
            return report(id, slug, false, "(suppressed uninstall ran the wrong closures)")
        }
        // NOT suppressed (an ordinary external edit / hand edit): both halves run.
        guard let fullInstall = try? run(suppressReconcile: false, invoke: { try $0.install(profile) }),
              fullInstall.setupInstall == 1, fullInstall.watchStart == 1 else {
            return report(id, slug, false, "(un-suppressed install skipped setupInstall)")
        }
        guard let fullUninstall = try? run(suppressReconcile: false, invoke: { try $0.uninstall(profile) }),
              fullUninstall.setupUninstall == 1, fullUninstall.watchStop == 1 else {
            return report(id, slug, false, "(un-suppressed uninstall skipped setupUninstall)")
        }

        return report(id, slug, true)
    }

    // MARK: - AC-L61-3b — a marker-hit CLI write is classified through the real watcher

    /// limpet-plan.md L6.1 change A. Complements `testReconcileClosuresDispatch`
    /// (which tests the closure-selection logic in isolation) by proving the
    /// CLI's actual write — through `ProfileStore.writeProfileFile`, the same
    /// function `LimpetCLI`'s `writeProfile` closure calls — really is
    /// classified `.cliWrite` by `ConfigFileWatcher`, for both an edit of an
    /// existing id and a create of a new one.
    private static func testCLIWriteClassifiedThroughRealWriter() -> Bool {
        let id = "AC-L61-3b", slug = "cli-write-classified-through-real-writer"
        let dir = "\(selfTestRoot)/ac-l61-3b"
        try? FileManager.default.removeItem(atPath: dir)
        let profilesDir = "\(dir)/profiles"
        let markerDir = "\(dir)/cli-writes"

        return CLIWriteMarker.withDirectory(markerDir) {
            /// Simulates a `limpet profile set`/`create` write: note the marker
            /// for the exact bytes about to be written, THEN write them — the
            /// same order `LimpetCLI`'s `writeProfile` closure uses, calling the
            /// SAME `ProfileStore.writeProfileFile` the CLI does.
            ///
            /// `ProfileStore.writeProfileFile` also notes the write in
            /// `ConfigSelfWriteRegistry` — correct for the app's own writes, and
            /// harmless in production for the CLI's, since the CLI runs as its
            /// OWN process with its OWN registry instance, never the running
            /// app's. This self-test runs everything in one process, so that
            /// note would otherwise pollute the very registry
            /// `ConfigFileWatcher.classifyWrite` checks first, making a marker
            /// hit look like a same-process self-write instead — undo exactly
            /// that one entry, restoring the cross-process reality.
            func cliWrite(_ profile: SyncProfile) -> String? {
                guard let data = ProfileStore.encodedProfileFileData(profile) else { return nil }
                let hash = ConfigSelfWriteRegistry.hash(data)
                CLIWriteMarker.note(contentHash: hash)
                let filename = ProfileStore.writeProfileFile(profile, in: profilesDir)
                _ = ConfigSelfWriteRegistry.shared.consumeIfSelfWrite(contentHash: hash)
                return filename
            }

            var existing = sampleProfile(name: "Existing", isEnabled: true)
            guard ProfileStore.writeProfileFile(existing, in: profilesDir) != nil else {
                return report(id, slug, false, "(fixture write failed)")
            }
            existing.name = "Existing renamed"
            let existingPath = "\(profilesDir)/\(existing.shortId).profile.json"
            guard cliWrite(existing) != nil else {
                return report(id, slug, false, "(cliWrite of the update failed)")
            }
            guard ConfigFileWatcher.classifyWrite(forFileAt: existingPath) == .cliWrite else {
                return report(id, slug, false, "(a marked update was not classified .cliWrite)")
            }

            let created = sampleProfile(name: "Created", isEnabled: true)
            let createdPath = "\(profilesDir)/\(created.shortId).profile.json"
            guard cliWrite(created) != nil else {
                return report(id, slug, false, "(cliWrite of the create failed)")
            }
            guard ConfigFileWatcher.classifyWrite(forFileAt: createdPath) == .cliWrite else {
                return report(id, slug, false, "(a marked create was not classified .cliWrite)")
            }

            return report(id, slug, true)
        }
    }

    // MARK: - AC-L61-4 — .syncAlreadyRunning reduces to .syncing

    /// limpet-plan.md L6.1 change C, root cause 3. Mutation: reverting the
    /// `.syncAlreadyRunning` case added to `SyncManager.reduceProfileState`
    /// (and the matching `processLogEvent` branch) must fail this.
    private static func testSyncAlreadyRunningSetsSyncing() -> Bool {
        let id = "AC-L61-4", slug = "sync-already-running-sets-syncing"
        let result = SyncManager.reduceProfileState(.idle, for: .syncAlreadyRunning)
        guard result == .syncing else {
            return report(id, slug, false, "(.syncAlreadyRunning reduced .idle to \(result), expected .syncing)")
        }
        // Idempotent from an already-syncing state too.
        let result2 = SyncManager.reduceProfileState(.syncing, for: .syncAlreadyRunning)
        guard result2 == .syncing else {
            return report(id, slug, false, "(.syncAlreadyRunning reduced .syncing to \(result2), expected .syncing)")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L61-5 — install throws when launchctl load fails

    /// limpet-plan.md L6.1 change B. Injects a `loadCommand` that fails
    /// WITHOUT ever invoking real `launchctl` (a hard limit for this repo).
    /// Mutation: reverting `install`'s exit-status check back to `_ = ...`
    /// must fail this.
    private static func testInstallThrowsOnLaunchctlLoadFailure() -> Bool {
        let id = "AC-L61-5", slug = "install-throws-on-launchctl-load-failure"
        let dir = "\(selfTestRoot)/ac-l61-5"
        try? FileManager.default.removeItem(atPath: dir)
        var profile = sampleProfile(name: "LoadFails", isEnabled: true)
        profile.localSyncPath = "\(dir)/local"
        try? FileManager.default.createDirectory(atPath: profile.localSyncPath, withIntermediateDirectories: true)

        do {
            try SyncSetupService.shared.install(
                profile: profile,
                loadAgent: true,
                executablePath: "/Applications/limpet.app/Contents/MacOS/limpet",  // not translocated
                otherProfiles: [],
                isInstalled: { _ in false },
                loadCommand: { _ in (output: "launchctl: could not find service", exitCode: 3) })
            return report(id, slug, false, "(install did not throw on a failing loadCommand)")
        } catch SyncSetupService.SetupError.launchAgentLoadFailed(let exitCode, let output) {
            guard exitCode == 3, output.contains("could not find service") else {
                return report(id, slug, false, "(wrong error payload: exit=\(exitCode) output=\(output))")
            }
        } catch {
            return report(id, slug, false, "(threw the wrong error: \(error))")
        }

        // A succeeding loadCommand must not throw.
        do {
            try SyncSetupService.shared.install(
                profile: profile, loadAgent: true,
                executablePath: "/Applications/limpet.app/Contents/MacOS/limpet",
                otherProfiles: [], isInstalled: { _ in false },
                loadCommand: { _ in (output: "", exitCode: 0) })
        } catch {
            return report(id, slug, false, "(install threw on a succeeding loadCommand: \(error))")
        }

        return report(id, slug, true)
    }

    // MARK: - AC-L61-6 — SIGTERM's killpg helper on a real spawned process group

    /// limpet-plan.md L6.1 change B. `SyncWatchDaemon.run` never returns
    /// (`dispatchMain()`), so driving its actual `DispatchSource` SIGTERM
    /// handler in-process is not possible here; per the plan, this instead
    /// drives the extracted `terminateChildProcessGroup` helper against a
    /// process group THIS test spawns itself (never touching a real watcher or
    /// sync). UNTESTED by this: that a real SIGTERM delivered to a running
    /// `limpet watch` process actually invokes this helper before exiting —
    /// that wiring (`signal`+`DispatchSource.makeSignalSource` in `run`) is
    /// covered only by code review and the live check in the plan's Acceptance.
    private static func testTerminateChildProcessGroupKillsRealGroup() -> Bool {
        let id = "AC-L61-6", slug = "terminate-child-process-group"
        let dir = "\(selfTestRoot)/ac-l61-6"
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // A fake "sync child": a script that is its own process-group leader
        // (Foundation's Process spawns a new process group by default — the
        // same fact the plan measured live for the real sync script) and
        // spawns a `sleep` grandchild in that same group.
        let scriptPath = "\(dir)/fake-child.sh"
        let script = "#!/bin/bash\nsleep 30 &\nwait\n"
        guard (try? script.write(toFile: scriptPath, atomically: true, encoding: .utf8)) != nil,
              (try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)) != nil
        else {
            return report(id, slug, false, "(failed to write the fake child script)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return report(id, slug, false, "(failed to spawn the fake child: \(error))")
        }
        let pgid = process.processIdentifier

        // Give the grandchild `sleep` a moment to actually start before we
        // terminate the group — otherwise this could pass by accident (nothing
        // spawned yet to leak).
        Thread.sleep(forTimeInterval: 0.3)
        guard killpg(pgid, 0) == 0 else {
            process.waitUntilExit()
            return report(id, slug, false, "(the fake child's process group was already gone before terminating it)")
        }

        SyncWatchDaemon.terminateChildProcessGroup(pid: pgid)

        var groupGone = false
        for _ in 0..<20 {  // up to 2s, matching the plan's acceptance window
            if killpg(pgid, 0) != 0 { groupGone = true; break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.waitUntilExit()  // reap; this test spawned it, so this is the one process it may wait on

        guard groupGone else {
            return report(id, slug, false, "(script and/or sleep grandchild still alive 2s after terminateChildProcessGroup)")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L61-7 — the spawn/termination race closes without an orphan

    /// limpet-plan.md L6.1 change B, code-review finding 7. Drives
    /// `RunningChildState`'s pure decisions directly — every method returns a
    /// decision rather than calling `killpg`/`exit` itself, specifically so
    /// this test can exercise the exact race (SIGTERM arriving between
    /// `beginSpawning()` and `spawned(pid:)`) without ever calling real
    /// `exit()` on the self-test process itself.
    private static func testSpawnTerminationRaceClosesWithoutOrphan() -> Bool {
        let id = "AC-L61-7", slug = "spawn-termination-race"

        // Idle: nothing running or spawning — terminate now.
        let idleState = RunningChildState()
        guard idleState.requestTermination() == .exitNow else {
            return report(id, slug, false, "(idle state did not decide .exitNow)")
        }

        // A child already running when termination is requested — kill+exit directly.
        let runningState = RunningChildState()
        runningState.beginSpawning()
        guard runningState.spawned(pid: 555) == .ok else {
            return report(id, slug, false, "(spawned(pid:) fired early with no pending termination)")
        }
        guard runningState.requestTermination() == .killAndExit(555) else {
            return report(id, slug, false, "(a running child did not decide .killAndExit)")
        }

        // THE RACE: termination requested while `.spawning`, before the PID is
        // known. The handler must `.wait` (not exit — nothing to kill yet, and
        // exiting here would orphan the process `spawned(pid:)` is about to
        // record). `spawned(pid:)` must then finish the job the instant it has
        // a PID — this is exactly what closes the finding 7 window.
        let raceState = RunningChildState()
        raceState.beginSpawning()
        guard raceState.requestTermination() == .wait else {
            return report(id, slug, false, "(a mid-spawn termination request did not decide .wait)")
        }
        guard raceState.spawned(pid: 4242) == .killAndExitNow(4242) else {
            return report(id, slug, false, "(spawned(pid:) after a pending termination did not decide to kill+exit)")
        }

        // A spawn that fails (`pid: nil`) after a pending termination has
        // nothing to kill, but MUST still decide to exit — verifier gap 2:
        // without this, `requestTermination` already returned `.wait` (so the
        // handler did not exit) and a failed spawn used to report `.ok` (so
        // this call did not exit either), leaving the watcher alive until a
        // second signal or launchd's own SIGKILL.
        let failedSpawnState = RunningChildState()
        failedSpawnState.beginSpawning()
        guard failedSpawnState.requestTermination() == .wait else {
            return report(id, slug, false, "(setup: expected .wait)")
        }
        guard failedSpawnState.spawned(pid: nil) == .exitNow else {
            return report(id, slug, false, "(a failed spawn after a pending termination did not decide to exit)")
        }

        // Contrast: a failed spawn with NO pending termination must not exit.
        let failedSpawnNoTermination = RunningChildState()
        failedSpawnNoTermination.beginSpawning()
        guard failedSpawnNoTermination.spawned(pid: nil) == .ok else {
            return report(id, slug, false, "(a failed spawn with no pending termination wrongly decided to exit)")
        }

        return report(id, slug, true)
    }

    // MARK: - AC-L61-8 — CLIWriteMarker.consume ignores non-hex-64 filenames

    /// limpet-plan.md L6.1 change A, code-review finding 6. `note()`'s atomic
    /// write (`String.write(toFile:atomically:true,…)`) briefly creates a
    /// differently-named temp file in the SAME directory before renaming it
    /// into place, and that temp file can be caught by a directory listing
    /// with its content only PARTIALLY written (a real atomic-write race, not
    /// simulated content). The previous version's blanket "unparseable →
    /// delete" cleanup in `consume()` would delete such a file out from under
    /// the write it belongs to; the fix restricts that cleanup to names that
    /// are actually 64 lowercase hex characters, so a temp file — under any
    /// name `note()` could ever give one — is never even inspected, whatever
    /// its content looks like at the moment of the race. Simulates exactly
    /// the historical failure mode: a non-hex-64-named file with GARBAGE
    /// (unparseable-as-timestamp) content, which the OLD code's
    /// content-parse-failure branch deleted unconditionally.
    private static func testCLIWriteMarkerIgnoresNonHashFilenames() -> Bool {
        let id = "AC-L61-8", slug = "cli-write-marker-ignores-non-hash-filenames"
        let dir = "\(selfTestRoot)/ac-l61-8"
        try? FileManager.default.removeItem(atPath: dir)
        let markerDir = "\(dir)/cli-writes"
        let fm = FileManager.default

        return CLIWriteMarker.withDirectory(markerDir) {
            try? fm.createDirectory(atPath: markerDir, withIntermediateDirectories: true)

            // A transient temp-file-shaped name (what an atomic write's rename
            // source looks like) caught mid-write: garbage, unparseable content.
            let tempPath = "\(markerDir)/.note.tmp.\(UUID().uuidString)"
            guard fm.createFile(atPath: tempPath, contents: Data("not-a-timestamp".utf8)) else {
                return report(id, slug, false, "(failed to write the temp-file fixture)")
            }

            // A real marker for an unrelated hash, so `consume` has something
            // legitimate to do on the same call.
            let unrelated = String(repeating: "a", count: 64)
            CLIWriteMarker.note(contentHash: unrelated)

            // Look up a hash that was never noted — `consume` returns false,
            // but must still run its sweep pass over the directory.
            let neverNoted = String(repeating: "b", count: 64)
            guard CLIWriteMarker.consume(hash: neverNoted) == false else {
                return report(id, slug, false, "(consume matched a hash that was never noted)")
            }

            guard fm.fileExists(atPath: tempPath) else {
                return report(id, slug, false, "(consume deleted a non-hex-64-named file in the marker directory)")
            }
            guard CLIWriteMarker.consume(hash: unrelated) else {
                return report(id, slug, false, "(the unrelated real marker was not left intact/consumable)")
            }

            return report(id, slug, true)
        }
    }

    // MARK: - AC-L61-9 — install refreshes an already-loaded agent and cleans up a failed load

    /// limpet-plan.md L6.1 change B, code-review finding 4. Both halves use
    /// ONLY injected closures — `isLoadedCheck`/`unloadCommand`/`loadCommand`
    /// — never real `launchctl`.
    private static func testInstallRefreshesLoadedAgentAndCleansUpFailure() -> Bool {
        let id = "AC-L61-9", slug = "install-refreshes-loaded-agent-cleans-up-failure"
        let dir = "\(selfTestRoot)/ac-l61-9"
        try? FileManager.default.removeItem(atPath: dir)
        var profile = sampleProfile(name: "Reload", isEnabled: true)
        profile.localSyncPath = "\(dir)/local"
        try? FileManager.default.createDirectory(atPath: profile.localSyncPath, withIntermediateDirectories: true)

        // (a) Already loaded: install must unload BEFORE loading, so `load`
        // always starts fresh rather than being a no-op over a stale agent.
        var callOrder: [String] = []
        do {
            try SyncSetupService.shared.install(
                profile: profile, loadAgent: true,
                executablePath: "/Applications/limpet.app/Contents/MacOS/limpet",
                otherProfiles: [], isInstalled: { _ in false },
                loadCommand: { _ in callOrder.append("load"); return (output: "", exitCode: 0) },
                isLoadedCheck: { _ in true },
                unloadCommand: { _ in callOrder.append("unload"); return (output: "", exitCode: 0) })
        } catch {
            return report(id, slug, false, "(install threw unexpectedly: \(error))")
        }
        guard callOrder == ["unload", "load"] else {
            return report(id, slug, false, "(call order was \(callOrder), expected [unload, load])")
        }

        // Not loaded: no unload call at all.
        callOrder = []
        do {
            try SyncSetupService.shared.install(
                profile: profile, loadAgent: true,
                executablePath: "/Applications/limpet.app/Contents/MacOS/limpet",
                otherProfiles: [], isInstalled: { _ in false },
                loadCommand: { _ in callOrder.append("load"); return (output: "", exitCode: 0) },
                isLoadedCheck: { _ in false },
                unloadCommand: { _ in callOrder.append("unload"); return (output: "", exitCode: 0) })
        } catch {
            return report(id, slug, false, "(install threw unexpectedly: \(error))")
        }
        guard callOrder == ["load"] else {
            return report(id, slug, false, "(call order was \(callOrder), an unnecessary unload ran)")
        }

        // (b) A failed load must remove the plist it just wrote — otherwise
        // `agentInstalled`/`isInstalled` reports true with no agent actually
        // loaded, and the F6 overlap check would count it as a real opponent.
        // (a) above installed successfully, so a plist is on disk; remove it
        // to isolate this half's own fixture.
        try? FileManager.default.removeItem(atPath: profile.plistPath)
        do {
            try SyncSetupService.shared.install(
                profile: profile, loadAgent: true,
                executablePath: "/Applications/limpet.app/Contents/MacOS/limpet",
                otherProfiles: [], isInstalled: { _ in false },
                loadCommand: { _ in (output: "boom", exitCode: 1) },
                isLoadedCheck: { _ in false },
                unloadCommand: { _ in (output: "", exitCode: 0) })
            return report(id, slug, false, "(install did not throw on a failing load)")
        } catch SyncSetupService.SetupError.launchAgentLoadFailed {
            // expected
        } catch {
            return report(id, slug, false, "(threw the wrong error: \(error))")
        }
        guard FileManager.default.fileExists(atPath: profile.plistPath) == false else {
            return report(id, slug, false, "(the plist was left behind after a failed load)")
        }

        // (c) CodeRabbit PR #9: a loaded agent that fails to unload must not be
        // "replaced" by a load on top of it — install throws and never loads.
        callOrder = []
        do {
            try SyncSetupService.shared.install(
                profile: profile, loadAgent: true,
                executablePath: "/Applications/limpet.app/Contents/MacOS/limpet",
                otherProfiles: [], isInstalled: { _ in false },
                loadCommand: { _ in callOrder.append("load"); return (output: "", exitCode: 0) },
                isLoadedCheck: { _ in true },
                unloadCommand: { _ in callOrder.append("unload"); return (output: "busy", exitCode: 5) })
            return report(id, slug, false, "(install did not throw on a failing unload)")
        } catch SyncSetupService.SetupError.launchAgentUnloadFailed {
            // expected
        } catch {
            return report(id, slug, false, "(threw the wrong error on a failing unload: \(error))")
        }
        guard callOrder == ["unload"] else {
            return report(id, slug, false, "(call order after a failing unload was \(callOrder), expected [unload] only)")
        }

        return report(id, slug, true)
    }

    // MARK: - AC-L61-10 — a marker-hit CLI write, through the REAL ConfigFileWatcher event path

    /// limpet-plan.md L6.1 v3.1/v3.2 acceptance; verifier gap 1. AC-L61-1 and
    /// AC-L61-3/3b call `ConfigFileWatcher.classifyWrite` directly — a pure
    /// function M1 (`case .cliWrite: classify(...)` → `case .cliWrite:
    /// continue` inside `processChangedPaths`) never touches, so those tests
    /// cannot fail it. This test drives a REAL `ConfigFileWatcher` — real
    /// FSEvents, real debounce, real `processChangedPaths` dispatch — pointed
    /// at a temp directory under `LimpetPaths.home` (never the real
    /// `~/.config/limpet`), and its `onProfileChange` callback runs the SAME
    /// static dispatch `SyncManager.applyExternalProfileEdit`/
    /// `applyExternalProfileCreate` build from (`SyncManager.reconcileClosures`
    /// + `SyncManager.applyExternalEdit`/`applyExternalCreateIfNeeded`) against
    /// a REAL `ProfileStore` on that same temp directory — the fallback the
    /// plan names when wiring to the production `SyncManager` methods directly
    /// isn't possible headlessly (a full `SyncManager` starts its own
    /// `ConfigFileWatcher`/workspace observer/LogWatchers, which this
    /// codebase's self-tests deliberately avoid standing up — see the
    /// pre-existing comment on `AC-L5-2`).
    ///
    /// Real FSEvents delivery + debounce lands `processChangedPaths` on
    /// `DispatchQueue.main.async`; `ConfigSelfTest.run()` never spins the main
    /// run loop (self-test exits before `LimpetApp`'s SwiftUI run loop ever
    /// starts), so this test pumps it itself in short bursts
    /// (`pumpMainRunLoop`) until the callback fires or a timeout passes — the
    /// standard way to let real async delegate/closure callbacks run inside a
    /// synchronous test process.
    private static func testConfigFileWatcherRealDispatchOnCLIMarkerHit() -> Bool {
        let id = "AC-L61-10", slug = "config-file-watcher-real-dispatch-cli-marker-hit"
        let watchDir = "\(LimpetPaths.home)/ac-l61-10-watch"
        try? FileManager.default.removeItem(atPath: watchDir)
        guard (try? FileManager.default.createDirectory(
            atPath: watchDir, withIntermediateDirectories: true)) != nil else {
            return report(id, slug, false, "(failed to create the watch directory fixture)")
        }

        let store = ProfileStore(
            profilesDirectory: watchDir,
            defaults: UserDefaults(suiteName: "com.nanako.limpet.selftest.ac-l61-10.\(UUID().uuidString)")!)

        var setupInstallCalls = 0, setupUninstallCalls = 0
        var dispatchedCalls: [(path: String, suppressReconcile: Bool)] = []

        /// EXACTLY the dispatch `SyncManager.applyExternalProfileEdit`/
        /// `applyExternalProfileCreate` build — `reconcileClosures` decides
        /// which of the four closures run, `applyExternalEdit`/
        /// `applyExternalCreateIfNeeded` are the same static functions
        /// production calls. No test-local re-implementation of the SUPPRESS
        /// decision itself (that would just repeat AC-L61-3's mistake) — this
        /// test's only job is proving the REAL watcher reaches this code at
        /// all on a `.cliWrite`, which M1 breaks.
        let watcher = ConfigFileWatcher(
            watchedDirectory: watchDir,
            debounceInterval: 0.3,
            onProfileChange: { path, suppressReconcile in
                dispatchedCalls.append((path, suppressReconcile))
                guard let data = FileManager.default.contents(atPath: path) else { return }
                let (install, uninstall) = SyncManager.reconcileClosures(
                    suppressReconcile: suppressReconcile,
                    setupInstall: { _ in setupInstallCalls += 1 },
                    setupUninstall: { _ in setupUninstallCalls += 1 },
                    watchStart: { _ in }, watchStop: { _ in })
                let outcome = SyncManager.applyExternalEdit(
                    data: data, path: path,
                    known: { store.profile(for: $0) },
                    others: [], isInstalled: { _ in true },
                    persist: { store.update($0) },
                    install: install, uninstall: uninstall,
                    reportError: { _, _ in })
                if case .create(let decoded) = outcome {
                    _ = SyncManager.applyExternalCreateIfNeeded(
                        decoded: decoded, isKnownId: false, existing: [],
                        isInstalled: { _ in true },
                        persist: { store.add($0) },
                        install: { try? install($0) },
                        quarantine: { _ in })
                }
            },
            onSettingsChange: {})
        watcher.start()
        defer { watcher.stop() }

        /// Pumps the main run loop in short bursts until `condition` is true
        /// or `timeout` elapses — see the type doc for why this is needed at
        /// all (the self-test process never otherwise spins the main run loop).
        func pumpMainRunLoop(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            return condition()
        }

        /// Simulates a `limpet profile set`/`create` write: notes the marker
        /// for the exact bytes about to be written (at `CLIWriteMarker`'s
        /// AMBIENT `directory` — the real default, under this run's redirected
        /// `LimpetPaths.home`, exactly what the production CLI process would
        /// use; no `withDirectory` override needed or wanted here), THEN
        /// writes them — `LimpetCLI`'s `writeProfile` closure's exact order,
        /// through the SAME `ProfileStore.writeProfileFile`.
        func cliWrite(_ profile: SyncProfile) -> Bool {
            guard let data = ProfileStore.encodedProfileFileData(profile) else { return false }
            let hash = ConfigSelfWriteRegistry.hash(data)
            CLIWriteMarker.note(contentHash: hash)
            let ok = ProfileStore.writeProfileFile(profile, in: watchDir) != nil
            // Same one-entry undo AC-L61-3b documents: this self-test runs the
            // "CLI" write and the "app" watcher in ONE process, so
            // `writeProfileFile`'s OWN self-write registry note (correct
            // in production, where the CLI is a separate process with its own
            // registry) would otherwise mask this exact marker hit as a
            // same-process self-write instead.
            _ = ConfigSelfWriteRegistry.shared.consumeIfSelfWrite(contentHash: hash)
            return ok
        }

        // --- set on an existing id ---
        var existing = sampleProfile(name: "Existing")
        store.add(existing)  // a real app write: no marker, direct
        existing.name = "Existing renamed"
        guard cliWrite(existing) else {
            return report(id, slug, false, "(cliWrite of the update failed)")
        }
        guard pumpMainRunLoop(timeout: 5, until: { dispatchedCalls.count >= 1 }) else {
            return report(id, slug, false, "(the real watcher never dispatched the update within 5s)")
        }
        guard dispatchedCalls[0].suppressReconcile else {
            return report(id, slug, false, "(the update was dispatched with suppressReconcile=false)")
        }
        guard store.profile(for: existing.id)?.name == "Existing renamed" else {
            return report(id, slug, false, "(profileStore did not reflect the CLI update)")
        }

        // --- create with a new id ---
        let created = sampleProfile(name: "Created")
        guard cliWrite(created) else {
            return report(id, slug, false, "(cliWrite of the create failed)")
        }
        guard pumpMainRunLoop(timeout: 5, until: { dispatchedCalls.count >= 2 }) else {
            return report(id, slug, false, "(the real watcher never dispatched the create within 5s)")
        }
        guard dispatchedCalls[1].suppressReconcile else {
            return report(id, slug, false, "(the create was dispatched with suppressReconcile=false)")
        }
        guard store.profile(for: created.id) == created else {
            return report(id, slug, false, "(profileStore did not reflect the CLI create)")
        }

        guard setupInstallCalls == 0, setupUninstallCalls == 0 else {
            return report(
                id, slug, false,
                "(a marker hit ran a real SyncSetupService call: install=\(setupInstallCalls) uninstall=\(setupUninstallCalls))")
        }

        return report(id, slug, true)
    }

    // MARK: - AC-L62-1 — trash root derivation

    private static func testTrashRootDerivation() -> Bool {
        let id = "AC-L62-1", slug = "trash-root-derivation"
        var profile = sampleProfile()
        profile.rcloneRemote = "s4:"
        profile.remotePath = "nanako-mirror/Datarget"
        profile.trashDays = 14
        let megaSection = ["type": "s3", "provider": "Mega"]

        guard SyncSetupService.trashRoot(for: profile, remoteSection: megaSection)
                == "s4:nanako-mirror/.limpet-trash/Datarget" else {
            return report(id, slug, false, "(localToRemote Mega did not derive the expected root)")
        }

        var reverse = profile
        reverse.syncDirection = .remoteToLocal
        guard SyncSetupService.trashRoot(for: reverse, remoteSection: megaSection) == nil else {
            return report(id, slug, false, "(remoteToLocal derived a root)")
        }

        var versioned = profile
        versioned.rcloneRemote = "aws:"
        versioned.remoteVersioning = true
        guard SyncSetupService.trashRoot(for: versioned, remoteSection: ["type": "s3", "provider": "AWS"]) == nil else {
            return report(id, slug, false, "(a versioned remote derived a root)")
        }

        var bucketRoot = profile
        bucketRoot.remotePath = "Datarget"  // no parent
        guard SyncSetupService.trashRoot(for: bucketRoot, remoteSection: megaSection) == nil else {
            return report(id, slug, false, "(a bucket-root remotePath derived a root)")
        }

        var off = profile
        off.trashDays = 0
        guard SyncSetupService.trashRoot(for: off, remoteSection: megaSection) == nil else {
            return report(id, slug, false, "(trashDays=0 derived a root)")
        }

        // Wired into the derived config.
        let confPath = "\(selfTestRoot)/ac-l62-1-rclone.conf"
        try? "[s4]\ntype = s3\nprovider = Mega\n".write(toFile: confPath, atomically: true, encoding: .utf8)
        let service = RcloneConfigService(configPath: confPath)
        let json = SyncSetupService.shared.generateProfileConfig(for: profile, rcloneConfig: service)
        let dict = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        guard dict?["trashRoot"] as? String == "s4:nanako-mirror/.limpet-trash/Datarget",
              dict?["trashDays"] as? Int == 14 else {
            return report(id, slug, false, "(derived config missing trashRoot/trashDays: \(String(describing: dict)))")
        }

        // The script adds --backup-dir/--suffix iff a root was resolved.
        guard let withRoot = runScriptFixture(
            name: "ac-l62-1-with-root",
            overrides: ["trashRoot": "s4:nanako-mirror/.limpet-trash/Datarget", "trashDays": 14]),
            withRoot.argv.contains("--backup-dir"), withRoot.argv.contains("--suffix"),
            withRoot.argv.contains("--suffix-keep-extension") else {
            return report(id, slug, false, "(script did not add --backup-dir/--suffix with a trash root)")
        }
        guard let withoutRoot = runScriptFixture(name: "ac-l62-1-without-root", overrides: ["trashRoot": "", "trashDays": 14]),
              !withoutRoot.argv.contains("--backup-dir"), !withoutRoot.argv.contains("--suffix") else {
            return report(id, slug, false, "(script added --backup-dir with no trash root)")
        }

        return report(id, slug, true)
    }

    // MARK: - AC-L62-2 — trashDays change reinstalls

    private static func testTrashDaysChangeReinstalls() -> Bool {
        let id = "AC-L62-2", slug = "trash-days-change-reinstalls"
        let current = sampleProfile()
        var updated = current
        updated.trashDays = current.trashDays + 5
        let action = SyncManager.reconcileAction(from: current, to: updated)
        return report(id, slug, action == .reinstall, "(got \(action))")
    }

    // MARK: - AC-L62-3 — trash purge: strict dates, once per day, never under --dry-run

    private static func testTrashPurge() -> Bool {
        let id = "AC-L62-3", slug = "trash-purge-strict-dates-once-per-day"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let now = Date()
        let today = formatter.string(from: now)
        let within = formatter.string(from: Calendar.current.date(byAdding: .day, value: -5, to: now)!)
        let older = formatter.string(from: Calendar.current.date(byAdding: .day, value: -20, to: now)!)
        let trashRoot = "\(selfTestRoot)/ac-l62-3-trash"
        let purgedLog = "\(selfTestRoot)/ac-l62-3-purged.log"
        try? FileManager.default.removeItem(atPath: purgedLog)

        // "today", "within" cutoff, "older" than cutoff, an invalid-format
        // entry, a non-zero-padded date, a nested path lsf --dirs-only would
        // never show at the top level anyway (defense in depth), and an
        // OLD-but-not-exactly-formatted entry ("2020-01-01x/") that a regex
        // missing its `^…$` anchors would still purge (year 2020 sorts before
        // any cutoff derived from `now`, so a lax "contains a date" match
        // would trip on it even though a real `lsf --dirs-only` line would
        // never look like this).
        let stubBody = """
            if [ "$1" = "lsf" ]; then
                printf '%s/\\n' "\(today)" "\(within)" "\(older)"
                printf 'notadate/\\n2026-9-1/\\nx/2026-01-01/\\n2020-01-01x/\\n'
                exit 0
            fi
            if [ "$1" = "purge" ]; then
                for last in "$@"; do :; done  # the path is the last argument (L6.3 added stats flags before it)
                echo "$last" >> "\(purgedLog)"
                exit 0
            fi
            exit 0
            """
        guard let result = runScriptFixtureAppending(
            name: "ac-l62-3", overrides: ["trashRoot": trashRoot, "trashDays": 14], stubBody: stubBody) else {
            return report(id, slug, false, "(fixture setup failed)")
        }
        guard result.status == 0 else {
            return report(id, slug, false, "(script did not exit 0: \(result.status), log: \(result.log))")
        }
        let purged = (try? String(contentsOfFile: purgedLog, encoding: .utf8)) ?? ""
        guard purged.contains("\(trashRoot)/\(older)/"),
              !purged.contains("\(trashRoot)/\(today)/"),
              !purged.contains("\(trashRoot)/\(within)/"),
              !purged.contains("notadate"), !purged.contains("2026-9-1"),
              !purged.contains("x/2026-01-01"), !purged.contains("2020-01-01x") else {
            return report(id, slug, false, "(wrong purge set: \(purged))")
        }

        // Once per stamp day: a second run the same day makes no lsf/purge call.
        guard let second = runScriptFixtureAppending(
            name: "ac-l62-3", overrides: ["trashRoot": trashRoot, "trashDays": 14], stubBody: stubBody, reset: false),
              second.status == 0 else {
            return report(id, slug, false, "(second same-day run failed)")
        }
        guard !second.invocations.contains(where: { $0.first == "lsf" || $0.first == "purge" }) else {
            return report(id, slug, false, "(a second same-day run purged again: \(second.invocations))")
        }

        // Never under --dry-run.
        guard let dryRun = runScriptFixtureAppending(
            name: "ac-l62-3-dry", overrides: ["trashRoot": trashRoot, "trashDays": 14, "additionalFlags": "--dry-run"],
            stubBody: stubBody),
              dryRun.status == 0 else {
            return report(id, slug, false, "(--dry-run fixture failed)")
        }
        guard !dryRun.invocations.contains(where: { $0.first == "lsf" || $0.first == "purge" }) else {
            return report(id, slug, false, "(purge ran under --dry-run: \(dryRun.invocations))")
        }

        return report(id, slug, true)
    }

    // MARK: - AC-L62-4 — exit 76 on overwrites OR deletes hitting --max-delete (S4 path, real rclone)

    /// Real local rclone with `--disable Move` (measured 2026-09-28): forces
    /// the Copy+Delete fallback S4 uses (S4 has no server-side Move), so a
    /// LOCAL backend reproduces the exact log lines measured live on S4.
    /// Never touches a remote or the network — both sides are local
    /// directories under `selfTestRoot`, and `RCLONE_CONFIG=/dev/null`.
    private static func testTrashExitSeventySix() -> Bool {
        let id = "AC-L62-4", slug = "trash-exit-76-overwrites-and-deletes"
        guard let rclonePath = RcloneLocator.resolve() else {
            return report(id, slug, true, "(skipped: no local rclone binary found)")
        }

        func run(name: String, files: [String: String], overrides: [String: Any]) -> (status: Int32, log: String)? {
            let fm = FileManager.default
            let root = "\(selfTestRoot)/\(name)"
            let localPath = "\(root)/source"
            let remotePath = "\(root)/dest"
            let scriptPath = "\(root)/limpet-sync.sh"
            let configPath = "\(root)/profile.json"
            let filterPath = "\(root)/exclude.txt"
            let logPath = "\(root)/sync.log"
            var config: [String: Any] = [
                "remote": remotePath, "localPath": localPath, "logPath": logPath,
                "lockFile": "\(root)/sync.lock", "drivePath": "", "additionalFlags": "",
                "filterPath": filterPath, "syncDirection": "localToRemote",
                "remotePath": "SelfTest", "transfers": 4,
                "trashRoot": "\(root)/trash", "trashDays": 14,
            ]
            config.merge(overrides) { _, new in new }
            do {
                try fm.createDirectory(atPath: localPath, withIntermediateDirectories: true)
                try fm.createDirectory(atPath: remotePath, withIntermediateDirectories: true)
                if !fm.fileExists(atPath: filterPath) {
                    try "".write(toFile: filterPath, atomically: true, encoding: .utf8)
                }
                try SyncSetupService.shared.generateSyncScript().write(toFile: scriptPath, atomically: true, encoding: .utf8)
                for (rel, content) in files {
                    try content.write(toFile: "\(localPath)/\(rel)", atomically: true, encoding: .utf8)
                }
                try JSONSerialization.data(withJSONObject: config).write(to: URL(fileURLWithPath: configPath))
            } catch {
                return nil
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptPath, configPath]
            var env = ProcessInfo.processInfo.environment
            env["RCLONE_BIN"] = rclonePath
            env["RCLONE_CONFIG"] = "/dev/null"
            env["HOME"] = LimpetPaths.home
            process.environment = env
            process.standardError = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            process.waitUntilExit()
            let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
            return (process.terminationStatus, log)
        }

        // Overwrites: trips on "Cancelling sync due to fatal error: --max-delete
        // threshold reached" — no "Got fatal error on delete" line at all.
        guard let seedOv = run(name: "ac-l62-4-ov", files: ["o1.txt": "v1", "o2.txt": "v1", "o3.txt": "v1"], overrides: [:]),
              seedOv.status == 0 else {
            return report(id, slug, false, "(overwrite seed sync failed)")
        }
        guard let overwritten = run(
            name: "ac-l62-4-ov", files: ["o1.txt": "v2", "o2.txt": "v2", "o3.txt": "v2"],
            overrides: ["maxDelete": 2, "additionalFlags": "--disable Move"]) else {
            return report(id, slug, false, "(overwrite run failed to execute)")
        }
        guard overwritten.status == 76 else {
            return report(id, slug, false, "(overwrite: expected exit 76, got \(overwritten.status): \(overwritten.log))")
        }

        // Deletes: trips on "Got fatal error on delete: --max-delete threshold reached".
        guard let seedDel = run(name: "ac-l62-4-del", files: ["d1.txt": "v1", "d2.txt": "v1", "d3.txt": "v1"], overrides: [:]),
              seedDel.status == 0 else {
            return report(id, slug, false, "(delete seed sync failed)")
        }
        for f in ["d1.txt", "d2.txt", "d3.txt"] {
            try? FileManager.default.removeItem(atPath: "\(selfTestRoot)/ac-l62-4-del/source/\(f)")
        }
        guard let deleted = run(
            name: "ac-l62-4-del", files: [:], overrides: ["maxDelete": 2, "additionalFlags": "--disable Move"]) else {
            return report(id, slug, false, "(delete run failed to execute)")
        }
        guard deleted.status == 76 else {
            return report(id, slug, false, "(delete: expected exit 76, got \(deleted.status): \(deleted.log))")
        }

        return report(id, slug, true)
    }

    // MARK: - AC-L62-5 — backup naming (real rclone) + restore matching

    private static func testTrashBackupNamingAndRestore() -> Bool {
        let id = "AC-L62-5", slug = "trash-backup-naming-and-restore"
        guard let rclonePath = RcloneLocator.resolve() else {
            return report(id, slug, true, "(skipped: no local rclone binary found)")
        }
        let root = "\(selfTestRoot)/ac-l62-5"
        try? FileManager.default.removeItem(atPath: root)
        let src = "\(root)/src", dst = "\(root)/dst", trash = "\(root)/trash"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HHmmss"

        func sync() -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: rclonePath)
            process.arguments = [
                "sync", src, dst, "--config", "/dev/null", "--links", "--disable", "Move",
                "--backup-dir", "\(trash)/\(formatter.string(from: Date()))",
                "--suffix", "-\(timeFormatter.string(from: Date()))", "--suffix-keep-extension",
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return -1 }
            process.waitUntilExit()
            return process.terminationStatus
        }

        do {
            try FileManager.default.createDirectory(atPath: src, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: dst, withIntermediateDirectories: true)
            try "v1".write(toFile: "\(src)/a.tar.gz", atomically: true, encoding: .utf8)
            try "v1".write(toFile: "\(src)/.env", atomically: true, encoding: .utf8)
            try "v1".write(toFile: "\(src)/Makefile", atomically: true, encoding: .utf8)
            try "v1".write(toFile: "\(src)/x.min.js", atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(atPath: "\(src)/l.txt", withDestinationPath: "a.tar.gz")
        } catch {
            return report(id, slug, false, "(fixture setup failed)")
        }
        guard sync() == 0 else { return report(id, slug, false, "(seed sync failed)") }

        Thread.sleep(forTimeInterval: 1.1)  // distinct HHMMSS suffix from the seed
        do {
            try "v2".write(toFile: "\(src)/a.tar.gz", atomically: true, encoding: .utf8)
            try "v2".write(toFile: "\(src)/.env", atomically: true, encoding: .utf8)
            try "v2".write(toFile: "\(src)/Makefile", atomically: true, encoding: .utf8)
            try "v2".write(toFile: "\(src)/x.min.js", atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(atPath: "\(src)/l.txt")  // deleted, not overwritten
        } catch {
            return report(id, slug, false, "(overwrite/delete setup failed)")
        }
        guard sync() == 0 else { return report(id, slug, false, "(second sync failed)") }

        let today = formatter.string(from: Date())
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "\(trash)/\(today)") else {
            return report(id, slug, false, "(no backups landed under \(trash)/\(today))")
        }
        let listing = entries.map { "\(today)/\($0)" }.joined(separator: "\n")

        for baseName in ["a.tar.gz", ".env", "Makefile", "x.min.js", "l.txt"] {
            guard let match = LimpetCLI.newestTrashMatch(listing: listing, dateFixed: nil, dirComponent: "", baseName: baseName) else {
                return report(id, slug, false, "(no match found for \(baseName) in: \(listing))")
            }
            let matchedPath = "\(trash)/\(match.date)/\((match.entry as NSString).lastPathComponent)"
            guard FileManager.default.fileExists(atPath: matchedPath)
                    || (try? FileManager.default.destinationOfSymbolicLink(atPath: matchedPath)) != nil else {
                return report(id, slug, false, "(matched path missing on disk: \(matchedPath))")
            }
            if baseName == "l.txt" {
                guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: matchedPath), dest == "a.tar.gz" else {
                    return report(id, slug, false, "(restored symlink target wrong: \(matchedPath))")
                }
            }
        }

        // A mutation back to a stem/ext split (only the LAST dot) must fail
        // this for the compound-extension case: measured `a.tar.gz` splits at
        // the FIRST dot -> `a-100003.tar.gz`.
        guard LimpetCLI.trashSuffixMatch(candidate: "a-100003.tar.gz", original: "a.tar.gz") != nil else {
            return report(id, slug, false, "(trashSuffixMatch regressed on a compound extension)")
        }

        return report(id, slug, true)
    }

    // MARK: - AC-L62-6 — trash restore validation + newest-version selection

    private static func testTrashRestoreValidationAndNewestMatch() -> Bool {
        let id = "AC-L62-6", slug = "trash-restore-validation-and-newest-match"

        for bad in ["", "/etc/x", "../x", "a/../../x", "a/b/..", "a/./b"] {
            guard LimpetCLI.validateTrashRelativePath(bad) != nil else {
                return report(id, slug, false, "(accepted invalid path \"\(bad)\")")
            }
        }
        guard LimpetCLI.validateTrashRelativePath("a/b.txt") == nil else {
            return report(id, slug, false, "(rejected a valid relative path)")
        }
        for badDate in ["../x", "2026-1-1", "2026/01/01", "20260101", "2026-01-01x"] {
            guard LimpetCLI.validateTrashDate(badDate) != nil else {
                return report(id, slug, false, "(accepted invalid --date \"\(badDate)\")")
            }
        }
        guard LimpetCLI.validateTrashDate("2026-01-01") == nil, LimpetCLI.validateTrashDate(nil) == nil else {
            return report(id, slug, false, "(rejected a valid date or nil)")
        }

        // Parse coverage.
        guard case .success(.trashList(target: "p", date: nil)) = LimpetCLI.parse(["trash", "list", "p"]),
              case .success(.trashList(target: "p", date: "2026-01-01")) =
                LimpetCLI.parse(["trash", "list", "p", "--date", "2026-01-01"]),
              case .success(.trashRestore(target: "p", relativePath: "a/b.txt", date: nil, force: true)) =
                LimpetCLI.parse(["trash", "restore", "p", "a/b.txt", "--force"]) else {
            return report(id, slug, false, "(trash list/restore did not parse)")
        }

        // Refused BEFORE any rclone call.
        let profile = sampleProfile()
        var ran = 0
        let refusalEnv = fakeCLIEnvironment(runRclone: { _, _, _ in ran += 1; return (0, "", "") }, readProfiles: { [profile] })
        for argv in [
            ["trash", "restore", profile.shortId, "../x"],
            ["trash", "restore", profile.shortId, "a/b", "--date", "2026-1-1"],
            ["trash", "list", profile.shortId, "--date", "bad"],
        ] {
            let code = LimpetCLI.execute(argv, env: refusalEnv)
            guard code == 65 else {
                return report(id, slug, false, "(\(argv) did not exit 65, got \(code))")
            }
        }
        guard ran == 0 else {
            return report(id, slug, false, "(a refused path/date still called rclone \(ran) time(s))")
        }

        // Overwrite refused without --force, no rclone call either.
        var restoreProfile = profile
        restoreProfile.rcloneRemote = "s4:"
        restoreProfile.remotePath = "nanako-mirror/Datarget"
        restoreProfile.localSyncPath = "\(selfTestRoot)/ac-l62-6-local"
        var overwriteCalls = 0
        let overwriteEnv = fakeCLIEnvironment(
            runRclone: { _, _, _ in overwriteCalls += 1; return (0, "", "") },
            readProfiles: { [restoreProfile] },
            fileExists: { $0 == "\(restoreProfile.localSyncPath)/x.txt" },
            remoteSection: { _ in ["type": "s3", "provider": "Mega"] })
        let overwriteCode = LimpetCLI.execute(["trash", "restore", restoreProfile.shortId, "x.txt"], env: overwriteEnv)
        guard overwriteCode == 1, overwriteCalls == 0 else {
            return report(id, slug, false, "(an existing local file was restored without --force)")
        }

        // No trash root configured -> no rclone call, exit non-zero for restore.
        var noTrash = profile
        let noTrashEnv = fakeCLIEnvironment(readProfiles: { [noTrash] }, remoteSection: { _ in nil })
        guard LimpetCLI.execute(["trash", "restore", noTrash.shortId, "x.txt"], env: noTrashEnv) != 0 else {
            return report(id, slug, false, "(restore succeeded with no trash root configured)")
        }
        _ = noTrash  // silence "never mutated" warning if any

        // Newest-version selection over a fixture listing (pure).
        let listing = "2026-09-20/a-100000.txt\n2026-09-26/a-100500.txt\n2026-09-26/a-090000.txt\n2026-09-26/other.txt\n"
        guard let match = LimpetCLI.newestTrashMatch(listing: listing, dateFixed: nil, dirComponent: "", baseName: "a.txt") else {
            return report(id, slug, false, "(no match on fixture listing)")
        }
        guard match.date == "2026-09-26", match.entry == "2026-09-26/a-100500.txt" else {
            return report(id, slug, false, "(wrong newest match: \(match))")
        }
        // A fixed --date restricts to that date's own (unprefixed) listing.
        guard let fixedMatch = LimpetCLI.newestTrashMatch(
            listing: "a-090000.txt\na-100500.txt\n", dateFixed: "2026-09-20", dirComponent: "", baseName: "a.txt"),
              fixedMatch.date == "2026-09-20", fixedMatch.entry == "a-100500.txt" else {
            return report(id, slug, false, "(fixed-date listing did not select the highest suffix)")
        }

        return report(id, slug, true)
    }

    // MARK: - AC-L62-8 — trash list/restore ignore trashDays/direction/versioning
    // (code-review finding 4 on 87bbf67): they keep working after trash was
    // switched off or the profile's direction/versioning changed.

    private static func testTrashCommandsUsePathFormulaIgnoringActiveRule() -> Bool {
        let id = "AC-L62-8", slug = "trash-commands-ignore-active-rule"

        var profile = sampleProfile()
        profile.rcloneRemote = "s4:"
        profile.remotePath = "nanako-mirror/Datarget"

        // trashRootPath (the CLI's root) ignores every "is trash ACTIVE" input.
        let expected = "s4:nanako-mirror/.limpet-trash/Datarget"
        guard SyncSetupService.trashRootPath(for: profile) == expected else {
            return report(id, slug, false, "(trashRootPath wrong for the base case)")
        }
        var trashOff = profile
        trashOff.trashDays = 0
        var reversed = profile
        reversed.syncDirection = .remoteToLocal
        // AWS (unlike MEGA/Cloudflare) DOES respect remoteVersioning — MEGA
        // S4 has no versioning at all regardless of the flag, so testing the
        // versioning-off-switch needs a provider where it actually matters.
        var versioned = profile
        versioned.rcloneRemote = "aws:"
        versioned.remoteVersioning = true
        let versionedRootExpected = "aws:nanako-mirror/.limpet-trash/Datarget"

        for candidate in [trashOff, reversed] {
            guard SyncSetupService.trashRootPath(for: candidate) == expected else {
                return report(id, slug, false, "(trashRootPath changed when trashDays/direction did)")
            }
            // trashRoot (the sync/purge root) DOES apply the active-trash rule
            // — this is the contrast finding 4 is about.
            guard SyncSetupService.trashRoot(for: candidate, remoteSection: ["type": "s3", "provider": "Mega"]) == nil else {
                return report(id, slug, false, "(trashRoot stayed active when it should not have)")
            }
        }
        guard SyncSetupService.trashRootPath(for: versioned) == versionedRootExpected else {
            return report(id, slug, false, "(trashRootPath changed when remoteVersioning did)")
        }
        guard SyncSetupService.trashRoot(for: versioned, remoteSection: ["type": "s3", "provider": "AWS"]) == nil else {
            return report(id, slug, false, "(trashRoot stayed active for a versioned AWS remote)")
        }
        // A bucket-root remotePath has no parent either way — both nil.
        var bucketRoot = profile
        bucketRoot.remotePath = "Datarget"
        guard SyncSetupService.trashRootPath(for: bucketRoot) == nil,
              SyncSetupService.trashRoot(for: bucketRoot, remoteSection: ["type": "s3", "provider": "Mega"]) == nil else {
            return report(id, slug, false, "(a bucket-root remotePath produced a root)")
        }

        // The CLI: `trash list`/`trash restore` succeed in reaching rclone for
        // a profile whose trash is currently OFF (trashDays = 0) — the OLD
        // code (which called `trashRoot`, layering the active-trash checks on
        // top) would have refused before ever calling rclone.
        var listArgs: [String] = []
        let env = fakeCLIEnvironment(
            runRclone: { args, _, _ in listArgs = args; return (0, "2026-09-01/old.txt\n", "") },
            readProfiles: { [trashOff] })
        guard LimpetCLI.execute(["trash", "list", trashOff.shortId], env: env) == 0,
              listArgs.contains(expected) else {
            return report(id, slug, false, "(trash list refused a profile whose trash is currently off)")
        }

        return report(id, slug, true)
    }

    /// Real rclone against a self-test-owned `type = local` config, run with
    /// its CWD at `dataDir` so `selftest:<path>` resolves under it (shared by
    /// AC-L62-9 and AC-L62-11; never a network remote).
    private static func localRcloneRunner(rclonePath: String, confPath: String, dataDir: String)
        -> (_ args: [String], _ remote: String?, _ timeout: TimeInterval) -> (Int32, String, String) {
        return { args, _, _ in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: rclonePath)
            process.arguments = ["--config", confPath] + args
            process.currentDirectoryURL = URL(fileURLWithPath: dataDir)
            let outPipe = Pipe(), errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            guard (try? process.run()) != nil else { return (-1, "", "") }
            process.waitUntilExit()
            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (process.terminationStatus, out, err)
        }
    }

    // MARK: - AC-L62-11 — trash restore never writes through a symlink
    // (CodeRabbit, PR #10): a symlinked subdirectory pointing outside
    // `localSyncPath` is refused before any rclone call; a symlink AT the
    // destination is never followed (refused without --force, the link itself
    // replaced with it); a normal nested path and a symlinked `localSyncPath`
    // still restore. Real rclone, real symlinks, all under `selfTestRoot`.

    private static func testTrashRestoreSymlinkContainment() -> Bool {
        let id = "AC-L62-11", slug = "trash-restore-symlink-containment"
        guard let rclonePath = RcloneLocator.resolve() else {
            return report(id, slug, true, "(skipped: no local rclone binary found)")
        }
        let fm = FileManager.default
        let root = "\(selfTestRoot)/ac-l62-11"
        try? fm.removeItem(atPath: root)
        let localDir = "\(root)/local", outsideDir = "\(root)/outside", dataDir = "\(root)/data"
        let trashDateDir = "\(dataDir)/parent/.limpet-trash/leaf/2026-09-01"
        let confPath = "\(root)/rclone.conf"
        do {
            for dir in ["\(localDir)/nested", outsideDir, "\(trashDateDir)/sub", "\(trashDateDir)/nested/deep"] {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            try "trashed-sub".write(toFile: "\(trashDateDir)/sub/file-100000.txt", atomically: true, encoding: .utf8)
            try "trashed-nested".write(toFile: "\(trashDateDir)/nested/deep/n-100000.txt", atomically: true, encoding: .utf8)
            try "trashed-link".write(toFile: "\(trashDateDir)/link-100000.txt", atomically: true, encoding: .utf8)
            try "trashed-dangling".write(toFile: "\(trashDateDir)/dangling-100000.txt", atomically: true, encoding: .utf8)
            try "outside-original".write(toFile: "\(outsideDir)/target.txt", atomically: true, encoding: .utf8)
            try fm.createSymbolicLink(atPath: "\(localDir)/sub", withDestinationPath: outsideDir)
            try fm.createSymbolicLink(atPath: "\(localDir)/dsub", withDestinationPath: "\(outsideDir)/no-such-dir")
            try fm.createSymbolicLink(atPath: "\(localDir)/link.txt", withDestinationPath: "\(outsideDir)/target.txt")
            try fm.createSymbolicLink(atPath: "\(localDir)/dangling.txt", withDestinationPath: "\(outsideDir)/nowhere.txt")
            try fm.createSymbolicLink(atPath: "\(root)/local-alias", withDestinationPath: localDir)
            try "[selftest]\ntype = local\n".write(toFile: confPath, atomically: true, encoding: .utf8)
        } catch {
            return report(id, slug, false, "(fixture setup failed: \(error))")
        }

        var profile = sampleProfile()
        profile.rcloneRemote = "selftest:"
        profile.remotePath = "parent/leaf"
        profile.localSyncPath = localDir
        var aliased = profile
        aliased.localSyncPath = "\(root)/local-alias"

        let realRclone = localRcloneRunner(rclonePath: rclonePath, confPath: confPath, dataDir: dataDir)
        var rcloneCalls = 0
        func env(_ p: SyncProfile) -> CLIEnvironment {
            fakeCLIEnvironment(
                runRclone: { args, remote, timeout in rcloneCalls += 1; return realRclone(args, remote, timeout) },
                readProfiles: { [p] },
                fileExists: { fm.fileExists(atPath: $0) },
                itemExists: CLIEnvironment.lstatExists,
                realPath: CLIEnvironment.resolvedRealPath,
                removeFile: { (try? fm.removeItem(atPath: $0)) != nil },
                moveFile: { f, t, r in r ? CLIEnvironment.moveReplacing(f, t) : CLIEnvironment.moveNoReplace(f, t) })
        }
        func outsideUntouched() -> Bool {
            (try? fm.contentsOfDirectory(atPath: outsideDir)) == ["target.txt"]
                && (try? String(contentsOfFile: "\(outsideDir)/target.txt", encoding: .utf8)) == "outside-original"
        }
        func isLink(_ path: String) -> Bool { (try? fm.destinationOfSymbolicLink(atPath: path)) != nil }

        // A symlinked subdirectory (existing or dangling) pointing outside:
        // exit 65, with or without --force, before any rclone call.
        for argv in [["sub/file.txt"], ["sub/file.txt", "--force"], ["sub/new/file.txt"], ["dsub/x.txt"]] {
            let code = LimpetCLI.execute(["trash", "restore", profile.shortId] + argv, env: env(profile))
            guard code == 65, rcloneCalls == 0, outsideUntouched() else {
                return report(id, slug, false,
                    "(\(argv) through a symlinked dir: exit \(code), rclone calls \(rcloneCalls), outside untouched \(outsideUntouched()))")
            }
        }

        // A symlink AT the destination, without --force: refused like any
        // existing entry (a dangling one too), no rclone call, link intact.
        for name in ["link.txt", "dangling.txt"] {
            let code = LimpetCLI.execute(["trash", "restore", profile.shortId, name], env: env(profile))
            guard code == 1, rcloneCalls == 0, isLink("\(localDir)/\(name)"), outsideUntouched() else {
                return report(id, slug, false, "(\(name) symlink destination without --force: exit \(code), rclone calls \(rcloneCalls))")
            }
        }

        // With --force: the LINK itself is replaced by a regular file; its
        // target is never written.
        for name in ["link.txt", "dangling.txt"] {
            let code = LimpetCLI.execute(["trash", "restore", profile.shortId, name, "--force"], env: env(profile))
            let stem = (name as NSString).deletingPathExtension
            guard code == 0, !isLink("\(localDir)/\(name)"),
                  (try? String(contentsOfFile: "\(localDir)/\(name)", encoding: .utf8)) == "trashed-\(stem)",
                  outsideUntouched() else {
                return report(id, slug, false, "(\(name) symlink destination with --force: exit \(code), outside untouched \(outsideUntouched()))")
            }
        }

        // A normal nested path (with a not-yet-existing directory) restores.
        let nestedCode = LimpetCLI.execute(["trash", "restore", profile.shortId, "nested/deep/n.txt"], env: env(profile))
        guard nestedCode == 0,
              (try? String(contentsOfFile: "\(localDir)/nested/deep/n.txt", encoding: .utf8)) == "trashed-nested" else {
            return report(id, slug, false, "(normal nested restore failed: exit \(nestedCode))")
        }

        // A localSyncPath that is ITSELF a symlink is legitimate: the root is
        // resolved too, so its own files are inside.
        let aliasCode = LimpetCLI.execute(["trash", "restore", aliased.shortId, "nested/deep/n.txt", "--force"], env: env(aliased))
        guard aliasCode == 0 else {
            return report(id, slug, false, "(restore under a symlinked localSyncPath refused: exit \(aliasCode))")
        }

        return report(id, slug, true)
    }

    // MARK: - AC-L62-12 — a forced restore whose final move fails leaves the
    // existing file untouched (CodeRabbit, PR #10: remove-then-move lost both).

    private static func testForcedRestoreReplaceIsAtomic() -> Bool {
        let id = "AC-L62-12", slug = "forced-restore-replace-atomic"
        let fm = FileManager.default
        let root = "\(selfTestRoot)/ac-l62-12"
        try? fm.removeItem(atPath: root)
        let localDir = "\(root)/local"
        do {
            try fm.createDirectory(atPath: "\(localDir)/dir/child", withIntermediateDirectories: true)
            try "original".write(toFile: "\(localDir)/a.txt", atomically: true, encoding: .utf8)
        } catch {
            return report(id, slug, false, "(fixture setup failed)")
        }
        var profile = sampleProfile()
        profile.rcloneRemote = "s4:"
        profile.remotePath = "nanako-mirror/Datarget"
        profile.localSyncPath = localDir
        func content(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

        // `copyto` is faked: `writeTemp` decides whether it actually leaves the
        // temp file. Reporting success WITHOUT writing it makes the final move
        // fail after the copy "succeeded" — the exact failure the old
        // remove-then-move turned into losing the existing file.
        var writeTemp = false
        // CodeRabbit PR #10: another process creating the target after the
        // existence check, i.e. while the copy runs.
        var createDuringCopy: String?
        let env = fakeCLIEnvironment(
            runRclone: { args, _, _ in
                if args.first == "lsf" { return (0, "2026-09-01/a-100000.txt\n2026-09-01/b-100000.txt\n", "") }
                if args.first == "copyto", writeTemp, let dest = args.last {
                    try? "restored".write(toFile: String(dest.dropFirst(":local,links:".count)), atomically: true, encoding: .utf8)
                }
                if args.first == "copyto", let late = createDuringCopy {
                    try? "late".write(toFile: late, atomically: true, encoding: .utf8)
                }
                return (0, "", "")
            },
            readProfiles: { [profile] },
            itemExists: CLIEnvironment.lstatExists,
            realPath: CLIEnvironment.resolvedRealPath,
            removeFile: { (try? fm.removeItem(atPath: $0)) != nil },
            moveFile: { f, t, r in r ? CLIEnvironment.moveReplacing(f, t) : CLIEnvironment.moveNoReplace(f, t) })

        let failCode = LimpetCLI.execute(["trash", "restore", profile.shortId, "a.txt", "--force"], env: env)
        guard failCode == 1, content("\(localDir)/a.txt") == "original" else {
            return report(id, slug, false, "(a failed final move lost or altered the existing file: exit \(failCode))")
        }
        writeTemp = true
        let okCode = LimpetCLI.execute(["trash", "restore", profile.shortId, "a.txt", "--force"], env: env)
        guard okCode == 0, content("\(localDir)/a.txt") == "restored",
              !fm.fileExists(atPath: "\(localDir)/a.txt.limpet-restore-tmp") else {
            return report(id, slug, false, "(forced restore did not replace the existing file: exit \(okCode))")
        }

        // Without --force the final move never replaces, even an item that
        // appeared after the existence check (CodeRabbit, PR #10).
        createDuringCopy = "\(localDir)/b.txt"
        let raceCode = LimpetCLI.execute(["trash", "restore", profile.shortId, "b.txt"], env: env)
        createDuringCopy = nil
        guard raceCode == 1, content("\(localDir)/b.txt") == "late",
              !fm.fileExists(atPath: "\(localDir)/b.txt.limpet-restore-tmp") else {
            return report(id, slug, false, "(a non-force restore replaced a file created during the copy: exit \(raceCode), b.txt=\(content("\(localDir)/b.txt") ?? "nil"))")
        }

        // An existing item at the temp path is never deleted, even with
        // --force (CodeRabbit, PR #10).
        try? "mine".write(toFile: "\(localDir)/a.txt.limpet-restore-tmp", atomically: true, encoding: .utf8)
        let tempCode = LimpetCLI.execute(["trash", "restore", profile.shortId, "a.txt", "--force"], env: env)
        guard tempCode == 1, content("\(localDir)/a.txt.limpet-restore-tmp") == "mine" else {
            return report(id, slug, false, "(an existing temp-path file was deleted or overwritten: exit \(tempCode))")
        }
        try? fm.removeItem(atPath: "\(localDir)/a.txt.limpet-restore-tmp")

        // A non-empty directory in the way: refused, directory intact (the
        // old removeItem deleted it recursively, then "succeeded").
        try? "x".write(toFile: "\(root)/tmp-file", atomically: true, encoding: .utf8)
        guard !CLIEnvironment.moveReplacing("\(root)/tmp-file", "\(localDir)/dir"),
              fm.fileExists(atPath: "\(localDir)/dir/child") else {
            return report(id, slug, false, "(a file replaced a non-empty directory)")
        }

        return report(id, slug, true)
    }

    // MARK: - AC-L62-9 — restore a `.rclonelink` object as a real symlink;
    // atomic temp-then-rename leaves nothing partial on failure (code-review
    // findings 2/3 on 87bbf67), via the REAL `LimpetCLI.execute` entry point
    // against a real local rclone `type = local` pseudo-remote (never a
    // network remote — a self-test-owned throwaway config under selfTestRoot,
    // the standard way to address a local directory through the
    // `<remote>:<path>` shape `trashRootPath` always produces).

    private static func testTrashRestoreRclonelinkSymlinkAndAtomicRename() -> Bool {
        let id = "AC-L62-9", slug = "trash-restore-rclonelink-symlink-atomic-rename"
        guard let rclonePath = RcloneLocator.resolve() else {
            return report(id, slug, true, "(skipped: no local rclone binary found)")
        }

        let root = "\(selfTestRoot)/ac-l62-9"
        try? FileManager.default.removeItem(atPath: root)
        let localDir = "\(root)/local"
        let dataDir = "\(root)/data"
        let trashDateDir = "\(dataDir)/parent/.limpet-trash/leaf/2026-09-01"
        let confPath = "\(root)/rclone.conf"
        do {
            try FileManager.default.createDirectory(atPath: localDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: trashDateDir, withIntermediateDirectories: true)
            try "hello".write(toFile: "\(trashDateDir)/a-100000.tar.gz", atomically: true, encoding: .utf8)
            // A symlink stored as a `.rclonelink` CONTENT object — measured
            // 2026-09-28: this is how a remote without native symlink support
            // (S3/B2) represents one; the object's BYTES are the link target
            // text, not an actual on-disk symlink.
            try "a.tar.gz".write(toFile: "\(trashDateDir)/l-100000.txt.rclonelink", atomically: true, encoding: .utf8)
            try "[selftest]\ntype = local\n".write(toFile: confPath, atomically: true, encoding: .utf8)
        } catch {
            return report(id, slug, false, "(fixture setup failed)")
        }

        var profile = sampleProfile()
        // `remotePath` matches production's cloud-relative shape (no leading
        // slash); the real directory is reached by running rclone with its
        // CWD set to `dataDir`, exactly like a real local backend resolves a
        // relative path — measured 2026-09-28:
        //   cd <dataDir> && rclone --config <conf> lsf -R selftest:parent/.limpet-trash/leaf
        //   -> lists 2026-09-01/, 2026-09-01/a-100000.tar.gz
        profile.rcloneRemote = "selftest:"
        profile.remotePath = "parent/leaf"
        profile.localSyncPath = localDir

        let realRclone = localRcloneRunner(rclonePath: rclonePath, confPath: confPath, dataDir: dataDir)
        let moveFile: (String, String, Bool) -> Bool = { f, t, r in r ? CLIEnvironment.moveReplacing(f, t) : CLIEnvironment.moveNoReplace(f, t) }
        let env = fakeCLIEnvironment(
            runRclone: realRclone,
            readProfiles: { [profile] },
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            removeFile: { (try? FileManager.default.removeItem(atPath: $0)) != nil },
            moveFile: moveFile)

        // Plain-file restore.
        let plainCode = LimpetCLI.execute(["trash", "restore", profile.shortId, "a.tar.gz"], env: env)
        guard plainCode == 0,
              let plainContent = try? String(contentsOfFile: "\(localDir)/a.tar.gz", encoding: .utf8),
              plainContent == "hello" else {
            return report(id, slug, false, "(plain restore failed: exit \(plainCode))")
        }
        guard !FileManager.default.fileExists(atPath: "\(localDir)/a.tar.gz.limpet-restore-tmp") else {
            return report(id, slug, false, "(temp restore file left behind after a plain success)")
        }

        // Symlink restore FROM THE .rclonelink OBJECT FORM — must land as a
        // real local symlink, not a regular file containing "a.tar.gz" as text.
        let linkCode = LimpetCLI.execute(["trash", "restore", profile.shortId, "l.txt"], env: env)
        guard linkCode == 0 else {
            return report(id, slug, false, "(symlink restore failed: exit \(linkCode))")
        }
        let restoredLinkPath = "\(localDir)/l.txt"
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: restoredLinkPath), target == "a.tar.gz" else {
            return report(id, slug, false, "(l.txt was not restored as a real symlink to a.tar.gz)")
        }
        guard !FileManager.default.fileExists(atPath: "\(restoredLinkPath).limpet-restore-tmp") else {
            return report(id, slug, false, "(temp restore file left behind after a symlink success)")
        }

        // Atomic temp-then-rename: an INDUCED copyto failure (a valid match is
        // found — sourcePath is legitimate — but the copy itself is made to
        // fail) must never move anything into place and must never leave a
        // temp file behind.
        var copytoCalls = 0
        var moveCalls = 0
        func failingCopytoRclone(_ args: [String], _ remote: String?, _ timeout: TimeInterval) -> (Int32, String, String) {
            if args.first == "copyto" {
                copytoCalls += 1
                return (1, "", "induced failure for AC-L62-9")
            }
            return realRclone(args, remote, timeout)
        }
        let failEnv = fakeCLIEnvironment(
            runRclone: failingCopytoRclone,
            readProfiles: { [profile] },
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            removeFile: { (try? FileManager.default.removeItem(atPath: $0)) != nil },
            moveFile: { from, to, replace in moveCalls += 1; return moveFile(from, to, replace) })
        let failCode = LimpetCLI.execute(["trash", "restore", profile.shortId, "a.tar.gz", "--force"], env: failEnv)
        guard failCode != 0, copytoCalls == 1, moveCalls == 0,
              !FileManager.default.fileExists(atPath: "\(localDir)/a.tar.gz.limpet-restore-tmp") else {
            return report(id, slug, false,
                "(an induced copy failure moved something into place or left a temp file: copyto=\(copytoCalls) move=\(moveCalls))")
        }
        // The pre-existing a.tar.gz (from the earlier successful restore) must
        // be untouched by the failed --force attempt.
        guard let untouchedContent = try? String(contentsOfFile: "\(localDir)/a.tar.gz", encoding: .utf8),
              untouchedContent == "hello" else {
            return report(id, slug, false, "(the existing file was altered by a failed restore attempt)")
        }

        return report(id, slug, true)
    }

    // MARK: - AC-L62-10 — purge: $NO_CHECK_CERT (never additionalRcloneFlags)
    // reaches lsf/purge; an lsf failure logs one line, writes no stamp, and a
    // later run retries; -n, a bundled short-flag cluster containing n (-vn,
    // -nv), --dry-run=true and --dry-run=<non-false> are all dry runs,
    // --dry-run=false is not (code-review findings 5/7 on 87bbf67; the
    // bundled-cluster case from a fresh-verifier follow-up review).

    private static func testTrashPurgeCertFlagsFailureAndDryRunVariants() -> Bool {
        let id = "AC-L62-10", slug = "trash-purge-cert-flags-failure-dryrun-variants"
        let trashRoot = "\(selfTestRoot)/ac-l62-10-trash"

        // --- $NO_CHECK_CERT reaches lsf; additionalRcloneFlags never does ---
        let homeDir = "\(selfTestRoot)/ac-l62-10-home"
        try? FileManager.default.removeItem(atPath: homeDir)
        let rcloneConfDir = "\(homeDir)/.config/rclone"
        do {
            try FileManager.default.createDirectory(atPath: rcloneConfDir, withIntermediateDirectories: true)
            try "[selftest-fixture-remote]\nno_check_certificate = true\n"
                .write(toFile: "\(rcloneConfDir)/rclone.conf", atomically: true, encoding: .utf8)
        } catch {
            return report(id, slug, false, "(HOME fixture setup failed)")
        }
        let noopStub = "if [ \"$1\" = \"lsf\" ]; then exit 0; fi\nif [ \"$1\" = \"purge\" ]; then exit 0; fi\nexit 0\n"
        guard let certResult = runScriptFixtureAppending(
            name: "ac-l62-10-certflags",
            overrides: ["trashRoot": trashRoot, "trashDays": 14, "additionalFlags": "--exclude=*.tmp --bwlimit=1M"],
            stubBody: noopStub, extraEnvironment: ["HOME": homeDir]) else {
            return report(id, slug, false, "(cert/flags fixture setup failed)")
        }
        guard certResult.status == 0, let lsfCall = certResult.invocations.first(where: { $0.first == "lsf" }) else {
            return report(id, slug, false, "(no lsf invocation recorded: status \(certResult.status))")
        }
        guard lsfCall.contains("--no-check-certificate") else {
            return report(id, slug, false, "(lsf did not receive --no-check-certificate: \(lsfCall))")
        }
        guard !lsfCall.contains("--exclude=*.tmp"), !lsfCall.contains("--bwlimit=1M") else {
            return report(id, slug, false, "(lsf received the profile's additionalRcloneFlags: \(lsfCall))")
        }

        // --- an lsf failure logs one line, writes NO stamp, and a later run retries ---
        let failStub = "if [ \"$1\" = \"lsf\" ]; then exit 1; fi\nexit 0\n"
        let failName = "ac-l62-10-lsf-fail"
        guard let first = runScriptFixtureAppending(
            name: failName, overrides: ["trashRoot": trashRoot, "trashDays": 14], stubBody: failStub) else {
            return report(id, slug, false, "(lsf-failure fixture setup failed)")
        }
        guard first.status == 0, first.log.contains("could not list"),
              first.invocations.contains(where: { $0.first == "lsf" }) else {
            return report(id, slug, false, "(lsf failure did not log the expected line: \(first.log))")
        }
        let stampPath = "\(selfTestRoot)/\(failName)/profile.trash-purged"
        guard !FileManager.default.fileExists(atPath: stampPath) else {
            return report(id, slug, false, "(the stamp was written despite an lsf failure)")
        }
        guard let second = runScriptFixtureAppending(
            name: failName, overrides: ["trashRoot": trashRoot, "trashDays": 14], stubBody: failStub, reset: false),
              second.invocations.contains(where: { $0.first == "lsf" }) else {
            return report(id, slug, false, "(a later run did not retry the purge after an lsf failure)")
        }

        // --- dry-run detection: -n, a bundled short-flag cluster containing n
        // (-vn, -nv — measured 2026-09-28: rclone -vn logs "Skipped copy as
        // --dry-run is set"), --dry-run=true, --dry-run=<non-false> all skip;
        // --dry-run=false does not ---
        let dryRunStub = "if [ \"$1\" = \"lsf\" ]; then exit 0; fi\nexit 0\n"
        let cases: [(flag: String, isDryRun: Bool)] = [
            ("-n", true), ("-vn", true), ("-nv", true),
            ("--dry-run=true", true), ("--dry-run=1", true), ("--dry-run=false", false),
        ]
        for (index, testCase) in cases.enumerated() {
            guard let result = runScriptFixtureAppending(
                name: "ac-l62-10-dry-\(index)",
                overrides: ["trashRoot": trashRoot, "trashDays": 14, "additionalFlags": testCase.flag],
                stubBody: dryRunStub) else {
                return report(id, slug, false, "(dry-run fixture setup failed for \"\(testCase.flag)\")")
            }
            let lsfCalled = result.invocations.contains(where: { $0.first == "lsf" })
            if testCase.isDryRun {
                guard !lsfCalled else {
                    return report(id, slug, false, "(\"\(testCase.flag)\" was not treated as a dry run)")
                }
            } else {
                guard lsfCalled else {
                    return report(id, slug, false, "(\"\(testCase.flag)\" was incorrectly treated as a dry run)")
                }
            }
        }

        // --- trashDays is exactly 0...365 (CodeRabbit, PR #10): an unbounded
        // digit string never reaches `date -v-Nd` ---
        for (value, accepted) in [("0", true), ("365", true), ("366", false), ("014", false),
                                  ("99999999999999999999", false)] {
            guard let result = runScriptFixtureAppending(
                name: "ac-l62-10-days", overrides: ["trashRoot": trashRoot, "trashDays": value], stubBody: noopStub) else {
                return report(id, slug, false, "(trashDays fixture setup failed for \(value))")
            }
            let refused = result.status == 64 && result.invocations.isEmpty
                && result.log.contains("trashDays must be a whole number from 0 to 365")
            guard refused != accepted, accepted ? result.status == 0 : true else {
                return report(id, slug, false, "(trashDays \(value): status \(result.status), expected accepted=\(accepted))")
            }
        }

        // --- an empty CUTOFF skips the purge with one log line and writes no
        // stamp. `date -v...` is made to fail with an exported bash function
        // (measured 2026-09-28: /bin/bash 3.2.57 imports `BASH_FUNC_date%%`
        // and it shadows /bin/date despite the script's own PATH export) ---
        let noCutoffName = "ac-l62-10-no-cutoff"
        guard let noCutoff = runScriptFixtureAppending(
            name: noCutoffName, overrides: ["trashRoot": trashRoot, "trashDays": 14], stubBody: noopStub,
            extraEnvironment: ["BASH_FUNC_date%%": "() { if [[ \"$1\" == -v* ]]; then return 1; fi; command date \"$@\"; }"]) else {
            return report(id, slug, false, "(no-cutoff fixture setup failed)")
        }
        let skipLines = noCutoff.log.components(separatedBy: "\n")
            .filter { $0.contains("Trash purge skipped: could not compute the cutoff date") }
        guard noCutoff.status == 0, skipLines.count == 1,
              !noCutoff.invocations.contains(where: { $0.first == "lsf" || $0.first == "purge" }),
              !FileManager.default.fileExists(atPath: "\(selfTestRoot)/\(noCutoffName)/profile.trash-purged") else {
            return report(id, slug, false,
                "(empty cutoff: status \(noCutoff.status), skip lines \(skipLines.count), invocations \(noCutoff.invocations))")
        }

        return report(id, slug, true)
    }

    // MARK: - AC-L62-7 — RcloneLogEntry parsing + SyncManager's filter TOGETHER:
    // a real delete surfaces exactly once, an overwrite surfaces zero deletes,
    // and a genuine rename is never confused with a backup-dir move.

    /// Code-review finding 1 (P1) on 87bbf67: the previous `shouldReportFileChange`
    /// was keyed off `operation == .deleted` alone, which ALSO matched
    /// `Moved into backup dir` (mapped to the same `.deleted` case as the
    /// ambiguous bare `Deleted`), so EVERY delete on a trash profile was
    /// dropped, real ones included. Finding 8: `Moved (server-side) to: ...`
    /// is ambiguous the same way (a real `--track-renames` rename vs a
    /// Move-capable backend's backup move) and must be suppressed on a trash
    /// profile like the bare `Deleted`, while an unambiguous `Renamed from
    /// "..."` must never be. This drives the REAL production seam end to end:
    /// `RcloneLogEntry.fileChange` (parsing) THEN `SyncManager.shouldReportFileChange`
    /// (the filter) — not either one in isolation.
    private static func testRealDeleteSurfacesOnceOverwriteSurfacesZero() -> Bool {
        let id = "AC-L62-7", slug = "real-delete-once-overwrite-zero-rename-unambiguous"

        func entry(level: String, msg: String, object: String) -> RcloneLogEntry {
            RcloneLogEntry(
                level: level, msg: msg, time: "2026-09-28T00:00:00.000000+08:00",
                object: object, objectType: "*local.Object", stats: nil, source: nil, size: nil)
        }
        /// Reported .deleted count for a sequence of lines, given `hasTrashRoot`.
        func reportedDeletedCount(_ lines: [RcloneLogEntry], hasTrashRoot: Bool) -> Int {
            lines.compactMap(\.fileChange)
                .filter { $0.operation == .deleted && SyncManager.shouldReportFileChange($0, hasTrashRoot: hasTrashRoot) }
                .count
        }

        // Measured 2026-09-28 (rclone 1.75.1, --disable Move, the S4 path):
        // a real delete is "Copied (server-side copy) to: …" + "Deleted" +
        // "Moved into backup dir" (all for the SAME object, d1.txt); an
        // overwrite is "Copied (server-side copy) to: …" + "Deleted" only
        // (object a.txt), no "Moved into backup dir" line at all.
        let s4Delete = [
            entry(level: "info", msg: "Copied (server-side copy) to: d1-100002.txt", object: "d1.txt"),
            entry(level: "info", msg: "Deleted", object: "d1.txt"),
            entry(level: "info", msg: "Moved into backup dir", object: "d1.txt"),
        ]
        let s4Overwrite = [
            entry(level: "info", msg: "Copied (server-side copy) to: a-100001.tar.gz", object: "a.txt"),
            entry(level: "info", msg: "Deleted", object: "a.txt"),
        ]
        guard reportedDeletedCount(s4Delete, hasTrashRoot: true) == 1 else {
            return report(id, slug, false, "(a real S4-path delete did not surface exactly one .deleted)")
        }
        guard reportedDeletedCount(s4Overwrite, hasTrashRoot: true) == 0 else {
            return report(id, slug, false, "(an S4-path overwrite surfaced a .deleted)")
        }
        // Without a trash root, nothing is ever suppressed: the delete
        // sequence's "Deleted" AND "Moved into backup dir" BOTH map to
        // .deleted and both count (2); the overwrite sequence's lone
        // "Deleted" line counts once (1) — exactly as pre-trash code, since
        // hasTrashRoot gates the whole filter off.
        guard reportedDeletedCount(s4Delete, hasTrashRoot: false) == 2,
              reportedDeletedCount(s4Overwrite, hasTrashRoot: false) == 1 else {
            return report(id, slug, false, "(a non-trash profile's Deleted lines were suppressed)")
        }

        // Finding 8, reference measurement (plan's "Move-capable backends, for
        // reference" note — a Move-capable backend backs up directly, no
        // Copy+Delete fallback): an overwrite's backup step and a delete's
        // both log "Moved (server-side) to: …"; the delete ALSO logs "Moved
        // into backup dir" (no bare "Deleted" at all on this path).
        let moveCapableOverwrite = entry(level: "info", msg: "Moved (server-side) to: a-renamed.txt", object: "a.txt")
        let moveCapableDelete = [
            entry(level: "info", msg: "Moved (server-side) to: d1-100003.txt", object: "d1.txt"),
            entry(level: "info", msg: "Moved into backup dir", object: "d1.txt"),
        ]
        let genuineRename = entry(level: "info", msg: "Renamed from \"old.txt\"", object: "new.txt")

        guard let overwriteChange = moveCapableOverwrite.fileChange, overwriteChange.operation == .renamed,
              overwriteChange.mayBeTrashArtifact else {
            return report(id, slug, false, "(the Move-capable overwrite line did not parse as an ambiguous .renamed)")
        }
        guard !SyncManager.shouldReportFileChange(overwriteChange, hasTrashRoot: true),
              SyncManager.shouldReportFileChange(overwriteChange, hasTrashRoot: false) else {
            return report(id, slug, false, "(the ambiguous rename was not suppressed for trash / shown without it)")
        }
        let deleteRenamedChanges = moveCapableDelete.compactMap(\.fileChange)
        guard deleteRenamedChanges.filter({ SyncManager.shouldReportFileChange($0, hasTrashRoot: true) }).count == 1 else {
            return report(id, slug, false, "(the Move-capable delete did not surface exactly one change under trash)")
        }
        guard let genuineChange = genuineRename.fileChange, genuineChange.operation == .renamed,
              !genuineChange.mayBeTrashArtifact,
              SyncManager.shouldReportFileChange(genuineChange, hasTrashRoot: true),
              SyncManager.shouldReportFileChange(genuineChange, hasTrashRoot: false) else {
            return report(id, slug, false, "(a genuine \"Renamed from\" line was suppressed or misparsed)")
        }

        return report(id, slug, true)
    }

    // MARK: - L6.3 helpers

    /// Runs the main run loop (the main queue's `async` blocks only run there)
    /// until `done()` or `timeout`.
    private static func pumpMain(timeout: TimeInterval, until done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return done()
    }

    private final class RecordingDelegate: LogWatcherDelegate {
        var batches: [[String]] = []
        var allOnMain = true
        func logWatcher(_ watcher: LogWatcher, didReceiveNewLines lines: [String]) {
            if !Thread.isMainThread { allOnMain = false }
            batches.append(lines)
        }
        func count(of needle: String) -> Int { batches.joined().filter { $0.contains(needle) }.count }
    }

    private static func appendLine(_ text: String, to path: String) {
        guard let h = FileHandle(forWritingAtPath: path) else { return }
        h.seekToEndOfFile()
        h.write(Data((text + "\n").utf8))
        try? h.close()
    }

    private static func inode(_ path: String) -> UInt64? {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    // MARK: - AC-L63-1 — batch coalescing (stats keep-last, events in order) and FIFO delivery

    private static func testCoalesceLogEventsAndFIFODelivery() -> Bool {
        let id = "AC-L63-1", slug = "coalesce-and-fifo-delivery"
        let parser = LogParser()
        func stats(_ n: Int) -> String {
            #"{"level":"info","msg":"stats","time":"2026-10-03T00:00:00.000000+08:00","stats":{"bytes":\#(n),"totalBytes":1000}}"#
        }
        let lines = [
            "2026-10-03 00:00:00 - Starting sync (local → remote)", stats(1), stats(2),
            #"{"level":"info","msg":"Copied (new)","time":"2026-10-03T00:00:00.000000+08:00","object":"a.txt","objectType":"*local.Object"}"#,
            stats(3), "2026-10-03 00:00:09 - Sync completed successfully", stats(4),
        ]
        let events = lines.compactMap { parser.parse(line: $0) }
        guard events.count == lines.count else {
            return report(id, slug, false, "(parser produced \(events.count) of \(lines.count) events)")
        }
        let out = SyncManager.coalesceLogEvents(events)
        var kinds: [String] = []
        var lastBytes = -1
        for e in out {
            switch e.type {
            case .syncStarted: kinds.append("started")
            case .stats(let st): kinds.append("stats"); lastBytes = st.bytes ?? -1
            case .fileChange: kinds.append("change")
            case .syncCompleted: kinds.append("completed")
            default: kinds.append("other")
            }
        }
        guard kinds == ["started", "change", "completed", "stats"], lastBytes == 4 else {
            return report(id, slug, false, "(coalesced to \(kinds), last stats bytes \(lastBytes))")
        }
        guard SyncManager.coalesceLogEvents([]).isEmpty else {
            return report(id, slug, false, "(empty batch not empty)")
        }

        // Raw prefilter (runs before JSON decoding): lines below are verbatim rclone 1.75.1
        // `--use-json-log --stats 1s` output captured 2026-10-03, plus a file name that
        // contains the stats text (JSON-escaped, so it must not match).
        let realStats = #"{"time":"2026-10-03T03:57:24.892833+08:00","level":"info","msg":"\nTransferred:   \t   28.610 MiB / 28.610 MiB, 100%, 0 B/s, ETA -\nChecks:                 0 / 0, -, Listed 2\nTransferred:            2 / 2, 100%\nServer Side Copies:     2 @ 28.610 MiB\nElapsed time:         0.0s\n\n","stats":{"bytes":30000003,"checks":0,"deletedDirs":0,"deletes":0,"elapsedTime":0.03785025,"errors":0,"eta":null,"fatalError":false,"listed":2,"renames":0,"retryError":false,"serverSideCopies":2,"serverSideCopyBytes":30000003,"serverSideMoveBytes":0,"serverSideMoves":0,"speed":0,"totalBytes":30000003,"totalChecks":0,"totalTransfers":2,"transferTime":0.037651209,"transfers":2},"source":"accounting/stats.go:549"}"#
        let realCopied = #"{"time":"2026-10-03T03:57:24.855461+08:00","level":"info","msg":"Copied (server-side copy)","size":3,"object":"a.txt","objectType":"*local.Object","source":"operations/copy.go:380"}"#
        let tricky = #"{"level":"info","msg":"Copied (new)","object":"x\"stats\":{y.txt","objectType":"*local.Object"}"#
        let laterStats = realStats.replacingOccurrences(of: "\"bytes\":30000003", with: "\"bytes\":1")
        let raw = [realStats, "2026-10-03 00:00:00 - note", realCopied, laterStats, tricky]
        guard let firstEvent = parser.parse(line: realStats), case .stats = firstEvent.type else {
            return report(id, slug, false, "(the captured rclone stats line did not parse as .stats)")
        }
        let kept = SyncManager.dropSupersededStatsLines(raw)
        guard kept == [raw[1], raw[2], raw[3], raw[4]] else {
            return report(id, slug, false, "(prefilter kept \(kept.count) lines: \(kept.map { $0.prefix(30) }))")
        }
        guard SyncManager.dropSupersededStatsLines([raw[1], raw[2], raw[4]]) == [raw[1], raw[2], raw[4]],
              SyncManager.dropSupersededStatsLines([]).isEmpty else {
            return report(id, slug, false, "(prefilter changed a batch without stats lines)")
        }
        // Same final events as coalescing the fully parsed batch.
        func summary(_ ls: [String]) -> [String] {
            SyncManager.coalesceLogEvents(ls.compactMap { parser.parse(line: $0) }).map { e in
                if case .stats(let st) = e.type { return "stats\(st.bytes ?? -1)" }
                return String(e.rawLine.prefix(20))
            }
        }
        guard summary(SyncManager.dropSupersededStatsLines(raw)) == summary(raw) else {
            return report(id, slug, false, "(prefilter changed the coalesced result)")
        }

        // FIFO: batches N and N+1 flushed from the watcher queue arrive on main in order.
        guard Thread.isMainThread else { return report(id, slug, false, "(self-test not on main)") }
        let dir = "\(selfTestRoot)/ac-l63-1"
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let log = "\(dir)/w.log"
        FileManager.default.createFile(atPath: log, contents: nil)
        let delegate = RecordingDelegate()
        let watcher = LogWatcher(logPath: log, heartbeatInterval: 0.2, activePollingInterval: 0.2, flushInterval: 0.2)
        watcher.delegate = delegate
        watcher.startWatching()
        for n in 0..<10 {
            appendLine("2026-10-03 00:00:00 - Starting sync batch-\(n)", to: log)  // transition line: immediate flush
            watcher.pollNowForTesting()
        }
        _ = pumpMain(timeout: 3) { delegate.count(of: "batch-") >= 10 }
        watcher.stopWatching()
        let order = delegate.batches.joined().compactMap { l in l.components(separatedBy: "batch-").last.flatMap(Int.init) }
        guard order == Array(0..<10), delegate.allOnMain else {
            return report(id, slug, false, "(delivery order \(order), allOnMain \(delegate.allOnMain))")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L63-2 — exit code 79 text (78 stays unmapped: secretUnavailableExitCode)

    private static func testExitCodeErrorTextStalled() -> Bool {
        let id = "AC-L63-2", slug = "exit-code-79-sync-stalled"
        let text = SyncManager.exitCodeErrorText(79)
        guard text == "Sync stalled", SyncWatchDaemon.stalledExitCode == 79,
              SyncWatchDaemon.stalledExitCode != SyncWatchDaemon.secretUnavailableExitCode else {
            return report(id, slug, false, "(79 mapped to \"\(text)\")")
        }
        guard SyncManager.exitCodeErrorText(78) == "Exit code 78", SyncManager.exitCodeErrorText(76) == "Delete limit reached",
              SyncManager.exitCodeErrorText(1) == "Exit code 1" else {
            return report(id, slug, false, "(neighbouring codes changed)")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L63-3 — watchdog decision (pure)

    private static func testWatchdogDecision() -> Bool {
        let id = "AC-L63-3", slug = "watchdog-decision"
        let t = SyncWatchDaemon.WatchdogTimings(stallThreshold: 1800, killGrace: 30, postKillWait: 60, checkInterval: 60)
        let base = LogFileStat(size: 100, inode: 7)
        func d(size: UInt64 = 100, inode: UInt64 = 7, last: TimeInterval = 0, now: TimeInterval,
               sent: TimeInterval? = nil, killed: TimeInterval? = nil,
               alive: Bool = true, reaped: Bool = false) -> (SyncWatchDaemon.WatchdogDecision, Bool) {
            let r = SyncWatchDaemon.watchdogDecision(
                lastProgress: base, lastProgressTime: last, current: LogFileStat(size: size, inode: inode), now: now,
                sigtermSentAt: sent, sigkillSentAt: killed, groupAlive: alive, childReaped: reaped, timings: t)
            return (r.decision, r.progressed)
        }
        typealias D = SyncWatchDaemon.WatchdogDecision
        let cases: [(String, (D, Bool), (D, Bool))] = [
            ("quiet below threshold", d(now: 1799), (.wait, false)),
            ("quiet at threshold", d(now: 1800), (.terminate, false)),
            ("grew", d(size: 101, now: 5000), (.wait, true)),
            ("inode changed (rotation)", d(inode: 8, now: 5000), (.wait, true)),
            // The times are monotonic uptime seconds. A Mac that slept for hours advances
            // the wall clock but not uptime, so the elapsed time the function sees is small.
            ("large wall-clock jump, no monotonic elapsed time", d(last: 100_000, now: 100_001), (.wait, false)),
            ("bash exited on its own before the watchdog acted, though quiet", d(now: 5000, reaped: true), (.exited, false)),
            ("bash exited on its own with the log growing", d(size: 200, now: 5, reaped: true), (.exited, true)),
            ("sigterm sent, grace not elapsed", d(now: 1820, sent: 1800), (.wait, false)),
            ("child reaped, group alive, grace elapsed", d(now: 1830, sent: 1800, reaped: true), (.kill, false)),
            ("child not reaped, group alive, grace elapsed", d(now: 1830, sent: 1800), (.kill, false)),
            ("child reaped, group alive, grace not elapsed", d(now: 1801, sent: 1800, reaped: true), (.wait, false)),
            ("group gone, child reaped", d(now: 1801, sent: 1800, alive: false, reaped: true), (.done, false)),
            ("group gone, child not yet reaped", d(now: 1801, sent: 1800, alive: false), (.wait, false)),
            ("log grows after SIGTERM never cancels it", d(size: 500, now: 1801, sent: 1800, reaped: true), (.wait, true)),
            ("after SIGKILL, post-kill wait not elapsed", d(now: 1859, sent: 1800, killed: 1830, reaped: true), (.kill, false)),
            ("after SIGKILL, group still alive past the post-kill wait", d(now: 1890, sent: 1800, killed: 1830, reaped: true), (.giveUp, false)),
            ("post-kill wait elapsed but bash not reaped yet", d(now: 1890, sent: 1800, killed: 1830), (.kill, false)),
            ("group gone after SIGKILL", d(now: 1840, sent: 1800, killed: 1830, alive: false, reaped: true), (.done, false)),
        ]
        for (name, got, want) in cases where got != want {
            return report(id, slug, false, "(\(name): got \(got), want \(want))")
        }
        // Production reads the sleep-pausing clock for every watchdog time value.
        let a = SyncWatchDaemon.monotonicNow()
        guard abs(a - ProcessInfo.processInfo.systemUptime) < 1 else {
            return report(id, slug, false, "(monotonicNow is not the system uptime)")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L63-4 — script log rotation, run for real in the isolated home

    private static func testScriptLogRotation() -> Bool {
        let id = "AC-L63-4", slug = "script-log-rotation"
        let name = "ac-l63-4"
        let root = "\(selfTestRoot)/\(name)"
        let log = "\(root)/sync.log"
        let stub = "exit 0\n"
        guard let first = runScriptFixtureAppending(name: name, overrides: [:], stubBody: stub), first.status == 0 else {
            return report(id, slug, false, "(first run failed)")
        }
        guard !FileManager.default.fileExists(atPath: "\(log).1") else {
            return report(id, slug, false, "(a small log was rotated)")
        }
        // Over the 20 MB threshold: 20 MiB + 1 line.
        let line = String(repeating: "x", count: 1023) + "\n"
        let big = Data(String(repeating: line, count: 20 * 1024 + 1).utf8)
        guard (try? big.write(to: URL(fileURLWithPath: log))) != nil else {
            return report(id, slug, false, "(could not write the big log)")
        }
        let oldInode = inode(log)
        guard let second = runScriptFixtureAppending(name: name, overrides: [:], stubBody: stub, reset: false),
              second.status == 0 else {
            return report(id, slug, false, "(rotating run failed)")
        }
        let rotatedSize = (try? FileManager.default.attributesOfItem(atPath: "\(log).1"))?[.size] as? UInt64
        guard rotatedSize == UInt64(big.count), inode("\(log).1") == oldInode else {
            return report(id, slug, false, "(.1 is not the old log: size \(String(describing: rotatedSize)))")
        }
        guard inode(log) != nil, inode(log) != oldInode, second.log.contains("Starting sync"),
              second.log.utf8.count < 4096 else {
            return report(id, slug, false, "(new log missing or not fresh: \(second.log.utf8.count) bytes)")
        }
        // A second rotation replaces .1 (one old generation only).
        guard (try? big.write(to: URL(fileURLWithPath: log))) != nil,
              let third = runScriptFixtureAppending(name: name, overrides: [:], stubBody: stub, reset: false),
              third.status == 0,
              ((try? FileManager.default.attributesOfItem(atPath: "\(log).1"))?[.size] as? UInt64) == UInt64(big.count),
              !FileManager.default.fileExists(atPath: "\(log).2") else {
            return report(id, slug, false, "(second rotation did not replace .1 / left a .2)")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L63-5 — LogWatcher: rotation reopens at 0, delivered once; stop mid-read is safe

    private static func testLogWatcherRotationAndStop() -> Bool {
        let id = "AC-L63-5", slug = "logwatcher-rotation-from-zero-and-stop"
        guard Thread.isMainThread else { return report(id, slug, false, "(self-test not on main)") }
        let dir = "\(selfTestRoot)/ac-l63-5"
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let log = "\(dir)/w.log"
        try? String(repeating: "old line\n", count: 50).write(toFile: log, atomically: true, encoding: .utf8)
        let delegate = RecordingDelegate()
        let watcher = LogWatcher(logPath: log, heartbeatInterval: 0.3, activePollingInterval: 0.3, flushInterval: 0.2)
        watcher.delegate = delegate
        watcher.startWatching()

        // Rotate exactly as the script does, then the run's first line lands in the NEW file.
        try? FileManager.default.moveItem(atPath: log, toPath: "\(log).1")
        FileManager.default.createFile(atPath: log, contents: nil)
        appendLine("2026-10-03 00:00:00 - Starting sync (local → remote)", to: log)
        // Both the source event (already firing) and a forced poll race to reopen.
        watcher.pollNowForTesting()
        watcher.pollNowForTesting()
        _ = pumpMain(timeout: 3) { delegate.count(of: "Starting sync") >= 1 }
        _ = pumpMain(timeout: 1) { false }  // leave room for a duplicate to show up
        guard delegate.count(of: "Starting sync") == 1 else {
            watcher.stopWatching()
            return report(id, slug, false, "(Starting sync delivered \(delegate.count(of: "Starting sync")) times)")
        }
        guard delegate.count(of: "old line") == 0 else {
            watcher.stopWatching()
            return report(id, slug, false, "(old content was replayed)")
        }

        // Stop while writes (and so reads) are in flight: no crash, no later delivery.
        let writer = Thread {
            for n in 0..<2000 { appendLine("2026-10-03 00:00:01 - line \(n)", to: log) }
        }
        writer.start()
        Thread.sleep(forTimeInterval: 0.02)
        watcher.stopWatching()
        _ = pumpMain(timeout: 0.5) { false }
        let delivered = delegate.batches.count
        while !writer.isFinished { Thread.sleep(forTimeInterval: 0.01) }
        _ = pumpMain(timeout: 0.8) { false }
        guard delegate.batches.count == delivered else {
            return report(id, slug, false, "(batches kept arriving after stopWatching)")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L63-5b — a missing path is never created; the file is opened at 0 when it appears

    private static func testLogWatcherMissingPathNeverCreated() -> Bool {
        let id = "AC-L63-5b", slug = "logwatcher-missing-path-never-created"
        guard Thread.isMainThread else { return report(id, slug, false, "(self-test not on main)") }
        let dir = "\(selfTestRoot)/ac-l63-5b"
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let log = "\(dir)/never-created.log"
        let interval: TimeInterval = 0.4
        let delegate = RecordingDelegate()
        let watcher = LogWatcher(logPath: log, heartbeatInterval: interval, activePollingInterval: interval, flushInterval: 0.2)
        watcher.delegate = delegate
        watcher.startWatching()
        _ = pumpMain(timeout: interval * 2.5) { false }
        guard !FileManager.default.fileExists(atPath: log) else {
            watcher.stopWatching()
            return report(id, slug, false, "(the watcher created the log)")
        }
        // The file appears with content already in it, as when tee/the script creates it.
        let content = "2026-10-03 00:00:00 - Starting sync (local → remote)\n"
        try? content.write(toFile: log, atomically: false, encoding: .utf8)
        let ino = inode(log)
        let appeared = Date()
        let got = pumpMain(timeout: interval * 3) { delegate.count(of: "Starting sync") >= 1 }
        let latency = Date().timeIntervalSince(appeared)
        _ = pumpMain(timeout: interval * 2) { false }
        watcher.stopWatching()
        guard got, latency <= interval + 0.6, delegate.count(of: "Starting sync") == 1 else {
            return report(id, slug, false, "(delivered \(delegate.count(of: "Starting sync"))x after \(latency)s, poll interval \(interval)s)")
        }
        guard inode(log) == ino, (try? String(contentsOfFile: log, encoding: .utf8)) == content else {
            return report(id, slug, false, "(the watcher changed the file)")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L63-6 — the purge's one-line stats are inert to LogParser; the script requests them

    private static func testPurgeStatsLineIsInertAndFlagged() -> Bool {
        let id = "AC-L63-6", slug = "purge-stats-line-inert-and-flagged"
        // Captured 2026-10-03 from `rclone purge --disable Purge --tpslimit 20 --stats 5s
        // --stats-one-line --stats-log-level NOTICE` (local backend, per-object deletes).
        let captured = "2026/10/03 03:28:49 NOTICE:           0 B / 0 B, -, 0 B/s, ETA -"
        if let event = LogParser().parse(line: captured) {
            switch event.type {
            case .unknown: break
            default: return report(id, slug, false, "(parsed as \(event.type), expected nil or .unknown)")
            }
        }
        // The script passes the flags to lsf and purge and keeps their stderr in the log.
        let trashRoot = "\(selfTestRoot)/ac-l63-6-trash"
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        let older = formatter.string(from: Calendar.current.date(byAdding: .day, value: -20, to: Date())!)
        let stubBody = """
            if [ "$1" = "lsf" ]; then printf '%s/\\n' "\(older)"; exit 0; fi
            if [ "$1" = "purge" ]; then echo "\(captured)" >&2; exit 0; fi
            exit 0
            """
        guard let r = runScriptFixtureAppending(
            name: "ac-l63-6", overrides: ["trashRoot": trashRoot, "trashDays": 14], stubBody: stubBody),
              r.status == 0 else {
            return report(id, slug, false, "(fixture failed)")
        }
        let flags = ["--stats", "1m", "--stats-one-line", "--stats-log-level", "NOTICE"]
        for verb in ["lsf", "purge"] {
            guard let inv = r.invocations.first(where: { $0.first == verb }),
                  zip(inv, inv.dropFirst()).contains(where: { $0 == "--stats" && $1 == "1m" }),
                  flags.allSatisfy(inv.contains) else {
                return report(id, slug, false, "(\(verb) was not run with \(flags): \(r.invocations))")
            }
        }
        guard r.log.contains(captured) else {
            return report(id, slug, false, "(purge stderr did not reach the profile log)")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L63-7 — startup never replays the log tail

    private static func testStartupTailStaysIdle() -> Bool {
        let id = "AC-L63-7", slug = "startup-tail-stays-idle"
        let dir = "\(selfTestRoot)/ac-l63-7"
        try? FileManager.default.removeItem(atPath: dir)
        let store = ProfileStore(
            profilesDirectory: "\(dir)/profiles",
            defaults: UserDefaults(suiteName: "com.nanako.limpet.selftest.l63-7.\(UUID().uuidString)")!)
        var started = sampleProfile(name: "L63 started")
        var failed = sampleProfile(name: "L63 failed")
        started.localSyncPath = "\(dir)/src-a"
        failed.localSyncPath = "\(dir)/src-b"
        for (p, tail) in [(started, "2026-10-03 00:00:00 - Starting sync (local → remote)"),
                          (failed, "2026-10-03 00:00:00 - Sync failed with exit code 5")] {
            try? FileManager.default.createDirectory(
                atPath: (p.logPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            guard p.logPath.hasPrefix(LimpetPaths.home), !FileManager.default.fileExists(atPath: p.lockFilePath),
                  (try? (tail + "\n").write(toFile: p.logPath, atomically: true, encoding: .utf8)) != nil else {
                return report(id, slug, false, "(fixture setup failed or the lock path is occupied)")
            }
            store.add(p)
        }
        let manager = SyncManager(profileStore: store)
        _ = pumpMain(timeout: 1.5) { false }  // anything replayed would have arrived by now
        // No lock held: the tail must not make the first profile "syncing", and the
        // failure tail must not reach processLogEvent (which would set .error and notify).
        guard manager.profileStates[started.id] == .idle, manager.profileStates[failed.id] == .idle,
              manager.profileErrors[started.id] == nil, manager.profileErrors[failed.id] == nil else {
            return report(id, slug, false, "(states: \(String(describing: manager.profileStates[started.id])), \(String(describing: manager.profileStates[failed.id])))")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L63-9 — a line split inside a multibyte character is delivered once, intact

    private static func testLogWatcherSplitMultibyteLine() -> Bool {
        let id = "AC-L63-9", slug = "logwatcher-split-multibyte-line"
        guard Thread.isMainThread else { return report(id, slug, false, "(self-test not on main)") }
        let dir = "\(selfTestRoot)/ac-l63-9"
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let log = "\(dir)/w.log"
        FileManager.default.createFile(atPath: log, contents: nil)
        let delegate = RecordingDelegate()
        let watcher = LogWatcher(logPath: log, heartbeatInterval: 0.2, activePollingInterval: 0.2, flushInterval: 0.1)
        watcher.delegate = delegate
        watcher.startWatching()
        defer { watcher.stopWatching() }

        let text = #"{"level":"info","msg":"Copied (new)","object":"報告書.txt","objectType":"*local.Object","time":"2026-10-03T00:00:00.000000+08:00"}"#
        let bytes = Array((text + "\n").utf8)
        let mark = Array("報".utf8)
        guard let start = (0..<bytes.count - 3).first(where: { Array(bytes[$0..<$0 + 3]) == mark }) else {
            return report(id, slug, false, "(fixture: marker not found)")
        }
        let cut = start + 1  // inside the 3-byte character
        func write(_ b: ArraySlice<UInt8>) {
            guard let h = FileHandle(forWritingAtPath: log) else { return }
            h.seekToEndOfFile(); h.write(Data(b)); try? h.close()
        }
        write(bytes[..<cut])
        watcher.pollNowForTesting()
        _ = pumpMain(timeout: 0.6) { false }
        guard delegate.batches.isEmpty else {
            return report(id, slug, false, "(a partial line was delivered: \(delegate.batches))")
        }
        write(bytes[cut...])
        watcher.pollNowForTesting()
        _ = pumpMain(timeout: 3) { delegate.count(of: "報告書") >= 1 }
        _ = pumpMain(timeout: 0.6) { false }
        let all = delegate.batches.joined()
        guard all.count == 1, all.first == text else {
            return report(id, slug, false, "(delivered \(all.count) lines, first: \(String(describing: all.first)))")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L63-10 — the watchdog's stall line is a failure marker for the GUI's lock-vanished path

    private static func testStalledLineIsAFailureMarker() -> Bool {
        let id = "AC-L63-10", slug = "stalled-line-is-failure-marker"
        let dir = "\(selfTestRoot)/ac-l63-10"
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let start = "2026-10-03 00:00:00 - Starting sync (local → remote)"
        let stall = "2026-10-03 00:30:00 - Sync stalled: no log output for 30 min — stopping it"
        func lastError(_ lines: [String]) -> String? {
            let path = "\(dir)/\(UUID().uuidString).log"
            try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            return SyncManager.readLastErrorFromLog(path)
        }
        // The race: lock gone, SIGTERM sent, the exit line not written yet.
        guard lastError([start, stall]) == "Sync stalled" else {
            return report(id, slug, false, "(Starting sync + stall line gave \(String(describing: lastError([start, stall]))))")
        }
        guard lastError([start, stall, "2026-10-03 00:30:02 - Sync failed with exit code 79"]) == "Sync stalled" else {
            return report(id, slug, false, "(with the exit line it did not report the stall)")
        }
        guard lastError([start]) == nil,
              lastError([start, stall, "2026-10-03 00:31:00 - Starting sync (local → remote)", "2026-10-03 00:31:05 - Sync completed successfully"]) == nil else {
            return report(id, slug, false, "(a clean run, or a later success, reported an error)")
        }
        // An older run's stall line must not be read as the failure of a later,
        // still-unfinished run (CodeRabbit on PR #11).
        guard lastError([start, stall, "2026-10-03 00:30:02 - Sync failed with exit code 79", "2026-10-03 00:31:00 - Starting sync (local → remote)"]) == nil else {
            return report(id, slug, false, "(an older run's stall line was reported for a later unfinished run)")
        }
        // LogParser stays consistent: the stall line is not a state event of its own.
        for line in [stall, "2026-10-03 00:30:30 - Sync stalled: still running 30 s after SIGTERM — killing it"] {
            if let e = LogParser().parse(line: line), case .unknown = e.type { continue }
            else if LogParser().parse(line: line) == nil { continue }
            return report(id, slug, false, "(LogParser gave a state event for: \(line))")
        }
        guard SyncLogPatterns.isSyncStalled(stall), !SyncLogPatterns.isSyncFailed(stall),
              !SyncLogPatterns.isSyncCompleted(stall), !SyncLogPatterns.isSyncStarted(stall),
              !SyncLogPatterns.isSyncAlreadyRunning(stall), !LogWatcher.isTransitionLine(stall) else {
            return report(id, slug, false, "(pattern overlap with the stall line)")
        }
        return report(id, slug, true)
    }

    // MARK: - AC-L63-8 — A5: the stalled-sync watchdog end to end (real runChildProcess)

    /// Drives the REAL `SyncWatchDaemon.runChildProcess` (watchdog included)
    /// on the generated sync script with a stub rclone that blocks silently,
    /// SIGSTOPs that stub with /bin/kill -STOP, and records the ordered
    /// evidence. It does NOT run `limpet watch` itself (its signal handlers,
    /// scheduler, dispatchMain) — only the spawn/watchdog/escalation path.
    private static func testStalledSyncWatchdogEndToEnd() -> Bool {
        let id = "AC-L63-8", slug = "stalled-sync-watchdog-end-to-end"
        let fm = FileManager.default
        let root = "\(selfTestRoot)/ac-l63-8"
        try? fm.removeItem(atPath: root)
        let localPath = "\(root)/source", scriptPath = "\(root)/limpet-sync.sh", configPath = "\(root)/profile.json"
        let log = "\(root)/sync.log", lock = "\(root)/sync.lock", stubPath = "\(root)/rclone-stub.sh"
        let stubPidFile = "\(root)/stub.pid"
        let config: [String: Any] = [
            "remote": "selftest-fixture-remote:SelfTest", "localPath": localPath, "logPath": log, "lockFile": lock,
            "drivePath": "", "additionalFlags": "", "filterPath": "\(root)/exclude.txt",
            "syncDirection": "localToRemote", "remotePath": "SelfTest", "transfers": 4,
        ]
        func setupFailed(_ e: Error) -> Bool { report(id, slug, false, "(setup failed: \(e))") }
        do {
            try fm.createDirectory(atPath: localPath, withIntermediateDirectories: true)
            try "".write(toFile: "\(root)/exclude.txt", atomically: true, encoding: .utf8)
            try SyncSetupService.shared.generateSyncScript().write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try JSONSerialization.data(withJSONObject: config).write(to: URL(fileURLWithPath: configPath))
            // Blocks silently; `exec` keeps the pid we SIGSTOP. It ignores TERM and HUP
            // (ignored dispositions survive exec). Observed here: a STOP'd stub that did
            // not ignore TERM died when the watchdog's SIGTERM took bash down, and one that
            // ignored only TERM still died within the same moment — the likely cause is the
            // POSIX orphaned-process-group rule (SIGHUP then SIGCONT to stopped members once
            // the group leader is gone), not separately verified. With both ignored the
            // stub survives as a hung rclone would, so SIGKILL escalation is what removes it.
            try "#!/bin/sh\ntrap '' TERM HUP\necho $$ > \"\(stubPidFile)\"\nexec sleep 120\n".write(toFile: stubPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubPath)
        } catch { return setupFailed(error) }

        var env = ProcessInfo.processInfo.environment
        env["RCLONE_BIN"] = stubPath
        let timings = SyncWatchDaemon.WatchdogTimings(stallThreshold: 3, killGrace: 2, checkInterval: 0.5, groupPollInterval: 0.2)
        let t0 = Date()
        func ts() -> String { String(format: "+%.2fs", Date().timeIntervalSince(t0)) }

        var result: Int32?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            result = SyncWatchDaemon.runChildProcess(
                scriptPath: scriptPath, configPath: configPath, environment: env, logPath: log,
                log: { message in
                    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
                    appendLine("\(f.string(from: Date())) - \(message)", to: log)
                },
                timings: timings)
            done.signal()
        }

        func pidFrom(_ path: String) -> pid_t? {
            (try? String(contentsOfFile: path, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        func logText() -> String { (try? String(contentsOfFile: log, encoding: .utf8)) ?? "" }
        func alive(_ p: pid_t) -> Bool { kill(p, 0) == 0 }
        func psState(_ p: pid_t) -> String { runTool("/bin/ps", ["-o", "stat=", "-p", "\(p)"]).1.trimmingCharacters(in: .whitespacesAndNewlines) }

        var evidence: [String] = []
        var failure: String?
        var bashPid: pid_t = 0, stubPid: pid_t = 0
        var stopped = false, sawStall = false, bashGoneAt: String?, sawKill = false
        var stubAliveWhenBashGone = false, stubStateWhenBashGone = "", stubAliveEverySampleUntilKill = true
        var lastAliveSample = "", killedAt: String?, stubDeadAfterKill = false
        let deadline = Date().addingTimeInterval(30)
        while done.wait(timeout: .now() + 0.05) == .timedOut && Date() < deadline {
            if bashPid == 0, let p = pidFrom(lock) { bashPid = p }
            if stubPid == 0, let p = pidFrom(stubPidFile) { stubPid = p }
            if stubPid != 0 && !stopped {
                let r = runTool("/bin/kill", ["-STOP", "\(stubPid)"])
                stopped = r.0 == 0
                evidence.append("\(ts()) kill -STOP \(stubPid) (the child's rclone) exit \(r.0)")
            }
            let stubAliveNow = stubPid != 0 && alive(stubPid)  // sampled BEFORE the log is read
            let text = logText()
            if !sawStall, text.contains("Sync stalled: no log output") {
                sawStall = true
                evidence.append("\(ts()) log: stall line present")
            }
            if sawStall, bashGoneAt == nil, bashPid != 0, !alive(bashPid) {
                bashGoneAt = ts()
                stubAliveWhenBashGone = stubPid != 0 && alive(stubPid)
                stubStateWhenBashGone = psState(stubPid)
                evidence.append("\(bashGoneAt!) bash \(bashPid) exited after SIGTERM; STOP'd rclone \(stubPid) alive=\(stubAliveWhenBashGone) state=\(stubStateWhenBashGone)")
            }
            if bashGoneAt != nil, !sawKill, stubPid != 0 {
                // The SIGKILL goes out within ms of its log line, so "alive until the kill"
                // is the last sample taken BEFORE that line was first seen.
                if stubAliveNow { lastAliveSample = ts() } else if !text.contains("killing it") { stubAliveEverySampleUntilKill = false }
            }
            if !sawKill, text.contains("killing it") {
                sawKill = true
                killedAt = ts()
                evidence.append("\(killedAt!) log: SIGKILL escalation line (grace 2s); rclone \(stubPid) was alive at every sample from bash exit until \(lastAliveSample) = \(stubAliveEverySampleUntilKill)")
            }
            if sawKill, !stubDeadAfterKill, stubPid != 0, !alive(stubPid) {
                stubDeadAfterKill = true
                evidence.append("\(ts()) rclone \(stubPid) gone after SIGKILL")
            }
        }
        if result == nil { failure = "runChildProcess did not return in 30s"; _ = done.wait(timeout: .now() + 0.01) }
        let finished = ts()
        // Always leave nothing behind.
        if bashPid != 0 { killpg(bashPid, SIGKILL) }
        if stubPid != 0 { kill(stubPid, SIGKILL) }

        let pg = bashPid != 0 ? runTool("/usr/bin/pgrep", ["-g", "\(bashPid)"]) : (1, "")
        evidence.append("\(finished) runChildProcess returned \(String(describing: result)); `pgrep -g \(bashPid)` exit \(pg.0) output \"\(pg.1.trimmingCharacters(in: .whitespacesAndNewlines))\" (1 + empty = group gone)")

        let text = logText()
        let lines = text.split(separator: "\n").map(String.init)
        func index(_ needle: String) -> Int? { lines.firstIndex { $0.contains(needle) } }
        if failure == nil {
            if !stopped { failure = "stub never started" }
            else if !sawStall || bashGoneAt == nil || !sawKill { failure = "missing evidence stall=\(sawStall) bashGone=\(bashGoneAt != nil) kill=\(sawKill)" }
            else if !(stubAliveWhenBashGone && stubAliveEverySampleUntilKill && stubDeadAfterKill) {
                failure = "hung rclone: alive at bash exit \(stubAliveWhenBashGone), alive until kill \(stubAliveEverySampleUntilKill), gone after kill \(stubDeadAfterKill)"
            }
            else if !(pg.0 == 1 && pg.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { failure = "process group not gone" }
            else if result != 79 { failure = "returned \(String(describing: result)), expected 79" }
            else if let a = index("Sync stalled: no log output"), let b = index("killing it"), let c = index("Sync failed with exit code 79"),
                    a < b, b < c, lines.last?.contains("exit code 79") == true {
                // ordered
            } else { failure = "log lines out of order or missing: \(lines)" }
        }
        if let f = failure {
            for e in evidence { print("    A5 \(e)") }
            return report(id, slug, false, "(\(f))")
        }

        guard SyncManager.readLastErrorFromLog(log) == "Sync stalled" else {
            return report(id, slug, false, "(readLastErrorFromLog did not report the stalled run)")
        }

        // The next triggered run is not skipped by the lock: stale-PID path, then a real start.
        let lockLeft = fm.fileExists(atPath: lock)
        try? "#!/bin/sh\nexit 0\n".write(toFile: stubPath, atomically: true, encoding: .utf8)
        let before = lines.count
        let second = SyncWatchDaemon.runChildProcess(
            scriptPath: scriptPath, configPath: configPath, environment: env, logPath: log, log: { _ in }, timings: timings)
        let after = (try? String(contentsOfFile: log, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        let next = Array(after.dropFirst(before))
        evidence.append("\(ts()) next run: lock left behind=\(lockLeft), exit \(second), new log lines: \(next.filter { !$0.isEmpty })")
        guard second == 0, next.contains(where: { $0.contains("Starting sync") }),
              !next.contains(where: { $0.contains("already running") }) else {
            for e in evidence { print("    A5 \(e)") }
            return report(id, slug, false, "(the next run was skipped or failed)")
        }

        // A group `.giveUp` left alive blocks the next run until it is gone
        // (CodeRabbit on PR #11): no spawn, 79, one log line; then a normal run.
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/bin/sleep")
        holder.arguments = ["30"]
        do { try holder.run() } catch {
            return report(id, slug, false, "(could not start the holder process: \(error))")
        }
        SyncWatchDaemon.lingeringGroup = (holder.processIdentifier, false, SyncWatchDaemon.monotonicNow())
        var refusals: [String] = []
        let blockedLen = (try? String(contentsOfFile: log, encoding: .utf8))?.count ?? 0
        let blocked1 = SyncWatchDaemon.runChildProcess(
            scriptPath: scriptPath, configPath: configPath, environment: env, logPath: log, log: { refusals.append($0) }, timings: timings)
        let blocked2 = SyncWatchDaemon.runChildProcess(
            scriptPath: scriptPath, configPath: configPath, environment: env, logPath: log, log: { refusals.append($0) }, timings: timings)
        let startedWhileBlocked = ((try? String(contentsOfFile: log, encoding: .utf8))?.count ?? 0) != blockedLen
        holder.terminate()
        holder.waitUntilExit()
        let unblocked = SyncWatchDaemon.runChildProcess(
            scriptPath: scriptPath, configPath: configPath, environment: env, logPath: log, log: { _ in }, timings: timings)
        evidence.append("\(ts()) lingering group: blocked \(blocked1)/\(blocked2), refusal lines \(refusals.count), script ran while blocked \(startedWhileBlocked), after group gone exit \(unblocked)")
        guard blocked1 == 79, blocked2 == 79, refusals.count == 1, !startedWhileBlocked,
              unblocked == 0, SyncWatchDaemon.lingeringGroup.value == nil else {
            for e in evidence { print("    A5 \(e)") }
            return report(id, slug, false, "(a lingering stalled group did not block the next run, or never released it)")
        }

        // The 79 line parses to .syncFailed(79), whose text is "Sync stalled".
        guard let line = lines.first(where: { $0.contains("Sync failed with exit code 79") }),
              let event = LogParser().parse(line: line), case .syncFailed(let code, _) = event.type, code == 79,
              SyncManager.exitCodeErrorText(code) == "Sync stalled" else {
            return report(id, slug, false, "(LogParser/exitCodeErrorText did not map the 79 line)")
        }
        evidence.append("\(ts()) LogParser -> .syncFailed(exitCode: 79); exitCodeErrorText(79) == \"Sync stalled\"")
        for e in evidence { print("    A5 \(e)") }
        return report(id, slug, true)
    }


}

#endif
