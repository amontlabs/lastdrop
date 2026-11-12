import XCTest
@testable import LastDrop

/// Fake providers for the fallback chain: Codex, Antigravity and Z.ai stand in for the real backends.
enum FakeCodex: AgentBackend {
    nonisolated(unsafe) static var script: (AgentJob, AgentEvents) async -> SubagentRunner.Result = { _, _ in fatalError() }
    nonisolated(unsafe) static var calls: [AgentJob] = []
    static func models() async throws -> [AgentModel] { [] }
    static func run(_ job: AgentJob, _ events: AgentEvents) async -> SubagentRunner.Result { calls.append(job); return await script(job, events) }
    static func terminal(_ entry: AgentRegistry.Entry) -> String? { nil }
}

enum FakeAntigravity: AgentBackend {
    nonisolated(unsafe) static var script: (AgentJob, AgentEvents) async -> SubagentRunner.Result = { _, _ in fatalError() }
    nonisolated(unsafe) static var calls: [AgentJob] = []
    static func models() async throws -> [AgentModel] { [] }
    static func run(_ job: AgentJob, _ events: AgentEvents) async -> SubagentRunner.Result { calls.append(job); return await script(job, events) }
    static func terminal(_ entry: AgentRegistry.Entry) -> String? { nil }
}

enum FakeZAI: AgentBackend {
    nonisolated(unsafe) static var script: (AgentJob, AgentEvents) async -> SubagentRunner.Result = { _, _ in fatalError() }
    nonisolated(unsafe) static var calls: [AgentJob] = []
    static func models() async throws -> [AgentModel] { [] }
    static func run(_ job: AgentJob, _ events: AgentEvents) async -> SubagentRunner.Result { calls.append(job); return await script(job, events) }
    static func terminal(_ entry: AgentRegistry.Entry) -> String? { nil }
}

final class AgentFallbackTests: LastDropTestCase {
    private var lines: [[String: Any]] = []
    private var ledger: URL!

    override func setUpWithError() throws {
        lines = []
        ledger = FileManager.default.temporaryDirectory.appendingPathComponent("lastdrop-fb-\(UUID().uuidString).json")
        AgentRegistry.fileOverride = ledger
        AgentRun.sink = { [unowned self] in lines.append($0) }
        AgentRun.backends = { provider in
            switch provider {
            case .codex: FakeCodex.self
            case .antigravity: FakeAntigravity.self
            default: FakeZAI.self
            }
        }
        FakeCodex.calls = []; FakeAntigravity.calls = []; FakeZAI.calls = []
    }

    override func tearDown() {
        super.tearDown()
        AgentRegistry.fileOverride = nil
        AgentRun.sink = nil
        AgentRun.backends = { $0.backend }
        try? FileManager.default.removeItem(at: ledger)
    }

    private func definition(fallbacks: [AgentFallback] = [.init(provider: .antigravity, model: "gemini-4-argon", effort: nil)]) -> AgentDefinition {
        .init(name: "sol", description: "Reviews.", provider: .codex, model: "gpt-6.1-sol", effort: "high", fallbacks: fallbacks)
    }

    private func request(_ extra: String = "", cwd: String = "/tmp") throws -> AgentRun.Request {
        try JSONDecoder().decode(AgentRun.Request.self, from: Data(#"{"prompt":"p","cwd":"\#(cwd)"\#(extra)}"#.utf8))
    }

    private func limited() -> SubagentRunner.Result {
        .init(text: "Usage limit reached.", isError: true, limitReached: true, turns: 0, permissionDenials: 0, account: "Codex")
    }

    private func answered(_ place: String, session: String = "s1") -> SubagentRunner.Result {
        .init(text: "done", isError: false, limitReached: false, turns: 1, permissionDenials: 0, toolUses: 1, model: "m", sessionID: session, account: place)
    }

    private func types() -> [String] { lines.compactMap { $0["type"] as? String } }

    func testALimitedPrimaryFallsToTheNextAndTheLineSaysWhatRan() async throws {
        let id = "fb-" + UUID().uuidString
        FakeCodex.script = { [self] _, _ in limited() }
        FakeAntigravity.script = { [self] _, events in events.started("Antigravity", "gemini-4-argon"); return answered("Antigravity") }
        await AgentRun.runDefined(definition(), try request(), agentID: id, resume: nil, mcpConfig: nil)
        XCTAssertEqual(types(), ["moved", "started", "result"])
        XCTAssertEqual(lines[0]["provider"] as? String, "antigravity")
        XCTAssertEqual(lines[0]["model"] as? String, "gemini-4-argon")
        XCTAssertEqual(lines[1]["provider"] as? String, "antigravity")
        let result = lines[2]
        XCTAssertEqual(result["text"] as? String, "done")
        XCTAssertEqual(result["provider"] as? String, "antigravity")
        XCTAssertEqual(result["unavailable"] as? [String], ["gpt-6.1-sol"])
        // The entry a follow-up continues is the attempt that ran, with no chain.
        let entry = try XCTUnwrap(AgentRegistry.lookup(id))
        XCTAssertEqual(entry.definition?.provider, .antigravity)
        XCTAssertEqual(entry.definition?.model, "gemini-4-argon")
        XCTAssertTrue(entry.definition?.fallbacks.isEmpty == true)
        XCTAssertEqual(entry.model, "gemini-4-argon")
    }

    func testAnAttemptThatStartedThenFailedBeforeAnyWorkMovesWithANewStartedLine() async throws {
        FakeCodex.script = { [self] _, events in events.started("Codex", "gpt-6.1-sol"); return limited() }
        FakeAntigravity.script = { [self] _, events in events.started("Antigravity", "gemini-4-argon"); return answered("Antigravity") }
        await AgentRun.runDefined(definition(), try request(), agentID: "fb-" + UUID().uuidString, resume: nil, mcpConfig: nil)
        XCTAssertEqual(types(), ["started", "moved", "started", "result"])
        XCTAssertEqual(lines[0]["agentId"] as? String, lines[2]["agentId"] as? String)
        XCTAssertEqual(lines[0]["provider"] as? String, "codex")
        XCTAssertEqual(lines[2]["provider"] as? String, "antigravity")
    }

    /// A limit partway through hands the work to the next attempt, in the folder it was left in, with the task
    /// again and the previous thread to read. The caller sees one start, a move, and the final report.
    func testALimitPartwayHandsTheWorkToTheNextAttempt() async throws {
        let id = "fb-" + UUID().uuidString
        var after = limited()
        after.toolUses = 2
        after.sessionID = "codex-thread-1"
        after.directory = "/tmp/wt"
        FakeCodex.script = { _, events in events.started("Codex", "gpt-6.1-sol"); return after }
        FakeAntigravity.script = { [self] _, events in events.started("Antigravity", "gemini-4-argon"); return answered("Antigravity") }
        await AgentRun.runDefined(definition(), try request(#","isolation":"worktree""#), agentID: id, resume: nil, mcpConfig: nil)
        XCTAssertEqual(types(), ["started", "moved", "result"])
        XCTAssertEqual(lines.last?["text"] as? String, "done")
        let job = try XCTUnwrap(FakeAntigravity.calls.first)
        XCTAssertEqual(job.cwd, "/tmp/wt")
        XCTAssertFalse(job.worktree, "it continues in the worktree the work is in, not a new one")
        XCTAssertTrue(job.prompt.contains("codex-thread-1"))
        XCTAssertTrue(job.prompt.contains(id))
        XCTAssertTrue(job.prompt.contains(AgentRun.logURL(id).path))
        XCTAssertTrue(job.prompt.hasSuffix("\n\np"), "the original task comes again")
    }

    func testALimitPartwayOnTheLastAttemptIsTheCallersError() async throws {
        var after = limited()
        after.toolUses = 2
        FakeCodex.script = { _, events in events.started("Codex", "gpt-6.1-sol"); return after }
        await AgentRun.runDefined(definition(fallbacks: []), try request(), agentID: "fb-" + UUID().uuidString, resume: nil, mcpConfig: nil)
        XCTAssertEqual(types(), ["started", "result"])
        XCTAssertEqual(lines.last?["isError"] as? Bool, true)
    }

    func testAHandoverNobodyCanTakeSaysTheWorkWasStarted() async throws {
        let id = "fb-" + UUID().uuidString
        var after = limited()
        after.toolUses = 2
        FakeCodex.script = { _, events in events.started("Codex", "gpt-6.1-sol"); return after }
        FakeAntigravity.script = { [self] _, _ in limited() }
        await AgentRun.runDefined(definition(), try request(), agentID: id, resume: nil, mcpConfig: nil)
        XCTAssertEqual(types(), ["started", "moved", "result"])
        let text = try XCTUnwrap(lines.last?["text"] as? String)
        XCTAssertTrue(text.contains("stopped partway"), text)
        XCTAssertTrue(text.contains(AgentRun.logURL(id).path), text)
    }

    func testOtherErrorsDoNotFallBackEither() async throws {
        FakeCodex.script = { _, events in
            events.started("Codex", "gpt-6.1-sol")
            return .init(text: "Codex app-server stopped without an answer.", isError: true, limitReached: false, turns: 0, permissionDenials: 0)
        }
        await AgentRun.runDefined(definition(), try request(), agentID: "fb-" + UUID().uuidString, resume: nil, mcpConfig: nil)
        XCTAssertTrue(FakeAntigravity.calls.isEmpty)
        XCTAssertEqual(lines.last?["text"] as? String, "Codex app-server stopped without an answer.")
    }

    func testAStopEndsTheWholeChain() async throws {
        let id = "fb-" + UUID().uuidString
        FakeCodex.script = { [self] _, _ in AgentRegistry.markStopped(id); return limited() }
        FakeAntigravity.script = { _, _ in fatalError("a stopped agent must not start another attempt") }
        await AgentRun.runDefined(definition(), try request(), agentID: id, resume: nil, mcpConfig: nil)
        XCTAssertTrue(FakeAntigravity.calls.isEmpty)
        XCTAssertFalse(types().contains("moved"))
        _ = AgentRegistry.takeStopped(id)
    }

    func testWhenEveryAttemptFailsEachIsListedAndNeverClaude() async throws {
        let two = [AgentFallback(provider: .antigravity, model: "gemini-4-argon", effort: nil), .init(provider: .zai, model: "glm-5.3", effort: nil)]
        FakeCodex.script = { [self] _, _ in limited() }
        FakeAntigravity.script = { _, _ in .init(text: "Antigravity needs sign-in.", isError: true, limitReached: false, turns: 0, permissionDenials: 0, unavailable: true) }
        FakeZAI.script = { _, _ in .init(text: "Add a Z.ai key.", isError: true, limitReached: false, turns: 0, permissionDenials: 0, unavailable: true) }
        await AgentRun.runDefined(definition(fallbacks: two), try request(), agentID: "fb-" + UUID().uuidString, resume: nil, mcpConfig: nil)
        XCTAssertEqual(types(), ["moved", "moved", "error"])
        let text = try XCTUnwrap(lines.last?["text"] as? String)
        for expected in ["gpt-6.1-sol", "Usage limit reached.", "gemini-4-argon", "needs sign-in", "glm-5.3", "Z.ai key"] {
            XCTAssertTrue(text.contains(expected), text)
        }
    }

    func testAFollowUpContinuesOnTheModelThatRanWithNoChain() async throws {
        FakeAntigravity.script = { [self] _, _ in limited() }
        FakeCodex.script = { _, _ in fatalError("no chain on a follow-up") }
        var ran = definition()
        ran.fallbacks = []
        ran.provider = .antigravity
        ran.model = "gemini-4-argon"
        let entry = AgentRegistry.Entry(account: "Antigravity", directory: "/tmp", sessionID: "s1", model: "gemini-4-argon", at: Date(), definition: ran)
        // Even a definition that still lists fallbacks doesn't chain on a resume.
        var withChain = ran
        withChain.fallbacks = [.init(provider: .codex, model: "gpt-6.1-sol", effort: nil)]
        await AgentRun.runDefined(withChain, try request(), agentID: "fb-" + UUID().uuidString, resume: entry, mcpConfig: nil)
        XCTAssertTrue(FakeCodex.calls.isEmpty)
        XCTAssertEqual(FakeAntigravity.calls.count, 1)
    }

    func testWithoutFallbacksNothingChangesInWhatIsReported() async throws {
        FakeCodex.script = { [self] _, _ in limited() }
        await AgentRun.runDefined(definition(fallbacks: []), try request(), agentID: "fb-" + UUID().uuidString, resume: nil, mcpConfig: nil)
        XCTAssertEqual(types(), ["error"])
        XCTAssertEqual(lines[0]["text"] as? String, "Usage limit reached.")
        FakeCodex.script = { [self] _, events in events.started("Codex", "m"); return answered("Codex") }
        lines = []
        await AgentRun.runDefined(definition(fallbacks: []), try request(), agentID: "fb-" + UUID().uuidString, resume: nil, mcpConfig: nil)
        XCTAssertNil(lines.last?["unavailable"])
        XCTAssertEqual(lines.last?["provider"] as? String, "codex")
    }

    func testTheCallsEffortWinsAndAnUnsupportedLevelSkipsToTheNextAttempt() async throws {
        FakeCodex.script = { _, _ in .init(text: "Codex model m doesn't support effort max.", isError: true, limitReached: false, turns: 0, permissionDenials: 0, unavailable: true) }
        FakeAntigravity.script = { [self] _, events in events.started("Antigravity", "gemini-4-argon"); return answered("Antigravity") }
        var d = definition()
        d.fallbacks = [.init(provider: .antigravity, model: "gemini-4-argon", effort: "low")]
        await AgentRun.runDefined(d, try request(#","effort":"max""#), agentID: "fb-" + UUID().uuidString, resume: nil, mcpConfig: nil)
        XCTAssertEqual(FakeCodex.calls.first?.effort, "max")
        XCTAssertEqual(FakeAntigravity.calls.first?.effort, "max")
        XCTAssertEqual(lines.last?["unavailable"] as? [String], ["gpt-6.1-sol"])
        FakeAntigravity.calls = []
        await AgentRun.runDefined(d, try request(), agentID: "fb-" + UUID().uuidString, resume: nil, mcpConfig: nil)
        XCTAssertEqual(FakeAntigravity.calls.first?.effort, "low")   // its own, when the call names none
    }

    func testAWorktreeMadeByAFailedAttemptIsGoneBeforeTheNext() async throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("lastdrop-fbwt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        func git(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", repo.path, "-c", "user.name=T", "-c", "user.email=t@example.test"] + args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0)
        }
        try git(["init", "--quiet", "-b", "main"])
        try git(["commit", "--quiet", "--allow-empty", "-m", "i"])
        let seen = Seen()
        FakeCodex.script = { job, _ in
            let made = try! AgentWorktree.create(in: job.cwd, agentID: job.agentID)
            var r = SubagentRunner.Result(text: "Usage limit reached.", isError: true, limitReached: true, turns: 0, permissionDenials: 0, directory: made.directory)
            r.account = "Codex"
            return r
        }
        FakeAntigravity.script = { job, events in
            // The same name is free again: a second worktree can be made, and the first one's folder is gone.
            seen.existedBefore = FileManager.default.fileExists(atPath: job.cwd + "/.claude/worktrees/agent-\(job.agentID)")
            let made = try! AgentWorktree.create(in: job.cwd, agentID: job.agentID)
            events.started("Antigravity", "gemini-4-argon")
            return .init(text: "done", isError: false, limitReached: false, turns: 1, permissionDenials: 0, toolUses: 1, directory: made.directory, account: "Antigravity")
        }
        let id = "wt" + String(UUID().uuidString.prefix(6)).lowercased()
        await AgentRun.runDefined(definition(), try request(#","isolation":"worktree""#, cwd: repo.path),
                                  agentID: id, resume: nil, mcpConfig: nil)
        XCTAssertFalse(seen.existedBefore)
        XCTAssertEqual(lines.last?["text"] as? String, "done")
    }

    private final class Seen: @unchecked Sendable { var existedBefore = true }

    // MARK: Catalog

    func testSummaryShowsTheChainAndIsUnchangedWithout() {
        XCTAssertEqual(definition().summary, "Codex · gpt-6.1-sol · high, then Antigravity · gemini-4-argon")
        XCTAssertEqual(definition(fallbacks: []).summary, "Codex · gpt-6.1-sol · high")
        var two = definition()
        two.fallbacks.append(.init(provider: .zai, model: "glm-5.3", effort: "max"))
        XCTAssertEqual(two.summary, "Codex · gpt-6.1-sol · high, then Antigravity · gemini-4-argon, then Z.ai · glm-5.3 · max")
    }

    func testFallbacksRoundTripAndOlderCatalogsStillLoad() throws {
        let stored = try JSONEncoder.lastdrop.encode(AgentCatalog(agents: [definition()], revision: 3))
        XCTAssertEqual(try JSONDecoder.lastdrop.decode(AgentCatalog.self, from: stored).agents.first?.fallbacks, definition().fallbacks)
        // No fallbacks: the key isn't written, so the catalog is as it was before.
        let plain = String(decoding: try JSONEncoder.lastdrop.encode(AgentCatalog(agents: [definition(fallbacks: [])], revision: 3)), as: UTF8.self)
        XCTAssertFalse(plain.contains("fallbacks"))
        let old = #"{"revision":4,"agents":[{"id":"122651C3-88A7-4BF2-B4B0-2C3B5ADE7404","name":"w","description":"d","provider":"codex","model":"m","enabled":true}]}"#
        let catalog = try JSONDecoder.lastdrop.decode(AgentCatalog.self, from: Data(old.utf8))
        XCTAssertEqual(catalog.agents.first?.fallbacks, [])
        XCTAssertTrue(catalog.agents.first?.enabled == true)
        // id and enabled stay required, as before.
        let noID = #"{"revision":4,"agents":[{"name":"w","description":"d","provider":"codex","model":"m","enabled":true}]}"#
        XCTAssertThrowsError(try JSONDecoder.lastdrop.decode(AgentCatalog.self, from: Data(noID.utf8)))
    }

    /// The definition as a version without fallbacks decodes it: the ledger entry holds one.
    private struct OldDefinition: Codable {
        var id: UUID; var name: String; var description: String; var provider: AgentProvider; var model: String
        var effort: String?; var enabled: Bool
    }

    func testAnOlderVersionStillReadsADefinitionWithFallbacks() throws {
        let made = definition()
        let data = try JSONEncoder.lastdrop.encode(made)
        let old = try JSONDecoder.lastdrop.decode(OldDefinition.self, from: data)
        XCTAssertEqual(old.model, "gpt-6.1-sol")
        let entry = AgentRegistry.Entry(account: "Codex", directory: "/w", sessionID: "s", at: Date(), definition: made)
        XCTAssertEqual(try JSONDecoder.lastdrop.decode(AgentRegistry.Entry.self, from: JSONEncoder.lastdrop.encode(entry)).definition, made)
    }

    func testEachFallbackNeedsAModelAndMayNotRepeat() {
        let catalog = AgentCatalog()
        XCTAssertNil(catalog.problem(with: definition()))
        XCTAssertNotNil(catalog.problem(with: definition(fallbacks: [.init(provider: .zai, model: "", effort: nil)])))
        let twice = AgentFallback(provider: .zai, model: "glm-5.3", effort: nil)
        XCTAssertNotNil(catalog.problem(with: definition(fallbacks: [twice, twice])))
        XCTAssertNil(catalog.problem(with: definition(fallbacks: [twice, .init(provider: .openrouter, model: "glm-5.3", effort: nil)])))
        // The same model at another effort is another attempt; at the same effort it repeats.
        XCTAssertNil(catalog.problem(with: definition(fallbacks: [.init(provider: .codex, model: "gpt-6.1-sol", effort: "low")])))
        XCTAssertNotNil(catalog.problem(with: definition(fallbacks: [.init(provider: .codex, model: "gpt-6.1-sol", effort: "high")])))
    }

    // MARK: Review fixes

    func testAStopBetweenTwoAttemptsStartsNoFurtherOne() async throws {
        let id = "fb-" + UUID().uuidString
        FakeCodex.script = { [self] _, _ in limited() }
        FakeAntigravity.script = { _, _ in fatalError("a stopped agent must not start another attempt") }
        // The stop lands right after the switch is announced, before the next attempt begins.
        AgentRun.sink = { [unowned self] line in
            lines.append(line)
            if line["type"] as? String == "moved" { AgentRegistry.markStopped(id) }
        }
        await AgentRun.runDefined(definition(), try request(), agentID: id, resume: nil, mcpConfig: nil)
        XCTAssertTrue(FakeAntigravity.calls.isEmpty)
        XCTAssertEqual(lines.last?["type"] as? String, "error")
        _ = AgentRegistry.takeStopped(id)
    }

    func testARunnerBetweenAttemptsCanStillBeFound() {
        let id = "fb-" + UUID().uuidString
        XCTAssertFalse(AgentRegistry.runnerAlive(id))
        AgentRegistry.setProcess(id, claude: 0)
        XCTAssertTrue(AgentRegistry.runnerAlive(id))
        XCTAssertNil(AgentRegistry.process(id))   // no process to end, only the chain
        AgentRegistry.setProcess(id, claude: nil)
        XCTAssertFalse(AgentRegistry.runnerAlive(id))
    }

    private func repo() throws -> URL {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("lastdrop-fbwt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: repo) }
        for args in [["init", "--quiet", "-b", "main"], ["commit", "--quiet", "--allow-empty", "-m", "i"]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", repo.path, "-c", "user.name=T", "-c", "user.email=t@example.test"] + args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
        }
        return repo
    }

    func testAWorktreeIsRemovedWhenNothingStartedEvenOnTheLastAttemptOrForOtherErrors() async throws {
        let repo = try repo()
        let made = Made()
        let bug = SubagentRunner.Result(text: "Codex needs user input.", isError: true, limitReached: false, turns: 0, permissionDenials: 0)
        FakeCodex.script = { job, _ in
            let w = try! AgentWorktree.create(in: job.cwd, agentID: job.agentID)
            made.path = w.path
            var r = bug
            r.directory = w.directory
            return r
        }
        // No fallback and a failure that isn't about availability: `fail` must not leave the worktree behind.
        await AgentRun.runDefined(definition(fallbacks: []), try request(#","isolation":"worktree""#, cwd: repo.path),
                                  agentID: "w1" + String(UUID().uuidString.prefix(5)).lowercased(), resume: nil, mcpConfig: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(made.path)))
        XCTAssertEqual(lines.last?["type"] as? String, "error")
        // The last attempt of a chain that never started.
        lines = []
        FakeAntigravity.script = { job, _ in
            let w = try! AgentWorktree.create(in: job.cwd, agentID: job.agentID)
            made.path = w.path
            var r = SubagentRunner.Result(text: "Usage limit reached.", isError: true, limitReached: true, turns: 0, permissionDenials: 0)
            r.directory = w.directory
            return r
        }
        FakeCodex.script = { _, _ in .init(text: "Usage limit reached.", isError: true, limitReached: true, turns: 0, permissionDenials: 0) }
        await AgentRun.runDefined(definition(), try request(#","isolation":"worktree""#, cwd: repo.path),
                                  agentID: "w2" + String(UUID().uuidString.prefix(5)).lowercased(), resume: nil, mcpConfig: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(made.path)))
    }

    private final class Made: @unchecked Sendable { var path: String? }

    func testFallbackRowsMoveAndRemoveByTheirOwnIdentity() throws {
        let a = AgentFallback(provider: .antigravity, model: "a", effort: nil)
        let b = AgentFallback(provider: .zai, model: "b", effort: nil)
        let c = AgentFallback(provider: .openrouter, model: "c", effort: nil)
        var d = definition(fallbacks: [a, b, c])
        d.fallbacks.move(c.id, by: -1)
        XCTAssertEqual(d.fallbacks.map(\.model), ["a", "c", "b"])
        d.fallbacks.move(a.id, by: -1)   // already first
        d.fallbacks.move(b.id, by: 1)    // already last
        XCTAssertEqual(d.fallbacks.map(\.model), ["a", "c", "b"])
        d.fallbacks.removeAll { $0.id == c.id }
        XCTAssertEqual(d.fallbacks.map(\.model), ["a", "b"])
        d.fallbacks.removeAll { $0.id == UUID() }
        XCTAssertEqual(d.fallbacks.count, 2)
        // The id isn't stored, and doesn't count in comparisons.
        XCTAssertFalse(String(decoding: try JSONEncoder.lastdrop.encode(a), as: UTF8.self).contains("\"id\""))
        XCTAssertEqual(try JSONDecoder.lastdrop.decode(AgentFallback.self, from: JSONEncoder.lastdrop.encode(a)), a)
        XCTAssertNotEqual(AgentFallback(provider: .zai, model: "b", effort: nil).id, b.id)
        XCTAssertEqual(AgentFallback(provider: .zai, model: "b", effort: nil), b)
    }

    func testModelMissingAndSignInErrorsOnTheClaudeRunnerCountAsUnavailable() {
        // OpenRouter's retired model answers with a 404 in `errors`, not in `result`.
        let retired = SubagentRunner.parse(["is_error": true, "result": "", "errors": ["No endpoints found for acme/old-model."], "api_error_status": 404],
                                           provider: .openrouter)
        XCTAssertTrue(retired.modelUnavailable)
        XCTAssertTrue(retired.failedToStart)
        let zai = SubagentRunner.parse(["is_error": true, "result": "API Error: 404 model glm-9 does not exist"], provider: .zai)
        XCTAssertTrue(zai.modelUnavailable)
        // A Claude account whose sign-in expired.
        let signedOut = SubagentRunner.parse(["is_error": true, "result": "Invalid authentication credentials", "api_error_status": 401])
        XCTAssertTrue(signedOut.unavailable)
        XCTAssertTrue(signedOut.failedToStart)
        // The plan phrases keep working, and a plain failure stays unavailable-free.
        XCTAssertTrue(SubagentRunner.parse(["is_error": true, "result": "Fable 5.1 requires usage credits. Switch to another model."]).modelUnavailable)
        let bug = SubagentRunner.parse(["is_error": true, "result": "Something broke."])
        XCTAssertFalse(bug.failedToStart)
    }

    func testSkippedModelsNameTheirProviderOnlyWhenTheNameRepeatsAndNeverIncludeTheLastFailure() async throws {
        let chain = [AgentFallback(provider: .zai, model: "gpt-6.1-sol", effort: nil), .init(provider: .antigravity, model: "gemini-4-argon", effort: nil)]
        FakeCodex.script = { [self] _, _ in limited() }
        FakeZAI.script = { _, _ in .init(text: "Add a key.", isError: true, limitReached: false, turns: 0, permissionDenials: 0, unavailable: true) }
        FakeAntigravity.script = { [self] _, events in events.started("Antigravity", "gemini-4-argon"); return answered("Antigravity") }
        await AgentRun.runDefined(definition(fallbacks: chain), try request(), agentID: "fb-" + UUID().uuidString, resume: nil, mcpConfig: nil)
        XCTAssertEqual(lines.last?["unavailable"] as? [String], ["Codex gpt-6.1-sol", "Z.ai gpt-6.1-sol"])
        // The last attempt started and failed before work: it is the failure, not one of the skipped.
        lines = []
        FakeAntigravity.script = { [self] _, events in events.started("Antigravity", "gemini-4-argon"); return limited() }
        await AgentRun.runDefined(definition(fallbacks: chain), try request(), agentID: "fb-" + UUID().uuidString, resume: nil, mcpConfig: nil)
        XCTAssertEqual(lines.last?["unavailable"] as? [String], ["Codex gpt-6.1-sol", "Z.ai gpt-6.1-sol"])
        XCTAssertTrue((lines.last?["text"] as? String)?.contains("gemini-4-argon") == true)
    }
}
