/** One entry of a remote agent's transcript: what it said, a tool call, a tool's result. */
export type TranscriptItem =
  | { kind: 'text'; text: string }
  | { kind: 'tool'; id: string; summary: string; input: string }
  | { kind: 'result'; id: string; text: string; isError: boolean }

/** A subagent lastdrop runs on another Claude account. */
export type RemoteAgent = {
  id: string
  description: string
  /** Where it runs: the account ("Pro"), or the provider for an agent of lastdrop's list ("Codex"). */
  account: string
  model: string
  /** The provider of an agent of lastdrop's list (`codex`, `zai`, `claude`, ...); absent for one on another account. */
  provider?: string
  status: 'running' | 'done' | 'failed' | 'stopped'
  /** The steps it took, newest last ("Read: note.txt"). */
  steps: string[]
  /** Its transcript so far, newest last, long texts cut. */
  items: TranscriptItem[]
  /** The Agent call it answered: its row in the session's transcript. */
  toolUseId?: string
  startedAt: number
  endedAt?: number
}

declare module 'claude-code' {
  interface PluginState {
    lastdrop: { paneShown: boolean; open: string[] }
  }
}
