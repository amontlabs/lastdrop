import Foundation

/// Runs the official Antigravity CLI as an ACP agent (`agy acp`), leaving authentication and sessions with `agy`.
/// Each action that needs approval arrives as `session/request_permission` before it runs; lastdrop answers it with
/// the user's Claude Code rules, then Codex's reviewer policy judged by Gemini (`CommandJudge`). Nobody is asked.
/// ACP: https://agentclientprotocol.com. Flags and effort: https://www.antigravity.google/docs/cli/reference/
enum AntigravityBackend: AgentBackend {
    static let efforts = ["low", "medium", "high", "xhigh", "max"]

    static func executable(environment: [String: String] = ProcessInfo.processInfo.environment,
                           home: String = NSHomeDirectory()) -> String? {
        let candidates = [home + "/.local/bin/agy"]
            + (environment["PATH"] ?? "").components(separatedBy: ":").filter { !$0.isEmpty }.map { $0 + "/agy" }
            + ["/opt/homebrew/bin/agy"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func models() async throws -> [AgentModel] {
        guard let executable = executable() else { throw Failure("Antigravity (`agy`) was not found on this Mac.") }
        var output = ""
        let command = try await execute(executable, ["models"], directory: LastDropPaths.helperDirectory) { output += $0 + "\n" }
        guard command.status == 0 else { throw Failure(message(command.stderr.isEmpty ? output : command.stderr)) }
        let models = parseModels(output)
        guard !models.isEmpty else { throw Failure("Antigravity returned no models. Run `agy models` in Terminal to check access.") }
        return models
    }

    /// `agy models` lines, and ACP's `availableModels`, are a slug per model and effort with a display name.
    static func parseModels(_ text: String) -> [AgentModel] {
        var models: [AgentModel] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2 else { continue }
            let slug = String(fields[0]).trimmingCharacters(in: .whitespaces)
            let name = String(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !slug.isEmpty, !name.isEmpty else { continue }
            let effort = suffix(slug)
            let base = effort.map { String(slug.dropLast($0.count + 1)) } ?? slug
            let label = effort.map { " (\($0.capitalized))" }
            let display = label.flatMap { name.hasSuffix($0) ? String(name.dropLast($0.count)) : nil } ?? name
            if let index = models.firstIndex(where: { $0.id == base }) {
                if let effort, !models[index].efforts.contains(effort) { models[index].efforts.append(effort) }
            } else {
                models.append(AgentModel(id: base, name: display, efforts: effort.map { [$0] } ?? [], defaultEffort: nil))
            }
        }
        for index in models.indices {
            models[index].efforts = efforts.filter { models[index].efforts.contains($0) }
            models[index].defaultEffort = models[index].efforts.contains("medium") ? "medium" : models[index].efforts.first
        }
        return models
    }

    /// `session/new`'s `models.availableModels`, as `parseModels` reads them.
    static func parseModels(acp result: [String: Any]) -> [AgentModel] {
        let lines = (result.dict("models")?.array("availableModels") ?? []).compactMap { model -> String? in
            guard let id = model.string("modelId") else { return nil }
            return id + "\t" + (model.string("name") ?? id)
        }
        return parseModels(lines.joined(separator: "\n"))
    }

    private static func suffix(_ model: String) -> String? {
        efforts.first { model.hasSuffix("-" + $0) }
    }

    static func slug(model: String, effort: String?, models: [AgentModel]) throws -> String {
        if suffix(model) != nil { return model }
        guard let offered = models.first(where: { $0.id == model }) else {
            throw Failure("Antigravity does not offer model \(model). Run `agy models` to check access.", unavailable: true)
        }
        guard !offered.efforts.isEmpty else {
            if let effort { throw Failure("Antigravity model \(model) does not offer effort \(effort).", unavailable: true) }
            return model
        }
        let selected = effort ?? offered.defaultEffort ?? "medium"
        guard offered.efforts.contains(selected) else {
            throw Failure("Antigravity model \(model) does not offer effort \(selected) (available: \(offered.efforts.joined(separator: ", "))).", unavailable: true)
        }
        return model + "-" + selected
    }

    // MARK: Permissions

    /// How a session's permission mode runs on Antigravity.
    enum Policy: Equatable {
        /// `plan`, and every read-only role: Antigravity's plan mode; nothing that writes is allowed, and commands
        /// go to deny rules, then the judge told the agent is read-only.
        case readOnly
        /// `default`, `auto`, `acceptEdits`: edits in the workspace without asking (Antigravity's accept-edits),
        /// commands and other requests to the user's rules, then the judge.
        case checked
        /// `bypassPermissions`: everything is allowed.
        case bypass
    }

    static func policy(_ job: AgentJob) -> Policy {
        guard job.role == nil else { return .readOnly }
        switch job.permissionMode {
        case "bypassPermissions": return .bypass
        case "default", "acceptEdits", "auto", "": return .checked
        default: return .readOnly
        }
    }

    /// Antigravity's own mode for the policy. A saved CLI preference never applies: it's set on every session.
    static func mode(_ policy: Policy) -> String { policy == .readOnly ? "plan" : "accept-edits" }

    /// What the agent is told up front, after its role.
    static func commandNote(_ policy: Policy) -> String {
        switch policy {
        case .bypass: return ""
        case .readOnly, .checked:
            return """
            lastdrop runs you as a subagent, and nobody can answer permission prompts. Each shell command and each \
            action that needs approval is reviewed before it runs: first against the user's Claude Code permission \
            rules, then by a reviewer applying a safety policy to your task.\(policy == .readOnly ? " You are read-only: don't change files." : "") \
            A refusal is final for that command: don't retry it, rephrase it or work around it. Finish what you can \
            without it, and in your report name each refused command you needed and why, so the user can allow it.
            """
        }
    }

    /// A decision on one permission request, and the line the report's header shows when it is a refusal.
    struct Decision: Equatable, Sendable {
        var allow: Bool
        /// "swift test (not covered by your allow rules; judge: high risk, …)".
        var declined: String?
        /// The step shown while it runs ("Allowed by your rule Bash(git status:*): git status").
        var step: String
    }

    /// The action a permission request asks about: its tool, a short label, the command if it is one, and the
    /// input the judge reads.
    struct Action: Sendable {
        var tool: String
        var kind: String
        var label: String
        var command: String?
        var input: ACPClient.Payload

        init(_ params: [String: Any], directory: String) {
            let call = params.dict("toolCall") ?? [:]
            tool = call.string("name") ?? call.string("title") ?? "tool"
            kind = call.string("kind") ?? "other"
            var input = call.dict("rawInput") ?? call.dict("args") ?? [:]
            input.removeValue(forKey: "toolSummary")
            let command = input.string("CommandLine") ?? input.string("command")
            self.command = (tool == "run_command" || kind == "execute") ? command : nil
            if self.command != nil, input["Cwd"] == nil { input["Cwd"] = directory }
            self.input = .init(object: input)
            let name = tool
            let detail = AntigravityBackend.detail(input) ?? call.string("title")
            var label = self.command.map { $0.replacingOccurrences(of: "\n", with: " ") }
                ?? (detail.map { "\(name): \($0.replacingOccurrences(of: "\n", with: " "))" } ?? name)
            if label.count > 120 { label = String(label.prefix(119)) + "…" }
            self.label = label
        }
    }

    /// The user's rules, then the judge. `judge` runs the reviewer on a prompt (a seam for tests).
    static func decide(_ action: Action, policy: Policy, rules: PermissionRules, context: CommandJudge.Context,
                       policyText: () throws -> String, judge: (String) async -> CommandJudge.Verdict) async -> Decision {
        if policy == .bypass { return Decision(allow: true, step: "Allowed (bypass permissions): \(action.label)") }
        if let command = action.command {
            switch rules.check(command) {
            case .deny(let rule):
                return Decision(allow: false, declined: "\(action.label) (your deny rule \(rule))", step: "Declined by your rule \(rule): \(action.label)")
            case .ask(let rule):
                return Decision(allow: false, declined: "\(action.label) (your rule \(rule) asks first, and nobody can be asked)",
                                step: "Declined by your rule \(rule): \(action.label)")
            case .allow(let used) where policy == .checked:
                return Decision(allow: true, step: "Allowed by your rule \(used.joined(separator: ", ")): \(action.label)")
            default: break
            }
            // Claude Code's own read-only list: these never wait for the judge, in plan mode too.
            if let names = ReadOnlyCommands.check(command) {
                return Decision(allow: true, step: "Allowed as read-only (\(names.joined(separator: ", "))): \(action.label)")
            }
        } else if policy == .readOnly, ["edit", "delete", "move"].contains(action.kind) {
            return Decision(allow: false, declined: "\(action.label) (read-only agent)", step: "Declined (read-only agent): \(action.label)")
        }
        let why = action.command == nil ? "" : policy == .readOnly ? "read-only agent; " : "not covered by your allow rules; "
        let verdict: CommandJudge.Verdict
        do {
            let text = CommandJudge.prompt(policy: try policyText(), context: context,
                                           action: ["tool": action.tool, "arguments": action.input.object])
            verdict = await judge(text)
        } catch {
            verdict = .init(allow: false, failure: error.localizedDescription)
        }
        if verdict.allow { return Decision(allow: true, step: "Allowed by the reviewer: \(action.label)") }
        return Decision(allow: false, declined: "\(action.label) (\(why)\(verdict.summary))", step: "Declined by the reviewer: \(action.label)")
    }

    // MARK: Running

    static func run(_ job: AgentJob, _ events: AgentEvents) async -> SubagentRunner.Result {
        guard let executable = executable() else {
            return failure("Antigravity (`agy`) was not found on this Mac.", directory: job.cwd, unavailable: true)
        }
        return await run(job, events, executable: executable)
    }

    /// The most turns a run goes on for after `agy` ended its turn on a refusal.
    static let maxContinues = 4

    /// What the agent is told when `agy` ended its turn on a refusal, which a native agent would have gone past.
    static func continuePrompt(_ declined: String?, last: Bool) -> String {
        let what = declined.map { "lastdrop refused \($0)." } ?? "That action was refused and can't run here."
        let then = last ? "Don't run more commands: write your report now, naming what you needed and why."
            : "That is final for this command: don't retry it or work around it. Go on with the task without it and give your report, naming anything refused that you needed and why."
        return what + " " + then
    }

    /// The executable seam lets tests run a fake ACP agent; `judge` replaces the reviewer process, and `judgeModel`
    /// the judge chosen in Settings → Agents.
    static func run(_ job: AgentJob, _ events: AgentEvents, executable: String,
                    rules: PermissionRules? = nil, judgeModel: AgentJudge? = nil,
                    judge: (@Sendable (String) async -> CommandJudge.Verdict)? = nil) async -> SubagentRunner.Result {
        var directory = job.resume?.directory ?? job.cwd
        let policy = policy(job)
        let state = State(events: events, policy: policy, directory: directory)
        state.context = loadContext(job.resume?.sessionID) ?? CommandJudge.Context()
        state.context.instructions = job.instructions
        state.context.requests.append(job.prompt)
        if state.context.requests.count > 10 { state.context.requests.removeFirst(state.context.requests.count - 10) }
        let rules = rules ?? PermissionRules.load(cwd: job.cwd)
        let judges = JudgeProcesses()
        let judgeModel = judgeModel ?? AgentCatalog.load().judge(.antigravity) ?? CommandJudge.defaultJudge
        let judge: @Sendable (String) async -> CommandJudge.Verdict = judge ?? { prompt in
            await CommandJudge.judge(prompt, executable: executable, with: judgeModel,
                                     onProcess: { judges.add($0) }, onExit: { judges.remove($0) })
        }
        let policyText: @Sendable () throws -> String = { try CommandJudge.policy(readOnly: policy == .readOnly) }
        var client: ACPClient?
        defer { client?.stop(); judges.stopAll() }
        let start = Date()
        do {
            if job.resume == nil, job.worktree { directory = try AgentWorktree.create(in: directory, agentID: job.agentID).directory }
            state.directory = directory
            var environment = ProcessInfo.processInfo.environment
            environment[AgentRun.nestedMarker] = "1"
            let connection = ACPClient(executable: executable, arguments: ["acp"], directory: directory, environment: environment,
                                       name: "Antigravity", onNotification: { method, params in
                guard method == "session/update" else { return }
                state.receive(params.dict("update") ?? [:])
            }, onRequest: { method, params in
                guard method == "session/request_permission" else {
                    // lastdrop advertises no file system or terminal: agy runs its tools itself.
                    return .error(code: -32601, message: "lastdrop does not handle \(method).")
                }
                let action = Action(params, directory: state.directory)
                let options = params.array("options") ?? []
                let decision = await state.decide(action, policy: policy, rules: rules, policyText: policyText, judge: judge)
                let kind = decision.allow ? "allow_once" : "reject_once"
                let option = options.first { $0.string("kind") == kind }?.string("optionId") ?? (decision.allow ? "allow" : "deny")
                return .result(.init(object: ["outcome": ["outcome": "selected", "optionId": option]]))
            })
            client = connection
            try connection.start()
            events.process(connection.pid)
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            let initialized = try await connection.call("initialize", [
                "protocolVersion": 1,
                "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
                "clientInfo": ["name": "lastdrop", "version": version],
            ])
            let appends = initialized.dict("agentCapabilities")?.dict("_meta")?.dict("antigravity")?.dict("systemPrompt")?["append"] as? Bool == true
            let system = [job.instructions, commandNote(policy)].filter { !$0.isEmpty }.joined(separator: "\n\n")
            var params: [String: Any] = ["cwd": directory, "mcpServers": [[String: Any]]()]
            if appends { params["_meta"] = ["antigravity": ["systemPrompt": ["append": system]]] }
            let session: [String: Any]
            let sessionID: String
            if let resume = job.resume {
                params["sessionId"] = resume.sessionID
                session = try await connection.call("session/resume", params)
                sessionID = resume.sessionID
            } else {
                session = try await connection.call("session/new", params)
                guard let id = session.string("sessionId"), !id.isEmpty else { throw Failure("Antigravity's session/new has no sessionId.") }
                sessionID = id
            }
            state.sessionID = sessionID
            let offered = parseModels(acp: session)
            // A judge the account can't run refuses what it would judge, with that reason: never another model.
            state.judgeProblem = CommandJudge.problem(judgeModel, offered: offered)
            if let problem = state.judgeProblem { events.note("Command judge: " + problem) }
            let model = job.resume?.model ?? job.definition.model
            let selected = try slug(model: model, effort: job.resume?.effort ?? job.effort, models: offered)
            do { _ = try await connection.call("session/set_model", ["sessionId": sessionID, "modelId": selected]) } catch {
                throw Failure("Antigravity cannot use model \(selected) on the current account: \(error.localizedDescription)", unavailable: true)
            }
            _ = try await connection.call("session/set_mode", ["sessionId": sessionID, "modeId": mode(policy)])
            state.model = selected
            events.started("Antigravity", selected)

            var prompt = appends ? job.prompt : system + "\n\n" + job.prompt
            var stopReason = "end_turn"
            var continues = 0
            while true {
                state.beginTurn()
                let answer = try await connection.call("session/prompt", ["sessionId": sessionID, "prompt": [["type": "text", "text": prompt]]],
                                                        timeout: nil)
                state.endTurn(usage: answer.dict("usage") ?? [:])
                stopReason = answer.string("stopReason") ?? "end_turn"
                // `agy` ends its turn on a refusal; a native agent goes on and still reports. Go on, a few times.
                guard stopReason == "end_turn", let refused = state.endedOnRefusal, continues < maxContinues else { break }
                continues += 1
                events.step("Antigravity stopped after a refused command; continuing")
                prompt = continuePrompt(refused, last: continues == maxContinues || state.refusalsInARow >= 3)
            }
            saveContext(state.context, sessionID: sessionID)
            return state.finish(stopReason: stopReason, durationMs: Int(Date().timeIntervalSince(start) * 1000))
        } catch {
            saveContext(state.context, sessionID: state.sessionID)
            if let client, !client.process.isRunning { client.drainStderr() }
            let stderr = client?.stderr ?? ""
            let text = [error.localizedDescription, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            var result = failure(text, directory: directory, unavailable: (error as? Failure)?.unavailable == true)
            result.sessionID = state.sessionID
            result.model = state.model
            result.toolUses = state.toolCount
            result.declined = state.declined
            return result
        }
    }

    /// The judge's context for a session, kept so a follow-up's judge still sees the original task.
    private static func contextURL(_ sessionID: String) -> URL {
        LastDropPaths.agentsDir.appendingPathComponent("antigravity-\(sessionID).json")
    }

    private static func loadContext(_ sessionID: String?) -> CommandJudge.Context? {
        guard let sessionID, let data = try? Data(contentsOf: contextURL(sessionID)) else { return nil }
        return try? JSONDecoder().decode(CommandJudge.Context.self, from: data)
    }

    private static func saveContext(_ context: CommandJudge.Context, sessionID: String?) {
        guard let sessionID, !sessionID.isEmpty, let data = try? JSONEncoder().encode(context) else { return }
        LastDropPaths.ensure(LastDropPaths.agentsDir)
        try? data.write(to: contextURL(sessionID), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: contextURL(sessionID).path)
    }

    static func terminal(_ entry: AgentRegistry.Entry) -> String? {
        guard !entry.sessionID.isEmpty else { return nil }
        return "cd \(ClaudeSignIn.shellQuote(entry.directory)) || exit 1\nexec agy --conversation \(ClaudeSignIn.shellQuote(entry.sessionID))"
    }

    /// Reviewer processes still running when the run ends (stopped mid-check) are ended with it.
    final class JudgeProcesses: @unchecked Sendable {
        private let lock = NSLock()
        private var pids: [Int32] = []
        func add(_ pid: Int32) { lock.withLock { pids.append(pid) } }
        func remove(_ pid: Int32) { lock.withLock { pids.removeAll { $0 == pid } } }
        func stopAll() {
            // Only processes not yet reaped are listed, so a pid can't have been reused.
            for pid in lock.withLock({ pids }) { kill(pid, SIGTERM) }
        }
    }

    // MARK: Turn state

    /// What a run has seen: updates arrive on the client's reading thread, permission requests on their own tasks.
    final class State: @unchecked Sendable {
        let events: AgentEvents
        let policy: Policy
        var directory: String
        var model: String?
        var sessionID: String?
        var context = CommandJudge.Context()
        /// Why the chosen judge can't run on this account; set once the session lists its models.
        var judgeProblem: String? {
            get { lock.withLock { _judgeProblem } }
            set { lock.withLock { _judgeProblem = newValue } }
        }
        private var _judgeProblem: String?

        private let lock = NSLock()
        private var tools: [String: String] = [:]          // toolCallId → name
        private var results = Set<String>()
        private var segment = ""                            // agent text since the last tool call
        private var report = ""                             // the turn's last text segment
        private(set) var declined: [String] = []
        private var refusedAt: String?                      // the refusal the turn may have ended on
        private(set) var refusalsInARow = 0
        private var cache: [String: Decision] = [:]
        private var turns = 0
        private var input = 0.0, output = 0.0
        private var denials = 0

        init(events: AgentEvents, policy: Policy, directory: String) {
            self.events = events
            self.policy = policy
            self.directory = directory
        }

        var toolCount: Int { lock.withLock { tools.count } }

        func beginTurn() {
            lock.withLock { segment = ""; report = ""; refusedAt = nil }
        }

        func endTurn(usage: [String: Any]) {
            let text = lock.withLock { () -> String in
                turns += 1
                input += (usage.double("inputTokens") ?? 0) + (usage.double("cachedReadTokens") ?? 0)
                output += (usage.double("outputTokens") ?? 0) + (usage.double("thoughtTokens") ?? 0)
                let text = segment
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { report = text }
                segment = ""
                return text
            }
            if let item = SubagentRunner.transcriptItem(["type": "text", "text": text]) { events.item(item) }
        }

        /// The refusal the turn ended on, when nothing came after it.
        var endedOnRefusal: String? {
            lock.withLock { refusedAt }
        }

        func receive(_ update: [String: Any]) {
            switch update.string("sessionUpdate") {
            case "agent_message_chunk":
                guard let text = update.dict("content")?.string("text") else { return }
                lock.withLock {
                    segment += text
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { refusedAt = nil }
                }
            case "tool_call", "tool_call_update":
                guard let id = update.string("toolCallId") else { return }
                let name = update.string("name") ?? update.string("title") ?? "tool"
                var input = update.dict("rawInput") ?? update.dict("args") ?? [:]
                input.removeValue(forKey: "toolSummary")
                let status = update.string("status") ?? ""
                let (isNew, text) = lock.withLock { () -> (Bool, String) in
                    guard tools[id] == nil else { return (false, "") }
                    tools[id] = name
                    refusedAt = nil
                    context.record(tool: name, input: input)
                    let text = segment
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { report = text }
                    segment = ""
                    return (true, text)
                }
                if isNew {
                    if let item = SubagentRunner.transcriptItem(["type": "text", "text": text]) { events.item(item) }
                    var item = SubagentRunner.transcriptItem(["type": "tool_use", "id": id, "name": name, "input": input])!
                    let summary = AntigravityBackend.summary(name, input)
                    item["summary"] = summary
                    events.step(summary)
                    events.item(item)
                }
                guard status == "completed" || status == "failed" else { return }
                guard lock.withLock({ results.insert(id).inserted }) else { return }
                let raw = update.dict("rawOutput")
                let output = raw?.string("output")
                    ?? (update.array("content") ?? []).compactMap { $0.dict("content")?.string("text") ?? $0.string("newText") }.joined(separator: "\n")
                if let item = SubagentRunner.transcriptItem(["type": "tool_result", "tool_use_id": id, "content": output,
                                                             "is_error": status == "failed"]) { events.item(item) }
            default: break
            }
        }

        func decide(_ action: Action, policy: Policy, rules: PermissionRules, policyText: () throws -> String,
                    judge: (String) async -> CommandJudge.Verdict) async -> Decision {
            let problem = judgeProblem
            let input = (try? JSONSerialization.data(withJSONObject: action.input.object, options: [.sortedKeys]))
                .map { String(decoding: $0, as: UTF8.self) } ?? action.label
            let key = action.tool + "\u{1}" + input
            if let cached = lock.withLock({ cache[key] }) { return record(cached, cached: true) }
            if let command = action.command, policy != .bypass, ReadOnlyCommands.check(command) == nil { events.step("Checking: \(action.label)") }
            let context = lock.withLock { self.context }
            let decision = await AntigravityBackend.decide(action, policy: policy, rules: rules, context: context,
                                                           policyText: policyText, judge: { prompt in
                if let problem { return CommandJudge.Verdict(allow: false, failure: problem) }
                return await judge(prompt)
            })
            lock.withLock { cache[key] = decision }
            return record(decision, cached: false)
        }

        private func record(_ decision: Decision, cached: Bool) -> Decision {
            events.step(decision.step)
            events.note(decision.allow ? decision.step : "Declined: " + (decision.declined ?? decision.step))
            lock.withLock {
                if decision.allow { refusalsInARow = 0; return }
                denials += 1
                refusalsInARow += 1
                refusedAt = decision.declined
                if let line = decision.declined, !declined.contains(line) { declined.append(line) }
            }
            return decision
        }

        func finish(stopReason: String, durationMs: Int) -> SubagentRunner.Result {
            lock.withLock {
                let text = report.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : report
                var isError = false
                var message = text
                switch stopReason {
                case "end_turn", "max_tokens", "max_turn_requests":
                    if text.isEmpty {
                        isError = true
                        message = "Antigravity ended without writing a report."
                            + (declined.isEmpty ? "" : " lastdrop refused: \(declined.joined(separator: "; ")).")
                    }
                case "refusal": isError = true; message = "Antigravity refused to continue." + (text.isEmpty ? "" : "\n" + text)
                case "cancelled": isError = true; message = "The Antigravity turn was cancelled."
                default: isError = text.isEmpty; if isError { message = "Antigravity ended with \(stopReason)." }
                }
                // `agy` reports a spent quota as the model's own reply ("⚠ Individual quota reached. …") and ends the turn
                // normally. A short reply that is only that is a failure of the attempt, never a report.
                let limit = !isError && AntigravityBackend.isLimitNotice(text)
                if limit { isError = true }
                return .init(text: message, isError: isError, limitReached: limit, turns: turns, permissionDenials: denials,
                             toolUses: tools.count, durationMs: durationMs, inputTokens: Int(input), outputTokens: Int(output),
                             model: model, sessionID: sessionID, directory: directory, account: "Antigravity", declined: declined)
            }
        }
    }

    static func detail(_ input: [String: Any]) -> String? {
        ["CommandLine", "TargetFile", "Path", "AbsolutePath", "SearchPath", "SearchDirectory", "DirectoryPath", "Query", "Url", "Description",
         "command", "file_path", "query", "url"].compactMap { input.string($0) }.first
    }

    static func summary(_ tool: String, _ input: [String: Any]) -> String {
        guard let detail = detail(input) else { return tool }
        return String((tool + ": " + detail.replacingOccurrences(of: "\n", with: " ")).prefix(100))
    }

    // MARK: Processes and failures

    private struct Command {
        var status: Int32
        var stderr: String
    }

    private static func execute(_ executable: String, _ arguments: [String], directory: String?,
                                onLine: (String) -> Void) async throws -> Command {
        let process = Process(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory.map { URL(fileURLWithPath: $0) }
        var environment = ProcessInfo.processInfo.environment
        environment[AgentRun.nestedMarker] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let errors = Task.detached { String(decoding: (try? stderr.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self) }
        do {
            for try await line in stdout.fileHandleForReading.bytes.lines { onLine(line) }
        } catch {
            if process.isRunning { process.terminate() }
        }
        process.waitUntilExit()
        return Command(status: process.terminationStatus, stderr: await errors.value)
    }

    struct Failure: LocalizedError {
        var errorDescription: String?
        /// A failure about availability (the model or effort isn't offered), which an agent's fallback may take over.
        var unavailable = false
        init(_ message: String, unavailable: Bool = false) { errorDescription = message; self.unavailable = unavailable }
    }

    private static func message(_ text: String) -> String {
        let detail = String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(2000))
        if needsSignIn(text) {
            return "Antigravity needs sign-in. Open `agy` in Terminal and authenticate. \(detail)"
        }
        if modelUnavailable(text) { return "Antigravity cannot use this model on the current account. \(detail)" }
        return detail
    }

    static func needsSignIn(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("authentication required") || lower.contains("not authenticated") || lower.contains("not signed in")
            || lower.contains("unauthenticated") || lower.contains("token expired") || lower.contains("not logged in")
            || lower.contains("please log in") || lower.contains("please sign in") || lower.contains("invalid_grant")
            || lower.contains("auth_required")
    }

    static func modelUnavailable(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("model") && ["not available", "not supported", "not found", "not recognized", "not entitled", "access denied",
                                           "permission_denied", "does not have access", "requires a", "unknown model", "cannot use model"].contains { lower.contains($0) }
    }

    static func mentionsLimit(_ text: String) -> Bool {
        let lower = text.lowercased()
        return !modelUnavailable(text) && (lower.contains("resource_exhausted") || lower.contains("quota exhausted")
            || lower.contains("quota exceeded") || lower.contains("quota has been exhausted") || lower.contains("usage limit")
            || lower.contains("limit reached") || lower.contains("quota limit") || lower.contains("quota reached")
            || lower.contains("upgrade your subscription"))
    }

    /// A whole reply that is just a quota notice (short, and reading like one: a real report that merely
    /// mentions quotas or rate limits in prose isn't taken for a notice).
    static func isLimitNotice(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 600 else { return false }
        if trimmed.hasPrefix("⚠") { return true }
        let lower = trimmed.lowercased()
        let phrases = ["quota reached", "upgrade your subscription", "resets in", "usage limit reached"]
        return phrases.contains(where: lower.contains) || (lower.contains("hit your") && lower.contains("limit"))
    }

    static func failure(_ text: String, directory: String, unavailable: Bool = false) -> SubagentRunner.Result {
        .init(text: message(text), isError: true, limitReached: mentionsLimit(text), modelUnavailable: modelUnavailable(text),
              turns: 0, permissionDenials: 0, directory: directory, account: "Antigravity", unavailable: unavailable || needsSignIn(text))
    }
}
