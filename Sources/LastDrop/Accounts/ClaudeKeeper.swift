import Foundation
import Network
import Observation

/// Keeps every Claude account's sign-in renewed before it expires, Main included, so its usage can always be
/// read and routing never meets an account it can't judge.
///
/// lastdrop never asks Anthropic for tokens: Claude Code is the only OAuth client. Claude Code renews a token
/// with under 5 minutes left whenever it starts, so the keeper starts it with no prompt (`ClaudeSignIn.renew`)
/// 4 minutes before expiry, in the background. Accounts in use renew themselves; the keeper sees their expiry
/// move and does nothing. When only the user can help (the sign-in ended, or Claude Code cleared a dead one),
/// the account says so and routing skips it.
@MainActor @Observable
final class ClaudeKeeper {
    struct SignIn: Equatable {
        var state: SignInState = .ok
        /// Why it needs a sign-in, for the panel.
        var detail: String?
        var expiresAt: Date?
        /// When the sign-in itself ends; Claude Code can't renew it past this.
        var endsAt: Date?
        /// The plan in the sign-in ("Max 20x"), for sizing it without reading the keychain again.
        var plan: String?
        /// Claude Code can renew it: without a refresh token, starting it changes nothing.
        var hasRefreshToken = true
        var checkedAt: Date = .distantPast
        /// Renewals in a row that didn't move the expiry.
        var attempts = 0
        var nextAttempt: Date?
        var renewing = false
        /// Renewals kept failing while online, long after expiry: Claude Code can't renew it.
        var gaveUp = false

        /// The sign-in ends soon: worth signing in again before it does.
        func endsSoon(now: Date = .now) -> Bool {
            state == .ok && (endsAt.map { $0.timeIntervalSince(now) < ClaudeKeeper.warnBefore } ?? false)
        }
    }

    /// Renew this long before the token expires (Claude Code renews within 5 minutes of expiry).
    nonisolated static let renewAhead: TimeInterval = 4 * 60
    /// Read each blob at least this often: sessions renew sign-ins too, and the expiry moves by itself.
    nonisolated static let recheckEvery: TimeInterval = 5 * 60
    /// Waits between renewals that failed after expiry: 1, 2, 5, then every 15 minutes.
    nonisolated static let retryDelays: [TimeInterval] = [60, 120, 300, 900]
    /// Say so this long before a sign-in ends.
    nonisolated static let warnBefore: TimeInterval = 3 * 86400
    /// Failing renewals, online, this long past expiry: the user has to sign in.
    nonisolated static let giveUpAfter: TimeInterval = 30 * 60

    /// By `ClaudeAccount.id`.
    private(set) var signIns: [String: SignIn] = [:]
    /// A renewal moved the expiry: the account's usage can be read again right away.
    @ObservationIgnored var onRenewed: ((ClaudeAccount) -> Void)?
    @ObservationIgnored private var online = true
    /// Accounts whose blob is being read right now: a second tick (the panel opening, a wake) waits its turn.
    @ObservationIgnored private var checking: Set<String> = []
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.online = up }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    /// Screenshots only: a made-up sign-in.
    func preview(_ id: String, _ signIn: SignIn) { signIns[id] = signIn }

    /// Read the blobs again on the next tick (after a wake, a 401, or a sign-in).
    func recheck(_ id: String? = nil) {
        for key in signIns.keys where id == nil || key == id { signIns[key]?.checkedAt = .distantPast }
    }

    /// Every app tick (15 s). Reads a blob only when one is due, and starts at most one renewal per account.
    func tick(_ accounts: [ClaudeAccount], now: Date = .now) async {
        for account in accounts { await check(account, now: now) }
        let ids = Set(accounts.map(\.id))
        for key in signIns.keys where !ids.contains(key) { signIns[key] = nil }
    }

    private func check(_ account: ClaudeAccount, now: Date) async {
        guard !checking.contains(account.id), !(signIns[account.id]?.renewing ?? false),
              Self.isDue(signIns[account.id] ?? SignIn(), now: now) else { return }
        checking.insert(account.id)
        defer { checking.remove(account.id) }
        let dir = account.cliConfigDir
        let facts = await Task.detached { ClaudeProvider.storedCredentials(configDir: dir).flatMap(ClaudeProvider.signInFacts(from:)) }.value
        // Read after the wait: a renewal may have finished meanwhile.
        var entry = signIns[account.id] ?? SignIn()
        guard !entry.renewing else { return }
        let previous = entry.expiresAt
        entry.checkedAt = now
        entry.expiresAt = facts?.expiresAt
        entry.endsAt = facts?.endsAt
        entry.plan = facts?.plan
        entry.hasRefreshToken = facts?.hasRefreshToken ?? false
        // Moved by someone else (a session on the account, or a sign-in): nothing left to retry.
        if let moved = facts?.expiresAt, moved != previous, moved > now {
            entry.attempts = 0
            entry.nextAttempt = nil
            entry.gaveUp = false
        }
        let judged = Self.judge(facts, now: now)
        let wasUsable = signIns[account.id]?.state.isUsable ?? true
        entry.state = judged.state
        entry.detail = judged.detail
        if judged.state == .ok, entry.gaveUp {
            entry.state = .needsSignIn
            entry.detail = "Claude Code couldn't renew its sign-in."
        }
        if entry.state.isUsable, online, Self.renewDue(entry, now: now) {
            entry.renewing = true
            signIns[account.id] = entry
            Task { [weak self] in
                let renewed = await ClaudeSignIn.renew(account)
                self?.finished(account, renewed: renewed)
            }
            return
        }
        if wasUsable && !entry.state.isUsable {
            SubagentLog.write("the \(account.id) sign-in needs you: \(entry.detail ?? entry.state.rawValue)")
        }
        signIns[account.id] = entry
    }

    private func finished(_ account: ClaudeAccount, renewed: Bool, now: Date = .now) {
        guard var entry = signIns[account.id] else { return }
        entry.renewing = false
        entry.checkedAt = .distantPast   // read the blob again on the next tick
        if renewed {
            entry.attempts = 0
            entry.nextAttempt = nil
            entry.gaveUp = false
        } else {
            entry.attempts += 1
            entry.nextAttempt = Self.nextAttempt(after: entry.attempts, expiresAt: entry.expiresAt, now: now)
            if entry.attempts >= 3, online, now.timeIntervalSince(entry.expiresAt ?? .distantPast) > Self.giveUpAfter {
                entry.gaveUp = true
            }
        }
        signIns[account.id] = entry
        if renewed { onRenewed?(account) }
    }

    // MARK: Rules (pure)

    /// The blob is due a read: the periodic one, the renewal deadline, or a retry.
    nonisolated static func isDue(_ entry: SignIn, now: Date) -> Bool {
        if now.timeIntervalSince(entry.checkedAt) >= recheckEvery { return true }
        if let next = entry.nextAttempt { return now >= next }
        if let expiry = entry.expiresAt { return now >= expiry.addingTimeInterval(-renewAhead) }
        return false
    }

    /// Time to start Claude Code on it: within `renewAhead` of expiry (or past it), once any wait is over.
    /// No token at all, but a refresh token: due at once.
    nonisolated static func renewDue(_ entry: SignIn, now: Date) -> Bool {
        guard entry.hasRefreshToken else { return false }
        if let expiry = entry.expiresAt, now < expiry.addingTimeInterval(-renewAhead) { return false }
        return entry.nextAttempt.map { now >= $0 } ?? true
    }

    /// After a renewal that didn't take: again just past expiry if it hasn't come yet (the path Claude Code
    /// always takes), then 1, 2, 5 and every 15 minutes.
    nonisolated static func nextAttempt(after attempts: Int, expiresAt: Date?, now: Date) -> Date {
        if let expiry = expiresAt, now < expiry { return expiry.addingTimeInterval(5) }
        return now.addingTimeInterval(retryDelays[min(max(attempts - 2, 0), retryDelays.count - 1)])
    }

    /// What the blob alone says. Claude Code clears a sign-in Anthropic refused (`invalid_grant`) to empty
    /// tokens, with `loginEnded: "time_limit"` when it ran out.
    nonisolated static func judge(_ facts: ClaudeProvider.SignInFacts?, now: Date) -> (state: SignInState, detail: String?) {
        guard let facts else { return (.signedOut, "Not signed in to Claude Code.") }
        if !facts.hasRefreshToken {
            // A token that can't be renewed still works until it expires.
            if let expiry = facts.expiresAt, expiry > now { return (.ok, nil) }
            return (.needsSignIn, facts.loginEnded == "time_limit" ? "Its sign-in ran out." : "Its sign-in stopped working.")
        }
        if let ends = facts.endsAt, ends <= now {
            return (.needsSignIn, "Its sign-in ran out on \(ends.formatted(.dateTime.day().month(.abbreviated))).")
        }
        return (.ok, nil)
    }
}
