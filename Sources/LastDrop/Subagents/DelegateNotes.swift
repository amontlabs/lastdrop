import Foundation

/// What a T3 Code parent thread meant for the plain Claude children it starts with `delegate_task`: auto mode refuses a
/// call a hook changed, so the request (run id, model, effort, description, permission mode) can't ride in the task.
/// The parent's plugin notes it here before T3 sees the call, and the child's plugin claims it on its first turn by its
/// task text (and its parent thread when T3 says), binding the note to the child's thread so its follow-ups find the run.
///
/// One file in lastdrop's support folder, `delegate-notes.json`, shared by every account profile (parent and child may
/// run under different `CLAUDE_CONFIG_DIR`s), every change under `delegate-notes.lock`. A note is a JSON object the
/// plugin owns; this reads only `id` (the run id), `createdAt` (ms since 1970), and what it adds: `child` (the thread T3
/// answered the call with), `thread` (the thread that claimed it), `claimedAt` and `usedAt` (the binding's last
/// lookup). Unclaimed notes expire after ten minutes; claimed ones 30 days after their last use, the 500 most
/// recently used kept. The file is always replaced whole (atomically), so the plugin reads it without the lock.
enum DelegateNotes {
    static let unclaimedTTL: TimeInterval = 10 * 60
    static let claimedTTL: TimeInterval = 30 * 24 * 3600
    static let keptClaimed = 500

    static var file: URL { LastDropPaths.support.appendingPathComponent("delegate-notes.json") }
    static var lock: URL { LastDropPaths.support.appendingPathComponent("delegate-notes.lock") }

    typealias Note = [String: Any]

    /// Stores `note` (replacing one with its id). False when it has no id.
    @discardableResult
    static func put(_ note: Note, now: Date = Date()) -> Bool {
        guard let id = note["id"] as? String, !id.isEmpty else { return false }
        var clean = note
        for key in ["thread", "claimedAt", "usedAt", "child"] { clean.removeValue(forKey: key) }
        if !(clean["createdAt"] is NSNumber) { clean["createdAt"] = ms(now) }
        withNotes(now: now) { notes in
            notes.removeAll { $0["id"] as? String == id }
            notes.append(clean)
        }
        return true
    }

    /// Removes the note `id` if no thread claimed it: a child that exists keeps its note.
    static func drop(_ id: String, now: Date = Date()) {
        withNotes(now: now) { notes in notes.removeAll { $0["id"] as? String == id && $0["thread"] == nil } }
    }

    /// The note bound to `thread`, if any, and the unclaimed notes that haven't expired, oldest first.
    static func list(thread: String?, now: Date = Date()) -> (bound: Note?, open: [Note]) {
        withNotes(now: now) { notes in
            let bound = thread.flatMap { t in notes.last { $0["thread"] as? String == t } }
            let open = notes.filter { $0["thread"] == nil }.sorted { created($0) < created($1) }
            return (bound, open)
        }
    }

    /// Binds note `id` to `thread`, once: the note, or nil when it is gone, expired, meant for another child thread or
    /// another thread has it. The same thread claiming again gets it back, and marks it used now.
    static func claim(_ id: String, thread: String, now: Date = Date()) -> Note? {
        withNotes(now: now) { notes in
            guard let i = notes.firstIndex(where: { $0["id"] as? String == id }) else { return nil }
            if let owner = notes[i]["thread"] as? String {
                guard owner == thread else { return nil }
                notes[i]["usedAt"] = ms(now)
                return notes[i]
            }
            if let child = notes[i]["child"] as? String, child != thread { return nil }
            notes[i]["thread"] = thread
            notes[i]["claimedAt"] = ms(now)
            notes[i]["usedAt"] = ms(now)
            return notes[i]
        }
    }

    enum Expected: String { case ok, replay, gone, other }

    /// Records that T3 answered note `id`'s call with child thread `child`. `replay` when another note already names
    /// that thread (T3 replayed a task it had: no new child), and the note is dropped if unclaimed; `other` when a
    /// different thread claimed it first; `gone` when it isn't there.
    static func expect(_ id: String, child: String, now: Date = Date()) -> Expected {
        withNotes(now: now) { notes in
            guard let i = notes.firstIndex(where: { $0["id"] as? String == id }) else { return .gone }
            let taken = notes.contains { $0["id"] as? String != id && ($0["thread"] as? String == child || $0["child"] as? String == child) }
            if let owner = notes[i]["thread"] as? String { return owner == child ? .ok : (taken ? .replay : .other) }
            if taken {
                notes.remove(at: i)
                return .replay
            }
            notes[i]["child"] = child
            return .ok
        }
    }

    private static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
    private static func created(_ note: Note) -> Double { (note["createdAt"] as? NSNumber)?.doubleValue ?? 0 }
    /// A claimed note's last use: its last lookup, else its claim, else its creation.
    private static func used(_ note: Note) -> Double {
        (note["usedAt"] as? NSNumber)?.doubleValue ?? (note["claimedAt"] as? NSNumber)?.doubleValue ?? created(note)
    }

    /// Drops expired notes: unclaimed after ten minutes, claimed 30 days after their last use or past the 500 most
    /// recently used.
    private static func prune(_ notes: inout [Note], now: Date) {
        let nowMs = Double(ms(now))
        notes.removeAll { note in
            let claimed = note["thread"] != nil
            return (nowMs - (claimed ? used(note) : created(note))) / 1000 > (claimed ? claimedTTL : unclaimedTTL)
        }
        let claimed = notes.enumerated().filter { $0.element["thread"] != nil }
        if claimed.count > keptClaimed {
            let oldest = Set(claimed.sorted { used($0.element) < used($1.element) }.prefix(claimed.count - keptClaimed).map(\.offset))
            notes = notes.enumerated().filter { !oldest.contains($0.offset) }.map(\.element)
        }
    }

    /// A read-modify-write under the lock; the file is replaced atomically, and only when something changed.
    private static func withNotes<T>(now: Date, _ body: (inout [Note]) -> T) -> T {
        LastDropPaths.ensure(LastDropPaths.support)
        let fd = open(lock.path, O_CREAT | O_RDWR, 0o600)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        var notes: [Note] = []
        if let data = try? Data(contentsOf: file),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let stored = json["notes"] as? [Note] {
            notes = stored
        }
        let before = serialize(notes)
        prune(&notes, now: now)
        let value = body(&notes)
        let after = serialize(notes)
        if after != before, let after {
            try? after.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        return value
    }

    private static func serialize(_ notes: [Note]) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["notes": notes], options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// One answer line for the plugin.
    static func answer(_ input: Data, now: Date = Date()) -> [String: Any] {
        guard let request = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any], let op = request["op"] as? String else {
            return ["type": "error", "text": "delegate-note: expected a JSON object with op"]
        }
        switch op {
        case "put":
            guard let note = request["note"] as? Note, put(note, now: now) else { return ["type": "error", "text": "delegate-note: put needs a note with an id"] }
            return ["type": "ok"]
        case "drop":
            guard let id = request["id"] as? String else { return ["type": "error", "text": "delegate-note: drop needs an id"] }
            drop(id, now: now)
            return ["type": "ok"]
        case "list":
            let (bound, open) = list(thread: request["thread"] as? String, now: now)
            var out: [String: Any] = ["type": "ok", "open": open]
            if let bound { out["bound"] = bound }
            return out
        case "claim":
            guard let id = request["id"] as? String, let thread = request["thread"] as? String, !thread.isEmpty else {
                return ["type": "error", "text": "delegate-note: claim needs an id and a thread"]
            }
            if let note = claim(id, thread: thread, now: now) { return ["type": "ok", "note": note] }
            return ["type": "taken"]
        case "expect":
            guard let id = request["id"] as? String, let child = request["child"] as? String, !child.isEmpty else {
                return ["type": "error", "text": "delegate-note: expect needs an id and a child"]
            }
            return ["type": "ok", "result": expect(id, child: child, now: now).rawValue]
        default:
            return ["type": "error", "text": "delegate-note: unknown op \(op)"]
        }
    }

    /// `lastdrop --delegate-note`: one request on stdin (`{"op":"put"|"drop"|"list"|"claim"|"expect",…}`), one JSON line out.
    static func main() -> Never {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let out = answer(input)
        let data = (try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        FileHandle.standardOutput.write(data + Data("\n".utf8))
        exit(out["type"] as? String == "error" ? 1 : 0)
    }
}
