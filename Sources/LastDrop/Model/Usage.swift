import Foundation

/// One limit window, e.g. "Session" (5h) or "Weekly".
struct UsageWindow: Hashable, Sendable, Codable {
    var label: String
    /// 0...100, share of the window already used. Nil when the provider returned no number.
    var usedPercent: Double?
    var resetsAt: Date?
    /// Optional count-style value shown instead of a percent ("75 / 100 left").
    var detail: String?
    /// Resets that clear this limit alone (Claude's model-only grants); the account's others sit on the snapshot.
    var resets: LimitResets?

    var remainingPercent: Double? { usedPercent.map { 100 - $0 } }
}

/// Spend on one API key (OpenRouter), in dollars.
struct KeyUsage: Hashable, Sendable, Codable {
    var name: String
    var total: Double
    var today: Double?
    var month: Double?
    var limit: Double?
    var limitRemaining: Double?
    var disabled = false
}

/// One-off limit resets an account holds and can spend: Claude's reset grants, Codex's reset credits.
struct LimitResets: Hashable, Sendable, Codable {
    var count: Int
    /// When each remaining reset expires, soonest first; one entry per reset. May be shorter than
    /// `count` when the provider gave no dates.
    var expiries: [Date]

    func adding(_ count: Int, _ expiries: [Date]) -> LimitResets {
        LimitResets(count: self.count + count, expiries: (self.expiries + expiries).sorted())
    }

    /// Without the resets whose deadline has passed.
    func current(now: Date = .now) -> LimitResets {
        let gone = expiries.filter { $0 <= now }.count
        return LimitResets(count: max(0, count - gone), expiries: expiries.filter { $0 > now })
    }
}

/// Answers that are worth asking for at most once an hour, per account. A failed attempt keeps the
/// previous answer and still counts, so an outage or a 429 is retried an hour later, not every refresh.
actor HourlyCache<Value: Sendable> {
    private var entries: [String: (checked: Date, value: Value?)] = [:]
    private let interval: TimeInterval

    init(interval: TimeInterval = 3600) { self.interval = interval }

    func value(_ key: String, fetch: @Sendable () async throws -> Value?) async -> Value? {
        if let entry = entries[key], Date().timeIntervalSince(entry.checked) < interval { return entry.value }
        let previous = entries[key]?.value
        let value = (try? await fetch()) ?? previous
        entries[key] = (Date(), value)
        return value
    }
}

/// What an account can spend once its plan's limits are used up: Codex credits, Claude extra usage.
struct ExtraCredits: Hashable, Sendable, Codable {
    /// "47,074 credits", "$12.40 of $50.00".
    var amount: String
    /// The limits are used up and this is what the account runs on now.
    var inUse = false
    /// "About 11,769 to 61,197 messages".
    var detail: String?
}

/// Everything a provider (or one account of a provider) reports in one refresh.
struct UsageSnapshot: Hashable, Sendable, Codable {
    var title: String           // "Claude", "Codex", "Antigravity", "Z.ai", "OpenRouter"
    var plan: String?           // "Max 5x", "Pro", "GLM Coding Max"
    var windows: [UsageWindow]
    /// Per-key spend, shown when the provider section is expanded.
    var keys: [KeyUsage] = []
    /// Replaces the Session/Weekly percentages in the menu bar ("$37.66").
    var menuBarText: String?
    var resets: LimitResets?
    var credits: ExtraCredits?
    var fetchedAt: Date = .now
}

enum ProviderID: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude, codex, antigravity, zai, openrouter
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        case .zai: "Z.ai"
        case .openrouter: "OpenRouter"
        }
    }
}

enum ProviderError: LocalizedError, Sendable {
    case notConfigured(String)      // e.g. "Run `codex` to sign in."; hides the menu bar item
    case unauthorized(String)
    case http(Int)
    case rateLimited(String)        // retried on the normal schedule, not the fast one
    case invalidResponse
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let s), .unauthorized(let s), .message(let s), .rateLimited(let s): s
        case .http(let code): "Request failed (HTTP \(code))."
        case .invalidResponse: "Unexpected response."
        }
    }
}

protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    func fetch() async throws -> UsageSnapshot
}
