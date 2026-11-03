import Foundation

/// Runs a CLI's own sign-in (`claude auth login`, `codex login`): it opens the browser and exits once the
/// sign-in lands. No terminal is attached, so a CLI that would ask on stdin gets nothing and gives up.
enum CLILogin {
    static func run(_ executable: String, _ arguments: [String], environment: [String: String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: LastDropPaths.helperDirectory)
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let tail = Tail()
        output.fileHandleForReading.readabilityHandler = { tail.add($0.availableData) }
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in done.resume() }
                do { try process.run() } catch { process.terminationHandler = nil; done.resume(throwing: error) }
            }
        } onCancel: {
            // Cancelled before launching: terminate() on a process that never ran raises.
            if process.isRunning { process.terminate() }
        }
        output.fileHandleForReading.readabilityHandler = nil
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            throw ProviderError.message(tail.text.isEmpty ? "The sign-in didn't finish." : tail.text)
        }
    }

    /// The last line the CLI printed, for its error.
    private final class Tail: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func add(_ chunk: Data) { lock.lock(); data.append(chunk); if data.count > 4000 { data = data.suffix(2000) }; lock.unlock() }
        var text: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).last.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
        }
    }
}
