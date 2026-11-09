import XCTest
@testable import LastDrop

final class PermissionRulesTests: LastDropTestCase {
    private func rules(allow: [String] = [], deny: [String] = [], ask: [String] = []) -> PermissionRules {
        var rules = PermissionRules()
        rules.add(["allow": allow, "deny": deny, "ask": ask])
        return rules
    }

    func testOnlyBashRulesAreKeptAndParameterRulesSkipped() {
        let r = rules(allow: ["Bash", "Bash(npm test:*)", "Read(./x)", "WebFetch(domain:a.b)", "Bash(run_in_background:true)", "Bash()"])
        XCTAssertEqual(r.allow, ["*", "npm test:*"])
    }

    /// The rows of Claude Code's "Wildcard patterns" table.
    func testWildcardsMatchLikeClaudeCode() {
        let cases: [(String, [String], [String])] = [
            ("npm run build", ["npm run build"], ["npm run build --watch"]),
            ("npm run *", ["npm run build", "npm run test --watch", "npm run"], ["npm install"]),
            ("git log * main", ["git log --oneline main", "git log -5 main"], ["git log main", "git push origin main"]),
            ("git * main", ["git merge main", "git push origin main"], ["git log"]),
            ("* --version", ["node --version"], ["node -v"]),
            ("ls *", ["ls -la", "ls"], ["lsof"]),
            ("ls*", ["ls -la", "lsof"], []),
            ("* --help *", ["npm --help x"], ["npm --help"]),
            ("ls:*", ["ls -la", "ls"], ["lsof"]),
            ("git:* push", [], ["git push", "git x push"]),
            ("*", ["anything at all"], []),
        ]
        for (rule, yes, no) in cases {
            for command in yes { XCTAssertTrue(PermissionRules.matches(rule, command), "\(rule) should match \(command)") }
            for command in no { XCTAssertFalse(PermissionRules.matches(rule, command), "\(rule) should not match \(command)") }
        }
    }

    func testEveryPartOfACompoundCommandMustBeAllowed() {
        let r = rules(allow: ["Bash(git status)", "Bash(npm test *)"])
        XCTAssertEqual(r.check("git status && npm test"), .allow(["Bash(git status)", "Bash(npm test *)"]))
        XCTAssertEqual(r.check("git status; npm test --watch | npm test"), .allow(["Bash(git status)", "Bash(npm test *)"]))
        XCTAssertEqual(r.check("git status && rm -rf x"), PermissionRules.Verdict.none)
        XCTAssertEqual(r.check("npm test &&"), PermissionRules.Verdict.none, "a dangling operator is unparseable")
        XCTAssertEqual(r.check("git status & curl x"), PermissionRules.Verdict.none)
        XCTAssertEqual(r.check("echo 'git status && npm test'"), PermissionRules.Verdict.none)
        // Separators inside quotes don't split.
        XCTAssertEqual(rules(allow: ["Bash(echo *)"]).check("echo 'a && b; c'"), .allow(["Bash(echo *)"]))
    }

    func testAllowNeverCoversSubstitutionsRedirectsOrControlFlow() {
        let r = rules(allow: ["Bash(echo *)", "Bash(git status)", "Bash(cat *)"])
        for command in ["echo $(rm -rf x)", "echo `whoami`", "echo \"$(id)\"", "(git status)", "{ git status; }", "echo x > out.txt",
                        "cat < /etc/passwd", "cat <<EOF\nx\nEOF", "for f in a; do echo $f; done", "if git status; then echo y; fi",
                        "FOO=1 echo x", "echo 'unterminated"] {
            XCTAssertEqual(r.check(command), PermissionRules.Verdict.none, command)
        }
        XCTAssertEqual(r.check("echo x 2>&1"), .allow(["Bash(echo *)"]))
        XCTAssertEqual(r.check("echo x >/dev/null 2>/dev/null"), .allow(["Bash(echo *)"]))
        XCTAssertEqual(r.check("echo 'a > b'"), .allow(["Bash(echo *)"]))
    }

    func testDenyAndAskMatchAnyPartIncludingNestedOnes() {
        let r = rules(allow: ["Bash"], deny: ["Bash(rm *)"], ask: ["Bash(git push *)"])
        XCTAssertEqual(r.check("rm -rf build"), .deny("Bash(rm *)"))
        XCTAssertEqual(r.check("cd /tmp && rm -rf build"), .deny("Bash(rm *)"))
        XCTAssertEqual(r.check("echo \"$(rm -rf x)\""), .deny("Bash(rm *)"))
        XCTAssertEqual(r.check("for f in a; do rm $f; done"), .deny("Bash(rm *)"))
        XCTAssertEqual(r.check("FOO=bar rm -rf tmp/"), .deny("Bash(rm *)"))
        XCTAssertEqual(r.check("timeout 30 rm x"), .deny("Bash(rm *)"))
        XCTAssertEqual(r.check("git status; git push origin main"), .ask("Bash(git push *)"))
        XCTAssertEqual(r.check("ls -la"), .allow(["Bash(*)"]))
        // Deny wins over allow, whatever the order of files.
        XCTAssertEqual(rules(allow: ["Bash(rm -rf build)"], deny: ["Bash(rm *)"]).check("rm -rf build"), .deny("Bash(rm *)"))
    }

    func testWrappersAreStrippedAndExecWrappersNeedAnExactRule() {
        let r = rules(allow: ["Bash(npm test *)", "Bash(grep *)", "Bash(find *)", "Bash(watch *)", "Bash(find build -type f -delete)"])
        XCTAssertEqual(r.check("timeout 30 npm test"), .allow(["Bash(npm test *)"]))
        XCTAssertEqual(r.check("nice -n 5 nohup npm test --ci"), .allow(["Bash(npm test *)"]))
        XCTAssertEqual(r.check("xargs grep pattern"), .allow(["Bash(grep *)"]))
        XCTAssertEqual(r.check("xargs -n1 grep pattern"), PermissionRules.Verdict.none)
        XCTAssertEqual(r.check("find . -name x"), .allow(["Bash(find *)"]))
        XCTAssertEqual(r.check("find . -name x -delete"), PermissionRules.Verdict.none)
        XCTAssertEqual(r.check("find . -exec rm {} ;"), PermissionRules.Verdict.none)
        XCTAssertEqual(r.check("find build -type f -delete"), .allow(["Bash(find build -type f -delete)"]))
        XCTAssertEqual(r.check("watch ls"), PermissionRules.Verdict.none)
        XCTAssertEqual(r.check("command -v npm"), PermissionRules.Verdict.none)
    }

    func testLoadsUserAndProjectSettings() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("lastdrop-rules-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appendingPathComponent("repo/sub")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("repo/.git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("repo/.claude"), withIntermediateDirectories: true)
        func write(_ path: String, _ object: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: object).write(to: home.appendingPathComponent(path))
        }
        try write(".claude/settings.json", ["permissions": ["allow": ["Bash(git status)"], "deny": ["Bash(rm *)"]]])
        try write("repo/sub/.claude/settings.json", ["permissions": ["allow": ["Bash(npm test *)"]]])
        try write("repo/.claude/settings.local.json", ["permissions": ["ask": ["Bash(git push *)"], "allow": ["Read(x)"]]])
        let rules = PermissionRules.load(cwd: project.path, environment: [:], home: home.path)
        XCTAssertEqual(rules.allow, ["git status", "npm test *"])
        XCTAssertEqual(rules.deny, ["rm *"])
        XCTAssertEqual(rules.ask, ["git push *"])
        // An agent's worktree also reads the main checkout's untracked local settings.
        let worktree = home.appendingPathComponent("repo/.claude/worktrees/agent-x")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(home.path)/repo/.git/worktrees/agent-x\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertEqual(PermissionRules.load(cwd: worktree.path, environment: [:], home: home.path).ask, ["git push *"])
        // CLAUDE_CONFIG_DIR replaces ~/.claude for user settings.
        let other = PermissionRules.load(cwd: "/nonexistent", environment: ["CLAUDE_CONFIG_DIR": home.appendingPathComponent("repo/.claude").path], home: home.path)
        XCTAssertEqual(other.allow, [])
    }
}
