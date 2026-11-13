import XCTest
@testable import LastDrop

/// Base class of every test: the session ledger, the agent registry, the usage file, Claude Code's shared
/// `.claude.json` and `~/.claude`, and the accounts' folders (`~/.claude-accounts`) point at files of the test's own, so a
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
        SubagentLog.fileOverride = folder.appendingPathComponent("subagents.log")
        SubagentUsage.fileOverride = folder.appendingPathComponent("usage.json")
        // As if the app were running: a runner reads the file and never asks Anthropic itself.
        SubagentUsage.appRunningOverride = true
        ClaudeProvider.sharedConfigOverride = folder.appendingPathComponent(".claude.json").path
        ClaudeProfile.sharedOverride = folder.appendingPathComponent(".claude").path
        Account.claudeFoldersOverride = folder.appendingPathComponent(".claude-accounts").path
    }

    override func tearDown() {
        SessionLedger.fileOverride = nil
        AgentRegistry.fileOverride = nil
        SubagentLog.fileOverride = nil
        SubagentUsage.fileOverride = nil
        SubagentUsage.appRunningOverride = nil
        ClaudeProvider.sharedConfigOverride = nil
        ClaudeProfile.sharedOverride = nil
        Account.claudeFoldersOverride = nil
        if let ledgerFolder { try? FileManager.default.removeItem(at: ledgerFolder) }
        super.tearDown()
    }
}
