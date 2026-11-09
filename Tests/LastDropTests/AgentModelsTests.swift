import XCTest
@testable import LastDrop

/// Extra models for the Agent tool: the model asked for is the model that runs, read-only roles, effort, worktrees.
final class AgentModelsTests: LastDropTestCase {
    private func definition(effort: String? = "high") -> AgentDefinition {
        .init(name: "sol", description: "Reviews.", provider: .codex, model: "gpt-6.1-sol", effort: effort)
    }

    private func request(_ json: String) throws -> AgentRun.Request {
        try JSONDecoder().decode(AgentRun.Request.self, from: Data(json.utf8))
    }

    // MARK: Never swap the model

    func testNoCodeSwapsTheModelForAnother() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 40)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("fallbackModel"), file.lastPathComponent)
            XCTAssertFalse(text.contains("Using Sonnet"), file.lastPathComponent)
        }
    }

    func testTheModelAskedForIsTheCallsOtherwiseTheSessions() throws {
        XCTAssertEqual(try request(#"{"prompt":"p","cwd":"/w","model":"opus","parentModel":"sonnet"}"#).wantedModel, "opus")
        XCTAssertEqual(try request(#"{"prompt":"p","cwd":"/w","parentModel":"fable"}"#).wantedModel, "fable")
        XCTAssertNil(try request(#"{"prompt":"p","cwd":"/w"}"#).wantedModel)
    }

    func testTheModelRefusalNamesTheModel() {
        let text = AgentRun.modelRefusal("fable", "Fable 5.1 requires usage credits.")
        XCTAssertTrue(text.contains("fable"))
        XCTAssertTrue(text.contains("Fable 5.1 requires usage credits."))
    }

    // MARK: Effort

    func testTheCallsEffortWinsOverTheDefinitionsAndAFollowUpKeepsItsOwn() throws {
        let call = try request(#"{"prompt":"p","cwd":"/w","effort":"max","agent":"sol"}"#)
        let plain = try request(#"{"prompt":"p","cwd":"/w","agent":"sol"}"#)
        XCTAssertEqual(AgentRun.effort(definition(), call, resume: nil), "max")
        XCTAssertEqual(AgentRun.effort(definition(), plain, resume: nil), "high")
        XCTAssertNil(AgentRun.effort(definition(effort: nil), plain, resume: nil))
        let entry = AgentRegistry.Entry(account: "Codex", directory: "/w", sessionID: "s", effort: "low", at: Date())
        XCTAssertEqual(AgentRun.effort(definition(), call, resume: entry), "low")
    }

    func testAClaudeAgentRefusesALevelClaudeCodeWouldIgnore() async {
        let job = AgentJob(agentID: "t", definition: .init(name: "o", description: "d", provider: .claude, model: "opus"), prompt: "p",
                           cwd: "/w", effort: "extreme", permissionMode: "auto", worktree: false)
        let result = await ClaudeBackend.run(job, AgentEvents(process: { _ in }, started: { _, _ in }, step: { _ in }, item: { _ in }))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("extreme"))
    }

    // MARK: Read-only roles

    func testReadOnlyRolesDenyTheEditingToolsOnClaudeCode() {
        let args = SubagentRunner.arguments(.init(prompt: "x", sessionID: "s", disallowedTools: SubagentRunner.editingTools))
        XCTAssertEqual(args.firstIndex(of: "--disallowedTools").map { args[$0 + 1] }, "Edit,Write,NotebookEdit")
        XCTAssertFalse(SubagentRunner.arguments(.init(prompt: "x", sessionID: "s")).contains("--disallowedTools"))
    }

    func testAReadOnlyRunNeverTakesAReadyProcess() {
        let account = ClaudeAccount(id: "Pro")
        let plain = SubagentRunner.Request(prompt: "x", model: "opus", sessionID: "s")
        var readOnly = plain
        readOnly.disallowedTools = SubagentRunner.editingTools
        XCTAssertNotNil(SubagentRunner.warmSpec(plain, on: account, in: "/w", environment: [:]))
        XCTAssertNil(SubagentRunner.warmSpec(readOnly, on: account, in: "/w", environment: [:]))
    }

    func testTheRoleIsKeptInTheEntryForFollowUps() throws {
        var entry = AgentRegistry.Entry(account: "Codex", directory: "/w", sessionID: "s", at: Date(), role: "Explore")
        XCTAssertEqual(try JSONDecoder.lastdrop.decode(AgentRegistry.Entry.self, from: JSONEncoder.lastdrop.encode(entry)).role, "Explore")
        entry.role = nil
        XCTAssertNil(try JSONDecoder.lastdrop.decode(AgentRegistry.Entry.self, from: JSONEncoder.lastdrop.encode(entry)).role)
        let old = #"{"account":"Pro","directory":"/w","sessionID":"s","at":1793098000}"#
        XCTAssertNil(try JSONDecoder.lastdrop.decode(AgentRegistry.Entry.self, from: Data(old.utf8)).role)
    }

    func testTheRequestCarriesTheRoleAndTheBareAgentName() throws {
        let request = try request(#"{"prompt":"p","cwd":"/w","agent":"sol","role":"Plan","effort":"high"}"#)
        XCTAssertEqual(request.agent, "sol")
        XCTAssertEqual(request.role, "Plan")
        XCTAssertNil(request.model)
        XCTAssertEqual(AgentCatalog(agents: [definition()]).agent(request.agent!)?.name, "sol")
    }

    // MARK: Worktree and declined actions

    func testAWorktreesBranchIsReadOrAbsentWhenDetached() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lastdrop-branch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func git(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", dir.path, "-c", "user.name=T", "-c", "user.email=t@example.test"] + args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "\(args)")
        }
        try git(["init", "--quiet", "-b", "worktree-keen-owl"])
        try git(["commit", "--quiet", "--allow-empty", "-m", "i"])
        XCTAssertEqual(AgentRun.branch(of: dir.path), "worktree-keen-owl")
        try git(["checkout", "--quiet", "--detach"])
        XCTAssertNil(AgentRun.branch(of: dir.path))
        XCTAssertNil(AgentRun.branch(of: "/does-not-exist"))
    }

    func testClaudeCodesPermissionDenialsAreListedOnce() {
        let result = SubagentRunner.parse(["is_error": false, "result": "ok", "permission_denials": [
            ["tool_name": "Bash", "tool_input": ["command": "git push"]],
            ["tool_name": "Bash", "tool_input": ["command": "git push"]],
            ["tool_name": "WebFetch", "tool_input": ["url": "https://example.test"]],
        ]])
        XCTAssertEqual(result.declined, ["Bash: git push (needed approval)", "WebFetch: https://example.test (needed approval)"])
        XCTAssertEqual(result.permissionDenials, 3)
    }

    // MARK: Review round 1

    private final class Seen: @unchecked Sendable {
        var model: String?
    }

    func testAReadyProcessReportsTheModelItWasSwitchedTo() async throws {
        let input = Pipe(), output = Pipe(), errors = Pipe()
        let lines = [
            #"{"type":"system","subtype":"init","session_id":"warm-s","cwd":"/w","model":"claude-haiku-warm","agents":[]}"#,
            #"{"type":"control_response","response":{"subtype":"success","request_id":"mode"}}"#,
            #"{"type":"control_response","response":{"subtype":"success","request_id":"model"}}"#,
            #"{"type":"result","is_error":false,"result":"ok","num_turns":1,"modelUsage":{"claude-haiku-warm":{"costUSD":0.001},"claude-opus-4-8":{"costUSD":0.2}}}"#,
        ]
        output.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        try output.fileHandleForWriting.close()
        try errors.fileHandleForWriting.close()
        let seen = Seen()
        let request = SubagentRunner.Request(prompt: "p", model: "opus", sessionID: "x")
        let result = await SubagentRunner.run(request, on: ClaudeAccount(id: "Pro"), in: "/w", claim: { _ in
            .init(sessionID: "warm-s", pid: 0, input: input.fileHandleForWriting, output: output.fileHandleForReading,
                  errors: errors.fileHandleForReading)
        }, check: { seen.model = $0["model"] as? String; return nil }, onStep: { _ in })
        XCTAssertEqual(seen.model, "opus")
        XCTAssertEqual(result.model, "opus")   // not the pricier Haiku in modelUsage, nor the model it was warmed for
    }

    func testModelUsageIsNeverUsedToNameTheModel() {
        let result = SubagentRunner.parse(["is_error": false, "result": "ok",
                                           "modelUsage": ["claude-haiku": ["costUSD": 9.0], "claude-opus": ["costUSD": 0.5]]])
        XCTAssertNil(result.model)
    }

    func testWorktreeDetailsAreNotedOnlyWhenTheRunLeftTheFolder() {
        var result = SubagentRunner.Result(text: "", isError: false, limitReached: false, turns: 1, permissionDenials: 0, directory: "/w/.claude/worktrees/x")
        AgentRun.noteWorktree(&result, isolation: nil, cwd: "/w")
        XCTAssertNil(result.worktreePath)
        AgentRun.noteWorktree(&result, isolation: "worktree", cwd: "/w/.claude/worktrees/x")
        XCTAssertNil(result.worktreePath)
        AgentRun.noteWorktree(&result, isolation: "worktree", cwd: "/w")
        XCTAssertEqual(result.worktreePath, "/w/.claude/worktrees/x")
    }

    func testTheEntryKeepsTheWorktreeForFollowUps() throws {
        var entry = AgentRegistry.Entry(account: "Codex", directory: "/w", sessionID: "s", at: Date())
        entry.worktreePath = "/w/wt"
        entry.worktreeBranch = "worktree-a"
        let back = try JSONDecoder.lastdrop.decode(AgentRegistry.Entry.self, from: JSONEncoder.lastdrop.encode(entry))
        XCTAssertEqual(back.worktreePath, "/w/wt")
        XCTAssertEqual(back.worktreeBranch, "worktree-a")
    }

    func testThePluginCanTellACompatibleApp() {
        XCTAssertEqual(AgentCatalog().pluginJSON()["agentModels"] as? Bool, true)
    }

    // MARK: Ledger compatibility (round 3)

    /// The ledger as the version before extra models decoded it: `lacking` and `fullUntil` required.
    private struct OldStore: Codable {
        var agents: [String: AgentRegistry.Entry] = [:]
        var lacking: [String: [String]] = [:]
        var fullUntil: [String: Date] = [:]
        var processes: [String: AgentRegistry.Processes]? = [:]
        var stopped: [String]? = []
    }

    func testAnOldFormatLedgerRoundTrips() throws {
        let old = #"{"agents":{"a1":{"account":"Pro","directory":"/w","sessionID":"s","model":"haiku","at":1793098000}},"lacking":{"Pro":["fable"]},"fullUntil":{"Pro":1793099000},"processes":{},"stopped":[]}"#
        var store = try JSONDecoder.lastdrop.decode(AgentRegistry.Store.self, from: Data(old.utf8))
        XCTAssertEqual(store.agents["a1"]?.sessionID, "s")
        XCTAssertEqual(store.fullUntil["Pro"], Date(timeIntervalSince1970: 1793099000))
        store.agents["a2"] = AgentRegistry.Entry(account: "Codex", directory: "/w", sessionID: "t", at: Date(), role: "Plan")
        let back = try JSONDecoder.lastdrop.decode(AgentRegistry.Store.self, from: JSONEncoder.lastdrop.encode(store))
        XCTAssertEqual(Set(back.agents.keys), ["a1", "a2"])
        XCTAssertEqual(back.agents["a2"]?.role, "Plan")
    }

    func testTheLedgerTheNewCodeWritesDecodesUnderTheOldShape() throws {
        var store = AgentRegistry.Store()
        store.agents["a1"] = AgentRegistry.Entry(account: "Pro", directory: "/w", sessionID: "s", at: Date(), role: "Explore")
        let data = try JSONEncoder.lastdrop.encode(store)
        let old = try JSONDecoder.lastdrop.decode(OldStore.self, from: data)
        XCTAssertEqual(Set(old.agents.keys), ["a1"])
        XCTAssertEqual(old.lacking, [:])   // still written, for versions that require it
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("lackingSince"))
    }

    func testAStoredLackingMemoryDecodesHarmlesslyAndIsDroppedOnTheNextWrite() throws {
        let stored = #"{"agents":{"a1":{"account":"Pro","directory":"/w","sessionID":"s","at":1793098000}},"lacking":{"Pro":["fable"]},"lackingSince":{"Pro":{"fable":1793098000}},"fullUntil":{}}"#
        let store = try JSONDecoder.lastdrop.decode(AgentRegistry.Store.self, from: Data(stored.utf8))
        XCTAssertEqual(Set(store.agents.keys), ["a1"])
        let written = String(decoding: try JSONEncoder.lastdrop.encode(store), as: UTF8.self)
        XCTAssertFalse(written.contains("lackingSince"))
        XCTAssertFalse(written.contains("fable"))
        XCTAssertTrue(written.contains("\"lacking\""))
    }

    func testMissingAndUnknownKeysNeverMakeTheLedgerUnreadable() throws {
        let sparse = try JSONDecoder.lastdrop.decode(AgentRegistry.Store.self, from: Data(#"{"agents":{},"future":{"x":1}}"#.utf8))
        XCTAssertTrue(sparse.agents.isEmpty)
        XCTAssertTrue(try JSONDecoder.lastdrop.decode(AgentRegistry.Store.self, from: Data("{}".utf8)).agents.isEmpty)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lastdrop-t-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dir.appendingPathComponent(f).path)
            }
            try? FileManager.default.removeItem(at: dir)
        }
        return dir
    }

    private func backups(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.contains(".unreadable-") }.sorted()
    }

    func testAnUnreadableLedgerIsKeptNotOverwritten() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("subagents.json")
        let bad = Data(#"{"agents":{"a1":{"account":7}}}"#.utf8)
        try bad.write(to: file)
        let read = AgentRegistry.readStore(at: file)
        XCTAssertTrue(read.store.agents.isEmpty)
        XCTAssertTrue(read.writable)
        let kept = try XCTUnwrap(backups(dir).first)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(kept)), bad)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let absent = AgentRegistry.readStore(at: file)   // absent: a fresh ledger, nothing more to keep
        XCTAssertTrue(absent.writable)
        XCTAssertEqual(backups(dir).count, 1)
    }

    func testASecondBadFileNeverReplacesAnEarlierBackup() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("subagents.json")
        try Data("first".utf8).write(to: file)
        _ = AgentRegistry.readStore(at: file)
        try Data("second".utf8).write(to: file)
        _ = AgentRegistry.readStore(at: file)
        let kept = backups(dir)
        XCTAssertEqual(kept.count, 2)
        XCTAssertEqual(Set(try kept.map { try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8) }), ["first", "second"])
    }

    func testAFileThatCantBeReadIsKeptToo() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("subagents.json")
        try Data(#"{"agents":{}}"#.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: file.path)
        let read = AgentRegistry.readStore(at: file)
        XCTAssertTrue(read.writable)
        XCTAssertEqual(backups(dir).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAFailedMoveSkipsTheWriteAndKeepsTheFile() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("subagents.json")
        try Data("bad".utf8).write(to: file)
        struct Refused: Error {}
        let read = AgentRegistry.readStore(at: file, move: { _, _ in throw Refused() })
        XCTAssertFalse(read.writable)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "bad")
        // A "move" that reports success but leaves the file in place doesn't count either.
        XCTAssertFalse(AgentRegistry.readStore(at: file, move: { _, _ in }).writable)
    }

    func testSavingTheCatalogOverAnUnreadableOneKeepsABackup() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("agent-catalog.json")
        let bad = Data(#"{"agents":"not a list"}"#.utf8)
        try bad.write(to: file)
        XCTAssertTrue(AgentCatalog.load(from: file).agents.isEmpty)
        try AgentCatalog().save(to: file)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(try XCTUnwrap(backups(dir).first))), bad)
        XCTAssertEqual(AgentCatalog.load(from: file).revision, 1)
        try AgentCatalog().save(to: file)   // a readable file needs no backup
        XCTAssertEqual(backups(dir).count, 1)
        // A file that can't even be read is not saved over.
        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: file.path)
        XCTAssertThrowsError(try AgentCatalog().save(to: file))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertEqual(AgentCatalog.load(from: file).revision, 1)   // untouched by the refused save
    }

    // MARK: Worktrees like Claude Code's (round 3)

    func testAnUnchangedWorktreeIsRemovedAndAChangedOneKept() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("lastdrop-wt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        func git(_ dir: URL, _ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", dir.path, "-c", "user.name=T", "-c", "user.email=t@example.test"] + args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "\(args)")
        }
        try git(repo, ["init", "--quiet", "-b", "main"])
        try git(repo, ["commit", "--quiet", "--allow-empty", "-m", "i"])
        let root = "/private" + repo.path

        let clean = try AgentWorktree.create(in: repo.path, agentID: "a1")
        XCTAssertEqual(URL(fileURLWithPath: clean.path).resolvingSymlinksInPath().path, URL(fileURLWithPath: root).resolvingSymlinksInPath().path + "/.claude/worktrees/agent-a1")
        XCTAssertEqual(clean.branch, "worktree-agent-a1")
        XCTAssertTrue(AgentWorktree.isUnchanged(clean.path))
        AgentWorktree.remove(clean.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: clean.path))
        XCTAssertFalse(try shell(repo.path, ["branch", "--list", "worktree-agent-a1"]).contains("worktree-agent-a1"))

        let dirty = try AgentWorktree.create(in: repo.path, agentID: "a2")
        try Data("x".utf8).write(to: URL(fileURLWithPath: dirty.path + "/new.txt"))
        XCTAssertFalse(AgentWorktree.isUnchanged(dirty.path))

        let committed = try AgentWorktree.create(in: repo.path, agentID: "a3")
        try git(URL(fileURLWithPath: committed.path), ["commit", "--quiet", "--allow-empty", "-m", "work"])
        XCTAssertFalse(AgentWorktree.isUnchanged(committed.path))
        XCTAssertFalse(AgentWorktree.isUnchanged("/does-not-exist"))
        XCTAssertThrowsError(try AgentWorktree.create(in: FileManager.default.temporaryDirectory.path, agentID: "a4"))
    }

    private func shell(_ dir: String, _ args: [String]) throws -> String {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir] + args
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: A refused model, offline (round 3)

    /// A stand-in `claude`: refuses `fable` on the account named in `refusing` (by its config folder) and records
    /// every call's folder and arguments. The smallest seam that reaches the real runner: `run`'s `executable:`.
    private func fakeClaude(in folder: URL, refusing: [String]) throws -> String {
        let path = folder.appendingPathComponent("claude")
        let script = """
        #!/bin/bash
        echo "${CLAUDE_CONFIG_DIR:-main} $*" >> "\(folder.path)/calls"
        cat > /dev/null
        echo '{"type":"system","subtype":"init","session_id":"s1","cwd":"/w","model":"claude-fable-5-1","agents":[]}'
        case "${CLAUDE_CONFIG_DIR:-main}" in
        \(refusing.map { "*/\($0)|\($0)" }.joined(separator: "|"))) echo '{"type":"result","is_error":true,"result":"Fable 5.1 requires usage credits. Switch to another model.","api_error_status":429}' ;;
        *) echo '{"type":"result","is_error":false,"result":"done","num_turns":1}' ;;
        esac
        """
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path.path
    }

    func testARefusedModelIsNeverSwappedForAnother() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lastdrop-fake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pro = ClaudeAccount(id: "Pro"), main = ClaudeAccount(id: "main")
        let claude = try fakeClaude(in: folder, refusing: ["Pro"])
        let request = SubagentRunner.Request(prompt: "p", model: "fable", sessionID: "s")

        let refused = await SubagentRunner.run(request, on: pro, in: folder.path, claim: { _ in nil }, executable: claude, onStep: { _ in })
        XCTAssertTrue(refused.modelUnavailable)
        XCTAssertFalse(refused.limitReached)
        XCTAssertTrue(refused.isError)
        let answered = await SubagentRunner.run(request, on: main, in: folder.path, claim: { _ in nil }, executable: claude, onStep: { _ in })
        XCTAssertFalse(answered.isError)

        let calls = try String(contentsOf: folder.appendingPathComponent("calls"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(calls.count, 2)
        for call in calls {
            XCTAssertTrue(call.contains("--model fable"), "\(call)")
            XCTAssertFalse(call.contains("sonnet"), "\(call)")
        }
        XCTAssertTrue(AgentRun.modelRefusal("fable", refused.text).contains("fable"))
    }

    func testEveryAccountRefusingLeavesAVisibleModelError() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lastdrop-fake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let claude = try fakeClaude(in: folder, refusing: ["Pro", "main"])
        let request = SubagentRunner.Request(prompt: "p", model: "fable", sessionID: "s")
        var last: SubagentRunner.Result?
        for account in [ClaudeAccount(id: "Pro"), ClaudeAccount(id: "main")] {
            last = await SubagentRunner.run(request, on: account, in: folder.path, claim: { _ in nil }, executable: claude, onStep: { _ in })
            XCTAssertTrue(last?.modelUnavailable == true)
        }
        let text = AgentRun.modelRefusal("fable", try XCTUnwrap(last).text)
        XCTAssertTrue(text.contains("fable") && text.contains("no other model stands in"), text)
        let calls = try String(contentsOf: folder.appendingPathComponent("calls"), encoding: .utf8)
        XCTAssertFalse(calls.contains("sonnet"))
    }

    // MARK: Worktrees from subfolders and bare repositories (round 4)

    private func runGit(_ dir: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir, "-c", "user.name=T", "-c", "user.email=t@example.test", "-c", "protocol.file.allow=always"] + args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "\(args)")
    }

    func testACallFromASubfolderRunsInTheSameSubfolderOfTheWorktree() throws {
        let repo = try tempDir()
        try runGit(repo.path, ["init", "--quiet", "-b", "main"])
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("pkg/inner"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: repo.appendingPathComponent("pkg/inner/f.txt"))
        try runGit(repo.path, ["add", "."])
        try runGit(repo.path, ["commit", "--quiet", "-m", "i"])
        let made = try AgentWorktree.create(in: repo.appendingPathComponent("pkg/inner").path, agentID: "s1")
        XCTAssertTrue(made.path.hasSuffix("/.claude/worktrees/agent-s1"))
        XCTAssertTrue(made.directory.hasSuffix("/.claude/worktrees/agent-s1/pkg/inner"), made.directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: made.directory + "/f.txt"))
        // Reported as the worktree's top, wherever the run was.
        var result = SubagentRunner.Result(text: "", isError: false, limitReached: false, turns: 1, permissionDenials: 0, directory: made.directory)
        AgentRun.noteWorktree(&result, isolation: "worktree", cwd: repo.appendingPathComponent("pkg/inner").path)
        XCTAssertEqual(URL(fileURLWithPath: result.worktreePath ?? "").resolvingSymlinksInPath().path,
                       URL(fileURLWithPath: made.path).resolvingSymlinksInPath().path)
        XCTAssertEqual(result.worktreeBranch, "worktree-agent-s1")
        XCTAssertTrue(AgentWorktree.remove(made.path))
    }

    func testAWorktreeOfABareRepositoryIsRemovedWithItsBranch() throws {
        let origin = try tempDir()
        try runGit(origin.path, ["init", "--quiet", "-b", "main"])
        try runGit(origin.path, ["commit", "--quiet", "--allow-empty", "-m", "i"])
        let bare = try tempDir().appendingPathComponent("bare.git")
        try runGit(origin.path, ["clone", "--quiet", "--bare", origin.path, bare.path])
        let main = bare.deletingLastPathComponent().appendingPathComponent("main-wt")
        try runGit(bare.path, ["worktree", "add", "--quiet", main.path, "main"])
        let made = try AgentWorktree.create(in: main.path, agentID: "b1")
        XCTAssertTrue(AgentWorktree.isUnchanged(made.path))
        XCTAssertTrue(AgentWorktree.remove(made.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: made.path))
        let branches = try shell(bare.path, ["branch", "--list", "worktree-agent-b1"])
        XCTAssertFalse(branches.contains("worktree-agent-b1"))
        XCTAssertFalse(AgentWorktree.remove("/does-not-exist"))
    }

    // MARK: Fall back to the built-in agent (round 5)

    func testForgettingAnAgentThatNeverRanLeavesNoEntryProcessOrStopMark() {
        var store = AgentRegistry.Store()
        store.agents["a1"] = AgentRegistry.Entry(account: "Pro", directory: "/w", sessionID: "s", at: Date())
        store.agents["a2"] = AgentRegistry.Entry(account: "Pro", directory: "/w", sessionID: "t", at: Date())
        store.processes = ["a1": .init(runner: 1, claude: 2)]
        store.stopped = ["a1", "a2"]
        store.forget("a1")
        XCTAssertEqual(Set(store.agents.keys), ["a2"])
        XCTAssertNil(store.processes?["a1"])
        XCTAssertEqual(store.stopped, ["a2"])
    }

    func testTheRunnerSaysNativeNotAnErrorWhenNoAccountIsLeft() throws {
        // The line the plugin hands back to the built-in agent, and the one place it comes from.
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/LastDrop/Subagents/AgentRun.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains(#"emit(["type": "native"])"#))
        XCTAssertTrue(source.contains(#"if request.isolation != "worktree" {"#))
        XCTAssertTrue(source.contains("AgentRegistry.forget(agentID)"))
    }
}
