import XCTest
@testable import LastDrop

final class ProviderMappingTests: LastDropTestCase {
    private func obj(_ json: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    // MARK: Codex

    func testCodexClassifiesByWindowLength() {
        // Weekly-only plan reports its weekly window in the primary slot.
        let root = obj("""
        {"plan_type":"prolite","rate_limit":{"primary_window":{"used_percent":42,"limit_window_seconds":604800,"reset_after_seconds":3600}}}
        """)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let w = CodexProvider.windows(from: root, now: now)
        XCTAssertEqual(w.map(\.label), ["Weekly"])
        XCTAssertEqual(w[0].usedPercent, 42)
        XCTAssertEqual(w[0].resetsAt, now.addingTimeInterval(3600))
        XCTAssertEqual(CodexProvider.planName("prolite"), "Pro 100")
        XCTAssertEqual(CodexProvider.planName("pro"), "Pro 200")
        XCTAssertEqual(CodexProvider.planName("plus"), "Plus")
    }

    func testCodexSlotFallbackAndResetAt() {
        let root = obj("""
        {"rate_limit":{"primary_window":{"used_percent":10,"reset_at":2000000000},
                       "secondary_window":{"used_percent":55.5,"reset_at":2000600000}}}
        """)
        let w = CodexProvider.windows(from: root)
        XCTAssertEqual(w.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(w[1].usedPercent, 55.5)
        XCTAssertEqual(w[0].resetsAt, Date(timeIntervalSince1970: 2_000_000_000))
    }

    // MARK: Antigravity

    func testAntigravityBucketsMergeAcrossHosts() {
        let prod = obj("""
        {"groups":[{"displayName":"Gemini","buckets":[
          {"bucketId":"gemini-5h","remainingFraction":0.75,"resetTime":"2026-10-26T15:00:00Z"},
          {"bucketId":"gemini-weekly","remainingFraction":0.5}]}]}
        """)
        let daily = obj("""
        {"response":{"groups":[{"displayName":"Claude","buckets":[
          {"bucketId":"3p-5h","remainingFraction":1},
          {"bucketId":"3p-weekly"},
          {"bucketId":"gemini-5h","remainingFraction":0.1}]},
          {"displayName":"Gemini 4 Argon","buckets":[{"bucketId":"argon-weekly","remainingFraction":0.2}]}]}}
        """)
        let w = AntigravityProvider.windows(fromSummaries: [prod, daily])
        XCTAssertEqual(w.map(\.label), ["Session", "Weekly", "Claude"])
        XCTAssertEqual(w[0].usedPercent ?? -1, 25, accuracy: 0.001)   // first host wins
        XCTAssertEqual(w[1].usedPercent ?? -1, 50, accuracy: 0.001)
        XCTAssertEqual(w[2].usedPercent ?? -1, 0, accuracy: 0.001)
        XCTAssertNotNil(w[0].resetsAt)
    }

    func testAntigravityPlanAndTokenParsing() {
        XCTAssertEqual(AntigravityProvider.plan(fromLoadCodeAssist: obj(#"{"paidTier":{"id":"g1-ultra-tier","name":"x"}}"#)), "Ultra")
        XCTAssertEqual(AntigravityProvider.plan(fromLoadCodeAssist: obj(#"{"currentTier":{"name":"Google AI Pro"}}"#)), "Pro")
        let t = AntigravityProvider.token(from: obj(#"{"token":{"accessToken":"a","refresh_token":"r","expiry":"2026-10-26T12:00:00Z"}}"#))
        XCTAssertEqual(t?.access, "a")
        XCTAssertEqual(t?.refresh, "r")
        XCTAssertNotNil(t?.expiry)
    }

    // MARK: Z.ai

    func testZAIWindows() throws {
        let root = obj("""
        {"success":true,"data":{"limits":[
          {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":30,"nextResetTime":1770648402389},
          {"type":"CREDIT_LIMIT","unit":6,"number":1,"percentage":12,"nextResetTime":1771000000000},
          {"type":"TIME_LIMIT","unit":5,"number":1,"usage":100,"currentValue":25}]}}
        """)
        let w = try ZAIProvider.windows(from: root)
        XCTAssertEqual(w.map(\.label), ["Session", "Weekly", "Web Searches"])
        XCTAssertEqual(w[0].usedPercent, 30)
        XCTAssertEqual(w[0].resetsAt, Date(timeIntervalSince1970: 1_770_648_402.389))
        XCTAssertEqual(w[2].usedPercent, 25)
        XCTAssertEqual(w[2].detail, "75 / 100 left")
        XCTAssertEqual(ZAIProvider.plan(from: obj(#"{"data":[{"productName":"GLM Coding Max"}]}"#)), "GLM Coding Max")
    }

    func testZAIFailureMessage() {
        XCTAssertThrowsError(try ZAIProvider.windows(from: obj(#"{"success":false,"msg":"no plan"}"#))) { error in
            XCTAssertEqual((error as? ProviderError)?.errorDescription, "no plan")
        }
    }
}

final class FormatTests: LastDropTestCase {
    func testDurations() {
        XCTAssertEqual(Format.duration(30), "1m")
        XCTAssertEqual(Format.duration(12 * 60), "12m")
        XCTAssertEqual(Format.duration(2 * 3600 + 15 * 60), "2h 15m")
        XCTAssertEqual(Format.duration(3 * 3600), "3h")
        XCTAssertEqual(Format.duration(3 * 86400 + 4 * 3600 + 59), "3d 4h")
        let now = Date()
        XCTAssertEqual(Format.resets(now.addingTimeInterval(-5), now: now), "Resetting now")
        XCTAssertEqual(Format.left(UsageWindow(label: "Session", usedPercent: 41.6)), "58% left")
    }

    func testCodexTokenExpiry() {
        func jwt(exp: Double) -> String {
            let payload = Data(#"{"exp":\#(exp)}"#.utf8).base64EncodedString()
                .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            return "e30.\(payload).sig"
        }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertTrue(CodexProvider.isExpiring(jwt(exp: 2_000_000_030), now: now))
        XCTAssertFalse(CodexProvider.isExpiring(jwt(exp: 2_000_003_600), now: now))
        XCTAssertFalse(CodexProvider.isExpiring("not-a-jwt", now: now))
    }
}

final class ClaudeMappingTests: LastDropTestCase {
    func testClaudeWindowsAndPlan() throws {
        let root = try JSONSerialization.jsonObject(with: Data("""
        {"five_hour":{"utilization":6.0,"resets_at":"2026-10-26T19:59:59.943648+00:00"},
         "seven_day":{"utilization":35,"resets_at":"2026-10-30T10:00:00+00:00"},
         "seven_day_opus":null,"seven_day_sonnet":{"utilization":12.5,"resets_at":null},
         "limits":[{"kind":"weekly_all","percent":35},
                   {"kind":"weekly_scoped","percent":10,"resets_at":"2026-10-28T03:59:59.802507+00:00",
                    "scope":{"model":{"id":null,"display_name":"Fable"}}}]}
        """.utf8)) as! [String: Any]
        let w = ClaudeProvider.windows(from: root)
        XCTAssertEqual(w.map(\.label), ["Session", "Weekly", "Fable Weekly", "Sonnet Weekly"])
        XCTAssertEqual(w[2].usedPercent, 10)
        XCTAssertNotNil(w[2].resetsAt)
        XCTAssertEqual(w[0].usedPercent, 6)
        XCTAssertEqual(w[0].resetsAt?.timeIntervalSince1970 ?? 0, 1_793_044_799.943, accuracy: 0.01)
        XCTAssertNil(w[3].resetsAt)

        XCTAssertEqual(ClaudeProvider.planName(type: "max", tier: "default_claude_max_20x"), "Max 20x")
        XCTAssertEqual(ClaudeProvider.planName(type: "pro", tier: "default_claude_ai"), "Pro")
        let creds = ClaudeProvider.credentials(from: #"{"claudeAiOauth":{"accessToken":"t","expiresAt":1793044799000,"subscriptionType":"max"}}"#)
        XCTAssertEqual(creds?.accessToken, "t")
        XCTAssertEqual(creds?.plan, "Max")
        XCTAssertNil(ClaudeProvider.credentials(from: "{}"))

        let profile = try! JSONSerialization.jsonObject(with: Data(#"{"organization":{"plan_display_name":"Ultra","rate_limit_tier":"default_claude_max_20x"}}"#.utf8)) as! [String: Any]
        XCTAssertEqual(ClaudeProvider.planDisplayName(fromProfile: profile), "Ultra")
        XCTAssertNil(ClaudeProvider.planDisplayName(fromProfile: ["organization": ["plan_display_name": " "]]))
        XCTAssertNil(ClaudeProvider.planDisplayName(fromProfile: [:]))
    }
}

final class NewProviderTests: LastDropTestCase {
    private func obj(_ json: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    func testAntigravityArgonWeekly() {
        let body = obj("""
        {"groups":[{"displayName":"Gemini","buckets":[{"bucketId":"gemini-5h","remainingFraction":0.5},
                                                      {"bucketId":"gemini-weekly","remainingFraction":0.8}]},
                   {"displayName":"Gemini 4 Argon","buckets":[{"bucketId":"argon-weekly","window":"weekly","remainingFraction":0.25}]},
                   {"displayName":"Claude","buckets":[{"bucketId":"3p-5h","remainingFraction":1}]}]}
        """)
        let w = AntigravityProvider.windows(fromSummaries: [body])
        XCTAssertEqual(w.map(\.label), ["Session", "Weekly", "Argon Weekly", "Claude"])
        XCTAssertEqual(w[2].remainingPercent ?? -1, 25, accuracy: 0.001)
    }

    func testOpenRouterMapping() {
        let balance = OpenRouterProvider.balance(from: obj(#"{"data":{"total_credits":50,"total_usage":12.34}}"#))
        XCTAssertEqual(balance?.total, 50)
        let window = OpenRouterProvider.creditsWindow(balance!)
        XCTAssertEqual(window.detail, "$37.66 of $50.00 left")
        XCTAssertEqual(window.remainingPercent ?? -1, 75.32, accuracy: 0.001)

        let keys = OpenRouterProvider.keys(fromList: obj("""
        {"data":[{"name":"small","usage":1.5,"usage_daily":0.1,"usage_monthly":1,"limit":null,"disabled":false},
                 {"name":"","label":"sk-or-v1-abc...xyz","usage":9,"limit":20,"limit_remaining":11,"disabled":true}]}
        """))
        XCTAssertEqual(keys.map(\.name), ["sk-or-v1-abc...xyz", "small"])
        XCTAssertEqual(keys[0].limitRemaining, 11)
        XCTAssertTrue(keys[0].disabled)
        XCTAssertEqual(keys[1].today, 0.1)
    }

    func testZAISessionCandidates() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl"
        let found = ZAISignInWindow.candidates([("user", #"{"name":"x","token":"\#(jwt)"}"#), ("theme", "dark"),
                                                ("z-ai-token", jwt)])
        XCTAssertEqual(found, [jwt])
    }
}

final class PanelSplitTests: LastDropTestCase {
    func testOnlySessionAndWeeklyShowByDefault() {
        let w = ["Session", "Weekly", "Fable Weekly", "Claude"].map { UsageWindow(label: $0, usedPercent: 1) }
        let split = ProviderSection.split(w)
        XCTAssertEqual(split.main.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(split.more.map(\.label), ["Fable Weekly", "Claude"])
        let credits = ProviderSection.split([UsageWindow(label: "Credits", usedPercent: 10)])
        XCTAssertEqual(credits.main.map(\.label), ["Credits"])
        XCTAssertTrue(credits.more.isEmpty)
    }

    private func obj(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    func testCodexCreditsAndWhetherTheyreInUse() throws {
        let root = obj(#"{"rate_limit":{"limit_reached":true},"credits":{"has_credits":true,"unlimited":false,"overage_limit_reached":false,"balance":"47074.2524","approx_local_messages":[11769,61197]}}"#)
        let credits = try XCTUnwrap(CodexProvider.credits(from: root))
        XCTAssertEqual(credits.amount, "\(47074.formatted()) credits")
        XCTAssertTrue(credits.inUse)
        XCTAssertEqual(credits.detail, "About \(11769.formatted()) to \(61197.formatted()) messages")
        XCTAssertNil(CodexProvider.credits(from: obj(#"{"credits":{"has_credits":false,"balance":"0"}}"#)))
        XCTAssertFalse(CodexProvider.credits(from: obj(#"{"rate_limit":{"limit_reached":false},"credits":{"has_credits":true,"balance":"10"}}"#))!.inUse)
    }

    func testClaudeExtraUsageOnlyWhenEnabled() {
        XCTAssertNil(ClaudeProvider.extraUsage(from: obj(#"{"spend":{"enabled":false,"used":{"amount_minor":0,"currency":"USD","exponent":2}}}"#), limitReached: true))
        let on = ClaudeProvider.extraUsage(from: obj(#"{"spend":{"enabled":true,"used":{"amount_minor":1240,"currency":"USD","exponent":2},"limit":{"amount_minor":5000,"currency":"USD","exponent":2}}}"#), limitReached: true)
        XCTAssertEqual(on?.amount, "\(12.4.formatted(.currency(code: "USD"))) of \(50.0.formatted(.currency(code: "USD")))")
        XCTAssertEqual(on?.inUse, true)
    }

    func testCodexExtraLimitsShowUnderTheirOwnNames() {
        let root = obj(#"{"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000}},"code_review_rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":604800}},"additional_rate_limits":[{"limit_name":"gpt-6-spark","rate_limit":{"primary_window":{"used_percent":40,"limit_window_seconds":18000},"secondary_window":{"used_percent":20,"limit_window_seconds":604800}}}]}"#)
        let labels = CodexProvider.windows(from: root).map(\.label)
        XCTAssertEqual(labels, ["Session", "Code review Weekly", "Spark Session", "Spark Weekly"])
        XCTAssertEqual(CodexProvider.windows(from: obj(#"{"additional_rate_limits":null}"#)).count, 0)
    }
}
