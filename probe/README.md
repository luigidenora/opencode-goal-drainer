# probe — il substrato runtime di opencode 2.0.14, misurato

Questa directory non è codice del goal drainer. È la **misura** su cui la spec
v2 è stata corretta, e su cui i task successivi devono appoggiarsi invece di
supporre.

La ragione di esistere: la spec è già stata scritta una volta su assunzioni
sbagliate. Il trigger `session.idle` che la v1 dava per emesso **non viene mai
emesso**, e nessuno lo aveva scoperto perché l'aveva dedotto dai typings. Questa
probe esiste perché la prossima volta la risposta sia un fatto, non una deduzione.

## Uso

```bash
PORT=4599 ROOT=/tmp/opencode/probe-home bash probe/run.sh
```

- `PORT` — porta libera su cui avviare il server della probe.
- `ROOT` — directory temporanea che diventa `HOME` e `XDG_CONFIG_HOME` isolati.
  Viene **cancellata e ricreata** a ogni esecuzione.

Uscita attesa: `0`, e `probe/out/FINDINGS.md` con sei sezioni `## Domanda N`.

Ci vogliono alcuni minuti: la probe esegue tre turni reali di modello più un
quarto per far chiamare il tool di prova dal modello.

## Cosa produce

| Percorso | Contenuto |
|---|---|
| `probe/out/FINDINGS.md` | **il documento da leggere.** Una sezione per ciascuna delle sei domande, ognuna con Risposta / Come è stata misurata / Cosa cambia nella spec |
| `probe/out/plugin-last.jsonl` | tutto ciò che il mini-plugin ha visto nel runtime, riga per riga |
| `probe/out/events-N.log` | righe `data:` grezze dello stream SSE, un file per listener |
| `probe/out/serve.log` | stdout e stderr del server |
| `probe/out/session-*.json` | snapshot di `GET /api/session/<id>` |
| `probe/out/q*.json` | risposte grezze delle singole prove |

`probe/plugin-probe/` è il mini-plugin che risponde alle domande 1 e 2. Non è
riutilizzabile nel plugin vero: serve solo a guardare il runtime.

## Le regole che la probe segue, e perché

**1. Mai `opencode api`.** Riutilizza in silenzio il servizio in background
condiviso dell'utente e legge la configurazione reale. Una probe fatta così dà
risultati falsi e non serve a niente. Tutto passa da `opencode serve` su porta
libera.

**2. `HOME` isolato non basta se l'ambiente parla.** Se la probe gira dentro una
sessione opencode, `OPENCODE_CONFIG` punta al file di configurazione gestito
dell'utente e il server "isolato" carica i suoi plugin. `run.sh` tira fuori con
`env -u` `OPENCODE_CONFIG`, `OPENCODE_CONFIG_CONTENT`, `OPENCODE_CONFIG_DIR`,
`OPENCODE_SESSION_ID`, `OPENCODE_CLIENT`, `OPENCODE_PORT`,
`OPENCODE_SERVER_PASSWORD`, `OPENCODE_SIMULATE`. È la differenza fra una misura e una
misura che sembra vera.

**3. La password viene fissata per via ambiente.** `OPENCODE_PASSWORD` funziona e
fa risparmiare di cacare la riga `server password …` nel log, che su questa build
non viene emessa quando la password arriva dall'ambiente.
`OPENCODE_SERVER_PASSWORD` **non** funziona: `/api/info` resta 401. Entrambe le
cose sono misurate, non dedotte.

**4. Aspettare il catalogo dei modelli.** `/api/info` risponde prima che il
catalogo dei modelli sia pronto. Un prompt lanciato in quella finestra fallisce
con `session.execution.failed` e `error.type = "provider.no-route"`, messaggio
`Model unavailable: …` — **identico** al fallimento di un modello inesistente.
Senza questa attesa, la domanda 6 misurerebbe una condizione di partenza e la
chiamerebbe `failed`.

**5. Il listener SSE si apre prima dell'azione.** Un evento terminale aperto
dopo che è già passato non si riprende.

**6. Niente valori dedotti.** Dove una prova non è riuscita, la sezione dice
**non misurato** e riporta l'errore esatto. Un numero inventato è peggio di una
casella vuota, perché la casella vuota si vede.

## Una nota su `as any`

`probe/plugin-probe/index.ts` non importa `@opencode-ai/plugin` e usa `any` ovunque.
Non è pigrizia: i typings 1.18.16 dichiarano un `PluginInput` con sette chiavi e un
`Hooks` con una forma che **non è quella del runtime di 2.0.14**. Scrivere contro
i typings produrrebbe codice che compila e non gira. La misura del runtime è
proprio ciò che il plugin-probe esiste per fare, quindi non può appoggiarsi ai
typings che sta smentendo.

I typings restano comunque un'ottima fonte per *cosa provare*: dicono dove
guardare, non cosa troverai.

## Cosa non fare con questa probe

- non chiamarla per fare debug del plugin vero: quando il plugin avrà i suoi test,
  quelli bastano
- non rieseguirla in un loop: consuma crediti di modello
- non modificare `FINDINGS.md` a mano per aggiornarlo. Se un fatto è cambiato, la
  probe va rieseguita: il valore di questo file è che ogni riga è stata osservata
  in una esecuzione reale