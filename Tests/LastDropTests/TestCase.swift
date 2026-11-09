import XCTest
@testable import LastDrop

/// Base class of every test: the session ledger and the agent registry point at files of the test's own, so a
/// test that reaches `SessionLedger.record` (the runner, the warm pool) or `AgentRegistry.markFull` (the reaper,
/// a limit) never writes the real `sessions.json` or `subagents.json`. A test that wants files of its own sets
/// the overrides after `super.setUp()`.
class LastDropTestCase: XCTestCase {
    private var ledgerFolder: URL?

    override func setUp() {
        super.setUp()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lastdrop-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        ledgerFolder = folder
        SessionLedger.fileOverride = folder.appendingPathComponent("sessions.json")
        AgentRegistry.fileOverride = folder.appendingPathComponent("subagents.json")
    }

    override func tearDown() {
        SessionLedger.fileOverride = nil
        AgentRegistry.fileOverride = nil
        if let ledgerFolder { try? FileManager.default.removeItem(at: ledgerFolder) }
        super.tearDown()
    }
}
