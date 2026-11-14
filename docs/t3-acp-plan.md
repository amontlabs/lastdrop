# Plan: lastdrop as a T3 Code provider (ACP)

Status: 2026-11-14, revised after a review by Opus and one by Fable. Phase 1 built on branch `t3-acp`, see As built (it overrides the Build sections where they differ). Facts about T3 come from reading its source (clone of 2026-11-03,
`~/code/research/t3code`); nothing here was run.

## Goal

In T3 Code the user sets nothing up. lastdrop adds itself as one provider, "lastdrop", and every model lastdrop
knows (Claude on any account, Gemini/Argon on Antigravity, Codex models, GLM, OpenRouter) can be picked in T3's
model menu for a thread, and used by `delegate_task` for background children. Accounts, subscriptions, fallbacks
and limits stay in lastdrop.

## How T3 runs such a provider (facts)

- Settings entry, reloaded live (`serverSettings.ts:1240`):
  `providerInstances.lastdrop = {driver:"acpRegistry", enabled:true, displayName:"lastdrop",
  config:{source:"local", commandPath:<absolute path>, commandArgs:[...]}}`.
- One agent process and one ACP session per T3 thread. Order: `initialize` → `session/new` (or `session/load` /
  `session/resume` for an existing thread) → `session/set_config_option` (model, options) → `session/prompt`.
  `session/cancel` to stop; T3 waits up to 10 s for the prompt to answer `stopReason:"cancelled"`.
- Models: a probe spawns the agent at startup (`initialize` + `session/new`, then kills it; cached 15 min). Models
  come from a `category:"model"` select config option. Other config options become per-model options
  (`thought_level` → reasoning effort). Model switch inside a thread works when the session exposes that option.
- Idle: T3 kills the process after 30 idle minutes; the next message opens `session/load` (needs
  `loadSession:true`) with the stored session id. Load failure fails the next turn (no summary fallback).
- Steering: a plain message during a turn is queued; an explicit steer is cancel + a new `session/prompt`.
- Renders: `agent_message_chunk`, `agent_thought_chunk`, `tool_call`/`tool_call_update` (with `kind`), `plan`,
  `usage_update {used,size,cost}` (context display), `notice`, `available_commands_update`.
- MCP: T3 passes its own `t3-code` MCP server in `session/new`/`load` (stdio bridge command, or over ACP when the
  agent advertises `mcpCapabilities.acp`), and sets `T3_ACP_MCP_ENDPOINT`/`_AUTHORIZATION` in the env. That is how a
  non-Claude main thread gets `delegate_task`, `t3_thread_*`, previews.
- Permissions: T3 does not tell a generic agent its runtime mode. It answers `session/request_permission` by mode:
  read/search/think always allowed; `approval-required` asks the user; `auto-accept-edits` allows edits, asks
  others; `auto`/`full-access` allow all. A missing `kind` counts as `other`.
- `delegate_task` accepts `target.providerInstanceId:"lastdrop"` + any listed model; `orchestrator_capabilities`
  lists the instance with its models (8 shown unless custom/favorite/inherited) and `canRunChildTask`.
- Missing for a generic ACP thread vs T3's Claude provider: idle compaction, rate-limit display, per-turn
  tokens/cost/cache TTL, active steering, subagent rows, fork-from-turn, text generation (titles), and rollback
  (T3 restores files and opens a fresh `session/new`: the agent loses the conversation).

## Scope by phase

**Phase 1 — background children (replaces the tag design; same behaviour as today).** Every `delegate_task`
child that lastdrop takes today runs in a lastdrop ACP thread instead, through `AgentRun`: catalog agents (build,
review, judge, scout…, Claude-backed ones included) and plain Claude models (`opus`, `sonnet`, none). Same picking
(smallest plan first), fallbacks, mid-run handover at a limit and `moved` notice as Agent calls. What the model calls
doesn't change: it still sends `delegate_task` with `target.model: "flash"` (or no model), and the plugin's
`tool.call` sets `target.providerInstanceId: "lastdrop"` (today it removes the model and adds the tag). Same case as
today when lastdrop has no room: a plain call goes to T3's Claude provider unchanged, an added model is denied.
The whole tag design goes: the hidden tag, the steer cursor, the `session.compact` skip, the answer rewrites
(`rewriteT3`, `addedModels`), and the empty Claude host process per child. Agent calls (foreground) are unchanged.

**Phase 2 — non-Claude main threads.** The user picks e.g. "Gemini 3.8 Pro" or "GLM 5.3" for a thread in T3's
menu. The thread gets T3's tools through the MCP server T3 passes. **Blocked on rollback, and only T3 can fix it**: T3 rolls
an ACP thread back by restoring files and opening a bare fresh session (`adapter.ts:9073-9105`) with no thread id,
`_meta` or history, so the agent loses the conversation silently and can't even say so. Ask T3 (Ideas discussion)
for a full-thread handoff after an ACP rollback, or the thread id in `_meta`. Phase 2 also advertises lastdrop's
permission modes (auto, accept-edits, plan, bypass) as ACP session modes, so T3 shows the mode and its Plan toggle
maps to the read-only role (check T3's mode ceiling, `adapter.ts:7195-7204`), and needs an allow path for T3's own
tools in Antigravity's judge (its rules cover only Bash; ~5 s per call, may refuse `delegate_task`).

**Not planned — Claude main threads through lastdrop.** They stay on T3's Claude provider with lastdrop's launcher
(account choice, relay, reaper), which lastdrop sets up too. Moving them would lose idle compaction (Claude-only,
`IdleCompactionService.ts:40-44`), rate-limit display, active steering, subagent rows and rollback, for no gain.

## Build

1. **Entry point.** `lastdrop --acp` checked as `argv[1]` before the `contains` chain (like `--claude-thread`),
   plus a wrapper `support/bin/lastdrop-acp` so `commandPath` is a stable absolute path across app updates.
2. **ACP server (`Sources/LastDrop/ACP/ACPServer.swift`).** Line-delimited JSON-RPC on stdin/stdout, reusing
   `ACPClient`'s framing and `Reply`/`Payload`; requests to T3 with id correlation. Logs to stderr +
   `subagents.log`, never stdout.
   - `initialize`: protocol v1, `sessionCapabilities.resume` (not `loadSession`, which also tells T3 it can rebuild
     a snapshot by replay, `adapter.ts:784`), `promptCapabilities.image` per backend (start: false), MCP over stdio
     only.
   - **The probe.** T3 runs `initialize` + `session/new` and kills the process, every 15 minutes, on each refresh and
     on each `provider_unavailable` retry. So `session/new` only returns an id and the `configOptions`: it records
     nothing and starts nothing until the first `session/prompt`. Send `available_commands_update` at once or
     never (T3 waits 500 ms for it, `probe.ts:48`).
   - `session/new` answer, from the catalog file alone (no provider calls; a failed probe isn't cached and reruns):
     `configOptions` with a `model` select of every enabled catalog agent plus `fable`, `opus`, `sonnet`, `haiku`,
     id = catalog name, label from its description/summary. No `thought_level` in Phase 1: T3 gives every model one shared option set, and catalog
     agents carry their effort.
   - The ACP session id is minted by lastdrop and is never a Claude session id; backend sessions keep the
     per-account rules (forks get new ids).
   - First `session/prompt` of a session: write the `ACPSessions` entry (T3 cwd, model, backend session id,
     account, MCP servers).
   - `session/resume`: look the session up and answer. A stale or missing entry must fail clearly, since T3 then
     starts a new session and fails the next turn (`adapter.ts:7020-7036`, `7062`).
   - `session/set_config_option` / `session/set_model`: change the model for the next turn. A change on a non-empty
     session hands the work over (`handoverPrompt`) with a visible notice.
   - `session/prompt`: run one turn (below), stream updates, answer `stopReason` `end_turn` / `cancelled` /
     `refusal`; errors as JSON-RPC errors with a readable message.
   - `session/cancel`: stop the running backend the way `--agent-stop` does, answer `cancelled` within 10 s.
   - `session/close`: T3's Force stop after 10 s (`AcpSessionRuntime.ts:2520`); kill the backend's process group.
3. **Turn engine: `AgentRun` as a library.** Today `--agent-run` is one process per turn reading one JSON request.
   Split its core (`run`, `runDefined`, fallbacks, retries, registry writes) from the stdin/stdout CLI wrapper so
   the ACP process calls it in-process per prompt, with `resume` on every turn after the first. `--agent-run` keeps
   working for the plugin (Agent tool). Main threads (Phase 2) follow the thread rules for any Claude-backed
   endpoint run.
4. **Events → ACP updates.** Map `AgentEvents`: `step`/`item(tool)` → `tool_call` + `tool_call_update` with a real
   `kind` (read/edit/delete/move/execute/search/fetch/think/other) and status; `item(text)` →
   `agent_message_chunk`; `moved` → `notice` ("Moved to … : limit reached"); final usage → `usage_update` before
   the prompt answers. Text deltas come after Phase 1 (Antigravity forwards chunks instead of coalescing; Codex
   item deltas; endpoint runs `--include-partial-messages`).
5. **MCP pass-through.** Give each backend the stdio MCP servers from `session/new`: Antigravity `session/new
   mcpServers`, Codex its config override, Z.ai/OpenRouter Claude Code `--mcp-config`.
6. **Permissions: one owner, lastdrop.** Keep lastdrop's checks (Antigravity judge, Codex auto_review, endpoint
   auto mode) and forward nothing to T3. Forwarding refusals would turn them into yeses in T3's `auto` and
   `full-access` modes (`clientPolicy.ts:172-181`), and T3's approval mode can't be honoured anyway, since T3 doesn't
   tell a generic agent its mode. T3's approval setting doesn't apply to lastdrop threads; say so in the docs. The
   `Declined:` report line stays.
7. **Model list refresh.** `delegate_task` checks T3's live published model list
   (`OrchestratorMcpService.ts:1423-1431`), which every session start and every `config_option_update` republishes
   and which overrides later probes. So on a catalog change every live lastdrop ACP process sends
   `config_option_update` with the new list. No outside T3 call refreshes it (`server.refreshProviders` returns the
   cached probe), and rewriting the instance's config would rebuild it and close its threads. Remaining gap: with no
   live lastdrop session, a just-added model is refused until one starts (document; or ask T3 for cache
   invalidation on this driver).
8. **T3 setup (`T3Settings`).** The existing T3 switch also writes the `lastdrop` instance (same atomic one-key
   write, backup, undo). Turning off sets `enabled:false` rather than removing it (only changed entries rebuild).
9. **Plugin changes.** `tool.call` on `delegate_task` keeps the model's call shape and only adds
   `target.providerInstanceId: "lastdrop"` (and the run's id) for the children it takes today; the listing line stays
   as it is. Answers need no rewrite: T3 names the child's real model. Remove the parent-side tag path; keep the
   child-side tag reader for one release, so follow-ups to children started before the update still run through
   lastdrop.
10. **Health.** `canRunChildTask` is false while the instance has any constraint (`OrchestratorMcpService.ts:2322`),
    so a failing probe (after an app update, say) blocks every added-model child. Add a doctor check in the app,
    and gate the feature on T3 versions it was tested with; add a contract test against a fake T3 client.
11. **Tests first.** Add an override for `LastDropPaths.support` (today a `static let`; tests touch the real
    `agent-catalog.json` and `agents/`). ACP server tests with a fake T3 client (template:
    `AntigravityBackendTests.fakeAgent`): probe (records nothing), new/resume/prompt/cancel/close/steer,
    set_config_option, `usage_update` before the answer, no stdout noise.

## Live checks (T3 + real accounts)

1. Instance shows healthy; the model menu lists lastdrop's models with labels and efforts.
2. Phase 1: Claude thread → `delegate_task` flash in background → runs on Antigravity, T3 shows "flash" natively;
   `task_status`; steer mid-turn; stop and Force stop; follow-up `t3_thread_send` resumes the same run; a model
   added in lastdrop is usable at once while a lastdrop thread is alive.
3. Phase 2: new thread on Gemini → edits code, calls `delegate_task` from inside, sees T3 tools; approval mode asks
   in lastdrop's mode (no T3 approval prompts); idle 30 min → next message resumes (`session/resume`); model switch mid-thread gets a handover notice.
4. A limit mid-turn on an added model → the next model in its chain continues with a visible notice.
5. Stats count the turns (backend transcripts), `subagents.json` records them.

## Open questions

- Rollback (blocks Phase 2): needs a T3 change (handoff or thread id); nothing on lastdrop's side can fix it.
- Cost of one lastdrop process per thread: T3 keeps it 30 idle minutes, and up to 4 hours with background work
  (`ProviderSessionManager.ts:57-58`).
- Switching a thread between T3's Claude provider and lastdrop goes through T3's provider switch (a summary
  handoff), not `set_config_option`.
- Text deltas, images and MCP over ACP: after Phase 1.
- T3's per-prompt `<t3_code_instructions>` wrapper and `<runtime_info>` block go to every model: fine for
  Gemini/GLM? Check token cost and whether they confuse non-Claude models.
- Does T3 render a child's own tool rows inside the parent (subagent rows) for ACP children? Static
  `supportsSubagents:false` suggests no; the child thread itself shows them.
- ACP-transport MCP vs stdio bridge: which is simpler for each backend?
- Text generation stays on whatever T3 has (today Codex `gpt-6-luna`).

## Build contract for Phase 1 (2026-11-14, overrides the Build section where they differ)

Rule: nothing that works today may change or break. The runner, Agent calls, routing, accounts and fallbacks are
untouched; the ACP path is only a new way for T3 to hand lastdrop a child it already takes today.

- **No runner refactor.** The ACP server runs each turn by spawning `lastdrop --agent-run` with the same JSON request
  the plugin's `delegatedTurn` sends today (prompt, description, subagentType, model or agent, effort, cwd,
  permissionMode, id, `resume` after the first turn), reading the same stdout lines (`started`, `step`, `item`,
  `moved`, `tick`, `result`, `no_room`, `native`, `error`), and stopping with `lastdrop --agent-stop <id>`. Build item
  3 (AgentRun as a library) is dropped.
- **The tag stays as the carrier.** The plugin still tags the task exactly as today (`<!-- lastdrop {id, agent|model,
  effort, description} -->`); additionally it sets `target.providerInstanceId: "lastdrop"` and `target.model` to the
  agent/model name. The ACP server reads the run (id, effort, description) from the tag in the first prompt, and
  the prompt text the runner gets must be exactly what `delegatedTurn` gives it today (the task without the tag; T3's
  ACP wrapper `<t3_code_instructions>…</t3_code_instructions><user_request>…</user_request>` and the trailing
  `<runtime_info>`/PR-linking block are not part of it, since a T3 Claude child gets those as system prompt, which the
  runner never saw). Follow-up prompts: the new user text only.
- **Fallback = today's path.** If `delegate_task` with the lastdrop instance answers an error (T3 too old, instance
  missing, disabled, unhealthy, model unavailable: nothing was created), the plugin calls it once more exactly as it
  does today (tag, model removed, T3's Claude instance). The child-side tag reader (`delegatedTurn`) and the T3 answer
  rewrites stay for that path. For lastdrop-instance children the answer rewrites are skipped (T3 already names the
  model and instance).
- **Names.** T3 instance id `lastdrop`, driver `acpRegistry`, displayName `lastdrop`, config `{source:"local",
  commandPath:"<support>/bin/lastdrop-acp", commandArgs:[]}`. Wrapper `~/Library/Application
  Support/lastdrop/bin/lastdrop-acp` runs `exec "<app binary>" --acp "$@"`, written the way the `claude-thread`
  wrapper is. `lastdrop --acp` is matched as `argv[1]`, before the `contains` chain.
- **Models offered** (`session/new` configOptions `model` select, from the catalog file only): every enabled catalog
  agent by name, plus `fable`, `opus`, `sonnet`, `haiku`. No `thought_level`.
- **Permission mode** passed to the runner: whatever `delegatedTurn` passes today for a child (read it there).

## As built (branch `t3-acp`, 2026-11-14, not merged, not tried live)

Revised the same day: since 2026-11-14 Claude Code's auto mode refuses any call a hook changed ("a hook changed
this call's input after auto mode reviewed it"), and the user's T3 threads run in auto mode. The tag, the model
removal and the `providerInstanceId` the plugin added were all changes, so the plugin no longer changes a
`delegate_task` call at all. The build contract's "the tag stays as the carrier" and "fallback = today's path" are
replaced by this:

- **How the plugin knows the instance is set up.** `lastdrop --agent-catalog` (read before each prompt) adds
  `t3Instance: true` when `T3Settings.acpStatus()` is `ready`: `providerInstances.lastdrop` in T3's settings is ours
  (driver `acpRegistry`, local command), enabled, and its wrapper is there. An older app sends no field: not set up.
  Not chosen: reading `~/.t3/userdata/settings.json` with `$.fs` (allowed, any absolute path), since the app already
  owns that file's path, its overrides and what counts as ours.
- **What the model is told.** In T3 with the instance set up, the listing paragraph says: Agent with the `lastdrop:`
  types for foreground work; for background work on an added agent or on Claude, `delegate_task` with `target:
  { providerInstanceId: "lastdrop", model: "<agent name, or fable/opus/sonnet/haiku>" }`. It is frozen per session
  like the rest of the paragraph, so a session that started before the instance was set up keeps the earlier text
  (the deny below then tells it the form).
- **The plugin's `delegate_task` hook.** A call on the `lastdrop` instance goes to T3 unchanged, with no room check
  (the server does it). A plain Claude child (no model, or a Claude model, on T3's Claude instance) goes unchanged:
  an ordinary T3 Claude thread, on the account lastdrop's thread launcher picks. An added agent on T3's Claude
  instance is denied, naming the instance form. Other instances, other providers' models and other machines are
  left to T3, as before.
- **Where the tag path survives.** Only when the instance is not set up and the session is not in auto mode (the
  permission mode from the last classic hook event; unknown counts as not auto, as before). There, a change still
  runs, so the old path stays whole: room check, tag, added model removed from `target`, answer rewrites. In auto
  mode without the instance, a plain child goes unchanged and an added agent is denied, pointing to the Agent type.
  The child-side tag reader (`delegatedTurn`) and the answer rewrites stay, for that path and for children started
  before the update. The first try on the instance with a fallback to the tagged call, and its 10-minute skip, are
  gone: both were a changed call.
- **The ACP server.** An untagged first prompt now runs: a new run id (`acp-<uuid>`), the session's model as the
  agent (a catalog agent) or the Claude model (`model`), no effort and no description. Before the runner starts, it
  asks `lastdrop --agent-route` with the request the plugin's `admission` sends (the turn's request without the id);
  `no_room` fails the prompt with the plugin's deny text ("lastdrop found nowhere to run flash."; for a Claude model,
  the existing plain-child message), an `error` line fails it with its text. A model lastdrop doesn't have fails
  clearly. The entry records `checksRoom`, so a first prompt cancelled before the run started is checked again;
  follow-ups (`resume`) are not. The prompt the runner gets is the task as T3 hands it to the child (T3's own role
  line, "Act as the review sub-agent…", included, as on the tag path), without T3's wrapper and runtime blocks.
  Tagged first prompts run exactly as before.
- **Permission mode of an untagged child.** T3 tells a generic ACP agent no mode, and no tag carries the parent's.
  T3's Plan heading still runs a turn as `plan`; otherwise the request has no `permissionMode`, which the runner maps
  to auto. So a child of a full-access (bypass) thread now runs in auto mode, where lastdrop's checks apply, and a
  child of an `acceptEdits` thread runs looser than its parent did.
- **What an untagged child drops.** The call's `title` (no description). (`target.options` effort: see "Model
  names and effort" below.)

Review fixes (Fable, same day):

- **A refused instance.** Settings can say ready while T3 refuses the instance (probe failing, `canRunChildTask`
  false). The plugin reads the answer of each call on the instance; one T3 refused before creating anything (the
  `T3_REFUSED_TARGET` errors) stamps it for 10 minutes, as before. Meanwhile the instance counts as not set up:
  the listing (if frozen then) doesn't name it, added agents take the tag path outside auto mode, and in auto mode
  they are denied pointing to the Agent type. T3's error gets a note saying which. No loop between the deny and
  T3's refusal.
- **Plain Claude children.** With the instance usable and room, a plain call is denied once with the instance form
  (`lastdrop has room for opus: …`; no model names the parent's model by family), so lastdrop's picking and mid-run
  handover apply. The same call (session + task) sent again goes unchanged: a child the server then finds no room
  for can always fall back to T3's Claude instance. Calls the instance can't carry (options, own modes, a full
  model id) go unchanged.
- **Listing.** The instance clause leads the paragraph and stands alone with an empty catalog.
- **Unknown mode.** The mod API has no live permission mode, only classic events. Unknown (after a reload) counts as
  auto for the tag branch: a plain child goes unchanged, an added agent is denied with its Agent type.
- **Model changes.** Before the run starts, an untagged session takes a new model (agent or Claude model again);
  after, a different model is refused with -32602 "This run stays on <x>; start a new task for <y>." The same model
  again is accepted (T3 sets it when it opens a thread).
- **Room check.** Ended after 30 s ("didn't answer") or at once on a cancel, which answers `cancelled`.
- **Threads the user starts on the provider (open).** T3's source (2026-11-03 clone) gives an ACP agent no sign of a
  delegated child: `session/new` is `{cwd, mcpServers, additionalDirectories}` (`AcpSessionRuntime.ts`), the
  prompt wrapper (`orchestrationInstructions.ts`) is the same for both, and the child flag
  (`lineage.relationshipToParent === "subagent"`, `ProviderSessionManager.ts` prepareMcpSession) only reaches T3's
  MCP session registry. Asking T3's MCP endpoint about the thread from the server would be the only check, and it
  isn't built. So a user-started thread runs like a child: no T3 tools, and a rollback (a bare `session/new`)
  starts a new run without the conversation. Documented in docs/agents.md and the app's T3 setting
  ("for background tasks"). Ask T3 for a child marker in `session/new` `_meta`, with the Phase 2 rollback request.
Plain Claude children, revised again (same day): the deny-once above is gone (the user rejected it: a refused call
and the prompt written twice in the parent's context). A plain Claude child now goes to T3 unchanged in every mode,
and its run rides beside the call instead of in it:

- **Parent.** On T3's Claude instance, with no model or a Claude one (alias or full id), and room (`--agent-route`,
  as the tag path asked): before `next(e)` the plugin writes a note with what the tag carried (`run`: id, model,
  effort, description, permission mode; no agent), the parent's `T3CODE_THREAD_ID`, the task as given, the parent's
  model and `createdAt`. T3 answering `isError`, a deny, or a throw drops the note (only if unclaimed: a child that
  claimed it keeps it). No room, or a note that can't be written: the call still goes unchanged, an ordinary T3
  Claude thread. The tag is no longer written for plain children in any mode; it stays for added agents outside auto
  mode without the instance, and for apps without notes (below). `untag` still reads tagged children.
- **Ledger.** `lastdrop --delegate-note` (`DelegateNotes.swift`): one JSON request on stdin (`put`, `drop`, `list`
  with the thread, `claim` id+thread), one line out. The file is `<support>/delegate-notes.json`, every change under
  `delegate-notes.lock` (flock) and written atomically, so it is shared by every account profile (parent and child may
  run under different `CLAUDE_CONFIG_DIR`s; `$.store` isn't shared). Unclaimed notes go after 10 minutes (the plugin
  checks `createdAt` too), claimed ones after 30 days, at most 500. A claim binds once; the same thread claiming again
  gets it back. `--agent-catalog` says `delegateNotes: true`; an older app (which would open its window for an
  unknown flag) gets the earlier behaviour: plain children unchanged in auto mode, tagged otherwise.
- **Child.** `delegatedChild` without a tag, in T3 (`T3CODE_THREAD_ID` set): the binding from `$.store`
  (`delegated-thread:<thread>`), else `list` (a note bound to this thread: a follow-up in a later process, maybe on
  another account). Only a first turn (no assistant message yet) claims: an open, unexpired note whose task ends the
  joined first user blocks (whole, or after a line break: T3's "Act as the … sub-agent" line before it, a merged steer
  after it, the same blocks loop as the tag). Among several, the one whose model family is the child's `e.model`
  (no model: the parent's), then the oldest. From there it is the tag path's code: same run, `delegated:<id>` state,
  resume, hand-back. One `list` per thread process; a result of none is kept in memory.
- **Lineage.** The child asks T3 for its own thread with `$.mcp.call("t3-code", "t3_thread_read", { threadId, limit:
  1, maxCharsPerItem: 1 })` (a read: only a caller reading its own child's result marks it delivered), up to 3 times
  500 ms apart since T3's tools may still be connecting. `relationshipToParent: "subagent"`: only notes whose
  `parentThread` is its `parentThreadId`. Anything else (a thread the user started, a fork): nothing is claimed, so
  a user thread that shares the text keeps its own model. T3 not answering: claim only when exactly one note matches.
- **What the model reads.** The T3 listing paragraph with the instance set up now says Claude models use delegate_task
  as usual (lastdrop picks the account) and added agents need `providerInstanceId: "lastdrop"`. Paragraphs frozen
  earlier keep their bytes (any frozen text starting "Background work in T3 Code" is ours). `delegate_task`'s own
  description (`tool.describe`) gains one sentence naming the added agents and the instance while the instance is set
  up and agents exist; built from the catalog's names only, invalidated when that sentence changes.
- **The ACP server** still runs plain Claude models on the instance; nothing points there any more.
- Not tried in a live T3 yet: the `$.mcp.call` server name and timing at a child's first turn, and T3's exact first
  message for a Claude child, come from T3's source and the tag path's evidence.

Review fixes (Fable, same day, on the notes):

- Any lastdrop failure on the plain path (catalog read, room check, runner) sends the call to T3 unchanged, never a deny.
- A binding counts only while the session's first user blocks still end with the noted task (same match as the
  claim); a fresh session T3 starts in the thread (a handoff) runs on its own model, like a tagged child that lost
  its tag.
- The plugin reads `delegate-notes.json` itself without the lock (the catalog's `delegateNotesFile`; the app always
  replaces the file whole), so an ordinary T3 thread starts no process; `--delegate-note list` is the fallback. The
  first look's outcome, a failure or an unanswered lineage included, is kept for the process.
- After T3 answers, the parent records the child thread (`expect`): only that thread may claim the note, without
  asking T3 its lineage. An answer naming a thread another note has is a replayed task, and its note is dropped; one
  naming no child thread here (another machine) drops the note too. Identical tasks still go oldest first.
- Claimed notes expire 30 days after their last use (`usedAt`, refreshed once per child process); the 500 cap keeps
  the most recently used.
- `t3_thread_read` blocks that aren't JSON are skipped. The description's agent names are sorted, and a description
  given while the catalog couldn't be read is invalidated once it can.

Live check (2026-11-14, dev build): a plain haiku child was noted, claimed, bound and answered "alpha" on claude-2.
Its `t3_thread_send` follow-up failed with "The child got a new turn without a text message.": lastdrop's runner
answers in a Claude Code session of its own, which inherits the child's environment (`T3CODE_THREAD_ID`) and gets
the same task, so the plugin there matched the child's binding and read the child's state (`sent` already counting
the follow-up). The tag path never had this (the runner's session gets the task without the tag). Fix: `noted`
ignores sessions with `LASTDROP_SUBAGENT` (the runner sets it on every session it starts).

- `CommandJudgeTests` hang now and then in a full `swift test` on `main` too (unrelated).
  `AntigravityBackendTests.testSIGTERMEndsTheReportedChildPromptly` can fail under heavy load.

Model names and effort (same day):

- **Order and names.** Claude's models first, then the catalog's enabled agents in its order. Values unchanged
  (`fable`… and agent names); names "Claude Fable 5.2", "Claude Opus 5.5", "Claude Sonnet 5.5", "Claude Haiku 5.5",
  and "<agent> · <first provider> <model name>" ("build · Antigravity Claude Sonnet 5.5"; a Claude agent reads
  "judge · Claude Fable 5.2"). Versions live once, in `ClaudeBackend.aliases`; model names come from
  `UsagePrice.displayName` (GLM ids stay raw). Description: the agent's description, then its chain summary. Cut at
  T3's 160/1024.
- **Effort.** A `thought_level` select (id `effort`) is published while the selected model takes an effort from the
  caller: Claude models always (low…max, Claude Code takes every level on every alias), an agent only when its
  `effort` is nil (Settings' "Auto"), with its provider's levels known without asking it (`callerEfforts`: Z.ai
  low/high/max, others low…max; Codex/OpenRouter/Antigravity models may take fewer, and a level a model lacks fails
  that attempt with the provider's message). First value `auto` = no effort, the default. The probe's `sonnet` has
  it, so `delegate_task`'s `target.options` effort passes T3's check. A model change sends `config_option_update`
  (option added, removed or changed). `set_config_option effort`: an unknown level is refused; on a fixed-effort
  agent any value is accepted and ignored; before the run starts it is taken (an effort the next model lacks falls
  back to auto); after, only the same value is accepted, since the runner resumes a run at its first effort. The
  untagged run's request carries it (`effort`); tagged runs keep the tag's. A fixed agent never gets one (a request
  effort would override the agent's own in `AgentRun.effort`).
- **Listing.** New sessions read that `target.options [{id:"effort"}]` works for Claude models and agents without a
  fixed effort; paragraphs frozen with "no options" keep their bytes. The `delegate_task` supplement says the same.
- Not tried live: T3 sending the effort before or after the model, and skipping a value the live option lacks.
