import Foundation

/// `lastdrop --claude-thread <claude args…>`: the launcher the wrapper script T3 Code points at runs, which
/// picks the account and execs the real claude. T3 starts every thread's Claude Code itself and always resumes
/// it with the id it knows the thread by, so this launcher is the only place accounts can be chosen: a new
/// thread starts on the account with the most room, and a thread that continues moves only when moving costs
/// nothing (the conversation went quiet, or was just compacted). It writes the session ledger, because the
/// conversations folder is shared and no longer tells which account a conversation used.
enum ThreadLauncher {
    // MARK: The decision, and everything it reads

    /// What the current conversation's transcript says about its end: when it last answered, and whether a
    /// compaction followed that answer.
    struct Transcript: Equatable, Sendable {
        var lastAssistantAt: Date?
        var justCompacted: Bool

        /// No transcript to read: the conversation is old or unknown, so moving costs nothing.
        static let cold = Transcript(lastAssistantAt: nil, justCompacted: false)
    }

    /// The ledger reads the decision needs, as closures so tests can stand a fake in.
    struct Ledger: Sendable {
        /// The conversation a T3 thread continues in now: its own id until it first moved.
        var currentSession: @Sendable (_ thread: String) -> String
        /// The account a conversation was recorded on.
        var account: @Sendable (_ session: String) -> String?

        /// The real ledger file, shared with the app and the other runners.
        static let live = Ledger(currentSession: { SessionLedger.currentSession(ofThread: $0) },
                                 account: { SessionLedger.session($0)?.account })
    }

    enum Action: String, Sendable { case stay, move, new }

    /// One ledger write the caller applies after the decision (the decision itself writes nothing).
    enum Write: Equatable, Sendable {
        /// `SessionLedger.record(session:account:forkedAt:)`.
        case record(session: String, account: String, forkedAt: Date?)
        /// `SessionLedger.setCurrent(_:ofThread:)`.
        case current(session: String, thread: String)
    }

    struct Decision: Equatable, Sendable {
        /// The arguments claude runs with, every argument T3 passed kept but the resume and session ids.
        var args: [String]
        /// The account id the process runs on.
        var account: String
        var action: Action
        /// Why it stayed or moved, for the log.
        var reason: String
        var writes: [Write]
        /// The session the process runs (a move's new id, a resume's current conversation), "" when unknown.
        var session: String
    }

    /// The flags of T3's that matter, in either form (`--flag value`, `--flag=value`).
    struct Parsed: Equatable, Sendable {
        var resume: String?
        var sessionID: String?
        var resumeSessionAt: String?
        var forkSession = false
    }

    static func parse(_ args: [String]) -> Parsed {
        var parsed = Parsed()
        var i = 0
        while i < args.count {
            let arg = args[i]
            func value(_ name: String) -> String? {
                if arg == name, i + 1 < args.count { return args[i + 1] }
                if arg.hasPrefix(name + "=") { return String(arg.dropFirst(name.count + 1)) }
                return nil
            }
            if let v = value("--resume-session-at") { parsed.resumeSessionAt = v }
            else if let v = value("--resume") { parsed.resume = v }
            else if let v = value("--session-id") { parsed.sessionID = v }
            else if arg == "--fork-session" { parsed.forkSession = true }
            i += 1
        }
        return parsed
    }

    /// How long since a conversation last answered before moving it no longer costs a full re-read.
    static let warmAfter: TimeInterval = 55 * 60

    /// The account a thread runs on, and the arguments and ledger writes that follow. Reads nothing: every
    /// input is passed in, so tests try each rule.
    static func decide(_ args: [String], ledger: Ledger, candidates: [SubagentAccounts.Candidate],
                       transcript: Transcript, now: Date,
                       newSessionID: () -> String = { UUID().uuidString.lowercased() }) -> Decision {
        let parsed = parse(args)
        // Nothing to continue: a new thread (`--session-id X`), or a plain claude run without an id. It starts
        // on the roomiest account; main is the floor when no account can be trusted with it.
        guard let resume = parsed.resume else {
            let account = SubagentAccounts.pickForThread(candidates)?.account.id ?? ClaudeAccount.mainID
            let session = parsed.sessionID ?? ""
            return .init(args: args, account: account, action: .new,
                         reason: session.isEmpty ? "no session id" : "new thread",
                         writes: session.isEmpty ? [] : [.record(session: session, account: account, forkedAt: nil)],
                         session: session)
        }
        let current = ledger.currentSession(resume)
        let onCurrent = ledger.account(current) ?? ClaudeAccount.mainID
        // T3 forks the thread itself: it brings the new session id, the launcher only chooses the account.
        if parsed.forkSession {
            let account = SubagentAccounts.pickForThread(candidates)?.account.id ?? onCurrent
            let session = parsed.sessionID ?? current
            return .init(args: replacingResume(resume, with: current, in: args), account: account, action: .new,
                         reason: "T3 fork",
                         writes: parsed.sessionID.map { [.record(session: $0, account: account, forkedAt: now)] } ?? [],
                         session: session)
        }
        // `--resume-session-at` names messages of the current conversation's lineage: another account's fork
        // wouldn't have them, so the thread never moves whatever its transcript says.
        func stay(_ reason: String) -> Decision {
            .init(args: replacingResume(resume, with: current, in: args), account: onCurrent, action: .stay,
                  reason: reason, writes: [], session: current)
        }
        if parsed.resumeSessionAt != nil { return stay("resume-session-at") }
        let warm = transcript.lastAssistantAt.map { now.timeIntervalSince($0) < warmAfter } ?? false
        let free = !warm || transcript.justCompacted
        let candidate = candidates.first { $0.account.id == onCurrent }
        // An account whose usage can't be read can't be trusted not to be full: that counts as full. A full
        // account can't answer at all, so it ends a warm thread's stay too.
        let full = candidate.map { !SubagentAccounts.hasRoom($0) } ?? true
        if !free && !full { return stay("warm") }
        guard let best = SubagentAccounts.pickForThread(candidates), best.account.id != onCurrent else {
            return stay(full ? "full, no other account has room" : "already the roomiest")
        }
        // Moving costs nothing (the conversation is cold, or just compacted): fork it onto the roomier
        // account as a new session. T3 never learns the new id; the ledger maps the thread to it.
        let moved = newSessionID()
        var args = replacingResume(resume, with: current, in: args)
        args = droppingSessionID(in: args) + ["--fork-session", "--session-id", moved]
        return .init(args: args, account: best.account.id, action: .move,
                     reason: full ? "\(onCurrent) full" : "cold, \(best.account.id) has more room",
                     writes: [.record(session: moved, account: best.account.id, forkedAt: now),
                              .current(session: moved, thread: resume)],
                     session: moved)
    }

    /// `--resume X` (either form) renamed to another conversation, in place, everything else kept.
    static func replacingResume(_ old: String, with id: String, in args: [String]) -> [String] {
        var args = args
        if let i = args.firstIndex(of: "--resume"), i + 1 < args.count { args[i + 1] = id; return args }
        if let i = args.firstIndex(where: { $0.hasPrefix("--resume=") }) { args[i] = "--resume=\(id)" }
        return args
    }

    /// Drops `--session-id X` / `--session-id=X`: a move brings its own new id.
    static func droppingSessionID(in args: [String]) -> [String] {
        var kept: [String] = []
        var i = 0
        while i < args.count {
            if args[i] == "--session-id" { i += 2; continue }
            if args[i].hasPrefix("--session-id=") { i += 1; continue }
            kept.append(args[i])
            i += 1
        }
        return kept
    }

    // MARK: The transcript

    /// The conversations all accounts share; tests point this at a folder of their own.
    nonisolated(unsafe) static var projectsOverride: String?

    /// Only the tail is read: a conversation can be megabytes, and only its end says whether it is warm.
    static let tailBytes = 512 * 1024

    /// What the conversation's transcript (`~/.claude/projects/*/<session>.jsonl`) says about its end.
    /// A missing file counts as cold: an unreadable conversation is treated like an old one.
    static func transcript(ofConversation session: String) -> Transcript {
        guard !session.isEmpty else { return .cold }
        guard let file = conversationFile(session) else { return .cold }
        guard let data = tail(of: file) else { return .cold }
        return parseTail(data)
    }

    static func conversationFile(_ session: String) -> URL? {
        let root = projectsOverride ?? NSHomeDirectory() + "/.claude/projects"
        for project in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
            let file = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(project)
                .appendingPathComponent("\(session).jsonl")
            if FileManager.default.fileExists(atPath: file.path) { return file }
        }
        return nil
    }

    private static func tail(of file: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        // Seek back to where the tail starts; a short file starts over at its beginning.
        try? handle.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
        return try? handle.read(upToCount: tailBytes)
    }

    /// The transcript's last answer, and whether a compaction came after it. The lines after the last
    /// assistant line decide: a boundary before it belongs to an earlier part of the conversation.
    static func parseTail(_ data: Data) -> Transcript {
        var transcript = Transcript.cold
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            switch object["type"] as? String {
            case "assistant":
                transcript.lastAssistantAt = timestamp(object["timestamp"]) ?? transcript.lastAssistantAt
                transcript.justCompacted = false
            case "system" where object["subtype"] as? String == "compact_boundary":
                transcript.justCompacted = true
            case "user" where (object["isCompactSummary"] as? Bool) == true:
                transcript.justCompacted = true
            default: break
            }
        }
        return transcript
    }

    private static func timestamp(_ any: Any?) -> Date? {
        guard let text = any as? String else { return nil }
        return Self.stampWithSeconds.date(from: text) ?? Self.stamp.date(from: text)
    }

    private static let stampWithSeconds: ISO8601DateFormatter = {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return stamp
    }()
    private static let stamp = ISO8601DateFormatter()

    // MARK: The wrapper script

    /// Where the wrapper T3 Code points at sits.
    static var wrapperPath: URL {
        (wrapperDirectory ?? LastDropPaths.support.appendingPathComponent("bin", isDirectory: true))
            .appendingPathComponent("claude-thread")
    }

    /// Tests keep the wrapper in a folder of their own.
    nonisolated(unsafe) static var wrapperDirectory: URL?

    /// Writes the wrapper T3 Code runs instead of claude, once its content differs: it hands T3's arguments
    /// to this app's launcher, which execs the real claude on the account it chose.
    static func writeWrapper(executable: String? = Bundle.main.executablePath) {
        guard let executable else { return }
        let script = "#!/bin/sh\nexec '\(executable.replacingOccurrences(of: "'", with: "'\\''"))' --claude-thread \"$@\"\n"
        LastDropPaths.ensure(wrapperPath.deletingLastPathComponent())
        guard (try? Data(contentsOf: wrapperPath)) != Data(script.utf8) else { return }
        guard (try? Data(script.utf8).write(to: wrapperPath, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperPath.path)
    }

    // MARK: Launching

    struct Plan {
        var args: [String]
        var environment: [String: String]
    }

    /// `Entry.main` hands the arguments after `--claude-thread` here, and never comes back. Whatever goes
    /// wrong before the exec, T3 still gets a working claude: the real one, run exactly as it asked.
    static func main(_ args: [String]) -> Never {
        guard let claude = realClaude() else {
            fputs("lastdrop: couldn't find the Claude Code executable to run.\n", stderr)
            exit(127)
        }
        if let plan = choose(args) {
            exec(claude, args: plan.args, environment: plan.environment)
        }
        exec(claude, args: args, environment: ProcessInfo.processInfo.environment)
    }

    /// Chooses the account and writes the ledger; nil runs claude exactly as T3 asked, untouched.
    private static func choose(_ args: [String]) -> Plan? {
        let parsed = parse(args)
        let ledger = Ledger.live
        let current = parsed.resume.map { ledger.currentSession($0) } ?? ""
        let transcript = current.isEmpty ? Transcript.cold : transcript(ofConversation: current)

        var candidates: [SubagentAccounts.Candidate] = []
        for account in ClaudeAccountsConfig.load().ordered {
            // An account nobody is signed in to can't run anything.
            guard ClaudeProvider.signedInAccount(configDir: account.cliConfigDir).uuid != nil else { continue }
            let usage = sync { await SubagentUsage.shared.usage(account) }
            candidates.append(.init(account: account, name: account.id, sessionUsed: usage.session, weeklyUsed: usage.weekly,
                                    size: PlanSize(plan: SubagentUsage.plan(account))))
        }
        // No account to run on (nobody is signed in anywhere): leave the choice to claude itself.
        guard !candidates.isEmpty else { return nil }
        let decision = decide(args, ledger: ledger, candidates: candidates, transcript: transcript, now: Date())
        for write in decision.writes {
            switch write {
            case .record(let session, let account, let forkedAt): SessionLedger.record(session: session, account: account, forkedAt: forkedAt)
            case .current(let session, let thread): SessionLedger.setCurrent(session, ofThread: thread)
            }
        }
        if !decision.session.isEmpty {
            SessionLedger.addLive(.init(pid: getpid(), account: decision.account, session: decision.session,
                                        thread: parsed.resume ?? decision.session, at: Date()))
        }
        SubagentLog.write("thread \(String((parsed.resume ?? decision.session).prefix(8))): \(decision.action.rawValue) on \(decision.account) (\(decision.reason))")
        return Plan(args: decision.args, environment: environment(for: decision.account))
    }

    /// The environment claude runs in: this process's, with `CLAUDE_CONFIG_DIR` naming the chosen account
    /// (gone for Main, which uses the default folder).
    private static func environment(for accountID: String, base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        if let dir = ClaudeAccount(id: accountID).cliConfigDir { environment["CLAUDE_CONFIG_DIR"] = dir }
        else { environment.removeValue(forKey: "CLAUDE_CONFIG_DIR") }
        return environment
    }

    /// The real claude: the native install, then PATH — but never this launcher again, which T3's
    /// `CLAUDE_CODE_EXECPATH` (its "Binary path") names. Without the hint nothing else resolves, there is
    /// nothing real to run.
    static func realClaude(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        func isSelf(_ path: String) -> Bool {
            if path == wrapperPath.path { return true }
            guard let own = Bundle.main.executablePath else { return false }
            let real = { (url: String) in URL(fileURLWithPath: url).resolvingSymlinksInPath().path }
            return real(path) == real(own)
        }
        if let found = SubagentRunner.executable(environment: environment), !isSelf(found) { return found }
        var withoutHint = environment
        withoutHint.removeValue(forKey: "CLAUDE_CODE_EXECPATH")
        return SubagentRunner.executable(environment: withoutHint).flatMap { isSelf($0) ? nil : $0 }
    }

    /// Blocks until the async body ends: the launcher must have chosen before it execs.
    private static func sync<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var value: T?
        Task.detached {
            value = await body()
            done.signal()
        }
        done.wait()
        return value!
    }

    /// The pid survives execve, so the app can still end the process between turns.
    private static func exec(_ claude: String, args: [String], environment: [String: String]) -> Never {
        let argv = ([claude] + args).map { strdup($0)! } + [nil]
        let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)")! } + [nil]
        execve(claude, argv, envp)
        fputs("lastdrop: couldn't run \(claude): \(String(cString: strerror(errno))).\n", stderr)
        exit(127)
    }
}
