import Foundation
import Darwin

/// One Agent Client Protocol agent process (`agy acp`): JSON-RPC 2.0 over stdin and stdout, one object per line.
/// https://agentclientprotocol.com
///
/// Notifications go to `onNotification` on the reading thread, in order, before the answer to any later request
/// is delivered, so a caller that awaits `session/prompt` has seen every update of that turn. Requests from the
/// agent go to `onRequest`, which may take its time (a permission check runs a reviewer): the reading thread goes
/// on and the answer is written when it is ready. A request left unanswered when the connection ends is moot.
final class ACPClient: @unchecked Sendable {
    struct RPCError: Error, LocalizedError {
        var code: Int
        var message: String
        var errorDescription: String? { message }
    }

    enum Reply: Sendable {
        case result(Payload)
        case error(code: Int, message: String)
    }

    /// A JSON object off the wire. `Any` isn't Sendable, so it travels wrapped.
    struct Payload: @unchecked Sendable { var object: [String: Any] }

    let process = Process()
    let onNotification: @Sendable (String, [String: Any]) -> Void
    let onRequest: @Sendable (String, [String: Any]) async -> Reply

    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let lock = NSLock()
    private struct Pending {
        var continuation: CheckedContinuation<[String: Any], Error>
        var timeout: DispatchWorkItem?
    }
    private var pending: [Int: Pending] = [:]
    private var nextID = 0
    private var closed: Error?
    private var stderrTail = Data()
    private let name: String
    private let stderrDone = DispatchSemaphore(value: 0)

    var pid: Int32 { process.processIdentifier }
    /// The last 8 KB the agent wrote to stderr, for a failure's message.
    var stderr: String { lock.withLock { String(decoding: stderrTail, as: UTF8.self) } }

    init(executable: String, arguments: [String], directory: String, environment: [String: String], name: String,
         onNotification: @escaping @Sendable (String, [String: Any]) -> Void,
         onRequest: @escaping @Sendable (String, [String: Any]) async -> Reply) {
        self.name = name
        self.onNotification = onNotification
        self.onRequest = onRequest
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    func start() throws {
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.finish(RPCError(code: -32000, message: "\(self.name) exited"))
        }
        // An early CLI failure must report EPIPE instead of ending lastdrop with SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        let out = output.fileHandleForReading
        Thread.detachNewThread { [self] in read(out) }
        let err = errors.fileHandleForReading
        Thread.detachNewThread { [self] in
            defer { stderrDone.signal() }
            while case let data = err.availableData, !data.isEmpty {
                lock.withLock {
                    stderrTail.append(data)
                    if stderrTail.count > 8192 { stderrTail = Data(stderrTail.suffix(8192)) }
                }
            }
        }
    }

    /// Waits up to `timeout` for the agent's stderr to close, so a failure's message has all of it.
    func drainStderr(timeout: TimeInterval = 1) {
        if stderrDone.wait(timeout: .now() + timeout) == .success { stderrDone.signal() }
    }

    /// Sends a request and waits for its answer; nil `timeout` waits as long as the agent runs.
    func call(_ method: String, _ params: [String: Any], timeout: TimeInterval? = 60) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { (waiting: CheckedContinuation<[String: Any], Error>) in
            lock.lock()
            if let closed {
                lock.unlock()
                return waiting.resume(throwing: closed)
            }
            nextID += 1
            let id = nextID
            let timer = timeout.map { _ in
                DispatchWorkItem { [weak self] in
                    self?.fail(id, RPCError(code: -32000, message: "\(self?.name ?? "Agent") did not answer \(method) in time."))
                }
            }
            pending[id] = Pending(continuation: waiting, timeout: timer)
            lock.unlock()
            if let timer, let timeout { DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer) }
            do { try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params]) } catch { fail(id, error) }
        }
    }

    func notify(_ method: String, _ params: [String: Any]) {
        try? send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    /// Ends waiters immediately, then asks the process to exit and kills it after five seconds if needed.
    func stop() {
        finish(RPCError(code: -32000, message: "\(name) was stopped"))
        try? input.fileHandleForWriting.close()
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [process] in
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func send(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) + Data("\n".utf8)
        lock.lock(); defer { lock.unlock() }
        if let closed { throw closed }
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func fail(_ id: Int, _ error: Error) {
        let waiting = lock.withLock { pending.removeValue(forKey: id) }
        waiting?.timeout?.cancel()
        waiting?.continuation.resume(throwing: error)
    }

    private func read(_ handle: FileHandle) {
        var buffer = Data()
        while case let data = handle.availableData, !data.isEmpty {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D }) else { continue }
                guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                    finish(RPCError(code: -32700, message: "\(name) wrote invalid protocol JSON."))
                    stop()
                    return
                }
                receive(object)
            }
        }
        finish(RPCError(code: -32000, message: "\(name) exited"))
    }

    private func finish(_ error: Error) {
        lock.lock()
        guard closed == nil else { lock.unlock(); return }
        closed = error
        let waiting = pending
        pending = [:]
        lock.unlock()
        for (_, w) in waiting { w.timeout?.cancel(); w.continuation.resume(throwing: error) }
    }

    private func receive(_ object: [String: Any]) {
        if let method = object.string("method") {
            let params = object.dict("params") ?? [:]
            guard let id = object["id"] else { return onNotification(method, params) }
            let request = Payload(object: ["id": id, "params": params])
            Task.detached { [self] in
                let reply = await onRequest(method, request.object.dict("params") ?? [:])
                let id = request.object["id"]!
                switch reply {
                case .result(let result): try? send(["jsonrpc": "2.0", "id": id, "result": result.object])
                case .error(let code, let text): try? send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": text]])
                }
            }
            return
        }
        guard let id = (object["id"] as? NSNumber)?.intValue else { return }
        let waiting = lock.withLock { pending.removeValue(forKey: id) }
        waiting?.timeout?.cancel()
        if let error = object.dict("error") {
            waiting?.continuation.resume(throwing: RPCError(code: (error["code"] as? NSNumber)?.intValue ?? 0,
                                                            message: error.string("message") ?? "\(name) error"))
        } else {
            waiting?.continuation.resume(returning: object.dict("result") ?? [:])
        }
    }
}
