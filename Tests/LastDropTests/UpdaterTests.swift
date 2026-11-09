import CryptoKit
import Foundation
import Security
import XCTest
@testable import LastDrop

@MainActor
final class UpdaterTests: LastDropTestCase {
    private var dir: URL!
    private let page = URL(string: "https://example.com")!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lastdrop-updater-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func file(_ name: String, _ text: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// An ad-hoc signed lastdrop.app with a real executable and a resource, zipped as a release.
    private func app(version: String, id: String = "com.amontlabs.lastdrop", in folder: String = "release") throws -> (app: URL, zip: URL) {
        let root = dir.appendingPathComponent(folder)
        let app = root.appendingPathComponent("lastdrop.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let executable = app.appendingPathComponent("Contents/MacOS/lastdrop")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("plugin".utf8).write(to: resources.appendingPathComponent("plugin.txt"))
        let plist: [String: Any] = ["CFBundleExecutable": "lastdrop", "CFBundleIdentifier": id, "CFBundlePackageType": "APPL",
                                    "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try tool("/usr/bin/codesign", "--force", "--sign", "-", app.path)
        let zip = root.appendingPathComponent("lastdrop.zip")
        try tool("/usr/bin/ditto", "-c", "-k", "--keepParent", app.path, zip.path)
        return (app, zip)
    }

    private func tool(_ path: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func requirement(_ text: String) throws -> SecRequirement {
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(text as CFString, [], &requirement), errSecSuccess)
        return try XCTUnwrap(requirement)
    }

    private func waitUntilSettled(_ updater: Updater) async {
        while updater.phase == .downloading { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testANewerReleaseWaitsForTheDownloadInProgress() async {
        let updater = Updater(current: "1.0.0", forceRelease: true)
        updater.preview(.downloading, version: "2.0.0")
        updater.latest = { [page] in .init(version: "3.0.0", zip: page, checksum: nil, page: page) }
        await updater.check(manual: false)
        XCTAssertEqual(updater.phase, .downloading)
        XCTAssertEqual(updater.release?.version, "2.0.0")
    }

    func testAStagedAppThatWasClearedIsFetchedAgain() async {
        let updater = Updater(current: "1.0.0", forceRelease: true)
        updater.preview(.ready, version: "2.0.0", staged: dir.appendingPathComponent("gone/lastdrop.app"))
        updater.installer = { _ in XCTFail("installed an app that isn't there") }
        updater.install()
        XCTAssertNil(updater.stagedPath)
        await waitUntilSettled(updater)
        // The preview's release has no checksum, so this is as far as the download goes.
        guard case .failed(let message) = updater.phase else { return XCTFail("\(updater.phase)") }
        XCTAssertTrue(message.contains("no checksum"))
    }

    func testAnAppDamagedWhileItWaitedIsDroppedAndARestartThatFailedIsKept() throws {
        let app = try app(version: "2.0.0").app
        let updater = Updater(current: "1.0.0", forceRelease: true)
        updater.preview(.ready, version: "2.0.0", staged: app)
        updater.installer = { _ in throw UpdateError("Can't write") }
        updater.install()
        XCTAssertEqual(updater.phase, .failed("Can't write"))
        XCTAssertEqual(updater.stagedPath, app.path)
        updater.installer = { _ in throw UpdateError("Damaged", untrusted: true) }
        updater.install()
        XCTAssertNil(updater.stagedPath)
    }

    func testVersionsCompareNumerically() throws {
        XCTAssertGreaterThan(try XCTUnwrap(Version("0.10.0")), try XCTUnwrap(Version("0.9.3")))
        XCTAssertEqual(try XCTUnwrap(Version("v1.2")), try XCTUnwrap(Version("1.2.0")))
        XCTAssertGreaterThan(try XCTUnwrap(Version("1.2.1")), try XCTUnwrap(Version("1.2")))
        XCTAssertNil(Version("latest"))
        XCTAssertNil(Version(""))
    }

    func testDevelopmentBuildsNeverUpdate() {
        XCTAssertFalse(Updater(current: "0.0.0-dev").isRelease)
    }

    func testAnOlderOrEqualReleaseIsNotOffered() async {
        let updater = Updater(current: "1.2.0", forceRelease: true)
        for version in ["1.2.0", "1.1.9"] {
            updater.latest = { [page] in .init(version: version, zip: page, checksum: nil, page: page) }
            await updater.check(manual: true)
            XCTAssertEqual(updater.phase, .idle)
            XCTAssertNil(updater.release)
        }
    }

    func testASkippedVersionOnlyComesBackWhenYouAsk() async {
        let updater = Updater(current: "1.0.0", forceRelease: true)
        updater.latest = { [page] in .init(version: "2.0.0", zip: page, checksum: nil, page: page) }
        updater.skipped = { "2.0.0" }
        await updater.check(manual: false)
        XCTAssertEqual(updater.phase, .idle)
        await updater.check(manual: true)
        XCTAssertEqual(updater.phase, .available)
    }

    func testAReleaseWithoutAChecksumIsNeverFetchedAndSaysSoEvenInTheBackground() async {
        let updater = Updater(current: "1.0.0", forceRelease: true)
        updater.latest = { [page] in .init(version: "2.0.0", zip: page, checksum: nil, page: page) }
        await updater.update(manual: false)
        await waitUntilSettled(updater)
        guard case .failed(let message) = updater.phase else { return XCTFail("\(updater.phase)") }
        XCTAssertTrue(message.contains("no checksum"))
        XCTAssertTrue(updater.showsInPanel)
    }

    func testABackgroundDownloadStaysOutOfThePanelAndAFailedOneIsLeftToTheNextCheck() async throws {
        let updater = Updater(current: "1.0.0", forceRelease: true)
        let missing = dir.appendingPathComponent("gone.zip")
        let checksum = try file("gone.zip.sha256", digest(""))
        updater.latest = { [page] in .init(version: "2.0.0", zip: missing, checksum: checksum, page: page) }
        await updater.update(manual: false)
        XCTAssertEqual(updater.phase, .downloading)
        XCTAssertFalse(updater.showsInPanel)
        await waitUntilSettled(updater)
        XCTAssertEqual(updater.phase, .available)
    }

    func testAMismatchedChecksumFails() async throws {
        let zip = try file("lastdrop.zip", "zip")
        try await Updater.verifyChecksum(of: zip, against: try file("good.sha256", "\(digest("zip"))  lastdrop.zip\n"))
        do {
            try await Updater.verifyChecksum(of: zip, against: try file("bad.sha256", "\(digest("other"))  lastdrop.zip\n"))
            XCTFail("accepted a wrong checksum")
        } catch {
            XCTAssertEqual((error as? UpdateError)?.untrusted, true)
        }
    }

    func testUnpackKeepsOnlyThisAppAtThatVersionSignedAsRequired() throws {
        let target = dir.appendingPathComponent("lastdrop.app")
        let anyApp = try requirement(#"identifier "com.amontlabs.lastdrop""#)
        let release = try app(version: "2.0.0")
        let staged = try Updater.unpack(release.zip, version: "2.0.0", beside: target, requirement: anyApp, bundleID: "com.amontlabs.lastdrop")
        XCTAssertEqual(Bundle(url: staged)?.infoDictionary?["CFBundleShortVersionString"] as? String, "2.0.0")
        try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())

        func refused(_ zip: URL, version: String, requirement: SecRequirement, _ expected: String) {
            XCTAssertThrowsError(try Updater.unpack(zip, version: version, beside: target, requirement: requirement, bundleID: "com.amontlabs.lastdrop")) {
                XCTAssertTrue($0.localizedDescription.contains(expected), $0.localizedDescription)
            }
        }
        refused(release.zip, version: "3.0.0", requirement: anyApp, "isn't version")
        refused(try app(version: "2.0.0", id: "com.example.other", in: "other").zip, version: "2.0.0", requirement: anyApp, "isn't lastdrop")
        let certificate = try requirement(#"identifier "com.amontlabs.lastdrop" and certificate leaf = H"0000000000000000000000000000000000000000""#)
        refused(release.zip, version: "2.0.0", requirement: certificate, "certificate")
    }

    func testATamperedAppFailsItsSignature() throws {
        let release = try app(version: "2.0.0")
        let requirement = try requirement(#"identifier "com.amontlabs.lastdrop""#)
        try Updater.verifySignature(release.app, requirement)
        let resource = release.app.appendingPathComponent("Contents/Resources/plugin.txt")
        try Data("changed".utf8).write(to: resource)
        XCTAssertThrowsError(try Updater.verifySignature(release.app, requirement))
        try Data("plugin".utf8).write(to: resource)
        try Updater.verifySignature(release.app, requirement)
        let executable = release.app.appendingPathComponent("Contents/MacOS/lastdrop")
        var binary = try Data(contentsOf: executable)
        binary[binary.count / 2] ^= 0xFF
        try binary.write(to: executable)
        XCTAssertThrowsError(try Updater.verifySignature(release.app, requirement))
    }

    func testSwapExchangesBothBundlesAndAFailedOneLeavesThem() throws {
        let old = try app(version: "1.0.0", in: "old").app, new = try app(version: "2.0.0", in: "new").app
        func version(_ url: URL) -> String? {
            NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
        }
        try Updater.swap(new, old)
        XCTAssertEqual(version(old), "2.0.0")
        XCTAssertEqual(version(new), "1.0.0")
        XCTAssertThrowsError(try Updater.swap(dir.appendingPathComponent("missing.app"), old))
        XCTAssertEqual(version(old), "2.0.0")
    }
}
