import { expect, test } from 'claude-code/testing'

// The seam under test is a native spawn followed by its model step. Core tool results stay opaque;
// the runner supplies JSON lines, and a model request beneath turn.step is counted as a routing failure.
const ID = 'a1111111111111111'
const NATIVE = { status: 'async_launched', agentId: ID, marker: 'core owns this answer' }
const RESULT = { type: 'result', text: 'exact remote report\n', inputTokens: 100, outputTokens: 10,
                 cacheReadInputTokens: 50, cacheCreationInputTokens: 20, model: 'claude-haiku-5-5',
                 context: { inputTokens: 30, outputTokens: 10, cacheReadInputTokens: 50, cacheCreationInputTokens: 20 } }
// A long remote turn: ~1.77M tokens over its many requests, while its last request held 42k.
const LONG = { ...RESULT, inputTokens: 1_770_000, outputTokens: 30_000, cacheReadInputTokens: 1_700_000, cacheCreationInputTokens: 60_000,
               context: { inputTokens: 3, outputTokens: 200, cacheReadInputTokens: 41_000, cacheCreationInputTokens: 700 } }
/** The context size Claude Code reads from a turn's stop: its last request's input and output. */
function contextOf(chunks: { kind: string; usage?: unknown }[]): number {
  const u = chunks.find(c => c.kind === 'stop')?.usage as Record<string, number> | null | undefined
  return u ? u.input_tokens! + u.cache_read_input_tokens! + u.cache_creation_input_tokens! + u.output_tokens! : 0
}
const CATALOG = { revision: 3, agents: [
  { name: 'sol', description: 'Reviews: hard bugs.', provider: 'codex', summary: 'Codex · gpt-6.1-sol · high', prompt: 'You are sol.' },
  { name: 'argon', description: 'Advisor: trade-offs.', provider: 'antigravity', summary: 'Antigravity · gemini-4-argon', prompt: 'You are argon.' },
] }
const TYPES = 'The lastdrop: agent types are agents the user added; each runs on the provider and model its description names.'
const SOL = 'Reviews: hard bugs. (Codex · gpt-6.1-sol · high)'
const ARGON = 'Advisor: trade-offs. (Antigravity · gemini-4-argon)'
const POINTER = '\nOnly if the user asks to change these, run '
const COMMAND = `${POINTER}${new URL('..', import.meta.url).pathname.replace(/\/$/, '')}/../../../MacOS/lastdrop --agents --help`
const NATIVE_LISTING = 'Available agent types for the Agent tool:\n- general-purpose: Does things.'
const HANDBACK = '<system-reminder>\nYour final report is delivered through SubagentHandback: when your work is complete, call SubagentHandback({message: <your full report>}). The call ends your run, so make it your last step. Only a SubagentHandback call reaches your caller as your result; plain text you write at the end is not delivered. Do not also send the report with SendMessage: your caller would get it twice.\n</system-reminder>'
type Body = Parameters<typeof test>[1] extends infer B ? (B extends (...args: infer A) => unknown ? A : never) : never
const lines = (...objects: object[]) => objects.map(o => JSON.stringify(o)).join('\n') + '\n'
type Message = { role: 'user' | 'assistant'; content: { type: string; text?: string }[] }
type Options = {
  route?: object; background?: boolean; fork?: boolean; workflow?: boolean; refusal?: string; 
  outputs?: object[]; gate?: Promise<void>; wrongID?: boolean; noStart?: boolean; catalog?: typeof CATALOG; handback?: boolean
  storeFailure?: boolean; selfTest?: object; nativeTasks?: boolean; liveCatalog?: () => object; runnerFails?: boolean; agentModels?: boolean; before?: object[]; spawnId?: () => string; noAgentTool?: boolean; storeLimit?: number; sessionId?: () => string; env?: Record<string, string>; t3?: Record<string, object>; t3Throws?: boolean
  /** How T3 answers a delegate_task on the `lastdrop` instance: refuses (the default, so the tests of the call as it was run on it), accepts, or answers a given error. */
  lastdrop?: 'accept' | { error: string }
  /** What `--agent-catalog` says of lastdrop's own T3 instance: set up (true), or not (absent, as an older app). */
  t3Instance?: boolean
  /** `--delegate-note` answers an error, as with a full disk. */
  notesFail?: boolean
  /** T3 tools that answer with this error (isError), as T3 failing a call. */
  t3Errors?: Record<string, string>
  /** false: an app without `--delegate-note` (older), so plain T3 children take the tag path outside auto mode. */
  notes?: false
  /** What `t3_thread_read` on the child's own thread says: its parent, no parent (null), or an error. */
  lineage?: string | null | 'error'
}

function engine([$test, on]: Body, options: Options = {}) {
  const calls: { flag: string; request: Record<string, unknown> }[] = []
  const spawned: object[] = []
  const nativeCalls: string[] = []
  const nativeInputs: Record<string, unknown>[] = []
  const statuses: (string | undefined)[] = []
  const submitted: (readonly string[] | undefined)[] = []
  const invalidated: string[] = []
  const registered: { name: string; description: string; prompt: string }[] = []
  const store = new Map<string, unknown>()
  // lastdrop's note ledger (`--delegate-note`), as the app keeps it: expiry is the plugin's to check here.
  const notes: Record<string, unknown>[] = []
  const mcpCalls: Record<string, unknown>[] = []
  let env: Record<string, string> = { ...options.env }
  // The session's folder as a hook reads it: a worktree subagent's own loop reads its worktree.
  let cwd = '/work'
  const context = (value: Message[]) => options.handback === false ? value : value.map((m, i) =>
    i === 0 ? { ...m, content: [...m.content, { type: 'text', text: HANDBACK }] } : m)
  let messages: Message[] = context([{ role: 'user', content: [{ type: 'text', text: 'initial task' }] }])
  let modelSteps = 0
  let runCount = 0
  // Folders that are gone (a worktree the engine removed); git answers by subcommand.
  const missing = new Set<string>()
  const gitAnswers: Record<string, string> = { 'status': ' M notes.txt', 'symbolic-ref': 'worktree-agent-x', 'reflog': 'a\nb' }
  on('fs.exists', (_, e) => ({ value: !missing.has(e.path) }))
  on('env.get', (_, e) => ({ value: env[e.name] }))
  on('clock.sleep', () => ({ value: undefined }))
  on('mcp.call', (_, e) => {
    mcpCalls.push(e as never)
    if (options.lineage === 'error' || options.lineage === undefined) return { value: { content: [{ type: 'text', text: 'not connected' }], isError: true } } as never
    const threadId = (e.args as Record<string, unknown>).threadId
    const thread = { threadId, parentThreadId: options.lineage, relationshipToParent: options.lineage === null ? null : 'subagent' }
    return { value: { content: [{ type: 'text', text: JSON.stringify({ thread, recentRuns: [], items: [] }) }], isError: false } } as never
  })
  on('session.cwd', () => ({ value: cwd }))
  on('session.id', () => ({ value: options.sessionId?.() ?? 'session-1' }))
  on('session.model', () => ({ value: 'claude-haiku-5-5' }))
  on('session.messages', () => ({ value: messages }))
  on('store.get', (_, e) => ({ value: store.get(e.key) }))
  on('store.keys', () => ({ value: [...store.keys()] }))
  on('store.delete', (_, e) => { store.delete(e.key); return { value: undefined } })
  on('store.set', (_, e) => {
    if (options.storeFailure) return { deny: 'disk full' }
    const size = [...store].reduce((n, [k, v]) => n + (k === e.key ? 0 : k.length + JSON.stringify(v).length), e.key.length + JSON.stringify(e.value).length)
    if (options.storeLimit !== undefined && size > options.storeLimit) return { deny: 'store over its limit' }
    store.set(e.key, JSON.parse(JSON.stringify(e.value)))
    return { value: undefined }
  })
  let opened = 0
  on('ui.open', () => { opened++; return { value: { isPlaced: true } } })
  on('ui.status', (_, e) => { statuses.push(e.text); return { value: undefined } })
  on('ui.log', () => ({ value: undefined }))
  on('ui.toast', () => ({ value: undefined }))
  on('ui.invalidate', (_, e) => { invalidated.push(e.event); return { value: undefined } })
  on('tool.list', () => ({ value: options.noAgentTool ? [] : [{ name: 'Agent' }] as never }))
  on('agent.offer', () => ({ isOffered: true }))
  on('session.compact', (_, e) => ({ messages: e.messages }))
  on('tool.describe', (_, e) => ({ description: e.description }))
  on('prompt.attachment', (_, e) => ({ text: e.text }))
  on('command.register', (_, e) => ({ value: { command: `lastdrop:${e.name}` } }))
  on('agent.register', (_, e) => { registered.push(e as never); return { value: { agent: `lastdrop:${e.name}` } } })
  on('process.run', (_, e) => {
    const sub = (e.argv as string[])[3] ?? ''
    const out = gitAnswers[sub]
    return { value: { exitCode: out === undefined ? 1 : 0, stdout: out === undefined ? '' : `${out}\n`, stderr: '' } } as never
  })
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('classic.UserPromptSubmit', () => ({}))
  on('prompt.submit', (_, e) => { submitted.push(e.context); return { text: e.text, context: e.context } })
  on('process.spawn', async function* (_, e) {
    const flag = e.argv[1] ?? ''
    const request = JSON.parse(e.input || '{}') as Record<string, unknown>
    calls.push({ flag, request })
    if (options.runnerFails) throw new Error('no runner')
    if (flag === '--agent-route') yield { stream: 'stdout', text: lines(options.route ?? { type: 'routed' }) }
    else if (flag === '--agent-catalog') yield { stream: 'stdout', text: lines({ ...(options.liveCatalog?.() ?? options.catalog ?? { revision: 1, agents: [] }), nativeTasks: options.nativeTasks ?? true, agentModels: options.agentModels ?? true, ...(options.t3Instance === undefined ? {} : { t3Instance: options.t3Instance }), ...(options.notes === false ? {} : { delegateNotes: true }) }) }
    else if (flag === '--delegate-note' && options.notesFail) yield { stream: 'stdout', text: lines({ type: 'error', text: 'disk full' }) }
    else if (flag === '--delegate-note') {
      const op = request.op
      if (op === 'put') notes.push({ ...(request.note as object) })
      if (op === 'drop') notes.splice(0, notes.length, ...notes.filter(n => n.id !== request.id || n.thread !== undefined))
      if (op === 'list') {
        const bound = notes.find(n => n.thread === request.thread)
        yield { stream: 'stdout', text: lines({ type: 'ok', open: notes.filter(n => n.thread === undefined), ...(bound ? { bound } : {}) }) }
      } else if (op === 'claim') {
        const note = notes.find(n => n.id === request.id)
        if (note && (note.thread === undefined || note.thread === request.thread)) {
          note.thread = request.thread
          yield { stream: 'stdout', text: lines({ type: 'ok', note }) }
        } else yield { stream: 'stdout', text: lines({ type: 'taken' }) }
      } else yield { stream: 'stdout', text: lines({ type: 'ok' }) }
    }
    else if (flag === '--agent-selftest') yield { stream: 'stdout', text: lines(options.selfTest ?? { type: 'ok' }) }
    else if (flag === '--agent-run') {
      runCount++
      if (options.before) yield { stream: 'stdout', text: lines(...options.before) }
      if (!options.noStart) yield { stream: 'stdout', text: lines({ type: 'started', agentId: options.wrongID ? 'old-runner-id' : request.id, account: 'Pro', model: 'haiku' }) }
      if (options.gate) await options.gate
      yield { stream: 'stdout', text: lines(...(options.outputs ?? [RESULT])) }
    }
    return { value: { code: 0, signal: null } }
  })
  on('tool.call', async (_, e) => {
    nativeCalls.push(e.tool)
    nativeInputs.push(e)
    if (options.t3Throws && e.tool.startsWith('mcp__t3-code__')) throw new Error('connection reset')
    const instance = (e.target as Record<string, unknown> | undefined)?.providerInstanceId
    if (e.tool === 'mcp__t3-code__delegate_task' && instance === 'lastdrop' && options.lastdrop !== 'accept') {
      const error = options.lastdrop?.error ?? 'Provider instance lastdrop is not registered.'
      return { isError: true, result: error, text: error } as never
    }
    const failure = options.t3Errors?.[e.tool]
    if (failure !== undefined) return { isError: true, result: failure, text: failure } as never
    const t3 = options.t3?.[e.tool]
    // As Claude Code gives a T3 tool's answer: one JSON string (blocks in older versions).
    if (t3) return { result: JSON.stringify(t3), text: JSON.stringify(t3) } as never
    if (e.tool !== 'Agent') return { result: { marker: `native ${e.tool}` } }
    if (options.refusal) return { deny: options.refusal }
    const spawn = await $test.agent.spawn({ tool_use_id: e.tool_use_id, prompt: e.prompt, description: e.description,
      subagentType: e.subagent_type ?? 'general-purpose', model: e.model, cwd: e.isolation === 'worktree' ? undefined : '/native', permissionMode: options.handback === false ? 'acceptEdits' : 'auto',
      parentModel: 'claude-haiku-5-5', background: options.background ?? true, fork: options.fork ?? false,
      workflow: options.workflow ? { runId: 'wf_x', agentIndex: 1 } : undefined } as never)
    if (spawn.deny !== undefined) return { deny: spawn.deny }
    return { result: NATIVE }
  })
  on('agent.spawn', (_, e) => { spawned.push(e); return { model: 'claude-haiku-5-5', agentId: options.spawnId?.() ?? ID } })
  on('turn.step', async function* (_, e) {
    modelSteps++
    yield { kind: 'text', index: 0, text: 'built-in response' }
    yield { kind: 'stop', stopReason: 'end_turn', usage: null }
    return { turnId: e.turnId, index: e.index, answer: 'built-in response', toolUses: [], stopReason: 'end_turn', usage: null }
  })
  return { calls, spawned, nativeCalls, nativeInputs, statuses, submitted, invalidated, store, registered, notes, mcpCalls,
    cwd(value: string) { cwd = value },
    env(value: Record<string, string>) { env = value },
    remove(path: string) { missing.add(path) },
    git(sub: string, out: string | undefined) { if (out === undefined) delete gitAnswers[sub]; else gitAnswers[sub] = out },
    get modelSteps() { return modelSteps }, get opened() { return opened }, get runCount() { return runCount },
    messages(value: Message[]) { messages = context(value) },
    async launch(fields: object = {}) {
      return $test.tool.call({ tool: 'Agent', tool_use_id: 'toolu_x', description: 'read a note', prompt: 'initial task', ...fields } as never)
    },
  }
}

async function step($: Body[0], turnId = 'turn-1', index = 0, agentId: string | undefined = ID) {
  const stream = $.turn.step({ turnId, index, agentId, model: 'claude-haiku-5-5', messageCount: 1 })
  const chunks = []
  for await (const chunk of stream) chunks.push(chunk)
  return chunks
}
async function resume($: Body[0], prompt: string) {
  await $.agent.spawn({ tool_use_id: '', prompt, description: 'read a note', subagentType: 'general-purpose',
    parentModel: 'haiku', permissionMode: 'auto', background: true, fork: false, resume: { agentId: ID } } as never)
}
/** A call's keys and values in order, so an added key (even one set to undefined) shows. */
const exact = (value: object) => Object.entries(value)

function report(chunks: Awaited<ReturnType<typeof step>>): string {
  return chunks.filter(c => c.kind === 'input' || c.kind === 'text').map(c => c.kind === 'input' ? JSON.parse(c.json).message : c.text).join('')
}

test('routing creates a real native task before running the remote agent, and preserves the native answer', async ($, on) => {
  const e = engine([$, on])
  const answer = await e.launch()
  expect(answer.result).toEqual(NATIVE)
  expect(e.spawned.length).toBe(1)
  expect(e.runCount).toBe(0)
  expect(e.calls.some(c => c.flag === '--agent-route')).toBe(true)
  const chunks = await step($)
  expect(report(chunks)).toBe(RESULT.text)
  expect(chunks.find(c => c.kind === 'tool')?.name).toBe('SubagentHandback')
  expect(e.modelSteps).toBe(0)
  const request = e.calls.find(c => c.flag === '--agent-run')!.request
  expect(request.id).toBe(ID)
  expect(request.cwd).toBe('/native')
  expect(request.permissionMode).toBe('auto')
  expect(request.background).toBe(true)
})

test('foreground routing uses the same native task and report adapter', async ($, on) => {
  const e = engine([$, on], { background: false })
  expect((await e.launch()).result).toEqual(NATIVE)
  expect(report(await step($))).toBe(RESULT.text)
  expect(e.calls.find(c => c.flag === '--agent-run')?.request.background).toBe(false)
  expect(e.modelSteps).toBe(0)
})

test('native agents without the handback instruction return plain text and end_turn', async ($, on) => {
  const e = engine([$, on], { handback: false })
  await e.launch()
  const chunks = await step($)
  expect(report(chunks)).toBe(RESULT.text)
  expect(chunks.some(c => c.kind === 'tool')).toBe(false)
  expect(chunks.find(c => c.kind === 'stop')?.stopReason).toBe('end_turn')
  expect(e.modelSteps).toBe(0)
})

test('no room leaves the native agent and its model calls untouched', async ($, on) => {
  const e = engine([$, on], { route: { type: 'no_room' } })
  expect((await e.launch()).result).toEqual(NATIVE)
  expect((await step($))[0]).toEqual({ kind: 'text', index: 0, text: 'built-in response' })
  expect(e.runCount).toBe(0)
  expect(e.modelSteps).toBe(1)
})

test('SDK hosts retain background routing', async ($, on) => {
  const e = engine([$, on])
  await $.session.start({ cwd: '/work', surface: null, isInteractive: false })
  await e.launch()
  expect(report(await step($))).toBe(RESULT.text)
  expect(e.modelSteps).toBe(0)
})

test('native SendMessage follow-ups resume the remote id and only forward the new message', async ($, on) => {
  const e = engine([$, on])
  await e.launch()
  await step($)
  e.messages([{ role: 'user', content: [{ type: 'text', text: 'initial task' }] },
    { role: 'assistant', content: [] },
    { role: 'user', content: [
      { type: 'text', text: 'The coordinator sent a message while you were working:\nnext task\n\nAddress this before completing your current task.\n' },
      { type: 'text', text: 'next task' },
    ] }])
  expect(report(await step($, 'turn-2'))).toBe(RESULT.text)
  const run = e.calls.filter(c => c.flag === '--agent-run').at(-1)!.request
  expect(run.resume).toBe(ID)
  expect(run.prompt).toBe('next task')
  expect(e.modelSteps).toBe(0)
})

test('a native agent restored from persistent routing state still resumes remotely', async ($, on) => {
  const e = engine([$, on])
  e.store.set(`native-agent:${ID}`, { request: { prompt: '', cwd: '/original', subagentType: 'Explore', effort: 'high' },
    description: 'restored agent', toolUseId: 'toolu_old', ran: true, cursor: 1 })
  e.messages([{ role: 'user', content: [{ type: 'text', text: 'old task' }] },
    { role: 'user', content: [{ type: 'text', text: 'follow-up after resume' }] }])
  expect(report(await step($))).toBe(RESULT.text)
  const request = e.calls.find(c => c.flag === '--agent-run')!.request
  expect(request.resume).toBe(ID)
  expect(request.prompt).toBe('follow-up after resume')
  expect(request.cwd).toBe('/original')
  expect(request.subagentType).toBe('Explore')
  expect(e.modelSteps).toBe(0)
})

test('a coordinator-only inbox wrapper forwards its message instead of losing it', async ($, on) => {
  const e = engine([$, on])
  await e.launch()
  await step($)
  e.messages([{ role: 'user', content: [{ type: 'text', text: 'initial task' }] },
    { role: 'user', content: [{ type: 'text', text: 'The coordinator sent a message while you were working:\nwrapped task\n\nAddress this before completing your current task.\n' }] }])
  expect(report(await step($, 'turn-2'))).toBe(RESULT.text)
  expect(e.calls.filter(c => c.flag === '--agent-run').at(-1)?.request.prompt).toBe('wrapped task')
})

test('a queued native resume forwards its pinned prompt before it appears in session.messages', async ($, on) => {
  let release = () => {}
  const gate = new Promise<void>(resolve => { release = resolve })
  const e = engine([$, on], { gate })
  await e.launch()
  const working = step($)
  for (let i = 0; i < 30 && e.runCount === 0; i++) await new Promise(resolve => setTimeout(resolve, 10))
  release()
  expect(report(await working)).toBe(RESULT.text)
  expect(e.runCount).toBe(1)
  e.messages([{ role: 'user', content: [{ type: 'text', text: 'initial task' }] },
    { role: 'assistant', content: [{ type: 'text', text: RESULT.text }] }])
  await resume($, 'message while working')
  expect(report(await step($, 'turn-2'))).toBe(RESULT.text)
  expect(e.runCount).toBe(2)
  expect(e.calls.filter(c => c.flag === '--agent-run')[1]?.request.prompt).toBe('message while working')
})

test('TaskStop, ListAgents and SendMessage remain native calls with native results', async ($, on) => {
  const e = engine([$, on])
  await e.launch()
  for (const name of ['TaskStop', 'ListAgents', 'SendMessage']) {
    const answer = await $.tool.call({ tool: name, task_id: ID, to: ID, message: 'hi' } as never)
    expect(answer.result).toEqual({ marker: `native ${name}` })
  }
  expect(e.calls.some(c => c.flag === '--agent-stop')).toBe(false)
  expect(e.runCount).toBe(0)
})

test('the remote run’s last request reaches the native stop chunk as its usage', async ($, on) => {
  const e = engine([$, on])
  await e.launch()
  const stop = (await step($)).find(c => c.kind === 'stop')
  expect(stop?.usage).toEqual({ model: 'claude-haiku-5-5', input_tokens: 30, output_tokens: 10,
                              cache_read_input_tokens: 50, cache_creation_input_tokens: 20 })
})

test('a backend that gives no last request reports no usage rather than its run total', async ($, on) => {
  const { context: _, ...total } = RESULT
  const e = engine([$, on], { outputs: [total] })
  await e.launch()
  expect((await step($)).find(c => c.kind === 'stop')?.usage).toBeNull()
})

test('after a long remote turn, a native agent’s follow-up goes through', async ($, on) => {
  const e = engine([$, on], { outputs: [LONG] })
  await e.launch()
  const first = await step($)
  expect(report(first)).toBe(RESULT.text)
  // Claude Code compares this with the child's window before the next turn; the run total would be ~1.77M.
  expect(contextOf(first)).toBe(41_903)
  e.messages([{ role: 'user', content: [{ type: 'text', text: 'initial task' }] },
    { role: 'assistant', content: [{ type: 'text', text: RESULT.text }] },
    { role: 'user', content: [{ type: 'text', text: 'next task' }] }])
  const second = await step($, 'turn-2')
  expect(report(second)).toBe(RESULT.text)
  expect(contextOf(second)).toBeLessThan(200_000)
  expect(e.calls.filter(c => c.flag === '--agent-run').at(-1)!.request).toMatchObject({ prompt: 'next task', resume: ID })
  expect(e.modelSteps).toBe(0)
})

test('an admission failure refuses the native spawn instead of falling back', async ($, on) => {
  const e = engine([$, on], { route: { type: 'error', text: 'routing is broken' } })
  expect((await e.launch()).deny).toContain('routing is broken')
  expect(e.spawned).toEqual([])
  expect(e.runCount).toBe(0)
})

test('an older app is rejected before calling a CLI mode it does not recognize', async ($, on) => {
  const e = engine([$, on], { nativeTasks: false })
  expect((await e.launch()).deny).toContain('Update the lastdrop app and plugin together')
  expect(e.calls.some(c => c.flag === '--agent-route')).toBe(false)
  expect(e.spawned).toEqual([])
})

test('a runner error is an explicit native report and never a local model request', async ($, on) => {
  const e = engine([$, on], { noStart: true, outputs: [{ type: 'error', text: 'missing agent type on Pro' }] })
  await e.launch()
  expect(report(await step($))).toContain('lastdrop agent failed: Error: missing agent type on Pro')
  expect(e.modelSteps).toBe(0)
})

test('a runner that ends without a report produces an explicit native failure report', async ($, on) => {
  const e = engine([$, on], { outputs: [{ type: 'step', text: 'Read: note.txt' }] })
  await e.launch()
  expect(report(await step($))).toContain('without the agent’s report')
  expect(e.modelSteps).toBe(0)
})

test('loss of room for an added model is an error, never execution on Claude', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG, noStart: true, outputs: [{ type: 'no_room' }] })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await e.launch({ subagent_type: 'lastdrop:sol' })
  expect(report(await step($))).toContain('No other account has room after the native agent started')
  expect(e.modelSteps).toBe(0)
})

test('a plain reroute with no room after the native spawn runs as the built-in agent', async ($, on) => {
  const e = engine([$, on], { noStart: true, outputs: [{ type: 'no_room' }] })
  await e.launch()
  expect((await step($))[0]).toEqual({ kind: 'text', index: 0, text: 'built-in response' })
  expect(e.modelSteps).toBe(1)
  expect(e.store.has(`native-agent:${ID}`)).toBe(false)
  expect(e.opened).toBe(0)
})

for (const started of [false, true]) {
  test(`a native line ${started ? 'after started' : 'with no started'} hands the run to the built-in agent`, async ($, on) => {
    const e = engine([$, on], { noStart: !started, outputs: [{ type: 'native' }] })
    await e.launch()
    expect((await step($))[0]).toEqual({ kind: 'text', index: 0, text: 'built-in response' })
    expect(e.modelSteps).toBe(1)
    expect(e.store.has(`native-agent:${ID}`)).toBe(false)
    expect(e.opened).toBe(0)
    expect(e.statuses.at(-1)).toBeUndefined()
    // Its later steps are the built-in agent's own.
    await step($, 'turn-1', 1)
    expect(e.modelSteps).toBe(2)
    expect(e.runCount).toBe(started ? 1 : 1)
    const pane = await $.ui.mount({ plugin: 'lastdrop', component: 'Pane', requestId: 'lastdrop-agents', props: {}, surface: 'terminal' })
    expect(await pane.find({ type: 'Text', text: /on Pro/ })).toBeFalsy()
    await pane.unmount()
  })
}

test('a native line for an added model is a visible failure, never the built-in agent', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG, outputs: [{ type: 'native' }] })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await e.launch({ subagent_type: 'lastdrop:sol' })
  expect(report(await step($))).toContain('handed the agent to the built-in agent')
  expect(e.modelSteps).toBe(0)
})

test('a plain reroute opens its pane on the first sign of work, not on started', async ($, on) => {
  const e = engine([$, on], { outputs: [{ type: 'step', text: 'Read: note.txt' }, RESULT] })
  await e.launch()
  await step($)
  expect(e.opened).toBe(1)
})

test('a run shows each step live as thinking in block 0, before its report in block 1', async ($, on) => {
  const e = engine([$, on], { outputs: [{ type: 'step', text: 'Bash: swift test' }, { type: 'tick' }, { type: 'step', text: 'Read: note.txt' }, RESULT] })
  await e.launch()
  const chunks = await step($)
  const thinking = chunks.filter(c => c.kind === 'thinking')
  expect(thinking.map(c => c.text)).toEqual(['Bash: swift test\n\n', 'Read: note.txt\n\n'])
  expect(thinking.every(c => c.index === 0)).toBe(true)
  expect(report(chunks)).toBe(RESULT.text)
  expect(chunks.find(c => c.kind === 'tool')).toMatchObject({ name: 'SubagentHandback', index: 1 })
  expect(chunks.findIndex(c => c.kind === 'thinking')).toBeLessThan(chunks.findIndex(c => c.kind === 'tool'))
  expect(e.modelSteps).toBe(0)
})

test('a run with no steps keeps its report in block 0', async ($, on) => {
  const e = engine([$, on], { outputs: [{ type: 'tick' }, RESULT] })
  await e.launch()
  const chunks = await step($)
  expect(chunks.some(c => c.kind === 'thinking')).toBe(false)
  expect(chunks.find(c => c.kind === 'tool')?.index).toBe(0)
})

test('a plain reroute shows nothing before its first step, so the built-in agent can still take it', async ($, on) => {
  const e = engine([$, on], { outputs: [{ type: 'moved', account: 'Pro', reason: 'limit' }, { type: 'native' }] })
  await e.launch()
  const chunks = await step($)
  expect(chunks.some(c => c.kind === 'thinking')).toBe(false)
  expect(report(chunks)).toBe('built-in response')
  expect(e.modelSteps).toBe(1)
})

test('a failure after steps were shown is reported after them, never as a built-in step', async ($, on) => {
  const e = engine([$, on], { outputs: [{ type: 'step', text: 'Bash: ls' }, { type: 'result', isError: true, text: 'boom' }] })
  await e.launch()
  const chunks = await step($)
  expect(chunks[0]).toMatchObject({ kind: 'thinking', index: 0 })
  expect(report(chunks)).toContain('boom')
  expect(chunks.find(c => c.kind === 'tool')?.index).toBe(1)
  expect(e.modelSteps).toBe(0)
})

test('an older runner that changes ids fails visibly', async ($, on) => {
  const e = engine([$, on], { wrongID: true })
  await e.launch()
  expect(report(await step($))).toContain('did not keep the native agent id')
  expect(e.modelSteps).toBe(0)
})

test('a second model step after handback never falls back to the session account', async ($, on) => {
  const e = engine([$, on])
  await e.launch()
  await step($)
  const chunks = await step($, 'turn-1', 1)
  expect(report(chunks)).toContain('another model step')
  expect(chunks.some(c => c.kind === 'tool')).toBe(false)
  expect(e.modelSteps).toBe(0)
})

test('failure to persist a route produces an error report, never a local request', async ($, on) => {
  const e = engine([$, on], { storeFailure: true })
  await e.launch()
  expect(report(await step($))).toContain('could not save the native agent’s route')
  expect(e.runCount).toBe(0)
  expect(e.modelSteps).toBe(0)
})

test('a worktree call reaches the engine unchanged, and the runner works in the engine’s worktree', async ($, on) => {
  const e = engine([$, on])
  await e.launch({ isolation: 'worktree' })
  expect(exact(e.nativeInputs[0]!)).toEqual(exact({ tool: 'Agent', tool_use_id: 'toolu_x', description: 'read a note', prompt: 'initial task', isolation: 'worktree' }))
  e.cwd('/work/.claude/worktrees/agent-x')
  expect(report(await step($))).toBe(`Worktree: /work/.claude/worktrees/agent-x (branch worktree-agent-x).\n\n${RESULT.text}`)
  const run = e.calls.find(c => c.flag === '--agent-run')!.request
  expect(run.cwd).toBe('/work/.claude/worktrees/agent-x')
  expect(run.isolation).toBeUndefined()
  // The admission check is asked as before.
  expect(e.calls.find(c => c.flag === '--agent-route')?.request.isolation).toBe('worktree')
})

test('a follow-up stays in the engine’s worktree while it exists, then goes to the caller’s folder', async ($, on) => {
  const e = engine([$, on])
  await e.launch({ isolation: 'worktree' })
  e.cwd('/work/.claude/worktrees/agent-x')
  await step($)
  e.cwd('/work')
  const more = (text: string) => e.messages([{ role: 'user', content: [{ type: 'text', text: 'initial task' }] }, { role: 'user', content: [{ type: 'text', text }] }])
  more('more')
  await resume($, 'more')
  expect(report(await step($, 'turn-2'))).toContain('Worktree: /work/.claude/worktrees/agent-x')
  // The agent left it unchanged and ended: Claude Code removed it.
  e.remove('/work/.claude/worktrees/agent-x')
  more('again')
  await resume($, 'again')
  expect(report(await step($, 'turn-3'))).toBe(RESULT.text)
  const runs = e.calls.filter(c => c.flag === '--agent-run').map(c => c.request)
  expect(runs.map(r => r.cwd)).toEqual(['/work/.claude/worktrees/agent-x', '/work/.claude/worktrees/agent-x', '/work'])
  expect(runs.map(r => r.isolation)).toEqual([undefined, undefined, undefined])
})

test('an unchanged worktree is left out of the header, and a detached one names no branch', async ($, on) => {
  const e = engine([$, on])
  await e.launch({ isolation: 'worktree' })
  e.cwd('/work/.claude/worktrees/agent-x')
  e.git('status', '')
  e.git('reflog', 'a')
  expect(report(await step($))).toBe(RESULT.text)
  e.git('symbolic-ref', undefined)
  await e.launch({ isolation: 'worktree', tool_use_id: 'toolu_2' })
  e.cwd('/work/.claude/worktrees/agent-y')
  // Detached and clean: changed or not can't be told from a branch, so it is named, without one.
  expect(report(await step($, 'turn-2'))).toBe(`Worktree: /work/.claude/worktrees/agent-y.\n\n${RESULT.text}`)
})

test('with no worktree from the engine the runner makes its own, as before', async ($, on) => {
  const e = engine([$, on])
  await e.launch({ isolation: 'worktree' })
  await step($)
  const run = e.calls.find(c => c.flag === '--agent-run')!.request
  expect(run.isolation).toBe('worktree')
  expect(run.cwd).toBe('/work')
})

test('a built-in worktree call retains its isolation when no other account has room', async ($, on) => {
  const e = engine([$, on], { route: { type: 'no_room' } })
  await e.launch({ isolation: 'worktree' })
  expect(e.nativeInputs[0]?.isolation).toBe('worktree')
  expect(e.runCount).toBe(0)
})

test('prompt hooks still warm a process with the session folder and model', async ($, on) => {
  const e = engine([$, on])
  await $.classic.UserPromptSubmit({ prompt: 'hi', permission_mode: 'plan' } as never)
  for (let i = 0; i < 30 && !e.calls.some(c => c.flag === '--agent-warm'); i++) await new Promise(resolve => setTimeout(resolve, 10))
  const request = e.calls.find(c => c.flag === '--agent-warm')?.request
  expect(request?.cwd).toBe('/work')
  expect(request?.parentModel).toBe('claude-haiku-5-5')
  expect(request?.permissionMode).toBe('plan')
})

test('a failed version self-test remains visible in the status line', async ($, on) => {
  const e = engine([$, on], { selfTest: { type: 'failed', version: '2.2.0', step: 'resume', text: 'missing session' } })
  await $.session.start({ cwd: '/work', surface: null, isInteractive: false })
  for (let i = 0; i < 30 && !e.statuses.some(t => t?.includes('broken')); i++) await new Promise(resolve => setTimeout(resolve, 10))
  expect(e.statuses.at(-1)).toContain('broken on Claude Code 2.2.0 (resume: missing session)')
})

test('unrelated native subagents and the main loop retain their model steps', async ($, on) => {
  const e = engine([$, on])
  await step($, 'native', 0, 'a-unrouted')
  await step($, 'main', 0, undefined)
  expect(e.modelSteps).toBe(2)
  expect(e.runCount).toBe(0)
})

for (const options of [{ fork: true }, { workflow: true }]) {
  test(`special native spawn ${JSON.stringify(options)} stays built-in`, async ($, on) => {
    const e = engine([$, on], options)
    await e.launch()
    await step($)
    expect(e.runCount).toBe(0)
    expect(e.modelSteps).toBe(1)
  })
}

for (const fields of [{ agentId: 'parent-agent' }, { name: 'teammate' }, { isolation: 'remote' }]) {
  test(`special Agent call ${JSON.stringify(fields)} stays built-in`, async ($, on) => {
    const e = engine([$, on])
    await e.launch(fields)
    await step($)
    expect(e.calls.some(c => c.flag === '--agent-route')).toBe(false)
    expect(e.modelSteps).toBe(1)
  })
}

test('unknown Agent fields still fail explicitly', async ($, on) => {
  const e = engine([$, on])
  expect((await e.launch({ run_after: 'lunch' })).deny).toContain('`run_after`')
  expect(e.nativeCalls).toEqual([])
})

test('permission refusal does not start a remote run', async ($, on) => {
  const e = engine([$, on], { refusal: 'Permission denied' })
  expect((await e.launch()).deny).toBe('Permission denied')
  expect(e.runCount).toBe(0)
})

const MESSAGE = { role: 'user', text: 'earlier', toolUses: [], handle: 'm1' }
async function listing($: Body[0], text = NATIVE_LISTING, fields: object = {}) {
  return (await $.prompt.attachment({ type: 'agent_listing_delta', text, origin: { kind: 'engine' }, ...fields } as never)).text
}
async function submit($: Body[0], text = 'hi') {
  return (await $.prompt.submit({ text, wait: false, origin: { kind: 'user' } } as never)).context
}

test('an added agent runs as its own type on the native adapter', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await e.launch({ subagent_type: 'lastdrop:sol' })
  expect(e.spawned.length).toBe(1)
  expect(e.nativeInputs[0]?.model).toBeUndefined()
  expect(report(await step($))).toBe(`Ran on claude-haiku-5-5.\n\n${RESULT.text}`)
  const request = e.calls.find(c => c.flag === '--agent-run')!.request
  expect(request.agent).toBe('sol')
  expect(request.model).toBeUndefined()
  expect(request.role).toBeUndefined()
  expect(e.calls.find(c => c.flag === '--agent-route')?.request.agent).toBe('sol')
  expect(e.modelSteps).toBe(0)
})

test('an unknown model is denied with what is available, after a fresh read of the list', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG })
  expect((await e.launch({ model: 'nova' })).deny).toBe("Model nova isn't available. Use sonnet, opus, haiku, fable. The user's added agents are the agent types lastdrop:sol, lastdrop:argon.")
  expect(e.calls.filter(c => c.flag === '--agent-catalog').length).toBe(1)
  expect(e.spawned).toEqual([])
})

test('with no added agents an unknown model lists only Claude models', async ($, on) => {
  const e = engine([$, on])
  expect((await e.launch({ model: 'nova' })).deny).toBe("Model nova isn't available. Use sonnet, opus, haiku, fable. The user has no added agents.")
  expect((await e.launch({ subagent_type: 'lastdrop:nova' })).deny).toBe("Agent type lastdrop:nova isn't available. The user has no added agents.")
})

test('an agent added since the last read is registered by the call, which reaches the engine unchanged', async ($, on) => {
  let live: object = { revision: 1, agents: [] }
  const e = engine([$, on], { liveCatalog: () => live })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  expect(e.registered).toEqual([])
  live = CATALOG
  await e.launch({ subagent_type: 'lastdrop:sol' })
  // Registered now, the type dispatches from the next turn on: whether this call runs is the engine's to say.
  expect(e.registered.map(r => r.name)).toEqual(['sol', 'argon'])
  expect(exact(e.nativeInputs[0]!)).toEqual(exact({ tool: 'Agent', tool_use_id: 'toolu_x', description: 'read a note', prompt: 'initial task', subagent_type: 'lastdrop:sol' }))
})

test('Claude models and calls without a model stay native', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG })
  for (const fields of [{ model: 'sonnet' }, { model: 'opus' }, { model: 'haiku' }, { model: 'fable' }, {}, { subagent_type: 'Explore' }]) {
    await e.launch(fields)
  }
  expect(e.calls.filter(c => c.flag === '--agent-route').every(c => c.request.agent === undefined)).toBe(true)
  expect(e.nativeInputs.map(i => i.model)).toEqual(['sonnet', 'opus', 'haiku', 'fable', undefined, undefined])
})

test('an added agent spawns under its own name as the model, so hosts never label it as Claude', async ($, on) => {
  let spawns = 0
  const e = engine([$, on], { catalog: CATALOG, spawnId: () => `new-${++spawns}` })
  await e.launch({ subagent_type: 'lastdrop:sol' })
  await e.launch({ model: 'sonnet', tool_use_id: 'toolu_2' })
  await e.launch({ tool_use_id: 'toolu_3' })
  expect(e.spawned.map(s => s.model)).toEqual(['sol', 'sonnet', undefined])
  expect(e.calls.find(c => c.flag === '--agent-route')?.request.model).toBeUndefined()
  expect(e.calls.find(c => c.flag === '--agent-route')?.request.agent).toBe('sol')
})

test('Explore and Plan pass their role on a reroute; an added agent passes none', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  for (const type of ['Explore', 'Plan', 'general-purpose', 'claude', undefined]) await e.launch({ subagent_type: type })
  await e.launch({ subagent_type: 'lastdrop:sol' })
  const routes = e.calls.filter(c => c.flag === '--agent-route').map(c => c.request)
  expect(routes.map(r => r.role)).toEqual(['Explore', 'Plan', undefined, undefined, undefined, undefined])
  expect(routes.map(r => r.subagentType)).toEqual(['Explore', 'Plan', 'general-purpose', 'claude', undefined, 'general-purpose'])
})

test('an added agent refuses a model, nesting, names and remote isolation', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG })
  expect((await e.launch({ subagent_type: 'lastdrop:sol', model: 'opus' })).deny).toBe('lastdrop:sol runs on its own model. Call it without model.')
  for (const fields of [{ agentId: 'parent-agent' }, { name: 'teammate' }, { isolation: 'remote' }]) {
    expect((await e.launch({ subagent_type: 'lastdrop:sol', ...fields })).deny).toContain('run only from the main session')
  }
  expect(e.spawned).toEqual([])
  expect(e.nativeCalls).toEqual([])
})

test('the old forms are denied with the type that replaces them, and never rewritten', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG })
  await $.agent.offer({ agent: 'Explore', description: 'x', source: 'built-in' } as never)
  const guidance = 'sol is an agent type: call the Agent tool with subagent_type: "lastdrop:sol" and no model. It runs as a general agent, never as Explore or Plan.'
  for (const fields of [{ model: 'sol' }, { model: 'sol', subagent_type: 'Explore' }, { model: 'sol', subagent_type: 'general-purpose' },
                        { subagent_type: 'sol' }, { subagent_type: 'sol', model: 'opus' }]) {
    expect((await e.launch(fields)).deny).toBe(guidance)
  }
  // From inside a subagent no form of it runs: the answer says so rather than naming a type it can't call.
  for (const fields of [{ model: 'argon' }, { subagent_type: 'argon' }]) {
    expect((await e.launch({ ...fields, agentId: 'parent-agent' })).deny).toBe("lastdrop's agents (lastdrop:argon) run only from the main session.")
  }
  expect(e.nativeCalls).toEqual([])
  expect(e.calls.some(c => c.flag === '--agent-route')).toBe(false)
})

test('an added agent with no room is denied, never run by the built-in agent', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG, route: { type: 'no_room' } })
  expect((await e.launch({ subagent_type: 'lastdrop:sol' })).deny).toContain('nowhere to run sol')
  expect(e.spawned).toEqual([])
})

test('an added agent with a worktree reaches the engine unchanged and runs in its worktree', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG })
  await e.launch({ subagent_type: 'lastdrop:sol', isolation: 'worktree' })
  expect(exact(e.nativeInputs[0]!)).toEqual(exact({ tool: 'Agent', tool_use_id: 'toolu_x', description: 'read a note', prompt: 'initial task',
                                                  subagent_type: 'lastdrop:sol', isolation: 'worktree' }))
  e.cwd('/work/.claude/worktrees/agent-x')
  expect(report(await step($))).toBe(`Ran on claude-haiku-5-5. Worktree: /work/.claude/worktrees/agent-x (branch worktree-agent-x).\n\n${RESULT.text}`)
  const run = e.calls.find(c => c.flag === '--agent-run')!.request
  expect(run.cwd).toBe('/work/.claude/worktrees/agent-x')
  expect(run.isolation).toBeUndefined()
})

test('a special spawn of an added agent is denied', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG, fork: true })
  expect((await e.launch({ subagent_type: 'lastdrop:sol' })).deny).toContain('run only from the main session')
})

test('a route saved for the old lastdrop: types still resumes', async ($, on) => {
  const e = engine([$, on])
  e.store.set(`native-agent:${ID}`, { request: { prompt: '', cwd: '/original', subagentType: 'lastdrop:sol', agent: 'lastdrop:sol' },
    description: 'old agent', toolUseId: 'toolu_old', ran: true, cursor: 1 })
  e.messages([{ role: 'user', content: [{ type: 'text', text: 'old task' }] },
    { role: 'user', content: [{ type: 'text', text: 'follow-up' }] }])
  expect(report(await step($))).toBe(`Ran on claude-haiku-5-5.\n\n${RESULT.text}`)
  expect(e.calls.find(c => c.flag === '--agent-run')?.request.agent).toBe('lastdrop:sol')
})

test('the report header names the model, the worktree and what was declined', async ($, on) => {
  const result = { ...RESULT, model: 'gpt-6.1-sol' }
  const full = { ...result, worktreePath: '/w/x', worktreeBranch: 'agent-x', declined: ['git push (needed approval)', 'rm -rf build (needed approval)'] }
  const outputs = [result]
  const e = engine([$, on], { catalog: CATALOG, outputs })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await e.launch({ subagent_type: 'lastdrop:sol' })
  expect(report(await step($))).toBe(`Ran on gpt-6.1-sol.\n\n${RESULT.text}`)
  outputs[0] = { ...result, worktreePath: '/w/x', worktreeBranch: 'agent-x' }
  await e.launch({ subagent_type: 'lastdrop:sol', tool_use_id: 'toolu_2' })
  expect(report(await step($, 'turn-2'))).toContain(`Ran on gpt-6.1-sol. Worktree: /w/x (branch agent-x).\n\n`)
  outputs[0] = full
  await e.launch({ subagent_type: 'lastdrop:sol', tool_use_id: 'toolu_3' })
  expect(report(await step($, 'turn-3'))).toBe(`Ran on gpt-6.1-sol. Worktree: /w/x (branch agent-x).\nDeclined: git push (needed approval); rm -rf build (needed approval)\n\n${RESULT.text}`)
})

test('Claude reroutes and failed agent runs get no header', async ($, on) => {
  const outputs: object[] = [RESULT]
  const e = engine([$, on], { catalog: CATALOG, outputs })
  await e.launch()
  expect(report(await step($))).toBe(RESULT.text)
  outputs[0] = { type: 'result', isError: true, text: 'it broke', model: 'gpt-6.1-sol' }
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await e.launch({ subagent_type: 'lastdrop:sol', tool_use_id: 'toolu_2' })
  expect(report(await step($, 'turn-2'))).toBe('lastdrop agent failed: Error: it broke')
})

test('the main loop listing gets what the lastdrop: types are, and the pointer to the command', async ($, on) => {
  engine([$, on], { catalog: CATALOG })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  expect(await listing($)).toBe(`${NATIVE_LISTING}\n\n${TYPES}${COMMAND}`)
})

test('each enabled agent is registered as a lastdrop: type, with its description and where it runs', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG })
  await $.session.start({ cwd: '/work' } as never)
  expect(e.registered.map(r => [r.name, r.description])).toEqual([['sol', SOL], ['argon', ARGON]])
  expect(e.registered.every(r => r.prompt.includes('never sent to a model') && !('tools' in r))).toBe(true)
})

test('an unchanged catalog registers nothing again, so the listing stays as it is', async ($, on) => {
  let live: object = CATALOG
  const e = engine([$, on], { liveCatalog: () => live })
  await $.session.start({ cwd: '/work' } as never)
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await submit($)
  live = { ...CATALOG, revision: 4 }
  await submit($)
  expect(e.registered.length).toBe(2)
  live = { revision: 5, agents: [{ ...CATALOG.agents[0], description: 'Changed.' }, CATALOG.agents[1]] }
  await submit($)
  expect(e.registered.slice(2).map(r => [r.name, r.description])).toEqual([['sol', 'Changed. (Codex · gpt-6.1-sol · high)']])
})

test('a type whose agent left the catalog is hidden; one added is offered and registered', async ($, on) => {
  let live: object = CATALOG
  const e = engine([$, on], { liveCatalog: () => live })
  await $.session.start({ cwd: '/work' } as never)
  const offer = async (agent: string) => (await $.agent.offer({ agent, description: 'x', source: 'plugin' } as never)).isOffered
  expect(await offer('lastdrop:sol')).toBe(true)
  live = { revision: 9, agents: [CATALOG.agents[1], { ...CATALOG.agents[0], name: 'nova' }] }
  await submit($)
  expect(await offer('lastdrop:sol')).toBe(false)
  expect(await offer('lastdrop:nova')).toBe(true)
  expect(await offer('lastdrop:argon')).toBe(true)
  expect(await offer('general-purpose')).toBe(true)
  expect(e.registered.at(-1)?.name).toBe('nova')
  expect((await e.launch({ subagent_type: 'lastdrop:sol' })).deny).toBe("Agent type lastdrop:sol isn't available. The user's added agents are the agent types lastdrop:argon, lastdrop:nova.")
})

test('an app without agentModels registers nothing and hides every lastdrop: type', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG, agentModels: false })
  await $.session.start({ cwd: '/work' } as never)
  expect(e.registered).toEqual([])
  expect((await $.agent.offer({ agent: 'lastdrop:sol', description: 'x', source: 'plugin' } as never)).isOffered).toBe(false)
})

test('a routed call reaches the engine byte-identical, and its spawn is claimed and labelled', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG })
  const call = { subagent_type: 'lastdrop:sol', effort: 'high', run_in_background: true }
  await e.launch(call)
  expect(exact(e.nativeInputs[0]!)).toEqual(exact({ tool: 'Agent', tool_use_id: 'toolu_x', description: 'read a note', prompt: 'initial task', ...call }))
  expect(e.spawned.map(s => (s as { model?: string }).model)).toEqual(['sol'])
  expect(e.calls.find(c => c.flag === '--agent-route')?.request.effort).toBe('high')
  await step($)
  expect(e.calls.find(c => c.flag === '--agent-run')?.request).toMatchObject({ agent: 'sol', subagentType: 'general-purpose', effort: 'high' })
})

test('a spawn of a lastdrop: type that no Agent call claimed is refused, so its placeholder never runs', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG })
  const answer = await $.agent.spawn({ tool_use_id: 'toolu_other', prompt: 'x', description: 'x', subagentType: 'lastdrop:sol',
    parentModel: 'haiku', permissionMode: 'auto', background: true, fork: false } as never)
  expect(answer.deny).toContain('run only from the main session')
  expect(e.spawned).toEqual([])
})

test('the pointer to the command stays out of notes, and a listing frozen by an earlier version keeps its bytes', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await listing($)
  expect(await submit($)).toBeUndefined()
  // As the version before the types stored it, and the message it produced at each read.
  const old = `- sol: Reviews: hard bugs. (Codex · gpt-6.1-sol · high)${COMMAND}`
  e.store.set('listing:session-1', old)
  expect(await listing($)).toBe(`${NATIVE_LISTING}\n\nThe Agent tool's model parameter also accepts these models the user added:\n${old}`)
  // A list frozen before the pointer existed.
  e.store.set('listing:session-1', '- sol: x')
  expect(await listing($)).toBe(`${NATIVE_LISTING}\n\nThe Agent tool's model parameter also accepts these models the user added:\n- sol: x`)
  e.store.set('listing:session-1', '')
  expect(await listing($)).toBe(NATIVE_LISTING)
})

test('in T3 Code a listing frozen by an earlier version keeps that version’s T3 header', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG, env: { T3CODE_THREAD_ID: 'thread-1' } })
  e.store.set('listing:session-1', `- sol: x${COMMAND}`)
  expect(await listing($)).toBe(`${NATIVE_LISTING}\n\nThe Agent tool's model parameter and delegate_task's target.model also accept these models the user added. They run through the Agent tool like Claude's own models, so the rule to use delegate_task for another provider's model doesn't apply to them: use Agent, and delegate_task only for background work.\n- sol: x${COMMAND}`)
})

test('an empty list appends nothing', async ($, on) => {
  engine([$, on])
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  expect(await listing($)).toBe(NATIVE_LISTING)
})

test('subagent listings, other attachments and other engine text stay untouched', async ($, on) => {
  engine([$, on], { catalog: CATALOG })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  expect(await listing($, NATIVE_LISTING, { agentId: 'a-sub' })).toBe(NATIVE_LISTING)
  expect(await listing($, 'New agent types are now available:\n- x: y')).toBe('New agent types are now available:\n- x: y')
  expect(await listing($, NATIVE_LISTING, { origin: { kind: 'hook', event: 'SessionStart' } })).toBe(NATIVE_LISTING)
  expect(await listing($, NATIVE_LISTING, { origin: { kind: 'plugin', event: 'prompt.submit' } })).toBe(NATIVE_LISTING)
  expect((await $.prompt.attachment({ type: 'todo_reminder', text: NATIVE_LISTING, origin: { kind: 'engine' } } as never)).text).toBe(NATIVE_LISTING)
})

test('the first listing is frozen for the session and replays after a change keep it', async ($, on) => {
  let live: object = CATALOG
  let id = 'session-1'
  const e = engine([$, on], { liveCatalog: () => live, sessionId: () => id })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  const first = await listing($)
  expect(e.store.get('listing:session-1')).toBe(`${TYPES}${COMMAND}`)
  live = { revision: 9, agents: [] }
  await $.classic.UserPromptSubmit({ prompt: 'again' } as never)
  expect(await listing($)).toBe(first)
  // Another session starts from the list as it reads now.
  id = 'session-2'
  expect(await listing($)).toBe(NATIVE_LISTING)
  expect(e.store.get('listing:session-2')).toBe('')
})

test('a compaction of the main loop clears the frozen listing; a subagent compaction does not', async ($, on) => {
  let live: object = { revision: 1, agents: [] }
  const e = engine([$, on], { liveCatalog: () => live })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await listing($)
  await submit($)
  await $.session.compact({ trigger: 'manual', agentId: 'a-sub', messages: [MESSAGE] } as never)
  expect(e.store.has('listing:session-1')).toBe(true)
  await $.session.compact({ trigger: 'manual', messages: [MESSAGE] } as never)
  expect(e.store.has('listing:session-1')).toBe(false)
  expect(e.store.has('announced:session-1')).toBe(false)
  live = { revision: 9, agents: [CATALOG.agents[1]] }
  await $.classic.UserPromptSubmit({ prompt: 'again' } as never)
  expect(await listing($)).toBe(`${NATIVE_LISTING}\n\n${TYPES}${COMMAND}`)
})

test('a new session id after /clear starts without a frozen listing', async ($, on) => {
  let id = 'before'
  const e = engine([$, on], { catalog: CATALOG, sessionId: () => id })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await listing($)
  id = 'after'
  expect(e.store.has('listing:after')).toBe(false)
  expect(await submit($)).toBeUndefined()
  await listing($)
  expect(e.store.get('listing:after')).toBe(`${TYPES}${COMMAND}`)
})

test('the stored listings of old sessions are pruned to the latest hundred', async ($, on) => {
  let id = 's0'
  const e = engine([$, on], { catalog: CATALOG, sessionId: () => id })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  for (let i = 0; i < 105; i++) { id = `s${i}`; await listing($); await submit($) }
  expect([...e.store.keys()].filter(k => k.startsWith('listing:')).length).toBe(100)
  expect([...e.store.keys()].filter(k => k.startsWith('announced:')).length).toBe(100)
  expect(e.store.has('listing:s0')).toBe(false)
  expect(e.store.has('listing:s104')).toBe(true)
})

test('a changed description is announced once beside the next prompt; agents added or removed are the engine’s to tell', async ($, on) => {
  let live: object = CATALOG
  engine([$, on], { liveCatalog: () => live })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  expect(await submit($)).toBeUndefined()
  expect(await submit($)).toBeUndefined()
  live = { revision: 9, agents: [{ ...CATALOG.agents[0], description: 'Changed.' }, { ...CATALOG.agents[1], name: 'nova' }] }
  expect(await submit($)).toEqual(['These agents the user added now read:\n- lastdrop:sol: Changed. (Codex · gpt-6.1-sol · high)'])
  expect(await submit($)).toBeUndefined()
  live = { revision: 10, agents: [] }
  expect(await submit($)).toBeUndefined()
})

test('a resumed session keeps its frozen listing, and one from an earlier version starts its notes afresh', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG })
  e.store.set('listing:session-1', `${TYPES}${COMMAND}`)
  e.store.set('announced:session-1', '- sol: Old. (Codex)')
  expect(await listing($)).toBe(`${NATIVE_LISTING}\n\n${TYPES}${COMMAND}`)
  expect(await submit($)).toBeUndefined()
  expect(e.store.get('announced:session-1')).toEqual({ sol: SOL, argon: ARGON })
})

test('a note joins context a prompt already carries', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG })
  e.store.set('announced:session-1', { sol: 'Old.', argon: ARGON })
  const context = (await $.prompt.submit({ text: 'hi', wait: false, origin: { kind: 'user' }, context: ['mine'] } as never)).context
  expect(context).toEqual(['mine', `These agents the user added now read:\n- lastdrop:sol: ${SOL}`])
})

test('an empty list raises no note and no status', async ($, on) => {
  const e = engine([$, on])
  await submit($)
  expect(await submit($)).toBeUndefined()
  expect(e.statuses).toEqual([])
})

test('the listing and prompt hooks pass through when lastdrop fails', async ($, on) => {
  engine([$, on], { runnerFails: true })
  expect(await submit($)).toBeUndefined()
  expect(await listing($)).toBe(NATIVE_LISTING)
})

const BOUNDARY = { type: 'system', name: 'compact_boundary', content: [{ type: 'text', text: 'Compacted' }] }
const append = ($: Body[0], message: object, fields: object = {}) =>
  $.session.append({ message, door: 'engine', origin: { kind: 'engine' }, uuid: 'u1', ...fields } as never)

test('an app without agentModels adds nothing to listings or notes and refuses added agents', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG, agentModels: false })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  expect(await listing($)).toBe(NATIVE_LISTING)
  await submit($)
  expect(await submit($)).toBeUndefined()
  expect((await e.launch({ subagent_type: 'lastdrop:sol' })).deny).toContain('Update the lastdrop app')
  expect(e.spawned).toEqual([])
  expect((await e.launch({ model: 'sonnet' })).result).toEqual(NATIVE)
  expect((await e.launch()).result).toEqual(NATIVE)
})

test('a store that refuses writes never breaks the listing or the prompt', async ($, on) => {
  engine([$, on], { catalog: CATALOG, storeFailure: true })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  expect(await listing($)).toBe(`${NATIVE_LISTING}\n\n${TYPES}${COMMAND}`)
  expect(await submit($)).toBeUndefined()
})

test('a nearly full store is pruned before the listing is written', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG, storeLimit: 3000 })
  for (let i = 0; i < 100; i++) e.store.set(`listing:old${i}`, 'x'.repeat(20))
  for (let i = 0; i < 20; i++) e.store.set(`native-agent:old${i}`, { pad: 'y'.repeat(5) })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await listing($)
  expect(e.store.get('listing:session-1')).toBe(`${TYPES}${COMMAND}`)
  expect(e.store.has('listing:old0')).toBe(false)
})

test('old routes are pruned oldest first, never those of running agents', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG })
  e.store.set(`native-agent:${ID}`, { request: {}, description: 'x', toolUseId: 't', ran: false, cursor: 0 })
  for (let i = 0; i < 250; i++) e.store.set(`native-agent:old${i}`, { request: {} })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await e.launch({ subagent_type: 'lastdrop:sol', tool_use_id: 'toolu_new' })
  expect([...e.store.keys()].filter(k => k.startsWith('native-agent:')).length).toBeLessThanOrEqual(200)
  expect(e.store.has(`native-agent:${ID}`)).toBe(true)
  expect(e.store.has('native-agent:old0')).toBe(false)
  expect(e.store.get('added-agents')).toContain(ID)
})

test('a compaction notice row resets the main listing, with or without session.compact', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await listing($)
  await append($, BOUNDARY, { agentId: 'a-sub' })
  await append($, { type: 'system', name: 'local_command', content: [] })
  await append($, { type: 'attachment', name: 'agent_listing_delta', content: [] })
  expect(e.store.has('listing:session-1')).toBe(true)
  await append($, BOUNDARY)
  expect(e.store.has('listing:session-1')).toBe(false)
  expect(e.store.has('announced:session-1')).toBe(false)
  // A precomputed compaction raises no session.compact when it installs; replays raise no append at all.
  await $.session.compact({ trigger: 'precompute', messages: [MESSAGE] } as never)
  await listing($)
  await $.session.compact({ trigger: 'precompute', messages: [MESSAGE] } as never)
  expect(e.store.has('listing:session-1')).toBe(true)
})

test('resuming an added agent whose route is gone is refused, not run as Claude', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG })
  e.store.set('added-agents', [ID])
  const answer = await $.agent.spawn({ tool_use_id: '', prompt: 'follow-up', description: 'x', subagentType: 'general-purpose',
    parentModel: 'haiku', permissionMode: 'auto', background: true, fork: false, resume: { agentId: ID } } as never)
  expect(answer.deny).toContain('no saved route for added agent')
  expect(e.spawned).toEqual([])
})

test('a Claude reroute reports only its worktree', async ($, on) => {
  const outputs: object[] = [{ ...RESULT, worktreePath: '/w/x', worktreeBranch: 'agent-x' }]
  const e = engine([$, on], { outputs })
  await e.launch({ isolation: 'worktree' })
  expect(report(await step($))).toBe(`Worktree: /w/x (branch agent-x).\n\n${RESULT.text}`)
})

test('a spawned agent not yet run keeps its route and marker through pruning, whatever the pane shows', async ($, on) => {
  let next = ID
  const e = engine([$, on], { catalog: CATALOG, spawnId: () => next })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await e.launch({ subagent_type: 'lastdrop:sol' })
  for (let i = 0; i < 250; i++) e.store.set(`native-agent:old${i}`, { request: {} })
  next = 'b2222222222222222'
  await e.launch({ subagent_type: 'lastdrop:sol', tool_use_id: 'toolu_2' })
  expect(e.store.has(`native-agent:${ID}`)).toBe(true)
  expect(e.store.get('added-agents')).toContain(ID)
  expect(e.store.has('native-agent:old0')).toBe(false)
})

test('an added agent whose marker cannot be saved fails visibly instead of running', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG, storeLimit: 60 })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await e.launch({ subagent_type: 'lastdrop:sol' })
  expect(report(await step($))).toContain('could not save the native agent’s route')
  expect(e.runCount).toBe(0)
})

test('a frozen listing does not advertise agents to an app that lacks agentModels', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG, agentModels: false })
  e.store.set('listing:session-1', `${TYPES}${COMMAND}`)
  expect(await listing($)).toBe(NATIVE_LISTING)
})

test('a custom agent type named like an added model stays native', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await $.agent.offer({ agent: 'sol', description: 'mine', source: 'userSettings' } as never)
  await e.launch({ subagent_type: 'sol' })
  expect(e.calls.filter(c => c.flag === '--agent-route').every(c => c.request.agent === undefined)).toBe(true)
  expect(e.nativeInputs[0]?.subagent_type).toBe('sol')
})

test('after a reload, with no listing seen, the bare name as the type is denied with its type', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  expect((await e.launch({ subagent_type: 'sol' })).deny).toContain('subagent_type: "lastdrop:sol"')
  expect((await e.launch({ subagent_type: 'lastdrop:sol' })).result).toEqual(NATIVE)
})

test('added-agent ids outlive the routes cap', async ($, on) => {
  let next = ID
  const e = engine([$, on], { catalog: CATALOG, spawnId: () => next })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await e.launch({ subagent_type: 'lastdrop:sol' })
  await step($)
  for (let i = 0; i < 250; i++) e.store.set(`native-agent:old${i}`, { request: {} })
  next = 'b2222222222222222'
  await e.launch({ subagent_type: 'lastdrop:sol', tool_use_id: 'toolu_2' })
  expect([...e.store.keys()].filter(k => k.startsWith('native-agent:')).length).toBeLessThanOrEqual(200)
  expect(e.store.has(`native-agent:${ID}`)).toBe(false)
  // The in-memory route would still answer here; after a reload only the list tells.
  expect(e.store.get('added-agents')).toContain(ID)
})

test('the header names the models skipped as unavailable', async ($, on) => {
  const outputs: object[] = [{ ...RESULT, model: 'gemini-4-argon-high', unavailable: ['gpt-6.1-sol'] }]
  const e = engine([$, on], { catalog: CATALOG, outputs })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await e.launch({ subagent_type: 'lastdrop:sol' })
  expect(report(await step($))).toBe(`Ran on gemini-4-argon-high (gpt-6.1-sol unavailable).\n\n${RESULT.text}`)
  outputs[0] = { ...RESULT, model: 'c', unavailable: ['a', 'b'], worktreePath: '/w/x', worktreeBranch: 'agent-x', declined: ['git push (needed approval)'] }
  await e.launch({ subagent_type: 'lastdrop:sol', tool_use_id: 'toolu_2' })
  expect(report(await step($, 'turn-2'))).toBe(`Ran on c (a, b unavailable). Worktree: /w/x (branch agent-x).\nDeclined: git push (needed approval)\n\n${RESULT.text}`)
})

test('a fallback attempt updates the pane row and creates no second one', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG, outputs: [
    { type: 'moved', account: 'Codex', reason: 'usage limit' },
    { type: 'started', agentId: ID, account: 'Antigravity', model: 'gemini-4-argon-high', provider: 'antigravity' },
    { ...RESULT, account: 'Antigravity', model: 'gemini-4-argon-high', provider: 'antigravity', unavailable: ['gpt-6.1-sol'] },
  ] })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await e.launch({ subagent_type: 'lastdrop:sol' })
  await step($)
  const ui = await $.ui.mount({ plugin: 'lastdrop', component: 'Pane', requestId: 'lastdrop-agents', props: {}, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /on Antigravity · gemini-4-argon-high/ }))?.text).toContain('gemini-4-argon-high')
  expect(await ui.find({ type: 'Text', text: /on Pro/ })).toBeFalsy()
  const rows = await ui.findAll({ type: 'Button', text: /Show transcript/ })
  expect(rows.length).toBe(1)
  await ui.unmount()
})

test('a pane fuller than session state can hold never fails an agent', async ($, on) => {
  const item = { type: 'item', kind: 'text', text: 'x'.repeat(100_000) }
  const e = engine([$, on], { outputs: [...Array.from({ length: 50 }, () => item), RESULT] })
  await e.launch()
  expect(report(await step($))).toContain('exact remote report')
  const ui = await $.ui.mount({ plugin: 'lastdrop', component: 'Pane', requestId: 'lastdrop-agents', props: {}, surface: 'terminal' })
  expect(await ui.find({ type: 'Button', text: /Show transcript/ })).toBeTruthy()
  await ui.unmount()
})

test('a store that fills up mid-run never loses the report', async ($, on) => {
  const options = { storeFailure: false }
  const e = engine([$, on], options)
  await e.launch()
  options.storeFailure = true
  expect(report(await step($))).toContain('exact remote report')
})

test('a switch made before the agent started still reaches its row', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG, before: [{ type: 'moved', account: 'Codex', reason: 'usage limit' }] })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await e.launch({ subagent_type: 'lastdrop:sol' })
  await step($)
  const ui = await $.ui.mount({ plugin: 'lastdrop', component: 'Pane', requestId: 'lastdrop-agents', props: {}, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /Moved off Codex: usage limit/ }))?.text).toContain('usage limit')
  await ui.unmount()
})

// T3 Code's delegate_task: the parent tags the child's task, and lastdrop answers the child's own turns.
const DELEGATE = 'mcp__t3-code__delegate_task'
async function delegate($: Body[0], fields: object = {}) {
  return $.tool.call({ tool: DELEGATE, tool_use_id: 'toolu_d', task: 'review the diff', title: 'review', ...fields } as never)
}
function tagOf(task: string): Record<string, unknown> {
  const match = /\n\n<!-- lastdrop (\{.*\}) -->$/.exec(task)
  expect(match).toBeTruthy()
  return JSON.parse(match![1]!)
}
async function mainStep($: Body[0], turnId: string) {
  const chunks = []
  for await (const chunk of $.turn.step({ turnId, index: 0, model: 'claude-haiku-5-5', messageCount: 1 })) chunks.push(chunk)
  return chunks
}
const child = (task: string, ...more: Message[]): Message[] => [{ role: 'user', content: [{ type: 'text', text: task }] }, ...more]

test('with an app without notes, outside auto mode, delegate_task with no target is tagged with the run and keeps no target', async ($, on) => {
  const e = engine([$, on], { notes: false })
  await $.classic.UserPromptSubmit({ prompt: 'hi', permission_mode: 'default' } as never)
  expect((await delegate($)).result).toEqual({ marker: `native ${DELEGATE}` })
  const input = e.nativeInputs.at(-1)!
  expect(input.target).toBeUndefined()
  expect(String(input.task).startsWith('review the diff\n\n<!-- lastdrop ')).toBe(true)
  const run = tagOf(String(input.task))
  expect(run.id).toMatch(/^t3-[a-z0-9]+$/)
  expect(run.agent).toBeUndefined()
  expect(run.description).toBe('review')
  const route = e.calls.find(c => c.flag === '--agent-route')!.request
  expect(route.prompt).toBe('review the diff')
  expect(route.parentModel).toBe('claude-haiku-5-5')
  expect(e.runCount).toBe(0)
})

test('delegate_task with an added model drops it from the target and tags it as the agent', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG })
  await $.classic.UserPromptSubmit({ prompt: 'hi', permission_mode: 'default' } as never)
  await delegate($, { target: { model: 'sol', options: { effort: 'high' } }, mode: 'async' })
  const input = e.nativeInputs.at(-1)!
  expect(input.target).toEqual({ options: { effort: 'high' } })
  expect(input.mode).toBe('async')
  const run = tagOf(String(input.task))
  expect(run.agent).toBe('sol')
  expect(run.model).toBeUndefined()
  expect(run.effort).toBe('high')
  expect(e.calls.find(c => c.flag === '--agent-route')?.request.agent).toBe('sol')
})

test('with an app without notes, delegate_task with a Claude model keeps it on the target and in the tag', async ($, on) => {
  const e = engine([$, on], { notes: false })
  await $.classic.UserPromptSubmit({ prompt: 'hi', permission_mode: 'default' } as never)
  await delegate($, { target: { model: 'claude-opus-5-5', options: [{ id: 'effort', value: 'max' }] } })
  const input = e.nativeInputs.at(-1)!
  expect((input.target as Record<string, unknown>).model).toBe('claude-opus-5-5')
  expect(tagOf(String(input.task))).toMatchObject({ model: 'claude-opus-5-5', effort: 'max' })
})

test('no room leaves a plain delegate_task untouched and denies an added model', async ($, on) => {
  const e = engine([$, on], { route: { type: 'no_room' }, catalog: CATALOG })
  await $.classic.UserPromptSubmit({ prompt: 'hi', permission_mode: 'default' } as never)
  await delegate($)
  expect(e.nativeInputs.at(-1)!.task).toBe('review the diff')
  expect((await delegate($, { target: { model: 'sol' } })).deny).toBe('lastdrop found nowhere to run sol.')
})

test('delegate_task to another provider, model or machine is left to T3', async ($, on) => {
  const e = engine([$, on])
  await delegate($, { target: { providerInstanceId: 'codex', model: 'gpt-6.1-sol' } })
  await delegate($, { target: { model: 'gpt-6.1-sol' } })
  await delegate($, { target: { environmentId: 'vps' } })
  expect(e.nativeInputs.map(i => i.task)).toEqual(['review the diff', 'review the diff', 'review the diff'])
  expect(e.calls.some(c => c.flag === '--agent-route')).toBe(false)
})

test('a delegated child’s turn runs on lastdrop’s runner, never on its own model', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG })
  e.messages(child('review the diff\n\n<!-- lastdrop {"id":"t3-abc","agent":"sol","effort":"high","description":"review"} -->'))
  const chunks = await mainStep($, 'turn-1')
  expect(report(chunks)).toBe(RESULT.text)
  expect(chunks.find(c => c.kind === 'stop')?.stopReason).toBe('end_turn')
  const request = e.calls.find(c => c.flag === '--agent-run')!.request
  expect(request).toMatchObject({ prompt: 'review the diff', id: 't3-abc', agent: 'sol', effort: 'high', subagentType: 'general-purpose', cwd: '/work' })
  expect(request.resume).toBeUndefined()
  expect(e.modelSteps).toBe(0)
})

test('a delegated child shows its steps live before its answer', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG, outputs: [{ type: 'step', text: 'Bash: git diff' }, RESULT] })
  e.messages(child('review the diff\n\n<!-- lastdrop {"id":"t3-abc","agent":"sol","effort":"high","description":"review"} -->'))
  const chunks = await mainStep($, 'turn-1')
  expect(chunks[0]).toMatchObject({ kind: 'thinking', index: 0, text: 'Bash: git diff\n\n' })
  expect(chunks.find(c => c.kind === 'text')).toMatchObject({ index: 1 })
  expect(report(chunks)).toBe(RESULT.text)
})

test('a follow-up to a delegated child resumes the same run with only the new message', async ($, on) => {
  const e = engine([$, on])
  const task = 'note the word\n\n<!-- lastdrop {"id":"t3-abc","model":"claude-haiku-5-5"} -->'
  e.messages(child(task))
  await mainStep($, 'turn-1')
  e.messages(child(task, { role: 'assistant', content: [{ type: 'text', text: 'noted' }] },
    { role: 'user', content: [{ type: 'text', text: 'what was it?' }] }))
  expect(report(await mainStep($, 'turn-2'))).toBe(RESULT.text)
  const run = e.calls.filter(c => c.flag === '--agent-run').at(-1)!.request
  expect(run).toMatchObject({ prompt: 'what was it?', resume: 't3-abc', id: 't3-abc', model: 'claude-haiku-5-5' })
  expect(e.modelSteps).toBe(0)
})

test('a steer during a delegated child’s turn resumes the same run, though the engine merges it into the task', async ($, on) => {
  const e = engine([$, on])
  const task = 'Act as the sub-agent.\n\nfix it\n\n<!-- lastdrop {"id":"t3-abc","agent":"sol"} -->'
  e.messages(child(task))
  await mainStep($, 'turn-1')
  // The steer stopped turn 1 before its answer was written: Claude Code sends task and steer as one message.
  e.messages([{ role: 'user', content: [{ type: 'text', text: '<system-reminder>\nctx\n</system-reminder>' },
    { type: 'text', text: task }, { type: 'text', text: 'stop opening windows' }] }])
  expect(report(await mainStep($, 'turn-2'))).toBe(RESULT.text)
  expect(e.calls.filter(c => c.flag === '--agent-run').at(-1)!.request)
    .toMatchObject({ prompt: 'stop opening windows', resume: 't3-abc', id: 't3-abc', agent: 'sol' })
  expect(e.modelSteps).toBe(0)
})

test('a steer before a delegated child’s first run reaches the runner with the task', async ($, on) => {
  const e = engine([$, on])
  e.messages([{ role: 'user', content: [{ type: 'text', text: 'fix it\n\n<!-- lastdrop {"id":"t3-abc","agent":"sol"} -->' },
    { type: 'text', text: 'stop opening windows' }] }])
  await mainStep($, 'turn-1')
  expect(e.calls.find(c => c.flag === '--agent-run')!.request).toMatchObject({ prompt: 'fix it\n\nstop opening windows' })
  expect(e.calls.find(c => c.flag === '--agent-run')!.request.resume).toBeUndefined()
  expect(e.modelSteps).toBe(0)
})

test('a delegated child stored with a message cursor still sends only its new message', async ($, on) => {
  const e = engine([$, on])
  const task = 'go\n\n<!-- lastdrop {"id":"t3-abc"} -->'
  e.store.set('delegated:t3-abc', { ran: true, native: false, cursor: 2 })
  e.messages(child(task, { role: 'assistant', content: [{ type: 'text', text: 'done' }] },
    { role: 'user', content: [{ type: 'text', text: 'next' }] }))
  await mainStep($, 'turn-2')
  expect(e.calls.find(c => c.flag === '--agent-run')!.request).toMatchObject({ prompt: 'next', resume: 't3-abc' })
})

test('after a long remote turn, a delegated child’s follow-up goes through', async ($, on) => {
  const e = engine([$, on], { outputs: [LONG] })
  const task = 'note the word\n\n<!-- lastdrop {"id":"t3-abc","model":"claude-haiku-5-5"} -->'
  e.messages(child(task))
  const first = await mainStep($, 'turn-1')
  expect(contextOf(first)).toBe(41_903)
  e.messages(child(task, { role: 'assistant', content: [{ type: 'text', text: RESULT.text }] },
    { role: 'user', content: [{ type: 'text', text: 'what was it?' }] }))
  const second = await mainStep($, 'turn-2')
  expect(report(second)).toBe(RESULT.text)
  expect(contextOf(second)).toBeLessThan(200_000)
  expect(e.calls.filter(c => c.flag === '--agent-run').at(-1)!.request).toMatchObject({ prompt: 'what was it?', resume: 't3-abc' })
  expect(e.modelSteps).toBe(0)
})

test('a delegated child the runner hands back runs on its own model from then on', async ($, on) => {
  const e = engine([$, on], { noStart: true, outputs: [{ type: 'native' }] })
  const task = 'do it\n\n<!-- lastdrop {"id":"t3-abc"} -->'
  e.messages(child(task))
  expect((await mainStep($, 'turn-1'))[0]).toEqual({ kind: 'text', index: 0, text: 'built-in response' })
  e.messages(child(task, { role: 'assistant', content: [] }, { role: 'user', content: [{ type: 'text', text: 'more' }] }))
  await mainStep($, 'turn-2')
  expect(e.runCount).toBe(1)
  expect(e.modelSteps).toBe(2)
})

test('a delegated added model that fails reports it and never falls back to Claude', async ($, on) => {
  const e = engine([$, on], { noStart: true, outputs: [{ type: 'no_room' }] })
  e.messages(child('do it\n\n<!-- lastdrop {"id":"t3-abc","agent":"sol"} -->'))
  expect(report(await mainStep($, 'turn-1'))).toBe('lastdrop agent failed: lastdrop found nowhere to run sol.')
  expect(e.modelSteps).toBe(0)
})

test('a main session without the tag keeps its own model', async ($, on) => {
  const e = engine([$, on])
  e.messages(child('hello <!-- lastdrop {"id":"x"} --> there'))
  await mainStep($, 'turn-1')
  expect(e.modelSteps).toBe(1)
  expect(e.runCount).toBe(0)
})

test('in T3 Code the listing says delegate_task accepts the added agents’ names too', async ($, on) => {
  engine([$, on], { catalog: CATALOG, env: { T3CODE_THREAD_ID: 'thread-1' } })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  expect(await listing($)).toBe(`${NATIVE_LISTING}\n\n${TYPES} delegate_task's target.model also accepts their names without the lastdrop: prefix. They run through the Agent tool like Claude's own agents, so the rule to use delegate_task for another provider's model doesn't apply to them: use Agent, and delegate_task only for background work.${COMMAND}`)
})

test('a delegated child’s report names the account and model it ran on', async ($, on) => {
  const e = engine([$, on], { outputs: [{ ...RESULT, account: 'Antigravity', model: 'claude-sonnet-5-5-medium' }] })
  e.messages(child('do it\n\n<!-- lastdrop {"id":"t3-abc"} -->'))
  expect(report(await mainStep($, 'turn-1'))).toBe(`Ran on Antigravity (claude-sonnet-5-5-medium).\n\n${RESULT.text}`)
})

const SHELL = { taskId: 'task-1', childThreadId: 'thread-1', providerInstanceId: 'claudeAgent', model: 'claude-haiku-5-5', status: 'running' }
const json = (answer: { result?: unknown; text?: unknown }) => {
  expect(answer.text).toBe(answer.result)
  return JSON.parse(answer.result as string)
}

test('delegate_task’s answer names the added model and where it runs, not the child thread’s model', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG, t3: { [DELEGATE]: SHELL } })
  await $.classic.UserPromptSubmit({ prompt: 'hi', permission_mode: 'default' } as never)
  const answer = await delegate($, { target: { model: 'sol' } })
  expect(json(answer)).toEqual({ ...SHELL, model: 'sol', runsOn: 'lastdrop · Codex · gpt-6.1-sol · high' })
  expect(answer.context).toBeUndefined()
  expect(e.store.get('delegated-child:task-1')).toBe('sol')
  expect(e.store.get('delegated-child:thread-1')).toBe('sol')
})

// Auto mode refuses a call a hook changed: with lastdrop's T3 instance set up, every call goes to T3 as written.
const delegateCalls = (e: ReturnType<typeof engine>) => e.nativeInputs.filter((_, i) => e.nativeCalls[i] === DELEGATE)
const AUTO = { prompt: 'hi', permission_mode: 'auto' }
const DELEGATED = { tool: DELEGATE, tool_use_id: 'toolu_d', task: 'review the diff', title: 'review' }
/** A delegate_task call as the hook passed it, keys in order. */
const passed = (e: ReturnType<typeof engine>) => delegateCalls(e).map(c => exact(c))
const asWritten = (...fields: object[]) => fields.map(f => exact({ ...DELEGATED, ...f }))
const routeChecks = (e: ReturnType<typeof engine>) => e.calls.filter(c => c.flag === '--agent-route').length
const FORM = 'sol runs on lastdrop\'s T3 instance: call delegate_task with target: { providerInstanceId: "lastdrop", model: "sol" }, or for foreground work the Agent tool with subagent_type: "lastdrop:sol".'

for (const mode of ['auto', 'bypassPermissions']) {
  test(`a call on the lastdrop instance reaches T3 byte for byte (${mode}), with no room check`, async ($, on) => {
    const e = engine([$, on], { catalog: CATALOG, lastdrop: 'accept', t3Instance: true, t3: { [DELEGATE]: SHELL } })
    await $.classic.UserPromptSubmit({ prompt: 'hi', permission_mode: mode } as never)
    const fields = { target: { providerInstanceId: 'lastdrop', model: 'sol' }, mode: 'async' }
    const answer = await delegate($, fields)
    expect(passed(e)).toEqual(asWritten(fields))
    expect(exact(delegateCalls(e)[0]!.target as object)).toEqual(exact(fields.target))
    expect(routeChecks(e)).toBe(0)
    // T3 names the child's real model: nothing is rewritten or remembered.
    expect(json(answer)).toEqual(SHELL)
    expect(e.store.has('delegated-child:task-1')).toBe(false)
  })
}

test('a Claude model on the lastdrop instance, or one lastdrop doesn\'t know, also goes unchanged', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG, lastdrop: 'accept', t3Instance: false })
  await $.classic.UserPromptSubmit(AUTO as never)
  const opus = { target: { providerInstanceId: 'lastdrop', model: 'opus' } }
  const nope = { target: { providerInstanceId: 'lastdrop', model: 'nope' } }
  await delegate($, opus)
  await delegate($, nope)
  expect(passed(e)).toEqual(asWritten(opus, nope))
})

test('with the lastdrop instance set up, an added model on T3\'s Claude instance is denied with the instance\'s form', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG, t3Instance: true })
  await $.classic.UserPromptSubmit({ prompt: 'hi', permission_mode: 'default' } as never)
  expect((await delegate($, { target: { model: 'sol', options: { effort: 'high' } } })).deny).toBe(FORM)
  expect((await delegate($, { target: { providerInstanceId: 'claudeAgent', model: 'sol' } })).deny).toBe(FORM)
  expect(delegateCalls(e).length).toBe(0)
})

// A plain Claude child goes to T3 as written in every mode; its run is noted beside the call.
const PARENT = { T3CODE_THREAD_ID: 'parent-1' }
for (const mode of ['auto', 'default', 'bypassPermissions', undefined]) {
  for (const t3Instance of [true, false]) {
    test(`a plain Claude child goes unchanged and its run is noted (${mode ?? 'unknown'} mode, instance ${t3Instance ? 'set up' : 'absent'})`, async ($, on) => {
      const e = engine([$, on], { catalog: CATALOG, t3Instance, env: PARENT })
      await $.classic.UserPromptSubmit((mode ? { prompt: 'hi', permission_mode: mode } : { prompt: 'hi' }) as never)
      const fields = { target: { model: 'opus', options: [{ id: 'effort', value: 'max' }] }, mode: 'async' }
      await delegate($, fields)
      expect(passed(e)).toEqual(asWritten(fields))
      expect(routeChecks(e)).toBe(1)
      expect(e.notes.length).toBe(1)
      const note = e.notes[0]!
      expect(note).toMatchObject({ task: 'review the diff', parentThread: 'parent-1', parentModel: 'claude-haiku-5-5',
        run: { model: 'opus', effort: 'max', description: 'review', ...(mode ? { permissionMode: mode } : {}) } })
      expect((note.run as Record<string, unknown>).agent).toBeUndefined()
      expect(note.id).toMatch(/^t3-[a-z0-9]+$/)
      expect((note.run as Record<string, unknown>).id).toBe(note.id)
      expect(Math.abs(Date.now() - Number(note.createdAt))).toBeLessThan(5_000)
    })
  }
}

test('a plain child with no model, a full model id or a mode of its own goes unchanged, noted', async ($, on) => {
  const e = engine([$, on], { t3Instance: true, env: PARENT })
  await $.classic.UserPromptSubmit(AUTO as never)
  await delegate($)
  await delegate($, { target: { model: 'claude-opus-5-5' }, runtimeMode: 'approval-required' })
  expect(passed(e)).toEqual(asWritten({}, { target: { model: 'claude-opus-5-5' }, runtimeMode: 'approval-required' }))
  expect(e.notes.map(n => (n.run as Record<string, unknown>).model)).toEqual([undefined, 'claude-opus-5-5'])
})

test('the note goes when T3 answers the call with an error', async ($, on) => {
  const e = engine([$, on], { env: PARENT, t3Errors: { [DELEGATE]: 'Delegated tasks require an active run.' } })
  await $.classic.UserPromptSubmit(AUTO as never)
  const answer = await delegate($)
  expect(answer.isError).toBe(true)
  expect(e.notes.length).toBe(0)
  expect(e.calls.filter(c => c.flag === '--delegate-note').map(c => c.request.op)).toEqual(['put', 'drop'])
})

test('the note goes when the call throws, and the call is not run again', async ($, on) => {
  const e = engine([$, on], { t3Throws: true, env: PARENT })
  await $.classic.UserPromptSubmit(AUTO as never)
  expect((await delegate($)).deny).toContain('lastdrop failed')
  expect(e.notes.length).toBe(0)
  expect(e.nativeCalls.filter(t => t === DELEGATE).length).toBe(1)
})

test('a note T3 accepted stays for its child, and T3\'s answer is left as it wrote it', async ($, on) => {
  const e = engine([$, on], { t3: { [DELEGATE]: SHELL }, env: PARENT })
  await $.classic.UserPromptSubmit(AUTO as never)
  expect(json(await delegate($))).toEqual(SHELL)
  expect(e.notes.length).toBe(1)
})

test('with no room, a plain child goes unchanged and nothing is noted', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG, t3Instance: true, route: { type: 'no_room' }, env: PARENT })
  await $.classic.UserPromptSubmit(AUTO as never)
  await delegate($, { target: { model: 'opus' } })
  expect(passed(e)).toEqual(asWritten({ target: { model: 'opus' } }))
  expect(routeChecks(e)).toBe(1)
  expect(e.notes.length).toBe(0)
})

test('with an app without notes, a plain child in auto mode goes unchanged, unchecked', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG, t3Instance: true, notes: false })
  await $.classic.UserPromptSubmit(AUTO as never)
  await delegate($, { target: { model: 'opus' } })
  expect(passed(e)).toEqual(asWritten({ target: { model: 'opus' } }))
  expect(routeChecks(e)).toBe(0)
  expect(e.calls.some(c => c.flag === '--delegate-note')).toBe(false)
})

for (const mode of ['auto', undefined]) {
  test(`without the lastdrop instance, ${mode ?? 'an unknown'} mode passes a plain child unchanged and denies an added model`, async ($, on) => {
    const e = engine([$, on], { catalog: CATALOG })
    await $.classic.UserPromptSubmit((mode ? { prompt: 'hi', permission_mode: mode } : { prompt: 'hi' }) as never)
    await delegate($)
    await delegate($, { target: { model: 'opus' } })
    expect(passed(e)).toEqual(asWritten({}, { target: { model: 'opus' } }))
    expect((await delegate($, { target: { model: 'sol' } })).deny)
      .toBe('lastdrop can\'t start sol through delegate_task in auto mode until its T3 provider is set up (lastdrop\'s T3 Code setting). Use the Agent tool with subagent_type: "lastdrop:sol".')
    expect(delegateCalls(e).length).toBe(2)
    // The plain children only: each noted after its room check.
    expect(routeChecks(e)).toBe(2)
  })
}

test('without the lastdrop instance, outside auto mode, the tag path stays, with the parent\'s mode in the tag', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG, t3Instance: false, t3: { [DELEGATE]: SHELL } })
  await $.classic.UserPromptSubmit({ prompt: 'hi', permission_mode: 'bypassPermissions' } as never)
  const answer = await delegate($, { target: { model: 'sol', options: { effort: 'high' } } })
  const [call, ...more] = delegateCalls(e)
  expect(more.length).toBe(0)
  expect(call!.target).toEqual({ options: { effort: 'high' } })
  expect(tagOf(String(call!.task))).toMatchObject({ agent: 'sol', effort: 'high', permissionMode: 'bypassPermissions' })
  expect(json(answer)).toEqual({ ...SHELL, model: 'sol', runsOn: 'lastdrop · Codex · gpt-6.1-sol · high' })
})

for (const mode of ['auto', 'default']) {
  test(`no room never changes a plain call (${mode})`, async ($, on) => {
    const e = engine([$, on], { route: { type: 'no_room' } })
    await $.classic.UserPromptSubmit({ prompt: 'hi', permission_mode: mode } as never)
    await delegate($)
    expect(passed(e)).toEqual(asWritten({}))
  })
}

test('another instance is left to T3', async ($, on) => {
  const e = engine([$, on], { t3Instance: true })
  await $.classic.UserPromptSubmit(AUTO as never)
  const fields = { target: { providerInstanceId: 'codex', model: 'gpt-6.1-sol' } }
  await delegate($, fields)
  expect(passed(e)).toEqual(asWritten(fields))
})

const REFUSALS = ['Provider instance lastdrop is not registered.', 'Provider lastdrop cannot run a child task: Provider instance is disabled.',
  'Model sol is not advertised by provider lastdrop.', 'provider_unavailable']

for (const error of REFUSALS) {
  test(`T3 refusing the lastdrop instance (${error.slice(0, 30)}) stops sending children there for ten minutes`, async ($, on) => {
    const e = engine([$, on], { catalog: CATALOG, t3Instance: true, lastdrop: { error }, t3: { [DELEGATE]: SHELL } })
    await $.classic.UserPromptSubmit(AUTO as never)
    const fields = { target: { providerInstanceId: 'lastdrop', model: 'sol' } }
    const refused = await delegate($, fields)
    expect(passed(e)).toEqual(asWritten(fields))
    expect(refused.isError).toBe(true)
    expect(refused.text).toBe(`${error}\n\nlastdrop: its T3 instance is unavailable right now, so sol can't run in the background. For foreground work, use the Agent tool with subagent_type: "lastdrop:sol".`)
    expect(refused.result).toBe(refused.text)
    expect(typeof e.store.get('t3-lastdrop:failed')).toBe('number')
    // In auto mode the old form is denied, no longer pointed at the instance: no loop.
    expect((await delegate($, { target: { model: 'sol' } })).deny).toBe('lastdrop\'s T3 instance is unavailable right now, so sol can\'t run in the background. For foreground work, use the Agent tool with subagent_type: "lastdrop:sol".')
    // A plain child goes to T3's Claude instance unchanged, noted after its room check.
    await delegate($)
    expect(passed(e)).toEqual(asWritten(fields, {}))
    expect(routeChecks(e)).toBe(1)
  })
}

test('a refused lastdrop instance outside auto mode sends added agents down the tag path, then is tried again', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG, t3Instance: true, t3: { [DELEGATE]: SHELL } })
  await $.classic.UserPromptSubmit({ prompt: 'hi', permission_mode: 'default' } as never)
  const refused = await delegate($, { target: { providerInstanceId: 'lastdrop', model: 'sol' } })
  expect(refused.text).toContain('Call delegate_task again with target: { model: "sol" }; lastdrop runs it from T3\'s Claude instance.')
  await delegate($, { target: { model: 'sol' } })
  expect(tagOf(String(delegateCalls(e).at(-1)!.task)).agent).toBe('sol')
  e.store.set('t3-lastdrop:failed', Date.now() - 11 * 60_000)
  expect((await delegate($, { target: { model: 'sol' } })).deny).toBe(FORM)
})

test('a Claude model refused on the lastdrop instance is told to go without it', async ($, on) => {
  engine([$, on], { catalog: CATALOG, t3Instance: true })
  await $.classic.UserPromptSubmit(AUTO as never)
  const refused = await delegate($, { target: { providerInstanceId: 'lastdrop', model: 'opus' } })
  expect(refused.text).toContain('Call delegate_task again without providerInstanceId; the child runs on T3\'s Claude instance.')
})

test('an error T3 gives after creating something, or none it explains, is not a refusal', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG, t3Instance: true, lastdrop: { error: 'Delegated tasks require an active run owned by this MCP provider session.' } })
  await $.classic.UserPromptSubmit(AUTO as never)
  const answer = await delegate($, { target: { providerInstanceId: 'lastdrop', model: 'sol' } })
  expect(answer.text).toBe('Delegated tasks require an active run owned by this MCP provider session.')
  expect(e.store.has('t3-lastdrop:failed')).toBe(false)
})

const BACKGROUND = 'Background work in T3 Code on Claude models (fable, opus, sonnet, haiku) uses delegate_task as usual; lastdrop picks the account.'
/** The instance paragraph as an earlier build of this branch froze it. */
const OLD_BACKGROUND = 'Background work in T3 Code goes to lastdrop\'s T3 instance: call delegate_task with target: { providerInstanceId: "lastdrop", model: "<model>" } and no options, where <model> is fable, opus, sonnet or haiku. lastdrop picks the account.'

test('in T3 Code with the lastdrop instance set up, the listing leads with background work there', async ($, on) => {
  engine([$, on], { catalog: CATALOG, env: { T3CODE_THREAD_ID: 'thread-1' }, t3Instance: true })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  expect(await listing($)).toBe(`${NATIVE_LISTING}\n\n${BACKGROUND} For an added agent, call delegate_task with target: { providerInstanceId: "lastdrop", model: "<name>" } and no options, where <name> is a lastdrop: agent type without lastdrop:; effort comes from the agent's own settings. ${TYPES} They run through the Agent tool like Claude's own agents, so the rule to use delegate_task for another provider's model doesn't apply to them: use Agent with them for foreground work.${COMMAND}`)
})

test('with the lastdrop instance set up and no added agents, the listing still names the instance, and stays frozen', async ($, on) => {
  const e = engine([$, on], { env: { T3CODE_THREAD_ID: 'thread-1' }, t3Instance: true })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  const text = `${NATIVE_LISTING}\n\n${BACKGROUND}`
  expect(await listing($)).toBe(text)
  // Replayed on resume: the stored paragraph, not read as a list from before the types.
  expect(await listing($)).toBe(text)
  expect(e.store.get('listing:session-1')).toBe(text.slice(NATIVE_LISTING.length + 2))
})

test('a listing frozen with the earlier instance paragraph keeps its bytes', async ($, on) => {
  const e = engine([$, on], { env: { T3CODE_THREAD_ID: 'thread-1' }, t3Instance: true })
  e.store.set('listing:session-1', OLD_BACKGROUND)
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  expect(await listing($)).toBe(`${NATIVE_LISTING}\n\n${OLD_BACKGROUND}`)
})

test('outside T3, or with the instance refused, the listing doesn\'t name it', async ($, on) => {
  const e = engine([$, on], { env: { T3CODE_THREAD_ID: 'thread-1' }, t3Instance: true })
  e.store.set('t3-lastdrop:failed', Date.now())
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  expect(await listing($)).toBe(NATIVE_LISTING)
})

test('the T3 listing stays frozen for the session when the instance is set up later', async ($, on) => {
  let ready = false
  const e = engine([$, on], { liveCatalog: () => ({ ...CATALOG, t3Instance: ready }), env: { T3CODE_THREAD_ID: 'thread-1' } })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  const first = await listing($)
  expect(first).toContain("delegate_task's target.model also accepts their names")
  ready = true
  await $.classic.UserPromptSubmit({ prompt: 'again' } as never)
  expect(await listing($)).toBe(first)
  // The call itself follows what lastdrop says now.
  expect((await delegate($, { target: { model: 'sol' } })).deny).toBe(FORM)
  expect(delegateCalls(e).length).toBe(0)
})

test('orchestrator_capabilities adds no models when T3 already lists a healthy lastdrop instance with them', async ($, on) => {
  const listed = { providers: [{ providerInstanceId: 'lastdrop', canRunChildTask: true, models: [{ id: 'sol' }, { id: 'argon' }, { id: 'opus' }] }] }
  engine([$, on], { catalog: CATALOG, t3: { 'mcp__t3-code__orchestrator_capabilities': listed } })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  const answer = await $.tool.call({ tool: 'mcp__t3-code__orchestrator_capabilities', tool_use_id: 'c' } as never)
  expect(json(answer)).toEqual(listed)
})

test('a plain delegate_task’s answer is left as T3 wrote it', async ($, on) => {
  engine([$, on], { t3: { [DELEGATE]: SHELL } })
  expect(json(await delegate($))).toEqual(SHELL)
})

test('T3’s later answers about an added model’s child name it too, and leave other threads alone', async ($, on) => {
  const read = { thread: { threadId: 'thread-1', model: 'claude-haiku-5-5' }, recentRuns: [{ runId: 'r1', model: 'claude-haiku-5-5' }] }
  const other = { thread: { threadId: 'thread-9', model: 'claude-haiku-5-5' } }
  engine([$, on], { catalog: CATALOG, t3: { [DELEGATE]: SHELL, 'mcp__t3-code__task_status': { ...SHELL, status: 'completed' },
    'mcp__t3-code__t3_thread_read': read, 'mcp__t3-code__t3_thread_list': other } })
  await $.classic.UserPromptSubmit({ prompt: 'hi', permission_mode: 'default' } as never)
  await delegate($, { target: { model: 'sol' } })
  const status = await $.tool.call({ tool: 'mcp__t3-code__task_status', tool_use_id: 't1', taskId: 'task-1' } as never)
  expect(json(status)).toMatchObject({ model: 'sol', runsOn: 'lastdrop · Codex · gpt-6.1-sol · high', status: 'completed' })
  const thread = await $.tool.call({ tool: 'mcp__t3-code__t3_thread_read', tool_use_id: 't2', threadId: 'thread-1' } as never)
  expect(json(thread)).toEqual({ thread: { threadId: 'thread-1', model: 'sol', runsOn: 'lastdrop · Codex · gpt-6.1-sol · high' },
    recentRuns: [{ runId: 'r1', model: 'sol', runsOn: 'lastdrop · Codex · gpt-6.1-sol · high' }] })
  expect(json(await $.tool.call({ tool: 'mcp__t3-code__t3_thread_list', tool_use_id: 't3' } as never))).toEqual(other)
})

test('orchestrator_capabilities’ answer lists the added models and where they run', async ($, on) => {
  const caps = { inheritedModel: 'claude-haiku-5-5', providers: [{ providerInstanceId: 'antigravity', constraints: ['Provider instance is disabled.'] }] }
  engine([$, on], { catalog: CATALOG, t3: { 'mcp__t3-code__orchestrator_capabilities': caps } })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  const answer = await $.tool.call({ tool: 'mcp__t3-code__orchestrator_capabilities', tool_use_id: 'toolu_c' } as never)
  expect(json(answer)).toEqual({ ...caps, addedModels: [
    { model: 'sol', runsOn: 'lastdrop · Codex · gpt-6.1-sol · high' },
    { model: 'argon', runsOn: 'lastdrop · Antigravity · gemini-4-argon' },
  ] })
})

test('a delegated child’s conversation is never compacted, so its tag stays', async ($, on) => {
  const e = engine([$, on])
  e.messages(child('do it\n\n<!-- lastdrop {"id":"t3-abc","agent":"sol"} -->'))
  const answer = await $.session.compact({ trigger: 'manual', messages: [MESSAGE] } as never)
  expect(answer.skip).toBe('lastdrop runs this thread’s agent elsewhere; its conversation stays whole.')
  e.messages(child('hello'))
  expect((await $.session.compact({ trigger: 'manual', messages: [MESSAGE] } as never)).skip).toBeUndefined()
})

test('a delegated child whose state was lost resumes after lastdrop’s last answer', async ($, on) => {
  const e = engine([$, on])
  e.messages(child('first task\n\n<!-- lastdrop {"id":"t3-abc"} -->', { role: 'assistant', content: [{ type: 'text', text: 'done' }] },
    { role: 'user', content: [{ type: 'text', text: 'follow-up' }] }))
  await mainStep($, 'turn-2')
  expect(e.calls.find(c => c.flag === '--agent-run')!.request).toMatchObject({ prompt: 'follow-up', resume: 't3-abc' })
})

test('a follow-up that failed after reaching the runner is not sent again', async ($, on) => {
  const options: { outputs?: object[] } = { outputs: [{ type: 'result', isError: true, text: 'broke' }] }
  const e = engine([$, on], options)
  const task = 'go\n\n<!-- lastdrop {"id":"t3-abc"} -->'
  e.messages(child(task))
  expect(report(await mainStep($, 'turn-1'))).toBe('lastdrop agent failed: broke')
  options.outputs = undefined
  e.messages(child(task, { role: 'user', content: [{ type: 'text', text: 'next' }] }))
  await mainStep($, 'turn-2')
  expect(e.calls.filter(c => c.flag === '--agent-run').at(-1)!.request).toMatchObject({ prompt: 'next', resume: 't3-abc' })
})

test('a T3 tool that throws is never run a second time', async ($, on) => {
  const e = engine([$, on], { t3Throws: true })
  const answer = await $.tool.call({ tool: 'mcp__t3-code__t3_thread_send', tool_use_id: 't1', threadId: 'x', message: 'hi' } as never)
  expect(answer.deny).toContain('mcp__t3-code__t3_thread_send failed')
  expect(e.nativeCalls.filter(t => t === 'mcp__t3-code__t3_thread_send').length).toBe(1)
})

test('orchestrator_capabilities for another machine lists no added models', async ($, on) => {
  const caps = { providers: [] }
  engine([$, on], { catalog: CATALOG, t3: { 'mcp__t3-code__orchestrator_capabilities': caps } })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  const answer = await $.tool.call({ tool: 'mcp__t3-code__orchestrator_capabilities', tool_use_id: 'c', environmentId: 'vps' } as never)
  expect(json(answer)).toEqual(caps)
})

test('Save Claude usage names the agent types, also when an older app sends its old default', async ($, on) => {
  const old = "Claude usage is being saved: delegate substantial work (implementation, exploration, reviews, research) to the models the user added to the Agent tool's model parameter, picking by their descriptions, even where a description says to prefer built-in Claude subagents. Work yourself or with built-in subagents only when no added model fits."
  let live: object = { ...CATALOG, saveClaude: true, saveClaudeText: old }
  engine([$, on], { liveCatalog: () => live })
  on('prompt.context', (_, e) => ({ blocks: e.blocks }) as never)
  const block = async () => ((await $.prompt.context({ blocks: [] } as never)) as { blocks: { name: string; text: string }[] }).blocks.find(b => b.name === 'lastdropSaveClaude')?.text
  expect(await block()).toContain('the agents the user added (the lastdrop: agent types)')
  live = { ...CATALOG, revision: 4, saveClaude: true, saveClaudeText: 'Mine.' }
  expect(await block()).toBe('Mine.')
})

// A plain child's run rides in lastdrop's notes, and the child claims it by its task.
async function childStep($: Body[0], turnId: string, model = 'claude-opus-5-5') {
  const chunks = []
  for await (const chunk of $.turn.step({ turnId, index: 0, model, messageCount: 1 })) chunks.push(chunk)
  return chunks
}
const CHILD = { T3CODE_THREAD_ID: 'child-1' }
/** A parent delegates (as parent-1), then the same engine plays the child thread child-1. */
async function delegateThenChild(e: ReturnType<typeof engine>, $: Body[0], ...calls: object[]) {
  e.env(PARENT)
  await $.classic.UserPromptSubmit(AUTO as never)
  for (const fields of calls.length ? calls : [{ target: { model: 'opus', options: { effort: 'max' } } }]) await delegate($, fields)
  e.env(CHILD)
}
const runs = (e: ReturnType<typeof engine>) => e.calls.filter(c => c.flag === '--agent-run').map(c => c.request)

test('a noted child claims its run by its task and runs on lastdrop\'s runner', async ($, on) => {
  const e = engine([$, on], { lineage: 'parent-1' })
  await delegateThenChild(e, $)
  const id = e.notes[0]!.id
  e.messages(child('review the diff'))
  expect(report(await childStep($, 'turn-1'))).toBe(RESULT.text)
  expect(runs(e)[0]).toMatchObject({ prompt: 'review the diff', id, model: 'opus', effort: 'max', description: 'review', permissionMode: 'auto', subagentType: 'general-purpose' })
  expect(runs(e)[0]!.resume).toBeUndefined()
  expect(runs(e)[0]!.agent).toBeUndefined()
  expect(e.modelSteps).toBe(0)
  expect(e.notes[0]!.thread).toBe('child-1')
  expect(e.mcpCalls[0]).toMatchObject({ server: 't3-code', tool: 't3_thread_read', args: { threadId: 'child-1', limit: 1, maxCharsPerItem: 1 } })
})

test('a noted child\'s task may follow T3\'s role line, and a steer merged after it reaches the first run', async ($, on) => {
  const e = engine([$, on], { lineage: 'parent-1' })
  await delegateThenChild(e, $)
  e.messages([{ role: 'user', content: [{ type: 'text', text: '<system-reminder>\nctx\n</system-reminder>' },
    { type: 'text', text: 'Act as the review sub-agent for this task.\n\nreview the diff' }, { type: 'text', text: 'stop opening windows' }] }])
  await childStep($, 'turn-1')
  expect(runs(e)[0]).toMatchObject({ prompt: 'Act as the review sub-agent for this task.\n\nreview the diff\n\nstop opening windows' })
  expect(e.modelSteps).toBe(0)
})

test('a follow-up to a noted child resumes the same run, also from a new process that has only lastdrop\'s notes', async ($, on) => {
  const e = engine([$, on], { lineage: 'parent-1' })
  await delegateThenChild(e, $)
  const id = e.notes[0]!.id
  e.messages(child('Act as the review sub-agent for this task.\n\nreview the diff'))
  await childStep($, 'turn-1')
  // A steer merged into the task after the first run, then a follow-up.
  e.messages([{ role: 'user', content: [{ type: 'text', text: 'Act as the review sub-agent for this task.\n\nreview the diff' }, { type: 'text', text: 'also the tests' }] }])
  await childStep($, 'turn-2')
  expect(runs(e).at(-1)).toMatchObject({ prompt: 'also the tests', resume: id, id })
  e.messages([{ role: 'user', content: [{ type: 'text', text: 'Act as the review sub-agent for this task.\n\nreview the diff' }, { type: 'text', text: 'also the tests' }] },
    { role: 'assistant', content: [{ type: 'text', text: 'done' }] }, { role: 'user', content: [{ type: 'text', text: 'what was it?' }] }])
  await childStep($, 'turn-3')
  expect(runs(e).at(-1)).toMatchObject({ prompt: 'what was it?', resume: id, id })
  expect(e.modelSteps).toBe(0)
})

test('a child process that finds its binding only in lastdrop\'s notes resumes the run', async ($, on) => {
  const e = engine([$, on], { lineage: 'parent-1', env: CHILD })
  const run = { id: 't3-old', model: 'opus' }
  e.notes.push({ id: 't3-old', run, task: 'review the diff', parentThread: 'parent-1', createdAt: Date.now() - 60 * 60_000, thread: 'child-1' })
  e.store.set('delegated:t3-old', { ran: true, native: false, sent: 1 })
  e.messages(child('review the diff', { role: 'assistant', content: [{ type: 'text', text: 'done' }] },
    { role: 'user', content: [{ type: 'text', text: 'what was it?' }] }))
  await childStep($, 'turn-2')
  expect(runs(e)[0]).toMatchObject({ prompt: 'what was it?', resume: 't3-old', id: 't3-old', model: 'opus' })
  expect(e.store.get('delegated-thread:child-1')).toMatchObject({ id: 't3-old' })
  expect(e.modelSteps).toBe(0)
})

test('two notes with the same task go to the children whose models they asked for', async ($, on) => {
  const e = engine([$, on], { lineage: 'parent-1' })
  await delegateThenChild(e, $, { target: { model: 'opus' } }, { target: { model: 'sonnet' } })
  const [opus, sonnet] = e.notes.map(n => n.id)
  e.messages(child('review the diff'))
  await childStep($, 'turn-1', 'claude-sonnet-5-5')
  expect(runs(e)[0]).toMatchObject({ id: sonnet, model: 'sonnet' })
  e.env({ T3CODE_THREAD_ID: 'child-2' })
  await childStep($, 'turn-1', 'claude-opus-5-5')
  expect(runs(e)[1]).toMatchObject({ id: opus, model: 'opus' })
  expect(e.notes.map(n => n.thread)).toEqual(['child-2', 'child-1'])
})

test('of two notes for the same model, the oldest goes first', async ($, on) => {
  const e = engine([$, on], { lineage: 'parent-1' })
  await delegateThenChild(e, $, {}, {})
  e.notes[1]!.createdAt = Number(e.notes[0]!.createdAt) - 1
  e.messages(child('review the diff'))
  await childStep($, 'turn-1', 'claude-haiku-5-5')
  expect(runs(e)[0]!.id).toBe(e.notes[1]!.id)
})

test('an expired note is never claimed', async ($, on) => {
  const e = engine([$, on], { lineage: 'parent-1' })
  await delegateThenChild(e, $)
  e.notes[0]!.createdAt = Date.now() - 11 * 60_000
  e.messages(child('review the diff'))
  await childStep($, 'turn-1')
  expect(e.modelSteps).toBe(1)
  expect(e.runCount).toBe(0)
  expect(e.notes[0]!.thread).toBeUndefined()
})

for (const [what, lineage] of [['a thread T3 says nobody delegated', null], ['a child of another thread', 'parent-9']] as const) {
  test(`${what} with the same text claims nothing`, async ($, on) => {
    const e = engine([$, on], { lineage })
    await delegateThenChild(e, $)
    e.messages(child('review the diff'))
    await childStep($, 'turn-1')
    await childStep($, 'turn-1b')
    expect(e.modelSteps).toBe(2)
    expect(e.runCount).toBe(0)
    expect(e.notes[0]!.thread).toBeUndefined()
    // Asked once per process.
    expect(e.calls.filter(c => c.flag === '--delegate-note' && c.request.op === 'list').length).toBe(1)
  })
}

test('when T3 can\'t say whose child it is, only a single matching note is claimed', async ($, on) => {
  const e = engine([$, on], { lineage: 'error' })
  await delegateThenChild(e, $)
  e.messages(child('review the diff'))
  await childStep($, 'turn-1')
  expect(e.mcpCalls.length).toBe(3)
  expect(e.runCount).toBe(1)
  expect(e.notes[0]!.thread).toBe('child-1')
})

test('when T3 can\'t say whose child it is and two notes match, none is claimed', async ($, on) => {
  const e = engine([$, on], { lineage: 'error' })
  await delegateThenChild(e, $, { target: { model: 'opus' } }, { target: { model: 'sonnet' } })
  e.messages(child('review the diff'))
  await childStep($, 'turn-1')
  expect(e.runCount).toBe(0)
  expect(e.modelSteps).toBe(1)
  expect(e.notes.every(n => n.thread === undefined)).toBe(true)
})

test('a task that only ends a longer word, or a thread that already answered, claims nothing', async ($, on) => {
  const e = engine([$, on], { lineage: 'parent-1' })
  await delegateThenChild(e, $)
  e.messages(child('please, review the diff'))
  await childStep($, 'turn-1')
  e.env({ T3CODE_THREAD_ID: 'child-2' })
  e.messages(child('review the diff', { role: 'assistant', content: [{ type: 'text', text: 'hi' }] }, { role: 'user', content: [{ type: 'text', text: 'more' }] }))
  await childStep($, 'turn-2')
  expect(e.runCount).toBe(0)
  expect(e.notes[0]!.thread).toBeUndefined()
})

test('a session outside T3 never asks for notes', async ($, on) => {
  const e = engine([$, on])
  e.messages(child('review the diff'))
  await mainStep($, 'turn-1')
  expect(e.calls.some(c => c.flag === '--delegate-note')).toBe(false)
  expect(e.modelSteps).toBe(1)
})

test('a noted child the runner hands back runs on its own model from then on', async ($, on) => {
  const e = engine([$, on], { lineage: 'parent-1', noStart: true, outputs: [{ type: 'native' }] })
  await delegateThenChild(e, $)
  e.messages(child('review the diff'))
  expect((await childStep($, 'turn-1'))[0]).toEqual({ kind: 'text', index: 0, text: 'built-in response' })
  e.messages(child('review the diff', { role: 'assistant', content: [] }, { role: 'user', content: [{ type: 'text', text: 'more' }] }))
  await childStep($, 'turn-2')
  expect(e.runCount).toBe(1)
  expect(e.modelSteps).toBe(2)
})

test('a noted child\'s conversation is never compacted', async ($, on) => {
  const e = engine([$, on], { lineage: 'parent-1' })
  await delegateThenChild(e, $)
  e.messages(child('review the diff'))
  await childStep($, 'turn-1')
  expect((await $.session.compact({ trigger: 'manual', messages: [MESSAGE] } as never)).skip).toBe('lastdrop runs this thread’s agent elsewhere; its conversation stays whole.')
})

test('a failing note ledger leaves the thread on its own model, and the parent\'s call unchanged', async ($, on) => {
  const e = engine([$, on], { env: PARENT, notesFail: true, lineage: 'parent-1' })
  await $.classic.UserPromptSubmit(AUTO as never)
  await delegate($)
  expect(passed(e)).toEqual(asWritten({}))
  e.env(CHILD)
  e.messages(child('review the diff'))
  expect(report(await childStep($, 'turn-1'))).toBe('built-in response')
  expect(e.modelSteps).toBe(1)
})

// delegate_task's own description names the added agents while the instance is set up.
async function described($: Body[0]) {
  return (await $.tool.describe({ tool: DELEGATE, description: 'Delegate a task.', provider: { plugin: 'mcp:t3-code', tier: 'user' } } as never)).description
}
const SUPPLEMENT = '\n\nThe agents the user added to lastdrop (sol, argon) run only with target.providerInstanceId "lastdrop" and target.model set to the agent\'s name; Claude models need no providerInstanceId.'

test('delegate_task\'s description names the added agents and the instance, the same at every read', async ($, on) => {
  engine([$, on], { catalog: CATALOG, t3Instance: true })
  expect(await described($)).toBe(`Delegate a task.${SUPPLEMENT}`)
  await $.classic.UserPromptSubmit(AUTO as never)
  expect(await described($)).toBe(`Delegate a task.${SUPPLEMENT}`)
})

test('without the instance or added agents, delegate_task\'s description is T3\'s', async ($, on) => {
  engine([$, on], { catalog: CATALOG })
  expect(await described($)).toBe('Delegate a task.')
})

test('a change to the added agents or the instance invalidates delegate_task\'s description; an unchanged catalog doesn\'t', async ($, on) => {
  let live: object = { ...CATALOG, t3Instance: true }
  const e = engine([$, on], { liveCatalog: () => live })
  await $.classic.UserPromptSubmit(AUTO as never)
  await $.classic.UserPromptSubmit(AUTO as never)
  expect(e.invalidated.filter(x => x === 'tool.describe').length).toBe(0)
  live = { ...CATALOG, t3Instance: false }
  await $.classic.UserPromptSubmit(AUTO as never)
  expect(e.invalidated.filter(x => x === 'tool.describe').length).toBe(1)
  expect(await described($)).toBe('Delegate a task.')
})
