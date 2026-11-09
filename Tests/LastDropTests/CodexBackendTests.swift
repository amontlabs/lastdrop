import XCTest
@testable import LastDrop

final class CodexBackendTests: XCTestCase {
    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testModelDiscoveryUsesModelSlugAndAdvertisedEfforts() throws {
        let page = try json(#"{"data":[{"id":"picker-id","model":"gpt-6-luna","displayName":"Luna","hidden":false,"supportedReasoningEfforts":[{"reasoningEffort":"low","description":"Fast"},{"reasoningEffort":"high","description":"Thorough"}],"defaultReasoningEffort":"low"},{"id":"hidden","model":"hidden","hidden":true}],"nextCursor":"page-2"}"#)
        XCTAssertEqual(try CodexBackend.decodeModels(page), [.init(id: "gpt-6-luna", name: "Luna", efforts: ["low", "high"], defaultEffort: "low")])
        XCTAssertThrowsError(try CodexBackend.decodeModels([:]))
    }

    func testPermissionModesKeepTheSandboxAndReviewerExplicit() throws {
        for (mode, sandbox, approval, reviewer) in [
            ("default", "workspace-write", "on-request", "auto_review"),
            ("plan", "read-only", "never", "user"),
            ("acceptEdits", "workspace-write", "on-request", "user"),
            ("auto", "workspace-write", "on-request", "auto_review"),
            ("bypassPermissions", "danger-full-access", "never", "user")
        ] {
            let params = try CodexBackend.permissions(mode)
            XCTAssertEqual(params["sandbox"] as? String, sandbox)
            XCTAssertEqual(params["approvalPolicy"] as? String, approval)
            XCTAssertEqual(params["approvalsReviewer"] as? String, reviewer)
        }
        XCTAssertThrowsError(try CodexBackend.permissions("misspelled"))
        XCTAssertEqual(try CodexBackend.permissions("auto", autoReview: false)["approvalsReviewer"] as? String, "user")
    }

    func testOnlyUsageLimitsExhaustTheAccount() throws {
        XCTAssertTrue(CodexBackend.limitReached(try json(#"{"message":"Quota exhausted","codexErrorInfo":"usageLimitExceeded"}"#)))
        for info in ["rateLimitExceeded", "sessionBudgetExceeded", "unauthorized", "badRequest"] {
            XCTAssertFalse(CodexBackend.limitReached(["message": "rate limit", "codexErrorInfo": info]))
        }
        XCTAssertFalse(CodexBackend.limitReached(["codexErrorInfo": "usageLimitExceeded"], willRetry: true))
    }

    func testMCPTranslatesBothTransportsAndSkipsSSE() throws {
        let config = try json(#"{"mcpServers":{"docs":{"command":"node","args":["server.js"],"env":{"TOKEN":"private"}},"remote":{"type":"http","url":"https://example.test/mcp","headers":{"Authorization":"secret"}},"legacy":{"type":"sse","url":"https://example.test/sse"}}}"#)
        let mapped = CodexBackend.mcpOverrides(config)
        XCTAssertEqual(mapped.config["mcp_servers.docs.command"] as? String, "node")
        XCTAssertEqual(mapped.config["mcp_servers.docs.args"] as? [String], ["server.js"])
        XCTAssertEqual(mapped.config["mcp_servers.docs.env"] as? [String: String], ["TOKEN": "private"])
        XCTAssertEqual(mapped.config["mcp_servers.remote.http_headers"] as? [String: String], ["Authorization": "secret"])
        XCTAssertEqual(mapped.skipped, ["legacy"])
        XCTAssertNil(mapped.config["mcp_servers.legacy.url"])
    }

    func testDottedMCPNamesUseLiteralTableKeys() {
        let mapped = CodexBackend.mcpOverrides(["mcpServers": ["docs.api": ["command": "node"], "other": ["type": "http", "url": "https://example.test/mcp"]]])
        let servers = mapped.config["mcp_servers"] as? [String: [String: Any]]
        XCTAssertEqual(servers?["docs.api"]?["command"] as? String, "node")
        XCTAssertEqual(servers?["other"]?["url"] as? String, "https://example.test/mcp")
        XCTAssertEqual(mapped.config.count, 1)
    }

    func testCodexOwnMCPServersAreNotOverridden() {
        let mapped = CodexBackend.mcpOverrides(["mcpServers": ["lcu": ["command": "node", "args": ["claude.mjs"]], "docs": ["command": "node"]]], native: ["lcu"])
        XCTAssertNil(mapped.config["mcp_servers.lcu.command"])
        XCTAssertNil(mapped.config["mcp_servers.lcu.args"])
        XCTAssertEqual(mapped.config["mcp_servers.docs.command"] as? String, "node")
        XCTAssertEqual(mapped.kept, ["lcu"])
    }

    func testCompletedItemsAreEmittedOnceAndOnlyFinalAnswerWins() throws {
        let log = CodexEventLog()
        var turn = CodexBackend.TurnState()
        let command = try json(#"{"id":"c1","type":"commandExecution","command":"printf ok","cwd":"/tmp","status":"completed","aggregatedOutput":"ok","exitCode":0}"#)
        turn.item(command, completed: false, events: log.events)
        turn.item(command, completed: true, events: log.events)
        turn.item(command, completed: true, events: log.events)
        turn.item(["id": "m1", "type": "agentMessage", "phase": "final_answer", "text": "answer"], completed: true, events: log.events)
        turn.item(["id": "m2", "type": "agentMessage", "phase": "commentary", "text": "afterthought"], completed: true, events: log.events)
        XCTAssertEqual(turn.answer, "answer")
        XCTAssertEqual(turn.toolUses, 1)
        XCTAssertEqual(log.items.map { $0["kind"] as? String }, ["tool", "result", "text", "text"])
        XCTAssertEqual(log.steps, ["Bash: printf ok"])
    }

    func testOtherToolsReasoningAndDisplayCaps() throws {
        let log = CodexEventLog()
        var turn = CodexBackend.TurnState()
        for item in [
            #"{"id":"f1","type":"fileChange","changes":[{"path":"/tmp/a.swift","kind":{"type":"update","movePath":null},"diff":"+ok"}],"status":"completed"}"#,
            #"{"id":"m1","type":"mcpToolCall","server":"docs","tool":"lookup","arguments":{"query":"Swift"},"status":"failed","error":{"message":"Offline"},"result":null}"#,
            #"{"id":"w1","type":"webSearch","query":"Swift","action":{"type":"search","query":"Swift"}}"#,
            #"{"id":"r1","type":"reasoning","summary":["Check the source"],"content":[]}"#,
            #"{"id":"p1","type":"plan","text":"Run the tests"}"#
        ] { turn.item(try json(item), completed: true, events: log.events) }
        turn.item(["id": "long", "type": "agentMessage", "text": String(repeating: "x", count: 5000)], completed: true, events: log.events)
        XCTAssertEqual(turn.toolUses, 3)
        XCTAssertEqual(log.steps, ["Edit: /tmp/a.swift", "docs/lookup", "WebSearch: Swift"])
        XCTAssertEqual(log.items[3]["isError"] as? Bool, true)
        XCTAssertEqual((log.items.last?["text"] as? String)?.count, 4001)
        XCTAssertEqual(turn.answer.count, 5000)
    }

    func testUsageSnapshotsSubtractResumeBaselineWithoutDoubleCountingSubsets() {
        var state = CodexBackend.TurnState()
        state.baseline = ["inputTokens": 100, "outputTokens": 10]
        let usage: [String: Any] = ["total": ["inputTokens": 160, "cachedInputTokens": 40, "outputTokens": 25, "reasoningOutputTokens": 5]]
        state.usage(usage, resumed: true)
        state.usage(usage, resumed: true)
        XCTAssertEqual(state.inputTokens, 60)
        XCTAssertEqual(state.outputTokens, 15)
    }

    func testTerminalQuotesDirectoryAndSession() throws {
        let entry = AgentRegistry.Entry(account: "Codex", directory: "/tmp/a'b", sessionID: "thread'1", at: Date())
        XCTAssertEqual(CodexBackend.terminal(entry), "cd \(ClaudeSignIn.shellQuote(entry.directory)) || exit 1\nexec codex resume \(ClaudeSignIn.shellQuote(entry.sessionID))")
    }

    func testNVMExecutableLookupWithoutPATH() throws {
        let root = try temporaryDirectory()
        let bin = root.appendingPathComponent(".nvm/versions/node/v22/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let file = bin.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        XCTAssertEqual(CodexBackend.executable(environment: ["PATH": "", "NVM_DIR": root.appendingPathComponent(".nvm").path], home: root.path), file.path)
    }

    func testLifecycleAnswersEveryRequestAndBuffersEarlyNotifications() async throws {
        let fake = try fixture("standard")
        let log = CodexEventLog()
        var request = job(in: fake.deletingLastPathComponent().path)
        let config = fake.deletingLastPathComponent().appendingPathComponent("mcp.json")
        try Data(#"{"mcpServers":{"docs":{"command":"node","args":["s.js"]},"sse":{"type":"sse","url":"https://example.test"},"lcu":{"command":"node","args":["claude.mjs"]}}}"#.utf8).write(to: config)
        request.mcpConfig = config.path
        let result = await CodexBackend.run(request, log.events, executable: fake.path)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(result.text, "ok 🦉")
        XCTAssertEqual(result.toolUses, 1)
        XCTAssertEqual(result.permissionDenials, 8)
        XCTAssertEqual(result.inputTokens, 100)
        XCTAssertEqual(result.outputTokens, 10)
        XCTAssertEqual(result.account, "Codex")
        XCTAssertEqual(result.sessionID, "thread-1")
        XCTAssertEqual(log.started, ["Codex/gpt-6-luna"])
        XCTAssertEqual(log.pids.count, 1)
        XCTAssertTrue(log.steps.contains("Skipped unsupported Codex MCP server: sse"))
        XCTAssertTrue(log.steps.contains("Kept Codex's own MCP server: lcu"))
        let requests = try requests(fake)
        let thread = try XCTUnwrap(requests.first { $0.string("method") == "thread/start" }?.dict("params"))
        XCTAssertEqual(thread.string("cwd"), request.cwd)
        XCTAssertEqual(thread.string("developerInstructions"), request.definition.instructions)
        XCTAssertEqual(thread.dict("config")?.string("mcp_servers.docs.command"), "node")
        XCTAssertNil(thread.dict("config")?["mcp_servers.lcu.command"])
        XCTAssertEqual(requests.first { $0.string("method") == "config/read" }?.dict("params")?.string("cwd"), request.cwd)
        XCTAssertEqual(requests.filter { $0.string("method") == "model/list" }.count, 2)
    }

    func testDeclinedRequestsAreDescribedForTheCaller() async throws {
        let fake = try fixture("standard")
        let result = await CodexBackend.run(job(in: fake.deletingLastPathComponent().path), CodexEventLog().events, executable: fake.path)
        XCTAssertTrue(["Bash", "Edit files", "Extra permissions", "mcpServer/elicitation/request"].map { $0 + " (needed approval)" }.allSatisfy(result.declined.contains), "\(result.declined)")
        XCTAssertEqual(Set(result.declined).count, result.declined.count)
        XCTAssertEqual(CodexBackend.describe(declined: "item/commandExecution/requestApproval", ["command": "git push\norigin"]), "Bash: git push origin")
        XCTAssertEqual(CodexBackend.describe(declined: "execCommandApproval", ["command": ["rm", "-rf", "x"]]), "Bash: rm -rf x")
    }

    func testAReadOnlyRoleGetsTheReadOnlySandboxWhateverTheModeIs() async throws {
        for mode in ["auto", "bypassPermissions", "acceptEdits"] {
            let fake = try fixture("standard")
            var request = job(in: fake.deletingLastPathComponent().path)
            request.permissionMode = mode
            request.role = "Plan"
            let result = await CodexBackend.run(request, CodexEventLog().events, executable: fake.path)
            XCTAssertFalse(result.isError, result.text)
            let thread = try XCTUnwrap(try requests(fake).first { $0.string("method") == "thread/start" }?.dict("params"))
            XCTAssertEqual(thread.string("sandbox"), "read-only", mode)
            XCTAssertEqual(thread.string("approvalPolicy"), "never", mode)
            XCTAssertEqual(thread.string("developerInstructions"), request.definition.instructions(role: "Plan"))
            XCTAssertTrue(try XCTUnwrap(thread.string("developerInstructions")).contains("step-by-step implementation plan"))
        }
    }

    func testResumeUsesSavedDirectoryModelEffortAndTokenBaseline() async throws {
        let fake = try fixture("resume")
        var request = job(in: fake.deletingLastPathComponent().path)
        request.resume = .init(account: "Codex", directory: request.cwd, sessionID: "thread-1", model: "gpt-6-luna", effort: "low", at: Date())
        request.cwd = "/does-not-exist"
        request.definition.model = "changed-model"
        request.effort = "unsupported"
        request.worktree = true
        let result = await CodexBackend.run(request, CodexEventLog().events, executable: fake.path)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(result.directory, request.resume?.directory)
        XCTAssertEqual(result.inputTokens, 100)
        XCTAssertEqual(result.outputTokens, 10)
        let requests = try requests(fake)
        XCTAssertFalse(requests.contains { $0.string("method") == "thread/start" })
        XCTAssertEqual(requests.first { $0.string("method") == "thread/resume" }?.dict("params")?.string("threadId"), "thread-1")
        XCTAssertEqual(requests.first { $0.string("method") == "turn/start" }?.dict("params")?.string("effort"), "low")
    }

    func testUnsupportedEffortFailsBeforeThreadCreation() async throws {
        let fake = try fixture("standard")
        var request = job(in: fake.deletingLastPathComponent().path)
        request.effort = "ultra"
        let log = CodexEventLog()
        let result = await CodexBackend.run(request, log.events, executable: fake.path)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("doesn't support effort ultra"))
        XCTAssertTrue(log.started.isEmpty)
        XCTAssertFalse(try requests(fake).contains { $0.string("method") == "thread/start" })
    }

    func testAutoReviewFallsBackOnlyAfterExplicitRejection() async throws {
        let fake = try fixture("auto")
        var request = job(in: fake.deletingLastPathComponent().path)
        request.permissionMode = "auto"
        let log = CodexEventLog()
        let result = await CodexBackend.run(request, log.events, executable: fake.path)
        XCTAssertFalse(result.isError, result.text)
        let starts = try requests(fake).filter { $0.string("method") == "thread/start" }
        XCTAssertEqual(starts.compactMap { $0.dict("params")?.string("approvalsReviewer") }, ["auto_review", "user"])
        XCTAssertTrue(log.steps.contains { $0.contains("auto review is unavailable") })
    }

    func testTerminalUsageErrorIsNotATransientRateLimit() async throws {
        for scenario in ["quota", "retry", "interrupted"] {
            let fake = try fixture(scenario)
            let result = await CodexBackend.run(job(in: fake.deletingLastPathComponent().path), CodexEventLog().events, executable: fake.path)
            XCTAssertTrue(result.isError)
            XCTAssertEqual(result.limitReached, scenario == "quota")
        }
    }

    func testUnanswerableQuestionReturnsBlocked() async throws {
        let fake = try fixture("question")
        let result = await CodexBackend.run(job(in: fake.deletingLastPathComponent().path), CodexEventLog().events, executable: fake.path)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("needs user input"))
    }

    func testReportedPIDStopsRunEvenWhenChildHoldsStdoutOpen() async throws {
        let fake = try fixture("stop")
        let log = CodexEventLog()
        var events = log.events
        events.started = { _, _ in if let pid = log.pids.first { kill(pid, SIGTERM) } }
        let started = Date()
        let result = await CodexBackend.run(job(in: fake.deletingLastPathComponent().path), events, executable: fake.path)
        XCTAssertTrue(result.isError)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testControlTimeoutClosesConnectionWithoutReplaying() async throws {
        let fake = try fixture("timeout")
        let server = CodexAppServer(executable: fake.path, directory: fake.deletingLastPathComponent().path, environment: ProcessInfo.processInfo.environment)
        try server.start()
        defer { server.stop() }
        try await server.initialize()
        do {
            _ = try await server.call("unanswered", [:], timeout: 0.05)
            XCTFail("Expected a timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        XCTAssertEqual(try requests(fake).filter { $0.string("method") == "unanswered" }.count, 1)
    }

    func testRPCUsageErrorKeepsStructuredData() async throws {
        let fake = try fixture("rpc-quota")
        let result = await CodexBackend.run(job(in: fake.deletingLastPathComponent().path), CodexEventLog().events, executable: fake.path)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.limitReached)
        XCTAssertEqual(result.text, "Quota exhausted")
        XCTAssertEqual(try requests(fake).filter { $0.string("method") == "thread/start" }.count, 1)
    }

    func testInvalidProtocolFailsPendingRequestPromptly() async throws {
        let fake = try fixture("invalid")
        let started = Date()
        let result = await CodexBackend.run(job(in: fake.deletingLastPathComponent().path), CodexEventLog().events, executable: fake.path)
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.text, "Codex returned invalid protocol JSON.")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testNamedWorktreeExistsBeforeThreadStart() async throws {
        let fake = try fixture("standard")
        let directory = fake.deletingLastPathComponent().path
        try git(["init", "--quiet", directory])
        try git(["-C", directory, "-c", "user.name=Test", "-c", "user.email=test@example.test", "commit", "--quiet", "--allow-empty", "-m", "Initial"])
        var request = job(in: directory)
        request.worktree = true
        let result = await CodexBackend.run(request, CodexEventLog().events, executable: fake.path)
        let worktree = try XCTUnwrap(result.directory)
        defer { try? git(["-C", directory, "worktree", "remove", "--force", worktree]) }
        XCTAssertFalse(result.isError, result.text)
        XCTAssertNotEqual(worktree, directory)
        XCTAssertTrue(worktree.hasSuffix("/.claude/worktrees/agent-test"))
        XCTAssertEqual(AgentRun.branch(of: worktree), "worktree-agent-test")
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree + "/.git"))
        XCTAssertEqual(try requests(fake).first { $0.string("method") == "thread/start" }?.dict("params")?.string("cwd"), worktree)
    }

    func testLiveCodexStartAndResume() async throws {
        guard ProcessInfo.processInfo.environment["LASTDROP_LIVE_CODEX"] == "1" else {
            throw XCTSkip("Set LASTDROP_LIVE_CODEX=1 for the two-turn Codex check.")
        }
        let directory = try temporaryDirectory().path
        var request = job(in: directory)
        request.permissionMode = "plan"
        let first = await CodexBackend.run(request, CodexEventLog().events)
        XCTAssertFalse(first.isError, first.text)
        XCTAssertEqual(first.text.trimmingCharacters(in: .whitespacesAndNewlines), "ok")
        guard !first.isError else { return }
        let session = try XCTUnwrap(first.sessionID)
        request.resume = .init(account: "Codex", directory: first.directory ?? directory, sessionID: session,
                               model: first.model, effort: "low", at: Date())
        let second = await CodexBackend.run(request, CodexEventLog().events)
        XCTAssertFalse(second.isError, second.text)
        XCTAssertEqual(second.text.trimmingCharacters(in: .whitespacesAndNewlines), "ok")
        XCTAssertEqual(second.sessionID, session)
    }

    private func job(in directory: String) -> AgentJob {
        .init(agentID: "test", definition: .init(name: "codex-test", description: "Be concise.", provider: .codex, model: "gpt-6-luna"),
              prompt: "Reply with exactly: ok", cwd: directory, effort: "low", permissionMode: "default", worktree: false)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lastdrop-codex-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func requests(_ fixture: URL) throws -> [[String: Any]] {
        try String(contentsOf: fixture.appendingPathExtension("requests"), encoding: .utf8).split(separator: "\n").map { try json(String($0)) }
    }

    private func fixture(_ scenario: String) throws -> URL {
        let file = try temporaryDirectory().appendingPathComponent("codex")
        let script = "#!/usr/bin/env python3\nscenario = '\(scenario)'\n" + Self.serverFixture
        try Data(script.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    // Real v2 message shapes, with notifications deliberately preceding the turn/start response.
    private static let serverFixture = #"""
import sys, json, pathlib, time, subprocess
log = open(__file__ + '.requests', 'a', buffering=1)
initialized = False
cwd = None
rejected = False
def read():
    line = sys.stdin.readline()
    if not line: sys.exit(0)
    log.write(line)
    return json.loads(line)
def send(value):
    data = (json.dumps(value, ensure_ascii=False) + '\n').encode()
    sys.stdout.buffer.write(data[:13]); sys.stdout.buffer.flush()
    sys.stdout.buffer.write(data[13:]); sys.stdout.buffer.flush()
def response(req, value): send({'id':req['id'], 'result':value})
def event(method, params): send({'method':method, 'params':params})
def ask(method, expected):
    send({'id':'server-' + method, 'method':method, 'params':{'threadId':'thread-1','turnId':'turn-1','itemId':'c1','questions':[]}})
    reply = read()
    assert reply['id'] == 'server-' + method
    if expected is None: assert 'error' in reply
    else: assert reply['result'] == expected, reply
def usage(i, o, turn):
    event('thread/tokenUsage/updated', {'threadId':'thread-1','turnId':turn,'tokenUsage':{'total':{'inputTokens':i,'outputTokens':o,'cachedInputTokens':20,'reasoningOutputTokens':2},'last':{'inputTokens':100,'outputTokens':10}}})
while True:
    req = read(); method = req.get('method'); p = req.get('params', {})
    if scenario == 'invalid': print('invalid JSON', flush=True); time.sleep(10); continue
    if scenario == 'timeout' and method == 'unanswered': time.sleep(10); continue
    if method == 'initialize': response(req, {'userAgent':'test','platformFamily':'unix','platformOs':'macos','codexHome':'/tmp'})
    elif method == 'initialized': initialized = True
    elif method == 'config/read': response(req, {'config':{'mcp_servers':{'lcu':{'command':'node'}}},'origins':{}})
    elif method == 'model/list':
        assert initialized
        if not p.get('cursor'): response(req, {'data':[{'id':'hidden','model':'hidden','hidden':True}], 'nextCursor':'page2'})
        else: response(req, {'data':[{'id':'catalog-id','model':'gpt-6-luna','displayName':'Luna','hidden':False,'supportedReasoningEfforts':[{'reasoningEffort':'low','description':'Fast'}],'defaultReasoningEffort':'low'}],'nextCursor':None})
    elif method in ('thread/start','thread/resume'):
        assert initialized
        if scenario == 'rpc-quota':
            send({'id':req['id'],'error':{'code':-32000,'message':'Quota exhausted','data':{'codexErrorInfo':'usageLimitExceeded'}}}); continue
        if scenario == 'auto' and not rejected:
            rejected = True
            send({'id':req['id'],'error':{'code':-32602,'message':'unsupported approvalsReviewer auto_review'}}); continue
        cwd = p['cwd']
        assert pathlib.Path(cwd).is_dir()
        assert p['model'] == 'gpt-6-luna'
        response(req, {'thread':{'id':'thread-1','cwd':cwd,'turns':[]},'cwd':cwd,'model':'gpt-6-luna'})
        if method == 'thread/resume': usage(500,50,'old-turn')
    elif method == 'turn/start':
        assert p['effort'] == 'low'
        if scenario == 'question': ask('item/tool/requestUserInput', {'answers':{}})
        if scenario == 'standard':
            for method in ('item/commandExecution/requestApproval','item/fileChange/requestApproval'): ask(method, {'decision':'decline'})
            ask('item/permissions/requestApproval', {'permissions':{},'scope':'turn'})
            ask('mcpServer/elicitation/request', {'action':'cancel'})
            ask('execCommandApproval', {'decision':'denied'})
            ask('applyPatchApproval', {'decision':'denied'})
            ask('item/tool/call', {'success':False,'contentItems':[{'type':'inputText','text':'lastdrop cannot answer this tool request.'}]})
            ask('future/request', None)
        if scenario == 'stop':
            subprocess.Popen(['/bin/sleep', '4'])
            response(req, {'turn':{'id':'turn-1','status':'inProgress','items':[]}})
            time.sleep(10); continue
        item = {'id':'c1','type':'commandExecution','command':'printf ok','cwd':cwd,'status':'completed','aggregatedOutput':'ok','exitCode':0}
        for method in ('item/started','item/completed','item/completed'): event(method, {'threadId':'thread-1','turnId':'turn-1','item':item})
        event('item/completed', {'threadId':'thread-1','turnId':'unrelated','item':{'id':'wrong','type':'agentMessage','text':'wrong'}})
        response(req, {'turn':{'id':'turn-1','status':'inProgress','items':[]}})
        if scenario == 'question': time.sleep(10); continue
        if scenario in ('quota','retry','interrupted'):
            error = {'message':'Usage limit' if scenario == 'quota' else 'Rate limit','codexErrorInfo':'usageLimitExceeded' if scenario == 'quota' else 'rateLimitExceeded'}
            event('error', {'threadId':'thread-1','turnId':'turn-1','error':error,'willRetry':scenario == 'retry'})
            event('turn/completed', {'threadId':'thread-1','turn':{'id':'turn-1','items':[],'status':'interrupted' if scenario == 'interrupted' else 'failed','error':error}})
            continue
        message = {'id':'m1','type':'agentMessage','phase':'final_answer','text':'ok 🦉'}
        event('item/completed', {'threadId':'thread-1','turnId':'turn-1','item':message})
        usage(600 if scenario == 'resume' else 100,60 if scenario == 'resume' else 10,'turn-1')
        event('turn/completed', {'threadId':'thread-1','turn':{'id':'turn-1','status':'completed','error':None,'items':[item,message]}})
"""#
}

private final class CodexEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storedItems: [[String: Any]] = []
    private var storedSteps: [String] = []
    private var storedPIDs: [Int32] = []
    private var storedStarted: [String] = []
    var items: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return storedItems }
    var steps: [String] { lock.lock(); defer { lock.unlock() }; return storedSteps }
    var pids: [Int32] { lock.lock(); defer { lock.unlock() }; return storedPIDs }
    var started: [String] { lock.lock(); defer { lock.unlock() }; return storedStarted }
    var events: AgentEvents {
        .init(process: { [self] in
            lock.lock(); defer { lock.unlock() }; storedPIDs.append($0)
        }, started: { [self] place, model in
            lock.lock(); defer { lock.unlock() }; storedStarted.append("\(place)/\(model)")
        }, step: { [self] in
            lock.lock(); defer { lock.unlock() }; storedSteps.append($0)
        }, item: { [self] in
            lock.lock(); defer { lock.unlock() }; storedItems.append($0)
        })
    }
}
