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

`probe/out/` viene **svuotato a ogni esecuzione**. È deliberato: ogni artefatto
citato in `FINDINGS.md` deve essere di quella esecuzione, senza una versione
precedente che lo contraddica. `probe/out/FINDINGS.md` è l'unico file committato.

Ci vogliono alcuni minuti: quattro turni reali di modello, più un secondo server per
le controprove.

## Cosa produce

| Percorso | Contenuto |
|---|---|
| `probe/out/FINDINGS.md` | **il documento da leggere.** Una sezione per ciascuna delle sei domande, ognuna con Risposta / Come è stata misurata / Cosa cambia nella spec |
| `probe/out/plugin-last.jsonl` | tutto ciò che il mini-plugin ha visto nel runtime, riga per riga |
| `probe/out/events-N.log` | righe `data:` grezze dello stream SSE, un file per listener |
| `probe/out/serve.log` | stdout e stderr del server |
| `probe/out/session-*.json` | snapshot di `GET /api/session/<id>` |
| `probe/out/q*.json` | risposte grezze delle singole prove |
| `probe/out/controprove/` | log del server delle controprove e stato dei plugin difettosi |
| `probe/controprove/` | i plugin volutamente mal scritti che generano gli errori citati |

`probe/plugin-probe/` è il mini-plugin che risponde alle domande 1 e 2. Non è
riutilizzabile nel plugin vero: serve solo a guardare il runtime.
`probe/controprove/` contiene due plugin **volutamente sbagliati**, per produrre gli
errori che il percorso felice non genera.

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

**3. La password viene fissata per via ambiente.** `OPENCODE_PASSWORD` e
`OPENCODE_SERVER_PASSWORD` autenticano allo stesso modo — entrambe misurate in
esecuzioni separate, con due server che differiscono solo per quella variabile. La
probe usa `OPENCODE_PASSWORD` per un motivo diverso: con una password
dell'ambiente, `opencode serve` **non stampa** la riga `server password …`, quindi
andare a leggerla nel log renderebbe la probe dipendente da una riga che questa
build non emette in quel caso.

Il dettaglio che è costato un errore a una versione precedente: `curl` restituisce
`000` quando la connessione fallisce, e quel `000` **non** è un `401`. Prima di
concludere che una variabile «non autentica», va verificato che il server fosse in
ascolto — dal suo stdout, che è l'unico canale che non dipende
dall'autenticazione.

**4. Aspettare il catalogo dei modelli.** `/api/info` risponde prima che il
catalogo dei modelli sia pronto. Un prompt lanciato in quella finestra fallisce
con `session.execution.failed` e `error.type = "provider.no-route"`, messaggio
`Model unavailable: …` — **identico** al fallimento di un modello inesistente.
Senza questa attesa, la domanda 6 misurerebbe una condizione di partenza e la
chiamerebbe `failed`.

Questa ambiguità ha un prezzo che va detto, non solo evitato: quando `run.sh`
produce `failed` **volendo**, usando un modello inesistente, quel `failed` non
dimostra che `failed` significhi «modello inesistente». Dimostra che l'evento arriva
e che `data.error` è tipizzato. Un task che debba distinguere i due casi deve
ricontrollare il catalogo quando legge `failed`.

**5. Il listener SSE si apre prima dell'azione, e le attese filtrano per sessione.**
Un evento terminale aperto dopo che è già passato non si riprende. E
`GET /api/event` è **un unico stream per tutto il server**, non per sessione: un
attesa che guarda solo il `type` può essere soddisfatta dall'evento di una sessione
che sta ancora girando. `sse_wait` in `run.sh` filtra su `data.sessionID` e rifiuta di
partire senza `SESSION_ID` impostata.

**6. Niente valori dedotti.** Dove una prova non è riuscita, la sezione dice
**non misurato** e riporta l'errore esatto. Un numero inventato è peggio di una
casella vuota, perché la casella vuota si vede.

**7. Le osservazioni sul percorso di errore hanno bisogno di controprove.** Il
percorso felice della probe non genera i messaggi che descrivono cosa succede
quando un plugin è scritto male — e senza artefatto, quelle righe in
`FINDINGS.md` sarebbero prese da un'esecuzione precedente e non sarebbero più
verificabili. `probe/controprove/` avvia un **secondo server**, con il proprio HOME e
la propria porta, e carica plugin volutamente difettosi. Artefatti in
`probe/out/controprove/`.

**8. Le variabili che il documento interpola sono inizializzate tutte.** Con
`set -euo pipefail`, una variabile che un `if` non entra ad assegnare fa
schiantare la scrittura di `FINDINGS.md`: la probe produrrebbe **nessun**
documento invece di un documento con un «non misurato». Il fallback è proprio ciò
che il brief pretende, quindi non può essere il primo caso a cedere.

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
- non rieseguirla in un loop: fa quattro turni di modello e ci mette qualche minuto
- non modificare `FINDINGS.md` a mano per aggiornarlo. Se un fatto è cambiato, la
  probe va rieseguita: il valore di questo file è che ogni riga è stata osservata
  in una esecuzione reale