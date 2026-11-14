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

    func testAClaimedNoteExpiresThirtyDaysAfterItsLastUse() {
        DelegateNotes.put(["id": "a", "createdAt": ms(t0)], now: t0)
        _ = DelegateNotes.claim("a", thread: "c", now: t0)
        // Looked up again on day 25: it lives until day 55.
        XCTAssertNotNil(DelegateNotes.claim("a", thread: "c", now: t0.addingTimeInterval(25 * 86400)))
        XCTAssertEqual(DelegateNotes.list(thread: "c", now: t0.addingTimeInterval(50 * 86400)).bound?["id"] as? String, "a")
        XCTAssertNil(DelegateNotes.list(thread: "c", now: t0.addingTimeInterval(56 * 86400)).bound)
    }

    func testTheCapKeepsTheMostRecentlyUsedBindings() {
        for i in 0..<DelegateNotes.keptClaimed {
            DelegateNotes.put(["id": "n\(i)", "createdAt": ms(t0) + Int64(i)], now: t0)
            _ = DelegateNotes.claim("n\(i)", thread: "c\(i)", now: t0.addingTimeInterval(Double(i)))
        }
        // n0 is the oldest note, but used last; then one binding too many.
        _ = DelegateNotes.claim("n0", thread: "c0", now: t0.addingTimeInterval(9_000))
        DelegateNotes.put(["id": "extra"], now: t0.addingTimeInterval(9_500))
        _ = DelegateNotes.claim("extra", thread: "cx", now: t0.addingTimeInterval(9_600))
        DelegateNotes.put(["id": "trigger", "createdAt": ms(t0)], now: t0.addingTimeInterval(10_001))
        XCTAssertNotNil(DelegateNotes.list(thread: "c0", now: t0.addingTimeInterval(10_002)).bound)
        XCTAssertNil(DelegateNotes.list(thread: "c1", now: t0.addingTimeInterval(10_002)).bound)
    }

    func testExpectNamesTheChildAndOnlyThatThreadMayClaim() {
        DelegateNotes.put(["id": "a", "task": "x"], now: t0)
        XCTAssertEqual(DelegateNotes.expect("a", child: "c1", now: t0), .ok)
        XCTAssertNil(DelegateNotes.claim("a", thread: "c2", now: t0))
        XCTAssertNotNil(DelegateNotes.claim("a", thread: "c1", now: t0))
        XCTAssertEqual(DelegateNotes.expect("a", child: "c1", now: t0), .ok, "claimed by the same child first")
        XCTAssertEqual(DelegateNotes.expect("gone", child: "c1", now: t0), .gone)
    }

    func testAReplayedTaskDropsItsNewNote() {
        DelegateNotes.put(["id": "first", "task": "x"], now: t0)
        _ = DelegateNotes.claim("first", thread: "c1", now: t0)
        DelegateNotes.put(["id": "again", "task": "x"], now: t0)
        XCTAssertEqual(DelegateNotes.expect("again", child: "c1", now: t0), .replay)
        XCTAssertTrue(DelegateNotes.list(thread: nil, now: t0).open.isEmpty)
        // Replayed before its first note was claimed: the earlier note named the child.
        DelegateNotes.put(["id": "b1", "task": "y"], now: t0)
        XCTAssertEqual(DelegateNotes.expect("b1", child: "c2", now: t0), .ok)
        DelegateNotes.put(["id": "b2", "task": "y"], now: t0)
        XCTAssertEqual(DelegateNotes.expect("b2", child: "c2", now: t0), .replay)
        XCTAssertEqual(ids(DelegateNotes.list(thread: nil, now: t0).open), ["b1"])
    }

    func testConcurrentPutsClaimsAndExpectsLoseNothing() {
        DispatchQueue.concurrentPerform(iterations: 24) { i in
            DelegateNotes.put(["id": "n\(i)", "task": "x", "createdAt": ms(t0) + Int64(i)], now: t0)
        }
        let wins = Atomic()
        DispatchQueue.concurrentPerform(iterations: 48) { i in
            // Two threads race for each note; an expect runs beside them.
            if i % 3 == 0 { _ = DelegateNotes.expect("n\(i / 2)", child: "t\(i)", now: t0) }
            if DelegateNotes.claim("n\(i / 2)", thread: "t\(i)", now: t0) != nil { wins.add() }
        }
        XCTAssertEqual(wins.value, 24)
        XCTAssertTrue(DelegateNotes.list(thread: nil, now: t0).open.isEmpty)
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
        XCTAssertEqual(try ask(["op": "expect", "id": "t3-a", "child": "c"])["result"] as? String, "ok")
        XCTAssertEqual(try ask(["op": "put", "note": ["task": "no id"]])["type"] as? String, "error")
        XCTAssertEqual(DelegateNotes.answer(Data("nope".utf8))["type"] as? String, "error")
    }

    func testTheCatalogLineSaysNotesAreSupported() throws {
        let line = AgentCatalog.pluginLine(catalog: AgentCatalog(agents: []), t3Instance: false)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(json["delegateNotes"] as? Bool, true)
        XCTAssertEqual(json["delegateNotesFile"] as? String, DelegateNotes.file.path)
    }
}

private final class Atomic: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func add() { lock.lock(); count += 1; lock.unlock() }
}
