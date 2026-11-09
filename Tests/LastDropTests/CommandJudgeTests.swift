import XCTest
@testable import LastDrop

final class CommandJudgeTests: XCTestCase {
    func testThePolicyFilesShipWithTheirLicence() throws {
        let directory = try XCTUnwrap(CommandJudge.policyDirectory())
        for file in ["policy_template.md", "policy.md", "LICENSE", "NOTICE"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path), file)
        }
        let notice = try String(contentsOf: directory.appendingPathComponent("NOTICE"), encoding: .utf8)
        XCTAssertTrue(notice.contains("github.com/openai/codex") && notice.contains("Apache"))
        let policy = try CommandJudge.policy(readOnly: false, directory: directory)
        XCTAssertFalse(policy.contains("{{"), "every template slot is filled")
        XCTAssertTrue(policy.contains("## Environment Profile"))
        XCTAssertTrue(policy.contains("## lastdrop"))
        XCTAssertFalse(policy.contains("called read-only"))
        XCTAssertTrue(try CommandJudge.policy(readOnly: true, directory: directory).contains("called read-only"))
        XCTAssertThrowsError(try CommandJudge.policy(readOnly: false, directory: URL(fileURLWithPath: "/nonexistent")))
    }

    func testThePromptHoldsTheTaskAndCallInputsOnly() {
        var context = CommandJudge.Context(instructions: "You review code.", requests: ["Fix the failing test."])
        context.record(tool: "view_file", input: ["AbsolutePath": "/w/a.swift", "toolSummary": "the agent's own words"])
        let prompt = CommandJudge.prompt(policy: "POLICY", context: context,
                                         action: ["tool": "run_command", "arguments": ["CommandLine": "swift test", "Cwd": "/w"]])
        XCTAssertTrue(prompt.hasPrefix("POLICY\n\n# Output"))
        XCTAssertTrue(prompt.contains(#"{"content":"You review code.","role":"developer"}"#))
        XCTAssertTrue(prompt.contains(#"{"content":"Fix the failing test.","role":"user"}"#))
        XCTAssertTrue(prompt.contains(#"view_file"#) && prompt.contains("/w/a.swift"))
        XCTAssertFalse(prompt.contains("the agent's own words"))
        XCTAssertTrue(prompt.contains(#"<planned_action>"# + "\n" + #"{"arguments":{"CommandLine":"swift test","Cwd":"/w"},"tool":"run_command"}"#), prompt)
        // Long fields are cut and marked.
        let long = CommandJudge.Context(requests: [String(repeating: "x", count: 10_000)])
        XCTAssertTrue(CommandJudge.prompt(policy: "", context: long, action: [:]).contains("<truncated />"))
    }

    func testContextKeepsTheLatestCalls() {
        var context = CommandJudge.Context()
        for i in 0..<50 { context.record(tool: "t\(i)", input: [:]) }
        XCTAssertEqual(context.calls.count, 40)
        XCTAssertEqual(context.calls.first?.tool, "t10")
    }

    func testOnlyAClearAllowAllows() {
        let allow = CommandJudge.parse(#"Thinking… {"risk_level": "low", "user_authorization": "high", "outcome": "allow", "rationale": "Runs tests."}"#)
        XCTAssertEqual(allow, .init(allow: true, risk: "low", authorization: "high", rationale: "Runs tests."))
        let deny = CommandJudge.parse("```json\n{\"risk_level\":\"critical\",\"user_authorization\":\"unknown\",\"outcome\":\"deny\",\"rationale\":\"Uploads a key.\"}\n```")
        XCTAssertFalse(deny.allow)
        XCTAssertEqual(deny.summary, "judge: critical risk, user authorization unknown — Uploads a key.")
        for text in ["", "I think this is fine.", #"{"outcome": "maybe"}"#, #"{"outcome": allow}"#] {
            let verdict = CommandJudge.parse(text)
            XCTAssertFalse(verdict.allow, text)
            XCTAssertNotNil(verdict.failure, text)
            XCTAssertTrue(verdict.summary.hasPrefix("judge failed: "), verdict.summary)
        }
    }

    func testAJudgeThatFailsOrHangsDenies() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lastdrop-judge-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func script(_ body: String) throws -> String {
            let path = folder.appendingPathComponent("agy-\(UUID().uuidString)")
            try ("#!/bin/zsh\n" + body).write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
            return path.path
        }
        let args = folder.appendingPathComponent("args").path
        let good = try script("printf '%s\\n' \"$@\" > \(args); pwd >> \(args); print '{\"risk_level\":\"low\",\"user_authorization\":\"high\",\"outcome\":\"allow\",\"rationale\":\"ok\"}'")
        let verdict = await CommandJudge.judge("PROMPT", executable: good)
        XCTAssertTrue(verdict.allow)
        let lines = try String(contentsOfFile: args, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(lines.prefix(12)), ["-p", "PROMPT", "--mode", "plan", "--model", "gemini-3.8-flash", "--effort", "low",
                                                  "--disable-slash-commands", "--print-timeout", "120s", lines[11]])
        XCTAssertTrue(lines[11].contains("lastdrop-judge-"), "runs from an empty folder of its own")
        let failing = try script("print -u2 'authentication required'; exit 3")
        let failed = await CommandJudge.judge("PROMPT", executable: failing)
        XCTAssertFalse(failed.allow)
        XCTAssertEqual(failed.summary, "judge failed: agy exited with status 3 (authentication required)")
        let missing = await CommandJudge.judge("PROMPT", executable: folder.appendingPathComponent("none").path)
        XCTAssertFalse(missing.allow)
        XCTAssertEqual(missing.failure, "could not start agy")
    }
}

final class CommandJudgeSettingTests: XCTestCase {
    func testTheJudgeRunsTheConfiguredModelAndEffort() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lastdrop-judge-setting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let args = folder.appendingPathComponent("args").path
        let path = folder.appendingPathComponent("agy").path
        try ("#!/bin/zsh\nprintf '%s\\n' \"$@\" > \(args); print '{\"outcome\":\"allow\",\"risk_level\":\"low\",\"user_authorization\":\"high\",\"rationale\":\"ok\"}'")
            .write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        _ = await CommandJudge.judge("P", executable: path, with: AgentJudge(model: "gemini-4-argon", effort: "high"))
        var lines = try String(contentsOfFile: args, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(lines[4...7]), ["--model", "gemini-4-argon", "--effort", "high"])
        _ = await CommandJudge.judge("P", executable: path, with: AgentJudge(model: "gemini-4-argon"))
        lines = try String(contentsOfFile: args, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[4...6], ["--model", "gemini-4-argon", "--disable-slash-commands"], "no effort, no --effort")
        // A model agy won't run is named as unavailable, never replaced.
        try "#!/bin/zsh\nprint -u2 'Unknown model ID: nope'; exit 1".write(toFile: path, atomically: true, encoding: .utf8)
        let missing = await CommandJudge.judge("P", executable: path, with: AgentJudge(model: "nope", effort: "low"))
        XCTAssertFalse(missing.allow)
        XCTAssertTrue(missing.failure?.hasPrefix("the command judge nope · low is not available") ?? false, missing.summary)
    }

    func testTheJudgeIsCheckedAgainstTheSessionsModels() {
        let offered = [AgentModel(id: "gemini-3.8-flash", name: "Flash", efforts: ["low", "high"], defaultEffort: nil)]
        XCTAssertNil(CommandJudge.problem(AgentJudge(model: "gemini-3.8-flash", effort: "low"), offered: offered))
        XCTAssertNil(CommandJudge.problem(AgentJudge(model: "gemini-3.8-flash"), offered: offered))
        XCTAssertNotNil(CommandJudge.problem(AgentJudge(model: "gemini-3.8-flash", effort: "max"), offered: offered))
        XCTAssertNotNil(CommandJudge.problem(AgentJudge(model: "gone"), offered: offered))
        XCTAssertNil(CommandJudge.problem(AgentJudge(model: "gone"), offered: []), "an empty list can't say no")
        XCTAssertEqual(CommandJudge.defaultJudge, AgentJudge(model: "gemini-3.8-flash", effort: "low"))
    }
}
