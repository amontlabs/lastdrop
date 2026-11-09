import Foundation

/// Which Claude account each Claude Code conversation ran on, and which conversation each T3 Code thread
/// continues in now. Every account's folder shares one conversations folder (`~/.claude/projects`), so the
/// folder no longer tells which account a conversation used: this ledger does. The thread launcher and the
/// subagent runner write it; Stats and the launcher read it. It lives in its own file, under a lock, because
/// several processes write it (each launch, each subagent run, the app).
enum SessionLedger {
    struct Session: Codable, Equatable, Sendable {
        /// `ClaudeAccount.id`: "main", or an account's folder name.
        var account: String
        var startedAt: Date
        /// For a conversation forked from another (`--fork-session`, when a thread or an agent moves to another
        /// account): its lines from before this were copied from the conversation it came from, which counts them.
        var forkedAt: Date?
    }

    /// A T3 Code thread, keyed by the session id T3 knows it by (T3 never learns of a fork's new id).
    struct Thread: Codable, Equatable, Sendable {
        /// The conversation it continues in now: T3's own id until it first moves.
        var current: String
        var at: Date
    }

    /// A thread's Claude Code process the launcher started: the app ends it between turns once its account is out.
    struct Live: Codable, Equatable, Sendable {
        var pid: Int32
        var account: String
        var session: String
        var thread: String
        var at: Date
        /// When the process started, so a reused pid isn't taken for it. Nil in entries written before this was
        /// kept (or without it): `addLive` fills it in, and an unknown one is checked by the process's name instead.
        var startedAt: Date?

        init(pid: Int32, account: String, session: String, thread: String, at: Date, startedAt: Date? = nil) {
            self.pid = pid
            self.account = account
            self.session = session
            self.thread = thread
            self.at = at
            self.startedAt = startedAt
        }
    }

    struct Store: Codable, Equatable, Sendable {
        var sessions: [String: Session] = [:]
        var threads: [String: Thread] = [:]
        var live: [Live] = []

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sessions = try c.decodeIfPresent([String: Session].self, forKey: .sessions) ?? [:]
            threads = try c.decodeIfPresent([String: Thread].self, forKey: .threads) ?? [:]
            live = try c.decodeIfPresent([Live].self, forKey: .live) ?? []
        }
    }

    // MARK: Sessions

    /// The most sessions kept, and the age under which none is ever dropped (see `prune`).
    static let maxSessions = 20_000
    static let keepNewerThan: TimeInterval = 30 * 86_400

    /// Notes that `session` runs on `account`. A session already noted keeps its first account and start, except
    /// that a fresh (not forked) record replaces one whose conversation has no transcript lines yet: T3 restarts a
    /// thread nobody answered with `--session-id X` on another account, and the old record would misattribute it.
    /// `replace: true` forces it. Past `maxSessions` the oldest are dropped.
    static func record(session: String, account: String, forkedAt: Date? = nil, at: Date = Date(), replace: Bool = false) {
        guard !session.isEmpty else { return }
        withStore { store in
            if let existing = store.sessions[session] {
                guard replace || (forkedAt == nil && existing.account != account && !hasTranscriptLines(session)) else { return }
            }
            store.sessions[session] = Session(account: account, startedAt: at, forkedAt: forkedAt)
            prune(&store, now: at)
        }
    }

    /// Stats needs a session's account only until its transcript is indexed, so the ledger keeps at most
    /// `maxSessions`, dropping the oldest `startedAt` first and never a session newer than 30 days.
    static func prune(_ store: inout Store, now: Date = Date()) {
        guard store.sessions.count > maxSessions else { return }
        let cutoff = now.addingTimeInterval(-keepNewerThan)
        let old = store.sessions.filter { $0.value.startedAt < cutoff }.sorted { $0.value.startedAt < $1.value.startedAt }
        for (id, _) in old.prefix(store.sessions.count - maxSessions) { store.sessions.removeValue(forKey: id) }
    }

    /// Whether the session's transcript in `~/.claude/projects` already has a line.
    static func hasTranscriptLines(_ session: String) -> Bool {
        guard let url = SessionTransfer.transcript(session, in: SessionTransfer.mainProjects) else { return false }
        return ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0) > 0
    }

    static func session(_ id: String) -> Session? { withStore { $0.sessions[id] } }

    /// Every session noted so far, for Stats.
    static func allSessions() -> [String: Session] { withStore { $0.sessions } }

    // MARK: Threads

    /// The conversation T3's thread `thread` continues in now: its own id until it first moved.
    static func currentSession(ofThread thread: String) -> String {
        withStore { $0.threads[thread]?.current } ?? thread
    }

    static func setCurrent(_ session: String, ofThread thread: String, at: Date = Date()) {
        withStore { store in
            store.threads[thread] = Thread(current: session, at: at)
            if store.threads.count > 2000 {
                store.threads = Dictionary(uniqueKeysWithValues: store.threads.sorted { $0.value.at > $1.value.at }
                    .prefix(1500).map { ($0.key, $0.value) })
            }
        }
    }

    // MARK: Live processes

    static func addLive(_ entry: Live) {
        var entry = entry
        if entry.startedAt == nil { entry.startedAt = processStart(entry.pid) }
        withStore { store in
            store.live.removeAll { $0.pid == entry.pid || !isAlive($0.pid) }
            store.live.append(entry)
        }
    }

    /// The launched processes still running.
    static func live() -> [Live] {
        withStore { store in
            store.live.removeAll { !isAlive($0.pid) }
            return store.live
        }
    }

    static func removeLive(pid: Int32) { withStore { $0.live.removeAll { $0.pid == pid } } }

    /// When the process `pid` started, nil if it isn't there.
    static func processStart(_ pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }

    /// The path of the process's executable, nil if it isn't there.
    static func processPath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard pid > 0, proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// True when `pid` is still the process the entry recorded, not another that reused the pid: the start time
    /// when known, else an executable whose path mentions claude (or the node/bun it runs on).
    static func isSameProcess(_ entry: Live) -> Bool {
        guard let started = processStart(entry.pid) else { return false }
        if let recorded = entry.startedAt { return abs(started.timeIntervalSince(recorded)) < 2 }
        let path = (processPath(entry.pid) ?? "").lowercased()
        return path.contains("claude") || path.hasSuffix("/node") || path.hasSuffix("/bun")
    }

    static func isAlive(_ pid: Int32) -> Bool { pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) }

    // MARK: File

    static let file = LastDropPaths.support.appendingPathComponent("sessions.json")

    /// Tests keep the ledger in a file of their own.
    nonisolated(unsafe) static var fileOverride: URL?

    private static func withStore<T>(_ body: (inout Store) -> T) -> T {
        let url = fileOverride ?? file
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let lockFD = open(url.path + ".lock", O_CREAT | O_RDWR, 0o600)
        if lockFD >= 0 { flock(lockFD, LOCK_EX) }
        defer { if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) } }
        var store = Store()
        var writable = true
        if let data = try? Data(contentsOf: url) {
            if let decoded = try? JSONDecoder.lastdrop.decode(Store.self, from: data) {
                store = decoded
            } else {
                // Never written over: kept aside, and a new ledger starts only once it is.
                let aside = url.appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))")
                writable = (try? FileManager.default.moveItem(at: url, to: aside)) != nil
            }
        }
        let before = store
        let value = body(&store)
        if writable, store != before, let data = try? JSONEncoder.lastdrop.encode(store) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return value
    }
}

/// How big a Claude plan's limits are, in Pro's: Max 20x has twenty times Pro's 5-hour window but ten times its week.
struct PlanSize: Equatable, Sendable {
    var session: Double
    var weekly: Double

    init(session: Double = 1, weekly: Double = 1) {
        self.session = session
        self.weekly = weekly
    }

    /// From the plan name lastdrop shows: claude.ai's current names ("Pro", "Max", "Ultra"), or Claude Code's
    /// older ones when the profile can't be read ("Max 5x", "Max 20x"). Unknown plans count as Pro.
    init(plan: String?) {
        switch plan?.lowercased().replacingOccurrences(of: " ", with: "") {
        case "ultra", "max20x": self.init(session: 20, weekly: 10)
        case "max5x", "max": self.init(session: 5, weekly: 5)
        default: self.init()
        }
    }
}
