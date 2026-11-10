import XCTest
@testable import LastDrop

/// An account's profile: `~/.claude` through links, and a `.claude.json` that is Main's with the account's own keys.
final class ClaudeProfileTests: LastDropTestCase {
    private let mainUUID = "614646e1-0000-0000-0000-000000000001"
    private let otherUUID = "12c3cbaa-0000-0000-0000-000000000002"
    private let account = ClaudeAccount(id: "claude-2")
    private var folder: String { account.cliConfigDir! }
    private var shared: String { ClaudeProfile.sharedOverride! }
    private var mainFile: String { ClaudeProvider.sharedConfigOverride! }
    private var profile: String { ClaudeProfile.directory(folder: folder) }
    private let fm = FileManager.default

    override func setUp() {
        super.setUp()   // the account's folder and `~/.claude` are in the test's own folder, removed with it
        try! fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try! fm.createDirectory(atPath: shared, withIntermediateDirectories: true)
    }

    private func write(_ config: [String: Any], to path: String) {
        try! JSONSerialization.data(withJSONObject: config).write(to: URL(fileURLWithPath: path))
    }

    private func read(_ path: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))) as? [String: Any] ?? [:]
    }

    private func usage(_ uuid: String, at: Double = 1) -> [String: Any] { ["accountUuid": uuid, "fetchedAtMs": at] }

    private func mainConfig() -> [String: Any] {
        ["oauthAccount": ["accountUuid": mainUUID], "cachedUsageUtilization": usage(mainUUID),
         "modelAccessCache": ["main"], "userID": "main-device", "startupPrefetchedAt": 1,
         "mcpServers": ["t3": ["command": "t3"]], "projects": ["/repo": ["hasTrustDialogAccepted": true]],
         "hasCompletedOnboarding": true, "numStartups": 501, "someKeyFromTheFuture": "shared"]
    }

    // MARK: Which keys

    func testCachesAndAccountKeysAreOwnEverythingElseIsShared() {
        // Everything Claude Code 2.1.321 clears when signing out.
        for key in ["oauthAccount", "managedSettingsNoticeSeenOrg", "additionalModelOptionsCache", "additionalModelOptionsAnsweredAt",
                    "additionalModelCostsCache", "modelAccessCache", "orgModelDefaultCache", "cachedArtifactRoster",
                    "artifactRosterDenied", "lastSeenOrgDefaultUpdatedAt", "clientDataCache", "clientDataCacheSlots",
                    "autoCompactWindowsCache", "cachedUsageUtilization", "metricsStatusCache", "metricsStatusCacheByPrincipal",
                    "githubWebConnectionStatusCache", "unusedLimitResetStatusCache", "startupPrefetchedAt"] {
            XCTAssertTrue(ClaudeProfile.isOwn(key), key)
        }
        for key in ["cachedExtraUsageDisabledReason", "cachedGrowthBookFeatures", "passesEligibilityCache", "userID"] {
            XCTAssertTrue(ClaudeProfile.isOwn(key), key)
        }
        for key in ["mcpServers", "projects", "hasCompletedOnboarding", "numStartups", "githubRepoPaths", "tipsHistory",
                    "installMethod", "someKeyFromTheFuture"] {
            XCTAssertFalse(ClaudeProfile.isOwn(key), key)
        }
    }

    func testMergedIsMainsConfigWithTheAccountsOwnKeys() {
        let own: [String: Any] = ["oauthAccount": ["accountUuid": otherUUID], "cachedUsageUtilization": usage(otherUUID),
                                  "mcpServers": ["stale": [:]], "numStartups": 2, "onlyInTheAccount": true]
        let config = ClaudeProfile.merged(main: mainConfig(), own: own)
        XCTAssertEqual(config.dict("oauthAccount")?.string("accountUuid"), otherUUID)
        XCTAssertEqual(config.dict("cachedUsageUtilization")?.string("accountUuid"), otherUUID)
        // Main's own keys never reach the account, even those the account doesn't have.
        XCTAssertNil(config["modelAccessCache"])
        XCTAssertNil(config["userID"])
        XCTAssertNil(config["startupPrefetchedAt"])
        // Shared keys are exactly Main's: a server removed there is gone here too.
        XCTAssertEqual(config.dict("mcpServers")?.keys.sorted(), ["t3"])
        XCTAssertEqual(config["numStartups"] as? Int, 501)
        XCTAssertEqual(config["someKeyFromTheFuture"] as? String, "shared")
        XCTAssertNil(config["onlyInTheAccount"])
    }

    func testOwnStateFollowsTheProfileUntilTheFolderIsSignedInElsewhere() {
        let profile: [String: Any] = ["oauthAccount": ["accountUuid": otherUUID], "cachedUsageUtilization": usage(otherUUID, at: 9)]
        let sameFolder: [String: Any] = ["oauthAccount": ["accountUuid": otherUUID], "cachedUsageUtilization": usage(otherUUID, at: 1)]
        let own = ClaudeProfile.ownState(profile: profile, folder: sameFolder)
        XCTAssertEqual(own.dict("cachedUsageUtilization")?["fetchedAtMs"] as? Double, 9)
        // New profile, or one that never knew its account: the folder's sign-in.
        XCTAssertEqual(ClaudeProfile.ownState(profile: nil, folder: sameFolder).dict("oauthAccount")?.string("accountUuid"), otherUUID)
        XCTAssertEqual(ClaudeProfile.ownState(profile: [:], folder: sameFolder).dict("oauthAccount")?.string("accountUuid"), otherUUID)
        // The folder was signed in to another account: the profile's answers are that other account's no more.
        let moved = ClaudeProfile.ownState(profile: profile, folder: ["oauthAccount": ["accountUuid": "new"]])
        XCTAssertEqual(moved.dict("oauthAccount")?.string("accountUuid"), "new")
        XCTAssertNil(moved["cachedUsageUtilization"])
        // No folder config: the profile stands.
        XCTAssertEqual(ClaudeProfile.ownState(profile: profile, folder: nil).dict("oauthAccount")?.string("accountUuid"), otherUUID)
        XCTAssertTrue(ClaudeProfile.ownState(profile: nil, folder: nil).isEmpty)
    }

    // MARK: The folder

    func testPrepareBuildsTheProfileAndLeavesEverythingElseAlone() throws {
        write(mainConfig(), to: mainFile)
        let mainBefore = try Data(contentsOf: URL(fileURLWithPath: mainFile))
        let folderConfig: [String: Any] = ["oauthAccount": ["accountUuid": otherUUID], "userID": "other-device", "projects": [:]]
        write(folderConfig, to: folder + "/.claude.json")
        try fm.createDirectory(atPath: folder + "/projects/old", withIntermediateDirectories: true)   // from the earlier design
        for name in ["projects", "plugins", "backups", "sessions"] { try fm.createDirectory(atPath: shared + "/" + name, withIntermediateDirectories: true) }
        for name in ["settings.json", "CLAUDE.md", "imported.md", ".last-cleanup", ".claude.json", "mcp-needs-auth-cache.json", "remote-settings.json"] {
            try Data("{}".utf8).write(to: URL(fileURLWithPath: shared + "/" + name))
        }

        XCTAssertEqual(ClaudeProfile.prepare(folder: folder), profile)

        // Folders and the user's files are Main's; the config, its backups and Claude Code's own files aren't linked.
        for name in ["projects", "plugins", "sessions", "settings.json", "CLAUDE.md", "imported.md"] {
            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: profile + "/" + name), shared + "/" + name, name)
        }
        for name in ["backups", ".last-cleanup", "mcp-needs-auth-cache.json", "remote-settings.json"] {
            XCTAssertNil(try? fm.attributesOfItem(atPath: profile + "/" + name), name)
        }
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: profile + "/.claude.json"))
        let config = read(profile + "/.claude.json")
        XCTAssertEqual(config.dict("oauthAccount")?.string("accountUuid"), otherUUID)
        XCTAssertEqual(config.string("userID"), "other-device")
        XCTAssertNil(config["cachedUsageUtilization"])
        XCTAssertEqual(config.dict("mcpServers")?.keys.sorted(), ["t3"])
        XCTAssertNotNil(config.dict("projects")?["/repo"])
        XCTAssertEqual(try fm.attributesOfItem(atPath: profile + "/.claude.json")[.posixPermissions] as? Int, 0o600)
        XCTAssertNil(try? fm.attributesOfItem(atPath: profile + "/.claude.json.lock"))

        // Main's config, the sign-in folder and its old conversations are as they were.
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: mainFile)), mainBefore)
        XCTAssertTrue(NSDictionary(dictionary: read(folder + "/.claude.json")).isEqual(to: folderConfig))
        XCTAssertTrue(fm.fileExists(atPath: folder + "/projects/old"))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: shared + "/projects"), [])
    }

    func testNextStartKeepsTheAccountsAnswersAndTakesMainsChanges() {
        write(mainConfig(), to: mainFile)
        write(["oauthAccount": ["accountUuid": otherUUID]], to: folder + "/.claude.json")
        XCTAssertNotNil(ClaudeProfile.prepare(folder: folder))
        // A session on the account keeps its answer, and adds a server in its own file.
        var config = read(profile + "/.claude.json")
        config["cachedUsageUtilization"] = usage(otherUUID, at: 42)
        config["mcpServers"] = ["t3": [:], "addedInTheAccount": [:]]
        write(config, to: profile + "/.claude.json")
        // Meanwhile Main fetched its own usage and the user changed its servers.
        var main = mainConfig()
        main["cachedUsageUtilization"] = usage(mainUUID, at: 77)
        main["mcpServers"] = ["linear": [:]]
        write(main, to: mainFile)

        XCTAssertNotNil(ClaudeProfile.prepare(folder: folder))
        config = read(profile + "/.claude.json")
        XCTAssertEqual(config.dict("cachedUsageUtilization")?.string("accountUuid"), otherUUID)
        XCTAssertEqual(config.dict("cachedUsageUtilization")?["fetchedAtMs"] as? Double, 42)
        XCTAssertEqual(config.dict("mcpServers")?.keys.sorted(), ["linear"])
        XCTAssertEqual(read(mainFile).dict("cachedUsageUtilization")?.string("accountUuid"), mainUUID)
    }

    func testNothingInTheProfileIsReplaced() throws {
        write(mainConfig(), to: mainFile)
        try fm.createDirectory(atPath: shared + "/projects", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: shared + "/tasks", withIntermediateDirectories: true)
        // Claude Code made a folder in the profile before `~/.claude` had one, and a link points elsewhere.
        try fm.createDirectory(atPath: profile + "/tasks", withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: URL(fileURLWithPath: profile + "/tasks/a"))
        try fm.createSymbolicLink(atPath: profile + "/projects", withDestinationPath: "/nonexistent-elsewhere")
        XCTAssertNotNil(ClaudeProfile.prepare(folder: folder))
        XCTAssertEqual(try String(contentsOfFile: profile + "/tasks/a", encoding: .utf8), "kept")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: profile + "/projects"), "/nonexistent-elsewhere")
        // What `~/.claude` gains later is linked at the next start.
        try fm.createDirectory(atPath: shared + "/skills", withIntermediateDirectories: true)
        XCTAssertNotNil(ClaudeProfile.prepare(folder: folder))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: profile + "/skills"), shared + "/skills")
    }

    func testUnchangedConfigIsNotRewritten() throws {
        write(mainConfig(), to: mainFile)
        XCTAssertNotNil(ClaudeProfile.prepare(folder: folder))
        let file = profile + "/.claude.json"
        // A session saved it since, in Claude Code's own layout: the same config still.
        write(read(file), to: file)
        let old = Date(timeIntervalSince1970: 1_000_000)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: file)
        XCTAssertNotNil(ClaudeProfile.prepare(folder: folder))
        XCTAssertEqual(try fm.attributesOfItem(atPath: file)[.modificationDate] as? Date, old)
    }

    func testManyRunnersStartingAtOnceLeaveOneWholeConfig() throws {
        write(mainConfig(), to: mainFile)
        write(["oauthAccount": ["accountUuid": otherUUID]], to: folder + "/.claude.json")
        let folder = folder, profile = profile
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            XCTAssertEqual(ClaudeProfile.prepare(folder: folder), profile)
        }
        let config = read(profile + "/.claude.json")
        XCTAssertEqual(config.dict("oauthAccount")?.string("accountUuid"), otherUUID)
        XCTAssertEqual(config.dict("mcpServers")?.keys.sorted(), ["t3"])
        // No lock and no half-written file is left behind.
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: profile), [".claude.json"])
    }

    func testAHeldLockOrAnUnreadableMainConfigLeavesTheProfileAsItIs() throws {
        // No profile yet and nothing to build it from: the session runs in `~/.claude`.
        XCTAssertNil(ClaudeProfile.prepare(folder: folder))
        try Data("{ half a fi".utf8).write(to: URL(fileURLWithPath: mainFile))
        XCTAssertNil(ClaudeProfile.prepare(folder: folder))
        let neverAdded = ClaudeAccount(id: "never-added").cliConfigDir!
        XCTAssertNil(ClaudeProfile.prepare(folder: neverAdded))
        XCTAssertFalse(fm.fileExists(atPath: neverAdded))

        write(mainConfig(), to: mainFile)
        XCTAssertNotNil(ClaudeProfile.prepare(folder: folder))
        let file = profile + "/.claude.json"
        let before = try Data(contentsOf: URL(fileURLWithPath: file))
        // Main's config is being rewritten, or unreadable: the profile from last time still serves.
        try Data("{ half a fi".utf8).write(to: URL(fileURLWithPath: mainFile))
        XCTAssertEqual(ClaudeProfile.prepare(folder: folder), profile)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: file)), before)
        // A Claude Code session holds the config lock: its save isn't crossed, and its lock is left alone.
        var main = mainConfig()
        main["numStartups"] = 502
        write(main, to: mainFile)
        try fm.createDirectory(atPath: file + ".lock", withIntermediateDirectories: false)
        XCTAssertEqual(ClaudeProfile.prepare(folder: folder), profile)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: file)), before)
        XCTAssertTrue(fm.fileExists(atPath: file + ".lock"))
        try fm.removeItem(atPath: file + ".lock")
        XCTAssertEqual(ClaudeProfile.prepare(folder: folder), profile)
        XCTAssertEqual(read(file)["numStartups"] as? Int, 502)
    }

    // MARK: Where it's used

    func testRunEnvironmentRunsAnAccountInItsProfile() {
        write(["oauthAccount": ["accountUuid": otherUUID]], to: folder + "/.claude.json")
        let base = ["PATH": "/bin", "CLAUDE_CONFIG_DIR": "/elsewhere", "CLAUDE_CODE_ACCOUNT_UUID": "u1"]
        // Without Main's config there's no profile: the account's sign-in in `~/.claude`, as before.
        XCTAssertNil(account.runEnvironment(from: base)["CLAUDE_CONFIG_DIR"])
        write(mainConfig(), to: mainFile)
        let env = account.runEnvironment(from: base)
        XCTAssertEqual(env["CLAUDE_CONFIG_DIR"], profile)
        XCTAssertEqual(env["CLAUDE_SECURESTORAGE_CONFIG_DIR"], folder)
        XCTAssertEqual(read(profile + "/.claude.json").dict("oauthAccount")?.string("accountUuid"), otherUUID)
        // The runner drops the caller's identity and keeps the account's profile.
        let runner = SubagentRunner.environment(for: account, from: base)
        XCTAssertEqual(runner["CLAUDE_CONFIG_DIR"], env["CLAUDE_CONFIG_DIR"])
        XCTAssertNil(runner["CLAUDE_CODE_ACCOUNT_UUID"])
        // Main is never given a profile.
        let main = ClaudeAccount(id: "main").runEnvironment(from: base)
        XCTAssertNil(main["CLAUDE_CONFIG_DIR"])
        XCTAssertNil(main["CLAUDE_SECURESTORAGE_CONFIG_DIR"])
    }

    func testUsageCacheIsReadFromTheProfile() {
        write(mainConfig(), to: mainFile)
        write(["oauthAccount": ["accountUuid": otherUUID]], to: folder + "/.claude.json")
        XCTAssertNotNil(ClaudeProfile.prepare(folder: folder))
        let provider = ClaudeProvider(configDir: folder)
        XCTAssertEqual(provider.cacheFiles, [mainFile, profile + "/.claude.json", folder + "/.claude.json"])
        XCTAssertNil(provider.cachedUsage())
        var config = read(profile + "/.claude.json")
        config["cachedUsageUtilization"] = [
            "accountUuid": otherUUID, "fetchedAtMs": (Date().timeIntervalSince1970 - 60) * 1000,
            "utilization": ["five_hour": ["utilization": 26, "resets_at": "2099-01-01T00:00:00+00:00"]],
        ]
        write(config, to: profile + "/.claude.json")
        XCTAssertNotNil(provider.cachedUsage())
    }
}
