import { spawnSync } from "node:child_process"
import { createHash } from "node:crypto"

export const FINGERPRINT_EXCLUDES: string[] = [
  ".git/",
  "node_modules/",
  ".venv/",
  "__pycache__/",
  ".pytest_cache/",
  ".ruff_cache/",
  "dist/",
  "build/",
  "output/",
  "runs/",
  ".opencode/goal/",
  ".superpowers/",
]

export function isExcluded(path: string): boolean {
  const p = path.replace(/^\.\//, "").replace(/^\/+/, "")
  return FINGERPRINT_EXCLUDES.some((ex) => p === ex.replace(/\/$/, "") || p.includes("/" + ex) || p.startsWith(ex))
}

export interface VerifyResult {
  exitCode: number
  tail: string
  timedOut: boolean
}

export function verifySync(input: { command: string; cwd: string; timeoutMs: number }): VerifyResult {
  const r = spawnSync("bash", ["-lc", input.command], {
    cwd: input.cwd,
    encoding: "utf8",
    timeout: input.timeoutMs,
    maxBuffer: 16 * 1024 * 1024,
  })
  const out = (r.stdout ?? "") + (r.stderr ?? "")
  const timedOut = r.error?.code === "ETIMEDOUT" || r.signal === "SIGTERM"
  return {
    exitCode: timedOut ? -1 : (r.status ?? -1),
    tail: out.slice(-4000),
    timedOut,
  }
}

export function fingerprintSync(root: string, paths: string[]): string {
  const keep = paths.filter((p) => !isExcluded(p)).sort()
  if (keep.length === 0) throw new Error("no-vcs")
  return createHash("sha256").update(keep.join("\n")).digest("hex")
}

export function changedPaths(root: string): string[] {
  const [names, status] = [
    spawnSync("git", ["status", "--porcelain=v1", "--untracked-files=all"], { cwd: root, encoding: "utf8" }),
    spawnSync("git", ["diff", "--name-only"], { cwd: root, encoding: "utf8" }),
  ]
  if (names.status !== 0) throw new Error("no-vcs")
  const fromStatus = (names.stdout ?? "")
    .split("\n")
    .map((l) => l.slice(3).trim())
    .filter(Boolean)
  const fromDiff = (status.stdout ?? "").split("\n").map((l) => l.trim()).filter(Boolean)
  return [...new Set([...fromStatus, ...fromDiff])]
}

export function stalled(input: { redStreak: number; turns: number; unchanged: boolean }): boolean {
  return input.redStreak >= 5 && input.unchanged
}
