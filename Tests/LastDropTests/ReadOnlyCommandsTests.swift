import XCTest
@testable import LastDrop

final class ReadOnlyCommandsTests: XCTestCase {
    private func allowed(_ commands: [String], file: StaticString = #filePath, line: UInt = #line) {
        for command in commands { XCTAssertNotNil(ReadOnlyCommands.check(command), command, file: file, line: line) }
    }

    private func refused(_ commands: [String], file: StaticString = #filePath, line: UInt = #line) {
        for command in commands { XCTAssertNil(ReadOnlyCommands.check(command), command, file: file, line: line) }
    }

    func testPlainAndSpecialCommandsRead() {
        allowed(["ls", "ls -la src", "cat README.md", "head -n 20 a.txt", "tail -5 log.txt", "wc -l *.swift", "pwd",
                 "whoami", "du -sh .", "df -h", "diff a b", "stat a", "cd src", "echo hello", #"echo 'a b' "c""#,
                 #"printf '%s\n' hi"#, "find . -name '*.swift' -type f", "uniq -c", "sort a.txt | uniq", "jq '.name' package.json",
                 "test -f a.txt", "[ -d src ]", "node --version", "docker ps", "date", "date +%Y-%m-%d",
                 "which swift", "file a.png", "sha256sum a", "tree -L 2", "ps aux", "true", "tput cols"])
    }

    func testFlagTablesAllowListedFlagsOnly() {
        allowed(["grep -rn foo src", "grep -E 'a|b' file", "grep -A3 -i foo f", "rg -n --hidden foo", "rg -t swift foo",
                 "sort -rn", "sort -k 2,2n -t , f", "sed -n '1,20p' f", "sed -n -e '/foo/p' f", "sed 's/a/b/g' f",
                 "base64 -d", "fd -e swift", "xargs grep foo", "xargs -0 grep -l foo", "hostname"])
        refused(["grep --frobnicate foo", "rg --pre ./x foo", "fd -x rm", "fd --exec rm", "sort -o out.txt in.txt",
                 "sort --output=out in", "sed -i 's/a/b/' f", "sed -i.bak 's/a/b/' f", "sed 's/a/b/w out' f",
                 "sed 'e date' f", "sed '1w out' f", "sed -f script.sed f", "base64 -o out in", "tree -o out",
                 "xargs rm", "xargs -0 rm", "hostname evil", "date 010100002030", "date -s 2030-01-01", "tput reset",
                 "uniq in out", "sort -t, f", "git log -n5", "git cat-file --textconv HEAD:a", "git cat-file --filters HEAD:a", "ss -K", "ps --frobnicate", "lsof -+L1x", "gh pr list --web", "gh pr view 1 -R host.example/o/r", "git log --format=%G?", "git log --pretty=myalias", "tput reset", "uniq a.txt", "git -C .. status", "jq -f prog.jq", "jq 'env' f", "jq --rawfile a b ."])
    }

    func testGitReadsOnly() {
        allowed(["git status", "git status -sb", "git status --porcelain", "git diff --stat HEAD~3",
                 "git diff --cached -- a.swift", "git log --oneline -20", "git log -n 5 --format=%H", "git show HEAD:a.txt",
                 "git branch", "git branch -a -v", "git branch --list 'feat/*'", "git branch --contains HEAD", "git tag",
                 "git tag -l 'v*'", "git rev-parse --abbrev-ref HEAD", "git blame -L 1,20 a.swift", "git remote -v",
                 "git stash list", "git config --get user.name", "git worktree list", "git ls-files", "git merge-base main HEAD",
                 "git --no-pager log -1"])
        refused(["git branch -D main", "git branch -d x", "git branch newname", "git branch -m a b", "git tag v1",
                 "git tag -d v1", "git checkout main", "git commit -m x", "git push", "git stash", "git stash pop",
                 "git config user.name x", "git diff --output=out", "git diff --ext-diff", "git log --output=x",
                 "git -c core.pager=sh log", "git --git-dir=/x log", "git grep -O foo", "git grep --open-files-in-pager foo",
                 "git reflog expire --all", "git remote add x y", "git ls-remote origin", "git worktree add x"])
    }

    func testGhAndDockerReadsOnly() {
        allowed(["gh pr view 12", "gh pr list --state open", "gh pr checks", "gh run view 1 --log", "docker logs -n 50 web",
                 "docker inspect -f '{{.State}}' web"])
        refused(["gh pr merge 12", "gh api repos/x", "gh pr view 12 --web", "docker run x", "docker -H tcp://x ps",
                 "docker logs --details=x"])
    }

    func testDangerousShapesAreNeverReadOnly() {
        refused([#"find . -exec rm {} \;"#, "find . -delete", "find . -fprint out", #"find . -execdir sh -c x \;"#,
                 "echo $HOME", "echo `id`", "echo $(id)", "cat a > b", "cat a >> b", "ls > out", "cat < /etc/passwd",
                 "(ls)", "{ ls; }", "ls && rm -rf x", "ls; rm x", "cat a | sh", "for f in *; do cat $f; done",
                 "if true; then ls; fi", "FOO=1 ls", "env", "rm -rf x", "curl https://x", "bash -c ls", "python3 -c 1",
                 "echo hi #comment", #"cat a\ b"#, "printf -v x hi", "printf '%d' abc", #"printf '\x41'"#, "pwd -P",
                 "cd a b", "ls &", "echo 'unterminated", "test -v x", "[[ a =~ b ]]", "sed -n '$p' f", "grep 'x$' f"])
    }

    func testCompoundCommandsNeedEveryPartReadOnly() {
        XCTAssertEqual(ReadOnlyCommands.check("git status && ls -la | head -5"), ["git status", "ls", "head"])
        XCTAssertEqual(ReadOnlyCommands.check("cd src; git log -1 2>&1"), ["cd", "git log"])
        XCTAssertEqual(ReadOnlyCommands.check("ls missing 2>/dev/null || echo none"), ["ls", "echo"])
        XCTAssertEqual(ReadOnlyCommands.check("timeout 5 git status"), ["git status"])
        XCTAssertNil(ReadOnlyCommands.check("git status && git push"))
        XCTAssertNil(ReadOnlyCommands.check("ls | xargs rm"))
        XCTAssertNil(ReadOnlyCommands.check("grep -l foo * | xargs sed -i s/a/b/"))
    }
}

/// lastdrop's matcher against Claude Code 2.1.319's own flag tables: every listed flag is read-only, and no flag
/// outside a command's table is.
final class ReadOnlyTablesTests: XCTestCase {
    /// A line that uses `flag` on `command`, with a value of its kind and whatever the command needs around it.
    static func line(_ command: String, _ flag: String, _ kind: ReadOnlyCommands.Value?) -> String {
        let value: String
        switch kind {
        case .some(.number): value = " 5"
        case .some(.string): value = " x"
        case .some(.char): value = " x"
        case .some(.braces): value = " {}"
        case .some(.eof): value = " EOF"
        case .some(.none), nil: value = ""
        }
        let quoted = flag.contains("?") ? "'\(flag)'" : flag
        // git takes `--format`/`--pretty` as a format, not a name from config (Claude Code refuses that too).
        if ["--format", "--pretty"].contains(flag), command.hasPrefix("git") { return "\(command) \(flag) %h" }
        switch command {
        case "sed": return "sed \(quoted)\(value) p"
        case "git remote show": return "git remote show -n \(quoted)\(value) origin"
        case "test": return "test \(quoted)\(value)"
        default: return "\(command) \(quoted)\(value)"
        }
    }

    func testEveryFlagClaudeCodeAllowsIsReadOnly() {
        var refused: [String] = []
        var count = 0
        for (command, table) in ReadOnlyCommands.flagTables {
            for (flag, kind) in table where flag != "--" {
                count += 1
                let line = Self.line(command, flag, kind)
                if ReadOnlyCommands.check(line) == nil { refused.append(line) }
            }
        }
        print("TABLES accepted \(count - refused.count) of \(count)")
        // Claude Code's own extra checks refuse the first two too (the value reads as a date to set, or a branch
        // name). lastdrop is stricter on an unquoted `{}`, which its parser takes for a group: `-I '{}'` passes.
        XCTAssertEqual(refused.sorted(), ["date --iso-8601 x", "git branch --abbrev 5", "xargs -I {}"])
        XCTAssertNotNil(ReadOnlyCommands.check("xargs -I '{}' grep foo '{}'"))
    }

    func testNoFlagOutsideClaudeCodesTablesIsReadOnly() {
        let tables = ReadOnlyCommands.flagTables
        let longs = Set(tables.values.flatMap(\.keys).filter { $0.hasPrefix("--") && $0 != "--" })
        let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".map { "-" + String($0) }
        var accepted: [String] = []
        var count = 0
        // `test` operators are checked by lastdrop's own `test` rule, which only refuses `-v` and `-R`.
        for (command, table) in tables where command != "test" {
            // Claude Code takes `-<digits>` on every git command (`git log -20`).
            for flag in longs.union(letters) where table[flag] == nil && !(command.hasPrefix("git ") && flag.dropFirst().allSatisfy(\.isNumber)) {
                count += 1
                for line in [Self.line(command, flag, nil), Self.line(command, flag, .string)] where ReadOnlyCommands.check(line) != nil {
                    accepted.append(line)
                }
            }
        }
        print("TABLES refused \(count - Set(accepted.map { String($0.split(separator: " ").dropLast().joined()) }).count) of \(count) flags outside the tables")
        XCTAssertEqual(accepted.sorted(), [], "Claude Code doesn't allow these")
    }
}
