import AppKit
import Foundation

/// One Claude account with everything the panel, the menu bar and Settings show about it.
struct ClaudeAccountRow: Identifiable {
    var account: ClaudeAccount
    /// "Max", "Pro": what the menu bar and the panel call it.
    var name: String
    var email: String?
    var plan: String?
    var snapshot: UsageSnapshot?
    var error: String?
    /// The account its Claude Code sign-in belongs to; nil when not signed in yet.
    var cliUUID: String?
    /// Below both thresholds, so it can take subagents from sessions on other accounts.
    var takesSubagents = false
    var id: String { account.id }
    var isMain: Bool { account.isMain }

    func used(_ label: String) -> Double? { snapshot?.windows.first { $0.label == label }?.usedPercent }
}

extension AppModel {
    // MARK: Derived

    /// Several accounts: the Claude card lists them instead of one set of meters.
    var showsClaudeAccounts: Bool { !claudeConfig.accounts.isEmpty }

    var claudeRows: [ClaudeAccountRow] {
        claudeConfig.ordered.map { account -> ClaudeAccountRow in
            let s = state(of: Account(provider: .claude, key: account.id))
            let cli = ClaudeProvider.signedInAccount(configDir: account.cliConfigDir)
            let plan = s.snapshot?.plan
            let name = account.isMain ? plan.map { String($0.split(separator: " ")[0]) } ?? "Main" : account.id
            var row = ClaudeAccountRow(account: account, name: name, email: cli.email, plan: plan, snapshot: s.snapshot,
                                       error: s.error, cliUUID: cli.uuid)
            if let session = row.used("Session"), let weekly = row.used("Weekly") {
                row.takesSubagents = session < claudeConfig.sessionThreshold * 100 && weekly < claudeConfig.weeklyThreshold * 100
            }
            return row
        }
    }

    // MARK: Ticks

    /// Every 15 s and when the panel opens: the account list, whether the plugin is installed, and the
    /// Claude accounts' usage for the subagent runner.
    func claudeTick() async {
        let fresh = AccountsConfig.load()
        if fresh != accountsConfig { accountsConfig = fresh }
        syncPlugin()
        writeUsageStatus()
    }

    /// Each account's latest usage for the subagent runner, so it needn't ask Anthropic on every run.
    private func writeUsageStatus() {
        var status: [String: SubagentUsage.Status] = [:]
        for row in claudeRows {
            let s = state(of: Account(provider: .claude, key: row.id))
            // Kept through errors (rate limited, say): when it was read goes with it.
            guard let at = s.lastSuccess, s.snapshot != nil else { continue }
            status[row.id] = .init(session: row.used("Session"), weekly: row.used("Weekly"), at: at, plan: s.snapshot?.plan)
        }
        // Agents on other providers pick among their accounts by the same reading. A plan without
        // Session and Weekly (OpenRouter credits) counts its one window as both.
        for account in accountsConfig.accounts where account.provider != .claude {
            let s = state(of: account)
            guard let at = s.lastSuccess, let windows = s.snapshot?.windows else { continue }
            func used(_ label: String) -> Double? { windows.first { $0.label == label }?.usedPercent }
            let only = windows.count == 1 ? windows[0].usedPercent : nil
            status[AgentPool.usageKey(account)] = .init(session: used("Session") ?? only, weekly: used("Weekly") ?? only, at: at)
        }
        let saved = SubagentUsage.readStatus()
        // A runner may have read an account more recently than the app.
        for (id, entry) in saved where (status[id]?.at ?? .distantPast) < entry.at { status[id] = entry }
        // The backoff is shared with the runners: the app's rebuilt entries keep it, and an account never read yet
        // keeps its placeholder.
        for (id, entry) in saved where entry.blockedUntil != nil || entry.failures != nil {
            if status[id] == nil { status[id] = entry; continue }
            status[id]?.blockedUntil = entry.blockedUntil
            status[id]?.failures = entry.failures
        }
        if status != saved { SubagentUsage.writeStatus(status) }
    }
}
