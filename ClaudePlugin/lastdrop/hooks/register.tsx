import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, TurnStepChunk, TurnStepInput, TurnStepResult, TurnUsage } from 'claude-code'

import type { RemoteAgent, TranscriptItem } from '../types'

// Claude Code owns each routed agent's task, transcript row, notifications and lifetime. lastdrop
// answers its `turn.step` with the other account or provider's report, without a local model request.
// A separate `agent.spawn` hook calls the engine, so that hook's nesting never skips our step adapter.
// Forks, teammates, workflow agents, remote agents and calls inside subagents stay built-in on purpose.

/**
 * The Agent tool's arguments as of Claude Code 2.1.310, and the keys `tool.call` adds beside them.
 * `run_in_background` is left out of some sessions' schema; the engine still reads it, and `agent.spawn`'s
 * `background` carries what it decided.
 */
const AGENT_KEYS = new Set([
  'description', 'prompt', 'subagent_type', 'model', 'effort', 'name', 'team_name', 'mode', 'isolation', 'run_in_background',
  'tool', 'tool_use_id', 'consent', 'agentId', 'requestMeta',
])
const ISOLATIONS = new Set([undefined, 'worktree', 'remote'])

const PANE = 'lastdrop-agents'
/** The pane's rows. In memory, not session state: state has a size limit, and a display must never fail an agent. */
let agents: RemoteAgent[] = []
const paneShown = atom({ plugin: 'lastdrop', key: 'paneShown' } as const, false)
/** Agents whose transcript is unfolded, in their row and in the pane. */
const open = atom({ plugin: 'lastdrop', key: 'open' } as const, [] as string[])

/** The session's permission mode, as the last classic hook event reported it. */
let permissionMode: string | undefined

type Line = { type: string; [key: string]: unknown }

/** An agent of lastdrop's list, as `lastdrop --agent-catalog` gives it. */
type Defined = { name: string; description: string; provider: string; summary: string; prompt: string }

/** lastdrop's enabled agents as last read, by name (`codex-deep`), and the list's revision. */
let catalog = new Map<string, Defined>()
let revision: number | undefined
let saveClaude = false

const SAVING_CONTEXT = 'lastdropSaveClaude'
/** The instruction when lastdrop sends none (an older app): lastdrop sends its default, or the user's edit. */
const SAVING_INSTRUCTION = "Claude usage is being saved: delegate substantial work (implementation, exploration, reviews, research) to the models the user added to the Agent tool's model parameter, picking by their descriptions, even where a description says to prefer built-in Claude subagents. Work yourself or with built-in subagents only when no added model fits."
let savingInstruction = SAVING_INSTRUCTION
let nativeTasks: boolean | undefined
/** Whether the app puts agents in the Agent tool's model parameter (an older one doesn't). */
let agentModels = false

/** Claude's own Agent models: any other `model` names an agent of lastdrop's list. */
const NATIVE = new Set(['sonnet', 'opus', 'haiku', 'fable'])
/** The types an added agent runs as; Explore and Plan make it read-only. */
const AGENT_TYPES = new Set([undefined, 'general-purpose', 'claude', 'Explore', 'Plan'])
const ROLES = new Set(['Explore', 'Plan'])
/** The agent types the engine offered the model: a custom one named like an added model wins over it. */
const offered = new Set<string>()

/** The types lastdrop registered before agents became a `model`; a call or a resume naming one is refused. */
const TYPE_PREFIX = 'lastdrop:'

function owns(type: unknown): type is string {
  return typeof type === 'string' && type.startsWith(TYPE_PREFIX)
}

/** The start of Claude's list of agent types, in the attachment that carries it. */
const LISTING = 'Available agent types'

/** The most of the list a session's store entries keep: the store has a size limit. */
const LIST_BYTES = 8_000

/** The agents of lastdrop's list as the model reads them: one line each, what it is for and where it runs. */
function listText(): string {
  if (!agentModels) return ''
  const lines: string[] = []
  let bytes = 0
  for (const [name, agent] of catalog) {
    const line = `- ${name}: ${agent.description.trim()} (${agent.summary})`
    bytes += new TextEncoder().encode(line).length + 1
    if (bytes > LIST_BYTES) break
    lines.push(line)
  }
  return lines.join('\n')
}

/** What the model reads of the list: appended to the native listing, and in a note when it changes. */
const ADDED = "The Agent tool's model parameter also accepts these models the user added:\n"
/** In T3 Code, whose delegate_task runs background children: lastdrop runs those too (see DELEGATE). */
const ADDED_T3 = "The Agent tool's model parameter and delegate_task's target.model also accept these models the user added. They run through the Agent tool like Claude's own models, so the rule to use delegate_task for another provider's model doesn't apply to them: use Agent, and delegate_task only for background work.\n"
const CHANGED = "The models the user added to the Agent tool's model parameter changed. It now accepts:\n"
const REMOVED = "The models the user added to the Agent tool's model parameter were removed."
/** Ends the frozen listing, so the command's instructions cost nothing until they're read. */
const POINTER = '\nOnly if the user asks to change these, run '

/** Sessions whose first-prompt grace was used, for when the store refuses to keep it. */
const graced = new Set<string>()
const KEPT_SESSIONS = 100
const KEPT_ROUTES = 200

/**
 * Keeps the latest entries under `prefix` (oldest go first, except `keep`'s ids): the store has a size limit
 * and sessions and agents never end.
 */
async function prune($: EngineInterface, prefix: string, limit: number, keep: ReadonlySet<string> = new Set()): Promise<void> {
  const keys = (await $.store.keys()).filter(key => key.startsWith(prefix))
  let extra = keys.length - limit
  for (const key of keys) {
    if (extra <= 0) break
    if (keep.has(key.slice(prefix.length))) continue
    await $.store.delete(key)
    extra--
  }
}

/** Agents with a remote turn in progress. */
const active = new Set<string>()

/**
 * Ids whose routes are never pruned: a turn in progress, an agent not yet run (its spawn is still being
 * saved), or one the pane shows running. The pane keeps only 50 agents, so it can't be the only source.
 */
async function running($: EngineInterface): Promise<Set<string>> {
  const ids = new Set(active)
  for (const [id, route] of routes) if (!route.ran) ids.add(id)
  for (const agent of agents) if (agent.status === 'running') ids.add(agent.id)
  return ids
}

/**
 * Stores a value, pruning first and once more if the store still refuses it. A full store must not break
 * a prompt or an attachment: false means it wasn't kept.
 */
async function put($: EngineInterface, key: string, value: unknown): Promise<boolean> {
  const colon = key.indexOf(':') + 1
  const prefix = key.slice(0, colon)
  const limit = prefix === 'listing:' || prefix === 'announced:' || prefix === 'grace:' ? KEPT_SESSIONS : KEPT_ROUTES
  try {
    await prune($, prefix, limit - 1, await running($))
    await $.store.set(key, value)
    return true
  } catch {
    try {
      await prune($, prefix, Math.floor(limit / 2), await running($))
      await $.store.set(key, value)
      return true
    } catch (error) {
      $.ui.log(`lastdrop: its store refused ${prefix}: ${String(error)}`, { to: 'debug' })
      return false
    }
  }
}

/**
 * The ids of added-agent runs, one list apart from the routes' cap: a resume of one whose route was pruned
 * must be refused, never run as Claude. The latest 5000 are kept (about 100 KB of the store's 4 MiB), so a
 * resume of an agent older than that many added-agent runs is the one case that is not caught.
 */
const ADDED_AGENTS = 'added-agents'
const KEPT_ADDED = 5000

async function wasAdded($: EngineInterface, id: string): Promise<boolean> {
  const list = await $.store.get(ADDED_AGENTS)
  // Markers of earlier versions were a key apiece.
  return (Array.isArray(list) && list.includes(id)) || (await $.store.get(`added-agent:${id}`)) === true
}

async function markAdded($: EngineInterface, id: string): Promise<boolean> {
  try {
    const list = await $.store.get(ADDED_AGENTS)
    const ids = Array.isArray(list) ? list.filter(known => known !== id) : []
    await $.store.set(ADDED_AGENTS, [...ids, id].slice(-KEPT_ADDED))
    return true
  } catch (error) {
    $.ui.log(`lastdrop: its store refused the added-agent list: ${String(error)}`, { to: 'debug' })
    return false
  }
}

/** A session's listing starts again, from the list as it reads now. */
async function resetListing($: EngineInterface): Promise<void> {
  const id = await $.session.id()
  graced.delete(id)
  for (const prefix of ['listing:', 'announced:', 'grace:']) await $.store.delete(`${prefix}${id}`)
}

/**
 * Reads lastdrop's list: its enabled agents, by name, from the next turn on. A change reaches the model
 * through `prompt.submit`'s note, since the listing it already read stays as it was.
 */
async function syncCatalog($: EngineInterface): Promise<void> {
  let text = ''
  for await (const chunk of $.process.spawn({ argv: [await runner($), '--agent-catalog'] })) {
    if (chunk.stream === 'stdout') text += chunk.text
  }
  const parsed = JSON.parse(text.trim() || '{}') as {
    revision?: number; agents?: Defined[]; saveClaude?: boolean; saveClaudeText?: string; nativeTasks?: boolean; agentModels?: boolean
  }
  nativeTasks = parsed.nativeTasks === true
  agentModels = parsed.agentModels === true
  if (parsed.revision !== undefined && parsed.revision === revision) return
  catalog = new Map((parsed.agents ?? []).map(agent => [agent.name, agent] as const))
  revision = parsed.revision
  saveClaude = parsed.saveClaude === true
  savingInstruction = parsed.saveClaudeText?.trim() || SAVING_INSTRUCTION
}

/**
 * What the model should be told about the list now, if it differs from what it last read (the frozen
 * listing's, or the last note's). Without a frozen listing the native format probably changed: tell it all.
 */
async function listNote($: EngineInterface): Promise<string | undefined> {
  const id = await $.session.id()
  const list = listText()
  const frozen = await $.store.get(`listing:${id}`)
  const announced = await $.store.get(`announced:${id}`)
  const known = typeof announced === 'string' ? announced : typeof frozen === 'string' ? frozen.split(POINTER)[0] : undefined
  if (known === undefined) {
    // The first prompt of a session, or the first after a compaction, comes before the listing is built.
    if (!graced.has(id) && (await $.store.get(`grace:${id}`)) !== true) {
      graced.add(id)
      await put($, `grace:${id}`, true)
      return undefined
    }
    if (list === '' || !(await $.tool.list()).some(tool => tool.name === 'Agent')) return undefined
    if (!listingBroken) {
      listingBroken = true
      broken = "lastdrop: Claude Code's agent list changed; added agents are announced in a note instead"
      $.ui.log(broken, { to: 'debug' })
      await showStatus($)
    }
  } else if (known === list) {
    return undefined
  }
  await put($, `announced:${id}`, list)
  return list === '' ? REMOVED : `${CHANGED}${list}`
}

type Request = Record<string, unknown>
type Route = { request: Request; description: string; toolUseId: string; ran: boolean; cursor: number; handback?: boolean; resumePrompt?: string; error?: string }
const claims = new Map<string, Request>()
const routes = new Map<string, Route>()
/** A native step can arrive before its spawn's reply has crossed the worker boundary. */
const spawning = new Set<Promise<void>>()

/** lastdrop's own binary: beside this plugin inside lastdrop.app, else the usual install. */
async function runner($: EngineInterface): Promise<string> {
  const bundled = `${$.plugin.root}/../../../MacOS/lastdrop`
  return (await $.fs.exists(bundled)) ? bundled : '/Applications/lastdrop.app/Contents/MacOS/lastdrop'
}

type Chunk = { stream: string; text: string }

/** A `lastdrop --agent-run` process, read as JSON lines. Ending its stream ends the process. */
class Run {
  private buffer = ''
  constructor(private readonly stream: AsyncIterator<Chunk, unknown>) {}

  /** Its next line, or null once it ended. */
  async next(): Promise<Line | null> {
    for (;;) {
      const newline = this.buffer.indexOf('\n')
      if (newline >= 0) {
        const text = this.buffer.slice(0, newline)
        this.buffer = this.buffer.slice(newline + 1)
        try {
          return JSON.parse(text) as Line
        } catch {
          continue
        }
      }
      const chunk = await this.stream.next()
      if (chunk.done) return null
      if (chunk.value.stream === 'stdout') this.buffer += chunk.value.text
    }
  }

  stop(): void {
    void this.stream.return?.()
  }
}

type Begun = { run: Run; line: Line; early: Line[] } | { noRoom: true } | { native: true } | { error: string }

/**
 * Starts `lastdrop --agent-run` and reads it until the agent started: the run, its `started` line and the `moved`/`step` lines before it,
 * `noRoom` when no account has room, `native` when lastdrop leaves the run to the built-in agent, else the
 * error that kept it from starting.
 */
async function start($: EngineInterface, request: Record<string, unknown>): Promise<Begun> {
  try {
    const stream = $.process.spawn({ argv: [await runner($), '--agent-run'], input: JSON.stringify(request) })
    const run = new Run(stream[Symbol.asyncIterator]())
    const early: Line[] = []
    for (let line = await run.next(); line; line = await run.next()) {
      if (line.type === 'moved' || line.type === 'step') early.push(line)
      if (line.type === 'no_room') return { noRoom: true }
      if (line.type === 'native') return { native: true }
      if (line.type === 'started') return { run, line, early }
      if (line.type === 'error' || line.type === 'result') return { error: String(line.text ?? 'lastdrop could not start the agent.') }
    }
    return { error: 'lastdrop’s runner ended before the agent started.' }
  } catch (error) {
    return { error: `lastdrop’s runner failed: ${String(error)}` }
  }
}

/**
 * A prompt was sent, so an Agent call may follow: lastdrop starts Claude Code on the account it would
 * pick, so the agent finds it ready instead of waiting for it to start. Nothing happens when one is ready.
 */
async function warmUp($: EngineInterface): Promise<void> {
  const request = { prompt: '', cwd: await $.session.cwd(), permissionMode, parentModel: await $.session.model() }
  for await (const _ of $.process.spawn({ argv: [await runner($), '--agent-warm'], input: JSON.stringify(request) })) {
    // Nothing to read; it ends once the app has the request.
  }
}

/** Plain reroutes whose pane waits for their first sign of work: a fallback to the built-in agent shows none. */
const quiet = new Set<string>()

async function showPane($: EngineInterface): Promise<void> {
  if (await read($, paneShown)) return
  await update($, paneShown, () => true)
  void $.ui.open({ id: PANE, title: 'Agents on other accounts' })
}

async function started($: EngineInterface, line: Line, description: string, resumed: boolean,
                       toolUseId?: string, lazyPane = false): Promise<void> {
  const id = String(line.agentId)
  if (agents.some(a => a.id === id)) {
    agents = agents.map(a => (a.id === id ? { ...a, status: 'running' as const, endedAt: undefined } : a))
  } else {
    const agent: RemoteAgent = {
      id, description, account: String(line.account), model: String(line.model ?? ''),
      provider: line.provider === undefined ? undefined : String(line.provider),
      status: 'running', steps: [], items: [], startedAt: Date.now(), toolUseId,
    }
    agents = [...agents, agent].slice(-50)
  }
  $.ui.invalidate('ui.render')
  if (lazyPane) quiet.add(id)
  else if (!resumed) await showPane($)
  await showStatus($)
}

/** Records a line of an agent's run in its row. */
async function record($: EngineInterface, id: string, line: Line): Promise<void> {
  if (quiet.has(id) && (line.type === 'step' || line.type === 'item' || line.type === 'result')) {
    quiet.delete(id)
    await showPane($)
  }
  if (line.type === 'started') {
    // A later attempt of the same run (a fallback): the row stays, and shows what really runs now.
    agents = agents.map(a => (a.id === id
      ? { ...a, account: String(line.account ?? a.account), model: String(line.model ?? a.model),
          provider: line.provider === undefined ? a.provider : String(line.provider) }
      : a))
    $.ui.invalidate('ui.render')
    return
  }
  if (line.type === 'step' || line.type === 'moved') {
    const text = line.type === 'moved' ? `Moved off ${line.account}: ${line.reason}` : String(line.text)
    agents = agents.map(a => (a.id === id ? { ...a, steps: [...a.steps, text].slice(-40) } : a))
    $.ui.invalidate('ui.render')
    return
  }
  if (line.type === 'item') {
    const { type: _, ...item } = line
    agents = agents.map(a => (a.id === id ? { ...a, items: [...a.items, item as unknown as TranscriptItem].slice(-300) } : a))
    $.ui.invalidate('ui.render')
    return
  }
  if (line.type !== 'result') return
  const failed = line.isError === true
  const stopped = line.stopped === true
  agents = agents.map(a => (a.id === id
    ? { ...a, status: stopped ? 'stopped' : failed ? 'failed' : 'done', endedAt: Date.now(),
        account: String(line.account ?? a.account), model: String(line.model ?? a.model),
        provider: line.provider === undefined ? a.provider : String(line.provider) }
    : a))
  $.ui.invalidate('ui.render')
  await showStatus($)
}

/** Admission happens before native spawn; it never starts a remote model or claims a warm process. */
async function admission($: EngineInterface, request: Request): Promise<'routed' | 'no_room'> {
  if (nativeTasks === undefined) await syncCatalog($)
  if (!nativeTasks) throw new Error('Update the lastdrop app and plugin together: this app does not support native routed tasks.')
  const stream = $.process.spawn({ argv: [await runner($), '--agent-route'], input: JSON.stringify(request) })
  const run = new Run(stream[Symbol.asyncIterator]())
  try {
    const line = await run.next()
    if (line?.type === 'routed' || line?.type === 'no_room') return line.type
    throw new Error(String(line?.text ?? 'lastdrop’s routing check ended without an answer.'))
  } finally {
    run.stop()
  }
}

async function stopRemote($: EngineInterface, id: string): Promise<void> {
  const result = await $.process.run([await runner($), '--agent-stop', id])
  if (result.exitCode !== 0) $.ui.log(`lastdrop: stop ${id}: ${result.stdout || result.stderr}`, { to: 'debug' })
}

/** New native inbox messages since the preceding remote run, without the engine's context reminders. */
async function inbox($: EngineInterface, id: string, route: Route): Promise<string> {
  const messages = await $.session.messages({ agentId: id, as: 'api' })
  if (!Array.isArray(messages)) throw new Error(messages.deny)
  // $.tool.list() lists the main loop's tools. The native request itself carries this instruction in auto mode.
  route.handback = messages.some(m => m.role === 'user' && m.content.some(b => b.type === 'text'
    && typeof b.text === 'string' && b.text.startsWith('<system-reminder>\nYour final report is delivered through SubagentHandback:')))
  if (messages.length < route.cursor) throw new Error('The native agent’s transcript was compacted before lastdrop read its messages.')
  const text: string[] = []
  for (const message of messages.slice(route.cursor)) {
    if (message.role !== 'user') continue
    const blocks = message.content.filter(b => b.type === 'text' && typeof b.text === 'string').map(b => String(b.text))
    // A resumed turn can contain the coordinator's reminder and the same message as its own text block.
    const plain = blocks.filter(t => !t.startsWith('<system-reminder>') && !t.startsWith('The coordinator sent a message while you were working:\n'))
    for (const block of blocks) {
      const prefix = 'The coordinator sent a message while you were working:\n'
      const suffix = '\n\nAddress this before completing your current task.\n'
      if (!block.startsWith(prefix)) continue
      if (!block.endsWith(suffix)) throw new Error('Claude Code changed the native inbox message format.')
      const message = block.slice(prefix.length, -suffix.length)
      if (!plain.includes(message)) plain.push(message)
    }
    text.push(...plain)
    if (message.content.some(b => b.type !== 'text' && b.type !== 'tool_result')) {
      throw new Error('lastdrop cannot forward a non-text message to the remote agent.')
    }
  }
  route.cursor = messages.length
  return text.join('\n\n')
}

/**
 * Auto-mode native agents require handback; other modes deliver plain text at end_turn. `block` is the
 * first free content block: 1 after the live progress took block 0.
 */
function* respond(e: TurnStepInput, text: string, usage: TurnUsage | null, handback: boolean, block = 0): Generator<TurnStepChunk, TurnStepResult> {
  if (handback && e.index === 0) {
    yield { kind: 'tool', index: block, id: `lastdrop_${e.turnId}_${e.index}`, name: 'SubagentHandback' }
    yield { kind: 'input', index: block, json: JSON.stringify({ message: text }) }
    yield { kind: 'stop', stopReason: 'tool_use', usage }
    return { turnId: e.turnId, index: e.index, answer: '',
             toolUses: [{ name: 'SubagentHandback', input: { message: text } }], stopReason: 'tool_use', usage }
  }
  yield { kind: 'text', index: block, text }
  yield { kind: 'stop', stopReason: 'end_turn', usage }
  return { turnId: e.turnId, index: e.index, answer: text, toolUses: [], stopReason: 'end_turn', usage }
}

/** How long a run may go without a visible update before a "still working" line; Claude Code stops a subagent silent for 600 s. */
const QUIET_MS = 240_000

/**
 * Turns a run's lines into what its native turn shows live: each step as it happens and, through the
 * runner's minute ticks, a "still working" line when a long step leaves it quiet. Claude Code's watchdog
 * stops a subagent whose stream shows nothing for ten minutes, and treats these updates as progress.
 * `held` keeps a plain reroute quiet until its first step: before any work it may still go to the
 * built-in agent, whose own response must start the turn.
 */
function progress(report: (text: string) => void, held: boolean): (line: Line) => void {
  let last = Date.now()
  let current = ''
  let open = !held
  return line => {
    const now = Date.now()
    if (line.type === 'step') {
      open = true
      current = String(line.text ?? '')
    } else if (line.type === 'moved') {
      if (!open) return
      current = `Moved off ${String(line.account)}: ${String(line.reason)}`
    } else if (line.type === 'tick' && open && now - last >= QUIET_MS) {
      const minutes = Math.round((now - last) / 60_000)
      report(`Still working${current ? ` on ${current}` : ''} (${minutes} min without a new step)\n\n`)
      last = now
      return
    } else {
      return
    }
    last = now
    if (current) report(`${current}\n\n`)
  }
}

/**
 * Runs `work` and yields each update it reports while it runs, as thinking in block 0, which is shown live
 * and never recorded; the generator's value is the work's. `shown` says whether block 0 was used.
 */
async function* live<T>(work: (report: (text: string) => void) => Promise<T>, shown: { value: boolean }): AsyncGenerator<TurnStepChunk, T> {
  const queue: string[] = []
  let wake: (() => void) | undefined
  let settled = false
  const done = work(text => { queue.push(text); wake?.() })
  void done.then(() => { settled = true; wake?.() }, () => { settled = true; wake?.() })
  for (;;) {
    while (queue.length > 0) {
      shown.value = true
      yield { kind: 'thinking', index: 0, text: queue.shift()! }
    }
    if (settled) return await done
    await new Promise<void>(resolve => { wake = resolve })
    wake = undefined
  }
}

/**
 * An added agent's spawn with its name as the subagent's model. Claude Code stamps each of the subagent's
 * messages with its step model, and hosts (T3 Code) label the subagent by it; lastdrop answers every step,
 * so the name only labels and never reaches a model. `tool.call` can't pass it: the Agent tool's schema
 * allows Claude's models only, while `agent.spawn` takes any id. A resumed agent keeps it; the engine
 * refuses a hook's model on a resume.
 */
function labelled<E extends { model?: string }>(e: E, agent: unknown): E {
  return typeof agent === 'string' && agent !== '' ? { ...e, model: agent } : e
}

/** Where an added agent ran and what it could not do, for the report's first lines; a reroute gets only its worktree. */
function header(request: Request, line: Line): string {
  const where = line.worktreePath ? `Worktree: ${String(line.worktreePath)}${line.worktreeBranch ? ` (branch ${String(line.worktreeBranch)})` : ''}.` : ''
  if (request.agent === undefined) return where ? `${where}\n\n` : ''
  if (!line.model) return ''
  const worktree = where ? ` ${where}` : ''
  const declined = Array.isArray(line.declined) && line.declined.length > 0 ? `\nDeclined: ${line.declined.join('; ')}` : ''
  const skipped = Array.isArray(line.unavailable) && line.unavailable.length > 0 ? ` (${line.unavailable.join(', ')} unavailable)` : ''
  return `Ran on ${String(line.model)}${skipped}.${worktree}${declined}\n\n`
}

function usageOf(line: Line, model: string): TurnUsage {
  const cached = Number(line.cacheReadInputTokens ?? 0)
  const created = Number(line.cacheCreationInputTokens ?? 0)
  return { model: String(line.model ?? model), input_tokens: Math.max(0, Number(line.inputTokens ?? 0) - cached - created),
           output_tokens: Number(line.outputTokens ?? 0), cache_read_input_tokens: cached, cache_creation_input_tokens: created }
}

/** One remote run per native turn; the engine schedules new turns for messages queued while it worked. */
async function remoteTurn($: EngineInterface, e: TurnStepInput, route: Route, signal: AbortSignal,
                          report: (text: string) => void = () => {}): Promise<Line> {
  const id = e.agentId!
  if (route.error) throw new Error(route.error)
  if (e.index !== 0) throw new Error('Claude Code requested another model step after lastdrop’s handback.')
  const previous = route.cursor
  const message = await inbox($, id, route)
  const nextPrompt = route.resumePrompt || message
  route.resumePrompt = undefined
  const prompt = route.ran ? nextPrompt : [String(route.request.prompt), previous > 0 ? nextPrompt : ''].filter(Boolean).join('\n\n')
  if (route.ran && !prompt) throw new Error('The native agent resumed without a new text message.')
  await put($, `native-agent:${id}`, route)
  let run: Run | undefined
  const stop = () => {
    void stopRemote($, id).catch(error => $.ui.log(`lastdrop: stop ${id} failed: ${String(error)}`, { to: 'debug' }))
  }
  signal.addEventListener('abort', stop, { once: true })
  try {
    if (signal.aborted) throw new Error('Stopped by Claude Code.')
    const request = { ...route.request, prompt, id, resume: route.ran ? id : undefined }
    const begun = await start($, request)
    // Nothing ran yet, so the built-in agent can take a plain reroute; an added model never runs on Claude.
    const plain = route.request.agent === undefined && !route.ran
    if ('native' in begun || ('noRoom' in begun && plain)) {
      if (!plain) throw new Error('lastdrop’s runner handed the agent to the built-in agent after it had run.')
      return { type: 'native' }
    }
    if ('noRoom' in begun) throw new Error('No other account has room after the native agent started. lastdrop did not run it on the session’s account.')
    if ('error' in begun) throw new Error(begun.error)
    run = begun.run
    if (String(begun.line.agentId) !== id) throw new Error('lastdrop’s runner did not keep the native agent id. Update the lastdrop app and plugin together.')
    await started($, begun.line, route.description, route.ran, route.toolUseId, plain)
    const show = progress(report, plain)
    // Switches made before the agent started (a fallback taken at once) still show in its row.
    for (const line of begun.early) { await record($, id, line); show(line) }
    route.ran = true
    route.request.prompt = ''
    await put($, `native-agent:${id}`, route)
    let result: Line | undefined
    for (let line = await run.next(); line; line = await run.next()) {
      show(line)
      if (line.type === 'native') {
        // Only a run that has done no work can be handed over.
        if (!plain) throw new Error('lastdrop’s runner handed the agent to the built-in agent after it had run.')
        result = line
        break
      }
      await record($, id, line)
      if (line.type === 'result' || line.type === 'error') { result = line; break }
    }
    run.stop()
    run = undefined
    if (!result) throw new Error('lastdrop’s runner ended without the agent’s report.')
    if (result.type === 'native') return result
    if (result.isError === true || result.type === 'error') throw new Error(String(result.text ?? 'The remote agent failed.'))
    await inbox($, id, route)
    await put($, `native-agent:${id}`, route)
    return result
  } finally {
    signal.removeEventListener('abort', stop)
    run?.stop()
    if (signal.aborted) {
      await record($, id, { type: 'result', stopped: true, text: 'Stopped', isError: true })
    }
  }
}

/** What the self-test found broken on this Claude Code version, shown until a run passes. */
let broken: string | undefined
let listingBroken = false

/**
 * Checks, once per Claude Code version, that subagents on other accounts still work (`lastdrop
 * --agent-selftest`); what broke stays in the status line and the debug log.
 */
async function selfTest($: EngineInterface): Promise<void> {
  let line: Line | undefined
  for await (const chunk of $.process.spawn({ argv: [await runner($), '--agent-selftest'] })) {
    if (chunk.stream === 'stdout' && chunk.text.trim()) line = JSON.parse(chunk.text.trim().split('\n')[0] ?? '{}') as Line
  }
  if (line?.type === 'failed') {
    broken = `lastdrop: subagents on other accounts are broken on Claude Code ${String(line.version)} (${String(line.step)}: ${String(line.text)})`
    $.ui.log(broken, { to: 'debug' })
    $.ui.toast(broken, { timeoutMs: 15_000 })
  } else if (line?.type === 'ok') {
    broken = undefined
  }
  await showStatus($)
}

async function showStatus($: EngineInterface): Promise<void> {
  const running = agents.filter(a => a.status === 'running')
  const where = [...new Set(running.map(a => a.account))].join(', ')
  const text = [running.length > 0 ? `${running.length} agent${running.length === 1 ? '' : 's'} on ${where}` : undefined, broken]
    .filter(Boolean).join(' · ')
  $.ui.status(text || undefined)
}

function elapsed(agent: RemoteAgent, now: number): string {
  const s = Math.round(((agent.endedAt ?? now) - agent.startedAt) / 1000)
  return s < 60 ? `${s}s` : `${Math.floor(s / 60)}m ${s % 60}s`
}

function plural(n: number, word: string): string {
  return `${n} ${word}${n === 1 ? '' : 's'}`
}

/** Terminal on the agent's own Claude Code session, on its account. */
async function openInTerminal($: EngineInterface, id: string): Promise<void> {
  for await (const _ of $.process.spawn({ argv: [await runner($), '--agent-open', id] })) {
    // Nothing to read.
  }
}

/**
 * An agent as its row reads, like a built-in agent's: what it is and where it runs, its latest steps, and
 * on demand its whole transcript (what it said, each tool call and result, its answer).
 */
function agentBlock($: EngineInterface, e: Parameters<EngineInterface['ui']['resolve']>[0], agent: RemoteAgent,
                    unfolded: boolean): JSX.Element {
  const { Box, Text, Button, Markdown } = $.ui.resolve(e)
  const tools = agent.items.filter(i => i.kind === 'tool').length || agent.steps.length
  const state = { running: 'Running', done: 'Done', failed: 'Failed', stopped: 'Stopped' }[agent.status]
  const toggle = () => update($, open, list => (list.includes(agent.id) ? list.filter(i => i !== agent.id) : [...list, agent.id]))
  return (
    <Box flexDirection="column">
      <Text>
        <Text bold>{{ running: '● ', done: '✓ ', failed: '✗ ', stopped: '■ ' }[agent.status]}Agent · {agent.description}</Text>
        <Text dimColor>  on {agent.account || 'another account'}{agent.model ? ` · ${agent.model}` : ''}</Text>
      </Text>
      <Text dimColor>  {state} {elapsed(agent, Date.now())} · {plural(tools, 'tool use')}</Text>
      {!unfolded && (agent.status === 'running' ? agent.steps.slice(-3) : agent.steps.slice(-1)).map(step => (
        <Text dimColor>  ⎿ {step}</Text>
      ))}
      {unfolded && (
        <Box flexDirection="column" marginLeft={2} marginTop={1}>
          {agent.items.length === 0 && <Text dimColor>Nothing yet.</Text>}
          {agent.items.map(item =>
            item.kind === 'text' ? <Markdown text={item.text} />
            : item.kind === 'tool' ? <Text>→ {item.summary}</Text>
            : <Text dimColor={!item.isError} color={item.isError ? 'red' : undefined}>
                {'  ⎿ '}{item.text.split('\n').slice(0, 6).join('\n    ')}{item.text.split('\n').length > 6 ? '\n    …' : ''}
              </Text>,
          )}
        </Box>
      )}
      <Box flexDirection="row" gap={1} marginTop={unfolded ? 1 : 0}>
        <Button key={`transcript-${agent.id}`} dimColor onPress={toggle}>{unfolded ? 'Hide transcript' : 'Show transcript'}</Button>
        <Button key={`terminal-${agent.id}`} dimColor onPress={() => openInTerminal($, agent.id)}>Open in Terminal</Button>
      </Box>
    </Box>
  )
}

/**
 * T3 Code's tool for a child thread, the way to run background work there: T3 replaces a thread's Claude
 * Code process (a model change, Stop), which ends its native background agents. The child is an ordinary
 * T3 Claude thread; lastdrop's plugin inside it answers its turns with `lastdrop --agent-run`, as for an
 * Agent subagent, so the child's own model never runs on the session's account. The tag at the end of the
 * task carries the run; when lastdrop hands the run back (no room), the child's model reads the task.
 */
const DELEGATE = 'mcp__t3-code__delegate_task'
const TAG = '<!-- lastdrop '
const TAG_END = ' -->'
/** T3's built-in Claude instance; another instance may be another provider, which lastdrop leaves alone. */
const T3_CLAUDE = 'claudeAgent'

const CAPABILITIES = 'mcp__t3-code__orchestrator_capabilities'
const T3_TOOLS = /^mcp__t3-code__/

/** Where a delegated child's report came from: T3 shows only the child thread's own instance and model. */
function delegatedHeader(line: Line): string {
  const where = line.worktreePath ? ` Worktree: ${String(line.worktreePath)}${line.worktreeBranch ? ` (branch ${String(line.worktreeBranch)})` : ''}.` : ''
  const declined = Array.isArray(line.declined) && line.declined.length > 0 ? `\nDeclined: ${line.declined.join('; ')}` : ''
  const skipped = Array.isArray(line.unavailable) && line.unavailable.length > 0 ? `, ${line.unavailable.join(', ')} unavailable` : ''
  if (!line.account) return where ? `${where.trim()}\n\n` : ''
  return `Ran on ${String(line.account)}${line.model ? ` (${String(line.model)}${skipped})` : ''}.${where}${declined}\n\n`
}

/** Where an added model runs, as T3's answers show it in place of the child thread's own model. */
function runsOn(agent: string): string {
  return `lastdrop · ${catalog.get(agent)?.summary ?? 'its own provider'}`
}

/**
 * T3's answers name a child by the instance and model of its thread, which never run for an added model.
 * This rewrites, in the JSON the model reads, each of our children's `model` to the added model and adds
 * `runsOn`; `children` maps a task's or thread's id to its added model. Another answer is left as it is.
 */
function rewriteChildren(value: unknown, children: ReadonlyMap<string, string>, agent?: string): unknown {
  if (Array.isArray(value)) return value.map(v => rewriteChildren(v, children, agent))
  if (value === null || typeof value !== 'object') return value
  const record = value as Record<string, unknown>
  const thread = record.thread as Record<string, unknown> | undefined
  const ids = [record.taskId, record.childThreadId, record.threadId, thread?.threadId]
  const own = agent ?? ids.map(id => (typeof id === 'string' ? children.get(id) : undefined)).find(Boolean)
  const out: Record<string, unknown> = {}
  for (const [key, field] of Object.entries(record)) {
    out[key] = key === 'model' && own !== undefined ? own : rewriteChildren(field, children, own)
    if (key === 'model' && own !== undefined) out.runsOn = runsOn(own)
  }
  return out
}

/** The ids of tasks and threads a JSON answer names, to look up which are ours. */
function idsIn(value: unknown, found = new Set<string>()): Set<string> {
  if (Array.isArray(value)) for (const v of value) idsIn(v, found)
  else if (value !== null && typeof value === 'object') {
    for (const [key, field] of Object.entries(value)) {
      if ((key === 'taskId' || key === 'childThreadId' || key === 'threadId') && typeof field === 'string') found.add(field)
      else idsIn(field, found)
    }
  }
  return found
}

/** The texts of a T3 tool's answer: Claude Code gives an MCP tool's text as one string, or as text blocks. */
function textsOf(answer: { result?: unknown }): string[] {
  if (typeof answer.result === 'string') return [answer.result]
  if (!Array.isArray(answer.result)) return []
  return answer.result.flatMap(b => (b?.type === 'text' && typeof b.text === 'string' ? [b.text as string] : []))
}

/** The JSON values of a T3 tool's answer. */
function jsonOf(answer: { result?: unknown }): unknown[] {
  return textsOf(answer).flatMap(text => {
    try {
      return [JSON.parse(text) as unknown]
    } catch {
      return []
    }
  })
}

/** A T3 tool's answer with its JSON texts passed through `edit`; text that isn't JSON stays. */
function editAnswer<T extends { result?: unknown; text?: unknown }>(answer: T, edit: (json: unknown) => unknown): T {
  const change = (text: string) => {
    try {
      return JSON.stringify(edit(JSON.parse(text)))
    } catch {
      return text
    }
  }
  const result = typeof answer.result === 'string' ? change(answer.result)
    : Array.isArray(answer.result)
      ? answer.result.map(b => (b?.type === 'text' && typeof b.text === 'string' ? { ...b, text: change(b.text) } : b))
      : answer.result
  return { ...answer, result, ...(typeof answer.text === 'string' ? { text: change(answer.text) } : {}) }
}

/** A T3 tool's answer with our children's model, and the added models, shown as they run. */
async function rewriteT3<T extends { result?: unknown; text?: unknown }>($: EngineInterface, tool: string, answer: T): Promise<T> {
  if (tool === CAPABILITIES) {
    if (!agentModels || catalog.size === 0) return answer
    const added = [...catalog.keys()].map(model => ({ model, runsOn: runsOn(model) }))
    return editAnswer(answer, json => (json !== null && typeof json === 'object' && !Array.isArray(json) ? { ...json, addedModels: added } : json))
  }
  const children = new Map<string, string>()
  for (const id of idsIn(jsonOf(answer))) {
    const agent = await $.store.get(`delegated-child:${id}`)
    if (typeof agent === 'string') children.set(id, agent)
  }
  return children.size === 0 ? answer : editAnswer(answer, json => rewriteChildren(json, children))
}

/** A delegated child's run, as its tag carries it. */
type Delegated = { id: string; agent?: string; model?: string; effort?: string; description?: string }
/** What the child's turns did so far: `cursor` is where its next turn's new messages start. */
type DelegatedState = { ran: boolean; native: boolean; cursor: number }

function tag(task: string, run: Delegated): string {
  return `${task}\n\n${TAG}${JSON.stringify(run)}${TAG_END}`
}

function untag(text: string): { task: string; run: Delegated } | undefined {
  const trimmed = text.trimEnd()
  const start = trimmed.lastIndexOf(`\n\n${TAG}`)
  if (start < 0 || !trimmed.endsWith(TAG_END)) return undefined
  try {
    const run = JSON.parse(trimmed.slice(start + 2 + TAG.length, -TAG_END.length)) as Delegated
    return typeof run?.id === 'string' ? { task: trimmed.slice(0, start), run } : undefined
  } catch {
    return undefined
  }
}

type ApiMessage = { role: string; content: { type: string; text?: unknown }[] }

/** A user message's own text, without the engine's reminders. */
function userText(message: ApiMessage): string {
  return message.content.filter(b => b.type === 'text' && typeof b.text === 'string' && !b.text.startsWith('<system-reminder>'))
    .map(b => String(b.text)).join('\n\n')
}

/** `effort` from delegate_task's options, given as a list or an object. */
function effortOf(options: unknown): string | undefined {
  const value = Array.isArray(options) ? options.find(o => o?.id === 'effort')?.value : (options as Record<string, unknown> | undefined)?.effort
  return typeof value === 'string' ? value : undefined
}

/**
 * A main-session step of a delegated child: lastdrop's runner answers it, or undefined when this session
 * isn't one or lastdrop handed the run back (the engine's model then runs).
 */
async function delegatedChild($: EngineInterface) {
  const messages = await $.session.messages({ as: 'api' })
  if (!Array.isArray(messages)) return undefined
  const first = messages.findIndex(m => m.role === 'user')
  const found = first < 0 ? undefined : untag(userText(messages[first] as ApiMessage))
  if (!found) return undefined
  const key = `delegated:${found.run.id}`
  // Without its state (the store refused it, or pruned it), lastdrop's earlier answers say how far the run got.
  const answered = messages.map(m => m.role).lastIndexOf('assistant')
  const state = (await $.store.get(key) as DelegatedState | undefined)
    ?? { ran: answered >= 0, native: false, cursor: answered >= 0 ? answered + 1 : first + 1 }
  return { ...found, messages, key, state }
}

async function delegatedTurn($: EngineInterface, e: TurnStepInput, signal: AbortSignal,
                             report: (text: string) => void = () => {}): Promise<Line | undefined> {
  const child = await delegatedChild($)
  if (!child) return undefined
  const { run, task, messages, key, state } = child
  if (state.native) return undefined
  if (e.index !== 0) throw new Error('Claude Code requested another model step after lastdrop’s answer.')
  if (messages.length < state.cursor) throw new Error('The child’s transcript was compacted before lastdrop read its messages.')
  const prompt = state.ran
    ? messages.slice(state.cursor).filter(m => m.role === 'user').map(m => userText(m as ApiMessage)).filter(Boolean).join('\n\n')
    : task
  if (!prompt) throw new Error('The child got a new turn without a text message.')
  const request: Request = {
    prompt, description: run.description, subagentType: 'general-purpose', model: run.model, effort: run.effort,
    cwd: await $.session.cwd(), permissionMode, parentModel: e.model, agent: run.agent, id: run.id,
    resume: state.ran ? run.id : undefined,
  }
  // Nothing ran yet, so the child's own model can take a plain run; an added model never runs on Claude.
  const plain = run.agent === undefined && !state.ran
  const handBack = async () => {
    if (!plain) throw new Error('lastdrop’s runner handed the agent back after it had run.')
    state.native = true
    await put($, key, state)
    return undefined
  }
  let stream: Run | undefined
  const stop = () => {
    void stopRemote($, run.id).catch(error => $.ui.log(`lastdrop: stop ${run.id} failed: ${String(error)}`, { to: 'debug' }))
  }
  signal.addEventListener('abort', stop, { once: true })
  try {
    if (signal.aborted) throw new Error('Stopped by Claude Code.')
    const begun = await start($, request)
    if ('native' in begun || ('noRoom' in begun && plain)) return await handBack()
    if ('noRoom' in begun) throw new Error(`lastdrop found nowhere to run ${run.agent ?? 'this agent'}.`)
    if ('error' in begun) throw new Error(begun.error)
    stream = begun.run
    state.ran = true
    // The messages so far reached the runner: a failure or a stop from here never sends them again.
    state.cursor = messages.length
    await put($, key, state)
    const show = progress(report, plain)
    for (const line of begun.early) show(line)
    let result: Line | undefined
    for (let line = await stream.next(); line; line = await stream.next()) {
      show(line)
      if (line.type === 'native') return await handBack()
      if (line.type === 'result' || line.type === 'error') { result = line; break }
    }
    if (!result) throw new Error('lastdrop’s runner ended without the agent’s report.')
    if (result.isError === true || result.type === 'error') throw new Error(String(result.text ?? 'The remote agent failed.'))
    return { ...result, text: delegatedHeader(result) + String(result.text ?? '') }
  } finally {
    signal.removeEventListener('abort', stop)
    stream?.stop()
  }
}

export const register: Register = on => {
  // Context leaves the shared system prompt intact. Claude renders it before UserPromptSubmit, so
  // re-read the catalog here and invalidate this cached answer for the next prompt. Unchanged text
  // keeps the model's prompt cache; section invalidation would also rebuild the shared system prompt.
  on('prompt.context', async ($, e, next) => {
    await syncCatalog($).catch(error => $.ui.log(`lastdrop: reading lastdrop's agents failed: ${String(error)}`, { to: 'debug' }))
    const answer = await next(e)
    const blocks = answer.blocks.filter(block => block.name !== SAVING_CONTEXT)
    $.ui.invalidate('prompt.context')
    $.ui.log(`lastdrop: Save Claude usage context: ${saveClaude ? savingInstruction : '(absent)'}`, { to: 'debug' })
    return { ...answer, blocks: saveClaude ? [...blocks, { name: SAVING_CONTEXT, text: savingInstruction }] : blocks }
  })

  // The mode built-in subagents inherit; the classic hook events carry it.
  on('classic.UserPromptSubmit', async ($, e, next) => {
    if (e.permission_mode) permissionMode = e.permission_mode
    void warmUp($).catch(error => $.ui.log(`lastdrop: warm-up failed: ${String(error)}`, { to: 'debug' }))
    // Edits to lastdrop's list apply from this turn's next model call on.
    await syncCatalog($).catch(error => $.ui.log(`lastdrop: reading lastdrop's agents failed: ${String(error)}`, { to: 'debug' }))
    return next(e)
  }).catch(($, e, next) => next(e))

  // The model reads the added agents beside Claude's own list of agent types. Replayed messages are
  // resolved again (on resume), so the text is frozen per session: the prompt cache keeps its prefix.
  on('prompt.attachment', { type: 'agent_listing_delta' }, async ($, e, next) => {
    if (e.agentId !== undefined || e.origin.kind !== 'engine' || !e.text.startsWith(LISTING)) return next(e)
    const answer = await next(e)
    if (answer.text === null) return answer
    if (revision === undefined) await syncCatalog($).catch(error => $.ui.log(`lastdrop: reading lastdrop's agents failed: ${String(error)}`, { to: 'debug' }))
    // An app that doesn't know added agents advertises none, even where a frozen listing has them: on a
    // resume after a downgrade the stored message changes, which only a rare downgrade can cause.
    if (!agentModels) return answer
    const id = await $.session.id()
    let list = await $.store.get(`listing:${id}`)
    if (typeof list !== 'string') {
      const current = listText()
      list = current === '' ? '' : `${current}${POINTER}${await runner($)} --agents --help`
      // A store that refuses leaves this request on the current list; the next one tries again.
      if (await put($, `listing:${id}`, list) && (await $.store.get(`announced:${id}`)) === undefined) await put($, `announced:${id}`, current)
    }
    const added = (await $.env.get('T3CODE_THREAD_ID')) ? ADDED_T3 : ADDED
    return list === '' ? answer : { ...answer, text: `${answer.text}\n\n${added}${list}` }
  }).catch(($, e, next) => next(e))

  // A compaction builds the listing again. A precomputed one installs later, with no `session.compact`
  // of its own then, so the notice row it files is the sign; a replayed row never raises `session.append`.
  on('session.compact', async ($, e, next) => {
    // A delegated child's own model never reads its conversation, and the summary would drop the tag.
    if (e.agentId === undefined && e.trigger !== 'precompute') {
      const child = await delegatedChild($)
      if (child && !child.state.native) return { skip: 'lastdrop runs this thread’s agent elsewhere; its conversation stays whole.' }
    }
    const answer = await next(e)
    if (e.agentId === undefined && e.trigger !== 'precompute' && answer.skip === undefined) await resetListing($)
    return answer
  }).catch(($, e, next) => next(e))
  on('session.append', async ($, e, next) => {
    if (e.agentId === undefined && e.message.type === 'system' && e.message.name === 'compact_boundary') await resetListing($)
    return next(e)
  }).catch(($, e, next) => next(e))

  // A change of the list reaches the model once, beside the prompt that follows it.
  on('prompt.submit', async ($, e, next) => {
    await syncCatalog($).catch(error => $.ui.log(`lastdrop: reading lastdrop's agents failed: ${String(error)}`, { to: 'debug' }))
    const note = await listNote($)
    return next(note ? { ...e, context: [...(e.context ?? []), note] } : e)
  }).catch(($, e, next) => next(e))

  on('classic.PostToolUse', ($, e, next) => {
    if (e.permission_mode) permissionMode = e.permission_mode
    return next(e)
  }).catch(($, e, next) => next(e))

  on('session.start', async ($, e, next) => {
    await $.command.register({ name: 'agents-elsewhere', description: 'Show the subagents lastdrop runs on your other accounts and providers' })
    await syncCatalog($).catch(error => $.ui.log(`lastdrop: reading lastdrop's agents failed: ${String(error)}`, { to: 'debug' }))
    void selfTest($).catch(error => {
      broken = `lastdrop: its self-test could not run (${String(error)})`
      $.ui.log(broken, { to: 'debug' })
      $.ui.toast(broken, { timeoutMs: 15_000 })
    })
    return next(e)
  })

  on('command.run', { command: 'agents-elsewhere' }, async $ => {
    await $.ui.open({ id: PANE, title: 'Agents on other accounts' })
    return { text: 'Opened the pane of agents running on your other accounts.' }
  })

  // Which types the engine offers, so a custom agent type named like an added model keeps its name.
  on('agent.offer', async ($, e, next) => {
    const answer = await next(e)
    if (answer.isOffered) offered.add(e.agent)
    return answer
  }).catch(($, e, next) => next(e))

  on('tool.call', { tool: 'Agent' }, async ($, e, next) => {
    if (e.subagent_type === 'fork') return next(e)
    if (owns(e.subagent_type)) {
      return { deny: `lastdrop's agents are no longer agent types. Call the Agent tool with model: "${e.subagent_type.slice(TYPE_PREFIX.length)}" instead.` }
    }
    let agent: string | undefined
    let type = e.subagent_type
    // The natural mistake: the name of an added model as the type. Not when a custom agent type has that name.
    if (typeof type === 'string' && !AGENT_TYPES.has(type) && !offered.has(type)) {
      if (!catalog.has(type)) await syncCatalog($)
      if (agentModels && catalog.has(type)) {
        // After a reload no listing has been seen yet, so a custom type of this name can't be ruled out.
        if (offered.size === 0) return { deny: `${type} is a model. Use model: "${type}".` }
        if (e.model !== undefined && e.model !== type) {
          return { deny: `${type} is a model. Use model: "${type}", or model: "${String(e.model)}" with a Claude agent type.` }
        }
        agent = type
        type = 'general-purpose'
      }
    }
    if (agent !== undefined || (typeof e.model === 'string' && !NATIVE.has(e.model))) {
      agent ??= String(e.model)
      let fresh = false
      if (!agentModels) { await syncCatalog($); fresh = true }
      if (!agentModels) return { deny: 'Update the lastdrop app: this one does not support added agents in the Agent tool’s model parameter.' }
      if (!catalog.has(agent) && !fresh) await syncCatalog($)
      if (!catalog.has(agent)) {
        const added = catalog.size > 0 ? `, or: ${[...catalog.keys()].join(', ')}` : ''
        return { deny: `Model ${agent} isn't available. Use ${[...NATIVE].join(', ')}${added}.` }
      }
      if (e.agentId !== undefined || e.isolation === 'remote' || e.name !== undefined) {
        return { deny: `lastdrop's agents (${agent}) run only from the main session, unnamed, without remote isolation.` }
      }
      if (!AGENT_TYPES.has(type)) return { deny: `${agent} runs only as general-purpose, Explore or Plan.` }
    }
    if (e.agentId !== undefined || e.isolation === 'remote' || e.name !== undefined) return next(e)
    const unknown = Object.keys(e).filter(key => !AGENT_KEYS.has(key))
    if (unknown.length > 0 || !ISOLATIONS.has(e.isolation)) {
      const what = unknown.length > 0 ? `field${unknown.length === 1 ? '' : 's'} ${unknown.map(k => `\`${k}\``).join(', ')}`
        : `isolation \`${String(e.isolation)}\``
      return { deny: `lastdrop doesn't handle the Agent tool's ${what} yet, so it can't run this agent. Tell the user: lastdrop's plugin needs updating for it.` }
    }
    const request: Request = {
      prompt: e.prompt, description: e.description, subagentType: type, model: agent ? undefined : e.model,
      effort: e.effort, isolation: e.isolation, cwd: await $.session.cwd(), permissionMode,
      parentModel: await $.session.model(), agent,
      role: ROLES.has(String(type)) ? type : undefined,
    }
    if (await admission($, request) === 'no_room') {
      return agent ? { deny: `lastdrop found nowhere to run ${agent}.` } : next(e)
    }
    claims.set(e.tool_use_id, request)
    try {
      // The shell is a native task that validates the call; the remote worker alone needs the model's
      // `model` and a worktree.
      return await next({ ...e, subagent_type: type, model: agent ? undefined : e.model, isolation: e.isolation === 'worktree' ? undefined : e.isolation })
    } finally {
      claims.delete(e.tool_use_id)
    }
  }).catch(($, e, next) => ({ deny: `lastdrop failed: ${next.error.message ?? next.error.kind}` }))

  // A T3 Code child thread runs where an Agent call would: lastdrop picks the account, or the added model's
  // provider, and the child's turns run there (delegatedTurn). No room: T3 starts the child unchanged.
  on('tool.call', { tool: DELEGATE }, async ($, e, next) => {
    const call = e as unknown as Record<string, unknown>
    const target = (call.target ?? {}) as Record<string, unknown>
    if (typeof call.task !== 'string' || target.environmentId !== undefined) return next(e)
    if ((target.providerInstanceId ?? T3_CLAUDE) !== T3_CLAUDE || (target.driverKind ?? T3_CLAUDE) !== T3_CLAUDE) return next(e)
    const model = typeof target.model === 'string' ? target.model : undefined
    if (model !== undefined && !model.startsWith('claude-') && !NATIVE.has(model) && !catalog.has(model)) await syncCatalog($)
    const agent = model !== undefined && agentModels && catalog.has(model) ? model : undefined
    // Another provider's model on this instance: T3 answers it.
    if (model !== undefined && agent === undefined && !model.startsWith('claude-') && !NATIVE.has(model)) return next(e)
    const effort = effortOf(target.options)
    const description = typeof call.title === 'string' ? call.title : undefined
    const request: Request = {
      prompt: call.task, description, subagentType: 'general-purpose', model: agent ? undefined : model, effort,
      cwd: await $.session.cwd(), permissionMode, parentModel: await $.session.model(), agent,
    }
    if (await admission($, request) === 'no_room') {
      return agent ? { deny: `lastdrop found nowhere to run ${agent}.` } : next(e)
    }
    const id = `t3-${Date.now().toString(36)}${Math.random().toString(36).slice(2, 10)}`
    const run: Delegated = { id, agent, model: agent ? undefined : model, effort, description }
    // T3 doesn't know an added model; the child keeps the session's, which never runs for it.
    const { model: _, ...rest } = target
    const childTarget = agent ? rest : target
    const { target: __, ...args } = call
    const routed = Object.keys(childTarget).length > 0 ? { ...args, target: childTarget } : args
    const answer = await next({ ...routed, task: tag(call.task, run) } as unknown as typeof e)
    if (answer.deny !== undefined || !agent) return answer
    // The answer names the child thread's own model: the model reads the added one, and where it runs.
    // The child exists now, so a failure here keeps T3's answer instead of failing (or repeating) the call.
    try {
      for (const id of idsIn(jsonOf(answer))) await put($, `delegated-child:${id}`, agent)
      return editAnswer(answer, json => rewriteChildren(json, new Map(), agent))
    } catch (error) {
      $.ui.log(`lastdrop: rewriting delegate_task's answer failed: ${String(error)}`, { to: 'debug' })
      return answer
    }
  }).catch(($, e, next) => ({ deny: `lastdrop failed: ${next.error.message ?? next.error.kind}` }))

  // T3's other answers about our children (task_status, t3_thread_read, ...) name the thread's model too, and
  // orchestrator_capabilities lists only T3's providers, without the added models.
  on('tool.call', { tool: T3_TOOLS }, async ($, e, next) => {
    if (e.tool === DELEGATE) return next(e)
    const answer = await next(e)
    if (answer.deny !== undefined) return answer
    if (e.tool === CAPABILITIES && (e as unknown as Record<string, unknown>).environmentId !== undefined) return answer
    // The tool ran: a failure here keeps T3's answer, never runs it again.
    try {
      return await rewriteT3($, e.tool, answer)
    } catch (error) {
      $.ui.log(`lastdrop: rewriting ${e.tool}'s answer failed: ${String(error)}`, { to: 'debug' })
      return answer
    }
    // Only `next` can throw past the try, and a tool that failed must not run twice.
  }).catch(($, e, next) => ({ deny: `${e.tool} failed: ${next.error.message ?? next.error.kind}` }))

  on('agent.spawn', async ($, e, next) => {
    const special = e.fork || e.isTeammate || e.workflow || e.parentAgentId !== undefined
    if (!e.resume && special && claims.get(e.tool_use_id)?.agent !== undefined) {
      return { deny: `lastdrop's agents (${String(claims.get(e.tool_use_id)?.agent)}) run only from the main session's Agent tool.` }
    }
    if (special && !e.resume) return next(e)
    if (e.resume) {
      const id = e.resume.agentId
      const route = routes.get(id) ?? await $.store.get(`native-agent:${id}`) as Route | undefined
      if (route) {
        // Queued resumes can reach step 0 before their coordinator message appears in session.messages.
        route.resumePrompt = e.prompt
        if (e.permissionMode) route.request.permissionMode = e.permissionMode
        routes.set(id, route)
        await put($, `native-agent:${id}`, route)
      } else if (owns(e.subagentType) || await wasAdded($, id)) {
        // A native turn would answer as Claude, without the agent that ran before.
        return { deny: `lastdrop has no saved route for added agent ${id}, so it can't be resumed. Start a new one.` }
      }
      return next(e)
    }
    const claim = claims.get(e.tool_use_id)
    if (!claim) return next(e)
    const request: Request = {
      ...claim, subagentType: e.subagentType, model: claim.agent ? undefined : e.model ?? claim.model,
      cwd: e.cwd ?? claim.cwd, permissionMode: e.permissionMode ?? claim.permissionMode,
      parentModel: e.parentModel, background: e.background,
    }
    let ready = () => {}
    const pending = new Promise<void>(resolve => { ready = resolve })
    spawning.add(pending)
    try {
      const result = await next(labelled(e, claim.agent))
      if (result.deny !== undefined || !result.agentId) return result
      const route: Route = { request, description: e.description, toolUseId: e.tool_use_id, ran: false, cursor: 0,
                             handback: e.permissionMode === 'auto' }
      routes.set(result.agentId, route)
      // The marker goes first: with a route but no marker a lost route would resume as Claude. Either one
      // failing fails the run visibly.
      const marked = claim.agent === undefined || await markAdded($, result.agentId)
      if (!marked || !await put($, `native-agent:${result.agentId}`, route)) {
        route.error = 'lastdrop could not save the native agent’s route: the store refused it.'
      }
      return result
    } finally {
      ready()
      spawning.delete(pending)
    }
  }).catch(($, e, next) => ({ deny: `lastdrop failed: ${next.error.message ?? next.error.kind}` }))

  // Separate registration: a spawn nested in agent.spawn/tool.call still reaches this hook.
  on('turn.step', async function* ($, e, next) {
    const shown = { value: false }
    if (!e.agentId) {
      let result: Line | undefined
      try {
        result = yield* live(report => delegatedTurn($, e, next.signal, report), shown)
      } catch (error) {
        if (next.signal.aborted) return { turnId: e.turnId, index: e.index, answer: '', toolUses: [], stopReason: null, usage: null }
        if (shown.value) return yield* respond(e, `lastdrop agent failed: ${String(error)}`, null, false, 1)
        throw error
      }
      if (!result) {
        if (shown.value) return yield* respond(e, 'lastdrop agent failed: its runner handed the turn back after showing its work.', null, false, 1)
        return yield* next(e)
      }
      return yield* respond(e, String(result.text ?? ''), usageOf(result, e.model), false, shown.value ? 1 : 0)
    }
    if (spawning.size > 0) await Promise.all([...spawning])
    const route = routes.get(e.agentId) ?? await $.store.get(`native-agent:${e.agentId}`) as Route | undefined
    if (!route) return yield* next(e)
    routes.set(e.agentId, route)
    let result: Line
    let lead = ''
    let native = false
    try {
      active.add(e.agentId)
      result = yield* live(report => remoteTurn($, e, route, next.signal, report), shown)
      native = result.type === 'native'
      if (!native) lead = header(route.request, result)
    } catch (error) {
      if (next.signal.aborted) return { turnId: e.turnId, index: e.index, answer: '', toolUses: [], stopReason: null, usage: null }
      result = { type: 'result', isError: true, text: `lastdrop agent failed: ${String(error)}` }
      await record($, e.agentId, result)
      $.ui.log(String(result.text), { to: 'debug' })
    } finally {
      active.delete(e.agentId)
    }
    if (native && shown.value) {
      native = false
      result = { type: 'result', isError: true, text: 'lastdrop agent failed: its runner handed the agent to the built-in agent after showing its work.' }
    }
    if (native) {
      // No account took the run and no work happened: the built-in agent runs it, as if lastdrop weren't here.
      routes.delete(e.agentId)
      quiet.delete(e.agentId)
      const id = e.agentId
      await $.store.delete(`native-agent:${id}`)
      agents = agents.filter(a => a.id !== id)
      $.ui.invalidate('ui.render')
      await showStatus($)
      return yield* next(e)
    }
    const text = lead + String(result.text ?? '')
    const usage = usageOf(result, e.model)
    return yield* respond(e, text, usage, route.handback === true, shown.value ? 1 : 0)
  }).catch(async function* ($, e, next) {
    // A routing adapter must never fail open to a model request on the session's account.
    const text = `lastdrop agent failed: ${next.error.message ?? next.error.kind}`
    return yield* respond(e, text, null, e.agentId !== undefined && routes.get(e.agentId)?.handback === true)
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    const list = agents.slice().reverse()
    const unfolded = await read($, open)
    return (
      <Box flexDirection="column">
        {list.length === 0 && <Text dimColor>No agents on other accounts yet in this session.</Text>}
        {list.map(agent => (
          <Box flexDirection="column" marginBottom={1}>
            {agentBlock($, e, agent, unfolded.includes(agent.id))}
          </Box>
        ))}
      </Box>
    )
  })
}
