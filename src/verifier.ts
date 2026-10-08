import { spawnSync } from "node:child_process"
import { createHash } from "node:crypto"
import { readFileSync, statSync } from "node:fs"
import { resolve } from "node:path"

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

/**
 * Impronta del lavoro: hash di **percorso più contenuto** dei file non esclusi.
 *
 * Hashare i soli percorsi non basta: finché l'agente lavora sullo stesso file la
 * lista dei percorsi non cambia, e l'anti-livelock scambierebbe il lavoro in corso
 * per stallo. I file oltre `MAX_HASH_BYTES` contribuiscono con dimensione e mtime,
 * che è un'approssimazione dichiarata e sufficiente per accorgersi di una modifica.
 */
const MAX_HASH_BYTES = 1024 * 1024

export function fingerprintSync(root: string, paths: string[]): string {
  const keep = paths.filter((p) => !isExcluded(p)).sort()
  if (keep.length === 0) throw new Error("no-vcs")
  const h = createHash("sha256")
  for (const p of keep) {
    h.update(p)
    h.update("\0")
    const abs = resolve(root, p)
    try {
      const st = statSync(abs)
      if (!st.isFile()) {
        h.update("not-a-file")
      } else if (st.size <= MAX_HASH_BYTES) {
        h.update(readFileSync(abs))
      } else {
        h.update(`${st.size}:${st.mtimeMs}`)
      }
    } catch {
      // Un percorso elencato da git ma non più leggibile (cancellato nel frattempo)
      // contribuisce come assente: è comunque un cambiamento.
      h.update("missing")
    }
    h.update("\0")
  }
  return h.digest("hex")
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
