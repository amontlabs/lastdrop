import AppKit
import Foundation

/// Signing an account in: Claude Code does it itself, in the account's own folder, from the browser or in Terminal.
enum ClaudeSignIn {
    /// What a new account's terminal sign-in shares with `~/.claude`: everything but the sign-in itself.
    static let sharedItems = ["settings.json", "settings.local.json", "CLAUDE.md", "skills", "agents", "commands",
                              "hooks", "plugins", "output-styles"]

    /// Prepares the account's Claude Code folder (links to the shared items in `~/.claude`) and opens
    /// Terminal on `claude` there, where Claude Code signs in itself.
    static func openTerminalSignIn(_ account: ClaudeAccount, name: String) throws {
        try prepareFolder(account)
        let script = LastDropPaths.support.appendingPathComponent("sign-in-\(account.id).command")
        LastDropPaths.ensure(LastDropPaths.support)
        let export = account.cliConfigDir.map { "export CLAUDE_CONFIG_DIR=\(shellQuote($0))\n" } ?? ""
        try """
        #!/bin/zsh -l
        \(export)echo "Claude Code for \(name): sign in with the same account as its Claude window."
        echo "If it doesn't ask, type /login. lastdrop reads this sign-in to show the account's usage."
        exec claude
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
    }

    /// Creates the account's Claude Code folder with links to the shared items in `~/.claude`.
    static func prepareFolder(_ account: ClaudeAccount) throws {
        let fm = FileManager.default
        if let dir = account.cliConfigDir {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let shared = NSHomeDirectory() + "/.claude"
            for item in sharedItems {
                let source = shared + "/" + item, target = dir + "/" + item
                guard fm.fileExists(atPath: source),
                      (try? fm.attributesOfItem(atPath: target)) == nil else { continue }   // keep anything already there
                try fm.createSymbolicLink(atPath: target, withDestinationPath: source)
            }
        }
    }

    /// Signs the account in through `claude auth login`, which opens the browser and returns once the sign-in
    /// lands. Cancelling the task stops it.
    static func browserSignIn(_ account: ClaudeAccount) async throws {
        try prepareFolder(account)
        guard let claude = SubagentRunner.executable() else { throw ProviderError.message("Claude Code (`claude`) was not found on this Mac.") }
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") }
        if let dir = account.cliConfigDir { environment["CLAUDE_CONFIG_DIR"] = dir }
        try await CLILogin.run(claude, ["auth", "login"], environment: environment)
        guard ClaudeProvider.signedInAccount(configDir: account.cliConfigDir).uuid != nil else {
            throw ProviderError.message("The sign-in didn't finish. Try again.")
        }
    }

    /// Claude Code renews an account's sign-in when it starts; lastdrop only reads it. So when an account's
    /// sign-in has expired (unused for a while), lastdrop starts Claude Code on it with no prompt, which costs
    /// no usage, and waits for the renewed sign-in to land in the keychain. Watching the keychain asks Anthropic
    /// nothing; the usage is then read once. Nil when that didn't renew it, or the usage still can't be read.
    static func renew(_ account: ClaudeAccount, lean: Bool = false) async -> UsageSnapshot? {
        guard !account.isMain, let claude = SubagentRunner.executable() else { return nil }
        SubagentLog.write("renewing the \(account.id) sign-in")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
        // The sign-in is renewed where it lives (and its refresh lock), so this one runs in the account's folder.
        var environment = SubagentRunner.environment(for: account, from: ProcessInfo.processInfo.environment)
        environment.removeValue(forKey: "CLAUDE_SECURESTORAGE_CONFIG_DIR")
        if let dir = account.cliConfigDir { environment["CLAUDE_CONFIG_DIR"] = dir }
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: LastDropPaths.helperDirectory)
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        defer { try? input.fileHandleForWriting.close() }   // no prompt: it exits by itself
        var renewed = false
        for _ in 0..<15 {
            try? await Task.sleep(for: .seconds(2))
            let running = process.isRunning   // before the read: a sign-in written as it exits still counts
            renewed = isSignedIn(ClaudeProvider.storedCredentials(configDir: account.cliConfigDir))
            if renewed || !running { break }
        }
        guard renewed else { return nil }
        var provider = ClaudeProvider(configDir: account.cliConfigDir)
        provider.lean = lean
        return try? await provider.fetch()
    }

    /// True when the stored sign-in (Claude Code's credentials blob) holds a token that hasn't expired.
    static func isSignedIn(_ raw: String?, now: Date = .now) -> Bool {
        raw.flatMap(ClaudeProvider.credentials(from:))?.isUsable(now: now) ?? false
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
