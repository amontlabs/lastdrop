import AppKit
import Foundation

/// Whether an account works for one feature, as its row shows it.
enum Capability: Equatable, Sendable {
    case ready
    /// Not working, with what to do about it ("Install agy").
    case problem(String)
    /// Not known yet: still loading.
    case pending
}

/// What lastdrop found about an account on this Mac, without asking the provider. Slow to work out (it reads
/// the keychain through `security`), so it's refreshed in the background and kept.
struct LocalCheck: Equatable, Sendable {
    var connected: Bool
    var email: String?
    /// Whether it can run agents, or what it lacks; nil when its provider can't run agents on it.
    var agents: Capability?
}

/// One account as the panel and Settings show it.
struct AccountInfo: Identifiable {
    var account: Account
    var name: String
    var email: String?
    var plan: String?
    var state: ProviderState
    var limits: Capability
    /// The account new agents of its provider go to: the one with the most room. Not for Claude, which has
    /// `badges` instead.
    var isNext = false
    /// Claude: the kinds of new work that go to this account ("Threads", "Subagents", "Fable").
    var badges: [String] = []
    /// Claude: its sign-in, as the keeper judged it.
    var signIn: ClaudeKeeper.SignIn?
    var id: String { account.id }

    func used(_ label: String) -> Double? { state.snapshot?.windows.first { $0.label == label }?.usedPercent }
}

/// Where adding an account stands.
enum ConnectStatus: Equatable {
    case idle
    /// Waiting for the browser or checking a key; the text says which.
    case working(String)
    case failed(String)
}

extension AppModel {
    // MARK: What to show

    /// The provider's accounts that are connected, or were added: a main account shows once a login is found.
    func accounts(_ provider: ProviderID) -> [AccountInfo] {
        let next = nextAccountID(provider)
        return accountsConfig.pool(provider).compactMap { account -> AccountInfo? in
            let s = state(of: account)
            let check = localChecks[account.id]
            let connected = check?.connected ?? (s.snapshot != nil || (s.lastAttempt != nil && !s.notConfigured))
            guard !account.isMain || connected || s.snapshot != nil else { return nil }
            return info(account, state: s, check: check)
        }.map { (info: AccountInfo) -> AccountInfo in
            var info = info
            info.isNext = info.id == next
            if provider == .claude {
                info.badges = claudeBadges[info.account.key] ?? []
                info.signIn = keeper.signIns[info.account.key]
            }
            return info
        }
    }

    /// The account new agents of this provider go to, when there's a choice and an extra model of the Agent
    /// tool runs on it. Claude accounts show where each kind of work goes instead (`claudeBadges`).
    private func nextAccountID(_ provider: ProviderID) -> String? {
        guard showsAgents, provider != .claude else { return nil }
        let pool = accountsConfig.pool(provider).filter { localChecks[$0.id]?.agents == .ready }
        guard pool.count > 1 else { return nil }
        if provider != .claude {
            guard let agentProvider = AgentProvider.allCases.first(where: { $0.usageID == provider }), AgentPool.pools(agentProvider),
                  AgentCatalog.load().enabled.contains(where: { $0.provider == agentProvider }) else { return nil }
        }
        var usage: [String: SubagentUsage.Status] = [:]
        for account in pool {
            let s = state(of: account)
            guard let at = s.lastSuccess, let windows = s.snapshot?.windows else { continue }
            func used(_ label: String) -> Double? { windows.first { $0.label == label }?.usedPercent }
            let only = windows.count == 1 ? windows[0].usedPercent : nil
            usage[AgentPool.usageKey(account)] = .init(session: used("Session") ?? only, weekly: used("Weekly") ?? only, at: at)
        }
        return AgentPool.next(pool, usage: usage, config: accountsConfig)?.id
    }

    /// Why no account of the provider can run agents ("Install agy"), else nil.
    func agentProblem(_ provider: AgentProvider) -> String? {
        guard provider != .claude else { return nil }
        let checks = accountsConfig.pool(provider.usageID).compactMap { localChecks[$0.id]?.agents }
        guard !checks.isEmpty, !checks.contains(.ready) else { return nil }
        return checks.compactMap(\.problem).first ?? "Connect a \(provider.displayName) account"
    }

    /// Providers with at least one account to show, in the panel's order.
    var connectedProviders: [ProviderID] { order.filter { !accounts($0).isEmpty } }

    var allAccounts: [AccountInfo] { order.flatMap { accounts($0) } }

    private func info(_ account: Account, state s: ProviderState, check: LocalCheck?) -> AccountInfo {
        let plan = s.snapshot?.plan
        return AccountInfo(account: account, name: displayName(account, plan: plan), email: check?.email, plan: plan, state: s,
                           limits: limitsCapability(s, connected: check?.connected))
    }

    /// Its own name, else its plan's first word for Claude ("Max"), else the plan, else "Main".
    func displayName(_ account: Account, plan: String?) -> String {
        if let name = account.name { return name }
        if account.provider == .claude, let first = plan?.split(separator: " ").first { return String(first) }
        return plan ?? (account.isMain ? account.provider.displayName : account.key)
    }

    private func limitsCapability(_ s: ProviderState, connected: Bool?) -> Capability {
        if connected == false && s.snapshot == nil { return .problem("Not signed in") }
        if let error = s.error { return .problem(error) }
        return s.snapshot == nil ? .pending : .ready
    }

    /// Works out every account's local check off the main thread.
    func refreshLocalChecks() {
        let accounts = accountsConfig.accounts
        Task.detached(priority: .utility) {
            var checks: [String: LocalCheck] = [:]
            for account in accounts { checks[account.id] = Self.localCheck(account) }
            await MainActor.run { if checks != self.localChecks { self.localChecks = checks } }
        }
    }

    nonisolated static func localCheck(_ account: Account) -> LocalCheck {
        let connected = account.hasCredentials
        var check = LocalCheck(connected: connected)
        switch account.provider {
        case .claude:
            check.email = ClaudeProvider.signedInAccount(configDir: account.folder).email
            check.agents = connected ? .ready : .problem("Not signed in")
        case .antigravity:
            let raw = Keychain.readOwn(service: AntigravityProvider.loginService, account: account.keychainItem(AntigravityProvider.loginAccount))
            check.email = raw.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }?.string("email")
            // Agents run through `agy`, whose own login is one per Mac: the main account's.
            if account.isMain { check.agents = AntigravityBackend.executable() == nil ? .problem("Install the Antigravity CLI (agy)") : .ready }
        case .codex:
            check.agents = CodexBackend.executable() == nil ? .problem("Install the Codex CLI") : AgentPool.canRun(account) ? .ready : .problem("Sign in to Codex")
        case .zai:
            check.agents = AgentPool.canRun(account) ? .ready : .problem("Add a Z.ai Coding Plan key")
        case .openrouter:
            check.agents = AgentPool.canRun(account) ? .ready : .problem("Add an OpenRouter API key")
        }
        return check
    }

    // MARK: Adding

    /// What adding an account of `provider` signs in: its main account while that has no login, else a new one.
    func connectTarget(_ provider: ProviderID) -> Account {
        let main = Account.main(provider)
        if localChecks[main.id]?.connected == false || accounts(provider).isEmpty { return main }
        return Account(provider: provider, key: accountsConfig.newKey(provider))
    }

    /// Signs in through the browser: Claude and Codex through their CLIs, Antigravity with Google.
    func connectInBrowser(_ provider: ProviderID) {
        let account = connectTarget(provider)
        run(connect: account, status: "Finish signing in in your browser.") {
            switch provider {
            case .claude:
                try await ClaudeSignIn.browserSignIn(ClaudeAccount(id: account.key))
            case .codex:
                guard let codex = CodexBackend.executable() else { throw ProviderError.message("The Codex CLI (`codex`) was not found on this Mac.") }
                var environment = ProcessInfo.processInfo.environment
                if let home = account.folder {
                    LastDropPaths.ensure(URL(fileURLWithPath: home))
                    // Its own login, and the user's Codex settings: config (MCP servers, model) and instructions.
                    for item in ["config.toml", "AGENTS.md", "prompts", "skills"] {
                        let source = NSHomeDirectory() + "/.codex/" + item, target = home + "/" + item
                        guard FileManager.default.fileExists(atPath: source), (try? FileManager.default.attributesOfItem(atPath: target)) == nil else { continue }
                        try FileManager.default.createSymbolicLink(atPath: target, withDestinationPath: source)
                    }
                    environment["CODEX_HOME"] = home
                }
                try await CLILogin.run(codex, ["login"], environment: environment)
                guard CodexProvider.hasCredentials(home: account.folder) else { throw ProviderError.message("The sign-in didn't finish. Try again.") }
            case .antigravity:
                let (refreshToken, email) = try await GoogleOAuth.signIn()
                var login: [String: Any] = ["refresh_token": refreshToken]
                login["email"] = email
                let data = try JSONSerialization.data(withJSONObject: login)
                guard Keychain.writeOwn(service: AntigravityProvider.loginService, account: account.keychainItem(AntigravityProvider.loginAccount),
                                        value: String(decoding: data, as: UTF8.self)) else {
                    throw ProviderError.message("Couldn't save the sign-in to the keychain.")
                }
            case .zai, .openrouter:
                throw ProviderError.message("\(provider.displayName) connects with an API key.")
            }
        }
    }

    /// Saves an API key (Z.ai, OpenRouter) once the provider accepts it.
    func connect(_ provider: ProviderID, key: String) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let account = connectTarget(provider)
        let item = account.keychainItem(provider == .zai ? ZAIProvider.keyAccount : OpenRouterProvider.keyAccount)
        let service = provider == .zai ? ZAIProvider.service : OpenRouterProvider.keyService
        run(connect: account, status: "Checking the key…") {
            let previous = Keychain.readOwn(service: service, account: item)
            guard Keychain.writeOwn(service: service, account: item, value: key) else { throw ProviderError.message("Couldn't save the key to the keychain.") }
            do {
                _ = try await account.usageProvider.fetch()
            } catch {
                // Put back what was there, so a typo doesn't sign the account out; unless another attempt
                // has saved its own key since.
                if Keychain.readOwn(service: service, account: item) == key {
                    if let previous { _ = Keychain.writeOwn(service: service, account: item, value: previous) } else { Keychain.delete(service: service, account: item) }
                }
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                throw ProviderError.message("\(provider.displayName) didn't accept the key: \(error.localizedDescription)")
            }
        }
    }

    /// The z.ai website sign-in, for the main account: it reads limits only.
    func connectZAIWebsite() {
        connectStatus = .idle
        ZAISignInWindow.present { [weak self] success in
            guard let self, success else { return }
            self.finishConnect(.main(.zai))
        }
    }

    func cancelConnect() {
        connectTask?.cancel()
        connectTask = nil
        connectStatus = .idle
    }

    private func run(connect account: Account, status: String, _ body: @escaping @MainActor () async throws -> Void) {
        connectTask?.cancel()
        connectStatus = .working(status)
        connectTask = Task {
            do {
                try await body()
                finishConnect(account)
            } catch is CancellationError {
                connectStatus = .idle
            } catch {
                if !Task.isCancelled { connectStatus = .failed(error.localizedDescription) }
            }
            NSApp.activate()
        }
    }

    /// Adds a new account to its pool once signed in, named after its plan, and reads its usage.
    private func finishConnect(_ account: Account) {
        if !account.isMain, accountsConfig.account(account.id) == nil {
            updateAccounts { $0.append(account) }
        }
        connectStatus = .idle
        lastConnected = account.id
        forgetUsage(account)
        refreshLocalChecks()
        Task {
            await refresh([account])
            // Two accounts on one plan would read the same: number the newer one.
            guard !account.isMain, accountsConfig.account(account.id)?.name == nil, let plan = state(of: account).snapshot?.plan else { return }
            let base = account.provider == .claude ? String(plan.split(separator: " ").first ?? "") : plan
            let taken = Set(accounts(account.provider).filter { $0.id != account.id }.map(\.name))
            let name = ([base] + (2...9).map { "\(base) \($0)" }).first { !taken.contains($0) } ?? base
            updateAccounts { $0.rename(account.id, to: name) }
        }
    }

    // MARK: Changing

    func rename(_ id: String, to name: String) { updateAccounts { $0.rename(id, to: name) } }

    func moveAccount(_ id: String, by offset: Int) { updateAccounts { $0.move(id, by: offset) } }

    /// A main account of a CLI login (Claude, Codex) stays: signing out is the CLI's business.
    func canRemove(_ account: Account) -> Bool { !account.isMain || ![.claude, .codex].contains(account.provider) }

    /// Forgets an account and the keys lastdrop kept for it. An added account's CLI folder stays on disk.
    /// A main account only loses lastdrop's own sign-in.
    func remove(_ account: Account) {
        for (service, item) in Self.ownItems(account.provider) {
            Keychain.delete(service: service, account: account.keychainItem(item))
        }
        if !account.isMain { updateAccounts { $0.remove(account.id) } }
        forgetUsage(account)
        refreshLocalChecks()
        if account.isMain { Task { await refresh([account]) } }
    }

    /// The keychain items lastdrop itself keeps for a provider's accounts (before the per-account suffix).
    nonisolated static func ownItems(_ provider: ProviderID) -> [(service: String, item: String)] {
        switch provider {
        case .antigravity: [(AntigravityProvider.loginService, AntigravityProvider.loginAccount)]
        case .zai: [(ZAIProvider.service, ZAIProvider.sessionAccount), (ZAIProvider.service, ZAIProvider.keyAccount)]
        case .openrouter: [(OpenRouterProvider.keyService, OpenRouterProvider.keyAccount)]
        case .claude, .codex: []
        }
    }

    /// Opens Terminal on `claude` for the account, when the browser sign-in can't be used.
    func signInInTerminal(_ account: Account) {
        do {
            try ClaudeSignIn.openTerminalSignIn(ClaudeAccount(id: account.key), name: displayName(account, plan: state(of: account).snapshot?.plan))
        } catch {
            connectStatus = .failed("Couldn't open Terminal: \(error.localizedDescription)")
        }
    }

    func setThresholds(session: Double? = nil, weekly: Double? = nil) {
        updateAccounts { config in
            if let session { config.sessionThreshold = session }
            if let weekly { config.weeklyThreshold = weekly }
        }
    }

    /// Changes the saved account list, which agent runners read too.
    func updateAccounts(_ change: (inout AccountsConfig) -> Void) {
        var config = AccountsConfig.load()
        change(&config)
        do {
            try config.save()
            accountsConfig = config
        } catch {
            connectStatus = .failed("Couldn't save the account list: \(error.localizedDescription)")
        }
    }
}
