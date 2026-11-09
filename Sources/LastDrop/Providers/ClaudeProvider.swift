import CryptoKit
import Foundation

/// Claude (Pro/Max subscription) limits, read with the OAuth login Claude Code keeps in the keychain.
struct ClaudeProvider: UsageProvider {
    var id: ProviderID { .claude }
    /// The Claude Code config folder whose sign-in to read (`CLAUDE_CONFIG_DIR`); nil for the default.
    var configDir: String?
    /// A short-lived runner process: it asks the usage endpoint and nothing else. The plan name and reset grants
    /// are the app's to fetch (their caches live in one process), and the runner reads the plan from the status file.
    var lean = false

    /// The id this account has in the shared usage file: "main", or its folder's name.
    var usageID: String { configDir.map { ($0 as NSString).lastPathComponent } ?? ClaudeAccount.mainID }

    private static let usageURL = "https://api.anthropic.com/api/oauth/usage"
    private static let profileURL = "https://api.anthropic.com/api/oauth/profile"

    struct Credentials { var accessToken: String; var expiresAt: Date?; var plan: String? }

    func fetch() async throws -> UsageSnapshot {
        // Another process (or an earlier refresh) was told to back off: asking again only keeps the 429 going.
        if let until = SubagentUsage.blockedUntil(usageID) { throw ProviderError.rateLimited(Self.rateLimitedMessage(until: until)) }
        guard let raw = Self.storedCredentials(configDir: configDir) else {
            throw ProviderError.notConfigured("Run `claude` to sign in.")
        }
        guard let creds = Self.credentials(from: raw) else {
            throw ProviderError.notConfigured("Claude Code is not signed in with a Claude subscription.")
        }

        // Read-only: Claude Code refreshes its own login, so an expired token just means "run claude".
        let expired = "Claude Code sign-in expired. Run `claude` to refresh it."
        if let expiry = creds.expiresAt, expiry.timeIntervalSinceNow < 60 {
            throw ProviderError.unauthorized(expired)
        }
        let windows: [UsageWindow], credits: ExtraCredits?
        do {
            (windows, credits) = try await Self.usage(accessToken: creds.accessToken, expired: expired)
        } catch let limited as UsageRateLimited {
            let until = SubagentUsage.recordBlock(usageID, retryAfter: limited.retryAfter)
            throw ProviderError.rateLimited(Self.rateLimitedMessage(until: until))
        }
        SubagentUsage.clearBlock(usageID)
        if lean { return UsageSnapshot(title: "Claude", plan: creds.plan, windows: windows, credits: credits) }
        // After a successful usage fetch, so the token is known to work; a failure only costs the badge.
        let token = creds.accessToken
        let resets = await Self.resetCache.value(configDir ?? "main") { try await Self.resetGrants(accessToken: token) }
        let plan = await Self.planCache.value(configDir ?? "main") { try await Self.planDisplayName(accessToken: token) }
        var snapshot = UsageSnapshot(title: "Claude", plan: plan ?? creds.plan, windows: windows)
        snapshot.resets = resets
        snapshot.credits = credits
        return snapshot
    }

    static func rateLimitedMessage(until: Date, now: Date = .now) -> String {
        let minutes = max(1, Int((until.timeIntervalSince(now) / 60).rounded(.up)))
        return "Claude usage is rate limited. Retrying in \(minutes) minute\(minutes == 1 ? "" : "s")."
    }

    /// The usage endpoint answered 429, with its Retry-After seconds when it sent them.
    struct UsageRateLimited: Error { var retryAfter: TimeInterval? }

    /// Reset grants are asked for at most once an hour per account: asking on every refresh got
    /// OpenUsage sustained 429s on the usage endpoint.
    private static let resetCache = HourlyCache<LimitResets>()

    /// The plan's current name ("Ultra") is asked for at most once an hour per account.
    private static let planCache = HourlyCache<String>()

    /// The plan name claude.ai shows. Claude Code's keychain login only keeps internal ids
    /// ("max", "default_claude_max_20x"), which no longer match the names Anthropic sells the plans under.
    static func planDisplayName(accessToken: String) async throws -> String? {
        let headers = ["Authorization": "Bearer \(accessToken)", "Accept": "application/json",
                       "anthropic-beta": "oauth-2025-04-20", "User-Agent": "lastdrop"]
        let (body, http) = try await HTTP.json(HTTP.request(profileURL, headers: headers))
        guard (200..<300).contains(http.statusCode), let root = body as? [String: Any] else { throw ProviderError.http(http.statusCode) }
        return planDisplayName(fromProfile: root)
    }

    /// `{"organization": {"plan_display_name": "Ultra", …}}`; nil when missing or blank.
    static func planDisplayName(fromProfile root: [String: Any]) -> String? {
        guard let name = root.dict("organization")?.string("plan_display_name")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }

    /// Anthropic's one-off usage-limit resets: the usage endpoint with `cedar_ember=1` adds a
    /// `cedar_ember` block (as Claude Code and OpenUsage read it).
    static func resetGrants(accessToken: String) async throws -> LimitResets? {
        let headers = ["Authorization": "Bearer \(accessToken)", "Accept": "application/json",
                       "anthropic-beta": "oauth-2025-04-20", "User-Agent": "lastdrop"]
        let (body, http) = try await HTTP.json(HTTP.request(usageURL + "?cedar_ember=1&skip_spend=1", headers: headers))
        guard (200..<300).contains(http.statusCode), let root = body as? [String: Any] else { throw ProviderError.http(http.statusCode) }
        return resetGrants(from: root["cedar_ember"])
    }

    /// `{"eligible": true, "grants": [{"id", "resets_left", "ends_at", "clears"}], "next_grant_id"}`. Nil for
    /// a missing or `null` block (plans outside the program) or a malformed grant. An ineligible account
    /// has no usable resets.
    static func resetGrants(from value: Any?, now: Date = .now) -> LimitResets? {
        guard let block = value as? [String: Any] else { return nil }
        var count = 0
        var expiries: [Date] = []
        for entry in block["grants"] as? [Any] ?? [] {
            guard let grant = entry as? [String: Any], let left = grant.double("resets_left") else { return nil }
            let ends = Dates.iso(grant.string("ends_at"))
            guard block["eligible"] as? Bool == true, left >= 1, ends.map({ $0 > now }) ?? true else { continue }
            count += Int(left)
            if let ends { expiries += Array(repeating: ends, count: Int(left)) }
        }
        return LimitResets(count: count, expiries: expiries.sorted())
    }

    /// Usage of the account `accessToken` belongs to.
    static func usage(accessToken: String, expired: String) async throws -> ([UsageWindow], ExtraCredits?) {
        let headers = ["Authorization": "Bearer \(accessToken)", "Accept": "application/json",
                       "anthropic-beta": "oauth-2025-04-20", "User-Agent": "lastdrop"]
        let (body, http) = try await HTTP.json(HTTP.request(usageURL, headers: headers))
        if http.statusCode == 401 || http.statusCode == 403 { throw ProviderError.unauthorized(expired) }
        if http.statusCode == 429 {
            throw UsageRateLimited(retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0.trimmingCharacters(in: .whitespaces)) })
        }
        guard (200..<300).contains(http.statusCode) else { throw ProviderError.http(http.statusCode) }
        guard let root = body as? [String: Any] else { throw ProviderError.invalidResponse }
        let windows = windows(from: root)
        return (windows, extraUsage(from: root, limitReached: windows.contains { ($0.usedPercent ?? 0) >= 100 }))
    }

    /// Extra usage, which covers the account past its plan's limits: `spend: {"enabled", "used": {"amount_minor",
    /// "currency", "exponent"}, "limit": {…} | null, "balance": {…} | null}`. Nil while it's off.
    static func extraUsage(from root: [String: Any], limitReached: Bool) -> ExtraCredits? {
        guard let spend = root.dict("spend"), spend["enabled"] as? Bool == true else { return nil }
        func money(_ value: Any?) -> String? {
            guard let money = value as? [String: Any], let minor = money.double("amount_minor") else { return nil }
            let amount = minor / pow(10, money.double("exponent") ?? 2)
            return amount.formatted(.currency(code: money.string("currency") ?? "USD"))
        }
        let used = money(spend["used"]) ?? 0.0.formatted(.currency(code: "USD"))
        let amount = money(spend["limit"]).map { "\(used) of \($0)" } ?? money(spend["balance"]).map { "\($0) left" } ?? "\(used) used"
        return ExtraCredits(amount: amount, inUse: limitReached, detail: "Extra usage")
    }

    // MARK: Mapping (pure)

    /// Session and Weekly, then one weekly row per model-scoped limit ("Fable Weekly").
    /// Anthropic moved per-model windows from `seven_day_<model>` into the `limits` array;
    /// the legacy keys are still read when present. `utilization` and `percent` are 0-100.
    static func windows(from root: [String: Any]) -> [UsageWindow] {
        func window(_ label: String, _ used: Double?, _ reset: String?) -> UsageWindow? {
            guard let used else { return nil }
            return UsageWindow(label: label, usedPercent: min(max(used, 0), 100), resetsAt: Dates.iso(reset))
        }
        var windows = [("five_hour", "Session"), ("seven_day", "Weekly")].compactMap { key, label in
            window(label, root.dict(key)?.double("utilization"), root.dict(key)?.string("resets_at"))
        }
        for limit in root.array("limits") ?? [] where limit.string("kind") == "weekly_scoped" {
            guard let name = limit.dict("scope")?.dict("model")?.string("display_name"), !name.isEmpty,
                  let w = window("\(name) Weekly", limit.double("percent"), limit.string("resets_at")),
                  !windows.contains(where: { $0.label == w.label }) else { continue }
            windows.append(w)
        }
        for (key, label) in [("seven_day_sonnet", "Sonnet Weekly"), ("seven_day_opus", "Opus Weekly")]
        where !windows.contains(where: { $0.label == label }) {
            if let w = window(label, root.dict(key)?.double("utilization"), root.dict(key)?.string("resets_at")) {
                windows.append(w)
            }
        }
        return windows
    }

    /// Parses Claude Code's `{"claudeAiOauth": {...}}` credentials blob.
    static func credentials(from raw: String) -> Credentials? {
        guard let json = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
              let oauth = json.dict("claudeAiOauth"),
              let token = oauth.string("accessToken")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return Credentials(accessToken: token, expiresAt: Dates.epoch(oauth.double("expiresAt")),
                           plan: planName(type: oauth.string("subscriptionType"), tier: oauth.string("rateLimitTier")))
    }

    /// Fallback when the profile can't be read: "max" + "default_claude_max_20x" → "Max 20x"; "pro" → "Pro".
    static func planName(type: String?, tier: String?) -> String? {
        guard let type = type?.trimmingCharacters(in: .whitespacesAndNewlines), !type.isEmpty else { return nil }
        let name = type.prefix(1).uppercased() + type.dropFirst()
        if let tier, let r = tier.range(of: #"\d+x$"#, options: .regularExpression) {
            return "\(name) \(tier[r])"
        }
        return name
    }

    // MARK: Credential loading

    private static func storedCredentials(configDir: String?) -> String? {
        if let raw = Keychain.read(service: keychainService(configDir: configDir)) { return raw }
        let dir = configDir ?? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { ($0 as NSString).expandingTildeInPath }
            ?? NSHomeDirectory() + "/.claude"
        guard let data = FileManager.default.contents(atPath: dir + "/.credentials.json") else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Claude Code's keychain item for a config folder: `Claude Code-credentials`, plus the first 8 hex
    /// digits of the SHA-256 of the folder path when `CLAUDE_CONFIG_DIR` is set (Claude Code 2.1.310).
    static func keychainService(configDir: String?) -> String {
        guard let configDir else { return "Claude Code-credentials" }
        let digest = SHA256.hash(data: Data(configDir.precomposedStringWithCanonicalMapping.utf8))
        return "Claude Code-credentials-" + digest.map { String(format: "%02x", $0) }.joined().prefix(8)
    }

    /// The account a Claude Code config folder is signed in to: `oauthAccount` in its `.claude.json`
    /// (`~/.claude.json` for the default folder).
    static func signedInAccount(configDir: String?) -> (uuid: String?, email: String?) {
        let path = configDir.map { $0 + "/.claude.json" } ?? NSHomeDirectory() + "/.claude.json"
        let account = (try? Data(contentsOf: URL(fileURLWithPath: path)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?.dict("oauthAccount")
        return (account?.string("accountUuid"), account?.string("emailAddress"))
    }
}
