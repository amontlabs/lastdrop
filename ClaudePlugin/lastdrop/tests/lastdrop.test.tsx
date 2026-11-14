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
const LIST = '- sol: Reviews: hard bugs. (Codex · gpt-6.1-sol · high)\n- argon: Advisor: trade-offs. (Antigravity · gemini-4-argon)'
const ADDED = "The Agent tool's model parameter also accepts these models the user added:\n"
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
}

function engine([$test, on]: Body, options: Options = {}) {
  const calls: { flag: string; request: Record<string, unknown> }[] = []
  const spawned: object[] = []
  const nativeCalls: string[] = []
  const nativeInputs: Record<string, unknown>[] = []
  const statuses: (string | undefined)[] = []
  const submitted: (readonly string[] | undefined)[] = []
  const invalidated: string[] = []
  const store = new Map<string, unknown>()
  const context = (value: Message[]) => options.handback === false ? value : value.map((m, i) =>
    i === 0 ? { ...m, content: [...m.content, { type: 'text', text: HANDBACK }] } : m)
  let messages: Message[] = context([{ role: 'user', content: [{ type: 'text', text: 'initial task' }] }])
  let modelSteps = 0
  let runCount = 0
  on('fs.exists', () => ({ value: true }))
  on('env.get', (_, e) => ({ value: options.env?.[e.name] }))
  on('session.cwd', () => ({ value: '/work' }))
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
  on('prompt.attachment', (_, e) => ({ text: e.text }))
  on('command.register', (_, e) => ({ value: { command: `lastdrop:${e.name}` } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('classic.UserPromptSubmit', () => ({}))
  on('prompt.submit', (_, e) => { submitted.push(e.context); return { text: e.text, context: e.context } })
  on('process.spawn', async function* (_, e) {
    const flag = e.argv[1] ?? ''
    const request = JSON.parse(e.input || '{}') as Record<string, unknown>
    calls.push({ flag, request })
    if (options.runnerFails) throw new Error('no runner')
    if (flag === '--agent-route') yield { stream: 'stdout', text: lines(options.route ?? { type: 'routed' }) }
    else if (flag === '--agent-catalog') yield { stream: 'stdout', text: lines({ ...(options.liveCatalog?.() ?? options.catalog ?? { revision: 1, agents: [] }), nativeTasks: options.nativeTasks ?? true, agentModels: options.agentModels ?? true }) }
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
    const t3 = options.t3?.[e.tool]
    // As Claude Code gives a T3 tool's answer: one JSON string (blocks in older versions).
    if (t3) return { result: JSON.stringify(t3), text: JSON.stringify(t3) } as never
    if (e.tool !== 'Agent') return { result: { marker: `native ${e.tool}` } }
    if (options.refusal) return { deny: options.refusal }
    const spawn = await $test.agent.spawn({ tool_use_id: e.tool_use_id, prompt: e.prompt, description: e.description,
      subagentType: e.subagent_type ?? 'general-purpose', model: e.model, cwd: '/native', permissionMode: options.handback === false ? 'acceptEdits' : 'auto',
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
  return { calls, spawned, nativeCalls, nativeInputs, statuses, submitted, invalidated, store,
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
  await e.launch({ model: 'sol' })
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
  await e.launch({ model: 'sol' })
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

test('only the remote worker creates a routed worktree', async ($, on) => {
  const e = engine([$, on])
  await e.launch({ isolation: 'worktree' })
  expect(e.nativeInputs[0]?.isolation).toBeUndefined()
  await step($)
  expect(e.calls.find(c => c.flag === '--agent-run')?.request.isolation).toBe('worktree')
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

test('an added agent runs through the model parameter on the native adapter', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await e.launch({ model: 'sol' })
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
  expect((await e.launch({ model: 'nova' })).deny).toBe("Model nova isn't available. Use sonnet, opus, haiku, fable, or: sol, argon.")
  expect(e.calls.filter(c => c.flag === '--agent-catalog').length).toBe(1)
  expect(e.spawned).toEqual([])
})

test('with no added agents an unknown model lists only Claude models', async ($, on) => {
  const e = engine([$, on])
  expect((await e.launch({ model: 'nova' })).deny).toBe("Model nova isn't available. Use sonnet, opus, haiku, fable.")
})

test('an agent added since the last read is found by the call', async ($, on) => {
  let live: object = { revision: 1, agents: [] }
  const e = engine([$, on], { liveCatalog: () => live })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  live = CATALOG
  expect((await e.launch({ model: 'sol' })).result).toEqual(NATIVE)
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
  await e.launch({ model: 'sol' })
  await e.launch({ model: 'sonnet', tool_use_id: 'toolu_2' })
  await e.launch({ tool_use_id: 'toolu_3' })
  expect(e.spawned.map(s => s.model)).toEqual(['sol', 'sonnet', undefined])
  expect(e.calls.find(c => c.flag === '--agent-route')?.request.model).toBeUndefined()
  expect(e.calls.find(c => c.flag === '--agent-route')?.request.agent).toBe('sol')
})

test('Explore and Plan pass their role; other types pass none', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  for (const type of ['Explore', 'Plan', 'general-purpose', 'claude', undefined]) {
    await e.launch({ model: 'sol', subagent_type: type })
  }
  const routes = e.calls.filter(c => c.flag === '--agent-route').map(c => c.request)
  expect(routes.map(r => r.role)).toEqual(['Explore', 'Plan', undefined, undefined, undefined])
  expect(routes.map(r => r.subagentType)).toEqual(['Explore', 'Plan', 'general-purpose', 'claude', undefined])
  await e.launch({ model: 'sol', subagent_type: 'Explore', tool_use_id: 'toolu_y' })
  expect(e.nativeInputs.at(-1)?.subagent_type).toBe('Explore')
  expect(report(await step($))).toContain('Ran on')
  expect(e.calls.find(c => c.flag === '--agent-run')?.request.role).toBeDefined()
})

test('an added agent refuses custom types, nesting, names and remote isolation', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG })
  expect((await e.launch({ model: 'sol', subagent_type: 'code-reviewer' })).deny).toBe('sol runs only as general-purpose, Explore or Plan.')
  for (const fields of [{ agentId: 'parent-agent' }, { name: 'teammate' }, { isolation: 'remote' }]) {
    expect((await e.launch({ model: 'sol', ...fields })).deny).toContain('run only from the main session')
  }
  expect(e.spawned).toEqual([])
  expect(e.nativeCalls).toEqual([])
})

test('a lastdrop: type is denied and names the model that replaces it', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG })
  expect((await e.launch({ subagent_type: 'lastdrop:sol' })).deny).toContain('model: "sol"')
  expect((await e.launch({ subagent_type: 'lastdrop:sol', agentId: 'parent-agent' })).deny).toContain('model: "sol"')
  expect(e.nativeCalls).toEqual([])
})

test('an added agent with no room is denied, never run by the built-in agent', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG, route: { type: 'no_room' } })
  expect((await e.launch({ model: 'sol' })).deny).toContain('nowhere to run sol')
  expect(e.spawned).toEqual([])
})

test('an added agent keeps the worktree out of the native shell', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG })
  await e.launch({ model: 'sol', isolation: 'worktree' })
  expect(e.nativeInputs[0]?.isolation).toBeUndefined()
  await step($)
  expect(e.calls.find(c => c.flag === '--agent-run')?.request.isolation).toBe('worktree')
})

test('a special spawn of an added agent is denied', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG, fork: true })
  expect((await e.launch({ model: 'sol' })).deny).toContain('run only from the main session')
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
  await e.launch({ model: 'sol' })
  expect(report(await step($))).toBe(`Ran on gpt-6.1-sol.\n\n${RESULT.text}`)
  outputs[0] = { ...result, worktreePath: '/w/x', worktreeBranch: 'agent-x' }
  await e.launch({ model: 'sol', tool_use_id: 'toolu_2' })
  expect(report(await step($, 'turn-2'))).toContain(`Ran on gpt-6.1-sol. Worktree: /w/x (branch agent-x).\n\n`)
  outputs[0] = full
  await e.launch({ model: 'sol', tool_use_id: 'toolu_3' })
  expect(report(await step($, 'turn-3'))).toBe(`Ran on gpt-6.1-sol. Worktree: /w/x (branch agent-x).\nDeclined: git push (needed approval); rm -rf build (needed approval)\n\n${RESULT.text}`)
})

test('Claude reroutes and failed agent runs get no header', async ($, on) => {
  const outputs: object[] = [RESULT]
  const e = engine([$, on], { catalog: CATALOG, outputs })
  await e.launch()
  expect(report(await step($))).toBe(RESULT.text)
  outputs[0] = { type: 'result', isError: true, text: 'it broke', model: 'gpt-6.1-sol' }
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await e.launch({ model: 'sol', tool_use_id: 'toolu_2' })
  expect(report(await step($, 'turn-2'))).toBe('lastdrop agent failed: Error: it broke')
})

test('the main loop listing gets the added agents', async ($, on) => {
  engine([$, on], { catalog: CATALOG })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  expect(await listing($)).toBe(`${NATIVE_LISTING}\n\n${ADDED}${LIST}${COMMAND}`)
})

test('the pointer to the command stays out of notes, and a listing frozen without it keeps its bytes', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await listing($)
  e.store.delete('announced:session-1')
  expect(await submit($)).toBeUndefined()
  e.store.set('listing:session-1', LIST)
  expect(await listing($)).toBe(`${NATIVE_LISTING}\n\n${ADDED}${LIST}`)
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
  expect(e.store.get('listing:session-1')).toBe(`${LIST}${COMMAND}`)
  live = { revision: 9, agents: [{ ...CATALOG.agents[0], description: 'Changed.' }] }
  await $.classic.UserPromptSubmit({ prompt: 'again' } as never)
  expect(await listing($)).toBe(first)
  // Another session starts from the list as it reads now.
  id = 'session-2'
  expect(await listing($)).toContain('- sol: Changed. (Codex')
  expect(e.store.get('listing:session-2')).toContain('Changed.')
})

test('a compaction of the main loop clears the frozen listing; a subagent compaction does not', async ($, on) => {
  let live: object = CATALOG
  const e = engine([$, on], { liveCatalog: () => live })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await listing($)
  await $.session.compact({ trigger: 'manual', agentId: 'a-sub', messages: [MESSAGE] } as never)
  expect(e.store.has('listing:session-1')).toBe(true)
  await $.session.compact({ trigger: 'manual', messages: [MESSAGE] } as never)
  expect(e.store.has('listing:session-1')).toBe(false)
  expect(e.store.has('announced:session-1')).toBe(false)
  live = { revision: 9, agents: [CATALOG.agents[1]] }
  await $.classic.UserPromptSubmit({ prompt: 'again' } as never)
  expect(await listing($)).toBe(`${NATIVE_LISTING}\n\n${ADDED}- argon: Advisor: trade-offs. (Antigravity · gemini-4-argon)${COMMAND}`)
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
  expect(e.store.get('listing:after')).toBe(`${LIST}${COMMAND}`)
})

test('the stored listings of old sessions are pruned to the latest hundred', async ($, on) => {
  let id = 's0'
  const e = engine([$, on], { catalog: CATALOG, sessionId: () => id })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  for (let i = 0; i < 105; i++) { id = `s${i}`; await listing($) }
  expect([...e.store.keys()].filter(k => k.startsWith('listing:')).length).toBe(100)
  expect([...e.store.keys()].filter(k => k.startsWith('announced:')).length).toBe(100)
  expect(e.store.has('listing:s0')).toBe(false)
  expect(e.store.has('listing:s104')).toBe(true)
})

test('a changed list is announced once beside the next prompt, and a removed list too', async ($, on) => {
  let live: object = CATALOG
  engine([$, on], { liveCatalog: () => live })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  expect(await submit($)).toBeUndefined()
  await listing($)
  expect(await submit($)).toBeUndefined()
  live = { revision: 9, agents: [CATALOG.agents[1]] }
  const note = "The models the user added to the Agent tool's model parameter changed. It now accepts:\n- argon: Advisor: trade-offs. (Antigravity · gemini-4-argon)"
  expect(await submit($)).toEqual([note])
  expect(await submit($)).toBeUndefined()
  live = { revision: 10, agents: [] }
  expect(await submit($)).toEqual(["The models the user added to the Agent tool's model parameter were removed."])
  expect(await submit($)).toBeUndefined()
})

test('a resumed session with a changed list keeps its frozen listing and announces the difference', async ($, on) => {
  const e = engine([$, on], { catalog: { revision: 9, agents: [CATALOG.agents[1]] } })
  e.store.set('listing:session-1', LIST)
  expect(await listing($)).toBe(`${NATIVE_LISTING}\n\n${ADDED}${LIST}`)
  expect(await submit($)).toEqual([expect.stringContaining('now accepts:\n- argon')])
})

test('a note joins context a prompt already carries', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG })
  e.store.set('listing:session-1', '')
  const context = (await $.prompt.submit({ text: 'hi', wait: false, origin: { kind: 'user' }, context: ['mine'] } as never)).context
  expect(context?.[0]).toBe('mine')
  expect(context?.[1]).toContain(LIST)
})

test('without a frozen listing after the first prompt the full list goes in a note, with one status', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG })
  expect(await submit($)).toBeUndefined()
  expect(await submit($)).toEqual([`The models the user added to the Agent tool's model parameter changed. It now accepts:\n${LIST}`])
  expect(await submit($)).toBeUndefined()
  expect(e.statuses.filter(t => t?.includes('agent list changed')).length).toBe(1)
})

test('an empty list with no frozen listing raises no note and no status', async ($, on) => {
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
  expect((await e.launch({ model: 'sol' })).deny).toContain('Update the lastdrop app')
  expect(e.spawned).toEqual([])
  expect((await e.launch({ model: 'sonnet' })).result).toEqual(NATIVE)
  expect((await e.launch()).result).toEqual(NATIVE)
})

test('the first-prompt grace lives in the store and ends with the listing reset', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG })
  await submit($)
  expect(e.store.get('grace:session-1')).toBe(true)
  // A reloaded plugin has no memory of it, and the next prompt is the one that tells.
  expect((await submit($))?.[0]).toContain(LIST)
  await $.session.compact({ trigger: 'manual', messages: [MESSAGE] } as never)
  expect(e.store.has('grace:session-1')).toBe(false)
  expect(await submit($)).toBeUndefined()
})

test('a store that refuses writes never breaks the listing or the prompt', async ($, on) => {
  engine([$, on], { catalog: CATALOG, storeFailure: true })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  expect(await listing($)).toBe(`${NATIVE_LISTING}\n\n${ADDED}${LIST}${COMMAND}`)
  expect(await submit($)).toBeUndefined()
})

test('a nearly full store is pruned before the listing is written, and long lists are cut', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG, storeLimit: 3000 })
  for (let i = 0; i < 100; i++) e.store.set(`listing:old${i}`, 'x'.repeat(20))
  for (let i = 0; i < 20; i++) e.store.set(`native-agent:old${i}`, { pad: 'y'.repeat(5) })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await listing($)
  expect(e.store.get('listing:session-1')).toBe(`${LIST}${COMMAND}`)
  expect(e.store.has('listing:old0')).toBe(false)
})

test('a long list is cut to a byte budget', async ($, on) => {
    const many = { revision: 5, agents: Array.from({ length: 200 }, (_, i) => ({ ...CATALOG.agents[0], name: `a${i}`, description: 'd'.repeat(100) })) }
  const big = engine([$, on], { catalog: many })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await listing($)
  expect(new TextEncoder().encode(String(big.store.get('listing:session-1')).split(POINTER)[0]).length).toBeLessThan(8001)
})

test('old routes are pruned oldest first, never those of running agents', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG })
  e.store.set(`native-agent:${ID}`, { request: {}, description: 'x', toolUseId: 't', ran: false, cursor: 0 })
  for (let i = 0; i < 250; i++) e.store.set(`native-agent:old${i}`, { request: {} })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await e.launch({ model: 'sol', tool_use_id: 'toolu_new' })
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

test('a session without the Agent tool gets no fallback note and no status', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG, noAgentTool: true })
  await submit($)
  expect(await submit($)).toBeUndefined()
  expect(e.statuses).toEqual([])
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
  await e.launch({ model: 'sol' })
  for (let i = 0; i < 250; i++) e.store.set(`native-agent:old${i}`, { request: {} })
  next = 'b2222222222222222'
  await e.launch({ model: 'sol', tool_use_id: 'toolu_2' })
  expect(e.store.has(`native-agent:${ID}`)).toBe(true)
  expect(e.store.get('added-agents')).toContain(ID)
  expect(e.store.has('native-agent:old0')).toBe(false)
})

test('an added agent whose marker cannot be saved fails visibly instead of running', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG, storeLimit: 60 })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await e.launch({ model: 'sol' })
  expect(report(await step($))).toContain('could not save the native agent’s route')
  expect(e.runCount).toBe(0)
})

test('with a store that refuses writes, grace is used once and the next prompt announces the list', async ($, on) => {
  engine([$, on], { catalog: CATALOG, storeFailure: true })
  expect(await submit($)).toBeUndefined()
  expect((await submit($))?.[0]).toContain(LIST)
})

test('a frozen listing does not advertise agents to an app that lacks agentModels', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG, agentModels: false })
  e.store.set('listing:session-1', LIST)
  expect(await listing($)).toBe(NATIVE_LISTING)
})

test('an added model named as the agent type runs as that model on a general-purpose shell', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await $.agent.offer({ agent: 'Explore', description: 'x', source: 'built-in' } as never)
  await e.launch({ subagent_type: 'sol' })
  expect(e.nativeInputs[0]?.subagent_type).toBe('general-purpose')
  expect(e.nativeInputs[0]?.model).toBeUndefined()
  await e.launch({ subagent_type: 'sol', model: 'sol', tool_use_id: 'toolu_2' })
  const routes = e.calls.filter(c => c.flag === '--agent-route').map(c => c.request)
  expect(routes.map(r => r.agent)).toEqual(['sol', 'sol'])
  expect(routes.map(r => r.subagentType)).toEqual(['general-purpose', 'general-purpose'])
  expect(routes.map(r => r.model)).toEqual([undefined, undefined])
})

test('an added model as the type with a different model is denied, naming the choice', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await $.agent.offer({ agent: 'Explore', description: 'x', source: 'built-in' } as never)
  expect((await e.launch({ subagent_type: 'sol', model: 'opus' })).deny).toBe('sol is a model. Use model: "sol", or model: "opus" with a Claude agent type.')
  expect((await e.launch({ subagent_type: 'sol', model: 'argon' })).deny).toContain('sol is a model')
  expect(e.nativeCalls).toEqual([])
})

test('a custom agent type named like an added model stays native', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await $.agent.offer({ agent: 'sol', description: 'mine', source: 'userSettings' } as never)
  await e.launch({ subagent_type: 'sol' })
  expect(e.calls.filter(c => c.flag === '--agent-route').every(c => c.request.agent === undefined)).toBe(true)
  expect(e.nativeInputs[0]?.subagent_type).toBe('sol')
})

test('after a reload, with no listing seen, the bare type form is denied and model calls are not', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  expect((await e.launch({ subagent_type: 'sol' })).deny).toBe('sol is a model. Use model: "sol".')
  expect((await e.launch({ model: 'sol' })).result).toEqual(NATIVE)
})

test('added-agent ids outlive the routes cap', async ($, on) => {
  let next = ID
  const e = engine([$, on], { catalog: CATALOG, spawnId: () => next })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await e.launch({ model: 'sol' })
  await step($)
  for (let i = 0; i < 250; i++) e.store.set(`native-agent:old${i}`, { request: {} })
  next = 'b2222222222222222'
  await e.launch({ model: 'sol', tool_use_id: 'toolu_2' })
  expect([...e.store.keys()].filter(k => k.startsWith('native-agent:')).length).toBeLessThanOrEqual(200)
  expect(e.store.has(`native-agent:${ID}`)).toBe(false)
  // The in-memory route would still answer here; after a reload only the list tells.
  expect(e.store.get('added-agents')).toContain(ID)
})

test('the header names the models skipped as unavailable', async ($, on) => {
  const outputs: object[] = [{ ...RESULT, model: 'gemini-4-argon-high', unavailable: ['gpt-6.1-sol'] }]
  const e = engine([$, on], { catalog: CATALOG, outputs })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await e.launch({ model: 'sol' })
  expect(report(await step($))).toBe(`Ran on gemini-4-argon-high (gpt-6.1-sol unavailable).\n\n${RESULT.text}`)
  outputs[0] = { ...RESULT, model: 'c', unavailable: ['a', 'b'], worktreePath: '/w/x', worktreeBranch: 'agent-x', declined: ['git push (needed approval)'] }
  await e.launch({ model: 'sol', tool_use_id: 'toolu_2' })
  expect(report(await step($, 'turn-2'))).toBe(`Ran on c (a, b unavailable). Worktree: /w/x (branch agent-x).\nDeclined: git push (needed approval)\n\n${RESULT.text}`)
})

test('a fallback attempt updates the pane row and creates no second one', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG, outputs: [
    { type: 'moved', account: 'Codex', reason: 'usage limit' },
    { type: 'started', agentId: ID, account: 'Antigravity', model: 'gemini-4-argon-high', provider: 'antigravity' },
    { ...RESULT, account: 'Antigravity', model: 'gemini-4-argon-high', provider: 'antigravity', unavailable: ['gpt-6.1-sol'] },
  ] })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await e.launch({ model: 'sol' })
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
  await e.launch({ model: 'sol' })
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

test('delegate_task with no target is tagged with the run and keeps no target', async ($, on) => {
  const e = engine([$, on])
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
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
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

test('delegate_task with a Claude model keeps it on the target and in the tag', async ($, on) => {
  const e = engine([$, on])
  await delegate($, { target: { model: 'claude-opus-5-5', options: [{ id: 'effort', value: 'max' }] } })
  const input = e.nativeInputs.at(-1)!
  expect((input.target as Record<string, unknown>).model).toBe('claude-opus-5-5')
  expect(tagOf(String(input.task))).toMatchObject({ model: 'claude-opus-5-5', effort: 'max' })
})

test('no room leaves a plain delegate_task untouched and denies an added model', async ($, on) => {
  const e = engine([$, on], { route: { type: 'no_room' }, catalog: CATALOG })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
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

test('in T3 Code the listing says delegate_task accepts the added models too', async ($, on) => {
  engine([$, on], { catalog: CATALOG, env: { T3CODE_THREAD_ID: 'thread-1' } })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  expect(await listing($)).toBe(`${NATIVE_LISTING}\n\nThe Agent tool's model parameter and delegate_task's target.model also accept these models the user added. They run through the Agent tool like Claude's own models, so the rule to use delegate_task for another provider's model doesn't apply to them: use Agent, and delegate_task only for background work.\n${LIST}${COMMAND}`)
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
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  const answer = await delegate($, { target: { model: 'sol' } })
  expect(json(answer)).toEqual({ ...SHELL, model: 'sol', runsOn: 'lastdrop · Codex · gpt-6.1-sol · high' })
  expect(answer.context).toBeUndefined()
  expect(e.store.get('delegated-child:task-1')).toBe('sol')
  expect(e.store.get('delegated-child:thread-1')).toBe('sol')
})

// The first try is lastdrop's own T3 instance; T3 refusing it falls back to the call as it always was.
const delegateCalls = (e: ReturnType<typeof engine>) => e.nativeInputs.filter((_, i) => e.nativeCalls[i] === DELEGATE)

test('delegate_task goes first to the lastdrop instance with the tag, the model and no options', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG, lastdrop: 'accept', t3: { [DELEGATE]: SHELL } })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  const answer = await delegate($, { target: { model: 'sol', options: { effort: 'high' } }, mode: 'async' })
  const calls = delegateCalls(e)
  expect(calls.length).toBe(1)
  expect(calls[0]!.target).toEqual({ providerInstanceId: 'lastdrop', model: 'sol' })
  expect(calls[0]!.mode).toBe('async')
  expect(tagOf(String(calls[0]!.task))).toMatchObject({ agent: 'sol', effort: 'high', description: 'review' })
  // T3 names the child's real model: nothing is rewritten or remembered.
  expect(json(answer)).toEqual(SHELL)
  expect(e.store.has('delegated-child:task-1')).toBe(false)
})

test('the tag carries the parent permission mode for the lastdrop instance', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG, lastdrop: 'accept', t3: { [DELEGATE]: SHELL } })
  await $.classic.UserPromptSubmit({ prompt: 'hi', permission_mode: 'bypassPermissions' } as never)
  await delegate($, { target: { model: 'sol' }, mode: 'async' })
  expect(tagOf(String(delegateCalls(e)[0]!.task))).toMatchObject({ agent: 'sol', permissionMode: 'bypassPermissions' })
})

test('a plain or Claude-model child keeps today\'s call: it never tries the lastdrop instance', async ($, on) => {
  const e = engine([$, on], { lastdrop: 'accept' })
  await delegate($)
  await delegate($, { target: { model: 'claude-opus-5-5', driverKind: 'claudeAgent', options: [{ id: 'effort', value: 'max' }] } })
  const [plain, opus, ...more] = delegateCalls(e)
  expect(more.length).toBe(0)
  expect((plain!.target as Record<string, unknown> | undefined)?.providerInstanceId).toBeUndefined()
  expect(opus!.target).toEqual({ model: 'claude-opus-5-5', driverKind: 'claudeAgent', options: [{ id: 'effort', value: 'max' }] })
  expect(tagOf(String(opus!.task))).toMatchObject({ model: 'claude-opus-5-5', effort: 'max' })
})

test('an added model with its own runtime or interaction mode keeps today\'s call', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG, lastdrop: 'accept', t3: { [DELEGATE]: SHELL } })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await delegate($, { target: { model: 'sol' }, runtimeMode: 'approval-required' })
  await delegate($, { target: { model: 'sol' }, interactionMode: 'plan' })
  await delegate($, { target: { model: 'sol' }, runtimeMode: 'inherit', interactionMode: 'inherit' })
  const [runtime, interaction, inherited, ...more] = delegateCalls(e)
  expect(more.length).toBe(0)
  expect((runtime!.target as Record<string, unknown> | undefined)?.providerInstanceId).toBeUndefined()
  expect((interaction!.target as Record<string, unknown> | undefined)?.providerInstanceId).toBeUndefined()
  expect((inherited!.target as Record<string, unknown>).providerInstanceId).toBe('lastdrop')
})

test('a call naming the lastdrop instance itself goes through the same checks and gets the tag', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG, lastdrop: 'accept', t3: { [DELEGATE]: SHELL } })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await delegate($, { target: { providerInstanceId: 'lastdrop', model: 'sol' } })
  await delegate($, { target: { providerInstanceId: 'lastdrop', model: 'opus' } })
  const [added, claude, ...more] = delegateCalls(e)
  expect(more.length).toBe(0)
  expect(added!.target).toEqual({ providerInstanceId: 'lastdrop', model: 'sol' })
  expect(tagOf(String(added!.task)).agent).toBe('sol')
  // A Claude model asked of the instance runs as a plain child on T3's Claude instance, as today.
  expect(claude!.target).toEqual({ model: 'opus' })
  expect(tagOf(String(claude!.task)).model).toBe('opus')
})

const REFUSALS = ['Provider instance lastdrop is not registered.', 'Provider lastdrop cannot run a child task: Provider instance is disabled.',
  'Model sol is not advertised by provider lastdrop.', 'Provider instance "lastdrop" is disabled for project p1.', 'provider_unavailable']

for (const error of REFUSALS) {
  test(`T3 refusing the lastdrop instance (${error.slice(0, 40)}) falls back to today's call, once`, async ($, on) => {
    const e = engine([$, on], { catalog: CATALOG, lastdrop: { error }, t3: { [DELEGATE]: SHELL } })
    await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
    const answer = await delegate($, { target: { model: 'sol', options: { effort: 'high' } } })
    const [first, second, ...more] = delegateCalls(e)
    expect(more.length).toBe(0)
    expect((first!.target as Record<string, unknown>).providerInstanceId).toBe('lastdrop')
    expect(second!.target).toEqual({ options: { effort: 'high' } })
    expect(tagOf(String(second!.task)).agent).toBe('sol')
    expect(tagOf(String(second!.task)).id).toBe(tagOf(String(first!.task)).id)
    // Today's rewrite of the fallback child's answer.
    expect(json(answer)).toEqual({ ...SHELL, model: 'sol', runsOn: 'lastdrop · Codex · gpt-6.1-sol · high' })
    expect(e.store.get('delegated-child:task-1')).toBe('sol')
  })
}

test('an error T3 gives after creating something, or none it explains, is never retried', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG, lastdrop: { error: 'Delegated tasks require an active run owned by this MCP provider session.' } })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  const answer = await delegate($, { target: { model: 'sol' } })
  expect(answer.isError).toBe(true)
  expect(delegateCalls(e).length).toBe(1)
})

test('a refused lastdrop instance is skipped for ten minutes, then tried again', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG, t3: { [DELEGATE]: SHELL } })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await delegate($, { target: { model: 'sol' } })
  expect(delegateCalls(e).length).toBe(2)
  await delegate($, { target: { model: 'sol' } })
  expect(delegateCalls(e).length).toBe(3)
  expect((delegateCalls(e)[2]!.target as Record<string, unknown> | undefined)?.providerInstanceId).toBeUndefined()
  e.store.set('t3-lastdrop:failed', Date.now() - 11 * 60_000)
  await delegate($, { target: { model: 'sol' } })
  expect(delegateCalls(e).length).toBe(5)
})

test('no room never tries the lastdrop instance', async ($, on) => {
  const e = engine([$, on], { route: { type: 'no_room' }, lastdrop: 'accept' })
  await delegate($)
  expect(delegateCalls(e).map(c => c.target)).toEqual([undefined])
})

test('another instance is left to T3 without trying the lastdrop instance', async ($, on) => {
  const e = engine([$, on], { lastdrop: 'accept' })
  await delegate($, { target: { providerInstanceId: 'codex', model: 'gpt-6.1-sol' } })
  expect(delegateCalls(e).length).toBe(1)
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
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
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
