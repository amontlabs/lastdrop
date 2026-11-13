import XCTest
@testable import LastDrop

/// Passing API errors (the 2026-11-13 Cloudflare 403s): what counts as one, how a run retries its session, and
/// how the work is handed on once the retries are spent. No real API call is made.
final class TransientErrorTests: LastDropTestCase {
    private let cloudflare = "Failed to authenticate. API Error: 403 Attention Required! | Cloudflare"

    override func tearDown() {
        SubagentRunner.retryPolicy = .standard
        SubagentRunner.nap = { await Nap.sleep($0) }
        SubagentRunner.hasTranscript = { session, request in
            let projects = request.endpoint.map { URL(fileURLWithPath: $0.directory).appendingPathComponent("projects") } ?? SessionTransfer.mainProjects
            return SessionTransfer.transcript(session, in: projects) != nil
        }
        AgentRun.sink = nil
        AgentRun.backends = { $0.backend }
        super.tearDown()
    }

    // MARK: The classifier

    func testTheIncidentsErrorsArePassingWhateverTheSignIn() {
        XCTAssertNotNil(TransientError.reason(cloudflare, status: 403, signInWorks: { false }))
        XCTAssertNotNil(TransientError.reason("API Error: 503 credential validation failed", status: nil, signInWorks: { false }))
        XCTAssertNotNil(TransientError.reason("API Error: 503 status code (no body)", status: 503, signInWorks: { false }))
    }

    func testOverloadedServerAndNetworkErrorsArePassing() {
        XCTAssertEqual(TransientError.reason("API Error: 529 {\"type\":\"overloaded_error\"}", status: 529, signInWorks: { false }),
                       "API overloaded (529)")
        XCTAssertNotNil(TransientError.reason("Overloaded", status: nil, signInWorks: { false }))
        XCTAssertNotNil(TransientError.reason("API Error: 500 Internal server error", status: 500, signInWorks: { false }))
        XCTAssertNotNil(TransientError.reason("API Error: 502 Bad Gateway", status: nil, signInWorks: { false }))
        XCTAssertNotNil(TransientError.reason("API Error: Connection error.", status: nil, signInWorks: { false }))
        XCTAssertNotNil(TransientError.reason("Error: read ECONNRESET", status: nil, signInWorks: { false }))
        XCTAssertNotNil(TransientError.reason("Request timed out.", status: nil, signInWorks: { false }))
    }

    func testAnAuthenticationFailureIsPassingOnlyWhileTheSignInWorks() {
        let text = "Failed to authenticate. API Error: 401 {\"type\":\"error\",\"error\":{\"type\":\"authentication_error\"}}"
        XCTAssertNotNil(TransientError.reason(text, status: 401, signInWorks: { true }))
        XCTAssertNil(TransientError.reason(text, status: 401, signInWorks: { false }))
        // Signed out is signed out, whatever the sign-in blob says.
        XCTAssertNil(TransientError.reason("Not logged in · Please run /login", status: nil, signInWorks: { true }))
        XCTAssertNil(TransientError.reason("OAuth token has been revoked. Please run /login.", status: 403, signInWorks: { true }))
    }

    func testTheSignInIsOnlyAskedAboutForAnAuthenticationFailure() {
        var asked = 0
        _ = TransientError.reason(cloudflare, status: 403, signInWorks: { asked += 1; return true })
        _ = TransientError.reason("Something broke.", status: nil, signInWorks: { asked += 1; return true })
        XCTAssertEqual(asked, 0)
        _ = TransientError.reason("Failed to authenticate.", status: 401, signInWorks: { asked += 1; return true })
        XCTAssertEqual(asked, 1)
    }

    func testOtherErrorsLimitsAndMissingModelsAreNotPassing() {
        XCTAssertNil(TransientError.reason("Something broke.", status: nil, signInWorks: { true }))
        let limit = SubagentRunner.classify(SubagentRunner.parse(["is_error": true, "result": "You've hit your session limit",
                                                                  "api_error_status": 429]), signInWorks: { true })
        XCTAssertTrue(limit.limitReached)
        XCTAssertNil(limit.transient)
        let model = SubagentRunner.classify(SubagentRunner.parse(["is_error": true, "result": "Fable 5.1 requires usage credits. Switch to another model."]),
                                            signInWorks: { true })
        XCTAssertNil(model.transient)
        let ok = SubagentRunner.classify(SubagentRunner.parse(["is_error": false, "result": "Cloudflare is a CDN."]), signInWorks: { true })
        XCTAssertNil(ok.transient, "only an error is ever passing")
    }

    /// The incident's result event: a passing error, not a sign-in to fix, and before any work a reason to fall back.
    func testTheIncidentsResultIsPassingAndFallsBackBeforeAnyWork() {
        var result = SubagentRunner.classify(SubagentRunner.parse(["type": "result", "is_error": true, "api_error_status": 403, "result": cloudflare]),
                                             signInWorks: { false })
        XCTAssertNotNil(result.transient)
        XCTAssertFalse(result.unavailable)
        XCTAssertFalse(result.limitReached)
        XCTAssertTrue(result.failedToStart)
        XCTAssertTrue(result.handsOn)
        result.toolUses = 3
        XCTAssertFalse(result.failedToStart, "after work, it is handed on, not skipped")
    }

    // MARK: The policy

    func testRetriesWaitTenThirtyNinetySecondsThenThreeMinutesJittered() {
        let policy = RetryPolicy.standard
        XCTAssertEqual((0..<4).compactMap { policy.delay(after: $0, random: 0) }, [10, 30, 90, 180])
        XCTAssertNil(policy.delay(after: 4, random: 0))
        XCTAssertEqual(policy.delay(after: 0, random: -1), 8)
        XCTAssertEqual(policy.delay(after: 3, random: 1), 216)
    }

    func testAStopCutsAWaitShort() async {
        let started = Date()
        Task { try? await Task.sleep(for: .milliseconds(50)); Nap.wakeAll() }
        await Nap.sleep(30)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    // MARK: Retrying a run

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [(SubagentRunner.Request, String)] = []
        private var _waits: [TimeInterval] = []
        var requests: [(SubagentRunner.Request, String)] { lock.lock(); defer { lock.unlock() }; return _requests }
        var waits: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return _waits }
        func add(_ r: SubagentRunner.Request, _ d: String) { lock.lock(); _requests.append((r, d)); lock.unlock() }
        func wait(_ t: TimeInterval) { lock.lock(); _waits.append(t); lock.unlock() }
    }

    private func failing(tools: Int = 1, session: String = "s1", directory: String = "/work/wt") -> SubagentRunner.Result {
        var r = SubagentRunner.Result(text: cloudflare, isError: true, limitReached: false, turns: 3, permissionDenials: 0, toolUses: tools,
                                      durationMs: 1000, sessionID: session, directory: directory)
        r.transient = "Cloudflare page instead of an API answer"
        return r
    }

    private func answered(session: String = "s1") -> SubagentRunner.Result {
        .init(text: "done", isError: false, limitReached: false, turns: 1, permissionDenials: 0, toolUses: 2, durationMs: 500, sessionID: session)
    }

    private func setUpRetries(transcript: Bool) -> Calls {
        let calls = Calls()
        SubagentRunner.retryPolicy = RetryPolicy(delays: [10, 30, 90, 180], jitter: 0)
        SubagentRunner.nap = { calls.wait($0) }
        SubagentRunner.hasTranscript = { _, _ in transcript }
        return calls
    }

    private let original = SubagentRunner.Request(prompt: "the task", subagentType: nil, model: "opus", effort: "high", permissionMode: "auto",
                                                  sessionID: "s1", mcpConfig: nil, systemPrompt: "role", disallowedTools: ["Edit"])

    /// Mid-run: the same session, account and folder, resumed and told to continue.
    func testAPassingErrorMidRunResumesTheSameSession() async {
        let calls = setUpRetries(transcript: true)
        var results = [failing(), answered()]
        let result = await SubagentRunner.runRetrying(original, on: ClaudeAccount(id: "claude-2"), in: "/work", label: "t3-x", onStep: { _ in },
                                                      once: { req, dir in calls.add(req, dir); return results.removeFirst() })
        XCTAssertFalse(result.isError)
        XCTAssertNil(result.transient)
        XCTAssertEqual(result.toolUses, 3, "the attempts' work adds up")
        XCTAssertEqual(result.durationMs, 1500)
        XCTAssertEqual(calls.waits, [10])
        let (retry, dir) = calls.requests[1]
        XCTAssertTrue(retry.resume)
        XCTAssertEqual(retry.sessionID, "s1")
        XCTAssertNil(retry.forkTo)
        XCTAssertEqual(retry.prompt, SubagentRunner.retryPrompt)
        XCTAssertEqual(dir, "/work/wt", "where it ran, a worktree included")
        XCTAssertEqual(retry.model, "opus")
        XCTAssertEqual(retry.effort, "high")
        XCTAssertEqual(retry.systemPrompt, "role")
        XCTAssertEqual(retry.disallowedTools, ["Edit"])
        XCTAssertFalse(retry.worktree)
        let log = (try? String(contentsOf: SubagentLog.fileOverride!, encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("t3-x on claude-2: temporary API error"), log)
        XCTAssertTrue(log.contains("retry 1 of 4 in 10 s, resuming session s1"), log)
        XCTAssertTrue(log.contains("retry 1 went through"), log)
    }

    /// At start, before Claude Code wrote anything: the run starts again as asked, under a new session id.
    func testAPassingErrorAtStartRunsTheRequestAgain() async {
        let calls = setUpRetries(transcript: false)
        var results = [failing(tools: 0), answered()]
        _ = await SubagentRunner.runRetrying(original, on: ClaudeAccount(id: "claude-2"), in: "/work", label: "a", onStep: { _ in },
                                             once: { req, dir in calls.add(req, dir); return results.removeFirst() })
        let (retry, dir) = calls.requests[1]
        XCTAssertEqual(retry.prompt, "the task")
        XCTAssertFalse(retry.resume)
        XCTAssertNotEqual(retry.sessionID, "s1")
        XCTAssertEqual(dir, "/work")
    }

    func testRetriesSpentLeaveThePassingErrorForTheCallerToHandOn() async {
        let calls = setUpRetries(transcript: true)
        let result = await SubagentRunner.runRetrying(original, on: ClaudeAccount(id: "claude-2"), in: "/work", label: "a", onStep: { _ in },
                                                      once: { [self] req, dir in calls.add(req, dir); return failing() })
        XCTAssertEqual(calls.requests.count, 5, "the run, then four retries")
        XCTAssertEqual(calls.waits, [10, 30, 90, 180])
        XCTAssertNotNil(result.transient)
        XCTAssertEqual(result.toolUses, 5)
        XCTAssertTrue(((try? String(contentsOf: SubagentLog.fileOverride!, encoding: .utf8)) ?? "").contains("4 retries spent, handing the work on"))
    }

    func testOtherErrorsAndStopsAreNotRetried() async {
        let calls = setUpRetries(transcript: true)
        let broke = SubagentRunner.Result(text: "Something broke.", isError: true, limitReached: false, turns: 1, permissionDenials: 0)
        _ = await SubagentRunner.runRetrying(original, on: ClaudeAccount(id: "c"), in: "/w", label: "a", onStep: { _ in },
                                             once: { req, dir in calls.add(req, dir); return broke })
        XCTAssertEqual(calls.requests.count, 1)
        _ = await SubagentRunner.runRetrying(original, on: ClaudeAccount(id: "c"), in: "/w", label: "b", stopped: { true }, onStep: { _ in },
                                             once: { [self] req, dir in calls.add(req, dir); return failing() })
        XCTAssertEqual(calls.requests.count, 2, "a stopped run isn't retried")
    }

    // MARK: Handing on in an agent's chain

    private func chain() -> AgentDefinition {
        .init(name: "build-hard", description: "Hard work.", provider: .antigravity, model: "claude-opus-5-5", effort: nil,
              fallbacks: [.init(provider: .codex, model: "gpt-6.1-sol", effort: nil)])
    }

    private func setUpChain() -> () -> [[String: Any]] {
        final class Lines: @unchecked Sendable { var all: [[String: Any]] = [] }
        let lines = Lines()
        AgentRun.sink = { lines.all.append($0) }
        AgentRun.backends = { $0 == .antigravity ? FakeAntigravity.self as any AgentBackend.Type : FakeCodex.self }
        FakeAntigravity.calls = []; FakeCodex.calls = []
        return { lines.all }
    }

    func testRetriesSpentPartwayHandTheWorkToTheNextAttempt() async throws {
        let lines = setUpChain()
        var after = failing(tools: 4, session: "claude-session", directory: "/tmp")
        after.account = "claude-2"
        FakeAntigravity.script = { _, events in events.started("claude-2", "opus"); return after }
        FakeCodex.script = { _, events in events.started("Codex", "gpt-6.1-sol")
            return .init(text: "finished", isError: false, limitReached: false, turns: 1, permissionDenials: 0, toolUses: 1, sessionID: "c") }
        let request = try JSONDecoder().decode(AgentRun.Request.self, from: Data(#"{"prompt":"p","cwd":"/tmp"}"#.utf8))
        await AgentRun.runDefined(chain(), request, agentID: "t3-" + UUID().uuidString, resume: nil, mcpConfig: nil)
        XCTAssertEqual(lines().compactMap { $0["type"] as? String }, ["started", "moved", "result"])
        XCTAssertTrue((lines()[1]["reason"] as? String ?? "").contains("temporary API error"))
        XCTAssertEqual(lines().last?["text"] as? String, "finished")
        let job = try XCTUnwrap(FakeCodex.calls.first)
        XCTAssertTrue(job.prompt.contains("after repeated temporary API errors"), job.prompt)
        XCTAssertTrue(job.prompt.contains("claude-session"))
    }

    func testRetriesSpentBeforeAnyWorkSkipToTheNextAttempt() async throws {
        let lines = setUpChain()
        FakeAntigravity.script = { [self] _, _ in failing(tools: 0) }
        FakeCodex.script = { _, events in events.started("Codex", "gpt-6.1-sol")
            return .init(text: "finished", isError: false, limitReached: false, turns: 1, permissionDenials: 0, toolUses: 1, sessionID: "c") }
        let request = try JSONDecoder().decode(AgentRun.Request.self, from: Data(#"{"prompt":"p","cwd":"/tmp"}"#.utf8))
        await AgentRun.runDefined(chain(), request, agentID: "t3-" + UUID().uuidString, resume: nil, mcpConfig: nil)
        XCTAssertEqual(lines().compactMap { $0["type"] as? String }, ["moved", "started", "result"])
        XCTAssertEqual(lines().last?["isError"] as? Bool, false)
        XCTAssertEqual(FakeCodex.calls.first?.prompt, "p", "nothing was done: the next attempt takes the task whole")
    }

    func testTheCallerReadsWhatHappenedWhenNothingCouldContinue() {
        let explained = AgentRun.explained(failing(), on: "claude-2")
        XCTAssertTrue(explained.text.hasPrefix("Claude Code kept failing on the claude-2 account with a temporary API error"))
        XCTAssertTrue(explained.text.hasSuffix(cloudflare))
        XCTAssertEqual(AgentRun.explained(explained, on: "claude-2").text, explained.text, "said once")
    }

    func testAnAccountWhoseRetriesWereSpentIsLeftAloneForAWhile() {
        XCTAssertFalse(AgentRegistry.isTroubled("claude-2"))
        AgentRegistry.markTroubled("claude-2")
        XCTAssertTrue(AgentRegistry.isTroubled("claude-2"))
        XCTAssertFalse(AgentRegistry.isTroubled("claude-2", now: Date().addingTimeInterval(AgentRegistry.troubledFor + 1)))
        XCTAssertFalse(AgentRegistry.isTroubled("main"))
    }

    // MARK: Threads

    private func resultLine(_ error: String?) -> Data {
        let object: [String: Any] = error.map { ["type": "result", "subtype": "success", "is_error": true, "api_error_status": 403, "result": $0] }
            ?? ["type": "result", "subtype": "success", "is_error": false, "result": "ok"]
        return try! JSONSerialization.data(withJSONObject: object) + Data([0x0A])
    }

    func testTheRelayTellsResultsAndPassingErrorsFromOtherLines() {
        let error = ThreadRelay.classify(resultLine(cloudflare), signInWorks: { false })
        XCTAssertTrue(error.isResult)
        XCTAssertNotNil(error.transient)
        XCTAssertEqual(ThreadRelay.classify(resultLine(nil), signInWorks: { false }).isResult, true)
        XCTAssertNil(ThreadRelay.classify(resultLine(nil), signInWorks: { false }).transient)
        let limit = try! JSONSerialization.data(withJSONObject: ["type": "result", "is_error": true, "result": "You've hit your session limit"])
        XCTAssertNil(ThreadRelay.classify(limit, signInWorks: { true }).transient, "the reaper handles limits")
        let streamed = Data(#"{"type":"stream_event","event":{"delta":{"text":"\"result\" Cloudflare"}}}"#.utf8)
        XCTAssertFalse(ThreadRelay.classify(streamed, signInWorks: { true }).isResult)
        XCTAssertTrue(ThreadRelay.endsWait(Data(#"{"type":"user","message":{"role":"user","content":"hi"}}"#.utf8)))
        XCTAssertTrue(ThreadRelay.endsWait(Data(#"{"type":"control_request","request_id":"1","request":{"subtype":"interrupt"}}"#.utf8)))
        XCTAssertFalse(ThreadRelay.endsWait(Data(#"{"type":"control_request","request_id":"2","request":{"subtype":"mcp_status"}}"#.utf8)))
    }

    func testTheRelayHoldsAPassingErrorRetriesAndStartsCountingAgainAfterATurnWentThrough() {
        var machine = ThreadRelay.Machine(policy: RetryPolicy(delays: [10, 30], jitter: 0))
        let line = resultLine(cloudflare)
        XCTAssertEqual(machine.fromChild(isResult: false, transient: nil, line: Data("x".utf8)), .forward)
        XCTAssertEqual(machine.fromChild(isResult: true, transient: "cf", line: line, random: 0), .hold(after: 10, generation: 1))
        XCTAssertEqual(machine.held, line)
        XCTAssertTrue(machine.fire(1))
        XCTAssertNil(machine.held, "the continued turn brings its own result")
        XCTAssertEqual(machine.fromChild(isResult: true, transient: "cf", line: line, random: 0), .hold(after: 30, generation: 2))
        XCTAssertTrue(machine.fire(2))
        XCTAssertEqual(machine.fromChild(isResult: true, transient: "cf", line: line, random: 0), .giveUp)
        XCTAssertEqual(machine.fromChild(isResult: true, transient: "cf", line: line, random: 0), .hold(after: 10, generation: 3))
        XCTAssertTrue(machine.fire(3))
        XCTAssertEqual(machine.fromChild(isResult: true, transient: nil, line: resultLine(nil)), .forward)
        XCTAssertEqual(machine.failures, 0)
    }

    func testT3SpeakingDuringAWaitLetsTheHeldResultThroughAndCancelsTheRetry() {
        var machine = ThreadRelay.Machine(policy: RetryPolicy(delays: [10], jitter: 0))
        let line = resultLine(cloudflare)
        guard case .hold(_, let generation) = machine.fromChild(isResult: true, transient: "cf", line: line, random: 0) else { return XCTFail() }
        XCTAssertNil(machine.fromParent(endsWait: false), "a control request passes alongside the wait")
        XCTAssertEqual(machine.fromParent(endsWait: true), line)
        XCTAssertFalse(machine.fire(generation))
        XCTAssertNil(machine.release())
    }

    func testLinesAreSplitWhereverTheChunksEnd() {
        var lines = ThreadRelay.Lines()
        XCTAssertEqual(lines.feed(Data("a\nb".utf8)), [Data("a\n".utf8)])
        XCTAssertEqual(lines.feed(Data("c\n\nd".utf8)), [Data("bc\n".utf8), Data("\n".utf8)])
        XCTAssertEqual(lines.rest(), Data("d".utf8))
        XCTAssertNil(lines.rest())
    }

    /// A fake claude behind the relay: its first turn ends at the incident's error, the relay holds it and tells the
    /// same process to continue, and T3 only sees the turn that went through.
    func testTheRelayRetriesATurnInTheSameProcess() throws {
        let (t3, folder) = try relay(script: """
        n=0
        while IFS= read -r line; do
          echo "$line" >> "$LOG"
          n=$((n+1))
          echo '{"type":"assistant","message":{"content":[{"type":"text","text":"turn '$n'"}]}}'
          if [ $n -eq 1 ]; then echo '\(String(decoding: resultLine(cloudflare).dropLast(), as: UTF8.self))'
          else echo '{"type":"result","subtype":"success","is_error":false,"result":"done '$n'"}'; fi
        done
        """, policy: RetryPolicy(delays: [0.05], jitter: 0))
        t3.send(#"{"type":"user","message":{"role":"user","content":"go"}}"#)
        let out = t3.read(until: { $0.contains("done 2") })
        XCTAssertFalse(out.contains("Attention Required"), out)
        XCTAssertTrue(out.contains("turn 1") && out.contains("turn 2"), out)
        let input = try String(contentsOf: folder.appendingPathComponent("input.log"), encoding: .utf8)
        XCTAssertTrue(input.contains(SubagentRunner.retryPrompt), input)
        t3.close()
        XCTAssertEqual(t3.exitCode(), 0)
    }

    /// Retries spent: T3 gets the error, the account is marked failing and the process ends, so the next message
    /// starts the thread elsewhere.
    func testTheRelayHandsTheThreadOnWhenRetriesAreSpent() throws {
        let (t3, _) = try relay(script: """
        while IFS= read -r line; do
          echo '\(String(decoding: resultLine(cloudflare).dropLast(), as: UTF8.self))'
        done
        """, policy: RetryPolicy(delays: [0.05], jitter: 0))
        t3.send(#"{"type":"user","message":{"role":"user","content":"go"}}"#)
        let out = t3.read(until: { $0.contains("Attention Required") })
        XCTAssertEqual(out.components(separatedBy: "Attention Required").count - 1, 1, "only the last error reaches T3")
        XCTAssertNotEqual(t3.exitCode(), 0)
        XCTAssertTrue(AgentRegistry.isTroubled("claude-2"))
    }

    // MARK: Relay harness

    private final class T3Side: @unchecked Sendable {
        let toRelay: Int32, fromRelay: Int32
        let exited = DispatchSemaphore(value: 0)
        var code: Int32 = -1
        init(toRelay: Int32, fromRelay: Int32) { self.toRelay = toRelay; self.fromRelay = fromRelay }

        func send(_ line: String) { _ = (line + "\n").withCString { write(toRelay, $0, strlen($0)) } }

        func read(until done: (String) -> Bool, timeout: TimeInterval = 10) -> String {
            var out = ""
            let deadline = Date().addingTimeInterval(timeout)
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !done(out), Date() < deadline {
                var fd = pollfd(fd: fromRelay, events: Int16(POLLIN), revents: 0)
                guard poll(&fd, 1, 200) > 0 else { continue }
                let n = Darwin.read(fromRelay, &buffer, buffer.count)
                if n <= 0 { break }
                out += String(decoding: buffer[0..<n], as: UTF8.self)
            }
            return out
        }

        func close() { Darwin.close(toRelay) }

        func exitCode() -> Int32 { _ = exited.wait(timeout: .now() + 10); return code }
    }

    private func relay(script: String, policy: RetryPolicy) throws -> (T3Side, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lastdrop-relay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let claude = folder.appendingPathComponent("claude")
        try Data("#!/bin/sh\n\(script)\n".utf8).write(to: claude)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        var down: [Int32] = [0, 0], up: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&down), 0)
        XCTAssertEqual(pipe(&up), 0)
        // T3's ends stay out of the fake claude, as fds 0 and 1 are the only ones T3 hands the real relay.
        for fd in down + up { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        let t3 = T3Side(toRelay: down[1], fromRelay: up[0])
        var env = ProcessInfo.processInfo.environment
        env["LOG"] = folder.appendingPathComponent("input.log").path
        let relay = ThreadRelay.start(claude.path, args: [], environment: env, account: ClaudeAccount(id: "claude-2"), label: "test",
                                      parentIn: down[0], parentOut: up[1], policy: policy) { code in
            t3.code = code
            t3.exited.signal()
        }
        XCTAssertNotNil(relay)
        let child = relay?.child ?? -1
        addTeardownBlock {
            if child > 0 { kill(child, SIGKILL) }   // never 0: that would signal the test's own process group
            Darwin.close(up[0]); Darwin.close(down[0]); Darwin.close(up[1])
        }
        return (t3, folder)
    }
}
