import XCTest
@testable import LastDrop

/// Runs on every account keep their conversations in the one `~/.claude/projects`, so usage has to tell the
/// accounts apart through the session ledger.
final class SharedConversationsTests: LastDropTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        SessionLedger.fileOverride = folder.appendingPathComponent("ledger.json")
    }

    override func tearDownWithError() throws {
        SessionLedger.fileOverride = nil
        try? FileManager.default.removeItem(at: folder)
    }

    private var home: URL { folder.appendingPathComponent("home", isDirectory: true) }
    private var shared: URL { home.appendingPathComponent(".claude/projects", isDirectory: true) }
    private var account: URL { home.appendingPathComponent(".claude-accounts/Work", isDirectory: true) }

    private func append(_ text: String, to path: URL) throws {
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
    }

    // MARK: Roots

    private func claudeRoots() throws -> [String] {
        UsageFiles.roots(home: home.path).filter { $0.kind == .claude }.map(\.path)
    }

    func testRootsHaveMainAndEachAccountsOwnRealProjects() throws {
        try FileManager.default.createDirectory(at: account.appendingPathComponent("projects/p"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: account.appendingPathComponent("projects/p"), withIntermediateDirectories: true)
        // No migration any more: a leftover `projects-before-sharing` is no root.
        XCTAssertEqual(try claudeRoots(), [shared.path, account.appendingPathComponent("projects").path])
    }

    func testRootsNeverWalkTheSameRealPathTwice() throws {
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
        // An account's `projects` that is a link to the main one is walked once, as the main root.
        try FileManager.default.createSymbolicLink(at: account.appendingPathComponent("projects"), withDestinationURL: shared)
        XCTAssertEqual(try claudeRoots(), [shared.path])
    }

    // MARK: The ledger says which account

    private func line(id: String, time: String) -> String {
        """
        {"type":"assistant","timestamp":"\(time)","sessionId":"s1","isSidechain":false,"cwd":"/work/app","requestId":"r-\(id)","message":{"id":"\(id)","model":"claude-opus-5-5","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":10,"output_tokens":5}}}

        """
    }

    private func updateRoots() throws -> String {
        let db = folder.appendingPathComponent("usage.sqlite").path
        let index = try XCTUnwrap(UsageIndex(path: db, roots: UsageFiles.roots(home: home.path), ledger: { UsageLedger() }))
        XCTAssertTrue(index.update())
        return db
    }

    /// The accounts whose rows the index recorded, straight from the database.
    private func accounts(_ db: String) throws -> [String] {
        let sqlite = try XCTUnwrap(SQLite(path: db))
        let query = try XCTUnwrap(sqlite.prepare("SELECT n.text FROM usage u JOIN name n ON n.id = u.account"))
        var names: [String] = []
        while query.next() { names.append(query.text(0) ?? "") }
        return names.sorted()
    }

    func testTheLedgerSaysWhichAccountASharedConversationRanOn() throws {
        SessionLedger.record(session: "s1", account: "Work")
        try FileManager.default.createDirectory(at: shared.appendingPathComponent("p"), withIntermediateDirectories: true)
        try line(id: "m1", time: "2026-10-30T16:25:03.424Z").write(to: shared.appendingPathComponent("p/s1.jsonl"), atomically: true, encoding: .utf8)
        try line(id: "m2", time: "2026-10-30T16:25:03.424Z").write(to: shared.appendingPathComponent("p/s2.jsonl"), atomically: true, encoding: .utf8)
        // A subagent transcript counts as the session its side folder belongs to.
        try FileManager.default.createDirectory(at: shared.appendingPathComponent("p/s1/subagents"), withIntermediateDirectories: true)
        try line(id: "m3", time: "2026-10-30T16:25:03.424Z").write(to: shared.appendingPathComponent("p/s1/subagents/agent-a.jsonl"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try accounts(updateRoots()), ["claude.Work", "claude.main"])
    }

    func testAnAccountFolderKeepsItsOwnAccount() throws {
        SessionLedger.record(session: "s1", account: "Work")
        try FileManager.default.createDirectory(at: account.appendingPathComponent("projects/p"), withIntermediateDirectories: true)
        try line(id: "m1", time: "2026-10-30T16:25:03.424Z").write(to: account.appendingPathComponent("projects/p/s1.jsonl"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try accounts(updateRoots()), ["claude.Work"])
    }

    func testLinesFromBeforeAForkDontCount() throws {
        // 2026-10-30T16:00Z: the 15:25 line was copied from the conversation the session forked from.
        let forked = Date(timeIntervalSince1970: Double(498_160) * 3600)
        let path = folder.appendingPathComponent("projects/p/s1.jsonl")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try line(id: "before", time: "2026-10-30T15:25:03.424Z").write(to: path, atomically: true, encoding: .utf8)
        try append(line(id: "after", time: "2026-10-30T16:25:03.424Z") + line(id: "after2", time: "2026-10-30T17:25:03.424Z"), to: path)
        let usage = UsageParser.claude(path.path, from: 0, forkedAt: forked, ledger: UsageLedger())
        XCTAssertEqual(usage.rows.count, 2)
        XCTAssertEqual(UsageParser.claude(path.path, from: 0, ledger: UsageLedger()).rows.count, 3)
    }
}
