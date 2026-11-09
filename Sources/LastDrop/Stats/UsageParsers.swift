import Foundation

/// Tokens by how they're billed.
struct UsageTokens: Equatable, Sendable {
    var input: Int64 = 0
    var cacheWrite: Int64 = 0
    var cacheWriteLong: Int64 = 0
    var cacheRead: Int64 = 0
    var output: Int64 = 0

    var total: Int64 { input + cacheWrite + cacheWriteLong + cacheRead + output }
    var promptSize: Int64 { input + cacheWrite + cacheWriteLong + cacheRead }

    static func += (a: inout UsageTokens, b: UsageTokens) {
        a.input += b.input
        a.cacheWrite += b.cacheWrite
        a.cacheWriteLong += b.cacheWriteLong
        a.cacheRead += b.cacheRead
        a.output += b.output
    }
}

/// One billed request. Strings repeat on nearly every row, so rows hold indexes into their file's lists.
struct UsageRow: Sendable {
    var hash: Int64
    var hour: Int32
    var session: Int32
    var model: Int32
    var directory: Int32
    var tokens: UsageTokens
}

/// What a file's new lines said.
struct ParsedUsage: Sendable {
    /// `key`: stable across files, so one session's copies add up as one.
    struct Session: Sendable { var key: String; var agent: Bool }
    var rows: [UsageRow] = []
    var sessions: [Session] = []
    var models: [String] = []
    var directories: [String] = []
    /// Antigravity keeps no working directory: paths its transcript mentions, and how often.
    var mentions: [String: Int] = [:]
    /// Where to read from next time.
    var end: Int64 = 0
    var context = UsageContext()
}

/// What a transcript states once, kept between reads because later lines don't repeat it.
struct UsageContext: Equatable, Sendable {
    var session: String?
    var model: String?
    var directory: String?
    var repository: String?
    var agent = false
}

/// What lastdrop itself knows about the agents it ran.
struct UsageLedger: Sendable {
    struct Run: Decodable, Sendable { var sessionID: String?; var model: String?; var directory: String? }
    private struct File: Decodable { var agents: [String: Run] }

    var runs: [String: Run] = [:]
    /// Agent name → model, for transcripts that open with "You are sol".
    var models: [String: String] = [:]

    static func load() -> UsageLedger {
        var ledger = UsageLedger()
        if let data = try? Data(contentsOf: LastDropPaths.agents), let file = try? JSONDecoder.lastdrop.decode(File.self, from: data) {
            for run in file.agents.values { if let id = run.sessionID { ledger.runs[id] = run } }
        }
        for agent in AgentCatalog.load().agents { ledger.models[agent.name] = agent.model }
        return ledger
    }
}

/// Turns repeated strings into small indexes, hashing the raw bytes so a repeat allocates nothing.
private struct Interner {
    private var indexes: [UInt64: Int32] = [:]
    private var lastHash: UInt64?
    private var lastIndex: Int32 = 0

    mutating func index(_ raw: Bytes, into list: inout [String], make: (Bytes) -> String) -> Int32 {
        var hash = StableHash()
        hash.add(raw)
        if hash.value == lastHash { return lastIndex }
        let index: Int32
        if let known = indexes[hash.value] {
            index = known
        } else {
            index = Int32(list.count)
            list.append(make(raw))
            indexes[hash.value] = index
        }
        lastHash = hash.value
        lastIndex = index
        return index
    }
}

enum UsageParser {
    static func parse(_ file: UsageFile, from offset: Int64, context: UsageContext, ledger: UsageLedger) -> ParsedUsage {
        switch file.kind {
        case .claude: claude(file.path, from: offset, forkedAt: file.forkedAt, ledger: ledger)
        case .codex: codex(file.path, from: offset, context: context)
        case .antigravity: antigravity(file.path, from: offset, context: context, ledger: ledger)
        }
    }

    private static func text(_ raw: Bytes) -> String { String(decoding: raw, as: UTF8.self) }

    // MARK: Claude Code

    /// Each request's usage stands on every line of its message, its output still growing on the early ones, and
    /// a session copied to another account keeps its rows: `(message id, request id)` identifies it. Rows with a `msg_hook_` id are other providers' runs
    /// that lastdrop's plugin put back into the conversation, under a Claude label; those runs count where they ran.
    static func claude(_ path: String, from offset: Int64, forkedAt: Date? = nil, ledger: UsageLedger) -> ParsedUsage {
        var out = ParsedUsage()
        var sessions = Interner(), models = Interner(), directories = Interner()
        var sessionIDs: [String] = []
        // Lines from before the fork were copied from the conversation it came from, which counts them. Whole
        // hours are enough: the copies made right at the fork dedupe on the request's identity.
        let forkedHour = forkedAt.map { Int32($0.timeIntervalSince1970 / 3600) }
        out.end = UsageFiles.lines(path: path, from: offset) { line in
            guard line.contains("\"usage\""), line.contains("\"assistant\""), !line.contains("\"msg_hook_") else { return }
            var type = Bytes(start: nil, count: 0), message = type, timestamp = type, sessionID = type, agentID = type, cwd = type, request = type
            var sidechain = false
            JSONSkim.fields(line) { key, value in
                if key.is("type") { type = value.rawString }
                else if key.is("message") { message = value }
                else if key.is("timestamp") { timestamp = value.rawString }
                else if key.is("sessionId") { sessionID = value.rawString }
                else if key.is("agentId") { agentID = value.rawString }
                else if key.is("isSidechain") { sidechain = value.bool }
                else if key.is("cwd") { cwd = value }
                else if key.is("requestId") { request = value }
            }
            guard type.is("assistant"), message.count > 0, let hour = timestamp.utcHour else { return }
            if let forked = forkedHour, hour < forked { return }
            var id = Bytes(start: nil, count: 0), model = id, usage = id
            JSONSkim.fields(message) { key, value in
                if key.is("id") { id = value }
                else if key.is("model") { model = value.rawString }
                else if key.is("usage") { usage = value }
            }
            guard usage.count > 2, model.count > 0, model[0] != UInt8(ascii: "<") else { return }
            var tokens = UsageTokens()
            var cacheCreation: Int64 = 0
            var split: Bytes?
            JSONSkim.fields(usage) { key, value in
                if key.is("input_tokens") { tokens.input = value.int }
                else if key.is("output_tokens") { tokens.output = value.int }
                else if key.is("cache_read_input_tokens") { tokens.cacheRead = value.int }
                else if key.is("cache_creation_input_tokens") { cacheCreation = value.int }
                else if key.is("cache_creation") { split = value }
            }
            tokens.cacheWrite = cacheCreation
            if let split {
                var short: Int64 = 0, long: Int64 = 0
                JSONSkim.fields(split) { key, value in
                    if key.is("ephemeral_5m_input_tokens") { short = value.int }
                    else if key.is("ephemeral_1h_input_tokens") { long = value.int }
                }
                if short + long > 0 { tokens.cacheWrite = short; tokens.cacheWriteLong = long }
            }
            var hash = StableHash()
            hash.add(id)
            hash.add(request)
            let side = sidechain && agentID.count > 0
            let sessionIndex = sessions.index(side ? agentID : sessionID, into: &sessionIDs) { text($0) }
            if Int(sessionIndex) == out.sessions.count {
                let id = sessionIDs[Int(sessionIndex)]
                out.sessions.append(.init(key: "claude:" + id, agent: side || ledger.runs[id] != nil))
            }
            let modelIndex = models.index(model, into: &out.models) { text($0) }
            let directory = directories.index(cwd, into: &out.directories) { $0.string ?? "" }
            out.rows.append(UsageRow(hash: hash.signed, hour: hour, session: sessionIndex, model: modelIndex, directory: directory, tokens: tokens))
        }
        return out
    }

    // MARK: Codex

    /// Tools that start Codex for someone else; anything they start is an agent.
    private static let agentOriginators: Set<String> = ["claude_codex_bridge", "codex_exec", "lastdrop", "headroom"]

    /// Each response logs its tokens, sometimes twice, at different times. A spawned agent's file replays its
    /// parent's lines. The running total and the response's own tokens identify it through both.
    static func codex(_ path: String, from offset: Int64, context: UsageContext) -> ParsedUsage {
        var out = ParsedUsage()
        out.context = context
        out.sessions = [.init(key: "", agent: false)]
        out.directories = [""]
        var modelIndex: Int32 = -1
        out.end = UsageFiles.lines(path: path, from: offset) { line in
            let head = Bytes(rebasing: line.prefix(160))
            if head.contains("\"session_meta\"") {
                guard out.context.session == nil else { return }
                readSessionMeta(line, into: &out.context)
            } else if head.contains("\"turn_context\"") {
                JSONSkim.fields(line) { key, value in
                    guard key.is("payload") else { return }
                    JSONSkim.fields(value) { key, value in
                        if key.is("model"), let model = value.string, model != out.context.model {
                            out.context.model = model
                            modelIndex = -1
                        }
                    }
                }
            } else if head.contains("\"event_msg\""), line.contains("\"last_token_usage\"") {
                var timestamp = Bytes(start: nil, count: 0), payload = timestamp
                JSONSkim.fields(line) { key, value in
                    if key.is("timestamp") { timestamp = value.rawString }
                    else if key.is("payload") { payload = value }
                }
                var type = Bytes(start: nil, count: 0), info = type
                JSONSkim.fields(payload) { key, value in
                    if key.is("type") { type = value.rawString }
                    else if key.is("info") { info = value }
                }
                guard type.is("token_count"), let hour = timestamp.utcHour, let model = out.context.model else { return }
                var last = Bytes(start: nil, count: 0), running = last
                JSONSkim.fields(info) { key, value in
                    if key.is("last_token_usage") { last = value }
                    else if key.is("total_token_usage") { running = value }
                }
                var input: Int64 = 0, cached: Int64 = 0, written: Int64 = 0, output: Int64 = 0
                JSONSkim.fields(last) { key, value in
                    if key.is("input_tokens") { input = value.int }
                    else if key.is("cached_input_tokens") { cached = value.int }
                    else if key.is("cache_write_input_tokens") { written = value.int }
                    else if key.is("output_tokens") { output = value.int }
                }
                guard last.count > 0 else { return }
                var hash = StableHash()
                hash.add(running)
                hash.add(last)
                if modelIndex < 0 {
                    modelIndex = Int32(out.models.firstIndex(of: model) ?? out.models.count)
                    if Int(modelIndex) == out.models.count { out.models.append(model) }
                }
                let tokens = UsageTokens(input: input - cached - written, cacheWrite: written, cacheRead: cached, output: output)
                out.rows.append(UsageRow(hash: hash.signed, hour: hour, session: 0, model: modelIndex, directory: 0, tokens: tokens))
            }
        }
        let id = out.context.session ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        out.sessions[0] = .init(key: "codex:" + id, agent: out.context.agent)
        out.directories[0] = out.context.directory ?? ""
        return out
    }

    private static func readSessionMeta(_ line: Bytes, into context: inout UsageContext) {
        var meta = Bytes(start: nil, count: 0)
        JSONSkim.fields(line) { key, value in if key.is("payload") { meta = value } }
        var originator: String?
        var git = Bytes(start: nil, count: 0)
        var spawned = false
        var read = UsageContext()
        JSONSkim.fields(meta) { key, value in
            if key.is("id") { read.session = value.string }
            else if key.is("cwd") { read.directory = value.string }
            else if key.is("originator") { originator = value.string }
            else if key.is("source") { spawned = value.count > 0 && value[0] == UInt8(ascii: "{") }
            else if key.is("git") { git = value }
        }
        JSONSkim.fields(git) { key, value in if key.is("repository_url") { read.repository = value.string } }
        read.agent = spawned || originator.map(agentOriginators.contains) == true
        read.model = context.model
        context = read
    }

    // MARK: Antigravity

    /// One step per line with its tokens, but no model and no working directory: lastdrop's ledger has both for
    /// recent runs, and for others the opening line names the agent and the paths mentioned give the project.
    static func antigravity(_ path: String, from offset: Int64, context: UsageContext, ledger: UsageLedger) -> ParsedUsage {
        var out = ParsedUsage()
        out.context = context
        let id = URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        let run = ledger.runs[id]
        out.context.session = id
        out.context.agent = true
        if out.context.model == nil { out.context.model = run?.model }
        if out.context.directory == nil { out.context.directory = run?.directory }
        out.sessions = [.init(key: "antigravity:" + id, agent: true)]
        let home = NSHomeDirectory() + "/"
        var needsModel = out.context.model == nil
        let needsDirectory = out.context.directory == nil
        out.end = UsageFiles.lines(path: path, from: offset) { line in
            if needsModel, let name = agentName(line) {
                out.context.model = ledger.models[name]
                needsModel = false
            }
            if needsDirectory { mentions(in: line, home: home, into: &out.mentions) }
            guard line.contains("\"input_tokens\"") else { return }
            var created = Bytes(start: nil, count: 0)
            var step: Int64 = 0
            var tokens = UsageTokens()
            JSONSkim.fields(line) { key, value in
                if key.is("created_at") { created = value.rawString }
                else if key.is("step_index") { step = value.int }
                else if key.is("input_tokens") { tokens.input = value.int }
                else if key.is("output_tokens") { tokens.output = value.int }
                else if key.is("cache_read_tokens") { tokens.cacheRead = value.int }
            }
            guard let hour = created.utcHour else { return }
            var hash = StableHash()
            hash.add(step)
            var key = id
            key.withUTF8 { hash.add($0) }
            out.rows.append(UsageRow(hash: hash.signed, hour: hour, session: 0, model: 0, directory: 0, tokens: tokens))
        }
        out.models = [out.context.model ?? "gemini"]
        out.directories = [out.context.directory ?? ""]
        return out
    }

    /// "sol" in a line with "You are sol, a subagent".
    private static func agentName(_ line: Bytes) -> String? {
        let opening: StaticString = "You are "
        guard let hit = memmem(line.baseAddress, line.count, opening.utf8Start, opening.utf8CodeUnitCount) else { return nil }
        let start = UnsafePointer(hit.assumingMemoryBound(to: UInt8.self)) + opening.utf8CodeUnitCount
        let rest = Bytes(start: start, count: min(line.baseAddress! + line.count - start, 40))
        guard let end = rest.firstIndex(of: UInt8(ascii: ",")) else { return nil }
        return String(decoding: rest[..<end], as: UTF8.self)
    }

    private static func mentions(in line: Bytes, home: String, into found: inout [String: Int]) {
        guard found.count < 256, var cursor = line.baseAddress else { return }
        let end = cursor + line.count
        var home = home
        home.withUTF8 { prefix in
            while cursor < end, let hit = memmem(cursor, end - cursor, prefix.baseAddress, prefix.count) {
                let start = UnsafePointer(hit.assumingMemoryBound(to: UInt8.self))
                var stop = start
                while stop < end, stop.pointee > 0x20, stop.pointee != 0x22, stop.pointee != 0x5C, stop.pointee != UInt8(ascii: "'"), stop.pointee != UInt8(ascii: ")") { stop += 1 }
                found[String(decoding: Bytes(start: start, count: stop - start), as: UTF8.self), default: 0] += 1
                cursor = stop
            }
        }
    }
}
