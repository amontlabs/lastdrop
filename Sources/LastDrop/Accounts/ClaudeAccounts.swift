import Foundation

/// Where lastdrop keeps its own files.
enum LastDropPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("lastdrop", isDirectory: true)
    }()
    /// Every provider's accounts (`AccountsConfig`).
    static let accountsConfig = support.appendingPathComponent("accounts.json")
    /// The Claude account list from before `accounts.json`; read once to migrate, never written.
    static let accounts = support.appendingPathComponent("claude-accounts.json")
    static let agents = support.appendingPathComponent("subagents.json")
    static let agentsLock = support.appendingPathComponent("subagents.lock")
    static let agentsDir = support.appendingPathComponent("agents", isDirectory: true)
    /// lastdrop's list of extra models for the Agent tool (Settings → Agents).
    static let agentCatalog = support.appendingPathComponent("agent-catalog.json")
    /// Each account's latest usage, written by the app as it refreshes, read by the subagent runner.
    static let usage = support.appendingPathComponent("usage.json")
    /// Held around every read-modify-write of `usage.json`, by the app and by runners alike.
    static let usageLock = support.appendingPathComponent("usage.lock")
    /// Touched by the app on every tick: runners read usage themselves only when it's old (the app isn't running).
    static let appHeartbeat = support.appendingPathComponent("app.heartbeat")
    /// The Claude Code version the subagent self-test last passed on.
    static let selfTest = support.appendingPathComponent("selftest.json")
    static let selfTestLock = support.appendingPathComponent("selftest.lock")
    /// An empty folder that helper CLIs (sign-in, model lists) start in. Starting them in the home folder made macOS ask
    /// for access to Music, Documents and volumes on lastdrop's behalf whenever they looked around where they started.
    static var helperDirectory: String {
        let url = support.appendingPathComponent("helper", isDirectory: true)
        ensure(url)
        return url.path
    }

    /// Creates `dir` readable by the user only.
    static func ensure(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }
}

/// One Claude account: a Claude Code sign-in of its own. Main is the default one (`~/.claude`); every other
/// account lives in `~/.claude-accounts/<name>` (`CLAUDE_CONFIG_DIR`). lastdrop shows each account's
/// limits and runs subagents on the accounts that have room (`lastdrop --mcp`).
struct ClaudeAccount: Codable, Hashable, Sendable, Identifiable {
    static let mainID = "main"

    /// "main", or a short name also used as the folder name ("Pro").
    var id: String
    var addedAt = Date()

    var isMain: Bool { id == Self.mainID }

    /// `CLAUDE_CONFIG_DIR` for this account (where its sign-in lives); nil for Main (the default `~/.claude`).
    var cliConfigDir: String? { Account(provider: .claude, key: id).folder }

    init(id: String) { self.id = id }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
    }

    static func slug(_ name: String) -> String { Account.slug(name) }
}

/// The Claude pool of `AccountsConfig`, as the subagent runner and the Claude settings use it. Its Codable
/// shape is the old `claude-accounts.json`, kept for migrating it.
struct ClaudeAccountsConfig: Codable, Equatable, Sendable {
    /// Accounts besides Main.
    var accounts: [ClaudeAccount] = []
    /// Priority order of account IDs; always contains "main" exactly once.
    var order: [String] = [ClaudeAccount.mainID]
    /// An account takes subagents while its Session and its Weekly use are below these (0...1).
    var sessionThreshold = ClaudeAccountsConfig.defaultThreshold
    var weeklyThreshold = ClaudeAccountsConfig.defaultThreshold
    static let defaultThreshold = 0.9

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try c.decodeIfPresent([ClaudeAccount].self, forKey: .accounts) ?? []
        order = try c.decodeIfPresent([String].self, forKey: .order) ?? [ClaudeAccount.mainID]
        sessionThreshold = try c.decodeIfPresent(Double.self, forKey: .sessionThreshold) ?? Self.defaultThreshold
        weeklyThreshold = try c.decodeIfPresent(Double.self, forKey: .weeklyThreshold) ?? Self.defaultThreshold
    }

    /// Every account, Main included, in priority order.
    var ordered: [ClaudeAccount] {
        order.compactMap { id in id == ClaudeAccount.mainID ? ClaudeAccount(id: id) : accounts.first { $0.id == id } }
    }

    /// Keeps `order` consistent with `accounts`: drops unknown IDs, appends missing ones, one "main".
    mutating func normalize() {
        var seen = Set<String>()
        order = order.filter { id in
            guard !seen.contains(id), id == ClaudeAccount.mainID || accounts.contains(where: { $0.id == id }) else { return false }
            seen.insert(id)
            return true
        }
        if !seen.contains(ClaudeAccount.mainID) { order.insert(ClaudeAccount.mainID, at: 0) }
        for a in accounts where !seen.contains(a.id) { order.append(a.id) }
    }

    /// The Claude pool and the thresholds of `all`.
    init(_ all: AccountsConfig) {
        let pool = all.pool(.claude)
        accounts = pool.filter { !$0.isMain }.map { account in
            var claude = ClaudeAccount(id: account.key)
            claude.addedAt = account.addedAt
            return claude
        }
        order = pool.map(\.key)
        sessionThreshold = all.sessionThreshold
        weeklyThreshold = all.weeklyThreshold
        normalize()
    }

    static func load() -> ClaudeAccountsConfig { ClaudeAccountsConfig(AccountsConfig.load()) }

    /// Puts this Claude pool and these thresholds into the saved `AccountsConfig`, leaving other providers alone.
    func save() throws {
        var all = AccountsConfig.load()
        all.replaceClaudePool(with: self)
        try all.save()
    }
}

extension AccountsConfig {
    /// The Claude pool becomes `claude`'s accounts and order, where the Claude pool was.
    mutating func replaceClaudePool(with claude: ClaudeAccountsConfig) {
        var claude = claude
        claude.normalize()
        let at = accounts.firstIndex { $0.provider == .claude } ?? 0
        // Keep what the list doesn't carry (name, menu bar, notifications) for the accounts that stay.
        let pool = claude.ordered.map { claudeAccount in
            accounts.first { $0.provider == .claude && $0.key == claudeAccount.id }
                ?? Account(provider: .claude, key: claudeAccount.id, addedAt: claudeAccount.isMain ? .distantPast : claudeAccount.addedAt)
        }
        accounts.removeAll { $0.provider == .claude }
        accounts.insert(contentsOf: pool, at: min(at, accounts.count))
        sessionThreshold = claude.sessionThreshold
        weeklyThreshold = claude.weeklyThreshold
        normalize()
    }
}

extension JSONEncoder {
    static let lastdrop: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

extension JSONDecoder {
    static let lastdrop: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}

extension ClaudeAccount {
    /// The environment to run claude on this account. Main runs as it is: `~/.claude` and the default sign-in.
    /// Another account is signed in through `CLAUDE_SECURESTORAGE_CONFIG_DIR` (its folder holds the sign-in) and
    /// runs in its profile (`CLAUDE_CONFIG_DIR`): `~/.claude` through links, so settings, plugins and
    /// conversations are Main's, with a `.claude.json` of its own (`ClaudeProfile`). Building the environment
    /// brings that profile up to date.
    func runEnvironment(from base: [String: String]) -> [String: String] {
        var env = base
        env.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        env.removeValue(forKey: "CLAUDE_SECURESTORAGE_CONFIG_DIR")
        if let dir = cliConfigDir {
            env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = dir
            env["CLAUDE_CONFIG_DIR"] = ClaudeProfile.prepare(folder: dir)
        }
        return env
    }
}
