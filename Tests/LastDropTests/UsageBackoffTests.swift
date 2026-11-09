import XCTest
@testable import LastDrop

final class UsageBackoffTests: LastDropTestCase {
    private let account = ClaudeAccount(id: "claude-2")
    private let now = Date()

    private func save(_ status: [String: SubagentUsage.Status]) { SubagentUsage.writeStatus(status) }

    func testOneProcessBlocksTheOthers() async {
        XCTAssertNil(SubagentUsage.blockedUntil("claude-2"))
        let until = SubagentUsage.recordBlock("claude-2", retryAfter: nil, now: now)
        XCTAssertEqual(until.timeIntervalSince(now), 300, accuracy: 1)
        // Another process sees it in the file.
        XCTAssertEqual(SubagentUsage.blockedUntil("claude-2", now: now)!.timeIntervalSince(until), 0, accuracy: 0.01)
        // And a provider fetch refuses before touching the keychain or the network.
        do {
            _ = try await ClaudeProvider(configDir: "/tmp/.claude-accounts/claude-2").fetch()
            XCTFail("should be blocked")
        } catch ProviderError.rateLimited(let message) {
            XCTAssertTrue(message.contains("Retrying in"), message)
        } catch { XCTFail("\(error)") }
    }

    func testBackoffGrowsAndIsCapped() {
        XCTAssertEqual([1, 2, 3, 4, 5].map { SubagentUsage.backoff(failures: $0) }, [300, 600, 1200, 1800, 1800])
        var t = now
        var waits: [TimeInterval] = []
        for _ in 0..<3 {
            let until = SubagentUsage.recordBlock("claude-2", retryAfter: nil, now: t)
            waits.append(until.timeIntervalSince(t))
            t = until.addingTimeInterval(1)
        }
        XCTAssertEqual(waits, [300, 600, 1200])
    }

    func testABurstCountsOnceAndServerRetryAfterWins() {
        let first = SubagentUsage.recordBlock("claude-2", retryAfter: 900, now: now)
        XCTAssertEqual(first.timeIntervalSince(now), 900, accuracy: 1)
        XCTAssertEqual(SubagentUsage.recordBlock("claude-2", retryAfter: nil, now: now).timeIntervalSince(first), 0, accuracy: 0.01)
        XCTAssertEqual(SubagentUsage.readStatus()["claude-2"]?.failures, 1)
    }

    func testSuccessClearsTheBlock() {
        SubagentUsage.recordBlock("claude-2", retryAfter: nil, now: now)
        SubagentUsage.clearBlock("claude-2")
        XCTAssertNil(SubagentUsage.blockedUntil("claude-2"))
        XCTAssertNil(SubagentUsage.readStatus()["claude-2"]?.failures)
    }

    func testRecentReadingIsUsedWhileBlocked() async {
        save(["claude-2": .init(session: 26, weekly: 2, at: Date().addingTimeInterval(-90 * 60),
                                blockedUntil: Date().addingTimeInterval(600), failures: 2)])
        let usage = await SubagentUsage().usage(account)
        XCTAssertEqual(usage.session, 26)
        XCTAssertEqual(usage.weekly, 2)
    }

    func testReadingOlderThanTwoHoursIsUnknownWhileBlocked() async {
        save(["claude-2": .init(session: 26, weekly: 2, at: Date().addingTimeInterval(-3 * 3600),
                                blockedUntil: Date().addingTimeInterval(600), failures: 1)])
        let usage = await SubagentUsage().usage(account)
        XCTAssertNil(usage.session)
        XCTAssertNil(usage.weekly)
    }

    func testRunnerUsesTheAppsFreshReadingWithoutFetching() async {
        // 14 minutes old: the app is running, so nothing is fetched and the reading comes back as is.
        save(["claude-2": .init(session: 40, weekly: 10, at: Date().addingTimeInterval(-14 * 60))])
        let usage = await SubagentUsage().usage(account)
        XCTAssertEqual(usage.session, 40)
        XCTAssertNil(SubagentUsage.blockedUntil("claude-2"))
    }

    func testOldStatusFilesDecode() throws {
        let json = #"{"main":{"session":5,"weekly":1,"at":800000000,"plan":"Max 20x"},"Pro":{"session":null,"weekly":null,"at":800000000}}"#
        let status = try JSONDecoder.lastdrop.decode([String: SubagentUsage.Status].self, from: Data(json.utf8))
        XCTAssertEqual(status["main"]?.plan, "Max 20x")
        XCTAssertNil(status["main"]?.blockedUntil)
        XCTAssertNil(status["Pro"]?.failures)
    }

    func testPoolKeepsABlockedAccountsReadingLonger() {
        let config = AccountsConfig()
        let acct = Account.main(.claude)
        let old = now.addingTimeInterval(-90 * 60)
        let plain = SubagentUsage.Status(session: 26, weekly: 2, at: old)
        var blocked = plain
        blocked.blockedUntil = now.addingTimeInterval(300)
        XCTAssertNil(AgentPool.room(acct, usage: ["main": plain], config: config, now: now))
        XCTAssertNotNil(AgentPool.room(acct, usage: ["main": blocked], config: config, now: now))
    }
}
