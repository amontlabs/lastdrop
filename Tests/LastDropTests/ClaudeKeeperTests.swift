import XCTest
@testable import LastDrop

/// The keeper's rules and the shared file's: sign-ins renewed ahead of expiry, problems only the user can fix,
/// readings that stay right as they age.
final class ClaudeKeeperTests: LastDropTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func facts(expires: TimeInterval?, ends: TimeInterval? = 30 * 86400, refresh: Bool = true, ended: String? = nil) -> ClaudeProvider.SignInFacts {
        .init(expiresAt: expires.map { now.addingTimeInterval($0) }, endsAt: ends.map { now.addingTimeInterval($0) },
              hasRefreshToken: refresh, loginEnded: ended)
    }

    // MARK: Reading Claude Code's blob

    func testSignInFactsReadClaudeCodesBlob() {
        let raw = #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1800000000000,"refreshTokenExpiresAt":1802000000000,"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}"#
        let f = ClaudeProvider.signInFacts(from: raw)
        XCTAssertEqual(f?.expiresAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(f?.endsAt, Date(timeIntervalSince1970: 1_802_000_000))
        XCTAssertEqual(f?.hasRefreshToken, true)
        XCTAssertEqual(f?.plan, "Max 20x")
        // What Claude Code leaves after Anthropic refused the refresh token (invalid_grant).
        let dead = ClaudeProvider.signInFacts(from: #"{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0,"loginEnded":"time_limit"}}"#)
        XCTAssertNil(dead?.expiresAt)
        XCTAssertEqual(dead?.hasRefreshToken, false)
        XCTAssertEqual(dead?.loginEnded, "time_limit")
    }

    func testJudgeNamesWhatOnlyTheUserCanFix() {
        XCTAssertEqual(ClaudeKeeper.judge(nil, now: now).state, .signedOut)
        XCTAssertEqual(ClaudeKeeper.judge(facts(expires: 3600), now: now).state, .ok)
        // Expired but renewable: still fine, the keeper renews it.
        XCTAssertEqual(ClaudeKeeper.judge(facts(expires: -3600), now: now).state, .ok)
        XCTAssertEqual(ClaudeKeeper.judge(facts(expires: nil, refresh: false, ended: "time_limit"), now: now).state, .needsSignIn)
        XCTAssertEqual(ClaudeKeeper.judge(facts(expires: nil, refresh: false), now: now).state, .needsSignIn)
        XCTAssertEqual(ClaudeKeeper.judge(facts(expires: 3600, ends: -60), now: now).state, .needsSignIn)
        // No refresh token, but the token still works for a while.
        XCTAssertEqual(ClaudeKeeper.judge(facts(expires: 600, refresh: false), now: now).state, .ok)
    }

    // MARK: Renewal schedule

    func testRenewsFourMinutesBeforeExpiryThenJustAfterThenBacksOff() {
        var entry = ClaudeKeeper.SignIn(expiresAt: now.addingTimeInterval(600), checkedAt: now)
        XCTAssertFalse(ClaudeKeeper.renewDue(entry, now: now))
        XCTAssertFalse(ClaudeKeeper.isDue(entry, now: now.addingTimeInterval(200)))
        XCTAssertTrue(ClaudeKeeper.isDue(entry, now: now.addingTimeInterval(360)))
        XCTAssertTrue(ClaudeKeeper.renewDue(entry, now: now.addingTimeInterval(360)))
        // The first attempt didn't take: again 5 s after expiry.
        let first = now.addingTimeInterval(360)
        entry.nextAttempt = ClaudeKeeper.nextAttempt(after: 1, expiresAt: entry.expiresAt, now: first)
        XCTAssertEqual(entry.nextAttempt, now.addingTimeInterval(605))
        XCTAssertFalse(ClaudeKeeper.renewDue(entry, now: now.addingTimeInterval(500)))
        XCTAssertTrue(ClaudeKeeper.renewDue(entry, now: now.addingTimeInterval(605)))
        // After expiry: 1, 2, 5, then every 15 minutes.
        let after = now.addingTimeInterval(700)
        XCTAssertEqual([2, 3, 4, 5, 9].map { ClaudeKeeper.nextAttempt(after: $0, expiresAt: entry.expiresAt, now: after).timeIntervalSince(after) },
                       [60, 120, 300, 900, 900])
    }

    func testNoRenewalWithoutARefreshTokenAndAtOnceWithoutAToken() {
        // Starting Claude Code can't renew a sign-in with no refresh token.
        XCTAssertFalse(ClaudeKeeper.renewDue(.init(expiresAt: now.addingTimeInterval(60), hasRefreshToken: false), now: now))
        // A refresh token but no access token: renew now.
        XCTAssertTrue(ClaudeKeeper.renewDue(.init(expiresAt: nil, hasRefreshToken: true), now: now))
    }

    func testWithoutTheAppARunnerSeesASignInRedoneInTerminal() async {
        SubagentUsage.appRunningOverride = false
        var status = SubagentUsage.Status(session: 10, weekly: 10, at: Date())
        status.signIn = .needsSignIn
        SubagentUsage.writeStatus(["nobody": status])
        // No sign-in in this account's (test) folder: it stays unusable, and nothing is asked.
        let usage = await SubagentUsage().usage(ClaudeAccount(id: "nobody"))
        XCTAssertFalse(usage.usable)
    }

    func testTheBlobIsReadEveryFiveMinutesAnyway() {
        let entry = ClaudeKeeper.SignIn(expiresAt: now.addingTimeInterval(8 * 3600), checkedAt: now)
        XCTAssertFalse(ClaudeKeeper.isDue(entry, now: now.addingTimeInterval(299)))
        XCTAssertTrue(ClaudeKeeper.isDue(entry, now: now.addingTimeInterval(300)))
    }

    func testEndsSoonWarnsThreeDaysAhead() {
        XCTAssertTrue(ClaudeKeeper.SignIn(endsAt: now.addingTimeInterval(2 * 86400)).endsSoon(now: now))
        XCTAssertFalse(ClaudeKeeper.SignIn(endsAt: now.addingTimeInterval(4 * 86400)).endsSoon(now: now))
    }

    // MARK: The shared file

    func testAWindowPastItsResetCountsAsUnused() {
        var status = SubagentUsage.Status(session: 100, weekly: 60, at: now.addingTimeInterval(-3600), models: ["Fable": 100])
        status.resetsAt = ["Session": now.addingTimeInterval(-60), "Weekly": now.addingTimeInterval(86400), "Fable": now.addingTimeInterval(-1)]
        let r = SubagentUsage.reading(status, now: now)
        XCTAssertEqual(r.session, 0)
        XCTAssertEqual(r.weekly, 60)
        XCTAssertEqual(r.models["Fable"], 0)
    }

    func testAReadingOlderThanTwoHoursIsUnknown() {
        let r = SubagentUsage.reading(.init(session: 10, weekly: 10, at: now.addingTimeInterval(-2 * 3600 - 1)), now: now)
        XCTAssertTrue(r.isUnknown)
        XCTAssertTrue(r.usable)
    }

    func testAnAccountThatNeedsSignInIsNotUsable() async {
        var status = SubagentUsage.Status(session: 10, weekly: 10, at: Date())
        status.signIn = .needsSignIn
        SubagentUsage.writeStatus(["claude-2": status])
        let usage = await SubagentUsage().usage(ClaudeAccount(id: "claude-2"))
        XCTAssertFalse(usage.usable)
    }

    func testLimitReachedHoldsUntilANewerReading() async {
        SubagentUsage.writeStatus(["claude-2": .init(session: 10, weekly: 10, at: Date().addingTimeInterval(-60))])
        AgentRegistry.markFull("claude-2")
        var usage = await SubagentUsage().usage(ClaudeAccount(id: "claude-2"))
        XCTAssertEqual(usage.session, 100)
        // The app read it again after the 429: its own numbers decide.
        SubagentUsage.writeStatus(["claude-2": .init(session: 12, weekly: 10, at: Date().addingTimeInterval(1))])
        usage = await SubagentUsage().usage(ClaudeAccount(id: "claude-2"))
        XCTAssertEqual(usage.session, 12)
    }

    func testResetsAreKeptByRowName() {
        let windows = [UsageWindow(label: "Weekly", usedPercent: 10, resetsAt: now), UsageWindow(label: "Fable Weekly", usedPercent: 5, resetsAt: now.addingTimeInterval(60))]
        XCTAssertEqual(SubagentUsage.resets(windows), ["Weekly": now, "Fable": now.addingTimeInterval(60)])
    }

    func testUpdateKeepsOtherWritersFields() {
        SubagentUsage.recordBlock("claude-2", retryAfter: 600, now: now)
        SubagentUsage.update { $0["claude-2"]?.signIn = .needsSignIn }
        let entry = SubagentUsage.readStatus()["claude-2"]
        XCTAssertNotNil(entry?.blockedUntil)
        XCTAssertEqual(entry?.signIn, .needsSignIn)
    }
}
