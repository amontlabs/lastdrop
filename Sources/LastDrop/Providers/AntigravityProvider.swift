import Foundation

/// Antigravity quota via the Google Cloud Code API, using the OAuth token Antigravity keeps in the keychain.
struct AntigravityProvider: UsageProvider {
    var id: ProviderID { .antigravity }
    /// The keychain account of lastdrop's own Google login for this account.
    var login = Self.loginAccount
    /// Falls back to the token the Antigravity app keeps: the main account only.
    var usesAppLogin = true

    /// The daily host first: it is the one Antigravity and agy use, and it tracks their usage. The production
    /// host can answer 200 with stale Gemini buckets (near 0% used while daily shows real use), so it only
    /// fills buckets the daily host lacks.
    private static let hosts = ["https://daily-cloudcode-pa.googleapis.com", "https://cloudcode-pa.googleapis.com"]
    private static let summaryPath = "/v1internal:retrieveUserQuotaSummary"
    private static let loadPath = "/v1internal:loadCodeAssist"
    /// Cloud Code answers 403 "no valid license" unless the caller sends the Antigravity client's
    /// User-Agent (OpenUsage does the same). Sent at the user's request. The hub form is the one T3 Code
    /// sends with the project, the request that returns the Argon buckets.
    private static let userAgent = "antigravity/hub/2.24.0 (aidev_client; os_type=darwin; arch=\(arch); cl=963137146)"
    #if arch(arm64)
    private static let arch = "arm64"
    #else
    private static let arch = "amd64"
    #endif
    private static let loadBody: [String: Any] = ["metadata": ["ideType": "ANTIGRAVITY", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]]

    // MARK: Fetch

    struct KeychainToken { var access: String?; var refresh: String?; var expiry: Date? }

    /// lastdrop's own Google login (Settings → Sign in) wins over the token Antigravity keeps.
    static let loginService = "lastdrop", loginAccount = "antigravity-login"

    func fetch() async throws -> UsageSnapshot {
        let stored = try Self.storedToken(login: login, usesAppLogin: usesAppLogin)
        var token = try await Self.accessToken(stored, forceRefresh: false)
        var info = await Self.loadCodeAssist(token: token)
        var outcome = await Self.fetchSummaries(token: token, project: info?.project)
        if case .authFailed = outcome, stored.refresh != nil {
            token = try await Self.accessToken(stored, forceRefresh: true)
            info = await Self.loadCodeAssist(token: token)
            outcome = await Self.fetchSummaries(token: token, project: info?.project)
        }
        switch outcome {
        case .authFailed: throw ProviderError.unauthorized(Self.expiredMessage)
        case .refused(let reason): throw ProviderError.message("Google refused the quota request: \(reason)")
        case .unavailable: throw ProviderError.message("Antigravity quota is temporarily unavailable.")
        case .ok(let bodies):
            return UsageSnapshot(title: "Antigravity", plan: info?.plan, windows: Self.windows(fromSummaries: bodies))
        }
    }

    private static let expiredMessage = "Antigravity sign-in expired. Sign in again in Settings."

    static func hasCredentials(login: String, usesAppLogin: Bool) -> Bool {
        (try? storedToken(login: login, usesAppLogin: usesAppLogin)) != nil
    }

    private static func storedToken(login: String, usesAppLogin: Bool) throws -> KeychainToken {
        if let raw = Keychain.readOwn(service: loginService, account: login),
           let json = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
           let refresh = json.string("refresh_token") {
            return KeychainToken(access: nil, refresh: refresh, expiry: nil)
        }
        guard usesAppLogin else { throw ProviderError.notConfigured("Sign in with Google in Settings.") }
        guard let raw = Keychain.read(service: "gemini", account: "antigravity") else {
            throw ProviderError.notConfigured("Sign in with Google in Settings, or open Antigravity.")
        }
        guard let token = parseKeychain(raw) else { throw ProviderError.message("Antigravity credentials are unreadable.") }
        return token
    }

    /// A still-valid stored token, else one minted from the refresh token. Google refresh tokens don't
    /// rotate, so this never touches Antigravity's own login; minted tokens live only in memory.
    private static func accessToken(_ stored: KeychainToken, forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let access = stored.access, stored.expiry.map({ $0.timeIntervalSinceNow > 60 }) ?? true {
            return access
        }
        guard let refresh = stored.refresh else { throw ProviderError.unauthorized(expiredMessage) }
        if !forceRefresh, let cached = await tokenCache.token(for: refresh) { return cached }
        switch await GoogleOAuth.refresh(refresh) {
        case .refreshed(let access, let expiresIn):
            await tokenCache.store(access, expiresAt: .now.addingTimeInterval(expiresIn), for: refresh)
            return access
        case .revoked: throw ProviderError.unauthorized(expiredMessage)
        case .unavailable: throw ProviderError.message("Google sign-in is temporarily unavailable.")
        }
    }

    private static let tokenCache = TokenCache()

    private actor TokenCache {
        private var entries: [String: (token: String, expiresAt: Date)] = [:]
        func token(for refresh: String) -> String? {
            guard let entry = entries[refresh], entry.expiresAt.timeIntervalSinceNow > 60 else { return nil }
            return entry.token
        }
        func store(_ token: String, expiresAt: Date, for refresh: String) { entries[refresh] = (token, expiresAt) }
    }

    // MARK: Mapping (pure)

    private static let buckets: [(id: String, label: String)] = [
        ("gemini-5h", "Session"), ("gemini-weekly", "Weekly"), ("3p-5h", "Claude"), ("3p-weekly", "Claude Weekly"),
    ]

    /// Argon buckets are `gemini-argon-5h` / `gemini-argon-weekly`, in their own group. Google only returns
    /// them when the request names the user's Code Assist project, as T3 Code does.
    private static func isArgon(_ bucket: [String: Any]) -> Bool {
        bucket.string("bucketId")?.hasPrefix("gemini-argon-") == true
    }

    /// Merges one or more `retrieveUserQuotaSummary` bodies by bucket id (first usable one wins).
    /// Order: Session, Weekly, Argon, Argon Weekly, Claude, Claude Weekly.
    static func windows(fromSummaries bodies: [[String: Any]]) -> [UsageWindow] {
        var found: [String: UsageWindow] = [:]
        for body in bodies {
            for group in groups(body) {
                for bucket in group.array("buckets") ?? [] {
                    guard let id = bucket.string("bucketId"), found[id] == nil,
                          let spec = buckets.first(where: { $0.id == id }),
                          let fraction = bucket.double("remainingFraction"), fraction.isFinite else { continue }
                    found[id] = UsageWindow(label: spec.label,
                                            usedPercent: min(max((1 - fraction) * 100, 0), 100),
                                            resetsAt: Dates.iso(bucket.string("resetTime")))
                }
            }
        }
        var windows = buckets.compactMap { found[$0.id] }
        if let argon = bodies.lazy.map(argonWindows).first(where: { !$0.isEmpty }) {
            windows.insert(contentsOf: argon, at: windows.firstIndex { $0.label.hasPrefix("Claude") } ?? windows.endIndex)
        }
        return windows
    }

    /// Argon's 5-hour and weekly buckets, judged per body so hosts are never mixed.
    private static func argonWindows(_ body: [String: Any]) -> [UsageWindow] {
        let argon = groups(body).flatMap { $0.array("buckets") ?? [] }
            .filter { isArgon($0) && $0["disabled"] as? Bool != true }
        return [("5h", "Argon"), ("weekly", "Argon Weekly")].compactMap { window, label in
            guard let bucket = argon.first(where: { $0.string("window") == window || $0.string("bucketId") == "gemini-argon-\(window)" }),
                  let fraction = bucket.double("remainingFraction"), fraction.isFinite else { return nil }
            return UsageWindow(label: label, usedPercent: min(max((1 - fraction) * 100, 0), 100),
                               resetsAt: Dates.iso(bucket.string("resetTime")))
        }
    }

    private static func groups(_ body: [String: Any]) -> [[String: Any]] {
        body.dict("response")?.array("groups") ?? body.array("groups") ?? []
    }

    private static func isComplete(_ body: [String: Any]) -> Bool {
        windows(fromSummaries: [body]).filter { !$0.label.hasPrefix("Argon") }.count == buckets.count
    }

    /// `paidTier.id` first, then its name, then the current tier's name.
    static func plan(fromLoadCodeAssist body: [String: Any]) -> String? {
        let known = ["g1-pro-tier": "Pro", "g1-ultra-tier": "Ultra", "g1-ultra-lite-tier": "Ultra Lite"]
        if let id = body.dict("paidTier")?.string("id"), let name = known[id] { return name }
        guard let raw = (body.dict("paidTier")?.string("name") ?? body.dict("currentTier")?.string("name"))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.hasPrefix("Google AI ") { return String(raw.dropFirst("Google AI ".count)) }
        for keyword in ["Ultra", "Pro", "Free"] where raw.lowercased().contains(keyword.lowercased()) { return keyword }
        return raw
    }

    /// `cloudaicompanionProject` is a bare id or `{"id": ...}`.
    static func project(fromLoadCodeAssist body: [String: Any]) -> String? {
        let id = body.string("cloudaicompanionProject") ?? body.dict("cloudaicompanionProject")?.string("id")
        return id.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: Keychain value

    /// `go-keyring-base64:` + base64(JSON `{"token": {...}}`); the prefix is optional.
    private static func parseKeychain(_ raw: String) -> KeychainToken? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "go-keyring-base64:"
        if text.hasPrefix(prefix) {
            guard let data = Data(base64Encoded: String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)),
                  let decoded = String(data: data, encoding: .utf8) else { return nil }
            text = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return nil }
        return token(from: json)
    }

    static func token(from object: [String: Any]) -> KeychainToken? {
        func first(_ d: [String: Any], _ keys: [String]) -> String? {
            for k in keys { if let s = d.string(k)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s } }
            return nil
        }
        let src = object.dict("token") ?? object
        let access = first(src, ["access_token", "accessToken", "token", "id_token", "idToken", "bearerToken", "auth_token", "authToken"])
        let refresh = first(src, ["refresh_token", "refreshToken"])
        if access == nil && refresh == nil {
            for key in ["tokens", "oauth", "oauth2", "credentials", "auth"] {
                if let nested = object.dict(key), let t = token(from: nested) { return t }
            }
            return nil
        }
        return KeychainToken(access: access, refresh: refresh, expiry: Dates.iso(first(src, ["expiry", "expires_at", "expiresAt"])))
    }

    // MARK: Network

    private enum Outcome { case ok([[String: Any]]), authFailed, refused(String), unavailable }

    private static func post(_ host: String, _ path: String, token: String, ua: String, body: [String: Any]) async -> (Int, [String: Any])? {
        let headers = ["Accept": "application/json", "Authorization": "Bearer \(token)", "User-Agent": ua]
        guard let (obj, http) = try? await HTTP.json(HTTP.request(host + path, method: "POST", headers: headers, json: body)) else { return nil }
        return (http.statusCode, obj as? [String: Any] ?? [:])
    }

    /// Asks the daily host, and the production one too when the first lacks any shared bucket.
    private static func fetchSummaries(token: String, project: String?) async -> Outcome {
        let body: [String: Any] = project.map { ["project": $0] } ?? [:]
        var bodies: [[String: Any]] = []
        var authFailed = false
        var refusal: String?
        for (index, host) in hosts.enumerated() {
            guard let (status, body) = await post(host, summaryPath, token: token, ua: userAgent, body: body) else { continue }
            if status == 401 { authFailed = true; continue }
            // 403 is Google turning the caller away (e.g. "no valid license"), not an expired login.
            if status == 403 { refusal = body.dict("error")?.string("message") ?? "HTTP 403"; continue }
            guard (200..<300).contains(status) else { continue }
            bodies.append(body)
            if index == 0, isComplete(body) { break }
        }
        if !bodies.isEmpty { return .ok(bodies) }
        if authFailed { return .authFailed }
        return refusal.map { .refused(String($0.prefix(120))) } ?? .unavailable
    }

    /// The plan, and the project the quota request must name for Argon to appear.
    private static func loadCodeAssist(token: String) async -> (plan: String?, project: String?)? {
        for host in hosts {
            if let (status, body) = await post(host, loadPath, token: token, ua: userAgent, body: loadBody),
               (200..<300).contains(status) {
                return (plan(fromLoadCodeAssist: body), project(fromLoadCodeAssist: body))
            }
        }
        return nil
    }
}
