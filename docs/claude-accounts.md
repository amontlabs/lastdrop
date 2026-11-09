# Several Claude accounts, with automatic failover for Claude Code

Status: **replaced twice.** The relay described here was built, then removed; so was the next design, one
Claude app copy per account. Current: [subagents on accounts with
room](#current-design-2026-10-27-subagents-on-accounts-with-room). The rest of this document is the research
and the earlier designs, kept for reference; their code is in git history.

## T3 Code threads on accounts with room (2026-11-09)

lastdrop chooses the account for each T3 Code thread too, not only for subagents. T3's Claude provider has
a **Binary path** setting. It points to `~/Library/Application Support/lastdrop/bin/claude-thread`, a
wrapper that runs `lastdrop --claude-thread <T3's arguments>`. The launcher (`ThreadLauncher`) chooses the
account, sets `CLAUDE_CONFIG_DIR` to it (none for Main), and `execve`s the real `claude`. T3 keeps every
Claude-only feature, because it still talks to Claude Code. A generic ACP provider would have lost idle
compaction, limit display, forks and steering.

**When it chooses.** T3 starts a thread's Claude on a new thread, after Stop, and after 30 idle minutes
(`ProviderSessionManager`, T3 0.1.7). Each start asks one question: *is this conversation's cache still warm
on its account, and does that account have room?* If yes, the thread stays. If not, it goes to the best account:
- A new thread (`--session-id`) goes to the best account.
- A cold one (last answer more than 55 minutes ago; the cache lasts an hour on subscriptions) may move.
- A just-compacted one may move. T3's idle compaction runs about two minutes before the cache expires, so it
  stays and uses the warm cache, and the next start moves it.
- `--resume-session-at` never moves: its message ids belong to the conversation's own lineage.

**Best account for a thread.** `SubagentAccounts.pickForThread` gives the most room in Pro-sized windows:
`min(5h size × 5h left, weekly size × weekly left)`. `PlanSize`: Pro 1/1, Max 5x 5/5, Max 20x 20/10. Only
accounts below 80% of their 5-hour window and 95% of their week are considered, so a long conversation
doesn't start on an account's last points; if none is, the roomiest account not at a limit. Subagents pick
differently (`SubagentAccounts.pick`): the smallest plan with room first, never the session's own account,
because they're short and move by themselves at a limit.

**Moving keeps no session id across accounts.** Every request carries the session id
(`x-claude-code-session-id`, `metadata.user_id.session_id`). A thread that moves continues as
`--resume <current> --fork-session --session-id <new>`, so each account only sees its own ids. T3 keeps its
own id forever and ignores the one Claude reports, so `SessionLedger` maps T3's id to the conversation it
continues in now. A subagent that moves at its limit forks the same way (`AgentRun.carryOn`).

**One conversations folder.** Before resuming, T3 checks that `<its id>.jsonl` exists in `~/.claude/projects`.
So every account folder's `projects` is now a link to `~/.claude/projects` (`ClaudeSignIn.shareConversations`,
run at launch). A folder's old conversations are kept as `projects-before-sharing`. Stats used to tell the
account by folder; it now reads it from `SessionLedger` (`~/Library/Application Support/lastdrop/sessions.json`),
and skips a fork's lines from before `forkedAt`, which its parent counts.

**At a limit.** The launcher records each thread's process (`SessionLedger.live`). Every 20 seconds the app
(`ThreadReaper`) looks at those threads' transcripts. When one ends with a usage-limit notice, the app marks the
account full, ends that process with SIGTERM, and posts a notification. The notice is written when the turn
ends, so the process is between turns, which T3 handles cleanly. The next message starts Claude again, and the
launcher moves the thread. Waiting for the reset is just not sending.

**Known limit.** A fork gives every copied message a new id. Rewinding or forking a moved thread from a turn
before the move may not find that turn.

Checked: T3's handling of the binary path, process exits and session ids, read in its source (0.1.7). Live,
with Haiku: `--resume X --fork-session --session-id N` on another account continues the conversation under
exactly `N`, and the launcher starts and resumes a thread. A live move between accounts is still to check once
the shared folder is in place.

## Current design (2026-10-27): subagents on accounts with room

The app copies below were also replaced. Each account is now a Claude Code sign-in (`CLAUDE_CONFIG_DIR`
= `~/.claude-accounts/<name>`). lastdrop's plugin keeps Claude Code's built-in `Agent` tool and native
subagents. When another account has room (never the session's own, both thresholds respected, most room
first), `lastdrop --agent-route` admits the call without starting a model or claiming a warm process.
The engine still checks the call and creates its own task through `agent.spawn`'s `next(e)`. A separate
`turn.step` hook runs `lastdrop --agent-run` inside that native task and serves the remote report without
calling the session's model client. Added agents (the Agent tool's `model: "<name>"`) use the same adapter.

Claude Code owns foreground/background transitions, ctrl+b, notifications, waiting before print-mode
exit, `ListAgents`, `TaskStop` and `SendMessage`. There are no plugin replacements for those tools or
notifications. A native follow-up arrives as a new turn at step 0; the plugin reads its new text through
`$.session.messages({ agentId, as: 'api' })` and the pinned `agent.spawn.resume` prompt, then resumes the
remote session under the same native id, account, folder, type and effort. Claude Code queues messages
received during remote work and starts the next native turn with them. Routes persist through `$.store`
so native resumes and worker reloads keep
using the remote backend. `--resume` alone restores neither the remote agent type nor its effort; the
runner still supplies both. Worktree isolation belongs to the remote worker, so the native task's shell
creates no second, unused worktree.

No-room calls remain built-in, as do ordinary forks, teammates, workflow agents, remote agents and calls
from subagents. Each subagent already running on an account counts as 10 points of its usage, so a burst
of parallel calls doesn't all land on one account's last points.

**Usage limits never reach the calling agent** (changed 2026-10-28, after six parallel Opus judges sent to
Pro at 50% ran it to its session limit and each reported `You've hit your session limit` to the caller,
which then asked the user whether to wait). If an account reaches its limit before any work, the agent
starts again on the next account. If it reaches its limit partway through, the agent's Claude Code session
is copied to the next account's folder (`projects/<folder>/<session>.jsonl` and its side files, without
the trailing limit notice) and continued there with `--resume` and a neutral "continue" prompt. A follow-up
(SendMessage) works the same way. The next account is the other account with the most room. If none
has room, it's the session's own account, which is where a built-in subagent would have run. The same
applies when the room an agent was admitted for is gone by the time it starts. Only when every account,
the session's own included, is at its limit does the caller get the limit as an error. The pane shows each
move. `LASTDROP_LIVE_FAILOVER=1 swift test --filter testLiveAnAgentAtItsLimit` checks a move between
two real accounts with Haiku.

Other failures never fall back: admission failures are Agent errors, and execution failures are explicit
`lastdrop agent failed: ...` reports with a failed pane entry. The native task may finish normally while
carrying that failure report.
The runner validates Claude Code's init before announcing `started`, and checks that the native id is
preserved. `lastdrop --agent-selftest` retains the ready-process start, resume and stop checks once per
Claude Code version. The pane, status line, warm pool and remote logs remain lastdrop's.

Earlier versions denied the native spawn, fabricated `async_launched` and submitted notifications through
`$.prompt.submit`; print runs could exit before those reports arrived. Commit `2867474` then rejected all
non-interactive hosts. That was incorrect for SDK hosts, including the desktop app, and `911d42a` reverts
it. There is no routing decision based on `isInteractive`. The still earlier MCP look-alike tools also
remain removed. See the [native task adapter](#native-task-adapter-2026-10-27) for the replacement's evidence.

Startup: a cold `claude -p` on the Pro account took 11.2 s before doing anything (12.5 s with the MCP
servers), the agent's own work 4 s. A process started with `--input-format stream-json` waits for its
prompt; given one 15 s later, it took its first step after 1.8 s. So the plugin asks the app to start one
(`lastdrop --agent-warm`) on each prompt the user sends, and a runner claims it over a Unix socket, receiving
its pipes with SCM_RIGHTS. In a real run the first step came 4.4 s after launch instead of 13. Each ready
process uses about 300 MB, plus about 450 MB of MCP servers here.

A ready process takes any call with the same account, folder and agent type: the runner sends it the control
requests the Agent SDK uses (`set_permission_mode`, `set_model`) and writes the prompt only once both are
answered, since a model switch applies to messages read after its answer. A process started on Sonnet then
answered as Haiku 2.3 s after the call, also when claimed during its startup. Plan mode answers with Sonnet
whatever model is asked for, cold or switched; that's Claude Code's own behavior. Cold starts measured on
2026-10-27 took 7 to 71 s before the first reply, with or without the MCP servers.

Checked first: `claude -p --output-format json` returns `result`, `session_id`, `is_error`,
`api_error_status` and `permission_denials`; `--resume <session_id>` continues the same session; `--agent`
accepts built-in types (Explore runs read-only) and custom ones; `--permission-mode auto`, `--effort`,
`--model` and `--worktree` work headless.

### Native task adapter (2026-10-27)

Primary sources were the installed Claude Code 2.1.310 runtime and the bundled 2.1.308
`plugin-authoring/types/claude-code.d.ts`, `reference.md` and examples. The initial claim that a native
agent could not serve an external report was wrong: `turn.step` supports a complete synthetic response.
The native task can own the lifecycle while its worker runs elsewhere. It does not need to replay remote
tool calls or preserve a remote model request byte for byte.

The disposable spike used a native agent, a two-second `$.process.spawn` wait and a one-line synthetic
report. `agent.spawn`'s `next(e)` returned `{ model, agentId }` before the first step, for foreground and
background alike. A separately registered `turn.step` hook received the same `agentId`; it was not skipped
by the spawn hook's nesting. Plain `claude -p` stayed alive, and the main Haiku model consumed the report.
`SendMessage` produced a new turn's step 0 on that id. `TaskStop` aborted `next.signal`, ended the waiting
process and executed a command issued by the abort listener. The production binding also waits for native
spawn replies that are still crossing the worker boundary, so an early step cannot slip through locally.

Report delivery has two native forms in this build:

- In auto mode, the native request includes a system reminder requiring `SubagentHandback`. Text plus
  `end_turn` triggered three `[handback-send-enforce]` re-prompts, then an unsent-report notification.
  The adapter instead yields a `tool` chunk naming `SubagentHandback`, an `input` chunk whose `message` is
  exactly the remote final text, and a `stop` chunk with `tool_use`. Core executes the native handback.
- In `acceptEdits`, that tool is absent. An unconditional handback call returned `No such tool available:
  SubagentHandback`. The adapter yields text and `end_turn` there. It identifies handback by the explicit
  instruction in `$.session.messages`, not by `$.tool.list()`, which lists the main loop's tools even when
  called from a subagent hook. A regression also prevents an unknown handback from causing an endless
  sequence of synthetic tool calls.

Queued messages exposed another ordering detail: a queued `SendMessage` resumed the native agent with
its exact text in `agent.spawn.prompt`, while the step's `$.session.messages` still contained only the
previous turn. Reading that snapshot alone produced `The native agent resumed without a new text message`.
The adapter now captures the pinned resume prompt before calling `next(e)` and runs once per native turn.
It leaves queuing, resumption and notification scheduling to the engine; it does not intercept SendMessage.
A regression reproduces the lagging snapshot.

The catalog now advertises `nativeTasks: true`. An older app is rejected before the plugin invokes
`--agent-route`, so an app that does not recognize that CLI mode cannot launch its GUI and leave the call
waiting. The native route and remote session are saved when the remote init succeeds, so a native stop
cannot erase the session needed by a later follow-up.

The stop chunk carries the remote model and token usage, with cache reads and cache writes kept separate.
The native transcript contains the report or handback, not the remote tool transcript. Remote progress
and tool results stay in the existing pane and logs; native tool-use counters count native calls only.
Auto mode can attach its own notice that the server-side safety classifier was unavailable for the
synthetic handback. lastdrop leaves that native review behavior intact and does not alter the report's
payload to hide it.

`next.signal` calls `lastdrop --agent-stop <nativeId>` and the process stream's cancellation ends the
runner. A runner's signal cleanup also stops processes handed to that runner by the warm pool, which are
not necessarily its children. Testing exposed an older PID-registration gap during permission/model
switches: a fake warm process observed `late` before the fix and `early` after it. The runner now registers
a claimed PID before sending switches, and a cold PID before writing its prompt, so early stops can find
it. It terminates a claimed process that cannot switch before starting a replacement.

Validation and live evidence are recorded below. All probes used this worktree, `--plugin-dir` and its
development binary; `/Applications/lastdrop.app` was not replaced. Drivers used tiny prompts and Haiku.
Main was at its weekly limit, so it could not be used as a real model driver for Pro:

- A real Haiku driver on Pro exercised the enabled Codex-backed `sol` agent (then called `lastdrop:sol`) for background,
  foreground, SendMessage, TaskStop and ListAgents, both with plain input and stream-json input held open.
  All ten runs passed. The final outputs handled the native reports; SendMessage reused the same native
  id; ListAgents showed that native id while running; TaskStop executed the abort listener's stop command.
  The remote provider used the existing agent's configured Codex model, not Haiku.
- A synthetic main loop under Main's real config exercised actual Haiku workers on Pro, without making
  main-account model requests or pretending Pro was a different account. These checks cover the same
  native lifecycle but do not claim a real main model consumed the reports. Background and foreground
  passed with plain and open stream-json input; SendMessage passed in both, resuming the same remote
  session and reporting `ACCOUNT-REPORT-TWO`. TaskStop and ListAgents passed with plain and open input.
  The open-input stop recorded its claimed Pro PID and the stop command succeeded; both the runner and
  Claude process exited. A message sent while the first remote run was still busy also delivered its
  second report in both input modes, after fixing the lagging native snapshot described above.

Checks: `claude plugin validate .` passed with the existing author/icon warnings; `claude plugin test .`
passed all 35 tests. `swift build` passed; `swift test` reported 94 tests, 5 skipped, no failures. No
repository tsconfig exists; a supplementary source-only `tsc --noEmit` check passed against the supplied
2.1.308 declarations. Plugin tests execute under the installed 2.1.310 host.

The native desktop UI and its ctrl+b key handling were not operated live; the SDK-equivalent open-input
runs exercise their task lifecycle. The plugin no longer overrides the native tool row or background
button. Full remote transcripts remain in lastdrop's pane rather than the native transcript.

## Earlier design: one app copy per account

Why the relay went: it could only swap the token on model requests, so a session's other traffic (settings,
telemetry, Remote Control) still went out as the Claude app's account; its connections didn't look like
Claude Code's own; it signed accounts in with Claude Code's OAuth client; and moving a running session between
accounts is the part most likely to break Anthropic's terms. Each account having its own native sign-in
avoids all four.

- **App copies.** The Claude app honours Chromium's `--user-data-dir` (it ignores `CLAUDE_USER_DATA_DIR` in
  signed builds, see its log line "signed builds ignore it"). A copy started with
  `--user-data-dir=~/Library/Application Support/Claude-<name>` has its own sign-in, session list and
  single-instance lock. Checked: the copies run side by side, each signed in to its own account.
- **Signing a copy in.** The app finishes sign-in through a `claude://` link, and macOS hands it to the copy
  that is already running. So the main app has to be closed while a new copy signs in. After that each copy
  keeps and renews its own sign-in.
- **Opening the right copy.** macOS treats every copy as one app. lastdrop finds each running copy by the
  `--user-data-dir` in its arguments (`KERN_PROCARGS2`) and activates that process, or starts a new instance
  with the argument.
- **Usage.** The app's own sign-in is encrypted with the "Claude Safe Storage" key, which only Claude.app may
  read. lastdrop reads a Claude Code terminal sign-in instead: Main's is `~/.claude` (keychain item
  `Claude Code-credentials`); another account's is its own `CLAUDE_CONFIG_DIR` (`~/.claude-accounts/<name>`,
  keychain item `Claude Code-credentials-<first 8 hex of sha256(folder)>`, as Claude Code 2.1.310 names it).
- **Sharing.** Every copy's Code tab runs Claude Code on `~/.claude`, so settings, hooks, skills, agents,
  plugins, CLAUDE.md, MCP servers and memory are shared. Separate: each copy's session list and what Anthropic
  keeps per account. Session presets (`ccd-session-presets.json`, keyed by account UUID; a preset is a folder,
  model, effort and worktree switch) are synced by lastdrop: union across copies, the most recently written
  file wins per preset, deletions tracked against the last sync, and only written to copies that aren't
  running.
- **Which account for new sessions:** the first in the order whose Session and Weekly use are below the
  threshold (85% by default); if none, the least used one that isn't full.

## Goal

- Connect several Claude accounts in lastdrop (for example a $20 Pro and a Max).
- Put them in a priority order. Claude Code uses the first account that has room. When its Session (5 h) or
  Weekly limit runs out, the next one takes over without you noticing. When the first one resets, it is
  used again.
- Nothing changes in the Claude app: same sign-in, sessions, chats and settings. The switching shows only in
  lastdrop.

The case this is for: Pro first, Max second. Pro uses its windows early and Max covers the rest, so you are
never left on Pro alone at the end of the week.

## Why not swap the sign-in

[claude-account-switcher](https://github.com/SnlperStripes/claude-account-switcher) switches the *desktop
app's* sign-in. It quits Claude, swaps `oauth:tokenCacheV2` in `config.json` and the cookie store, copies the
chat list between accounts, and starts Claude again. A reply being written at that moment is cut off. That
is the opposite of "invisible" and "don't touch my app", so it is a source of ideas only (rules for when to
switch, usage polling, not trusting stale numbers).

Swapping Claude Code's keychain item (`Claude Code-credentials`) does not work either:

- Sessions in the Claude app's Code tab don't use that item. The app passes its own sign-in to Claude
  Code (`CLAUDE_CODE_ENTRYPOINT=claude-desktop`, `CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH=1`, and the account
  is set by `CLAUDE_CODE_ACCOUNT_UUID` / `CLAUDE_CODE_USER_EMAIL`). So the keychain swap would only affect the
  terminal `claude`.
- Claude Code refreshes that item itself, and refresh tokens rotate. Two writers for one item means one of
  them ends up with a dead refresh token.
- Running sessions keep their token in memory, so a swap only takes effect at some later point.

## The design: a local relay that picks the account per request

Every Claude Code request goes to Anthropic's API with an `Authorization: Bearer sk-ant-oat01-…` OAuth
token. If Claude Code sends its requests to lastdrop on `127.0.0.1` instead, lastdrop can forward each one
with the token of whichever account should take it. Your conversations live on disk (`~/.claude/projects`),
not with the account, so changing accounts between two requests, even in the middle of a turn, is safe.

```
Claude Code (Code tab or terminal)
   │  POST /<secret>/v1/messages  (Bearer <the app's own token>)
   ▼
lastdrop relay, 127.0.0.1:<port>
   │  choose an account → replace Authorization → stream the response back unchanged
   │  read the rate-limit headers of every response → update that account's state
   │  429 "limit reached" before any byte was sent → replay the same request on the next account
   ▼
api.anthropic.com
```

### The one setting it needs

One key in `~/.claude/settings.json`, written when you turn on routing and removed when you turn it off:

```json
{ "env": { "ANTHROPIC_BASE_URL": "http://127.0.0.1:47811/<random secret>" } }
```

This is Claude Code's configuration, not the Claude app's. The app's sign-in, its sessions and
`config.json` stay as they are.

Checked on this Mac (Claude Code 2.1.308) by pointing a settings file at a local listener while the process
environment set `ANTHROPIC_BASE_URL=https://api.anthropic.com`, the way the Code tab does:

- The settings value wins over the environment variable.
- The path prefix is kept: requests arrive as `POST /<secret>/v1/messages?beta=true`. The prefix is the
  relay's secret, so other local programs can't spend your limits through it.
- The request carries `Authorization: Bearer sk-ant-oat01-…` and no organisation header, so replacing that one
  header is enough.

**Spike result (2026-10-26): this works for the terminal `claude` but not for the Code tab.** See
[Spike results](#spike-results-2026-10-26).

### Which account is which

- **Main account, no extra sign-in.** The token Claude Code sends already belongs to an account. The relay
  looks it up once (`/api/oauth/profile`, cached by token hash) and calls that account "Main". When Main
  is the one to use, the request goes through unchanged with Claude Code's own token. lastdrop never stores
  or refreshes that token.
- **Detected or picked by hand.** lastdrop shows which account the Claude app is signed in to
  (`lastKnownAccountUuid` in `~/Library/Application Support/Claude/config.json`) and which one the terminal
  `claude` uses (`oauthAccount.accountUuid` in `~/.claude.json`). Both are matched to connected accounts by
  account UUID. You can also mark any account as Main by hand; it is then just an ordinary connected
  account.
- **Other accounts: lastdrop's own sign-in.** Add account opens a sign-in window with an empty, throwaway
  web session (like `ZAISignInWindow`, a non-persistent `WKWebsiteDataStore`). You can sign in there with a
  different email than the one your browser and the Claude app use. It runs the same OAuth PKCE flow as
  `claude /login`, with the same scopes (details in result 5). The tokens go in the keychain under service
  `lastdrop`, like the Antigravity, Z.ai and OpenRouter logins. lastdrop refreshes them itself. They are a
  separate sign-in from any the Claude app has, so nothing competes over refresh tokens.

### Choosing the account (per request)

State per account: `status` (ok / limited), `limitedUntil`, the latest 5 h and 7 d use, and any
model-scoped weekly limits.

1. Go down the priority list. Pick the first account that isn't limited, or whose `limitedUntil` has
   passed. That is how it **returns to the first account after a reset**: the first request after the
   reset time tries it again.
2. Send the request. On success, update the account from the response headers
   (`anthropic-ratelimit-unified-status`, `-5h-utilization`, `-7d-utilization`, `-reset`, and the overage
   headers; exact names still to confirm, see below).
3. If the reply is a **limit-reached 429** (not an overload 529, not an ordinary rate limit that clears in
   seconds), mark the account limited until the reset Anthropic gives, and **replay the buffered request
   body on the next account**. Claude Code sees one successful response. Limits are checked before
   streaming starts, so a reply is never cut off part way.
4. If every account is limited, pass on the last 429 unchanged, so Claude Code shows its usual "limit
   reached" message with the earliest reset.

Rules on top of that:

- **Extra usage counts as limited.** If an account has extra usage (overage) turned on, Anthropic keeps
  accepting requests past the limit and bills you. When the headers say a request would be paid overage,
  treat that account as limited and move on. A setting per account can allow overage.
- **Model-scoped limits.** A Pro account can run out of a model's weekly limit ("Fable Weekly") before its
  general one. That limit applies to that model only: requests for that model skip the account, and the
  others keep using it.
- **No flapping.** It only moves on at a real limit, never on a percentage, and only goes back after the
  stated reset. An optional "switch early at 98%" can come later if replays turn out to be visible.
- **Fail open.** If lastdrop has no usable data, a sign-in fails to refresh, or any error happens inside the
  relay, the request goes through unchanged with Claude Code's own token. The worst case is today's
  behaviour.

What switching costs: the prompt cache belongs to the account, so the first request on the new account
reads the whole context again without the cache discount. On a long session that is a visible part of a Pro
Session window. It happens once per switch, not per request.

### Keeping it running

If the relay isn't listening, every Claude Code request fails. So:

- The relay is the same binary in a headless mode (`lastdrop --relay`, next to the existing `--print`),
  started by a LaunchAgent with `KeepAlive`. It keeps working if the menu bar app quits or crashes. The app
  talks to it over a Unix socket (state, switch events, "use this account now").
- Turning routing off, or uninstalling, removes the `env.ANTHROPIC_BASE_URL` key from `settings.json` and
  unloads the agent. lastdrop only edits that key and keeps the rest of the file as it was, formatting
  included where possible.
- A session already running keeps the base URL it started with. Turning routing on applies to new
  sessions. Turning it off while sessions run means the relay keeps passing their requests through until
  they end, so the agent stops once no request has come in for a while.

## In lastdrop

- **Claude section, one row per account,** in priority order: email, plan, Session and Weekly left, resets.
  A badge marks the account Claude Code is using now, and "Main" marks the account the Claude app is
  signed in to.
- **Activity line** under the section, for example "13:02 Pro reached its Session limit → Max. Back to Pro at
  17:40". Optional notification on each switch, using the existing notification setting.
- **Menu bar:** the Claude item shows the account in use. Optionally a small dot when it isn't the first in
  the list, so you can see Max has taken over.
- **Settings → Claude:** list of accounts you can drag to reorder; Add account; Remove; "Main" (detected, or
  picked by hand); "Allow extra usage" per account; "Route Claude Code through lastdrop" toggle, which
  explains the `settings.json` key it writes.
- **Usage polling** stays as it is (`/api/oauth/usage` every 5 minutes) but runs once per account. Between
  polls the relay's response headers keep the numbers current, so lastdrop gets more accurate without
  extra calls.

## Fit with the code

| New / changed | What |
| --- | --- |
| `Support/ClaudeOAuth.swift` | PKCE sign-in in an ephemeral web view, refresh, profile lookup. Modelled on `GoogleOAuth.swift`. |
| `Model/ClaudeAccounts.swift` | Account list, priority, Main, per-account limit state. The choosing logic is a pure function, tested like `ProviderMappingTests`. |
| `Relay/` | `NWListener` on loopback, HTTP/1.1 with streamed (SSE) pass-through, request buffering for replay, header parsing. |
| `Providers/ClaudeProvider.swift` | One snapshot per account (`ProviderID.claude` becomes a section with several accounts). |
| `lastdropApp.swift` | `--relay` entry point; LaunchAgent install/remove. |
| README | The "lastdrop only reads usage" paragraph gets a second exception: the relay, and the one `settings.json` key. |

## Spike results (2026-10-26)

How the test was run: a pass-through relay on `127.0.0.1:47811/<secret>` forwarded everything to
`api.anthropic.com` unchanged. It logged header names, a hash of the token and every rate-limit response header,
never tokens or bodies. The script is not in the repo. `~/.claude/settings.json` was backed up, changed for the
test, and restored byte for byte afterwards.

### 1. Routing: works for the terminal, not for the Code tab

- **Terminal `claude` (2.1.308):** requests reach the relay, streaming works, and the reply comes back
  normally. The test passed the URL through `--settings`. The documented `settings.json` `env` key behaves
  the same way for the terminal.
- **Code tab: no.** A new Code-tab session started with `env.ANTHROPIC_BASE_URL` in `~/.claude/settings.json`
  still had `ANTHROPIC_BASE_URL=https://api.anthropic.com`, and none of its requests reached the relay. The
  app sets that variable itself when it starts Claude Code, and the app's value wins. `API_TIMEOUT_MS` behaves
  the same: `settings.json` says 3000000, Code-tab sessions run with 900000.
- **New keys do get through.** A variable the app doesn't set (`LASTDROP_PROBE=1`) reached Code-tab sessions,
  even one already running: Claude Code re-reads `settings.json` while it runs. The app's own `--settings`
  flag contains no `env` (only `fastMode` and `deniedMcpServers`), and the sessions run with
  `--setting-sources=user,project,local`.

What this changes:

- **Terminal:** the design stands.
- **Code tab:** the only route left that doesn't touch the app is a variable the app doesn't set, which means
  `HTTPS_PROXY` (tested in result 3: it works). lastdrop would run a proxy that tunnels every host unchanged except `api.anthropic.com`. For
  that host it would decrypt the traffic to swap the token, which needs a local certificate authority that
  Claude Code trusts (`NODE_EXTRA_CA_CERTS`). Two catches, both untested:
  - Bash, git, npm and MCP servers run by those sessions inherit `HTTPS_PROXY` (they inherited
    `LASTDROP_PROBE`). All their traffic would go through lastdrop, and nothing works if lastdrop is down.
  - Whether Claude Code picks up `NODE_EXTRA_CA_CERTS` from `settings.json`, or only when it starts.
- The other routes all break the rules set at the top: swapping the app's own sign-in, managed settings
  (needs admin rights, and might be ignored the same way), or redirecting `api.anthropic.com` for the whole
  system.

### 2. Rate-limit headers (real response, Max account, `claude-haiku-5-5`)

Every `/v1/messages` response carries these. Utilisation values are fractions from 0 to 1; resets are Unix
seconds.

| Header | Value seen | Meaning |
| --- | --- | --- |
| `anthropic-ratelimit-unified-status` | `allowed_warning` | Overall: `allowed`, `allowed_warning`, presumably `rejected` at the limit |
| `…-5h-status` / `…-7d-status` | `allowed` / `allowed_warning` | Per window |
| `…-5h-utilization` / `…-7d-utilization` | `0.09` / `0.92` | What is used |
| `…-5h-reset` / `…-7d-reset` | `1793031600` (17:20 today) / `1793160000` (Wed 28 Oct, 05:00) | When each window resets |
| `…-reset` + `…-representative-claim` | `1793160000` + `seven_day` | The window that limits you right now, and its reset |
| `…-7d-surpassed-threshold` | `0.75` | Warning level that was crossed |
| `…-overage-status` | `rejected` | Extra usage: off here |
| `…-overage-disabled-reason` | `org_level_disabled` | |
| `…-upgrade-paths` | `overage` | |
| `…-fallback-percentage` | `0.5` | Unknown; probably model fallback |

These headers contain everything the choosing logic needs, without polling: the status of each window, its
reset time, and whether extra usage applies. No model-scoped header (Fable Weekly) showed up on a Haiku
request; check one on the scoped model. The 429 body at a real limit is still not recorded, because no
account was at its limit. Record it the first time one is.

Also seen: `HEAD /api/hello` at start-up (a connectivity check, no token), then
`POST /v1/messages?beta=true` with `Authorization: Bearer sk-ant-oat01-…`, `x-app`,
`x-claude-code-session-id` and `anthropic-beta`. No organisation or account header, so swapping the token
is the whole change.

### 3. Code tab through `HTTPS_PROXY`: works

Setup: a proxy on `127.0.0.1:47812` and a throwaway local CA, valid for 2 days and never added to the system
keychain. `~/.claude/settings.json` got `HTTPS_PROXY=http://127.0.0.1:47812` and
`NODE_EXTRA_CA_CERTS=<ca.pem>`. The proxy tunnels `CONNECT` to any host byte for byte. For
`api.anthropic.com` only, it decrypts with a certificate signed by that CA and forwards each request
unchanged. A new Code-tab session was then started.

- **Routing and TLS:** the new session (entrypoint `claude-desktop`) sent all its `api.anthropic.com` traffic
  through the proxy. It accepted the local CA, so `NODE_EXTRA_CA_CERTS` from `settings.json` is honoured
  at start-up. Its `/v1/messages` calls had the same rate-limit headers as in result 2.
- **Its token:** the Code-tab session sends the app's own token, not the one in the keychain (different
  hash), for the same account (identical usage numbers). So passing Main through unchanged works for both
  the terminal and the Code tab.
- **Not everything on `api.anthropic.com` is inference.** It also carried bootstrap, account settings, plugin,
  skill and marketplace lists under `/api/oauth/organizations/<org uuid>/…`, event logging, the MCP
  registry, and the Remote Control bridge. The bridge (`/v1/code/sessions/<id>/worker…`) uses a *separate*
  token. **The relay should swap the token on `/v1/messages` (and `count_tokens`) only**, and leave every
  other request unchanged, under the app's own account.
- **Other hosts go through it too:** the Datadog log intake, `mcp-proxy.anthropic.com`, the Copilot API,
  `registry.npmjs.org` (an MCP server started with `npx`) and `curl` from a hook. Everything a session
  starts inherits the proxy.

**Running sessions pick it up immediately, and keep it.** This is the finding with the most impact on the design:

- Every Code-tab session already running when the keys were added (seven processes, this one included)
  started using `HTTPS_PROXY` within seconds, without the CA. They worked only because the spike proxy
  tunnelled processes that were already running when it started, instead of decrypting their traffic.
  Decrypting it would have failed TLS in all of them.
- **Removing the keys does not take them back out** of running sessions. Setting them to `""` first does:
  the empty value reaches running sessions live, and it can then be removed. That is how the spike
  cleaned up.

What this means for lastdrop:

- `HTTPS_PROXY` + a local CA is a route for the Code tab that doesn't touch the app's sign-in, its sessions
  or `config.json`. It also covers the terminal `claude`, so one mechanism does both.
- **Decrypt only for processes that started after the CA was set.** Older processes don't trust it. The
  relay finds the client process from the socket (`lsof` in the spike, `proc_pidinfo` in Swift) and compares
  its start time with the time the keys were written. Older processes get a plain tunnel.
- **Turning off is two steps:** write `""` for both keys, wait for running sessions to pick it up, then remove
  them. The relay keeps tunnelling until no older process is still connected.
- **The relay must stay up while the keys are set.** If it isn't listening, every HTTPS request from every
  Claude Code session and its tools fails, not only inference. That makes the LaunchAgent with `KeepAlive`
  a requirement, not an option.
- The CA is lastdrop's own: generated on first use, key in the keychain, trusted only through
  `NODE_EXTRA_CA_CERTS`, never added to the system trust settings. Give it a name constraint for
  `api.anthropic.com`, so a leaked key can't be used to impersonate any other site to Claude Code.
- Also set `NO_PROXY=localhost,127.0.0.1,::1`, so tools that call local dev servers over HTTPS don't go
  through the relay.

### 4. What a limit looks like (from the Claude Code 2.1.308 binary)

Claude Code has a built-in limit simulator (`setScenario`) and a classifier for real responses. Between them
they show the exact shape, without having to wait for an account to run out:

- **Limit reached:** HTTP 429, body `{"type":"error","error":{"type":"rate_limit_error","message":"Rate limit
  exceeded"}}`, with these headers:
  - `anthropic-ratelimit-unified-status: rejected`
  - `…-overage-status` absent or `rejected`
  - `…-representative-claim`: the window that ran out. Seen in code: `five_hour`, `seven_day`,
    `seven_day_opus`, `seven_day_sonnet`.
  - `…-reset`: Unix seconds, the latest reset among the windows that ran out.
  - `retry-after`: seconds until that reset.

  Claude Code treats *any* 429, or a body containing `"type":"rate_limit_error"`, as rate limited. It
  reads the unified headers to tell you which limit and when it resets.
- **Model-scoped limits:** a `seven_day_opus` claim only blocks requests whose model contains "opus".
  Claude Code ignores it for other models. Newer per-model weekly limits come from the `limits[]` array of
  `/api/oauth/usage`. Their exact claim names aren't hard-coded, so match the claim to the model family
  rather than to a fixed list.
- **Extra usage covering the overflow:** `status: rejected` with `overage-status: allowed` or
  `allowed_warning`. The request is served and billed as extra usage. Related headers:
  `…-overage-in-use`, `…-overage-reset`, `…-overage-utilization`, and `…-overage-disabled-reason`
  (`out_of_credits`, `org_level_disabled`, `org_level_disabled_until`, `org_service_level_disabled`,
  `member_zero_credit_limit`, `seat_tier_zero_credit_limit`).
- **Warnings before the limit:** `status: allowed_warning`, with `…-5h-` / `…-7d-surpassed-threshold`
  and `…-utilization`.
- **Other 429s, not account limits:** a 429 with *no* unified headers ("headerless"). For example,
  "Usage credits are required for long context requests", which also shows up in a real
  [Claude Code bug report](https://claudeissues.com/issue/36951-bug-anthropic-api-error-rate-limit-exceeded-with-low-usage-quota).
  Moving to another account doesn't help with these.
- Also in the binary but not seen in a response yet: a `…-slow-*` family (status, retry-after, budget) and
  `…-grace-5h/7d-utilization`. The server only sends the grace values when the request carries
  `anthropic-usage-limit: extended`. Pass them through and ignore them for choosing.

**Rule for the relay:**

| Response | What the relay does |
| --- | --- |
| 2xx, `status` not `rejected` | Use as is; update the account's numbers |
| 2xx, `status: rejected`, overage allowed | Billed as extra usage. Unless the account allows it: mark it limited until `reset`, and use the next account from the next request |
| 429, `status: rejected`, overage absent or rejected | Mark it limited until `reset` (scoped to the model family if the claim is model-scoped); resend the same request on the next account |
| 429 without unified headers, 529, 5xx | Pass on unchanged; Claude Code retries as usual |

Still unconfirmed: whether a real server 429 carries exactly the same headers as the simulator. The
simulator copies the server's format, and Claude Code parses real responses with the same code. Log the
first real one to make sure.

### 5. Sign-in for extra accounts (from the Claude Code 2.1.308 binary, nothing signed in)

Production OAuth config, as Claude Code has it:

| | |
| --- | --- |
| Client ID | `9d1c250a-e61b-44d9-88ed-5944d1962f5e` |
| Authorize (Claude subscription) | `https://claude.com/cai/oauth/authorize` |
| Authorize (Console / API) | `https://platform.claude.com/oauth/authorize`, not used here |
| Token and refresh | `https://platform.claude.com/v1/oauth/token` (JSON body) |
| Redirect | `http://localhost:<port>/callback`, or `https://platform.claude.com/oauth/code/callback` for copying the code by hand |
| Profile | `GET https://api.anthropic.com/api/oauth/profile`, `Authorization: Bearer …`, `anthropic-beta: oauth-2025-04-20` |
| Normal scopes | `user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload`, plus `user:plugins` |
| `claude setup-token` | `user:inference` only, `expires_in: 31536000` (one year), no refresh |

**1. Authorize URL.** Claude Code's builder (`QWr`) sets these query parameters, in this order:

```
code=true
client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e
response_type=code
redirect_uri=http://localhost:<port>/callback
scope=user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload user:plugins
code_challenge=<base64url(SHA256(verifier))>
code_challenge_method=S256
state=<random>
login_hint=<email>            (optional: prefills the address)
orgUUID=<uuid>                (optional)
```

**2. Code for tokens.** `POST` to the token URL with `Content-Type: application/json`:

```json
{ "grant_type": "authorization_code", "code": "…", "redirect_uri": "<the same as above>",
  "client_id": "9d1c250a-…", "code_verifier": "…", "state": "…" }
```

A 401 means the code is invalid. The reply carries `access_token`, `refresh_token`, `expires_in` (seconds),
optionally `refresh_token_expires_in`, and `scope`.

**3. Refresh:**

```json
{ "grant_type": "refresh_token", "refresh_token": "…", "client_id": "9d1c250a-…",
  "scope": "<same scopes>" }
```

The reply may contain a **new** `refresh_token`; if it doesn't, the old one stays valid. Claude Code always
keeps whichever it gets back. lastdrop must save it in the keychain *before* using the new access token, so
that a crash can't leave a refresh token that has already been used.

**4. Who signed in.** Call `/api/oauth/profile` once: account UUID, email, organisation UUID and plan. That
UUID is what gets matched to `lastKnownAccountUuid` in the Claude app and to `oauthAccount.accountUuid` in
`~/.claude.json`.

**The flow in lastdrop:**

1. Settings → Claude → Add account. Optional email field, sent as `login_hint`.
2. lastdrop makes the PKCE verifier and challenge plus a `state`, and opens a one-shot listener on
   `127.0.0.1:<random port>`. The `LoopbackListener` in `GoogleOAuth.swift` already does this.
3. It opens the authorize URL in an **empty, throwaway browser session**, not the default browser. Your
   default browser and the Claude app are signed in to the main account, and claude.ai would simply
   approve that one again. Two ways to do it:
   - `ASWebAuthenticationSession` with `prefersEphemeralWebBrowserSession = true`: the system's own sign-in
     sheet. Google sign-in works in it. lastdrop cancels the sheet once the listener has the code. Needs a
     check that a `localhost` redirect completes inside the sheet.
   - A `WKWebView` with a non-persistent data store, like `ZAISignInWindow`, catching the
     `localhost/callback` navigation itself. Easiest to control, but Google refuses sign-in from embedded web
     views, so it only works for email-code logins.

   Start with the first and fall back to the second.
4. The listener gets `?code=…&state=…`, checks `state`, and answers with a "you can close this" page.
5. Exchange the code (step 2), fetch the profile (step 4), and save
   `{refresh_token, access_token, expires_at, scopes, account_uuid, email, org_uuid, plan}` in the keychain
   under service `lastdrop`, with the account UUID as the keychain account.
6. If the profile's UUID is already connected, or it is the Main account, say so and keep the existing
   entry. Main always uses passthrough (result 3), so it never needs a second sign-in, and no sign-in of the
   Claude app or the terminal `claude` is ever replaced.

**Refresh rules:** refresh when the access token has less than 5 minutes left, or after a 401 on a swapped
request. Only one refresh at a time per account. If the refresh is refused (`invalid_grant`), mark the account
"Sign in again" and leave it out of the order. The request in flight then falls through to the next account
or to Main.

**Why not `setup-token`-style tokens:** a one-year `user:inference` token needs no refresh, which is
appealing. But Claude Code itself notes that such tokens are rejected by endpoints that need `user:profile`.
That means no profile lookup, and probably no `/api/oauth/usage` for lastdrop's per-account meters. Use the
normal scopes.

**What a second sign-in does to the Claude app:** an extra account has no other sign-in, so nothing can
conflict. Signing in the *main* account a second time is avoided by design, so whether it would sign the app
out doesn't need testing.

**Terms:** lastdrop would use Claude Code's own client ID. The tokens are only ever sent on Claude Code's own
requests, so Anthropic sees normal Claude Code traffic. But a third-party app taking part in Claude Code's sign-in is exactly
the kind of thing Anthropic's terms on subscription tokens restrict, and it fits under the same warning as
the automatic switching (see Terms).

## As built

| Piece | Where |
| --- | --- |
| Account list, order, routing flags | `Accounts/Accounts.swift` (every provider's pool), `Accounts/ClaudeAccounts.swift` (the Claude pool), `~/Library/Application Support/lastdrop/accounts.json`, migrated from `claude-accounts.json` |
| Sign-in (system sheet, private mode, loopback redirect) | `Accounts/ClaudeOAuth.swift`, `Support/LoopbackReceiver.swift` |
| Tokens, refresh under a cross-process lock | `Accounts/ClaudeTokens.swift`, keychain service `lastdrop`, account `claude.<uuid>` |
| Proxy, tunnel, splice to the TLS listener | `Relay/RelayServer.swift` (port 47812) |
| Account choice, token swap, replay on a limit | `Relay/RelayEngine.swift`, `Relay/Router.swift`, `Relay/RateLimit.swift` |
| Which process connected, and when it started | `Relay/ClientProcess.swift` (`proc_pidinfo`, no `lsof`) |
| CA and leaf | `Relay/LocalCA.swift`, `/usr/bin/openssl`, files in `…/lastdrop/relay/` |
| `settings.json` edits, LaunchAgent, on and off | `Relay/SettingsFile.swift`, `Relay/RelayInstaller.swift` |
| State the relay shares with the app | `…/lastdrop/relay-state.json`, written every few seconds |
| Panel, menu bar, Settings | `Views/ClaudeAccountsSection.swift`, `Views/SettingsView.swift`, `Model/AppModel+Claude.swift` |

Differences from the design:

- **RSA, not EC.** LibreSSL (macOS's `/usr/bin/openssl`) writes EC keys with explicit curve parameters. Claude
  Code then fails every request with "unable to decode issuer public key", and `SecPKCS12Import` with
  `kSecImportToMemoryOnly` crashes on such a key. The CA is RSA 3072, the leaf RSA 2048.
- **The relay and the app share files, not a socket.** The relay writes its state to a JSON file; the app reads
  it every 15 s and when the panel opens. The app writes the account list, and the relay re-reads it when it changes.
- **Main is matched by account UUID.** If an account you add is the one Claude Code is signed in to, it is
  used as Main with Claude Code's own token, wherever it sits in the order.
- **`count_tokens` follows the same choice as `/v1/messages`.**
- **Turning off** blanks the keys, removes them after a minute, and the relay exits after 30 idle minutes
  and deletes its LaunchAgent file.

Tested:

- Unit tests: header reading, routing, account state, `settings.json` edits (add, blank, remove back to the
  original bytes), HTTP framing, token parsing.
- A loopback test with a fake Anthropic server: a limit-reached 429 for the first account is resent with the
  main account's token within the same request, and the next request skips the first account.
- The relay on this Mac with both the Claude app's bundled `claude` and the native terminal install
  (`~/.local/bin/claude` → `~/.local/share/claude/versions/<v>`), with the proxy passed through `--settings`:
  decrypted, passed through with Claude Code's own token, account and limits recorded.
- An independent code review found nine defects, all fixed with tests where testable:
  - the terminal install wasn't recognised (its process is named after its version);
  - a `100 Continue` or a dropped kept-alive connection could make a request go out twice;
  - an extra account's 401 could reach Claude Code instead of Main's "limit reached";
  - a 502 could be written into a half-sent response;
  - the tunnel cut half-closed connections;
  - `settings.json` could lose Claude Code's own concurrent edits, or get a second `env`;
  - the token lock blocked worker threads.

Not tested yet:

- Installing the LaunchAgent and turning routing on through the app. The automated session building this
  wasn't allowed to install a login item, so the first run is yours.
- A Code-tab session through the Swift relay. Same mechanism as spike 3, which worked.
- Signing in an extra account, and a real switch at a real limit.

## Session pinning (added 2026-10-26)

Switching a running session to another account costs one full re-read of the conversation on the new
account, because the prompt cache belongs to the account. So sessions stay put while their cache is warm.

Checked first with the terminal `claude` 2.1.310 through a pass-through relay, logging headers and cache
settings only:

- Every request carries `x-claude-code-session-id`. A subagent's requests carry the **same** ID, plus
  `x-claude-code-agent-id`.
- `cache_control.ttl` is `1h` on the main loop and the default 5 minutes for subagents. Each keeps its own
  cache (the subagent wrote 16k tokens, then read them back).
- `--resume` keeps the session ID and reads the cache when it's still warm.
- The body's `metadata.user_id` is a JSON string with `device_id`, `account_uuid` and `session_id`.

Rules (`Router.candidates`, `RelayEngine.settle`):

1. A session whose cache is warm stays on its account while that account has room. "Warm" means: the latest of
   each request's time plus that request's longest `cache_control.ttl`.
2. A new session, or one whose cache has expired, starts on the first account in the order whose Session and
   Weekly use are below `newSessionThreshold` (default 85%, from the last response headers; a window past its
   reset counts as empty). If every account is above it, the first with room is used.
3. At a hard limit, a warm session moves anyway: one full re-read on the new account, then it is pinned there.
4. Requests sent with another account's token have `metadata.user_id.account_uuid` changed to that account,
   the same length, nothing else touched.
5. Events: "moved" when a warm session had to move; otherwise one when new sessions start on another account
   ("Over 85%", a limit, or "Available again").

Pins live in the relay's state file (at most 200 sessions, dropped after 24 h). After a relay restart they
are read back.

Tested: unit tests for the rules and the metadata rewrite, a loopback test (a session stays on Pro while a
new one goes to Main because Pro is over 85%, and each body names the account of its token), and one real
request through the Swift relay (pinned to Main, warm for 60 minutes).

## Still to check

1. Probably fine to send every Claude Code session's subprocess traffic through lastdrop (not decided yet).
   What it costs: the relay has to be very reliable, and every connection goes through one more local hop.
2. The first real limit-reached 429 (log it), to confirm it matches result 4.
3. That an ephemeral `ASWebAuthenticationSession` completes a `localhost` redirect (a UI test, no account
   needed: point it at a local page that redirects).
4. Nothing else in the request is tied to the account, so a replay on another account behaves like a normal
   request.

## Terms

Anthropic's terms allow more than one account, but forbid "bypassing any of our systems or protective
measures". Rotating between accounts automatically to get past usage limits could be read that way, and
Anthropic could act on the accounts. claude-account-switcher keeps its auto-switch off by default for this
reason. lastdrop should do the same: routing is off until you turn it on, and the toggle says what it does.
