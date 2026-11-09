import Foundation

/// Points T3 Code's Claude provider at the thread wrapper (`ThreadLauncher.wrapperPath`), and back.
///
/// T3 keeps provider settings in `~/.t3/userdata/settings.json`, under `providerInstances.claudeAgent.config.binaryPath`
/// (read in T3 0.1.7: `serverSettings.ts`). The server watches that file and rebuilds its provider instances when it
/// changes, so no restart is needed; a thread already running keeps its Claude until T3 starts it again. T3 writes the
/// file only when the user changes a setting, in whole and atomically, so this edits it the same way: read, change
/// the one key, write beside it, rename. Every other key stays as it was. A file that doesn't parse is never touched,
/// because T3 leaves such a file for its user to repair. An admin's managed policy is not used on purpose: it would
/// lock the setting in T3's own screen.
enum T3Settings {
    enum State: Equatable, Sendable {
        /// Neither the app nor its data folder is here.
        case notInstalled
        /// T3's Claude provider runs `claude` itself.
        case off
        /// T3's Claude provider runs the wrapper.
        case on
        /// The user set a binary path of their own; turning on needs their say-so.
        case elsewhere(String)
        /// `settings.json` is there but isn't valid JSON, so it is left alone.
        case unreadable
    }

    /// Tests point these at folders of their own, never the real `~/.t3`.
    nonisolated(unsafe) static var userdataOverride: URL?
    nonisolated(unsafe) static var appOverride: URL?
    nonisolated(unsafe) static var backupOverride: URL?

    static var userdata: URL { userdataOverride ?? URL(fileURLWithPath: NSHomeDirectory() + "/.t3/userdata", isDirectory: true) }
    static var settingsFile: URL { userdata.appendingPathComponent("settings.json") }
    static var app: URL { appOverride ?? URL(fileURLWithPath: "/Applications/T3 Code (Beta).app") }
    /// The value the user had before, so turning off can put it back.
    static var backupFile: URL { backupOverride ?? LastDropPaths.support.appendingPathComponent("t3-binary-path.json") }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: app.path) || FileManager.default.fileExists(atPath: userdata.path)
    }

    /// T3's provider instance for Claude Code (`defaultInstanceIdForDriver`: the driver's own name).
    private static let instance = "claudeAgent"

    // MARK: Reading

    static func state(wrapper: String = ThreadLauncher.wrapperPath.path) -> State {
        guard isInstalled else { return .notInstalled }
        guard let root = read() else { return .unreadable }
        switch binaryPath(in: root) {
        case nil, "": return .off
        case wrapper?: return .on
        case let other?: return .elsewhere(other)
        }
    }

    /// The parsed file; an empty one when there is none (T3 hasn't saved a setting yet), nil when it is broken.
    private static func read() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsFile.resolvingSymlinksInPath()) else {
            return FileManager.default.fileExists(atPath: settingsFile.path) ? nil : [:]
        }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x09 || $0 == 0x0D }) { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func binaryPath(in root: [String: Any]) -> String? {
        let instances = root["providerInstances"] as? [String: Any]
        let config = (instances?[instance] as? [String: Any])?["config"] as? [String: Any]
        return config?["binaryPath"] as? String
    }

    // MARK: Writing

    enum Failure: Error, Equatable { case notInstalled, unreadable, elsewhere(String), cannotWrite }

    /// Sets the wrapper as T3's Claude binary. A path the user set themselves is kept in a backup and replaced only
    /// with `replacingElsewhere`; the wrapper script is written first, so T3 never points at a file that isn't there.
    static func enable(replacingElsewhere: Bool = false, wrapper: String = ThreadLauncher.wrapperPath.path) throws {
        guard isInstalled else { throw Failure.notInstalled }
        guard var root = read() else { throw Failure.unreadable }
        let current = binaryPath(in: root).flatMap { $0.isEmpty ? nil : $0 }
        if current == wrapper { return }
        if let current, !replacingElsewhere { throw Failure.elsewhere(current) }
        ThreadLauncher.writeWrapper()
        // The backup comes first: a crash between the two writes must lose nothing.
        guard saveBackup(previous: current) else { throw Failure.cannotWrite }
        setBinaryPath(wrapper, in: &root)
        try write(root)
    }

    /// Puts back what T3 had before (nothing, or the user's own path). Does nothing when T3's setting no longer
    /// points at the wrapper: it isn't ours to remove then.
    static func disable(wrapper: String = ThreadLauncher.wrapperPath.path) throws {
        guard isInstalled else { return }
        guard var root = read() else { throw Failure.unreadable }
        guard binaryPath(in: root) == wrapper else { return }
        setBinaryPath(loadBackup(), in: &root)
        try write(root)
        try? FileManager.default.removeItem(at: backupFile)
    }

    /// `nil` removes the key, and the instance when that leaves nothing but its driver (as T3's own file has it).
    private static func setBinaryPath(_ path: String?, in root: inout [String: Any]) {
        var instances = root["providerInstances"] as? [String: Any] ?? [:]
        var entry = instances[instance] as? [String: Any] ?? ["driver": instance]
        var config = entry["config"] as? [String: Any] ?? [:]
        if let path { config["binaryPath"] = path } else { config.removeValue(forKey: "binaryPath") }
        if config.isEmpty { entry.removeValue(forKey: "config") } else { entry["config"] = config }
        if path == nil, Set(entry.keys) == ["driver"] { instances.removeValue(forKey: instance) } else { instances[instance] = entry }
        if instances.isEmpty { root.removeValue(forKey: "providerInstances") } else { root["providerInstances"] = instances }
    }

    /// Replaces the file in one atomic rename, following a symlink to where the file really is.
    private static func write(_ root: [String: Any]) throws {
        let target = settingsFile.resolvingSymlinksInPath()
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            throw Failure.cannotWrite
        }
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (data + Data("\n".utf8)).write(to: target, options: .atomic)
        } catch { throw Failure.cannotWrite }
    }

    // MARK: The backup

    private static func saveBackup(previous: String?) -> Bool {
        LastDropPaths.ensure(backupFile.deletingLastPathComponent())
        let object: [String: Any] = previous.map { ["previous": $0] } ?? [:]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        return (try? data.write(to: backupFile, options: .atomic)) != nil
    }

    private static func loadBackup() -> String? {
        guard let data = try? Data(contentsOf: backupFile),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return object["previous"] as? String
    }
}
