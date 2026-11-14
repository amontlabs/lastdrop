import Foundation

/// The plugin's tag and report header, ported from `hooks/register.tsx` (`tag`/`untag`, `delegatedHeader`): the ACP
/// server must read the same tag and answer with the same text the plugin's `delegatedTurn` gives today.
enum LastDropTag {
    static let open = "<!-- lastdrop "
    static let close = " -->"

    /// A delegated child's run, as its tag carries it.
    struct Run: Equatable {
        var id: String
        var agent: String?
        var model: String?
        var effort: String?
        var description: String?
        /// Not in today's tag; read when a plugin adds it, since ACP doesn't say which mode T3 runs the thread in.
        var permissionMode: String?
    }

    /// `untag`: the task without its last line `<!-- lastdrop {…} -->`, and the run it carries.
    static func untag(_ text: String) -> (task: String, run: Run)? {
        let trimmed = String(text.reversed().drop(while: \.isWhitespace).reversed())
        guard trimmed.hasSuffix(close), let start = trimmed.range(of: "\n\n" + open, options: .backwards) else { return nil }
        let end = trimmed.index(trimmed.endIndex, offsetBy: -close.count)
        guard start.upperBound <= end else { return nil }
        let json = trimmed[start.upperBound..<end]
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let id = object["id"] as? String else { return nil }
        func string(_ key: String) -> String? { object[key] as? String }
        return (String(trimmed[..<start.lowerBound]),
                Run(id: id, agent: string("agent"), model: string("model"), effort: string("effort"),
                    description: string("description"), permissionMode: string("permissionMode")))
    }

    /// `tag`, for tests and symmetry with the plugin.
    static func tag(_ task: String, _ run: [String: Any]) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: run, options: [.withoutEscapingSlashes, .sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "\(task)\n\n\(open)\(json)\(close)"
    }

    /// `delegatedHeader`: where the child's report came from, before its text. `effort` (ACP runs only) says what
    /// effort the run took when that isn't the one T3's menu chose: "Ran on claude-2 (claude-haiku-5-5) · effort high
    /// (max isn't offered)."
    static func header(_ line: [String: Any], effort: String? = nil) -> String {
        func text(_ key: String) -> String? {
            guard let value = line[key], !(value is NSNull) else { return nil }
            let string = value as? String ?? "\(value)"
            return string.isEmpty ? nil : string
        }
        func list(_ key: String) -> [String] { (line[key] as? [Any] ?? []).map { $0 as? String ?? "\($0)" } }
        let path = text("worktreePath")
        let branch = text("worktreeBranch")
        let worktree = path.map { " Worktree: \($0)\(branch.map { " (branch \($0))" } ?? "")." } ?? ""
        let declined = list("declined").isEmpty ? "" : "\nDeclined: \(list("declined").joined(separator: "; "))"
        let skipped = list("unavailable").isEmpty ? "" : ", \(list("unavailable").joined(separator: ", ")) unavailable"
        let note = effort.map { " · \($0)" } ?? ""
        guard let account = text("account") else {
            let effortLine = effort.map { "Ran at \($0)." } ?? ""
            let first = [effortLine, worktree.trimmingCharacters(in: .whitespaces)].filter { !$0.isEmpty }.joined(separator: " ")
            return first.isEmpty ? "" : "\(first)\n\n"
        }
        let model = text("model").map { " (\($0)\(skipped))" } ?? ""
        return "Ran on \(account)\(model)\(note).\(worktree)\(declined)\n\n"
    }
}

/// A turn's runner lines as ACP updates: each step and tool a `tool_call` with its kind, updated as its result
/// comes; what the agent says between tools as thinking; a move to another account or model as a step of its own.
/// The report itself is the answer's message, sent by the server.
final class TurnView: @unchecked Sendable {
    private let send: ([String: Any]) -> Void
    private let session: String
    private var counter = 0
    /// Steps shown but not yet matched to the tool item they announce, oldest first: (toolCallId, title).
    private var steps: [(id: String, title: String)] = []
    /// Tool item ids → their toolCallId.
    private var tools: [String: String] = [:]
    /// Tool calls not finished yet.
    private var open: [String] = []
    /// The agent's latest text: thinking once a tool follows it; at the end, only when it isn't the report.
    private var held: String?

    init(session: String, send: @escaping ([String: Any]) -> Void) {
        self.session = session
        self.send = send
    }

    func show(_ line: [String: Any]) {
        switch line["type"] as? String {
        case "step":
            guard let text = line["text"] as? String, !text.isEmpty else { return }
            flush()
            let id = next()
            steps.append((id, text))
            start(id, title: text)
        case "moved":
            flush()
            let account = line["account"] as? String ?? "an account"
            let reason = line["reason"] as? String ?? "it couldn't go on"
            // T3 shows a notice as a turn item of its own (it advertises `session.notices`).
            send(["sessionUpdate": "notice", "severity": "warning", "title": "Moved off \(account)", "description": reason])
        case "item":
            item(line)
        default:
            break
        }
    }

    private func item(_ line: [String: Any]) {
        switch line["kind"] as? String {
        case "text":
            flush()
            held = line["text"] as? String
        case "tool":
            flush()
            let summary = line["summary"] as? String ?? "tool"
            let itemID = line["id"] as? String ?? ""
            var update: [String: Any] = [:]
            if let raw = line["input"] as? String, !raw.isEmpty {
                update["rawInput"] = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) ?? raw
            }
            if let index = steps.firstIndex(where: { $0.title == summary }) {
                let id = steps.remove(at: index).id
                if !itemID.isEmpty { tools[itemID] = id }
                if !update.isEmpty {
                    update["sessionUpdate"] = "tool_call_update"
                    update["toolCallId"] = id
                    send(update)
                }
            } else {
                let id = next()
                if !itemID.isEmpty { tools[itemID] = id }
                start(id, title: summary, extra: update)
            }
        case "result":
            guard let itemID = line["id"] as? String, let id = tools[itemID] else { return }
            let failed = line["isError"] as? Bool ?? false
            var update: [String: Any] = ["sessionUpdate": "tool_call_update", "toolCallId": id, "status": failed ? "failed" : "completed"]
            if let text = line["text"] as? String, !text.isEmpty {
                update["content"] = [["type": "content", "content": ["type": "text", "text": text]]]
            }
            open.removeAll { $0 == id }
            send(update)
        default:
            break
        }
    }

    /// The turn ended: tool calls still open end with it, and the agent's last text shows unless it is the report.
    func close(report: String?, failed: Bool) {
        if let held, !held.isEmpty, report.map({ !$0.hasSuffix(held.trimmingCharacters(in: .whitespacesAndNewlines)) }) ?? true {
            thought(held)
        }
        held = nil
        for id in open { send(["sessionUpdate": "tool_call_update", "toolCallId": id, "status": failed ? "failed" : "completed"]) }
        open = []
    }

    private func flush() {
        if let held, !held.isEmpty { thought(held) }
        held = nil
    }

    private func thought(_ text: String) {
        send(["sessionUpdate": "agent_thought_chunk", "content": ["type": "text", "text": text.hasSuffix("\n") ? text : text + "\n\n"]])
    }

    private func start(_ id: String, title: String, extra: [String: Any] = [:]) {
        var update: [String: Any] = ["sessionUpdate": "tool_call", "toolCallId": id, "title": title, "kind": Self.kind(title),
                                     "status": "in_progress"]
        update.merge(extra) { a, _ in a }
        open.append(id)
        send(update)
    }

    private func next() -> String {
        counter += 1
        return "lastdrop-\(counter)"
    }

    /// ACP's tool kinds, from the tool's name before its detail ("Read: note.txt", "run_command: ls").
    static func kind(_ title: String) -> String {
        let name = (title.split(separator: ":", maxSplits: 1).first.map(String.init) ?? title).lowercased()
        func has(_ words: String...) -> Bool { words.contains { name.contains($0) } }
        if has("websearch", "web_search", "search_web", "webfetch", "fetch", "url", "browser") { return "fetch" }
        if has("delete", "remove", "rm") && !has("read") { return "delete" }
        if has("move", "rename") && !has("moved") { return "move" }
        if has("read", "view", "cat", "open") { return "read" }
        if has("edit", "write", "replace", "patch", "create", "notebook") { return "edit" }
        if has("bash", "command", "shell", "exec", "terminal", "run") { return "execute" }
        if has("grep", "glob", "search", "find", "list", "ls") { return "search" }
        if has("plan", "think", "reason") { return "think" }
        return "other"
    }
}

/// What T3 adds to each ACP prompt (`orchestrationInstructions.ts` `t3AcpPromptWithInstructions`, `adapter.ts`
/// ~7700-7820): on a session's first prompt, and when the mode or tools change, the user's text comes as
/// `<t3_code_instructions>\n…\n</t3_code_instructions>\n\n<user_request>\n<text>\n</user_request>`; every prompt
/// that isn't a slash command also gets a text block of its own, `<runtime_info>…</runtime_info>` and
/// `<pull_request_linking>…</pull_request_linking>`. A T3 Claude child gets those as its system prompt, which the
/// runner never sees, so none of it is the task.
enum T3Wrapper {
    static let instructionsOpen = "<t3_code_instructions>\n"
    static let requestOpen = "\n</t3_code_instructions>\n\n<user_request>\n"
    static let requestClose = "\n</user_request>"
    static let runtimeOpen = "<runtime_info>"

    /// The user's text of a prompt's text blocks.
    static func strip(blocks: [String]) -> String {
        blocks.filter { !isRuntime($0) }.map(strip).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    static func isRuntime(_ block: String) -> Bool {
        let trimmed = block.drop(while: \.isWhitespace)
        return trimmed.hasPrefix(runtimeOpen) || trimmed.hasPrefix("<pull_request_linking>")
    }

    /// One block's user text: the instructions wrapper taken off, and a runtime block run into it cut.
    static func strip(_ block: String) -> String {
        var text = block
        // The runtime block is its own block today; should T3 join them, it still trails the request.
        if let runtime = text.range(of: "\n\n" + runtimeOpen, options: .backwards),
           text[runtime.upperBound...].contains("</runtime_info>") {
            text = String(text[..<runtime.lowerBound])
        }
        if text.hasPrefix(instructionsOpen), let open = text.range(of: requestOpen),
           let close = text.range(of: requestClose, options: .backwards), close.lowerBound >= open.upperBound {
            text = String(text[open.upperBound..<close.lowerBound])
        }
        return text
    }
}
