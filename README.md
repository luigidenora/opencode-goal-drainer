# opencode-goal-drainer

Un comando `/goal` per OpenCode che drena una backlog di item markdown. Prende il
primo item aperto, ci lavora per più turni, e lo chiude **solo** se il suo comando
`Verify:` esce con codice 0 **e** un giudice conferma. Poi passa al successivo.

## Uso

```
/goal drain docs/backlog.md     avvia il drenaggio
/goal status                    item corrente, turni, spesa per modello
/goal report                    done / bloccati / invalidi / aperti, con evidenze
/goal stop                      ferma il ciclo, conserva lo stato
/goal retry B-04                riapre un item bloccato
```

Il tool si chiama `goal_control` e accetta `{action, backlogPath, itemId}`: le stesse
cinque azioni, se preferisci invocarlo direttamente o da Code Mode.

## Formato della backlog

```markdown
## [ ] B-04 — Riconoscimento geometria del tavolo
Accetta:
- Geometria calibrata automaticamente sui segmenti supportati
- Errore mediano entro 1% della lunghezza del campo
Verify: `uv run --frozen pytest -q && uv run --frozen ruff check src tests`
```

`Verify:` è **obbligatorio**. Un item senza non viene mai tentato: viene marcato `[?]`
e saltato. È la difesa che impedisce a un agente di chiudere un item senza prove.

Al drenaggio il marker diventa:

| Marker | Significato |
|---|---|
| `[x]` | `done` — verifica verde e giudice d'accordo |
| `[!]` | `blocked` — reversibile con `/goal retry <id>` |
| `[?]` | `invalid` — `Verify:` assente o vuoto |
| `[ ]` | aperto |

Sotto l'item il drainer scrive data, turni, exit code e motivo del verdetto.

## Come decide

A ogni fine turno (`session.execution.succeeded`), in quest'ordine:

1. controlla il tetto di spesa; se superato, si ferma e riporta
2. esegue il comando `Verify:` dell'item e legge l'exit code
3. se rosso, reinietta l'output come continuazione e aspetta il turno dopo
4. se verde, chiede a un giudice un verdetto in JSON: `done`, `continue` o `blocked`

Il giudice **non viene mai consultato con una verifica rossa**, quindi non può
dichiarare `done` su un test che non gira. Se il giudice fallisce due volte, il
verdetto è `continue` con motivo "giudice non raggiungibile": un errore non è mai un
successo.

Il giudice gira con `session.generate` sulla sessione stessa: stateless, non tocca la
history, e non costa una sessione in più.

## Blocchi

Un item è marcato `blocked` solo se il giudice dichiara che manca un prerequisito che
nessun lavoro può creare. È **reversibile**: `/goal retry <id>` lo riapre. Un `[!]` non
conta come coda svuotata — il report dice "coda svuotata con N bloccati".

C'è anche un rilevamento di stallo: se la verifica resta rossa e i file sorgente non
cambiano per `stallTurns` turni (default 5), l'item è bloccato con motivo "nessun
progresso". Non scatta su una directory senza git: lì non c'è un dato onesto su cui
decidere.

## Budget

`budgetPercent` (default **10**) è la percentuale del limite mensile che il drainer può
consumare. Vale **solo per i modelli `opencode-go/*`**, gli unici che scalano
sull'abbonamento: i modelli del free tier non hanno tetto e il report lo dichiara invece
di mostrare uno `0%` che sembrerebbe una misura.

La spesa si accumula da `session.usage.updated`, attribuita al modello visto in
`session.step.started`. Il report mostra anche le soglie settimanale (50%) e 5 ore (20%)
di Go, che sono più strette del 10% mensile su una run lunga.

## Configurazione

```jsonc
{
  "plugins": [
    { "package": "/home/ld/opencode-goal",
      "options": {
        "budgetPercent": 10,
        "autoApprove": true,
        "stallTurns": 5,
        "verifyTimeoutMs": 600000,
        "watchdogMs": 1800000,
        "maxTurnsPerRun": 200,
        "monthlyLimitsUSD": { "opencode-go/space-bunny": 30 }
      } }
  ]
}
```

`monthlyLimitsUSD` ha come default la tabella dei limiti Go e resta sovrascrivibile.

`autoApprove` risponde `once` alle richieste di permesso per `edit`, `write` e `shell`
dentro il progetto, mentre un goal è attivo. **Mai `always`**: quella scelta scrive in
`/api/permission/saved` a livello di progetto e sopravvive a sessione, goal e riavvio.
`external_directory` non è mai auto-approvato.

## Garanzie

- il drainer **non attende un umano**: se si apre una domanda o un form, il goal si ferma
  con un motivo
- un prompt tuo durante il ciclo mette il goal in `paused-utente`: il ciclo finisce il
  turno e non reinietta
- un watchdog ferma il goal se non arriva nessun evento terminale per `watchdogMs`
- `state.json` ha un lease: due finestre sullo stesso progetto non drenano in parallelo
- due istanze del plugin sulla stessa directory non raddoppiano le continuazioni

## Sviluppo

```
npm test          # node:test sui moduli puri
npm run typecheck
```

Il substrato è stato misurato, non dedotto: `probe/out/FINDINGS.md` documenta cosa
esiste davvero in opencode 2.0.14 e cosa no. In particolare `session.idle` **non viene
mai emesso**, e il trigger è `session.execution.succeeded`.
