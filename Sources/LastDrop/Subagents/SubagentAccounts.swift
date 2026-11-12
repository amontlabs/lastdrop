import Foundation

/// Which Claude account a subagent, or a T3 Code thread, runs on.
///
/// Subagents are short, and move on by themselves when an account runs out, so they spend the smallest
/// accounts first: a Pro's 5-hour window resets whether it was used or not. The calling session's own account
/// is a candidate like any other, minus a reserve that keeps the session itself from running out. Only accounts
/// below both thresholds, and below the weekly threshold of the run's model (Fable Weekly), take one.
///
/// Threads are long, and moving one costs a full re-read, so a thread starts on the account with the most
/// room, counted in Pro-sized windows (`PlanSize`), and never on an account's last points.
enum SubagentAccounts {
    struct Candidate: Equatable, Sendable {
        var account: ClaudeAccount
        var name: String
        var sessionUsed: Double?   // 0...100
        var weeklyUsed: Double?
        /// The weekly limit scoped to the run's model ("Fable Weekly"), when the account has one.
        var modelUsed: Double? = nil
        /// The calling session runs on it: subagents leave it `ownReserve` points.
        var isOwn = false
        /// Subagents this server is running on it right now; spreads parallel calls over accounts.
        var active = 0
        var size = PlanSize()
    }

    /// Points of usage each subagent already running on an account is expected to take before it ends.
    static let reservedPerAgent = 10.0
    /// Points of the calling session's own account kept for the session itself.
    static let ownReserve = 20.0

    /// The subagent's account: the smallest plan with room, and among equal plans the one with the most
    /// room. The subagents running on an account count against its room, so a burst of calls doesn't all land
    /// on one account's last few points. When no account is known to have room, one whose usage is unknown
    /// (another than the session's own first) is tried: it refuses quickly if it's full, while one known to be
    /// full surely fails. With the app running, no account stays unknown for long (`ClaudeKeeper`).
    static func pick(_ candidates: [Candidate], sessionThreshold: Double, weeklyThreshold: Double) -> Candidate? {
        func room(_ c: Candidate) -> Double? {
            guard let s = c.sessionUsed, let w = c.weeklyUsed else { return nil }
            var r = min(sessionThreshold * 100 - s, weeklyThreshold * 100 - w)
            if let m = c.modelUsed { r = min(r, weeklyThreshold * 100 - m) }
            r -= Double(c.active) * reservedPerAgent + (c.isOwn ? ownReserve : 0)
            return r > 0 ? r : nil
        }
        var best: (Candidate, Double)?
        for c in candidates {
            guard let r = room(c) else { continue }
            guard let (b, br) = best else { best = (c, r); continue }
            // Ties keep the earlier one in the order.
            if c.size.session < b.size.session || (c.size.session == b.size.session && r > br) { best = (c, r) }
        }
        return best?.0 ?? unknown(candidates)
    }

    /// The last resort: an account nothing is known about, another than the session's own first.
    static func unknown(_ candidates: [Candidate]) -> Candidate? {
        let unknown = candidates.filter { $0.sessionUsed == nil || $0.weeklyUsed == nil }
        return unknown.first { !$0.isOwn } ?? unknown.first
    }

    /// A thread starts on an account only while it has used less than this much of its 5-hour window (percent)...
    static let threadSessionFloor = 80.0
    /// ...and of its week.
    static let threadWeeklyFloor = 95.0

    /// Room in Pro-sized windows: what's left of the 5-hour window and of the week, times the plan's size,
    /// whichever is tighter. Nil when unknown.
    static func threadRoom(_ c: Candidate) -> Double? {
        guard let s = c.sessionUsed, let w = c.weeklyUsed else { return nil }
        var room = min(c.size.session * (100 - s), c.size.weekly * (100 - w))
        if let m = c.modelUsed { room = min(room, c.size.weekly * (100 - m)) }
        return room / 100
    }

    /// The account a T3 Code thread starts on, or moves to when moving costs nothing: the most room among the
    /// accounts below both floors; if none is, the most room among those not at a limit; if none is, one whose
    /// usage is unknown. Nil when every account is at a limit.
    static func pickForThread(_ candidates: [Candidate]) -> Candidate? {
        func best(_ list: [Candidate]) -> Candidate? {
            var best: (Candidate, Double)?
            for c in list {
                guard let r = threadRoom(c), r > 0 else { continue }
                if best == nil || r > best!.1 { best = (c, r) }
            }
            return best?.0
        }
        let roomy = candidates.filter {
            guard let s = $0.sessionUsed, let w = $0.weeklyUsed else { return false }
            return s < threadSessionFloor && w < threadWeeklyFloor && ($0.modelUsed ?? 0) < threadWeeklyFloor
        }
        return best(roomy) ?? best(candidates.filter(hasRoom)) ?? unknown(candidates)
    }

    /// True while the account can still answer: below 100% of both windows.
    static func hasRoom(_ c: Candidate) -> Bool {
        guard let s = c.sessionUsed, let w = c.weeklyUsed else { return false }
        return s < 100 && w < 100 && (c.modelUsed ?? 0) < 100
    }

    /// The account the calling session runs as: the Claude app passes it to its Code-tab sessions; a
    /// terminal session is the one its config folder is signed in to.
    static func ownAccountUUID(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        // The folder a run is signed in at wins: a T3 thread on another account carries the Claude app's UUID too.
        if let dir = environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"], !dir.isEmpty,
           let uuid = ClaudeProvider.signedInAccount(configDir: (dir as NSString).expandingTildeInPath).uuid { return uuid }
        if let uuid = environment["CLAUDE_CODE_ACCOUNT_UUID"], !uuid.isEmpty { return uuid }
        let dir = environment["CLAUDE_CONFIG_DIR"].map { ($0 as NSString).expandingTildeInPath }
        return ClaudeProvider.signedInAccount(configDir: dir).uuid
    }
}

/// Where a Claude account's sign-in stands, as the app's keeper (`ClaudeKeeper`) last judged it.
enum SignInState: String, Codable, Sendable {
    case ok
    /// The sign-in ended or stopped working: only signing in again brings it back.
    case needsSignIn
    /// Nothing is signed in on this account's folder.
    case signedOut

    /// Can run work, as far as the sign-in goes.
    var isUsable: Bool { self == .ok }
}

/// Usage per account, as the lastdrop app keeps it in `usage.json`. The app is the one reader of Anthropic
/// and the one keeper of sign-ins (`ClaudeKeeper`): a runner only reads the file, so picking an account costs a
/// file read. Only while the app isn't running does a runner read an account itself, briefly and never renewing.
actor SubagentUsage {
    static let shared = SubagentUsage()

    struct Status: Codable, Equatable {
        var session: Double?
        var weekly: Double?
        var at: Date
        /// Weekly limits scoped to a model, by its name ("Fable": 100).
        var models: [String: Double]? = nil
        /// The plan's name ("Max 20x"), for `PlanSize`.
        var plan: String? = nil
        /// Anthropic answered 429 for this account: nobody asks again before this.
        var blockedUntil: Date? = nil
        /// Rate-limit answers in a row; the wait grows with it. Cleared by the next successful read.
        var failures: Int? = nil
        /// When each window resets, by its row's name ("Session", "Weekly", "Fable"): past it, the window counts
        /// as unused, so an old reading stays right.
        var resetsAt: [String: Date]? = nil
        /// The sign-in, as the app last judged it; nil (older files, or not judged yet) counts as fine.
        var signIn: SignInState? = nil
        /// Why it needs a sign-in, for the panel.
        var signInDetail: String? = nil
        /// When the sign-in itself ends (Claude Code's `refreshTokenExpiresAt`).
        var signInEndsAt: Date? = nil
    }

    /// A reading routes for this long. With the app running it is never this old: the app reads every account
    /// every few minutes and renews sign-ins before they expire, and resets are projected.
    static let readingValid: TimeInterval = 2 * 3600
    /// The app counts as running while its heartbeat is younger than this.
    static let heartbeatFresh: TimeInterval = 60
    /// Without the app, a runner reads an account itself once its reading is older than this...
    static let runnerReadAfter: TimeInterval = 5 * 60
    /// ...taking at most this long.
    static let runnerReadDeadline: TimeInterval = 3
    /// Longest wait after a rate limit.
    static let maxBackoff: TimeInterval = 30 * 60

    /// Tests point the shared status file elsewhere.
    nonisolated(unsafe) static var fileOverride: URL?
    /// Tests say whether the app is running.
    nonisolated(unsafe) static var appRunningOverride: Bool?

    /// The account's plan, as the app or a runner last read it.
    static func plan(_ account: ClaudeAccount) -> String? { readStatus()[account.id]?.plan }

    /// The plan's size for routing: the plan Anthropic's profile names, as the app saved it; the sign-in's only
    /// before the app read one, since Claude Code never updates it after an upgrade.
    static func size(_ account: ClaudeAccount) -> PlanSize {
        if let saved = plan(account) { return PlanSize(plan: saved) }
        return PlanSize(plan: ClaudeProvider.storedCredentials(configDir: account.cliConfigDir).flatMap(ClaudeProvider.credentials(from:))?.plan)
    }

    /// One reading of an account's limits for routing.
    struct Reading: Equatable {
        var session: Double?
        var weekly: Double?
        var models: [String: Double] = [:]
        /// False when only signing in again would let it run anything.
        var usable = true

        /// Nothing is known about its limits.
        var isUnknown: Bool { session == nil || weekly == nil }

        /// The weekly limit scoped to `model` ("claude-fable-5-2", "fable"), if the account has one.
        func used(model: String?) -> Double? {
            guard let model = model?.lowercased(), !model.isEmpty else { return nil }
            return models.first { name, _ in
                let word = name.lowercased().split(separator: " ").first.map(String.init) ?? ""
                return !word.isEmpty && model.contains(word)
            }?.value
        }
    }

    /// Routing values from a reading's rows. A plan without a 5-hour window (Ultra) has nothing to run out of
    /// there: once the week is read, its session counts as unused, not unknown.
    static func reading(_ windows: [UsageWindow]) -> Reading {
        func used(_ label: String) -> Double? { windows.first { $0.label == label }?.usedPercent }
        let weekly = used("Weekly")
        var models: [String: Double] = [:]
        for w in windows where w.label != "Weekly" && w.label.hasSuffix(" Weekly") {
            models[modelName(w.label)] = w.usedPercent
        }
        return Reading(session: used("Session") ?? (weekly == nil ? nil : 0), weekly: weekly, models: models)
    }

    /// "Fable Weekly" → "Fable".
    static func modelName(_ label: String) -> String { String(label.dropLast(" Weekly".count)) }

    /// When each window of a reading resets, by the names `Status.resetsAt` uses.
    static func resets(_ windows: [UsageWindow]) -> [String: Date] {
        var resets: [String: Date] = [:]
        for w in windows {
            guard let at = w.resetsAt else { continue }
            let name = w.label == "Session" || w.label == "Weekly" ? w.label : w.label.hasSuffix(" Weekly") ? modelName(w.label) : nil
            if let name { resets[name] = at }
        }
        return resets
    }

    /// The account's reading for routing at `now`: nil (unknown) when older than `readingValid`. A window past
    /// its reset counts as unused.
    static func reading(_ s: Status, now: Date = .now) -> Reading {
        var reading = Reading(usable: s.signIn?.isUsable ?? true)
        guard now.timeIntervalSince(s.at) < readingValid else { return reading }
        func projected(_ name: String, _ used: Double?) -> Double? {
            guard let used else { return nil }
            if let reset = s.resetsAt?[name], reset <= now { return 0 }
            return used
        }
        reading.weekly = projected("Weekly", s.weekly)
        // Older entries have no models; a session left out next to a read week is a plan without one.
        reading.session = projected("Session", s.session ?? (s.weekly == nil ? nil : 0))
        for (name, used) in s.models ?? [:] { reading.models[name] = projected(name, used) }
        return reading
    }

    /// The account's usage for routing: the app's reading, with resets projected. An account that just answered
    /// "limit reached" counts as full until a reading newer than that says otherwise. Without the app, an account
    /// read over 5 minutes ago is read here once, within 3 s.
    func usage(_ account: ClaudeAccount, now: Date = .now) async -> Reading {
        var saved = Self.readStatus()[account.id]
        if !Self.appIsRunning(now: now) {
            // The app judged the sign-in; while it's closed you may have signed in again in Terminal.
            if saved?.signIn?.isUsable == false {
                let facts = ClaudeProvider.storedCredentials(configDir: account.cliConfigDir).flatMap(ClaudeProvider.signInFacts(from:))
                let judged = ClaudeKeeper.judge(facts, now: now)
                if judged.state.isUsable { Self.update { $0[account.id]?.signIn = .ok; $0[account.id]?.signInDetail = nil } }
                saved = Self.readStatus()[account.id]
            }
            if saved?.signIn?.isUsable != false, now.timeIntervalSince(saved?.at ?? .distantPast) >= Self.runnerReadAfter {
                await Self.readItself(account, savedAt: saved?.at)
                saved = Self.readStatus()[account.id]
            }
        }
        var reading = saved.map { Self.reading($0, now: now) } ?? Reading()
        if let full = AgentRegistry.fullSince(account.id), (saved?.at ?? .distantPast) < full {
            reading.session = 100; reading.weekly = 100
        }
        return reading
    }

    /// The app wrote its heartbeat within the last minute.
    static func appIsRunning(now: Date = .now) -> Bool {
        if let appRunningOverride { return appRunningOverride }
        let attributes = try? FileManager.default.attributesOfItem(atPath: LastDropPaths.appHeartbeat.path)
        guard let touched = attributes?[.modificationDate] as? Date else { return false }
        return now.timeIntervalSince(touched) < heartbeatFresh
    }

    /// The app's part, done by a runner while the app isn't running: one read of the account (Claude Code's copy,
    /// else Anthropic, honouring the shared backoff), at most `runnerReadDeadline` long, saved for the next runner.
    /// A sign-in is never renewed here: that takes a Claude Code start, the app's job.
    private static func readItself(_ account: ClaudeAccount, savedAt: Date?) async {
        var reader = ClaudeProvider(configDir: account.cliConfigDir)
        reader.lean = true
        var cached = reader.cachedUsage()
        // Claude Code's copy is older than what's saved: it would change nothing, so ask Anthropic.
        if let copy = cached, copy.fetchedAt <= (savedAt ?? .distantPast) {
            reader.fresh = true
            cached = nil
        }
        let provider = reader
        let snapshot = await withDeadline(runnerReadDeadline) { try await provider.fetch() }
        guard let snapshot else { return }
        SubagentLog.write("\(account.id): the app isn't running, read by this runner")
        let at = cached?.fetchedAt ?? Date()
        update { status in
            var entry = status[account.id] ?? Status(session: nil, weekly: nil, at: at)
            guard entry.at <= at else { return }   // someone saved a newer one meanwhile
            let reading = reading(snapshot.windows)
            entry.session = reading.session
            entry.weekly = reading.weekly
            entry.models = reading.models
            entry.resetsAt = resets(snapshot.windows)
            entry.at = at
            entry.plan = ClaudeProvider.plan(shown: entry.plan, credentials: snapshot.plan)
            status[account.id] = entry
        }
    }

    /// The value, or nil when it threw or took longer than `seconds`.
    static func withDeadline<T: Sendable>(_ seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { try? await body() }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Full for the next ten minutes, for every runner, or until the app reads it again.
    func markFull(_ account: ClaudeAccount) { AgentRegistry.markFull(account.id) }

    // MARK: Shared backoff

    /// Wait after the n-th rate limit in a row: 5, 10, 20, then 30 minutes.
    static func backoff(failures: Int) -> TimeInterval {
        min(300 * pow(2, Double(max(failures, 1) - 1)), maxBackoff)
    }

    /// When the account may be asked again; nil when it may be now.
    static func blockedUntil(_ id: String, now: Date = .now) -> Date? {
        guard let until = readStatus()[id]?.blockedUntil, until > now else { return nil }
        return until
    }

    /// Records a 429 for the account: the server's Retry-After, else the growing backoff. An account already
    /// blocked keeps its block, so a burst of requests counts as one failure. Returns the end.
    @discardableResult
    static func recordBlock(_ id: String, retryAfter: TimeInterval?, now: Date = .now) -> Date {
        update { all in
            var entry = all[id] ?? Status(session: nil, weekly: nil, at: .distantPast)
            if let until = entry.blockedUntil, until > now { return until }
            let failures = (entry.failures ?? 0) + 1
            let wait = retryAfter.map { min(max($0, 60), 3600) } ?? backoff(failures: failures)
            let until = now.addingTimeInterval(wait)
            entry.failures = failures
            entry.blockedUntil = until
            all[id] = entry
            return until
        }
    }

    /// A successful read ends the backoff.
    static func clearBlock(_ id: String) {
        guard readStatus()[id].map({ $0.blockedUntil != nil || $0.failures != nil }) == true else { return }
        update { all in
            all[id]?.blockedUntil = nil
            all[id]?.failures = nil
        }
    }

    // MARK: The file

    static var fileURL: URL { fileOverride ?? LastDropPaths.usage }

    /// The whole file. Never blocks: writers replace it by rename, so a reader sees a whole old or new file.
    static func readStatus() -> [String: Status] {
        (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder.lastdrop.decode([String: Status].self, from: $0) } ?? [:]
    }

    /// A read-modify-write under `usage.lock`, so the app and runners never undo each other's writes.
    @discardableResult
    static func update<T>(_ body: (inout [String: Status]) -> T) -> T {
        LastDropPaths.ensure(fileURL.deletingLastPathComponent())
        let lockPath = fileOverride.map { $0.path + ".lock" } ?? LastDropPaths.usageLock.path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        var status = readStatus()
        let before = status
        let value = body(&status)
        if status != before { writeStatus(status) }
        return value
    }

    /// Replaces the file. Callers outside `update` are tests.
    static func writeStatus(_ status: [String: Status]) {
        LastDropPaths.ensure(fileURL.deletingLastPathComponent())
        try? JSONEncoder.lastdrop.encode(status).write(to: fileURL, options: .atomic)
    }
}
