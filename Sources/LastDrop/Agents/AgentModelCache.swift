import Foundation

/// The efforts each provider's models took when lastdrop last listed them (Settings, `--agents`, and each Antigravity
/// or Codex run, which list them anyway), in `agent-models.json` in the support folder. Read where asking the
/// provider would be too slow, as T3's probe of `lastdrop --acp` every 15 minutes. A provider never listed is absent.
enum AgentModelCache {
    struct Model: Codable, Equatable {
        var id: String
        var efforts: [String]
    }

    struct Entry: Codable, Equatable {
        var models: [Model]
        var updated: Date
    }

    static var file: URL { LastDropPaths.support.appendingPathComponent("agent-models.json") }

    /// Replaces `provider`'s list. An empty list says nothing (a provider that couldn't tell) and is not written; an
    /// unchanged one is not written again.
    static func save(_ provider: AgentProvider, _ models: [AgentModel], at url: URL = file, now: Date = .now) {
        guard !models.isEmpty else { return }
        let listed = models.map { Model(id: $0.id, efforts: $0.efforts) }
        withLock(url) {
            var all = load(url)
            if all[provider.rawValue]?.models == listed { return }
            all[provider.rawValue] = Entry(models: listed, updated: now)
            guard let data = try? JSONEncoder.lastdrop.encode(all) else { return }
            do { try data.write(to: url, options: .atomic) } catch {
                SubagentLog.write("agents: couldn't write \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    /// The efforts `model` took on `provider`, or nil when lastdrop never listed that model there.
    static func efforts(_ provider: AgentProvider, _ model: String, in all: [String: Entry]) -> [String]? {
        all[provider.rawValue]?.models.first { $0.id == model }?.efforts
    }

    static func load(_ url: URL = file) -> [String: Entry] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder.lastdrop.decode([String: Entry].self, from: $0) } ?? [:]
    }

    private static func withLock(_ url: URL, _ body: () -> Void) {
        LastDropPaths.ensure(url.deletingLastPathComponent())
        let fd = open(url.path + ".lock", O_CREAT | O_RDWR, 0o600)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        body()
    }
}

extension AgentProvider {
    /// The provider's models, asked now; the list is kept in `AgentModelCache`.
    func models() async throws -> [AgentModel] {
        let models = try await backend.models()
        AgentModelCache.save(self, models)
        return models
    }
}
