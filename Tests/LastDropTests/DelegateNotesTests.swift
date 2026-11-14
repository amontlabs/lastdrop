import XCTest
@testable import LastDrop

final class DelegateNotesTests: LastDropTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }
    private func ids(_ notes: [DelegateNotes.Note]) -> [String] { notes.compactMap { $0["id"] as? String } }

    func testTheFileIsInTheOverriddenSupportFolder() {
        XCTAssertTrue(DelegateNotes.file.path.hasPrefix(LastDropPaths.support.path))
        XCTAssertFalse(DelegateNotes.file.path.contains("Application Support/lastdrop"))
    }

    func testPutListClaimAndFollowUpLookup() throws {
        DelegateNotes.put(["id": "t3-a", "task": "review the diff", "createdAt": ms(t0), "parentThread": "p1"], now: t0)
        var listed = DelegateNotes.list(thread: "c1", now: t0)
        XCTAssertNil(listed.bound)
        XCTAssertEqual(ids(listed.open), ["t3-a"])
        XCTAssertEqual(listed.open.first?["task"] as? String, "review the diff")

        let claimed = try XCTUnwrap(DelegateNotes.claim("t3-a", thread: "c1", now: t0.addingTimeInterval(5)))
        XCTAssertEqual(claimed["thread"] as? String, "c1")
        // Consumed once: another thread can't take it, the same one gets it back.
        XCTAssertNil(DelegateNotes.claim("t3-a", thread: "c2", now: t0))
        XCTAssertNotNil(DelegateNotes.claim("t3-a", thread: "c1", now: t0))

        listed = DelegateNotes.list(thread: "c1", now: t0.addingTimeInterval(3600))
        XCTAssertEqual(listed.bound?["id"] as? String, "t3-a", "a claimed note outlives the unclaimed TTL")
        XCTAssertTrue(listed.open.isEmpty)
    }

    func testUnclaimedNotesExpireAfterTenMinutes() {
        DelegateNotes.put(["id": "old", "task": "x", "createdAt": ms(t0)], now: t0)
        DelegateNotes.put(["id": "new", "task": "x", "createdAt": ms(t0.addingTimeInterval(300))], now: t0.addingTimeInterval(300))
        let later = t0.addingTimeInterval(11 * 60)
        XCTAssertEqual(ids(DelegateNotes.list(thread: nil, now: later).open), ["new"])
        XCTAssertNil(DelegateNotes.claim("old", thread: "c", now: later))
    }

    func testDropRemovesOnlyAnUnclaimedNote() {
        DelegateNotes.put(["id": "a", "task": "x"], now: t0)
        DelegateNotes.put(["id": "b", "task": "y"], now: t0)
        _ = DelegateNotes.claim("b", thread: "c", now: t0)
        DelegateNotes.drop("a", now: t0)
        DelegateNotes.drop("b", now: t0)
        XCTAssertTrue(DelegateNotes.list(thread: nil, now: t0).open.isEmpty)
        XCTAssertEqual(DelegateNotes.list(thread: "c", now: t0).bound?["id"] as? String, "b")
    }

    func testOpenNotesAreOldestFirstAndAPutCantForgeABinding() {
        DelegateNotes.put(["id": "second", "createdAt": ms(t0) + 10, "thread": "forged"], now: t0)
        DelegateNotes.put(["id": "first", "createdAt": ms(t0)], now: t0)
        XCTAssertEqual(ids(DelegateNotes.list(thread: "forged", now: t0).open), ["first", "second"])
        XCTAssertNil(DelegateNotes.list(thread: "forged", now: t0).bound)
    }

    func testConcurrentClaimsBindOnce() {
        DelegateNotes.put(["id": "a", "task": "x"], now: t0)
        let wins = Atomic()
        DispatchQueue.concurrentPerform(iterations: 16) { i in
            if DelegateNotes.claim("a", thread: "c\(i)", now: t0) != nil { wins.add() }
        }
        XCTAssertEqual(wins.value, 1)
    }

    func testAnswerSpeaksThePluginsProtocol() throws {
        func ask(_ object: [String: Any]) throws -> [String: Any] {
            DelegateNotes.answer(try JSONSerialization.data(withJSONObject: object), now: t0)
        }
        XCTAssertEqual(try ask(["op": "put", "note": ["id": "t3-a", "task": "go", "createdAt": ms(t0)]])["type"] as? String, "ok")
        XCTAssertEqual((try ask(["op": "list", "thread": "c"])["open"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(try ask(["op": "claim", "id": "t3-a", "thread": "c"])["type"] as? String, "ok")
        XCTAssertEqual(try ask(["op": "claim", "id": "t3-a", "thread": "d"])["type"] as? String, "taken")
        XCTAssertEqual((try ask(["op": "list", "thread": "c"])["bound"] as? [String: Any])?["id"] as? String, "t3-a")
        XCTAssertEqual(try ask(["op": "put", "note": ["task": "no id"]])["type"] as? String, "error")
        XCTAssertEqual(DelegateNotes.answer(Data("nope".utf8))["type"] as? String, "error")
    }

    func testTheCatalogLineSaysNotesAreSupported() throws {
        let line = AgentCatalog.pluginLine(catalog: AgentCatalog(agents: []), t3Instance: false)
        XCTAssertEqual(try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])["delegateNotes"] as? Bool, true)
    }
}

private final class Atomic: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func add() { lock.lock(); count += 1; lock.unlock() }
}
