# I. Subagent progress and shell commands on other providers

2026-11-09, Claude Code 2.1.319, `agy` ACP server 1.5.3.

## 1. The stall ("Request interrupted by user for tool use"): fixed

Claude Code stops a subagent whose stream shows nothing for 600 s (`CLAUDE_ASYNC_AGENT_STALL_TIMEOUT_MS`), logging
"Agent stalled: no progress for 600s (stream watchdog did not recover)" and giving the caller
`[Request interrupted by user for tool use]`. lastdrop's `turn.step` answered only once the remote run ended, so
every routed agent longer than ten minutes died this way (both `flash` failures on 2026-11-09 were at exactly 600 s).

Verified with throwaway plugins (stall limit lowered for the test only):
- A hook that waits silently is stopped at the limit; one that yields `thinking` chunks keeps it alive. Thinking a
  hook streams is shown and not recorded.
- Real lastdrop, `gemini` on Antigravity, limit 20 s: the installed plugin failed with the stall; this build
  completed with the report.

Fix: `turn.step` streams each runner `step` as thinking in block 0 and the report in block 1; the runner prints
`{"type":"tick"}` every minute, and after four quiet minutes the plugin adds "Still working on …". See
`docs/agents.md`, Routing.

## 2. Mirroring remote actions as real tool rows: possible, per tool

- A `turn.step` hook can end a step with any number of `tool_use` steps; the native loop runs them, and a
  `tool.call` hook can answer one with its own `result` without running it (hooks run before the permission check).
- Core validates that result against the tool's output schema: a string for `Read`, `Edit`, `Write`, `Bash` is
  rejected. `Bash` accepts `{ stdout, stderr, interrupted }`. Other tools need their own shapes.
- A tool missing from the session (`Grep` in this build) fails as "No such tool available".

## 3. Commands for Z.ai / OpenRouter (`flash`): design, not built

Cause: auto mode's check is server-side; with a non-Anthropic `ANTHROPIC_BASE_URL` Claude Code treats the
session as third-party and asks that endpoint, which doesn't serve it, and it has no local check. Commands that
need approval are refused. No setting fixes it. A plugin can't get the check's verdict without running the tool
(`$.tool.check` skips the classifier).

Design: run the child's commands in the native subagent, which applies the session's rules and auto mode check.
1. The Z.ai child loads lastdrop's plugin (its profile links only agents, skills, CLAUDE.md, commands today). Its
   `tool.call` hook on `Bash` sends the call to the parent through the runner and waits (waiting on a `$` call
   costs no hook budget).
2. The parent's `turn.step` ends the current step with that `Bash` call; the native loop checks and runs it.
3. The next `turn.step` reads the result from `$.session.messages({ agentId })` and sends it back; the child's
   hook returns it as Bash's result.
4. Mirror GLM's short texts too, so the check sees intent, not only commands.

Verified pieces: multi-step answers with real `Bash` calls run under the parent's auto mode and complete; a
hook-supplied `Bash` result is recorded. Not built yet: the child plugin, the reverse channel (runner → child),
the native subagent's working folder matching a worktree.

## 4. Antigravity commands

`agy --mode auto` exists but this account gets "not available for this account". Through `agy acp`, a command
arrives first as `session/request_permission` (`run_command`, `CommandLine`, options `allow` / `deny`) and waits
for the client; `agy` runs it itself and never asks the client to run it (no `terminal/create`, even with the
`terminal` capability). Denied, the call fails and the turn ends.

So lastdrop can decide before an Antigravity command runs, but can't run it in the session.

`agy --sandbox --dangerously-skip-permissions` is not a Codex-like sandbox: a test by the user wrote to `/tmp`
and reached `https://example.com` (200). Not used.

Decision (user, 2026-11-09): no permission prompts. Move the backend to `agy acp` and answer each
`session/request_permission` with the session's rules for the same `Bash` command (`$.tool.check`): `allow` →
Allow; anything else → Deny. Declines must be clear to the main agent so it can ask the user for approval:
- The report header names them and why: "Declined (not in your Claude Code allow rules): `swift test`", so the
  main agent can suggest an allow rule (`Bash(swift test:*)`) and ask the user to add it.
- The agent is told up front (ACP `_meta.antigravity.systemPrompt.append`) that commands outside the user's allow
  rules are declined, and to say in its report which ones it needed and why.

## 5. How Claude and Codex review actions, and what a lastdrop reviewer could use (2026-11-09)

Sources checked by hand; agent reports that couldn't be confirmed are left out.

**Claude Code auto mode.** Anthropic's post ([How we built Claude Code auto mode](https://www.anthropic.com/engineering/claude-code-auto-mode), as relayed by [digitalapplied](https://www.digitalapplied.com/blog/claude-code-auto-mode-classifier-numbers-published)):
two stages on a Sonnet model, server-side. Stage 1 is a single-token yes/no filter tuned to block; stage 2 reasons only
about what stage 1 flagged, sharing its cached prefix. It is reasoning-blind: it sees user messages and tool calls,
not Claude's text or tool outputs (a separate probe screens tool outputs). Reads and in-project edits skip it.
Published rates: false positives 0.4% on 10,000 real calls (stage 1 alone 8.5%); misses 17% on 52 real overeager
actions and 5.7% on 1,000 synthetic exfiltration tasks. An independent stress test reports far more misses on
ambiguous tasks ([arXiv 2604.04978](https://arxivexplorer.arxivexplorer.workers.dev/paper/2604.04978v2)).
The policy itself ships with Claude Code: `claude auto-mode defaults` prints 16 allow, 72 soft-deny, 1 hard-deny
rules and 21 environment fields (about 83,000 characters); `claude auto-mode config` prints the user's effective
rules. `claude auto-mode critique` reviews custom rules.

**Codex auto-review** ([docs](https://learn.chatgpt.com/docs/sandboxing/auto-review)): with
`approvals_reviewer = "auto_review"`, requests that would wait for a person (escalated commands, network, edits
outside writable roots, prompt rules, MCP calls) go to a separate reviewer agent. It sees a compact transcript (user
messages, visible assistant updates, relevant tool calls and outputs, the request), not hidden reasoning, and may run
read-only checks. It approves or denies with a rationale; a denial tells the agent not to work around it. Codex
interrupts the turn after 3 denials in a row or 10 in the last 50. Policy: `[auto_review].policy` replaces it,
`extra_policy` adds to it. Not a security guarantee, in OpenAI's words. The reviewer model isn't named in the docs
(third parties call it `codex-auto-review`).

**Models.** Guard models (Llama Guard, ShieldGemma, Qwen3Guard) moderate chat content against fixed categories and
don't judge an action against a policy. `openai/gpt-oss-safeguard-20b` is built to reason over a given policy; on
OpenRouter about $0.075 / $0.30 per million tokens in / out, $0.0375 cached, 131k context
([OpenRouter](https://openrouter.ai/openai/gpt-oss-safeguard-20b)); open weights, so it can also run locally. A
120b version exists. General small models can judge with a policy prompt too.
