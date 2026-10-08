import { test } from "node:test"
import assert from "node:assert/strict"
import { buildPrompt, extractVerify, judge, parseVerdict } from "../src/judge.ts"

test("parseVerdict accetta JSON nudo", () => {
  assert.deepEqual(parseVerdict('{"status":"done","reason":"tutti verdi"}'), {
    status: "done",
    reason: "tutti verdi",
  })
})

test("parseVerdict estrae il JSON da un code fence o da testo attorno", () => {
  assert.equal(parseVerdict('Ecco:\n```json\n{"status":"continue","reason":"manca X"}\n```').status, "continue")
  assert.equal(parseVerdict('bla {"status":"blocked","reason":"manca la GPU"} bla').status, "blocked")
})

test("parseVerdict rifiuta status sconosciuti, reason vuota e testo senza JSON", () => {
  assert.equal(parseVerdict('{"status":"quasi","reason":"x"}'), null)
  assert.equal(parseVerdict('{"status":"done","reason":""}'), null)
  assert.equal(parseVerdict("non lo so"), null)
})

test("extractVerify riconosce le forme accettate e ignora le altre", () => {
  assert.equal(extractVerify("finché non passa. Verify: `pytest -q`"), "pytest -q")
  assert.equal(extractVerify("condizione\n```bash\nnpm test\n```"), "npm test")
  assert.equal(extractVerify("m.py deve esporre g()"), null)
})

test("buildPrompt porta condizione, criteri, esito e output", () => {
  const p = buildPrompt(
    { condition: "tutti i test passano", accepts: ["nessuna regressione"], verify: "pytest -q" },
    { exitCode: 0, tail: "24 passed", timedOut: false },
  )
  assert.match(p, /tutti i test passano/)
  assert.match(p, /nessuna regressione/)
  assert.match(p, /exit 0/)
  assert.match(p, /24 passed/)
})

test("buildPrompt senza verify non parla di exit", () => {
  const p = buildPrompt({ condition: "m.py espone g()" }, null)
  assert.doesNotMatch(p, /exit \d/)
  assert.match(p, /m\.py espone g\(\)/)
})

test("un giudice che non risponde mai non produce done", async () => {
  const generate = async () => "non lo so"
  const v = await judge(generate, { condition: "x" }, null)
  assert.equal(v.status, "continue")
  assert.match(v.reason, /non raggiungibile/)
})

test("un giudice che lancia non produce done", async () => {
  const generate = async () => {
    throw new Error("provider giù")
  }
  const v = await judge(generate, { condition: "x" }, null)
  assert.equal(v.status, "continue")
})

test("il giudice ritorna il verdetto quando è valido", async () => {
  const generate = async () => '{"status":"blocked","reason":"manca la GPU"}'
  const v = await judge(generate, { condition: "x" }, null)
  assert.deepEqual(v, { status: "blocked", reason: "manca la GPU" })
})
