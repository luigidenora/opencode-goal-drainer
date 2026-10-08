# opencode-goal-drainer

Un `/goal` per OpenCode. Imposta una condizione di completamento e l'agente ci
lavora finché non è soddisfatta, senza che tu debba ripromptare a ogni turno.

```
/goal tutti i test in test/auth passano e il lint è pulito
```

Da lì in avanti, a ogni fine turno, un giudice legge la condizione e quello che
l'agente ha fatto. Se non è soddisfatta, l'agente riparte da solo con il motivo
del giudice come guida. Quando è soddisfatta, il goal si chiude e il controllo
torna a te.

## Installazione

```bash
npm install -g opencode-goal-drainer
```

oppure, da un checkout locale:

```jsonc
// ~/.config/opencode/opencode.json
{
  "$schema": "https://opencode.ai/config.json",
  "plugins": ["opencode-goal-drainer"]
}
```

Poi `opencode reload`. Il plugin non ha dipendenze runtime: usa solo i moduli
`node:*`.

## Comandi

| Comando | Effetto |
|---|---|
| `/goal <condizione>` | imposta il goal e parte subito |
| `/goal` | stato: condizione, turni, durata, spesa, ultimo verdetto |
| `/goal clear` | azzera il goal (accettati anche `stop`, `off`, `reset`, `none`, `cancel`) |
| `/goal drain <file>` | modalità backlog: drena più item da un file markdown |
| `/goal retry <id>` | riapre un item bloccato della backlog |

Le stesse azioni esistono come tool `goal_control` (`set`, `status`, `clear`,
`drain`, `retry`, `report`), utile da Code Mode o quando vuoi che sia il modello
a impostare un goal.

## Come decide

A ogni fine turno (`session.execution.succeeded`), in quest'ordine:

1. se la sessione ha già speso oltre il tetto configurato, il goal si ferma e lo dichiara
2. se la condizione porta un comando di verifica, lo esegue e legge l'exit code
3. se rosso, reinietta l'output come continuazione e aspetta il turno dopo
4. se verde (o se non c'è un comando), chiede al giudice un verdetto in JSON

| Verdetto | Effetto |
|---|---|
| `done` | il goal si chiude con `achieved` |
| `continue` | il motivo viene reiniettato e l'agente riparte |
| `blocked` | il goal si chiude con `failed` e il motivo — è il "impossible" di Claude Code |

Il giudice **non viene mai consultato con una verifica rossa**, quindi non può
dichiarare `done` su un test che non gira. Se non risponde due volte, il verdetto
è `continue` con motivo "giudice non raggiungibile": un errore non è mai un successo.

Il giudice gira con `session.generate` sulla sessione stessa: stateless, non tocca
la history, non costa una sessione in più.

## Verifica deterministica

Se la condizione contiene un comando, diventa un gate:

```
/goal la migrazione è completa. Verify: `uv run --frozen pytest -q`
```

Forme riconosciute: `Verify: \`comando\``, oppure un blocco ```` ```bash ````. Quando
c'è, il comando viene **eseguito davvero** e il giudice vede solo un gate verde —
non deve fidarsi della parola dell'agente.

Con un gate attivo c'è anche l'anti-livelock: se il comando resta rosso e nessun
file sorgente cambia per `stallTurns` turni, il goal fallisce dichiarando "nessun
progresso" invece di bruciare il budget. Su una directory senza git l'anti-livelock
è disattivato: lì non c'è un dato onesto su cui decidere.

## Modalità backlog

```
/goal drain docs/backlog.md
```

```markdown
## [ ] B-04 — Riconoscimento geometria del tavolo
Accetta:
- Geometria calibrata automaticamente sui segmenti supportati
- Errore mediano entro 1% della lunghezza del campo
Verify: `uv run --frozen pytest -q && uv run --frozen ruff check src tests`
```

`Verify:` è **obbligatorio**: un item senza non viene mai tentato, viene marcato
`[?]` e saltato. Al drenaggio il marker diventa `[x]` (done), `[!]` (blocked) o
`[?]` (invalid), con data, turni, exit code e motivo sotto l'item.

Un `[!]` è **reversibile** con `/goal retry <id>`, e non conta come coda svuotata:
il report dice "coda svuotata con N bloccati".

## Budget

`budgetPercent` (default **10**) è la percentuale del limite mensile che il goal
può consumare. Vale **solo per i modelli `opencode-go/*`**, gli unici che scalano
sull'abbonamento OpenCode Go. I modelli del free tier non hanno tetto e il report
lo dichiara, invece di mostrare uno `0%` che sembrerebbe una misura.

La spesa si accumula da `session.usage.updated` e si attribuisce al modello visto
in `session.step.started`.

## Configurazione

```jsonc
{
  "plugins": [
    { "package": "opencode-goal-drainer",
      "options": {
        "budgetPercent": 10,
        "autoApprove": true,
        "stallTurns": 5,
        "verifyTimeoutMs": 600000,
        "watchdogMs": 1800000,
        "maxTurns": 0,
        "monthlyLimitsUSD": { "opencode-go/space-bunny": 30 }
      } }
  ]
}
```

`maxTurns: 0` significa nessun tetto di turni. `monthlyLimitsUSD` ha come default
la tabella dei limiti Go e resta sovrascrivibile.

`autoApprove` risponde `once` alle richieste di permesso per `edit`, `write` e
`shell` dentro il progetto, mentre un goal è attivo. **Mai `always`**: quella
scelta scrive in `/api/permission/saved` a livello di progetto e sopravvive a
sessione, goal e riavvio. `external_directory` non è mai auto-approvato.

## Garanzie

- il goal **non attende un umano**: se si apre una domanda o un form, si ferma con un motivo
- un tuo prompt durante il ciclo mette il goal in `paused-utente`: il turno finisce e non si reinietta
- un watchdog lo ferma se non arriva nessun evento terminale per `watchdogMs`
- `state.json` ha un lease: due finestre sullo stesso progetto non drenano in parallelo
- due istanze del plugin sulla stessa directory non raddoppiano le continuazioni
- lo stato vive in `<progetto>/.opencode/goal/state.json`: ogni progetto è indipendente

## Sviluppo

```bash
npm test
```

Il substrato è stato **misurato**, non dedotto: `probe/out/FINDINGS.md` documenta
cosa esiste davvero in opencode 2.0.14 e cosa no. In particolare `session.idle`
**non viene mai emesso** — il trigger è `session.execution.succeeded` — e il
server scarta il campo `metadata` dalle `session.synthetic`, quindi la
continuazione si riconosce da un marcatore nel testo.

`docs/superpowers/` contiene la specifica e il piano che hanno prodotto questo
plugin, comprese le correzioni che una probe aveva imposto al design.

## Licenza

MIT
