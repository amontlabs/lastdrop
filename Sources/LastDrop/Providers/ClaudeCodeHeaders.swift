import Foundation

/// The headers Claude Code sends to Anthropic's OAuth endpoints (usage, profile), sent the same way at the
/// user's request. Anthropic decides from them which app is asking, and offers reset grants (`cedar_ember`) to
/// Claude Code only: with lastdrop's own User-Agent the block came back `"eligible": false,
/// "ineligible_reason": "surface"` with no grants (2026-11-10, Claude Code 2.1.321). Claude Code itself can't
/// hand them over: its `get_usage` control request and its saved reading both carry `"cedar_ember": null`.
enum ClaudeCodeHeaders {
    /// What Claude Code 2.1.321's OAuth client sends: its common `x-app`, `User-Agent` and
    /// `X-Claude-Code-Session-Id`, the bearer, the OAuth beta, and a JSON content type.
    static func oauth(accessToken: String, version: String = installedVersion) -> [String: String] {
        ["Authorization": "Bearer \(accessToken)",
         "anthropic-beta": "oauth-2025-04-20",
         "Content-Type": "application/json",
         "Accept": "application/json, text/plain, */*",
         "x-app": "cli",
         "User-Agent": userAgent(version: version),
         "X-Claude-Code-Session-Id": sessionID]
    }

    /// `claude-cli/2.1.321 (external, cli)`: the version, then the entrypoint, `cli` in a terminal.
    static func userAgent(version: String) -> String { "claude-cli/\(version) (external, cli)" }

    /// One id for lastdrop's whole run, as one Claude Code session keeps one.
    static let sessionID = UUID().uuidString.lowercased()

    /// Used when no installed Claude Code can be found.
    static let fallbackVersion = "2.1.321"

    /// The Claude Code version installed now, so the User-Agent follows its updates. Read once per run.
    static let installedVersion: String = {
        let home = NSHomeDirectory(), files = FileManager.default
        return version(launcherTarget: try? files.destinationOfSymbolicLink(atPath: home + "/.local/bin/claude"),
                       installed: (try? files.contentsOfDirectory(atPath: home + "/.local/share/claude/versions")) ?? [])
    }()

    /// The version the `claude` launcher points at (`…/claude/versions/2.1.321`), else the newest installed one.
    static func version(launcherTarget: String?, installed: [String]) -> String {
        if let name = launcherTarget.map({ ($0 as NSString).lastPathComponent }), isVersion(name) { return name }
        return installed.filter(isVersion).max { $0.compare($1, options: .numeric) == .orderedAscending } ?? fallbackVersion
    }

    private static func isVersion(_ s: String) -> Bool { s.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil }
}
