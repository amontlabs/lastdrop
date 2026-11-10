import Foundation

/// A non-main account's Claude Code profile: `~/.claude` seen through links, with a `.claude.json` of its own.
///
/// Claude Code keeps its global state in `<CLAUDE_CONFIG_DIR or home>/.claude.json`, and part of that state
/// belongs to the signed-in account (who it is, the answers Anthropic gave it: usage, model access, feature
/// flags). When every account's sessions share `~/.claude.json`, each one finds the other's answers, throws them
/// away and asks again, which gets the account rate limited on the usage endpoint. No setting moves that one
/// file, so an account runs with `CLAUDE_CONFIG_DIR` naming a folder where everything is `~/.claude` (links)
/// except `.claude.json`. That file is `~/.claude.json` with the account's own keys swapped in, rebuilt each
/// time a session starts: MCP servers, project trust and every key lastdrop doesn't know come from Main, so
/// Main's file is never written and stays the one place to change them.
enum ClaudeProfile {
    /// Tests point `~/.claude` elsewhere.
    nonisolated(unsafe) static var sharedOverride: String?

    static var shared: String { sharedOverride ?? NSHomeDirectory() + "/.claude" }

    /// The profile of the account whose sign-in folder is `folder` (`~/.claude-accounts/<name>/profile`). The
    /// sign-in folder itself is left as it is: its keychain item is named after its path.
    static func directory(folder: String) -> String { folder + "/profile" }

    static func configFile(folder: String) -> String { directory(folder: folder) + "/.claude.json" }

    // MARK: What belongs to the account

    /// Keys Claude Code itself clears when signing out (2.1.321), and other answers about the signed-in account.
    static let ownKeys: Set<String> = [
        "oauthAccount", "managedSettingsNoticeSeenOrg", "additionalModelOptionsAnsweredAt", "artifactRosterDenied",
        "lastSeenOrgDefaultUpdatedAt", "startupPrefetchedAt",
        "userID", "machineID", "claudeCodeFirstTokenDate", "penguinModeOrgEnabled", "claudeAiMcpEverConnected",
        "hasAvailableSubscription", "hasAvailableMaxSubscription", "claudeMaxTier", "recommendedSubscription",
        "isQualifiedForDataSharing", "promoCreditCheck", "orgSurveyCheck",
        "fable51OrgPickMoveDone", "fable51OrgPickMoveWaitingSince",
    ]

    /// The account's own: the keys above and every cache (`cachedUsageUtilization`, `modelAccessCache`,
    /// `cachedGrowthBookFeatures`, `clientDataCacheSlots`…). A cache kept apart costs a request at worst; a cache
    /// shared between accounts is the fault this fixes. Any other key, known or not, is shared.
    static func isOwn(_ key: String) -> Bool { ownKeys.contains(key) || key.lowercased().contains("cache") }

    /// Main's config with the account's own keys in place of Main's.
    static func merged(main: [String: Any], own: [String: Any]) -> [String: Any] {
        main.filter { !isOwn($0.key) }.merging(own.filter { isOwn($0.key) }) { _, own in own }
    }

    /// Where the account's own keys are read: the profile, which its sessions keep current, unless the folder
    /// has since been signed in to another account (or the profile is new), and then the folder's.
    static func ownState(profile: [String: Any]?, folder: [String: Any]?) -> [String: Any] {
        func uuid(_ config: [String: Any]?) -> String? { config?.dict("oauthAccount")?.string("accountUuid") }
        guard let profile, let signedIn = uuid(profile) else { return folder ?? profile ?? [:] }
        if let now = uuid(folder), now != signedIn { return folder ?? [:] }
        return profile
    }

    // MARK: Preparing

    /// Brings the account's profile up to date and returns it, for `CLAUDE_CONFIG_DIR`. Nil when there is none
    /// to use (Main's config can't be read and no profile was made before): the session then runs in `~/.claude`.
    static func prepare(folder: String) -> String? {
        let dir = directory(folder: folder)
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder) else { return nil }   // no sign-in folder: no account to run as
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            link(into: dir)
            try sync(folder: folder)
        } catch {
            SubagentLog.write("the profile at \(dir) wasn't brought up to date: \(error.localizedDescription)")
        }
        return fm.fileExists(atPath: dir + "/.claude.json") ? dir : nil
    }

    /// The files of `~/.claude` a profile shares besides its folders: the ones the user writes, which includes
    /// every Markdown file (`CLAUDE.md` and the files it imports by a relative path). Claude Code's own
    /// top-level files (markers, status, small caches) stay each profile's.
    static let sharedFiles: Set<String> = ["settings.json", "settings.local.json", "keybindings.json", "history.jsonl"]
    static func isShared(file name: String) -> Bool { sharedFiles.contains(name) || name.hasSuffix(".md") }
    /// Folders that go with `.claude.json`: its backups.
    static let ownFolders: Set<String> = ["backups"]

    /// Links what `~/.claude` holds and the profile doesn't have yet. Nothing already there is touched.
    static func link(into dir: String) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: shared)) ?? [] {
            let source = shared + "/" + name, target = dir + "/" + name
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: source, isDirectory: &isDirectory),
                  isDirectory.boolValue ? !ownFolders.contains(name) : isShared(file: name),
                  (try? fm.attributesOfItem(atPath: target)) == nil else { continue }
            try? fm.createSymbolicLink(atPath: target, withDestinationPath: source)
        }
    }

    /// Rewrites the profile's `.claude.json` from Main's and the account's own keys, under Claude Code's own
    /// config lock so a running session's save and this one never cross. Skipped while Main's config can't be
    /// read or the lock is held: the next start does it.
    static func sync(folder: String) throws {
        let file = configFile(folder: folder)
        guard let main = read(ClaudeProvider.sharedConfig) else { return }
        try locked(file) {
            let profile = read(file)
            let config = merged(main: main, own: ownState(profile: profile, folder: read(folder + "/.claude.json")))
            // Nothing new, however Claude Code last laid the file out: running sessions aren't made to re-read it.
            if let profile, NSDictionary(dictionary: profile).isEqual(to: config) { return }
            let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            let temp = file + ".tmp.lastdrop.\(ProcessInfo.processInfo.processIdentifier)"
            guard FileManager.default.createFile(atPath: temp, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            guard rename(temp, file) == 0 else {
                try? FileManager.default.removeItem(atPath: temp)
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        }
    }

    private static func read(_ path: String) -> [String: Any]? {
        FileManager.default.contents(atPath: path).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// Claude Code saves its config while holding `<file>.lock`, a folder (proper-lockfile): making it is taking
    /// the lock. Waits a moment for a save in progress, then gives up without running `body`.
    static func locked(_ file: String, _ body: () throws -> Void) throws {
        let lock = file + ".lock"
        var tries = 0
        while mkdir(lock, 0o700) != 0 {
            guard errno == EEXIST, tries < 20 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            tries += 1
            usleep(25_000)
        }
        defer { rmdir(lock) }
        try body()
    }
}
