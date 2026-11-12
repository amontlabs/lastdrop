import Foundation

/// Runs one subagent turn as a headless Claude Code process (`claude -p`) on a given account, reading its
/// stream-json output as it comes.
enum SubagentRunner {
    struct Request: Equatable {
        var prompt: String
        var subagentType: String?
        var model: String?
        var effort: String?
        var worktree = false
        var permissionMode = "auto"
        /// The Claude Code session to start (`--session-id`), or to continue when `resume` is set.
        var sessionID: String
        var resume = false
        /// When set, forks the session to a new conversation under this id (`--resume <sessionID> --fork-session --session-id <forkTo>`).
        var forkTo: String?
        /// A `--mcp-config` file with the caller's own MCP servers.
        var mcpConfig: String?
        /// Added to Claude Code's system prompt (`--append-system-prompt`): an agent's role from lastdrop's list.
        var systemPrompt: String?
        /// An isolated endpoint profile; these runs never claim an account's ready process.
        var endpoint: EndpointProfile?
        /// Tools Claude Code must not offer (`--disallowedTools`), whatever the permission mode.
        var disallowedTools: [String] = []
    }

    /// The tools that change files, which a read-only role (Explore, Plan) never gets.
    static let editingTools = ["Edit", "Write", "NotebookEdit"]

    struct Result: Equatable {
        var text: String
        var isError: Bool
        /// Anthropic refused for usage limits; nothing to gain from retrying on the same account.
        var limitReached: Bool
        /// The account's plan doesn't include the model ("Fable 5.1 requires usage credits"); another model works.
        var modelUnavailable = false
        var turns: Int
        var permissionDenials: Int
        var toolUses = 0
        var durationMs = 0
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadInputTokens = 0
        var cacheCreationInputTokens = 0
        /// The usage of the run's last top-level API request (Claude Code's `message.usage`): the size of its context
        /// now, where the counts above add up every request. Nil when the run made none, or the backend can't say.
        var context: [String: Int]?
        var model: String?
        /// The session it ran as: a ready process comes with its own.
        var sessionID: String?
        /// Where it ran, as Claude Code reported it: a worktree's folder with `--worktree`.
        var directory: String?
        /// Refused before any work, by the caller's check of Claude Code's init (`check`).
        var refused = false
        /// Where it ran as its row shows it: the account ("Pro"), or the provider for other backends.
        var account: String?
        /// For an agent from lastdrop's list: the `Account.id` it ran on, which a follow-up returns to.
        var accountID: String?
        /// Short descriptions of the actions a provider asked approval for and lastdrop declined, as the caller reads them.
        var declined: [String] = []
        /// For an agent from lastdrop's list that ran in a worktree: where, and the branch when it has one.
        var worktreePath: String?
        var worktreeBranch: String?
        /// It failed before starting any work for a reason about availability that no limit or model flag says: the
        /// provider isn't installed, signed in or keyed, or doesn't take this effort. An agent's fallback may take it.
        var unavailable = false
        /// For an agent with fallbacks: the models tried before this one ran and skipped.
        var skipped: [String] = []

        /// Failed with nothing done, because the provider, account or model couldn't take it: what a fallback is for.
        /// Anything after a tool use, and any other error, is not.
        var failedToStart: Bool { isError && toolUses == 0 && (unavailable || limitReached || modelUnavailable) }
    }

    /// What a run needs to know Claude Code is the one it expects, from its `system`/`init` event: nil when
    /// it is, else why not. Every field read here is one a run relies on.
    static func checkInit(_ event: [String: Any], subagentType: String?) -> String? {
        for key in ["session_id", "cwd", "model", "agents"] where event[key] == nil {
            return "Claude Code's init event has no `\(key)`"
        }
        if let type = subagentType, !type.isEmpty, !(event["agents"] as? [String] ?? []).contains(type) {
            return "the \(type) agent type isn't available"
        }
        return nil
    }

    /// `claude -p` reads the prompt from stdin, so its length never meets the argument limit.
    static func arguments(_ request: Request) -> [String] {
        var args = ["-p", "--output-format", "stream-json", "--verbose", "--permission-mode", request.permissionMode]
        if let forkTo = request.forkTo {
            args += ["--resume", request.sessionID, "--fork-session", "--session-id", forkTo]
        } else {
            args += request.resume ? ["--resume", request.sessionID] : ["--session-id", request.sessionID]
        }
        // "general-purpose" is the plain session; any other type is an agent Claude Code knows
        // (Explore, Plan, or one from ~/.claude/agents, which every account's folder links to).
        if let type = request.subagentType, !type.isEmpty, type != "general-purpose" { args += ["--agent", type] }
        if let model = request.model, !model.isEmpty { args += ["--model", model] }
        if let effort = request.effort, !effort.isEmpty { args += ["--effort", effort] }
        if request.worktree { args.append("--worktree") }
        if !request.disallowedTools.isEmpty { args += ["--disallowedTools", request.disallowedTools.joined(separator: ",")] }
        // Claude accounts run in the main profile, which has the user's MCP servers; only an endpoint's own profile needs the copy.
        if let mcp = request.mcpConfig, request.endpoint != nil { args += ["--mcp-config", mcp] }
        if let prompt = request.systemPrompt, !prompt.isEmpty { args += ["--append-system-prompt", prompt] }
        if let endpoint = request.endpoint { args += endpoint.arguments }
        return args
    }

    /// What a ready process must have been started with to take this run; nil for a follow-up.
    static func warmSpec(_ request: Request, on account: ClaudeAccount, in directory: String,
                         environment base: [String: String]) -> WarmPool.Spec? {
        guard !request.resume, request.forkTo == nil, request.endpoint == nil, request.disallowedTools.isEmpty else { return nil }
        var args = arguments(request)
        if let i = args.firstIndex(of: "--session-id") { args.removeSubrange(i...i + 1) }
        return WarmPool.Spec(account: account.id, directory: directory, arguments: args,
                             environment: environment(for: account, from: base))
    }

    /// The calling session's environment, minus everything that ties it to that session and account.
    static func environment(for account: ClaudeAccount, from base: [String: String], endpoint: EndpointProfile? = nil) -> [String: String] {
        var env = account.runEnvironment(from: base.filter { key, _ in
            !(key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("CLAUDE_AGENT_") || key == "CLAUDECODE"
              || key == "CLAUDE_EFFORT" || key == "CLAUDE_PID"
              || key.hasPrefix("ANTHROPIC_") || key == "MAX_THINKING_TOKENS")
        })
        if let endpoint {
            env["CLAUDE_CONFIG_DIR"] = endpoint.directory
            env.merge(endpoint.environment) { _, new in new }
        }
        env[AgentRun.nestedMarker] = "1"
        return env
    }

    /// The native install first (it updates itself), then the `claude` on PATH.
    static func executable(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let fm = FileManager.default
        var candidates = [NSHomeDirectory() + "/.local/bin/claude"]
        candidates += (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" }
        if let exec = environment["CLAUDE_CODE_EXECPATH"] { candidates.append(exec) }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// The caller's MCP servers for `--mcp-config`: its user servers and the ones it set for this folder,
    /// from `~/.claude.json` (an account's own folder has neither). lastdrop's own entry is left out.
    static func mcpConfig(from claudeJSON: [String: Any], directory: String) -> [String: Any]? {
        var servers = claudeJSON.dict("mcpServers") ?? [:]
        for (key, value) in claudeJSON.dict("projects")?.dict(directory)?.dict("mcpServers") ?? [:] { servers[key] = value }
        servers["lastdrop"] = nil
        return servers.isEmpty ? nil : ["mcpServers": servers]
    }

    /// Runs to completion, calling `onStep` for each step the agent takes ("Read: note.txt"). `onProcess`
    /// gets Claude Code's pid, `check` its init event (a reason given stops the run, refused); `claim` is
    /// where a ready process comes from.
    static func run(_ request: Request, on account: ClaudeAccount, in directory: String,
                    claim: (WarmPool.Spec) -> WarmPool.Claimed? = WarmPool.claim,
                    executable override: String? = nil,
                    onProcess: @escaping @Sendable (Int32) -> Void = { _ in },
                    check: @escaping @Sendable ([String: Any]) -> String? = { _ in nil },
                    onStep: @escaping @Sendable (String) -> Void,
                    onItem: @escaping @Sendable ([String: Any]) -> Void = { _ in }) async -> Result {
        let base = ProcessInfo.processInfo.environment
        var output: FileHandle!, errors: FileHandle!
        var lines: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator!
        var process: Process?
        var sessionID = request.forkTo ?? request.sessionID
        var pid: Int32 = 0
        var earlyInit: [String: Any]?
        var switchedTo: String?
        /// The model the run started on, from its init event: what it reports, whatever else `modelUsage` lists.
        var startedOn: String?
        if let spec = warmSpec(request, on: account, in: directory, environment: base), let ready = claim(spec) {
            // Already started: switch it to this run's model and mode, then it only needs the prompt.
            pid = ready.pid
            onProcess(pid)   // TaskStop must work while the switches still wait for startup.
            var it = ready.output.bytes.lines.makeAsyncIterator()
            if await switched(ready.input, &it, model: request.model, permissionMode: request.permissionMode, initEvent: &earlyInit) {
                sessionID = ready.sessionID
                // The init event it started with names the model it was warmed for, not the one it switched to.
                if let model = request.model, !model.isEmpty { switchedTo = model }
                ready.input.write(WarmPool.userMessage(request.prompt))
                try? ready.input.close()
                output = ready.output
                errors = ready.errors
                lines = it
            } else {
                try? ready.input.close()
                terminate(ready.pid)
                lines = nil
                earlyInit = nil
                onStep("Starting Claude Code: the ready one couldn't switch")
            }
        }
        if output == nil {
            guard let claude = override ?? executable() else {
                return Result(text: "Claude Code (`claude`) was not found on this Mac.", isError: true, limitReached: false,
                              turns: 0, permissionDenials: 0, unavailable: true)
            }
            if request.endpoint == nil {
                SessionLedger.record(session: sessionID, account: account.id)
            }
            let started = Process()
            started.executableURL = URL(fileURLWithPath: claude)
            started.arguments = arguments(request)
            started.environment = environment(for: account, from: base, endpoint: request.endpoint)
            started.currentDirectoryURL = URL(fileURLWithPath: directory)
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            started.standardInput = stdin
            started.standardOutput = stdout
            started.standardError = stderr
            do { try started.run() } catch {
                return Result(text: error.localizedDescription, isError: true, limitReached: false, turns: 0, permissionDenials: 0)
            }
            pid = started.processIdentifier
            onProcess(pid)
            stdin.fileHandleForWriting.write(Data(request.prompt.utf8))
            try? stdin.fileHandleForWriting.close()
            output = stdout.fileHandleForReading
            errors = stderr.fileHandleForReading
            lines = output.bytes.lines.makeAsyncIterator()
            process = started
        }
        let errorHandle: FileHandle = errors
        let errText = Task.detached { String(decoding: errorHandle.readDataToEndOfFile(), as: UTF8.self) }

        var final: [String: Any]?
        var toolUses = 0
        var context: [String: Int]?
        var ranIn: String?
        var refusal: String?
        /// Its first init: true when the check refused it, the process stopped.
        func refuses(_ event: [String: Any]) -> Bool {
            guard ranIn == nil else { return false }
            ranIn = event.string("cwd") ?? directory
            var event = event
            if let switchedTo { event["model"] = switchedTo }
            startedOn = event.string("model")
            refusal = check(event)
            if refusal != nil { terminate(pid) }
            return refusal != nil
        }
        do {
            if let earlyInit, refuses(earlyInit) { lines = nil }
            reading: while let line = try await lines?.next() {
                guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
                switch event.string("type") {
                case "system" where event.string("subtype") == "init":
                    if let id = event.string("session_id"), !id.isEmpty {
                        sessionID = id
                        if request.endpoint == nil {
                            SessionLedger.record(session: id, account: account.id)
                        }
                    }
                    if refuses(event) { break reading }
                case "assistant":
                    // A subagent's requests (`parent_tool_use_id` set) are not the run's own context.
                    if event["parent_tool_use_id"] == nil || event["parent_tool_use_id"] is NSNull,
                       let usage = event.dict("message")?.dict("usage") {
                        context = contextUsage(usage)
                    }
                    for block in event.dict("message")?.array("content") ?? [] {
                        if block.string("type") == "tool_use" {
                            toolUses += 1
                            onStep(describe(tool: block.string("name") ?? "tool", input: block.dict("input") ?? [:]))
                        }
                        if let item = transcriptItem(block) { onItem(item) }
                    }
                case "user":
                    for block in event.dict("message")?.array("content") ?? [] {
                        if let item = transcriptItem(block) { onItem(item) }
                    }
                case "result":
                    final = event
                default:
                    break
                }
            }
        } catch {}
        process?.waitUntilExit()
        let stderrText = await errText.value
        if let refusal {
            return Result(text: refusal, isError: true, limitReached: false, turns: 0, permissionDenials: 0, sessionID: sessionID,
                          directory: ranIn, refused: true)
        }
        guard let final else {
            let message = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let endpoint = request.endpoint else {
                return Result(text: message.isEmpty ? "The subagent stopped without an answer." : String(message.suffix(2000)),
                              isError: true, limitReached: mentionsLimit(message), turns: 0, permissionDenials: 0,
                              sessionID: sessionID, directory: ranIn)
            }
            var result = parse(["is_error": true, "result": message.isEmpty ? "The subagent stopped without an answer." : String(message.suffix(2000))],
                               provider: endpoint.provider)
            result.sessionID = sessionID
            result.directory = ranIn
            return result
        }
        var result = parse(final, provider: request.endpoint?.provider)
        result.model = startedOn
        result.toolUses = toolUses
        result.context = context
        result.sessionID = sessionID
        result.directory = ranIn
        return result
    }

    /// One API request's usage, in the runner's line names.
    static func contextUsage(_ usage: [String: Any]) -> [String: Int] {
        ["inputTokens": Int(usage.double("input_tokens") ?? 0), "outputTokens": Int(usage.double("output_tokens") ?? 0),
         "cacheReadInputTokens": Int(usage.double("cache_read_input_tokens") ?? 0),
         "cacheCreationInputTokens": Int(usage.double("cache_creation_input_tokens") ?? 0)]
    }

    /// Stops a Claude Code process: asked to end, then made to after 5 s.
    static func terminate(_ pid: Int32) {
        guard pid > 0, kill(pid, SIGTERM) == 0 else { return }
        for _ in 0..<50 {
            if kill(pid, 0) != 0 { return }
            usleep(100_000)
        }
        kill(pid, SIGKILL)
    }

    /// Sends a taken-over process its switches and reads its output until each is answered: true when all
    /// succeeded. An init event among the lines before the answers is kept for the run's check.
    static func switched(_ input: FileHandle, _ lines: inout AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator,
                         model: String?, permissionMode: String, initEvent: inout [String: Any]?) async -> Bool {
        let switches = WarmPool.switches(model: model, permissionMode: permissionMode)
        var waiting = Set(switches.map(\.id))
        do {
            for s in switches { try input.write(contentsOf: s.data) }
            while !waiting.isEmpty, let line = try await lines.next() {
                guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
                if event.string("type") == "system", event.string("subtype") == "init" { initEvent = event }
                guard event.string("type") == "control_response", let response = event.dict("response"),
                      let id = response.string("request_id"), waiting.contains(id) else { continue }
                if response.string("subtype") != "success" {
                    SubagentLog.write("warm: a ready process refused \(id): \(response.string("error") ?? "")")
                    return false
                }
                waiting.remove(id)
            }
        } catch {
            return false
        }
        return waiting.isEmpty
    }

    /// One entry of the agent's transcript, as its row in the session shows it: what it said, each tool call
    /// with its input, each result. Long texts are cut; the whole session stays in the account's folder.
    static func transcriptItem(_ block: [String: Any]) -> [String: Any]? {
        func cut(_ text: String, _ limit: Int) -> String { text.count > limit ? String(text.prefix(limit)) + "…" : text }
        switch block.string("type") {
        case "text":
            guard let text = block.string("text"), !text.isEmpty else { return nil }
            return ["kind": "text", "text": cut(text, 4000)]
        case "tool_use":
            let input = block.dict("input") ?? [:]
            let json = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]))
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
            return ["kind": "tool", "id": block.string("id") ?? "", "summary": describe(tool: block.string("name") ?? "tool", input: input),
                    "input": cut(json, 2000)]
        case "tool_result":
            let text: String
            if let s = block["content"] as? String { text = s }
            else { text = (block.array("content") ?? []).compactMap { $0.string("text") }.joined(separator: "\n") }
            return ["kind": "result", "id": block.string("tool_use_id") ?? "", "text": cut(text, 2000),
                    "isError": block["is_error"] as? Bool ?? false]
        default:
            return nil
        }
    }

    /// Claude Code's result event (`--output-format json`, or the last stream-json line).
    static func parse(_ root: [String: Any], provider: AgentProvider? = nil) -> Result {
        var text = root.string("result") ?? ""
        let isError = root["is_error"] as? Bool ?? false
        let status = root.double("api_error_status").map(Int.init)
        var unauthorized = false
        var modelUnavailable = isError && Self.modelUnavailable(text)
        let limit: Bool
        if let provider, provider == .zai || provider == .openrouter {
            let errors = (root["errors"] as? [String] ?? []).joined(separator: "\n")
            if !errors.isEmpty { text += (text.isEmpty ? "" : "\n") + errors }
            // The model's absence is read from everything the endpoint said, `errors` included.
            modelUnavailable = isError && (Self.modelUnavailable(text) || endpointModelMissing(text, status: status))
            limit = isError && endpointLimit(text, status: status, provider: provider)
            if isError, status == 401 || hasCode(401, in: text) {
                unauthorized = true
                text = "\(provider.displayName) authentication failed. " + EndpointProfile.missingKey(provider) + "\n" + text
            } else if limit, provider == .openrouter {
                text = "OpenRouter credits exhausted. Add credits or raise this key's budget.\n" + text
            } else if isError, provider == .openrouter, text.lowercased().contains("management") {
                text = "OpenRouter management keys can't run models. Add a regular API key in lastdrop's Settings.\n" + text
            }
        } else {
            // A Claude account whose sign-in expired can't take the run, but another model or provider may.
            if isError, status == 401 { unauthorized = true }
            limit = isError && !modelUnavailable
                && (status == 429 || root.string("api_error") == "usage_limit_reached" || mentionsLimit(text))
        }
        let usage = root.dict("usage")
        var declined: [String] = []
        for denial in root["permission_denials"] as? [[String: Any]] ?? [] {
            let line = describe(tool: denial.string("tool_name") ?? "tool", input: denial.dict("tool_input") ?? [:]) + " (needed approval)"
            if !declined.contains(line) { declined.append(line) }
        }
        return Result(text: text, isError: isError,
                      limitReached: limit,
                      modelUnavailable: modelUnavailable,
                      turns: Int(root.double("num_turns") ?? 0),
                      permissionDenials: (root["permission_denials"] as? [Any])?.count ?? 0,
                      durationMs: Int(root.double("duration_ms") ?? 0),
                      inputTokens: Int((usage?.double("input_tokens") ?? 0) + (usage?.double("cache_read_input_tokens") ?? 0)
                                       + (usage?.double("cache_creation_input_tokens") ?? 0)),
                      outputTokens: Int(usage?.double("output_tokens") ?? 0),
                      cacheReadInputTokens: Int(usage?.double("cache_read_input_tokens") ?? 0),
                      cacheCreationInputTokens: Int(usage?.double("cache_creation_input_tokens") ?? 0),
                      declined: declined, unavailable: unauthorized)
    }

    /// Provider business codes survive Claude Code's flattened "API Error" strings.
    static func hasCode(_ code: Int, in text: String) -> Bool {
        text.range(of: "(?<![0-9])\(code)(?![0-9])", options: .regularExpression) != nil
    }

    /// An endpoint that doesn't have the model: Z.ai and OpenRouter answer with a 404 or a "model not found" text
    /// (OpenRouter's retired models: "No endpoints found for …").
    static func endpointModelMissing(_ text: String, status: Int?) -> Bool {
        let t = text.lowercased()
        return status == 404 || hasCode(404, in: text) || t.contains("no endpoints found") || t.contains("model not found")
            || t.contains("is not a valid model") || (t.contains("model") && t.contains("does not exist"))
    }

    static func endpointLimit(_ text: String, status: Int?, provider: AgentProvider) -> Bool {
        if provider == .zai {
            if [1302, 1305].contains(where: { hasCode($0, in: text) }) { return false }
            return ([1308, 1310] + Array(1316...1321)).contains { hasCode($0, in: text) }
        }
        let t = text.lowercased()
        return status == 402 || hasCode(402, in: text) || t.contains("billing_error") || t.contains("payment_required")
    }

    static func mentionsLimit(_ text: String) -> Bool {
        let t = text.lowercased()
        // Claude Code says "You've hit your session limit" / "weekly limit" / "Opus limit", not only "your limit".
        return t.contains("usage limit") || t.contains("limit reached") || t.contains("rate limit")
            || t.range(of: #"hit your (\w+ )?limit"#, options: .regularExpression) != nil
    }

    static func modelUnavailable(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("switch to another model") || t.contains("requires usage credits") || t.contains("not available on your plan")
    }

    /// One short line for a step, as a built-in agent's progress reads: "Read: note.txt", "Bash: Run the tests".
    static func describe(tool: String, input: [String: Any]) -> String {
        func file(_ key: String) -> String? { input.string(key).map { ($0 as NSString).lastPathComponent } }
        let detail: String?
        switch tool {
        case "Read", "Edit", "Write", "NotebookEdit": detail = file("file_path") ?? file("notebook_path")
        case "Bash": detail = input.string("description") ?? input.string("command")
        case "Grep", "Glob": detail = input.string("pattern")
        case "WebFetch": detail = input.string("url")
        case "WebSearch": detail = input.string("query")
        case "Agent", "Task": detail = input.string("description")
        default: detail = nil
        }
        guard let detail, !detail.isEmpty else { return tool }
        let line = detail.replacingOccurrences(of: "\n", with: " ")
        return line.count > 80 ? "\(tool): \(line.prefix(79))…" : "\(tool): \(line)"
    }
}
