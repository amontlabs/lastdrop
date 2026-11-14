import Darwin
import Foundation

/// `lastdrop --acp`: lastdrop as an Agent Client Protocol agent, the "lastdrop" provider of T3 Code. T3 runs one
/// process per thread and talks JSON-RPC 2.0 on its stdin and stdout, one object per line; everything else (logs,
/// stray prints) goes to stderr and `subagents.log`.
///
/// Phase 1 answers T3 children that lastdrop's plugin hands to this provider. Each turn runs as the plugin's
/// `delegatedTurn` runs it: `lastdrop --agent-run` with the same request (the task without its lastdrop tag first,
/// then each new message with `resume`), its lines shown as ACP updates, `lastdrop --agent-stop` to cancel.
/// Nothing is recorded and nothing starts until a session's first prompt: T3's probe opens a session every 15
/// minutes only to read the model list, then kills the process.
final class ACPServer: @unchecked Sendable {
    struct Options {
        /// A turn's runner: the request goes to its stdin, its lines come on its stdout.
        var runner: [String]
        /// Stops a run: the run's id is appended.
        var stopper: [String]
        var catalog: URL
        var sessions: URL
        /// How often a live session checks the catalog for a changed model list.
        var catalogPoll: TimeInterval = 2
        /// How long a cancelled turn waits for the runner to report it stopped before it ends it itself and answers.
        /// T3 waits 10 s for the answer.
        var cancelWait: TimeInterval = 7
        /// After SIGTERM, how long before SIGKILL.
        var killGrace: TimeInterval = 2

        /// This same binary.
        static func live() -> Options {
            let binary = Bundle.main.executablePath ?? CommandLine.arguments[0]
            return Options(runner: [binary, "--agent-run"], stopper: [binary, "--agent-stop"],
                           catalog: LastDropPaths.agentCatalog, sessions: ACPSessions.file)
        }
    }

    /// T3's models of Claude's own, beside the catalog's agents.
    static let claudeModels: [(id: String, name: String)] = [("fable", "Fable"), ("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")]
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
        answer(id, ["sessionId": session.id, "configOptions": configOptions(current: session.model)])
    }

    private func resume(_ id: Any, _ params: [String: Any]) {
        guard let sessionID = params["sessionId"] as? String else { return fail(id, -32602, "session/resume needs a sessionId.") }
        if let live = lock.withLock({ sessions[sessionID] }) {
            startWatching()
            return answer(id, ["configOptions": configOptions(current: live.model)])
        }
        guard let entry = ACPSessions.lookup(sessionID, at: options.sessions) else {
            SubagentLog.write("acp: resume of unknown session \(sessionID)")
            return fail(id, -32002, "lastdrop has no session \(sessionID): it was never prompted on this Mac, or its record was removed. Start a new thread.")
        }
        let session = Session(id: sessionID, cwd: params["cwd"] as? String ?? entry.cwd)
        session.entry = entry
        session.model = entry.model ?? Self.defaultModel
        lock.withLock { sessions[sessionID] = session }
        SubagentLog.write("acp: resumed session \(sessionID) (run \(entry.run), ran \(entry.ran))")
        startWatching()
        answer(id, ["configOptions": configOptions(current: session.model)])
    }

    private func setConfig(_ id: Any, _ params: [String: Any]) {
        guard let session = session(params) else { return fail(id, -32002, unknownSession(params)) }
        guard params["configId"] as? String == "model", let value = params["value"] as? String else {
            return fail(id, -32602, "lastdrop has only a model option.")
        }
        setModel(of: session, value)
        answer(id, ["configOptions": configOptions(current: session.model)])
    }

    private func setModel(_ id: Any, _ params: [String: Any]) {
        guard let session = session(params) else { return fail(id, -32002, unknownSession(params)) }
        guard let value = params["modelId"] as? String else { return fail(id, -32602, "session/set_model needs a modelId.") }
        setModel(of: session, value)
        answer(id, [:])
    }

    private func setModel(of session: Session, _ model: String) {
        lock.withLock {
            session.model = model
            // A run keeps what it started with; the model only names the session (and runs an untagged task).
            if session.entry != nil { session.entry?.model = model }
        }
        startWatching()
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

    /// The model select: every enabled agent of lastdrop's list, then Claude's own models.
    func configOptions(current: String?) -> [[String: Any]] {
        var options = Self.modelOptions(AgentCatalog.load(from: self.options.catalog))
        let value = current ?? Self.defaultModel
        if !options.contains(where: { $0["value"] as? String == value }) {
            options.append(["value": value, "name": value, "description": "No longer in lastdrop's list"])
        }
        return [["id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": value, "options": options]]
    }

    static func modelOptions(_ catalog: AgentCatalog) -> [[String: Any]] {
        let agents = catalog.enabled.filter { !AgentCatalog.isReserved($0.name) }.map { agent -> [String: Any] in
            ["value": agent.name, "name": agent.name, "description": agent.summary]
        }
        let claude = claudeModels.map { model -> [String: Any] in
            ["value": model.id, "name": model.name, "description": "Claude · \(model.name) on your Claude accounts"]
        }
        return agents + claude
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
            update(session.id, ["sessionUpdate": "config_option_update", "configOptions": configOptions(current: session.model)])
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
        let text = Self.userText(params["prompt"] as? [[String: Any]] ?? [])
        let started: Result<(Turn, [String: Any]), PromptError> = lock.withLock {
            if session.turn != nil { return .failure(.init(code: -32000, message: "A turn is already running in this session.")) }
            let request: [String: Any]
            do { request = try prepare(session, text) } catch let error as PromptError { return .failure(error) } catch {
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
            var agent = run?.agent, model = run?.model
            if agent == nil && model == nil && found == nil {
                // No tag: the task runs on the model picked for the session.
                if catalog.agent(picked) != nil { agent = picked } else if Self.claudeModels.contains(where: { $0.id == picked }) { model = picked } else {
                    throw PromptError(code: -32000, message: "lastdrop has no model \(picked) (Settings → Agents).")
                }
            }
            if agent == nil && found != nil, run?.model == nil, catalog.agent(picked) != nil { agent = picked }
            let runID = run?.id ?? "acp-\(UUID().uuidString.lowercased())"
            let parent = Self.claudeModels.contains(where: { $0.id == picked }) ? picked : nil
            session.entry = ACPSessions.Entry(run: runID, model: picked, agent: agent, runModel: model, effort: run?.effort,
                                              description: run?.description, permissionMode: run?.permissionMode, parentModel: parent,
                                              cwd: session.cwd, ran: false, task: task, updated: .now)
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
        let data = try JSONSerialization.data(withJSONObject: request, options: [.withoutEscapingSlashes])
        try turn.start(options.runner, input: data, directory: request["cwd"] as? String)
        var started = false
        let plain = request["agent"] == nil && request["resume"] == nil
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
                // Stopped by something other than T3 (`--agent-stop` from elsewhere): reported as the plugin does.
                if line["stopped"] as? Bool == true { return .ended(text: LastDropTag.header(line) + (line["text"] as? String ?? ""), usage: Self.usage(line)) }
                if line["isError"] as? Bool == true { return .failed(line["text"] as? String ?? "The agent failed.") }
                if !started { return .failed(line["text"] as? String ?? "lastdrop could not start the agent.") }
                return .ended(text: LastDropTag.header(line) + (line["text"] as? String ?? ""), usage: Self.usage(line))
            default:
                view.show(line)
            }
        }
        if turn.cancelled { return .cancelled }
        return .failed(started ? "lastdrop’s runner ended without the agent’s report." : "lastdrop’s runner ended before the agent started.")
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
}

/// One open ACP session.
final class Session {
    let id: String
    var cwd: String
    var model: String?
    var entry: ACPSessions.Entry?
    var turn: Turn?

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
