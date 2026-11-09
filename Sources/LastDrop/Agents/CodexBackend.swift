import Foundation

/// Codex app-server, checked against CLI 0.160.0's stable schema (2026-10-27).
/// Wire sources: codex-rs/app-server-protocol/src/protocol/v2/{thread,turn,item,model,permissions}.rs;
/// lifecycle: https://learn.chatgpt.com/docs/app-server. Each run owns its connection and thread.
enum CodexBackend: AgentBackend {
    struct Failure: LocalizedError {
        var message: String
        /// A failure about availability (the model or effort isn't offered), which an agent's fallback may take over.
        var unavailable = false
        var errorDescription: String? { message }
        init(_ message: String, unavailable: Bool = false) { self.message = message; self.unavailable = unavailable }
    }

    static func executable(environment: [String: String] = ProcessInfo.processInfo.environment,
                           home: String = NSHomeDirectory()) -> String? {
        var candidates = (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        candidates += [home + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        let nvm = (environment["NVM_DIR"] ?? home + "/.nvm") + "/versions/node"
        candidates += ((try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? []).sorted().reversed().map { nvm + "/\($0)/bin/codex" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func models() async throws -> [AgentModel] {
        guard let path = executable() else { throw Failure("Codex (`codex`) was not found on this Mac.") }
        let server = CodexAppServer(executable: path, directory: LastDropPaths.helperDirectory, environment: ProcessInfo.processInfo.environment)
        try server.start()
        defer { server.stop() }
        return try await withTaskCancellationHandler {
            try await server.initialize()
            return try await models(server)
        } onCancel: { server.stop() }
    }

    static func models(_ server: CodexAppServer) async throws -> [AgentModel] {
        var result: [AgentModel] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            var params: [String: Any] = ["includeHidden": false, "limit": 100]
            if let cursor { params["cursor"] = cursor }
            let page = try await server.call("model/list", params)
            result += try decodeModels(page)
            cursor = page.string("nextCursor")
            if let cursor, !seen.insert(cursor).inserted { throw Failure("Codex repeated a model-list cursor.") }
        } while cursor != nil
        var ids = Set<String>()
        return result.filter { ids.insert($0.id).inserted }
    }

    static func decodeModels(_ page: [String: Any]) throws -> [AgentModel] {
        guard let data = page["data"] as? [[String: Any]] else { throw Failure("Codex returned an invalid model list.") }
        return try data.filter { $0["hidden"] as? Bool != true }.map { model in
            guard let id = model.string("model"), !id.isEmpty,
                  let efforts = model["supportedReasoningEfforts"] as? [[String: Any]] else {
                throw Failure("Codex returned a model without its slug or reasoning efforts.")
            }
            return AgentModel(id: id, name: model.string("displayName") ?? id,
                              efforts: efforts.compactMap { $0.string("reasoningEffort") },
                              defaultEffort: model.string("defaultReasoningEffort"))
        }
    }

    static func permissions(_ mode: String, autoReview: Bool = true) throws -> [String: Any] {
        let sandbox: String, approval: String
        switch mode {
        case "plan": sandbox = "read-only"; approval = "never"
        // Nobody can be asked headless, so "default" runs as auto does, as a Claude agent's does.
        case "default", "acceptEdits", "auto": sandbox = "workspace-write"; approval = "on-request"
        case "bypassPermissions": sandbox = "danger-full-access"; approval = "never"
        default: throw Failure("Codex doesn't recognize permission mode \(mode).")
        }
        return ["sandbox": sandbox, "approvalPolicy": approval,
                "approvalsReviewer": (mode == "auto" || mode == "default") && autoReview ? "auto_review" : "user"]
    }

    /// Codex splits override keys on every dot, without TOML unquoting (config/src/overrides.rs).
    /// Use a table value when a server name contains dots, preserving the caller's literal name.
    /// Servers Codex configures itself keep its own entry: a tool set up for both hosts (LCU) needs Codex's
    /// adapter, and Claude's copy would replace its command.
    static func mcpOverrides(_ root: [String: Any], native: Set<String> = []) -> (config: [String: Any], skipped: [String], kept: [String]) {
        var servers: [String: [String: Any]] = [:], skipped: [String] = [], kept: [String] = []
        for (name, value) in (root.dict("mcpServers") ?? [:]).sorted(by: { $0.key < $1.key }) {
            if native.contains(name) { kept.append(name); continue }
            guard let server = value as? [String: Any] else { skipped.append(name); continue }
            var mapped: [String: Any] = [:]
            switch server.string("type") ?? "stdio" {
            case "stdio":
                guard let command = server.string("command"), !command.isEmpty else { skipped.append(name); continue }
                mapped["command"] = command
                if let args = server["args"] as? [String] { mapped["args"] = args }
                if let env = server["env"] as? [String: String] { mapped["env"] = env }
                if let cwd = server.string("cwd") { mapped["cwd"] = cwd }
            case "http":
                guard let url = server.string("url"), let parsed = URL(string: url),
                      ["https", "http"].contains(parsed.scheme) else { skipped.append(name); continue }
                mapped["url"] = url
                if let headers = server["headers"] as? [String: String] { mapped["http_headers"] = headers }
            default: skipped.append(name); continue
            }
            servers[name] = mapped
        }
        if servers.keys.contains(where: { $0.contains(".") }) { return (["mcp_servers": servers], skipped, kept) }
        var config: [String: Any] = [:]
        for (name, fields) in servers {
            for (field, value) in fields { config["mcp_servers.\(name).\(field)"] = value }
        }
        return (config, skipped, kept)
    }

    /// The MCP servers Codex's own configuration defines for this folder. Older servers without
    /// `config/read` report none, so every caller server is translated as before.
    static func nativeMCPServers(_ server: CodexAppServer, cwd: String, events: AgentEvents) async -> Set<String> {
        do {
            let response = try await server.call("config/read", ["cwd": cwd], timeout: 15)
            return Set(response.dict("config")?.dict("mcp_servers")?.keys.map { $0 } ?? [])
        } catch {
            events.step("Codex didn't report its own MCP servers; using the caller's")
            return []
        }
    }

    /// Typed refusals let the server finish blocked tools. Unknown methods get an immediate answer too.
    static func decline(_ method: String) -> CodexAppServer.Reply {
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval": return .result(["decision": "decline"])
        case "item/permissions/requestApproval": return .result(["permissions": [:], "scope": "turn"])
        case "mcpServer/elicitation/request": return .result(["action": "cancel"])
        case "execCommandApproval", "applyPatchApproval": return .result(["decision": "denied"])
        case "item/tool/requestUserInput": return .result(["answers": [:]])
        case "item/tool/call": return .result(["success": false, "contentItems": [["type": "inputText", "text": "lastdrop cannot answer this tool request."]]])
        default: return .error(code: -32601, message: "lastdrop cannot answer \(method).")
        }
    }

    /// What a declined request asked for, as the caller reads it ("Bash: git push").
    static func describe(declined method: String, _ params: [String: Any]) -> String {
        switch method {
        case "item/commandExecution/requestApproval", "execCommandApproval":
            let command = params.string("command") ?? (params["command"] as? [String])?.joined(separator: " ") ?? ""
            return command.isEmpty ? "Bash" : "Bash: \(command.replacingOccurrences(of: "\n", with: " ").prefix(80))"
        case "item/fileChange/requestApproval", "applyPatchApproval": return "Edit files"
        case "item/permissions/requestApproval": return "Extra permissions"
        case "item/tool/call": return params.string("tool") ?? "Tool call"
        default: return method
        }
    }

    /// The requests the server asked and lastdrop declined, collected from its reading thread.
    final class Declined: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        var items: [String] { lock.lock(); defer { lock.unlock() }; return lines }
        func add(_ line: String) {
            lock.lock(); defer { lock.unlock() }
            if !lines.contains(line) { lines.append(line) }
        }
    }

    /// An error about the account or the model, not the work: signed out, or a model Codex doesn't have.
    static func unavailable(_ error: [String: Any]) -> Bool {
        if error.string("codexErrorInfo") == "unauthorized" { return true }
        let text = (error.string("message") ?? "").lowercased()
        return text.contains("model") && ["not found", "not supported", "does not exist", "not available", "unknown model"].contains { text.contains($0) }
    }

    static func limitReached(_ error: [String: Any], willRetry: Bool = false) -> Bool {
        !willRetry && error.string("codexErrorInfo") == "usageLimitExceeded"
    }

    static func run(_ job: AgentJob, _ events: AgentEvents) async -> SubagentRunner.Result {
        guard let path = executable() else {
            return .init(text: "Codex (`codex`) was not found on this Mac.", isError: true, limitReached: false, turns: 0, permissionDenials: 0,
                         unavailable: true)
        }
        return await run(job, events, executable: path, account: AgentPool.account(.codex, resume: job.resume))
    }

    /// An executable seam keeps lifecycle tests offline and independent of the user's Codex settings.
    static func run(_ job: AgentJob, _ events: AgentEvents, executable: String, account: Account = .main(.codex)) async -> SubagentRunner.Result {
        let startedAt = Date()
        var directory = job.resume?.directory ?? job.cwd
        var model = job.resume?.model ?? job.definition.model
        let effort = job.resume?.effort ?? job.effort
        var sessionID = job.resume?.sessionID
        var state = TurnState()
        var environment = ProcessInfo.processInfo.environment
        if let home = account.folder { environment["CODEX_HOME"] = home }
        let place = AgentPool.place(account)
        let declined = Declined()
        let server = CodexAppServer(executable: executable, directory: directory, environment: environment) { method, params in
            events.step("Declined Codex request: \(method)")
            declined.add(describe(declined: method, params) + " (needed approval)")
            return decline(method)
        }
        defer { server.stop() }
        func result(_ text: String, error: Bool, limit: Bool = false, unavailable: Bool = false, turns: Int = 0) -> SubagentRunner.Result {
            .init(text: text, isError: error, limitReached: limit, turns: turns, permissionDenials: state.denials,
                  toolUses: state.toolUses, durationMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                  inputTokens: state.inputTokens, outputTokens: state.outputTokens, model: model,
                  sessionID: sessionID, directory: directory, account: place, accountID: account.id, declined: declined.items, unavailable: unavailable)
        }
        do {
            try server.start()
            events.process(server.pid)
            return try await withTaskCancellationHandler {
                try await server.initialize()
                if let effort {
                    let available = try await models(server)
                    guard let selected = available.first(where: { $0.id == model }) else { throw Failure("Codex doesn't advertise model \(model); its reasoning effort cannot be validated.", unavailable: true) }
                    guard selected.efforts.contains(effort) else { throw Failure("Codex model \(model) doesn't support effort \(effort). Supported: \(selected.efforts.joined(separator: ", ")).", unavailable: true) }
                }
                if job.worktree && job.resume == nil {
                    directory = try AgentWorktree.create(in: directory, agentID: job.agentID).directory
                    events.step("Worktree: \(directory)")
                }
                // A read-only role gets the read-only sandbox, whatever the session's mode.
                var params = try permissions(job.role == nil ? job.permissionMode : "plan")
                params["cwd"] = directory
                params["model"] = model
                params["developerInstructions"] = job.instructions
                if let file = job.mcpConfig {
                    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file)))
                    guard let root = object as? [String: Any], root["mcpServers"] is [String: Any] else { throw Failure("lastdrop couldn't read the caller's MCP configuration.") }
                    let mcp = mcpOverrides(root, native: await nativeMCPServers(server, cwd: directory, events: events))
                    params["config"] = mcp.config
                    for name in mcp.skipped { events.step("Skipped unsupported Codex MCP server: \(name)") }
                    for name in mcp.kept { events.step("Kept Codex's own MCP server: \(name)") }
                }
                let method = job.resume == nil ? "thread/start" : "thread/resume"
                if let sessionID { params["threadId"] = sessionID }
                else { params["ephemeral"] = false }
                let response: [String: Any]
                do { response = try await server.call(method, params) }
                catch let error as CodexAppServer.RPCError where job.permissionMode == "auto" && Self.rejectsAutoReview(error) {
                    // Only an explicit configuration rejection is safe to retry; never replay a timeout.
                    params["approvalsReviewer"] = "user"
                    events.step("Codex auto review is unavailable; approval requests will be declined")
                    response = try await server.call(method, params)
                }
                guard let id = response.dict("thread")?.string("id"), !id.isEmpty else { throw Failure("Codex didn't return a thread ID.") }
                sessionID = id
                directory = response.string("cwd") ?? response.dict("thread")?.string("cwd") ?? directory
                model = response.string("model") ?? model
                var turnParams: [String: Any] = ["threadId": id, "input": [["type": "text", "text": job.prompt]]]
                if let effort { turnParams["effort"] = effort }
                let accepted = try await server.call("turn/start", turnParams)
                guard let turnID = accepted.dict("turn")?.string("id") else { throw Failure("Codex didn't return a turn ID.") }
                events.started(place, model)
                for await message in server.notifications {
                    let p = message.params
                    if message.method == "lastdrop/requestDeclined" {
                        state.denials += 1
                        if p.string("method") == "item/tool/requestUserInput" { throw Failure("Codex needs user input; lastdrop cannot answer it.") }
                        continue
                    }
                    guard p.string("threadId") == id else { continue }
                    if message.method == "thread/tokenUsage/updated", p.string("turnId") != turnID {
                        state.baseline = p.dict("tokenUsage")?.dict("total") ?? [:]
                        continue
                    }
                    if let eventTurn = p.string("turnId"), eventTurn != turnID { continue }
                    switch message.method {
                    case "item/started", "item/completed":
                        if let item = p.dict("item") { state.item(item, completed: message.method == "item/completed", events: events) }
                    case "thread/tokenUsage/updated": state.usage(p.dict("tokenUsage") ?? [:], resumed: job.resume != nil)
                    case "model/rerouted": model = p.string("toModel") ?? model
                    case "turn/plan/updated":
                        if let text = p.string("explanation"), !text.isEmpty { events.step("Plan: \(text)") }
                    case "error":
                        if p["willRetry"] as? Bool != true { state.error = p.dict("error") }
                    case "turn/completed":
                        guard let turn = p.dict("turn"), turn.string("id") == turnID else { continue }
                        for item in turn.array("items") ?? [] { state.item(item, completed: true, events: events) }
                        let error = turn.dict("error") ?? state.error
                        if turn.string("status") != "completed" {
                            return result(error?.string("message") ?? "Codex turn \(turn.string("status") ?? "failed").", error: true,
                                          limit: error.map { limitReached($0) } ?? false,
                                          unavailable: error.map { unavailable($0) } ?? false, turns: 1)
                        }
                        guard !state.answer.isEmpty else { return result("Codex completed without an answer.", error: true, turns: 1) }
                        return result(state.answer, error: false, turns: 1)
                    default: break
                    }
                }
                throw Failure("Codex app-server stopped without an answer.")
            } onCancel: { server.stop() }
        } catch {
            let data = (error as? CodexAppServer.RPCError)?.data as? [String: Any] ?? [:]
            let message = (error as? CodexAppServer.RPCError).map { ["message": $0.message].merging(data) { a, _ in a } } ?? [:]
            return result(error.localizedDescription, error: true, limit: limitReached(data) || state.error.map { limitReached($0) } == true,
                          unavailable: (error as? Failure)?.unavailable == true || unavailable(message)
                              || state.error.map { unavailable($0) } == true)
        }
    }

    private static func rejectsAutoReview(_ error: CodexAppServer.RPCError) -> Bool {
        let text = error.message.lowercased()
        return [-32600, -32602].contains(error.code) && ["auto_review", "approvalsreviewer", "approvals_reviewer"].contains(where: text.contains)
    }

    static func terminal(_ entry: AgentRegistry.Entry) -> String? {
        guard !entry.sessionID.isEmpty else { return nil }
        let home = entry.accountID.flatMap { AccountsConfig.load().account($0)?.folder }.map { "export CODEX_HOME=\(ClaudeSignIn.shellQuote($0))\n" } ?? ""
        return home + "cd \(ClaudeSignIn.shellQuote(entry.directory)) || exit 1\nexec codex resume \(ClaudeSignIn.shellQuote(entry.sessionID))"
    }

    /// Completed snapshots fit the append-only transcript. Starts show progress without duplicate rows.
    struct TurnState {
        private var completed = Set<String>()
        private var tools = Set<String>()
        private var finalAnswer: String?
        private var lastMessage = ""
        var answer: String { finalAnswer ?? lastMessage }
        var toolUses: Int { tools.count }
        var denials = 0
        var inputTokens = 0, outputTokens = 0
        var baseline: [String: Any] = [:]
        var error: [String: Any]?

        mutating func usage(_ usage: [String: Any], resumed: Bool) {
            guard let total = usage.dict("total") else { return }
            // Older servers without a resume baseline can only report the last response safely.
            let current = resumed && baseline.isEmpty ? usage.dict("last") ?? [:] : total
            inputTokens = max(0, Int(current.double("inputTokens") ?? 0) - Int(baseline.double("inputTokens") ?? 0))
            outputTokens = max(0, Int(current.double("outputTokens") ?? 0) - Int(baseline.double("outputTokens") ?? 0))
        }

        mutating func item(_ item: [String: Any], completed isComplete: Bool, events: AgentEvents) {
            guard let id = item.string("id"), !completed.contains(id) else { return }
            let type = item.string("type") ?? ""
            let summary: String?
            switch type {
            case "commandExecution": summary = "Bash: \(item.string("command") ?? "")"
            case "fileChange": summary = "Edit: \((item.array("changes") ?? []).compactMap { $0.string("path") }.joined(separator: ", "))"
            case "mcpToolCall": summary = "\(item.string("server") ?? "MCP")/\(item.string("tool") ?? "tool")"
            case "webSearch": summary = "WebSearch: \(item.string("query") ?? item.dict("action")?.string("query") ?? item.dict("action")?.string("url") ?? "")"
            case "dynamicToolCall", "collabAgentToolCall": summary = item.string("tool") ?? type
            default: summary = nil
            }
            if let summary, tools.insert(id).inserted { events.step(summary) }
            guard isComplete else { return }
            completed.insert(id)
            if let summary {
                // Never include thread config or MCP environment in transcript inputs.
                let input = item.filter { ["command", "cwd", "changes", "arguments", "server", "tool", "query", "action", "prompt"].contains($0.key) }
                let json = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) } ?? ""
                events.item(["kind": "tool", "id": id, "summary": summary, "input": cut(json, 2000)])
                var text = item.string("aggregatedOutput") ?? item.dict("error")?.string("message")
                if text == nil, let result = item["result"], !(result is NSNull),
                   let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .fragmentsAllowed]) {
                    text = String(decoding: data, as: UTF8.self)
                }
                let failed = item.string("status") == "failed" || item.string("status") == "declined"
                    || (item.double("exitCode").map { $0 != 0 } ?? false) || item["success"] as? Bool == false
                    || item.dict("error") != nil || item.dict("result")?["isError"] as? Bool == true
                events.item(["kind": "result", "id": id, "text": cut(text ?? item.string("status") ?? "completed", 2000), "isError": failed])
            } else {
                let text: String
                switch type {
                case "agentMessage":
                    text = item.string("text") ?? ""
                    lastMessage = text
                    if item.string("phase") == "final_answer" { finalAnswer = text }
                case "reasoning": text = (["Reasoning"] + (item["summary"] as? [String] ?? [])).joined(separator: "\n")
                case "plan": text = "Plan\n" + (item.string("text") ?? "")
                default: return
                }
                if !text.isEmpty { events.item(["kind": "text", "text": cut(text, 4000)]) }
            }
        }

        private func cut(_ text: String, _ limit: Int) -> String { text.count > limit ? String(text.prefix(limit)) + "…" : text }
    }
}
