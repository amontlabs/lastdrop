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
    /// Ask Anthropic even when Claude Code's copy is recent: the account just answered "limit reached", which
    /// the copy may predate.
    var fresh = false

    /// The id this account has in the shared usage file: "main", or its folder's name.
    var usageID: String { configDir.map { ($0 as NSString).lastPathComponent } ?? ClaudeAccount.mainID }

    private static let usageURL = "https://api.anthropic.com/api/oauth/usage"
    private static let profileURL = "https://api.anthropic.com/api/oauth/profile"

    struct Credentials {
        var accessToken: String; var expiresAt: Date?; var plan: String?
        /// Not about to expire: Anthropic would accept it.
        func isUsable(now: Date = .now) -> Bool { expiresAt.map { $0.timeIntervalSince(now) >= 60 } ?? true }
    }

    func fetch() async throws -> UsageSnapshot {
        // Claude Code asks the same endpoint for the same account and keeps the answer: while that's recent,
        // asking again only spends the account's small quota on the endpoint. The shared block stays as it
        // is: a cached answer says nothing about whether Anthropic would answer lastdrop now.
        if !fresh, let cached = cachedUsage() {
            let (windows, credits) = Self.reading(from: cached.root)
            if lean { return UsageSnapshot(title: "Claude", plan: nil, windows: windows, credits: credits) }
            let creds = Self.storedCredentials(configDir: configDir).flatMap(Self.credentials(from:))
            return await snapshot(windows: windows, credits: credits, creds: creds, grants: cached.root["cedar_ember"] as? [String: Any])
        }
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
        if !creds.isUsable() { throw ProviderError.unauthorized(expired) }
        let windows: [UsageWindow], credits: ExtraCredits?
        do {
            (windows, credits) = try await Self.usage(accessToken: creds.accessToken, expired: expired)
        } catch let limited as UsageRateLimited {
            let until = SubagentUsage.recordBlock(usageID, retryAfter: limited.retryAfter)
            throw ProviderError.rateLimited(Self.rateLimitedMessage(until: until))
        }
        SubagentUsage.clearBlock(usageID)
        if lean { return UsageSnapshot(title: "Claude", plan: creds.plan, windows: windows, credits: credits) }
        return await snapshot(windows: windows, credits: credits, creds: creds, grants: nil)
    }

    /// The app's snapshot: the reading plus the plan's name and the reset grants, each asked for at most once
    /// an hour and only with a sign-in that works. `grants` is the `cedar_ember` block when the reading already
    /// came with one, which saves that request.
    private func snapshot(windows: [UsageWindow], credits: ExtraCredits?, creds: Credentials?, grants: [String: Any]?) async -> UsageSnapshot {
        var snapshot = UsageSnapshot(title: "Claude", plan: creds?.plan, windows: windows)
        snapshot.credits = credits
        var grantList = Self.resetGrants(from: grants)
        if let creds {
            let token = creds.isUsable() ? creds.accessToken : nil
            if grants == nil {
                // The same endpoint as the usage: never asked while it's telling this account to back off.
                let ask = token != nil && SubagentUsage.blockedUntil(usageID) == nil
                grantList = await Self.resetCache.value(usageID) {
                    guard ask, let token else { throw ProviderError.http(429) }
                    return try await Self.resetGrants(accessToken: token)
                }
            }
            // Keyed by the subscription in the sign-in too: after a plan change the old name isn't kept, and
            // while the profile can't be read the sign-in's own name stands in.
            let plan = await Self.planCache.value("\(usageID)|\(creds.plan ?? "")") {
                guard let token else { throw ProviderError.http(401) }
                return try await Self.planDisplayName(accessToken: token)
            }
            snapshot.plan = plan ?? creds.plan
        }
        snapshot.resets = Self.place(grantList, on: &snapshot.windows)
        return snapshot
    }

    /// What the keeper needs to know about a sign-in, from Claude Code's blob alone.
    struct SignInFacts: Equatable {
        /// When the access token expires; nil when there's none (signed out, or Claude Code cleared a dead one).
        var expiresAt: Date?
        /// When the sign-in itself ends (`refreshTokenExpiresAt`).
        var endsAt: Date?
        var hasRefreshToken: Bool
        /// Claude Code's reason for clearing a dead sign-in: "time_limit" when it ran out.
        var loginEnded: String?
        /// The plan the sign-in names ("Max 20x").
        var plan: String?
    }

    /// Nil when the blob isn't a Claude subscription sign-in at all.
    static func signInFacts(from raw: String) -> SignInFacts? {
        guard let json = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
              let oauth = json.dict("claudeAiOauth") else { return nil }
        let access = oauth.string("accessToken")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let refresh = oauth.string("refreshToken")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let expires = oauth.double("expiresAt").flatMap { $0 > 0 ? $0 : nil }
        return SignInFacts(expiresAt: access.isEmpty ? nil : Dates.epoch(expires), endsAt: Dates.epoch(oauth.double("refreshTokenExpiresAt")),
                           hasRefreshToken: !refresh.isEmpty, loginEnded: oauth.string("loginEnded"),
                           plan: planName(type: oauth.string("subscriptionType"), tier: oauth.string("rateLimitTier")))
    }

    /// The plan in the account's sign-in, read without asking Anthropic. Nil when it isn't signed in.
    func credentialPlan() async -> String? {
        Self.storedCredentials(configDir: configDir).flatMap(Self.credentials(from:))?.plan
    }

    /// The plan name to keep when the profile can't be asked: the one already shown, which came from Anthropic's
    /// profile. The sign-in's plan only stands in when nothing was shown yet: Claude Code stamps it at sign-in and
    /// never updates it, so after an upgrade it still says "Pro" (seen 2026-11-12 on a Max 5x account).
    static func plan(shown: String?, credentials: String?) -> String? { shown ?? credentials }

    // MARK: Claude Code's cached reading

    /// The usage answer Claude Code keeps in its `.claude.json` (`cachedUsageUtilization`), the same JSON the
    /// endpoint returns.
    struct CachedUsage {
        var fetchedAt: Date
        var root: [String: Any]
    }

    /// A cached answer is used while younger than this. With the app's 5-minute refresh, a reading stays
    /// within the 15 minutes runners trust (`SubagentUsage.appReadingFresh`).
    static let cacheFresh: TimeInterval = 10 * 60

    /// Tests point `~/.claude.json` elsewhere.
    nonisolated(unsafe) static var sharedConfigOverride: String?
    /// Main's `.claude.json`.
    static var sharedConfig: String { sharedConfigOverride ?? NSHomeDirectory() + "/.claude.json" }

    /// Where Claude Code may have kept this account's answer: `~/.claude.json` (Main's sessions, and the
    /// sessions lastdrop started before accounts had profiles), the account's profile, where its sessions run,
    /// and the account folder's own, written when Claude Code signs in or renews there.
    var cacheFiles: [String] {
        [Self.sharedConfig] + (configDir.map { [ClaudeProfile.configFile(folder: $0), $0 + "/.claude.json"] } ?? [])
    }

    /// This account's recent answer from Claude Code, if it has one.
    func cachedUsage(now: Date = .now) -> CachedUsage? {
        Self.cachedUsage(accountUUID: Self.signedInAccount(configDir: configDir).uuid, files: cacheFiles, now: now)
    }

    /// The newest fresh answer for the account among the files.
    static func cachedUsage(accountUUID: String?, files: [String], now: Date = .now) -> CachedUsage? {
        guard let accountUUID else { return nil }
        return files.compactMap { path -> CachedUsage? in
            guard let data = FileManager.default.contents(atPath: path),
                  let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            return cachedUsage(fromConfig: config, accountUUID: accountUUID, now: now)
        }.max { $0.fetchedAt < $1.fetchedAt }
    }

    /// `{"cachedUsageUtilization": {"fetchedAtMs", "accountUuid", "utilization": {…}}}`. Sessions of every
    /// account write the shared file, so an answer counts only for the account it names. Nil when it names
    /// another (or none), is older than `cacheFresh` or dated ahead of the clock, or has no limits in it.
    static func cachedUsage(fromConfig config: [String: Any], accountUUID: String, now: Date = .now) -> CachedUsage? {
        guard let cache = config.dict("cachedUsageUtilization"), cache.string("accountUuid") == accountUUID,
              let fetchedAt = Dates.epoch(cache.double("fetchedAtMs")), let root = cache.dict("utilization"),
              (0..<cacheFresh).contains(now.timeIntervalSince(fetchedAt) + 5),   // a few seconds of clock slack
              !windows(from: root).isEmpty else { return nil }
        return CachedUsage(fetchedAt: fetchedAt, root: root)
    }

    static func rateLimitedMessage(until: Date, now: Date = .now) -> String {
        let minutes = max(1, Int((until.timeIntervalSince(now) / 60).rounded(.up)))
        return "Claude usage is rate limited. Retrying in \(minutes) minute\(minutes == 1 ? "" : "s")."
    }

    /// The usage endpoint answered 429, with its Retry-After seconds when it sent them.
    struct UsageRateLimited: Error { var retryAfter: TimeInterval? }

    /// Reset grants are asked for at most once an hour per account: asking on every refresh got
    /// OpenUsage sustained 429s on the usage endpoint.
    private static let resetCache = HourlyCache<[ResetGrant]>()

    /// The plan's current name ("Ultra") is asked for at most once an hour per account.
    private static let planCache = HourlyCache<String>()

    /// The plan name claude.ai shows. Claude Code's keychain login only keeps internal ids
    /// ("max", "default_claude_max_20x"), which no longer match the names Anthropic sells the plans under.
    static func planDisplayName(accessToken: String) async throws -> String? {
        let headers = ClaudeCodeHeaders.oauth(accessToken: accessToken)
        let (body, http) = try await HTTP.json(HTTP.request(profileURL, headers: headers))
        guard (200..<300).contains(http.statusCode), let root = body as? [String: Any] else { throw ProviderError.http(http.statusCode) }
        return planDisplayName(fromProfile: root)
    }

    /// `{"organization": {"plan_display_name": "Ultra", "organization_type": "claude_max", "rate_limit_tier":
    /// "default_claude_max_5x"}}`. Some accounts have no display name: then the type and tier ("Max 5x"), which
    /// are current, unlike the sign-in's. Nil when neither is there.
    static func planDisplayName(fromProfile root: [String: Any]) -> String? {
        let org = root.dict("organization")
        if let name = org?.string("plan_display_name")?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        guard let type = org?.string("organization_type"), type.hasPrefix("claude_") else { return nil }
        return planName(type: String(type.dropFirst("claude_".count)), tier: org?.string("rate_limit_tier"))
    }

    /// Anthropic's one-off usage-limit resets: the usage endpoint with `cedar_ember=1` adds a
    /// `cedar_ember` block (as Claude Code and OpenUsage read it). Anthropic lists them only to Claude Code,
    /// hence its headers (see `ClaudeCodeHeaders`).
    static func resetGrants(accessToken: String) async throws -> [ResetGrant]? {
        let headers = ClaudeCodeHeaders.oauth(accessToken: accessToken)
        let (body, http) = try await HTTP.json(HTTP.request(usageURL + "?cedar_ember=1&skip_spend=1", headers: headers))
        guard (200..<300).contains(http.statusCode), let root = body as? [String: Any] else { throw ProviderError.http(http.statusCode) }
        return resetGrants(from: root["cedar_ember"])
    }

    /// One reset grant the account can spend. `modelOnly` grants clear one model's weekly limit, not the
    /// account's (the launch-week Fable resets; see `isModelOnly`).
    struct ResetGrant: Hashable, Sendable {
        var count: Int
        var expiries: [Date]
        /// "New model launch: one Fable reset for Max, …"
        var label: String
        var modelOnly: Bool
    }

    /// `{"eligible": true, "grants": [{"id", "label", "resets_left", "ends_at", "clears"}], "next_grant_id"}`.
    /// Nil for a missing or `null` block (plans outside the program) or a malformed grant. An ineligible
    /// account has no usable resets.
    static func resetGrants(from value: Any?, now: Date = .now) -> [ResetGrant]? {
        guard let block = value as? [String: Any] else { return nil }
        var grants: [ResetGrant] = []
        for entry in block["grants"] as? [Any] ?? [] {
            guard let grant = entry as? [String: Any], let left = grant.double("resets_left") else { return nil }
            let ends = Dates.iso(grant.string("ends_at"))
            guard block["eligible"] as? Bool == true, left >= 1, ends.map({ $0 > now }) ?? true else { continue }
            let clears = grant["clears"] as? [String] ?? []
            grants.append(ResetGrant(count: Int(left), expiries: ends.map { Array(repeating: $0, count: Int(left)) } ?? [],
                                     label: grant.string("label") ?? "",
                                     modelOnly: isModelOnly(clears: clears)))
        }
        return grants
    }

    /// A grant clears one model's weekly limit rather than the account's: it clears a weekly limit other than
    /// `seven_day`, and not `seven_day` itself. The session may come with it: Max 20x's Fable launch grant
    /// clears `["seven_day_overage_included"]`, Max 5x's `["five_hour", "seven_day_overage_included"]`.
    static func isModelOnly(clears: [String]) -> Bool {
        !clears.contains("seven_day") && clears.contains { $0.hasPrefix("seven_day_") }
    }

    /// Puts each model-only grant on its model's weekly row ("Fable Weekly"): the one whose model the grant's
    /// label names, else the only model row there is. Returns the account's other resets, for its header.
    static func place(_ grants: [ResetGrant]?, on windows: inout [UsageWindow]) -> LimitResets? {
        guard let grants else { return nil }
        let modelRows = windows.indices.filter { windows[$0].label != "Weekly" && windows[$0].label.hasSuffix(" Weekly") }
        var account = LimitResets(count: 0, expiries: [])
        for grant in grants {
            let label = grant.label.lowercased()
            let row = grant.modelOnly
                ? modelRows.first { label.contains(windows[$0].label.dropLast(" Weekly".count).lowercased()) }
                    ?? (modelRows.count == 1 ? modelRows[0] : nil)
                : nil
            if let row {
                windows[row].resets = (windows[row].resets ?? LimitResets(count: 0, expiries: [])).adding(grant.count, grant.expiries)
            } else {
                account = account.adding(grant.count, grant.expiries)
            }
        }
        return account
    }

    /// Usage of the account `accessToken` belongs to.
    static func usage(accessToken: String, expired: String) async throws -> ([UsageWindow], ExtraCredits?) {
        let headers = ClaudeCodeHeaders.oauth(accessToken: accessToken)
        let (body, http) = try await HTTP.json(HTTP.request(usageURL, headers: headers))
        if http.statusCode == 401 || http.statusCode == 403 { throw ProviderError.unauthorized(expired) }
        if http.statusCode == 429 {
            throw UsageRateLimited(retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0.trimmingCharacters(in: .whitespaces)) })
        }
        guard (200..<300).contains(http.statusCode) else { throw ProviderError.http(http.statusCode) }
        guard let root = body as? [String: Any] else { throw ProviderError.invalidResponse }
        return reading(from: root)
    }

    /// The windows and extra usage in a usage answer, from Anthropic or from Claude Code's copy of one.
    static func reading(from root: [String: Any]) -> ([UsageWindow], ExtraCredits?) {
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

    static func storedCredentials(configDir: String?) -> String? {
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
        let path = configDir.map { $0 + "/.claude.json" } ?? sharedConfig
        let account = (try? Data(contentsOf: URL(fileURLWithPath: path)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?.dict("oauthAccount")
        return (account?.string("accountUuid"), account?.string("emailAddress"))
    }
}
