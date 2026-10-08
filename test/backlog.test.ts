import { test } from "node:test"
import assert from "node:assert/strict"
import { hasBlocked, nextOpen, parseBacklog, setStatus } from "../src/backlog.ts"

const DOC = `# Backlog

## [ ] B-01 — primo
Accetta:
- uno
- due
Verify: \`pytest -q\`

## [x] B-02 — secondo
Accetta:
- tre
Verify: \`pytest -q\`
`

test("estrae id, titolo, criteri e comando di verifica", () => {
  const items = parseBacklog(DOC)
  assert.equal(items.length, 2)
  assert.equal(items[0].id, "B-01")
  assert.equal(items[0].title, "primo")
  assert.deepEqual(items[0].accepts, ["uno", "due"])
  assert.equal(items[0].verify, "pytest -q")
  assert.equal(items[0].status, "open")
  assert.equal(items[1].status, "done")
})

test("un item senza Verify ha verify null e resta apribile", () => {
  const items = parseBacklog("## [ ] B-09 — senza verifica\nAccetta:\n- niente\n")
  assert.equal(items[0].verify, null)
})

test("nextOpen salta i done e restituisce il primo apribile", () => {
  const doc = "## [x] A-1 — chiuso\nVerify: `true`\n\n## [ ] A-2 — aperto\nVerify: `true`\n"
  assert.equal(nextOpen(parseBacklog(doc)).id, "A-2")
})

test("nextOpen su una coda tutta chiusa restituisce null", () => {
  const doneFirst = setStatus(DOC, "B-01", "done", {})
  assert.equal(nextOpen(parseBacklog(doneFirst)), null)
})

test("nextOpen considera apribile anche un item invalido", () => {
  const doc = "## [?] X-1 — invalido\n\n## [ ] X-2 — aperto\nVerify: `true`\n"
  assert.equal(nextOpen(parseBacklog(doc)).id, "X-1")
})

test("hasBlocked distingue coda svuotata da coda con bloccati", () => {
  assert.equal(hasBlocked(parseBacklog("## [!] B-01 — bloccato\nVerify: `x`\n")), true)
  assert.equal(hasBlocked(parseBacklog("## [x] B-01 — fatto\nVerify: `x`\n")), false)
})

test("setStatus riscrive il marker e aggiunge l'evidenza anche senza riga vuota finale", () => {
  const out = setStatus(DOC, "B-01", "done", { date: "2026-10-08", turns: 3, exitCode: 0 })
  assert.match(out, /## \[x\] B-01/)
  assert.match(out, /evidence:/)
  assert.match(out, /turns: 3/)
  assert.match(out, /exitCode: 0/)
})

test("setStatus non tocca gli altri item e non accumula evidenze", () => {
  const once = setStatus(DOC, "B-01", "done", { reason: "prima" })
  assert.match(once, /## \[x\] B-02/)
  const twice = setStatus(once, "B-01", "blocked", { reason: "seconda" })
  assert.equal((twice.match(/evidence:/g) ?? []).length, 1)
  assert.match(twice, /## \[!\] B-01/)
  assert.match(twice, /seconda/)
  assert.doesNotMatch(twice, /prima/)
})

test("setStatus su id inesistente restituisce il documento invariato", () => {
  assert.equal(setStatus(DOC, "B-99", "done", {}), DOC)
})
