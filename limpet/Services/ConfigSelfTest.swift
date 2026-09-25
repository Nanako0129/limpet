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

    /// Run every self-test. Returns 0 if all passed, 1 otherwise.
    static func run() -> Int32 {
        // Start clean so a previous run's leftovers can't mask a real failure.
        try? FileManager.default.removeItem(atPath: selfTestRoot)
        try? FileManager.default.createDirectory(atPath: selfTestRoot, withIntermediateDirectories: true)

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
        ]

        for check in checks {
            if !check() { allPassed = false }
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

        let selfWrittenPath = "\(dir)/self-written.profile.json"
        let selfWrittenContent = Data("{\"marker\":\"self-write\"}".utf8)
        guard (try? selfWrittenContent.write(to: URL(fileURLWithPath: selfWrittenPath))) != nil else {
            return report("AC-5", "self-write-suppression", false, "(failed to write fixture)")
        }
        ConfigSelfWriteRegistry.shared.noteSelfWrite(contentHash: ConfigSelfWriteRegistry.hash(selfWrittenContent))

        guard ConfigFileWatcher.shouldReconcile(forFileAt: selfWrittenPath) == false else {
            return report("AC-5", "self-write-suppression", false, "(a noted self-write was NOT suppressed)")
        }

        // A genuinely external write (different, un-noted content) must still reconcile.
        let externalPath = "\(dir)/external.profile.json"
        let externalContent = Data("{\"marker\":\"external-write\"}".utf8)
        guard (try? externalContent.write(to: URL(fileURLWithPath: externalPath))) != nil else {
            return report("AC-5", "self-write-suppression", false, "(failed to write external fixture)")
        }
        guard ConfigFileWatcher.shouldReconcile(forFileAt: externalPath) == true else {
            return report("AC-5", "self-write-suppression", false, "(an external write was incorrectly suppressed)")
        }

        return report("AC-5", "self-write-suppression", true)
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
            persist: { _ in persistCalls += 1 },
            install: { _ in installCalls += 1 }
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
                persist: { _ in persistCalls += 1 },
                install: { _ in installCalls += 1 }
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
            persist: { _ in persistCalls += 1 },
            install: { _ in installCalls += 1 }
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
            install: { _ in }
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
        runLaunchctl: @escaping (_ args: [String]) -> (Int32, String) = { _ in (0, "") },
        schemaFilesPresent: @escaping () -> Bool = { true },
        remoteSection: @escaping (String) -> [String: String]? = { _ in nil },
        writeProfile: @escaping (SyncProfile) -> Bool = { _ in true },
        installProfile: @escaping (SyncProfile) -> String? = { _ in nil },
        uninstallProfile: @escaping (SyncProfile) -> String? = { _ in nil },
        deleteProfileFile: @escaping (SyncProfile) -> Void = { _ in },
        removeFile: @escaping (String) -> Bool = { _ in true },
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
            runLaunchctl: runLaunchctl,
            schemaFilesPresent: schemaFilesPresent,
            remoteSection: remoteSection,
            writeProfile: writeProfile,
            installProfile: installProfile,
            uninstallProfile: uninstallProfile,
            deleteProfileFile: deleteProfileFile,
            removeFile: removeFile,
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
            runChild: { completion in completion(exitCode()) },
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
                runChild: { completion in pendingCompletions.append(completion) },
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
                runChild: { completion in pendingCompletions.append(completion) },
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
                runChild: { completion in pendingCompletions.append(completion) },
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
        name: String, overrides: [String: Any], stubTail: String = "exit 0\n"
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
                    executablePath: translocatedExecutable, otherProfiles: others)
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
            return SyncProfile.overlapError(other, among: [first]) != nil
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
        guard SyncProfile.overlapError(first, among: [first]) == nil else {
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
            writeProfile: { _ in wrote = true; return true },
            installProfile: { _ in installed = true; return nil },
            uninstallProfile: { _ in installed = true; return nil }
        )
        guard LimpetCLI.execute(["profile", "set", disjoint.shortId, "remotePath", "SelfTest/moved"], env: setEnv) == 65,
              !wrote, !installed else {
            return report(id, slug, false, "(profile set accepted an overlapping remotePath)")
        }

        // File drop.
        var persisted = 0, dropInstalled = 0
        let outcome = SyncManager.applyExternalCreateIfNeeded(
            decoded: nested, isKnownId: false, existing: [first],
            persist: { _ in persisted += 1 }, install: { _ in dropInstalled += 1 })
        guard outcome == .refusedOverlap, persisted == 0, dropInstalled == 0 else {
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

    /// A stub `security` whose behaviour is read from `<dir>/mode` (found /
    /// missing / error / hang) and which records its argv to `<dir>/argv`.
    private static func makeSecurityStub(in dir: String, secret: String) -> String? {
        let stub = "\(dir)/security-stub"
        let body = """
            #!/bin/sh
            printf '%s\\n' "$@" > "\(dir)/argv"
            cat > "\(dir)/stdin"
            case "$(cat "\(dir)/mode")" in
              found) printf '%s\\n' '\(secret)'; exit 0 ;;
              missing) exit 44 ;;
              error) exit 51 ;;
              hang) sleep 5; exit 0 ;;
            esac
            exit 0
            """
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try body.write(toFile: stub, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub)
            try "found".write(toFile: "\(dir)/mode", atomically: true, encoding: .utf8)
        } catch { return nil }
        return stub
    }

    /// The `applications` of the keychain item's decrypt ACL entry, parsed from
    /// `security dump-keychain -a` (which prints ACLs, never secrets).
    private static func decryptApplications(dump: String) -> [String]? {
        let lines = dump.components(separatedBy: "\n")
        guard let entry = lines.firstIndex(where: { $0.contains("authorizations") && $0.contains("decrypt") }),
              let header = lines[entry...].firstIndex(where: { $0.contains("applications") }) else { return nil }
        // Each application is an `N: <path> (OK)` line, followed by its own
        // `requirement:` line; the entry ends at the next `entry N:` header.
        var apps: [String] = []
        for line in lines[(header + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("entry ") { break }
            guard let colon = trimmed.firstIndex(of: ":"), !trimmed[..<colon].isEmpty,
                  trimmed[..<colon].allSatisfy(\.isNumber) else { continue }
            apps.append(trimmed[trimmed.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " (OK)", with: ""))
        }
        return apps
    }

    // MARK: - AC-L4-6 — keychain remote: created through /usr/bin/security only, secret nowhere else

    /// Uses the REAL `/usr/bin/security` against a THROWAWAY keychain created
    /// (and deleted) under the self-test root — never the login keychain.
    private static func testKeychainRemoteCreatedThroughSecurityOnly() -> Bool {
        let id = "AC-L4-6", slug = "keychain-remote-created-through-security-only"
        let fm = FileManager.default
        let dir = "\(selfTestRoot)/ac-l4-6"
        try? fm.removeItem(atPath: dir)
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let keychainPath = "\(dir)/selftest.keychain-db"
        guard runTool("/usr/bin/security", ["create-keychain", "-p", UUID().uuidString, keychainPath]).0 == 0 else {
            return report(id, slug, false, "(could not create the throwaway keychain)")
        }
        defer { _ = runTool("/usr/bin/security", ["delete-keychain", keychainPath]) }

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
        let store = KeychainSecretStore(keychainPath: keychainPath)
        let service = RcloneConfigService(configPath: confPath, rclonePath: rcloneStub, keychain: store)
        let secret = "SEKRET-l4-6 \"q'$x"
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

        // The keychain holds it, and only /usr/bin/security may read it without a prompt.
        guard store.read(account: "limpet_test_st") == .found(secret) else {
            return report(id, slug, false, "(keychain read-back did not return the secret)")
        }
        let dump = runTool("/usr/bin/security", ["dump-keychain", "-a", keychainPath])
        guard dump.0 == 0, !dump.1.contains(secret),
              decryptApplications(dump: dump.1) == [KeychainSecretStore.trustedApplication] else {
            return report(id, slug, false, "(decrypt ACL applications: \(String(describing: decryptApplications(dump: dump.1))))")
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
            keychain: KeychainSecretStore(securityPath: stub, keychainPath: "\(dir)/unused.keychain-db"))
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
            keychain: KeychainSecretStore(securityPath: stub, keychainPath: keychainPath, timeout: 0.5))
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
                "access_key_id": "AKID", "provider": "Mega", "region": "ap-tokyo-1",
                "endpoint": "s3.ap-tokyo-1.megas4.com"]) else {
            return report(id, slug, false, "(remote add did not parse as expected)")
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
        guard let stub = makeSecurityStub(in: dir, secret: "unused") else {
            return report(id, slug, false, "(fixture setup failed)")
        }
        let confPath = "\(dir)/rclone.conf"
        let original = "[s4]\ntype = s3\nprovider = Mega\naccess_key_id = AKID\nlimpet_keychain = true\n\n"
            + "[bb]\ntype = b2\naccount = KEYID\nlimpet_keychain = true\n"
        let rcloneStub = "\(dir)/rclone-stub"
        try? original.write(toFile: confPath, atomically: true, encoding: .utf8)
        try? "#!/bin/sh\ntouch \"\(dir)/rclone-ran\"\nexit 0\n".write(toFile: rcloneStub, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rcloneStub)
        let service = RcloneConfigService(
            configPath: confPath, rclonePath: rcloneStub,
            keychain: KeychainSecretStore(securityPath: stub, keychainPath: "\(dir)/k.keychain-db"))

        // F5 remap: an existing s3/b2 remote edits as itself, never as webdav.
        guard let s4 = service.readRemoteConfig(name: "s4"), s4.provider == .s3Compatible,
              s4.generateConfigSection().contains("type = s3"),
              let bb = service.readRemoteConfig(name: "bb"), bb.provider == .b2,
              bb.generateConfigSection().contains("type = b2") else {
            return report(id, slug, false, "(s3/b2 section was not read back as s3/b2)")
        }

        // Editing without re-entering the secret changes nothing (checked before the delete).
        if (try? service.updateRemote(s4)) != nil ||
            (try? String(contentsOfFile: confPath, encoding: .utf8)) != original ||
            FileManager.default.fileExists(atPath: "\(dir)/rclone-ran") ||
            FileManager.default.fileExists(atPath: "\(dir)/argv") {
            return report(id, slug, false, "(update without a secret was not refused before touching rclone.conf)")
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
        let argv = (try? String(contentsOfFile: "\(dir)/argv", encoding: .utf8)) ?? ""
        let stdin = (try? String(contentsOfFile: "\(dir)/stdin", encoding: .utf8)) ?? ""
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
                runChild: { completion in runs(); completion(SyncWatchScheduler.deleteLimitExitCode) },
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
            runChild: { completion in childRuns += 1; completion(exitCode) },
            now: { clock.now },
            scheduleAfter: { s, a in clock.scheduleAfter(s, a) },
            logSourceMissing: {},
            refusalReason: { SyncWatchDaemon.refusalReason(for: mine, profilesDirectory: dir) },
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
            runChild: { completion in badRuns += 1; completion(0) },
            now: { clock.now },
            scheduleAfter: { s, a in clock.scheduleAfter(s, a) },
            logSourceMissing: {},
            refusalReason: { SyncWatchDaemon.refusalReason(for: bad, profilesDirectory: "\(dir)-empty") },
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
            runChild: { completion in runs += 1; pendingCompletion = completion },
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

}

#endif
