import XCTest
@testable import LastDrop

/// Failover keeps the transcript, the ledger's replace and prune rules, the reaper's process and limit checks,
/// and the T3 settings rewrite.
final class ReviewFixesTests: LastDropTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lastdrop-fixes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        SessionTransfer.mainProjectsOverride = root.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("projects/p"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        SessionTransfer.mainProjectsOverride = nil
        T3Settings.userdataOverride = nil
        T3Settings.appOverride = nil
        T3Settings.backupOverride = nil
        ThreadLauncher.wrapperDirectory = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func transcript(_ id: String, _ text: String) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent("projects/p/\(id).jsonl"))
    }

    // MARK: 4

    func testFailoverLeavesTheOriginalTranscriptUntouched() async throws {
        let original = """
        {"type":"user","message":{"role":"user","content":"hi"}}
        {"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"You've hit your session limit"}]}}
        """
        try transcript("orig", original)
        let a = ClaudeAccount(id: "A")
        let entry = AgentRegistry.Entry(account: "A", directory: root.path, sessionID: "orig", model: nil, subagentType: nil, effort: nil, at: Date())
        let result = SubagentRunner.Result(text: "", isError: false, limitReached: true, turns: 1, permissionDenials: 0)
        // No other account: the loop ends before reaching a process.
        _ = await AgentRun.carryOn("fx", entry: entry, result: result, accounts: [a], config: ClaudeAccountsConfig(), own: nil,
                                   tried: [], permissionMode: "auto", mcpConfig: nil)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("projects/p/orig.jsonl"), encoding: .utf8), original)
    }

    // MARK: 7

    func testAFreshRecordReplacesASessionWithoutTranscript() {
        SessionLedger.record(session: "s", account: "A")
        SessionLedger.record(session: "s", account: "B")
        XCTAssertEqual(SessionLedger.session("s")?.account, "B")
    }

    func testARecordKeepsItsAccountOnceTheTranscriptHasLines() throws {
        SessionLedger.record(session: "s", account: "A")
        try transcript("s", "{\"type\":\"user\"}\n")
        SessionLedger.record(session: "s", account: "B")
        XCTAssertEqual(SessionLedger.session("s")?.account, "A")
        SessionLedger.record(session: "s", account: "C", replace: true)
        XCTAssertEqual(SessionLedger.session("s")?.account, "C")
    }

    func testAForkRecordNeverReplaces() {
        SessionLedger.record(session: "s", account: "A")
        SessionLedger.record(session: "s", account: "B", forkedAt: Date())
        XCTAssertEqual(SessionLedger.session("s")?.account, "A")
    }

    // MARK: 11

    func testSameProcessChecksStartTimeThenName() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["30"]
        try proc.run()
        defer { if proc.isRunning { proc.terminate() } }
        let pid = proc.processIdentifier
        let real = try XCTUnwrap(SessionLedger.processStart(pid))
        var entry = SessionLedger.Live(pid: pid, account: "A", session: "s", thread: "t", at: Date(), startedAt: real)
        XCTAssertTrue(SessionLedger.isSameProcess(entry))
        entry.startedAt = real.addingTimeInterval(-3600)   // the pid was another process then
        XCTAssertFalse(SessionLedger.isSameProcess(entry))
        entry.startedAt = nil   // unknown: checked by name, and sleep is not claude
        XCTAssertFalse(SessionLedger.isSameProcess(entry))
    }

    func testReaperSkipsAReusedPid() throws {
        let projects = root.appendingPathComponent("rp")
        try FileManager.default.createDirectory(at: projects.appendingPathComponent("p"), withIntermediateDirectories: true)
        ThreadReaper.projectsDirOverride = projects
        defer { ThreadReaper.projectsDirOverride = nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["30"]
        try proc.run()
        defer { if proc.isRunning { proc.terminate() } }
        let file = projects.appendingPathComponent("p/s.jsonl")
        try Data(#"{"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"You've hit your session limit"}]}}"#.utf8)
            .write(to: file)
        SessionLedger.addLive(.init(pid: proc.processIdentifier, account: "A", session: "s", thread: "t",
                                    at: Date().addingTimeInterval(-60), startedAt: Date().addingTimeInterval(-3600)))
        ThreadReaper.check()
        XCTAssertTrue(proc.isRunning)
        XCTAssertTrue(SessionLedger.live().first { $0.pid == proc.processIdentifier } == nil)
    }

    func testOldLiveEntriesWithoutAStartDecode() throws {
        let json = #"{"sessions":{},"threads":{},"live":[{"pid":1,"account":"A","session":"s","thread":"t","at":1793098000}]}"#
        let store = try JSONDecoder.lastdrop.decode(SessionLedger.Store.self, from: Data(json.utf8))
        XCTAssertEqual(store.live.count, 1)
        XCTAssertNil(store.live.first?.startedAt)
    }

    func testAModelLimitIsNotAnAccountLimit() {
        func notice(_ text: String) -> Data {
            Data(#"{"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"\#(text)"}]}}"#.utf8)
        }
        XCTAssertEqual(ThreadReaper.limit(tail: notice("You've hit your Opus limit")), .model)
        XCTAssertFalse(ThreadReaper.isLimitNotice(tail: notice("You've hit your Opus limit")))
        XCTAssertEqual(ThreadReaper.limit(tail: notice("You've hit your session limit")), .account)
        XCTAssertEqual(ThreadReaper.limit(tail: notice("Claude AI usage limit reached")), .account)
        XCTAssertEqual(ThreadReaper.limit(tail: notice("You've hit your weekly limit")), .account)
    }

    // MARK: 12

    private func useSettings() throws -> URL {
        let userdata = root.appendingPathComponent("userdata")
        try FileManager.default.createDirectory(at: userdata, withIntermediateDirectories: true)
        T3Settings.userdataOverride = userdata
        T3Settings.appOverride = root.appendingPathComponent("T3.app")
        T3Settings.backupOverride = root.appendingPathComponent("backup.json")
        ThreadLauncher.wrapperDirectory = root.appendingPathComponent("bin")
        return userdata.appendingPathComponent("settings.json")
    }

    func testSettingsKeepModeAndFormatting() throws {
        let file = try useSettings()
        try #"{"theme":"a/b","providerInstances":{}}"#.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        try T3Settings.enable(wrapper: "/w/claude-thread")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o640)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("\"theme\": \"a/b\""), text)
        XCTAssertTrue(text.contains("\"binaryPath\": \"/w/claude-thread\""), text)
        XCTAssertTrue(text.hasSuffix("}\n"))
    }

    func testColonsInsideStringsStay() {
        let out = String(decoding: T3Settings.tightenColons(Data(#"{"a" : "x \" : y" }"#.utf8)), as: UTF8.self)
        XCTAssertEqual(out, #"{"a": "x \" : y" }"#)
    }

    // MARK: 13

    func testPruneDropsTheOldestBeyondTheCapButNeverRecentOnes() {
        let now = Date()
        var store = SessionLedger.Store()
        for i in 0..<(SessionLedger.maxSessions + 10) {
            store.sessions["old\(i)"] = .init(account: "A", startedAt: now.addingTimeInterval(-40 * 86_400 - Double(i)))
        }
        SessionLedger.prune(&store, now: now)
        XCTAssertEqual(store.sessions.count, SessionLedger.maxSessions)
        XCTAssertNil(store.sessions["old\(SessionLedger.maxSessions + 9)"])
        XCTAssertNotNil(store.sessions["old0"])

        var recent = SessionLedger.Store()
        for i in 0..<(SessionLedger.maxSessions + 10) {
            recent.sessions["r\(i)"] = .init(account: "A", startedAt: now.addingTimeInterval(-Double(i)))
        }
        SessionLedger.prune(&recent, now: now)
        XCTAssertEqual(recent.sessions.count, SessionLedger.maxSessions + 10)
    }
}
