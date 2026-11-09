import XCTest
@testable import LastDrop

/// Base class of every test: the session ledger points at a file of the test's own, so a test that reaches
/// `SessionLedger.record` (the runner, the warm pool) never writes the real `sessions.json`. A test that wants
/// a ledger of its own sets `fileOverride` after `super.setUp()`.
class LastDropTestCase: XCTestCase {
    private var ledgerFolder: URL?

    override func setUp() {
        super.setUp()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lastdrop-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        ledgerFolder = folder
        SessionLedger.fileOverride = folder.appendingPathComponent("sessions.json")
    }

    override func tearDown() {
        SessionLedger.fileOverride = nil
        if let ledgerFolder { try? FileManager.default.removeItem(at: ledgerFolder) }
        super.tearDown()
    }
}
