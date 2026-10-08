import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"

export interface TokenUsage {
  input: number
  output: number
  reasoning: number
  cache: { read: number; write: number }
}

export type GoalStatus =
  | "idle"
  | "running"
  | "achieved"
  | "failed"
  | "cleared"
  | "paused-utente"
  | "stopped"

export interface GoalState {
  ownerSessionID: string
  /** `condition` = goal generico come quello di Claude Code. `backlog` = drenaggio di più item. */
  mode: "condition" | "backlog"
  /** Modalità condition: la condizione di completamento. */
  condition: string | null
  /** Gate deterministico opzionale, in entrambe le modalità. */
  verify: string | null
  /** Modalità backlog. */
  backlogPath: string | null
  current: string | null
  status: GoalStatus
  turns: number
  redStreak: number
  spend: Record<string, { cost: number; tokens: TokenUsage }>
  lease: { expiresAt: number }
  lastReason: string | null
  lastEventAt: number
  fingerprint: string | null
  startedAt: number
  maxTurns: number
  updatedAt: number
}

export function statePath(root: string): string {
  return join(root, ".opencode", "goal", "state.json")
}

export function readState(root: string): GoalState | null {
  try {
    const raw = readFileSync(statePath(root), "utf8")
    const s = JSON.parse(raw)
    if (!s || typeof s !== "object" || typeof s.ownerSessionID !== "string") return null
    return s as GoalState
  } catch {
    return null
  }
}

export function writeState(root: string, s: GoalState): void {
  const p = statePath(root)
  mkdirSync(dirname(p), { recursive: true })
  const tmp = p + ".tmp"
  writeFileSync(tmp, JSON.stringify(s, null, 2) + "\n")
  renameSync(tmp, p)
}

export function blankState(sessionID: string, now: number, ttlMs: number): GoalState {
  return {
    ownerSessionID: sessionID,
    mode: "condition",
    condition: null,
    verify: null,
    backlogPath: null,
    current: null,
    status: "idle",
    turns: 0,
    redStreak: 0,
    spend: {},
    lease: { expiresAt: now + ttlMs },
    lastReason: null,
    lastEventAt: now,
    fingerprint: null,
    startedAt: now,
    maxTurns: 0,
    updatedAt: now,
  }
}

export function acquireLease(
  s: GoalState | null,
  sessionID: string,
  now: number,
  ttlMs: number,
): { ok: boolean; reason?: string; state?: GoalState } {
  if (!s) return { ok: true, state: blankState(sessionID, now, ttlMs) }
  if (s.ownerSessionID === sessionID) {
    return { ok: true, state: { ...s, lease: { expiresAt: now + ttlMs } } }
  }
  if (now >= s.lease.expiresAt) {
    return {
      ok: true,
      state: { ...s, ownerSessionID: sessionID, lease: { expiresAt: now + ttlMs }, updatedAt: now },
    }
  }
  const left = Math.ceil((s.lease.expiresAt - now) / 1000)
  return { ok: false, reason: `lease attivo di ${s.ownerSessionID} per altri ${left}s` }
}

export function renewLease(s: GoalState, sessionID: string, now: number, ttlMs: number): boolean {
  if (s.ownerSessionID !== sessionID) return false
  s.lease.expiresAt = now + ttlMs
  s.updatedAt = now
  return true
}

export function isTerminal(status: GoalStatus): boolean {
  return status === "achieved" || status === "failed" || status === "cleared" || status === "stopped"
}
