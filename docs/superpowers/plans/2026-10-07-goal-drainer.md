# Goal Drainer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Un plugin OpenCode V2 che espone `/goal` e drena una backlog di item markdown, chiudendo ciascuno solo con una verifica deterministica più un verdetto di un giudice.

**Architecture:** Un plugin che si abbona allo stream SSE `/api/event` e reagisce a `session.execution.succeeded | failed | interrupted`. A ogni turno concluso esegue il comando `Verify:` dell'item via `POST /api/shell`, e solo se l'exit code è 0 chiede un verdetto a `POST /api/session/{id}/generate`. Il ciclo continua iniettando `session.synthetic` con il motivo del verdetto.

**Tech Stack:** TypeScript, `@opencode-ai/plugin` (solo per `Plugin.define`), `fetch` nativo verso `/api/*`, `node:test` + `tsx` per i test, nessuna dipendenza runtime.

**Spec:** `docs/superpowers/specs/2026-10-07-goal-drainer-design.md`

## Global Constraints

- Target: **opencode 2.0.14** installato in `/home/ld/.opencode/bin/opencode`. Tutto ciò che non è misurato su questa build è da verificare, non da assumere.
- **Non usare `@opencode-ai/sdk`**: i suoi typings 1.18.18 puntano a rotte inesistenti (`POST /session` → 405). Solo `fetch` su `/api/*`.
- **`session.idle` non viene emesso.** Non usarlo come trigger, non usarlo nei test, non scriverlo nei commenti se non per spiegare perché è stato escluso.
- Il trigger è `session.execution.succeeded | failed | interrupted`, filtrato per `data.sessionID`.
- Il giudice è `POST /api/session/{id}/generate` con `{prompt}`. **Non** creare sessioni figlie: `POST /api/session` non accetta `parentID`.
- Auto-approva solo con `decision: "once"`. **Mai** `"always"`: scrive in `/api/permission/saved` per progetto e sopravvive a sessione, goal e riavvio.
- `external_directory` non è mai auto-approvato.
- La spesa si conta solo per modelli `opencode-go/*`. I free tier non hanno tetto e vanno dichiarati come tali.
- `budgetPercent` default **10**.
- `stallTurns` default **5**; `verifyTimeoutMs` default **600000**; `watchdogMs` default **1800000**.
- Un item senza `Verify:` non vuoto è `invalid` e non viene mai tentato.
- `[!]` (blocked) è reversibile e **non** conta come coda svuotata.
- La directory di lavoro di ogni comando è `/home/ld/foosball-vision`.
- Un passo = un'azione con risultato verificabile. Se un passo contiene due azioni, è due passi.

## Review Focus

Cinque classi di input che la spec implica e che nessun test dei task copre ancora. Ogni riga ha il suo test nel task che possiede il codice.

1. **Percorso non-git.** La spec dice che l'anti-livelock è disattivato senza VCS. Un progetto senza `.git` deve girare senza crash e senza `blocked` automatici, non deve bloccare e non deve inventare un'impronta. Test in Task 5.
2. **Progetto con `.venv/` e `output/` pieni di file che cambiano a ogni run.** È il caso reale di foosball-vision: senza le esclusioni l'impronta cambia sempre e il `blocked` automatico non arriva mai. Test in Task 5.
3. **Il giudice che risponde solo `blocked`.** Un modello così svuoterebbe la coda a costo zero dichiarando successo. Il report deve dire "svuotata con N bloccati" e `pickNext()` deve continuare a restituire gli `[!]` a `retry`. Test in Task 6.
4. **Un prompt dell'utente che arriva mentre il ciclo gira.** Deve mettere il goal in pausa, non essere letto dal worker come se fosse la continuazione del drainer. Test in Task 7.
5. **`state.json` scritto da due processi.** Due finestre opencode sullo stesso progetto non possono fare `pickNext()` sullo stesso item né lanciare `pytest` in parallelo sulla stessa working tree. Test in Task 4.

---

### Task 1: Probe del substrato

**Files:**
- Create: `probe/run.sh`
- Create: `probe/README.md`
- Test: nessun test automatico — la probe produce un report che un essere umano legge

**Interfaces:**
- Consumes: nulla
- Produces: `probe/FINDINGS.md`, che fissa per iscritto le risposte alle sei domande sotto. Ogni task successivo cita `probe/FINDINGS.md` invece di supporre.

Il task esiste perché la spec è già stata scritta una volta su substrato sbagliato, e la v2 è stata corretta proprio grazie a una misura. Questo task è la misura.

- [ ] **Step 1: scrivi `probe/run.sh`**

Deve accettare `PORT` e `ROOT`, e fare sei prove. Skeleton:

```bash
#!/usr/bin/env bash
# uso: PORT=4599 ROOT=/tmp/opencode/probe-home ./run.sh
set -euo pipefail
PORT="${PORT:?}"
ROOT="${ROOT:?}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/out"
mkdir -p "$OUT"
```

Poi, in ordine:

1. Avvia `HOME=$ROOT XDG_CONFIG_HOME=$ROOT/.config opencode serve --port "$PORT" --hostname 127.0.0.1` in background, scrivendo il log in `$OUT/serve.log`. Estrai la password dalla riga `server password …`.
2. Aspetta che la porta risponda. Sonda con `curl -u "opencode:$PW" http://127.0.0.1:$PORT/api/info` in loop fino a 30 tentativi da 1 secondo.
3. **Domanda 1 — `command.transform` espone `add`?** Non si può chiedere al server: va chiesto al runtime del plugin. Scrivi `probe/plugin-probe/index.ts` che registra un tool e, in `setup`, chiama `ctx.command.transform` stampando `Object.keys(editor)` e per ogni chiave se è funzione; poi registra il comando con `add` dentro un `try/catch` e riporta se ha funzionato.
4. **Domanda 2 — forma di `tool.transform`.** Nello stesso plugin, registra un tool e dentro `execute` stampa `Object.keys(ctx)` e `Object.keys(input)`. Scrivi il risultato in un file.
5. **Domanda 3 — `POST /api/session` accetta `parentID`?** Crea una sessione con `{"directory":"$ROOT/work","title":"child-probe","parentID":"ses_nonexistent"}`, poi `GET /api/session` e cerca un campo `parentID` in risposta, e `GET /api/session/<id>/children` per lo status code. Riporta entrambi.
6. **Domanda 4 — `session.generate`.** Crea una sessione con `model: {providerID:"opencode", id:"space-bunny-free"}`, invia un prompt `"Rispondi esattamente: ok"`, aspetta `session.execution.succeeded` sullo stream SSE, poi chiama `POST /api/session/<id>/generate` con `{"prompt":"Rispondi SOLO con questo JSON: {\"status\":\"continue\",\"reason\":\"ok\"}"}`. Riporta: il testo ricevuto, `GET /api/session/<id>/message` prima e dopo (conta i messaggi), e `cost`/`tokens` della sessione prima e dopo. Voglio sapere se è davvero stateless e se tocca il contatore.
7. **Domanda 5 — `/api/shell`.** `POST /api/shell` con `{"command":"exit 3","cwd":"$ROOT/work"}`, poi in loop `GET /api/shell/<id>` finché lo stato è terminale. Riporta il campo esatto che contiene l'exit code. Poi ripeti con `{"command":"sleep 30","timeout":2000}` e riporta cosa succede al timeout. Poi `GET /api/shell` e riporta se il comando uscito è ancora in lista.
8. **Domanda 6 — `failed` e `interrupted`.** Avvia un listener SSE. Invia un prompt che il modello non può soddisfare e, mentre gira, `POST /api/session/<id>/interrupt`. Riporta quali `session.execution.*` arrivano e con quali campi.
9. In ogni prova apri il listener SSE **prima** dell'azione che la deve generare, e salva tutte le righe `data: …` in `$OUT/events-<n>.log`.
10. Scrivi `$OUT/FINDINGS.md` con una sezione per domanda: **risposta**, **come è stata misurata**, **cosa cambia nella spec se la risposta è diversa da quella prevista**.

- [ ] **Step 2: esegui la probe**

Run: `PORT=4599 ROOT=/tmp/opencode/probe-home bash probe/run.sh`
Expected: exit 0, `probe/out/FINDINGS.md` esistente e con sei sezioni. Se una prova non è riuscita, la sezione dice **non misurato** con l'errore — non inventare un valore.

- [ ] **Step 3: verifica che la spec regga le risposte**

Run: `grep -c 'session.idle' probe/out/FINDINGS.md` → atteso `0` o un commento esplicito sul perché è citato.
Run: `grep -A5 'Domanda 3' probe/out/FINDINGS.md` → se dice che `parentID` **funziona**, la spec v2 §5 è superata dal fatto e il giudice potrebbe avere un modello proprio: fermati e segnalalo, non proseguire con i task seguenti.
Expected: tutte le sei domande hanno una risposta o un "non misurato" motivato.

- [ ] **Step 4: commit**

```bash
git add probe/
git commit -m "probe: misura del substrato runtime su opencode 2.0.14"
```

---

### Task 2: `api.ts` — trasporto verso il server

**Files:**
- Create: `src/api.ts`
- Create: `test/api.test.ts`
- Modify: `package.json` (scripts `test`, `typecheck`)

**Interfaces:**
- Consumes: `probe/FINDINGS.md` per sapere se `baseURL` e autenticazione arrivano dal ctx
- Produces:
  ```ts
  export type ApiOptions = { baseURL: string; password: string }
  export function createApi(opts: ApiOptions): Api
  export interface Api {
    shellCreate(input: { command: string; cwd: string; timeout?: number }): Promise<{ id: string }>
    shellGet(id: string): Promise<{ status: string; exitCode: number | null }>
    shellOutput(id: string): Promise<string>
    shellRemove(id: string): Promise<void>
    sessionGenerate(sessionID: string, prompt: string): Promise<string>
    sessionSynthetic(sessionID: string, input: { text: string; metadata?: Record<string, unknown> }): Promise<void>
    sessionMessages(sessionID: string): Promise<{ count: number; cost: number; tokens: TokenUsage }>
    vcsStatus(): Promise<{ files: { path: string; status: string }[] }>
    permissionReply(sessionID: string, requestID: string, decision: "once" | "always"): Promise<void>
    subscribeEvents(signal: AbortSignal): AsyncIterable<ServerEvent>
  }
  export interface TokenUsage { input: number; output: number; reasoning: number; cache: { read: number; write: number } }
  export interface ServerEvent {
    type: string
    data: Record<string, unknown>
    durable?: { aggregateID: string; seq: number; version: number }
  }
  ```

- [ ] **Step 1: scrivi il test del parsing della risposta**

```ts
import { test } from "node:test"
import assert from "node:assert/strict"
import { parseEnvelope, parseSseLine, unwrapData } from "../src/api.ts"

test("unwrapData scarta l'involucro data e tiene gli eventi utili", () => {
  assert.deepEqual(unwrapData({ data: { id: "ses_1", title: "x" } }).id, "ses_1")
})

test("parseSseLine legge una riga data: e ne ricava il type", () => {
  const line = 'data: {"id":"evt_1","type":"session.execution.succeeded","data":{"sessionID":"ses_1"}}'
  const ev = parseSseLine(line)
  assert.equal(ev.type, "session.execution.succeeded")
  assert.equal(ev.data.sessionID, "ses_1")
})

test("parseSseLine su una riga non-data restituisce null", () => {
  assert.equal(parseSseLine(": keep-alive"), null)
})

test("parseEnvelope segnala i non-2xx con il corpo per il debugging", () => {
  const e = parseEnvelope(404, '{"_tag":"SessionNotFoundError"}')
  assert.equal(e.ok, false)
  assert.equal(e.status, 404)
  assert.match(e.body, /SessionNotFoundError/)
})
```

- [ ] **Step 2: esegui il test e verifica che fallisce**

Run: `npm test`
Expected: FAIL con "Cannot find module '../src/api.ts'"

- [ ] **Step 3: implementa `src/api.ts`**

Esporta i tre helper puri richiesti dal test, con queste firme esatte:

```ts
export function parseEnvelope(status: number, body: string): { ok: boolean; status: number; body: string }
export function parseSseLine(line: string): ServerEvent | null
export function unwrapData<T>(envelope: { data: T }): T
```

`parseSseLine` accetta solo righe che iniziano con `data: `, fa `JSON.parse` del resto, e restituisce `null` se il parse fallisce o se `type` manca. Tutti gli endpoint sotto `/api`. Autenticazione `Authorization: Basic base64("opencode:" + password)`. `subscribeEvents` fa `fetch` sullo stream `/api/event` con lo `signal` passato a `AbortSignal` e itera le righe.

Ogni metodo non-2xx lancia un errore che contiene status e body: un body tipo `{"_tag":"PermissionNotFoundError"}` è la sola diagnostica utile.

- [ ] **Step 4: esegui il test e verifica che passa**

Run: `npm test`
Expected: PASS, 4 test

- [ ] **Step 5: commit**

```bash
git add src/api.ts test/api.test.ts package.json
git commit -m "feat: trasporto verso /api con fetch e parser SSE"
```

---

### Task 3: `backlog.ts` — il formato degli item

**Files:**
- Create: `src/backlog.ts`
- Create: `test/backlog.test.ts`

**Interfaces:**
- Consumes: nulla
- Produces:
  ```ts
  export type ItemStatus = "open" | "done" | "blocked" | "invalid"
  export interface Item {
    id: string
    title: string
    status: ItemStatus
    accepts: string[]
    verify: string | null
    evidence: { date?: string; turns?: number; exitCode?: number | null; reason?: string }
  }
  export function parseBacklog(markdown: string): Item[]
  export function renderItem(item: Item): string
  export function nextOpen(items: Item[]): Item | null
  export function hasBlocked(items: Item[]): boolean
  export function setStatus(markdown: string, id: string, status: ItemStatus, evidence: Item["evidence"]): string
  ```

- [ ] **Step 1: scrivi i test del parser**

```ts
import { test } from "node:test"
import assert from "node:assert/strict"
import { parseBacklog, nextOpen, hasBlocked, setStatus } from "../src/backlog.ts"

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
})

test("un item senza Verify resta open ma ha verify null", () => {
  const items = parseBacklog("## [ ] B-09 — senza verifica\nAccetta:\n- niente\n")
  assert.equal(items[0].verify, null)
})

test("nextOpen salta i done e restituisce il primo aperto", () => {
  const items = parseBacklog(DOC)
  assert.equal(nextOpen(items).id, "B-02")  // B-01 è done dopo setStatus, vedi test sotto
})
```

Aggiungi il test che fissa `nextOpen` sul documento giusto: `nextOpen` deve restituire `B-01` su `DOC` non modificato, e `B-03` se `B-01` è marcato done. Scrivilo esplicitamente così l'intento è chiaro.

```ts
test("hasBlocked distingue coda svuotata da coda con bloccati", () => {
  assert.equal(hasBlocked(parseBacklog("## [!] B-01 — bloccato\nVerify: `x`\n")), true)
  assert.equal(hasBlocked(parseBacklog("## [x] B-01 — fatto\nVerify: `x`\n")), false)
})

test("setStatus riscrive il marker e aggiunge l'evidenza", () => {
  const out = setStatus(DOC, "B-01", "done", { date: "2026-10-07", turns: 3, exitCode: 0 })
  assert.match(out, /## \[x\] B-01/)
  assert.match(out, /turns: 3/)
  assert.match(out, /exitCode: 0/)
})

test("setStatus su id inesistente restituisce il documento invariato", () => {
  assert.equal(setStatus(DOC, "B-99", "done", {}), DOC)
})
```

- [ ] **Step 2: esegui i test e verifica che falliscono**

Run: `npm test`
Expected: FAIL con "Cannot find module '../src/backlog.ts'"

- [ ] **Step 3: implementa `src/backlog.ts`**

`parseBacklog` splitta su righe che iniziano con `## `, poi dentro ogni blocco cerca `Accetta:` (righe `- ` fino alla riga successiva che non è di lista), `Verify:` (tutto ciò che segue i backtick, o l'intera riga se non ci sono backtick) ed `evidence:` (un blocco `key: value` finale). Lo status viene dal marker `[ ]` `[x]` `[!]` `[?]`.

`setStatus` sostituisce solo la riga dell'item e rimuove un eventuale blocco `evidence:` precedente prima di appendere il nuovo, così un `retry` non accumula prove stale. Se l'id non esiste, restituisce l'input identico.

`nextOpen` restituisce il primo item con status `open` **o** `invalid`: un item invalido non deve bloccare la coda. `hasBlocked` restituisce `true` se esiste almeno un `blocked`.

- [ ] **Step 4: esegui i test e verifica che passano**

Run: `npm test`
Expected: PASS

- [ ] **Step 5: commit**

```bash
git add src/backlog.ts test/backlog.test.ts
git commit -m "feat: parser della backlog con stati done/blocked/invalid reversibili"
```

---

### Task 4: `store.ts` — stato su disco con lease

**Files:**
- Create: `src/store.ts`
- Create: `test/store.test.ts`

**Interfaces:**
- Consumes: `Item` da `src/backlog.ts` (Task 3)
- Produces:
  ```ts
  export interface GoalState {
    ownerSessionID: string
    status: "idle" | "running" | "paused-utente" | "stopped"
    backlogPath: string
    current: string | null
    turns: number
    spend: Record<string, { cost: number; tokens: TokenUsage }>
    lease: { expiresAt: number }
    lastReason: string | null
    updatedAt: number
  }
  export function statePath(root: string): string
  export async function readState(root: string): Promise<GoalState | null>
  export async function writeState(root: string, s: GoalState): Promise<void>
  export function acquireLease(s: GoalState | null, sessionID: string, now: number, ttlMs: number): { ok: boolean; reason?: string; state?: GoalState }
  export function renewLease(s: GoalState, sessionID: string, now: number, ttlMs: number): boolean
  ```

- [ ] **Step 1: scrivi i test del lease**

```ts
import { test } from "node:test"
import assert from "node:assert/strict"
import { acquireLease, renewLease, statePath, type GoalState } from "../src/store.ts"

const base: GoalState = {
  ownerSessionID: "ses_1", status: "idle", backlogPath: "docs/backlog.md",
  current: null, turns: 0, spend: {}, lease: { expiresAt: 1000 },
  lastReason: null, updatedAt: 0,
}

test("il lease scaduto può essere preso da un'altra sessione", () => {
  const r = acquireLease(base, "ses_2", 5000, 30000)
  assert.equal(r.ok, true)
  assert.equal(r.state.ownerSessionID, "ses_2")
})

test("un lease vivo blocca una seconda sessione", () => {
  const r = acquireLease({ ...base, lease: { expiresAt: 60000 } }, "ses_2", 5000, 30000)
  assert.equal(r.ok, false)
  assert.match(r.reason, /lease/)
})

test("la stessa sessione riprende il proprio lease", () => {
  const r = acquireLease({ ...base, lease: { expiresAt: 60000 } }, "ses_1", 5000, 30000)
  assert.equal(r.ok, true)
})

test("renewLease fallisce per una sessione che non è la proprietaria", () => {
  assert.equal(renewLease(base, "ses_2", 5000, 30000), false)
})

test("lo stato sta sotto .opencode/goal/state.json nella root", () => {
  assert.match(statePath("/proj"), /\.opencode\/goal\/state\.json$/)
})
```

- [ ] **Step 2: esegui i test e verifica che falliscono**

Run: `npm test`
Expected: FAIL con "Cannot find module '../src/store.ts'"

- [ ] **Step 3: implementa `src/store.ts`**

`statePath` usa `path.join(root, ".opencode", "goal", "state.json")`. `readState` restituisce `null` se il file non esiste o se il JSON non è valido — uno stato illeggibile non deve bloccare il drainer, deve ripartire da zero. `writeState` crea la directory e scrive in modo atomico (`writeFile` su `state.json.tmp` poi `rename`), perché un `state.json` troncato a metà è peggio di uno assente.

`acquireLease`: se `s` è `null`, crea uno stato nuovo di proprietà. Se `s.ownerSessionID === sessionID`, rinnova e ok. Altrimenti ok solo se `now >= s.lease.expiresAt`.

- [ ] **Step 4: esegui i test e verifica che passano**

Run: `npm test`
Expected: PASS

- [ ] **Step 5: commit**

```bash
git add src/store.ts test/store.test.ts
git commit -m "feat: stato su disco con lease e scrittura atomica"
```

---

### Task 5: `verifier.ts` — la verifica deterministica

**Files:**
- Create: `src/verifier.ts`
- Create: `test/verifier.test.ts`
- Create: `test/fixtures/proj/` con `.git/`, un sorgente, e un `.gitignore` che esclude `__pycache__/`

**Interfaces:**
- Consumes: `Api` da `src/api.ts` (Task 2)
- Produces:
  ```ts
  export const FINGERPRINT_EXCLUDES: string[]
  export function fingerprintPath(paths: string[]): string
  export function isExcluded(path: string): boolean
  export interface VerifyResult { exitCode: number; tail: string; timedOut: boolean }
  export async function verify(api: Api, input: { command: string; cwd: string; timeoutMs: number }): Promise<VerifyResult>
  export async function fingerprint(api: Api): Promise<string>
  export function stalled(input: { redStreak: number; turns: number; unchanged: boolean }): boolean
  ```

- [ ] **Step 1: scrivi i test delle esclusioni e dello stall**

```ts
import { test } from "node:test"
import assert from "node:assert/strict"
import { isExcluded, fingerprintPath, stalled } from "../src/verifier.ts"

test("le cache non contano come lavoro", () => {
  assert.equal(isExcluded("src/foosball/__pycache__/x.pyc"), true)
  assert.equal(isExcluded(".pytest_cache/v/cache/lastfailed"), true)
  assert.equal(isExcluded(".ruff_cache/0.1.0/x"), true)
  assert.equal(isExcluded(".venv/lib/python3.11/site-packages/x.py"), true)
  assert.equal(isExcluded("output/verification/analysis/run.json"), true)
  assert.equal(isExcluded("runs/latest/frame.png"), true)
  assert.equal(isExcluded(".opencode/goal/state.json"), true)
})

test("i sorgenti contano come lavoro", () => {
  assert.equal(isExcluded("src/foosball/cli.py"), false)
  assert.equal(isExcluded("tests/test_cli.py"), false)
})

test("l'impronta cambia se un sorgente cambia e non se una cache cambia", () => {
  const a = fingerprintPath(["src/a.py", "__pycache__/a.pyc", ".pytest_cache/x"])
  const b = fingerprintPath(["src/a.py", "__pycache__/b.pyc", ".pytest_cache/y"])
  assert.equal(a, b, "le cache non devono cambiare l'impronta")
  const c = fingerprintPath(["src/b.py", "__pycache__/a.pyc"])
  assert.notEqual(a, c)
})

test("lo stall richiede rosso consecutivo E impronta invariata", () => {
  assert.equal(stalled({ redStreak: 5, turns: 5, unchanged: true }), true)
  assert.equal(stalled({ redStreak: 5, turns: 5, unchanged: false }), false)
  assert.equal(stalled({ redStreak: 4, turns: 9, unchanged: true }), false)
})

test("senza VCS fingerprint lancia no-vcs invece di restituire un hash costante", async () => {
  const fake = { vcsStatus: async () => ({ files: [] }) } as unknown as Api
  await assert.rejects(() => fingerprint(fake), /no-vcs/)
})
```

Il test `no-vcs` è la ragione per cui quel caso è una Review Focus: un hash costante
sembrerebbe "nessun lavoro" e bloccherebbe ogni item senza dirlo.

- [ ] **Step 2: esegui i test e verifica che falliscono**

Run: `npm test`
Expected: FAIL con "Cannot find module '../src/verifier.ts'"

- [ ] **Step 3: implementa `src/verifier.ts`**

`FINGERPRINT_EXCLUDES` è la lista esatta: `[".git/", "node_modules/", ".venv/", "__pycache__/", ".pytest_cache/", ".ruff_cache/", "dist/", "build/", "output/", "runs/", ".opencode/goal/"]`. `isExcluded` controlla se il path normalizzato inizia con uno di questi.

`fingerprint` chiama `api.vcsStatus()`, tiene i path non esclusi, e se **non ne trova nessuno** lancia un errore con messaggio `"no-vcs"`. Quel messaggio è il segnale che il chiamante usa per disattivare l'anti-livelock invece di trattare tutto come invariato. Non ritornare `"0"` in quel caso: un'hash costante sembrerebbe progresso zero e bloccherebbe tutto.

`verify` chiama `api.shellCreate`, poi `api.shellGet` in loop ogni 500ms finché lo stato è terminale o passa `timeoutMs`. Al timeout chiama `api.shellRemove` e restituisce `{ exitCode: -1, tail, timedOut: true }`. `tail` sono gli ultimi 4000 caratteri di `api.shellOutput`.

`stalled` è pura: `redStreak >= 5 && unchanged && turns > redStreak`.

- [ ] **Step 4: esegui i test e verifica che passano**

Run: `npm test`
Expected: PASS

- [ ] **Step 5: verifica il caso reale su foosball-vision**

Run: `node --experimental-strip-types -e "…"` che istanzia `Api` contro il servizio reale, chiama `fingerprint` due volte lontano da un run di pytest, e poi dentro `uv run --frozen pytest -q`, e verifica che l'impronta resti uguale.
Expected: le due impronte **prima** sono diverse, e l'impronta **dopo** pytest è uguale a quella di prima. Se cambia, le esclusioni non bastano e il `blocked` automatico scatterà mai.

- [ ] **Step 6: commit**

```bash
git add src/verifier.ts test/verifier.test.ts test/fixtures/
git commit -m "feat: verifica deterministica con impronta che ignora le cache"
```

---

### Task 6: `judge.ts` — il verdetto

**Files:**
- Create: `src/judge.ts`
- Create: `test/judge.test.ts`

**Interfaces:**
- Consumes: `Api` (Task 2), `Item` (Task 3)
- Produces:
  ```ts
  export type Verdict = { status: "done" | "continue" | "blocked"; reason: string }
  export function buildPrompt(item: Item, v: VerifyResult): string
  export function parseVerdict(text: string): Verdict | null
  export async function judge(api: Api, sessionID: string, item: Item, v: VerifyResult): Promise<Verdict>
  ```

- [ ] **Step 1: scrivi i test del parsing del verdetto**

```ts
import { test } from "node:test"
import assert from "node:assert/strict"
import { buildPrompt, parseVerdict } from "../src/judge.ts"

test("parseVerdict accetta JSON nudo", () => {
  assert.deepEqual(parseVerdict('{"status":"done","reason":"tutti verdi"}'),
    { status: "done", reason: "tutti verdi" })
})

test("parseVerdict estrae il JSON da un code fence", () => {
  const t = "Ecco il verdetto:\n```json\n{\"status\":\"continue\",\"reason\":\"manca X\"}\n```\nfine"
  assert.equal(parseVerdict(t).status, "continue")
})

test("parseVerdict rifiuta uno status sconosciuto", () => {
  assert.equal(parseVerdict('{"status":"quasi","reason":"x"}'), null)
})

test("parseVerdict rifiuta testo senza JSON", () => {
  assert.equal(parseVerdict("non lo so"), null)
})

test("il secondo errore del giudice non produce mai done", async () => {
  const fake = { sessionGenerate: async () => "non lo so" } as unknown as Api
  const v = await judge(fake, "ses_1", ITEM, { exitCode: 0, tail: "", timedOut: false })
  assert.equal(v.status, "continue")
  assert.match(v.reason, /non raggiungibile/)
})

test("buildPrompt porta obiettivo, criteri ed exit code", () => {
  const p = buildPrompt(
    { id: "B-01", title: "geometria", status: "open", accepts: ["errore <1%"], verify: "pytest -q", evidence: {} },
    { exitCode: 0, tail: "24 passed", timedOut: false })
  assert.match(p, /geometria/)
  assert.match(p, /errore <1%/)
  assert.match(p, /exit 0/)
  assert.match(p, /24 passed/)
  assert.doesNotMatch(p, /pytest -q\n\nRispondi SOLO/)
})
```

L'ultimo asserto è il punto: il prompt **non** deve contenere il transcript, perché `session.generate` lo porta già dal contesto della sessione.

- [ ] **Step 2: esegui i test e verifica che falliscono**

Run: `npm test`
Expected: FAIL con "Cannot find module '../src/judge.ts'"

- [ ] **Step 3: implementa `src/judge.ts`**

`buildPrompt` produce: obiettivo (titolo), criteri di accettazione uno per riga, il comando e il suo `exit N`, gli ultimi 4000 caratteri di output, e il contratto del verdetto con le tre regole — in particolare che `blocked` è **solo** per un prerequisito che nessun lavoro può creare, e **non** per "non ho ancora lavorato".

`parseVerdict` prova `JSON.parse` sul testo intero; se fallisce, prende il primo `{` e l'ultimo `}` e riprova; se ancora fallisce, cerca un code fence. Validazione: `status` deve essere uno dei tre, `reason` stringa non vuota. Altrimenti `null`.

`judge` chiama `api.sessionGenerate` fino a due volte se `parseVerdict` restituisce `null`. Al secondo fallimento **non** lancia: restituisce `{ status: "continue", reason: "giudice non raggiungibile" }`. Un errore del giudice non può mai produrre `done`.

- [ ] **Step 4: esegui i test e verifica che passano**

Run: `npm test`
Expected: PASS

- [ ] **Step 5: verifica che la risposta sia deterministica sul servizio reale**

Run: uno script che crea una sessione con `space-bunny-free`, esegue un turno, e chiama `buildPrompt` + `sessionGenerate` con un item finto la cui verifica è verde, tre volte.
Expected: le tre risposte sono JSON validi. Se il modello gratis non rispetta il contratto, il fallback è stringa: stringa `status=continue` e non va trattato come blocker.

- [ ] **Step 6: commit**

```bash
git add src/judge.ts test/judge.test.ts
git commit -m "feat: verdetto del giudice su session.generate senza transcript nel prompt"
```

---

### Task 7: `index.ts` — il plugin e il ciclo

**Files:**
- Create: `src/index.ts`
- Create: `test/cycle.test.ts`
- Create: `README.md`

**Interfaces:**
- Consumes: `Api` (2), `backlog.ts` (3), `store.ts` (4), `verifier.ts` (5), `judge.ts` (6)
- Produces: il plugin registrato. Tool `goal_control` con azioni `start | status | stop | report | retry`.

- [ ] **Step 1: scrivi i test del ciclo con un `Api` finto**

Il finto implementa `Api` e conta le chiamate. Casi:

```ts
test("verifica rossa e giudice mai consultato", async () => { /* exitCode 1 → zero sessionGenerate */ })
test("verifica verde e giudice done → item marcato done e si passa al successivo", async () => { /* due item */ })
test("verifica verde e giudice blocked → item [!] e la coda non è svuotata", async () => {
  // dopo il giro: il primo item è [!], hasBlocked è true, e lo stop dice
  // "coda svuotata con 1 bloccati" e non "coda svuotata"
})
test("un giudice che risponde sempre blocked non conclude la coda", async () => {
  // tutti gli item diventano [!]; lo stop NON dice "coda svuotata" e
  // nextOpen sugli item aggiornati non restituisce un [x]
})
test("verifica rossa per 5 turni con impronta invariata → blocked automatico", async () => { /* senza chiamare il giudice */ })
test("tetto di budget superato → stop, nessun synthetic", async () => { /* spend già sopra */ })
test("form aperta → abort del goal con motivo", async () => { /* evento form.created */ })
test("prompt utente in arrivo → stato paused-utente e nessun synthetic", async () => { /* inbox enqueued senza metadata.source */ })
test("execution.interrupted → il turno non conta come succeeded e non reinietta", async () => { })
test("execution.failed → stesso trattamento di interrupted", async () => { })
test("lease di un'altra sessione → start rifiutato con motivo", async () => { })

test("la spesa degli eventi riconcilia con il costo dei messaggi", async () => {
  // dopo due turni: la somma di spend da session.usage.updated è uguale
  // a cost di sessionMessages(). Se diverge di più dell'1%, /goal report
  // lo segnala invece di fidarsi del contatore push
})
```

- [ ] **Step 2: esegui i test e verifica che falliscono**

Run: `npm test`
Expected: FAIL con "Cannot find module '../src/index.ts'"

- [ ] **Step 3: implementa `src/index.ts` — bootstrap, tool, eventi**

Esporta `export const GoalPlugin = Plugin.define({ id: "goal-drainer", async setup(ctx) { … } })`.

In `setup`: leggi le opzioni da `ctx.options` con i default del Global Constraints, costruisci `createApi` con `baseURL` e password presi dal ctx (secondo `probe/FINDINGS.md`), registra il tool `goal_control` con input `{ action, backlogPath?, itemId? }` e una descrizione che dice cosa fa ogni azione. Se `command.transform` espone `add` (Task 1, domanda 1), registra anche il comando `goal` che inoltra ad `action: "start"` con `backlogPath` da `$ARGUMENTS`.

Apri il flusso eventi con `api.subscribeEvents(controller.signal)` e tieni il `AbortController` in
closure; `setup` deve restituire una funzione di cleanup che chiama `controller.abort()` e
rilascia il lease. Senza quella, un reload del plugin lascia un listener vivo che continua a
scrivere `state.json` accanto a un drainer nuovo, e i due si contendono il lease senza che nessuno
lo sappia.

`/goal status` chiama `api.sessionMessages(sessionID)` e confronta `cost` con la somma di `spend`
accumulata dagli eventi: se divergono di più dell'1%, il report lo dice invece di fidarsi del
contatore push.

- [ ] **Step 4: implementa il supervisore**

Il gestore eventi, in ordine di precedenza, per `event.data.sessionID` pari al `ownerSessionID`:

1. `session.form.created` → `stop("form aperto: il drainer non aspetta un umano")`
2. `session.inbox.enqueued` con `metadata.source !== "goal-drainer"` → `status = "paused-utente"`
3. `session.usage.updated` → accumula `spend[providerID/modelID]` e confronta con le soglie.
   La tabella dei limiti, se `monthlyLimitsUSD` non la sovrascrive, è:
   ```ts
   const GO_MONTHLY_LIMIT_USD: Record<string, number> = {
     "opencode-go/space-bunny": 30,
     "opencode-go/muse-spark-1.3-contributor": 60,
     "opencode-go/muse-spark-1.2-contributor": 60,
     "opencode-go/deepseek-v4-pro": 15,
     "opencode-go/deepseek-v4.1-flash": 60,
     "opencode-go/deepseek-v4-flash": 30,
     "opencode-go/deepseek-v4-flash-vision-exp": 15,
     "opencode-go/qwen3.7-plus": 60,
     "opencode-go/qwen3.8-flash": 30,
     "opencode-go/qwen3.8-max": 15,
     "opencode-go/glm-5.2": 60,
     "opencode-go/glm-5.3": 15,
     "opencode-go/glm-5.3-flash": 60,
     "opencode-go/mimo-v2.5": 60,
     "opencode-go/mimo-v2.5-pro": 15,
     "opencode-go/mimo-v2.6-flash": 60,
     "opencode-go/mimo-v2.6-pro": 15,
     "opencode-go/minimax-m2.7": 60,
     "opencode-go/minimax-m3": 60,
     "opencode-go/kimi-k2.7-code": 60,
     "opencode-go/kimi-k3": 15,
     "opencode-go/longcat-2.0": 60,
     "opencode-go/hy3": 60,
     "opencode-go/hy4-preview": 30,
     "opencode-go/grok-4.6": 15,
     "opencode-go/grok-4.7": 15,
     "opencode-go/gpt-6-luna": 15,
     "opencode-go/gpt-5.6-luna": 15,
   }
   ```
   Un modello assente dalla tabella non ferma mai: viene riportato in token con la riga
   "nessun tetto noto per questo modello". `/goal report` mostra per ogni modello tre soglie —
   mensile (`budgetPercent`), settimanale (50%) e 5 ore (20%) — e segnala quando la spesa della
   run è concentrata in una finestra 5 ore, senza fermare nulla.
4. `session.execution.succeeded` → `onTurnEnd()`
5. `session.execution.failed | interrupted` →azzera `redStreak`, scrive `lastReason`, non reinietta

`onTurnEnd` è il cuore e deve essere una funzione pura-ish, testabile con l'`Api` finto:

```
se status !== "running" → return
se !renewLease → stop("lease perso") e return
item = nextOpen(items); se null → stop(hasBlocked ? "coda svuotata con N bloccati" : "coda svuotata")
v = await verify(...)
if v.exitCode !== 0:
    redStreak++; unchanged = fingerprint uguale alla precedente
    se stalled(...) → markBlocked(item, "verifica rossa senza modifiche"); redStreak = 0
    altrimenti → api.sessionSynthetic(sessionID, { text: "Check rosso (exit " + v.exitCode + ").\nOutput:\n" + v.tail, metadata: { source: "goal-drainer" } })
    return
redStreak = 0
se verdict.status === "done" → markDone(item, v); continua al prossimo item con la stessa onTurnEnd
se verdict.status === "blocked" → markBlocked(item, verdict.reason)
altrimenti → api.sessionSynthetic(sessionID, { text: verdict.reason, metadata: { source: "goal-drainer" } })
```

Ogni chiamata a `sessionSynthetic` porta `metadata: { source: "goal-drainer" }`: è il marcatore
che permette al supervisore di distinguere la propria continuazione da un prompt dell'utente. Il supervisore considera
"input esterno" qualsiasi `session.inbox.enqueued` il cui `metadata.source` non sia
`goal-drainer`: prompt dell'utente, ma anche `/loop` o altri comandi.

Watchdog: un `setInterval` che, se `status === "running"` e `now - lastEventAt > watchdogMs`, chiama `stop("watchdog: nessun evento terminale")`. Il watchdog copre anche il caso `session.revert`: dopo un revert la `synthetic` non risveglia il runner, nessun evento terminale arriva, e il watchdog ferma il goal dichiarandolo invece di lasciare una continuazione in inbox per sempre.

Auto-approva: su `session.permission.updated`, se `autoApprove` e l'`action` è fra `edit`, `write`,
`shell` e il `resource` è sotto la root del progetto, chiama
`api.permissionReply(sessionID, requestID, "once")`. **`external_directory` non è nella lista.**
Non serve una `permissionList` separata: l'evento dice già che c'è una richiesta pendente.
Un `deny` esplicito già presente non produce richiesta, quindi non c'è caso da coprire.

- [ ] **Step 5: esegui i test e verifica che passano**

Run: `npm test`
Expected: PASS

- [ ] **Step 6: scrivi `README.md`**

Cinque righe: cosa fa, come si avvia (`/goal drain docs/backlog.md`), il formato dell'item, il significato di `[x]` `[!]` `[?]`, e che `[!]` è reversibile con `/goal retry <id>`. Niente copia della spec.

- [ ] **Step 7: typecheck e commit**

Run: `npm run typecheck`
Expected: nessun errore

```bash
git add src/index.ts test/cycle.test.ts README.md
git commit -m "feat: ciclo del drainer su session.execution.succeeded"
```

---

### Task 8: Collegamento e verifica end-to-end

**Files:**
- Create: `docs/backlog.md` in `/home/ld/foosball-vision`
- Modify: `/home/ld/.config/opencode/opencode.json`

**Interfaces:**
- Consumes: tutto
- Produces: un installazione funzionante

- [ ] **Step 1: registra il plugin**

Aggiungi in `~/.config/opencode/opencode.json`, **accanto** alle chiavi esistenti senza toccarle:

```jsonc
"plugins": ["superpowers@git+https://github.com/obra/superpowers.git", "/home/ld/opencode-goal"]
```

Non usare insieme `agent` e `agents` nella stessa config: misurato, fa fallire il caricamento di **tutti** gli agenti. La tua config non ha nessuna delle due, ma la regola vale per chi ci scrive dopo.

- [ ] **Step 2: crea la backlog di prova con quattro item**

In `/home/ld/foosball-vision/docs/backlog.md`: uno che passa subito, uno la cui verifica è impossibile, uno senza `Verify:`, uno che diventa verde solo al secondo tentativo. Scrivi i `Verify:` reali del progetto (`uv run --frozen pytest -q && uv run --frozen ruff check src tests`).

- [ ] **Step 3: verifica che il plugin si carichi**

Run: `opencode api get /api/plugin`
Expected: `goal-drainer` presente nell'elenco. Se non c'è, guarda `~/.local/share/opencode/log/opencode.log` filtrando `role=server`.

- [ ] **Step 4: verifica che il tool esista**

Run: `opencode api get /api/tool`
Expected: un tool il cui id contiene `goal`.

- [ ] **Step 5: un giro reale**

Run: `/goal drain docs/backlog.md` in una sessione nuova, poi osserva `/goal status` a metà.
Expected: il primo item `done` con exit code 0; l'impossibile `[!]`; il senza `Verify:` `[?]`; il quarto `done` al secondo tentativo. `docs/backlog.md` aggiornato con le evidenze.

- [ ] **Step 6: verifica che il tetto fermi davvero**

Run: `/goal stop`, poi riavvia con `budgetPercent: 1` e un item che non finisce.
Expected: stop al tetto, `state.json` coerente, nessun `done` false.

- [ ] **Step 7: commit**

```bash
cd /home/ld/foosball-vision
git add docs/backlog.md
git commit -m "test: backlog di prova per il goal drainer"
```