import Foundation

/// Claude Code processes started ahead of time, so a subagent doesn't wait the ~11 s Claude Code takes
/// to start. The lastdrop app keeps them: each is `claude -p --input-format stream-json`, already loaded
/// and waiting for its prompt. A runner (`lastdrop --agent-run`) claims one whose arguments match its own
/// over a Unix socket; the app hands over the process's pipes (SCM_RIGHTS), so the run belongs to the
/// runner as if it had started it, and the app quitting doesn't stop it.
enum WarmPool {
    /// What a process is started with. A run can take a process when all of it matches except the model
    /// and the permission mode, which the runner switches after taking it over, and the environment, which
    /// only the newest caller's is used of.
    struct Spec: Codable, Equatable {
        var account: String
        var directory: String
        /// `claude` arguments without the session id.
        var arguments: [String]
        var environment: [String: String]

        func matches(_ other: Spec) -> Bool {
            account == other.account && directory == other.directory && Self.fixed(arguments) == Self.fixed(other.arguments)
        }

        /// The arguments a running process can't change.
        static func fixed(_ arguments: [String]) -> [String] {
            var out: [String] = []
            var i = 0
            while i < arguments.count {
                if arguments[i] == "--model" || arguments[i] == "--permission-mode" { i += 2; continue }
                out.append(arguments[i])
                i += 1
            }
            return out
        }
    }

    struct Message: Codable {
        /// "claim": hand over a matching process, and start another for the next run. "warm": have one ready.
        var op: String
        var spec: Spec
    }

    /// A claimed process: write the prompt to `input` as a stream-json user message, then close it.
    struct Claimed {
        var sessionID: String
        /// Claude Code's own process, for stopping the run.
        var pid: Int32
        var input: FileHandle
        var output: FileHandle
        var errors: FileHandle
    }

    static var socketPath: String { LastDropPaths.agentsDir.appendingPathComponent("warm.sock").path }
    /// Unclaimed this long, a process is let go: its view of the folder (git status, CLAUDE.md) ages.
    static let idleLimit: TimeInterval = 10 * 60
    static let maxProcesses = 2

    /// The stream-json line `claude -p --input-format stream-json` reads as the prompt.
    static func userMessage(_ prompt: String) -> Data {
        line(["type": "user", "message": ["role": "user", "content": prompt]])
    }

    /// A control request (what the Agent SDK's `setModel` and `setPermissionMode` send), answered by a
    /// `control_response` with the same `request_id`.
    static func controlRequest(_ id: String, _ request: [String: Any]) -> Data {
        line(["type": "control_request", "request_id": id, "request": request])
    }

    /// The switches a taken-over process needs before its prompt, by request id. The model applies only
    /// to messages Claude Code reads after it answered, so the prompt waits for every answer.
    static func switches(model: String?, permissionMode: String) -> [(id: String, data: Data)] {
        var out = [(id: "mode", data: controlRequest("mode", ["subtype": "set_permission_mode", "mode": permissionMode]))]
        if let model, !model.isEmpty {
            out.append((id: "model", data: controlRequest("model", ["subtype": "set_model", "model": model])))
        }
        return out
    }

    private static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        data.append(0x0A)
        return data
    }

    // MARK: Runner side

    static func claim(_ spec: Spec) -> Claimed? {
        guard let fd = connect() else { return nil }
        defer { close(fd) }
        guard send(fd, Message(op: "claim", spec: spec)) else { return nil }
        var fds: [Int32] = []
        guard let reply = receive(fd, fds: &fds), let sessionID = reply["sessionID"] as? String,
              let pid = (reply["pid"] as? NSNumber)?.int32Value, fds.count == 3 else {
            fds.forEach { close($0) }
            return nil
        }
        return Claimed(sessionID: sessionID, pid: pid, input: FileHandle(fileDescriptor: fds[0], closeOnDealloc: true),
                       output: FileHandle(fileDescriptor: fds[1], closeOnDealloc: true),
                       errors: FileHandle(fileDescriptor: fds[2], closeOnDealloc: true))
    }

    /// Starts a process as the app keeps one, handed straight to the caller: the self-test's ready process.
    static func launch(_ spec: Spec) -> Claimed? {
        guard let (process, sessionID, input, output, errors) = start(spec) else { return nil }
        return Claimed(sessionID: sessionID, pid: process.processIdentifier, input: input.fileHandleForWriting,
                       output: output.fileHandleForReading, errors: errors.fileHandleForReading)
    }

    /// `claude -p --input-format stream-json` with the spec's arguments, waiting for its prompt.
    static func start(_ spec: Spec, onExit: (@Sendable (Process) -> Void)? = nil) -> (Process, String, Pipe, Pipe, Pipe)? {
        guard let claude = SubagentRunner.executable(environment: spec.environment) else { return nil }
        let sessionID = UUID().uuidString.lowercased()
        SessionLedger.record(session: sessionID, account: spec.account)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = spec.arguments + ["--input-format", "stream-json", "--session-id", sessionID]
        process.environment = spec.environment
        process.currentDirectoryURL = URL(fileURLWithPath: spec.directory)
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = onExit
        do { try process.run() } catch { return nil }
        return (process, sessionID, input, output, errors)
    }

    static func warm(_ spec: Spec) {
        guard let fd = connect() else { return }
        defer { close(fd) }
        _ = send(fd, Message(op: "warm", spec: spec))
        var fds: [Int32] = []
        _ = receive(fd, fds: &fds)
    }

    private static func connect() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = unixAddress(socketPath)
        let ok = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { close(fd); return nil }
        return fd
    }

    // MARK: Wire

    static func unixAddress(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let bytes = Array(path.utf8.prefix(raw.count - 1))
            raw.copyBytes(from: bytes + [0])
        }
        return address
    }

    static func send(_ fd: Int32, _ message: Message) -> Bool {
        guard var data = try? JSONEncoder().encode(message) else { return false }
        data.append(0x0A)
        return data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == data.count
    }

    /// One JSON line and the descriptors sent with it (Darwin's cmsghdr is 12 bytes, data 4-aligned).
    static func reply(_ fd: Int32, _ object: [String: Any], passing fds: [Int32] = []) {
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        data.append(0x0A)
        let headerSize = MemoryLayout<cmsghdr>.size
        var control = [UInt8](repeating: 0, count: fds.isEmpty ? 0 : headerSize + fds.count * 4)
        if !fds.isEmpty {
            control.withUnsafeMutableBytes { raw in
                raw.storeBytes(of: cmsghdr(cmsg_len: socklen_t(headerSize + fds.count * 4), cmsg_level: SOL_SOCKET, cmsg_type: SCM_RIGHTS),
                               as: cmsghdr.self)
                for (i, f) in fds.enumerated() { raw.storeBytes(of: f, toByteOffset: headerSize + i * 4, as: Int32.self) }
            }
        }
        data.withUnsafeMutableBytes { body in
            var iov = iovec(iov_base: body.baseAddress, iov_len: body.count)
            control.withUnsafeMutableBytes { ctl in
                withUnsafeMutablePointer(to: &iov) { iovPointer in
                    var header = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: iovPointer, msg_iovlen: 1,
                                        msg_control: fds.isEmpty ? nil : ctl.baseAddress, msg_controllen: socklen_t(ctl.count), msg_flags: 0)
                    _ = sendmsg(fd, &header, 0)
                }
            }
        }
    }

    static func receive(_ fd: Int32, fds: inout [Int32]) -> [String: Any]? {
        var body = [UInt8](repeating: 0, count: 4096)
        let headerSize = MemoryLayout<cmsghdr>.size
        var control = [UInt8](repeating: 0, count: headerSize + 16 * 4)
        var received = 0
        var controlLength = 0
        body.withUnsafeMutableBytes { bodyRaw in
            var iov = iovec(iov_base: bodyRaw.baseAddress, iov_len: bodyRaw.count)
            control.withUnsafeMutableBytes { ctl in
                withUnsafeMutablePointer(to: &iov) { iovPointer in
                    var header = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: iovPointer, msg_iovlen: 1,
                                        msg_control: ctl.baseAddress, msg_controllen: socklen_t(ctl.count), msg_flags: 0)
                    received = recvmsg(fd, &header, 0)
                    controlLength = Int(header.msg_controllen)
                }
            }
        }
        if controlLength >= headerSize {
            control.withUnsafeBytes { raw in
                let header = raw.load(as: cmsghdr.self)
                guard header.cmsg_level == SOL_SOCKET, header.cmsg_type == SCM_RIGHTS else { return }
                let count = (Int(header.cmsg_len) - headerSize) / 4
                fds = (0..<count).map { raw.load(fromByteOffset: headerSize + $0 * 4, as: Int32.self) }
            }
        }
        guard received > 0 else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(body.prefix(received)))) as? [String: Any]
    }
}

/// The app's side: the processes waiting, and the socket runners claim them through.
final class WarmPoolServer: @unchecked Sendable {
    static let shared = WarmPoolServer()

    private struct Entry {
        var spec: WarmPool.Spec
        var sessionID: String
        var process: Process
        var input: Pipe
        var output: Pipe
        var errors: Pipe
        var since: Date
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var listener: Int32 = -1
    private var timer: DispatchSourceTimer?

    func start() {
        guard listener < 0, SubagentRunner.executable() != nil else { return }
        LastDropPaths.ensure(LastDropPaths.agentsDir)
        let path = WarmPool.socketPath
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = WarmPool.unixAddress(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); return }
        chmod(path, 0o600)
        listener = fd
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { if errno == EINTR { continue } else { return } }
                DispatchQueue.global().async { self.serve(client) }
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in self?.prune() }
        timer.resume()
        self.timer = timer
    }

    /// Lets every waiting process go; with its input closed and no prompt, Claude Code exits by itself.
    func stop() {
        lock.lock()
        let all = entries
        entries = []
        lock.unlock()
        all.forEach { try? $0.input.fileHandleForWriting.close() }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while !data.contains(0x0A) {
            let n = read(client, &buffer, buffer.count)
            if n <= 0 { return }
            data.append(contentsOf: buffer.prefix(n))
        }
        guard let message = try? JSONDecoder().decode(WarmPool.Message.self, from: data.prefix { $0 != 0x0A }) else { return }
        prune()
        switch message.op {
        case "claim":
            if let entry = take(message.spec) {
                WarmPool.reply(client, ["sessionID": entry.sessionID, "pid": entry.process.processIdentifier], passing: [
                    entry.input.fileHandleForWriting.fileDescriptor, entry.output.fileHandleForReading.fileDescriptor,
                    entry.errors.fileHandleForReading.fileDescriptor,
                ])
                // The runner holds its own copies now; ours would keep the process from seeing the end of its input.
                try? entry.input.fileHandleForWriting.close()
                try? entry.output.fileHandleForReading.close()
                try? entry.errors.fileHandleForReading.close()
                SubagentLog.write("warm: handed over a ready process on \(message.spec.account)")
            } else {
                WarmPool.reply(client, ["miss": true])
            }
            ensure(message.spec)   // the next run in this folder finds one ready
        default:
            ensure(message.spec)
            WarmPool.reply(client, ["ok": true])
        }
    }

    private func take(_ spec: WarmPool.Spec) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        guard let i = entries.firstIndex(where: { $0.spec.matches(spec) && $0.process.isRunning }) else { return nil }
        return entries.remove(at: i)
    }

    private func ensure(_ spec: WarmPool.Spec) {
        lock.lock()
        if let i = entries.firstIndex(where: { $0.spec.matches(spec) && $0.process.isRunning }) {
            entries[i].since = Date()   // asked for again: keep it longer
            lock.unlock()
            return
        }
        lock.unlock()
        guard let entry = spawn(spec) else { return }
        lock.lock()
        entries.append(entry)
        var evicted: [Entry] = []
        while entries.count > WarmPool.maxProcesses { evicted.append(entries.removeFirst()) }
        lock.unlock()
        evicted.forEach { try? $0.input.fileHandleForWriting.close() }
    }

    private func spawn(_ spec: WarmPool.Spec) -> Entry? {
        let started = WarmPool.start(spec) { [weak self] done in
            guard let self else { return }
            self.lock.lock()
            self.entries.removeAll { $0.process === done }
            self.lock.unlock()
        }
        guard let (process, sessionID, input, output, errors) = started else { return nil }
        SubagentLog.write("warm: started a process on \(spec.account) in \(spec.directory)")
        return Entry(spec: spec, sessionID: sessionID, process: process, input: input, output: output, errors: errors, since: Date())
    }

    private func prune() {
        lock.lock()
        let now = Date()
        let stale = entries.filter { now.timeIntervalSince($0.since) > WarmPool.idleLimit }
        entries.removeAll { now.timeIntervalSince($0.since) > WarmPool.idleLimit }
        lock.unlock()
        stale.forEach { try? $0.input.fileHandleForWriting.close() }
    }
}
