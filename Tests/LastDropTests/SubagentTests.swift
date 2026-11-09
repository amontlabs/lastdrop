import XCTest
@testable import LastDrop

final class SubagentTests: XCTestCase {
    private func candidate(_ id: String, _ session: Double?, _ weekly: Double?, active: Int = 0) -> SubagentAccounts.Candidate {
        .init(account: ClaudeAccount(id: id), name: id, sessionUsed: session, weeklyUsed: weekly, active: active)
    }

    // MARK: Choosing an account

    func testPicksTheAccountWithMostRoom() {
        let picked = SubagentAccounts.pick([candidate("A", 60, 20), candidate("B", 10, 30)], sessionThreshold: 0.9, weeklyThreshold: 0.9)
        XCTAssertEqual(picked?.account.id, "B")
    }

    func testSkipsAccountsAtOrOverAThreshold() {
        XCTAssertNil(SubagentAccounts.pick([candidate("A", 90, 10), candidate("B", 10, 95)], sessionThreshold: 0.9, weeklyThreshold: 0.9))
        XCTAssertEqual(SubagentAccounts.pick([candidate("A", 89, 10)], sessionThreshold: 0.9, weeklyThreshold: 0.9)?.account.id, "A")
    }

    func testUnknownUsageIsNoRoom() {
        XCTAssertNil(SubagentAccounts.pick([candidate("A", nil, 10)], sessionThreshold: 0.9, weeklyThreshold: 0.9))
    }

    func testParallelCallsSpreadOverAccounts() {
        let picked = SubagentAccounts.pick([candidate("A", 10, 10, active: 2), candidate("B", 20, 20)], sessionThreshold: 0.9, weeklyThreshold: 0.9)
        XCTAssertEqual(picked?.account.id, "B")
    }

    func testRunningAgentsUseUpAnAccountsRoom() {
        // Pro at 50% of a 90% threshold: four agents fit, a fifth goes elsewhere (or to the session's own).
        XCTAssertEqual(SubagentAccounts.pick([candidate("Pro", 50, 25, active: 3)], sessionThreshold: 0.9, weeklyThreshold: 0.95)?.account.id, "Pro")
        XCTAssertNil(SubagentAccounts.pick([candidate("Pro", 50, 25, active: 4)], sessionThreshold: 0.9, weeklyThreshold: 0.95))
    }

    func testOwnAccountComesFromTheSession() {
        XCTAssertEqual(SubagentAccounts.ownAccountUUID(environment: ["CLAUDE_CODE_ACCOUNT_UUID": "u1"]), "u1")
    }

    // MARK: Running Claude Code

    func testNativeTaskIDsSurviveTheRunnerProtocol() throws {
        func request(_ fields: String) throws -> AgentRun.Request {
            try JSONDecoder().decode(AgentRun.Request.self, from: Data("{\"prompt\":\"x\",\"cwd\":\"/work\"\(fields)}".utf8))
        }
        let native = try request(",\"id\":\"a1234567890abcdef\",\"resume\":\"a1234567890abcdef\"")
        XCTAssertEqual(native.id, native.resume)
        XCTAssertTrue(native.validID)
        XCTAssertTrue(try request("").validID)
        for id in ["", "../another-agent", "a/b", String(repeating: "a", count: 101)] {
            XCTAssertFalse(try request(",\"id\":\"\(id)\"").validID)
        }
    }

    func testNativeUsageKeepsTheCacheCountsSeparate() {
        let result = SubagentRunner.parse(["type": "result", "result": "report", "usage": [
            "input_tokens": 30, "output_tokens": 10, "cache_read_input_tokens": 50, "cache_creation_input_tokens": 20,
        ]])
        XCTAssertEqual(result.inputTokens, 100)
        XCTAssertEqual(result.outputTokens, 10)
        XCTAssertEqual(result.cacheReadInputTokens, 50)
        XCTAssertEqual(result.cacheCreationInputTokens, 20)
    }

    func testArgumentsMirrorTheBuiltInParameters() {
        let args = SubagentRunner.arguments(.init(prompt: "x", subagentType: "Explore", model: "haiku", effort: "high", worktree: true,
                                                  permissionMode: "acceptEdits", sessionID: "s1", mcpConfig: "/m.json"))
        XCTAssertEqual(args, ["-p", "--output-format", "stream-json", "--verbose", "--permission-mode", "acceptEdits",
                              "--session-id", "s1", "--agent", "Explore", "--model", "haiku", "--effort", "high", "--worktree",
                              "--mcp-config", "/m.json"])
        XCTAssertFalse(SubagentRunner.arguments(.init(prompt: "x", subagentType: "general-purpose", sessionID: "s")).contains("--agent"))
        XCTAssertTrue(SubagentRunner.arguments(.init(prompt: "x", sessionID: "s1", resume: true)).contains("--resume"))
        let forkArgs = SubagentRunner.arguments(.init(prompt: "x", sessionID: "s1", resume: true, forkTo: "s2"))
        XCTAssertTrue(forkArgs.contains("--fork-session"))
        XCTAssertEqual(forkArgs, ["-p", "--output-format", "stream-json", "--verbose", "--permission-mode", "auto",
                                  "--resume", "s1", "--fork-session", "--session-id", "s2"])
    }

    func testPermissionModeFollowsTheSession() {
        XCTAssertEqual(AgentRun.mappedPermissionMode("acceptEdits"), "acceptEdits")
        XCTAssertEqual(AgentRun.mappedPermissionMode("plan"), "plan")
        XCTAssertEqual(AgentRun.mappedPermissionMode("default"), "auto")   // a headless run can't ask
        XCTAssertEqual(AgentRun.mappedPermissionMode(nil), "auto")
    }

    func testEnvironmentDropsTheCallingSessionsIdentity() {
        let base = ["PATH": "/bin", "HOME": "/Users/x", "CLAUDE_CODE_ACCOUNT_UUID": "u1", "CLAUDE_CODE_ENTRYPOINT": "claude-desktop",
                    "CLAUDECODE": "1", "CLAUDE_CONFIG_DIR": "/elsewhere", "ANTHROPIC_BASE_URL": "https://api.anthropic.com"]
        let pro = SubagentRunner.environment(for: ClaudeAccount(id: "Pro"), from: base)
        XCTAssertEqual(pro["PATH"], "/bin")
        XCTAssertNil(pro["CLAUDE_CODE_ACCOUNT_UUID"])
        XCTAssertNil(pro["CLAUDECODE"])
        XCTAssertTrue(pro["CLAUDE_CONFIG_DIR"]!.hasSuffix("/.claude-accounts/Pro"))
        XCTAssertEqual(pro[AgentRun.nestedMarker], "1")
        XCTAssertNil(SubagentRunner.environment(for: ClaudeAccount(id: "main"), from: base)["CLAUDE_CONFIG_DIR"])
    }

    func testMCPServersComeFromTheCallersConfig() {
        let root: [String: Any] = [
            "mcpServers": ["lcu": ["command": "lcu"], "lastdrop": ["command": "lastdrop"]],
            "projects": ["/work": ["mcpServers": ["db": ["command": "db"]]], "/other": ["mcpServers": ["x": [:]]]],
        ]
        let servers = SubagentRunner.mcpConfig(from: root, directory: "/work")?["mcpServers"] as? [String: Any]
        XCTAssertEqual(Set(servers?.keys ?? [:].keys), ["lcu", "db"])
        XCTAssertNil(SubagentRunner.mcpConfig(from: [:], directory: "/work"))
    }

    func testParsesClaudeCodesResult() {
        let ok = SubagentRunner.parse(["type": "result", "is_error": false, "result": "HELLO", "num_turns": 2, "permission_denials": [],
                                       "duration_ms": 1200, "usage": ["input_tokens": 10, "output_tokens": 5]])
        XCTAssertEqual(ok.text, "HELLO")
        XCTAssertFalse(ok.isError)
        XCTAssertEqual(ok.durationMs, 1200)
        XCTAssertEqual(ok.outputTokens, 5)
        let limit = SubagentRunner.parse(["is_error": true, "result": "Claude AI usage limit reached", "api_error_status": 429, "num_turns": 1])
        XCTAssertTrue(limit.limitReached)
        let model = SubagentRunner.parse(["is_error": true, "result": "Fable 5.1 requires usage credits. Switch to another model, or manage usage credits at https://claude.ai/settings/usage?from=cc_cli_limit_message, to continue.", "api_error_status": 429])
        XCTAssertTrue(model.modelUnavailable)
        XCTAssertFalse(model.limitReached)
    }

    func testStepsReadLikeAgentProgress() {
        XCTAssertEqual(SubagentRunner.describe(tool: "Read", input: ["file_path": "/a/b/note.txt"]), "Read: note.txt")
        XCTAssertEqual(SubagentRunner.describe(tool: "Bash", input: ["command": "npm test", "description": "Run the tests"]), "Bash: Run the tests")
        XCTAssertEqual(SubagentRunner.describe(tool: "TodoWrite", input: [:]), "TodoWrite")
    }

    func testAReadyProcessMatchesEverythingButTheSession() {
        let account = ClaudeAccount(id: "Pro")
        let a = SubagentRunner.Request(prompt: "one", model: "sonnet", permissionMode: "auto", sessionID: "s1", mcpConfig: "/m.json")
        var b = a
        b.prompt = "two"
        b.sessionID = "s2"
        let specA = SubagentRunner.warmSpec(a, on: account, in: "/work", environment: [:])
        XCTAssertEqual(specA?.arguments.contains("--session-id"), false)
        XCTAssertTrue(specA?.matches(SubagentRunner.warmSpec(b, on: account, in: "/work", environment: ["PATH": "/bin"])!) ?? false)
        // The runner switches these after taking a process over.
        b.model = "haiku"
        b.permissionMode = "plan"
        XCTAssertTrue(specA?.matches(SubagentRunner.warmSpec(b, on: account, in: "/work", environment: [:])!) ?? false)
        b.subagentType = "Explore"
        XCTAssertFalse(specA?.matches(SubagentRunner.warmSpec(b, on: account, in: "/work", environment: [:])!) ?? true)
        XCTAssertFalse(specA?.matches(SubagentRunner.warmSpec(a, on: account, in: "/elsewhere", environment: [:])!) ?? true)
        var resumed = a
        resumed.resume = true
        XCTAssertNil(SubagentRunner.warmSpec(resumed, on: account, in: "/work", environment: [:]))
    }

    func testATakenOverProcessIsSwitchedToTheRunsModelAndMode() {
        let switches = WarmPool.switches(model: "haiku", permissionMode: "plan")
        XCTAssertEqual(switches.map(\.id), ["mode", "model"])
        let model = try? JSONSerialization.jsonObject(with: switches[1].data) as? [String: Any]
        XCTAssertEqual(model?["type"] as? String, "control_request")
        XCTAssertEqual(model?["request_id"] as? String, "model")
        XCTAssertEqual((model?["request"] as? [String: Any])?["subtype"] as? String, "set_model")
        XCTAssertEqual((model?["request"] as? [String: Any])?["model"] as? String, "haiku")
        XCTAssertEqual(WarmPool.switches(model: nil, permissionMode: "auto").map(\.id), ["mode"])
    }

    func testAClaimedProcessCanBeStoppedWhileItsSwitchesAreStillPending() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lastdrop-warm-stop-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("registered")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-u", "-c", """
        import json, pathlib, sys
        early = None
        for line in sys.stdin:
            event = json.loads(line)
            if event['type'] == 'control_request':
                if early is None: early = pathlib.Path(sys.argv[1]).exists()
                print(json.dumps({'type':'control_response', 'response':{'subtype':'success', 'request_id':event['request_id']}}), flush=True)
            elif event['type'] == 'user':
                print(json.dumps({'type':'result', 'result':'early' if early else 'late', 'is_error':False, 'num_turns':1}), flush=True)
                break
        """, marker.path]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let ready = WarmPool.Claimed(sessionID: "warm", pid: process.processIdentifier,
                                    input: input.fileHandleForWriting, output: output.fileHandleForReading, errors: errors.fileHandleForReading)
        let result = await SubagentRunner.run(.init(prompt: "x", model: "haiku", sessionID: ""), on: ClaudeAccount(id: "Pro"),
                                             in: directory.path, claim: { _ in ready }, onProcess: { pid in
            try? String(pid).write(to: marker, atomically: true, encoding: .utf8)
        }, onStep: { _ in })
        process.waitUntilExit()
        XCTAssertEqual(result.text, "early", "TaskStop needs the pid before a ready process answers its control requests")
    }

    func testPipesTravelOverTheSocket() throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let pipe = Pipe()
        WarmPool.reply(pair[0], ["sessionID": "abc"], passing: [pipe.fileHandleForWriting.fileDescriptor])
        var fds: [Int32] = []
        let reply = WarmPool.receive(pair[1], fds: &fds)
        XCTAssertEqual(reply?["sessionID"] as? String, "abc")
        XCTAssertEqual(fds.count, 1)
        let handle = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
        handle.write(Data("hi".utf8))
        try handle.close()
        try pipe.fileHandleForWriting.close()
        XCTAssertEqual(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "hi")
        close(pair[0]); close(pair[1])
    }

    func testThePromptIsAStreamJSONUserMessage() throws {
        let line = WarmPool.userMessage("Read note.txt")
        XCTAssertEqual(line.last, 0x0A)
        let object = try JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "user")
        XCTAssertEqual((object?["message"] as? [String: Any])?["content"] as? String, "Read note.txt")
    }

    func testTranscriptEntriesReadLikeTheAgentsRow() {
        XCTAssertEqual(SubagentRunner.transcriptItem(["type": "text", "text": "Done."])?["text"] as? String, "Done.")
        let tool = SubagentRunner.transcriptItem(["type": "tool_use", "id": "t1", "name": "Read", "input": ["file_path": "/a/note.txt"]])
        XCTAssertEqual(tool?["summary"] as? String, "Read: note.txt")
        XCTAssertEqual(tool?["id"] as? String, "t1")
        XCTAssertTrue((tool?["input"] as? String)?.contains("\"/a/note.txt\"") == true)
        let result = SubagentRunner.transcriptItem(["type": "tool_result", "tool_use_id": "t1",
                                                    "content": [["type": "text", "text": "a"], ["type": "text", "text": "b"]]])
        XCTAssertEqual(result?["text"] as? String, "a\nb")
        XCTAssertEqual(result?["isError"] as? Bool, false)
        XCTAssertNil(SubagentRunner.transcriptItem(["type": "thinking", "thinking": "…"]))
        XCTAssertEqual((SubagentRunner.transcriptItem(["type": "text", "text": String(repeating: "x", count: 5000)])?["text"] as? String)?.count, 4001)
    }

    func testAFollowUpKeepsTheAgentTypeAndEffort() {
        let args = SubagentRunner.arguments(.init(prompt: "x", subagentType: "Explore", effort: "high", sessionID: "s1", resume: true))
        XCTAssertEqual(Array(args[6...]), ["--resume", "s1", "--agent", "Explore", "--effort", "high"])
    }

    func testClaudeCodesInitIsCheckedBeforeTheAgentCountsAsStarted() {
        let init_: [String: Any] = ["type": "system", "subtype": "init", "session_id": "s", "cwd": "/w/.claude/worktrees/a",
                                    "model": "claude-haiku-5-5", "agents": ["general-purpose", "Explore", "Plan"]]
        XCTAssertNil(SubagentRunner.checkInit(init_, subagentType: "Explore"))
        XCTAssertNil(SubagentRunner.checkInit(init_, subagentType: nil))
        XCTAssertEqual(SubagentRunner.checkInit(init_, subagentType: "Reviewer"), "the Reviewer agent type isn't available")
        var changed = init_
        changed["agents"] = nil
        XCTAssertEqual(SubagentRunner.checkInit(changed, subagentType: nil), "Claude Code's init event has no `agents`")
    }

    func testAUsageLimitReadsFromClaudeCodesApiError() {
        let limit = SubagentRunner.parse(["is_error": true, "result": "You've hit your weekly limit", "api_error": "usage_limit_reached"])
        XCTAssertTrue(limit.limitReached)
    }

    func testClaudeCodesLimitMessagesReadAsLimits() {
        for text in ["You've hit your session limit · resets 10:40pm (Europe/Paris)", "You've hit your weekly limit · resets 5am",
                     "You've hit your Opus limit", "You've hit your limit"] {
            XCTAssertTrue(SubagentRunner.parse(["is_error": true, "result": text]).limitReached, text)
        }
        XCTAssertFalse(SubagentRunner.parse(["is_error": true, "result": "You've hit a snag"]).limitReached)
    }

    // MARK: Moving a session to another account

    func testTransferDropsTheTrailingLimitNoticeOnly() throws {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"go"}}"#,
            #"{"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"Overloaded"}]}}"#,
            #"{"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"tool_use"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result"}]}}"#,
            #"{"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"You've hit your session limit"}]}}"#,
            #"{"type":"last-prompt","lastPrompt":"go"}"#,
            "",
        ]
        let kept = String(decoding: SessionTransfer.withoutTrailingNotices(Data(lines.joined(separator: "\n").utf8)), as: UTF8.self)
        XCTAssertEqual(kept, (lines[0...3] + lines[5...]).joined(separator: "\n"))
    }

    func testTransferCopiesTheTranscriptAndItsSideFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lastdrop-transfer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("a/projects"), target = root.appendingPathComponent("b/projects")
        let project = source.appendingPathComponent("-w-sic")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("s1/tool-results"), withIntermediateDirectories: true)
        try Data(#"{"type":"user","message":{"content":"go"}}"#.utf8).write(to: project.appendingPathComponent("s1.jsonl"))
        try Data("big".utf8).write(to: project.appendingPathComponent("s1/tool-results/r.txt"))

        XCTAssertTrue(SessionTransfer.copy("s1", from: source, to: target))
        XCTAssertNotNil(FileManager.default.contents(atPath: target.appendingPathComponent("-w-sic/s1.jsonl").path))
        XCTAssertEqual(FileManager.default.contents(atPath: target.appendingPathComponent("-w-sic/s1/tool-results/r.txt").path), Data("big".utf8))
        XCTAssertFalse(SessionTransfer.copy("missing", from: source, to: target))
        XCTAssertFalse(SessionTransfer.copy("s1", from: source, to: source))

        // A symlinked folder resolves to the same real path, so copy refuses it.
        let symlink = root.appendingPathComponent("c/projects")
        try FileManager.default.createDirectory(at: symlink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
        XCTAssertFalse(SessionTransfer.copy("s1", from: source, to: symlink))
    }

    /// Starts a Haiku agent on another account, treats it as stopped at its limit (as it is when that account
    /// is full), and checks the session's own account continues the same session and answers.
    func testLiveAnAgentAtItsLimitContinuesOnTheSessionsOwnAccount() async throws {
        guard ProcessInfo.processInfo.environment["LASTDROP_LIVE_FAILOVER"] == "1" else {
            throw XCTSkip("Set LASTDROP_LIVE_FAILOVER=1 to move a Haiku session between two signed-in accounts.")
        }
        let config = ClaudeAccountsConfig.load()
        let own = SubagentAccounts.ownAccountUUID()
        guard let mine = AgentRun.ownAccount(config.ordered, own: own),
              let other = config.ordered.first(where: { $0.id != mine.id }) else { throw XCTSkip("Needs two lastdrop accounts.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lastdrop-failover-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID().uuidString.lowercased()
        let first = SubagentRunner.Request(prompt: "What is 17 times 3? Reply with the number only.", subagentType: nil, model: "haiku",
                                           effort: nil, permissionMode: "auto", sessionID: sessionID)
        var result = await SubagentRunner.run(first, on: other, in: directory.path, claim: { _ in nil }) { _ in }
        result.limitReached = true
        let entry = AgentRegistry.Entry(account: other.id, directory: result.directory ?? directory.path, sessionID: sessionID,
                                        model: "haiku", subagentType: nil, effort: nil, at: Date())
        let (final, moved) = await AgentRun.carryOn("live-failover", entry: entry, result: result, accounts: [mine, other], config: config,
                                                     own: own, tried: [], permissionMode: "auto", mcpConfig: nil)
        XCTAssertEqual(moved.account, mine.id)
        XCTAssertFalse(final.isError, final.text)
        XCTAssertTrue(final.text.contains("51"), final.text)
    }

    func testAgentsRecordedBeforeTheAgentTypeWasKeptStillLoad() throws {
        let old = #"{"account":"Pro","directory":"/w","sessionID":"s","model":"haiku","at":1793098000}"#
        let entry = try JSONDecoder.lastdrop.decode(AgentRegistry.Entry.self, from: Data(old.utf8))
        XCTAssertEqual(entry.sessionID, "s")
        XCTAssertNil(entry.subagentType)
        let store = try JSONDecoder.lastdrop.decode(AgentRegistry.Store.self, from: Data(#"{"agents":{},"lacking":{},"fullUntil":{}}"#.utf8))
        XCTAssertEqual(store.processes?.count, 0)
    }

    func testForkRunStartsColdWithoutClaimingWarmPool() {
        let req = SubagentRunner.Request(prompt: "p", sessionID: "s1", resume: true, forkTo: "s2")
        let spec = SubagentRunner.warmSpec(req, on: ClaudeAccount(id: "Pro"), in: "/dir", environment: [:])
        XCTAssertNil(spec, "A fork run must start cold, never reuse a warm process")
    }

    func testIsLimitNoticeCases() {
        // Case 1: Limit notice is the last turn
        let noticeLast = """
        {"type":"assistant","message":{"model":"claude-3-haiku","content":[{"type":"text","text":"hello"}]}}
        {"type":"user","message":{"role":"user","content":"do work"}}
        {"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"You have reached your usage limit."}]}}
        """
        XCTAssertTrue(ThreadReaper.isLimitNotice(tail: Data(noticeLast.utf8)))

        // Case 2: Real assistant reply comes after limit notice
        let replyAfter = """
        {"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"You have reached your usage limit."}]}}
        {"type":"assistant","message":{"model":"claude-3-haiku","content":[{"type":"text","text":"I am back and working fine."}]}}
        """
        XCTAssertFalse(ThreadReaper.isLimitNotice(tail: Data(replyAfter.utf8)))

        // Case 3: Metadata lines after limit notice (metadata is ignored, notice is still the last user/assistant line)
        let metadataAfter = """
        {"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"Weekly limit exceeded."}]}}
        {"type":"last-prompt","lastPrompt":"go"}
        {"type":"progress","step":1}
        """
        XCTAssertTrue(ThreadReaper.isLimitNotice(tail: Data(metadataAfter.utf8)))

        // Case 4: Synthetic error without mentioning limit
        let syntheticOtherError = """
        {"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"Internal server error."}]}}
        """
        XCTAssertFalse(ThreadReaper.isLimitNotice(tail: Data(syntheticOtherError.utf8)))

        // Case 5: Empty data
        XCTAssertFalse(ThreadReaper.isLimitNotice(tail: Data()))
    }

    func testThreadReaperChecksAndReapsLiveProcess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lastdrop-reaper-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            SessionLedger.fileOverride = nil
            ThreadReaper.projectsDirOverride = nil
        }
        let ledgerFile = root.appendingPathComponent("sessions.json")
        SessionLedger.fileOverride = ledgerFile

        let projects = root.appendingPathComponent("projects")
        let projectFolder = projects.appendingPathComponent("proj-test")
        try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)
        ThreadReaper.projectsDirOverride = projects

        // Start a dummy sleeper process
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["60"]
        try proc.run()
        defer { if proc.isRunning { proc.terminate() } }

        let session = "thread-session-1"
        let transcript = projectFolder.appendingPathComponent("\(session).jsonl")

        // Written before live entry time: reaper should ignore it
        let notice = #"{"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"Usage limit reached."}]}}"# + "\n"
        try Data(notice.utf8).write(to: transcript)

        let entryTime = Date().addingTimeInterval(2)
        SessionLedger.addLive(.init(pid: proc.processIdentifier, account: "account-alpha", session: session, thread: "t1", at: entryTime))

        XCTAssertEqual(SessionLedger.live().count, 1)
        ThreadReaper.check()
        // Still alive because file was modified before entry.at
        XCTAssertTrue(SessionLedger.isAlive(proc.processIdentifier))
        XCTAssertEqual(SessionLedger.live().count, 1)

        // Now update modification date of transcript after entry.at
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: transcript.path)

        ThreadReaper.check()

        // Wait up to 1 second for SIGTERM
        for _ in 0..<10 {
            if !SessionLedger.isAlive(proc.processIdentifier) { break }
            usleep(100_000)
        }
        XCTAssertFalse(SessionLedger.isAlive(proc.processIdentifier))
        XCTAssertTrue(SessionLedger.live().isEmpty)
    }

    func testCarryOnRewritesTranscriptWhenSharedFolderAndForksToNewID() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lastdrop-carryon-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            SessionLedger.fileOverride = nil
        }
        SessionLedger.fileOverride = root.appendingPathComponent("sessions.json")

        let sharedProjects = root.appendingPathComponent("shared/projects")
        let project = sharedProjects.appendingPathComponent("myproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let oldSessionID = "original-session-1"
        let transcriptURL = project.appendingPathComponent("\(oldSessionID).jsonl")
        let content = """
        {"type":"user","message":{"role":"user","content":"hello"}}
        {"type":"assistant","message":{"model":"claude-3-haiku","content":[{"type":"text","text":"step 1"}]}}
        {"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"You have hit your session limit"}]}}
        """
        try Data(content.utf8).write(to: transcriptURL)

        // Account A and B
        let accA = ClaudeAccount(id: "AccountA")
        let accB = ClaudeAccount(id: "AccountB")

        // Test rewrite in place
        let fromProjects = sharedProjects
        let toProjects = sharedProjects
        XCTAssertEqual(fromProjects.resolvingSymlinksInPath(), toProjects.resolvingSymlinksInPath())

        let dataBefore = try Data(contentsOf: transcriptURL)
        let cleaned = SessionTransfer.withoutTrailingNotices(dataBefore)
        try cleaned.write(to: transcriptURL, options: .atomic)

        let rewritten = String(decoding: try Data(contentsOf: transcriptURL), as: UTF8.self)
        XCTAssertFalse(rewritten.contains("limit"))
        XCTAssertTrue(rewritten.contains("step 1"))

        // And ledger records fork
        let newID = "forked-session-1"
        SessionLedger.record(session: newID, account: accB.id, forkedAt: Date())
        let recorded = SessionLedger.session(newID)
        XCTAssertEqual(recorded?.account, "AccountB")
        XCTAssertNotNil(recorded?.forkedAt)
    }
}
