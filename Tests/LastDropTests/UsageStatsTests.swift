import Foundation
import XCTest
@testable import LastDrop

final class UsageStatsTests: LastDropTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        SessionLedger.fileOverride = folder.appendingPathComponent("ledger.json")   // never the real one
    }

    override func tearDownWithError() throws {
        SessionLedger.fileOverride = nil
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ name: String, _ text: String) throws -> String {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func append(_ path: String, _ text: String) throws {
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try handle.close()
    }

    private func claudeLine(id: String = "msg_1", request: String = "req_1", model: String = "claude-opus-5-5", time: String = "2026-10-30T16:25:03.424Z",
                            session: String = "s1", input: Int = 100, output: Int = 50, read: Int = 1000, sidechain: Bool = false, agent: String? = nil,
                            cwd: String = "/work/app") -> String {
        let agentField = agent.map { "\"agentId\":\"\($0)\"," } ?? ""
        return """
        {"type":"assistant","timestamp":"\(time)","sessionId":"\(session)","isSidechain":\(sidechain),\(agentField)"cwd":"\(cwd)","requestId":"\(request)","message":{"id":"\(id)","model":"\(model)","content":[{"type":"text","text":"say \\"usage\\": {\\"output_tokens\\": 9}"}],"usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":\(read),"cache_creation_input_tokens":40,"cache_creation":{"ephemeral_5m_input_tokens":10,"ephemeral_1h_input_tokens":30}}}}

        """
    }

    private func index(_ path: String = "projects", account: String = "claude.main", kind: UsageFile.Kind = .claude) throws -> (UsageIndex, String) {
        let db = folder.appendingPathComponent("usage.sqlite").path
        let root = UsageFiles.Root(path: folder.appendingPathComponent(path).path, kind: kind, account: account)
        return (try XCTUnwrap(UsageIndex(path: db, roots: [root], ledger: { UsageLedger() })), db)
    }

    private func cube(_ db: String) throws -> UsageCube {
        try XCTUnwrap(UsageCube.load(path: db, sinceHour: 0) { $0 })
    }

    private let oct30 = Date(timeIntervalSince1970: 1_793_393_000)   // 2026-10-30, past 16:00 UTC

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // MARK: Reading JSON

    func testSkimReadsOnlyRealTopLevelKeys() {
        let json = #"{"text":"\"usage\":{\"a\":1}","nested":{"usage":{"a":2}},"list":[{"usage":3},"]"],"usage":{"a":4},"n":12,"b":true}"#
        var usage = "", number: Int64 = 0, flag = false, seen = 0
        Array(json.utf8).withUnsafeBufferPointer { bytes in
            JSONSkim.fields(bytes) { key, value in
                seen += 1
                if key.is("usage") { usage = String(decoding: value, as: UTF8.self) }
                if key.is("n") { number = value.int }
                if key.is("b") { flag = value.bool }
            }
        }
        XCTAssertEqual(usage, #"{"a":4}"#)
        XCTAssertEqual(number, 12)
        XCTAssertTrue(flag)
        XCTAssertEqual(seen, 6)
    }

    func testHoursMatchFoundation() {
        for (text, expected) in [("2026-10-30T16:25:03.424Z", 1_793_377_503.0), ("2024-02-29T00:00:00Z", 1_709_164_800.0), ("1970-01-01T01:00:00Z", 3600.0)] {
            let hour = Array(text.utf8).withUnsafeBufferPointer(\.utcHour)
            XCTAssertEqual(hour, Int32(expected / 3600), text)
        }
    }

    func testLinesLeaveAnUnfinishedLineForNextTime() throws {
        let long = String(repeating: "x", count: 3 << 20)
        let path = try write("a.jsonl", "one\n\(long)\nunfin")
        var seen: [Int] = []
        let end = UsageFiles.lines(path: path, from: 0) { seen.append($0.count) }
        XCTAssertEqual(seen, [3, long.count])
        try append(path, "ished\n")
        var rest: [String] = []
        XCTAssertGreaterThan(UsageFiles.lines(path: path, from: end) { rest.append(String(decoding: $0, as: UTF8.self)) }, end)
        XCTAssertEqual(rest, ["unfinished"])
    }

    // MARK: Claude

    func testClaudeSkipsReinjectedAndSyntheticRows() throws {
        let hook = claudeLine(id: "msg_hook_abc")
        let synthetic = claudeLine(id: "msg_2", model: "<synthetic>")
        let path = try write("a.jsonl", hook + synthetic + claudeLine(id: "msg_3") + #"{"type":"user","message":{"usage":"assistant"}}"# + "\n")
        let usage = UsageParser.claude(path, from: 0, ledger: UsageLedger())
        XCTAssertEqual(usage.rows.count, 1)
        XCTAssertEqual(usage.rows[0].tokens, UsageTokens(input: 100, cacheWrite: 10, cacheWriteLong: 30, cacheRead: 1000, output: 50))
        XCTAssertEqual(usage.models, ["claude-opus-5-5"])
    }

    func testClaudeSidechainIsAnAgent() throws {
        let path = try write("a.jsonl", claudeLine() + claudeLine(id: "msg_2", sidechain: true, agent: "a1"))
        let usage = UsageParser.claude(path, from: 0, ledger: UsageLedger())
        XCTAssertEqual(usage.sessions.map(\.key), ["claude:s1", "claude:a1"])
        XCTAssertEqual(usage.sessions.map(\.agent), [false, true])
    }

    func testClaudeSessionLastdropRanIsAnAgent() throws {
        let path = try write("a.jsonl", claudeLine())
        var ledger = UsageLedger()
        ledger.runs["s1"] = .init(sessionID: "s1", model: nil, directory: nil)
        XCTAssertEqual(UsageParser.claude(path, from: 0, ledger: ledger).sessions.first?.agent, true)
    }

    // MARK: Codex

    private func codexMeta(originator: String = "lastdrop", source: String = "\"vscode\"") -> String {
        """
        {"timestamp":"2026-10-30T11:00:00.000Z","type":"session_meta","payload":{"id":"t1","cwd":"/work/app","originator":"\(originator)","source":\(source),"git":{"repository_url":"git@github.com:acme/app.git"}}}

        """
    }

    private func codexTurn(time: String = "2026-10-30T11:00:05.000Z", model: String = "gpt-6.1-sol", input: Int = 1000, cached: Int = 800, running: Int? = nil) -> String {
        """
        {"timestamp":"\(time)","type":"turn_context","payload":{"model":"\(model)"}}
        {"timestamp":"\(time)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\(running ?? input + 20)},"last_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),"cache_write_input_tokens":0,"output_tokens":20,"total_tokens":\(input + 20)}}}}

        """
    }

    func testCodexRowsAreBilledNetOfCache() throws {
        let path = try write("rollout.jsonl", codexMeta() + codexTurn())
        let usage = UsageParser.codex(path, from: 0, context: UsageContext())
        XCTAssertEqual(usage.rows.first?.tokens, UsageTokens(input: 200, cacheRead: 800, output: 20))
        XCTAssertEqual(usage.sessions.first?.key, "codex:t1")
        XCTAssertEqual(usage.sessions.first?.agent, true)
        XCTAssertEqual(usage.directories, ["/work/app"])
        XCTAssertEqual(usage.context.repository, "git@github.com:acme/app.git")
    }

    func testCodexOwnSessionsAreNotAgentsButSpawnedOnesAre() throws {
        let own = try write("a.jsonl", codexMeta(originator: "Codex Desktop"))
        XCTAssertEqual(UsageParser.codex(own, from: 0, context: UsageContext()).context.agent, false)
        let spawned = try write("b.jsonl", codexMeta(originator: "Codex Desktop", source: #"{"subagent":{}}"#))
        XCTAssertEqual(UsageParser.codex(spawned, from: 0, context: UsageContext()).context.agent, true)
    }

    func testCodexContinuesFromSavedContext() throws {
        let path = try write("a.jsonl", codexMeta() + codexTurn())
        let first = UsageParser.codex(path, from: 0, context: UsageContext())
        try append(path, codexTurn(time: "2026-10-30T12:00:00.000Z").split(separator: "\n")[1] + "\n")
        let next = UsageParser.codex(path, from: first.end, context: first.context)
        XCTAssertEqual(next.rows.count, 1)
        XCTAssertEqual(next.models, ["gpt-6.1-sol"])
        XCTAssertEqual(next.sessions.first?.key, "codex:t1")
    }

    // MARK: Antigravity

    func testAntigravityNamesTheAgentsModel() throws {
        let path = try write("brain/c1/.system_generated/logs/transcript.jsonl", """
        {"step_index":0,"created_at":"2026-10-30T16:24:44Z","content":"You are argon, a subagent."}
        {"step_index":1,"created_at":"2026-10-30T16:24:44Z","input_tokens":70,"cache_read_tokens":5,"output_tokens":22}

        """)
        var ledger = UsageLedger()
        ledger.models["argon"] = "gemini-4-argon"
        let usage = UsageParser.antigravity(path, from: 0, context: UsageContext(), ledger: ledger)
        XCTAssertEqual(usage.models, ["gemini-4-argon"])
        XCTAssertEqual(usage.rows.first?.tokens, UsageTokens(input: 70, cacheRead: 5, output: 22))
        XCTAssertEqual(usage.sessions, [.init(key: "antigravity:c1", agent: true)])
    }

    // MARK: Prices

    func testPrices() throws {
        XCTAssertEqual(UsagePrice.of("claude-opus-5-5")?.rates.cacheRead, 0.2)
        XCTAssertEqual(UsagePrice.of("claude-opus-5")?.rates.input, 5)
        XCTAssertEqual(UsagePrice.of("claude-haiku-4-5-20251001")?.rates.input, 1)
        let astra = try XCTUnwrap(UsagePrice.of("gpt-6-astra"))
        XCTAssertEqual(astra.rates(sizeClass: UsagePrice.sizeClass(300_000), hour: 0).input, 20)
        XCTAssertEqual(astra.rates(sizeClass: UsagePrice.sizeClass(300_000), hour: 0).output, 75)
        XCTAssertEqual(astra.rates(sizeClass: UsagePrice.sizeClass(272_000), hour: 0).input, 10)
        XCTAssertNil(UsagePrice.of("codex-auto-review"))
        let tokens = UsageTokens(input: 1_000_000, cacheWrite: 1_000_000, cacheWriteLong: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)
        XCTAssertEqual(try XCTUnwrap(UsagePrice.of("claude-opus-5-5")).rates.cost(tokens), 4 + 5 + 8 + 0.2 + 20, accuracy: 1e-9)
    }

    func testGeminiPricesDoubleOnTheirDates() throws {
        let argon = try XCTUnwrap(UsagePrice.of("gemini-4-argon"))
        let december = Int32(Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: .gmt, year: 2026, month: 12, day: 1))!.timeIntervalSince1970 / 3600)
        XCTAssertEqual(argon.rates(sizeClass: 0, hour: december - 1).input, 2)
        XCTAssertEqual(argon.rates(sizeClass: 0, hour: december).input, 4)
    }

    func testDisplayNames() {
        XCTAssertEqual(UsagePrice.displayName("claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(UsagePrice.displayName("claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(UsagePrice.displayName("gpt-6.1-sol"), "GPT-6.1 Sol")
        XCTAssertEqual(UsagePrice.displayName("gemini-4-argon"), "Gemini 4 Argon")
    }

    // MARK: Project names

    func testWorktreesCountAsTheirRepository() throws {
        let repo = folder.appendingPathComponent("code/app")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("Sources/Views"), withIntermediateDirectories: true)
        let worktree = try write("elsewhere/feature/.git", "gitdir: \(repo.path)/.git/worktrees/feature\n")
        var names = ProjectNames(home: folder.path)
        XCTAssertEqual(names.name(directory: repo.appendingPathComponent("Sources/Views").path), "app")
        XCTAssertEqual(names.name(directory: URL(fileURLWithPath: worktree).deletingLastPathComponent().path), "app")
    }

    func testDirectoriesThatAreGone() {
        var names = ProjectNames(home: "/Users/me")
        XCTAssertEqual(names.name(directory: "/private/tmp/x/y"), ProjectNames.scratch)
        XCTAssertEqual(names.name(directory: "/gone/tool/.claude/worktrees/a"), "tool")
        XCTAssertEqual(names.name(directory: "/gone/sic-worktrees/novelcore"), "sic")
        XCTAssertEqual(names.name(directory: "/Users/me/.codex/worktrees/ab12/app"), "app")
        XCTAssertEqual(names.name(directory: "/private/tmp/w", repository: "git@github.com:acme/app.git"), "app")
    }

    // MARK: The index

    func testReadsOnlyWhatsNew() throws {
        let path = try write("projects/p/a.jsonl", claudeLine())
        let (index, db) = try index()
        XCTAssertTrue(index.update())
        XCTAssertFalse(index.update())
        XCTAssertEqual(try cube(db).rows.reduce(0) { $0 + $1.tokens }, 1190)
        try append(path, claudeLine(id: "msg_2"))
        XCTAssertTrue(index.update())
        XCTAssertEqual(try cube(db).rows.reduce(0) { $0 + $1.tokens }, 2380)
    }

    func testRepeatedRowsAndCopiedSessionsCountOnce() throws {
        let line = claudeLine()
        _ = try write("projects/p/a.jsonl", line + line + line)
        let (first, db) = try index()
        first.update()
        _ = try write("copy/projects/p/a.jsonl", line)
        let root = UsageFiles.Root(path: folder.appendingPathComponent("copy/projects").path, kind: .claude, account: "claude.other")
        let second = try XCTUnwrap(UsageIndex(path: db, roots: [root], ledger: { UsageLedger() }))
        XCTAssertFalse(second.update())
        let rows = try cube(db).rows
        XCTAssertEqual(rows.reduce(0) { $0 + $1.tokens }, 1190)
    }

    func testARewrittenFileIsNotCountedTwice() throws {
        let path = try write("projects/p/a.jsonl", claudeLine() + claudeLine(id: "msg_2"))
        let (index, db) = try index()
        index.update()
        try claudeLine().write(toFile: path, atomically: false, encoding: .utf8)
        index.update()
        XCTAssertEqual(try cube(db).rows.reduce(0) { $0 + $1.tokens }, 2380)
    }

    func testAReplacedFileIsReadFromTheStart() throws {
        let path = try write("projects/p/a.jsonl", claudeLine())
        let (index, db) = try index()
        index.update()
        try FileManager.default.removeItem(atPath: path)
        Thread.sleep(forTimeInterval: 1.1)   // Dates here are in whole seconds.
        _ = try write("projects/p/a.jsonl", claudeLine(id: "msg_2", output: 1000) + claudeLine(id: "msg_3"))
        index.update()
        XCTAssertEqual(try cube(db).rows.reduce(0) { $0 + $1.tokens }, 1190 + 2140 + 1190)
    }

    func testCodexRepeatedEventsCountOnce() throws {
        let turn = codexTurn(time: "2026-10-30T11:00:05.000Z", running: 5000)
        let again = codexTurn(time: "2026-10-30T11:00:09.000Z", running: 5000)
        let next = codexTurn(time: "2026-10-30T11:00:12.000Z", running: 6000)
        _ = try write("sessions/a.jsonl", codexMeta() + turn + again + next)
        let (index, db) = try index("sessions", account: "codex.main", kind: .codex)
        index.update()
        XCTAssertEqual(try cube(db).rows.reduce(0) { $0 + $1.tokens }, 2040)
    }

    func testClaudeOutputGrowsAcrossLinesAndScans() throws {
        let path = try write("projects/p/a.jsonl", claudeLine(output: 7) + claudeLine(output: 50))
        let (index, db) = try index()
        index.update()
        XCTAssertEqual(try cube(db).rows.reduce(0) { $0 + $1.tokens }, 1190)
        try append(path, claudeLine(output: 185))
        index.update()
        XCTAssertEqual(try cube(db).rows.reduce(0) { $0 + $1.tokens }, 1325)
        try append(path, claudeLine(output: 7))
        index.update()
        XCTAssertEqual(try cube(db).rows.reduce(0) { $0 + $1.tokens }, 1325)
    }

    func testADamagedDatabaseIsReplaced() throws {
        _ = try write("projects/p/a.jsonl", claudeLine())
        try Data(repeating: 0x41, count: 8192).write(to: folder.appendingPathComponent("usage.sqlite"))
        let (index, path) = try index()
        XCTAssertTrue(index.update())
        XCTAssertEqual(try cube(path).rows.count, 1)
    }

    func testAnUnreadableFileReportsIt() {
        XCTAssertEqual(UsageFiles.lines(path: folder.appendingPathComponent("none").path, from: 0) { _ in }, -1)
    }

    func testOldFilesAreSkippedOnTheFirstScan() throws {
        let path = try write("projects/p/a.jsonl", claudeLine())
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -100 * 86400)], ofItemAtPath: path)
        let (index, _) = try index()
        XCTAssertFalse(index.update())
    }

    func testLongCodexPromptsPayLongRates() throws {
        _ = try write("sessions/a.jsonl", codexMeta() + codexTurn(input: 300_000, cached: 0))
        let (index, db) = try index("sessions", account: "codex.main", kind: .codex)
        index.update()
        // 2 × $2 input, 1.5 × $10 output.
        XCTAssertEqual(Double(try XCTUnwrap(try cube(db).rows.first).usd), 0.3 * 4 + 0.00002 * 15, accuracy: 1e-5)
    }

    // MARK: Pages

    private func row(_ hour: Int32, session: Int32, usd: Float = 1, model: UInt16 = 0, project: UInt16 = 0, account: UInt16 = 0, provider: UInt8 = 0, agent: Bool = false) -> UsageCube.Row {
        .init(hour: hour, session: session, usd: usd, tokens: 100, model: model, project: project, account: account, provider: provider, agent: agent)
    }

    private func sample() -> UsageCube {
        var cube = UsageCube()
        cube.models = [("Opus 5.5", .claude), ("GPT-6.1 Sol", .codex)]
        cube.projects = ["app", "tool"]
        cube.accounts = [("Claude", .claude), ("Codex", .codex)]
        cube.sessionCount = 5
        let now = Int32(oct30.timeIntervalSince1970 / 3600)
        cube.rows = [
            row(now - 24 * 8, session: 0),                                 // before the week
            row(now - 24 * 2, session: 1, agent: true),
            row(now - 24 * 2 + 1, session: 1, agent: true),                // one agent, two hours
            row(now - 24, session: 2, model: 1, project: 1, account: 1, provider: 1, agent: true),
            row(now, session: 3),
            row(now, session: 4, project: 1),
        ]
        cube.firstHour = [now - 24 * 14, now - 24, .max]
        return cube
    }

    func testPeriods() {
        let cube = sample()
        let today = cube.page(StatsSelection(period: .today), now: oct30, calendar: utc)
        XCTAssertEqual(today.usd, 2)
        XCTAssertEqual(today.sessions, 2)
        XCTAssertEqual(today.bars.count, 24)
        let week = cube.page(StatsSelection(period: .week), now: oct30, calendar: utc)
        XCTAssertEqual(week.usd, 5)
        XCTAssertEqual(week.agents, 2)
        XCTAssertEqual(week.sessions, 2)
        XCTAssertEqual(week.bars.count, 7)
        XCTAssertEqual(week.bars.map(\.total).reduce(0, +), 5)
        XCTAssertEqual(week.change, 4)
    }

    func testTablesCountDistinctAgents() {
        let week = sample().page(StatsSelection(period: .week), now: oct30, calendar: utc)
        XCTAssertEqual(week.projects.map(\.name), ["app", "tool"])
        XCTAssertEqual(week.projects.map(\.agents), [1, 1])
        XCTAssertEqual(week.accounts.first?.usd, 4)
        XCTAssertEqual(week.models.last?.name, "GPT-6.1 Sol")
    }

    func testPickingABarNarrowsTheNumbersNotTheBars() {
        let cube = sample()
        var selection = StatsSelection(period: .week)
        selection.day = cube.page(selection, now: oct30, calendar: utc).bars[4].start
        let day = cube.page(selection, now: oct30, calendar: utc)
        XCTAssertEqual(day.usd, 2)
        XCTAssertEqual(day.agents, 1)
        XCTAssertEqual(day.bars.count, 7)
        XCTAssertEqual(day.bars.map(\.total).reduce(0, +), 5)
    }

    func testAProjectSplitsAgentsFromItsUser() {
        let page = sample().page(StatsSelection(period: .week, project: "app"), now: oct30, calendar: utc)
        XCTAssertEqual(page.usd, 3)
        XCTAssertEqual(page.work.map(\.name), ["Agents", "You"])
        XCTAssertEqual(page.work.map(\.usd), [2, 1])
        XCTAssertEqual(page.models.map(\.usd), [2])   // its agents' only
    }

    func testADayWithAnExtraHourHasABarForEachHour() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let fallBack = Date(timeIntervalSince1970: 1_792_962_000)   // 2026-10-25, 25 hours in Paris
        XCTAssertEqual(UsageCube().page(StatsSelection(period: .today), now: fallBack, calendar: calendar).bars.count, 25)
    }

    func testChangeNeedsHistoryThatFarBack() {
        var cube = sample()
        cube.firstHour = [Int32(oct30.timeIntervalSince1970 / 3600), .max, .max]
        XCTAssertNil(cube.page(StatsSelection(period: .week), now: oct30, calendar: utc).change)
    }

    func testAnEmptyCubeHasAnEmptyPage() {
        let page = UsageCube().page(StatsSelection(), now: oct30, calendar: utc)
        XCTAssertEqual(page.usd, 0)
        XCTAssertEqual(page.bars.count, 7)
    }
}

extension ParsedUsage.Session: Equatable {
    public static func == (a: Self, b: Self) -> Bool { a.key == b.key && a.agent == b.agent }
}
