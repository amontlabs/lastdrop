import Foundation

/// Errors that end a Claude Code turn but say nothing about the account: a Cloudflare page in front of Anthropic's
/// API, a 5xx, 529 overloaded, a dropped connection, or "Failed to authenticate" while the account's sign-in is
/// fine. On 2026-11-13 claude-2 answered "503 credential validation failed", then "403 Attention Required! |
/// Cloudflare", for about four minutes while its sign-in was valid; Claude Code retries 5xx itself but takes
/// a 403 as final, and two subagents died. A transient error is retried on the same session, then handed on
/// like a usage limit; only a real sign-in problem, a limit or another error is final.
enum TransientError {
    /// Why `text` (Claude Code's result, or what it wrote to stderr) is a passing error; nil when it isn't one.
    /// `status` is Claude Code's `api_error_status` when it reported one. `signInWorks` is asked only for an
    /// authentication failure without a Cloudflare page: then the account's own sign-in decides.
    static func reason(_ text: String, status: Int?, signInWorks: () -> Bool) -> String? {
        let t = text.lowercased()
        // Only signing in again fixes these, whatever else the text says.
        let signedOut = ["not logged in", "please run /login", "token has been revoked", "invalid_grant", "oauth token has expired"]
        if signedOut.contains(where: t.contains) { return nil }
        // An HTML page instead of JSON: Cloudflare's block or challenge in front of the API.
        let page = ["cloudflare", "attention required", "<html", "<!doctype html", "just a moment"]
        if page.contains(where: t.contains) { return "Cloudflare page instead of an API answer" }
        if status == 529 || t.contains("overloaded") || SubagentRunner.hasCode(529, in: text) { return "API overloaded (529)" }
        if let status, (500...599).contains(status) { return "API server error (\(status))" }
        let server = ["internal server error", "service unavailable", "bad gateway", "gateway timeout", "credential validation failed"]
        if t.range(of: #"api error:?\s*5\d\d"#, options: .regularExpression) != nil || server.contains(where: t.contains) {
            return "API server error"
        }
        let network = ["econnreset", "etimedout", "econnrefused", "enotfound", "eai_again", "epipe", "socket hang up", "network error",
                       "fetch failed", "connection error", "request timed out", "unable to connect", "und_err", "network is unreachable"]
        if network.contains(where: t.contains) { return "network error" }
        let auth = status == 401 || status == 403 || t.contains("failed to authenticate") || t.contains("authentication_failed")
        if auth, signInWorks() { return "authentication failed while the sign-in is valid" }
        return nil
    }

    /// The account's sign-in, as Claude Code keeps it, is one it can use: a token, and a sign-in that hasn't ended.
    static func signInWorks(_ account: ClaudeAccount, now: Date = .now) -> Bool {
        guard let facts = ClaudeProvider.storedCredentials(configDir: account.cliConfigDir).flatMap(ClaudeProvider.signInFacts(from:))
        else { return false }
        return facts.expiresAt != nil && ClaudeKeeper.judge(facts, now: now).state == .ok
    }
}

/// How long to wait before each retry after a transient error: 10 s, 30 s, 90 s, 3 min, each moved by up to a
/// fifth either way so parallel runs don't come back in step. Then the work is handed on.
struct RetryPolicy: Sendable, Equatable {
    var delays: [TimeInterval] = [10, 30, 90, 180]
    var jitter = 0.2

    static let standard = RetryPolicy()

    var retries: Int { delays.count }

    /// The wait before retry number `failures + 1`; nil when the retries are spent. `random` is in -1...1.
    func delay(after failures: Int, random: Double = .random(in: -1...1)) -> TimeInterval? {
        guard failures >= 0, failures < delays.count else { return nil }
        return max(0, delays[failures] * (1 + jitter * min(max(random, -1), 1)))
    }
}

/// A wait a stop can cut short: `lastdrop --agent-stop` sends the runner SIGUSR1 when it has no Claude Code
/// process to end, which ends the wait at once (the runner then sees the stop).
enum Nap {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var waiting: [UUID: CheckedContinuation<Void, Never>] = [:]
    nonisolated(unsafe) private static var source: DispatchSourceSignal?

    /// Listens for SIGUSR1; called once by the runner.
    static func wakeOnSignal() {
        lock.lock(); defer { lock.unlock() }
        guard source == nil else { return }
        signal(SIGUSR1, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .global(qos: .userInitiated))
        s.setEventHandler { wakeAll() }
        s.resume()
        source = s
    }

    static func wakeAll() {
        lock.lock()
        let all = waiting
        waiting = [:]
        lock.unlock()
        for continuation in all.values { continuation.resume() }
    }

    static func sleep(_ seconds: TimeInterval) async {
        let id = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            waiting[id] = continuation
            lock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
                lock.lock()
                let mine = waiting.removeValue(forKey: id)
                lock.unlock()
                mine?.resume()
            }
        }
    }
}
