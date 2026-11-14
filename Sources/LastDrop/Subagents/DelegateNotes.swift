import Foundation

/// What a T3 Code parent thread meant for the plain Claude children it starts with `delegate_task`: auto mode refuses a
/// call a hook changed, so the request (run id, model, effort, description, permission mode) can't ride in the task.
/// The parent's plugin notes it here before T3 sees the call, and the child's plugin claims it on its first turn by its
/// task text (and its parent thread when T3 says), binding the note to the child's thread so its follow-ups find the run.
///
/// One file in lastdrop's support folder, `delegate-notes.json`, shared by every account profile (parent and child may
/// run under different `CLAUDE_CONFIG_DIR`s), every change under `delegate-notes.lock`. A note is a JSON object the
/// plugin owns; this reads only `id` (the run id), `createdAt` (ms since 1970), and the binding it adds, `thread` and
/// `claimedAt`. Unclaimed notes expire after ten minutes; claimed ones stay 30 days, the newest 500 at most.
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
        clean.removeValue(forKey: "thread")
        clean.removeValue(forKey: "claimedAt")
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

    /// Binds note `id` to `thread`, once: the note, or nil when it is gone, expired or another thread has it. The same
    /// thread claiming again gets it back.
    static func claim(_ id: String, thread: String, now: Date = Date()) -> Note? {
        withNotes(now: now) { notes in
            guard let i = notes.firstIndex(where: { $0["id"] as? String == id }) else { return nil }
            if let owner = notes[i]["thread"] as? String { return owner == thread ? notes[i] : nil }
            notes[i]["thread"] = thread
            notes[i]["claimedAt"] = ms(now)
            return notes[i]
        }
    }

    private static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
    private static func created(_ note: Note) -> Double { (note["createdAt"] as? NSNumber)?.doubleValue ?? 0 }

    /// Drops expired notes: unclaimed after ten minutes, claimed after 30 days or past the newest 500.
    private static func prune(_ notes: inout [Note], now: Date) {
        let nowMs = Double(ms(now))
        notes.removeAll { note in
            let claimed = note["thread"] != nil
            let since = ((claimed ? note["claimedAt"] : nil) as? NSNumber)?.doubleValue ?? created(note)
            return (nowMs - since) / 1000 > (claimed ? claimedTTL : unclaimedTTL)
        }
        let claimed = notes.enumerated().filter { $0.element["thread"] != nil }
        if claimed.count > keptClaimed {
            let oldest = Set(claimed.sorted { created($0.element) < created($1.element) }.prefix(claimed.count - keptClaimed).map(\.offset))
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
        default:
            return ["type": "error", "text": "delegate-note: unknown op \(op)"]
        }
    }

    /// `lastdrop --delegate-note`: one request on stdin (`{"op":"put"|"drop"|"list"|"claim",…}`), one JSON line out.
    static func main() -> Never {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let out = answer(input)
        let data = (try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        FileHandle.standardOutput.write(data + Data("\n".utf8))
        exit(out["type"] as? String == "error" ? 1 : 0)
    }
}
