import { test } from "node:test"
import assert from "node:assert/strict"
import { mkdtempSync, rmSync, writeFileSync, readFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import {
  acquireLease,
  blankState,
  isTerminal,
  readState,
  renewLease,
  statePath,
  writeState,
  type GoalState,
} from "../src/store.ts"

function withTmp<T>(fn: (root: string) => T): T {
  const root = mkdtempSync(join(tmpdir(), "goal-test-"))
  try {
    return fn(root)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
}

test("lo stato sta sotto .opencode/goal/state.json nella root", () => {
  assert.match(statePath("/proj"), /\.opencode\/goal\/state\.json$/)
})

test("lo stato sopravvive a un giro su disco", () => {
  withTmp((root) => {
    const s = blankState("ses_1", 1000, 30000)
    s.condition = "tutti i test passano"
    s.status = "running"
    writeState(root, s)
    const back = readState(root)
    assert.equal(back?.condition, "tutti i test passano")
    assert.equal(back?.status, "running")
  })
})

test("uno stato illeggibile non blocca il drainer: si riparte da zero", () => {
  withTmp((root) => {
    writeState(root, blankState("ses_1", 1000, 30000))
    writeFileSync(statePath(root), "{ troncato")
    assert.equal(readState(root), null)
  })
})

test("la scrittura è atomica: nessun file temporaneo lasciato indietro", () => {
  withTmp((root) => {
    writeState(root, blankState("ses_1", 1000, 30000))
    const raw = readFileSync(statePath(root), "utf8")
    assert.doesNotThrow(() => JSON.parse(raw))
    assert.throws(() => readFileSync(statePath(root) + ".tmp", "utf8"))
  })
})

test("il lease scaduto può essere preso da un'altra sessione", () => {
  const base: GoalState = { ...blankState("ses_1", 0, 0), lease: { expiresAt: 1000 } }
  const r = acquireLease(base, "ses_2", 5000, 30000)
  assert.equal(r.ok, true)
  assert.equal(r.state?.ownerSessionID, "ses_2")
})

test("un lease vivo blocca una seconda sessione e spiega perché", () => {
  const base: GoalState = { ...blankState("ses_1", 0, 0), lease: { expiresAt: 60000 } }
  const r = acquireLease(base, "ses_2", 5000, 30000)
  assert.equal(r.ok, false)
  assert.match(r.reason ?? "", /lease/)
  assert.match(r.reason ?? "", /ses_1/)
})

test("la stessa sessione riprende il proprio lease", () => {
  const base: GoalState = { ...blankState("ses_1", 0, 0), lease: { expiresAt: 60000 } }
  assert.equal(acquireLease(base, "ses_1", 5000, 30000).ok, true)
})

test("renewLease fallisce per una sessione che non è la proprietaria", () => {
  const base = blankState("ses_1", 0, 0)
  assert.equal(renewLease(base, "ses_2", 5000, 30000), false)
  assert.equal(renewLease(base, "ses_1", 5000, 30000), true)
  assert.equal(base.lease.expiresAt, 35000)
})

test("isTerminal riconosce gli stati conclusi", () => {
  assert.equal(isTerminal("achieved"), true)
  assert.equal(isTerminal("failed"), true)
  assert.equal(isTerminal("cleared"), true)
  assert.equal(isTerminal("stopped"), true)
  assert.equal(isTerminal("running"), false)
  assert.equal(isTerminal("paused-utente"), false)
  assert.equal(isTerminal("idle"), false)
})
