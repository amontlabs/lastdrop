import Foundation

/// Z.ai (GLM Coding Plan) usage, authenticated with an API key.
struct ZAIProvider: UsageProvider {
    var id: ProviderID { .zai }
    /// The keychain accounts of this account's website session and Coding Plan key.
    var sessionItem = Self.sessionAccount
    var keyItem = Self.keyAccount
    /// Falls back to `~/.config/zai/key.json`, `ZAI_API_KEY` and `GLM_API_KEY`: the main account only.
    var usesFallbacks = true

    private static let quotaURL = "https://api.z.ai/api/monitor/usage/quota/limit"
    private static let subscriptionURL = "https://api.z.ai/api/biz/subscription/list"

    func fetch() async throws -> UsageSnapshot {
        guard let auth = Self.authorization(sessionItem: sessionItem, keyItem: keyItem, usesFallbacks: usesFallbacks) else { throw ProviderError.notConfigured("Sign in to Z.ai in Settings.") }
        let headers = ["Authorization": auth.header, "Accept": "application/json"]

        let (body, http) = try await HTTP.json(HTTP.request(Self.quotaURL, headers: headers))
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderError.unauthorized(auth.isSession ? "Z.ai session expired. Sign in again in Settings."
                                                            : "Z.ai API key invalid. Check it in Settings.")
        }
        guard (200..<300).contains(http.statusCode) else { throw ProviderError.http(http.statusCode) }
        guard let root = body as? [String: Any] else { throw ProviderError.invalidResponse }
        let windows = try Self.windows(from: root)

        // Plan name is best-effort.
        var plan: String?
        if let (sub, subHTTP) = try? await HTTP.json(HTTP.request(Self.subscriptionURL, headers: headers)),
           (200..<300).contains(subHTTP.statusCode), let subRoot = sub as? [String: Any] {
            plan = Self.plan(from: subRoot)
        }
        return UsageSnapshot(title: "Z.ai", plan: plan, windows: windows)
    }

    // MARK: Mapping (pure)

    /// Window length in hours from Z.ai's `(unit, number)` pair: 3 = hours, 4 = days, 5 = months, 6 = weeks.
    private static func hours(unit: Double, number: Double) -> Double? {
        switch unit {
        case 3: number
        case 4: number * 24
        case 5: number * 24 * 30
        case 6: number * 24 * 7
        default: nil
        }
    }

    static func windows(from root: [String: Any]) throws -> [UsageWindow] {
        if root["success"] as? Bool == false {
            throw ProviderError.message(root.string("msg") ?? "Z.ai returned an error.")
        }
        let container = root.dict("data") ?? root
        guard let limits = container.array("limits") else { throw ProviderError.invalidResponse }

        func type(_ e: [String: Any]) -> String? { e.string("type") ?? e.string("name") }
        func reset(_ e: [String: Any]) -> Date? { Dates.epoch(e.double("nextResetTime")) }

        var windows: [UsageWindow] = []
        for entry in limits where type(entry) == "CREDIT_LIMIT" || type(entry) == "TOKENS_LIMIT" {
            guard let unit = entry.double("unit"), let number = entry.double("number"), number > 0,
                  let h = hours(unit: unit, number: number), let pct = entry.double("percentage") else { continue }
            windows.append(UsageWindow(label: h < 24 ? "Session" : "Weekly",
                                       usedPercent: min(max(pct, 0), 100), resetsAt: reset(entry)))
        }
        if let web = limits.first(where: { type($0) == "TIME_LIMIT" }),
           let used = web.double("currentValue"), let limit = web.double("usage") {
            windows.append(UsageWindow(label: "Web Searches",
                                       usedPercent: limit > 0 ? min(max(used / limit * 100, 0), 100) : nil,
                                       resetsAt: reset(web),
                                       detail: "\(Int(max(limit - used, 0))) / \(Int(limit)) left"))
        }
        return windows
    }

    static func plan(from root: [String: Any]) -> String? {
        guard let name = root.array("data")?.first?.string("productName"), !name.isEmpty else { return nil }
        return name
    }

    // MARK: Credentials

    static let service = "lastdrop", sessionAccount = "zai-session", keyAccount = "zai-api-key"

    /// The web session from Settings → Sign in, else an API key.
    static func authorization(sessionItem: String, keyItem: String, usesFallbacks: Bool) -> (header: String, isSession: Bool)? {
        if let header = Keychain.readOwn(service: service, account: sessionItem), !header.isEmpty { return (header, true) }
        return apiKey(keyItem: keyItem, usesFallbacks: usesFallbacks).map { ("Bearer \($0)", false) }
    }

    /// The first candidate token that the quota endpoint accepts, as a full `Authorization` value.
    static func validSessionHeader(_ candidates: [String]) async -> String? {
        for token in candidates {
            for header in ["Bearer \(token)", token] {
                let req = HTTP.request(quotaURL, headers: ["Authorization": header, "Accept": "application/json"])
                guard let (body, http) = try? await HTTP.json(req), (200..<300).contains(http.statusCode),
                      let root = body as? [String: Any], (try? windows(from: root)) != nil else { continue }
                return header
            }
        }
        return nil
    }

    /// The main account's key, which agents use.
    static func apiKey() -> String? { apiKey(keyItem: keyAccount, usesFallbacks: true) }

    static func apiKey(keyItem: String, usesFallbacks: Bool) -> String? {
        if let k = Keychain.readOwn(service: service, account: keyItem), !k.isEmpty { return k }
        guard usesFallbacks else { return nil }
        if let k = keyFromFile() { return k }
        for name in ["ZAI_API_KEY", "GLM_API_KEY"] {
            if let k = envValue(name) { return k }
        }
        return nil
    }

    private static func keyFromFile() -> String? {
        let path = NSHomeDirectory() + "/.config/zai/key.json"
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for k in ["apiKey", "api_key", "key"] {
                if let s = json.string(k)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
            }
            return nil
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// GUI apps don't inherit the shell environment, so fall back to asking a login shell.
    private static func envValue(_ name: String) -> String? {
        if let v = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lic", "printf %s \"$\(name)\""]
        p.currentDirectoryURL = URL(fileURLWithPath: LastDropPaths.helperDirectory)
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        if done.wait(timeout: .now() + 3) == .timedOut { p.terminate(); return nil }
        let value = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
