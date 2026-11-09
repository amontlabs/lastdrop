import Foundation

/// `lastdrop --agents`: changes lastdrop's list of agents from the command line, with the checks Settings makes.
/// The agent listing points here, so a coding agent can read `--help` when it needs to and pay nothing otherwise.
enum AgentsCommand {
    static let help = """
    Changes the agents lastdrop adds to Claude Code's Agent tool. Use it only when the user asks for a change.
    Changes apply from the next prompt.

    lastdrop --agents list                  Every agent, as JSON set takes
    lastdrop --agents models <provider>     The provider's model ids and efforts
    lastdrop --agents set                   Add an agent, or replace the one with its name, from JSON on stdin
    lastdrop --agents remove <name>         Remove an agent
    lastdrop --agents saving on|off         Save Claude usage: ask Claude to delegate to these agents first
    lastdrop --agents judge <provider> <model> [effort]
                                            The model that checks the provider's agents' commands
    lastdrop --agents judge <provider> default
                                            Back to the default judge

    Providers: \(AgentProvider.allCases.map(\.rawValue).joined(separator: ", "))

    Judges: zai (default glm-5.3), openrouter (default: each agent's own model), antigravity (default
    gemini-3.8-flash low; the only one that takes an effort). A weak judge lets risky commands through.
    A judge the provider doesn't serve isn't replaced: the agents' checked commands fail with that reason.

    set reads this, with models in the order they're tried (effort and enabled are optional):
    {
      "name": "sol",
      "description": "Reviews: what Claude reads to choose this agent.",
      "models": [{ "provider": "codex", "model": "gpt-6.1-sol", "effort": "high" }],
      "enabled": true
    }

    Prints JSON and exits 0, or prints the reason to stderr and exits 1.
    A provider that can't list its models leaves a warning in the answer: its ids weren't checked.
    Sign-ins and API keys are in lastdrop's Settings only.
    """

    /// An agent as `list` prints it and `set` reads it.
    struct Entry: Codable {
        var name: String
        var description: String
        var models: [AgentFallback]
        /// Missing keeps what a replaced agent had; a new one starts enabled.
        var enabled: Bool?
    }

    private struct Listing: Encodable {
        var agents: [Entry]
        var saveClaude: Bool
        var judges: [String: Judge]
    }

    /// A provider's command judge as `list` and `judge` print it. No model means each agent's own model.
    private struct Judge: Encodable {
        var model: String?
        var effort: String?
        var isDefault: Bool

        private enum CodingKeys: String, CodingKey { case model, effort, isDefault = "default" }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(model ?? "the agent's own model", forKey: .model)
            try c.encodeIfPresent(effort, forKey: .effort)
            try c.encode(isDefault, forKey: .isDefault)
        }
    }

    private struct JudgeSaved: Encodable {
        var provider: String
        var judge: Judge
        var warnings: [String]
    }

    private struct Saved: Encodable {
        var saved: Entry
        var warnings: [String]
    }

    private struct Removed: Encodable { var removed: String }
    private struct Saving: Encodable { var saveClaude: Bool }

    struct Failure: LocalizedError {
        var errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    static func main() -> Never {
        let args = CommandLine.arguments
        let verb = args.firstIndex(of: "--agents").map { Array(args[($0 + 1)...]) } ?? []
        Task {
            do {
                print(try await run(verb))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(1)
            }
        }
        dispatchMain()
    }

    /// What a command prints; a failure's reason is the error's.
    static func run(_ args: [String],
                    stdin: () -> Data = { FileHandle.standardInput.readDataToEndOfFile() },
                    models: (AgentProvider) async throws -> [AgentModel] = { try await $0.backend.models() },
                    url: URL = LastDropPaths.agentCatalog) async throws -> String {
        switch (args.first, args.count) {
        case (nil, _), ("--help", _), ("-h", _), ("help", _):
            return help
        case ("list", 1):
            let catalog = AgentCatalog.load(from: url)
            return try text(Listing(agents: catalog.agents.map(entry), saveClaude: catalog.saveClaude, judges: judges(catalog)))
        case ("models", 2):
            return try text(try await models(provider(args[1])))
        case ("set", 1):
            return try await set(stdin(), models: models, url: url)
        case ("remove", 2):
            try change(url) { catalog in
                guard let i = catalog.agents.firstIndex(where: { $0.name == args[1] }) else { throw Failure("No agent named \(args[1]).") }
                catalog.agents.remove(at: i)
            }
            return try text(Removed(removed: args[1]))
        case ("saving", 2) where ["on", "off"].contains(args[1]):
            try change(url) { $0.saveClaude = args[1] == "on" }
            return try text(Saving(saveClaude: args[1] == "on"))
        case ("judge", 3), ("judge", 4):
            return try await judge(provider(args[1]), args[2], effort: args.count == 4 ? args[3] : nil, models: models, url: url)
        default:
            throw Failure("Unknown command: \(args.joined(separator: " ")). See --agents --help.")
        }
    }

    private static func judges(_ catalog: AgentCatalog) -> [String: Judge] {
        Dictionary(uniqueKeysWithValues: AgentProvider.judged.map { provider in
            let judge = catalog.judge(provider)
            return (provider.rawValue, Judge(model: judge?.model, effort: judge?.effort, isDefault: catalog.judges[provider] == nil))
        })
    }

    /// Sets or resets a provider's judge, checked against the provider's live list as `set` checks models.
    private static func judge(_ provider: AgentProvider, _ model: String, effort: String?,
                              models: (AgentProvider) async throws -> [AgentModel], url: URL) async throws -> String {
        guard AgentProvider.judged.contains(provider) else {
            throw Failure(AgentCatalog.problem(judge: AgentJudge(model: model), for: provider) ?? "No judge for \(provider.displayName).")
        }
        var warnings: [String] = []
        let chosen: AgentJudge?
        if model == "default" {
            guard effort == nil else { throw Failure("judge \(provider.rawValue) default takes no effort.") }
            chosen = nil
        } else {
            let judge = AgentJudge(model: model, effort: effort)
            if let problem = AgentCatalog.problem(judge: judge, for: provider) { throw Failure(problem) }
            warnings = try await check([AgentFallback(provider: provider, model: model, effort: effort)], models: models)
            chosen = judge
        }
        var saved = AgentCatalog()
        try change(url) { catalog in
            catalog.judges[provider] = chosen
            saved = catalog
        }
        let judge = saved.judge(provider)
        return try text(JudgeSaved(provider: provider.rawValue,
                                   judge: Judge(model: judge?.model, effort: judge?.effort, isDefault: chosen == nil), warnings: warnings))
    }

    private static func set(_ data: Data, models: (AgentProvider) async throws -> [AgentModel], url: URL) async throws -> String {
        let new: Entry
        do { new = try JSONDecoder().decode(Entry.self, from: data) } catch { throw Failure("Couldn't read the agent: \(reason(error)) See --agents --help.") }
        guard !new.models.isEmpty else { throw Failure("Give the agent at least one model.") }
        // Before the lock: a provider can take seconds to answer.
        let warnings = try await check(new.models, models: models)
        var saved = new
        try change(url) { catalog in
            var agent = catalog.agents.first { $0.name == new.name }
                ?? AgentDefinition(name: new.name, description: new.description, provider: new.models[0].provider, model: new.models[0].model)
            agent.description = new.description
            agent.chain = new.models
            agent.enabled = new.enabled ?? agent.enabled
            if let problem = catalog.problem(with: agent) { throw Failure(problem) }
            if let i = catalog.agents.firstIndex(where: { $0.id == agent.id }) { catalog.agents[i] = agent } else { catalog.agents.append(agent) }
            saved = entry(agent)
        }
        return try text(Saved(saved: saved, warnings: warnings))
    }

    /// Refuses a model or effort the provider doesn't offer. As in Settings, a provider that lists nothing can't
    /// say no, so its ids are taken as they are: a list that failed comes back as a warning.
    private static func check(_ entries: [AgentFallback], models: (AgentProvider) async throws -> [AgentModel]) async throws -> [String] {
        var warnings: [String] = []
        for provider in AgentProvider.allCases where entries.contains(where: { $0.provider == provider }) {
            let offered: [AgentModel]
            do {
                offered = try await models(provider)
            } catch {
                warnings.append("Couldn't list \(provider.displayName)'s models (\(error.localizedDescription)), so its ids weren't checked.")
                continue
            }
            if offered.isEmpty { continue }
            for wanted in entries where wanted.provider == provider {
                guard let model = offered.first(where: { $0.id == wanted.model }) else {
                    throw Failure("\(provider.displayName) doesn't offer \(wanted.model). Run --agents models \(provider.rawValue).")
                }
                if let effort = wanted.effort, !model.efforts.contains(effort) {
                    let takes = model.efforts.isEmpty ? "takes no effort" : "takes \(model.efforts.joined(separator: ", "))"
                    throw Failure("\(model.id) \(takes); received \(effort).")
                }
            }
        }
        return warnings
    }

    private static func change(_ url: URL, _ edit: (inout AgentCatalog) throws -> Void) throws {
        try AgentCatalog.update(at: url, edit)
        announce()
    }

    /// Open Settings pages are in another process.
    static func announce() {
        DistributedNotificationCenter.default().postNotificationName(.agentCatalogChanged, object: nil, userInfo: nil, deliverImmediately: true)
    }

    private static func provider(_ name: String) throws -> AgentProvider {
        guard let provider = AgentProvider(rawValue: name) else {
            throw Failure("No provider named \(name). Use \(AgentProvider.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return provider
    }

    private static func entry(_ agent: AgentDefinition) -> Entry {
        Entry(name: agent.name, description: agent.description, models: agent.chain, enabled: agent.enabled)
    }

    private static func text<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func reason(_ error: Error) -> String {
        switch error as? DecodingError {
        case .keyNotFound(let key, _): "\(key.stringValue) is missing."
        case .dataCorrupted(let context), .typeMismatch(_, let context), .valueNotFound(_, let context): context.debugDescription
        default: error.localizedDescription
        }
    }
}
