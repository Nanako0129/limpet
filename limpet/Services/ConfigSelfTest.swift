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
            testGeneratedPlistShape,
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
        let json = SyncSetupService.shared.generateProfileConfig(for: profile)

        let forbidden = ["\"isEnabled\"", "\"isMuted\""]
        for key in forbidden where json.contains(key) {
            return report("AC-2", "derived-json-frozen", false, "(unexpectedly contains \(key))")
        }

        let requiredFrozenKeys = ["\"profileId\"", "\"remote\"", "\"localPath\"", "\"syncIntervalMinutes\""]
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
        runRclone: @escaping (_ args: [String], _ timeout: TimeInterval) -> (Int32, String, String) = { _, _ in (0, "", "") },
        readProfiles: @escaping () -> [SyncProfile] = { [] },
        fileExists: @escaping (String) -> Bool = { _ in false },
        runLaunchctl: @escaping (_ args: [String]) -> (Int32, String) = { _ in (0, "") },
        schemaFilesPresent: @escaping () -> Bool = { true },
        writeProfile: @escaping (SyncProfile) -> Bool = { _ in true },
        installProfile: @escaping (SyncProfile) -> String? = { _ in nil },
        uninstallProfile: @escaping (SyncProfile) -> String? = { _ in nil },
        deleteProfileFile: @escaping (SyncProfile) -> Void = { _ in },
        readStdin: @escaping () -> String? = { nil },
        readFile: @escaping (String) -> String? = { _ in nil },
        stdout: @escaping (String) -> Void = { _ in },
        stderr: @escaping (String) -> Void = { _ in }
    ) -> CLIEnvironment {
        CLIEnvironment(
            runRclone: runRclone,
            readProfiles: readProfiles,
            fileExists: fileExists,
            runLaunchctl: runLaunchctl,
            schemaFilesPresent: schemaFilesPresent,
            writeProfile: writeProfile,
            installProfile: installProfile,
            uninstallProfile: uninstallProfile,
            deleteProfileFile: deleteProfileFile,
            readStdin: readStdin,
            readFile: readFile,
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
        let listEnv = fakeCLIEnvironment(runRclone: { args, _ in
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
            runRclone: { args, _ in args.first == "version" ? (0, "rclone v1.66.0", "") : (0, "", "") },
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
        let noRcloneEnv = fakeCLIEnvironment(runRclone: { _, _ in (127, "", "not found") })
        let noRcloneChecks = LimpetCLI.doctorChecks(env: noRcloneEnv)
        guard noRcloneChecks.contains(where: { $0.name == "rclone" && $0.status == .fail }) else {
            return report("AC-CLI2", "doctor-pure-checks", false, "(rclone-absent env did not produce a .fail rclone check)")
        }
        guard LimpetCLI.run(.doctor, env: noRcloneEnv) != 0 else {
            return report("AC-CLI2", "doctor-pure-checks", false, "(rclone-absent doctor run did not exit non-zero)")
        }

        // schema missing → .warn only, exit still 0.
        let noSchemaEnv = fakeCLIEnvironment(
            runRclone: { args, _ in args.first == "version" ? (0, "rclone v1.66.0", "") : (0, "", "") },
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
            runRclone: { args, _ in args.first == "version" ? (0, "rclone v1.66.0", "") : (0, "", "") },
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
            runRclone: { args, _ in args.first == "version" ? (0, "rclone v1.66.0", "") : (0, "", "") },
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
            runRclone: { args, _ in args.first == "version" ? (0, "rclone v1.66.0", "") : (0, "", "") },
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
              contents.contains("exec \"/tmp/fake-limpet-binary\" \"$@\"") else {
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
            logSourceMissing: { onLogSourceMissing?() }
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
                logSourceMissing: {}
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
                logSourceMissing: {}
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
                logSourceMissing: {}
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

    // MARK: - AC-W3 — generated launchd plist shape (limpet-plan.md L3(c))

    private static func testGeneratedPlistShape() -> Bool {
        let profile = sampleProfile()
        let plist = SyncSetupService.shared.generateLaunchdPlist(for: profile)

        guard plist.contains("<key>KeepAlive</key>"), plist.contains("<true/>") else {
            return report("AC-W3", "watch-plist-shape", false, "(missing KeepAlive true)")
        }
        guard plist.contains("<key>RunAtLoad</key>") else {
            return report("AC-W3", "watch-plist-shape", false, "(missing RunAtLoad)")
        }
        guard !plist.contains("StartInterval") else {
            return report("AC-W3", "watch-plist-shape", false, "(still has StartInterval)")
        }
        guard let programArgsRange = plist.range(of: "<key>ProgramArguments</key>") else {
            return report("AC-W3", "watch-plist-shape", false, "(missing ProgramArguments)")
        }
        let afterProgramArgs = plist[programArgsRange.upperBound...]
        guard let arrayClose = afterProgramArgs.range(of: "</array>") else {
            return report("AC-W3", "watch-plist-shape", false, "(ProgramArguments array not closed)")
        }
        let argsBlock = afterProgramArgs[..<arrayClose.lowerBound]
        guard argsBlock.contains("<string>watch</string>"),
              argsBlock.contains("<string>\(profile.shortId)</string>") else {
            return report(
                "AC-W3", "watch-plist-shape", false,
                "(ProgramArguments does not end with watch, <shortId>)")
        }

        return report("AC-W3", "watch-plist-shape", true)
    }

}

#endif
