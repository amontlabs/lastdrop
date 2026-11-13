import Foundation

/// Sits between T3 Code and a thread's Claude Code, passing every line through both ways, so a turn that ends at a
/// passing API error (`TransientError`) doesn't end the thread's work. Claude Code's `result` line for such a turn
/// is held back from T3, and after 10 s, 30 s, 90 s and 3 min (jittered) the same process, session, account and
/// folder is told to continue, as a stream-json user message; T3 sees one turn that took longer. A message or a
/// stop from T3 meanwhile lets the held result through first. Once the retries are spent the result goes to T3,
/// the account is marked as failing, and the process ends, so T3's next message starts the thread again through
/// the launcher, which moves it to another account (as a usage limit does).
///
/// The launcher used to `execve` claude; it now stays as this relay, its pid the one the ledger and T3 know, and
/// passes on the signals it gets. `LASTDROP_THREAD_RELAY=0` brings the plain `execve` back.
enum ThreadRelay {
    /// The relay's decisions, without any I/O: what to do with each line, wait and stop.
    struct Machine {
        var policy: RetryPolicy
        /// The `result` line T3 hasn't seen yet, while a retry waits.
        private(set) var held: Data?
        /// Retries in a row so far; a turn that went through starts the count again.
        private(set) var failures = 0
        /// Bumped for each hold, so a wait that was overtaken (T3 spoke first) does nothing when it ends.
        private(set) var generation = 0

        init(policy: RetryPolicy) { self.policy = policy }

        enum FromChild: Equatable {
            case forward
            /// Keep the line from T3; after `after` seconds call `fire(generation)`.
            case hold(after: TimeInterval, generation: Int)
            /// The retries are spent: forward the line, and hand the thread on.
            case giveUp
        }

        /// A line from Claude Code: `result` tells whether it is a turn's result line, `transient` why its error is
        /// a passing one, when it is.
        mutating func fromChild(isResult: Bool, transient: String?, line: Data, random: Double = .random(in: -1...1)) -> FromChild {
            guard isResult else { return .forward }
            guard transient != nil else { failures = 0; return .forward }
            guard let wait = policy.delay(after: failures, random: random) else { failures = 0; return .giveUp }
            failures += 1
            generation += 1
            held = line
            return .hold(after: wait, generation: generation)
        }

        /// T3 sent a line. One that starts or stops a turn (a user message, an interrupt) first lets a held result
        /// through, returned here to write ahead of it; anything else (a control request Claude Code answers while
        /// idle) passes alongside the wait.
        mutating func fromParent(endsWait: Bool) -> Data? {
            guard endsWait, let line = held else { return nil }
            held = nil
            failures = 0
            generation += 1
            return line
        }

        /// A wait ended: true when its retry still stands (nothing overtook it). The held result is dropped: the
        /// continued turn brings its own.
        mutating func fire(_ generation: Int) -> Bool {
            guard generation == self.generation, held != nil else { return false }
            held = nil
            return true
        }

        /// Claude Code is gone (or T3 closed its side): a held result goes to T3 so the turn ends.
        mutating func release() -> Data? {
            defer { held = nil; generation += 1 }
            return held
        }
    }

    /// Whether a line of Claude Code's stream-json output is a turn's result, and when its error is a passing one,
    /// why. A usage limit or a model the plan lacks is never passing (the reaper and the next start handle those).
    static func classify(_ line: Data, signInWorks: () -> Bool) -> (isResult: Bool, transient: String?) {
        // Most lines are streamed text: only one that mentions a result is parsed.
        guard line.range(of: Data(#""result""#.utf8)) != nil,
              let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], event.string("type") == "result"
        else { return (false, nil) }
        guard event["is_error"] as? Bool == true else { return (true, nil) }
        let result = SubagentRunner.classify(SubagentRunner.parse(event), signInWorks: signInWorks)
        return (true, result.transient)
    }

    /// A line from T3 that starts or stops a turn: a user message, or an interrupt.
    static func endsWait(_ line: Data) -> Bool {
        guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return true }
        switch event.string("type") {
        case "user": return true
        case "control_request": return event.dict("request")?.string("subtype") == "interrupt"
        default: return false
        }
    }

    /// Splits a byte stream into lines, newline included, keeping the unfinished end for the next chunk.
    struct Lines {
        private var pending = Data()

        mutating func feed(_ chunk: Data) -> [Data] {
            pending.append(chunk)
            var out: [Data] = []
            var start = pending.startIndex
            while let newline = pending[start...].firstIndex(of: 0x0A) {
                out.append(Data(pending[start...newline]))
                start = newline + 1
            }
            // One copy of what's left, not one per line.
            if start > pending.startIndex { pending = Data(pending[start...]) }
            return out
        }

        /// What's left at the end of the stream.
        mutating func rest() -> Data? {
            defer { pending = Data() }
            return pending.isEmpty ? nil : pending
        }
    }

    // MARK: Running it

    /// Runs claude under the relay and exits as it does. `label` names the thread in subagents.log.
    static func run(_ claude: String, args: [String], environment: [String: String], account: ClaudeAccount, label: String) -> Never {
        signal(SIGPIPE, SIG_IGN)
        guard let relay = start(claude, args: args, environment: environment, account: account, label: label,
                                parentIn: 0, parentOut: 1, onExit: { exit($0) }) else { fallback(claude, args, environment) }
        relay.forwardSignals()
        dispatchMain()
    }

    /// Starts claude with its stdin and stdout through the relay, T3's side on `parentIn` and `parentOut`; nil when
    /// it couldn't. `onExit` gets claude's exit code once its output is drained.
    static func start(_ claude: String, args: [String], environment: [String: String], account: ClaudeAccount, label: String,
                      parentIn: Int32, parentOut: Int32, policy: RetryPolicy = SubagentRunner.retryPolicy,
                      onExit: @escaping @Sendable (Int32) -> Void) -> Relay? {
        var toChild: [Int32] = [0, 0], fromChild: [Int32] = [0, 0]
        guard pipe(&toChild) == 0, pipe(&fromChild) == 0 else { return nil }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, toChild[0], 0)
        posix_spawn_file_actions_adddup2(&actions, fromChild[1], 1)
        for fd in [toChild[0], toChild[1], fromChild[0], fromChild[1]] { posix_spawn_file_actions_addclose(&actions, fd) }
        let argv = ([claude] + args).map { strdup($0) } + [nil]
        let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        var child: pid_t = 0
        // Same process group: T3 ends the thread by signalling the group, which reaches claude directly too.
        let spawned = posix_spawn(&child, claude, &actions, nil, argv, envp)
        posix_spawn_file_actions_destroy(&actions)
        close(toChild[0]); close(fromChild[1])
        guard spawned == 0 else {
            close(toChild[1]); close(fromChild[0])
            return nil
        }
        // The relay's own ends stay out of the processes claude starts.
        _ = fcntl(toChild[1], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fromChild[0], F_SETFD, FD_CLOEXEC)
        let relay = Relay(child: child, input: toChild[1], output: fromChild[0], parentIn: parentIn, parentOut: parentOut,
                          policy: policy, account: account, label: label, onExit: onExit)
        relay.start()
        return relay
    }

    /// The relay couldn't start claude itself: the thread runs as it did before.
    private static func fallback(_ claude: String, _ args: [String], _ environment: [String: String]) -> Never {
        let argv = ([claude] + args).map { strdup($0) } + [nil]
        let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)")! } + [nil]
        execve(claude, argv, envp)
        perror("claude-thread: exec")
        exit(127)
    }

    /// The running relay: three threads (T3's lines, Claude Code's lines, the exit) and the waits' timers.
    final class Relay: @unchecked Sendable {
        let child: pid_t
        let input: Int32
        let output: Int32
        let parentIn: Int32
        let parentOut: Int32
        let account: ClaudeAccount
        let label: String
        let onExit: @Sendable (Int32) -> Void
        private var machine: Machine
        /// Guards `machine` only; writes take their own locks, so a pipe that's full never blocks the other side.
        private let state = NSLock()
        private let toT3 = NSLock()
        private let toClaude = NSLock()
        private var inputClosed = false
        private var signals: [DispatchSourceSignal] = []
        private let drained = DispatchSemaphore(value: 0)

        init(child: pid_t, input: Int32, output: Int32, parentIn: Int32, parentOut: Int32, policy: RetryPolicy,
             account: ClaudeAccount, label: String, onExit: @escaping @Sendable (Int32) -> Void) {
            self.child = child; self.input = input; self.output = output; self.parentIn = parentIn; self.parentOut = parentOut
            self.account = account; self.label = label; self.onExit = onExit
            machine = Machine(policy: policy)
        }

        func start() {
            Thread.detachNewThread { self.pumpFromT3() }
            Thread.detachNewThread { self.pumpFromClaude() }
            Thread.detachNewThread { self.waitForExit() }
        }

        /// The signals the relay gets (the reaper's SIGTERM, a Ctrl-C) go to claude, which ends, and so does the relay.
        func forwardSignals() {
            for sig in [SIGTERM, SIGINT, SIGHUP] {
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInitiated))
                source.setEventHandler { [child] in kill(child, sig) }
                source.resume()
                signals.append(source)
            }
        }

        private func pumpFromT3() {
            var lines = Lines()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = read(parentIn, &buffer, buffer.count)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { break }
                for line in lines.feed(Data(buffer[0..<n])) {
                    state.lock()
                    let released = machine.fromParent(endsWait: ThreadRelay.endsWait(line))
                    state.unlock()
                    if let released {
                        SubagentLog.write("thread \(label): T3 spoke while a retry waited; the held error goes through")
                        writeT3(released)
                    }
                    writeClaude(line)
                }
            }
            if let rest = lines.rest() { writeClaude(rest) }
            state.lock()
            let released = machine.release()
            state.unlock()
            if let released { writeT3(released) }
            toClaude.lock()
            inputClosed = true
            close(input)
            toClaude.unlock()
        }

        private func pumpFromClaude() {
            var lines = Lines()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let account = account
            let signInWorks = { TransientError.signInWorks(account) }
            while true {
                let n = read(output, &buffer, buffer.count)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { break }
                for line in lines.feed(Data(buffer[0..<n])) { fromClaude(line, signInWorks: signInWorks) }
            }
            if let rest = lines.rest() { writeT3(rest) }
            state.lock()
            let released = machine.release()
            state.unlock()
            if let released { writeT3(released) }
            drained.signal()
        }

        private func fromClaude(_ line: Data, signInWorks: () -> Bool) {
            let (isResult, transient) = ThreadRelay.classify(line, signInWorks: signInWorks)
            state.lock()
            let action = machine.fromChild(isResult: isResult, transient: transient, line: line)
            let failures = machine.failures, retries = machine.policy.retries
            state.unlock()
            switch action {
            case .forward:
                writeT3(line)
            case .hold(let wait, let generation):
                SubagentLog.write("thread \(label) on \(account.id): temporary API error (\(transient ?? "")); "
                                  + "retry \(failures) of \(retries) in \(Int(wait.rounded())) s, continuing the same session")
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + wait) { [self] in
                    state.lock()
                    let go = machine.fire(generation)
                    state.unlock()
                    guard go else { return }
                    SubagentLog.write("thread \(label) on \(account.id): retry \(failures) of \(retries), telling it to continue")
                    writeClaude(WarmPool.userMessage(SubagentRunner.retryPrompt))
                }
            case .giveUp:
                SubagentLog.write("thread \(label) on \(account.id): temporary API error (\(transient ?? "")) again; "
                                  + "retries spent, ending the process so the next message moves the thread")
                writeT3(line)
                AgentRegistry.markTroubled(account.id)
                kill(child, SIGTERM)
            }
        }

        private func waitForExit() {
            var status: Int32 = 0
            while waitpid(child, &status, 0) < 0, errno == EINTR {}
            // Its last lines may still be in the pipe; a helper it left behind holding the pipe open doesn't hold the thread up.
            _ = drained.wait(timeout: .now() + 2)
            let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            onExit(code)
        }

        private func writeT3(_ data: Data) {
            toT3.lock(); defer { toT3.unlock() }
            Self.writeAll(parentOut, data)
        }

        private func writeClaude(_ data: Data) {
            toClaude.lock(); defer { toClaude.unlock() }
            guard !inputClosed else { return }
            Self.writeAll(input, data)
        }

        private static func writeAll(_ fd: Int32, _ data: Data) {
            data.withUnsafeBytes { raw in
                guard var p = raw.baseAddress else { return }
                var left = raw.count
                while left > 0 {
                    let n = write(fd, p, left)
                    if n < 0 { if errno == EINTR { continue }; return }
                    p = p.advanced(by: n)
                    left -= n
                }
            }
        }
    }
}
