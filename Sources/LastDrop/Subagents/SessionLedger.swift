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

    /// Notes that `session` runs on `account`. A session already noted keeps its first account and start.
    static func record(session: String, account: String, forkedAt: Date? = nil, at: Date = Date()) {
        guard !session.isEmpty else { return }
        withStore { store in
            if store.sessions[session] == nil {
                store.sessions[session] = Session(account: account, startedAt: at, forkedAt: forkedAt)
            }
        }
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

    /// From the plan name lastdrop shows ("Pro", "Max 5x", "Max 20x"). Unknown plans count as Pro.
    init(plan: String?) {
        switch plan?.lowercased().replacingOccurrences(of: " ", with: "") {
        case "max20x": self.init(session: 20, weekly: 10)
        case "max5x", "max": self.init(session: 5, weekly: 5)
        default: self.init()
        }
    }
}
