import Foundation
import XCTest
@testable import LastDrop

/// The real transcripts on this Mac, timed. Reads them, writes only the database named by `LASTDROP_USAGE_BENCH`:
/// `LASTDROP_USAGE_BENCH=/tmp/usage.sqlite swift test -c release -Xswiftc -enable-testing --filter UsageBenchmark`
final class UsageBenchmarkTests: LastDropTestCase {
    private func time<T>(_ label: String, _ work: () -> T) -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = work()
        print(String(format: "%@: %.2f ms", label, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6))
        return result
    }

    func testRealTranscripts() throws {
        guard let path = ProcessInfo.processInfo.environment["LASTDROP_USAGE_BENCH"] else { throw XCTSkip("Set LASTDROP_USAGE_BENCH") }
        let index = try XCTUnwrap(UsageIndex(path: path))
        let files = time("list files") { () -> [UsageFile] in
            var files: [UsageFile] = []
            for root in UsageFiles.roots() { UsageFiles.list(root, into: &files) }
            return files
        }
        print("files \(files.count)")
        time("first update, at the app's priority") {
            DispatchQueue.global(qos: .utility).sync { _ = index.update() }
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print("peak memory \(usage.ru_maxrss / (1 << 20)) MB")
        time("second update") { _ = index.update() }
        time("third update") { _ = index.update() }
        let hour = Int32(Date().timeIntervalSince1970 / 3600) - 61 * 24
        let cube = try XCTUnwrap(time("load") { UsageCube.load(path: path, sinceHour: hour) { $0 } })
        print("rows \(cube.rows.count), sessions \(cube.sessionCount), row size \(MemoryLayout<UsageCube.Row>.stride)")
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        print("database \(size / 1024) KB")
        for period in StatsPeriod.allCases {
            let page = time(period.rawValue) { cube.page(StatsSelection(period: period)) }
            print(String(format: "  $%.0f %.2fB agents %d sessions %d change %@ note %@", page.usd, Double(page.tokens) / 1e9, page.agents, page.sessions,
                         page.change.map { String(format: "%+.0f%%", $0 * 100) } ?? "-", page.note ?? "-"))
            print("  projects", page.projects.prefix(7).map { "\($0.name) \(Int($0.usd)) \($0.agents)" })
            print("  accounts", page.accounts.map { "\($0.name) \(Int($0.usd)) \($0.agents)" })
            print("  models", page.models.prefix(7).map { "\($0.name) \(Int($0.usd)) \($0.agents)" })
        }
        let sic = time("project") { cube.page(StatsSelection(period: .month, project: "sic")) }
        print(String(format: "  sic $%.0f agents %d", sic.usd, sic.agents), sic.work.map { "\($0.name) \(Int($0.usd))" })
    }
}
