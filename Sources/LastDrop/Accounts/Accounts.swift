import Foundation

/// One sign-in on one provider. A provider's accounts form its pool, in priority order: the panel lists
/// them in that order, and work goes to the one with the most room, then the next.
///
/// Every provider has a main account, which uses the login already on the Mac (Claude Code's `~/.claude`,
/// Codex's `~/.codex`, the Antigravity app, `ZAI_API_KEY`…) and lastdrop's original keychain items. Every
/// other account keeps its login apart: its own folder for CLIs, or keychain items suffixed with its key.
struct Account: Codable, Hashable, Sendable, Identifiable {
    static let mainKey = "main"

    var provider: ProviderID
    /// Unique within the provider: "main", or a short name also used in folder and keychain names ("Pro").
    var key: String
    /// What the panel and Settings call it ("Pro", "Work"); nil uses its plan.
    var name: String?
    var addedAt = Date()
    /// What it shows in the menu bar; nil shows nothing, and with nothing shown the menu bar is an icon.
    var menuBar: MenuBarMode?
    /// Notify when a Session or Weekly limit reaches this share used (0...1); nil never.
    var notifyAt: Double?

    static let notifyChoices = [0.75, 0.9, 1.0]

    /// A notification level as people read it: what's left, not what's used ("At 10% left").
    static func notifyTitle(_ level: Double) -> String {
        level >= 1 ? "Used up" : "\(Int(((1 - level) * 100).rounded()))% left"
    }

    init(provider: ProviderID, key: String, name: String? = nil, addedAt: Date = Date(), menuBar: MenuBarMode? = nil, notifyAt: Double? = 1) {
        self.provider = provider
        self.key = key
        self.name = name
        self.addedAt = addedAt
        self.menuBar = menuBar
        self.notifyAt = notifyAt
    }

    static func main(_ provider: ProviderID) -> Account { Account(provider: provider, key: mainKey, addedAt: .distantPast) }

    /// "claude.main", "codex.work": unique across providers.
    var id: String { "\(provider.rawValue).\(key)" }
    var isMain: Bool { key == Self.mainKey }

    /// "Pro" → "Pro"; "my work" → "my-work". Letters, digits, "-" and "_" only.
    static func slug(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let parts = name.trimmingCharacters(in: .whitespaces).components(separatedBy: allowed.inverted)
        return parts.filter { !$0.isEmpty }.joined(separator: "-")
    }

    // MARK: Where its login lives

    /// Tests point `~/.claude-accounts` elsewhere.
    nonisolated(unsafe) static var claudeFoldersOverride: String?

    /// The folder a CLI keeps this account's login in: `CLAUDE_CONFIG_DIR` or `CODEX_HOME`. Nil for a main
    /// account, which uses the CLI's default, and for providers without a CLI login.
    var folder: String? {
        guard !isMain else { return nil }
        switch provider {
        case .claude: return (Self.claudeFoldersOverride ?? NSHomeDirectory() + "/.claude-accounts") + "/\(key)"
        case .codex: return NSHomeDirectory() + "/.codex-accounts/\(key)"
        case .antigravity, .zai, .openrouter: return nil
        }
    }

    /// The keychain account for one of lastdrop's own items ("zai-api-key"), kept apart per account.
    func keychainItem(_ base: String) -> String { isMain ? base : "\(base).\(key)" }

    /// Reads this account's usage.
    var usageProvider: any UsageProvider {
        switch provider {
        case .claude: ClaudeProvider(configDir: folder)
        case .codex: CodexProvider(home: folder)
        case .antigravity: AntigravityProvider(login: keychainItem(AntigravityProvider.loginAccount), usesAppLogin: isMain)
        case .zai: ZAIProvider(sessionItem: keychainItem(ZAIProvider.sessionAccount), keyItem: keychainItem(ZAIProvider.keyAccount),
                               usesFallbacks: isMain)
        case .openrouter: OpenRouterProvider(keyItem: keychainItem(OpenRouterProvider.keyAccount), usesEnvironment: isMain)
        }
    }

    /// Has a login or key lastdrop can use, judged locally without asking the provider: true doesn't
    /// mean it still works.
    var hasCredentials: Bool {
        switch provider {
        case .claude: ClaudeProvider.signedInAccount(configDir: folder).uuid != nil
        case .codex: CodexProvider.hasCredentials(home: folder)
        case .antigravity: AntigravityProvider.hasCredentials(login: keychainItem(AntigravityProvider.loginAccount), usesAppLogin: isMain)
        case .zai: ZAIProvider.authorization(sessionItem: keychainItem(ZAIProvider.sessionAccount),
                                             keyItem: keychainItem(ZAIProvider.keyAccount), usesFallbacks: isMain) != nil
        case .openrouter: OpenRouterProvider.apiKey(keyItem: keychainItem(OpenRouterProvider.keyAccount), usesEnvironment: isMain) != nil
        }
    }
}

/// Every account of every provider, and how work picks among a pool. Saved in lastdrop's support folder,
/// read by the app and by each agent runner.
struct AccountsConfig: Codable, Equatable, Sendable {
    /// Each provider's pool in priority order. Always holds exactly one main account per provider.
    var accounts: [Account] = []
    /// An account takes work while its Session and its Weekly use are below these (0...1).
    var sessionThreshold = AccountsConfig.defaultThreshold
    var weeklyThreshold = AccountsConfig.defaultThreshold
    static let defaultThreshold = 0.9

    init() { normalize() }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try c.decodeIfPresent([Account].self, forKey: .accounts) ?? []
        sessionThreshold = try c.decodeIfPresent(Double.self, forKey: .sessionThreshold) ?? Self.defaultThreshold
        weeklyThreshold = try c.decodeIfPresent(Double.self, forKey: .weeklyThreshold) ?? Self.defaultThreshold
        normalize()
    }

    /// One provider's accounts, main included, in priority order.
    func pool(_ provider: ProviderID) -> [Account] { accounts.filter { $0.provider == provider } }

    func account(_ id: String) -> Account? { accounts.first { $0.id == id } }

    /// Drops duplicate accounts and adds a missing main account at the front of its pool.
    mutating func normalize() {
        var seen = Set<String>()
        accounts = accounts.filter { seen.insert($0.id).inserted }
        for provider in ProviderID.allCases where !seen.contains(Account.main(provider).id) {
            let first = accounts.firstIndex { $0.provider == provider } ?? accounts.endIndex
            accounts.insert(.main(provider), at: first)
        }
    }

    /// Adds an account at the end of its provider's pool. Nil when the name has no usable characters,
    /// is "main", or is taken in that pool (compared ignoring case: folder names on macOS do).
    mutating func add(_ provider: ProviderID, name: String) -> Account? {
        let key = Account.slug(name)
        guard !key.isEmpty, key.lowercased() != Account.mainKey,
              !pool(provider).contains(where: { $0.key.lowercased() == key.lowercased() }) else { return nil }
        let account = Account(provider: provider, key: key)
        append(account)
        return account
    }

    /// Puts `account` at the end of its provider's pool.
    mutating func append(_ account: Account) {
        let after = accounts.lastIndex { $0.provider == account.provider }.map { $0 + 1 } ?? accounts.endIndex
        accounts.insert(account, at: after)
    }

    /// A key no account of the provider has yet, for an account added before its name is known ("codex-2").
    func newKey(_ provider: ProviderID) -> String {
        let taken = Set(pool(provider).map { $0.key.lowercased() })
        return (2...).lazy.map { "\(provider.rawValue)-\($0)" }.first { !taken.contains($0) }!
    }

    mutating func rename(_ id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id) { $0.name = name.isEmpty ? nil : name }
    }

    mutating func update(_ id: String, _ change: (inout Account) -> Void) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        change(&accounts[i])
    }

    /// Forgets an account. A main account can't be removed: it stands for the login already on the Mac.
    mutating func remove(_ id: String) {
        accounts.removeAll { $0.id == id && !$0.isMain }
    }

    /// Moves an account up (-1) or down (+1) its own pool; other providers' accounts don't count as steps.
    mutating func move(_ id: String, by offset: Int) {
        guard let account = account(id) else { return }
        var pool = pool(account.provider)
        guard let i = pool.firstIndex(of: account), pool.indices.contains(i + offset) else { return }
        pool.swapAt(i, i + offset)
        var next = pool.makeIterator()
        accounts = accounts.map { $0.provider == account.provider ? next.next()! : $0 }
    }

    // MARK: Files

    static func load(from url: URL = LastDropPaths.accountsConfig, legacy: URL = LastDropPaths.accounts) -> AccountsConfig {
        if let data = try? Data(contentsOf: url), let config = try? JSONDecoder.lastdrop.decode(AccountsConfig.self, from: data) {
            return config
        }
        guard let data = try? Data(contentsOf: legacy),
              let old = try? JSONDecoder.lastdrop.decode(ClaudeAccountsConfig.self, from: data) else { return AccountsConfig() }
        return AccountsConfig(migrating: old)
    }

    func save(to url: URL = LastDropPaths.accountsConfig) throws {
        LastDropPaths.ensure(url.deletingLastPathComponent())
        try JSONEncoder.lastdrop.encode(self).write(to: url, options: .atomic)
    }

    /// The Claude account list from before there were pools (`claude-accounts.json`), which stays on disk
    /// untouched: same accounts, order and thresholds, and every other provider's main account.
    init(migrating old: ClaudeAccountsConfig) {
        self.init()
        replaceClaudePool(with: old)
    }
}
