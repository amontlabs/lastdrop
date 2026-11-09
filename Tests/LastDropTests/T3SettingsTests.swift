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
}
