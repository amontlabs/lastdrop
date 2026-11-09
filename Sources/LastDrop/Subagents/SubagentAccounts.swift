import Foundation

/// Which Claude account a subagent, or a T3 Code thread, runs on.
///
/// Subagents are short, and move on by themselves when an account runs out, so they spend the smallest
/// accounts first: a Pro's 5-hour window resets whether it was used or not. Never the calling session's
/// own account, only accounts below both thresholds.
///
/// Threads are long, and moving one costs a full re-read, so a thread starts on the account with the most
/// room, counted in Pro-sized windows (`PlanSize`), and never on an account's last points.
enum SubagentAccounts {
    struct Candidate: Equatable, Sendable {
        var account: ClaudeAccount
        var name: String
        var sessionUsed: Double?   // 0...100
        var weeklyUsed: Double?
        /// Subagents this server is running on it right now; spreads parallel calls over accounts.
        var active = 0
        var size = PlanSize()
    }

    /// Points of usage each subagent already running on an account is expected to take before it ends.
    static let reservedPerAgent = 10.0

    /// The subagent's account: the smallest plan with room, and among equal plans the one with the most
    /// room. Nil when none has room. Unknown usage counts as no room: an account whose limits can't be read
    /// can't be trusted not to be full. The subagents running on an account count against its room, so a
    /// burst of calls doesn't all land on one account's last few points.
    static func pick(_ candidates: [Candidate], sessionThreshold: Double, weeklyThreshold: Double) -> Candidate? {
        func room(_ c: Candidate) -> Double? {
            guard let s = c.sessionUsed, let w = c.weeklyUsed else { return nil }
            let r = min(sessionThreshold * 100 - s, weeklyThreshold * 100 - w) - Double(c.active) * reservedPerAgent
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
        return min(c.size.session * (100 - s), c.size.weekly * (100 - w)) / 100
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
            return s < threadSessionFloor && w < threadWeeklyFloor
        }
        return best(roomy) ?? best(candidates.filter { ($0.sessionUsed ?? 100) < 100 && ($0.weeklyUsed ?? 100) < 100 })
    }

    /// True while the account can still answer: below 100% of both windows.
    static func hasRoom(_ c: Candidate) -> Bool {
        guard let s = c.sessionUsed, let w = c.weeklyUsed else { return false }
        return s < 100 && w < 100
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
    private var cache: [String: (at: Date, sessionUsed: Double?, weeklyUsed: Double?)] = [:]

    struct Status: Codable, Equatable {
        var session: Double?
        var weekly: Double?
        var at: Date
        /// The plan's name ("Max 20x"), for `PlanSize`.
        var plan: String? = nil
    }

    /// The account's plan, as the app or a runner last read it.
    static func plan(_ account: ClaudeAccount) -> String? { readStatus()[account.id]?.plan }

    func usage(_ account: ClaudeAccount) async -> (session: Double?, weekly: Double?) {
        if AgentRegistry.isFull(account.id) { return (100, 100) }
        let saved = Self.readStatus()[account.id]
        if let saved, Date().timeIntervalSince(saved.at) < 360 { return (saved.session, saved.weekly) }
        if let hit = cache[account.id], Date().timeIntervalSince(hit.at) < 120 { return (hit.sessionUsed, hit.weeklyUsed) }
        var snapshot: UsageSnapshot?
        do {
            snapshot = try await ClaudeProvider(configDir: account.cliConfigDir).fetch()
        } catch ProviderError.unauthorized {
            snapshot = await ClaudeSignIn.renew(account)
            if snapshot == nil { SubagentLog.write("the \(account.id) sign-in couldn't be renewed") }
        } catch {
            SubagentLog.write("usage of \(account.id) unreadable: \(error.localizedDescription)")
            // Rate limited, say: an older reading beats none. A full account still answers "limit reached".
            if let saved, Date().timeIntervalSince(saved.at) < 30 * 60 { return (saved.session, saved.weekly) }
            snapshot = nil
        }
        func used(_ label: String) -> Double? { snapshot?.windows.first { $0.label == label }?.usedPercent }
        cache[account.id] = (Date(), used("Session"), used("Weekly"))
        // Shared with the next runners, which are other processes.
        if snapshot != nil {
            var status = Self.readStatus()
            status[account.id] = Status(session: used("Session"), weekly: used("Weekly"), at: Date(), plan: snapshot?.plan)
            Self.writeStatus(status)
        }
        return (used("Session"), used("Weekly"))
    }

    /// Full for the next ten minutes, for every runner.
    func markFull(_ account: ClaudeAccount) { AgentRegistry.markFull(account.id) }

    static func readStatus() -> [String: Status] {
        (try? Data(contentsOf: LastDropPaths.usage)).flatMap { try? JSONDecoder.lastdrop.decode([String: Status].self, from: $0) } ?? [:]
    }

    static func writeStatus(_ status: [String: Status]) {
        LastDropPaths.ensure(LastDropPaths.support)
        try? JSONEncoder.lastdrop.encode(status).write(to: LastDropPaths.usage, options: .atomic)
    }
}
