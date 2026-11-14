import XCTest
@testable import LastDrop

/// `lastdrop --acp` driven as T3 drives it: a fake T3 client on the server's stdin and stdout, and a fake runner
/// (`--agent-run`) and stopper (`--agent-stop`) that record what they got. Everything lives in the test's folder.
final class ACPServerTests: LastDropTestCase {
    private var folder: URL!

    override func setUp() {
        super.setUp()
        folder = LastDropPaths.support
        LastDropPaths.ensure(folder)
        let catalog = AgentCatalog(agents: [
            AgentDefinition(name: "flash", description: "Quick work", provider: .antigravity, model: "gemini-3.8-flash", effort: "low"),
            AgentDefinition(name: "sol", description: "Reviews", provider: .codex, model: "gpt-6.1-sol", enabled: false),
        ])
        try! catalog.save(to: LastDropPaths.agentCatalog)
    }

    // MARK: Probe

    func testTheProbeGetsTheModelsAndRecordsNothing() throws {
        let t3 = try client()
        let initialized = try t3.call("initialize", ["protocolVersion": 2, "clientCapabilities": [:]])
        XCTAssertEqual(initialized["protocolVersion"] as? Int, 1)
        XCTAssertNil(initialized["info"], "an info key makes T3 read the answer as ACP v2")
        let capabilities = try XCTUnwrap(initialized["agentCapabilities"] as? [String: Any])
        XCTAssertEqual(capabilities["loadSession"] as? Bool, false)
        XCTAssertNotNil((capabilities["sessionCapabilities"] as? [String: Any])?["resume"] as? [String: Any])
        XCTAssertEqual((capabilities["promptCapabilities"] as? [String: Any])?["image"] as? Bool, false)

        let new = try t3.call("session/new", ["cwd": folder.path, "mcpServers": []])
        XCTAssertTrue((new["sessionId"] as? String ?? "").hasPrefix("lastdrop-"))
        let model = try XCTUnwrap((new["configOptions"] as? [[String: Any]])?.first)
        XCTAssertEqual(model["category"] as? String, "model")
        XCTAssertEqual(model["type"] as? String, "select")
        XCTAssertEqual(model["currentValue"] as? String, "sonnet")
        let options = try XCTUnwrap(model["options"] as? [[String: Any]])
        XCTAssertEqual(options.map { $0["value"] as? String ?? "" }, ["fable", "opus", "sonnet", "haiku", "flash"])
        XCTAssertEqual(options.map { $0["name"] as? String ?? "" },
                       ["Claude Fable 5.2", "Claude Opus 5.5", "Claude Sonnet 5.5", "Claude Haiku 5.5", "flash · Antigravity Gemini 3.8 Flash"])
        XCTAssertEqual(options[4]["description"] as? String, "Quick work (Antigravity · gemini-3.8-flash · low)")
        // The default model takes an effort, so delegate_task's `target.options` effort passes T3's check.
        let effort = try XCTUnwrap((new["configOptions"] as? [[String: Any]])?.last)
        XCTAssertEqual(effort["id"] as? String, "effort")
        XCTAssertEqual(effort["category"] as? String, "thought_level")
        XCTAssertEqual(effort["type"] as? String, "select")
        XCTAssertEqual(effort["currentValue"] as? String, "auto")
        XCTAssertEqual((effort["options"] as? [[String: Any]])?.map { $0["value"] as? String ?? "" }, ["auto", "low", "medium", "high", "xhigh", "max"])
        t3.end()

        XCTAssertFalse(FileManager.default.fileExists(atPath: ACPSessions.file.path), "session/new records nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("requests.jsonl").path), "and starts nothing")
        XCTAssertTrue(t3.noise.isEmpty, "\(t3.noise)")
    }

    // MARK: Turns

    func testATaggedPromptRunsWhatDelegatedTurnWouldAndAFollowUpResumesIt() throws {
        try scenario([
            [["type": "started", "agentId": "task-1", "account": "Antigravity", "model": "gemini-3.8-flash"],
             ["type": "step", "text": "Read: a.txt"],
             ["type": "item", "kind": "tool", "id": "t1", "summary": "Read: a.txt", "input": "{\"file_path\":\"/w/a.txt\"}"],
             ["type": "item", "kind": "result", "id": "t1", "text": "hello", "isError": false],
             ["type": "moved", "account": "Antigravity", "reason": "its quota ran out; continuing on Codex"],
             ["type": "item", "kind": "text", "text": "All done."],
             ["type": "result", "text": "All done.", "isError": false, "account": "Antigravity", "model": "gemini-3.8-flash",
              "unavailable": ["argon"], "worktreePath": "/w/tree", "worktreeBranch": "lastdrop/x",
              "context": ["inputTokens": 10, "cacheReadInputTokens": 1000, "cacheCreationInputTokens": 5, "outputTokens": 20]]],
            [["type": "started", "agentId": "task-1", "account": "Antigravity", "model": "gemini-3.8-flash"],
             ["type": "result", "text": "Second.", "isError": false, "account": "Antigravity", "model": "gemini-3.8-flash"]],
        ])
        let t3 = try client()
        let session = try open(t3, model: "flash")
        let task = "Act as the reviewer sub-agent for this task.\n\nCheck a.txt"
        let tagged = LastDropTag.tag(task, ["id": "task-1", "agent": "flash", "effort": "high", "description": "Check a file"])
        let answer = try t3.call("session/prompt", ["sessionId": session, "prompt": t3Prompt(tagged, first: true)])
        XCTAssertEqual(answer["stopReason"] as? String, "end_turn")

        let requests = try runnerRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(NSDictionary(dictionary: requests[0]), NSDictionary(dictionary: [
            "prompt": task, "description": "Check a file", "subagentType": "general-purpose", "effort": "high",
            "cwd": folder.path, "agent": "flash", "id": "task-1",
        ]))

        let updates = t3.updates(session)
        let kinds = updates.map { $0["sessionUpdate"] as? String ?? "" }
        XCTAssertEqual(kinds, ["tool_call", "tool_call_update", "tool_call_update", "notice", "usage_update", "agent_message_chunk"])
        XCTAssertEqual(updates[0]["kind"] as? String, "read")
        XCTAssertEqual(updates[0]["title"] as? String, "Read: a.txt")
        XCTAssertEqual(updates[0]["status"] as? String, "in_progress")
        XCTAssertEqual((updates[1]["rawInput"] as? [String: Any])?["file_path"] as? String, "/w/a.txt")
        XCTAssertEqual(updates[2]["status"] as? String, "completed")
        XCTAssertEqual(updates[3]["title"] as? String, "Moved off Antigravity")
        XCTAssertEqual(updates[4]["used"] as? Int, 1035)
        XCTAssertEqual(updates[4]["size"] as? Int, 200_000)
        XCTAssertEqual((updates[5]["content"] as? [String: Any])?["text"] as? String,
                       "Ran on Antigravity (gemini-3.8-flash, argon unavailable). Worktree: /w/tree (branch lastdrop/x).\n\nAll done.")

        let entry = try XCTUnwrap(ACPSessions.lookup(session))
        XCTAssertEqual(entry.run, "task-1")
        XCTAssertTrue(entry.ran)
        XCTAssertNil(entry.task)

        t3.clearUpdates()
        let followUp = try t3.call("session/prompt", ["sessionId": session, "prompt": t3Prompt("And b.txt?", first: false)])
        XCTAssertEqual(followUp["stopReason"] as? String, "end_turn")
        let second = try runnerRequests()[1]
        XCTAssertEqual(second["prompt"] as? String, "And b.txt?")
        XCTAssertEqual(second["resume"] as? String, "task-1")
        XCTAssertEqual(second["agent"] as? String, "flash")
        XCTAssertEqual(second["effort"] as? String, "high")
        XCTAssertEqual(t3.updates(session).last?["content"].flatMap { ($0 as? [String: Any])?["text"] as? String },
                       "Ran on Antigravity (gemini-3.8-flash).\n\nSecond.")
        t3.end()
        XCTAssertTrue(t3.noise.isEmpty, "\(t3.noise)")
    }

    func testAPlainClaudeChildPassesItsModelAsTheParentModel() throws {
        try scenario([[["type": "started", "agentId": "task-2", "account": "work"],
                       ["type": "result", "text": "Ok.", "isError": false, "account": "work", "model": "claude-opus-5-5"]]])
        let t3 = try client()
        let session = try open(t3, model: "opus")
        let tagged = LastDropTag.tag("Do it", ["id": "task-2", "description": "Plain"])
        _ = try t3.call("session/prompt", ["sessionId": session, "prompt": t3Prompt(tagged, first: true)])
        let request = try runnerRequests()[0]
        XCTAssertEqual(request["parentModel"] as? String, "opus")
        XCTAssertNil(request["model"])
        XCTAssertNil(request["agent"])
        XCTAssertEqual(request["prompt"] as? String, "Do it")
        t3.end()
    }

    func testNoRoomAndFailuresAnswerAReadableError() throws {
        try scenario([[["type": "no_room"]],
                      [["type": "started", "agentId": "task-3", "account": "Codex"],
                       ["type": "result", "text": "Codex said no.", "isError": true]]])
        let t3 = try client()
        let session = try open(t3, model: "flash")
        let tagged = LastDropTag.tag("Do it", ["id": "task-3", "agent": "flash"])
        let error = try t3.callError("session/prompt", ["sessionId": session, "prompt": t3Prompt(tagged, first: true)])
        XCTAssertEqual(error, "lastdrop found nowhere to run flash.")
        // Nothing ran, so the next prompt sends the task again.
        let again = try t3.callError("session/prompt", ["sessionId": session, "prompt": t3Prompt("Please", first: false)])
        XCTAssertEqual(again, "Codex said no.")
        let requests = try runnerRequests()
        XCTAssertEqual(requests[1]["prompt"] as? String, "Do it\n\nPlease")
        XCTAssertNil(requests[1]["resume"])
        t3.end()
    }

    // MARK: Cancel and close

    func testCancelStopsTheRunAndAnswersCancelled() throws {
        try scenario([[["type": "started", "agentId": "task-4", "account": "Codex"], ["type": "step", "text": "Bash: sleep"],
                       ["waitStop": true]]])
        let t3 = try client()
        let session = try open(t3, model: "flash")
        let id = t3.send("session/prompt", ["sessionId": session, "prompt": t3Prompt(LastDropTag.tag("Long", ["id": "task-4", "agent": "flash"]), first: true)])
        _ = try t3.waitFor { ($0["params"] as? [String: Any]).flatMap { ($0["update"] as? [String: Any])?["sessionUpdate"] as? String } == "tool_call" }
        let sent = Date()
        t3.notify("session/cancel", ["sessionId": session])
        let answer = try t3.answer(id, timeout: 10)
        XCTAssertLessThan(Date().timeIntervalSince(sent), 10)
        XCTAssertEqual((answer["result"] as? [String: Any])?["stopReason"] as? String, "cancelled")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("stops.txt"), encoding: .utf8), "task-4\n")
        XCTAssertEqual(t3.updates(session).last?["status"] as? String, "failed", "the open tool call ends with the turn")
        t3.end()
    }

    func testARunStoppedElsewhereFailsTheTurnLikeThePlugin() throws {
        try scenario([[["type": "started", "agentId": "task-9", "account": "Codex"],
                       ["type": "result", "text": "Stopped.", "isError": true, "stopped": true, "account": "Codex"]]])
        let t3 = try client()
        let session = try open(t3, model: "flash")
        let message = try t3.callError("session/prompt", ["sessionId": session, "prompt": t3Prompt(LastDropTag.tag("Long", ["id": "task-9", "agent": "flash"]), first: true)])
        XCTAssertEqual(message, "Stopped.", "delegatedTurn throws the runner's error text")
        t3.end()
    }

    func testAnUntaggedPromptRunsTheSessionsModelUnderANewIDAfterARoomCheck() throws {
        try scenario([[["type": "started", "agentId": "x", "account": "Antigravity", "model": "gemini-3.8-flash"],
                       ["type": "result", "text": "Done.", "isError": false, "account": "Antigravity", "model": "gemini-3.8-flash"]],
                      [["type": "started", "agentId": "x", "account": "Antigravity"],
                       ["type": "result", "text": "Again.", "isError": false, "account": "Antigravity"]]])
        let t3 = try client()
        let session = try open(t3, model: "flash")
        // As T3 hands a delegate_task child to an ACP provider: the task as the model wrote it, inside T3's wrapper.
        let task = "Act as the review sub-agent for this task.\n\nCheck a.txt <!-- not a tag -->"
        let answer = try t3.call("session/prompt", ["sessionId": session, "prompt": t3Prompt(task, first: true)])
        XCTAssertEqual(answer["stopReason"] as? String, "end_turn")

        let request = try runnerRequests()[0]
        let id = try XCTUnwrap(request["id"] as? String)
        XCTAssertTrue(id.hasPrefix("acp-"), id)
        XCTAssertEqual(NSDictionary(dictionary: request), NSDictionary(dictionary: [
            "prompt": task, "subagentType": "general-purpose", "cwd": folder.path, "agent": "flash", "id": id,
        ]), "no effort, description or permission mode: the runner maps a missing mode to auto")
        let routes = try jsonLines("routes.jsonl")
        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(NSDictionary(dictionary: routes[0]), NSDictionary(dictionary: [
            "prompt": task, "subagentType": "general-purpose", "cwd": folder.path, "agent": "flash",
        ]), "the request the plugin's admission sends, without the run's id")
        XCTAssertEqual(ACPSessions.lookup(session)?.run, id)

        // A follow-up resumes the run without another room check.
        _ = try t3.call("session/prompt", ["sessionId": session, "prompt": t3Prompt("And b.txt?", first: false)])
        let second = try runnerRequests()[1]
        XCTAssertEqual(second["resume"] as? String, id)
        XCTAssertEqual(second["prompt"] as? String, "And b.txt?")
        XCTAssertEqual(try jsonLines("routes.jsonl").count, 1)
        t3.end()
        XCTAssertTrue(t3.noise.isEmpty, "\(t3.noise)")
    }

    func testAnUntaggedClaudeModelRunsThatModel() throws {
        try scenario([[["type": "started", "agentId": "x", "account": "work"],
                       ["type": "result", "text": "Ok.", "isError": false, "account": "work", "model": "claude-opus-5-5"]]])
        let t3 = try client()
        let session = try open(t3, model: "opus")
        _ = try t3.call("session/prompt", ["sessionId": session, "prompt": t3Prompt("Do it", first: true)])
        let request = try runnerRequests()[0]
        XCTAssertEqual(request["model"] as? String, "opus")
        XCTAssertNil(request["agent"])
        XCTAssertEqual(try jsonLines("routes.jsonl")[0]["model"] as? String, "opus")
        t3.end()
    }

    func testAnUntaggedPromptWithNoRoomAnswersAnErrorAndRunsNothing() throws {
        try JSONSerialization.data(withJSONObject: ["type": "no_room"]).write(to: folder.appendingPathComponent("route.json"))
        let t3 = try client()
        let flash = try open(t3, model: "flash")
        XCTAssertEqual(try t3.callError("session/prompt", ["sessionId": flash, "prompt": t3Prompt("Do it", first: true)]),
                       "lastdrop found nowhere to run flash.")
        let opus = try open(t3, model: "opus")
        let plain = try t3.callError("session/prompt", ["sessionId": opus, "prompt": t3Prompt("Do it", first: true)])
        XCTAssertTrue(plain?.hasPrefix("lastdrop found no account with room for opus") ?? false, plain ?? "no error")
        try JSONSerialization.data(withJSONObject: ["type": "error", "text": "No agent flash is enabled in lastdrop (Settings → Agents)."])
            .write(to: folder.appendingPathComponent("route.json"))
        XCTAssertEqual(try t3.callError("session/prompt", ["sessionId": flash, "prompt": t3Prompt("Again", first: false)]),
                       "No agent flash is enabled in lastdrop (Settings → Agents).")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("requests.jsonl").path), "no runner started")
        XCTAssertEqual(try jsonLines("routes.jsonl").count, 3)
        t3.end()
    }

    func testAnUntaggedPromptForAModelLastdropDoesntHaveIsRefused() throws {
        let t3 = try client()
        let session = try open(t3, model: "sol")   // disabled in the catalog
        let message = try t3.callError("session/prompt", ["sessionId": session, "prompt": t3Prompt("Do it", first: true)])
        XCTAssertEqual(message, "lastdrop has no model sol. Pick one of lastdrop's agents, or fable, opus, sonnet or haiku.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("routes.jsonl").path))
        t3.end()
    }

    func testACancelDuringTheRoomCheckAnswersCancelledAndStartsNothing() throws {
        try JSONSerialization.data(withJSONObject: ["type": "routed", "sleep": 20]).write(to: folder.appendingPathComponent("route.json"))
        let t3 = try client()
        let session = try open(t3, model: "flash")
        let id = t3.send("session/prompt", ["sessionId": session, "prompt": t3Prompt("Do it", first: true)])
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: folder.appendingPathComponent("routes.jsonl").path) && Date() < deadline { usleep(20_000) }
        let sent = Date()
        t3.notify("session/cancel", ["sessionId": session])
        let answer = try t3.answer(id, timeout: 10)
        XCTAssertLessThan(Date().timeIntervalSince(sent), 3, "the check is ended, not waited for")
        XCTAssertEqual((answer["result"] as? [String: Any])?["stopReason"] as? String, "cancelled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("requests.jsonl").path), "no runner started")
        t3.end()
    }

    func testARoomCheckThatHangsFailsThePrompt() throws {
        try JSONSerialization.data(withJSONObject: ["type": "routed", "sleep": 20]).write(to: folder.appendingPathComponent("route.json"))
        let t3 = try client(routeTimeout: 0.5)
        let session = try open(t3, model: "flash")
        XCTAssertEqual(try t3.callError("session/prompt", ["sessionId": session, "prompt": t3Prompt("Do it", first: true)]),
                       "lastdrop’s routing check didn’t answer in 0 s.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("requests.jsonl").path))
        t3.end()
    }

    func testAnUntaggedRunThatNeverStartedIsCheckedAgainAfterARestart() throws {
        try scenario([[["type": "no_room"]],
                      [["type": "started", "agentId": "x", "account": "Antigravity"], ["type": "result", "text": "Ok.", "isError": false, "account": "Antigravity"]]])
        let first = try client()
        let session = try open(first, model: "flash")
        // The room check passed, then the runner found none: nothing ran.
        XCTAssertNotNil(try first.callError("session/prompt", ["sessionId": session, "prompt": t3Prompt("Do it", first: true)]))
        first.end()
        let saved = try XCTUnwrap(ACPSessions.lookup(session))
        XCTAssertFalse(saved.ran)
        XCTAssertEqual(saved.checksRoom, true)

        let second = try client()
        _ = try second.call("initialize", ["protocolVersion": 2])
        _ = try second.call("session/resume", ["sessionId": session, "cwd": folder.path, "mcpServers": []])
        _ = try second.call("session/prompt", ["sessionId": session, "prompt": t3Prompt("Please", first: true)])
        let request = try runnerRequests()[1]
        XCTAssertEqual(request["prompt"] as? String, "Do it\n\nPlease")
        XCTAssertNil(request["resume"])
        XCTAssertEqual(request["id"] as? String, saved.run)
        XCTAssertEqual(try jsonLines("routes.jsonl").count, 2, "checked again: it never ran")
        second.end()
    }

    func testAModelChangeBeforeTheRunStartsIsTakenAndAfterIsRefused() throws {
        try scenario([[["type": "no_room"]],
                      [["type": "started", "agentId": "x", "account": "work"], ["type": "result", "text": "Ok.", "isError": false, "account": "work"]]])
        let t3 = try client()
        let session = try open(t3, model: "flash")
        XCTAssertNotNil(try t3.callError("session/prompt", ["sessionId": session, "prompt": t3Prompt("Do it", first: true)]))
        let changed = try t3.call("session/set_config_option", ["sessionId": session, "configId": "model", "value": "opus"])
        XCTAssertEqual((changed["configOptions"] as? [[String: Any]])?.first?["currentValue"] as? String, "opus")
        _ = try t3.call("session/prompt", ["sessionId": session, "prompt": t3Prompt("Now", first: false)])
        let request = try runnerRequests()[1]
        XCTAssertEqual(request["model"] as? String, "opus")
        XCTAssertNil(request["agent"])

        // The run started: it stays on opus. The same model again (T3 sets it when it opens a thread) is fine.
        XCTAssertNoThrow(try t3.call("session/set_config_option", ["sessionId": session, "configId": "model", "value": "opus"]))
        XCTAssertEqual(try t3.callError("session/set_config_option", ["sessionId": session, "configId": "model", "value": "flash"]),
                       "This run stays on opus; start a new task for flash.")
        XCTAssertEqual(try t3.callError("session/set_model", ["sessionId": session, "modelId": "haiku"]),
                       "This run stays on opus; start a new task for haiku.")
        XCTAssertEqual(try t3.callError("session/set_config_option", ["sessionId": session, "configId": "model", "value": "nope"]),
                       "This run stays on opus; start a new task for nope.")
        XCTAssertEqual(ACPSessions.lookup(session)?.model, "opus")
        t3.end()
    }

    func testAModelLastdropDoesntHaveIsRefusedBeforeTheRunStarts() throws {
        try scenario([[["type": "no_room"]]])
        let t3 = try client()
        let session = try open(t3, model: "flash")
        XCTAssertNotNil(try t3.callError("session/prompt", ["sessionId": session, "prompt": t3Prompt("Do it", first: true)]))
        XCTAssertEqual(try t3.callError("session/set_config_option", ["sessionId": session, "configId": "model", "value": "sol"]),
                       "lastdrop has no model sol. Pick one of lastdrop's agents, or fable, opus, sonnet or haiku.")
        XCTAssertEqual(ACPSessions.lookup(session)?.agent, "flash")
        t3.end()
    }

    func testAFreshSessionAfterARollbackStartsANewRun() throws {
        // T3 rolls an ACP thread back by opening a bare session/new: lastdrop can't tell it's the same thread.
        let line: [String: Any] = ["type": "result", "text": "Ok.", "isError": false, "account": "Antigravity"]
        try scenario([[["type": "started", "agentId": "x", "account": "Antigravity"], line], [["type": "started", "agentId": "y", "account": "Antigravity"], line]])
        let t3 = try client()
        let before = try open(t3, model: "flash")
        _ = try t3.call("session/prompt", ["sessionId": before, "prompt": t3Prompt("Do it", first: true)])
        let after = try open(t3, model: "flash")
        XCTAssertNotEqual(before, after)
        _ = try t3.call("session/prompt", ["sessionId": after, "prompt": t3Prompt("Go on", first: true)])
        let requests = try runnerRequests()
        XCTAssertNotEqual(requests[0]["id"] as? String, requests[1]["id"] as? String)
        XCTAssertNil(requests[1]["resume"], "the earlier run's conversation isn't carried over")
        XCTAssertEqual(requests[1]["prompt"] as? String, "Go on")
        t3.end()
    }

    func testATaggedPromptIsNotCheckedForRoomAgain() throws {
        try scenario([[["type": "started", "agentId": "task-t", "account": "Codex"], ["type": "result", "text": "Ok.", "isError": false]]])
        try JSONSerialization.data(withJSONObject: ["type": "no_room"]).write(to: folder.appendingPathComponent("route.json"))
        let t3 = try client()
        let session = try open(t3, model: "flash")
        let answer = try t3.call("session/prompt", ["sessionId": session, "prompt": t3Prompt(LastDropTag.tag("Do it", ["id": "task-t", "agent": "flash"]), first: true)])
        XCTAssertEqual(answer["stopReason"] as? String, "end_turn")
        XCTAssertEqual(try runnerRequests()[0]["id"] as? String, "task-t")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("routes.jsonl").path), "the plugin checked it")
        t3.end()
    }

    func testPlanModeFromT3sWrapperRunsTheTurnReadOnlyUntilDefault() throws {
        let line: [String: Any] = ["type": "result", "text": "Ok.", "isError": false, "account": "Codex"]
        let started: [String: Any] = ["type": "started", "agentId": "task-p", "account": "Codex"]
        try scenario([[started, line], [started, line], [started, line]])
        let t3 = try client()
        let session = try open(t3, model: "flash")
        let tagged = LastDropTag.tag("Look", ["id": "task-p", "agent": "flash", "permissionMode": "bypassPermissions"])
        _ = try t3.call("session/prompt", ["sessionId": session, "prompt": t3Prompt(tagged, first: true)])
        func wrapped(_ mode: String, _ text: String) -> [[String: Any]] {
            [["type": "text", "text": "<t3_code_instructions>\n## T3 Code interaction mode: \(mode)\n\nx\n</t3_code_instructions>\n\n<user_request>\n\(text)\n</user_request>"]]
        }
        _ = try t3.call("session/prompt", ["sessionId": session, "prompt": wrapped("Plan", "Plan it")])
        _ = try t3.call("session/prompt", ["sessionId": session, "prompt": wrapped("Default", "Do it")])
        let modes = try runnerRequests().map { $0["permissionMode"] as? String }
        XCTAssertEqual(modes, ["bypassPermissions", "plan", "bypassPermissions"])
        XCTAssertEqual(try runnerRequests()[1]["prompt"] as? String, "Plan it")
        t3.end()
    }

    func testCancelEndsARunnerThatIgnoresTheStop() throws {
        try scenario([[["type": "started", "agentId": "task-5", "account": "Codex"], ["sleep": 60]]])
        let t3 = try client(cancelWait: 1)
        let session = try open(t3, model: "flash")
        let id = t3.send("session/prompt", ["sessionId": session, "prompt": t3Prompt(LastDropTag.tag("Long", ["id": "task-5", "agent": "flash"]), first: true)])
        let pid = try runnerPID()
        t3.notify("session/cancel", ["sessionId": session])
        let answer = try t3.answer(id, timeout: 10)
        XCTAssertEqual((answer["result"] as? [String: Any])?["stopReason"] as? String, "cancelled")
        XCTAssertTrue(gone(pid, within: 5), "the runner was ended")
        t3.end()
    }

    func testCloseEndsTheRunnerAndThePrompt() throws {
        try scenario([[["type": "started", "agentId": "task-6", "account": "Codex"], ["sleep": 60]]])
        let t3 = try client()
        let session = try open(t3, model: "flash")
        let id = t3.send("session/prompt", ["sessionId": session, "prompt": t3Prompt(LastDropTag.tag("Long", ["id": "task-6", "agent": "flash"]), first: true)])
        let pid = try runnerPID()
        XCTAssertTrue(try t3.call("session/close", ["sessionId": session]).isEmpty)
        let answer = try t3.answer(id, timeout: 5)
        XCTAssertEqual((answer["result"] as? [String: Any])?["stopReason"] as? String, "cancelled")
        XCTAssertTrue(gone(pid, within: 5))
        XCTAssertNotNil(try t3.callError("session/prompt", ["sessionId": session, "prompt": t3Prompt("more", first: false)]))
        t3.end()
    }

    // MARK: Restart and catalog

    func testASessionResumesAfterTheProcessRestarts() throws {
        try scenario([[["type": "started", "agentId": "task-7", "account": "Antigravity"],
                       ["type": "result", "text": "One.", "isError": false, "account": "Antigravity"]],
                      [["type": "started", "agentId": "task-7", "account": "Antigravity"],
                       ["type": "result", "text": "Two.", "isError": false, "account": "Antigravity"]]])
        let first = try client()
        let session = try open(first, model: "flash")
        _ = try first.call("session/prompt", ["sessionId": session, "prompt": t3Prompt(LastDropTag.tag("Go", ["id": "task-7", "agent": "flash"]), first: true)])
        first.end()

        let second = try client()
        _ = try second.call("initialize", ["protocolVersion": 2])
        let resumed = try second.call("session/resume", ["sessionId": session, "cwd": folder.path, "mcpServers": []])
        XCTAssertEqual((resumed["configOptions"] as? [[String: Any]])?.first?["currentValue"] as? String, "flash")
        let answer = try second.call("session/prompt", ["sessionId": session, "prompt": t3Prompt("Again", first: true)])
        XCTAssertEqual(answer["stopReason"] as? String, "end_turn")
        let request = try runnerRequests()[1]
        XCTAssertEqual(request["prompt"] as? String, "Again")
        XCTAssertEqual(request["resume"] as? String, "task-7")

        let unknown = try second.callError("session/resume", ["sessionId": "lastdrop-nope", "cwd": folder.path, "mcpServers": []])
        XCTAssertTrue(unknown?.contains("lastdrop has no session lastdrop-nope") ?? false, unknown ?? "")
        second.end()
    }

    func testACatalogChangeUpdatesTheModelsOfALiveSession() throws {
        let t3 = try client()
        let session = try open(t3, model: "flash")
        try AgentCatalog.update { $0.agents.append(AgentDefinition(name: "glm", description: "Cheap", provider: .zai, model: "glm-5.3")) }
        let update = try t3.waitFor(timeout: 5) {
            let update = ($0["params"] as? [String: Any])?["update"] as? [String: Any]
            let models = (update?["configOptions"] as? [[String: Any]])?.first?["options"] as? [[String: Any]] ?? []
            return update?["sessionUpdate"] as? String == "config_option_update" && models.contains { $0["value"] as? String == "glm" }
        }
        let options = (((update["params"] as? [String: Any])?["update"] as? [String: Any])?["configOptions"] as? [[String: Any]])?.first
        XCTAssertEqual(options?["currentValue"] as? String, "flash")
        XCTAssertEqual((options?["options"] as? [[String: Any]])?.map { $0["value"] as? String ?? "" }, ["fable", "opus", "sonnet", "haiku", "flash", "glm"])
        XCTAssertEqual(((update["params"] as? [String: Any])?["sessionId"] as? String), session)
        t3.end()
    }

    // MARK: Effort

    func testNamesAndEffortsFollowEachModel() throws {
        try addAgents()
        let catalog = AgentCatalog.load(from: LastDropPaths.agentCatalog)
        let names = ACPServer.modelOptions(catalog).map { $0["name"] as? String ?? "" }
        XCTAssertEqual(names, ["Claude Fable 5.2", "Claude Opus 5.5", "Claude Sonnet 5.5", "Claude Haiku 5.5", "flash · Antigravity Gemini 3.8 Flash",
                               "build · Antigravity Claude Sonnet 5.5", "judge · Claude Fable 5.2", "glm · Z.ai glm-5.3", "codex · Codex GPT-6.1 Sol"])
        XCTAssertEqual(ACPServer.modelOptions(catalog)[5]["description"] as? String,
                       "Implementation (Antigravity · claude-sonnet-5-5, then Claude · sonnet)")
        for model in ["fable", "opus", "sonnet", "haiku", "judge"] { XCTAssertEqual(ACPServer.efforts(for: model, catalog), ClaudeBackend.efforts, model) }
        XCTAssertEqual(ACPServer.efforts(for: "build", catalog), AntigravityBackend.efforts)
        XCTAssertEqual(ACPServer.efforts(for: "glm", catalog), ["low", "high", "max"])
        XCTAssertNil(ACPServer.efforts(for: "flash", catalog), "its effort is fixed")
        XCTAssertNil(ACPServer.efforts(for: "nope", catalog))
        XCTAssertEqual(ACPServer.configOptions(model: "flash", effort: "high", catalog).count, 1, "no effort option for a fixed effort")
        XCTAssertEqual(ACPServer.configOptions(model: "glm", effort: "medium", catalog).last?["currentValue"] as? String, "auto",
                       "an effort the model doesn't take shows as auto")
        XCTAssertEqual(ACPServer.bounded(String(repeating: "a", count: 200), 160).count, 160)
    }

    func testAModelChangeSendsTheEffortOptionForTheNewModel() throws {
        let t3 = try client()
        let session = try open(t3, model: nil)
        _ = try t3.call("session/set_config_option", ["sessionId": session, "configId": "model", "value": "flash"])
        let fixed = try configUpdate(t3, session)
        XCTAssertEqual(fixed.map { $0["id"] as? String ?? "" }, ["model"], "a fixed-effort agent has no effort option")
        t3.clearUpdates()
        let set = try t3.call("session/set_config_option", ["sessionId": session, "configId": "model", "value": "haiku"])
        XCTAssertEqual((set["configOptions"] as? [[String: Any]])?.map { $0["id"] as? String ?? "" }, ["model", "effort"])
        let claude = try configUpdate(t3, session)
        XCTAssertEqual(claude.map { $0["id"] as? String ?? "" }, ["model", "effort"])
        XCTAssertEqual(claude.last?["currentValue"] as? String, "auto")
        t3.clearUpdates()
        _ = try t3.call("session/set_model", ["sessionId": session, "modelId": "flash"])
        XCTAssertEqual(try configUpdate(t3, session).count, 1)
        t3.end()
    }

    func testTheChosenEffortGoesToTheRunAndStaysWithIt() throws {
        try scenario([[["type": "started", "agentId": "x", "account": "work"], ["type": "result", "text": "Ok.", "isError": false]]])
        let t3 = try client()
        let session = try open(t3, model: "opus")
        let set = try t3.call("session/set_config_option", ["sessionId": session, "configId": "effort", "value": "xhigh"])
        XCTAssertEqual((set["configOptions"] as? [[String: Any]])?.last?["currentValue"] as? String, "xhigh")
        XCTAssertEqual(try t3.callError("session/set_config_option", ["sessionId": session, "configId": "effort", "value": "huge"]),
                       "opus takes effort auto, low, medium, high, xhigh, max, not huge.")
        XCTAssertEqual(try t3.callError("session/set_config_option", ["sessionId": session, "configId": "mode", "value": "x"]),
                       "lastdrop has only a model and an effort option.")
        _ = try t3.call("session/prompt", ["sessionId": session, "prompt": t3Prompt("Do it", first: true)])
        XCTAssertEqual(try runnerRequests()[0]["effort"] as? String, "xhigh")
        XCTAssertEqual(try jsonLines("routes.jsonl")[0]["effort"] as? String, "xhigh")
        XCTAssertEqual(ACPSessions.lookup(session)?.effort, "xhigh")
        // The runner continues a run at the effort it began with: the same is fine, another is refused.
        XCTAssertNoThrow(try t3.call("session/set_config_option", ["sessionId": session, "configId": "effort", "value": "xhigh"]))
        XCTAssertEqual(try t3.callError("session/set_config_option", ["sessionId": session, "configId": "effort", "value": "auto"]),
                       "This run stays at effort xhigh; start a new task for effort auto.")
        t3.end()
    }

    func testAnAgentWithoutAnEffortTakesTheCallersAndAFixedOneIgnoresIt() throws {
        try addAgents()
        try scenario([[["type": "started", "agentId": "x", "account": "Antigravity"], ["type": "result", "text": "Ok.", "isError": false]],
                      [["type": "started", "agentId": "y", "account": "Antigravity"], ["type": "result", "text": "Ok.", "isError": false]]])
        let t3 = try client()
        // As T3 may send them: the effort first, on the default model, then the model.
        let build = try open(t3, model: nil)
        _ = try t3.call("session/set_config_option", ["sessionId": build, "configId": "effort", "value": "max"])
        _ = try t3.call("session/set_config_option", ["sessionId": build, "configId": "model", "value": "build"])
        _ = try t3.call("session/prompt", ["sessionId": build, "prompt": t3Prompt("Do it", first: true)])
        XCTAssertEqual(try runnerRequests()[0]["agent"] as? String, "build")
        XCTAssertEqual(try runnerRequests()[0]["effort"] as? String, "max")

        let flash = try open(t3, model: nil)
        _ = try t3.call("session/set_config_option", ["sessionId": flash, "configId": "effort", "value": "high"])
        _ = try t3.call("session/set_config_option", ["sessionId": flash, "configId": "model", "value": "flash"])
        let ignored = try t3.call("session/set_config_option", ["sessionId": flash, "configId": "effort", "value": "medium"])
        XCTAssertEqual((ignored["configOptions"] as? [[String: Any]])?.count, 1)
        _ = try t3.call("session/prompt", ["sessionId": flash, "prompt": t3Prompt("Do it", first: true)])
        XCTAssertEqual(try runnerRequests()[1]["agent"] as? String, "flash")
        XCTAssertNil(try runnerRequests()[1]["effort"], "flash runs at its own low")

        let glm = try open(t3, model: "glm")
        XCTAssertEqual(try t3.callError("session/set_config_option", ["sessionId": glm, "configId": "effort", "value": "medium"]),
                       "glm takes effort auto, low, high, max, not medium.")
        t3.end()
    }

    private func addAgents() throws {
        try AgentCatalog.update {
            $0.agents += [
                AgentDefinition(name: "build", description: "Implementation", provider: .antigravity, model: "claude-sonnet-5-5",
                                fallbacks: [AgentFallback(provider: .claude, model: "sonnet")]),
                AgentDefinition(name: "judge", description: "Judgement", provider: .claude, model: "fable"),
                AgentDefinition(name: "glm", description: "Cheap", provider: .zai, model: "glm-5.3"),
                AgentDefinition(name: "codex", description: "Reviews", provider: .codex, model: "gpt-6.1-sol"),
            ]
        }
    }

    /// The session's next `config_option_update`.
    private func configUpdate(_ t3: FakeT3, _ session: String) throws -> [[String: Any]] {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let update = t3.updates(session).first(where: { $0["sessionUpdate"] as? String == "config_option_update" }) {
                return update["configOptions"] as? [[String: Any]] ?? []
            }
            usleep(50_000)
        }
        throw NSError(domain: "acp", code: 2, userInfo: [NSLocalizedDescriptionKey: "no config_option_update"])
    }

    // MARK: Text

    func testT3sWrapperAndRuntimeBlockAreNotPartOfTheTask() {
        let wrapped = "<t3_code_instructions>\n## T3 Code interaction mode: Default\n\nBe good.\n</t3_code_instructions>\n\n<user_request>\nFix it\n\nplease\n</user_request>"
        let runtime = "<runtime_info>In case you're asked: you are running in T3 Code.</runtime_info>\n\n<pull_request_linking>\nLink PRs.\n</pull_request_linking>"
        XCTAssertEqual(T3Wrapper.strip(blocks: [wrapped, runtime]), "Fix it\n\nplease")
        XCTAssertEqual(T3Wrapper.strip(blocks: ["Bare text", runtime]), "Bare text")
        XCTAssertEqual(T3Wrapper.strip(blocks: [wrapped + "\n\n" + runtime]), "Fix it\n\nplease")
        XCTAssertEqual(T3Wrapper.strip(blocks: ["/compact"]), "/compact")
    }

    func testTheTagReadsAsThePluginReadsIt() {
        let tagged = LastDropTag.tag("Task\n\nwith lines", ["id": "abc", "agent": "flash", "effort": "high", "description": "d"]) + "\n  "
        let found = LastDropTag.untag(tagged)
        XCTAssertEqual(found?.task, "Task\n\nwith lines")
        XCTAssertEqual(found?.run, LastDropTag.Run(id: "abc", agent: "flash", effort: "high", description: "d"))
        XCTAssertNil(LastDropTag.untag("No tag here"))
        XCTAssertNil(LastDropTag.untag("x\n\n<!-- lastdrop {\"agent\":\"flash\"} -->"), "a tag without an id")
        XCTAssertEqual(LastDropTag.header(["account": "work", "declined": ["rm -rf /"]]), "Ran on work.\nDeclined: rm -rf /\n\n")
        XCTAssertEqual(LastDropTag.header(["worktreePath": "/w"]), "Worktree: /w.\n\n")
        XCTAssertEqual(LastDropTag.header([:]), "")
    }

    func testToolKinds() {
        XCTAssertEqual(TurnView.kind("Read: a.txt"), "read")
        XCTAssertEqual(TurnView.kind("view_file: /a"), "read")
        XCTAssertEqual(TurnView.kind("Edit: a.swift"), "edit")
        XCTAssertEqual(TurnView.kind("Bash: ls"), "execute")
        XCTAssertEqual(TurnView.kind("run_command: ls"), "execute")
        XCTAssertEqual(TurnView.kind("Grep: foo"), "search")
        XCTAssertEqual(TurnView.kind("WebSearch: swift"), "fetch")
        XCTAssertEqual(TurnView.kind("Plan: steps"), "think")
        XCTAssertEqual(TurnView.kind("Moved off work: it is at its usage limit"), "other")
    }

    // MARK: Helpers

    private func open(_ t3: FakeT3, model: String?) throws -> String {
        _ = try t3.call("initialize", ["protocolVersion": 2])
        let new = try t3.call("session/new", ["cwd": folder.path, "mcpServers": []])
        let session = try XCTUnwrap(new["sessionId"] as? String)
        guard let model else { return session }
        let set = try t3.call("session/set_config_option", ["sessionId": session, "configId": "model", "value": model])
        XCTAssertEqual((set["configOptions"] as? [[String: Any]])?.first?["currentValue"] as? String, model)
        // A changed model sends its options again (the effort option follows it): read before the test's own updates.
        if model != ACPServer.defaultModel {
            _ = try t3.waitFor { (($0["params"] as? [String: Any])?["sessionId"] as? String) == session }
        }
        t3.clearUpdates()
        return session
    }

    /// A prompt as T3 sends it to an ACP provider: the wrapper on the first, the runtime block on each.
    private func t3Prompt(_ text: String, first: Bool) -> [[String: Any]] {
        let body = first ? "<t3_code_instructions>\nInstructions.\n</t3_code_instructions>\n\n<user_request>\n\(text)\n</user_request>" : text
        return [["type": "text", "text": body],
                ["type": "text", "text": "<runtime_info>In case you're asked: you are running in T3 Code through the acpRegistry harness, as flash.</runtime_info>\n\n<pull_request_linking>\nx\n</pull_request_linking>"]]
    }

    private func client(cancelWait: TimeInterval = 7, routeTimeout: TimeInterval = 10) throws -> FakeT3 {
        let runner = try script("runner", Self.runnerScript)
        let stopper = try script("stopper", Self.stopperScript)
        let router = try script("router", Self.routerScript)
        var options = ACPServer.Options(runner: [runner], stopper: [stopper], router: [router], catalog: LastDropPaths.agentCatalog, sessions: ACPSessions.file)
        options.catalogPoll = 0.2
        options.cancelWait = cancelWait
        options.killGrace = 0.5
        options.routeTimeout = routeTimeout
        return FakeT3(options: options)
    }

    private func scenario(_ turns: [[[String: Any]]]) throws {
        try JSONSerialization.data(withJSONObject: turns).write(to: folder.appendingPathComponent("scenario.json"))
    }

    private func runnerRequests() throws -> [[String: Any]] { try jsonLines("requests.jsonl") }

    private func jsonLines(_ name: String) throws -> [[String: Any]] {
        let text = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    private func runnerPID() throws -> Int32 {
        let url = folder.appendingPathComponent("runner.pid")
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return pid }
            usleep(50_000)
        }
        throw XCTSkip("the fake runner never started")
    }

    private func gone(_ pid: Int32, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            var status: Int32 = 0
            _ = waitpid(pid, &status, WNOHANG)
            if kill(pid, 0) != 0 { return true }
            usleep(50_000)
        }
        return false
    }

    private func script(_ name: String, _ body: String) throws -> String {
        let url = folder.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url.path
    }

    /// Records the request, then plays this turn's lines: `sleep` waits, `waitStop` waits for the stopper.
    private static let runnerScript = #"""
    #!/usr/bin/env python3
    import json, os, sys, time
    here = os.path.dirname(os.path.abspath(__file__))
    request = json.loads(sys.stdin.read())
    with open(os.path.join(here, 'requests.jsonl'), 'a') as f: f.write(json.dumps(request) + '\n')
    turn = sum(1 for _ in open(os.path.join(here, 'requests.jsonl'))) - 1
    open(os.path.join(here, 'runner.pid'), 'w').write(str(os.getpid()))
    turns = json.load(open(os.path.join(here, 'scenario.json'))) if os.path.exists(os.path.join(here, 'scenario.json')) else []
    for line in (turns[turn] if turn < len(turns) else []):
        if 'sleep' in line: time.sleep(line['sleep']); continue
        if line.get('waitStop'):
            while not os.path.exists(os.path.join(here, 'stopped-' + request['id'])): time.sleep(0.05)
            line = {'type': 'result', 'text': 'Stopped.', 'isError': True, 'stopped': True}
        sys.stdout.write(json.dumps(line) + '\n'); sys.stdout.flush()
    """#

    /// Records the routing check and answers `route.json`, or `routed`.
    private static let routerScript = #"""
    #!/usr/bin/env python3
    import json, os, sys, time
    here = os.path.dirname(os.path.abspath(__file__))
    request = json.loads(sys.stdin.read())
    with open(os.path.join(here, 'routes.jsonl'), 'a') as f: f.write(json.dumps(request) + '\n')
    path = os.path.join(here, 'route.json')
    answer = json.load(open(path)) if os.path.exists(path) else {'type': 'routed'}
    if 'sleep' in answer: time.sleep(answer.pop('sleep'))
    sys.stdout.write(json.dumps(answer) + '\n')
    """#

    private static let stopperScript = #"""
    #!/usr/bin/env python3
    import os, sys
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, 'stops.txt'), 'a') as f: f.write(sys.argv[1] + '\n')
    open(os.path.join(here, 'stopped-' + sys.argv[1]), 'w').close()
    """#
}

/// T3's side of the connection: requests in, every line out kept and checked to be JSON-RPC.
private final class FakeT3: @unchecked Sendable {
    let server: ACPServer
    private let toServer = Pipe(), fromServer = Pipe()
    private let lock = NSLock()
    private let arrived = DispatchSemaphore(value: 0)
    private var messages: [[String: Any]] = []
    private var cleared = 0
    private(set) var noise: [String] = []
    private var nextID = 1 << 30
    private let served = DispatchSemaphore(value: 0)

    init(options: ACPServer.Options) {
        server = ACPServer(input: toServer.fileHandleForReading.fileDescriptor, output: fromServer.fileHandleForWriting.fileDescriptor, options: options)
        Thread.detachNewThread { [self] in
            server.serve()
            server.shutdown()
            served.signal()
        }
        Thread.detachNewThread { [self] in
            var buffer = Data()
            let handle = fromServer.fileHandleForReading
            while case let data = handle.availableData, !data.isEmpty {
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer = Data(buffer[buffer.index(after: newline)...])
                    lock.withLock {
                        if let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], object["jsonrpc"] as? String == "2.0" {
                            messages.append(object)
                        } else {
                            noise.append(String(decoding: line, as: UTF8.self))
                        }
                    }
                    arrived.signal()
                }
            }
        }
    }

    @discardableResult
    func send(_ method: String, _ params: [String: Any]) -> Int {
        let id = lock.withLock { nextID += 1; return nextID }
        write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        return id
    }

    func notify(_ method: String, _ params: [String: Any]) {
        write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func write(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object) + Data("\n".utf8)
        toServer.fileHandleForWriting.write(data)
    }

    func call(_ method: String, _ params: [String: Any], timeout: TimeInterval = 10) throws -> [String: Any] {
        let reply = try answer(send(method, params), timeout: timeout)
        if let error = reply["error"] as? [String: Any] { throw NSError(domain: "acp", code: 1, userInfo: [NSLocalizedDescriptionKey: error["message"] as? String ?? ""]) }
        return reply["result"] as? [String: Any] ?? [:]
    }

    func callError(_ method: String, _ params: [String: Any], timeout: TimeInterval = 10) throws -> String? {
        let reply = try answer(send(method, params), timeout: timeout)
        return (reply["error"] as? [String: Any])?["message"] as? String
    }

    func answer(_ id: Int, timeout: TimeInterval = 10) throws -> [String: Any] {
        try waitFor(timeout: timeout) { ($0["id"] as? Int) == id && $0["method"] == nil }
    }

    func waitFor(timeout: TimeInterval = 10, _ match: ([String: Any]) -> Bool) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let found = lock.withLock({ messages.first(where: match) }) { return found }
            if Date() >= deadline { throw NSError(domain: "acp", code: 2, userInfo: [NSLocalizedDescriptionKey: "timed out"]) }
            _ = arrived.wait(timeout: .now() + 0.1)
        }
    }

    /// The session's updates since the last `clearUpdates`.
    func updates(_ session: String) -> [[String: Any]] {
        lock.withLock {
            messages[cleared...].compactMap { message -> [String: Any]? in
                guard message["method"] as? String == "session/update", let params = message["params"] as? [String: Any],
                      params["sessionId"] as? String == session else { return nil }
                return params["update"] as? [String: Any]
            }
        }
    }

    func clearUpdates() { lock.withLock { cleared = messages.count } }

    /// Closes stdin, as T3 does when it ends the process, and waits for the server to finish.
    func end() {
        try? toServer.fileHandleForWriting.close()
        _ = served.wait(timeout: .now() + 10)
    }
}
