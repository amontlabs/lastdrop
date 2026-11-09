import Foundation

/// A model a provider offers, as the Agents list's picker shows it.
struct AgentModel: Hashable, Sendable, Identifiable, Encodable {
    var id: String
    var name: String
    /// The reasoning efforts it takes, lowest first; empty when it takes none.
    var efforts: [String]
    var defaultEffort: String?
}

/// One run of an agent from lastdrop's list, as its backend gets it.
struct AgentJob: Sendable {
    var agentID: String
    var definition: AgentDefinition
    var prompt: String
    var cwd: String
    /// The call's effort, else the definition's; nil leaves it to the provider.
    var effort: String?
    /// The session's permission mode as Claude Code names it (`default`, `acceptEdits`, `plan`, `auto`,
    /// `bypassPermissions`); each backend maps it to its provider's own.
    var permissionMode: String
    /// `isolation: "worktree"`: run in a git worktree of its own.
    var worktree: Bool
    /// A `--mcp-config` file with the caller's MCP servers (`{"mcpServers": {...}}`), when it has any.
    var mcpConfig: String?
    /// A follow-up (SendMessage): the run it continues, as the registry remembers it.
    var resume: AgentRegistry.Entry?
    /// `Explore` or `Plan`: the agent may not change files, whatever the permission mode says.
    var role: String?

    /// The agent's role from the list, plus the brief of the read-only role it was called as.
    var instructions: String { definition.instructions(role: role) }
}

/// What a backend reports while it runs; the runner turns it into the plugin's lines and the agent's log.
struct AgentEvents: Sendable {
    /// The process running the agent, which TaskStop ends (SIGTERM, then SIGKILL after 5 s).
    var process: @Sendable (Int32) -> Void
    /// The provider took the agent: where it runs as its row shows it ("Codex", "Pro") and on what model.
    /// Called once; a run that ends before it is an error the Agent call answers with.
    var started: @Sendable (_ place: String, _ model: String) -> Void
    /// A step as its row shows it ("Bash: Run the tests").
    var step: @Sendable (String) -> Void
    /// A transcript entry: `["kind": "text", "text"]`, `["kind": "tool", "id", "summary", "input"]` or
    /// `["kind": "result", "id", "text", "isError"]`, long texts cut as `SubagentRunner.transcriptItem` cuts them.
    var item: @Sendable ([String: Any]) -> Void
    /// A line for the agent's log only, such as why a command was allowed or refused.
    var note: @Sendable (String) -> Void = { _ in }
}

/// Runs agents on one provider.
protocol AgentBackend {
    /// What the picker offers.
    static func models() async throws -> [AgentModel]
    /// Runs the job to its answer. `sessionID` and `directory` in the result are what a follow-up and Open in
    /// Terminal continue; `account` is where it ran.
    static func run(_ job: AgentJob, _ events: AgentEvents) async -> SubagentRunner.Result
    /// The zsh lines Open in Terminal runs to continue the agent's own session interactively.
    static func terminal(_ entry: AgentRegistry.Entry) -> String?
}

extension AgentProvider {
    var backend: any AgentBackend.Type {
        switch self {
        case .claude: ClaudeBackend.self
        case .codex: CodexBackend.self
        case .zai: ZAIBackend.self
        case .openrouter: OpenRouterBackend.self
        case .antigravity: AntigravityBackend.self
        }
    }
}

/// A provider lastdrop can't run agents on yet: every run is an error saying so.
enum UnavailableBackend: AgentBackend {
    static func models() async throws -> [AgentModel] { [] }

    static func run(_ job: AgentJob, _ events: AgentEvents) async -> SubagentRunner.Result {
        .init(text: "lastdrop can't run \(job.definition.provider.displayName) agents yet.", isError: true, limitReached: false,
              turns: 0, permissionDenials: 0)
    }

    static func terminal(_ entry: AgentRegistry.Entry) -> String? { nil }
}

/// Agents on your other Claude accounts: plain Claude Code, on the account with the most room, with the
/// definition's model and effort and its role added to the system prompt.
enum ClaudeBackend: AgentBackend {
    static let efforts = ["low", "medium", "high", "xhigh", "max"]

    static func models() async throws -> [AgentModel] {
        [("fable", "Fable"), ("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")].map {
            AgentModel(id: $0.0, name: $0.1, efforts: efforts, defaultEffort: nil)
        }
    }

    static func run(_ job: AgentJob, _ events: AgentEvents) async -> SubagentRunner.Result {
        // Claude Code ignores a level it doesn't know with a warning; the call should fail instead.
        if let effort = job.effort, !efforts.contains(effort) {
            return .init(text: "Claude agents take \(efforts.joined(separator: ", ")) effort; received \(effort).", isError: true,
                         limitReached: false, turns: 0, permissionDenials: 0, unavailable: true)
        }
        let config = ClaudeAccountsConfig.load()
        let permissionMode = AgentRun.mappedPermissionMode(job.permissionMode)
        let onProcess = events.process
        if let entry = job.resume {
            guard let account = config.ordered.first(where: { $0.id == entry.account }) else {
                return .init(text: "The \(entry.account) account is no longer in lastdrop.", isError: true, limitReached: false,
                             turns: 0, permissionDenials: 0)
            }
            _ = SessionTransfer.transcriptInMain(entry.sessionID, from: account)   // an old run's session moves to ~/.claude
            AgentRegistry.setRunning(account.id)
            let req = SubagentRunner.Request(prompt: job.prompt, model: entry.model, effort: entry.effort, permissionMode: permissionMode,
                                             sessionID: entry.sessionID, resume: true, mcpConfig: job.mcpConfig,
                                             systemPrompt: job.instructions, disallowedTools: job.role == nil ? [] : SubagentRunner.editingTools)
            var result = await SubagentRunner.run(req, on: account, in: entry.directory, onProcess: onProcess, check: check(account, entry.model, events),
                                                  onStep: events.step, onItem: events.item)
            if result.limitReached { await SubagentUsage.shared.markFull(account) }
            result.account = account.id
            return result
        }

        let own = SubagentAccounts.ownAccountUUID()
        var tried = Set<String>()
        var last: SubagentRunner.Result?
        let model = job.definition.model
        while let account = await AgentRun.pick(config.ordered, config: config, own: own, excluding: tried) {
            AgentRegistry.setRunning(account.id)
            let req = SubagentRunner.Request(prompt: job.prompt, model: model, effort: job.effort, worktree: job.worktree,
                                             permissionMode: permissionMode, sessionID: UUID().uuidString.lowercased(),
                                             mcpConfig: job.mcpConfig, systemPrompt: job.instructions,
                                             disallowedTools: job.role == nil ? [] : SubagentRunner.editingTools)
            var result = await SubagentRunner.run(req, on: account, in: job.cwd, onProcess: onProcess,
                                                  check: check(account, model, events),
                                                  onStep: events.step, onItem: events.item)
            result.account = account.id
            if result.sessionID == nil { result.sessionID = req.sessionID }
            if result.limitReached { await SubagentUsage.shared.markFull(account) }
            // Refused before doing anything: another account can take the task whole.
            if result.limitReached && result.toolUses == 0 && !AgentRegistry.wasStopped(job.agentID) {
                tried.insert(account.id)
                events.step("Moved off \(account.id): it is at its usage limit")
                last = result
                continue
            }
            // The plan doesn't include the model: another account may. It is never swapped for another model.
            if result.modelUnavailable && result.toolUses == 0 && !AgentRegistry.wasStopped(job.agentID) {
                tried.insert(account.id)
                events.step("Moved off \(account.id): its plan doesn't include \(model)")
                last = result
                continue
            }
            return result
        }
        var none = last ?? .init(text: "", isError: true, limitReached: true, turns: 0, permissionDenials: 0)
        none.unavailable = true
        none.text = none.modelUnavailable ? AgentRun.modelRefusal(model, none.text)
            : "No other Claude account has room for \(job.definition.name) right now."
        return none
    }

    /// Claude Code's init passed: the agent started on `account`.
    private static func check(_ account: ClaudeAccount, _ model: String?, _ events: AgentEvents) -> @Sendable ([String: Any]) -> String? {
        { event in
            if let reason = SubagentRunner.checkInit(event, subagentType: nil) { return "\(reason) on the \(account.id) account" }
            events.started(account.id, model ?? event.string("model") ?? "")
            return nil
        }
    }

    static func terminal(_ entry: AgentRegistry.Entry) -> String? {
        let account = ClaudeAccount(id: entry.account)
        let export = account.cliConfigDir.map { "unset CLAUDE_CONFIG_DIR\nexport CLAUDE_SECURESTORAGE_CONFIG_DIR=\(ClaudeSignIn.shellQuote($0))\n" } ?? ""
        return "\(export)cd \(ClaudeSignIn.shellQuote(entry.directory)) || exit 1\nexec claude --resume \(entry.sessionID)"
    }
}
