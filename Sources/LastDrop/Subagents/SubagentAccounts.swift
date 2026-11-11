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
    /// room. Nil when none has room. Unknown usage counts as no room: an account whose limits can't be read
    /// can't be trusted not to be full. The subagents running on an account count against its room, so a
    /// burst of calls doesn't all land on one account's last few points.
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
        return best?.0
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
    /// accounts below both floors; if none is, the most room among those not at a limit. Nil when every
    /// account is at a limit or unreadable.
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
        return best(roomy) ?? best(candidates.filter(hasRoom))
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

/// Usage per account: what the lastdrop app last read (it refreshes every few minutes), else read now from
/// the account's own Claude Code sign-in. An account that just answered "limit reached" counts as full.
actor SubagentUsage {
    static let shared = SubagentUsage()
    private var cache: [String: (at: Date, reading: Reading)] = [:]

    struct Status: Codable, Equatable {
        var session: Double?
        var weekly: Double?
        var at: Date
        /// Weekly limits scoped to a model, by its name ("Fable": 100).
        var models: [String: Double]? = nil
        /// The plan's name ("Max 20x"), for `PlanSize`.
        var plan: String? = nil
        /// Anthropic answered 429 for this account: no process asks again before this. Shared, so the app and
        /// every runner back off together.
        var blockedUntil: Date? = nil
        /// Rate-limit answers in a row; the wait grows with it. Cleared by the next successful read.
        var failures: Int? = nil
    }

    /// The app's own reading is fresh for this long; younger than that, a runner never asks Anthropic itself.
    static let appReadingFresh: TimeInterval = 15 * 60
    /// While an account can't be read, its last reading still routes for this long.
    static let readingKept: TimeInterval = 2 * 3600
    /// Longest wait after a rate limit.
    static let maxBackoff: TimeInterval = 30 * 60

    /// Tests point the shared status file elsewhere.
    nonisolated(unsafe) static var fileOverride: URL?

    /// The account's plan, as the app or a runner last read it.
    static func plan(_ account: ClaudeAccount) -> String? { readStatus()[account.id]?.plan }

    /// The plan's size for routing: from the sign-in's rate-limit tier ("Max 5x"), which says the size outright,
    /// else from the name the app shows.
    static func size(_ account: ClaudeAccount) -> PlanSize {
        let tier = ClaudeProvider.storedCredentials(configDir: account.cliConfigDir).flatMap(ClaudeProvider.credentials(from:))?.plan
        return PlanSize(plan: tier ?? plan(account))
    }

    /// One reading of an account's limits for routing.
    struct Reading: Equatable {
        var session: Double?
        var weekly: Double?
        var models: [String: Double] = [:]

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
            models[String(w.label.dropLast(" Weekly".count))] = w.usedPercent
        }
        return Reading(session: used("Session") ?? (weekly == nil ? nil : 0), weekly: weekly, models: models)
    }

    // MARK: Shared backoff

    /// When the account may be asked again; nil when it may be now.
    static func blockedUntil(_ id: String, now: Date = .now) -> Date? {
        guard let until = readStatus()[id]?.blockedUntil, until > now else { return nil }
        return until
    }

    /// Wait after the n-th rate limit in a row: 5, 10, 20, then 30 minutes.
    static func backoff(failures: Int) -> TimeInterval {
        min(300 * pow(2, Double(max(failures, 1) - 1)), maxBackoff)
    }

    /// Records a 429 for the account for every process: the server's Retry-After, else the growing backoff. An
    /// account already blocked keeps its block, so a burst of processes counts as one failure. Returns the end.
    @discardableResult
    static func recordBlock(_ id: String, retryAfter: TimeInterval?, now: Date = .now) -> Date {
        var all = readStatus()
        var entry = all[id] ?? Status(session: nil, weekly: nil, at: .distantPast)
        if let until = entry.blockedUntil, until > now { return until }
        let failures = (entry.failures ?? 0) + 1
        let wait = retryAfter.map { min(max($0, 60), 3600) } ?? backoff(failures: failures)
        let until = now.addingTimeInterval(wait)
        entry.failures = failures
        entry.blockedUntil = until
        all[id] = entry
        writeStatus(all)
        return until
    }

    /// A successful read ends the backoff.
    static func clearBlock(_ id: String) {
        var all = readStatus()
        guard all[id]?.blockedUntil != nil || all[id]?.failures != nil else { return }
        all[id]?.blockedUntil = nil
        all[id]?.failures = nil
        writeStatus(all)
    }

    /// The account's usage for routing. The app fetches and writes `usage.json`; a runner reads it, and asks
    /// Anthropic only when the app's reading is old (the app isn't running) and no process was told to back
    /// off. While the account can't be read, its last reading (up to two hours old) stands in.
    func usage(_ account: ClaudeAccount) async -> Reading {
        if AgentRegistry.isFull(account.id) { return Reading(session: 100, weekly: 100) }
        let saved = Self.readStatus()[account.id]
        let now = Date()
        func reading(_ s: Status) -> Reading {
            // Older entries have no models; a session left out next to a read week is a plan without one.
            Reading(session: s.session ?? (s.weekly == nil ? nil : 0), weekly: s.weekly, models: s.models ?? [:])
        }
        let kept: Reading? = saved.flatMap { now.timeIntervalSince($0.at) < Self.readingKept ? reading($0) : nil }
        if let saved, now.timeIntervalSince(saved.at) < Self.appReadingFresh { return reading(saved) }
        var provider = ClaudeProvider(configDir: account.cliConfigDir)
        provider.lean = true
        // Claude Code's own recent answer for the account costs no request, so it's read even while blocked.
        let cached = provider.cachedUsage(now: now)
        if cached == nil, Self.blockedUntil(account.id, now: now) != nil { return kept ?? Reading() }
        if let hit = cache[account.id], now.timeIntervalSince(hit.at) < 120 { return hit.reading }
        var snapshot: UsageSnapshot?
        do {
            snapshot = try await provider.fetch()
        } catch ProviderError.unauthorized {
            snapshot = await ClaudeSignIn.renew(account, lean: true)
            if snapshot == nil { SubagentLog.write("the \(account.id) sign-in couldn't be renewed") }
        } catch {
            SubagentLog.write("usage of \(account.id) unreadable: \(error.localizedDescription)")
            // Rate limited, say: an older reading beats none. A full account still answers "limit reached".
            if let kept { return kept }
            snapshot = nil
        }
        let result = snapshot.map { Self.reading($0.windows) } ?? Reading()
        cache[account.id] = (Date(), result)
        // Shared with the next runners, which are other processes.
        if let snapshot {
            // A copy of Claude Code's answer is as old as when Claude Code asked.
            Self.recordReading(account.id, session: result.session, weekly: result.weekly, models: result.models,
                               at: cached?.fetchedAt ?? Date(), credentialPlan: snapshot.plan)
        }
        return result
    }

    /// A runner's reading, for the next runners. The entry's backoff stays: a reading from Claude Code's copy
    /// doesn't end it, and one from Anthropic already did. A runner doesn't ask for the plan's name, so it keeps
    /// the one the app read, unless the sign-in says the plan changed.
    static func recordReading(_ id: String, session: Double?, weekly: Double?, models: [String: Double]? = nil, at: Date,
                              credentialPlan: String?) {
        var status = readStatus()
        var entry = status[id] ?? Status(session: nil, weekly: nil, at: at)
        entry.session = session
        entry.weekly = weekly
        entry.models = models
        entry.at = at
        entry.plan = ClaudeProvider.plan(shown: entry.plan, credentials: credentialPlan)
        status[id] = entry
        writeStatus(status)
    }

    /// Full for the next ten minutes, for every runner.
    func markFull(_ account: ClaudeAccount) { AgentRegistry.markFull(account.id) }

    static func readStatus() -> [String: Status] {
        (try? Data(contentsOf: fileOverride ?? LastDropPaths.usage)).flatMap { try? JSONDecoder.lastdrop.decode([String: Status].self, from: $0) } ?? [:]
    }

    static func writeStatus(_ status: [String: Status]) {
        LastDropPaths.ensure(LastDropPaths.support)
        try? JSONEncoder.lastdrop.encode(status).write(to: fileOverride ?? LastDropPaths.usage, options: .atomic)
    }
}
