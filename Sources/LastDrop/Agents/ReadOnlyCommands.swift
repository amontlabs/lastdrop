import Foundation

/// Commands that only read, which an Antigravity agent runs without waiting for the judge: the list Claude Code
/// itself runs without a check (read from Claude Code 2.1.319 and checked with its `dontAsk` mode; see
/// docs/research/I-subagent-progress-and-commands.md §9). Its per-command flag tables are transcribed as data in
/// `ReadOnlyFlagTables.swift`; the rules are lastdrop's own code and never looser than Claude Code's: an unknown
/// flag, a `$`, a backtick, a redirection to a file, a subshell or control flow is never read-only, and a compound
/// command is read-only only when every part is. What isn't read-only goes to the judge.
enum ReadOnlyCommands {
    /// The read-only commands `command` is made of (`["git status", "ls"]`), or nil when any part isn't one.
    static func check(_ command: String) -> [String]? {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !command.contains("$"), !command.contains("`"),
              !backgrounds(command), let parts = PermissionRules.split(command, loose: false), !parts.isEmpty else { return nil }
        var names: [String] = []
        for part in parts {
            let unwrapped = PermissionRules.unwrap(part, forAllow: true)
            guard !unwrapped.blocked, let words = words(unwrapped.text), let name = readOnly(words) else { return nil }
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// An unquoted `&` that sends a command to the background (not `&&`, `2>&1` or `&>`).
    static func backgrounds(_ command: String) -> Bool {
        var single = false, double = false, escaped = false, masked = ""
        for c in command {
            if escaped { escaped = false; masked.append("_"); continue }
            if c == "\\" && !single { escaped = true; masked.append("_"); continue }
            if c == "'" && !double { single.toggle() } else if c == "\"" && !single { double.toggle() }
            masked.append(single || double ? "_" : c)
        }
        let rest = masked.replacingOccurrences(of: #"&&|[<>]&|&>"#, with: " ", options: .regularExpression)
        return rest.contains("&")
    }

    // MARK: Words

    /// The part's words with quotes removed, without the harmless redirections `2>&1` and `>/dev/null`. nil when an
    /// unquoted `<`, `>`, `(`, `)`, `{`, `}` or `\` is left: a redirection, a subshell, a brace expansion or an escape.
    static func words(_ part: String) -> [String]? {
        var raw: [(text: String, quoted: String)] = []   // the word as typed, and with quoted characters as "_"
        var text = "", masked = ""
        var single = false, double = false, escaped = false, started = false
        for c in part {
            if escaped { escaped = false; text.append(c); masked.append("_"); continue }
            if !single, !double, c.isWhitespace {
                if started { raw.append((text, masked)); text = ""; masked = ""; started = false }
                continue
            }
            started = true
            if c == "'" && !double { single.toggle(); masked.append("_"); continue }
            if c == "\"" && !single { double.toggle(); masked.append("_"); continue }
            if double && c == "\\" { escaped = true; masked.append("_"); continue }
            text.append(c)
            masked.append(single || double ? "_" : c)
        }
        guard !single, !double else { return nil }
        if started { raw.append((text, masked)) }
        let harmless: Set<String> = ["2>&1", "1>&2", ">&2", "2>/dev/null", ">/dev/null", "1>/dev/null", "&>/dev/null"]
        var words: [String] = []
        var i = 0
        while i < raw.count {
            let masked = raw[i].quoted
            if harmless.contains(masked) { i += 1; continue }
            if ["2>", ">", "&>"].contains(masked), i + 1 < raw.count, raw[i + 1].quoted == "/dev/null" { i += 2; continue }
            if masked.contains(where: { "<>(){}\\".contains($0) }) { return nil }
            words.append(raw[i].text)
            i += 1
        }
        return words
    }

    // MARK: Commands

    /// Any arguments: these only read or print.
    static let plain: Set<String> = [
        "cal", "uptime", "cat", "head", "tail", "wc", "stat", "strings", "hexdump", "od", "nl", "id", "uname", "free",
        "df", "du", "locale", "groups", "nproc", "basename", "dirname", "realpath", "cut", "paste", "tr", "column",
        "tac", "rev", "fold", "expand", "unexpand", "fmt", "comm", "cmp", "numfmt", "readlink", "diff", "true",
        "false", "sleep", "type", "expr", "seq", "tsort", "pr",
    ]

    /// Only with no arguments.
    static let bare: Set<String> = ["pwd", "whoami", "alias"]

    /// Only exactly these.
    static let exact: Set<String> = [
        "claude -h", "claude --help", "node -v", "node --version", "python --version", "python3 --version", "ip addr",
        "docker ps", "docker images",
    ]

    /// `find` actions that run, delete or write.
    static let findActions: Set<String> = ["-rm", "-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprint0",
                                           "-fprintf", "-fls", "-files0-from"]

    /// The read-only command's name for the log, or nil.
    static func readOnly(_ words: [String]) -> String? {
        guard let first = words.first else { return nil }
        let args = Array(words.dropFirst())
        if exact.contains(words.joined(separator: " ")) { return words.joined(separator: " ") }
        if first == "docker", let sub = args.first, ["ps", "images"].contains(sub) { return "docker " + sub }
        if plain.contains(first) || first == "ls" { return first }
        if bare.contains(first) { return args.isEmpty ? first : nil }
        switch first {
        case "echo":
            return args.allSatisfy { !$0.contains("#") && !$0.contains("!") } ? first : nil
        case "printf": return printf(args) ? first : nil
        case "cd": return args.count <= 1 ? first : nil
        case "find": return args.contains(where: findActions.contains) ? nil : first
        case "history": return args.isEmpty || (args.count == 1 && Int(args[0]) != nil) ? first : nil
        case "arch": return args.isEmpty || (args.count == 1 && ["-h", "--help"].contains(args[0])) ? first : nil
        case "ifconfig": return args.count <= 1 && !(args.first?.hasPrefix("-") ?? false) ? first : nil
        case "uniq": return uniq(args) ? first : nil
        case "jq": return jq(args) ? first : nil
        case "test", "[", "[[": return test(args) ? first : nil
        case "git": return git(args)
        case "gh": return gh(args)
        case "docker": return docker(args)
        case "xargs": return xargs(args)
        default: break
        }
        guard let table = flagTables[first], flags(args, table, command: first), !dangerous(first, args) else { return nil }
        return first
    }

    // MARK: Flags

    /// Claude Code's flag rule: every flag is in the table, by its name before `=`. A flag that takes no value
    /// takes no `=`; one that does takes `=value` or the next word, which isn't a flag, doesn't start with `-` for a
    /// string (git's `--sort=-date` aside), is digits for a number and one character for a char. Short flags may
    /// be clustered (`-rn`) only when none takes a value; `git log -20` and `grep -A3` are understood. Words that
    /// aren't flags are allowed; after `--` every word is one.
    static func flags(_ args: [String], _ table: [String: Value], command: String) -> Bool {
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "--" { return true }
            guard arg.hasPrefix("-"), arg.count > 1 else { i += 1; continue }
            let parts = arg.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0]), attached = parts.count > 1 ? String(parts[1]) : nil
            guard !name.isEmpty else { return false }
            guard let kind = table[name] else {
                if command == "git", name.range(of: #"^-\d+$"#, options: .regularExpression) != nil { i += 1; continue }
                if ["grep", "egrep", "fgrep", "rg"].contains(command), !name.hasPrefix("--"), name.count > 2,
                   let kind = table[String(name.prefix(2))], [.number, .string].contains(kind) {
                    let rest = String(name.dropFirst(2))
                    if rest.allSatisfy(\.isNumber) { i += 1; continue }
                }
                if !name.hasPrefix("--"), name.count > 2 {
                    for letter in name.dropFirst() { guard table["-" + String(letter)] == Value.none else { return false } }
                    i += 1; continue
                }
                return false
            }
            if kind == .none {
                if attached != nil { return false }
                i += 1; continue
            }
            let value: String
            if let attached { value = attached; i += 1 } else {
                guard i + 1 < args.count, !isFlag(args[i + 1]) else { return false }
                value = args[i + 1]; i += 2
            }
            if kind == .string, value.hasPrefix("-"), !(command == "git" && name == "--sort" && value.range(of: #"^-[a-zA-Z]"#, options: .regularExpression) != nil) {
                return false
            }
            switch kind {
            case .none: return false
            case .string: break
            case .number: guard !value.isEmpty, value.allSatisfy(\.isNumber) else { return false }
            case .char: guard value.count == 1 else { return false }
            case .braces: guard value == "{}" else { return false }
            case .eof: guard value == "EOF" else { return false }
            }
        }
        return true
    }

    private static func isFlag(_ word: String) -> Bool {
        word.count > 1 && word.range(of: #"^-[a-zA-Z0-9_-]"#, options: .regularExpression) != nil
    }

    /// Claude Code's extra checks for commands whose flags alone don't make them safe.
    static func dangerous(_ command: String, _ args: [String]) -> Bool {
        switch command {
        case "sed": return !sed(args)
        case "date":
            // `date 0101…` sets the clock: words must be `+FORMAT`, apart from these flags' values.
            let values: Set<String> = ["-d", "--date", "-r", "--reference", "--rfc-3339"]
            var i = 0
            while i < args.count {
                let arg = args[i]
                if arg.hasPrefix("--") && arg.contains("=") { i += 1 }
                else if arg.hasPrefix("-") { i += values.contains(arg) ? 2 : 1 }
                else { if !arg.hasPrefix("+") { return true }; i += 1 }
            }
            return false
        case "hostname":
            // Flags only: a name would set it.
            return !args.allSatisfy { $0.range(of: #"^(-[a-zA-Z]|--[a-zA-Z-]+)$"#, options: .regularExpression) != nil }
        case "which":
            var after = false
            for arg in args {
                if after { continue }
                if arg == "--" { after = true }
                else if arg.hasPrefix("-"), arg.range(of: #"^(-[A-Za-z]+|--[a-z-]+)$"#, options: .regularExpression) == nil { return true }
            }
            return false
        case "tput":
            // Capabilities that reset or reprogram the terminal, and `-S` (capabilities from stdin).
            let refused: Set<String> = ["init", "reset", "rs1", "rs2", "rs3", "is1", "is2", "is3", "iprog", "if", "rf", "clear",
                                        "flash", "mc0", "mc4", "mc5", "mc5i", "mc5p", "pfkey", "pfloc", "pfx", "pfxl", "smcup", "rmcup"]
            var i = 0, after = false
            while i < args.count {
                let arg = args[i]
                if arg == "--" { after = true; i += 1 }
                else if !after, arg.hasPrefix("-") {
                    if arg == "-S" || (!arg.hasPrefix("--") && arg.count > 2 && arg.contains("S")) { return true }
                    i += arg == "-T" ? 2 : 1
                } else { if refused.contains(arg) { return true }; i += 1 }
            }
            return false
        default: return false
        }
    }

    // MARK: Special rules

    /// No option (`printf -v` writes a variable), and only plain text, `%s`-like conversions and simple escapes.
    static func printf(_ args: [String]) -> Bool {
        guard let format = args.first, !format.hasPrefix("-") else { return false }
        if format.range(of: #"\\(u|U|x|[0-7])"#, options: .regularExpression) != nil { return false }
        if format.range(of: #"%[-+ #0-9.]*[diouxXeEfFgGaAc]"#, options: .regularExpression) != nil {
            return args.dropFirst().allSatisfy { Double($0) != nil }
        }
        return true
    }

    /// Flags only: no input or output file (Claude Code 2.1.319 refuses `uniq a.txt` too).
    static func uniq(_ args: [String]) -> Bool {
        let flags: Set<String> = ["-c", "--count", "-d", "--repeated", "-D", "-u", "--unique", "-i", "--ignore-case",
                                  "-z", "--zero-terminated"]
        let values: Set<String> = ["-f", "--skip-fields", "-s", "--skip-chars", "-w", "--check-chars"]
        var i = 0
        while i < args.count {
            let arg = args[i]
            i += 1
            if flags.contains(arg) { continue }
            let name = String(arg.split(separator: "=", maxSplits: 1).first ?? "")
            guard values.contains(name) else { return false }
            let value: String
            if arg.contains("=") { value = String(arg.dropFirst(name.count + 1)) } else {
                guard i < args.count else { return false }
                value = args[i]; i += 1
            }
            guard !value.isEmpty, value.allSatisfy(\.isNumber) else { return false }
        }
        return true
    }

    /// A filter and files: no module loading or reading of filter files, and no environment access.
    static func jq(_ args: [String]) -> Bool {
        let refused: Set<String> = ["-f", "-L", "--from-file", "--rawfile", "--slurpfile", "--run-tests", "--library-path"]
        if args.contains(where: { refused.contains(String($0.split(separator: "=", maxSplits: 1).first ?? "")) }) { return false }
        let filter = args.first { !$0.hasPrefix("-") } ?? ""
        return ["env", "ENV", "include", "import", "input_filename", "$__loc__"].allSatisfy { !filter.contains($0) }
    }

    /// `-v` and `-R` look up variables (with subscripts bash evaluates); the rest only test files and strings.
    static func test(_ args: [String]) -> Bool {
        !args.contains { ["-v", "-R"].contains($0) } && !args.contains("=~")
    }

    /// The words that aren't flags, skipping the values of `values`.
    private static func positionals(_ args: [String], values: Set<String>) -> [String] {
        var out: [String] = [], skip = false
        for arg in args {
            if skip { skip = false; continue }
            if values.contains(arg) { skip = true; continue }
            if arg.hasPrefix("-") && arg != "-" { continue }
            out.append(arg)
        }
        return out
    }

    /// A sed script made of addresses and the commands p d q Q = l n N g G h H x z D P, s///flags and y///.
    static func sedScript(_ script: String) -> Bool {
        let c = Array(script)
        var i = 0
        func regex(_ delimiter: Character) -> Bool {
            while i < c.count {
                if c[i] == "\\" { i += 2; continue }
                if c[i] == delimiter { i += 1; return true }
                if c[i] == "\n" { return false }
                i += 1
            }
            return false
        }
        func address() -> Bool {
            if i < c.count, c[i].isNumber { while i < c.count, c[i].isNumber || c[i] == "~" { i += 1 }; return true }
            if i < c.count, c[i] == "/" { i += 1; guard regex("/") else { return false }; while i < c.count, "IM".contains(c[i]) { i += 1 }; return true }
            return true
        }
        while i < c.count {
            if c[i].isWhitespace || c[i] == ";" || c[i] == "}" { i += 1; continue }
            guard address() else { return false }
            if i < c.count, c[i] == "," { i += 1; guard address() else { return false } }
            while i < c.count, c[i] == " " || c[i] == "!" { i += 1 }
            guard i < c.count else { return false }
            let command = c[i]
            i += 1
            switch command {
            case "p", "d", "q", "Q", "=", "l", "n", "N", "g", "G", "h", "H", "x", "z", "D", "P", "{":
                while i < c.count, c[i].isNumber { i += 1 } // `q5`, `l 40`
            case "s", "y":
                guard i < c.count, !c[i].isWhitespace, c[i] != "\\", c[i] != "\n" else { return false }
                let delimiter = c[i]
                i += 1
                guard regex(delimiter), regex(delimiter) else { return false }
                if command == "s" { while i < c.count, "gpiIm0123456789".contains(c[i]) { i += 1 } }
            default:
                return false
            }
            guard i == c.count || c[i].isWhitespace || c[i] == ";" || c[i] == "}" else { return false }
        }
        return true
    }


    // MARK: xargs, sed

    /// Claude Code's targets for `xargs`: only these, themselves read-only.
    static let xargsTargets: Set<String> = ["echo", "printf", "wc", "grep", "egrep", "fgrep", "head", "tail"]

    /// `xargs` with its listed flags, then a listed target that is read-only with its arguments.
    static func xargs(_ args: [String]) -> String? {
        guard let table = flagTables["xargs"] else { return nil }
        var i = 0
        while i < args.count, args[i].hasPrefix("-"), args[i] != "--" {
            let name = String(args[i].split(separator: "=", maxSplits: 1)[0])
            guard let kind = table[name] else { return nil }
            i += kind == .none || args[i].contains("=") ? 1 : 2
        }
        if i < args.count, args[i] == "--" { i += 1 }
        guard flags(Array(args[..<min(i, args.count)]), table, command: "xargs") else { return nil }
        if i >= args.count { return "xargs" }
        guard xargsTargets.contains(args[i]), let target = readOnly(Array(args[i...])) else { return nil }
        return "xargs " + target
    }

    /// Read-only sed: the table's flags (no `-i`, no `-f`), and printing scripts only (no `w`, `e`, `r`).
    static func sed(_ args: [String]) -> Bool {
        var scripts: [String] = [], i = 0, first: String?
        while i < args.count {
            let arg = args[i]
            i += 1
            if arg == "-e" || arg == "--expression" { if i < args.count { scripts.append(args[i]); i += 1 }; continue }
            if arg.hasPrefix("--expression=") { scripts.append(String(arg.dropFirst(13))); continue }
            if arg == "-l" || arg == "--line-length" { i += 1; continue }
            if arg.hasPrefix("-") && arg != "-" { continue }
            if first == nil { first = arg }
        }
        if scripts.isEmpty, let first { scripts.append(first) }
        return !scripts.isEmpty && scripts.allSatisfy(sedScript)
    }

    // MARK: git, gh, docker

    /// The table for `git <sub>` (or `git config --get`, `git stash list`…): the longest key the words start with.
    private static func table(_ prefix: String, _ args: [String]) -> (name: String, rest: [String], table: [String: Value])? {
        for count in stride(from: min(2, args.count), through: 1, by: -1) {
            let name = ([prefix] + args.prefix(count)).joined(separator: " ")
            if let table = flagTables[name] { return (name, Array(args.dropFirst(count)), table) }
        }
        return nil
    }

    /// `~user` expansions, and `~` with braces: they read outside what the command names.
    private static func tilde(_ args: [String]) -> Bool {
        args.contains { $0.range(of: #"(^|[=:])~"#, options: .regularExpression) != nil || ($0.contains("~") && $0.contains("{")) }
    }

    /// git formats that run gpg (`%G…`, `%(signature)`), and `--pretty` names from config.
    private static func gitFormatDanger(_ args: [String]) -> Bool {
        let builtIn: Set<String> = ["oneline", "short", "medium", "full", "fuller", "email", "raw", "reference", "mboxrd"]
        for (i, arg) in args.enumerated() {
            if arg.range(of: #"%[-+ ]?G|%\(\*?signature"#, options: .regularExpression) != nil { return true }
            for flag in ["--format", "--pretty", "--sort", "--group"] {
                var value: String?
                if arg == flag, i + 1 < args.count { value = args[i + 1] } else if arg.hasPrefix(flag + "=") { value = String(arg.dropFirst(flag.count + 1)) }
                guard let value else { continue }
                if tilde([value]) || value.contains("signature") { return true }
                if flag == "--format" || flag == "--pretty", !value.isEmpty, !value.contains("%"),
                   !value.hasPrefix("format:"), !value.hasPrefix("tformat:"), !builtIn.contains(value) { return true }
            }
        }
        return false
    }

    /// Only `--no-pager` before the subcommand: `-c`, `-C`, `--git-dir` and the rest change what runs or where.
    static func git(_ args: [String]) -> String? {
        var args = args
        while args.first == "--no-pager" { args.removeFirst() }
        guard let sub = args.first, !sub.hasPrefix("-"), !tilde(args), !gitFormatDanger(args),
              let (name, rest, table) = table("git", args), flags(rest, table, command: "git") else { return nil }
        switch name {
        case "git remote":
            return rest.allSatisfy { $0 == "-v" || $0 == "--verbose" } ? name : nil
        case "git remote show":
            // One remote, named plainly, with `-n` (no network).
            let split = rest.firstIndex(of: "--")
            let before = split.map { Array(rest[..<$0]) } ?? rest, after = split.map { Array(rest[($0 + 1)...]) } ?? []
            let names = before.filter { $0 != "-n" } + after
            guard names.count == 1, before.contains("-n"),
                  names[0].range(of: #"^[a-zA-Z0-9_][a-zA-Z0-9_-]*$"#, options: .regularExpression) != nil else { return nil }
            return name
        case "git reflog":
            if let verb = rest.first, !verb.hasPrefix("-"), !["show", "list"].contains(verb) { return nil }
            return rest.contains(where: ["expire", "delete", "exists", "drop", "write"].contains) ? nil : name
        case "git branch", "git tag":
            // A name without `--list` (or `-l` in a cluster) creates one; these flags' values are revisions.
            let takesValue: Set<String> = name == "git tag"
                ? ["--contains", "--no-contains", "--merged", "--no-merged", "--points-at", "--sort", "--format", "-n"]
                : ["--contains", "--no-contains", "--points-at", "--sort", "--merged", "--no-merged"]
            var listing = false, i = 0, after = false
            while i < rest.count {
                let arg = rest[i]
                if arg == "--", !after { after = true; i += 1; continue }
                if !after, arg.hasPrefix("-") {
                    if arg == "--list" || arg == "-l" || (!arg.hasPrefix("--") && arg.count > 2 && !arg.contains("=") && arg.dropFirst().contains("l")) { listing = true }
                    // `--merged` takes an optional revision on branch: one that follows is that revision.
                    i += arg.contains("=") ? 1 : takesValue.contains(arg) && i + 1 < rest.count && !rest[i + 1].hasPrefix("-") ? 2 : 1
                } else {
                    if !listing { return nil }
                    i += 1
                }
            }
            return name
        case "git ls-remote":
            // No remote named: only the configured one. A value flag's value isn't a remote.
            var i = 0
            while i < rest.count {
                let arg = rest[i]
                if !arg.hasPrefix("-") { return nil }
                i += !arg.contains("=") && (table[arg] ?? .none) != .none ? 2 : 1
            }
            return name
        default:
            return name
        }
    }

    /// gh views, without a value that points elsewhere (`host/owner/repo`, a URL, `user@host`).
    static func gh(_ args: [String]) -> String? {
        guard let (name, rest, table) = table("gh", args), name.split(separator: " ").count == 3,
              flags(rest, table, command: "gh") else { return nil }
        for arg in rest {
            var value = arg
            if arg.hasPrefix("-") {
                guard let equals = arg.firstIndex(of: "=") else { continue }
                value = String(arg[arg.index(after: equals)...])
            }
            if value.contains("://") || value.contains("@") || value.filter({ $0 == "/" }).count >= 2 { return nil }
        }
        return name
    }

    /// `docker logs` and `docker inspect`, without options that pick another daemon.
    static func docker(_ args: [String]) -> String? {
        guard let (name, rest, table) = table("docker", args), flags(rest, table, command: "docker"), !tilde(rest) else { return nil }
        let host = ["-H", "-c", "-r", "--host", "--context", "--config", "--tlscacert", "--tlscert", "--tlskey", "--url",
                    "--connection", "--identity", "--remote", "--module", "--out"]
        let letters = Set(host.filter { $0.count == 2 }.map { $0.last! })
        for arg in rest {
            if host.contains(where: { arg == $0 || arg.hasPrefix($0 + "=") || ($0.count == 2 && arg.count > 2 && arg.hasPrefix($0)) }) { return nil }
            if arg.hasPrefix("-"), !arg.hasPrefix("--") {
                let cluster = arg.dropFirst().prefix { $0.isLetter }
                if cluster.count >= 2, cluster.contains(where: letters.contains) { return nil }
            }
        }
        return name
    }
}
