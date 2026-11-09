import Foundation

/// Commands that only read, which an Antigravity agent runs without waiting for the judge: the list Claude Code
/// itself runs without a check (read from Claude Code 2.1.319 and checked with its `dontAsk` mode; see
/// docs/research/I-subagent-progress-and-commands.md §9), implemented here as lastdrop's own rules and kept
/// conservative: an unknown flag, a `$`, a backtick, a redirection to a file, a subshell or control flow is never
/// read-only, and a compound command is read-only only when every part is. What isn't read-only goes to the judge.
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
        "false", "sleep", "type", "expr", "seq", "tsort", "pr", "ps", "netstat", "lsof", "pgrep", "ss",
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
        case "sed": return sed(args) ? first : nil
        case "tput": return args.count == 1 && ["cols", "lines", "colors", "longname"].contains(args[0]) ? first : nil
        case "date":
            // `date 0101…` sets the clock; only `+FORMAT`, or any word after BSD's `-j` (parse, don't set).
            guard flagTables["date"]!.allows(args), !args.contains(where: { $0 == "-s" || $0.hasPrefix("--set") }) else { return nil }
            let words = positionals(args, values: ["-d", "-r", "-f", "-v", "-z", "--date", "--reference"])
            return args.contains("-j") || words.allSatisfy({ $0.hasPrefix("+") }) ? first : nil
        default:
            guard let table = flagTables[first] else { return nil }
            return table.allows(args) ? first : nil
        }
    }

    // MARK: Flag tables

    /// A command whose flags must all be listed. `values` take the next word (or `=…`, or the rest of a short
    /// cluster); `positional` false refuses any other word.
    struct Flags: Sendable {
        var short = ""          // letters allowed alone or in a cluster: "rn"
        var shortValues = ""    // letters that take a value
        var long: Set<String> = []
        var longValues: Set<String> = []
        var positional = true

        func allows(_ args: [String]) -> Bool {
            var i = 0, afterDashes = false
            while i < args.count {
                let arg = args[i]
                i += 1
                if afterDashes || arg == "-" || !arg.hasPrefix("-") {
                    if !positional { return false }
                    continue
                }
                if arg == "--" { afterDashes = true; continue }
                if arg.hasPrefix("--") {
                    let name = String(arg.split(separator: "=", maxSplits: 1)[0])
                    if long.contains(name) { if arg.contains("=") && !longValues.contains(name) { return false }; continue }
                    guard longValues.contains(name) else { return false }
                    if !arg.contains("=") { guard i < args.count else { return false }; i += 1 }
                    continue
                }
                // A short cluster: `-rn`, `-k2,2n`, `-A3`, `-n 5`.
                let letters = Array(arg.dropFirst())
                var j = 0
                while j < letters.count {
                    let letter = letters[j]
                    if shortValues.contains(letter) {
                        if j == letters.count - 1 { guard i < args.count else { return false }; i += 1 }
                        break
                    }
                    guard short.contains(letter) else { return false }
                    j += 1
                }
            }
            return true
        }
    }

    static let flagTables: [String: Flags] = {
        let grep = Flags(short: "EFGPabcHhiIlLnoqrRsTuUvwxyzZV", shortValues: "ABCDdefm",
                         long: ["--extended-regexp", "--fixed-strings", "--basic-regexp", "--perl-regexp", "--ignore-case",
                                "--no-ignore-case", "--invert-match", "--word-regexp", "--line-regexp", "--count", "--files-with-matches",
                                "--files-without-match", "--only-matching", "--quiet", "--silent", "--no-messages", "--byte-offset",
                                "--with-filename", "--no-filename", "--line-number", "--initial-tab", "--null", "--null-data",
                                "--text", "--recursive", "--dereference-recursive", "--color", "--colour", "--version", "--help",
                                "--line-buffered", "--binary", "--label"],
                         longValues: ["--regexp", "--file", "--max-count", "--after-context", "--before-context", "--context",
                                      "--include", "--exclude", "--exclude-dir", "--exclude-from", "--binary-files", "--devices",
                                      "--directories", "--color", "--colour", "--label"])
        let sum = Flags(short: "bctwz", long: ["--binary", "--check", "--tag", "--text", "--zero", "--ignore-missing", "--quiet",
                                                "--status", "--strict", "--warn"])
        return [
            "grep": grep, "egrep": grep, "fgrep": grep,
            "rg": Flags(short: "iSsvwxFPclLnNHIoqUzaRuh.0", shortValues: "eEfgtTmABCMjrd",
                        long: ["--ignore-case", "--smart-case", "--case-sensitive", "--invert-match", "--word-regexp",
                               "--line-regexp", "--fixed-strings", "--pcre2", "--count", "--count-matches", "--files",
                               "--files-with-matches", "--files-without-match", "--line-number", "--no-line-number",
                               "--with-filename", "--no-filename", "--only-matching", "--quiet", "--multiline",
                               "--multiline-dotall", "--hidden", "--no-ignore", "--no-ignore-vcs", "--follow", "--text",
                               "--json", "--vimgrep", "--heading", "--no-heading", "--sort-files", "--stats", "--trim",
                               "--null", "--column", "--byte-offset", "--no-messages", "--unrestricted", "--search-zip",
                               "--type-list", "--version", "--help", "--debug", "--files-without-match", "--crlf",
                               "--passthru", "--no-config", "--one-file-system", "--glob-case-insensitive"],
                        longValues: ["--regexp", "--file", "--glob", "--iglob", "--type", "--type-not", "--max-count",
                                     "--after-context", "--before-context", "--context", "--max-columns", "--threads",
                                     "--replace", "--max-depth", "--max-filesize", "--sort", "--sortr", "--color",
                                     "--colors", "--encoding", "--context-separator", "--field-match-separator", "--path-separator"]),
            "fd": fdFlags, "fdfind": fdFlags,
            "file": Flags(short: "bciIkLhNrsz0E", long: ["--brief", "--mime", "--mime-type", "--mime-encoding", "--keep-going",
                                                         "--dereference", "--no-dereference", "--no-pad", "--raw", "--special-files",
                                                         "--uncompress", "--print0", "--version", "--help"]),
            "sort": Flags(short: "bcCdfghiMmnrRsuVz", shortValues: "kt",
                          long: ["--ignore-leading-blanks", "--check", "--dictionary-order", "--ignore-case", "--general-numeric-sort",
                                 "--human-numeric-sort", "--ignore-nonprinting", "--month-sort", "--merge", "--numeric-sort",
                                 "--reverse", "--random-sort", "--stable", "--unique", "--version-sort", "--zero-terminated"],
                          longValues: ["--key", "--field-separator"]),
            "tree": Flags(short: "adlfxpsugDFqNQrtvUCnAShJ", shortValues: "LPI",
                          long: ["--noreport", "--dirsfirst", "--gitignore", "--prune", "--du", "--si", "--version", "--help"],
                          longValues: ["--filelimit", "--charset", "--sort", "--timefmt"]),
            "which": Flags(short: "as"),
            "base64": Flags(short: "dD", shortValues: "ibw", long: ["--decode", "--ignore-garbage"],
                            longValues: ["--input", "--wrap", "--break"]),
            "sha256sum": sum, "sha1sum": sum, "md5sum": sum, "sha512sum": sum,
            "hostname": Flags(short: "fsdiI", positional: false),
            "date": Flags(short: "uRIjn", shortValues: "drfvz",
                          long: ["--utc", "--universal", "--rfc-email", "--iso-8601", "--rfc-3339"],
                          longValues: ["--date", "--reference", "--iso-8601", "--rfc-3339"]),
        ]
    }()

    static let fdFlags = Flags(short: "HIsiglLapu0", shortValues: "dtEecS",
                               long: ["--hidden", "--no-ignore", "--no-ignore-vcs", "--case-sensitive", "--ignore-case",
                                      "--glob", "--regex", "--fixed-strings", "--absolute-path", "--list-details", "--follow",
                                      "--full-path", "--print0", "--unrestricted", "--version", "--help", "--prune", "--quiet"],
                               longValues: ["--max-depth", "--min-depth", "--exact-depth", "--type", "--extension", "--exclude",
                                            "--color", "--size", "--changed-within", "--changed-before", "--max-results", "--owner",
                                            "--search-path", "--base-directory"])

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
        Flags(short: "cdDiuz", shortValues: "fsw",
              long: ["--count", "--repeated", "--all-repeated", "--ignore-case", "--unique", "--zero-terminated", "--group"],
              longValues: ["--skip-fields", "--skip-chars", "--check-chars"]).allows(args)
            && positionals(args, values: ["-f", "-s", "-w"]).isEmpty
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

    /// `xargs` with its listed flags, running a read-only command (or `echo`, its default).
    static func xargs(_ args: [String]) -> String? {
        let values: Set<Character> = ["I", "n", "P", "L", "s", "E", "d"], alone: Set<Character> = ["0", "t", "r", "x"]
        var i = 0
        while i < args.count, args[i].hasPrefix("-"), args[i].count > 1 {
            let letters = Array(args[i].dropFirst())
            i += 1
            guard let letter = letters.first else { return nil }
            if values.contains(letter) { if letters.count == 1 { guard i < args.count else { return nil }; i += 1 }; continue }
            guard letters.allSatisfy(alone.contains) else { return nil }
        }
        if i == args.count { return "xargs" }
        return readOnly(Array(args[i...])).map { "xargs " + $0 }
    }

    /// Read-only sed: no in-place editing, and a script of printing commands only (no `w`, `e`, `r`).
    static func sed(_ args: [String]) -> Bool {
        var scripts: [String] = [], files = false, i = 0
        while i < args.count {
            let arg = args[i]
            i += 1
            switch arg {
            case "-n", "--quiet", "--silent", "-E", "-r", "--regexp-extended", "-s", "--separate", "-u", "--unbuffered", "-z", "--null-data":
                continue
            case "-e", "--expression":
                guard i < args.count else { return false }
                scripts.append(args[i]); i += 1
            default:
                if arg.hasPrefix("--expression=") { scripts.append(String(arg.dropFirst(13))); continue }
                if arg.hasPrefix("-") && arg != "-" {
                    // A cluster like `-nE`; `-i`, `-f` and anything unknown refuse.
                    guard arg.dropFirst().allSatisfy({ "nEsurz".contains($0) }) else { return false }
                    continue
                }
                if scripts.isEmpty && !files { scripts.append(arg); files = true } // the first word is the script
            }
        }
        return !scripts.isEmpty && scripts.allSatisfy(sedScript)
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

    // MARK: git, gh, docker

    /// Formatting and selection flags shared by git's diff, log and show. Left out on purpose: `--output` (writes a
    /// file), `--ext-diff` (runs a program), `--exec`.
    static let gitDiffFlags: Set<String> = [
        "-p", "-u", "--patch", "-s", "--no-patch", "--raw", "--patch-with-raw", "--stat", "--numstat", "--shortstat",
        "--dirstat", "--summary", "--name-only", "--name-status", "--check", "--full-index", "--binary", "--abbrev",
        "--color", "--no-color", "--color-words", "--color-moved", "--word-diff", "--word-diff-regex", "-w",
        "--ignore-all-space", "-b", "--ignore-space-change", "--ignore-blank-lines", "--ignore-space-at-eol",
        "--ignore-cr-at-eol", "--minimal", "--patience", "--histogram", "--diff-algorithm", "--unified", "-U",
        "--function-context", "-W", "--find-renames", "-M", "--find-copies", "-C", "--no-renames", "--relative",
        "--no-relative", "-R", "--text", "-a", "--exit-code", "--quiet", "--cached", "--staged", "--merge-base",
        "--no-index", "--no-ext-diff", "--no-textconv", "--src-prefix", "--dst-prefix", "--no-prefix", "-z",
        "--diff-filter", "-S", "-G", "--pickaxe-all", "--pickaxe-regex", "--compact-summary", "--submodule",
        "--ignore-submodules", "--line-prefix", "--ita-invisible-in-index", "-O", "--skip-to", "--rotate-to",
        "-l", "--break-rewrites", "-B", "-D", "--irreversible-delete", "--anchored", "--indent-heuristic",
        "--no-indent-heuristic", "--default-prefix", "--dd", "-m", "-c", "--cc", "--first-parent", "--merges",
        "--no-merges", "--remerge-diff",
    ]

    static let gitLogFlags: Set<String> = gitDiffFlags.union([
        "--oneline", "--graph", "--decorate", "--no-decorate", "--decorate-refs", "--decorate-refs-exclude", "--all",
        "--branches", "--tags", "--remotes", "--glob", "--exclude", "-n", "--max-count", "--skip", "--since", "--after",
        "--until", "--before", "--author", "--committer", "--grep", "--all-match", "--invert-grep", "-i",
        "--regexp-ignore-case", "-E", "--extended-regexp", "-F", "--fixed-strings", "-P", "--perl-regexp", "--format",
        "--pretty", "--date", "--reverse", "--follow", "--no-walk", "--topo-order", "--date-order",
        "--author-date-order", "--ancestry-path", "--simplify-by-decoration", "--full-history", "--left-right",
        "--cherry-pick", "--cherry-mark", "--cherry", "--boundary", "--source", "--use-mailmap", "--mailmap",
        "--abbrev-commit", "--no-abbrev-commit", "--parents", "--children", "--relative-date", "--show-signature",
        "--notes", "--no-notes", "--show-notes", "-L", "--max-parents", "--min-parents", "--walk-reflogs", "-g",
        "--expand-tabs", "--no-expand-tabs", "--encoding", "-t", "-r", "--root", "--show-linear-break", "--log-size",
        "--count", "--objects", "--in-commit-order", "--not", "--stdin", "-1", "-2", "-3", "-4", "-5", "-6", "-7", "-8", "-9",
    ])

    /// Flags for subcommands that only read. Positional words (revisions, paths) are allowed unless said otherwise.
    static let gitTables: [String: Set<String>] = [
        "status": ["-s", "--short", "-b", "--branch", "--porcelain", "--long", "-v", "--verbose", "-u", "-uno", "-unormal",
                   "-uall", "--untracked-files", "--ignored", "--ignore-submodules", "--column", "--no-column",
                   "--ahead-behind", "--no-ahead-behind", "--renames", "--no-renames", "--find-renames", "-z", "--show-stash"],
        "diff": gitDiffFlags,
        "log": gitLogFlags,
        "show": gitLogFlags,
        "shortlog": gitLogFlags.union(["-s", "--summary", "-e", "--email", "--group", "-c", "--committer", "-w"]),
        "blame": ["-L", "-l", "-t", "-s", "-e", "--show-email", "-w", "-M", "-C", "-p", "--porcelain", "--line-porcelain",
                  "--incremental", "-f", "--show-name", "-n", "--show-number", "-c", "--root", "--since", "--date",
                  "--abbrev", "--color-lines", "--color-by-age", "--ignore-rev", "--first-parent", "--reverse", "--progress",
                  "--no-progress", "-b", "--minimal"],
        "rev-parse": ["--abbrev-ref", "--symbolic-full-name", "--symbolic", "--short", "--verify", "-q", "--quiet",
                      "--show-toplevel", "--show-prefix", "--show-cdup", "--git-dir", "--git-common-dir", "--absolute-git-dir",
                      "--is-inside-work-tree", "--is-inside-git-dir", "--is-bare-repository", "--is-shallow-repository",
                      "--all", "--branches", "--tags", "--remotes", "--default", "--sq", "--not", "--show-object-format",
                      "--path-format", "--git-path", "--show-superproject-working-tree", "--local-env-vars", "--since", "--until"],
        "rev-list": gitLogFlags,
        "merge-base": ["--all", "--octopus", "--independent", "--is-ancestor", "--fork-point"],
        "describe": ["--tags", "--all", "--long", "--abbrev", "--always", "--exact-match", "--contains", "--candidates",
                     "--match", "--exclude", "--first-parent", "--dirty", "--broken"],
        "cat-file": ["-t", "-s", "-e", "-p", "--batch-check", "--batch", "--textconv", "--filters", "--follow-symlinks",
                     "--batch-all-objects", "--unordered", "--use-mailmap", "--buffer", "-Z"],
        "for-each-ref": ["--count", "--sort", "--format", "--color", "--shell", "--perl", "--python", "--tcl",
                         "--points-at", "--merged", "--no-merged", "--contains", "--no-contains", "--ignore-case",
                         "--omit-empty", "--exclude", "--include-root-refs"],
        "ls-files": ["-c", "--cached", "-d", "--deleted", "-m", "--modified", "-o", "--others", "-i", "--ignored", "-s",
                     "--stage", "-u", "--unmerged", "-k", "--killed", "-z", "--directory", "--no-empty-directory",
                     "--exclude-standard", "-x", "--exclude", "--error-unmatch", "--full-name", "--recurse-submodules",
                     "--abbrev", "--debug", "--eol", "--deduplicate", "-t", "-v", "-f", "--format", "--sparse"],
        "grep": ["-i", "--ignore-case", "-I", "-w", "--word-regexp", "-v", "--invert-match", "-n", "--line-number",
                 "--column", "-l", "--files-with-matches", "-L", "--files-without-match", "-c", "--count", "-h", "-H",
                 "--full-name", "-E", "--extended-regexp", "-G", "--basic-regexp", "-F", "--fixed-strings", "-P",
                 "--perl-regexp", "-e", "--and", "--or", "--not", "--all-match", "-q", "--quiet", "-A", "-B", "-C",
                 "--after-context", "--before-context", "--context", "-p", "--show-function", "-W", "--function-context",
                 "--cached", "--untracked", "--no-index", "--recurse-submodules", "--max-depth", "-r", "--recursive",
                 "--no-recursive", "-z", "--null", "-o", "--only-matching", "--break", "--heading", "--color",
                 "--no-color", "-a", "--text", "--threads", "-m", "--max-count", "--exclude-standard", "--no-exclude-standard"],
        "reflog": gitLogFlags,
        "remote": ["-v", "--verbose"],
        "tag": ["-l", "--list", "-n", "--sort", "--contains", "--no-contains", "--merged", "--no-merged", "--points-at",
                "--format", "--column", "--no-column", "-i", "--ignore-case", "--color"],
        "branch": ["-a", "--all", "-r", "--remotes", "-l", "--list", "-v", "-vv", "--verbose", "--show-current",
                   "--contains", "--no-contains", "--merged", "--no-merged", "--sort", "--format", "--points-at",
                   "--color", "--no-color", "--column", "--no-column", "-i", "--ignore-case", "--abbrev", "--no-abbrev"],
        "ls-remote": ["--heads", "--tags", "--branches", "--refs", "-q", "--quiet", "--exit-code", "--get-url", "--sort",
                      "--symref", "-h", "-t", "-b"],
    ]

    /// `git` flags that change what runs or where: none is allowed before the subcommand except `--no-pager`
    /// (Claude Code 2.1.319 refuses `git -C . status` too).
    static func git(_ args: [String]) -> String? {
        var args = args[...]
        while let first = args.first, first.hasPrefix("-") {
            if first == "--no-pager" || first == "-P" { args = args.dropFirst() }
            else { return nil }
        }
        guard let sub = args.first else { return nil }
        var rest = Array(args.dropFirst())
        var name = "git " + sub
        switch sub {
        case "stash":
            guard let verb = rest.first, ["list", "show"].contains(verb) else { return nil }
            rest.removeFirst()
            name += " " + verb
            return gitFlags(rest, gitLogFlags) ? name : nil
        case "worktree":
            guard rest.first == "list", rest.dropFirst().allSatisfy({ ["--porcelain", "-v", "--verbose", "-z"].contains($0) }) else { return nil }
            return name + " list"
        case "config":
            let reads: Set<String> = ["--get", "--get-all", "--get-regexp", "--list", "-l", "--get-urlmatch"]
            let scopes: Set<String> = ["--global", "--local", "--system", "--worktree", "--show-origin", "--show-scope",
                                       "--name-only", "-z", "--null", "--includes", "--no-includes", "--type", "--bool", "--int", "--path"]
            guard rest.contains(where: reads.contains),
                  rest.allSatisfy({ !$0.hasPrefix("-") || reads.contains($0) || scopes.contains(String($0.split(separator: "=")[0])) }),
                  !rest.contains(where: { $0.hasPrefix("--file") || $0 == "-f" || $0 == "--blob" })
            else { return nil }
            return name
        case "remote":
            if rest.isEmpty || rest.allSatisfy({ ["-v", "--verbose"].contains($0) }) { return name }
            if let verb = rest.first, ["show", "get-url"].contains(verb), rest.count >= 2,
               rest.dropFirst().allSatisfy({ !$0.hasPrefix("-") || ["-n", "--push", "--all"].contains($0) }) { return name + " " + verb }
            return nil
        case "reflog":
            if rest.first == "show" { rest.removeFirst() }
            else if let verb = rest.first, !verb.hasPrefix("-"), ["expire", "delete", "exists", "drop"].contains(verb) { return nil }
            return gitFlags(rest, gitLogFlags) ? name : nil
        case "branch", "tag":
            guard let table = gitTables[sub], gitFlags(rest, table) else { return nil }
            // A name without `--list` creates a branch or tag; values of these flags are revisions.
            let listing = rest.contains("-l") || rest.contains("--list")
            let takesValue: Set<String> = ["--contains", "--no-contains", "--merged", "--no-merged", "--points-at", "--sort", "--format"]
            var previous = ""
            for arg in rest {
                defer { previous = arg }
                if arg.hasPrefix("-") { continue }
                if takesValue.contains(previous) || listing { continue }
                if sub == "tag", previous == "-n" { continue }
                return nil
            }
            return name
        case "ls-remote":
            guard let table = gitTables[sub], gitFlags(rest, table), !rest.contains(where: { !$0.hasPrefix("-") }) else { return nil }
            return name
        default:
            guard let table = gitTables[sub], gitFlags(rest, table) else { return nil }
            return name
        }
    }

    /// Every flag is in `table`, by its name before `=` or, for a short flag with its value attached (`-n5`,
    /// `-U3`, `-uno`), by its first letter.
    static func gitFlags(_ args: [String], _ table: Set<String>) -> Bool {
        let refused = ["--output", "--ext-diff", "--exec", "--open-files-in-pager", "--upload-pack", "--server-option"]
        var afterDashes = false
        for arg in args {
            if afterDashes || !arg.hasPrefix("-") || arg == "-" { continue }
            if arg == "--" { afterDashes = true; continue }
            if refused.contains(where: { arg.hasPrefix($0) }) || arg.hasPrefix("-O") && arg.count > 2 { return false }
            let name = String(arg.split(separator: "=", maxSplits: 1)[0])
            if table.contains(name) { continue }
            if !arg.hasPrefix("--"), arg.count > 2, table.contains(String(arg.prefix(2))) {
                // `-n5` is `-n 5`; a cluster like `-pv` needs each letter listed.
                let rest = arg.dropFirst(2)
                if rest.allSatisfy(\.isNumber) || ["-U", "-M", "-C", "-B", "-u", "-n", "-L", "-S", "-G", "-O"].contains(String(arg.prefix(2))) { continue }
                if rest.allSatisfy({ table.contains("-" + String($0)) }) { continue }
            }
            if arg.range(of: #"^-\d+$"#, options: .regularExpression) != nil, table.contains("-n") { continue }
            return false
        }
        return true
    }

    /// gh subcommands that only read. Flags: anything but `--web` (opens a browser); `gh api` isn't here.
    static let ghReads: Set<String> = [
        "pr view", "pr list", "pr diff", "pr checks", "pr status", "issue view", "issue list", "issue status",
        "repo view", "run list", "run view", "auth status", "release list", "release view", "workflow list",
        "workflow view", "label list", "search repos", "search issues", "search prs", "search commits", "search code",
    ]

    static func gh(_ args: [String]) -> String? {
        guard args.count >= 2 else { return nil }
        let name = args[0] + " " + args[1]
        guard ghReads.contains(name), !args.contains(where: { ["-w", "--web"].contains($0) || $0.hasPrefix("--web=") }) else { return nil }
        // `run view --log` and the rest only print; `--exit-status`-like flags only change the exit code.
        return "gh " + name
    }

    static func docker(_ args: [String]) -> String? {
        guard let sub = args.first else { return nil }
        let table: Flags
        switch sub {
        case "logs": table = Flags(short: "ft", shortValues: "n", long: ["--follow", "--timestamps", "--details"],
                                   longValues: ["--since", "--until", "--tail"])
        case "inspect": table = Flags(short: "s", shortValues: "f", long: ["--size"], longValues: ["--format", "--type"])
        default: return nil
        }
        return table.allows(Array(args.dropFirst())) ? "docker " + sub : nil
    }
}
