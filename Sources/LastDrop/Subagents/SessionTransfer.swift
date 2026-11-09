import Foundation

/// Finds a Claude Code session's transcript in `~/.claude/projects`, where every run now keeps its sessions, and
/// brings one over from an account's own folder when an agent started before that left it there.
enum SessionTransfer {
    static func projectsDir(_ account: ClaudeAccount) -> URL {
        URL(fileURLWithPath: account.cliConfigDir ?? NSHomeDirectory() + "/.claude").appendingPathComponent("projects")
    }

    static var mainProjects: URL { URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects") }

    /// The session's transcript under `projects`, whatever the project folder.
    static func transcript(_ sessionID: String, in projects: URL) -> URL? {
        let fm = FileManager.default
        guard !sessionID.isEmpty, let project = (try? fm.contentsOfDirectory(atPath: projects.path))?.first(where: {
            fm.fileExists(atPath: projects.appendingPathComponent("\($0)/\(sessionID).jsonl").path)
        }) else { return nil }
        return projects.appendingPathComponent("\(project)/\(sessionID).jsonl")
    }

    /// The session's transcript in `~/.claude/projects`; one only in the old account's own folder is copied
    /// there first (with its side folder). Nil when neither has it.
    static func transcriptInMain(_ sessionID: String, from old: ClaudeAccount, main: URL = mainProjects, oldProjects: URL? = nil) -> URL? {
        if let found = transcript(sessionID, in: main) { return found }
        guard copy(sessionID, from: oldProjects ?? projectsDir(old), to: main) else { return nil }
        return transcript(sessionID, in: main)
    }

    /// True once the transcript, and its side files when it has any, are in `to`'s folder for the same project.
    static func copy(_ sessionID: String, from: ClaudeAccount, to: ClaudeAccount) -> Bool {
        copy(sessionID, from: projectsDir(from), to: projectsDir(to))
    }

    static func copy(_ sessionID: String, from source: URL, to target: URL) -> Bool {
        let fm = FileManager.default
        guard !sessionID.isEmpty, source.resolvingSymlinksInPath() != target.resolvingSymlinksInPath(),
              let project = (try? fm.contentsOfDirectory(atPath: source.path))?.first(where: {
                  fm.fileExists(atPath: source.appendingPathComponent("\($0)/\(sessionID).jsonl").path)
              }),
              let data = try? Data(contentsOf: source.appendingPathComponent("\(project)/\(sessionID).jsonl")) else { return false }
        let from = source.appendingPathComponent(project), to = target.appendingPathComponent(project)
        try? fm.createDirectory(at: to, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard (try? withoutTrailingNotices(data).write(to: to.appendingPathComponent("\(sessionID).jsonl"), options: .atomic)) != nil
        else { return false }
        // Long tool results kept apart and the agent's own subagents, which the transcript points to.
        let side = from.appendingPathComponent(sessionID)
        if fm.fileExists(atPath: side.path) {
            let copy = to.appendingPathComponent(sessionID)
            try? fm.removeItem(at: copy)
            try? fm.copyItem(at: side, to: copy)
        }
        return true
    }

    /// The transcript without the notices Claude Code wrote after the account's last answer ("You've hit your
    /// session limit"): resumed elsewhere, the agent carries on from its last real step and never reads them.
    static func withoutTrailingNotices(_ data: Data) -> Data {
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        var i = lines.count - 1
        while i >= 0 {
            defer { i -= 1 }
            guard let event = (try? JSONSerialization.jsonObject(with: Data(lines[i]))) as? [String: Any],
                  ["user", "assistant"].contains(event.string("type")) else { continue }   // metadata stays
            guard event["isApiErrorMessage"] as? Bool == true || event.dict("message")?.string("model") == "<synthetic>" else { break }
            lines.remove(at: i)
        }
        return Data(lines.joined(separator: [0x0A]))
    }
}
