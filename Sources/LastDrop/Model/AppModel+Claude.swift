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
            return ClaudeAccountRow(account: account, name: name, email: cli.email, plan: plan, snapshot: s.snapshot,
                                    error: s.error, cliUUID: cli.uuid)
        }
    }

    // MARK: Ticks

    /// Every 15 s and when the panel opens: the account list, whether the plugin is installed, the sign-ins,
    /// and the shared usage file the runners route by.
    func claudeTick() async {
        let fresh = AccountsConfig.load()
        if fresh != accountsConfig { accountsConfig = fresh }
        syncPlugin()
        await keeper.tick(claudeConfig.ordered)
        announceSignIns()
        await rereadFullAccounts()
        writeUsageStatus()
        touchHeartbeat()
        let badges = routingBadges()
        if badges != claudeBadges { claudeBadges = badges }
    }

    /// An account that answered "limit reached" is read again at once (at most once a minute), so its own
    /// numbers decide when it frees, not a blind ten minutes.
    private func rereadFullAccounts() async {
        let now = Date()
        let due = claudeConfig.ordered.map { Account(provider: .claude, key: $0.id) }.filter { account in
            guard let full = AgentRegistry.fullSince(account.key) else { return false }
            let s = state(of: account)
            return (s.lastSuccess ?? .distantPast) < full && now.timeIntervalSince(s.lastAttempt ?? .distantPast) >= 60
        }
        if !due.isEmpty { await refresh(due) }
    }

    /// Runners read usage themselves only while this is old.
    private func touchHeartbeat() {
        let url = LastDropPaths.appHeartbeat
        LastDropPaths.ensure(LastDropPaths.support)
        if (try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)) == nil {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
    }

    /// Each account's latest usage and sign-in for the runners, so a pick is a file read. Written under the
    /// file's lock; a newer reading already there (a runner's, while the app was closed) is kept.
    private func writeUsageStatus() {
        let signIns = keeper.signIns
        var claude: [String: (at: Date?, snapshot: UsageSnapshot?)] = [:]
        for account in claudeConfig.ordered {
            let s = state(of: Account(provider: .claude, key: account.id))
            claude[account.id] = (s.lastSuccess, s.snapshot)
        }
        // Agents on other providers pick among their accounts by the same file. A plan without Session and
        // Weekly (OpenRouter credits) counts its one window as both.
        var others: [String: (at: Date, session: Double?, weekly: Double?)] = [:]
        for account in accountsConfig.accounts where account.provider != .claude {
            let s = state(of: account)
            guard let at = s.lastSuccess, let windows = s.snapshot?.windows else { continue }
            func used(_ label: String) -> Double? { windows.first { $0.label == label }?.usedPercent }
            let only = windows.count == 1 ? windows[0].usedPercent : nil
            others[AgentPool.usageKey(account)] = (at, used("Session") ?? only, used("Weekly") ?? only)
        }
        SubagentUsage.update { status in
            for (id, read) in claude {
                var entry = status[id] ?? .init(session: nil, weekly: nil, at: .distantPast)
                if let at = read.at, let snapshot = read.snapshot, at > entry.at {
                    let reading = SubagentUsage.reading(snapshot.windows)
                    entry.session = reading.session
                    entry.weekly = reading.weekly
                    entry.models = reading.models.isEmpty ? nil : reading.models
                    entry.resetsAt = SubagentUsage.resets(snapshot.windows)
                    entry.at = at
                }
                // A plan change shows up without a new reading too (the sign-in names it).
                if let plan = read.snapshot?.plan { entry.plan = plan }
                let signIn = signIns[id]
                entry.signIn = signIn?.state
                entry.signInDetail = signIn?.detail
                entry.signInEndsAt = signIn?.endsAt
                status[id] = entry
            }
            for (id, read) in others where read.at > (status[id]?.at ?? .distantPast) {
                var entry = status[id] ?? .init(session: nil, weekly: nil, at: read.at)
                entry.session = read.session
                entry.weekly = read.weekly
                entry.at = read.at
                status[id] = entry
            }
        }
    }

    // MARK: Where work goes

    /// The account each kind of new work would go to now, worked out by the same rules and from the same file
    /// as the runners, for a session on no account in particular: threads (most room), subagents (smallest plan
    /// with room), and each model-scoped limit ("Fable"). Only with agents on and more than one account.
    func routingBadges(now: Date = .now) -> [String: [String]] {
        guard showsAgents else { return [:] }
        let accounts = claudeConfig.ordered.filter { ClaudeProvider.signedInAccount(configDir: $0.cliConfigDir).uuid != nil }
        guard accounts.count > 1 else { return [:] }
        let status = SubagentUsage.readStatus()
        var readings: [String: SubagentUsage.Reading] = [:]
        for account in accounts {
            var reading = status[account.id].map { SubagentUsage.reading($0, now: now) } ?? .init()
            if keeper.signIns[account.id]?.state.isUsable == false { reading.usable = false }
            // As the runners count it: "limit reached" holds until a newer reading.
            if let full = AgentRegistry.fullSince(account.id, now: now), (status[account.id]?.at ?? .distantPast) < full {
                reading.session = 100
                reading.weekly = 100
            }
            readings[account.id] = reading
        }
        func candidates(_ model: String?) -> [SubagentAccounts.Candidate] {
            accounts.compactMap { account in
                guard let r = readings[account.id], r.usable else { return nil }
                let plan = status[account.id]?.plan ?? keeper.signIns[account.id]?.plan
                return .init(account: account, name: account.id, sessionUsed: r.session, weeklyUsed: r.weekly,
                             modelUsed: r.used(model: model), size: PlanSize(plan: plan))
            }
        }
        var badges: [String: [String]] = [:]
        func mark(_ id: String?, _ badge: String) { if let id { badges[id, default: []].append(badge) } }
        let config = claudeConfig
        mark(SubagentAccounts.pickForThread(candidates(nil))?.account.id, "Threads")
        mark(SubagentAccounts.pick(candidates(nil), sessionThreshold: config.sessionThreshold, weeklyThreshold: config.weeklyThreshold)?.account.id, "Subagents")
        for model in Set(readings.values.flatMap { $0.models.keys }).sorted() {
            mark(SubagentAccounts.pick(candidates(model.lowercased()), sessionThreshold: config.sessionThreshold,
                                       weeklyThreshold: config.weeklyThreshold)?.account.id, model)
        }
        return badges
    }

    // MARK: Sign-ins only you can fix

    /// The Claude accounts that need you to sign in again, in the panel's order and by the panel's names.
    var accountsNeedingSignIn: [AccountInfo] {
        accounts(.claude).filter { $0.signIn.map { !$0.state.isUsable } ?? false }
    }

    /// One notification per account and problem, with a Sign in button; a sign-in ending within three days
    /// gets one too.
    private func announceSignIns() {
        for info in accounts(.claude) {
            guard let signIn = info.signIn else { continue }
            let id = info.account.key
            let problem = !signIn.state.isUsable ? signIn.state.rawValue : signIn.endsSoon() ? "endsSoon" : nil
            let prefix = "signin-\(id)-"
            guard let problem else {
                if announcedSignIns.contains(where: { $0.hasPrefix(prefix) }) {
                    announcedSignIns = announcedSignIns.filter { !$0.hasPrefix(prefix) }
                    withdrawSignIn(account: id)
                }
                continue
            }
            guard announcedSignIns.insert(prefix + problem).inserted else { continue }
            let name = "Claude (\(info.name))"
            let text = problem == "endsSoon"
                ? "\(name)'s sign-in ends \(signIn.endsAt.map { Format.clock($0) } ?? "soon"). Sign in again to keep lastdrop using it."
                : "\(name) needs you to sign in again. Until then, lastdrop doesn't run anything on it."
            postSignIn(text, account: id)
        }
    }

    /// Signs the account in again in the browser, with its address filled in, then reads it at once.
    func signInAgain(_ id: String) {
        let account = ClaudeAccount(id: id)
        let email = ClaudeProvider.signedInAccount(configDir: account.cliConfigDir).email
        Task {
            do {
                try await ClaudeSignIn.browserSignIn(account, email: email)
            } catch {
                claudeError = error.localizedDescription
            }
            keeper.recheck(id)
            await claudeTick()
            await refresh([Account(provider: .claude, key: id)])
        }
    }
}
