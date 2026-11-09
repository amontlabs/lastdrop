import Foundation

/// The user's Claude Code `Bash(...)` permission rules, applied to a command another provider's agent wants to run.
/// Matching follows https://code.claude.com/docs/en/permissions (Bash, Compound commands, Wrappers) and stays
/// conservative: whenever lastdrop can't be sure a command is covered by allow rules, the rules don't decide and the
/// reviewer does. A deny or ask rule decides as soon as any part of the command matches it.
struct PermissionRules: Sendable, Equatable {
    /// `Bash(...)` specifiers; `*` stands for a bare `Bash` rule.
    var allow: [String] = []
    var deny: [String] = []
    var ask: [String] = []

    enum Verdict: Equatable {
        /// Every part of the command matches one of these allow rules.
        case allow([String])
        case deny(String)
        /// An ask rule matches: the user wants to be asked, and nobody can be asked here.
        case ask(String)
        /// The rules don't decide.
        case none
    }

    // MARK: Loading

    /// User settings (`$CLAUDE_CONFIG_DIR` or `~/.claude`), managed settings, and the project's
    /// `.claude/settings.json` and `.claude/settings.local.json` in `cwd` and its git root.
    static func load(cwd: String, environment: [String: String] = ProcessInfo.processInfo.environment,
                     home: String = NSHomeDirectory()) -> PermissionRules {
        let config = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.claude"
        var files = [config + "/settings.json", "/Library/Application Support/ClaudeCode/managed-settings.json"]
        var roots = [cwd]
        if let root = gitRoot(cwd), root != cwd { roots.append(root) }
        for root in roots { files += [root + "/.claude/settings.json", root + "/.claude/settings.local.json"] }
        var rules = PermissionRules()
        for file in files {
            guard let data = FileManager.default.contents(atPath: file),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            rules.add(root.dict("permissions") ?? [:])
        }
        return rules
    }

    mutating func add(_ permissions: [String: Any]) {
        func bash(_ key: String) -> [String] { (permissions[key] as? [String] ?? []).compactMap(Self.bashSpecifier) }
        for rule in bash("allow") where !allow.contains(rule) { allow.append(rule) }
        for rule in bash("deny") where !deny.contains(rule) { deny.append(rule) }
        for rule in bash("ask") where !ask.contains(rule) { ask.append(rule) }
    }

    /// `Bash` → `*`; `Bash(npm test:*)` → `npm test:*`; other tools and parameter rules (`Bash(timeout:5)`) → nil.
    static func bashSpecifier(_ rule: String) -> String? {
        let rule = rule.trimmingCharacters(in: .whitespaces)
        if rule == "Bash" { return "*" }
        guard rule.hasPrefix("Bash("), rule.hasSuffix(")") else { return nil }
        let spec = String(rule.dropFirst(5).dropLast())
        let parameters = ["run_in_background", "timeout", "description", "dangerouslyDisableSandbox", "command"]
        if let colon = spec.firstIndex(of: ":"), parameters.contains(spec[..<colon].trimmingCharacters(in: .whitespaces)) { return nil }
        return spec.isEmpty ? nil : spec
    }

    private static func gitRoot(_ directory: String) -> String? {
        var url = URL(fileURLWithPath: directory)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.path }
            url.deleteLastPathComponent()
        }
        return nil
    }

    // MARK: Checking

    func check(_ command: String) -> Verdict {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return .none }
        // Deny and ask see every piece, including those inside substitutions, subshells and loops.
        let pieces = Self.split(command, loose: true)?.map { Self.unwrap($0, forAllow: false).text } ?? [command]
        for rule in deny { if pieces.contains(where: { Self.matches(rule, $0) }) { return .deny("Bash(\(rule))") } }
        for rule in ask { if pieces.contains(where: { Self.matches(rule, $0) }) { return .ask("Bash(\(rule))") } }
        // Allow needs a command lastdrop fully understands, every part of it covered.
        guard !allow.isEmpty, let parts = Self.split(command, loose: false) else { return .none }
        var used: [String] = []
        for part in parts {
            let unwrapped = Self.unwrap(part, forAllow: true)
            guard !unwrapped.blocked, !Self.redirects(unwrapped.text) else { return .none }
            let exact = Self.needsExactRule(unwrapped.text)
            guard let rule = allow.first(where: { rule in
                if exact { return !rule.contains("*") && !unwrapped.text.contains("*") && rule == unwrapped.text }
                return Self.matches(rule, unwrapped.text)
            }) else { return .none }
            if !used.contains("Bash(\(rule))") { used.append("Bash(\(rule))") }
        }
        return .allow(used)
    }

    /// Claude Code's wildcard: `*` matches any text; `:*` at the end means ` *`; a trailing ` *` that is the only
    /// wildcard also matches the bare command.
    static func matches(_ rule: String, _ command: String) -> Bool {
        var rule = rule
        if rule.hasSuffix(":*") { rule = String(rule.dropLast(2)) + " *" }
        if rule == "*" { return true }
        let parts = rule.components(separatedBy: "*")
        if parts.count == 1 { return rule == command }
        if parts.count == 2, rule.hasSuffix(" *"), command == String(rule.dropLast(2)) { return true }
        let pattern = "^" + parts.map(NSRegularExpression.escapedPattern(for:)).joined(separator: ".*") + "$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return false }
        return regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil
    }

    /// The command's parts, split at `&&`, `||`, `;`, `|`, `|&`, `&` and newlines outside quotes. Strict (`loose`
    /// false) gives nil for anything it doesn't fully understand: substitutions, subshells, groups, here-docs,
    /// control flow, unbalanced quotes, a dangling operator. Loose also splits at those, for deny rules.
    static func split(_ command: String, loose: Bool) -> [String]? {
        var parts: [String] = [], current = ""
        var single = false, double = false, escaped = false
        let chars = Array(command)
        var i = 0
        var dangling = false
        func cut() {
            let part = current.trimmingCharacters(in: .whitespacesAndNewlines)
            current = ""
            if !part.isEmpty { parts.append(part) }
        }
        while i < chars.count {
            let c = chars[i], next = i + 1 < chars.count ? chars[i + 1] : nil
            if escaped { current.append(c); escaped = false; i += 1; continue }
            if single { current.append(c); if c == "'" { single = false }; i += 1; continue }
            if c == "\\" { current.append(c); escaped = true; i += 1; continue }
            if double {
                if c == "\"" { double = false; current.append(c); i += 1; continue }
                if c == "`" || (c == "$" && next == "(") {
                    guard loose else { return nil }
                    cut(); i += c == "`" ? 1 : 2; continue
                }
                current.append(c); i += 1; continue
            }
            switch c {
            case "'": single = true; current.append(c); i += 1
            case "\"": double = true; current.append(c); i += 1
            case "&" where next == "&", "|" where next == "|":
                cut(); dangling = true; i += 2
            case "|" where next == "&":
                cut(); dangling = true; i += 2
            case "&" where next == ">", ">" where next == "&", "<" where next == "&":
                // `&>file`, `2>&1`, `<&3`: redirections, not separators.
                current.append(c); current.append(next!); i += 2
            case ";", "|", "&", "\n":
                dangling = c == "|"
                cut(); i += 1
            case "`", "(", ")", "{", "}":
                guard loose else { return nil }
                cut(); i += 1
            case "$" where next == "(":
                guard loose else { return nil }
                cut(); i += 2
            case "<" where next == "<":
                guard loose else { return nil }
                current.append(c); i += 1
            default:
                if !c.isWhitespace { dangling = false }
                current.append(c); i += 1
            }
        }
        if single || double || escaped { return loose ? parts + [current] : nil }
        if !loose, dangling { return nil }
        cut()
        if loose {
            // Control-flow words in front of a command (`for … do rm x; done`) aren't the command.
            let keywords: Set<String> = ["if", "then", "else", "elif", "fi", "do", "done", "while", "until", "!", "time", "case", "esac"]
            return parts.map { part in
                var words = part.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                while let first = words.first, keywords.contains(first) { words.removeFirst() }
                return words.joined(separator: " ")
            }.filter { !$0.isEmpty }
        }
        // Control flow can't be judged part by part.
        let flow: Set<String> = ["if", "then", "else", "elif", "fi", "for", "do", "done", "while", "until", "case", "esac", "function", "select"]
        if parts.contains(where: { flow.contains(String($0.split(separator: " ").first ?? "")) }) { return nil }
        return parts
    }

    /// A part with Claude Code's wrappers and leading variable assignments removed. For allow, any assignment
    /// blocks the part (lastdrop doesn't know Claude Code's list of safe variables).
    static func unwrap(_ part: String, forAllow: Bool) -> (text: String, blocked: Bool) {
        var words = Self.words(part)
        var blocked = false
        func drop(_ n: Int) { words.removeFirst(min(n, words.count)) }
        var changed = true
        while changed, let first = words.first?.text {
            changed = true
            if first.range(of: #"^[A-Za-z_][A-Za-z0-9_]*\+?="#, options: .regularExpression) != nil {
                if forAllow { blocked = true }
                drop(1)
            } else if ["nohup", "builtin", "noglob"].contains(first) {
                drop(1)
            } else if first == "command", words.count > 1, !["-v", "-V"].contains(words[1].text) {
                drop(1)
            } else if first == "xargs", words.count > 1, !words[1].text.hasPrefix("-") {
                drop(1)
            } else if first == "time" {
                drop(words.count > 1 && words[1].text == "-p" ? 2 : 1)
            } else if first == "nice" {
                if words.count > 2, words[1].text == "-n" { drop(3) }
                else if words.count > 1, words[1].text.range(of: #"^-\d+$"#, options: .regularExpression) != nil { drop(2) }
                else { drop(1) }
            } else if first == "timeout" {
                drop(1)
                while let flag = words.first?.text, flag.hasPrefix("-") {
                    drop(["-s", "-k", "--signal", "--kill-after"].contains(flag) ? 2 : 1)
                }
                drop(1) // the duration
            } else if first == "stdbuf" {
                drop(1)
                while let flag = words.first?.text, flag.hasPrefix("-") { drop(["-i", "-o", "-e"].contains(flag) ? 2 : 1) }
            } else {
                changed = false
            }
        }
        guard let start = words.first?.start else { return ("", blocked) }
        return (String(part[start...]).trimmingCharacters(in: .whitespacesAndNewlines), blocked)
    }

    /// Words of a part, split at unquoted whitespace, with where each starts.
    private static func words(_ part: String) -> [(text: String, start: String.Index)] {
        var words: [(String, String.Index)] = []
        var current = "", start: String.Index?
        var single = false, double = false, escaped = false
        var index = part.startIndex
        while index < part.endIndex {
            let c = part[index]
            if !single, !double, !escaped, c.isWhitespace {
                if let s = start { words.append((current, s)); current = ""; start = nil }
            } else {
                if start == nil { start = index }
                if escaped { escaped = false } else if c == "\\" && !single { escaped = true }
                else if c == "'" && !double { single.toggle() } else if c == "\"" && !single { double.toggle() }
                current.append(c)
            }
            index = part.index(after: index)
        }
        if let s = start { words.append((current, s)) }
        return words
    }

    /// An unquoted redirection whose target is a file: the command's rule doesn't cover writing or reading it.
    static func redirects(_ part: String) -> Bool {
        var single = false, double = false, escaped = false
        var stripped = ""
        for c in part {
            if escaped { escaped = false; stripped.append("_"); continue }
            if c == "\\" && !single { escaped = true; stripped.append("_"); continue }
            if c == "'" && !double { single.toggle(); stripped.append("_"); continue }
            if c == "\"" && !single { double.toggle(); stripped.append("_"); continue }
            stripped.append(single || double ? "_" : c)
        }
        // Harmless targets: /dev/null and file descriptors.
        let harmless = #"(\d*|&)>>?\s*/dev/null|\d*>&\d+|<&\d+"#
        let rest = stripped.replacingOccurrences(of: harmless, with: " ", options: .regularExpression)
        return rest.contains(">") || rest.contains("<")
    }

    /// Exec wrappers and `find` with an action that runs, deletes or writes: only an exact rule can allow them.
    static func needsExactRule(_ command: String) -> Bool {
        let words = words(command).map(\.text)
        guard let first = words.first else { return false }
        if ["watch", "setsid", "ionice", "flock"].contains(first) { return true }
        let actions: Set<String> = ["-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprint0", "-fprintf", "-fls", "-files0-from"]
        return first == "find" && words.contains { actions.contains($0) }
    }
}
