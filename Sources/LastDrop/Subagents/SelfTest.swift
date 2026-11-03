import Foundation

/// `lastdrop --agent-selftest`: once per Claude Code version, checks on another account that everything a
/// subagent relies on still works, so an update that breaks it shows at once instead of at the next Agent
/// call. Writes one JSON line:
///
/// - `{"type":"ok","version"}`: passed now, or earlier on this version (`cached`).
/// - `{"type":"failed","version","step","text"}`: what broke; the plugin shows it until a run passes.
/// - `{"type":"skipped","reason"}`: nothing to test on (no account has room) or another session is testing.
///
/// It costs two one-line Haiku answers on that account. It also checks that Claude Code still has the
/// flags read-only roles and effort use, which costs nothing.
enum SelfTest {
    static func main() -> Never {
        Task.detached {
            AgentRun.emit(await run())
            exit(0)
        }
        dispatchMain()
    }

    struct Record: Codable { var version: String; var at: Date }

    static func run() async -> [String: Any] {
        // A subagent's own session has the plugin too; the session that started it tests.
        if ProcessInfo.processInfo.environment[AgentRun.nestedMarker] != nil { return ["type": "skipped", "reason": "inside a subagent"] }
        guard let claude = SubagentRunner.executable() else {
            return ["type": "failed", "version": "", "step": "find", "text": "Claude Code (`claude`) was not found on this Mac."]
        }
        let version = self.version(of: claude)
        func failed(_ step: String, _ text: String) -> [String: Any] {
            SubagentLog.write("selftest: \(step) failed on Claude Code \(version): \(text)")
            return ["type": "failed", "version": version, "step": step, "text": text]
        }
        if let record = (try? Data(contentsOf: LastDropPaths.selfTest)).flatMap({ try? JSONDecoder.lastdrop.decode(Record.self, from: $0) }),
           record.version == version {
            return ["type": "ok", "version": version, "cached": true]
        }

        // Read-only roles and the call's effort lean on these flags; `claude --help` lists them without a request.
        let help = output(of: claude, ["--help"])
        for flag in ["--disallowedTools", "--effort"] where !help.contains(flag) {
            return failed("flags", "Claude Code no longer has \(flag), which agents of lastdrop's list rely on")
        }

        LastDropPaths.ensure(LastDropPaths.support)
        let lockFD = open(LastDropPaths.selfTestLock.path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            return ["type": "skipped", "reason": "another session is running the self-test"]
        }
        defer { flock(lockFD, LOCK_UN); close(lockFD) }

        let config = ClaudeAccountsConfig.load()
        guard let account = await AgentRun.pick(config.ordered, config: config, own: SubagentAccounts.ownAccountUUID(), excluding: [],
                                                log: false) else {
            return ["type": "skipped", "reason": "no other Claude account has room"]
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lastdrop-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let items = Items()

        // 1. A ready process, as the app keeps one: switched to the run's model and mode, given an agent type.
        let first = SubagentRunner.Request(prompt: "Reply with exactly: lastdrop-ok", subagentType: "Explore", model: "haiku",
                                           permissionMode: "auto", sessionID: "")
        let started = await SubagentRunner.run(first, on: account, in: folder.path, claim: WarmPool.launch,
                                               check: { SubagentRunner.checkInit($0, subagentType: "Explore") },
                                               onStep: { _ in }, onItem: { items.add($0) })
        if started.isError { return failed("start", started.text) }
        guard started.text.contains("lastdrop-ok"), let sessionID = started.sessionID else {
            return failed("start", "the answer read \"\(started.text.prefix(200))\", not lastdrop-ok")
        }
        guard started.turns > 0, started.durationMs > 0, started.outputTokens > 0 else {
            return failed("start", "Claude Code's result event no longer carries num_turns, duration_ms or usage")
        }
        guard items.texts > 0 else { return failed("start", "Claude Code's assistant events no longer carry the agent's text") }

        // 2. A follow-up (SendMessage): the same session, folder and agent type.
        let next = SubagentRunner.Request(prompt: "Reply with exactly: lastdrop-ok-2", subagentType: "Explore", model: "haiku",
                                          permissionMode: "auto", sessionID: sessionID, resume: true)
        let resumed = await SubagentRunner.run(next, on: account, in: started.directory ?? folder.path,
                                               check: { SubagentRunner.checkInit($0, subagentType: "Explore") },
                                               onStep: { _ in })
        if resumed.isError { return failed("continue", resumed.text) }
        guard resumed.text.contains("lastdrop-ok-2") else {
            return failed("continue", "the answer read \"\(resumed.text.prefix(200))\", not lastdrop-ok-2")
        }

        // 3. TaskStop: the process ends when told to, as `lastdrop --agent-stop` tells it.
        let pid = PID()
        let stop = SubagentRunner.Request(prompt: "Reply with exactly: lastdrop-stop", model: "haiku", permissionMode: "auto",
                                          sessionID: UUID().uuidString.lowercased())
        let clock = Date()
        let stopped = await SubagentRunner.run(stop, on: account, in: folder.path, claim: { _ in nil },
                                               onProcess: { pid.value = $0 }, check: { _ in "stopping" }, onStep: { _ in })
        guard stopped.refused else { return failed("stop", "Claude Code sent no init event to stop it at") }
        guard pid.value > 0, kill(pid.value, 0) != 0, Date().timeIntervalSince(clock) < 30 else {
            return failed("stop", "Claude Code kept running after it was told to stop")
        }

        if let data = try? JSONEncoder.lastdrop.encode(Record(version: version, at: Date())) {
            try? data.write(to: LastDropPaths.selfTest, options: .atomic)
        }
        SubagentLog.write("selftest: passed on Claude Code \(version) with \(account.id)")
        return ["type": "ok", "version": version]
    }

    /// `claude --version`'s answer ("2.1.310 (Claude Code)"), or "" when it gave none.
    static func version(of claude: String) -> String {
        output(of: claude, ["--version"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What `claude` prints for `arguments`, or "" when it didn't run.
    static func output(of claude: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: LastDropPaths.helperDirectory)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private final class Items: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var texts: Int { lock.lock(); defer { lock.unlock() }; return count }
        func add(_ item: [String: Any]) {
            guard item["kind"] as? String == "text" else { return }
            lock.lock(); count += 1; lock.unlock()
        }
    }

    private final class PID: @unchecked Sendable {
        private let lock = NSLock()
        private var pid: Int32 = 0
        var value: Int32 {
            get { lock.lock(); defer { lock.unlock() }; return pid }
            set { lock.lock(); pid = newValue; lock.unlock() }
        }
    }
}
