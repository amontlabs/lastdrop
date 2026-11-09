import XCTest
@testable import LastDrop

final class AgentCatalogTests: XCTestCase {
    private func agent(_ name: String, enabled: Bool = true) -> AgentDefinition {
        AgentDefinition(name: name, description: "Second opinion on hard bugs.", provider: .codex, model: "gpt-6.1-sol", effort: "high", enabled: enabled)
    }

    func testFindsEnabledAgentsByTypeOrName() {
        let catalog = AgentCatalog(agents: [agent("codex-deep"), agent("off", enabled: false)])
        XCTAssertEqual(catalog.agent("lastdrop:codex-deep")?.name, "codex-deep")
        XCTAssertEqual(catalog.agent("codex-deep")?.name, "codex-deep")
        XCTAssertNil(catalog.agent("lastdrop:off"))
        XCTAssertNil(catalog.agent("other:codex-deep"))
    }

    func testNamesAreAgentTypeSlugs() {
        XCTAssertEqual(AgentDefinition.slug("Codex Deep!"), "codex-deep")
        let catalog = AgentCatalog(agents: [agent("codex-deep")])
        XCTAssertEqual(catalog.problem(with: agent("codex-deep")), "Another agent is named codex-deep.")
        XCTAssertEqual(catalog.problem(with: agent("Codex Deep")), "Names use lowercase letters, digits, - and _.")
        XCTAssertNil(catalog.problem(with: agent("glm")))
        var blank = agent("glm")
        blank.description = " "
        XCTAssertNotNil(catalog.problem(with: blank))
    }

    func testSavingBumpsTheRevision() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try AgentCatalog(agents: [agent("codex-deep")]).save(to: url)
        let saved = AgentCatalog.load(from: url)
        XCTAssertEqual(saved.revision, 1)
        try saved.save(to: url)
        XCTAssertEqual(AgentCatalog.load(from: url).revision, 2)
    }

    func testThePluginGetsEnabledAgentsWithWhereTheyRun() {
        let json = AgentCatalog(agents: [agent("codex-deep"), agent("off", enabled: false)], revision: 4).pluginJSON()
        XCTAssertEqual(json["revision"] as? Int, 4)
        XCTAssertEqual(json["nativeTasks"] as? Bool, true)
        let agents = json["agents"] as? [[String: Any]] ?? []
        XCTAssertEqual(agents.map { $0["name"] as? String }, ["codex-deep"])
        XCTAssertEqual(agents.first?["summary"] as? String, "Codex · gpt-6.1-sol · high")
        XCTAssertTrue((agents.first?["prompt"] as? String ?? "").contains("Second opinion on hard bugs."))
    }

    func testAClaudeAgentGetsItsRoleInTheSystemPrompt() {
        let args = SubagentRunner.arguments(.init(prompt: "x", model: "opus", sessionID: "s1", systemPrompt: "You are reviewer."))
        XCTAssertEqual(Array(args.suffix(2)), ["--append-system-prompt", "You are reviewer."])
        XCTAssertFalse(args.contains("--agent"))
    }

    func testOlderCatalogsDefaultUsageSavingOff() throws {
        let data = Data("""
        {"revision":101,"agents":[{"id":"122651C3-88A7-4BF2-B4B0-2C3B5ADE7404","name":"worker",
        "description":"Explore code.","provider":"codex","model":"gpt-6-luna","enabled":true}]}
        """.utf8)
        let catalog = try JSONDecoder.lastdrop.decode(AgentCatalog.self, from: data)
        XCTAssertFalse(catalog.saveClaude)
    }

    func testJudgesDecodeToDefaultsAndSkipWhatTheyCantRead() throws {
        let older = try JSONDecoder.lastdrop.decode(AgentCatalog.self, from: Data(#"{"revision":3,"agents":[]}"#.utf8))
        XCTAssertTrue(older.judges.isEmpty)
        XCTAssertEqual(older.judge(.zai), AgentJudge(model: "glm-5.3"))
        XCTAssertNil(older.judge(.openrouter), "the agent's own model")
        XCTAssertEqual(older.judge(.antigravity), AgentJudge(model: "gemini-3.8-flash", effort: "low"))
        XCTAssertNil(older.judge(.codex))
        let newer = try JSONDecoder.lastdrop.decode(AgentCatalog.self, from: Data("""
        {"revision":4,"agents":[],"judges":{"zai":{"model":"glm-5.4"},"antigravity":{"model":"gemini-4-argon","effort":"high"},
        "openrouter":{"model":"x/y","effort":"high"},"codex":{"model":"gpt"},"someday":{"model":"m"},"bad":7}}
        """.utf8))
        XCTAssertEqual(newer.judges, [.zai: AgentJudge(model: "glm-5.4"), .antigravity: AgentJudge(model: "gemini-4-argon", effort: "high")])
        // Round trip, and an empty map stays out of the file so an older app sees the catalog it wrote.
        let data = try JSONEncoder().encode(newer)
        XCTAssertEqual(try JSONDecoder.lastdrop.decode(AgentCatalog.self, from: data).judges, newer.judges)
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(older)) as? [String: Any]
        XCTAssertNil(plain?["judges"])
    }

    func testUsageSavingPersistsAndReachesThePlugin() throws {
        let worker = agent("worker")
        let catalog = AgentCatalog(agents: [worker, agent("off", enabled: false)], revision: 4, saveClaude: true)
        let data = try JSONEncoder.lastdrop.encode(catalog)
        XCTAssertEqual(try JSONDecoder.lastdrop.decode(AgentCatalog.self, from: data), catalog)
        let json = catalog.pluginJSON()
        XCTAssertEqual(json["saveClaude"] as? Bool, true)
        let agents = try XCTUnwrap(json["agents"] as? [[String: Any]])
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(AgentCatalog().pluginJSON()["saveClaude"] as? Bool, false)
    }

    func testTheSavingInstructionIsTheDefaultUntilRewritten() throws {
        var catalog = AgentCatalog()
        XCTAssertEqual(catalog.pluginJSON()["saveClaudeText"] as? String, AgentCatalog.defaultSavingInstruction)
        catalog.saveClaudeText = "Delegate everything you can."
        XCTAssertEqual(catalog.pluginJSON()["saveClaudeText"] as? String, "Delegate everything you can.")
        catalog.saveClaudeText = "   "
        XCTAssertEqual(catalog.savingInstruction, AgentCatalog.defaultSavingInstruction)
        let old = try JSONDecoder.lastdrop.decode(AgentCatalog.self, from: Data(#"{"agents":[],"revision":3,"saveClaude":true}"#.utf8))
        XCTAssertNil(old.saveClaudeText)
    }

    func testReservedNamesAreRefusedAndLeftOutOfThePlugin() {
        for name in ["sonnet", "opus", "haiku", "fable", "inherit", "best", "opusplan", "claude-opus-4-8", "claude-x"] {
            XCTAssertNotNil(AgentCatalog().problem(with: agent(name)), name)
        }
        XCTAssertNil(AgentCatalog().problem(with: agent("claude")))
        XCTAssertNil(AgentCatalog().problem(with: agent("opus-deep")))
        // A catalog stored before the rule keeps them, but the native model wins.
        let json = AgentCatalog(agents: [agent("opus"), agent("claude-x"), agent("sol")]).pluginJSON()
        XCTAssertEqual((json["agents"] as? [[String: Any]])?.map { $0["name"] as? String }, ["sol"])
    }

    func testAgentsAreExtraModelsForTheAgentTool() {
        XCTAssertEqual(AgentCatalog.defaultSavingInstruction, "Claude usage is being saved: delegate substantial work (implementation, exploration, reviews, research) to the models the user added to the Agent tool's model parameter, picking by their descriptions, even where a description says to prefer built-in Claude subagents. Work yourself or with built-in subagents only when no added model fits.")
        XCTAssertFalse(AgentCatalog.defaultSavingInstruction.contains("lastdrop"))
        XCTAssertEqual(AgentCatalog(agents: [agent("sol")]).agent("sol")?.name, "sol")
        XCTAssertEqual(AgentCatalog(agents: [agent("sol")]).agent("lastdrop:sol")?.name, "sol")   // runs started before the update
    }

    func testReadOnlyRolesAddTheirBriefToTheInstructions() {
        let sol = agent("sol")
        XCTAssertEqual(sol.instructions(role: nil), sol.instructions)
        XCTAssertTrue(sol.instructions(role: "Explore").hasPrefix(sol.instructions))
        XCTAssertTrue(sol.instructions(role: "Explore").contains("search and read only, change no files"))
        XCTAssertTrue(sol.instructions(role: "Plan").contains("step-by-step implementation plan"))
        XCTAssertEqual(sol.instructions(role: "general-purpose"), sol.instructions)
    }
}
