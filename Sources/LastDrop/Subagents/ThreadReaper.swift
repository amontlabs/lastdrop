import Foundation
import UserNotifications

/// Watches running T3 Code threads and ends any whose Claude account has reached its usage limit.
/// T3 Code handles an exit between turns cleanly, and the next message in that thread continues on another account.
enum ThreadReaper {
    /// Overridden in tests to point to a test folder instead of ~/.claude/projects.
    nonisolated(unsafe) static var projectsDirOverride: URL?

    /// True when the LAST line of type "user" or "assistant" in a transcript tail is a limit notice:
    /// `isApiErrorMessage == true` or `message.model == "<synthetic>"`, and its text content mentions "limit" (case-insensitive).
    static func isLimitNotice(tail: Data) -> Bool { limit(tail: tail) == .account }

    enum Limit: Equatable { case none, account, model }

    /// `.account` for a limit on the whole account (session, weekly, usage), `.model` for one on a single model
    /// ("You've hit your Opus limit"), which says nothing about the account's room for the others.
    static func limit(tail: Data) -> Limit {
        let lines = tail.split(separator: 0x0A, omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = event.string("type"),
                  ["user", "assistant"].contains(type) else { continue }

            let isApiError = event["isApiErrorMessage"] as? Bool == true
            let isSynthetic = event.dict("message")?.string("model") == "<synthetic>"
            guard isApiError || isSynthetic else { return .none }

            // A usage limit ("You've hit your session limit", "Claude AI usage limit reached"), not a passing
            // rate limit (429), which Claude Code retries and which says nothing about the account's room.
            let text = extractText(from: event)
            guard text.range(of: #"hit your .*limit|usage limit|limit reached|(session|weekly|opus|sonnet|haiku|fable) limit"#, options: [.regularExpression, .caseInsensitive]) != nil
            else { return .none }
            let wholeAccount = text.range(of: #"session limit|usage limit|weekly limit"#, options: [.regularExpression, .caseInsensitive]) != nil
            let aModel = text.range(of: #"opus|sonnet|haiku|fable"#, options: [.regularExpression, .caseInsensitive]) != nil
            return aModel && !wholeAccount ? .model : .account
        }
        return .none
    }

    /// Extracts plain text from the message content of an event.
    private static func extractText(from event: [String: Any]) -> String {
        guard let message = event.dict("message") else { return "" }
        if let contentString = message["content"] as? String {
            return contentString
        }
        if let blocks = message.array("content") {
            return blocks.compactMap { $0.string("text") }.joined(separator: "\n")
        }
        return ""
    }

    /// Checks live T3 Code processes in the ledger, terminating any that finished a turn with a limit notice.
    static func check() {
        let liveEntries = SessionLedger.live()
        guard !liveEntries.isEmpty else { return }

        let fm = FileManager.default
        let projectsURL = projectsDirOverride ?? URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects")

        for entry in liveEntries {
            guard let transcriptURL = findTranscript(sessionID: entry.session, in: projectsURL) else { continue }
            guard let attrs = try? fm.attributesOfItem(atPath: transcriptURL.path),
                  let modifiedAt = attrs[.modificationDate] as? Date,
                  modifiedAt > entry.at else { continue }

            guard let tail = readTail(of: transcriptURL, maxLength: 256 * 1024) else { continue }
            let kind = limit(tail: tail)
            if kind == .model {
                // One model is out, not the account: the process and the account stay as they are.
                SubagentLog.write("reaper: thread process \(entry.pid) (session \(entry.session)) on \(entry.account) hit a model-specific limit; leaving it")
                continue
            }
            guard kind == .account else { continue }
            // The pid may have been reused by another process since: only the one the launcher started is signalled.
            guard SessionLedger.isSameProcess(entry) else {
                SubagentLog.write("reaper: pid \(entry.pid) is no longer the thread process of session \(entry.session); not signalling it")
                SessionLedger.removeLive(pid: entry.pid)
                continue
            }

            SubagentLog.write("reaper: thread process \(entry.pid) (session \(entry.session)) on \(entry.account) hit usage limit; ending process")
            AgentRegistry.markFull(entry.account)
            kill(entry.pid, SIGTERM)
            SessionLedger.removeLive(pid: entry.pid)

            notify(account: entry.account)
        }
    }

    /// Reads up to `maxLength` bytes from the end of a file.
    private static func readTail(of url: URL, maxLength: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        let offset = size > UInt64(maxLength) ? size - UInt64(maxLength) : 0
        handle.seek(toFileOffset: offset)
        return handle.readDataToEndOfFile()
    }

    /// Finds ~/.claude/projects/*/<session>.jsonl.
    private static func findTranscript(sessionID: String, in projectsURL: URL) -> URL? {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(atPath: projectsURL.path) else { return nil }
        for project in projects {
            let candidate = projectsURL.appendingPathComponent("\(project)/\(sessionID).jsonl")
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Shows a macOS notification that the account is full and the thread will continue on another account.
    private static func notify(account: String) {
        let title = "\(account) is at its usage limit"
        let body = "Your next message in that T3 Code thread continues on another Claude account."
        // Only the app can post: `swift run` and the test runner have no bundle to post from.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: "limit-\(account)-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
