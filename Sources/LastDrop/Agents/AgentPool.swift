import Foundation

/// Which of a provider's accounts runs an agent from lastdrop's list: the one with the most room under the
/// thresholds, else the first that can, as Claude subagents pick among Claude accounts. A follow-up stays on
/// the account its agent started on, since its thread or session lives there.
enum AgentPool {
    /// Antigravity agents go through `agy`, which keeps one login per Mac: only the main account can run them.
    static func pools(_ provider: AgentProvider) -> Bool { [.codex, .zai, .openrouter].contains(provider) }

    /// The account for a run, reading the saved accounts and the usage the app last wrote.
    static func account(_ provider: AgentProvider, resume: AgentRegistry.Entry?) -> Account {
        let config = AccountsConfig.load()
        if let id = resume?.accountID, let account = config.account(id) { return account }
        guard pools(provider) else { return .main(provider.usageID) }
        let accounts = config.pool(provider.usageID).filter { $0.isMain || canRun($0) }
        return pick(accounts, usage: SubagentUsage.readStatus(), config: config) ?? .main(provider.usageID)
    }

    /// Has what the provider needs to run agents, judged locally: a CLI login or a key of its own.
    static func canRun(_ account: Account) -> Bool {
        switch account.provider {
        case .codex: CodexProvider.hasCredentials(home: account.folder)
        case .zai: ZAIProvider.apiKey(keyItem: account.keychainItem(ZAIProvider.keyAccount), usesFallbacks: account.isMain) != nil
        case .openrouter: OpenRouterProvider.apiKey(keyItem: account.keychainItem(OpenRouterProvider.keyAccount), usesEnvironment: account.isMain) != nil
        case .claude, .antigravity: account.isMain
        }
    }

    /// The account with the most room; ties keep the order. With no reading under the thresholds, the
    /// first: unknown usage doesn't stop an agent, the provider answers "limit reached" if it must.
    static func pick(_ accounts: [Account], usage: [String: SubagentUsage.Status], config: AccountsConfig, now: Date = .now,
                     isFull: (String) -> Bool = AgentRegistry.isFull) -> Account? {
        var best: (Account, Double)?
        for account in accounts {
            guard !isFull(usageKey(account)), let room = room(account, usage: usage, config: config, now: now) else { continue }
            if best == nil || room > best!.1 { best = (account, room) }
        }
        return best?.0 ?? accounts.first
    }

    /// The account the panel marks Next: only one with room, since when all are full, work stays where it is.
    /// Claude subagents avoid the session's own account, which the panel takes to be Main, until no other has room.
    static func next(_ pool: [Account], usage: [String: SubagentUsage.Status], config: AccountsConfig, now: Date = .now) -> Account? {
        let open = pool.filter { room($0, usage: usage, config: config, now: now) != nil }
        let others = open.filter { $0.provider == .claude && !$0.isMain }
        return pick(others.isEmpty ? open : others, usage: usage, config: config, now: now, isFull: { _ in false })
    }

    /// Points left before the nearer threshold; nil when unknown, stale or past it.
    static func room(_ account: Account, usage: [String: SubagentUsage.Status], config: AccountsConfig, now: Date = .now) -> Double? {
        guard let status = usage[usageKey(account)], now.timeIntervalSince(status.at) < 30 * 60 else { return nil }
        let rooms = [status.session.map { config.sessionThreshold * 100 - $0 }, status.weekly.map { config.weeklyThreshold * 100 - $0 }].compactMap { $0 }
        guard let room = rooms.min(), room > 0 else { return nil }
        return room
    }

    /// Claude accounts keep their old usage keys ("main", "Pro"), which the subagent runner reads.
    static func usageKey(_ account: Account) -> String { account.provider == .claude ? account.key : account.id }

    /// Where it runs, as the agent's row says it: "Codex", or "Codex · Work" for an added account.
    static func place(_ account: Account, name: String? = nil) -> String {
        account.isMain ? account.provider.displayName : "\(account.provider.displayName) · \(name ?? account.name ?? account.key)"
    }
}
