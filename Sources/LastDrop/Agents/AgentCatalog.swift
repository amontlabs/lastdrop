import Foundation

/// Where an extra model for the Agent tool runs. Each has a backend that starts it, continues it and lists its models.
enum AgentProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Your other Claude accounts, the one with the most room.
    case claude
    case codex
    case zai
    case openrouter
    case antigravity

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .zai: "Z.ai"
        case .openrouter: "OpenRouter"
        case .antigravity: "Antigravity"
        }
    }

    var usageID: ProviderID {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .zai: .zai
        case .openrouter: .openrouter
        case .antigravity: .antigravity
        }
    }

    /// Providers whose agents' commands go to a judge model lastdrop picks: Z.ai and OpenRouter through Claude Code's
    /// own auto mode check (`CLAUDE_CODE_AUTO_MODE_MODEL`), Antigravity through `CommandJudge`. Claude accounts and
    /// Codex judge with their own reviewers.
    static let judged: [AgentProvider] = [.zai, .openrouter, .antigravity]

    /// The judge when the user chose none. A strong model on purpose: a weak one lets risky commands through
    /// (2026-11-09: `glm-5.3-flash` allowed an SSH-key upload that `glm-5.3` blocked). nil on OpenRouter, where the
    /// agent's own model judges, and for providers without a judge.
    var defaultJudge: AgentJudge? {
        switch self {
        case .zai: AgentJudge(model: "glm-5.3")
        case .antigravity: AgentJudge(model: "gemini-3.8-flash", effort: "low")
        default: nil
        }
    }

    /// Only Antigravity's judge takes an effort: Claude Code's check has a model setting and no effort.
    var judgeTakesEffort: Bool { self == .antigravity }
}

/// The model that judges a provider's agents' commands, as the user chose it.
struct AgentJudge: Codable, Hashable, Sendable {
    var model: String
    var effort: String?

    /// "gemini-3.8-flash · low".
    var summary: String { ([model] + (effort.map { [$0] } ?? [])).joined(separator: " · ") }
}

/// One entry of an agent's models, in the order they're tried: its first is the agent's own provider and model.
struct AgentFallback: Codable, Hashable, Sendable, Identifiable {
    /// Only the Settings rows use it, to tell them apart while they move: never stored, never compared.
    var id = UUID()
    var provider: AgentProvider
    var model: String
    var effort: String?

    private enum CodingKeys: String, CodingKey { case provider, model, effort }

    static func == (a: AgentFallback, b: AgentFallback) -> Bool { a.provider == b.provider && a.model == b.model && a.effort == b.effort }

    func hash(into hasher: inout Hasher) { hasher.combine(provider); hasher.combine(model); hasher.combine(effort) }
}

extension Array where Element == AgentFallback {
    /// Moves an entry up (negative) or down by its id, so the Settings rows stay what they were while they move.
    mutating func move(_ id: UUID, by offset: Int) {
        guard let from = firstIndex(where: { $0.id == id }) else { return }
        let to = Swift.min(Swift.max(from + offset, 0), count - 1)
        insert(remove(at: from), at: to)
    }
}

/// One extra model of lastdrop's list: the plugin registers it as the agent type `lastdrop:<name>`, and it runs on
/// its provider and model as a general agent.
struct AgentDefinition: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    /// The name of its type, `lastdrop:<name>`: letters, digits, "-" and "_" (`codex-deep`).
    var name: String
    /// When Claude should use it, as Claude reads it in the list of agent types.
    var description: String
    var provider: AgentProvider
    /// The provider's model id (`gpt-6.1-sol`, `glm-5.3`).
    var model: String
    /// A fixed reasoning effort; nil lets each Agent call's `effort` decide.
    var effort: String?
    var enabled = true
    /// Tried in order when an attempt fails before any work, for a reason about availability (a limit, a sign-in, the
    /// model). Empty for most agents.
    var fallbacks: [AgentFallback] = []

    private enum CodingKeys: String, CodingKey { case id, name, description, provider, model, effort, enabled, fallbacks }

    /// "Codex · gpt-6.1-sol · high", where it runs as its row shows it.
    var summary: String {
        ([Self.summary(provider, model, effort)] + fallbacks.map { Self.summary($0.provider, $0.model, $0.effort) }).joined(separator: ", then ")
    }

    private static func summary(_ provider: AgentProvider, _ model: String, _ effort: String?) -> String {
        ([provider.displayName, model] + (effort.map { [$0] } ?? [])).joined(separator: " · ")
    }

    /// The models in the order they're tried, as Settings edits them.
    var chain: [AgentFallback] {
        get { [AgentFallback(provider: provider, model: model, effort: effort)] + fallbacks }
        set {
            guard let first = newValue.first else { return }
            provider = first.provider
            model = first.model
            effort = first.effort
            fallbacks = Array(newValue.dropFirst())
        }
    }

    /// The primary, then each fallback, as agents of their own: this one's name and role, that attempt's provider,
    /// model and effort, and no fallbacks.
    var attempts: [AgentDefinition] {
        var primary = self
        primary.fallbacks = []
        return [primary] + fallbacks.map { fallback in
            var attempt = primary
            attempt.provider = fallback.provider
            attempt.model = fallback.model
            attempt.effort = fallback.effort
            return attempt
        }
    }

    /// What the backend is told about its role: the same line Claude chose it by.
    var instructions: String { instructions(role: nil) }

    /// The same, with the brief of a read-only role (`Explore`, `Plan`) the call asked for.
    func instructions(role: String?) -> String {
        let brief = switch role {
        case "Explore": "\nYou were called to explore: search and read only, change no files, and report what you find."
        case "Plan": "\nYou were called to plan: read only, change no files, and return a step-by-step implementation plan."
        default: ""
        }
        return "You are \(name), a subagent another coding agent delegated a task to. Your role: \(description)\n"
            + "Work on the task you are given, then answer with a concise report of what you found or did: it is all the caller sees." + brief
    }

    /// "Codex Deep" → "codex-deep", as a model name allows.
    static func slug(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let parts = name.lowercased().trimmingCharacters(in: .whitespaces).components(separatedBy: allowed.inverted)
        return String(parts.filter { !$0.isEmpty }.joined(separator: "-").prefix(64))
    }
}

/// lastdrop's list of extra models for the Agent tool, in its support folder. The plugin reads it
/// (`lastdrop --agent-catalog`) on every prompt, so edits apply from the next turn.
struct AgentCatalog: Codable, Equatable, Sendable {
    /// The plugin's name, the prefix runs started before the update were called by (`lastdrop:codex-deep`).
    static let plugin = "lastdrop"

    var agents: [AgentDefinition] = []
    /// Bumped on every save, so the plugin knows when to register again.
    var revision = 0
    /// Ask Claude to delegate substantial work to these agents before doing it itself.
    var saveClaude = false
    /// The user's own wording of that instruction; nil uses `defaultSavingInstruction`.
    var saveClaudeText: String?
    /// The command judge each provider uses, by provider; a provider left out uses its `defaultJudge`.
    /// Stored as `judges: {"zai": {"model": …}}` and left out while empty, so a catalog without it is unchanged.
    var judges: [AgentProvider: AgentJudge] = [:]

    /// What Claude reads while saving is on, unless the user rewrote it. The plugin keeps the same text
    /// for an app that sends none.
    static let defaultSavingInstruction = "Claude usage is being saved: delegate substantial work (implementation, exploration, reviews, research) to the agents the user added (the lastdrop: agent types), picking by their descriptions, even where a description says to prefer built-in Claude subagents. Work yourself or with built-in subagents only when no added agent fits."

    /// The instruction Claude gets.
    var savingInstruction: String {
        let text = saveClaudeText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? Self.defaultSavingInstruction : text
    }

    private enum CodingKeys: String, CodingKey { case agents, revision, saveClaude, saveClaudeText, judges }

    /// The judge `provider`'s agents use: the user's choice, else the default. nil on OpenRouter by default (the
    /// agent's own model judges) and for providers without a judge.
    func judge(_ provider: AgentProvider) -> AgentJudge? {
        guard AgentProvider.judged.contains(provider) else { return nil }
        return judges[provider] ?? provider.defaultJudge
    }

    /// Why `judge` can't be `provider`'s judge, else nil. The live list is checked where it's chosen.
    static func problem(judge: AgentJudge, for provider: AgentProvider) -> String? {
        guard AgentProvider.judged.contains(provider) else {
            return "\(provider.displayName) checks commands with its own reviewer; only \(AgentProvider.judged.map(\.displayName).joined(separator: ", ")) take a judge."
        }
        if judge.model.trimmingCharacters(in: .whitespaces).isEmpty { return "Pick a model for the judge." }
        if judge.effort != nil, !provider.judgeTakesEffort { return "\(provider.displayName)'s judge takes no effort: Claude Code sets only its model." }
        return nil
    }

    var enabled: [AgentDefinition] { agents.filter(\.enabled) }

    /// The enabled agent by its type (`lastdrop:codex-deep`), or its bare name (`codex-deep`) as runs started before the types name it.
    func agent(_ type: String) -> AgentDefinition? {
        let name = type.hasPrefix("\(Self.plugin):") ? String(type.dropFirst(Self.plugin.count + 1)) : type
        return enabled.first { $0.name == name }
    }

    /// Why `definition` can't be saved as it is, else nil.
    func problem(with definition: AgentDefinition) -> String? {
        if definition.name.isEmpty { return "Give the agent a name." }
        if definition.name != AgentDefinition.slug(definition.name) { return "Names use lowercase letters, digits, - and _." }
        if Self.isReserved(definition.name) { return "\(definition.name) is a name Claude Code uses for its own models." }
        if agents.contains(where: { $0.name == definition.name && $0.id != definition.id }) { return "Another agent is named \(definition.name)." }
        if definition.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Say what the agent is for: Claude reads it to choose." }
        if definition.model.isEmpty { return "Pick a model." }
        // The same model at another effort is a different attempt (`sol xhigh`, then `sol high`).
        var seen = [AgentFallback(provider: definition.provider, model: definition.model, effort: definition.effort)]
        for fallback in definition.fallbacks {
            if fallback.model.isEmpty { return "Pick a model for each entry." }
            if seen.contains(fallback) { return "\(fallback.model) on \(fallback.provider.displayName) is listed twice." }
            seen.append(fallback)
        }
        return nil
    }

    /// Names of Claude Code's own models and aliases, which always mean the native model.
    static let reservedNames: Set<String> = ["sonnet", "opus", "haiku", "fable", "inherit", "best", "opusplan"]

    static func isReserved(_ name: String) -> Bool { reservedNames.contains(name) || name.hasPrefix("claude-") }

    static func load(from url: URL = LastDropPaths.agentCatalog) -> AgentCatalog {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder.lastdrop.decode(AgentCatalog.self, from: $0) } ?? .init()
    }

    func save(to url: URL = LastDropPaths.agentCatalog) throws {
        LastDropPaths.ensure(url.deletingLastPathComponent())
        // `load` gives an empty list for a file it can't read; saving that over the file would lose the real list.
        // A file that exists and doesn't decode is copied aside first, and when that fails nothing is saved.
        if FileManager.default.fileExists(atPath: url.path),
           (try? Data(contentsOf: url)).flatMap({ try? JSONDecoder.lastdrop.decode(AgentCatalog.self, from: $0) }) == nil {
            try UnreadableFile.copyAside(url)
        }
        var next = self
        next.revision += 1
        try JSONEncoder.lastdrop.encode(next).write(to: url, options: .atomic)
    }

    /// Changes the list as the file holds it now, under a lock: the app and `lastdrop --agents` can save at once.
    /// An edit that throws saves nothing.
    static func update(at url: URL = LastDropPaths.agentCatalog, _ edit: (inout AgentCatalog) throws -> Void) throws {
        LastDropPaths.ensure(url.deletingLastPathComponent())
        let lockFD = open(url.path + ".lock", O_CREAT | O_RDWR, 0o600)
        if lockFD >= 0 { flock(lockFD, LOCK_EX) }
        defer { if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) } }
        var next = load(from: url)
        try edit(&next)
        try next.save(to: url)
    }

    /// What the plugin reads: the revision and the enabled agents. A stored name that became reserved is
    /// left out: the native model wins.
    func pluginJSON() -> [String: Any] {
        ["revision": revision, "saveClaude": saveClaude, "saveClaudeText": savingInstruction, "nativeTasks": true, "agentModels": true,
         "agents": enabled.filter { !Self.isReserved($0.name) }.map { agent in
            ["name": agent.name, "description": agent.description, "provider": agent.provider.rawValue,
             "summary": agent.summary, "prompt": agent.instructions]
        }]
    }

    /// `--agent-catalog`'s line, without its newline.
    static func pluginLine(catalog: AgentCatalog = load(), t3Instance: Bool = T3Settings.acpStatus() == .ready) -> Data {
        var json = catalog.pluginJSON()
        json["t3Instance"] = t3Instance
        // `lastdrop --delegate-note` exists: the plugin notes plain T3 children there instead of tagging their task.
        json["delegateNotes"] = true
        // Read by the plugin without the lock (the file is replaced whole), so an ordinary thread spawns nothing.
        json["delegateNotesFile"] = DelegateNotes.file.path
        return (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    /// `lastdrop --agent-catalog`: the enabled agents for the plugin, as one JSON line. `t3Instance` says T3 Code
    /// runs lastdrop's own provider instance (`lastdrop`, enabled, its wrapper in place): the plugin then sends
    /// background children there, in the call as the model writes it.
    static func printMain() -> Never {
        let data = pluginLine()
        FileHandle.standardOutput.write(data + Data("\n".utf8))
        exit(0)
    }
}

extension AgentCatalog {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        agents = try values.decode([AgentDefinition].self, forKey: .agents)
        revision = try values.decode(Int.self, forKey: .revision)
        saveClaude = try values.decodeIfPresent(Bool.self, forKey: .saveClaude) ?? false
        saveClaudeText = try values.decodeIfPresent(String.self, forKey: .saveClaudeText)
        // A judge this version can't read (an unknown provider, a newer shape) is skipped, never a failure:
        // the provider falls back to its default rather than losing the whole list.
        let stored = (try? values.decodeIfPresent([String: Lenient<AgentJudge>].self, forKey: .judges)) ?? nil
        for (key, value) in stored ?? [:] {
            guard let provider = AgentProvider(rawValue: key), let judge = value.value, Self.problem(judge: judge, for: provider) == nil else { continue }
            judges[provider] = judge
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(agents, forKey: .agents)
        try c.encode(revision, forKey: .revision)
        try c.encode(saveClaude, forKey: .saveClaude)
        try c.encodeIfPresent(saveClaudeText, forKey: .saveClaudeText)
        if !judges.isEmpty {
            try c.encode(Dictionary(uniqueKeysWithValues: judges.map { ($0.key.rawValue, $0.value) }), forKey: .judges)
        }
    }
}

/// A value that decodes to nil instead of failing, so one bad entry doesn't fail its neighbours.
private struct Lenient<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

extension AgentDefinition {
    /// `id`, `enabled` and the rest are required as before; only `effort` and `fallbacks` may be missing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decode(String.self, forKey: .description)
        provider = try c.decode(AgentProvider.self, forKey: .provider)
        model = try c.decode(String.self, forKey: .model)
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        fallbacks = try c.decodeIfPresent([AgentFallback].self, forKey: .fallbacks) ?? []
    }

    /// Without fallbacks the key is left out, so stored catalogs and ledger entries stay as they were.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(description, forKey: .description)
        try c.encode(provider, forKey: .provider)
        try c.encode(model, forKey: .model)
        try c.encodeIfPresent(effort, forKey: .effort)
        try c.encode(enabled, forKey: .enabled)
        if !fallbacks.isEmpty { try c.encode(fallbacks, forKey: .fallbacks) }
    }
}
