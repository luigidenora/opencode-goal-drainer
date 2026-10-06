# Goal Drainer — design

Data: 2026-10-07
Stato: in attesa di revisione
Repository: `~/opencode-goal` (plugin OpenCode V2)

## 1. Obiettivo

Un comando `/goal` che **drena una backlog di issue** in modo autonomo: prende il primo item
aperto, ci lavora sopra per più turni, lo chiude solo con una prova deterministica, e passa
al successivo. Si ferma da solo quando la coda è vuota, quando un item è impossibile, o quando
il budget percentuale dell'abbonamento è esaurito.

### Criteri di successo

1. Un item è `done` **solo** se il suo comando `Verify:` esce con codice 0 **e** il giudice
   conferma. Nessuna auto-dichiarazione.
2. Un item la cui `Verify:` non può diventare verde va in `blocked` con un motivo, e il drainer
   passa al successivo senza consumare il budget.
3. Il drainer non può superare la percentuale configurata del tetto mensile **per modello**.
4. Il ciclo sopravvive alla compressione del contesto e a un interrupt dell'utente: lo stato
   del goal è su disco, non nella conversazione.
5. Tutto ciò che il drainer chiude `done` è riproducibile: il comando di verifica è nel repo e
   l'evidenza finisce nel file di backlog.

## 2. Terreno verificato

Tutto quanto segue è stato verificato **sulla build installata** (opencode 2.0.14,
`@opencode-ai/sdk` 1.18.18), non sui docs.

### 2.1 Primitive disponibili

| Bisogno | Primitive | Stato |
|---|---|---|
| Fine di un turno | evento `session.idle` sullo stream `GET /api/event` | presente |
| Verifica deterministica | `POST /api/shell` → `GET /api/shell/{id}` (exit code) → `GET /api/shell/{id}/output` | presente |
| Continuazione del lavoro | `POST /api/session/{id}/prompt` e `/synthetic`, con `delivery: steer\|queue` | presente |
| Giudice senza contesto | `POST /api/experimental/generate` con `{prompt, model}` | presente, **ma vedi 2.3** |
| Costo e token per sessione | `tokens` e `cost` su `Session.Message.Assistant` | presenti |
| Costo aggregato per modello | `GET /api/experimental/session/stats` | funziona, **non filtrabile per sessione** |
| Auto-approva permessi | `GET /api/permission/request` + `POST /api/session/{id}/permission/{rid}/reply` | presente |
| Tool da plugin | `tool.transform` | presente nel binario |
| Aggiungere un comando da plugin | `CommandDraft` espone solo `list/get/update/remove` | **`add` assente** → si usa un comando markdown |
| Regole di permesso di sessione | `ctx.permission.rules` | **assente nel 2.0.14** → si risponde alle richieste pendenti |
| Hook di fine turno (Stop hook) | — | **non esiste in nessuna forma** |

### 2.2 Vincoli sul naming degli agenti

I file in `agents/` sono registrati con l'ID **derivato dal filename, senza normalizzazioni**.
`goal-worker.agent.md` produce l'ID `goal-worker.agent`. Se la config crea un entry
`goal-worker`, si ottengono **due agenti distinti**: quello da config con `system` vuoto e i
permessi, quello da markdown con le istruzioni. I comandi che puntano a `agent: goal-worker`
usano quello vuoto.

**Regola per questo plugin:** i file agent si chiamano `<id>.md`, mai `<id>.agent.md`.

### 2.3 Il vincolo di `opencode-go`

I docs di OpenCode Go richiedono l'header `x-opencode-session` su ogni richiesta. Testato su
`longcat-2.5-preview-free`, `muse-spark-1.3-contributor`, `mimo-v2.6-flash`, `qwen3.8-flash`:

```
Model unavailable: opencode-go/longcat-2.5-preview-free
Request is missing x-opencode-session and cannot be routed efficiently.
```

Il server non inoltra l'header sulla rotta `experimental.generate`, quindi **Go non è
raggiungibile da un giudice stateless**. Un subagent invece è una sessione reale e porta la
sessione con sé. Da qui la scelta del giudice come subagent.

Su Zen, `opencode/space-bunny-free` risponde e funziona; gli altri modelli free di Zen sono
rifiutati con *"OpenCode's free tier can only be used from within OpenCode"*.

## 3. Perché non `opencode-goal-worker`

Il pacchetto npm è 378 righe di markdown e zero righe di codice: non è un plugin, è un primary
agent che cicla dentro un singolo turno (`goal-worker.agent.md:143`). Difetti verificati:

- il ciclo muore a compressione di contesto o interrupt, cosa che il design qui deve sopravvivere
- verdetto solo booleano: niente `blocked`, quindi un item impossibile gira all'infinito
- nessun comando di verifica: decide un modello, non un exit code
- nessun tetto di spesa: `max_iterations` conta turni
- nessuna backlog: un goal per volta
- la sua unica guardia anti-loop è auto-giudicata dal lavoratore (`goal-worker.agent.md:100`)
- i nomi dei tool nel prompt sono V1 (`bash`, `task`) invece di `shell` e `subagent`
- `model: ollama-cloud/deepseek-v4-flash` non risolve: `modelID` vuoto

Da riusare: il prompt del giudice come bozza di partenza per il contratto JSON.

## 4. Architettura

Plugin V2 (`Plugin.define`), TypeScript, nessuna dipendenza runtime oltre `@opencode-ai/sdk`.

```
/goal drain docs/backlog.md
      │
      ▼
┌──────────────┐    start/stop/status/report
│ goal_control │  (tool registrato dal plugin)
└──────┬───────┘
       │
       ▼
┌──────────────┐   session.idle        ┌────────────────┐
│  supervisor  │──────────────────────►│ auto-approver  │
└──┬────────┬──┘                       └────────────────┘
   │        │
   │        └──► backlog/source.ts ──► items, pickNext(), mark(status, evidence)
   │
   ├──► verifier.ts ──► POST /api/shell ──► { exitCode, tail }
   │
   ├──► judge.ts ─────► session.create({parentID, model}) ──► subagent "goal-judge"
   │
   ├──► budget.ts ────► somma tokens/cost dei messaggi della sessione, per modello
   │
   └──► store.ts ─────► .opencode/goal/state.json
```

### 4.1 Componenti

| File | Responsabilità unica | Non fa |
|---|---|---|
| `index.ts` | `Plugin.define`, registra il tool, avvia il supervisor | nessuna logica di loop |
| `tool.ts` | schema e dispatch del tool `goal_control` | non tocca il loop |
| `supervisor.ts` | reagisce a `session.idle`, orchestra gli altri, decide | non chiama il giudice direttamente |
| `backlog/types.ts` | interfaccia `BacklogSource` | non sa cosa sia un file markdown |
| `backlog/markdown.ts` | parser del file di backlog | non decide il prossimo item |
| `verifier.ts` | esegue `Verify:` via `/api/shell`, ritorna `{exitCode, tail}` | non giudica |
| `judge.ts` | crea e interroga il subagent, valida il JSON | non decide `done` |
| `budget.ts` | contatori per modello, soglie percentuali | non ferma il loop da solo, dice solo `exceeded` |
| `store.ts` | lettura/scrittura `state.json` | non contiene policy |
| `approver.ts` | auto-risponde alle richieste di permesso mentre un goal è attivo | non concede permessi nuovi a mano |
| `compress.ts` | riduce il transcript a una finestra utile per il giudice | non decide |

### 4.2 Chi fa il lavoro

Il drainer **non ha un agente lavoratore proprio**. Lavora nella sessione in cui è stato
avviato, con l'agente che l'utente ha selezionato. Questo è intenzionale: il ciclo deve
sopravvivere alla compressione di contesto, e un agente dedicato che vive dentro un turno
sopravvive Male. Il plugin non cambia mai agente o modello della sessione.

Il giudice, invece, è un subagent separato con modello proprio.

### 4.3 Config

```jsonc
{
  "plugins": [
    { "package": "/home/ld/opencode-goal",
      "options": {
        "judgeModel": "opencode-go/muse-spark-1.3-contributor",
        "judgeFallbackModels": ["opencode-go/mimo-v2.6-flash"],
        "budgetPercent": 10,
        "monthlyLimitsUSD": { "opencode-go/muse-spark-1.3-contributor": 60 },
        "autoApprove": true,
        "stallTurns": 5,
        "verifyTimeoutMs": 600000
      } }
  ]
}
```

`monthlyLimitsUSD` ha come default la tabella dei docs Go e resta sovrascrivibile: se Go cambia
i prezzi, il plugin non va aggiornato.

## 5. Il ciclo

A ogni `session.idle` della sessione con un goal attivo:

```
1. budget.check()  →  se una soglia è superata: stop + report, nient'altro
2. verifier.run(item.Verify)
     ├─ exit ≠ 0 ──► se stallTurns consecutivi con diff invariato → blocked, item successivo
     │                altrimenti session.synthetic("Check rosso. Ultimo output: …") e fine
     └─ exit = 0 ──► step 3
3. compress(transcript) ──► judge.transcribe(...)
     ├─ done     ──► item chiuso con evidenze → item successivo, o "coda vuota" e stop
     ├─ continue ──► session.synthetic( motivo ) → il ciclo riparte al prossimo idle
     └─ blocked  ──► item bloccato con motivo → item successivo
4. in ogni caso: report sintetico su state.json
```

La verifica **precede** il giudice. Il giudice non può mai dire `done` su una verifica rossa:
`verifier` short-circuita a `step 2` e non lo chiama.

### 5.1 Le quattro scelte che rendono il ciclo deterministico

**Impronta del working tree.** Lo stall detector non confronta il testo del Agent, confronta
un dato. L'impronta è `sha256` di `GET /api/vcs/status` e `GET /api/vcs/diff` concatenati,
ricalcolata a ogni verifica. Se l'impronta non cambia per `stallTurns` verifiche rosse
consecutive, l'item è `blocked: nessun progresso`. Un repo non-git dà impronta costante: in
quel caso lo stall detector è disattivato e vale solo il tetto percentuale, perché non c'è
modo onesto di misurare il lavoro fatto.

**Finestra del transcript.** Il giudice riceve al massimo gli ultimi 60.000 caratteri del
transcript, più i riassunti dei turni precedenti compressi a 2.000 caratteri ciascuno, più
l'output corrente della verifica. Se il transcript eccede, si taglia dal basso: la coda conta
più della testa. Il plugin non pretende che il giudice ricordi tutto, pretende solo che veda
l'ultimo lavoro e la prova.

**Delivery della continuazione.** `session.synthetic` con `delivery: "steer"`. La continuazione
è un'integrazione al lavoro in corso, non una richiesta utente in coda: con `queue` il
lavoratore la leggerebbe solo al turno dopo, il che azzera il vantaggio del ciclo.

**Timeout della verifica.** `verifyTimeoutMs`, default 600.000. Superato: il comando viene
terminato, l'item resta in verifica e il timeout viene riportato come parte del motivo della
continuazione. Un timeout non è un `blocked`: è un tentativo ancora da fare.

## 6. Formato della backlog

```markdown
## [ ] B-04 — Riconoscimento geometria del tavolo
Accetta:
- Geometria calibrata automaticamente sui segmenti supportati
- Errore mediano entro 1% della lunghezza del campo
Verify: `uv run --frozen pytest -q && uv run --frozen ruff check src tests`
Blocked-by: —
```

Il parser richiede `Verify:` non vuoto. Un item senza `Verify:` è `invalid` e viene saltato con
avviso: è il punto in cui la disciplina del progetto viene enforced dalla macchina.

Al drenaggio, il `[ ]` diventa `[x]` (done), `[!]` (blocked) o `[?]` (invalid), e sotto
l'item compaiono data, numero di turni, esito della verifica e motivo del verdetto.

## 7. Il giudice

Subagent `goal-judge`, `mode: subagent`, modello `opencode-go/muse-spark-1.3-contributor`
($0.10 in / $0.20 out per Mtok, 226.600 richieste/mese, tetto mensile $60).

Tutti i tool negati: il giudice legge, non agisce.

Output: solo JSON.

```json
{"status": "done|continue|blocked", "reason": "≤120 caratteri"}
```

`reason` diventa il testo della continuazione nel caso `continue`.

Regole del prompt, derivate dal prompt del pacchetto npm e ristrette:

- `done` solo se la condizione è soddisfatta e dimostrabile dal materiale fornito
- `blocked` se la condizione richiede qualcosa che non esiste o non è raggiungibile
  (dipendenza mancante, dati assenti, permesso negato): **non** usare `blocked` per
  semplicemente non averci ancora lavorato
- `continue` per tutto il resto, con il motivo che punta alla prossima azione

Se il JSON non è valido: un retry. Due fallimenti → cambia modello di fallback. Un fallimento
anche sul fallback → il verdetto è `continue` con motivo "giudice non raggiungibile" e il
tentativo viene contato nello stall detector. **Un errore del giudice non può mai produrre
`done`.**

## 8. Budget percentuale

Il tetto è una percentuale del **limite mensile del modello consumato**, contata per modello.

- `budgetPercent`, default **10**
- il tetto del modello X è `budgetPercent/100 × monthlyLimitsUSD[X]`
- la spesa è la somma di `cost` dei messaggi `Session.Message.Assistant` della sessione del
  goal, dal momento dell'avvio, raggruppata per modello
- `session.stats` serve da controllo incrociato e da riferimento: non è filtrabile per sessione,
  quindi non è la fonte primaria

### 8.1 Le tre finestre di Go

I docs Go definiscono tre finestre: 5 ore = 20% del mensile, settimanale = 50%, mensile = 100%.

Il tetto configurato è una percentuale del **mensile**, ma il vincolo più stretto in una run
lunga è la finestra 5 ore. Con il default: 10% di $60 = $6, contro un tetto 5 ore di $12. Un
drainer che corre a pieno ritmo può raggiungere i $6 in circa due ore e mezza.

Per questo il plugin **mostra tutte e tre le soglie** nel report e segnale esplicitamente
quando la spesa della run è concentrata in una finestra 5 ore. Non ferma il drenaggio per
questo da solo: fermarsi ce l'ha già il tetto percentuale. Il segnalamento serve a te, che
vedi il report mentre gira.

### 8.2 Modelli gratis

Se il modello ha `monthlyLimitsUSD` assente o costo 0 (Zen free, `space-bunny-free`), il
contatore non ferma mai. Viene comunque riportato in token, così il limite di lavoro si legge.

## 9. Sicurezza e arresti

| Meccanismo | Regola | Perché |
|---|---|---|
| Anti-livelock | `stallTurns` (default 5) verifiche rosse consecutive **e** impronta del working tree invariata → `blocked` | un item impossibile non deve consumare il tetto; non limita l'autonomia sui task che procedono |
| Tetto percentuale | vedi §8 | unico stop per spesa |
| Giudice irraggiungibile | retry → fallback → `continue`, mai `done` | un errore non è un successo |
| Auto-approva | solo `edit`, `write`, `shell` su path del progetto, solo mentre un goal è attivo, mai `external_directory` | `external_directory` è il caso in cui un agente AUTOMATICO esce dal repo: resta sempre `ask` |
| Permesso denegato esplicitamente | mai sovrascritto | una regola `deny` esplicita resta `deny` |
| Interrupt | `/goal stop` ed Esc interrompono sempre; `stop` scrive `state.json` prima di uscire | il goal è recuperabile |
| Item `invalid` | saltato, non tentato | meglio una backlog incompleta che un test che non gira |

## 10. Comandi

Un solo comando markdown `~/.config/opencode/commands/goal.md` che inoltra a `goal_control`:

| Uso | Effetto |
|---|---|
| `/goal drain <file>` | avvisa il drainer su quella backlog |
| `/goal status` | item corrente, turni, spesa per modello, tre soglie, ultimo verdetto |
| `/goal stop` | ferma il ciclo, conserva lo stato |
| `/goal report` | tabella `done` / `blocked` / `invalid` / `open` con evidenze |

Lo stato vive in `.opencode/goal/state.json` nella directory del progetto, così un
`/goal status` dopo un riavvio di opencode legge il vero.

## 11. Verifica

1. **Unit**, con client finto: parser del verdetto JSON, parser della backlog, contatori di
   budget per modello, rilevamento stall, compressione del transcript, naming degli agenti.
2. **Integrazione**, in un progetto scratch con tre item: uno che passa subito, uno con una
   verifica che non può passare, uno senza `Verify:`. Atteso: `done`, `blocked`, `invalid`, e
   il ciclo converge senza loop.
3. **Tetto**: uno scratch con `budgetPercent` basso e un item che non finisce. Atteso: stop al
   tetto, `state.json` coerente, nessun `done` false.
4. **Manuale**: un item vero e piccolo su foosball-vision.

## 12. Primo passo: la probe

Prima di scrivere il loop, una probe usa-e-getta in un `HOME` isolato con `opencode serve` su
una porta libera. Deve confermare:

1. cosa contiene davvero il ctx del plugin V2 in 2.0.14, e se `command.add` esiste
2. la forma esatta dell'evento `session.idle`
3. che un subagent con modello `opencode-go/*` venga **accettato** (è la premessa di §7; se
   fallisce, il giudice torna su `experimental.generate` e si perde Go)
4. che `POST /api/shell` riporti l'exit code come atteso

Se la probe contraddice §7, il design si ferma e si corregge **prima** di scrivere il loop. La
probe viene buttata.

## 13. Fuori scope

- adapter per GitHub Issues o Linear: l'interfaccia `BacklogSource` c'è, l'adapter no
- continuazione attraverso la compressione di contesto oltre al salvataggio stato: il ciclo riparte
  dall'item, non dal mezzo del lavoro
- modalità headless (`opencode run`) per il drainer
- uso come Stop hook per altri plugin

## 14. Rischi noti

| Rischio | Stato |
|---|---|
| Go rifiuta il subagent come ha rifiutato la rotta stateless | **non verificato**, è il punto 3 della probe |
| I limiti mensili Go cambiano | tabella nel plugin, sovrascrivibile dalla config |
| Il giudice free/cheap rifiuta `done` che merita | scelta deliberata: preferisce un `continue` in più a un `done` in meno |
| Un item con `Verify:` debole | difesa del progetto, non del plugin: `Verify:` è dichiarato e versionato |
