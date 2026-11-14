import Foundation

/// The sessions `lastdrop --acp` answered, by ACP session id, in `acp-sessions.json` in the support folder. T3 kills
/// an idle agent process after 30 minutes and opens the thread again with `session/resume` and the stored id, so a
/// session must outlive its process. An entry is written at a session's first prompt, never by `session/new` (T3's
/// probe opens a session every 15 minutes and drops it), and holds only what the next turn needs to continue the
/// same lastdrop run: the run's id, what it runs, and whether the runner started it.
enum ACPSessions {
    struct Entry: Codable, Equatable {
        /// The lastdrop run (`--agent-run`'s `id`): the tag's id, so stop and resume reach the same run.
        var run: String
        /// The model T3 picked for the session (`session/set_config_option`).
        var model: String?
        /// What the runner runs, as the tag or the picked model gave it: an agent of lastdrop's list, or a Claude model.
        var agent: String?
        var runModel: String?
        /// The effort the runner gets: an untagged run's choice as its model takes it (`ACPServer.resolveEffort`).
        var effort: String?
        /// The effort T3's menu chose for an untagged run (nil: auto), kept for the menu and the answer's header.
        var requestedEffort: String?
        var description: String?
        var permissionMode: String?
        var parentModel: String?
        var cwd: String
        /// The runner started the run: later turns continue it (`resume`) with only their new text.
        var ran: Bool
        /// The task, kept until the runner starts it: a prompt cancelled before then sends it again with the next one.
        var task: String?
        /// The first prompt had no lastdrop tag, so no plugin checked room: the server does before the run starts.
        var checksRoom: Bool?
        var updated: Date
    }

    /// Entries untouched this long are dropped at the next write.
    static let keepFor: TimeInterval = 60 * 24 * 3600

    static var file: URL { LastDropPaths.support.appendingPathComponent("acp-sessions.json") }

    static func lookup(_ id: String, at url: URL = file) -> Entry? { load(url)[id] }

    /// Writes `entry` for `id` under a lock: one lastdrop process runs per T3 thread, and many write at once.
    static func save(_ id: String, _ entry: Entry, at url: URL = file, now: Date = .now) {
        withLock(url) {
            var all = load(url).filter { now.timeIntervalSince($0.value.updated) < keepFor }
            var entry = entry
            entry.updated = now
            all[id] = entry
            LastDropPaths.ensure(url.deletingLastPathComponent())
            if let data = try? JSONEncoder.lastdrop.encode(all) {
                do { try data.write(to: url, options: .atomic) } catch {
                    SubagentLog.write("acp: couldn't write \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
    }

    private static func load(_ url: URL) -> [String: Entry] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder.lastdrop.decode([String: Entry].self, from: $0) } ?? [:]
    }

    private static func withLock<T>(_ url: URL, _ body: () -> T) -> T {
        LastDropPaths.ensure(url.deletingLastPathComponent())
        let fd = open(url.path + ".lock", O_CREAT | O_RDWR, 0o600)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        return body()
    }
}
