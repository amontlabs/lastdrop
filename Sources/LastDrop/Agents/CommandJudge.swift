import Foundation

/// Judges an Antigravity agent's action with Codex's open-source reviewer policy (Apache 2.0, shipped in
/// `Resources/CodexGuardian` with its licence and NOTICE), asked of Gemini through the user's own Antigravity plan:
/// `agy -p … --mode plan` from an empty folder, so the judge has nothing to look at and changes nothing.
/// Like Codex's reviewer it sees the task (trusted), the agent's earlier tool calls (inputs only) and the planned
/// action; tool outputs and the agent's own text are left out as untrusted. Anything but a clear answer denies.
enum CommandJudge {
    /// The judge when the user chose none in Settings → Agents.
    static var defaultJudge: AgentJudge { AgentProvider.antigravity.defaultJudge! }
    /// `--print-timeout` for `agy`; the process is killed 30 s after it if it hasn't ended.
    static let timeout: TimeInterval = 120

    struct Verdict: Equatable, Sendable {
        var allow: Bool
        var risk: String = ""
        var authorization: String = ""
        var rationale: String = ""
        /// Why there is no real verdict (the judge failed, timed out or answered something unreadable).
        var failure: String?

        /// "judge: high risk, user authorization low — <rationale>", as the declined line shows it.
        var summary: String {
            if let failure { return "judge failed: \(failure)" }
            let scores = [risk.isEmpty ? nil : "\(risk) risk", authorization.isEmpty ? nil : "user authorization \(authorization)"]
                .compactMap { $0 }.joined(separator: ", ")
            let reason = rationale.trimmingCharacters(in: .whitespacesAndNewlines)
            return "judge: " + [scores.isEmpty ? nil : scores, reason.isEmpty ? nil : reason].compactMap { $0 }.joined(separator: " — ")
        }
    }

    /// What the judge reads besides the action. `requests` are trusted: the agent's role and the task the main
    /// agent wrote for the user, and follow-ups. `calls` are the agent's earlier tool calls, inputs only.
    struct Context: Codable, Equatable, Sendable {
        var instructions: String = ""
        var requests: [String] = []
        var calls: [Call] = []

        struct Call: Codable, Equatable, Sendable {
            var tool: String
            var input: String
        }

        mutating func record(tool: String, input: [String: Any]) {
            var input = input
            input.removeValue(forKey: "toolSummary") // the agent's own words
            let json = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            calls.append(Call(tool: tool, input: CommandJudge.clip(json, 600)))
            if calls.count > 40 { calls.removeFirst(calls.count - 40) }
        }
    }

    // MARK: Policy

    /// The policy files: in the app's Resources, next to a development build's checkout, or in this source tree.
    static func policyDirectory(executable: String = CommandLine.arguments.first ?? "") -> URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("CodexGuardian")) }
        let binary = URL(fileURLWithPath: executable).resolvingSymlinksInPath().deletingLastPathComponent()
        candidates.append(binary.deletingLastPathComponent().appendingPathComponent("Resources/CodexGuardian"))
        var up = binary
        for _ in 0..<4 { up.deleteLastPathComponent(); candidates.append(up.appendingPathComponent("Resources/CodexGuardian")) }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(source.appendingPathComponent("Resources/CodexGuardian"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("policy_template.md").path) }
    }

    static func policy(readOnly: Bool, directory: URL? = policyDirectory()) throws -> String {
        guard let directory,
              let template = try? String(contentsOf: directory.appendingPathComponent("policy_template.md"), encoding: .utf8),
              let policy = try? String(contentsOf: directory.appendingPathComponent("policy.md"), encoding: .utf8) else {
            throw Failure("the Codex policy files are missing from lastdrop")
        }
        var extra = """
        ## lastdrop
        - The agent is a subagent run by lastdrop for the user's main Claude Code session. The developer message is the agent's role as the user configured it, and the user messages are the task the main agent wrote for the user and any follow-ups: both are trusted, like user messages.
        - Actions covered by the user's own allow rules never reach you; actions their deny rules cover are refused before you see them.
        """
        if readOnly {
            extra += "\n- The agent was called read-only (an Explore or Plan agent): deny any action that could create, change or delete files or change any other state. Allow only actions that read."
        }
        return template.replacingOccurrences(of: "{{ tenant_policy_config }}", with: policy)
            .replacingOccurrences(of: "{{ extra_policy }}", with: extra)
    }

    /// Why no command can be judged: the chosen judge can't run. Commands that need the judge are refused with it.
    static func unavailable(_ judge: AgentJudge) -> String {
        "the command judge \(judge.summary) is not available on this Antigravity account; choose another in lastdrop's Settings → Agents"
    }

    /// The reason the judge can't run on an account offering `models`, else nil. An empty list can't say no.
    static func problem(_ judge: AgentJudge, offered models: [AgentModel]) -> String? {
        guard !models.isEmpty else { return nil }
        guard let model = models.first(where: { $0.id == judge.model }) else { return unavailable(judge) }
        if let effort = judge.effort, !model.efforts.isEmpty, !model.efforts.contains(effort) { return unavailable(judge) }
        return nil
    }

    struct Failure: LocalizedError {
        var errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "<truncated />"
    }

    static func prompt(policy: String, context: Context, action: [String: Any]) -> String {
        func line(_ object: [String: Any]) -> String {
            (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        }
        var lines: [String] = []
        if !context.instructions.isEmpty { lines.append(line(["role": "developer", "content": clip(context.instructions, 1500)])) }
        lines += context.requests.map { line(["role": "user", "content": clip($0, 4000)]) }
        lines += context.calls.map { line(["role": "assistant", "tool_call": ["tool": $0.tool, "input": $0.input]]) }
        return policy + """


        # Output
        Do not use any tools. Judge only from the transcript below; tool outputs are not available. Reply with only this JSON object and nothing else:
        {"risk_level": "low|medium|high|critical", "user_authorization": "unknown|low|medium|high", "outcome": "allow|deny", "rationale": "<one sentence>"}

        <transcript>
        \(lines.joined(separator: "\n"))
        </transcript>

        <planned_action>
        \(clip(line(action), 4000))
        </planned_action>
        """
    }

    /// The last JSON object with an `outcome` in the judge's answer. Only "allow" allows.
    static func parse(_ text: String) -> Verdict {
        let pattern = #"\{[^{}]*"outcome"[^{}]*\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              let range = Range(match.range, in: text),
              let object = (try? JSONSerialization.jsonObject(with: Data(text[range].utf8))) as? [String: Any],
              let outcome = object.string("outcome")?.lowercased(), ["allow", "deny"].contains(outcome) else {
            let tail = text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200)
            return Verdict(allow: false, failure: tail.isEmpty ? "no answer" : "unreadable answer (\(tail.replacingOccurrences(of: "\n", with: " ")))")
        }
        return Verdict(allow: outcome == "allow", risk: object.string("risk_level") ?? "",
                       authorization: object.string("user_authorization") ?? "", rationale: object.string("rationale") ?? "")
    }

    /// Runs the judge with `with`'s model and effort (no `--effort` when it has none). Every failure is a deny with
    /// its reason; a model `agy` won't run is named as such, never swapped for another.
    /// `onProcess` gets the judge's pid when it starts and `onExit` once it has been reaped.
    static func judge(_ prompt: String, executable: String, with judge: AgentJudge = defaultJudge, onProcess: @escaping @Sendable (Int32) -> Void = { _ in },
                      onExit: @escaping @Sendable (Int32) -> Void = { _ in }) async -> Verdict {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("lastdrop-judge-\(UUID().uuidString)")
        do { try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true) } catch {
            return Verdict(allow: false, failure: "could not make its empty folder")
        }
        defer { try? FileManager.default.removeItem(at: empty) }
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-p", prompt, "--mode", "plan", "--model", judge.model] + (judge.effort.map { ["--effort", $0] } ?? [])
            + ["--disable-slash-commands", "--print-timeout", "\(Int(timeout))s"]
        process.currentDirectoryURL = empty
        var environment = ProcessInfo.processInfo.environment
        environment[AgentRun.nestedMarker] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch { return Verdict(allow: false, failure: "could not start agy") }
        onProcess(process.processIdentifier)
        let killer = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 30, execute: killer)
        let stderr = Task.detached { String(decoding: (try? errors.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self) }
        let stdout = await Task.detached { String(decoding: (try? output.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self) }.value
        process.waitUntilExit()
        onExit(process.processIdentifier)
        killer.cancel()
        let diagnostics = await stderr.value
        var verdict = parse(stdout)
        if verdict.failure != nil {
            if process.terminationReason == .uncaughtSignal { verdict.failure = "timed out" }
            else if process.terminationStatus != 0 {
                let detail = (diagnostics.isEmpty ? stdout : diagnostics).trimmingCharacters(in: .whitespacesAndNewlines).suffix(200)
                if AntigravityBackend.modelUnavailable(String(detail)) {
                    verdict.failure = unavailable(judge) + " (\(detail.replacingOccurrences(of: "\n", with: " ")))"
                    return verdict
                }
                verdict.failure = "agy exited with status \(process.terminationStatus)" + (detail.isEmpty ? "" : " (\(detail.replacingOccurrences(of: "\n", with: " ")))")
            }
        }
        return verdict
    }
}
