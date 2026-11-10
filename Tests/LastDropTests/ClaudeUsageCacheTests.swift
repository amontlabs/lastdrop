import XCTest
@testable import LastDrop

/// Claude Code's cached usage answer (`cachedUsageUtilization` in `.claude.json`) stands in for a request.
final class ClaudeUsageCacheTests: LastDropTestCase {
    private let uuid = "12c3cbaa-0000-0000-0000-000000000002"
    private let other = "614646e1-0000-0000-0000-000000000001"
    private let now = Date()
    private var folder: URL!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("lastdrop-cache-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    /// A `.claude.json` signed in to `account`, with a cached answer for `cached` fetched `age` seconds ago.
    private func config(account: String? = nil, cached: String?, age: TimeInterval = 60, session: Double = 26,
                        grants: Any = NSNull()) -> [String: Any] {
        var config: [String: Any] = [:]
        if let account { config["oauthAccount"] = ["accountUuid": account, "emailAddress": "a@example.com"] }
        var cache: [String: Any] = [
            "fetchedAtMs": (now.timeIntervalSince1970 - age) * 1000,
            "utilization": [
                "five_hour": ["utilization": session, "resets_at": "2099-01-01T00:00:00+00:00"],
                "seven_day": ["utilization": 2, "resets_at": "2099-01-02T00:00:00+00:00"],
                "cedar_ember": grants,
                "spend": ["enabled": false],
            ],
        ]
        if let cached { cache["accountUuid"] = cached }
        config["cachedUsageUtilization"] = cache
        return config
    }

    @discardableResult
    private func write(_ config: [String: Any], to path: String) -> String {
        try! JSONSerialization.data(withJSONObject: config).write(to: URL(fileURLWithPath: path))
        return path
    }

    private var shared: String { ClaudeProvider.sharedConfigOverride! }
    private var accountFile: String { folder.appendingPathComponent(".claude.json").path }

    func testMatchingAccountIsRead() throws {
        let hit = try XCTUnwrap(ClaudeProvider.cachedUsage(fromConfig: config(cached: uuid), accountUUID: uuid, now: now))
        XCTAssertEqual(hit.fetchedAt.timeIntervalSince(now), -60, accuracy: 1)
        let (windows, credits) = ClaudeProvider.reading(from: hit.root)
        XCTAssertEqual(windows.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(windows.map(\.usedPercent), [26, 2])
        XCTAssertNil(credits)
    }

    func testAnotherAccountsAnswerIsIgnored() {
        XCTAssertNil(ClaudeProvider.cachedUsage(fromConfig: config(cached: other), accountUUID: uuid, now: now))
        // Claude Code may leave the account out: then it's nobody's.
        XCTAssertNil(ClaudeProvider.cachedUsage(fromConfig: config(cached: nil), accountUUID: uuid, now: now))
    }

    func testStaleOrFutureAnswerIsIgnored() {
        let age = ClaudeProvider.cacheFresh
        XCTAssertNotNil(ClaudeProvider.cachedUsage(fromConfig: config(cached: uuid, age: age - 30), accountUUID: uuid, now: now))
        XCTAssertNil(ClaudeProvider.cachedUsage(fromConfig: config(cached: uuid, age: age + 1), accountUUID: uuid, now: now))
        XCTAssertNil(ClaudeProvider.cachedUsage(fromConfig: config(cached: uuid, age: -3600), accountUUID: uuid, now: now))
    }

    func testMalformedCacheIsIgnored() {
        XCTAssertNil(ClaudeProvider.cachedUsage(fromConfig: [:], accountUUID: uuid, now: now))
        var empty = config(cached: uuid)
        empty["cachedUsageUtilization"] = ["fetchedAtMs": now.timeIntervalSince1970 * 1000, "accountUuid": uuid, "utilization": [String: Any]()]
        XCTAssertNil(ClaudeProvider.cachedUsage(fromConfig: empty, accountUUID: uuid, now: now))
    }

    func testMissingFilesAndUnknownAccount() {
        let missing = folder.appendingPathComponent("nope.json").path
        XCTAssertNil(ClaudeProvider.cachedUsage(accountUUID: uuid, files: [missing], now: now))
        try! Data("not json".utf8).write(to: URL(fileURLWithPath: accountFile))
        XCTAssertNil(ClaudeProvider.cachedUsage(accountUUID: uuid, files: [missing, accountFile], now: now))
        write(config(cached: uuid), to: accountFile)
        XCTAssertNotNil(ClaudeProvider.cachedUsage(accountUUID: uuid, files: [missing, accountFile], now: now))
        // An account that isn't signed in has no answer to match.
        XCTAssertNil(ClaudeProvider.cachedUsage(accountUUID: nil, files: [accountFile], now: now))
    }

    func testNewestMatchingFileWins() throws {
        write(config(cached: uuid, age: 300, session: 10), to: shared)
        write(config(account: uuid, cached: uuid, age: 30, session: 40), to: accountFile)
        let hit = try XCTUnwrap(ClaudeProvider.cachedUsage(accountUUID: uuid, files: [shared, accountFile], now: now))
        XCTAssertEqual(ClaudeProvider.reading(from: hit.root).0.first?.usedPercent, 40)
        // The shared file now holds another account's answer: the folder's own still serves.
        write(config(cached: other, age: 5, session: 99), to: shared)
        let own = try XCTUnwrap(ClaudeProvider.cachedUsage(accountUUID: uuid, files: [shared, accountFile], now: now))
        XCTAssertEqual(ClaudeProvider.reading(from: own.root).0.first?.usedPercent, 40)
    }

    func testProviderReadsTheSharedFileForItsOwnAccount() {
        // The folder only says who the account is; the answer is in the file every session shares.
        write(["oauthAccount": ["accountUuid": uuid]], to: accountFile)
        write(config(account: other, cached: uuid), to: shared)
        XCTAssertNotNil(ClaudeProvider(configDir: folder.path).cachedUsage())
        // Main is whoever the shared file is signed in to: here the answer is someone else's.
        XCTAssertNil(ClaudeProvider().cachedUsage())
        write(config(account: other, cached: other), to: shared)
        XCTAssertNotNil(ClaudeProvider().cachedUsage())
        XCTAssertNil(ClaudeProvider(configDir: folder.path).cachedUsage())
    }

    func testFetchServesTheCacheWithoutAskingEvenWhileBlocked() async throws {
        write(["oauthAccount": ["accountUuid": uuid]], to: accountFile)
        write(config(cached: uuid), to: shared)
        var provider = ClaudeProvider(configDir: folder.path)
        provider.lean = true   // a runner: no keychain, no plan
        let id = provider.usageID
        let until = SubagentUsage.recordBlock(id, retryAfter: 3600)
        let snapshot = try await provider.fetch()
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [26, 2])
        // The block is Anthropic's answer to lastdrop: a copy of Claude Code's doesn't end it.
        XCTAssertEqual(SubagentUsage.blockedUntil(id)!.timeIntervalSince(until), 0, accuracy: 0.01)
        // Once the copy is gone, the block refuses again.
        write(config(cached: other), to: shared)
        do {
            _ = try await provider.fetch()
            XCTFail("should be blocked")
        } catch ProviderError.rateLimited {} catch { XCTFail("\(error)") }
    }

    func testRunnerReadingKeepsTheBlockAndCorrectsThePlan() {
        let at = now.addingTimeInterval(-120)
        SubagentUsage.writeStatus(["claude-2": .init(session: 90, weekly: 50, at: now.addingTimeInterval(-3600), plan: "Pro",
                                                     blockedUntil: now.addingTimeInterval(1800), failures: 3)])
        // From Claude Code's copy: no sign-in was read, so the plan stays.
        SubagentUsage.recordReading("claude-2", session: 26, weekly: 2, at: at, credentialPlan: nil)
        var entry = SubagentUsage.readStatus()["claude-2"]
        XCTAssertEqual(entry?.session, 26)
        XCTAssertEqual(entry?.at.timeIntervalSince(at) ?? 1, 0, accuracy: 0.01)
        XCTAssertEqual(entry?.plan, "Pro")
        XCTAssertEqual(entry?.failures, 3)
        XCTAssertNotNil(SubagentUsage.blockedUntil("claude-2", now: now))
        // From Anthropic, with the sign-in's plan: the upgrade shows.
        SubagentUsage.recordReading("claude-2", session: 27, weekly: 2, at: now, credentialPlan: "Max 5x")
        entry = SubagentUsage.readStatus()["claude-2"]
        XCTAssertEqual(entry?.plan, "Max 5x")
        // An account never read before gets an entry.
        SubagentUsage.recordReading("new", session: 1, weekly: 1, at: now, credentialPlan: "Max 20x")
        XCTAssertEqual(SubagentUsage.readStatus()["new"]?.plan, "Max 20x")
    }

    func testPlanFollowsTheSignInOnlyWhenItsSizeChanged() {
        // Upgraded from Pro: the saved name would otherwise stay forever.
        XCTAssertEqual(ClaudeProvider.plan(shown: "Pro", credentials: "Max 5x"), "Max 5x")
        XCTAssertEqual(ClaudeProvider.plan(shown: "Max", credentials: "Max 20x"), "Max 20x")
        // The same plan under claude.ai's name: keep it.
        XCTAssertEqual(ClaudeProvider.plan(shown: "Ultra", credentials: "Max 20x"), "Ultra")
        XCTAssertEqual(ClaudeProvider.plan(shown: "Max", credentials: "Max 5x"), "Max")
        XCTAssertEqual(ClaudeProvider.plan(shown: nil, credentials: "Pro"), "Pro")
        XCTAssertEqual(ClaudeProvider.plan(shown: "Ultra", credentials: nil), "Ultra")
    }

    func testRenewalWaitsOnTheStoredSignIn() {
        func blob(expiresIn: TimeInterval?) -> String {
            let expiry = expiresIn.map { #", "expiresAt": \#(Int((now.timeIntervalSince1970 + $0) * 1000))"# } ?? ""
            return #"{"claudeAiOauth": {"accessToken": "token", "subscriptionType": "max"\#(expiry)}}"#
        }
        XCTAssertFalse(ClaudeSignIn.isSignedIn(nil, now: now))
        XCTAssertFalse(ClaudeSignIn.isSignedIn("{}", now: now))
        XCTAssertFalse(ClaudeSignIn.isSignedIn(blob(expiresIn: -10), now: now))
        XCTAssertFalse(ClaudeSignIn.isSignedIn(blob(expiresIn: 30), now: now))   // about to expire
        XCTAssertTrue(ClaudeSignIn.isSignedIn(blob(expiresIn: 8 * 3600), now: now))
        XCTAssertTrue(ClaudeSignIn.isSignedIn(blob(expiresIn: nil), now: now))
    }
}
