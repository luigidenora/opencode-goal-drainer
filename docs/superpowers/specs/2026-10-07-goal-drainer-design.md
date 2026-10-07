# Goal Drainer — design v2

Data: 2026-10-07
Stato: in attesa di revisione
Supersede: `be0e0e3` (v1)
Repository: `~/opencode-goal`

La v1 non era implementabile. Il suo trigger — l'evento `session.idle` — non viene mai emesso,
e il suo giudice non sarebbe mai stato un subagent. Questa è la versione corretta: il substrato
è quello **misurato**, non quello che i typings o una ricerca di stringhe promettevano.

## 1. Obiettivo

Un `/goal` che drena una backlog di issue: prende il primo item aperto, ci lavora per più
turni, lo chiude solo con una prova deterministica, passa al successivo. Si ferma quando la
coda è vuota, quando un item è impossibile, o quando il tetto percentuale di Go è superato.

### Criteri di successo

1. Un item è `done` **solo** se `Verify:` esce con codice 0 **e** il giudice conferma. Il
   giudice non viene mai consultato con una verifica rossa.
2. Un item non realizzabile diventa `[!]` **reversibile**: `/goal report` lo elenca e `/goal
   retry <id>` lo riapre. Un `[!]` non è un esito valido e non svuota la coda.
3. Il drainer non supera `budgetPercent` del tetto mensile del modello consumato.
4. Il ciclo riparte dall'inizio dell'item dopo compressione, interrupt o riavvio: lo stato
   del goal è su disco e i criteri di accettazione vivono nel file di backlog, non nel
   contesto.
5. Ogni `done` è riproducibile: `Verify:` è versionato nel repo e l'evidenza finisce in backlog.
6. Il drainer non attende mai un umano. Se l'agente apre una domanda o un form, il goal
   abortisce con un motivo.

## 2. Terreno misurato

Tutto qui sotto è stato osservato **in esecuzione** su opencode 2.0.14. Dove la v1 si basava su
una ricerca di stringhe nel binario o sui typings, la riga è marcata `[misurato]` oppure
`[non misurato]`.

### 2.1 Il traffico reale di un turno `[misurato]`

Eseguito un turno completo (`Rispondi esattamente: ok` su `space-bunny-free`) con un listener
SSE su `GET /api/event`. Questi sono **tutti** gli eventi emessi:

```
session.inbox.enqueued      seq 1
session.execution.started   seq 2
session.instructions.updated
session.inbox.delivered
session.step.started
session.text.started / .delta / .ended
session.step.streamed
session.step.ended          finish: "stop"
session.usage.updated       {"cost":0,"tokens":{"input":10436,"output":3,...}}
session.execution.succeeded seq 10
```

**`session.idle`: zero occorrenze.** Il token esiste nel binario come dichiarazione di schema,
ma nessun emittente lo produce. La v1 lo assumeva come trigger ed è la ragione per cui quel
design non poteva funzionare.

**Il trigger è `session.execution.succeeded`**, con i fratelli `failed` e `interrupted`. Il
payload è `{data:{sessionID}, durable:{aggregateID, seq, version}}`. Il blocco `durable`
consente il replay, quindi un plugin che ricarica i propri transform non perde eventi.

`session.usage.updated` porta `cost` e `tokens` **per sessione, a ogni turno**: è un feed di
spesa push, e rende inutile il polling dei messaggi.

### 2.2 Primitive `[misurato]`

| Bisogno | Primitive | Note |
|---|---|---|
| Fine di un turno | `session.execution.succeeded\|failed\|interrupted` | unico segnale reale |
| Spesa per sessione | `session.usage.updated` | push, per sessione |
| Verifica deterministica | `POST /api/shell` → `GET /api/shell/{id}` → `/output` | exit code in `shell.get` |
| Continuazione | `POST /api/session/{id}/synthetic` con `{text, metadata, delivery}` | durevole in inbox |
| Giudice | `POST /api/session/{id}/generate` con `{prompt}` | vedi §5 |
| Costo per messaggio | `tokens` e `cost` su `Session.Message.Assistant` | riconciliazione |
| Auto-approva | `GET /api/permission/request` → `.../permission/{rid}/reply` | solo `once`, vedi §9 |

### 2.3 Cosa NON esiste, contro la v1

| Cosa la v1 assumeva | Realtà |
|---|---|
| `session.idle` | mai emesso |
| `session.create({parentID})` crea un figlio | il payload è `{id,title,agent,model,location,metadata,permissions}`: **nessun `parentID`**, chiave extra scartata in silenzio. Crea una sessione radice |
| Il giudice è un subagent | non è e non può essere via HTTP. L'unica rotta che crea un figlio è `/fork`, che copia la history e non accetta modello |
| `ctx.permission.rules` per le regole di sessione | assente |
| `@opencode-ai/sdk` usabile | i typings V1 puntano a rotte inesistenti (`POST /session` → 405, `GET /event` → HTML della SPA); i typings V2 di `PluginContext` non contengono `session`, `event`, `tool`, `permission`, `generate`. Tutto ciò che serve è **solo** nei typings del binario, non pubblicati |
| `CommandDraft` senza `add` | questo è quanto dichiarano i typings 1.18.18; il draft che il binario passa a `command.transform` espone `{add}`. **Da verificare**: se `add` esiste, il comando si registra dal plugin e non serve un file fuori dal repo |

Da questo segue una conseguenza di trasporto: **il plugin parla al server con `fetch` su
`/api/*`**, non con l'SDK. Un wrapper `api.ts` sottile, e tutto il resto è indipendente dalla
forma del client.

### 2.4 Cosa c'è in abbonamento `[misurato]`

L'utente ha **solo il piano Go**. I modelli con provider `opencode` a costo 0 sono il free tier,
non scalato sull'abbonamento. Quindi l'unica spesa possibile è sui modelli `opencode-go/*`.

`opencode-go/*` richiede l'header `x-opencode-session`, che il server non inoltra sulla rotta
`experimental.generate`. Testato su quattro modelli: `Model unavailable` oppure
`Request is missing x-opencode-session`. **`session.generate` invece è costruito dalla sessione
e lo trasporta**, il che è il motivo per cui è il giudice giusto.

Su Zen, `opencode/space-bunny-free` risponde; gli altri free sono rifiutati con
*"OpenCode's free tier can only be used from within OpenCode"*.

## 3. Architettura

Sei moduli, contro gli undici della v1. Spariti: `compress.ts` (non serve, vedi §5: è il
contesto a portare il transcript, non il prompt), `tool.ts` (un tool, uno schema, una dispatch:
sta dentro `index.ts`), `approver.ts` (condivide lo stream col supervisore, ed essere un secondo
consumatore su due file è una race), `budget.ts` (accumula dagli stessi eventi che il supervisore
già legge). `backlog/types.ts` e `backlog/markdown.ts` diventano un `backlog.ts`: l'interfaccia
`BacklogSource` era un'astrazione per una seconda implementazione mai scritta.

```
/goal drain docs/backlog.md
      │
      ▼
┌─────────────────────────────────────────────────────────┐
│ index.ts                                                 │
│   tool goal_control · sottoscrizione eventi · supervisore │
│   accumulatore di spesa · auto-approva (once)            │
└───┬──────────────┬──────────────┬───────────────┬────────┘
    │              │              │               │
    ▼              ▼              ▼               ▼
 backlog.ts    verifier.ts     judge.ts        store.ts
 item,         POST /api/    session.generate  state.json
 pickNext()     shell          + verdetto       con lease
                              JSON
    └──────────────┴──────────────┴───────────────┘
                          api.ts
              fetch su /api/*, niente SDK
```

`config.ts` non è un modulo: è un file di dati (tabella dei limiti Go) più le opzioni dal
plugin, letti una volta in `setup`.

### 3.1 Il ciclo

```
session.execution.succeeded  (o failed / interrupted)  per la sessione col goal attivo
      │
      ├─ 1. auto-approva: rispondi once alle richieste pendenti ammesse
      ├─ 2. budget: la spesa di questo turno ha superato una soglia? → stop + report
      ├─ 3. verifier.run(item.Verify) via POST /api/shell
      │        ├─ exit ≠ 0 → stall? (§6) no: synthetic("Check rosso. Output: …"), fine
      │        │            sì: blocked, item successivo
      │        └─ exit = 0 → passo 4
      ├─ 4. judge: session.generate(prompt)
      │        ├─ done     → item chiuso con evidenze → item successivo, o "coda svuotata"
      │        ├─ continue → synthetic(motivo) → torna al prossimo succeeded
      │        └─ blocked  → item [!] reversibile → item successivo
      └─ 5. report su state.json
```

`interrupted` non è `succeeded`: un interrupt dell'utente **azzera il ciclo** e lo riavvia
dall'inizio dell'item corrente, senza perdere il lavoro già fatto su disco.

### 3.2 Config

```jsonc
{
  "plugins": [
    { "package": "/home/ld/opencode-goal",
      "options": {
        "judgePrompt": null,          // default: contratto in judge.ts
        "budgetPercent": 10,
        "monthlyLimitsUSD": {         // default: tabella Go, sovrascrivibile
          "opencode-go/space-bunny": 30,
          "opencode-go/muse-spark-1.3-contributor": 60
        },
        "autoApprove": true,
        "stallTurns": 5,
        "verifyTimeoutMs": 600000,
        "watchdogMs": 1800000
      } }
  ]
}
```

Il giudice **non ha modello proprio**: `session.generate` eredita il modello della sessione.
Finché la sessione è su `space-bunny-free` il giudice è gratis. Il giorno in cui si lavora su
un modello Go, anche il giudice scala — ed è la ragione per cui il tetto va contato per modello
e non per run.

## 4. Il comando

`tool goal_control` con azioni `start | status | stop | report | retry`, schema dichiarato, una
descrizione. Il comando `/goal` lo invoca. Se `command.transform` espone davvero `add`, il
comando si registra da qui; altrimenti un `~/.config/opencode/commands/goal.md` di quattro
righe. La probe lo stabilisce e non cambia altro.

## 5. Il giudice

`POST /api/session/{id}/generate` con `{prompt}`. Nessuna nuova sessione, nessun modello da
scegliere, nessun `parentID` che non esiste, nessun `session.idle` da filtrare.

**Il prompt non contiene il transcript.** `session.generate` è costruito dal contesto della
sessione: l'agente vede già il lavoro. Il prompt porta solo ciò che il contesto non sa:

```
Obiettivo:  <titolo item>
Accetta:    <criteri di accettazione dalla backlog>
Verifica:   <comando> → exit <n>
Output:     <ultimi 4 KB>

Rispondi SOLO con questo JSON:
{"status":"done|continue|blocked","reason":"≤120 caratteri"}

done     solo se ogni criterio è soddisfatto e dimostrato da quanto sopra
blocked  solo se manca un prerequisito che nessun lavoro può creare
         (dipendenza assente, dati assenti, permesso negato)
         NON usarlo per dire "non ho ancora lavorato"
continue tutto il resto; reason punta alla prossima azione
```

Questo elimina `compress.ts`: non c'è finestra da gestire perché il contesto lo porta la
sessione. E `metadata: {source: "goal-drainer"}` sulla `synthetic` rende ogni continuazione
riconoscibile in `GET /api/session/{id}/inbox`, che è il posto dove finirebbe anche un prompt
perso.

Parsing del verdetto: JSON tollerante (via code fence, testo prima/dopo). Non valido → retry.
Due fallimenti → verdetto `continue` con motivo "giudice non raggiungibile", e il tentativo
conta nello stall detector. **Un errore del giudice non può produrre `done`.**

## 6. L'anti-livelock, corretto

La v1 faceva `sha256(vcs/status + vcs/diff)` su tutto. Non poteva mai scattare: `pytest` scrive
`.pytest_cache` e `__pycache__` a ogni run, quindi l'impronta cambiava sempre.

L'impronta è `sha256` dei **path sorgente** da `GET /api/vcs/status`, con esclusione esplicita
di `.git/`, `node_modules/`, `.venv/`, `__pycache__/`, `.pytest_cache/`, `.ruff_cache/`,
`dist/`, `build/`, `output/`, `runs/`, `.opencode/goal/`. Se un file escluso cambia, non conta:
non è lavoro.

`stallTurns` verifiche rosse consecutive **e** impronta invariata → `[!]` con motivo "nessun
progresso". Su directory senza VCS l'anti-livelock è disattivato e vale solo il tetto
percentuale: non c'è dato onesto, e una guardia che indovina è peggio di nessuna guardia.

## 7. `blocked` non è un esito

Il buco più serio della v1: `blocked` era un verdetto libero di un modello, terminale, e non
consumava budget. Un modello che risponde sempre `blocked` svuotava la backlog a costo zero e il
report diceva "drenata".

Correzioni:

- `[!]` è **reversibile**: `/goal report` lo elenca, `/goal retry <id>` lo riapre
- la coda è "svuotata" solo se **non ci sono `[!]`**: altrimenti il report dice
  "svuotata con N item bloccati" e il drainer si ferma lo stesso
- **un item `[!]` non consuma budget**, quindi non può essere un modo per chiudere il ciclo:
  bloccando tutto si spende zero e non si conclude niente
- il motivo è obbligatorio e finisce in backlog accanto all'evidenza

## 8. Il budget percentuale

Vale **solo per `opencode-go/*`**: gli unici che scalano sull'abbonamento.

- `budgetPercent`, default **10**; tetto del modello X = `budgetPercent/100 × monthlyLimitsUSD[X]`
- fonte primaria: `session.usage.updated`, accumulata per modello dall'avvio del goal
- riconciliazione: somma di `cost` sui `Session.Message.Assistant`, per individuare drift
- i modelli free non hanno tetto e il report lo dichiara con una riga esplicita, invece di
  mostrare uno `0%` che sembrerebbe una misura

Se la sessione gira su free, il tetto è **inerte per costruzione** e il report lo dice. Non è un
difetto: un tetto che non scatta quando non si spende è corretto, purché lo dichiari.

Le tre finestre Go (5 ore = 20% del mensile, settimanale = 50%) sono mostrate nel report senza
fermare nulla: con il default, 10% di $60 = $6 contro un tetto 5 ore di $12, quindi è la
finestra corta a fermare prima, e serve a saperlo.

## 9. Sicurezza

| Meccanismo | Regola |
|---|---|
| Trigger | `session.execution.*`, filtrato per `sessionID` e per `aggregateID` del lease |
| Watchdog | nessun evento terminale entro `watchdogMs` (default 30 min) → stop con motivo. Il ciclo non può pendere in silenzio |
| Anti-livelock | §6 |
| Auto-approva | **solo `decision: "once"`**. `always` scrive in `/api/permission/saved` per progetto e sopravvive a sessione, goal e riavvio: mai. `external_directory` resta sempre `ask` perché è il caso in cui un agente automatico esce dal repo |
| `deny` esplicito | mai sovrascritto |
| Domanda o form aperto | `session.form.created` pendente → **abort del goal** con motivo. Un drainer che aspetta un umano non è un drainer, e la `synthetic` accodata verrebbe poi consumata dal worker senza che lui abbia mai visto la domanda |
| Input umano in arrivo | un prompt utente durante il ciclo marca il goal `paused-utente`: il ciclo finisce il turno e non reinietta. Provenienza discernibile via `metadata.source` |
| Concorrenza | `state.json` con `ownerSessionID` e `lease` (`expiresAt`). Un secondo drainer sullo stesso progetto rifiuta l'avvio invece di correre in parallelo sulla stessa working tree |
| Revert | dopo `session.revert` la `synthetic` non risveglia il runner: il goal si ferma e lo dice, invece di lasciare una continuazione in inbox per sempre |
| Cleanup | la sessione di giudice non esiste più (è la stessa del goal): niente proliferazione, niente `session.remove` che si blocca su `awaitIdle` |
| Interrompere | `/goal stop` ed Esc fermano sempre; `stop` scrive `state.json` prima di uscire |

## 10. Formato della backlog

```markdown
## [ ] B-04 — Riconoscimento geometria del tavolo
Accetta:
- Geometria calibrata automaticamente sui segmenti supportati
- Errore mediano entro 1% della lunghezza del campo
Verify: `uv run --frozen pytest -q && uv run --frozen ruff check src tests`
```

`Verify:` non vuoto è **obbligatorio**: un item senza è `invalid`, saltato con avviso, e non
prova a indovinare. Al drenaggio `[ ]` diventa `[x]` (done), `[!]` (blocked) o `[?]` (invalid),
con data, turni, exit code e motivo sotto l'item.

I criteri di accettazione vivono qui, non nel contesto: è questo che rende vera la promessa di
sopravvivere alla compressione. Dopo una compressione il contesto è un riassunto, ma la backlog
è ancora su disco e il giudice riceve i criteri freschi a ogni chiamata.

## 11. Verifica

1. **Unit**: parsing del verdetto, parser della backlog, esclusioni dell'impronta, calcolo
   della soglia, lease.
2. **Integrazione**, progetto scratch con quattro item: uno che passa subito, uno con verifica
   impossibile, uno senza `Verify:`, uno che diventa verde al secondo tentativo. Atteso:
   `done`, `[!]`, `[?]`, `done`, e il ciclo converge.
3. **Trigger**: un turno reale e l'evento `session.execution.succeeded` arriva con il
   `sessionID` giusto. È il test che la v1 non ha mai avuto.
4. **Tetto**: `budgetPercent` basso con un item che non finisce → stop al tetto, `state.json`
   coerente, nessun `done` false.
5. **Manuale**: un item vero e piccolo su foosball-vision.

## 12. La probe, prima di tutto

Sei interrogativi, tutti su un `HOME` isolato con `opencode serve` su porta libera. La probe
viene buttata.

1. `command.transform` espone `add`? Se sì, il comando si registra dal plugin.
2. `tool.transform`: forma esatta dell'editor e del contesto di `execute`.
3. `POST /api/session` accetta una chiave `parentID`? La v2 non lo usa, ma se lo accettasse la
   v1 tornerebbe possibile e il giudice potrebbe avere un modello proprio.
4. `POST /api/session/{id}/generate` ereditando il modello della sessione: confermare che
   funzioni e che non tocchi history né `cost`.
5. `POST /api/shell`: confermare l'exit code in `shell.get` e il comportamento a timeout.
6. `session.execution.failed` e `interrupted`: payload e che arrivino davvero.

Se la 3 dice sì, si riapre la possibilità di un giudice con modello proprio e la §5 va
rivalutata. È l'unico esito che cambierebbe la forma della soluzione.

## 13. Fuori scope

- adapter per GitHub Issues o Linear
- continuazione a metà item dopo compressione: il ciclo riparte dall'inizio dell'item
- `opencode run` headless per il drainer
- riuso come hook per altri plugin

## 14. Rischi noti

| Rischio | Stato |
|---|---|
| Il tetto è inerte su modelli free | voluto e dichiarato, §8 |
| `session.generate` non ha override di modello | il giudice scala quando la sessione scala. Documentato in §3.2 |
| Il giudice free sbaglia `blocked` in eccesso | `blocked` è reversibile e non conclude la coda, §7 |
| I limiti Go cambiano | tabella dati sovrascrivibile dalla config |
| Un `Verify:` debole | difesa del progetto, non del plugin: è dichiarato e versionato |
| Il trigger è un evento, non una garanzia di consegna | coperto da `durable.replay` sul server e dal watchdog |
