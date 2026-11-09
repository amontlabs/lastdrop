import Combine
import XCTest
@testable import LastDrop

final class AgentsCommandTests: LastDropTestCase {
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID().uuidString).json")
    }

    override func tearDown() {
        super.tearDown()
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + ".lock"))
    }

    private let offered = [AgentModel(id: "gpt-6.1-sol", name: "Sol", efforts: ["low", "high"], defaultEffort: nil)]

    @discardableResult
    private func run(_ args: String..., input: String = "", failing list: Error? = nil) async throws -> String {
        let offered = offered
        return try await AgentsCommand.run(args, stdin: { Data(input.utf8) }, models: { _ in
            if let list { throw list }
            return offered
        }, url: url)
    }

    private func sol(model: String = "gpt-6.1-sol", effort: String = "high", enabled: String = "") -> String {
        #"{"name":"sol","description":"Reviews.","models":[{"provider":"codex","model":"\#(model)","effort":"\#(effort)"}]\#(enabled)}"#
    }

    private func failure(_ args: String..., input: String = "") async -> String? {
        do {
            let offered = offered
            _ = try await AgentsCommand.run(args, stdin: { Data(input.utf8) }, models: { _ in offered }, url: url)
            return nil
        } catch { return error.localizedDescription }
    }

    func testHelpIsTheDefault() async throws {
        let help = try await run("--help")
        XCTAssertEqual(help, AgentsCommand.help)
        XCTAssertTrue(help.contains("codex"))
        let bare = try await AgentsCommand.run([], url: url)
        XCTAssertEqual(bare, AgentsCommand.help)
    }

    func testSetAddsThenReplacesByName() async throws {
        try await run("set", input: sol())
        let first = AgentCatalog.load(from: url).agents[0]
        XCTAssertEqual(first.summary, "Codex · gpt-6.1-sol · high")
        XCTAssertTrue(first.enabled)

        try await run("set", input: sol(effort: "low", enabled: #","enabled":false"#))
        let catalog = AgentCatalog.load(from: url)
        XCTAssertEqual(catalog.agents.count, 1)
        XCTAssertEqual(catalog.agents[0].id, first.id)
        XCTAssertEqual(catalog.agents[0].effort, "low")
        XCTAssertFalse(catalog.agents[0].enabled)

        // Left out, enabled stays as it was.
        try await run("set", input: sol())
        XCTAssertFalse(AgentCatalog.load(from: url).agents[0].enabled)
    }

    func testListPrintsWhatSetTakes() async throws {
        try await run("set", input: #"{"name":"sol","description":"Reviews.","models":[{"provider":"codex","model":"gpt-6.1-sol"},{"provider":"codex","model":"gpt-6.1-sol","effort":"low"}]}"#)
        let listed = try await run("list")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(listed.utf8)) as? [String: Any])
        XCTAssertEqual(json["saveClaude"] as? Bool, false)
        let agent = try XCTUnwrap((json["agents"] as? [[String: Any]])?.first)
        XCTAssertEqual((agent["models"] as? [[String: Any]])?.count, 2)

        try await run("set", input: String(decoding: try JSONSerialization.data(withJSONObject: agent), as: UTF8.self))
        let saved = AgentCatalog.load(from: url).agents
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].fallbacks.first?.effort, "low")
    }

    func testRefusalsSaveNothing() async throws {
        var message = await failure("set", input: sol(model: "gpt-guess"))
        XCTAssertEqual(message, "Codex doesn't offer gpt-guess. Run --agents models codex.")
        message = await failure("set", input: sol(effort: "max"))
        XCTAssertEqual(message, "gpt-6.1-sol takes low, high; received max.")
        message = await failure("set", input: #"{"name":"sol","description":"Reviews."}"#)
        XCTAssertEqual(message, "Couldn't read the agent: models is missing. See --agents --help.")
        message = await failure("set", input: #"{"name":"sol","description":"Reviews.","models":[]}"#)
        XCTAssertEqual(message, "Give the agent at least one model.")
        message = await failure("set", input: #"{"name":"sonnet","description":"Reviews.","models":[{"provider":"codex","model":"gpt-6.1-sol"}]}"#)
        XCTAssertEqual(message, "sonnet is a name Claude Code uses for its own models.")
        message = await failure("set", input: #"{"name":"Sol Deep","description":"Reviews.","models":[{"provider":"codex","model":"gpt-6.1-sol"}]}"#)
        XCTAssertEqual(message, "Names use lowercase letters, digits, - and _.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testAProviderThatCantListItsModelsLeavesAWarning() async throws {
        struct Offline: LocalizedError { var errorDescription: String? { "offline" } }
        let answer = try await run("set", input: sol(model: "gpt-new"), failing: Offline())
        XCTAssertTrue(answer.contains("Couldn't list Codex's models (offline), so its ids weren't checked."))
        XCTAssertEqual(AgentCatalog.load(from: url).agents[0].model, "gpt-new")
    }

    func testJudgeIsCheckedSavedListedAndReset() async throws {
        let models: (AgentProvider) async throws -> [AgentModel] = { provider in
            provider == .antigravity ? [AgentModel(id: "gemini-4-argon", name: "Argon", efforts: ["low", "high"], defaultEffort: nil)]
                : provider == .zai ? [AgentModel(id: "glm-5.4", name: "GLM", efforts: [], defaultEffort: nil)] : []
        }
        func run(_ args: String...) async throws -> String { try await AgentsCommand.run(args, models: models, url: url) }
        func failure(_ args: String...) async -> String? {
            do { _ = try await AgentsCommand.run(args, models: models, url: url); return nil } catch { return error.localizedDescription }
        }
        let listed = try await run("list")
        XCTAssertTrue(listed.contains(#""model" : "glm-5.3""#) && listed.contains("the agent's own model"), listed)
        try await run("judge", "antigravity", "gemini-4-argon", "high")
        try await run("judge", "zai", "glm-5.4")
        XCTAssertEqual(AgentCatalog.load(from: url).judges, [.antigravity: AgentJudge(model: "gemini-4-argon", effort: "high"),
                                                             .zai: AgentJudge(model: "glm-5.4")])
        let relisted = try await run("list")
        XCTAssertTrue(relisted.contains(#""model" : "gemini-4-argon""#))
        let missingModel = await failure("judge", "antigravity", "nope", "low")
        XCTAssertEqual(missingModel, "Antigravity doesn't offer nope. Run --agents models antigravity.")
        let missingEffort = await failure("judge", "antigravity", "gemini-4-argon", "max")
        XCTAssertEqual(missingEffort, "gemini-4-argon takes low, high; received max.")
        let effortOnZai = await failure("judge", "zai", "glm-5.4", "high")
        XCTAssertTrue(effortOnZai?.contains("takes no effort") ?? false)
        let codex = await failure("judge", "codex", "gpt-6.1-sol")
        XCTAssertTrue(codex?.contains("own reviewer") ?? false)
        // OpenRouter lists nothing here: the id is taken as it is.
        try await run("judge", "openrouter", "any/model")
        try await run("judge", "zai", "default")
        let catalog = AgentCatalog.load(from: url)
        XCTAssertNil(catalog.judges[.zai])
        XCTAssertEqual(catalog.judge(.zai), AgentJudge(model: "glm-5.3"))
        XCTAssertEqual(catalog.judge(.openrouter), AgentJudge(model: "any/model"))
    }

    func testRemoveAndSaving() async throws {
        try await run("set", input: sol())
        try await run("saving", "on")
        XCTAssertTrue(AgentCatalog.load(from: url).saveClaude)
        try await run("remove", "sol")
        XCTAssertTrue(AgentCatalog.load(from: url).agents.isEmpty)
        let missing = await failure("remove", "sol")
        XCTAssertEqual(missing, "No agent named sol.")
        let unknown = await failure("saving", "maybe")
        XCTAssertEqual(unknown, "Unknown command: saving maybe. See --agents --help.")
        let provider = await failure("models", "nope")
        XCTAssertEqual(provider, "No provider named nope. Use claude, codex, zai, openrouter, antigravity.")
    }

    func testACommandTellsOpenSettings() {
        let told = expectation(description: "the change reaches another process's listener")
        let listener = DistributedNotificationCenter.default().publisher(for: .agentCatalogChanged).sink { _ in told.fulfill() }
        defer { listener.cancel() }
        AgentsCommand.announce()
        wait(for: [told], timeout: 5)
    }

    func testConcurrentUpdatesAllLand() async throws {
        let url = url!
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    try? AgentCatalog.update(at: url) {
                        $0.agents.append(AgentDefinition(name: "a\(i)", description: "x", provider: .codex, model: "m"))
                    }
                }
            }
        }
        let catalog = AgentCatalog.load(from: url)
        XCTAssertEqual(catalog.agents.count, 20)
        XCTAssertEqual(catalog.revision, 20)
    }
}
