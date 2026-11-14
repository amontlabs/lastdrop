import XCTest
@testable import LastDrop

/// T3 Code's settings file, in a folder of the test's own: never the real `~/.t3`.
final class T3SettingsTests: LastDropTestCase {
    private var root: URL!
    private var file: URL { root.appendingPathComponent("userdata/settings.json") }
    private let wrapper = "/tmp/lastdrop-test/claude-thread"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lastdrop-t3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("userdata"), withIntermediateDirectories: true)
        T3Settings.userdataOverride = root.appendingPathComponent("userdata")
        T3Settings.appOverride = root.appendingPathComponent("T3 Code.app")   // absent: the data folder alone counts
        T3Settings.backupOverride = root.appendingPathComponent("backup.json")
        ThreadLauncher.wrapperDirectory = root.appendingPathComponent("bin")
    }

    override func tearDownWithError() throws {
        T3Settings.userdataOverride = nil
        T3Settings.appOverride = nil
        T3Settings.backupOverride = nil
        ThreadLauncher.wrapperDirectory = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String) throws { try text.write(to: file, atomically: true, encoding: .utf8) }

    private func json() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }

    private func claudePath() throws -> String? {
        let config = ((try json()["providerInstances"] as? [String: Any])?["claudeAgent"] as? [String: Any])?["config"] as? [String: Any]
        return config?["binaryPath"] as? String
    }

    func testNothingInstalled() throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent("userdata"))
        XCTAssertEqual(T3Settings.state(wrapper: wrapper), .notInstalled)
        XCTAssertThrowsError(try T3Settings.enable(wrapper: wrapper))
    }

    func testTheAppAloneCountsAsInstalled() throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent("userdata"))
        try FileManager.default.createDirectory(at: T3Settings.app, withIntermediateDirectories: true)
        XCTAssertEqual(T3Settings.state(wrapper: wrapper), .off)
        try T3Settings.enable(wrapper: wrapper)   // creates the folder and the file
        XCTAssertEqual(try claudePath(), wrapper)
    }

    func testOnKeepsEveryOtherSettingAndOffRestoresThem() throws {
        try write("""
        {"defaultRuntimeMode": "auto", "textGenerationModelSelection": {"instanceId": "codex"},
         "providerInstances": {"codex": {"driver": "codex", "config": {"binaryPath": "/x/codex"}}}}
        """)
        XCTAssertEqual(T3Settings.state(wrapper: wrapper), .off)
        try T3Settings.enable(wrapper: wrapper)
        XCTAssertEqual(T3Settings.state(wrapper: wrapper), .on)
        XCTAssertEqual(try claudePath(), wrapper)
        var kept = try json()
        XCTAssertEqual(kept["defaultRuntimeMode"] as? String, "auto")
        XCTAssertNotNil(kept["textGenerationModelSelection"])
        XCTAssertNotNil((kept["providerInstances"] as? [String: Any])?["codex"])

        try T3Settings.disable(wrapper: wrapper)
        XCTAssertEqual(T3Settings.state(wrapper: wrapper), .off)
        kept = try json()
        // The Claude instance T3 never had is gone again; the rest is as it was.
        XCTAssertNil((kept["providerInstances"] as? [String: Any])?["claudeAgent"])
        XCTAssertNotNil((kept["providerInstances"] as? [String: Any])?["codex"])
        XCTAssertEqual(kept["defaultRuntimeMode"] as? String, "auto")
    }

    func testAPathOfTheUsersOwnNeedsConsentAndComesBack() throws {
        try write("""
        {"providerInstances": {"claudeAgent": {"driver": "claudeAgent", "displayName": "Mine", "config": {"binaryPath": "/mine/claude", "homePath": "/h"}}}}
        """)
        XCTAssertEqual(T3Settings.state(wrapper: wrapper), .elsewhere("/mine/claude"))
        XCTAssertThrowsError(try T3Settings.enable(wrapper: wrapper)) { XCTAssertEqual($0 as? T3Settings.Failure, .elsewhere("/mine/claude")) }
        XCTAssertEqual(try claudePath(), "/mine/claude")   // refused: untouched

        try T3Settings.enable(replacingElsewhere: true, wrapper: wrapper)
        XCTAssertEqual(try claudePath(), wrapper)
        try T3Settings.disable(wrapper: wrapper)
        XCTAssertEqual(try claudePath(), "/mine/claude")
        let instance = try XCTUnwrap((try json()["providerInstances"] as? [String: Any])?["claudeAgent"] as? [String: Any])
        XCTAssertEqual(instance["displayName"] as? String, "Mine")
        XCTAssertEqual((instance["config"] as? [String: Any])?["homePath"] as? String, "/h")
    }

    func testOffLeavesAPathTheUserSetSince() throws {
        try write("""
        {"providerInstances": {"claudeAgent": {"driver": "claudeAgent", "config": {"binaryPath": "/later/claude"}}}}
        """)
        try T3Settings.disable(wrapper: wrapper)
        XCTAssertEqual(try claudePath(), "/later/claude")
    }

    func testABrokenFileIsNeverTouched() throws {
        try write("{ not json")
        XCTAssertEqual(T3Settings.state(wrapper: wrapper), .unreadable)
        XCTAssertThrowsError(try T3Settings.enable(wrapper: wrapper)) { XCTAssertEqual($0 as? T3Settings.Failure, .unreadable) }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{ not json")
    }

    func testAnEmptyOrMissingFileIsOff() throws {
        XCTAssertEqual(T3Settings.state(wrapper: wrapper), .off)   // none yet
        try write("")
        XCTAssertEqual(T3Settings.state(wrapper: wrapper), .off)
        try T3Settings.enable(wrapper: wrapper)
        XCTAssertEqual(try claudePath(), wrapper)
    }

    func testTurningOnTwiceKeepsTheFirstBackup() throws {
        try write(#"{"providerInstances": {"claudeAgent": {"driver": "claudeAgent", "config": {"binaryPath": "/mine/claude"}}}}"#)
        try T3Settings.enable(replacingElsewhere: true, wrapper: wrapper)
        try T3Settings.enable(wrapper: wrapper)
        try T3Settings.disable(wrapper: wrapper)
        XCTAssertEqual(try claudePath(), "/mine/claude")
    }

    func testASymlinkedFileIsWrittenWhereItPoints() throws {
        let real = root.appendingPathComponent("elsewhere.json")
        try #"{"defaultRuntimeMode": "auto"}"#.write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: real)
        try T3Settings.enable(wrapper: wrapper)
        XCTAssertEqual((try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)), real.path)
        XCTAssertEqual(try claudePath(), wrapper)
    }

    // MARK: The lastdrop provider instance

    private var acpWrapper: String { ThreadLauncher.acpWrapperPath.path }

    private func lastdropEntry() throws -> [String: Any]? {
        (try json()["providerInstances"] as? [String: Any])?["lastdrop"] as? [String: Any]
    }

    func testOnAddsBothKeys() throws {
        try write(#"{"defaultRuntimeMode": "auto"}"#)
        try T3Settings.enable(wrapper: wrapper)
        XCTAssertEqual(try claudePath(), wrapper)
        let entry = try XCTUnwrap(lastdropEntry())
        XCTAssertEqual(entry["driver"] as? String, "acpRegistry")
        XCTAssertEqual(entry["enabled"] as? Bool, true)
        XCTAssertEqual(entry["displayName"] as? String, "lastdrop")
        let config = try XCTUnwrap(entry["config"] as? [String: Any])
        XCTAssertEqual(config["source"] as? String, "local")
        XCTAssertEqual(config["commandPath"] as? String, acpWrapper)
        XCTAssertEqual(config["commandArgs"] as? [String], [])
        XCTAssertTrue(acpWrapper.hasSuffix("/bin/lastdrop-acp"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: acpWrapper))
        XCTAssertEqual(T3Settings.acpStatus(), .ready)
    }

    func testTurningOnAgainDoesNotWrite() throws {
        try T3Settings.enable(wrapper: wrapper)
        let before = try Data(contentsOf: file)
        let stamp = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        Thread.sleep(forTimeInterval: 0.05)
        try T3Settings.enable(wrapper: wrapper)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, stamp)
    }

    func testExtraFieldsOnOurEntryAreKept() throws {
        try write("""
        {"providerInstances": {"lastdrop": {"driver": "acpRegistry", "accentColor": "#fff", "displayName": "Mine",
          "config": {"source": "local", "commandPath": "/old/path", "commandArgs": [], "authMethodId": "x"}}}}
        """)
        try T3Settings.enable(wrapper: wrapper)
        let entry = try XCTUnwrap(lastdropEntry())
        XCTAssertEqual(entry["accentColor"] as? String, "#fff")
        XCTAssertEqual(entry["displayName"] as? String, "Mine")
        let config = try XCTUnwrap(entry["config"] as? [String: Any])
        XCTAssertEqual(config["authMethodId"] as? String, "x")
        XCTAssertEqual(config["commandPath"] as? String, acpWrapper)
        XCTAssertEqual(entry["enabled"] as? Bool, true)
    }

    func testOffDisablesTheEntryAndRestoresTheBinaryPath() throws {
        try write(#"{"providerInstances": {"claudeAgent": {"driver": "claudeAgent", "config": {"binaryPath": "/mine/claude"}}}}"#)
        try T3Settings.enable(replacingElsewhere: true, wrapper: wrapper)
        try T3Settings.disable(wrapper: wrapper)
        XCTAssertEqual(try claudePath(), "/mine/claude")
        let entry = try XCTUnwrap(lastdropEntry())
        XCTAssertEqual(entry["enabled"] as? Bool, false)
        XCTAssertEqual((entry["config"] as? [String: Any])?["commandPath"] as? String, acpWrapper)
        XCTAssertEqual(T3Settings.acpStatus(), .disabled)
        // On again flips it back without losing the entry.
        try T3Settings.enable(replacingElsewhere: true, wrapper: wrapper)
        XCTAssertEqual(try lastdropEntry()?["enabled"] as? Bool, true)
    }

    func testAForeignLastdropInstanceIsLeftAlone() throws {
        let text = #"{"providerInstances": {"lastdrop": {"driver": "codex", "config": {"binaryPath": "/x"}}}}"#
        try write(text)
        try T3Settings.enable(wrapper: wrapper)
        XCTAssertEqual(try claudePath(), wrapper)   // the switch still works
        let entry = try XCTUnwrap(lastdropEntry())
        XCTAssertEqual(entry["driver"] as? String, "codex")
        XCTAssertEqual((entry["config"] as? [String: Any])?["binaryPath"] as? String, "/x")
        XCTAssertNil(entry["enabled"])
        XCTAssertEqual(T3Settings.acpStatus(), .foreign)
        try T3Settings.disable(wrapper: wrapper)
        XCTAssertNil(try lastdropEntry()?["enabled"])
    }

    func testARegistryInstanceNamedLastdropIsForeign() throws {
        try write(#"{"providerInstances": {"lastdrop": {"driver": "acpRegistry", "config": {"source": "registry", "agentId": "devin"}}}}"#)
        try T3Settings.enable(wrapper: wrapper)
        XCTAssertEqual(T3Settings.acpStatus(), .foreign)
        XCTAssertEqual((try lastdropEntry()?["config"] as? [String: Any])?["agentId"] as? String, "devin")
        XCTAssertNil((try lastdropEntry()?["config"] as? [String: Any])?["commandPath"])
    }

    func testABrokenFileGetsNoInstanceEither() throws {
        try write("{ not json")
        XCTAssertThrowsError(try T3Settings.enable(wrapper: wrapper))
        XCTAssertThrowsError(try T3Settings.disable(wrapper: wrapper))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{ not json")
        XCTAssertEqual(T3Settings.acpStatus(), .unreadable)
    }

    func testTheCatalogLineTellsThePluginWhetherTheInstanceIsReady() throws {
        func t3Instance() throws -> Bool? {
            let line = AgentCatalog.pluginLine(catalog: AgentCatalog(agents: []))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])["t3Instance"] as? Bool
        }
        XCTAssertEqual(try t3Instance(), false, "no instance yet")
        try T3Settings.enable(wrapper: wrapper)
        XCTAssertEqual(try t3Instance(), true)
        try T3Settings.disable(wrapper: wrapper)
        XCTAssertEqual(try t3Instance(), false, "turned off")
    }

    func testStatusReportsAMissingWrapperAndAbsence() throws {
        XCTAssertEqual(T3Settings.acpStatus(), .absent)
        try T3Settings.enable(wrapper: wrapper)
        try FileManager.default.removeItem(atPath: acpWrapper)
        XCTAssertEqual(T3Settings.acpStatus(), .wrapperMissing)
    }

    func testTheWrapperScriptRunsAcpAndIsRefreshed() throws {
        ThreadLauncher.writeWrapper(executable: "/apps/it's/App")
        let text = try String(contentsOfFile: acpWrapper, encoding: .utf8)
        XCTAssertTrue(text.contains(#"exec '/apps/it'\''s/App' --acp "$@""#))
        ThreadLauncher.writeWrapper(executable: "/apps/other")
        XCTAssertTrue(try String(contentsOfFile: acpWrapper, encoding: .utf8).contains("/apps/other"))
    }
}
