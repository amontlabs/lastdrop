import XCTest
@testable import LastDrop

final class AgentPoolTests: LastDropTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let main = Account.main(.codex), work = Account(provider: .codex, key: "work"), home = Account(provider: .codex, key: "home")

    private func status(_ session: Double?, _ weekly: Double?, minutesAgo: Double = 1) -> SubagentUsage.Status {
        .init(session: session, weekly: weekly, at: now.addingTimeInterval(-minutesAgo * 60))
    }

    private func pick(_ usage: [String: SubagentUsage.Status], full: Set<String> = []) -> String? {
        AgentPool.pick([main, work, home], usage: usage, config: AccountsConfig(), now: now, isFull: { full.contains($0) })?.id
    }

    func testPicksTheAccountWithTheMostRoom() {
        XCTAssertEqual(pick(["codex.main": status(80, 10), "codex.work": status(20, 30), "codex.home": status(5, 70)]), "codex.work")
    }

    func testTiesKeepTheOrder() {
        XCTAssertEqual(pick(["codex.main": status(10, 10), "codex.work": status(10, 10)]), "codex.main")
    }

    func testFullStaleAndUnknownAccountsAreSkipped() {
        let usage = ["codex.main": status(95, 10), "codex.work": status(1, 1, minutesAgo: 45), "codex.home": status(50, 50)]
        XCTAssertEqual(pick(usage), "codex.home")
        XCTAssertEqual(pick(usage, full: ["codex.home"]), "codex.main", "nothing with room: the first account")
    }

    func testOneWindowCountsForBoth() {
        XCTAssertNotNil(AgentPool.room(work, usage: ["codex.work": status(40, nil)], config: AccountsConfig(), now: now))
        XCTAssertNil(AgentPool.room(work, usage: ["codex.work": status(nil, nil)], config: AccountsConfig(), now: now))
    }

    func testNextIsTheAccountWithMostRoom() {
        let main = Account.main(.codex)
        func next(_ usage: [String: SubagentUsage.Status]) -> String? {
            AgentPool.next([main, work], usage: usage, config: AccountsConfig(), now: now)?.key
        }
        XCTAssertEqual(next(["codex.main": status(1, 1), "codex.work": status(5, 48)]), "main")
        XCTAssertEqual(next(["codex.main": status(95, 1), "codex.work": status(5, 48)]), "work")
        XCTAssertNil(next(["codex.main": status(95, 1), "codex.work": status(95, 48)]), "nothing has room")
    }

    func testNextTreatsOtherProvidersMainLikeAnyAccount() {
        let usage = ["codex.main": status(10, 10), "codex.work": status(50, 50), "codex.home": status(95, 1)]
        XCTAssertEqual(AgentPool.next([main, work, home], usage: usage, config: AccountsConfig(), now: now), main)
        XCTAssertNil(AgentPool.next([home], usage: usage, config: AccountsConfig(), now: now))
    }

    func testClaudeAccountsKeepTheirUsageKeys() {
        XCTAssertEqual(AgentPool.usageKey(Account(provider: .claude, key: "Pro")), "Pro")
        XCTAssertEqual(AgentPool.usageKey(work), "codex.work")
    }

    func testOnlyProvidersWithSeparateLoginsPool() {
        XCTAssertTrue(AgentPool.pools(.codex))
        XCTAssertTrue(AgentPool.pools(.zai))
        XCTAssertFalse(AgentPool.pools(.antigravity))
        XCTAssertEqual(AgentPool.place(.main(.zai)), "Z.ai")
        XCTAssertEqual(AgentPool.place(Account(provider: .zai, key: "zai-2", name: "Team")), "Z.ai · Team")
    }

    func testEachAddedAccountGetsItsOwnEndpointProfile() {
        XCTAssertTrue(EndpointProfile.directory(for: .zai, account: .main(.zai)).hasSuffix("/endpoints/zai"))
        XCTAssertTrue(EndpointProfile.directory(for: .zai, account: Account(provider: .zai, key: "zai-2")).hasSuffix("/endpoints/zai.zai-2"))
    }
}
