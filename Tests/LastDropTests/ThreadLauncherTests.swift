import XCTest
@testable import LastDrop

final class ThreadLauncherTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var ledgerFile: URL!
    private var projects: URL!

    override func setUpWithError() throws {
        ledgerFile = FileManager.default.temporaryDirectory.appendingPathComponent("lastdrop-tl-\(UUID().uuidString).json")
        projects = FileManager.default.temporaryDirectory.appendingPathComponent("lastdrop-tl-projects-\(UUID().uuidString)")
        SessionLedger.fileOverride = ledgerFile
        ThreadLauncher.projectsOverride = projects.path
    }

    override func tearDown() {
        SessionLedger.fileOverride = nil
        ThreadLauncher.projectsOverride = nil
        try? FileManager.default.removeItem(at: ledgerFile)
        try? FileManager.default.removeItem(at: projects)
    }

    // MARK: Helpers

    private func candidate(_ id: String, _ session: Double?, _ weekly: Double?) -> SubagentAccounts.Candidate {
        .init(account: ClaudeAccount(id: id), name: id, sessionUsed: session, weeklyUsed: weekly)
    }

    private func ledger(threads: [String: String] = [:], sessions: [String: String] = [:]) -> ThreadLauncher.Ledger {
        .init(currentSession: { threads[$0] ?? $0 }, account: { sessions[$0] })
    }

    /// The thread has answered `age` ago on its transcript; `compacted` puts a boundary after that answer.
    private func transcript(age: TimeInterval?, compacted: Bool = false) -> ThreadLauncher.Transcript {
        .init(lastAssistantAt: age.map { now.addingTimeInterval(-$0) }, justCompacted: compacted)
    }

    private func decide(_ args: [String], threads: [String: String] = [:], sessions: [String: String] = [:],
                        candidates: [SubagentAccounts.Candidate], transcript: ThreadLauncher.Transcript,
                        newSessionID: String = "moved-1", live: Bool = false) -> ThreadLauncher.Decision {
        let view = live ? .live : ledger(threads: threads, sessions: sessions)
        return ThreadLauncher.decide(args, ledger: view, candidates: candidates,
                                     transcript: transcript, now: now, newSessionID: { newSessionID })
    }

    // MARK: New threads

    func testNewThreadStartsOnTheRoomiestAccountAndRecordsIt() {
        let decision = decide(["--print", "--session-id", "X", "--verbose"],
                              candidates: [candidate("main", 50, 50), candidate("Pro", 10, 10)],
                              transcript: .cold)
        XCTAssertEqual(decision.account, "Pro")
        XCTAssertEqual(decision.action, .new)
        XCTAssertEqual(decision.args, ["--print", "--session-id", "X", "--verbose"])
        XCTAssertEqual(decision.writes, [.record(session: "X", account: "Pro", forkedAt: nil)])
        XCTAssertEqual(decision.session, "X")
    }

    func testANewThreadWithoutAnIdChangesNothingInTheLedger() {
        let decision = decide(["--print"], candidates: [candidate("main", 10, 10)], transcript: .cold)
        XCTAssertEqual(decision.account, "main")
        XCTAssertTrue(decision.writes.isEmpty)
    }

    // MARK: Staying warm

    func testAWarmThreadStays() {
        let decision = decide(["--resume", "X", "--verbose"], sessions: ["X": "A"],
                              candidates: [candidate("A", 10, 10), candidate("B", 0, 0)],
                              transcript: transcript(age: 10 * 60))
        XCTAssertEqual(decision.account, "A")
        XCTAssertEqual(decision.action, .stay)
        XCTAssertEqual(decision.args, ["--resume", "X", "--verbose"])
        XCTAssertTrue(decision.writes.isEmpty)
    }

    // MARK: Moving when it costs nothing

    func testAColdThreadMovesToTheRoomiestAccount() {
        let decision = decide(["--resume", "X", "--verbose"], sessions: ["X": "A"],
                              candidates: [candidate("A", 10, 10), candidate("B", 0, 0)],
                              transcript: transcript(age: 2 * 3600))
        XCTAssertEqual(decision.account, "B")
        XCTAssertEqual(decision.action, .move)
        XCTAssertEqual(decision.args, ["--resume", "X", "--verbose", "--fork-session", "--session-id", "moved-1"])
        XCTAssertEqual(decision.writes, [.record(session: "moved-1", account: "B", forkedAt: now),
                                         .current(session: "moved-1", thread: "X")])
        XCTAssertEqual(decision.session, "moved-1")
    }

    func testAJustCompactedThreadMovesEvenThoughItIsWarm() {
        let decision = decide(["--resume", "X"], sessions: ["X": "A"],
                              candidates: [candidate("A", 10, 10), candidate("B", 0, 0)],
                              transcript: transcript(age: 10 * 60, compacted: true))
        XCTAssertEqual(decision.action, .move)
        XCTAssertEqual(decision.account, "B")
    }

    func testAFullAccountMovesEvenWhenTheThreadIsWarm() {
        // The account is at its limit: it can't answer at all, so staying costs more than moving.
        let decision = decide(["--resume", "X"], sessions: ["X": "A"],
                              candidates: [candidate("A", 100, 100), candidate("B", 10, 10)],
                              transcript: transcript(age: 10 * 60))
        XCTAssertEqual(decision.action, .move)
        XCTAssertEqual(decision.account, "B")
    }

    func testAFullAccountWithNoOtherRoomStays() {
        let decision = decide(["--resume", "X"], sessions: ["X": "A"],
                              candidates: [candidate("A", 100, 100), candidate("B", 100, 100)],
                              transcript: transcript(age: 2 * 3600))
        XCTAssertEqual(decision.action, .stay)
        XCTAssertEqual(decision.account, "A")
    }

    func testAnUnreadableAccountCountsAsFull() {
        let decision = decide(["--resume", "X"], sessions: ["X": "A"],
                              candidates: [candidate("A", nil, nil), candidate("B", 10, 10)],
                              transcript: transcript(age: 10 * 60))
        XCTAssertEqual(decision.action, .move)
        XCTAssertEqual(decision.account, "B")
    }

    func testResumeSessionAtNeverMoves() {
        let decision = decide(["--resume", "X", "--resume-session-at", "msg-1"], sessions: ["X": "A"],
                              candidates: [candidate("A", 10, 10), candidate("B", 0, 0)],
                              transcript: transcript(age: 2 * 3600))
        XCTAssertEqual(decision.action, .stay)
        XCTAssertEqual(decision.account, "A")
        XCTAssertEqual(decision.args, ["--resume", "X", "--resume-session-at", "msg-1"])
    }

    // MARK: T3's own fork

    func testT3ForkPicksAFreshAccountAndRecordsItsSession() {
        let args = ["--resume", "X", "--fork-session", "--session-id", "M", "--verbose"]
        let decision = decide(args, sessions: ["X": "A"],
                              candidates: [candidate("A", 10, 10), candidate("B", 0, 0)],
                              transcript: transcript(age: 10 * 60))
        XCTAssertEqual(decision.action, .new)
        XCTAssertEqual(decision.account, "B")
        XCTAssertEqual(decision.args, args)
        XCTAssertEqual(decision.writes, [.record(session: "M", account: "B", forkedAt: now)])
        XCTAssertEqual(decision.session, "M")
    }

    // MARK: Argument forms

    func testEqualsFormOfFlagsIsParsedAndRewritten() {
        let parsed = ThreadLauncher.parse(["--print", "--resume=X", "--session-id=Y", "--fork-session", "--resume-session-at=Z"])
        XCTAssertEqual(parsed.resume, "X")
        XCTAssertEqual(parsed.sessionID, "Y")
        XCTAssertEqual(parsed.resumeSessionAt, "Z")
        XCTAssertTrue(parsed.forkSession)
        // A move rewrites the `=` form in place and drops the stray session id.
        let decision = decide(["--print", "--resume=X", "--session-id=Y"], sessions: ["X": "A"],
                              candidates: [candidate("A", 10, 10), candidate("B", 0, 0)],
                              transcript: transcript(age: 2 * 3600))
        XCTAssertEqual(decision.args, ["--print", "--resume=X", "--fork-session", "--session-id", "moved-1"])
    }

    func testAStayKeepsTheEqualsFormOfResume() {
        let decision = decide(["--resume=X"], sessions: ["X": "A"], candidates: [candidate("A", 10, 10)],
                              transcript: transcript(age: 10 * 60))
        XCTAssertEqual(decision.args, ["--resume=X"])
    }

    // MARK: Threads that moved before

    func testAThreadThatAlreadyMovedResumesItsCurrentConversation() throws {
        // The real ledger: the thread moved to B earlier, so it continues in conversation C now.
        SessionLedger.record(session: "C", account: "B")
        SessionLedger.setCurrent("C", ofThread: "X")
        let decision = decide(["--resume", "X"], candidates: [candidate("B", 10, 10), candidate("main", 0, 0)],
                              transcript: transcript(age: 10 * 60), newSessionID: "", live: true)
        XCTAssertEqual(decision.action, .stay)
        XCTAssertEqual(decision.args, ["--resume", "C"])
        XCTAssertEqual(decision.account, "B")
        XCTAssertEqual(decision.session, "C")
    }

    func testAMovedThreadMovesOnFromItsNewConversation() {
        // Cold again, and main has more room now: the fork continues the conversation it moved to, not T3's id.
        let decision = decide(["--resume", "X"], threads: ["X": "C"], sessions: ["C": "A"],
                              candidates: [candidate("A", 10, 10), candidate("main", 0, 0)],
                              transcript: transcript(age: 2 * 3600), newSessionID: "moved-2")
        XCTAssertEqual(decision.args, ["--resume", "C", "--fork-session", "--session-id", "moved-2"])
        XCTAssertEqual(decision.writes, [.record(session: "moved-2", account: "main", forkedAt: now),
                                         .current(session: "moved-2", thread: "X")])
    }

    // MARK: The transcript tail

    private func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private func stamp(_ offset: TimeInterval) -> String {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return stamp.string(from: now.addingTimeInterval(offset))
    }

    func testTailParsingReadsTheLastAnswer() {
        let lines = [json(["type": "user", "timestamp": stamp(-120)]),
                     json(["type": "assistant", "timestamp": stamp(-60)]),
                     json(["type": "user", "timestamp": stamp(-30)])]
        let transcript = ThreadLauncher.parseTail(Data(lines.joined(separator: "\n").utf8))
        XCTAssertEqual(transcript.lastAssistantAt, now.addingTimeInterval(-60))
        XCTAssertFalse(transcript.justCompacted)
    }

    func testTailParsingSeesACompactBoundaryAfterTheLastAnswer() {
        let lines = [json(["type": "assistant", "timestamp": stamp(-60)]),
                     json(["type": "system", "subtype": "compact_boundary", "timestamp": stamp(-50)]),
                     json(["type": "user", "timestamp": stamp(-40)])]
        XCTAssertTrue(ThreadLauncher.parseTail(Data(lines.joined(separator: "\n").utf8)).justCompacted)
    }

    func testTailParsingSeesACompactSummaryAfterTheLastAnswer() {
        let lines = [json(["type": "assistant", "timestamp": stamp(-60)]),
                     json(["type": "user", "isCompactSummary": true, "timestamp": stamp(-50)])]
        XCTAssertTrue(ThreadLauncher.parseTail(Data(lines.joined(separator: "\n").utf8)).justCompacted)
    }

    func testACompactionBeforeTheLastAnswerDoesNotCount() {
        let lines = [json(["type": "system", "subtype": "compact_boundary", "timestamp": stamp(-90)]),
                     json(["type": "assistant", "timestamp": stamp(-60)]),
                     json(["type": "user", "timestamp": stamp(-30)])]
        let transcript = ThreadLauncher.parseTail(Data(lines.joined(separator: "\n").utf8))
        XCTAssertFalse(transcript.justCompacted)
        XCTAssertEqual(transcript.lastAssistantAt, now.addingTimeInterval(-60))
    }

    func testGapsAndBrokenLinesInTheTailAreSkipped() {
        let lines = ["not json at all", "", json(["type": "assistant", "timestamp": stamp(-60)])]
        let transcript = ThreadLauncher.parseTail(Data(lines.joined(separator: "\n").utf8))
        XCTAssertEqual(transcript.lastAssistantAt, now.addingTimeInterval(-60))
        XCTAssertNil(ThreadLauncher.parseTail(Data("".utf8)).lastAssistantAt)
    }

    func testTheConversationFileIsFoundAcrossProjectsAndReadWarm() throws {
        try FileManager.default.createDirectory(at: projects.appendingPathComponent("proj-a"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projects.appendingPathComponent("proj-b"), withIntermediateDirectories: true)
        let lines = [json(["type": "assistant", "timestamp": stamp(-30)]),
                     json(["type": "user", "timestamp": stamp(-20)])]
        try Data(lines.joined(separator: "\n").utf8).write(to: projects.appendingPathComponent("proj-b").appendingPathComponent("conv-1.jsonl"))
        let transcript = ThreadLauncher.transcript(ofConversation: "conv-1")
        XCTAssertNotNil(transcript.lastAssistantAt)
        XCTAssertFalse(transcript.justCompacted)
        XCTAssertEqual(ThreadLauncher.transcript(ofConversation: "missing"), .cold)
    }

    // MARK: The wrapper script

    func testTheWrapperScriptExecsTheLauncherAndIsRewrittenOnlyWhenItDiffers() throws {
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent("lastdrop-tl-bin-\(UUID().uuidString)")
        ThreadLauncher.wrapperDirectory = bin
        defer { ThreadLauncher.wrapperDirectory = nil }
        ThreadLauncher.writeWrapper(executable: "/apps/lastdrop it's/App")
        let wrapper = ThreadLauncher.wrapperPath
        let script = try String(contentsOf: wrapper, encoding: .utf8)
        XCTAssertEqual(script, "#!/bin/sh\nexec '/apps/lastdrop it'\\''s/App' --claude-thread \"$@\"\n")
        let mode = try FileManager.default.attributesOfItem(atPath: wrapper.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o755)
        // An unchanged wrapper keeps its file: T3 may run it while the app rewrites it.
        let original = try Data(contentsOf: wrapper)
        ThreadLauncher.writeWrapper(executable: "/apps/lastdrop it's/App")
        XCTAssertEqual(try Data(contentsOf: wrapper), original)
    }
}
