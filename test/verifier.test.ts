import { test } from "node:test"
import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { changedPaths, fingerprintSync, isExcluded, stalled, verifySync } from "../src/verifier.ts"

function withRepo<T>(fn: (root: string) => T): T {
  const root = mkdtempSync(join(tmpdir(), "goal-verifier-"))
  const git = (...args: string[]) => spawnSync("git", args, { cwd: root, encoding: "utf8" })
  git("init", "-q")
  git("-c", "user.email=a@b", "-c", "user.name=a", "commit", "-q", "--allow-empty", "-m", "init")
  try {
    return fn(root)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
}

test("le cache non contano come lavoro", () => {
  assert.equal(isExcluded("src/__pycache__/x.pyc"), true)
  assert.equal(isExcluded(".pytest_cache/v/cache/lastfailed"), true)
  assert.equal(isExcluded(".ruff_cache/0.1.0/x"), true)
  assert.equal(isExcluded(".venv/lib/python3.11/site-packages/x.py"), true)
  assert.equal(isExcluded("output/verification/analysis/run.json"), true)
  assert.equal(isExcluded("runs/latest/frame.png"), true)
  assert.equal(isExcluded(".opencode/goal/state.json"), true)
})

test("i sorgenti contano come lavoro", () => {
  assert.equal(isExcluded("src/cli.py"), false)
  assert.equal(isExcluded("tests/test_cli.py"), false)
})

test("senza VCS fingerprint lancia no-vcs invece di un hash costante", () => {
  const empty = mkdtempSync(join(tmpdir(), "goal-novcs-"))
  try {
    assert.throws(() => changedPaths(empty), /no-vcs/)
  } finally {
    rmSync(empty, { recursive: true, force: true })
  }
})

test("l'impronta ignora le cache e segue i sorgenti", () => {
  withRepo((root) => {
    mkdirSync(join(root, "src"), { recursive: true })
    mkdirSync(join(root, "__pycache__"), { recursive: true })
    writeFileSync(join(root, "src", "a.py"), "x = 1\n")
    writeFileSync(join(root, "__pycache__", "a.pyc"), "cache1\n")
    const before = fingerprintSync(root, changedPaths(root))

    writeFileSync(join(root, "__pycache__", "a.pyc"), "cache2\n")
    assert.equal(fingerprintSync(root, changedPaths(root)), before, "una cache non deve cambiare l'impronta")

    writeFileSync(join(root, "src", "a.py"), "x = 2\n")
    assert.notEqual(fingerprintSync(root, changedPaths(root)), before, "un sorgente deve cambiare l'impronta")
  })
})

test("stalled richiede rosso consecutivo E impronta invariata", () => {
  assert.equal(stalled({ redStreak: 5, turns: 5, unchanged: true }), true)
  assert.equal(stalled({ redStreak: 5, turns: 5, unchanged: false }), false)
  assert.equal(stalled({ redStreak: 4, turns: 9, unchanged: true }), false)
})

test("verifySync riporta l'exit code e l'output", () => {
  const r = verifySync({ command: "echo ciao; exit 3", cwd: process.cwd(), timeoutMs: 10000 })
  assert.equal(r.exitCode, 3)
  assert.match(r.tail, /ciao/)
  assert.equal(r.timedOut, false)
})

test("verifySync segnala il timeout invece di un exit code", () => {
  const r = verifySync({ command: "sleep 5", cwd: process.cwd(), timeoutMs: 500 })
  assert.equal(r.timedOut, true)
  assert.equal(r.exitCode, -1)
})
