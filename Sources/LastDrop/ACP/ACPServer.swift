import Darwin
import Foundation

/// `lastdrop --acp`: lastdrop as an Agent Client Protocol agent, the "lastdrop" provider of T3 Code. T3 runs one
/// process per thread and talks JSON-RPC 2.0 on its stdin and stdout, one object per line; everything else (logs,
/// stray prints) goes to stderr and `subagents.log`.
///
/// Phase 1 answers T3 background children on this provider. The model calls `delegate_task` with
/// `target: {providerInstanceId: "lastdrop", model}` and the plugin passes the call unchanged (auto mode refuses a
/// changed call), so a first prompt is usually untagged: the run gets a new id, runs the session's model, and is
/// checked for room here (`lastdrop --agent-route`) the way the plugin's `admission` checks an Agent call. A first
/// prompt with lastdrop's tag (a child the plugin started before, or on its tag path) runs what the tag says.
/// Each turn runs as the plugin's `delegatedTurn` runs it: `lastdrop --agent-run` with the same request (the task
/// without its lastdrop tag first, then each new message with `resume`), its lines shown as ACP updates,
/// `lastdrop --agent-stop` to cancel.
/// Nothing is recorded and nothing starts until a session's first prompt: T3's probe opens a session every 15
/// minutes only to read the model list, then kills the process.
final class ACPServer: @unchecked Sendable {
    struct Options {
        /// A turn's runner: the request goes to its stdin, its lines come on its stdout.
        var runner: [String]
        /// Stops a run: the run's id is appended.
        var stopper: [String]
        /// Checks room for an untagged run before it starts: the request on its stdin, one line on its stdout.
        var router: [String]
        var catalog: URL
        var sessions: URL
        /// The efforts each provider's models took when lastdrop last listed them.
        var models: URL = AgentModelCache.file
        /// How often a live session checks the catalog for a changed model list.
        var catalogPoll: TimeInterval = 2
        /// How long a cancelled turn waits for the runner to report it stopped before it ends it itself and answers.
        /// T3 waits 10 s for the answer.
        var cancelWait: TimeInterval = 7
        /// After SIGTERM, how long before SIGKILL.
        var killGrace: TimeInterval = 2
        /// How long an untagged run's room check may take before the prompt fails.
        var routeTimeout: TimeInterval = 30

        /// This same binary.
        static func live() -> Options {
            let binary = Bundle.main.executablePath ?? CommandLine.arguments[0]
            return Options(runner: [binary, "--agent-run"], stopper: [binary, "--agent-stop"], router: [binary, "--agent-route"],
                           catalog: LastDropPaths.agentCatalog, sessions: ACPSessions.file)
        }
    }

    /// T3's models of Claude's own, before the catalog's agents: the alias as the value, "Claude Opus 5.5" as the name.
    static let claudeModels: [(id: String, name: String, model: String)] = ClaudeBackend.aliases.map {
        ($0.alias, modelName(.claude, $0.alias), $0.model)
    }
    /// The effort option's value for no effort: the run takes the agent's or Claude Code's own default.
    static let autoEffort = "auto"
    /// The effort menu, the same for every model and in every message: T3 gives every model of an ACP instance one
    /// option list, and a session's live options replace it for every thread (last report wins), so a menu narrowed
    /// to one model would narrow every thread's. A run gets the closest level its model offers (`resolveEffort`).
    static let effortLevels: [(value: String, name: String)] = [
        ("low", "Low"), ("medium", "Medium"), ("high", "High"), ("xhigh", "Extra high"), ("max", "Max"),
    ]
    /// Levels lowest first, for the closest one a model offers ("none" is no reasoning at all: never picked for one).
    static let effortRank = ["minimal", "low", "medium", "high", "xhigh", "max"]
    static let defaultModel = "sonnet"
    static let protocolVersion = 1
    /// What a turn tells the runner the child is, as `delegatedTurn` does.
    static let subagentType = "general-purpose"

    let options: Options
    private let input: Int32
    private let output: Int32
    private let writeLock = NSLock()
    private let lock = NSLock()
    private var sessions: [String: Session] = [:]
    private var watcher: DispatchSourceTimer?
    private var catalogStamp: String?

    init(input: Int32, output: Int32, options: Options) {
        self.input = input
        self.output = output
        self.options = options
    }

    // MARK: Entry

    /// `lastdrop --acp`: serves T3 on stdin and stdout until T3 closes stdin, then ends what still runs.
    static func main() -> Never {
        signal(SIGPIPE, SIG_IGN)
        // Only JSON-RPC may reach T3: the protocol keeps its own copy of stdout, and stdout itself becomes stderr,
        // so a print anywhere in lastdrop lands in T3's log instead of breaking the connection.
        let protocolOut = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        let server = ACPServer(input: STDIN_FILENO, output: protocolOut, options: .live())
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                server.shutdown()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
        server.serve()
        server.shutdown()
        exit(0)
    }

    nonisolated(unsafe) private static var signalSources: [DispatchSourceSignal] = []

    /// Reads requests until stdin closes.
    func serve() {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(input, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) else { continue }
                guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                    send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "lastdrop couldn't read that JSON-RPC line."]])
                    continue
                }
                receive(object)
            }
        }
    }

    /// Ends every running turn: T3 closed the connection or ended the process.
    func shutdown() {
        lock.withLock {
            watcher?.cancel()
            watcher = nil
        }
        let turns = lock.withLock { sessions.values.compactMap(\.turn) }
        for turn in turns { turn.terminate(grace: options.killGrace, wait: true) }
    }

    // MARK: Wire

    private func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        writeLock.withLock {
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = write(output, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0 { if errno == EINTR { continue }; return }
                    offset += written
                }
            }
        }
    }

    private func answer(_ id: Any, _ result: [String: Any]) { send(["jsonrpc": "2.0", "id": id, "result": result]) }

    private func fail(_ id: Any, _ code: Int, _ message: String) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    func update(_ session: String, _ update: [String: Any]) {
        send(["jsonrpc": "2.0", "method": "session/update", "params": ["sessionId": session, "update": update]])
    }

    private func receive(_ object: [String: Any]) {
        guard let method = object["method"] as? String else { return }   // T3 answering something: we ask nothing
        let params = object["params"] as? [String: Any] ?? [:]
        guard let id = object["id"], !(id is NSNull) else { return notification(method, params) }
        switch method {
        case "initialize": answer(id, initialize())
        case "session/new": newSession(id, params)
        case "session/resume": resume(id, params)
        case "session/set_config_option": setConfig(id, params)
        case "session/set_model": setModel(id, params)
        case "session/prompt": prompt(id, params)
        case "session/close": close(id, params)
        case "session/cancel": cancel(params); answer(id, [:])
        default: fail(id, -32601, "lastdrop doesn't support \(method).")
        }
    }

    private func notification(_ method: String, _ params: [String: Any]) {
        if method == "session/cancel" { cancel(params) }
    }

    // MARK: Methods

    private func initialize() -> [String: Any] {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        return [
            "protocolVersion": Self.protocolVersion,
            "agentCapabilities": [
                // Not loadSession: that also tells T3 it may rebuild a thread by replaying it, which lastdrop can't.
                "loadSession": false,
                // `close` makes T3 send session/close when it tears a thread down.
                "sessionCapabilities": ["resume": [String: Any](), "close": [String: Any]()],
                "promptCapabilities": ["image": false, "audio": false, "embeddedContext": false],
                "mcpCapabilities": ["http": false, "sse": false],
            ] as [String: Any],
            "agentInfo": ["name": "lastdrop", "title": "lastdrop", "version": version],
            "authMethods": [Any](),
        ]
    }

    /// The probe calls this every 15 minutes and kills the process: it reads the catalog file and nothing else.
    private func newSession(_ id: Any, _ params: [String: Any]) {
        let session = Session(id: "lastdrop-\(UUID().uuidString.lowercased())", cwd: params["cwd"] as? String ?? FileManager.default.currentDirectoryPath)
        session.model = Self.defaultModel
        lock.withLock { sessions[session.id] = session }
        answer(id, ["sessionId": session.id, "configOptions": configOptions(session), "models": modelState(session)])
    }

    private func resume(_ id: Any, _ params: [String: Any]) {
        guard let sessionID = params["sessionId"] as? String else { return fail(id, -32602, "session/resume needs a sessionId.") }
        if let live = lock.withLock({ sessions[sessionID] }) {
            startWatching()
            return answer(id, ["configOptions": configOptions(live), "models": modelState(live)])
        }
        guard let entry = ACPSessions.lookup(sessionID, at: options.sessions) else {
            SubagentLog.write("acp: resume of unknown session \(sessionID)")
            return fail(id, -32002, "lastdrop has no session \(sessionID): it was never prompted on this Mac, or its record was removed. Start a new thread.")
        }
        let session = Session(id: sessionID, cwd: params["cwd"] as? String ?? entry.cwd)
        session.entry = entry
        session.model = entry.model ?? Self.defaultModel
        session.effort = entry.requestedEffort ?? entry.effort
        lock.withLock { sessions[sessionID] = session }
        SubagentLog.write("acp: resumed session \(sessionID) (run \(entry.run), ran \(entry.ran))")
        startWatching()
        answer(id, ["configOptions": configOptions(session), "models": modelState(session)])
    }

    private func setConfig(_ id: Any, _ params: [String: Any]) {
        guard let session = session(params) else { return fail(id, -32002, unknownSession(params)) }
        let configID = params["configId"] as? String
        guard configID == "model" || configID == "effort", let value = params["value"] as? String else {
            return fail(id, -32602, "lastdrop has only a model and an effort option.")
        }
        if configID == "effort" {
            if let refusal = setEffort(of: session, value) { return fail(id, -32602, refusal) }
            return answer(id, ["configOptions": configOptions(session)])
        }
        if let refusal = setModel(of: session, value) { return fail(id, -32602, refusal) }
        answer(id, ["configOptions": configOptions(session)])
    }

    private func setModel(_ id: Any, _ params: [String: Any]) {
        guard let session = session(params) else { return fail(id, -32002, unknownSession(params)) }
        guard let value = params["modelId"] as? String else { return fail(id, -32602, "session/set_model needs a modelId.") }
        if let refusal = setModel(of: session, value) { return fail(id, -32602, refusal) }
        answer(id, [:])
    }

    /// The model for the session's next turn; the reason it can't change, else nil. Once the runner started the run,
    /// it stays on what it runs (the same model again is fine: T3 sets it when it opens a thread). Before that, an
    /// untagged run takes the new model; a tagged one runs what its tag says.
    private func setModel(of session: Session, _ model: String) -> String? {
        let catalog = AgentCatalog.load(from: options.catalog), known = AgentModelCache.load(options.models)
        let refusal: String? = lock.withLock {
            guard var entry = session.entry else { session.model = model; return nil }
            if model == entry.model { return nil }
            if entry.ran {
                return "This run stays on \(entry.agent ?? entry.runModel ?? entry.parentModel ?? entry.model ?? "its model"); start a new task for \(model)."
            }
            if entry.checksRoom == true {
                guard let what = Self.untaggedRun(model, catalog) else { return Self.unknownModel(model) }
                entry.agent = what.agent
                entry.runModel = what.model
                entry.parentModel = what.model
                entry.effort = Self.resolveEffort(session.effort, for: model, catalog, known).effort
                entry.requestedEffort = session.effort
            }
            entry.model = model
            session.entry = entry
            session.model = model
            return nil
        }
        if refusal == nil { startWatching() }
        return refusal
    }

    /// The effort for the session's runs; the reason it can't change, else nil. "auto" is no effort. Every model
    /// takes every level of the menu: a run gets the closest its model offers (`resolveEffort`), and its answer says so.
    /// Once the runner started the run, it keeps its effort (the runner continues a run at the effort it began
    /// with): a choice that gives the same effort is taken, another refused.
    private func setEffort(of session: Session, _ value: String) -> String? {
        guard value == Self.autoEffort || Self.effortLevels.contains(where: { $0.value == value }) else {
            return "lastdrop takes effort \(([Self.autoEffort] + Self.effortLevels.map(\.value)).joined(separator: ", ")), not \(value)."
        }
        let catalog = AgentCatalog.load(from: options.catalog), known = AgentModelCache.load(options.models)
        let effort = value == Self.autoEffort ? nil : value
        return lock.withLock {
            guard var entry = session.entry else { session.effort = effort; return nil }
            let untagged = entry.checksRoom == true
            let resolved = Self.resolveEffort(effort, for: entry.model ?? session.model ?? Self.defaultModel, catalog, known).effort
            if entry.ran && resolved != entry.effort {
                return "This run stays at effort \(entry.effort ?? Self.autoEffort); start a new task for effort \(value)."
            }
            session.effort = effort
            // A tagged run keeps the effort its tag gave.
            if untagged {
                entry.effort = resolved
                entry.requestedEffort = effort
                session.entry = entry
            }
            return nil
        }
    }

    /// The efforts a caller may pick for `model`, "auto" aside; nil when there is none to pick. A Claude model takes
    /// every one Claude Code takes. An agent takes one only without an effort of its own, and only a level every
    /// model of its chain that takes efforts takes: the call's effort goes to each attempt (`AgentRun.effort`), so a
    /// level its fallback lacks would fail the fallback. Each model's levels are the ones lastdrop last listed for it
    /// (`known`), else its provider's (`callerEfforts`). A first model that takes none gives no option; a fallback
    /// that takes none is left out of the check (it takes no effort from any caller, Agent calls included).
    static func efforts(for model: String, _ catalog: AgentCatalog, _ known: [String: AgentModelCache.Entry]) -> [String]? {
        if claudeModels.contains(where: { $0.id == model }) { return ClaudeBackend.efforts }
        guard let agent = catalog.agent(model), agent.effort == nil else { return nil }
        let levels = agent.chain.map { AgentModelCache.efforts($0.provider, $0.model, in: known) ?? $0.provider.callerEfforts }
        guard let first = levels.first, !first.isEmpty else { return nil }
        let common = levels.dropFirst().filter { !$0.isEmpty }.reduce(first) { kept, next in kept.filter(next.contains) }
        return common.isEmpty ? nil : common
    }

    /// What a run of `model` gets for the menu's `chosen` effort (nil: auto), and what its answer's header says
    /// when that isn't the choice. A Claude model takes it as is. An agent with its own effort keeps it (and the
    /// request carries none: a request effort would override the agent's own in `AgentRun.effort`). Otherwise the
    /// closest level the model offers (`efforts(for:)`): the next lower, else the next higher; a model that takes
    /// none runs without one.
    static func resolveEffort(_ chosen: String?, for model: String, _ catalog: AgentCatalog,
                              _ known: [String: AgentModelCache.Entry]) -> (effort: String?, note: String?) {
        guard let chosen else { return (nil, nil) }
        if let agent = catalog.agent(model), let own = agent.effort {
            return (nil, own == chosen ? nil : "effort \(own) (\(model) sets its own effort)")
        }
        if claudeModels.contains(where: { $0.id == model }) { return (chosen, nil) }
        guard catalog.agent(model) != nil else { return (nil, nil) }
        guard let levels = efforts(for: model, catalog, known) else { return (nil, "no effort (\(model) doesn't take one)") }
        if levels.contains(chosen) { return (chosen, nil) }
        let rank = { (level: String) in effortRank.firstIndex(of: level) }
        guard let wanted = rank(chosen) else { return (nil, nil) }
        let ranked = levels.compactMap { level in rank(level).map { (level, $0) } }
        let closest = ranked.filter { $0.1 < wanted }.max { $0.1 < $1.1 } ?? ranked.filter { $0.1 > wanted }.min { $0.1 < $1.1 }
        guard let closest else { return (nil, "no effort (\(model) offers none of lastdrop's levels)") }
        return (closest.0, "effort \(closest.0) (\(chosen) isn't offered)")
    }

    /// What an untagged run of `model` runs: an agent of lastdrop's list, or one of Claude's models; nil for neither.
    static func untaggedRun(_ model: String, _ catalog: AgentCatalog) -> (agent: String?, model: String?)? {
        if catalog.agent(model) != nil { return (model, nil) }
        if claudeModels.contains(where: { $0.id == model }) { return (nil, model) }
        return nil
    }

    static func unknownModel(_ model: String) -> String {
        "lastdrop has no model \(model). Pick one of lastdrop's agents, or fable, opus, sonnet or haiku."
    }

    private func close(_ id: Any, _ params: [String: Any]) {
        guard let sessionID = params["sessionId"] as? String else { return fail(id, -32602, "session/close needs a sessionId.") }
        let session = lock.withLock { sessions.removeValue(forKey: sessionID) }
        if let turn = session?.turn {
            turn.cancelled = true
            stop(turn)
            turn.terminate(grace: options.killGrace, wait: false)
            finish(turn, .cancelled)
        }
        answer(id, [:])
    }

    private func cancel(_ params: [String: Any]) {
        guard let session = session(params), let turn = lock.withLock({ session.turn }) else { return }
        turn.cancelled = true
        SubagentLog.write("acp: cancel \(session.id) (run \(turn.run))")
        stop(turn)
        // T3 waits 10 s for the answer: a runner that hasn't reported by then is ended here.
        DispatchQueue.global().asyncAfter(deadline: .now() + options.cancelWait) { [self] in
            guard !turn.isAnswered else { return }
            turn.terminate(grace: options.killGrace, wait: false)
            finish(turn, .cancelled)
        }
    }

    /// `lastdrop --agent-stop <run>`; a runner that hasn't started the agent yet has nothing to stop, so it is ended.
    private func stop(_ turn: Turn) {
        let stopper = options.stopper + [turn.run]
        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: stopper[0])
            process.arguments = Array(stopper.dropFirst())
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0, !turn.isAnswered { turn.terminate(grace: self.options.killGrace, wait: false) }
            } catch {
                SubagentLog.write("acp: couldn't run the stopper: \(error.localizedDescription)")
                turn.terminate(grace: self.options.killGrace, wait: false)
            }
        }
    }

    private func session(_ params: [String: Any]) -> Session? {
        guard let id = params["sessionId"] as? String else { return nil }
        return lock.withLock { sessions[id] }
    }

    private func unknownSession(_ params: [String: Any]) -> String {
        "lastdrop has no open session \(params["sessionId"] as? String ?? "(none)")."
    }

    // MARK: Models

    /// The session's options: the model select and the effort select, the same effort menu for every model.
    func configOptions(_ session: Session) -> [[String: Any]] {
        let (model, effort) = lock.withLock { (session.model ?? Self.defaultModel, session.effort) }
        return Self.configOptions(model: model, effort: effort, AgentCatalog.load(from: options.catalog))
    }

    /// The session's models as ACP's `models` state, each with the details of its effort in `_meta`.
    func modelState(_ session: Session) -> [String: Any] {
        let model = lock.withLock { session.model ?? Self.defaultModel }
        return Self.modelState(model: model, AgentCatalog.load(from: options.catalog), AgentModelCache.load(options.models))
    }

    /// `effort` is the menu's choice (nil: auto); a level outside the menu shows as auto.
    static func configOptions(model value: String, effort: String?, _ catalog: AgentCatalog) -> [[String: Any]] {
        let current = effort.flatMap { effort in effortLevels.first { $0.value == effort }?.value } ?? autoEffort
        return [["id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": value, "options": models(value, catalog)],
                effortOption(current)]
    }

    static func effortOption(_ current: String) -> [String: Any] {
        let auto: [String: Any] = ["value": autoEffort, "name": "Auto", "description": "No effort set: the model's or the agent's own default."]
        let levels = effortLevels.map { ["value": $0.value, "name": $0.name] as [String: Any] }
        return ["id": "effort", "name": "Effort", "category": "thought_level", "type": "select", "currentValue": current,
                "description": "A model that doesn't offer this level runs at the closest one it does, and its answer says so.",
                "options": [auto] + levels]
    }

    /// The model select's entries, the selected one kept when it left lastdrop's list.
    private static func models(_ value: String, _ catalog: AgentCatalog) -> [[String: Any]] {
        var models = modelOptions(catalog)
        if !models.contains(where: { $0["value"] as? String == value }) {
            models.append(["value": value, "name": value, "description": "No longer in lastdrop's list"])
        }
        return models
    }

    /// ACP's `models` state (`{currentModelId, availableModels: [{modelId, name, description, _meta}]}`), in
    /// `session/new` and `session/resume` only. Official T3 reads it only when no `model` config option exists
    /// (probe.ts, adapter.ts), so it changes nothing there; a patched T3 can read each model's effort from `_meta`,
    /// in the shape its Grok driver parses (`grokReasoningOptionsFromModel`).
    static func modelState(model value: String, _ catalog: AgentCatalog, _ known: [String: AgentModelCache.Entry]) -> [String: Any] {
        ["currentModelId": value, "availableModels": models(value, catalog).map { option -> [String: Any] in
            let id = option["value"] as? String ?? ""
            var model: [String: Any] = ["modelId": id, "name": option["name"] as? String ?? id, "_meta": modelMeta(id, catalog, known)]
            if let description = option["description"] { model["description"] = description }
            return model
        }]
    }

    /// One model's effort for a patched T3: whether the caller picks one, the levels it really offers with "auto"
    /// (its own default) first and default, and the backend it runs on first. A fixed-effort agent lists only its own.
    static func modelMeta(_ model: String, _ catalog: AgentCatalog, _ known: [String: AgentModelCache.Entry]) -> [String: Any] {
        func label(_ level: String) -> String { effortLevels.first { $0.value == level }?.name ?? level.capitalized }
        let agent = catalog.agent(model)
        var meta: [String: Any] = ["subProvider": (agent?.provider ?? .claude).displayName]
        if let own = agent?.effort {
            meta["supportsReasoningEffort"] = false
            meta["reasoningEfforts"] = [["value": own, "label": label(own), "default": true] as [String: Any]]
            meta["reasoningEffort"] = own
        } else if let levels = efforts(for: model, catalog, known) {
            meta["supportsReasoningEffort"] = true
            meta["reasoningEfforts"] = [["value": autoEffort, "label": "Auto", "default": true] as [String: Any]]
                + levels.map { ["value": $0, "label": label($0)] as [String: Any] }
            meta["reasoningEffort"] = autoEffort
        } else {
            meta["supportsReasoningEffort"] = false
            meta["reasoningEfforts"] = [[String: Any]]()
        }
        return meta
    }

    /// Claude's own models, then every enabled agent of lastdrop's list, in its order.
    static func modelOptions(_ catalog: AgentCatalog) -> [[String: Any]] {
        let claude = claudeModels.map { model -> [String: Any] in
            ["value": model.id, "name": model.name, "description": "\(model.model) on your Claude accounts, the one with the most room."]
        }
        let agents = catalog.enabled.filter { !AgentCatalog.isReserved($0.name) }.map { agent -> [String: Any] in
            // "build · Antigravity Claude Sonnet 5.5"; a Claude agent is "judge · Claude Fable 5.2", not "Claude Claude".
            let provider = agent.provider.displayName, model = modelName(agent.provider, agent.model)
            let runsOn = model.hasPrefix(provider + " ") ? model : "\(provider) \(model)"
            return ["value": agent.name, "name": bounded("\(agent.name) · \(runsOn)", 160),
                    "description": bounded("\(agent.description) (\(agent.summary))", 1024)]
        }
        return claude + agents
    }

    /// The name people know a model by: "Claude Opus 5.5" for `opus` or `claude-opus-5-5`, "GPT-6.1 Sol",
    /// "Gemini 3.8 Flash"; other ids as they are.
    static func modelName(_ provider: AgentProvider, _ model: String) -> String {
        let id = ClaudeBackend.aliases.first { $0.alias == model }?.model ?? model
        let name = UsagePrice.displayName(id)
        return id.hasPrefix("claude-") ? "Claude " + name : name
    }

    /// T3 cuts names at 160 characters and descriptions at 1024; cut here first, with an ellipsis.
    static func bounded(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    /// Polls the catalog while sessions are open; a changed list goes to every open session, since T3 publishes
    /// the model list `delegate_task` checks from each session's `config_option_update`.
    private func startWatching() {
        lock.lock()
        defer { lock.unlock() }
        guard watcher == nil else { return }
        catalogStamp = Self.stamp(options.catalog)
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + options.catalogPoll, repeating: options.catalogPoll)
        timer.setEventHandler { [weak self] in self?.checkCatalog() }
        timer.resume()
        watcher = timer
    }

    private func checkCatalog() {
        let stamp = Self.stamp(options.catalog)
        let open: [Session]? = lock.withLock {
            guard stamp != catalogStamp else { return nil }
            catalogStamp = stamp
            return Array(sessions.values)
        }
        guard let open else { return }
        for session in open {
            update(session.id, ["sessionUpdate": "config_option_update", "configOptions": configOptions(session)])
        }
    }

    private static func stamp(_ url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let date = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(date)-\(attributes[.size] as? Int ?? 0)-\(attributes[.systemFileNumber] as? Int ?? 0)"
    }

    // MARK: Prompt

    private func prompt(_ id: Any, _ params: [String: Any]) {
        guard let session = session(params) else { return fail(id, -32002, unknownSession(params)) }
        let blocks = params["prompt"] as? [[String: Any]] ?? []
        let text = Self.userText(blocks)
        let mode = Self.interactionMode(blocks)
        let started: Result<(Turn, [String: Any]), PromptError> = lock.withLock {
            if session.turn != nil { return .failure(.init(code: -32000, message: "A turn is already running in this session.")) }
            // T3 sends its interaction mode with the wrapper whenever it changes: Plan runs the turn read-only, as a
            // T3 Claude child switched to Plan does; Default goes back to the child's own mode.
            if let mode { session.plan = mode == "plan" }
            var request: [String: Any]
            do { request = try prepare(session, text); if session.plan { request["permissionMode"] = "plan" } } catch let error as PromptError { return .failure(error) } catch {
                return .failure(.init(code: -32000, message: error.localizedDescription))
            }
            let turn = Turn(requestID: id, session: session.id, run: session.entry!.run)
            session.turn = turn
            return .success((turn, request))
        }
        switch started {
        case .failure(let error): fail(id, error.code, error.message)
        case .success(let (turn, request)):
            if let entry = lock.withLock({ session.entry }) { ACPSessions.save(session.id, entry, at: options.sessions) }
            startWatching()
            Thread.detachNewThread { [self] in run(turn, request, session) }
        }
    }

    struct PromptError: Error { var code: Int; var message: String }

    /// The runner's request for this turn, as `delegatedTurn` builds it; the session's entry is created at its first.
    private func prepare(_ session: Session, _ text: String) throws -> [String: Any] {
        if session.entry == nil {
            let found = LastDropTag.untag(text)
            let task = found?.task ?? text
            let run = found?.run
            let picked = session.model ?? Self.defaultModel
            let catalog = AgentCatalog.load(from: options.catalog)
            var agent = run?.agent, model = run?.model, effort = run?.effort
            if found == nil {
                // A child the model started on this instance itself (the plugin never changes the call): it runs the
                // model T3 picked for the session, at the effort T3 picked if that model takes one, with no description,
                // and is checked for room first.
                guard let what = Self.untaggedRun(picked, catalog) else { throw PromptError(code: -32602, message: Self.unknownModel(picked)) }
                agent = what.agent
                model = what.model
                effort = Self.resolveEffort(session.effort, for: picked, catalog, AgentModelCache.load(options.models)).effort
            }
            if agent == nil && found != nil, run?.model == nil, catalog.agent(picked) != nil { agent = picked }
            let runID = run?.id ?? "acp-\(UUID().uuidString.lowercased())"
            let parent = Self.claudeModels.contains(where: { $0.id == picked }) ? picked : nil
            session.entry = ACPSessions.Entry(run: runID, model: picked, agent: agent, runModel: model, effort: effort,
                                              requestedEffort: found == nil ? session.effort : nil, description: run?.description, permissionMode: run?.permissionMode, parentModel: parent,
                                              cwd: session.cwd, ran: false, task: task, checksRoom: found == nil ? true : nil, updated: .now)
            SubagentLog.write("acp: session \(session.id) runs \(runID) (\(agent ?? model ?? parent ?? "session model"))\(found == nil ? ", untagged" : "")")
        } else if session.entry?.ran == false {
            // The run never started (the turn was cancelled first): the task goes again, with what came since.
            let task = [session.entry?.task ?? "", text].filter { !$0.isEmpty }.joined(separator: "\n\n")
            session.entry?.task = task
        }
        let entry = session.entry!
        let prompt = entry.ran ? text : entry.task ?? ""
        if prompt.isEmpty { throw PromptError(code: -32602, message: "The prompt has no text for lastdrop to send.") }
        return Self.request(entry, prompt: prompt)
    }

    /// `delegatedTurn`'s request, key for key (absent keys are left out, as JSON.stringify drops undefined).
    static func request(_ entry: ACPSessions.Entry, prompt: String) -> [String: Any] {
        var request: [String: Any] = ["prompt": prompt, "subagentType": subagentType, "cwd": entry.cwd, "id": entry.run]
        if let value = entry.description { request["description"] = value }
        if let value = entry.runModel { request["model"] = value }
        if let value = entry.effort { request["effort"] = value }
        if let value = entry.permissionMode { request["permissionMode"] = value }
        if let value = entry.parentModel { request["parentModel"] = value }
        if let value = entry.agent { request["agent"] = value }
        if entry.ran { request["resume"] = entry.run }
        return request
    }

    /// One turn: the runner's lines become updates, its report the answer.
    private func run(_ turn: Turn, _ request: [String: Any], _ session: Session) {
        let view = TurnView(session: session.id, send: { [weak self] in self?.update(session.id, $0) })
        let outcome: Outcome
        do {
            outcome = try drive(turn, request, session, view)
        } catch {
            outcome = .failed(error.localizedDescription)
        }
        if case .ended(let text, _) = outcome { view.close(report: text, failed: false) } else { view.close(report: nil, failed: true) }
        finish(turn, turn.cancelled ? .cancelled : outcome)
    }

    enum Outcome {
        case ended(text: String, usage: [String: Any]?)
        case failed(String)
        case cancelled
    }

    private func drive(_ turn: Turn, _ request: [String: Any], _ session: Session, _ view: TurnView) throws -> Outcome {
        let plain = request["agent"] == nil && request["resume"] == nil
        if request["resume"] == nil, lock.withLock({ session.entry?.checksRoom == true }) {
            switch Self.admit(options.router, request, timeout: options.routeTimeout, cancelled: { turn.cancelled }) {
            case .routed: break
            case .noRoom: return .failed(Self.noRoom(request, plain: plain))
            case .failed(let message): return .failed(message)
            case .cancelled: return .cancelled
            }
            if turn.cancelled { return .cancelled }
        }
        let data = try JSONSerialization.data(withJSONObject: request, options: [.withoutEscapingSlashes])
        try turn.start(options.runner, input: data, directory: request["cwd"] as? String)
        var started = false
        while let line = turn.nextLine() {
            let type = line["type"] as? String ?? ""
            switch type {
            case "started":
                if !started {
                    started = true
                    let saved: ACPSessions.Entry? = lock.withLock {
                        session.entry?.ran = true
                        session.entry?.task = nil
                        return session.entry
                    }
                    if let saved { ACPSessions.save(session.id, saved, at: options.sessions) }
                }
            case "no_room":
                return .failed(Self.noRoom(request, plain: plain))
            case "native":
                return .failed(Self.noRoom(request, plain: plain && !started))
            case "error":
                return .failed(line["text"] as? String ?? "lastdrop could not start the agent.")
            case "result":
                if turn.cancelled { return .cancelled }
                if line["isError"] as? Bool == true { return .failed(line["text"] as? String ?? "The agent failed.") }
                if !started { return .failed(line["text"] as? String ?? "lastdrop could not start the agent.") }
                return .ended(text: LastDropTag.header(line, effort: effortNote(session)) + (line["text"] as? String ?? ""), usage: Self.usage(line))
            default:
                view.show(line)
            }
        }
        if turn.cancelled { return .cancelled }
        return .failed(started ? "lastdrop’s runner ended without the agent’s report." : "lastdrop’s runner ended before the agent started.")
    }

    /// What the answer's header says about an untagged run's effort when it isn't the menu's choice; tagged runs
    /// and auto say nothing.
    private func effortNote(_ session: Session) -> String? {
        guard let entry = lock.withLock({ session.entry }), entry.checksRoom == true, entry.requestedEffort != nil else { return nil }
        return Self.resolveEffort(entry.requestedEffort, for: entry.model ?? Self.defaultModel, AgentCatalog.load(from: options.catalog),
                                  AgentModelCache.load(options.models)).note
    }

    enum Admission: Equatable { case routed, noRoom, failed(String), cancelled }

    /// `lastdrop --agent-route` with the request the plugin's `admission` sends for a delegate_task child (the
    /// turn's request without its run id): it picks nothing and starts nothing, it only says whether there is room.
    static func admit(_ router: [String], _ turnRequest: [String: Any], timeout: TimeInterval = 30,
                      cancelled: () -> Bool = { false }) -> Admission {
        var request = turnRequest
        request["id"] = nil
        guard let data = try? JSONSerialization.data(withJSONObject: request, options: [.withoutEscapingSlashes]) else {
            return .failed("lastdrop couldn't write its routing check.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: router[0])
        process.arguments = Array(router.dropFirst())
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.standardError
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do { try process.run() } catch { return .failed("lastdrop’s routing check failed: \(error.localizedDescription)") }
        try? stdin.fileHandleForWriting.write(contentsOf: data)
        try? stdin.fileHandleForWriting.close()
        // Read on its own thread, so a cancel or a check that hangs ends it here instead of holding the turn.
        let done = DispatchSemaphore(value: 0)
        let box = OutputBox()
        let reader = stdout.fileHandleForReading
        DispatchQueue.global().async {
            box.data = reader.readDataToEndOfFile()
            done.signal()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while done.wait(timeout: .now() + 0.05) == .timedOut {
            let stop: Admission? = cancelled() ? .cancelled : Date() >= deadline
                ? .failed("lastdrop’s routing check didn’t answer in \(Int(timeout)) s.") : nil
            if let stop {
                process.terminate()
                return stop
            }
        }
        process.waitUntilExit()
        let output = box.data
        let line = output.split(separator: 0x0A).lazy.compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }.first
        switch line?["type"] as? String {
        case "routed": return .routed
        case "no_room": return .noRoom
        default: return .failed(line?["text"] as? String ?? "lastdrop’s routing check ended without an answer.")
        }
    }

    /// What the plugin denies with when lastdrop has nowhere to run the child: here no Claude model of T3's stands by.
    static func noRoom(_ request: [String: Any], plain: Bool) -> String {
        let what = request["agent"] as? String ?? request["model"] as? String ?? request["parentModel"] as? String ?? "this agent"
        return plain
            ? "lastdrop found no account with room for \(what), and this thread has no model of its own to fall back to. Try again later, or start the task on T3's Claude provider."
            : "lastdrop found nowhere to run \(what)."
    }

    /// The run's last top-level request as the context's size, like the plugin's `usageOf`; nil when the backend can't say.
    static func usage(_ line: [String: Any]) -> [String: Any]? {
        guard let context = line["context"] as? [String: Any] else { return nil }
        func n(_ key: String) -> Int { (context[key] as? NSNumber)?.intValue ?? 0 }
        let used = n("inputTokens") + n("cacheReadInputTokens") + n("cacheCreationInputTokens") + n("outputTokens")
        let size = (context["contextWindow"] as? NSNumber)?.intValue ?? max(200_000, used)
        return ["sessionUpdate": "usage_update", "used": used, "size": size]
    }

    private func finish(_ turn: Turn, _ outcome: Outcome) {
        guard turn.answer() else { return }
        lock.withLock {
            if let session = sessions[turn.session], session.turn === turn { session.turn = nil }
        }
        switch outcome {
        case .ended(let text, let usage):
            if let usage { update(turn.session, usage) }
            if !text.isEmpty { update(turn.session, ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": text]]) }
            answer(turn.requestID, ["stopReason": "end_turn"])
        case .cancelled:
            answer(turn.requestID, ["stopReason": "cancelled"])
        case .failed(let message):
            SubagentLog.write("acp: turn of \(turn.session) failed: \(message.prefix(300))")
            fail(turn.requestID, -32000, message)
        }
    }

    // MARK: Prompt text

    /// The user's own text of a prompt: its text blocks, without T3's per-prompt wrapper.
    static func userText(_ blocks: [[String: Any]]) -> String {
        T3Wrapper.strip(blocks: blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil })
    }

    /// The interaction mode T3's wrapper names ("plan" or "default"), when the prompt carries the wrapper.
    static func interactionMode(_ blocks: [[String: Any]]) -> String? {
        for block in blocks where block["type"] as? String == "text" {
            guard let text = block["text"] as? String, text.hasPrefix(T3Wrapper.instructionsOpen),
                  let end = text.range(of: T3Wrapper.requestOpen) else { continue }
            let instructions = text[..<end.lowerBound]
            if instructions.contains("## T3 Code interaction mode: Plan") { return "plan" }
            if instructions.contains("## T3 Code interaction mode: Default") { return "default" }
        }
        return nil
    }
}

private final class OutputBox: @unchecked Sendable { var data = Data() }

/// One open ACP session.
final class Session {
    let id: String
    var cwd: String
    var model: String?
    /// The effort T3 picked (`effort` option); nil for auto. A run takes it only when its model takes one.
    var effort: String?
    var entry: ACPSessions.Entry?
    var turn: Turn?
    /// T3 set the thread to Plan: turns run read-only until it says Default.
    var plan = false

    init(id: String, cwd: String) {
        self.id = id
        self.cwd = cwd
    }
}

/// A running prompt: its runner process and the one answer it gets.
final class Turn: @unchecked Sendable {
    let requestID: Any
    let session: String
    let run: String
    private let lock = NSLock()
    private var answered = false
    private var _cancelled = false
    private var process: Process?
    private var buffer = Data()
    private var output: FileHandle?

    init(requestID: Any, session: String, run: String) {
        self.requestID = requestID
        self.session = session
        self.run = run
    }

    var cancelled: Bool {
        get { lock.withLock { _cancelled } }
        set { lock.withLock { _cancelled = newValue } }
    }

    var isAnswered: Bool { lock.withLock { answered } }

    /// True the first time only.
    func answer() -> Bool {
        lock.withLock {
            if answered { return false }
            answered = true
            return true
        }
    }

    func start(_ argv: [String], input: Data, directory: String?) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        if let directory, FileManager.default.fileExists(atPath: directory) { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.standardError
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        // The runner stays in this process's group: T3 ends a thread by its process group, which then reaches the
        // runner too, so no run outlives its thread.
        try lock.withLock {
            if _cancelled { throw ACPServer.PromptError(code: -32000, message: "Cancelled.") }
            try process.run()
            self.process = process
            self.output = stdout.fileHandleForReading
        }
        try? stdin.fileHandleForWriting.write(contentsOf: input)
        try? stdin.fileHandleForWriting.close()
    }

    /// The runner's next JSON line, or nil once its output ended.
    func nextLine() -> [String: Any]? {
        guard let output = lock.withLock({ self.output }) else { return nil }
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                if let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { return object }
                continue
            }
            let data = output.availableData
            if data.isEmpty { return nil }
            buffer.append(data)
        }
    }

    /// SIGTERM to the runner (it ends the agent processes it started), SIGKILL after `grace`.
    func terminate(grace: TimeInterval, wait: Bool) {
        guard let process = lock.withLock({ self.process }), process.isRunning else { return }
        let pid = process.processIdentifier
        kill(pid, SIGTERM)
        let kill9 = { if process.isRunning { kill(pid, SIGKILL) } }
        if wait {
            let deadline = Date().addingTimeInterval(grace)
            while process.isRunning && Date() < deadline { usleep(50_000) }
            kill9()
        } else {
            DispatchQueue.global().asyncAfter(deadline: .now() + grace, execute: kill9)
        }
    }
}
