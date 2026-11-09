import Foundation

/// A small database of what every transcript on this Mac has used, hour by hour.
///
/// Reading gigabytes of transcripts each time isn't an option, and they don't last: Claude Code and Codex delete
/// old sessions. So each file is read once, from where it was left, and only totals are kept. The index outlives
/// the transcripts, and a scan with nothing new reads nothing.
final class UsageIndex: @unchecked Sendable {
    /// History older than this isn't read on the first run. The panel shows 30 days, and compares them to the 30 before.
    static let historyDays = 61
    /// How long a request's identity is remembered, for a session copied to another account later.
    private static let dedupeDays = 180
    /// A pass over many files commits in steps, so a quit loses little and the panel can show what's there.
    private static let batchBytes: Int64 = 256 << 20
    private static let batchFiles = 512
    private static let schema: Int64 = 1

    private let db: SQLite
    private let statements: Statements
    private let roots: [UsageFiles.Root]
    private let ledger: () -> UsageLedger
    private let now: () -> Date
    private var names = ProjectNames()
    private var pruned = Date.distantPast

    private struct Cursor {
        var size: Int64
        var modified: Int64
        var born: Int64
        var offset: Int64
    }

    static var defaultPath: String { LastDropPaths.support.appendingPathComponent("usage.sqlite").path }

    init?(path: String = UsageIndex.defaultPath, roots: [UsageFiles.Root] = UsageFiles.roots(),
          ledger: @escaping () -> UsageLedger = UsageLedger.load, now: @escaping () -> Date = Date.init) {
        LastDropPaths.ensure(URL(fileURLWithPath: path).deletingLastPathComponent())
        guard let (db, statements) = Self.open(path) else { return nil }
        self.db = db
        self.statements = statements
        self.roots = roots
        self.ledger = ledger
        self.now = now
    }

    /// A damaged file is replaced, and its history read again from the transcripts that remain. Any other failure,
    /// as a full disk, leaves it alone.
    private static func open(_ path: String) -> (SQLite, Statements)? {
        guard let db = SQLite(path: path) else { return nil }
        if db.run(setup), let statements = Statements(db) { return (db, statements) }
        guard db.isCorrupt else { return nil }
        for suffix in ["", "-wal", "-shm"] { unlink(path + suffix) }
        guard let fresh = SQLite(path: path), fresh.run(setup), let statements = Statements(fresh) else { return nil }
        return (fresh, statements)
    }

    private static let setup = """
        PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA temp_store=MEMORY; PRAGMA journal_size_limit=4194304;
        BEGIN;
        CREATE TABLE IF NOT EXISTS name(id INTEGER PRIMARY KEY, kind INT NOT NULL, text TEXT NOT NULL, UNIQUE(kind, text));
        CREATE TABLE IF NOT EXISTS session(id INTEGER PRIMARY KEY, key INT NOT NULL UNIQUE, agent INT NOT NULL);
        CREATE TABLE IF NOT EXISTS file(path TEXT PRIMARY KEY, size INT, modified INT, born INT, offset INT,
                                        session TEXT, model TEXT, directory TEXT, repository TEXT, agent INT) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS seen(hash INTEGER PRIMARY KEY, hour INT NOT NULL, output INT NOT NULL) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS usage(
            hour INT NOT NULL, session INT NOT NULL, model INT NOT NULL, size INT NOT NULL, project INT NOT NULL, account INT NOT NULL,
            input INT NOT NULL, write INT NOT NULL, write_long INT NOT NULL, read INT NOT NULL, output INT NOT NULL,
            PRIMARY KEY(hour, session, model, size, project, account)) WITHOUT ROWID;
        PRAGMA user_version=\(schema);
        COMMIT;
        """

    // MARK: Reading transcripts

    /// Brings the index up to date. `progress` gets the share done when there's much to read. True if anything new was added.
    @discardableResult
    func update(progress: @escaping @Sendable (Double) -> Void = { _ in }) -> Bool {
        var files: [UsageFile] = []
        // The ledger is read once per scan: it says which account each conversation in the shared folder ran on.
        let sessions = SessionLedger.allSessions()
        for root in roots { UsageFiles.list(root, ledger: sessions, into: &files) }
        var cursors = loadCursors()
        let horizon = Int64(now().timeIntervalSince1970) - Int64(Self.historyDays) * 86400
        var pending: [UsageFile] = []
        for file in files {
            if let cursor = cursors[file.path] {
                if cursor.size != file.size || cursor.modified != file.modified || cursor.born != file.born { pending.append(file) }
            } else if file.modified >= horizon {
                pending.append(file)
            }
        }
        forget(cursors.keys.filter { [paths = Set(files.map(\.path))] in !paths.contains($0) })
        guard !pending.isEmpty else { return false }

        // The oldest copy of a session comes first, so its rows stay with the account they ran on.
        pending.sort { ($0.born, $0.path) < ($1.born, $1.path) }
        let run = ledger()
        let total = pending.reduce(0) { $0 + max($1.size - (cursors[$1.path]?.offset ?? 0), 1) }
        var done: Int64 = 0
        var added = false
        var start = 0
        while start < pending.count {
            var end = start, bytes: Int64 = 0
            while end < pending.count, end - start < Self.batchFiles, bytes < Self.batchBytes {
                bytes += max(pending[end].size - (cursors[pending[end].path]?.offset ?? 0), 1)
                end += 1
            }
            let batch = Array(pending[start..<end])
            var parsed = parse(batch, cursors: cursors, ledger: run)
            // Nothing was saved: the next scan starts here again.
            guard let wrote = write(batch, &parsed) else { break }
            added = added || wrote
            for (file, usage) in zip(batch, parsed) {
                cursors[file.path] = Cursor(size: file.size, modified: file.modified, born: file.born, offset: usage.end)
            }
            done += bytes
            start = end
            if total > Self.batchBytes { progress(Double(done) / Double(total)) }
        }
        prune()
        if total > Self.batchBytes { db.run("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA optimize;") }
        return added
    }

    /// Reads a batch on every core; the files share nothing until they're written, one at a time, in order.
    private func parse(_ batch: [UsageFile], cursors: [String: Cursor], ledger: UsageLedger) -> [ParsedUsage] {
        let contexts = batch.map { file -> UsageContext? in
            guard let cursor = cursors[file.path], cursor.born == file.born, cursor.offset <= file.size else { return nil }
            return context(file.path)
        }
        var results = [ParsedUsage](repeating: ParsedUsage(), count: batch.count)
        results.withUnsafeMutableBufferPointer { buffer in
            let out = buffer
            DispatchQueue.concurrentPerform(iterations: batch.count) { i in
                let file = batch[i]
                // No context: new, or replaced. Rows already counted are recognized.
                out[i] = UsageParser.parse(file, from: contexts[i] == nil ? 0 : cursors[file.path]!.offset, context: contexts[i] ?? UsageContext(), ledger: ledger)
            }
        }
        return results
    }

    private func context(_ path: String) -> UsageContext {
        let query = statements.context.bind(.text(path))
        defer { query.reset() }
        guard query.next() else { return UsageContext() }
        return UsageContext(session: query.text(0), model: query.text(1), directory: query.text(2), repository: query.text(3), agent: query.int(4) != 0)
    }

    private struct UsageKey: Hashable {
        var hour: Int32
        var session: Int64
        var model: Int64
        var size: Int64
        var project: Int64
        var account: Int64
    }

    /// Whether anything new was added, or nil if nothing was saved. All of a batch or none of it: a row marked seen
    /// but not counted would never be counted.
    private func write(_ batch: [UsageFile], _ parsed: inout [ParsedUsage]) -> Bool? {
        db.failed = false
        guard db.run("BEGIN IMMEDIATE") else { return nil }
        for i in parsed.indices where parsed[i].context.directory == nil && !parsed[i].mentions.isEmpty {
            guard let path = names.mostMentioned(parsed[i].mentions) else { continue }
            parsed[i].context.directory = path
            parsed[i].directories = [path]
        }
        var totals: [UsageKey: UsageTokens] = [:]
        var nameIDs: [String: Int64] = [:]
        func id(_ kind: Int64, _ text: String) -> Int64 {
            let key = "\(kind):\(text)"
            if let known = nameIDs[key] { return known }
            let statement = statements.name.bind(.int(kind), .text(text))
            let id = statement.next() ? statement.int(0) : 0
            statement.reset()
            nameIDs[key] = id
            return id
        }
        for (file, usage) in zip(batch, parsed) {
            let account = id(0, file.account)
            let sessions = usage.sessions.map { session -> Int64 in
                let statement = statements.session.bind(.int(StableHash.of(session.key)), .int(session.agent ? 1 : 0))
                let id = statement.next() ? statement.int(0) : 0
                statement.reset()
                return id
            }
            let models = usage.models.map { id(1, $0) }
            let projects = usage.directories.map { directory in
                id(2, directory.isEmpty ? "Other" : names.name(directory: directory, repository: usage.context.repository))
            }
            for row in usage.rows {
                var tokens = row.tokens
                if !statements.seen.bind(.int(row.hash), .int(Int64(row.hour)), .int(row.tokens.output)).write() {
                    guard let extra = addedOutput(row) else { continue }
                    tokens = UsageTokens(output: extra)
                }
                let key = UsageKey(hour: row.hour, session: sessions[Int(row.session)], model: models[Int(row.model)],
                                   size: UsagePrice.sizeClass(row.tokens.promptSize), project: projects[Int(row.directory)], account: account)
                totals[key, default: UsageTokens()] += tokens
            }
            // Couldn't read it: try again next scan, even if it never changes.
            guard usage.end >= 0 else { continue }
            let c = usage.context
            statements.file.bind(.text(file.path), .int(file.size), .int(file.modified), .int(file.born), .int(usage.end), .optional(c.session),
                                 .optional(c.model), .optional(c.directory), .optional(c.repository), .int(c.agent ? 1 : 0)).write()
        }
        for (key, t) in totals {
            statements.usage.bind(.int(Int64(key.hour)), .int(key.session), .int(key.model), .int(key.size),.int(key.project), .int(key.account),
                                  .int(t.input), .int(t.cacheWrite), .int(t.cacheWriteLong), .int(t.cacheRead), .int(t.output)).write()
        }
        guard !db.failed, db.run("COMMIT") else {
            db.run("ROLLBACK")
            return nil
        }
        return !totals.isEmpty
    }

    /// A later line of a request already counted: how much more output it reports, if any.
    private func addedOutput(_ row: UsageRow) -> Int64? {
        let query = statements.seenOutput.bind(.int(row.hash))
        let counted = query.next() ? query.int(0) : row.tokens.output
        query.reset()
        guard row.tokens.output > counted else { return nil }
        statements.growOutput.bind(.int(row.tokens.output), .int(row.hash)).write()
        return row.tokens.output - counted
    }

    private func loadCursors() -> [String: Cursor] {
        var cursors: [String: Cursor] = [:]
        guard let query = db.prepare("SELECT path, size, modified, born, offset FROM file") else { return cursors }
        while query.next() {
            cursors[query.text(0) ?? ""] = Cursor(size: query.int(1), modified: query.int(2), born: query.int(3), offset: query.int(4))
        }
        return cursors
    }

    private func forget(_ paths: [String]) {
        guard !paths.isEmpty, let delete = db.prepare("DELETE FROM file WHERE path = ?") else { return }
        db.run("BEGIN")
        for path in paths { delete.bind(.text(path)).write() }
        db.run("COMMIT")
    }

    private func prune() {
        guard now().timeIntervalSince(pruned) > 86400 else { return }
        pruned = now()
        let oldest = Int(now().timeIntervalSince1970 / 3600) - Self.dedupeDays * 24
        db.run("DELETE FROM seen WHERE hour < \(oldest)")
    }

    private struct Statements {
        let name, session, seen, seenOutput, growOutput, file, usage, context: SQLite.Statement

        init?(_ db: SQLite) {
            guard let context = db.prepare("SELECT session, model, directory, repository, agent FROM file WHERE path = ?"),
                  let name = db.prepare("INSERT INTO name(kind, text) VALUES(?, ?) ON CONFLICT(kind, text) DO UPDATE SET text = excluded.text RETURNING id"),
                  let session = db.prepare("INSERT INTO session(key, agent) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET agent = agent | excluded.agent RETURNING id"),
                  let seen = db.prepare("INSERT OR IGNORE INTO seen(hash, hour, output) VALUES(?, ?, ?)"),
                  let seenOutput = db.prepare("SELECT output FROM seen WHERE hash = ?"),
                  let growOutput = db.prepare("UPDATE seen SET output = ? WHERE hash = ?"),
                  let file = db.prepare("INSERT OR REPLACE INTO file VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"),
                  let usage = db.prepare("""
                  INSERT INTO usage VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                  ON CONFLICT DO UPDATE SET input = input + excluded.input, write = write + excluded.write,
                      write_long = write_long + excluded.write_long, read = read + excluded.read, output = output + excluded.output
                  """) else { return nil }
            (self.context, self.name, self.session, self.seen, self.seenOutput, self.growOutput, self.file, self.usage)
                = (context, name, session, seen, seenOutput, growOutput, file, usage)
        }
    }
}
