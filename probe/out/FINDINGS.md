# FINDINGS — probe del substrato runtime, opencode 2.0.14

Generato da `probe/run.sh` il 2026-10-07T13:18:51+02:00. Run `1791371903-869792`, porta `4599`, HOME isolato `/tmp/opencode/probe-home`.

Metodo: `opencode serve` su porta libera con `HOME` e `XDG_CONFIG_HOME` puntati a una
directory temporanea, e `env -u` su otto variabili d'ambiente
(`OPENCODE_CONFIG`, `OPENCODE_CONFIG_CONTENT`, `OPENCODE_CONFIG_DIR`,
`OPENCODE_SESSION_ID`, `OPENCODE_CLIENT`, `OPENCODE_PORT`,
`OPENCODE_SERVER_PASSWORD`, `OPENCODE_SIMULATE`).
**`opencode api` non è stato usato**: riusa il servizio in background condiviso e
leggerebbe la configurazione reale dell'utente.

Il `pid` riportato da `GET /api/info` viene confrontato con il pid che la probe ha
avviato: una porta occupata da un'altra istanza risponderebbe `200` prima che il
server della probe esista, e tutta la misura finirebbe addosso a quello.

Ogni risposta è un fatto misurato in questa esecuzione. Dove la prova non è riuscita
la sezione dice **non misurato** con l'errore esatto: nessun valore è dedotto dal
codice o dai typings.

Evidenze grezze in `probe/out/`: `serve.log`, `plugin-last.jsonl`,
`events-*.log`, `q*.json`, `session-*.json`.

---

## Domanda 1 — `command.transform` espone `add`?

### Risposta

**Sì.** Il draft passato a `command.transform` ha un solo membro, `add`, e il comando registrato compare in `GET /api/command`.

- chiavi del draft: `add`
- tipo dei membri: `{"add":"function"}`
- `typeof draft.add` = `function`, arità 1
- `draft.add({name, description, template})` → `{"payload":"{name,description,template}","ok":true,"returned":"[object Map]"}`

- `GET /api/command` contiene `probe_command`: `1` occorrenze
- descrizione del comando registrato, come la vede il server: `{"name":"probe_command","description":"Probe command. Chiama /probe_command con un argomento qualsiasi.","agent":null}`

### Come è stata misurata

`probe/plugin-probe/index.ts` chiama `ctx.command.transform(cb)` dentro `setup`, e
`cb` registra `Object.keys(draft)` e il tipo di ogni membro, poi chiama `draft.add`.
Il plugin è caricato da `$ROOT/.config/opencode/opencode.json` con
`plugins: [{package: "<repo>/probe/plugin-probe"}]`. L'errore che chiude la misura
è evitabile: `command.transform` prende **una callback**, non un editor — chiamarlo
con `{}` disabilita il plugin con `disabled plugin after transform failure …
'pe' is not a function`.

### Cosa cambia nella spec se la risposta è diversa da quella prevista

La spec v2 §4 dice: «Se `command.transform` espone davvero `add`, il comando si
registra da qui; altrimenti un `~/.config/opencode/commands/goal.md`. La probe lo
stabilisce e non cambia altro.» La risposta è **sì**, quindi la spec vale: nessun
file fuori dal repo, e `§3.2` (`"plugins": [{package: "/home/ld/opencode-goal"}]`)
è sufficiente. Se fosse stata no, `§4` andava riscritta e il plugin avrebbe dovuto
installare il file di comando — costo piccolo, nessun altro task dipende.

**Correzione che questa misura impone a `§2.3`.** La spec dice che «i typings V2 di
`PluginContext` non contengono `session`, `event`, `tool`, `permission`,
`generate``. I typings 1.18.16 in effetti non li contengono, ma il runtime li passa:
`Object.keys(input)` al `setup` = `app, location, options, agent, aisdk, command, event, experimental, generate, model, provider, integration, mcp, permission, plugin, reference, rpc, skill, storage, tool, vcs, websearch, worktree, session, shell`

---

## Domanda 2 — forma di `tool.transform`

### Risposta

**Misurata.** L'editor di `tool.transform` ha sei membri e i tool si registrano da lì.

- chiavi dell'editor: `list, get, namespace, add, update, remove`
- tipo dei membri: `{"list":"function","get":"function","namespace":"function","add":"function","update":"function","remove":"function"}`
- `typeof draft.add` = `function`, arità 1
- `draft.add({name, description, args, execute})` → `{"ok":true}`
- `draft.list()` prima del `add`: 60 tool, con `probe_tool` già presente: `true`
- `draft.get("probe_tool")` dopo il `add` → `{"ok":true,"type":"object","keys":["name","description","args","execute","id","options"]}`

Il tool è stato registrato dal plugin e **chiamato dal modello** durante un turno
reale su `opencode/space-bunny-free`. Cosa ricevono i due parametri di `execute`:

```json
{"args":{},"context":{"sessionID":"string","agent":"string","messageID":"string","id":"string","progress":"function","signal":"object"},"sessionID":"ses_ee9e9f741ffe7djc232vfNlVwC","messageID":"msg_116160ef9001Pi0S7tm52JPPQI","agent":"build","directory":null,"worktree":null,"abortType":"undefined","abortAborted":null,"metadataType":"undefined","askType":"undefined"}
```

- `Object.keys(args)` = `` — il tool è stato dichiarato con `args: {}`, quindi la lista vuota è quella attesa, non un'assenza di argomenti
- `Object.keys(context)` = `sessionID, agent, messageID, id, progress, signal`
- `context.directory` = `null`, `context.worktree` = `null` — **entrambi assenti**, benché i typings li dichiarino
- `typeof context.abort` = `undefined`, `typeof context.metadata` = `undefined`, `typeof context.ask` = `undefined`: il `ToolContext` dei typings 1.18.16 **non è** quello che il runtime passa

### Come è stata misurata

Come la 1, ma sul canale dei tool. `draft.add` **richiede un `name`**: senza,
fallisce con `TypeError: undefined is not an object (evaluating 'e.name.replace')`.
Con `name`, `description`, `args` ed `execute` va a buon fine e `draft.get("probe_tool")`
restituisce la definizione registrata. `args` e `context` dentro `execute` sono
registrati dal tool stesso quando il modello lo chiama: è l'unica prova onesta della
forma, perché `tool.transform` descrive l'editor e non l'invocazione.

### Cosa cambia nella spec se la risposta è diversa da quella prevista

La spec v2 non descrive `tool.transform`: la sua `§4` dà per scontato `tool
goal_control` come tool dichiarato. La misura **conferma** che la registrazione dal
plugin è possibile, ma con tre prezzi che la spec non prevedeva.

1. **`name` è obbligatorio.** Senza, `draft.add` fallisce con
   `TypeError: undefined is not an object (evaluating 'e.name.replace')`.
2. **La mappa `Hooks.tool` dei typings 1.18.16 non registra niente.** I tool si
   registrano dentro la callback di `ctx.tool.transform`. Un plugin che segue i
   typings — restituire `{ tool: { goal_control: {...} } }` da `setup` — non registra
   niente e, peggio, fa fallire il transform dei tool **per tutti gli altri
   plugin** (`disabled plugin after transform failure`, `state=tool`): un plugin
   scritto con i typings pubblicati può disabilitare il tool layer dell'intero
   server. Vale per `command`: la stessa chiave negli hooks disabilita il command
   layer (`state=command`). Quindi `setup` **non deve restituire chiavi `command` o
   `tool`**, e i tool vanno aggiunti con
   `ctx.tool.transform(draft => draft.add({name, description, args, execute}))`.
3. **`context` dentro `execute` non è il `ToolContext` dei typings.** I typings
   dichiarano `{sessionID, messageID, agent, directory, worktree, abort, metadata,
   ask}`; il runtime passa `{sessionID, agent, messageID, id, progress, signal}`.
   `directory` e `worktree` non ci sono, `abort` non è una chiave, `metadata` e
   `ask` mancano. Questo cambia il contratto di `src/index.ts`: `goal_control` non
   può usare `ctx.directory` — deve usare la directory che ha già nel lease di
   `state.json` (§9) — e l'annullamento è `context.signal`, non `context.abort`.
   Il `spec` di `goal_control` in T7 deve dichiararlo senza tipizzazioni.

---

## Domanda 3 — `POST /api/session` accetta `parentID`?

### Risposta

**No. `parentID` viene scartato: la sessione creata è una radice.** È l'esito previsto
dalla spec v2 e la §5 resta valida.

- `POST /api/session` con `parentID:"ses_nonexistent"` → HTTP `200`, sessione `ses_ee9e9e776ffeDivvRJ1nLDVy8U`
- `parentID` nella risposta della POST → `__NO_CHIAVE__`
- `parentID` in `GET /api/session/ses_ee9e9e776ffeDivvRJ1nLDVy8U` → `__NO_CHIAVE__`
- `parentID` in `GET /api/session` → `__NO_CHIAVE__`
- chiavi della sessione: `cost,id,location,projectID,time,title,tokens`
- richiesta di controllo identica **senza** `parentID` (`ses_ee9e9e735ffe5FJSLgcAKIwdgF`) → `parentID` = `__NO_CHIAVE__`
- `GET /api/session/ses_ee9e9e776ffeDivvRJ1nLDVy8U/children` → HTTP `404`, corpo: ``


### Come è stata misurata

Due richieste a `POST /api/session` identiche salvo la chiave `parentID`, più la
lettura di `GET /api/session` per cercare il campo, più `GET /api/session/<id>/children`.
Il confronto con la richiesta di controllo è ciò che distingue «la chiave è stata
scartata» da «il campo esiste ma è vuoto»: senza il controllo, un `parentID: null`
sembrerebbe la prova che `parentID` funzioni.

Nota sul payload: la specifica OpenAPI di `POST /api/session` per questa build non
ammette né `directory` né `parentID` — il campo directory si chiama `location:
{directory}`. Il brief chiedeva `{"directory": …, "parentID": …}`; la probe manda
`location` al suo posto, perché altrimenti misurerebbe uno schema sbagliato e non la
domanda.

### Cosa cambia nella spec se la risposta è diversa da quella prevista

Nessuna, se è «no»: è l'esito atteso, `§5` regge e il giudice resta
`session.generate` senza modello proprio. Se fosse «sì» — cioè se `parentID`
rispondesse `ses_nonexistent` — la spec v2 \§5 sarebbe superata dal fatto: il
giudice potrebbe avere una sessione propria con modello proprio, e `compress.ts`
tornerebbe necessario. **Questo è l\'unico esito che imporrebbe di fermarsi prima dei
task seguenti**, ed è dichiarato qui perché la decisione è di chi legge, non della probe.

---

## Domanda 4 — `session.generate` è davvero stateless?

### Risposta

**Funziona ed è davvero stateless: non scrive nella history e non tocca
`cost`, né `tokens`, né `outcome`.** La spec v2 §5 è confermata.
`generate` inoltre **non emette** `session.execution.*`: è una chiamata che
risponde su HTTP e non sullo stream.

- `POST /api/session/ses_ee9e9e724ffemrJbX4rz5jZuND/generate` {"prompt":"Rispondi SOLO con questo JSON: {…}"} → HTTP `200`
- testo ricevuto: `{"status":"continue","reason":"ok"}`
- messaggi in `GET /api/session/ses_ee9e9e724ffemrJbX4rz5jZuND/message`: prima `3`, dopo `3` — **messaggi nuovi: 0**
- tipi prima: `idle,assistant,user` — tipi dopo: `idle,assistant,user`
- `cost`: prima `0`, dopo `0`
- `tokens`: prima `{"input":5822,"output":3,"reasoning":0,"cache":{"read":465,"write":0}}`, dopo `{"input":5822,"output":3,"reasoning":0,"cache":{"read":465,"write":0}}`
- `outcome`: prima `succeeded`, dopo `succeeded`
- corpo completo di `generate`: `{"data":{"text":"{\"status\":\"continue\",\"reason\":\"ok\"}"}}`
- chiavi del primo elemento di `/message`: `id,outcome,time,type`

**La trappola che rende questa misura facile da sbagliare**, e che l'ha resa vera
solo alla terza esecuzione: `session.execution.succeeded` arriva **prima** che i
messaggi siano persistiti. Se si fa lo snapshot «prima» appena arriva l'evento, si
fotografa una sessione a metà turno — con il solo messaggio `user` — e il confronto
con lo snapshot «dopo» fa sembrare che `generate` abbia scritto due messaggi che in
realtà erano del primo turno. La prova va fatta aspettando che la sessione si
assesti (un `assistant` **e** un `idle` in `/message`), altrimenti si misura il
ritardo della persistenza e lo si attribuisce a `generate`.

Il testo di ritorno è la risposta del giudice al prompt, costruita con il contesto
della sessione già montato: il plugin non deve allegare il transcript, e
`compress.ts` resta correttamente sparito.

**Il caveat che resta dichiarato**: `cost` è `0` e i token sono
identici prima e dopo, ma il modello della prova è free — un valore `0` su un
modello gratis non distingue «`generate` non incassa» da «non può incassare». Su un
modello `opencode-go/*` questa misura **non lo sa** e non lo dichiarerà mai, perché
l'unico account disponibile per la probe è free. La spec lo dichiara già come rischio
noto in §14: è confermato come rischio reale, e resta aperto.


### Come è stata misurata

Sessione nuova su `space-bunny-free`, listener SSE aperto **prima** del prompt,
attesa di `session.execution.succeeded`, **poi attesa che la sessione si assesti**,
snapshot di `GET /api/session/<id>` e di `GET /api/session/<id>/message`, poi
`POST /api/session/<id>/generate`, poi gli stessi due snapshot.

Tre cose vengono confrontate, e vanno distinte perché dicono cose diverse:

- il **testo** di ritorno è la risposta che la spec usa per il verdetto del giudice
- **`cost` e `tokens`** dicono se il giudice pesa sul tetto di spesa
- **i messaggi in `/message`** dicono se `generate` lascia tracce nella conversazione

Il terzo è quello che la spec non si chiedeva.

Due errori che la prima stesura della probe ha commesso, e che valgono come
avvertimento:

1. **Contare i messaggi su `/session` invece che su `/message`.**
   `GET /api/session/<id>` non contiene i messaggi, quindi contarne lì dà sempre
   zero e sembrerebbe una prova di statelessness.
2. **Non aspettare che il turno sia persistito.** `session.execution.succeeded`
   arriva prima dei messaggi. La prima esecuzione riportava «1 prima, 3 dopo» e
   concludeva che `generate` scrivesse nella history; la seconda, dopo aver
   corretto il conteggio ma non l'attesa, riportava «1 prima, 2 dopo» con un
   `assistant` vuoto e concludeva la stessa cosa. La terza, aspettando l'assestamento,
   riporta zero messaggi nuovi ed è quella giusta.

Il tempo di assestamento non è trascurabile: nell'esecuzione corretta l'`assistant`
del primo turno è comparso circa 3 secondi dopo `succeeded`.

### Cosa cambia nella spec se la risposta è diversa da quella prevista

**Nulla: è l'esito atteso e la spec v2 §5 è confermata.** Il prompt viaggia con il
contesto della sessione già montato, senza transcript; la risposta torna nel corpo
della risposta HTTP e non nella history; `cost` e `tokens` non si muovono. Quindi
`compress.ts` resta correttamente sparito, e la §5 non va riscritta.

Un dettaglio che T6 deve sapere e che la spec non dice: **`generate` non emette
`session.execution.*`.** Il ciclo di §3.1 non riparte da solo dopo un verdetto, e
non deve: è il supervisore che inietta la `synthetic`. Ma chiunque scriva un test
di T6 aspettandosi un evento dopo `generate` aspetterà per sempre.

Il tetto di §8 resta aperto su un punto solo, ed è dichiarato in §14 come rischio
noto: su un modello free non si può distinguere «`generate` non incassa» da «non può
incassare perché il modello è gratis». `opencode-go/*` va misurato su una sessione a
pagamento, e finché non è fatto, il tetto deve contare anche il giudice — che è
comunque la scelta prudente.

---

## Domanda 5 — `/api/shell`: dove sta l'exit code, e cosa fa il timeout?

### Risposta

**L'exit code è nel campo `exit`** di `shell.get`, accanto a `status`.

- `POST /api/shell` {"command":"exit 3"} → `{"location":{"directory":"/tmp/opencode/probe-home/work"},"data":{"id":"sh_116163ce7001VEFXsCkZT1pDXJ","status":"running","command":"exit 3","cwd":"/tmp/opencode/probe-home/work","shell":"/usr/bin/bash","file":"/tmp/opencode/probe-home/.local/share/opencode/shell/e30f4f7f4dcaaffeec3e6ef7e7edd2824179067e/sh_116163ce7001VEFXsCkZT1pDXJ.out","pid":870077,"metadata":{},"time":{"started":1791371918567}}}`
- stato finale `exited`, campi di `shell.get`: `command,cwd,exit,file,id,metadata,pid,shell,status,time`
- campi che contengono "exit": `exit=3`
- `/output`: ``

**Al timeout `sleep 30` con `timeout: 2000` il comando viene ucciso, non esce:**
`status` diventa `timeout` (non `exited`, non `killed`) e **il campo `exit` non
esiste affatto** — la chiave è assente, quindi `obj["exit"]` è `undefined`. Il
decorso è nei `time`: `{"started":1791371918611,"completed":1791371920614}`, durata `2003` ms (timeout richiesto
2000). Campi di `shell.get`: `command,cwd,file,id,metadata,pid,shell,status,time`. Creazione: `{"location":{"directory":"/tmp/opencode/probe-home/work"},"data":{"id":"sh_116163d13001IdU6WKJvK3P7NJ","status":"running","command":"sleep 30","cwd":"/tmp/opencode/probe-home/work","shell":"/usr/bin/b`.

**Il comando uscito è ancora in lista:** `GET /api/shell` → `[]`.
`<id>` del comando uscito presente in lista: conteggio `0`.
`GET /api/shell/sh_116163ce7001VEFXsCkZT1pDXJ` dopo il termine → HTTP `200` (200 = resta
leggibile, 404 = sparisce).


### Come è stata misurata

`POST /api/shell` con `exit 3`, poi `GET /api/shell/<id>` in loop finché `status`
non è più `running`, con lettura di tutti i campi. Lo stesso con `sleep 30` e
`timeout: 2000`. Poi `GET /api/shell` per vedere se l'entry sopravvive. Il nome del
campo non è dedotto dallo schema: `exit` è una parola riservata in JavaScript, quindi
in TypeScript si legge `obj["exit"]` e non `obj.exit`, ed è il punto in cui un
`.d.ts` ingannevole fa scrivere `undefined`.

### Cosa cambia nella spec se la risposta è diversa da quella prevista

La spec v2 \§2.2 scrive «exit code in `shell.get`` senza dire il campo, quindi è
compatibile con `exit`. Ci sono due risposte che cambierebbero qualcosa: se
`timeout` **uccidesse** il processo senza campo `exit`, `src/verifier.ts` non
potrebbe distinguere «timeout» da «exit 124» e servirebbe un flag dedicato; se il
comando sparisse dalla lista, la pulizia di §5 in `api.ts` (`shellRemove`) diventerebbe
inutile ma innocua. Entrambe sono dettagli di T5, non cambiano \§3.

---

## Domanda 6 — `session.execution.failed` e `interrupted`

### Risposta

**Entrambi arrivano davvero, con payload distinti.** `interrupted` porta
`data.reason:"user"`; `failed` porta `data.error` con `type` e `message`.

- `interrupted`: `POST /api/session/ses_ee9e9baa8ffeBMpxNDnM9YjDon/interrupt` → HTTP `200`, corpo `{"interrupted":true}`.
  `session.execution.*` arrivati: `session.execution.interrupted session.execution.started`. `outcome` della sessione dopo: `interrupted`.
  Payload: `{"id":"evt_116165907001vOKzhBPX8axCBV","created":1791371925767,"type":"session.execution.interrupted","data":{"sessionID":"ses_ee9e9baa8ffeBMpxNDnM9YjDon","reason":"user"},"durable":{"aggregateID":"ses_ee9e9baa8ffeBMpxNDnM9YjDon","seq":10,"version":1}}`
- `session.step.failed` in questa esecuzione: `{"id":"evt_1161659050018pcnv6HKHef6iy","created":1791371925765,"type":"session.step.failed","location":{"directory":"/tmp/opencode/probe-home/work"},"data":{"sessionID":"ses_ee9e9baa8ffeBMpxNDnM9YjDon","assistantMessageID":"msg_1161649640010n4hA1HbPnsBLb","error":{"type":"aborted","message":"Step interrupted"}},"durable":{"aggregateID":"ses_ee9e9baa8ffeBMpxNDnM9YjDon","seq":9,"version":1}}`
  (arrivato, con `data.error.type` e `data.assistantMessageID`)
- `failed`: sessione su modello inesistente `ses_ee9e99d0cffeq68GEI7ly7WTZo`, `POST /prompt` → HTTP `200`.
  `session.execution.*` arrivati: `session.execution.failed session.execution.started`. `outcome` dopo: `failed`.
  Payload: `{"id":"evt_1161666ff0012sVST0wiCPpiYX","created":1791371929343,"type":"session.execution.failed","data":{"sessionID":"ses_ee9e99d0cffeq68GEI7ly7WTZo","error":{"type":"provider.no-route","message":"Model unavailable: opencode/modello-che-non-esiste-probe"}},"durable":{"aggregateID":"ses_ee9e99d0cffeq68GEI7ly7WTZo","seq":5,"version":1}}`

Riepilogo dei `type` distinti osservati su tutti i listener di questa esecuzione:
`server.connected session.execution.failed session.execution.interrupted session.execution.started session.execution.succeeded session.inbox.delivered session.inbox.enqueued session.instructions.updated session.reasoning.delta session.reasoning.ended session.reasoning.started session.step.ended session.step.failed session.step.started session.step.streamed session.text.delta session.text.ended session.text.started session.usage.updated`

La sua assenza è la misura che ha corretto la v1: `session.idle` **non compare in
nessuno dei listener di questa esecuzione** — `0` occorrenze in tutto,
su `3 (events-1.log events-2.log events-3.log)` file di eventi.
Il token esiste nel binario come dichiarazione di schema, ma nessun emittente lo
produce. È citato qui **solo** per documentare che la misura lo cerca e non lo
trova: nessun task successivo deve usarlo, nemmeno in un commento.


### Come è stata misurata

Listener SSE aperto **prima** del prompt in entrambi i casi, che è l'unico modo per
vedere gli eventi: aperto dopo, l'evento terminale è già passato.

Per `interrupted`: un prompt lunghissimo (3000 parole) su `space-bunny-free`, poi
`POST /api/session/<id>/interrupt` dopo 4 secondi, mentre il modello scriveva.

Per `failed`: **non** un prompt che il modello non può soddisfare. Un prompt
impossibile non è un errore: il modello risponde che non può, e il turno va a
`succeeded`. `failed` è l'esito di un turno che il runtime non può completare, e il
modo onesto di produrlo è una sessione su un modello che non esiste — errore del
runtime, non del modello.

### Cosa cambia nella spec se la risposta è diversa da quella prevista

**Poco: la spec v2 §3.1 e §9 sono confermate**, nessun ramo morto, nessuna
variazione di §3. `failed` e `interrupted` arrivano entrambi, con `outcome` coerente
nella sessione.

Tre precisazioni che T7 deve avere, perché cambiano il codice e non la spec:

1. **`interrupted` riporta solo `data.reason: "user"`.** Non dice perché il turno è
   finito male. Il motivo è in `session.step.failed`, che in un'esecuzione è arrivato
   **prima** (seq 9 contro seq 10) con `data.error = {type: "aborted", message:
   "Step interrupted"}` e `data.assistantMessageID`. Chi scrive il report di
   `/goal stop` deve ascoltare `session.step.failed`, non fidarsi di
   `session.execution.interrupted`.

2. **`session.step.failed` non è garantito da `interrupted`.** In un'esecuzione
   precedente di questa stessa probe l'interrupt è caduto mentre il runtime era in
   `session.retry.scheduled` — un errore di trasporto del provider,
   `ConnectionRefused` — e non dentro uno step: `step.failed` non è arrivato e
   `interrupted` sì. In questa esecuzione è arrivato. La coppia è quindi
   **variabile**, e un supervisore che vuole spiegare un interrupt deve trattare
   «nessun `step.failed`» come un caso possibile, non come un bug.
   `session.retry.scheduled` è un terzo evento da ascoltare, e §2.1 della spec non
   lo menziona: dice che il runtime è in riparazione, e il ciclo non deve contarlo
   come un turno.

3. **`failed` porta `data.error` tipizzato** — `type` è una stringa discriminante
   (`provider.no-route` misurato), `message` leggibile — **e `Session.Info.outcome`
   riporta il verdetto** (`interrupted`, `failed` misurati). Quindi un supervisore
   che perda un evento può comunque leggere lo stato finale dalla sessione: è la
   rete di sicurezza che rende accettabile non fare affidamento sui soli eventi.

---

## Extra misurato, fuori dalle sei domande

Sono fatti che le sei domande non chiedevano ma che le stesse prove hanno prodotto, e
che toccano la spec. Sono qui perché il report non deve perdere un fatto solo perché
nessuno lo aveva chiesto.

### Contratto del plugin, che i typings non descrivono

- **Il default export di un plugin non è una funzione.** È un oggetto
  `{ id, setup }` (o `{ id, effect }`). Un default export funzione viene rifiutato
  con `Plugin must export a default definition with an id and an effect or setup
  function.` I typings 1.18.16 dichiarano `Plugin` come funzione: sono sbagliati per
  2.0.14. Cambia l'intestazione di `src/index.ts` in T7.

- **`Object.keys(input)` al `setup`** (misurato, non deduotto):

  ```text
  app location options agent aisdk command event experimental generate model provider integration mcp permission plugin reference rpc skill storage tool vcs websearch worktree session shell
  ```

  I typings dichiarano sette chiavi: `client, project, directory, worktree,
  experimental_workspace, serverUrl, $`. Nel runtime ci sono ventisei, e le sette
  dei typings non ci sono più: non c'è `client`, non c'è `$`. Al loro posto ci sono
  i servizi su cui la spec §2.3 dice di non poter contare.

- **I servizi dentro l'input, con i loro metodi.** Sono l'alternativa alle rotte
  `/api/*` che §2.3 dichiara assenti dai typings, e la loro esistenza è un fatto:

  ```text
  session: hook(), create(), get(), switchAgent(), switchModel(), prompt(), generate(), command(), synthetic(), interrupt(), update(), move(), wait(), context()
permission: hook(), list(), get(), reply()
event: subscribe()
shell: hook()
vcs: get(), base(), branch(), status(), diff(), reload(), transform()
  ```

  Ci sono `session.generate`, `session.synthetic`, `session.interrupt`,
  `session.wait`, `permission.reply`, `event.subscribe`, `vcs.status`,
  `command.transform`, `tool.transform` — cioè esattamente le primitive che §2.2
  elenca come misurate via HTTP, disponibili anche come metodi. La scelta della
  spec di parlare al server con `fetch` su `/api/*` **regge**: sono gli stessi
  endpoint, ed è tipizzabile e testabile fuori da opencode. Ma la ragione addotta
  in §2.3 — «tutto ciò che serve è solo nei typings del binario, non pubblicati» —
  è sbagliata: questi servizi ci sono, sono solo assenti dai typings pubblicati.
  E `input.serverUrl` è `null`, quindi se T2 pensasse di derivare `baseURL` e
  autenticazione dal `ctx` resterebbe con le mani vuote: la sua scelta di non
  dipendere dal `ctx` è giusta, ma per un motivo diverso da quello scritto.

- **`OPENCODE_CONFIG` nell'ambiente rompe l'isolamento.** Se la probe gira dentro
  una sessione opencode, `OPENCODE_CONFIG` punta al file gestito dell'utente e il
  server «isolato» carica i suoi plugin. `env -u` su otto variabili è ciò che rende
  la misura credibile.

- **`opencode serve` non stampa `server password` quando la password viene
  dall'ambiente.** `OPENCODE_PASSWORD` funziona; `OPENCODE_SERVER_PASSWORD` **non**
  (`/api/info` resta 401). La probe fissa la password per via ambiente invece di
  leggere il log.

- **`input.serverUrl`, `input.directory`, `input.project` sono `null` e
  `input.worktree` è `{}`** dentro `setup`, con un `HOME` isolato. Se T2 conta su
  `baseURL` e autenticazione dal `ctx`, non li troverà lì: li prende da config o da
  `OPENCODE_PASSWORD`.


### Rotte misurate su questa build

- `POST /api/session`, `GET /api/session`, `GET /api/session/<id>`,
  `GET /api/session/<id>/message`, `POST /api/session/<id>/prompt`,
  `POST /api/session/<id>/generate`, `POST /api/session/<id>/interrupt`,
  `POST /api/shell`, `GET /api/shell`, `GET /api/shell/<id>`,
  `GET /api/shell/<id>/output`, `GET /api/event`, `GET /api/plugin`,
  `GET /api/command`, `GET /api/info`.
- **`GET /api/tool` non esiste** su 2.0.14: non è in `/openapi.json` e risponde
  `404` (misurato, HTTP `404`). Il brief lo indicava come disponibile; la
  forma dei tool si misura dal plugin (Q2), non dall'endpoint.
- `GET /api/session/<id>/children` non è in `/openapi.json` e risponde `404`
  (misurato, HTTP `404`).


---

## Traccia

- run: `1791371903-869792`
- porta: `4599`, `HOME=$ROOT`, cwd `$ROOT/work`
- log del server: `probe/out/serve.log`
- eventi SSE: 3 (events-1.log events-2.log events-3.log) file in `probe/out/events-*.log`
- output del plugin: `probe/out/plugin-last.jsonl`
- snapshot di sessione: `probe/out/session-*.json`

Questa esecuzione ha girato sul mini-plugin `probe/plugin-probe/index.ts`, che
registra `probe_command` e `probe_tool` solo per essere osservato. Per rieseguire:
`PORT=<porta libera> ROOT=<dir temporanea> bash probe/run.sh`. Le regole che la
probe segue, e perché, sono in `probe/README.md`.
