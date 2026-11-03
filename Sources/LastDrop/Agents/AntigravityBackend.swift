import Foundation

/// Runs the official Antigravity CLI, leaving authentication and sessions with `agy`.
/// Stream fields: https://www.antigravity.google/docs/cli/headless/
/// Flags and effort: https://www.antigravity.google/docs/cli/reference/
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
        return try await models(executable: executable)
    }

    private static func models(executable: String) async throws -> [AgentModel] {
        var output = ""
        let command = try await execute(executable, ["models"], directory: LastDropPaths.helperDirectory) { output += $0 + "\n" }
        guard command.status == 0 else { throw Failure(message(command.stderr.isEmpty ? output : command.stderr)) }
        let models = parseModels(output)
        guard !models.isEmpty else { throw Failure("Antigravity returned no models. Run `agy models` in Terminal to check access.") }
        return models
    }

    /// `agy models` has no JSON flag: each model is a tab-separated slug and display name.
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

    /// Set the mode explicitly so a saved CLI preference cannot broaden the caller's permissions.
    static func arguments(_ job: AgentJob, slug: String) -> [String] {
        // `-p` takes a string, even before another flag. An empty value leaves prompts to stdin.
        var args = ["-p=", "--input-format", "stream-json", "--output-format", "stream-json", "--model", slug, "--disable-slash-commands"]
        // The documented flag overrides effort for this invocation without changing the CLI's settings.
        if let effort = suffix(slug) { args += ["--effort", effort] }
        switch job.role == nil ? job.permissionMode : "plan" {
        case "bypassPermissions": args += ["--mode", "accept-edits", "--dangerously-skip-permissions"]
        // Nobody can be asked headless, so "default" lets it edit, as a Claude agent's auto mode does.
        case "default", "acceptEdits", "auto": args += ["--mode", "accept-edits"]
        default: args += ["--mode", "plan"]
        }
        if let resume = job.resume { args += ["--conversation", resume.sessionID] }
        return args
    }

    static func run(_ job: AgentJob, _ events: AgentEvents) async -> SubagentRunner.Result {
        guard let executable = executable() else {
            return failure("Antigravity (`agy`) was not found on this Mac.", directory: job.cwd, unavailable: true)
        }
        return await run(job, events, executable: executable)
    }

    /// The executable seam lets tests exercise pipes, resume and signals without a signed-in CLI.
    static func run(_ job: AgentJob, _ events: AgentEvents, executable: String,
                    onLine: (String) -> Void = { _ in }) async -> SubagentRunner.Result {
        var directory = job.resume?.directory ?? job.cwd
        do {
            let model = job.resume?.model ?? job.definition.model
            let offered = suffix(model) == nil ? try await models(executable: executable) : []
            let selected = try slug(model: model, effort: job.resume?.effort ?? job.effort, models: offered)
            if job.resume == nil, job.worktree { directory = try AgentWorktree.create(in: directory, agentID: job.agentID).directory }
            func turn(_ job: AgentJob, prompt: String, in directory: String) async throws -> (Stream, SubagentRunner.Result) {
                var stream = Stream(model: selected, directory: directory, events: events)
                var input = try JSONSerialization.data(withJSONObject: ["event": "user", "message": ["content": prompt]])
                input.append(0x0A)
                let command = try await execute(executable, arguments(job, slug: selected), directory: directory,
                                                input: input, onProcess: events.process) { line in
                    onLine(line)
                    guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return }
                    stream.receive(event)
                }
                return (stream, stream.finish(exitCode: command.status, stderr: command.stderr))
            }
            let (first, result) = try await turn(job, prompt: job.instructions + "\n\n" + job.prompt, in: directory)
            // A native agent goes on after a denied action and still writes its report; `agy` ends its turn there.
            // Go on in the same conversation, once, with the same model, effort, mode and folder.
            guard first.endedAfterDenial, let session = result.sessionID else { return result }
            var next = job
            next.resume = .init(account: "Antigravity", directory: result.directory ?? directory, sessionID: session, model: selected, at: Date())
            events.step("Antigravity ended after a declined action; continuing")
            let (_, second) = try await turn(next, prompt: continuePrompt, in: result.directory ?? directory)
            var merged = second
            merged.toolUses += result.toolUses
            merged.turns += result.turns
            merged.durationMs += result.durationMs
            merged.inputTokens += result.inputTokens
            merged.outputTokens += result.outputTokens
            merged.permissionDenials += result.permissionDenials
            merged.declined = result.declined + second.declined.filter { !result.declined.contains($0) }
            return merged
        } catch {
            return failure(error.localizedDescription, directory: directory, unavailable: (error as? Failure)?.unavailable == true)
        }
    }

    /// What a run that ended on a declined action is told when it goes on.
    static let continuePrompt = "That action was declined and can't run here. Finish the task without it and give your report."

    static func terminal(_ entry: AgentRegistry.Entry) -> String? {
        guard !entry.sessionID.isEmpty else { return nil }
        return "cd \(ClaudeSignIn.shellQuote(entry.directory)) || exit 1\nexec agy --conversation \(ClaudeSignIn.shellQuote(entry.sessionID))"
    }

    private struct Command {
        var status: Int32
        var stderr: String
    }

    private static func execute(_ executable: String, _ arguments: [String], directory: String?, input: Data = Data(),
                                onProcess: (Int32) -> Void = { _ in }, onLine: (String) -> Void) async throws -> Command {
        let process = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory.map { URL(fileURLWithPath: $0) }
        var environment = ProcessInfo.processInfo.environment
        environment[AgentRun.nestedMarker] = "1"
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // An early CLI failure must report EPIPE instead of ending lastdrop with SIGPIPE.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        onProcess(process.processIdentifier)
        let errors = Task.detached {
            var tail = Data()
            while let data = try? stderr.fileHandleForReading.read(upToCount: 8192), !data.isEmpty {
                tail.append(data)
                if tail.count > 8192 { tail = Data(tail.suffix(8192)) }
            }
            return String(decoding: tail, as: UTF8.self)
        }
        let writer = Task.detached {
            defer { try? stdin.fileHandleForWriting.close() }
            try? stdin.fileHandleForWriting.write(contentsOf: input)
        }
        do {
            for try await line in stdout.fileHandleForReading.bytes.lines { onLine(line) }
        } catch {
            if process.isRunning { process.terminate() }
        }
        process.waitUntilExit()
        await writer.value
        return Command(status: process.terminationStatus, stderr: await errors.value)
    }

    struct Failure: LocalizedError {
        var errorDescription: String?
        /// A failure about availability (the model or effort isn't offered), which an agent's fallback may take over.
        var unavailable = false
        init(_ message: String, unavailable: Bool = false) { errorDescription = message; self.unavailable = unavailable }
    }

    private static func message(_ text: String) -> String {
        let lower = text.lowercased()
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
    }

    static func modelUnavailable(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("model") && ["not available", "not supported", "not found", "not recognized", "not entitled", "access denied", "permission_denied", "does not have access", "requires a"].contains { lower.contains($0) }
    }

    static func mentionsLimit(_ text: String) -> Bool {
        let lower = text.lowercased()
        return !modelUnavailable(text) && (lower.contains("resource_exhausted") || lower.contains("quota exhausted")
            || lower.contains("quota exceeded") || lower.contains("quota has been exhausted") || lower.contains("usage limit")
            || lower.contains("limit reached") || lower.contains("quota limit"))
    }

    private static func failure(_ text: String, directory: String, unavailable: Bool = false) -> SubagentRunner.Result {
        .init(text: message(text), isError: true, limitReached: mentionsLimit(text), modelUnavailable: modelUnavailable(text),
              turns: 0, permissionDenials: 0, directory: directory, account: "Antigravity", unavailable: unavailable || needsSignIn(text))
    }

    /// A turn's NDJSON state. DONE closes a step; the final result never duplicates its text item.
    struct Stream {
        var model: String
        var directory: String
        var events: AgentEvents
        private var sessionID: String?
        private var started = false
        private var invalidInit: String?
        private var final: [String: Any]?
        private var text: [Int: String] = [:]
        private var completed = Set<Int>()
        private var tools = Set<Int>()
        private var results = Set<Int>()
        private var permissionDenials = 0
        private var declined: [String] = []
        private var userTurns = 0
        private var turnUsage: [String: Double] = [:]

        init(model: String, directory: String, events: AgentEvents) {
            self.model = model
            self.directory = directory
            self.events = events
        }

        mutating func receive(_ event: [String: Any]) {
            switch event.string("event") {
            case "init":
                guard !started else { return }
                guard let id = event.string("conversation_id"), !id.isEmpty,
                      let cwd = event.dict("init")?.string("cwd"), !cwd.isEmpty else {
                    invalidInit = "Antigravity's init event has no conversation_id or cwd."
                    return
                }
                sessionID = id
                directory = cwd
                started = true
                events.started("Antigravity", model)
            case "step_update":
                guard let step = event.dict("step_update"), let index = step.double("step_index").map(Int.init), !completed.contains(index) else { return }
                let done = step.string("state") == "DONE"
                // A tool that failed (a denied permission, for one) ends in ERROR, with no DONE after it.
                let ended = done || step.string("state") == "ERROR"
                if done {
                    if step.string("step_type") == "user_input" { userTurns += 1 }
                    for key in ["input_tokens", "output_tokens", "cache_read_tokens"] {
                        if let count = step.dict("usage")?.double(key) { turnUsage[key, default: 0] += count }
                    }
                }
                if step.string("step_type") == "agent_response" {
                    text[index, default: ""] += step.string("text_delta") ?? ""
                    if done, let item = SubagentRunner.transcriptItem(["type": "text", "text": text.removeValue(forKey: index) ?? ""]) {
                        events.item(item)
                    }
                } else if step.string("step_type") == "tool", let info = step.dict("tool_info") {
                    let name = step.string("tool_name") ?? info.string("name") ?? "tool"
                    let id = "\(sessionID ?? step.string("conversation_id") ?? "agy"):\(index)"
                    if tools.insert(index).inserted {
                        let input = info.dict("parameters") ?? [:]
                        var item = SubagentRunner.transcriptItem(["type": "tool_use", "id": id, "name": name, "input": input])!
                        let summary = Self.summary(name, input)
                        item["summary"] = summary
                        events.step(summary)
                        events.item(item)
                    }
                    if ended, results.insert(index).inserted {
                        let error = info["error"]
                        let failed = error != nil && !(error is NSNull)
                        let output = Self.render(info["output"])
                        let errorText = Self.render(error)
                        let resultText = [output, errorText].filter { !$0.isEmpty }.joined(separator: "\n")
                        if failed, errorText.lowercased().contains("permission") {
                            permissionDenials += 1
                            let line = Self.summary(step.string("tool_name") ?? info.string("name") ?? "tool", info.dict("parameters") ?? [:])
                            if !declined.contains(line) { declined.append(line) }
                        }
                        if let item = SubagentRunner.transcriptItem(["type": "tool_result", "tool_use_id": id,
                                                                   "content": resultText, "is_error": failed]) { events.item(item) }
                    }
                }
                if ended { completed.insert(index) }
            case "result": final = event.dict("result")
            default: break
            }
        }

        /// The turn ended as a success with no report after a request nobody could answer was denied.
        var endedAfterDenial: Bool {
            guard final?.string("status") == "SUCCESS", started, invalidInit == nil,
                  (final?.string("response") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            return !declined.isEmpty || !((final?["denied_actions"] as? [[String: Any]]) ?? []).isEmpty
        }

        func finish(exitCode: Int32, stderr: String) -> SubagentRunner.Result {
            let reportedStatus = final?.string("status") ?? ""
            let status = reportedStatus.isEmpty ? "INCOMPLETE" : reportedStatus
            let error = Self.render(final?["error"])
            let response = final?.string("response") ?? ""
            let failed = status != "SUCCESS" || exitCode != 0 || !started || invalidInit != nil
            // With nobody to answer, a permission request is denied and `agy` ends its turn there, as a success with
            // an empty response: that is a failure to report, not an answer.
            let denied = (final?["denied_actions"] as? [[String: Any]] ?? []).compactMap { $0.string("display_name") ?? $0.string("action") }
            let declined = self.declined.isEmpty ? denied : self.declined
            let empty = !failed && response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let emptyText = "Antigravity ended without writing a report."
                + (declined.isEmpty ? "" : " It asked permission for \(declined.joined(separator: ", ")), which lastdrop declines because nobody can answer.")
            let details = [error, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            let diagnostic = details.isEmpty ? "Antigravity ended with status \(status). \(response)" : details
            let usage = final?.dict("usage")
            // Resumed result counters include previous turns; step usage covers only this invocation.
            let input = turnUsage["input_tokens"] ?? usage?.double("input_tokens") ?? 0
            let cached = turnUsage["cache_read_tokens"] ?? usage?.double("cache_read_tokens") ?? 0
            let output = turnUsage["output_tokens"] ?? usage?.double("output_tokens") ?? 0
            return .init(text: failed ? message(invalidInit ?? diagnostic) : empty ? emptyText : response, isError: failed || empty,
                         limitReached: failed && mentionsLimit(status + " " + diagnostic),
                         modelUnavailable: failed && modelUnavailable(diagnostic),
                         turns: userTurns > 0 ? userTurns : Int(final?.double("num_turns") ?? 0),
                         permissionDenials: permissionDenials, toolUses: tools.count,
                         durationMs: Int((final?.double("duration_seconds") ?? 0) * 1000),
                         inputTokens: Int(input + cached), outputTokens: Int(output),
                         model: model, sessionID: sessionID ?? final?.string("conversation_id"), directory: directory, account: "Antigravity", declined: declined,
                         unavailable: failed && needsSignIn(diagnostic))
        }

        private static func render(_ value: Any?) -> String {
            guard let value, !(value is NSNull) else { return "" }
            if let string = value as? String { return string }
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }

        private static func summary(_ tool: String, _ input: [String: Any]) -> String {
            let detail = ["CommandLine", "TargetFile", "AbsolutePath", "SearchPath", "SearchDirectory", "Query", "Url", "Description", "command", "file_path", "query", "url"]
                .compactMap { input.string($0) }.first
            guard let detail else { return tool }
            return String((tool + ": " + detail.replacingOccurrences(of: "\n", with: " ")).prefix(100))
        }
    }
}
