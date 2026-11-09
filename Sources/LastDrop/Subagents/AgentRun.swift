import CryptoKit
import Foundation

/// `lastdrop --agent-run`: one subagent for lastdrop's Claude Code plugin, which answers the built-in Agent
/// tool with it. Reads a JSON request on stdin and writes JSON lines on stdout:
///
/// - `{"type":"no_room"}`: no other account has room; the plugin lets the built-in subagent run.
/// - `{"type":"native"}`: a plain call's accounts all refused it (a limit, or a plan without the model) before any
///   work happened, so the plugin lets the built-in agent run, exactly as if lastdrop hadn't touched it. It can come
///   at any point before the result, after `started` too. A call with worktree isolation (the built-in shell has
///   none) and a run already underway stay with the runner, which falls back to the session's own account.
/// - `{"type":"error","text"}`: it couldn't start, for a reason that needs fixing (no fallback hides it).
/// - `{"type":"started","agentId","account","model","outputFile"}`: Claude Code started as expected and
///   is running, the agent's id fixed; `model` is the model that runs.
/// - `{"type":"step","text"}`: a step the agent took ("Read: note.txt").
/// - `{"type":"moved","account","reason"}`: the account reached its usage limit or lacks the model; another
///   took over (before any work, from the start; partway through, continuing the same session).
/// - `{"type":"tick"}`: once a minute while it runs, so the plugin can show a long, quiet step is still going
///   (Claude Code stops a subagent that shows nothing for ten minutes).
/// - `{"type":"result","text","isError",...}`: its final answer; `stopped` when TaskStop ended it. An agent
///   from lastdrop's list also reports `worktreePath`, `worktreeBranch` and `declined` when they apply.
///
/// The model asked for is the model that runs: no account or provider ever stands in with another one.
enum AgentRun {
    /// Set in a subagent's environment: a subagent never starts subagents on yet another account.
    static let nestedMarker = "LASTDROP_SUBAGENT"

    struct Request: Decodable {
        var prompt: String
        var description: String?
        var subagentType: String?
        var model: String?
        var effort: String?
        var isolation: String?
        var cwd: String
        var permissionMode: String?
        /// The calling session's model, which a subagent inherits unless the call names one.
        var parentModel: String?
        /// An agent this runner started earlier: continue it (SendMessage) on its account.
        var resume: String?
        /// An extra model of lastdrop's list (`codex-deep`, or `lastdrop:codex-deep` from before): it runs on its
        /// own provider, never elsewhere. Then `model` is absent.
        var agent: String?
        /// `Explore` or `Plan` when the call's agent type is one of those: an `agent` run then changes no files.
        var role: String?
        /// Claude Code's native task id, also used for lastdrop's logs, stop and resume.
        var id: String?

        /// The model a run on the Claude accounts needs: the call's, else the session's own.
        var wantedModel: String? { model ?? parentModel }

        var validID: Bool {
            guard let id else { return true }
            return !id.isEmpty && id.count <= 100 && id.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
            }
        }
    }

    static func main(routeOnly: Bool = false) -> Never {
        stopOnSignal()
        Task.detached {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            guard let request = try? JSONDecoder().decode(Request.self, from: input) else {
                emit(["type": "result", "text": "lastdrop couldn't read the subagent request.", "isError": true])
                exit(1)
            }
            guard request.validID else {
                emit(["type": "error", "text": "lastdrop received an invalid native agent id."])
                exit(1)
            }
            if routeOnly { emit(await route(request)) } else {
                startTicks()
                await run(request)
            }
            AgentRegistry.setRunning(nil)
            exit(0)
        }
        dispatchMain()
    }

    private static var signalSources: [DispatchSourceSignal] = []
    private static var ticks: DispatchSourceTimer?

    /// A `tick` line every minute until the process ends: the plugin reads it as a sign of life, never as work.
    private static func startTicks() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { emit(["type": "tick"]) }
        timer.resume()
        ticks = timer
    }

    /// The plugin ends a run nobody waits for any more (the person interrupted a foreground agent) by ending
    /// this process: the Claude Code it started ends with it.
    private static func stopOnSignal() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                // A ready process came from the app, so it is not necessarily this runner's child.
                for pid in AgentRegistry.ownedProcesses() { SubagentRunner.terminate(pid) }
                var children = [pid_t](repeating: 0, count: 64)
                let count = proc_listchildpids(getpid(), &children, Int32(children.count * MemoryLayout<pid_t>.size))
                for pid in children.prefix(Int(max(0, min(count, Int32(children.count))))) where pid > 0 { kill(pid, SIGTERM) }
                AgentRegistry.setRunning(nil)
                exit(1)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// `lastdrop --agent-warm`: the plugin's heads-up when a prompt is sent, with the same request an Agent
    /// call would make. The app starts a process for it on the account a run would pick, unless one is ready.
    static func warmMain() -> Never {
        Task.detached {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            if let request = try? JSONDecoder().decode(Request.self, from: input),
               ProcessInfo.processInfo.environment[nestedMarker] == nil {
                await warm(request)
            }
            exit(0)
        }
        dispatchMain()
    }

    static func warm(_ request: Request) async {
        let config = ClaudeAccountsConfig.load()
        guard let account = await pick(config.ordered, config: config, own: SubagentAccounts.ownAccountUUID(), excluding: [], log: false)
        else { return }
        let req = SubagentRunner.Request(prompt: "", subagentType: request.subagentType, model: request.wantedModel, effort: request.effort,
                                         permissionMode: mappedPermissionMode(request.permissionMode), sessionID: "",
                                         mcpConfig: writeMCPConfig(directory: request.cwd))
        guard let spec = SubagentRunner.warmSpec(req, on: account, in: request.cwd, environment: ProcessInfo.processInfo.environment)
        else { return }
        WarmPool.warm(spec)
    }

    /// Tests read the lines here instead of standard output.
    nonisolated(unsafe) static var sink: (([String: Any]) -> Void)?
    /// The backend that runs an agent's provider; tests stand fakes in for the real ones.
    nonisolated(unsafe) static var backends: (AgentProvider) -> any AgentBackend.Type = { $0.backend }

    private static let output = NSLock()

    static func emit(_ object: [String: Any]) {
        if let sink { return sink(object) }
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: .withoutEscapingSlashes) else { return }
        data.append(0x0A)
        // Ticks come from a timer thread: one line is written whole before the next starts.
        output.lock()
        defer { output.unlock() }
        FileHandle.standardOutput.write(data)
    }

    /// Checks routing before the engine creates its native task. It starts no provider or model request.
    static func route(_ request: Request) async -> [String: Any] {
        if ProcessInfo.processInfo.environment[nestedMarker] != nil { return ["type": "no_room"] }
        if let id = request.resume {
            return ["type": AgentRegistry.lookup(id) == nil ? "no_room" : "routed"]
        }
        if let type = request.agent {
            guard AgentCatalog.load().agent(type) != nil else {
                return ["type": "error", "text": "No agent \(type) is enabled in lastdrop (Settings → Agents)."]
            }
            return ["type": "routed"]
        }
        let config = ClaudeAccountsConfig.load()
        let account = await pick(config.ordered, config: config, own: SubagentAccounts.ownAccountUUID(), excluding: [])
        return ["type": account == nil ? "no_room" : "routed"]
    }

    static func run(_ request: Request) async {
        let config = ClaudeAccountsConfig.load()
        let accounts = config.ordered
        let mcpConfig = writeMCPConfig(directory: request.cwd)
        let permissionMode = mappedPermissionMode(request.permissionMode)

        // A follow-up goes back to the account, session, folder and agent type the agent ran with.
        if let agentID = request.resume, let entry = AgentRegistry.lookup(agentID), let definition = entry.definition {
            return await runDefined(definition, request, agentID: agentID, resume: entry, mcpConfig: mcpConfig)
        }
        if let type = request.agent {
            guard ProcessInfo.processInfo.environment[nestedMarker] == nil else {
                emit(["type": "error", "text": "An agent lastdrop runs can't start lastdrop's agents (\(type))."])
                return
            }
            guard let definition = AgentCatalog.load().agent(type) else {
                emit(["type": "error", "text": "No agent \(type) is enabled in lastdrop (Settings → Agents)."])
                return
            }
            return await runDefined(definition, request, agentID: request.id ?? UUID().uuidString.lowercased(), resume: nil, mcpConfig: mcpConfig)
        }
        if let agentID = request.resume {
            guard let entry = AgentRegistry.lookup(agentID), let account = accounts.first(where: { $0.id == entry.account }) else {
                emit(["type": "error", "text": "No agent \(agentID) was started by lastdrop."])
                return
            }
            let launch = Launch()
            AgentRegistry.setRunning(account.id)
            let req = SubagentRunner.Request(prompt: request.prompt, subagentType: entry.subagentType, model: entry.model,
                                             effort: entry.effort, permissionMode: permissionMode, sessionID: entry.sessionID,
                                             resume: true, mcpConfig: mcpConfig)
            var result = await SubagentRunner.run(req, on: account, in: entry.directory,
                                                  onProcess: { AgentRegistry.setProcess(agentID, claude: $0) },
                                                  check: launch.check(subagentType: entry.subagentType, account: account.id) { event in
                AgentRegistry.remember(agentID, entry: entry, at: event["cwd"] as? String)
                emit(["type": "started", "agentId": agentID, "account": account.id, "model": entry.model ?? "", "outputFile": logURL(agentID).path])
            }) { step(agentID, $0) } onItem: { item(agentID, $0) }
            if result.limitReached { await SubagentUsage.shared.markFull(account) }
            guard launch.started else { return fail(agentID, result) }
            var moved = entry
            if let directory = result.directory { moved.directory = directory }
            (result, moved) = await carryOn(agentID, entry: moved, result: result, accounts: accounts, config: config,
                                            own: SubagentAccounts.ownAccountUUID(), tried: [],
                                            permissionMode: permissionMode, mcpConfig: mcpConfig)
            AgentRegistry.remember(agentID, entry: moved)
            result.worktreePath = moved.worktreePath
            result.worktreeBranch = moved.worktreeBranch
            finish(agentID, result, account: moved.account)
            return
        }

        if ProcessInfo.processInfo.environment[nestedMarker] != nil { emit(["type": "no_room"]); return }
        let own = SubagentAccounts.ownAccountUUID()
        let agentID = request.id ?? UUID().uuidString.lowercased()
        let launch = Launch()
        var tried = Set<String>()
        var refused: SubagentRunner.Result?
        while true {
            // The chain for a plain call: the other accounts, then the built-in agent. Only a call with worktree
            // isolation (the built-in shell has none) goes on to the session's own account through the runner.
            let next = request.isolation == "worktree"
                ? await nextAccount(accounts, config: config, own: own, excluding: tried)
                : await pick(accounts, config: config, own: own, excluding: tried)
            guard let account = next else {
                if request.isolation != "worktree" {
                    // No work happened (every attempt was refused before a tool ran): the built-in agent takes it.
                    AgentRegistry.forget(agentID)
                    emit(["type": "native"])
                    return
                }
                if launch.started {
                    finish(agentID, refused ?? .init(text: AgentRun.noRoom, isError: true, limitReached: true, turns: 0, permissionDenials: 0), account: nil)
                } else {
                    emit(["type": "no_room"])
                }
                return
            }
            let model = request.wantedModel
            AgentRegistry.setRunning(account.id)
            let check = launch.check(subagentType: request.subagentType, account: account.id) { event in
                // A native stop can end the runner before `run` returns. Keep its session from init onward.
                AgentRegistry.remember(agentID, entry: .init(account: account.id, directory: event["cwd"] as? String ?? request.cwd,
                                                           sessionID: event["session_id"] as? String ?? "", model: event["model"] as? String ?? model,
                                                           subagentType: request.subagentType, effort: request.effort, at: Date()))
                emit(["type": "started", "agentId": agentID, "account": account.id, "model": event["model"] as? String ?? model ?? "",
                      "outputFile": logURL(agentID).path])
                log(agentID, "Started on the \(account.id) account: \(request.description ?? "")")
            }
            let req = SubagentRunner.Request(prompt: request.prompt, subagentType: request.subagentType, model: model,
                                             effort: request.effort, worktree: request.isolation == "worktree",
                                             permissionMode: permissionMode, sessionID: UUID().uuidString.lowercased(),
                                             mcpConfig: mcpConfig)
            let onProcess: @Sendable (Int32) -> Void = { AgentRegistry.setProcess(agentID, claude: $0) }
            var result = await SubagentRunner.run(req, on: account, in: request.cwd, onProcess: onProcess, check: check) {
                step(agentID, $0)
            } onItem: { item(agentID, $0) }
            if !launch.started { return fail(agentID, result) }
            // Plans differ in models (Pro has no Fable): another account may have it. Never another model.
            if result.modelUnavailable && result.toolUses == 0 && !AgentRegistry.wasStopped(agentID) {
                tried.insert(account.id)
                refused = result
                refused?.text = modelRefusal(model, result.text)
                emit(["type": "moved", "account": account.id, "reason": "\(account.id) doesn't include \(model ?? "the model")"])
                continue
            }
            if result.limitReached && result.toolUses == 0 && !AgentRegistry.wasStopped(agentID) {
                // Refused before doing anything: another account can take the task whole.
                await SubagentUsage.shared.markFull(account)
                tried.insert(account.id)
                refused = result
                emit(["type": "moved", "account": account.id, "reason": "\(account.id) is at its usage limit"])
                continue
            }
            var entry = AgentRegistry.Entry(account: account.id, directory: result.directory ?? request.cwd,
                                            sessionID: result.sessionID ?? req.sessionID, model: model,
                                            subagentType: request.subagentType, effort: request.effort, at: Date())
            (result, entry) = await carryOn(agentID, entry: entry, result: result, accounts: accounts, config: config, own: own,
                                            tried: tried, permissionMode: permissionMode, mcpConfig: mcpConfig)
            noteWorktree(&result, isolation: request.isolation, cwd: request.cwd)
            entry.worktreePath = result.worktreePath
            entry.worktreeBranch = result.worktreeBranch
            AgentRegistry.remember(agentID, entry: entry)
            finish(agentID, result, account: entry.account)
            return
        }
    }

    /// What a moved agent is told: nothing about accounts or limits, only to go on.
    static let continuePrompt = "Continue the task from where you left off and finish it."

    /// An agent an account stopped at its usage limit partway through: its session moves to the next account
    /// with room that has its model, else to the calling session's own, and continues there. An account that
    /// refuses the model passes it on the same way. Whoever called the agent only ever gets its report; the
    /// limit, or the model, shows only when every account, the session's own included, is out of room or lacks it.
    static func carryOn(_ agentID: String, entry: AgentRegistry.Entry, result: SubagentRunner.Result,
                        accounts: [ClaudeAccount], config: ClaudeAccountsConfig, own: String?, tried: Set<String>,
                        permissionMode: String, mcpConfig: String?) async -> (SubagentRunner.Result, AgentRegistry.Entry) {
        var entry = entry, result = result, tried = tried
        var toolUses = result.toolUses, durationMs = result.durationMs
        while result.limitReached || result.modelUnavailable, !AgentRegistry.wasStopped(agentID),
              let from = accounts.first(where: { $0.id == entry.account }) {
            let cause: String
            if result.modelUnavailable {
                cause = "\(from.id) doesn't include \(entry.model ?? "the model")"
            } else {
                await SubagentUsage.shared.markFull(from)
                cause = "\(from.id) is at its usage limit"
            }
            tried.insert(from.id)
            guard let to = await nextAccount(accounts, config: config, own: own, excluding: tried) else { break }
            guard SessionTransfer.copy(entry.sessionID, from: from, to: to) else {
                SubagentLog.write("\(agentID): session \(entry.sessionID) couldn't be copied from \(from.id) to \(to.id)")
                break
            }
            SubagentLog.write("\(agentID) continues on \(to.id): \(cause)")
            emit(["type": "moved", "account": from.id, "reason": "\(cause); continuing on \(to.id)"])
            log(agentID, "\(cause); continuing on the \(to.id) account.")
            entry.account = to.id
            AgentRegistry.setRunning(to.id)
            AgentRegistry.remember(agentID, entry: entry)   // a stop or a follow-up finds it on its new account
            let req = SubagentRunner.Request(prompt: continuePrompt, subagentType: entry.subagentType, model: entry.model,
                                             effort: entry.effort, permissionMode: permissionMode, sessionID: entry.sessionID,
                                             resume: true, mcpConfig: mcpConfig)
            let onProcess: @Sendable (Int32) -> Void = { AgentRegistry.setProcess(agentID, claude: $0) }
            result = await SubagentRunner.run(req, on: to, in: entry.directory, onProcess: onProcess) {
                step(agentID, $0)
            } onItem: { item(agentID, $0) }
            toolUses += result.toolUses
            durationMs += result.durationMs
        }
        if result.modelUnavailable, let model = entry.model { result.text = modelRefusal(model, result.text) }
        result.toolUses = toolUses
        result.durationMs = durationMs
        return (result, entry)
    }

    /// The calling session's own account among lastdrop's, as `ownAccountUUID` names it.
    static func ownAccount(_ accounts: [ClaudeAccount], own: String?) -> ClaudeAccount? {
        guard let own else { return nil }
        return accounts.first { ClaudeProvider.signedInAccount(configDir: $0.cliConfigDir).uuid == own }
    }

    /// Where an admitted agent runs next: the other account with the most room, else the session's own.
    static func nextAccount(_ accounts: [ClaudeAccount], config: ClaudeAccountsConfig, own: String?,
                            excluding tried: Set<String>) async -> ClaudeAccount? {
        if let account = await pick(accounts, config: config, own: own, excluding: tried) { return account }
        guard let mine = ownAccount(accounts, own: own), !tried.contains(mine.id) else { return nil }
        SubagentLog.write("no other account has room → \(mine.id), the session's own")
        return mine
    }

    /// Runs an agent from lastdrop's list on its provider: its answer, or an error when the provider didn't
    /// take it. Nothing stands in for it: no other provider, no built-in agent.
    static func runDefined(_ definition: AgentDefinition, _ request: Request, agentID: String, resume: AgentRegistry.Entry?,
                           mcpConfig: String?) async {
        SubagentLog.write("\(agentID) \(resume == nil ? "start" : "continue") \(definition.name) on \(definition.summary)")
        // A follow-up continues on the model that ran, with no chain; a new run goes through the primary, then each
        // fallback, while an attempt fails before any work for a reason about availability.
        let attempts = resume == nil ? definition.attempts : [definition]
        // The stop command finds a runner by this record, between attempts as well as during one.
        AgentRegistry.setProcess(agentID, claude: 0)
        var failures: [String] = []
        var skipped: [(provider: AgentProvider, model: String)] = []
        var last: SubagentRunner.Result?
        var anyStarted = false
        func name(_ entry: (provider: AgentProvider, model: String)) -> String {
            // A model that appears twice in the chain is told apart by its provider.
            attempts.filter { $0.model == entry.model }.count > 1 ? "\(entry.provider.displayName) \(entry.model)" : entry.model
        }
        for (index, attempt) in attempts.enumerated() {
            if index > 0, AgentRegistry.wasStopped(agentID), let last {
                // Stopped between two attempts: no other one starts.
                if anyStarted { finish(agentID, last, account: last.account, agent: true, provider: attempts[index - 1].provider) } else { fail(agentID, last) }
                return
            }
            let launch = Launch()
            let job = AgentJob(agentID: agentID, definition: attempt, prompt: request.prompt, cwd: resume?.directory ?? request.cwd,
                               effort: effort(attempt, request, resume: resume), permissionMode: request.permissionMode ?? "default",
                               worktree: request.isolation == "worktree", mcpConfig: mcpConfig, resume: resume,
                               role: resume?.role ?? request.role)
            let events = AgentEvents(
                process: { AgentRegistry.setProcess(agentID, claude: $0) },
                started: { place, model in
                    guard launch.begin() else { return }
                    emit(["type": "started", "agentId": agentID, "account": place, "model": model, "provider": attempt.provider.rawValue,
                          "outputFile": logURL(agentID).path])
                    log(agentID, "Started \(attempt.name) on \(place) (\(model)): \(request.description ?? "")")
                },
                step: { step(agentID, $0) },
                item: { item(agentID, $0) },
                note: { log(agentID, "• " + $0) })
            var result = await backends(attempt.provider).run(job, events)
            anyStarted = anyStarted || launch.started
            last = result
            let isLast = index == attempts.count - 1
            // The attempt's process is over; a stop now has no process to end, only the chain.
            if !isLast { AgentRegistry.setProcess(agentID, claude: 0) }
            let failedToStart = !AgentRegistry.wasStopped(agentID) && result.failedToStart
            // Whatever ended it before it started, nothing it made stays behind: a worktree would block the next attempt's name.
            if (failedToStart || !launch.started), resume == nil, !isLast || !launch.started {
                noteWorktree(&result, isolation: request.isolation, cwd: request.cwd)
                if let path = result.worktreePath, AgentWorktree.isUnchanged(path), AgentWorktree.remove(path) {
                    result.worktreePath = nil
                    result.worktreeBranch = nil
                }
            }
            if failedToStart {
                let reason = String(result.text.split(separator: "\n").first ?? "").prefix(160)
                failures.append("\(attempt.provider.displayName) \(attempt.model): \(reason)")
                if !isLast {
                    skipped.append((attempt.provider, attempt.model))
                    let next = attempts[index + 1]
                    SubagentLog.write("\(agentID) \(attempt.model) can't start (\(reason)); trying \(next.model) on \(next.provider.displayName)")
                    emit(["type": "moved", "account": result.account ?? attempt.provider.displayName,
                          "reason": "\(attempt.model) can't start: \(reason)", "provider": next.provider.rawValue, "model": next.model])
                    continue
                }
                if attempts.count > 1 {
                    result.text = "No attempt of \(definition.name) could start:\n" + failures.map { "- " + $0 }.joined(separator: "\n")
                }
            }
            guard launch.started else { return fail(agentID, result) }
            // The models skipped on the way: never the attempt that ran, nor the last one that failed.
            result.skipped = skipped.map(name)
            await conclude(attempt, result, request, agentID: agentID, resume: resume, job: job)
            return
        }
    }

    /// What follows an attempt that ran: the report, the worktree, the entry a follow-up continues, the result line.
    private static func conclude(_ definition: AgentDefinition, _ finished: SubagentRunner.Result, _ request: Request, agentID: String,
                                 resume: AgentRegistry.Entry?, job: AgentJob) async {
        var result = finished
        requireReport(&result, from: definition)
        // The backends make their worktrees differently (detached, or on a branch of their own); where the run
        // ended up tells which, whichever made it.
        if let resume {
            result.worktreePath = resume.worktreePath
            result.worktreeBranch = resume.worktreeBranch
        } else {
            noteWorktree(&result, isolation: request.isolation, cwd: request.cwd)
            // As Claude Code does for its own: a worktree where nothing changed is removed, so the run
            // reports and continues (SendMessage) in the folder it was called in.
            if let path = result.worktreePath, definition.provider == .codex || definition.provider == .antigravity,
               AgentWorktree.isUnchanged(path), AgentWorktree.remove(path) {
                result.worktreePath = nil
                result.worktreeBranch = nil
                result.directory = request.cwd
            }
        }
        // The entry keeps the attempt that ran, so a follow-up continues on that model and not the chain.
        var entry = resume ?? AgentRegistry.Entry(account: result.account ?? definition.provider.displayName, directory: request.cwd,
                                                   sessionID: "", model: definition.model, subagentType: definition.name,
                                                   effort: job.effort, at: Date(), definition: definition, accountID: result.accountID,
                                                   role: job.role)
        if resume == nil {
            entry.worktreePath = result.worktreePath
            entry.worktreeBranch = result.worktreeBranch
        }
        if let session = result.sessionID, !session.isEmpty {
            var updated = entry
            updated.sessionID = session
            AgentRegistry.remember(agentID, entry: updated, at: result.directory)
        }
        finish(agentID, result, account: result.account ?? definition.provider.displayName, agent: true, provider: definition.provider)
    }

    /// A run that reports nothing is a failure whatever the provider, never a silent success.
    static func requireReport(_ result: inout SubagentRunner.Result, from definition: AgentDefinition) {
        guard !result.isError, result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        result.isError = true
        result.text = "\(definition.provider.displayName) returned an empty report for \(definition.name)."
    }

    /// Notes where a run with worktree isolation ended up, when that isn't the folder it was called in.
    static func noteWorktree(_ result: inout SubagentRunner.Result, isolation: String?, cwd: String) {
        guard isolation == "worktree", let directory = result.directory, directory != cwd else { return }
        // Where it ran may be a subfolder of the worktree; the worktree is its top.
        let top = AgentWorktree.root(of: directory) ?? directory
        result.worktreePath = top
        result.worktreeBranch = branch(of: top)
    }

    /// The branch a worktree has checked out; nil when it is detached or git can't say.
    static func branch(of directory: String) -> String? {
        let git = Process(), output = Pipe()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", directory, "symbolic-ref", "--short", "-q", "HEAD"]
        git.standardOutput = output
        git.standardError = FileHandle.nullDevice
        guard (try? git.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        git.waitUntilExit()
        let name = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return git.terminationStatus == 0 && !name.isEmpty ? name : nil
    }

    /// What a run's callbacks share: whether `started` went out, which happens once Claude Code's init
    /// passed the check, on whichever account and attempt that was.
    final class Launch: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        var started: Bool { lock.lock(); defer { lock.unlock() }; return done }

        /// Marks it started: true the first time only.
        func begin() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }

        /// The run's init check: a reason refuses it; otherwise `begin` runs, the first time only.
        func check(subagentType: String?, account: String, begin: @escaping @Sendable ([String: Any]) -> Void) -> @Sendable ([String: Any]) -> String? {
            { [self] event in
                if let reason = SubagentRunner.checkInit(event, subagentType: subagentType) { return "\(reason) on the \(account) account" }
                lock.lock()
                let first = !done
                done = true
                lock.unlock()
                if first { begin(event) }
                return nil
            }
        }
    }

    /// It never started: why, as an error for the plugin to show. Nothing else stands in for it.
    private static func fail(_ agentID: String, _ result: SubagentRunner.Result) {
        AgentRegistry.setProcess(agentID, claude: nil)
        _ = AgentRegistry.takeStopped(agentID)
        emit(["type": "error", "text": result.text.isEmpty ? "Claude Code stopped before it started." : result.text])
    }

    static let noRoom = "No other Claude account has room right now. Use built-in subagents."

    /// The effort a run takes: a follow-up's own, else the call's, else the one the agent's definition fixes.
    static func effort(_ definition: AgentDefinition, _ request: Request, resume: AgentRegistry.Entry?) -> String? {
        resume?.effort ?? request.effort ?? definition.effort
    }

    /// What the caller reads when no account could run the model: never a different model in its place.
    static func modelRefusal(_ model: String?, _ detail: String) -> String {
        "No Claude account lastdrop can use includes \(model ?? "the model"), and no other model stands in for it. \(detail)"
    }

    /// The account with the most room.
    static func pick(_ accounts: [ClaudeAccount], config: ClaudeAccountsConfig, own: String?,
                             excluding tried: Set<String>, log: Bool = true) async -> ClaudeAccount? {
        var candidates: [SubagentAccounts.Candidate] = []
        let allowOwn = FileManager.default.fileExists(atPath: LastDropPaths.allowOwnAccount.path)
        for account in accounts where !tried.contains(account.id) {
            guard let signedIn = ClaudeProvider.signedInAccount(configDir: account.cliConfigDir).uuid, allowOwn || signedIn != own else { continue }
            let usage = await SubagentUsage.shared.usage(account)
            candidates.append(.init(account: account, name: account.id, sessionUsed: usage.session, weeklyUsed: usage.weekly,
                                    active: AgentRegistry.running(account.id)))
        }
        let choice = SubagentAccounts.pick(candidates, sessionThreshold: config.sessionThreshold, weeklyThreshold: config.weeklyThreshold)
        if log { SubagentLog.write("own \(own?.prefix(8) ?? "?"); " + candidates.map {
            "\($0.name) session \($0.sessionUsed.map { "\(Int($0))%" } ?? "?") weekly \($0.weeklyUsed.map { "\(Int($0))%" } ?? "?")"
        }.joined(separator: ", ") + " → \(choice?.name ?? "none")") }
        return choice?.account
    }

    /// Built-in subagents inherit the parent's mode. A headless run can't ask, so "default" (ask each
    /// time) becomes auto, where Claude Code's classifier decides what would have been asked.
    static func mappedPermissionMode(_ mode: String?) -> String {
        guard let mode, !mode.isEmpty, mode != "default" else { return "auto" }
        return mode
    }

    private static func writeMCPConfig(directory: String) -> String? {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/.claude.json")
        guard let root = (try? Data(contentsOf: url)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
              let config = SubagentRunner.mcpConfig(from: root, directory: directory),
              let data = try? JSONSerialization.data(withJSONObject: config, options: .sortedKeys) else { return nil }
        // Named by content: the same servers give the same arguments, which a ready process must match.
        let digest = SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
        let file = LastDropPaths.agentsDir.appendingPathComponent("mcp-\(digest).json")
        LastDropPaths.ensure(LastDropPaths.agentsDir)
        guard (try? data.write(to: file, options: .atomic)) != nil else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file.path
    }

    // MARK: Output

    static func logURL(_ agentID: String) -> URL { LastDropPaths.agentsDir.appendingPathComponent("\(agentID).log") }

    private static func step(_ agentID: String, _ text: String) {
        emit(["type": "step", "text": text])
    }

    /// A transcript entry for the plugin's row, and in readable form for the agent's log (its `outputFile`).
    private static func item(_ agentID: String, _ item: [String: Any]) {
        var line = item
        line["type"] = "item"
        emit(line)
        switch item["kind"] as? String {
        case "text": log(agentID, item["text"] as? String ?? "")
        case "tool": log(agentID, "→ \(item["summary"] as? String ?? "")")
        case "result": log(agentID, "← " + (item["text"] as? String ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(20).joined(separator: "\n   "))
        default: break
        }
    }

    /// `lastdrop --agent-open <agentId>`: Terminal on the agent's own Claude Code session, on its account,
    /// where its whole transcript reads as any session's and can be continued.
    static func openMain() -> Never {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--agent-open"), i + 1 < args.count,
              let entry = AgentRegistry.lookup(args[i + 1]),
              let lines = (entry.definition?.provider ?? .claude).backend.terminal(entry) else { exit(1) }
        let script = LastDropPaths.agentsDir.appendingPathComponent("open-\(args[i + 1]).command")
        LastDropPaths.ensure(LastDropPaths.agentsDir)
        let body = "#!/bin/zsh -l\n\(lines)\n"
        guard (try? body.write(to: script, atomically: true, encoding: .utf8)) != nil else { exit(1) }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [script.path]
        try? open.run()
        open.waitUntilExit()
        exit(0)
    }

    /// `lastdrop --agent-stop <agentId>`: TaskStop for an agent lastdrop runs. Ends its Claude Code
    /// process; its runner then reports it stopped.
    static func stopMain() -> Never {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--agent-stop"), i + 1 < args.count else { exit(2) }
        let id = args[i + 1]
        // The runner may be between two attempts of a chain, with no Claude Code or provider process to end.
        guard AgentRegistry.runnerAlive(id) else {
            emit(["type": "error", "text": "Agent \(id) isn't running."])
            exit(1)
        }
        AgentRegistry.markStopped(id)
        if let pid = AgentRegistry.process(id) { SubagentRunner.terminate(pid) }
        emit(["type": "stopped"])
        exit(0)
    }

    private static func finish(_ agentID: String, _ result: SubagentRunner.Result, account: String?, agent: Bool = false,
                               provider: AgentProvider? = nil) {
        AgentRegistry.setProcess(agentID, claude: nil)
        if AgentRegistry.takeStopped(agentID) {
            log(agentID, "Stopped.")
            var object: [String: Any] = ["type": "result", "text": "Stopped.", "isError": true, "stopped": true,
                                         "toolUses": result.toolUses, "durationMs": result.durationMs]
            if let account { object["account"] = account }
            emit(object)
            return
        }
        log(agentID, result.isError ? "Failed: \(result.text.prefix(500))" : "Finished.\n\n\(result.text)")
        var object: [String: Any] = [
            "type": "result", "text": result.text, "isError": result.isError, "limitReached": result.limitReached,
            "toolUses": result.toolUses, "durationMs": result.durationMs, "turns": result.turns,
            "inputTokens": result.inputTokens, "outputTokens": result.outputTokens, "permissionDenials": result.permissionDenials,
            "cacheReadInputTokens": result.cacheReadInputTokens, "cacheCreationInputTokens": result.cacheCreationInputTokens,
        ]
        if let account { object["account"] = account }
        if let model = result.model { object["model"] = model }
        if let path = result.worktreePath { object["worktreePath"] = path }
        if let branch = result.worktreeBranch { object["worktreeBranch"] = branch }
        if agent, !result.declined.isEmpty { object["declined"] = result.declined }
        if let provider { object["provider"] = provider.rawValue }
        if !result.skipped.isEmpty { object["unavailable"] = result.skipped }
        emit(object)
    }

    private static func log(_ agentID: String, _ text: String) {
        LastDropPaths.ensure(LastDropPaths.agentsDir)
        let url = logURL(agentID)
        let line = Data("\(ISO8601DateFormatter().string(from: Date())) \(text)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(line); try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }
}

/// One line per decision in ~/Library/Logs/lastdrop/subagents.log, to see why an account was or wasn't used.
enum SubagentLog {
    static func write(_ line: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/lastdrop/subagents.log")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let entry = Data("\(ISO8601DateFormatter().string(from: Date())) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(entry); try? handle.close()
        } else {
            try? entry.write(to: url)
        }
    }
}

/// What lastdrop remembers about the agents it ran, shared by every runner process: which account and
/// session each agent is (for SendMessage), which accounts lack which models, and what is running now.
enum AgentRegistry {
    /// An agent as a follow-up needs it: where it ran (a worktree's folder with `--worktree`), its session,
    /// and what it was started as, which `--resume` alone doesn't bring back.
    struct Entry: Codable {
        var account: String
        var directory: String
        var sessionID: String
        var model: String?
        var subagentType: String?
        var effort: String?
        var at: Date
        /// For an agent from lastdrop's list, the definition it started with: a follow-up runs with it even
        /// after the list changed.
        var definition: AgentDefinition?
        /// For an agent from lastdrop's list: the `Account.id` it runs on.
        var accountID: String?
        /// `Explore` or `Plan` for an agent called as a read-only role: a follow-up stays read-only.
        var role: String?
        /// Where it ran when it had a worktree of its own, and the branch when that has one: a follow-up reports them again.
        var worktreePath: String?
        var worktreeBranch: String?
    }
    /// A running agent's processes: its runner's and Claude Code's.
    struct Processes: Codable { var runner: Int32; var claude: Int32 }
    /// The ledger file. Older and newer lastdrop versions read and write it by turns, so it keeps every key an
    /// older version requires (`lacking`, `fullUntil`), and no key here is required to decode: a missing or
    /// unknown one never makes the whole ledger unreadable.
    struct Store: Codable {
        var agents: [String: Entry] = [:]
        var fullUntil: [String: Date] = [:]     // account → when to try it again after "limit reached"
        var processes: [String: Processes]? = [:]
        var stopped: [String]? = []             // agents TaskStop ended, until their runner reported it

        init() {}

        private enum Keys: String, CodingKey { case agents, lacking, fullUntil, processes, stopped }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            agents = try c.decodeIfPresent([String: Entry].self, forKey: .agents) ?? [:]
            fullUntil = try c.decodeIfPresent([String: Date].self, forKey: .fullUntil) ?? [:]
            processes = try c.decodeIfPresent([String: Processes].self, forKey: .processes) ?? [:]
            stopped = try c.decodeIfPresent([String].self, forKey: .stopped) ?? []
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(agents, forKey: .agents)
            // Older versions require `lacking` (the models an account's plan lacked, which is no longer kept).
            try c.encode([String: [String]](), forKey: .lacking)
            try c.encode(fullUntil, forKey: .fullUntil)
            try c.encode(processes ?? [:], forKey: .processes)
            try c.encode(stopped ?? [], forKey: .stopped)
        }

        mutating func forget(_ id: String) {
            agents[id] = nil
            processes?[id] = nil
            stopped?.removeAll { $0 == id }
        }
    }

    /// Tests keep the ledger in a file of their own.
    nonisolated(unsafe) static var fileOverride: URL?

    private static func withStore<T>(_ body: (inout Store) -> T) -> T {
        LastDropPaths.ensure(LastDropPaths.support)
        let lockFD = open((AgentRegistry.fileOverride.map { $0.path + ".lock" } ?? LastDropPaths.agentsLock.path), O_CREAT | O_RDWR, 0o600)
        if lockFD >= 0 { flock(lockFD, LOCK_EX) }
        defer { if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) } }
        var (store, writable) = readStore(at: fileOverride ?? LastDropPaths.agents)
        let value = body(&store)
        if store.agents.count > 500 {
            store.agents = Dictionary(uniqueKeysWithValues: store.agents.sorted { $0.value.at > $1.value.at }.prefix(400).map { ($0.key, $0.value) })
        }
        if writable { try? JSONEncoder.lastdrop.encode(store).write(to: fileOverride ?? LastDropPaths.agents, options: .atomic) }
        return value
    }

    /// The ledger at `url`, and whether this call may write it back. A missing file is a new ledger. A file that
    /// exists but can't be read or decoded is never written over or deleted: it is moved to a unique
    /// `<name>.unreadable-<timestamp>`, and only once that holds does this call start a new ledger. If the move
    /// fails, the call works on an empty ledger it doesn't save: losing one update is better than the ledger.
    static func readStore(at url: URL, move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) })
        -> (store: Store, writable: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (Store(), true) }
        if let data = try? Data(contentsOf: url), let store = try? JSONDecoder.lastdrop.decode(Store.self, from: data) {
            return (store, true)
        }
        return (Store(), UnreadableFile.moveAside(url, move: move))
    }

    static func remember(_ id: String, entry: Entry, at directory: String? = nil) {
        var entry = entry
        if let directory { entry.directory = directory }
        entry.at = Date()
        withStore { $0.agents[id] = entry }
    }

    /// Records the Claude Code process running `id` (nil: none any more), beside this runner's own.
    static func setProcess(_ id: String, claude pid: Int32?) {
        withStore { store in
            store.processes = (store.processes ?? [:]).filter { kill($0.value.runner, 0) == 0 }
            store.processes?[id] = pid.map { Processes(runner: getpid(), claude: $0) }
        }
    }

    /// The Claude Code process running `id`, while the runner that started it is alive (so the pid is still its).
    static func process(_ id: String) -> Int32? {
        withStore { store in
            guard let p = store.processes?[id], p.claude > 0, kill(p.runner, 0) == 0 else { return nil }
            return p.claude
        }
    }

    /// Whether the runner of `id` is alive, whether or not a process of its own is running right now.
    static func runnerAlive(_ id: String) -> Bool {
        withStore { store in store.processes?[id].map { kill($0.runner, 0) == 0 } ?? false }
    }

    /// Only processes handed to this runner, including ones claimed from the warm pool.
    static func ownedProcesses() -> [Int32] {
        withStore { store in
            (store.processes ?? [:]).values.filter { $0.runner == getpid() && $0.claude > 0 }.map(\.claude)
        }
    }

    static func markStopped(_ id: String) { withStore { $0.stopped = ($0.stopped ?? []).filter { $0 != id } + [id] } }

    static func wasStopped(_ id: String) -> Bool { withStore { $0.stopped?.contains(id) ?? false } }

    /// Whether TaskStop ended `id`, forgetting it.
    static func takeStopped(_ id: String) -> Bool {
        withStore { store in
            guard store.stopped?.contains(id) == true else { return false }
            store.stopped?.removeAll { $0 == id }
            return true
        }
    }

    /// Drops an agent that never ran, so a follow-up doesn't find an entry for the built-in agent's work.
    static func forget(_ id: String) {
        withStore { $0.forget(id) }
    }

    static func lookup(_ id: String) -> Entry? { withStore { $0.agents[id] } }

    /// Agents whose runner is alive, newest first: read without the lock and without writing, for the panel.
    static func runningNow() -> [(id: String, entry: Entry)] {
        guard let store = (try? Data(contentsOf: fileOverride ?? LastDropPaths.agents)).flatMap({ try? JSONDecoder.lastdrop.decode(Store.self, from: $0) })
        else { return [] }
        return (store.processes ?? [:]).compactMap { id, p in
            guard p.claude > 0, kill(p.runner, 0) == 0, let entry = store.agents[id] else { return nil }
            return (id, entry)
        }.sorted { $0.entry.at > $1.entry.at }
    }

    static func markFull(_ account: String) { withStore { $0.fullUntil[account] = Date().addingTimeInterval(600) } }

    static func isFull(_ account: String) -> Bool { withStore { ($0.fullUntil[account] ?? .distantPast) > Date() } }

    /// Marks this runner as working on `account` (nil: on none) for `running(_:)`.
    static func setRunning(_ account: String?) {
        let dir = LastDropPaths.agentsDir.appendingPathComponent("running")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix("\(getpid()).") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        if let account { FileManager.default.createFile(atPath: dir.appendingPathComponent("\(getpid()).\(account)").path, contents: nil) }
    }

    /// Runner processes alive on an account, from their pid files; spreads parallel agents over accounts.
    static func running(_ account: String) -> Int {
        let dir = LastDropPaths.agentsDir.appendingPathComponent("running")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { name in
            let parts = name.split(separator: ".")
            guard parts.count == 2, parts[1] == account, let pid = Int32(parts[0]) else { return false }
            return kill(pid, 0) == 0
        }.count
    }
}
