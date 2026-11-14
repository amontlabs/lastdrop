# Agents on other providers — design

Status: extra models for the Agent tool, built on the `agent-models` branch, 2026-10-30; agent types since 2026-11-14 (`agent-types` branch). Codex and Antigravity are verified live; Z.ai and OpenRouter need an inference key to verify. Research behind it: [docs/research/](research/) (A: Claude Code side,
B: Codex, C: Z.ai and OpenRouter, D: Antigravity, H: byte checks and live runs of the Agent-model design).

## What Claude sees

Each added agent is an agent type of lastdrop's plugin, `lastdrop:<name>`, in Claude Code's own list of agent types:

```
- lastdrop:sol: Reviews: code, plans and diffs that need strong coding reasoning. (Codex · gpt-6.1-sol · high) (Tools: All tools)
```

Claude calls the built-in `Agent` tool with it as the type: `Agent({ subagent_type: "lastdrop:sol", prompt, description })`.
The plugin never changes the call. Since Claude Code 2.1.322 (2026-11-14), auto mode refuses any call a hook changed
after it was reviewed ("a hook changed this call's input after auto mode reviewed it"). The earlier form, `model: "sol"`,
needed a rewrite, so in auto mode it always failed. A registered type runs as written, in every permission mode.

The row, Show transcript, background, `SendMessage`, `TaskStop`, `ListAgents` and Open in Terminal work as they do for
agents on other Claude accounts. The system prompt and tools are unchanged; the types arrive in the listing, which is a
message (see Prompt cache below).

The rule: lastdrop changes where a subagent runs, never what runs. An added agent runs on its own provider
and model, and a Claude agent never runs on a different Claude model than the one asked for. If no account has
the model, the call fails naming it, or (for a reroute) the built-in agent runs.

What was given up: an added agent can't be combined with `Explore` or `Plan`. A `lastdrop:` type is always a general
agent (see Roles).

## The Agents list (Settings)

Settings has four pages: Accounts, Claude, Agents and General. Settings → Claude holds the **Agents in Claude Code**
switch (it installs the plugin; everything here needs it on), **T3 Code threads**, **Save Claude usage** and the
account limits. Settings → Agents holds the list.

**Save Claude usage** (Settings → Claude, off by default) asks Claude to delegate substantial implementation, exploration,
reviews and research to the added agents (the `lastdrop:` types) first, choosing by description,
even when a description says to prefer built-in Claude subagents. Claude works itself or uses built-in agents
only when none fits. The catalog stores this as `saveClaude`; older catalogs decode it as false. An app from before
the types sends the old default text, which names the Agent tool's model parameter; the plugin sends the current one
in its place (a text the user edited is sent as written).

One global list. Each entry:

| Field | Notes |
| --- | --- |
| name | The type is `lastdrop:<name>`. A slug (letters, digits, `-`, `_`); `sonnet`, `opus`, `haiku`, `fable`, `inherit`, `best`, `opusplan` and anything starting with `claude-` are reserved, because the native model wins. |
| description | The role Claude reads ("Second opinion on tricky bugs"). Also sent to the backend as instructions. |
| provider | Claude account pool, Codex, Z.ai, OpenRouter or Antigravity. |
| model | Picked from the provider's live list (Codex `model/list`, OpenRouter `/api/v1/models` filtered to tool use, Antigravity `agy`'s list, Z.ai fixed list). |
| effort | Preset (fixed level), or the call's `effort`, which wins over the preset (levels the model lacks are an error, not a silent clamp). |
| enabled | Off removes it from the list; a call already in flight or a stale one gets a clear "not available" error. |

lastdrop writes the list as a revisioned catalog in Application Support. Credentials never go in it.
`lastdrop --agent-catalog` prints the enabled agents (reserved names left out) and `agentModels: true`, which
tells the plugin the app speaks this design.

## Changing the list from an agent

`lastdrop --agents` changes the list without Settings: `list`, `models <provider>`, `set` (JSON on stdin, added or
replaced by name), `remove <name>`, `saving on|off` and `judge <provider> <model> [effort]` (or `judge <provider>
default`; see How commands are checked), with `--help` for the details. It prints JSON, or a reason on
stderr with exit code 1. `set` makes Settings' checks and also refuses a model or effort the provider's live list
doesn't have. A provider whose list fails leaves a warning, and its ids are taken as they are, as Settings lets you
type them. Sign-ins and API keys stay in Settings.

Every writer goes through `AgentCatalog.update`, which reads the file and saves it under a lock, so the app and the
command can't lose each other's edits. The command also sends a distributed notification, so an open Settings page
reloads.

Claude finds the command through one line that ends the text the plugin adds to the listing: "Only if the user asks
to change these, run <path> --agents --help". It costs about 25 tokens once per session, and the instructions are read
only when needed. Nothing enforces the "only if": the normal Bash permission prompt is what stops an unrequested change.
It sits in the frozen text, so it can't change a replayed message, and a listing frozen before it existed keeps its
bytes. Notes leave it out, so a session that started with no added agents doesn't get it until its listing is rebuilt.

## How it reaches Claude Code

**Registration.** At session start (after the engine's own `session.start`, once the session is bound) and after every
catalog read that changes it, the plugin calls `$.agent.register` for each enabled agent: `name` is the catalog name,
`description` is the catalog description plus its summary (`Reviews: hard bugs. (Codex · gpt-6.1-sol, then …)`), and
`prompt` is a placeholder that never runs, since lastdrop answers every step of the agent. `tools` is left out. A type
already registered with the same description is not registered again. The catalog is read before each prompt (and when
a call names an agent it doesn't know), so an edit applies from the next turn on.

**Removal.** The mod API has no way to drop a type: a type whose agent left the catalog (removed, disabled, or
renamed) stays registered, and an `agent.offer` hook answers `isOffered: false` for it, which hides it from the listing
and refuses it at dispatch. An app without `agentModels` gets nothing registered, and every `lastdrop:` type hidden. A
call naming a hidden type is denied with the list of what is available.

**What the model is told of a change.** The engine announces types added and removed itself, in the next turn's
listing delta ("New agent types are now available for the Agent tool: …", "The following agent types are no longer
available: - lastdrop:x"). It does not announce a description changed in place on a re-registered name (checked
2026-11-14, Claude Code 2.1.322, probe mod: re-registered `echo` with a new description, added `newbie`, hid `gone`;
the delta named only the last two). So `prompt.submit` attaches a note for that case only, once: "These agents the
user added now read: - lastdrop:sol: …". What the session was last told is stored per session (`announced:<id>`, the
latest 100 sessions). The first prompt of a session, or the first after a compaction or `/clear`, only records it.

**Prompt cache.** The listing is a message, not part of the system prompt or tools, so a change appends a delta
and keeps the cached prefix. Registration is stable within a session: the same catalog registers nothing again,
so the listing doesn't change. A catalog edit changes it once, through the engine's delta (added, removed) or the
plugin's note (a new description). A plugin reload (a save of its files) unloads its types and registers them again
with the same text.

**The listing text.** A `prompt.attachment` hook adds one paragraph to the main loop's `agent_listing_delta` when the
engine wrote it and it starts with `Available agent types`: "The lastdrop: agent types are agents the user added;
each runs on the provider and model its description names." and the pointer to `--agents --help` (see Changing the
list). Subagents' copies, other deltas and other attachments are left alone. Nothing is added when the catalog is
empty.

**Freezing.** Claude Code resolves replayed messages again on resume, so the paragraph is stored per session on first
use and reused for every later listing of that session (the runner's path could otherwise change it). Compaction of
the main loop clears it, so does `/clear`. Old sessions' entries are pruned (the latest 100). A session from before the
types keeps the frozen list it had, which names the `model` form; a call in that form is denied with the type to use.

**Routing (`tool.call`).** `fork` goes first, as before. Then:

- `subagent_type: "lastdrop:<name>"` not in the catalog after a fresh read → denied, naming the added agents
  ("Agent type lastdrop:x isn't available. The user's added agents are the agent types lastdrop:sol, lastdrop:argon.");
- one called from a subagent (`agentId`), with `name`, with remote isolation, or with a `model` → denied with a reason;
- otherwise `lastdrop --agent-route` is asked with `agent: <name>` and `subagentType: "general-purpose"`, no `model`
  and no role, and the call's `effort`. No room → denied.

The plugin records the claim under the call's `tool_use_id` and passes the call to the engine unchanged, byte for
byte; the engine validates it and creates its task. `agent.spawn` claims the task and sets the subagent's model to the
agent's name (`sol`). The Agent tool's schema refuses that name in the call, but `agent.spawn` takes any id. Claude
Code stamps every message of the subagent with its step model, even one a hook answered alone (it ignores
`usage.model`), and hosts label the subagent by it: without the name, T3 showed the parent's `claude-opus-5-5`
on each flash and gemini subagent. No request is ever made with the name, since lastdrop answers every step. A
resumed agent keeps it; the engine refuses a hook's model on a resume. A spawn of a `lastdrop:` type that no Agent call
claimed (a fork, a teammate, a workflow agent, another plugin's `$.agent.spawn`) is denied, so the placeholder prompt
never runs on Claude. `turn.step` runs `lastdrop --agent-run` and serves the
report. While the run works, the turn streams each of its steps as thinking ("Bash: swift test"), shown live and
not recorded, and the report follows in the next block. Claude Code stops a subagent whose stream shows nothing
for ten minutes ("Agent stalled", shown as `[Request interrupted by user for tool use]`), so during a long step the
runner's `tick` line, once a minute, lets the plugin add "Still working on … (N min without a new step)" after four
quiet minutes. A plain reroute shows nothing before its first step, since the built-in agent may still take it.
T3's delegated children stream the same way. Native models, `SendMessage` to older routes and every other call behave
as before; runs started under the earlier forms can still be continued.

**The earlier forms.** `model: "sol"` (with any type) and the bare name as the type (`subagent_type: "sol"`) are
denied, never rewritten: "sol is an agent type: call the Agent tool with subagent_type: "lastdrop:sol" and no model. It
runs as a general agent, never as Explore or Plan." A custom agent type named like an added agent keeps its name (the
plugin tells it from the engine's offers). Any other model outside sonnet, opus, haiku and fable is denied naming
Claude's models and the added agents.

**Report header.** A successful added-agent run starts with `Ran on <model>.`, plus ` Worktree: <path> (branch
<branch>).` when it had one, and on a following line `Declined: a; b` when something the agent needed was refused.
Each item says why: `git push (needed approval)` when a provider's request went unanswered, or, on Antigravity,
`swift test (not covered by your allow rules; judge: high risk, user authorization low — <rationale>)`, so the main
agent can suggest an allow rule. A Claude reroute with a worktree gets just the worktree line.

Usage saving adds one named block through `prompt.context`, leaving the shared system prompt intact.
Claude renders context before prompt-submit hooks, so the context hook reads the catalog itself and
invalidates that cached answer for the next prompt.

Claude Code sends a block with an unrouted name in one copy, made when the conversation holds none, and a
later answer doesn't add to, change or take back a copy that stands. In a running conversation:

- Switched on: the next prompt carries the block, added at the end of the conversation.
- Switched off, or the prompt text edited: the copy already sent stays, and the model keeps reading it until
  compaction or `/clear`. New conversations and compacted ones use the current setting.

No case changes what was already sent, so the switch keeps the prompt cache. A request capture (2026-10-30,
Claude Code 2.1.311, local mock API) found `tools` and `system` unchanged by the switch, and each request's
cached prefix byte-identical in the next through on, off and text edits. The instruction stayed in the request
after switching off and left only with compaction. The earlier `/context` check logged the hook's answer, not
what the model receives.
See the [mod API declarations](https://github.com/anthropics/claude-code/blob/main/mods/types/claude-code.d.ts),
`prompt.context`, `prompt.attachment` and `tool.call`.

Evidence for the agent types (2026-11-14, Claude Code 2.1.322, `claude -p --model sonnet --permission-mode auto`, the
plugin from this branch, the installed app's runner): asked to "ask the scout agent (one of the user's added agents)
what 17+25 is", Sonnet picked `lastdrop:scout` from the listing by itself and called it unchanged; the call was not
refused, `subagents.log` showed `start scout on Claude · haiku`, and the report came back as `Ran on
claude-haiku-5-5.\n\n42`. A worktree run of it and of a plain haiku reroute went the same way (see Worktrees).

Evidence for the earlier `model` form (Claude Code 2.1.311, no bypass flags): the requests are byte-identical in
`tools` and `system` with and without the plugin, and only the listing text differs. A model passed outside the enum reaches `tool.call`
before validation, and rewriting through `next` keeps the model's own `model: "sol"` in the transcript. With the
"models the user added" wording, Sonnet used `sol` for reviews 10/10 and `argon` for opinions 10/10, and Opus 5/5
each, all on the first try with `model`, and no added model for a search (Sonnet 0/10, Opus 0/5). These are small
samples through `claude -p`. See [research H](research/H-agent-models.md) for the byte checks and live runs.

## T3 Code

T3 Code runs each thread's `claude` itself and replaces that process on a model change, a provider switch or
Stop, which ends native background agents. Its orchestration prompt therefore sends background work through its
`delegate_task` tool, which starts a child thread. lastdrop runs those children the way it runs an Agent call,
with no extra providers or accounts set up in T3.

- **lastdrop's T3 instance.** lastdrop's T3 switch also adds a T3 provider instance `lastdrop` (driver
  `acpRegistry`), which runs `lastdrop --acp` and offers every enabled added agent by name plus `fable`, `opus`,
  `sonnet` and `haiku`; T3 lists it in `orchestrator_capabilities`. The model starts background work there with
  `delegate_task` and `target: { providerInstanceId: "lastdrop", model: "flash" }`, and the call goes to T3 exactly as
  written: since 2026-11-14 auto mode refuses a call a hook changed. lastdrop's server checks room
  (`--agent-route`, ended after 30 s or on a cancel), gives the run a new id and runs each turn with `--agent-run`.
  T3 names the child's real model and instance, so nothing is rewritten. The plugin knows the instance is set up
  from `--agent-catalog` (`t3Instance`: ours, enabled, its wrapper there).
  - What such a child loses against the tag path: `target.options` (effort: the instance offers none, so an added
    agent runs at its own effort and a Claude model at the runner's default) and the call's `title` (the run has
    no description). T3 tells it no permission mode: T3's Plan mode runs a turn read-only, otherwise it runs in auto
    mode, whatever its parent's (looser than an `acceptEdits` parent, tighter than a full-access one).
  - A model change on the child is taken until its run starts, then refused ("This run stays on opus; start a new
    task for flash.").
  - **Threads the user starts on it.** T3 lists lastdrop as a provider, so the user can start a top-level thread on
    it. T3 gives an ACP agent no sign of whether a thread is a delegated child: `session/new` has only `cwd` and
    the MCP servers, the per-prompt instructions are the same, and the child flag (`lineage.relationshipToParent`)
    stays inside T3's MCP session registry. So such a thread runs too, as a child would, but without T3's tools
    (the runner gets no MCP servers yet) and losing its conversation when T3 rolls it back (T3 opens a bare new
    session; lastdrop starts a new run). This is Phase 2's blocker; the app's T3 setting says the provider is for
    background tasks.
- **Parent (`tool.call` on `mcp__t3-code__delegate_task`).** The call is passed unchanged or refused, never changed:
  - On the `lastdrop` instance: unchanged. If T3 refuses it before creating anything (instance unhealthy, model not
    offered: the same errors as before), lastdrop treats the instance as not set up for 10 minutes, and adds a note
    to T3's error: in auto mode, use the Agent type for foreground work (background isn't available); otherwise
    call again without `providerInstanceId`, which takes the tag path.
  - An added agent on T3's Claude instance, instance usable: denied with the instance form ("sol runs on lastdrop's
    T3 instance: call delegate_task with target: { providerInstanceId: "lastdrop", model: "sol" }, or for foreground
    work the Agent tool with subagent_type: "lastdrop:sol".").
  - A plain Claude child (no model, or a Claude model, on T3's Claude instance), in every mode: unchanged.
    `--agent-route` is asked as for Agent; with room, lastdrop first notes the run (`lastdrop --delegate-note`, a
    locked `delegate-notes.json` in its support folder, shared by every account profile) with the parent's thread
    id and the task. The child's plugin claims the note at its first turn (see Child) and answers its turns as on
    the tag path. T3 failing the call drops the note; no room leaves an ordinary T3 Claude thread.
  - Other instances, other models and other machines are left to T3.
- **Without the instance (the tag path).** When the instance isn't set up (or the app is older, or T3 refused it in
  the last 10 minutes), a session in auto mode, or one whose mode isn't known yet (after a plugin reload, until the
  next prompt or tool result: the mod API has no live mode), gets an added agent denied, pointing to its Agent
  type. Plain children are noted as above (an app without `--delegate-note` sends them unchanged in auto mode and
  tagged outside it). Outside auto mode,
  where a changed call still runs, the old path stays: the plugin asks `--agent-route` as for Agent (no room: a
  plain call goes to T3 unchanged, an added model is denied); otherwise the task gets a last line
  `<!-- lastdrop {"id":…,"agent"|"model":…,"effort":…,"description":…,"permissionMode":…} -->`, and an added model
  is removed from `target` (T3 doesn't know it; the child keeps the session's model, which never runs for it). The
  transcript keeps the model's own arguments. The rest of this section is that path, which also serves children
  started before an update; lastdrop's server runs a tagged first prompt as the tag says.
- **Child of a note.** In T3 without a tag, the child looks for a note bound to its thread (its store, then
  lastdrop's notes: a follow-up). At its first turn it claims an open note (under 10 minutes old) whose task ends its
  first user blocks (after T3's "Act as the … sub-agent" line, before a merged steer), and whose parent is the one
  `t3_thread_read` names for this thread (a thread T3 says nobody delegated claims nothing; when T3 can't say, only
  a lone matching note). Several: the child's model family first, then the oldest. Then as below.
- **Child (`turn.step` on the main loop).** When the session's first user message ends with that tag, the
  plugin answers each turn with `lastdrop --agent-run` (the task, then each new message with `resume`), so the
  child's own model never runs. Accounts, added models, fallbacks at a limit and stop are the runner's, as for
  Agent; the report starts with `Ran on <account> (<model>).` A run the runner hands back (no room, nothing
  done) leaves the child on its own model from then on, reading the task with the tag line. Messages are sent
  once: the cursor moves as soon as the runner has them, and without stored state lastdrop's last answer marks
  where the run got to. The cursor counts the user's text blocks, not messages: a T3 steer stops the running
  turn before its answer is written, so Claude Code merges the steer into the message before it (the task's,
  after the tag), and the tag is looked for at the end of each of the first message's blocks. Without that, a
  steered child lost its tag and ran on its own model (seen 2026-11-13). The child's conversation is never compacted (`session.compact` is skipped), since no
  model reads it and a summary would drop the tag.
- **What the model reads of T3's answers.** T3 describes a child by its thread's instance and model, and lists
  only its own providers, with Antigravity and the like as disabled. Models read that as the added model not
  running (Opus cancelled such children). So, in the JSON T3 returns (the result is one string):
  `delegate_task`, and later answers that name an added model's child by `taskId` or thread id
  (`task_status`, `t3_thread_read`, …), show `"model":"flash","runsOn":"lastdrop · Antigravity · …"`; and
  `orchestrator_capabilities` gains `"addedModels":[{"model","runsOn"}]` (not for another machine). Plain
  Claude children are left as T3 wrote them. T3's own UI is unchanged. A rewrite that fails keeps T3's answer;
  a T3 tool is never called twice.
- **Listing.** In T3 (`T3CODE_THREAD_ID` set) with lastdrop's instance usable, the paragraph the plugin adds to
  the listing leads with it: "Background work in T3 Code on Claude models (fable, opus, sonnet, haiku) uses
  delegate_task as usual; lastdrop picks the account. For an added agent, call delegate_task with target: {
  providerInstanceId: "lastdrop", model: "<name>" } and no options, where <name> is a lastdrop: agent type without
  lastdrop:; effort comes from the agent's own settings." then the types sentence and "They run through the Agent
  tool like Claude's own agents, so the rule to use delegate_task for another provider's model doesn't apply to
  them: use Agent with them for foreground work." With no added agents it is the first sentence alone. A paragraph
  frozen with an earlier wording keeps it. `delegate_task`'s own description gains, while the instance is set up
  and agents exist, "The agents the user added to lastdrop (…) run only with target.providerInstanceId "lastdrop"
  and target.model set to the agent's name; Claude models need no providerInstanceId." Without the instance it reads as
  before: "… delegate_task's target.model also accepts their names without the lastdrop: prefix. They run through
  the Agent tool like Claude's own agents, so the rule to use delegate_task for another provider's model doesn't
  apply to them: use Agent, and delegate_task only for background work." The text is frozen per session like the rest of the
  paragraph; the hook follows what the app says now, so a session frozen before the instance was set up is told
  the form by the deny. T3's own prompt says to use `delegate_task` for another provider's model; it is appended
  after the sections a plugin can rewrite (`prompt.compose` lists `lean_body, pronouns, …` without it), so lastdrop
  answers it here instead.

Evidence (T3 Code beta, Claude Code 2.1.319, 2026-11-07, real T3 threads on Sonnet 5.5 and Opus 5.5):
"ask gemini …" used Agent with `gemini`, 5/5. "… flash in the background" and "start flash in the
background, then check task_status": before the answer rewrites, Opus cancelled 3 of 5 children and Sonnet
said flash didn't run; with them, 6/6 used delegate_task with `flash`, kept the child, and reported Antigravity
(task_status included). A follow-up `t3_thread_send` resumed the same run on the same account.

## Routing rules

- An added agent always runs on its provider and its model: never the built-in agent, never another provider,
  never another model. A Claude-provider agent may move among the accounts in the pool (one at its limit, or
  without the model, passes it on); the provider and model stay the same. The exclusions that apply today (forks, teammates, nested calls…) become errors for added agents.
- Out of room, signed out, model not on the plan → an error that says which and when it resets.
- The run keeps the provider, model, effort and session id it started with; `SendMessage` continues there even
  if the entry was edited since. A read-only role is kept too.
- A plain Claude call (a native model, or none) goes through a chain: the other Claude accounts first, the one
  with the most room; then the built-in agent itself, exactly as if lastdrop hadn't
  touched the call. When no other account takes it before any work was done (every attempt was refused for a
  limit or a plan without the model), the runner says `native` and the plugin lets the built-in agent run. The
  model is never swapped on the way. A run already underway (its session moves on to the next account, the
  session's own last) stays with the runner. A call with worktree isolation can go back to the built-in agent too:
  the engine made its worktree, and the built-in agent runs there.
- Every account is tried: one that refuses the model (a plan without it) is skipped for that run only, with nothing
  remembered between runs, so a plan or credit change is noticed at once.

## Fallbacks

An agent has one or more models by priority, each with its own provider, model and optional effort. The catalog
keeps the first as the agent's own and the rest as `fallbacks`. In Settings → Agents, the agent's editor shows them
as one **Models** list by priority, with at least one entry: "Tried in order. The next one runs only if the one above
can't start, never once work has begun." `fallbacks` is empty by default, so an agent without any reads and behaves
as before, and the stored catalog doesn't even carry the key.

The listing shows the chain, so Claude knows what it is choosing: `lastdrop:sol: Reviews… (Codex · gpt-6.1-sol · high,
then Antigravity · gemini-4-argon)`.

A fallback is tried only when an attempt fails before any work happened, and for a reason about availability: a
usage limit, a sign-in or key, a provider that isn't installed, a model the account doesn't have, or an effort the
provider doesn't take (an error, never a silent clamp). On Antigravity, `agy` reports a spent quota as the model's
own reply and ends the turn normally; a short reply that is only that notice counts as a usage limit, so the chain
moves on. Never for another error: an empty report, a bug, or a stop (`TaskStop` ends the whole chain at once).

An attempt that reaches a usage limit partway through hands its work to the next attempt (since 2026-11-12). A Claude
attempt first forks onto another Claude account with room (`AgentRun.carryOn`); only when none has room does the
chain move. The next attempt runs in the folder or worktree the work is in, never a new one, and is told
(`AgentRun.handoverPrompt`): another agent stopped partway at its limit, continue and don't start over; its thread
(the agent id and the provider's own thread id); its transcript, the agent's log in `agents/<agentId>.log`, to read
if it needs to; where its changes are; then the original task again. The caller sees one `started`, a `moved`, and
the final report. When no later attempt can continue, the error says the work was started and where it is. The call's `effort` wins over each
attempt's own. The read-only role and worktree isolation apply to every attempt, and a worktree a failed attempt
made is removed before the next starts.

A passing API error (a Cloudflare page, a 5xx, 529 overloaded, the network; see `TransientError` and
[claude-accounts.md](claude-accounts.md#t3-code-threads-on-accounts-with-room-2026-11-09)) is retried on the same
session first, after 10 s, 30 s, 90 s and 3 min. Once the retries are spent it counts as an availability reason: before
any work the chain moves on, and partway the work is handed on as at a usage limit, the next attempt told the previous
agent stopped after repeated temporary API errors.

For the plugin, each switch is a `moved` line (with the next `provider` and `model`), followed by a new `started`
line with the same `agentId` and the attempt's own `account`, `model` and `provider`, which updates the same row.
The `result` line carries `provider` (what ran) and `unavailable`, the models tried and skipped, when there are
any, and the report starts `Ran on gemini-4-argon-high (gpt-6.1-sol unavailable).` If every attempt fails the
error lists each one and why. Claude never stands in, unless the user put a Claude entry in the list.

The same model at another effort is its own attempt (`sol` at `xhigh`, then `sol` at `high`). A catalog saved by an
older version of the app drops fallbacks, which it doesn't know.

A follow-up (`SendMessage`) continues on the attempt that ran, from the entry saved for it, with no chain.

## Worktrees

The call's `isolation: "worktree"` reaches the engine unchanged, for an added agent and for a plain Claude reroute, so
Claude Code makes the subagent's worktree itself: `<repo>/.claude/worktrees/agent-<id>` on the branch
`worktree-agent-<id>`. `agent.spawn` doesn't carry its path (`e.cwd` is undefined), but the subagent's own loop runs
there, and the plugin's `turn.step` for it reads it as the session's folder (`$.session.cwd()`). On the agent's first
run the plugin gives the runner that folder as `cwd`, with no `isolation`, so the runner makes no worktree of its own,
and keeps it in the route, with the folder the call came from, for follow-ups. The report's header names it
(`Worktree: <path> (branch <branch>).`, the branch read with `git symbolic-ref --short -q HEAD`, none when detached)
only when the worktree is there and changed: not clean, or its branch moved (the reflog has more than its first
entry), the same test as the runner's `AgentWorktree.isUnchanged`. If the folder is still the parent's (no worktree
was made), the runner is asked for its own worktree, as before.

Claude Code handles the worktree as for its own agents: one the agent left unchanged is removed when the agent ends,
and one it changed is kept and named in the Agent result (`worktreePath`). `SendMessage` continues in it while it
exists. Once it is gone, a follow-up runs in the folder the call came from, with no worktree in its header: the plugin
checks the path on each turn, and the runner (`AgentRun.resumable`) moves a saved entry whose folder is missing to
the request's folder and drops its worktree. Claude Code resumes a session there (checked 2026-11-14: a session
started in `.claude/worktrees/agent-x`, its worktree removed, resumed from the repository's root and remembered the
conversation). As for native
worktrees, git sees `.claude/worktrees/` as untracked unless the repository ignores it.

Evidence (2026-11-14, Claude Code 2.1.322, `claude -p --permission-mode auto`): a probe mod's registered type called
with `isolation: "worktree"` got `agent.spawn` with no `cwd`, and its `turn.step` read
`…/repo/.claude/worktrees/agent-aed6cc934bfff75f5`, listed by `git worktree list` (locked by the agent); the engine
removed it after the unchanged run. Through the plugin, `lastdrop:scout` and a plain `general-purpose` haiku reroute
each wrote a file in the engine's worktree, which was kept and reported. The runner's own worktree code (Codex and
Antigravity runs, Claude Code's `--worktree` for Claude runners) stays for that fallback and for apps that ask it.

## Roles

A `lastdrop:` type is always a general agent: there is no way to combine an added agent with `Explore` or `Plan`
(`model` was how that was done, and the call can no longer be changed). A plain Claude reroute of `Explore` or `Plan`
still passes `role` to the runner, which runs it read-only however the permission mode is set, with a brief in its
instructions (search and report; return a step-by-step plan). Codex gets the read-only sandbox, Antigravity plan mode
(edits refused, and the judge told to allow only actions that read), and the Claude-runner providers (Claude accounts,
Z.ai, OpenRouter) `--disallowedTools Edit,Write,NotebookEdit`. A route saved with a role keeps it on a follow-up.

## Permission modes

The session's mode, as each provider runs it. A headless run can't ask anyone, so "ask" always becomes a check.

| Session mode | Claude accounts, Z.ai, OpenRouter | Codex | Antigravity |
| --- | --- | --- | --- |
| `default`, `auto` | `auto` | workspace-write + `auto_review` | accept-edits; commands: rules, read-only list, then judge |
| `acceptEdits` | `acceptEdits` | workspace-write | accept-edits; commands: rules, read-only list, then judge |
| `plan` (and Explore/Plan roles) | `plan` | read-only | plan; edits refused; commands: deny rules, read-only list, then judge (read-only) |
| `bypassPermissions` | `bypassPermissions` | full access | accept-edits; everything allowed |

On Antigravity `acceptEdits` works like `auto`: Claude Code would prompt for commands there, and nobody can be
asked, so they go through the same check.

## How commands are checked

Each provider judges its own agents. Nobody is asked and nothing is bypassed.

- **Claude accounts:** Claude Code's auto mode, with the user's rules.
- **Z.ai and OpenRouter:** Claude Code's client-side auto mode check (`CLAUDE_CODE_AUTO_MODE_SERVER=0`), with
  Anthropic's instructions and the user's rules, judged through the same endpoint by the provider's command judge
  (`CLAUDE_CODE_AUTO_MODE_MODEL`): `glm-5.3` on Z.ai and the agent's own model on OpenRouter unless the user chose
  another. Claude Code's own read-only commands (`ls`, `git status`, …) never reach this check. See Limits.
- **Codex:** its own `auto_review` reviewer. Requests it would still ask a person about are declined and reported.
- **Antigravity:** `agy acp` sends each action that needs approval as `session/request_permission` before it
  runs. lastdrop answers:
  1. The user's Claude Code rules for `Bash(...)`, from `~/.claude/settings.json` (or `$CLAUDE_CONFIG_DIR`),
     managed settings, and the project's `.claude/settings.json` and `.claude/settings.local.json` (the main
     checkout's too, from a worktree). A deny rule refuses; an ask rule refuses too, since nobody can be asked; an
     allow rule allows. Matching follows Claude Code's: exact, `*` anywhere, `:*` and a trailing ` *` (which also
     matches the bare command), wrappers like `timeout` and `nohup` stripped. Deny and ask match any part of a
     compound command, even inside `$(…)` or a loop. Allow needs every part covered and stays conservative: a
     substitution, subshell, redirect to a file, control flow, a leading `VAR=` or an exec wrapper is never
     allowed by a pattern and goes to the judge.
  2. Claude Code's read-only commands (`ReadOnlyCommands`), in every mode but bypass, plan included: allowed
     without the judge, logged as `Allowed as read-only (git status, ls): …`. The list was read from Claude Code
     2.1.319 (the commands it runs without any check) and checked black-box with its `dontAsk` mode (research I §9).
     Its per-command flag tables are transcribed as data (`ReadOnlyFlagTables.swift`, 1,747 flags); the rules
     around them are lastdrop's own code, never looser than Claude Code's. Plain readers (`ls`, `cat`, `head`, `wc`, `diff`,
     `stat`, `du`, …) take any arguments; `pwd`, `whoami` none; `echo`, `printf`, `cd`, `find` (no `-exec`,
     `-delete`, `-fprint…`), `jq` (no `-f`, `env`, `import`), `test` and `uniq` (flags only) have special rules;
     `git` (status, diff, log, show, blame, rev-parse, branch/tag listing, config `--get`, …), `gh` views,
     `docker logs/inspect`, `grep`, `rg`, `sed` (printing scripts only, no `-i`), `sort` (no `-o`), `xargs` (only
     `echo`, `printf`, `wc`, `grep`, `head`, `tail` as targets), `fd` (no `-x`), `tree` (no `-o`), `date` (no
     setting), `ps`, `lsof`, `ss`, `pgrep`, `netstat` and a few more take only the flags in Claude Code's tables,
     with its extra checks (git formats that run gpg, branch/tag listing only, `gh` values pointing at another
     host, `docker` daemon options, `tput` reset capabilities). Any `$`, backtick, redirect to a file (`2>&1` and `>/dev/null` are fine), subshell, brace, background
     `&`, control flow or leading `VAR=` makes the command not read-only; a compound command is read-only only
     when every part is. Any other flag goes to the judge.
  3. Otherwise the judge: Codex's open-source reviewer policy (`codex-rs/prompts/templates/guardian`, Apache 2.0,
     shipped in `Resources/CodexGuardian` with its licence and NOTICE), asked of the command judge (default
     `gemini-3.8-flash` at low effort) through the user's own Antigravity plan: `agy -p … --mode plan --disable-slash-commands --print-timeout 120s`
     from an empty folder. It reads the agent's role and task (the main agent's prompt, and follow-ups) as
     trusted, the agent's earlier tool calls (inputs only), and the planned action with its folder. Tool outputs
     and the agent's own words are left out. It answers `{risk_level, user_authorization, outcome, rationale}`;
     anything else, a failure or a timeout refuses. An identical action is judged once per run.

  The agent is told up front (ACP `_meta.antigravity.systemPrompt.append`) that its commands are reviewed, that a
  refusal is final, and to name in its report what it needed and why. `agy` ends its turn at a refusal, so
  lastdrop continues it with the reason (up to four times; the last asks for the report). Each decision is a live
  step and a `•` line in the agent's log. A check takes about 5 s (up to about 20 s).

**The command judge** is a per-provider setting: the **Command judge** row under the provider's accounts in
Settings → Accounts (shown while Agents in Claude Code is on), or `lastdrop --agents judge`. It is
stored in the catalog as `judges: {"zai": {"model": "glm-5.4"}, "antigravity": {"model": …, "effort": …}}`. Z.ai takes
a model from its list (default `glm-5.3`), OpenRouter a model id from its live list (default: each agent's own
model), Antigravity a model and effort from `agy`'s list (default `gemini-3.8-flash`, low). Both places check the
choice against the provider's live list like any agent model. A strong model is the default on purpose: on
2026-11-09 `glm-5.3-flash` allowed an SSH-key upload that `glm-5.3` blocked. A judge the provider doesn't serve is
never replaced: on Antigravity every command that needs the judge is refused with "the command judge … is not
available on this Antigravity account" (checked against the session's model list at start, and on `agy`'s own
error); on Z.ai and OpenRouter Claude Code's check fails with its own error. Older catalogs decode to the defaults,
an entry this version can't read is skipped, and the key is left out while empty. An older app rewriting the catalog
drops `judges` (its encoder doesn't know it), which puts the defaults back.

## Limits

- Main session only. A subagent gets no list of agent types at all (checked 2026-11-14, Claude Code 2.1.322: a
  native general-purpose subagent's loop raised no `agent_listing_delta`, and it reported no named types beside a
  main listing that had the probe's type), so it doesn't see the `lastdrop:` types. One that names a type anyway, in
  any form, is denied: "lastdrop's agents (lastdrop:x) run only from the main session."
- An added agent is always a general agent: it can't be combined with `Explore` or `Plan` (see Roles).
- On Claude-runner providers a read-only role still allows `Bash`, which can write. Native Explore has the same
  gap there; its restriction is by instruction.
- Provider permission requests nobody can answer are declined and reported (`Declined: … (needed approval)`), not
  asked.
- Antigravity's judge follows Codex's line, which is more permissive than Claude's auto mode: it allows read-only
  production SSH or killing a local process, which Claude blocks. Rules only cover `Bash(...)`: other requests
  (an edit outside the workspace, a fetch) always go to the judge. The judge starts one `agy` per check, on the
  user's plan.
- On Z.ai and OpenRouter, auto mode's server-side check can't run (the endpoint doesn't serve it), so the profile
  sets `CLAUDE_CODE_AUTO_MODE_SERVER=0`: Claude Code then judges actions with its own client-side check, with
  Anthropic's instructions and the user's rules, through the same endpoint. `CLAUDE_CODE_AUTO_MODE_MODEL` picks the
  judge: `glm-5.3` on Z.ai whatever the agent's model (`glm-5.3-flash` let an SSH-key upload through that `glm-5.3`
  blocked), the agent's own model on OpenRouter. Each judged action sends the whole policy to the provider and takes
  a few seconds. Claude Code made this check opt-in in 2.1.319; if a later version drops it, these agents' commands
  are refused again, as before. Evidence: research I, section 6.
- During an update, an older runner that is still running can strip `role` and the worktree fields from the
  ledger once, so a follow-up to a read-only agent started before the update may lose its read-only role. A brief,
  transient limit.
- A session started before the types keeps the text it froze (the bare list under its old header, rebuilt byte for
  byte as that version added it), so its replayed listing still names the `model` form; a call in that form is
  denied with the type to use. It gets the new paragraph after a compaction or `/clear`.

## Backends

Three runners cover five providers.

**1. Claude Code runner (exists).** Claude accounts as today, plus any Anthropic-compatible endpoint. A Claude
account's folder is only its sign-in. Main runs as plain `claude`. Another account runs with
`CLAUDE_SECURESTORAGE_CONFIG_DIR` naming its folder and `CLAUDE_CONFIG_DIR` naming `<folder>/profile`, which links
to everything in `~/.claude` and keeps only its own `.claude.json`. So settings, MCP servers (no `--mcp-config`
copy) and sessions (`~/.claude/projects`) are the user's own (see [claude-accounts.md](claude-accounts.md)).
Endpoints:
- Z.ai: `ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic`, `ANTHROPIC_AUTH_TOKEN=<Coding Plan API key>`,
  GLM model ids for every model role. Effort maps to GLM low/high/max. Needs a Coding Plan **API key**: the
  web session lastdrop keeps can't do inference. Ask for the key in Settings first; creating it through the
  console's private API comes later, if ever.
- OpenRouter: `ANTHROPIC_BASE_URL=https://openrouter.ai/api`, a regular (not management) key, model pinned to an
  OpenRouter id. Non-Claude models through Claude Code are unproven: mark each model "tested" only after a
  tracer run passes.
- Each provider gets its own `CLAUDE_CONFIG_DIR` (`~/.claude-accounts/zai`, …) with its own settings (no
  symlinked settings: they'd carry the user's env), and the runner scrubs every inherited `ANTHROPIC_*`
  variable before setting the provider's. Warm processes are keyed by provider and profile too: a live
  process can't change endpoint.
- New error classes: Z.ai business codes 1308/1310/1316–1321 (window exhausted) vs 1302/1305 (throttling);
  OpenRouter 402 (credit). Today's runner treats neither correctly.
- Free later: Kimi, DeepSeek, MiniMax use the same path.

**2. Codex runner (new).** `codex app-server --listen stdio://`, not `codex exec` (research B §1): it streams
items, lists models with their efforts, resumes and interrupts threads, and reports rate limits and typed
errors (`usageLimitExceeded`, …). Borrow from the bridge fork: JSON-RPC transport, lifecycle races, thread
persistence, wait logic (B §2, with the bugs to leave behind). Mapping:
- Items → transcript: commands → `Bash: …`, file changes, MCP calls, web search as tool rows; agent messages
  as text; the reasoning summary and plan as text. Final answer = the turn's final-phase message.
- Permission modes → sandbox + approval (default and auto → workspace-write + auto review, as a Claude
  agent's default becomes auto; acceptEdits → workspace-write; plan → read-only; bypass → full access).
  Antigravity: see Permission modes. Approval requests nobody can answer are declined, never left hanging.
- The user's MCP servers are translated from `~/.claude.json` into per-thread config overrides, except
  servers Codex already configures itself (`config/read`), which keep Codex's entry (LCU needs its Codex adapter); the role
  goes in `developerInstructions`; CLAUDE.md content is passed explicitly (Codex only reads AGENTS.md).
- Open in Terminal: `cd <cwd> && CODEX_HOME=<home> codex resume <threadId>` (stop the runner's copy first).
- Worktree isolation: lastdrop creates the worktree before `thread/start`, named as Claude Code names its own (see Worktrees).

**3. Antigravity: through the official `agy` CLI as a child process (the user decided to go ahead; no OAuth token reuse).**
lastdrop runs `agy acp` (Agent Client Protocol, JSON-RPC over stdio; research I §4 and §8):
- `initialize` (no file system or terminal: `agy` runs its tools itself), then `session/new` with the folder, or
  `session/resume` with the stored session for a follow-up. The ACP session id is the conversation id, so Open in
  Terminal's `agy --conversation <id>` opens the same conversation.
- The model and effort are one slug from `session/new`'s `availableModels` (`gemini-3.8-flash-low`), set with
  `session/set_model`; the mode with `session/set_mode` on every session, so a saved CLI preference never applies.
  An unknown slug is an `unavailable` model, for fallbacks.
- `session/update` gives the live steps and transcript (`tool_call`, `tool_call_update`, `agent_message_chunk`);
  the report is the turn's last text; tokens come from `session/prompt`'s `usage`.
- Permission requests: see How commands are checked. TaskStop ends `agy acp` and any judge still running.

Earlier it used `agy -p --output-format stream-json`, which can't answer a permission request headless. Policy:
Google's current FAQ calls wrapping `agy` in third-party coding agents unsupported on consumer plans,
its terms ban reusing the Antigravity OAuth, and it has banned accounts for this before. A Google forum
moderator said the opposite; that conflict is still open. Revisit once Google answers it in writing. Gemini
CLI no longer runs on consumer subscriptions. Separately: lastdrop's usage reading already uses Antigravity's
OAuth client and User-Agent, which those same terms cover. Worth reviewing.

## Order of work

1. Catalog + Settings list + listing and routing hooks, using the Claude account pool as the only
   provider. Proves registration, live edits, disable and errors with no new backend.
2. Z.ai and OpenRouter on the Claude Code runner (config dirs, env scrub, warm-pool keys, error classes).
3. Codex runner.
4. Antigravity, through `agy` (built; the policy question under Backends is still open).

Each backend ships after a tracer run passes: Read/Bash/Edit, warm start, continue, stop, transcript, Open in
Terminal, and a quota-exhausted error.
