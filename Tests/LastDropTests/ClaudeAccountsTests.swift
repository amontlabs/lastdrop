import XCTest
@testable import LastDrop

final class ClaudeAccountsTests: LastDropTestCase {
    // MARK: Accounts

    func testKeychainServiceMatchesClaudeCode() {
        XCTAssertEqual(ClaudeProvider.keychainService(configDir: nil), "Claude Code-credentials")
        // sha256("/Users/x/.claude-accounts/Pro")[0..<8], as Claude Code 2.1.310 names it.
        XCTAssertEqual(ClaudeProvider.keychainService(configDir: "/Users/x/.claude-accounts/Pro"), "Claude Code-credentials-71aaf74d")
    }

    func testFolders() {
        XCTAssertNil(ClaudeAccount(id: "main").cliConfigDir)
        XCTAssertTrue(ClaudeAccount(id: "Pro").cliConfigDir!.hasSuffix("/.claude-accounts/Pro"))
    }

    func testSlug() {
        XCTAssertEqual(ClaudeAccount.slug("Pro"), "Pro")
        XCTAssertEqual(ClaudeAccount.slug("  my work/acct "), "my-work-acct")
        XCTAssertEqual(ClaudeAccount.slug("../"), "")
    }

    func testNormalizeKeepsOneMainAndAddsAccounts() {
        var c = ClaudeAccountsConfig()
        c.accounts = [ClaudeAccount(id: "Pro")]
        c.order = ["gone", "main", "main"]
        c.normalize()
        XCTAssertEqual(c.order, ["main", "Pro"])
        c.order = ["Pro"]
        c.normalize()
        XCTAssertEqual(c.order, ["main", "Pro"])
        XCTAssertEqual(c.ordered.map(\.id), ["main", "Pro"])
    }

    func testOldThresholdFileStillLoads() throws {
        let config = try JSONDecoder.lastdrop.decode(ClaudeAccountsConfig.self, from: Data(#"{"order":["main"],"newSessionThreshold":0.85}"#.utf8))
        XCTAssertEqual(config.sessionThreshold, ClaudeAccountsConfig.defaultThreshold)
    }
}

final class LimitResetsTests: LastDropTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    func testClaudeResetGrants() {
        let block: [String: Any] = ["eligible": true, "next_grant_id": "g1", "grants": [
            ["id": "g1", "resets_left": 2, "ends_at": "2026-11-05T07:59:00+00:00", "clears": ["five_hour", "seven_day"]],
            ["id": "g0", "resets_left": 0, "ends_at": "2026-11-01T00:00:00+00:00"],
            ["id": "old", "resets_left": 1, "ends_at": "2020-01-01T00:00:00+00:00"],
        ]]
        let r = ClaudeProvider.resetGrants(from: block, now: now)
        XCTAssertEqual(r?.count, 2)
        XCTAssertEqual(r?.expiries.count, 2)
        XCTAssertNil(ClaudeProvider.resetGrants(from: NSNull()))
        XCTAssertEqual(ClaudeProvider.resetGrants(from: ["eligible": false, "grants": block["grants"]!], now: now)?.count, 0)
        XCTAssertNil(ClaudeProvider.resetGrants(from: ["eligible": true, "grants": [["id": "x"]]], now: now))   // malformed
    }

    func testCodexResetCredits() {
        let r = CodexProvider.resetCredits(from: ["available_count": 2, "credits": [
            ["status": "available", "expires_at": "2026-11-03T10:00:00Z"],
            ["expires_at": 1_793_500_000],
            ["status": "consumed", "expires_at": "2026-11-01T10:00:00Z"],
        ]])
        XCTAssertEqual(r?.count, 2)
        XCTAssertEqual(r?.expiries.count, 2)
        XCTAssertEqual(CodexProvider.resetCredits(from: ["available_count": 1])?.expiries, [])
        XCTAssertNil(CodexProvider.resetCredits(from: ["available_count": NSNull()]))
    }

    func testExpiredResetsDrop() {
        let r = LimitResets(count: 3, expiries: [now.addingTimeInterval(-10), now.addingTimeInterval(3600), now.addingTimeInterval(3600)])
        XCTAssertEqual(r.current(now: now), LimitResets(count: 2, expiries: [now.addingTimeInterval(3600), now.addingTimeInterval(3600)]))
    }

    func testTooltipGroupsSameDeadline() {
        let r = LimitResets(count: 3, expiries: [now.addingTimeInterval(3600), now.addingTimeInterval(3600), now.addingTimeInterval(86400 * 3)])
        let text = ResetBadge.tooltip(r, now: now)
        XCTAssertTrue(text.hasPrefix("3 limit resets to spend. Expire 2 in 1h"), text)
        XCTAssertTrue(text.contains("in 3d"), text)
    }
}
