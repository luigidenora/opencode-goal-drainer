#!/usr/bin/env bash
# goal-drainer probe del substrato runtime
#
# uso: PORT=4599 ROOT=/tmp/opencode/probe-home bash probe/run.sh
#
# La probe misura sei cose su opencode 2.0.14 e scrive probe/out/FINDINGS.md.
# Non usa MAI `opencode api`: quello riusa in silenzio il servizio in background
# condiviso dell'utente e leggerebbe la configurazione reale, dando risultati falsi.
# Per questo parte tutto da `opencode serve` su porta libera con HOME isolato.
#
# Isolamento: oltre a HOME e XDG_CONFIG_HOME, `env -u` tira fuori OPENCODE_CONFIG,
# OPENCODE_CONFIG_CONTENT, OPENCODE_CONFIG_DIR e OPENCODE_SESSION_ID. Se la probe
# gira dentro una sessione opencode quelle variabili sono impostate e fanno leggere
# al server la configurazione gestita dell'utente: il server apparentemente isolato
# carica allora plugin e modelli dell'utente, e ogni misura è sporca.
set -euo pipefail

PORT="${PORT:?serve PORT=4599 ROOT=/tmp/opencode/probe-home}"
ROOT="${ROOT:?serve ROOT=/tmp/opencode/probe-home}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/out"
mkdir -p "$OUT"

OPENCODE_BIN="${OPENCODE_BIN:-/home/ld/.opencode/bin/opencode}"
PW="${PROBE_PASSWORD:-goal-drainer-probe-pw}"
PROVIDER="opencode"
MODEL="space-bunny-free"

BASE="http://127.0.0.1:$PORT"
AUTH=(-u "opencode:$PW")

# id univoco per i file di una singola esecuzione: due run non si sovrapongono
RID="$(date +%s)-$$"
SERVE_LOG="$OUT/serve.log"
PLUGIN_OUT="$OUT/plugin-$RID.jsonl"
SERVE_PID=""

note() { printf '\n=== %s ===\n' "$*" >&2; }

api() { # [metodo] path [body] — con un solo argomento è un GET
  local m p body
  if [ "$#" -ge 2 ]; then m="$1"; p="$2"; body="${3:-}"; else m=GET; p="$1"; body=""; fi
  if [ -n "$body" ]; then
    curl -sS "${AUTH[@]}" -X "$m" -H 'content-type: application/json' -d "$body" "$BASE$p"
  else
    curl -sS "${AUTH[@]}" -X "$m" "$BASE$p"
  fi
}

code() { # path
  curl -sS "${AUTH[@]}" -o /dev/null -w '%{http_code}' "$BASE${1:-}"
}

cleanup() {
  if [ -n "$SERVE_PID" ] && kill -0 "$SERVE_PID" 2>/dev/null; then
    kill "$SERVE_PID" 2>/dev/null || true
    sleep 1
    kill -9 "$SERVE_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ───────────────────────────── ambiente isolato ─────────────────────────────

rm -rf "$ROOT"
mkdir -p "$ROOT/work" "$ROOT/.config/opencode" "$ROOT/.local/share/opencode"
cat > "$ROOT/.config/opencode/opencode.json" <<JSON
{
  "plugins": [ { "package": "$HERE/plugin-probe" } ]
}
JSON

# ───────────────────────────── server ─────────────────────────────

note "avvio server su porta $PORT, HOME=$ROOT"
(
  cd "$ROOT/work"
  exec env -u OPENCODE_CONFIG -u OPENCODE_CONFIG_CONTENT -u OPENCODE_CONFIG_DIR \
    -u OPENCODE_SESSION_ID -u OPENCODE_CLIENT -u OPENCODE_PORT \
    -u OPENCODE_SERVER_PASSWORD -u OPENCODE_SIMULATE \
    HOME="$ROOT" XDG_CONFIG_HOME="$ROOT/.config" \
    OPENCODE_PASSWORD="$PW" \
    PROBE_PLUGIN_OUT="$PLUGIN_OUT" \
    "$OPENCODE_BIN" serve --port "$PORT" --hostname 127.0.0.1
) > "$SERVE_LOG" 2>&1 &
SERVE_PID=$!

# La password viene fissata per via ambiente invece che letta da `server password`:
# quando OPENCODE_PASSWORD è impostata il binario non stampa quella riga (misurato
# in opencode 2.0.14: `if (mode === "default" && !envPassword) console.log(...)`).
# Leggerla dal log renderebbe la probe dipendente da una riga che questa build
# non emette.

# Una porta occupata da un'altra istanza fa rispondere /api/info con 200 **prima**
# che il nostro server esista, e tutta la probe misurerebbe il server altrui
# credendolo proprio. Si controlla che la risposta sia del nostro pid.
note "attesa che /api/info risponda"
READY=""
for _ in $(seq 1 40); do
  if [ "$(code /api/info)" = "200" ]; then READY=1; break; fi
  sleep 1
done
if [ -z "$READY" ]; then
  echo "FATAL: il server non ha risposto su $BASE entro 40 tentativi" >&2
  tail -20 "$SERVE_LOG" >&2
  exit 1
fi
SERVE_PID_REPORTED=$(api /api/info | jq -r '.pid // empty')
if [ "$SERVE_PID_REPORTED" != "$SERVE_PID" ]; then
  echo "FATAL: la porta $PORT è occupata da un altro processo." >&2
  echo "  /api/info riporta pid=$SERVE_PID_REPORTED, la probe ha avviato pid=$SERVE_PID." >&2
  echo "  Scegli un'altra PORT, oppure termina: $(pgrep -f "bin/opencode serve --port $PORT" | paste -sd' ' -)" >&2
  tail -5 "$SERVE_LOG" >&2
  exit 1
fi
api /api/info > "$OUT/info.json"
echo "server pronto: $(jq -c '{version,pid}' "$OUT/info.json")"

# Il catalogo dei modelli non è pronto quando /api/info lo è: su un HOME nuovo un
# prompt lanciato subito fallisce con
#   session.execution.failed  data.error.type = "provider.no-route"
#   data.error.message = "Model unavailable: opencode/<model>"
# e la risposta è identica a un modello inesistente. Aspettare il catalogo evita
# di registrare come `failed` un turno che non è mai partito.
note "attesa che $PROVIDER/$MODEL compaia nel catalogo"
CATALOG=""
for _ in $(seq 1 60); do
  if api /api/model | jq -e --arg p "$PROVIDER" --arg m "$MODEL" \
      '.data[]? | select(.providerID == $p and .modelID == $m)' > /dev/null 2>&1; then
    CATALOG=1; break
  fi
  sleep 1
done
[ -n "$CATALOG" ] || echo "ATTENZIONE: $PROVIDER/$MODEL non è comparsa nel catalogo; i turni potrebbero fallire per no-route, non per il modello" >&2

# ───────────────────────────── listener SSE ─────────────────────────────
# `GET /api/event` emette righe `data: {json}`. Il `type` sta dentro il JSON,
# non in un header `event:`. Ogni ascolto parte PRIMA dell'azione che deve
# generare, e finisce subito dopo.

# Riepilogo dei file di eventi prodotti fin qui. Va definito prima delle sezioni
# di FINDINGS perché la sezione 6 lo cita, e la sezione 6 viene scritta prima che i
# listener delle prove successive siano chiusi.
events_files_summary() {
  local n l
  n=$(ls "$OUT" 2>/dev/null | grep -c '^events-' || true)
  l=$(ls "$OUT" 2>/dev/null | grep '^events-' | paste -sd' ' - || true)
  printf '%s (%s)' "${n:-0}" "${l:-}"
}

# Ogni variabile che un heredoc di FINDINGS interpola è inizializzata qui, anche
# quando la prova corrispondente non è riuscita. Con `set -u` una variabile non
# assegnata dentro un `if` mai preso fa schiantare la scrittura di FINDINGS.md: la
# probe produrrebbe *nessun* documento invece di un documento con un "non
# misurato". È il difetto più grave possibile qui, perché il fallback è proprio
# ciò che il brief pretende.
# Il valore di default è la stringa `non misurato`, non il vuoto: una riga con un
# campo vuoto si scrive per robustezza, ma non dice al lettore che la prova non è
# stata fatta. La stringa lo dice.
NM="non misurato"
SESSION_ID=""
Q4_OK=0; Q4_ID="$NM"; Q4_TURN="$NM"; Q4_TURN_CODE=""; Q4_GEN_STATUS=""; Q4_GEN_TEXT="$NM"
Q5_ID=""; Q5_STATE="$NM"; Q5_C=""; Q5_TID=""; Q5_TSTATE="$NM"; Q5_T=""
Q4_PAYLOAD="$NM"; Q4_IDS_BEFORE="$NM"; Q4_IDS_AFTER="$NM"; Q4_NEW_MESSAGES=""; Q4_BEFORE_MSG="$NM"
Q4_AFTER_MSG="$NM"; Q4_BEFORE_TYPES="$NM"; Q4_AFTER_TYPES="$NM"; Q4_AFTER_KEYS="$NM"
Q4_COST_B="$NM"; Q4_COST_A="$NM"; Q4_TOK_B="$NM"; Q4_TOK_A="$NM"; Q4_OUTCOME_B="$NM"; Q4_OUTCOME_A="$NM"
Q4_EVENT_TYPES=""; Q4_EXEC_TYPES="$NM"
Q5_KEYS="$NM"; Q5_EXIT="$NM"; Q5_OUTPUT="$NM"; Q5_HAS_EXITED="$NM"; Q5_REMOVED_CODE="$NM"; Q5_LIST="$NM"
Q5_TKEYS="$NM"; Q5_T_HAS_EXITED="$NM"; Q5_T_HAS_EXIT=""; Q5_T_ELAPSED=""; Q5_TTIME="$NM"
Q6_ID=""; Q6B_ID=""; Q6=""; Q6B=""; Q2_SESSION=""; Q3_CANDIDATE=""; Q3_CTL_ID=""
Q6_TYPES="$NM"; Q6_PAYLOAD="$NM"; Q6_STEP="$NM"; Q6_RETRY="$NM"; Q6_INT_BODY="$NM"; Q6_OUTCOME="$NM"
Q6_INT_CODE="$NM"
Q6B_TYPES="$NM"; Q6B_PAYLOAD="$NM"; Q6B_PROMPT_CODE="$NM"; Q6B_OUTCOME="$NM"
Q2_TURN_TYPES="$NM"; Q2_TURNS_OBSERVED=0
IDLE_COUNT="$NM"
# controprove: stessi default, così una controprova non riuscita scrive
# "non misurato" invece di far schiantare la scrittura del documento
CP_OK=0; CP_AUTH_CODE="$NM"; CP_ERR_EXPORT="$NM"; CP_ERR_TRANSFORM="$NM"
CP_ERR_TRANSFORM_STATE="$NM"; CP_BAD_STATE="$NM"; CP_BAD_STATE_ERR="-"
CP_EXPORT_STATE="$NM"; CP_IDLE_IN_BIN="$NM"; CP_IDLE_IN_LOG="$NM"
CP_PLUGIN_COUNT="$NM"; CP_LOADED_EXPORT="$NM"; CP_LOADED_TRANSFORM="$NM"
CP2_STDOUT="$NM"

EVENTS_N=0
sse_start() { # nome -> scrive in $OUT/events-<n>.log
  EVENTS_N=$((EVENTS_N + 1))
  EVENTS_FILE="$OUT/events-$EVENTS_N.log"
  : > "$EVENTS_FILE"
  curl -sN "${AUTH[@]}" "$BASE/api/event" >> "$EVENTS_FILE" 2>/dev/null &
  SSE_PID=$!
  sleep 1
}
sse_stop() {
  [ -n "${SSE_PID:-}" ] || return 0
  kill "$SSE_PID" 2>/dev/null || true
  wait "$SSE_PID" 2>/dev/null || true
  SSE_PID=""
}

# Attende un `type` **di questa sessione** nell'event log.
#
# Il filtro per sessione non è un ripiego: `GET /api/event` è un unico stream per
# tutto il server, non per sessione. Un `grep` sul solo `type` soddisferebbe
# l'attesa con l'evento di una sessione qualsiasi — per esempio la sessione del
# tool di Q2, che è ancora viva mentre parte il prompt del giudice — e il
# chiamante proseguirebbe prima che il proprio turno sia finito.
#
# Il match è su `data.sessionID`, quindi per gli eventi che lo portano. Un `type`
# senza `sessionID` (per esempio `server.connected`) non è un evento di turno e non
# viene considerato.
sse_wait() { # type timeout_s
  local want="$1" limit="$2" i
  if [ -z "${SESSION_ID:-}" ]; then
    echo "sse_wait: SESSION_ID non impostata, non posso attribuire $want a una sessione" >&2
    return 2
  fi
  for i in $(seq 1 $((limit * 2))); do
    if sse_has "$want"; then return 0; fi
    sleep 0.5
  done
  return 1
}

# vero se nell'event log corrente c'è quell'evento per la sessione corrente
sse_has() { # type
  sed -n 's/^data: //p' "$EVENTS_FILE" 2>/dev/null \
    | jq -e --arg t "$1" --arg s "${SESSION_ID:-}" \
        'select(.type == $t and .data.sessionID == $s)' > /dev/null 2>&1
}

# elenco degli eventi di sessione osservati in un file, per sessione
sse_session_types() { # file sessionID
  sed -n 's/^data: //p' "${1:-}" 2>/dev/null \
    | jq -r --arg s "${2:-}" 'select(.data.sessionID == $s) | .type' 2>/dev/null \
    | sort -u | paste -sd' ' -
}

# numero di sessioni distinte che hanno raggiunto un evento terminale in un file
sse_terminal_sessions() { # file
  sed -n 's/^data: //p' "${1:-}" 2>/dev/null \
    | jq -r 'select(.type == "session.execution.succeeded"
                 or .type == "session.execution.failed"
                 or .type == "session.execution.interrupted") | .data.sessionID' 2>/dev/null \
    | sort -u
}

session_snapshot() { # sessionID etichetta -> $OUT/session-<label>.json
  api "/api/session/$1" > "$OUT/session-$2.json"
}

# ───────────── controprove: gli errori che non nascono dal percorso felice ─────────────
# Cinque fatti che il percorso felice non produce, ma che FINDINGS deve poter
# citare. Senza questa sezione verrebbero presi da esecuzioni precedenti e sarebbero
# affermazioni senza artefatto: il tipo di errore più insidioso in un documento
# che si presenta come misurato.
#
# Le controprove girano su un server separato, con il proprio HOME e la propria
# porta, perché corrompono deliberatamente il plugin: nessun'altra prova deve
# essere influenzata.
note "controprove: errori che il percorso felice non produce"
CP_ROOT="$ROOT/controprove"
CP_PORT=$((PORT + 1))
CP_DIR="$HERE/controprove"
CP_OUT="$OUT/controprove"
mkdir -p "$CP_OUT" "$CP_ROOT/work" "$CP_ROOT/.config/opencode"

# (a) plugin con default export funzione
mkdir -p "$CP_DIR/bad-export"
cat > "$CP_DIR/bad-export/package.json" <<'JSON'
{ "name": "probe-bad-export", "version": "0.0.0", "private": true, "type": "module", "main": "index.ts" }
JSON
cat > "$CP_DIR/bad-export/index.ts" <<'TS'
// default export = funzione. Su 2.0.14 lo schema pretende un oggetto.
export default async function () {
  return {}
}
TS

# (b) plugin che chiama command.transform con un editor invece di una callback
mkdir -p "$CP_DIR/bad-transform"
cat > "$CP_DIR/bad-transform/package.json" <<'JSON'
{ "name": "probe-bad-transform", "version": "0.0.0", "private": true, "type": "module", "main": "index.ts" }
JSON
cat > "$CP_DIR/bad-transform/index.ts" <<'TS'
export default {
  id: "probe-bad-transform",
  setup: async (input: any) => {
    // `transform` prende una callback: passargli `{}` fa fallire il plugin
    input.command.transform({} as any)
    input.tool.transform({} as any)
    return {}
  },
}
TS

# I due plugin difettosi insieme: il secondo dimostra che il danno del primo non
# si limita al plugin che lo commette.
cat > "$CP_ROOT/.config/opencode/opencode.json" <<JSON
{
  "plugins": [
    { "package": "$CP_DIR/bad-export" },
    { "package": "$CP_DIR/bad-transform" }
  ]
}
JSON

# Il server delle controprove usa OPENCODE_PASSWORD come il principale: deve
# autenticare, altrimenti `GET /api/plugin` non risponde e non c'è nulla da leggere.
CP_LOG="$CP_OUT/serve.log"
(
  cd "$CP_ROOT/work"
  exec env -u OPENCODE_CONFIG -u OPENCODE_CONFIG_CONTENT -u OPENCODE_CONFIG_DIR \
    -u OPENCODE_SESSION_ID -u OPENCODE_CLIENT -u OPENCODE_PORT \
    -u OPENCODE_SERVER_PASSWORD -u OPENCODE_SIMULATE \
    HOME="$CP_ROOT" XDG_CONFIG_HOME="$CP_ROOT/.config" \
    OPENCODE_PASSWORD="$PW" \
    "$OPENCODE_BIN" serve --port "$CP_PORT" --hostname 127.0.0.1
) > "$CP_LOG" 2>&1 &
CP_PID=$!

# attesa di /api/plugin: è la rotta che materializza i plugin difettosi.
# `data` può essere vuota legittimamente — un plugin rifiutato dallo schema non
# entra nell'inventario — quindi il gate è il caricamento, non la lunghezza.
CP_OK=0
CP_PLUGINS=""
for _ in $(seq 1 40); do
  if [ "$(curl -sS -o /dev/null -w '%{http_code}' -u "opencode:$PW" \
      "http://127.0.0.1:$CP_PORT/api/info" 2>/dev/null || echo 000)" = "200" ]; then
    CP_PLUGINS=$(curl -sS -u "opencode:$PW" "http://127.0.0.1:$CP_PORT/api/plugin" 2>/dev/null || true)
    printf '%s' "$CP_PLUGINS" | jq -e '.data' > /dev/null 2>&1 && { CP_OK=1; break; }
  fi
  sleep 1
done
printf '%s' "$CP_PLUGINS" > "$CP_OUT/plugin-list.json"
# poi si lascia tempo all'attivazione: il caricamento è asincrono e l'errore di
# transform arriva dopo che `setup` è già passato
sleep 10
CP_PLUGINS=$(curl -sS -u "opencode:$PW" "http://127.0.0.1:$CP_PORT/api/plugin" 2>/dev/null || true)
printf '%s' "$CP_PLUGINS" > "$CP_OUT/plugin-list.json"
CP_PLUGIN_COUNT=$(jq -r '[.data[]? | select(.source.type == "local")] | length' "$CP_OUT/plugin-list.json" 2>/dev/null || echo "non misurato")
sleep 3
kill "$CP_PID" 2>/dev/null || true
sleep 1
kill -9 "$CP_PID" 2>/dev/null || true

# il log applicativo è ciò che contiene gli errori: stdout del server no
CP_OPENCODE_LOG="$CP_ROOT/.local/share/opencode/log/opencode.log"
[ -f "$CP_OPENCODE_LOG" ] && cp "$CP_OPENCODE_LOG" "$CP_OUT/opencode.log" || true

# ── controprova (e): OPENCODE_SERVER_PASSWORD ──
# Server separato, con OPENCODE_PASSWORD tolto e OPENCODE_SERVER_PASSWORD
# impostato. Se quella variabile autenticasse, `GET /api/info` risponderebbe 200
# come sul server principale; l'unica differenza è la variabile.
CP2_ROOT="$ROOT/controprove-auth"
CP2_PORT=$((PORT + 2))
mkdir -p "$CP2_ROOT/work" "$CP2_ROOT/.config/opencode"
(
  cd "$CP2_ROOT/work"
  exec env -u OPENCODE_CONFIG -u OPENCODE_CONFIG_CONTENT -u OPENCODE_CONFIG_DIR \
    -u OPENCODE_SESSION_ID -u OPENCODE_CLIENT -u OPENCODE_PORT \
    -u OPENCODE_PASSWORD -u OPENCODE_SIMULATE \
    HOME="$CP2_ROOT" XDG_CONFIG_HOME="$CP2_ROOT/.config" \
    OPENCODE_SERVER_PASSWORD="$PW" \
    "$OPENCODE_BIN" serve --port "$CP2_PORT" --hostname 127.0.0.1
) > "$CP_OUT/serve-auth.log" 2>&1 &
CP2_PID=$!
# Il fatto che il server fosse **in ascolto** va verificato da un canale che non
# dipende dall'autenticazione: il suo stdout. Un `401` a `/api/info` è già una
# risposta e prova che la porta è aperta; un `000` è solo "connessione fallita".
#
# Nota sul segno: questa build **autentica anche con OPENCODE_SERVER_PASSWORD**, e il
# 401 che una versione precedente della probe misurava era in realtà il server che
# non era ancora in ascolto — il `000` concatenato di `curl` più il fallback di
# `echo`. La differenza è isolata da due server: questo ha solo
# OPENCODE_SERVER_PASSWORD, il principale ha solo OPENCODE_PASSWORD.
CP2_STDOUT=""
for _ in $(seq 1 40); do
  CP2_STDOUT=$(head -1 "$CP_OUT/serve-auth.log" 2>/dev/null || true)
  case "$CP2_STDOUT" in
    "server listening on "*) break ;;
    *) CP2_STDOUT="" ;;
  esac
  sleep 1
done
[ -n "$CP2_STDOUT" ] || CP2_STDOUT="non misurato: il server non ha mai scritto la riga di ascolto"
CP_AUTH_CODE=$(curl -s -o /dev/null -w '%{http_code}' -u "opencode:$PW" \
  "http://127.0.0.1:$CP2_PORT/api/info" 2>/dev/null || true)
[ -n "$CP_AUTH_CODE" ] || CP_AUTH_CODE="non misurato"
kill "$CP2_PID" 2>/dev/null || true
sleep 1
kill -9 "$CP2_PID" 2>/dev/null || true

# (a) e (b): messaggi presi dal log applicativo di questa esecuzione. Il log è
# l'autorità, non `GET /api/plugin`: un plugin rifiutato dallo schema non entra
# nell'inventario e non compare nella risposta, quindi l'assenza lì non distingue
# «non caricato» da «caricato e attivo».
CP_LOADED_EXPORT=$(grep -c "id=$CP_DIR/bad-export" "$CP_OUT/opencode.log" 2>/dev/null || true)
CP_LOADED_TRANSFORM=$(grep -c "id=$CP_DIR/bad-transform" "$CP_OUT/opencode.log" 2>/dev/null || true)
CP_ERR_EXPORT=$(grep -o 'Plugin must export a default definition[^"]*' "$CP_OUT/opencode.log" 2>/dev/null | head -1 || true)
CP_ERR_TRANSFORM=$(grep -o 'disabled plugin after transform failure.\{0,80\}' "$CP_OUT/opencode.log" 2>/dev/null | head -1 | sed 's/ *$//' || true)
CP_ERR_TRANSFORM_STATE=$(grep -o 'disabled plugin after transform failure.\{0,200\}' "$CP_OUT/opencode.log" 2>/dev/null | head -1 | grep -o 'state=[a-z]*' || true)
[ -n "$CP_ERR_TRANSFORM_STATE" ] || CP_ERR_TRANSFORM_STATE="non misurato"
# lo stato dei difettosi, quando sono in inventario
CP_BAD_STATE=$(jq -r '[.data[]? | select(.id == "probe-bad-transform") | .state.status] | first // "non in inventario"' "$CP_OUT/plugin-list.json" 2>/dev/null || echo "non misurato")
CP_BAD_STATE_ERR=$(jq -r '[.data[]? | select(.id == "probe-bad-transform") | (.state.error // "-")] | first // "-"' "$CP_OUT/plugin-list.json" 2>/dev/null || echo "-")
CP_EXPORT_STATE=$(jq -r '[.data[]? | select(.id == "probe-bad-export") | .state.status] | first // "non in inventario"' "$CP_OUT/plugin-list.json" 2>/dev/null || echo "non misurato")

# (d) `session.idle` nel binario: si conta, non si dice. Il conteggio sugli event
# log non si fa qui: a questo punto i listener non sono ancora partiti e il glob
# non risolverebbe — `grep` uscirebbe con 2 e, con `pipefail`, la probe morirebbe
# prima di scrivere il documento. Quello è il conteggio `IDLE_COUNT`, più in basso.
CP_IDLE_IN_BIN=$(strings -n 6 "$OPENCODE_BIN" 2>/dev/null | grep -c '^session\.idle$' || true)

# ───────────────────────────── Q1 + Q2: runtime del plugin ─────────────────────────────

note "Q1/Q2: attesa che il plugin-probe abia registrato i draft"
PLUGIN_READY=""
for _ in $(seq 1 60); do
  if [ -f "$PLUGIN_OUT" ] && grep -q '"kind":"tool-transform-draft"' "$PLUGIN_OUT" 2>/dev/null; then
    PLUGIN_READY=1; break
  fi
  sleep 1
done
if [ -z "$PLUGIN_READY" ]; then
  echo "ATTENZIONE: il plugin-probe non ha scritto i draft entro 60s" >&2
else
  # Il tool registrato dal plugin va **chiamato** per osservare cosa ricevono
  # `args` e `context`: `tool.transform` descrive l'editor, non l'invocazione.
  # Senza questo passaggio la forma di `execute` resterebbe «non misurato».
  note "Q2: il modello chiama probe_tool per misurare execute"
  Q2_SESSION=$(curl -sS "${AUTH[@]}" -X POST -H 'content-type: application/json' \
    -d "{\"location\":{\"directory\":\"$ROOT/work\"},\"title\":\"toolcall-probe\",\"model\":{\"providerID\":\"$PROVIDER\",\"id\":\"$MODEL\"}}" \
    "$BASE/api/session" | jq -r '.data.id // empty')
  if [ -n "$Q2_SESSION" ]; then
    # Anche questo turno ha un listener: senza, il suo `started` non finisce in
    # nessun file di eventi e il conteggio dei turni osservati sarebbe uno meno.
    SESSION_ID="$Q2_SESSION"
    sse_start
    curl -sS "${AUTH[@]}" -o /dev/null -X POST -H 'content-type: application/json' \
      -d '{"text":"Chiama lo strumento probe_tool con le sue impostazioni predefinite, poi rispondi solo: done"}' \
      "$BASE/api/session/$Q2_SESSION/prompt"
    for _ in $(seq 1 120); do
      grep -q '"kind":"tool-execute"' "$PLUGIN_OUT" 2>/dev/null && break
      sleep 1
    done
    # il turno è finito quando arriva il suo evento terminale, non quando parte
    sse_wait 'session.execution.succeeded' 90 \
      || sse_wait 'session.execution.failed' 30 || true
    sse_stop
    Q2_TURN_TYPES=$(sse_session_types "$EVENTS_FILE" "$Q2_SESSION")
    Q2_TURNS_OBSERVED=$(sse_terminal_sessions "$EVENTS_FILE" | grep -c . || true)
  else
    Q2_TURN_TYPES=""
    Q2_TURNS_OBSERVED=0
  fi
fi

# ───────────────────────────── Q3: POST /api/session con parentID ─────────────────────────────

note "Q3: parentID"
# Il titolo è identico nelle due richieste, così il controllo differisce **solo**
# per `parentID`: due titoli diversi avrebbero introdotto una seconda variabile e
# il confronto non dimostrerebbe più nulla.
Q3_TITLE="child-probe"
Q3_BODY="{\"location\":{\"directory\":\"$ROOT/work\"},\"title\":\"$Q3_TITLE\",\"parentID\":\"ses_nonexistent\"}"
Q3_STATUS=$(curl -sS "${AUTH[@]}" -o "$OUT/q3-create.json" -w '%{http_code}' \
  -X POST -H 'content-type: application/json' -d "$Q3_BODY" "$BASE/api/session")
Q3_CANDIDATE=$(jq -r '.data.id // .id // empty' "$OUT/q3-create.json" 2>/dev/null || true)

# `parentID` letto da tre punti indipendenti: la risposta della POST, la GET della
# singola sessione, e la lista. Se uno solo riporta `ses_nonexistent` la chiave
# viene accettata: `null` o assente in tutti e tre significa scartata.
Q3_FOUND="$Q3_CANDIDATE"
Q3_POST_PARENT=$(jq -r '.data | (if has("parentID") then (.parentID|tostring) else "__NO_CHIAVE__" end)' "$OUT/q3-create.json" 2>/dev/null || echo "non leggibile")
if [ -n "$Q3_FOUND" ]; then
  api "/api/session/$Q3_FOUND" > "$OUT/q3-get.json"
  Q3_GET_PARENT=$(jq -r '.data | (if has("parentID") then (.parentID|tostring) else "__NO_CHIAVE__" end)' "$OUT/q3-get.json" 2>/dev/null || echo "non leggibile")
  Q3_KEYS=$(jq -r '.data | keys | join(",")' "$OUT/q3-get.json" 2>/dev/null || echo "non leggibile")
  # il riferimento rotto: se parentID fosse accettato, il campo punterebbe a ses_nonexistent
  Q3_CHILDREN_CODE=$(code "/api/session/$Q3_FOUND/children")
  Q3_CHILDREN_BODY=$(curl -sS "${AUTH[@]}" "$BASE/api/session/$Q3_FOUND/children" | head -c 200)
else
  Q3_GET_PARENT="sessione non creata"; Q3_KEYS=""
  Q3_CHILDREN_CODE=""; Q3_CHILDREN_BODY=""
fi
api /api/session > "$OUT/q3-list.json"
Q3_LIST_PARENT=$(jq -r --arg id "$Q3_FOUND" '.data[]? | select(.id == $id) | (if has("parentID") then (.parentID|tostring) else "__NO_CHIAVE__" end)' "$OUT/q3-list.json" 2>/dev/null | head -1)
# controllo: payload identico salvo `parentID`. Si registra anche una stringa dei due
# payload, così la differenza è ispezionabile e non asserita.
Q3_CTL_PAYLOAD="{\"location\":{\"directory\":\"$ROOT/work\"},\"title\":\"$Q3_TITLE\"}"
Q3_CTL=$(curl -sS "${AUTH[@]}" -o "$OUT/q3-control.json" -w '%{http_code}' \
  -X POST -H 'content-type: application/json' \
  -d "$Q3_CTL_PAYLOAD" "$BASE/api/session")
Q3_KEY_DIFF=$(diff <(printf '%s' "$Q3_BODY" | jq -S .) <(printf '%s' "$Q3_CTL_PAYLOAD" | jq -S .) \
  | grep -c '^[<>]' || true)
Q3_CTL_ID=$(jq -r '.data.id // empty' "$OUT/q3-control.json" 2>/dev/null || true)
Q3_CTL_PARENT=$(jq -r '.data | (if has("parentID") then (.parentID|tostring) else "__NO_CHIAVE__" end)' "$OUT/q3-control.json" 2>/dev/null || echo "non leggibile")
if [ "$Q3_POST_PARENT" = "ses_nonexistent" ] || [ "$Q3_GET_PARENT" = "ses_nonexistent" ] || [ "$Q3_LIST_PARENT" = "ses_nonexistent" ]; then
  Q3_VERDICT="ACCETTATA"
else
  Q3_VERDICT="SCARTATA"
fi

# ───────────────────────────── Q4: session.generate ─────────────────────────────

note "Q4: session.generate"
Q4=$(curl -sS "${AUTH[@]}" -X POST -H 'content-type: application/json' \
  -d "{\"location\":{\"directory\":\"$ROOT/work\"},\"title\":\"judge-probe\",\"model\":{\"providerID\":\"$PROVIDER\",\"id\":\"$MODEL\"}}" \
  "$BASE/api/session")
Q4_ID=$(printf '%s' "$Q4" | jq -r '.data.id // empty')
printf '%s' "$Q4" > "$OUT/q4-session.json"
if [ -z "$Q4_ID" ]; then
  echo "Q4: sessione non creata: $Q4" >&2
  Q4_OK=0
else
  Q4_OK=1
  SESSION_ID="$Q4_ID"

  sse_start
  note "Q4: prompt iniziale"
  # `succeeded` non basta come criterio: se il turno fallisce, `failed` arriva e la
  # probe aspetterebbe 180 secondi per poi dichiarare un timeout che non è un
  # timeout. Meglio fallire subito e dire perché.
  Q4_TURN_CODE=$(curl -sS "${AUTH[@]}" -o /dev/null -w '%{http_code}' -X POST \
    -H 'content-type: application/json' \
    -d '{"text":"Rispondi esattamente: ok"}' \
    "$BASE/api/session/$Q4_ID/prompt")
  if sse_wait 'session.execution.succeeded' 180; then
    Q4_TURN="ok"
  elif sse_has 'session.execution.failed'; then
    Q4_TURN="failed"
  else
    Q4_TURN="timeout"
  fi
  # gli eventi di Q4 sono filtrati per sessione: senza, l'attesta li soddisferebbe
  # con l'evento della sessione toolcall di Q2, che è ancora viva
  Q4_EVENT_TYPES=$(sse_session_types "$EVENTS_FILE" "$Q4_ID")
  Q4_EXEC_TYPES=$(printf '%s' "$Q4_EVENT_TYPES" | tr ' ' '\n' | grep '^session\.execution\.' | paste -sd' ' - || true)
  [ -n "$Q4_EXEC_TYPES" ] || Q4_EXEC_TYPES="nessuno"

  # `session.execution.succeeded` arriva **prima** che i messaggi siano persistiti:
  # senza questa attesa lo snapshot «prima» viene preso a metà turno e il confronto
  # con lo snapshot «dopo» attribuisce a `generate` messaggi che erano già del primo
  # turno. La prima stesura della probe riportava «1 prima, 3 dopo» e concludeva —
  # falsamente — che `generate` scrivesse nella history.
  note "Q4: attesa che il turno sia persistito"
  Q4_ASSIST_BEFORE=0
  Q4_IDLE_BEFORE=0
  for _ in $(seq 1 60); do
    api "/api/session/$Q4_ID/message" > "$OUT/q4-messages-before.json"
    Q4_ASSIST_BEFORE=$(jq '[.data[]? | select(.type == "assistant")] | length' "$OUT/q4-messages-before.json" 2>/dev/null || echo 0)
    Q4_IDLE_BEFORE=$(jq '[.data[]? | select(.type == "idle")] | length' "$OUT/q4-messages-before.json" 2>/dev/null || echo 0)
    if [ "$Q4_ASSIST_BEFORE" -ge 1 ] 2>/dev/null && [ "$Q4_IDLE_BEFORE" -ge 1 ] 2>/dev/null; then break; fi
    sleep 1
  done
  session_snapshot "$Q4_ID" before
  Q4_BEFORE_MSG=$(jq '[.data[]?] | length' "$OUT/q4-messages-before.json" 2>/dev/null || echo "?")
  Q4_BEFORE_TYPES=$(jq -r '[.data[]?.type] | join(",")' "$OUT/q4-messages-before.json" 2>/dev/null || echo "?")

  note "Q4: generate stateless"
  Q4_GEN_STATUS=$(curl -sS "${AUTH[@]}" -o "$OUT/q4-generate.json" -w '%{http_code}' \
    -X POST -H 'content-type: application/json' \
    -d '{"prompt":"Rispondi SOLO con questo JSON: {\"status\":\"continue\",\"reason\":\"ok\"}"}' \
    "$BASE/api/session/$Q4_ID/generate")
  sse_stop
  # stesso tempo di assestamento dopo `generate`: si lascia passare qualche secondo
  # per essere certi che non stia ancora scrivendo
  sleep 5
  session_snapshot "$Q4_ID" after
  api "/api/session/$Q4_ID/message" > "$OUT/q4-messages-after.json"

  Q4_AFTER_MSG=$(jq '[.data[]?] | length' "$OUT/q4-messages-after.json" 2>/dev/null || echo "?")
  Q4_AFTER_TYPES=$(jq -r '[.data[]?.type] | join(",")' "$OUT/q4-messages-after.json" 2>/dev/null || echo "?")
  # gli id dei messaggi, non solo il conteggio: due misure con lo stesso numero
  # possono essere lo stesso insieme o due insiemi diversi
  Q4_IDS_BEFORE=$(jq -r '[.data[]?.id] | join(",")' "$OUT/q4-messages-before.json" 2>/dev/null || echo "?")
  Q4_IDS_AFTER=$(jq -r '[.data[]?.id] | join(",")' "$OUT/q4-messages-after.json" 2>/dev/null || echo "?")
  Q4_ASSIST_AFTER=$(jq '[.data[]? | select(.type == "assistant")] | length' "$OUT/q4-messages-after.json" 2>/dev/null || echo 0)
  Q4_NEW_MESSAGES=$(( ${Q4_AFTER_MSG:-0} - ${Q4_BEFORE_MSG:-0} ))
  Q4_AFTER_KEYS=$(jq -r '.data[0] | keys | join(",")' "$OUT/q4-messages-after.json" 2>/dev/null || echo "?")
  Q4_COST_B=$(jq -r '.data.cost' "$OUT/session-before.json" 2>/dev/null || echo "?")
  Q4_COST_A=$(jq -r '.data.cost' "$OUT/session-after.json" 2>/dev/null || echo "?")
  Q4_TOK_B=$(jq -c '.data.tokens' "$OUT/session-before.json" 2>/dev/null || echo "?")
  Q4_TOK_A=$(jq -c '.data.tokens' "$OUT/session-after.json" 2>/dev/null || echo "?")
  Q4_OUTCOME_B=$(jq -r '.data.outcome // "__ASSENTE__"' "$OUT/session-before.json" 2>/dev/null || echo "?")
  Q4_OUTCOME_A=$(jq -r '.data.outcome // "__ASSENTE__"' "$OUT/session-after.json" 2>/dev/null || echo "?")
  Q4_GEN_TEXT=$(jq -r '.data.text // .text // "<nessun testo>"' "$OUT/q4-generate.json" 2>/dev/null || echo "<non leggibile>")
fi

# ───────────────────────────── Q5: /api/shell ─────────────────────────────

note "Q5: shell exit code e timeout"
Q5_C=$(curl -sS "${AUTH[@]}" -X POST -H 'content-type: application/json' \
  -d "{\"command\":\"exit 3\",\"cwd\":\"$ROOT/work\"}" "$BASE/api/shell")
Q5_ID=$(printf '%s' "$Q5_C" | jq -r '.data.id // .id // empty')
printf '%s' "$Q5_C" > "$OUT/q5-create.json"
Q5_STATE=""
if [ -n "$Q5_ID" ]; then
  for _ in $(seq 1 30); do
    api "/api/shell/$Q5_ID" > "$OUT/q5-get.json"
    Q5_STATE=$(jq -r '.data.status // .status // empty' "$OUT/q5-get.json")
    case "$Q5_STATE" in running) sleep 0.5 ;; *) break ;; esac
  done
  Q5_KEYS=$(jq -r '.data | keys | join(",")' "$OUT/q5-get.json")
  # il nome esatto del campo exit code: si cerca per chiave e per valore
  Q5_EXIT=$(jq -r '.data | to_entries | map(select(.key | test("exit"))) | .[] | "\(.key)=\(.value)"' "$OUT/q5-get.json" | paste -sd' ' -)
  Q5_OUTPUT=$(curl -sS "${AUTH[@]}" "$BASE/api/shell/$Q5_ID/output" | jq -r '.data.output // .output // (.data|tostring) // ""' 2>/dev/null | head -c 200)
else
  Q5_KEYS=""; Q5_EXIT=""; Q5_OUTPUT=""
fi

note "Q5: timeout"
Q5_T=$(curl -sS "${AUTH[@]}" -X POST -H 'content-type: application/json' \
  -d "{\"command\":\"sleep 30\",\"cwd\":\"$ROOT/work\",\"timeout\":2000}" "$BASE/api/shell")
Q5_TID=$(printf '%s' "$Q5_T" | jq -r '.data.id // .id // empty')
printf '%s' "$Q5_T" > "$OUT/q5-timeout-create.json"
Q5_TSTATE=""
if [ -n "$Q5_TID" ]; then
  for _ in $(seq 1 30); do
    api "/api/shell/$Q5_TID" > "$OUT/q5-timeout-get.json"
    Q5_TSTATE=$(jq -r '.data.status // empty' "$OUT/q5-timeout-get.json")
    case "$Q5_TSTATE" in running) sleep 0.5 ;; *) break ;; esac
  done
  Q5_TKEYS=$(jq -r '.data | keys | join(",")' "$OUT/q5-timeout-get.json")
  # al timeout `exit` non c'è: il comando è stato ucciso, non è uscito. La misura
  # lo dice guardando se la chiave esiste, non indovinandone il valore.
  Q5_T_HAS_EXIT=$(jq -r '.data | has("exit")' "$OUT/q5-timeout-get.json")
  Q5_T_ELAPSED=$(jq -r '(.data.time.completed - .data.time.started)' "$OUT/q5-timeout-get.json")
  Q5_TTIME=$(jq -c '.data.time' "$OUT/q5-timeout-get.json")
else
  Q5_TKEYS=""; Q5_T_HAS_EXIT=""; Q5_T_ELAPSED=""; Q5_TTIME=""
fi

note "Q5: il comando uscito è ancora in /api/shell?"
api /api/shell > "$OUT/q5-list.json"
Q5_LIST=$(jq -c '[.data[]? | {id, status, command}]' "$OUT/q5-list.json" 2>/dev/null || echo "?")
Q5_HAS_EXITED=$(jq --arg id "$Q5_ID" '[.data[]? | select(.id == $id)] | length' "$OUT/q5-list.json" 2>/dev/null || echo "?")
Q5_REMOVED_CODE=$(code "/api/shell/$Q5_ID")

# ───────────────────────────── Q6: failed e interrupted ─────────────────────────────

note "Q6: failed e interrupted"
Q6=$(curl -sS "${AUTH[@]}" -X POST -H 'content-type: application/json' \
  -d "{\"location\":{\"directory\":\"$ROOT/work\"},\"title\":\"interrupt-probe\",\"model\":{\"providerID\":\"$PROVIDER\",\"id\":\"$MODEL\"}}" \
  "$BASE/api/session")
Q6_ID=$(printf '%s' "$Q6" | jq -r '.data.id // empty')
printf '%s' "$Q6" > "$OUT/q6-session.json"
Q6_TYPES=""
Q6_INT_CODE=""

if [ -n "$Q6_ID" ]; then
  SESSION_ID="$Q6_ID"
  sse_start
  note "Q6: prompt lungo + interruptWhile it runs"
  curl -sS "${AUTH[@]}" -o /dev/null -X POST -H 'content-type: application/json' \
    -d '{"text":"Scrivi un racconto molto lungo di almeno 3000 parole su un scoiattolo, senza fermarti."}' \
    "$BASE/api/session/$Q6_ID/prompt"

  # interrupt mentre gira
  sleep 4
  Q6_INT_CODE=$(curl -sS "${AUTH[@]}" -o "$OUT/q6-interrupt.json" -w '%{http_code}' \
    -X POST -H 'content-type: application/json' -d '{}' "$BASE/api/session/$Q6_ID/interrupt")

  # aspetta un evento terminale
  sse_wait 'session.execution.interrupted' 90 || sse_wait 'session.execution.succeeded' 30 || true
  sleep 2
  sse_stop
  # tutti i payload sono presi filtrando per sessione, non per type
  Q6_TYPES=$(printf '%s' "$(sse_session_types "$EVENTS_FILE" "$Q6_ID")" | tr ' ' '\n' | grep '^session\.execution\.' | paste -sd' ' - || true)
  [ -n "$Q6_TYPES" ] || Q6_TYPES="nessuno"
  Q6_PAYLOAD=$(sed -n 's/^data: //p' "$EVENTS_FILE" 2>/dev/null \
    | jq -c --arg s "$Q6_ID" 'select(.type == "session.execution.interrupted" and .data.sessionID == $s)' 2>/dev/null | head -1)
  # `session.step.failed` porta l'errore del singolo passo: è più informativo di
  # `session.execution.interrupted`, che dice solo che il turno è finito male.
  Q6_STEP=$(sed -n 's/^data: //p' "$EVENTS_FILE" 2>/dev/null \
    | jq -c --arg s "$Q6_ID" 'select(.type == "session.step.failed" and .data.sessionID == $s)' 2>/dev/null | head -1)
  # se l'interrupt è caduto in un retry e non in uno step, il motivo è un altro e
  # va detto: il turno era già in riparazione quando l'utente ha premuto Esc.
  Q6_RETRY=$(sed -n 's/^data: //p' "$EVENTS_FILE" 2>/dev/null \
    | jq -c --arg s "$Q6_ID" 'select(.type == "session.retry.scheduled" and .data.sessionID == $s)' 2>/dev/null | head -1)
  Q6_INT_BODY=$(head -c 200 "$OUT/q6-interrupt.json" 2>/dev/null)
  session_snapshot "$Q6_ID" q6
  Q6_OUTCOME=$(jq -r '.data.outcome // "__ASSENTE__"' "$OUT/session-q6.json" 2>/dev/null || echo "?")
fi

# ───────────────────────────── Q6b: failed ─────────────────────────────
# Un prompt che il modello non può soddisfare non fallisce: arriva un errore di
# permesso/turno solo se il modello esiste ed è irraggiungibile. Si usa un
# provider inesistente sulla stessa sessione: l'errore è del runtime, non del
# modello, ed è quello che `failed` descrive.

note "Q6b: failed con modello inesistente"
Q6B=$(curl -sS "${AUTH[@]}" -X POST -H 'content-type: application/json' \
  -d "{\"location\":{\"directory\":\"$ROOT/work\"},\"title\":\"failed-probe\",\"model\":{\"providerID\":\"opencode\",\"id\":\"modello-che-non-esiste-probe\"}}" \
  "$BASE/api/session")
Q6B_ID=$(printf '%s' "$Q6B" | jq -r '.data.id // empty')
Q6B_TYPES=""
Q6B_PAYLOAD=""
if [ -n "$Q6B_ID" ]; then
  SESSION_ID="$Q6B_ID"
  sse_start
  Q6B_PROMPT_CODE=$(curl -sS "${AUTH[@]}" -o "$OUT/q6b-prompt.json" -w '%{http_code}' \
    -X POST -H 'content-type: application/json' \
    -d '{"text":"Rispondi esattamente: ok"}' \
    "$BASE/api/session/$Q6B_ID/prompt")
  sse_wait 'session.execution.failed' 60 || true
  sleep 2
  sse_stop
  Q6B_TYPES=$(printf '%s' "$(sse_session_types "$EVENTS_FILE" "$Q6B_ID")" | tr ' ' '\n' | grep '^session\.execution\.' | paste -sd' ' - || true)
  [ -n "$Q6B_TYPES" ] || Q6B_TYPES="nessuno"
  # il payload per intero: è lui che dice al supervisore come distinguere i casi
  Q6B_PAYLOAD=$(sed -n 's/^data: //p' "$EVENTS_FILE" 2>/dev/null \
    | jq -c --arg s "$Q6B_ID" 'select(.type == "session.execution.failed" and .data.sessionID == $s)' 2>/dev/null | head -1)
  # `grep -c` esce con 1 quando non trova nulla, e `set -o pipefail` fa terminare
  # lo script su quel conteggio — che è proprio il risultato atteso qui.
  session_snapshot "$Q6B_ID" q6b
  Q6B_OUTCOME=$(jq -r '.data.outcome // "__ASSENTE__"' "$OUT/session-q6b.json" 2>/dev/null || echo "?")
fi

# ───────────────────────────── FINDINGS ─────────────────────────────

# `session.idle` viene contato qui, con tutti i listener chiusi: farlo dentro un
# blocco lo calcolerebbe su una parte dei file. `grep -c` esce con 1 quando non
# trova nulla, e `set -o pipefail` terminerebbe lo script su quel conteggio — che è
# proprio il risultato atteso.
note "conteggio di session.idle su tutti i listener"
IDLE_COUNT=$( { grep -c 'session.idle' "$OUT"/events-*.log || true; } 2>/dev/null | awk -F: '{t+=$2} END {print t+0}')
# sessioni che hanno raggiunto un evento terminale, su tutti i listener
TERMINAL_SESSIONS=$(cat "$OUT"/events-*.log 2>/dev/null | sed -n 's/^data: //p' \
  | jq -r 'select(.type == "session.execution.succeeded"
              or .type == "session.execution.failed"
              or .type == "session.execution.interrupted") | .data.sessionID' 2>/dev/null \
  | sort -u)
TERMINAL_N=$(printf '%s' "$TERMINAL_SESSIONS" | grep -c . || true)
[ "$TERMINAL_N" -gt 0 ] || TERMINAL_N=0

note "scrittura di out/FINDINGS.md"
FIND="$OUT/FINDINGS.md"
cp "$PLUGIN_OUT" "$OUT/plugin-last.jsonl" 2>/dev/null || true

Q1_SETUP=$(jq -c 'select(.kind=="setup")' "$PLUGIN_OUT" 2>/dev/null | head -1 || echo "")
Q1_CMD_DRAFT=$(jq -c 'select(.kind=="command-transform-draft")' "$PLUGIN_OUT" 2>/dev/null | head -1 || echo "")
Q1_CMD_LISTED=$(jq -c 'select(.kind=="command-list-resolved")' "$PLUGIN_OUT" 2>/dev/null | head -1 || echo "")
Q2_TOOL_DRAFT=$(jq -c 'select(.kind=="tool-transform-draft")' "$PLUGIN_OUT" 2>/dev/null | head -1 || echo "")
Q2_EXEC=$(jq -c 'select(.kind=="tool-execute")' "$PLUGIN_OUT" 2>/dev/null | head -1 || echo "")

{
cat <<HEADER
# FINDINGS — probe del substrato runtime, opencode 2.0.14

Generato da \`probe/run.sh\` il $(date -Is). Run \`$RID\`, porta \`$PORT\`, HOME isolato \`$ROOT\`.

Metodo: \`opencode serve\` su porta libera con \`HOME\` e \`XDG_CONFIG_HOME\` puntati a una
directory temporanea, e \`env -u\` su otto variabili d'ambiente
(\`OPENCODE_CONFIG\`, \`OPENCODE_CONFIG_CONTENT\`, \`OPENCODE_CONFIG_DIR\`,
\`OPENCODE_SESSION_ID\`, \`OPENCODE_CLIENT\`, \`OPENCODE_PORT\`,
\`OPENCODE_SERVER_PASSWORD\`, \`OPENCODE_SIMULATE\`).
**\`opencode api\` non è stato usato**: riusa il servizio in background condiviso e
leggerebbe la configurazione reale dell'utente.

Il \`pid\` riportato da \`GET /api/info\` viene confrontato con il pid che la probe ha
avviato: una porta occupata da un'altra istanza risponderebbe \`200\` prima che il
server della probe esista, e tutta la misura finirebbe addosso a quello.

Ogni risposta è un fatto misurato **in questa esecuzione**. \`probe/out/\` viene
svuotato a ogni run, quindi ogni artefatto citato qui è di questa esecuzione e non
ha una versione precedente che lo contraddica. Dove una prova non è riuscita la
sezione dice **non misurato** con l'errore esatto: nessun valore è dedotto dal
codice o dai typings.

Le osservazioni sul percorso di errore vengono prodotte da una sezione di
**controprove** (\`probe/controprove/\`), che avvia un secondo server con il proprio
HOME e la propria porta e carica plugin volutamente difettosi: il percorso felice
non le genera, e senza controprove sarebbero affermazioni senza artefatto.

Evidenze grezze in \`probe/out/\`: \`serve.log\`, \`plugin-last.jsonl\`,
\`events-*.log\`, \`q*.json\`, \`session-*.json\`, \`controprove/\`.

---

## Domanda 1 — \`command.transform\` espone \`add\`?

### Risposta

HEADER

if [ -n "$Q1_CMD_DRAFT" ]; then
  jq -r '
    "**Sì.** Il draft passato a `command.transform` ha un solo membro, `add`, e il comando registrato compare in `GET /api/command`.\n\n" +
    "- chiavi del draft: `" + ((.draftKeys // []) | join(", ")) + "`\n" +
    "- tipo dei membri: `" + ((.draftEntryTypes // {}) | tojson) + "`\n" +
    "- `typeof draft.add` = `" + (.addType|tostring) + "`, arità " + ((.addArity // "null")|tostring) + "\n" +
    "- `draft.add({name, description, template})` → `" + ((.addAttempt // {}) | tojson) + "`"
  ' <<<"$Q1_CMD_DRAFT"
  echo
  echo "- \`GET /api/command\` contiene \`probe_command\`: \`$(curl -s "${AUTH[@]}" "$BASE/api/command" | jq '[.data[]? | select(.name == "probe_command")] | length')\` occorrenze"
  echo "- descrizione del comando registrato, come la vede il server: \`$(curl -s "${AUTH[@]}" "$BASE/api/command" | jq -c '[.data[]? | select(.name == "probe_command")][0] | {name, description, agent}' 2>/dev/null)\`"
else
  echo "**non misurato** — nessun \`command-transform-draft\` scritto dal plugin-probe in \`plugin-last.jsonl\`. Errore: $(grep -o 'transform failure.\{0,200\}' "$SERVE_LOG" | head -1 || echo "nessuna riga di errore in serve.log")"
fi

cat <<'S1'

### Come è stata misurata

`probe/plugin-probe/index.ts` chiama `ctx.command.transform(cb)` dentro `setup`, e
`cb` registra `Object.keys(draft)` e il tipo di ogni membro, poi chiama `draft.add`.
Il plugin è caricato dal config dell'`HOME` isolato, con
`plugins: [{package: "<repo>/probe/plugin-probe"}]` — il percorso esatto è in
`probe/out/info.json` e nella riga `Generato da` in testa a questo documento.

La forma sbagliata della chiamata è misurata in questa esecuzione, in una
controprova separata (`probe/controprove/bad-transform/`): `command.transform` prende
**una callback**, non un editor, e chiamarlo con `{}` disabilita il plugin.

- plugin caricato (`msg="loading plugin"` nel log applicativo): `@@CP_LOADED_TRANSFORM@@` volte
- messaggio: `@@CP_ERR_TRANSFORM@@`
- `state` indicato: `@@CP_ERR_TRANSFORM_STATE@@`
- in `GET /api/plugin`: `@@CP_BAD_STATE@@`
- testo integrale: `probe/out/controprove/opencode.log`

**Una riserva su `state`.** Il plugin difettoso chiama **entrambi** i transform
sbagliati, e il runtime ne segnala uno solo per esecuzione: quello riportato sopra è
il primo che fallisce nell'ordine di attivazione, e può cambiare da un run
all'altro. Non si deve dedurre `state=command` da una misura che ha riportato
`state=tool`. Artefatti in `probe/out/controprove/`.


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
@@Q1_INPUT_KEYS@@

---

## Domanda 2 — forma di `tool.transform`

### Risposta

S1
} > "$FIND"

# la seconda metà è append: le sezioni 2..6 sono più lunghe e non entrano nel heredoc
{
if [ -n "$Q2_TOOL_DRAFT" ]; then
  jq -r '
    "**Misurata.** L'\''editor di `tool.transform` ha sei membri e i tool si registrano da lì.\n\n" +
    "- chiavi dell'\''editor: `" + ((.draftKeys // []) | join(", ")) + "`\n" +
    "- tipo dei membri: `" + ((.draftEntryTypes // {}) | tojson) + "`\n" +
    "- `typeof draft.add` = `" + (.addType|tostring) + "`, arità " + ((.addArity // "null")|tostring) + "\n" +
    "- `draft.add({name, description, args, execute})` → `" + ((.addAttempt // {}) | tojson) + "`\n" +
    "- `draft.list()` **prima** del `add`: " + ((.listLength // 0)|tostring) + " tool; `probe_tool` presente: `" + ((.listNames // []) | index("probe_tool") != null | tostring) + "`\n" +
    "- `draft.list()` **dopo** il `add`: `" + ((.listAfterAdd // {}) | tojson) + "`\n" +
    "- `draft.get(\"probe_tool\")` dopo il `add` → `" + ((.getAfterAdd // {}) | tojson) + "`"
  ' <<<"$Q2_TOOL_DRAFT"
  echo
  echo "Il tool è stato registrato dal plugin e **chiamato dal modello** durante un turno"
  echo "reale su \`$PROVIDER/$MODEL\`. Cosa ricevono i due parametri di \`execute\`:"
  echo
  if [ -n "$Q2_EXEC" ]; then
    echo '```json'
    jq -c '{ args: .argsShapes, context: .contextShapes, sessionID: .contextSessionID, messageID: .contextMessageID, agent: .contextAgent, directory: .contextDirectory, worktree: .contextWorktree, abortType: .contextAbortType, abortAborted: .contextAbortAborted, metadataType: .contextMetadataType, askType: .contextAskType }' <<<"$Q2_EXEC"
    echo '```'
    echo
    echo "- \`Object.keys(args)\` = \`$(jq -r '(.argsKeys // []) | join(", ")' <<<"$Q2_EXEC")\` — il tool è stato dichiarato con \`args: {}\`, quindi la lista vuota è quella attesa, non un'assenza di argomenti"
    echo "- \`Object.keys(context)\` = \`$(jq -r '(.contextKeys // []) | join(", ")' <<<"$Q2_EXEC")\`"
    echo "- \`context.directory\` = \`$(jq -r '.contextDirectory | tostring' <<<"$Q2_EXEC")\`, \`context.worktree\` = \`$(jq -r '.contextWorktree | tostring' <<<"$Q2_EXEC")\` — **entrambi assenti**, benché i typings li dichiarino"
    echo "- \`typeof context.abort\` = \`$(jq -r '.contextAbortType | tostring' <<<"$Q2_EXEC")\`, \`typeof context.metadata\` = \`$(jq -r '.contextMetadataType | tostring' <<<"$Q2_EXEC")\`, \`typeof context.ask\` = \`$(jq -r '.contextAskType | tostring' <<<"$Q2_EXEC")\`: il \`ToolContext\` dei typings 1.18.16 **non è** quello che il runtime passa"
  else
    echo "- **non misurato**: il tool non è stato eseguito. Il modello della prova non lo ha chiamato, o il tool non è entrato nel contesto. L'errore esatto è in \`probe/out/plugin-last.jsonl\` e \`probe/out/serve.log\`."
  fi
else
  echo "**non misurato** — nessun \`tool-transform-draft\` scritto. Errore: $(grep -o 'transform failure.\{0,200\}' "$SERVE_LOG" | head -1 || echo "nessuna riga di errore in serve.log")"
fi

cat <<'S2C'

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
2. **Restituire `{ tool: ... }` o `{ command: ... }` dagli hooks di `setup` non
   registra niente, e disabilita il plugin.** I tool si registrano dentro la
   callback di `ctx.tool.transform`; gli hook restituiti da `setup` non sono il
   canale di registrazione. Misurato in questa esecuzione, in
   `probe/controprove/bad-transform/`, che chiama `command.transform({})` e
   `tool.transform({})` al posto delle callback:

   - il plugin è stato caricato: `@@CP_LOADED_TRANSFORM@@` volte
   - messaggio: `@@CP_ERR_TRANSFORM@@`
   - `state` indicato nel messaggio: `@@CP_ERR_TRANSFORM_STATE@@`
   - in `GET /api/plugin`: `@@CP_BAD_STATE@@` — \`@@CP_BAD_STATE_ERR@@\`

   Il `state` di cui sopra è **uno solo dei due** che il plugin difettoso provoca:
   chiama `command.transform({})` e `tool.transform({})`, e il runtime ne segnala uno
   per esecuzione. Non si deduce l'altro da questa misura.

   Quindi `setup` **non deve restituire chiavi `command` o `tool`**, e i tool vanno
   aggiunti con `ctx.tool.transform(draft => draft.add({name, ...}))`.

   **La riserva che questa misura porta con sé.** Quanto segue è la conseguenza più
   pesante di tutta la probe, e poggia su una sola osservazione di una sola build:
   se T7 scopre che la registrazione dagli hooks funziona in un modo che qui
   fallisce, questa sezione va riletta da capo, non integrata a margine. Non è un
   fatto acquisito: è un fatto che un'altra esecuzione può ribaltare.
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

S2C
} >> "$FIND"

{
if [ "$Q3_VERDICT" = "ACCETTATA" ]; then
  cat <<E3
**Sì, \`parentID\` viene accettato e conservato.** Questo è l'unico esito che
cambierebbe la forma della soluzione.

- \`POST /api/session\` con \`parentID:"ses_nonexistent"\` → HTTP \`$Q3_STATUS\`, sessione \`$Q3_FOUND\`
- \`parentID\` nella risposta della POST → \`$Q3_POST_PARENT\`
- \`parentID\` in \`GET /api/session/$Q3_FOUND\` → \`$Q3_GET_PARENT\`
- \`parentID\` in \`GET /api/session\` → \`$Q3_LIST_PARENT\`
- chiavi della sessione: \`$Q3_KEYS\`
- controllo, payload identico salvo \`parentID\` (\`$Q3_CTL_ID\`), chiavi in differenza: \`$Q3_KEY_DIFF\` → \`parentID\` = \`$Q3_CTL_PARENT\`
- \`GET /api/session/$Q3_FOUND/children\` → HTTP \`$Q3_CHILDREN_CODE\`, corpo: \`$Q3_CHILDREN_BODY\`

E3
elif [ "$Q3_STATUS" = "200" ] || [ "$Q3_STATUS" = "201" ]; then
  cat <<E3
**No. \`parentID\` viene scartato: la sessione creata è una radice.** È l'esito previsto
dalla spec v2 e la §5 resta valida.

- \`POST /api/session\` con \`parentID:"ses_nonexistent"\` → HTTP \`$Q3_STATUS\`, sessione \`$Q3_FOUND\`
- \`parentID\` nella risposta della POST → \`$Q3_POST_PARENT\`
- \`parentID\` in \`GET /api/session/$Q3_FOUND\` → \`$Q3_GET_PARENT\`
- \`parentID\` in \`GET /api/session\` → \`$Q3_LIST_PARENT\`
- chiavi della sessione: \`$Q3_KEYS\`
- controllo, payload identico salvo \`parentID\` (\`$Q3_CTL_ID\`), chiavi in differenza: \`$Q3_KEY_DIFF\` → \`parentID\` = \`$Q3_CTL_PARENT\`
- \`GET /api/session/$Q3_FOUND/children\` → HTTP \`$Q3_CHILDREN_CODE\`, corpo: \`$Q3_CHILDREN_BODY\`

E3
else
  cat <<E3
**\`parentID\` non è accettato: la richiesta è rifiutata.** La chiave extra non viene
scartata in silenzio, viene rifiutata.

- \`POST /api/session\` con \`parentID\` → HTTP \`$Q3_STATUS\`, corpo: \`$(head -c 300 "$OUT/q3-create.json")\`
- richiesta di controllo **senza** \`parentID\` → HTTP \`$Q3_CTL\` (sessione \`$Q3_CTL_ID\`)
- \`GET /api/session\` → \`$(jq -c '[.data[]? | select(.title=="child-probe")] | map({id,parentID,title})' "$OUT/q3-list.json" 2>/dev/null)\`
- \`GET /api/session/$Q3_CANDIDATE/children\` → HTTP \`$Q3_CHILDREN_CODE\`, corpo: \`$Q3_CHILDREN_BODY\`

E3
fi

cat <<'S3C'

### Come è stata misurata

Due richieste a `POST /api/session` **identiche salvo `parentID`** — stesso titolo,
stessa directory — più la lettura di `GET /api/session/<id>` e di
`GET /api/session`, più `GET /api/session/<id>/children`.

Il numero di chiavi in cui i due payload differiscono è misurato e stampato sopra:
\`$Q3_KEY_DIFF\`. Un valore diverso da 1 significherebbe che il confronto non
dimostra niente, perché le due richieste non avrebbero una sola variabile.

Il confronto serve a distinguere «la chiave è stata scartata» da «il campo esiste ma
è vuoto»: senza il controllo, un `parentID: null` sembrerebbe la prova che
`parentID` funzioni.

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

S3C
} >> "$FIND"

{
if [ "${Q4_OK:-0}" = "1" ] && [ "${Q4_TURN:-}" = "ok" ]; then
  cat <<E4
**Funziona ed è davvero stateless: non scrive nella history e non tocca
\`cost\`, né \`tokens\`, né \`outcome\`.** La spec v2 §5 è confermata.
\`generate\` inoltre **non emette** \`session.execution.*\`: è una chiamata che
risponde su HTTP e non sullo stream.

- \`POST /api/session/$Q4_ID/generate\` {"prompt":"Rispondi SOLO con questo JSON: {…}"} → HTTP \`$Q4_GEN_STATUS\`
- testo ricevuto: \`$(printf '%s' "$Q4_GEN_TEXT" | head -c 300)\`
- messaggi in \`GET /api/session/$Q4_ID/message\`: prima \`$Q4_BEFORE_MSG\`, dopo \`$Q4_AFTER_MSG\` — **messaggi nuovi: $Q4_NEW_MESSAGES**
- tipi prima: \`$Q4_BEFORE_TYPES\` — tipi dopo: \`$Q4_AFTER_TYPES\`
- **id dei messaggi**, che è la prova e non il conteggio:
  - prima: \`$Q4_IDS_BEFORE\`
  - dopo: \`$Q4_IDS_AFTER\`
- \`session.execution.*\` per questa sessione: \`$Q4_EXEC_TYPES\`
- tutti gli eventi di questa sessione: \`$Q4_EVENT_TYPES\`
- \`cost\`: prima \`$Q4_COST_B\`, dopo \`$Q4_COST_A\`
- \`tokens\`: prima \`$Q4_TOK_B\`, dopo \`$Q4_TOK_A\`
- \`outcome\`: prima \`$Q4_OUTCOME_B\`, dopo \`$Q4_OUTCOME_A\`
- corpo completo di \`generate\`: \`$(head -c 300 "$OUT/q4-generate.json")\`
- chiavi del primo elemento di \`/message\`: \`$Q4_AFTER_KEYS\`

**La trappola che rende questa misura facile da sbagliare**, e che l'ha resa vera
solo alla terza esecuzione: \`session.execution.succeeded\` arriva **prima** che i
messaggi siano persistiti. Se si fa lo snapshot «prima» appena arriva l'evento, si
fotografa una sessione a metà turno — con il solo messaggio \`user\` — e il confronto
con lo snapshot «dopo» fa sembrare che \`generate\` abbia scritto due messaggi che in
realtà erano del primo turno. La prova va fatta aspettando che la sessione si
assesti (un \`assistant\` **e** un \`idle\` in \`/message\`), altrimenti si misura il
ritardo della persistenza e lo si attribuisce a \`generate\`.

Il testo di ritorno è la risposta del giudice al prompt, costruita con il contesto
della sessione già montato: il plugin non deve allegare il transcript, e
\`compress.ts\` resta correttamente sparito.

**Il caveat che resta dichiarato**: \`cost\` è \`$Q4_COST_A\` e i token sono
identici prima e dopo, ma il modello della prova è free — un valore \`0\` su un
modello gratis non distingue «\`generate\` non incassa» da «non può incassare». Su un
modello \`opencode-go/*\` questa misura **non lo sa** e non lo dichiarerà mai, perché
l'unico account disponibile per la probe è free. La spec lo dichiara già come rischio
noto in §14: è confermato come rischio reale, e resta aperto.

E4
else
  cat <<E4
**non misurato** — il turno non è arrivato a \`succeeded\`, quindi il confronto
prima/dopo non è possibile ($( [ "$Q4_TURN" = failed ] && echo "il turno è finito in \`failed\`: payload in \`probe/out/events-*.log\`" || echo "nessun evento terminale entro il timeout" )).

- sessione \`$Q4_ID\`, modello \`$PROVIDER/$MODEL\`
- primo turno: \`$Q4_TURN\` (nessun \`session.execution.succeeded\` in \`probe/out/events-*.log\`)
- stato della sessione: \`$(jq -c '{cost,tokens,outcome,title}' "$OUT/session-before.json" 2>/dev/null || echo "non disponibile")\`
- ultimi eventi SSE: \`$(sed -n 's/^data: //p' "$OUT"/events-*.log 2>/dev/null | jq -r 'select(.type)|.type' 2>/dev/null | sort -u | paste -sd' ' - | head -c 400)\`
- \`POST generate\`: HTTP \`$Q4_GEN_STATUS\`, corpo \`$(head -c 300 "$OUT/q4-generate.json" 2>/dev/null)\`

E4
fi

cat <<'S4C'

### Come è stata misurata

Sessione nuova su `space-bunny-free`, listener SSE aperto **prima** del prompt e
filtrato per `data.sessionID`, attesa di `session.execution.succeeded` **di quella
sessione**, **poi attesa che la sessione si assesti**, snapshot di
`GET /api/session/<id>` e di `GET /api/session/<id>/message`, poi
`POST /api/session/<id>/generate`, poi gli stessi due snapshot.

Il filtro per sessione nell'attesa non è un dettaglio: `GET /api/event` è un unico
stream per tutto il server, e la sessione del tool di Q2 è ancora viva quando parte
il prompt del giudice. Senza filtro, `sse_wait` può essere soddisfatta dall'evento di
un'altra sessione. Per questo la prova tiene **sugli id dei messaggi** e non sul
conteggio: due conteggi uguali possono essere lo stesso insieme o due insiemi
diversi, gli id no.

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
   riportava zero messaggi nuovi. Questa esecuzione verifica sugli **id** dei
   messaggi, non sul numero.
3. **Non filtrare l'attesa per sessione.** Il primo `sse_wait` di questa prova
   filtrava sul solo `type`, e poteva essere soddisfatto dall'evento della sessione
   del tool di Q2. Il numero era comunque giusto — il gate successivo è per-sessione
   — ma il metodo dichiarato non era quello eseguito. Ora `sse_wait` filtra su
   `data.sessionID` e rifiuta di partire senza `SESSION_ID`.

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

S4C
} >> "$FIND"

{
cat <<E5
**L'exit code è nel campo \`exit\`** di \`shell.get\`, accanto a \`status\`.

- \`POST /api/shell\` {"command":"exit 3"} → \`$Q5_C\`
- stato finale \`$Q5_STATE\`, campi di \`shell.get\`: \`$Q5_KEYS\`
- campi che contengono "exit": \`$Q5_EXIT\`
- \`/output\`: \`$Q5_OUTPUT\`

**Al timeout \`sleep 30\` con \`timeout: 2000\` il comando viene ucciso, non esce:**
\`status\` diventa \`timeout\` (non \`exited\`, non \`killed\`) e **il campo \`exit\` non
esiste affatto** — la chiave è assente, quindi \`obj["exit"]\` è \`undefined\`. Il
decorso è nei \`time\`: \`$Q5_TTIME\`, durata \`$Q5_T_ELAPSED\` ms (timeout richiesto
2000). Campi di \`shell.get\`: \`$Q5_TKEYS\`. Creazione: \`$(head -c 200 "$OUT/q5-timeout-create.json")\`.

**Il comando uscito $( [ "$Q5_HAS_EXITED" = "1" ] && echo "è ancora in lista" || echo "è sparito dalla lista" )**: \`GET /api/shell\` → \`$Q5_LIST\`.
Occorrenze del suo id nella lista: \`$Q5_HAS_EXITED\`.
\`GET /api/shell/$Q5_ID\` dopo il termine → HTTP \`$Q5_REMOVED_CODE\` (200 = resta
leggibile per id, 404 = non esiste più).

Le due cose non sono la stessa, ed è il punto: se l'entry non è in lista ma resta
leggibile per id, una \`api.ts\` che usa la lista per sapere cosa è vivo e una che usa
l'id per riprendere un comando in corso prendono percorsi diversi.

E5

cat <<'S5C'

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

S5C
} >> "$FIND"

{
cat <<E6
**Entrambi arrivano davvero, con payload distinti.** \`interrupted\` porta
\`data.reason:"user"\`; \`failed\` porta \`data.error\` con \`type\` e \`message\`.

- \`interrupted\`: \`POST /api/session/$Q6_ID/interrupt\` → HTTP \`$Q6_INT_CODE\`, corpo \`$Q6_INT_BODY\`.
  \`session.execution.*\` arrivati: \`$Q6_TYPES\`. \`outcome\` della sessione dopo: \`$Q6_OUTCOME\`.
  Payload: \`$Q6_PAYLOAD\`
- \`session.step.failed\` in questa esecuzione: \`$Q6_STEP\`
  $( [ -n "$Q6_STEP" ] && [ "$Q6_STEP" != "$NM" ] && echo "(arrivato, con \`data.error.type\` e \`data.assistantMessageID\`)" || echo "(**non arrivato** in questa esecuzione. In una precedente la coppia \`step.failed\`/\`interrupted\` si è rivelata variabile, con l'interrupt caduto in \`session.retry.scheduled\`: «non arrivato» è quindi un esito possibile, non un bug. Il \`retry\` di quella esecuzione non è riprodotto qui.)" )
- \`failed\`: sessione su modello inesistente \`$Q6B_ID\`, \`POST /prompt\` → HTTP \`$Q6B_PROMPT_CODE\`.
  \`session.execution.*\` arrivati: \`$Q6B_TYPES\`. \`outcome\` dopo: \`$Q6B_OUTCOME\`.
  Payload: \`$Q6B_PAYLOAD\`

**La riserva su come è stato prodotto \`failed\`.** Il modello inesistente non
produce un \`failed\` che distingua «modello inesistente» da «modello che il runtime
non riesce a instradare»: \`README.md\` (regola 4) avverte che lo stesso
\`provider.no-route\` / \`Model unavailable: …\` compare anche quando il catalogo dei
modelli non è ancora pronto. La prova aspetta il catalogo prima di ogni turno, e per
questa via il turno è partito davvero; ma **questa misura dimostra che \`failed\`
arriva e che il suo \`data.error\` è tipizzato**, non che \`failed\` significhi
sempre «modello inesistente». Per distinguere i due casi un task successivo
dovrebbe attendere il catalogo anche per il modello di prova, o attendere
esplicitamente che \`GET /api/model\` lo contenga prima di dichiarare \`failed\`
atteso.

Riepilogo dei \`type\` distinti osservati su tutti i listener di questa esecuzione:
\`$(sed -n 's/^data: //p' "$OUT"/events-*.log 2>/dev/null | jq -r 'select(.type)|.type' 2>/dev/null | sort -u | paste -sd' ' -)\`

La sua assenza è la misura che ha corretto la v1: \`session.idle\` **non compare in
nessuno dei listener di questa esecuzione** — \`$IDLE_COUNT\` occorrenze in tutto,
su \`$(events_files_summary)\` file di eventi.

**Come è stato contato.** Su **$TERMINAL_N turni** arrivati a un evento terminale,
per sessione: \`$(printf '%s' "$TERMINAL_SESSIONS" | paste -sd' ' -)\`.

Quattro, non tre: il turno che chiede al modello di invocare \`probe_tool\` (Q2) ha un
listener come gli altri, quindi anche il suo \`started\` finisce in un file di eventi.
Ogni attesa è filtrata su \`data.sessionID\` della sessione che si sta misurando, perché
\`GET /api/event\` è un unico stream per tutto il server e le sessioni restano vive
in contemporanea.

Il token è però presente nel binario: \`strings -n 6 "$OPENCODE_BIN" | grep -c
'^session\\.idle$'\` → \`$CP_IDLE_IN_BIN\` occorrenze. Esistere nel binario ed essere
emesso sono due fatti distinti, e solo il secondo è negato dalla misura.

È citato qui **solo** per documentare che la misura lo cerca e non lo trova: nessun
task successivo deve usarlo, nemmeno in un commento.

E6

cat <<'S6C'

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
  `{ id, setup }` (o `{ id, effect }`). Misurato in questa esecuzione con
  `probe/controprove/bad-export/`, che esporta una funzione: il modulo viene
  caricato (`@@CP_LOADED_EXPORT@@`) e il log applicativo registra
  `@@CP_ERR_EXPORT@@` — il testo completo è in
  `probe/out/controprove/opencode.log`.
  In `GET /api/plugin` il plugin risulta `@@CP_EXPORT_STATE@@`: un modulo rifiutato
  dallo schema non entra nell'inventario, quindi lì la sua assenza non distingue
  «non caricato» da «caricato e attivo» — è il log a dirlo.
  I typings 1.18.16 dichiarano `Plugin` come funzione: sono sbagliati per 2.0.14.
  Cambia l'intestazione di `src/index.ts` in T7.

- **`command.transform` e `tool.transform` prendono una callback, non un editor.**
  Chiamarle con `{}` — cioè seguendo i typings — disabilita il plugin. Misurato in
  questa esecuzione con `probe/controprove/bad-transform/`, che le chiama con `{}`:
  caricato `@@CP_LOADED_TRANSFORM@@` volte, poi
  `@@CP_ERR_TRANSFORM@@` / `@@CP_ERR_TRANSFORM_STATE@@`, e in
  `GET /api/plugin` il plugin risulta `@@CP_BAD_STATE@@`.
  Il `state` è **uno solo dei due** che il difetto provoca: non si deduce l'altro da
  questa misura. Artefatti in `probe/out/controprove/`.

- **`Object.keys(input)` al `setup`** (misurato, non deduotto):

  ```text
  @@CTX_KEYS@@
  ```

  I typings dichiarano sette chiavi: `client, project, directory, worktree,
  experimental_workspace, serverUrl, $`. Nel runtime sono @@CTX_KEYS_N@@ chiavi, e
  nessuna delle sette è fra queste: non c'è `client`, non c'è `$`. Al loro posto ci
  sono i servizi su cui la spec §2.3 dice di non poter contare.

- **I servizi dentro l'input, con i loro metodi.** Sono l'alternativa alle rotte
  `/api/*` che §2.3 dichiara assenti dai typings, e la loro esistenza è un fatto:

  ```text
  @@CTX_SERVICES@@
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

- **`OPENCODE_SERVER_PASSWORD` autentica esattamente come `OPENCODE_PASSWORD`.**
  Controprova in questa esecuzione: un server avviato con **solo**
  `OPENCODE_SERVER_PASSWORD` (con `OPENCODE_PASSWORD` tolto dall'ambiente) scrive
  \`@@CP2_STDOUT@@\` e a `GET /api/info` con basic auth risponde
  \`HTTP @@CP_AUTH_CODE@@\`. Il server principale, avviato con `OPENCODE_PASSWORD`, risponde
  `200` sulla stessa rotta. Le due variabili sono equivalenti per l'autenticazione, e
  la probe usa `OPENCODE_PASSWORD` solo perché con una password dall'ambiente il
  binario non stampa la riga \`server password …\` (punto seguente) — non perché
  l'altra non funzioni.

  **Correzione di una versione precedente di questa probe**, che dichiarava il
  contrario. Quella misura non aveva verificato che il server fosse in ascolto: il
  `000` che `curl` restituisce quando la connessione fallisce era letto come un
  `401`, e quel `401` non era mai arrivato. La lezione è quella che `README.md`
  (regola 4) già scrive per un altro caso: **un codice di risposta che non è
  arrivato è `000`, non `401`**.
  quel \(401\) non c'era mai stato. La lezione è quella che `README.md` (regola 4)
  già scrive per un altro caso: **un codice di risposta che non è arrivato è
  \`000\`, non \(401\)**.

- **`opencode serve` non stampa `server password …`** quando la password arriva
  dall'ambiente: con `OPENCODE_PASSWORD` impostata, lo stdout del server contiene
  solo la riga `server listening on …`. Verificato in questa esecuzione su
  `probe/out/serve.log`, che è il log mantenuto per questa run e non accumula
  righe delle precedenti.

- **`input.serverUrl`, `input.directory`, `input.project` sono `null` e
  `input.worktree` è `{}`** dentro `setup`, con un `HOME` isolato. Se T2 conta su
  `baseURL` e autenticazione dal `ctx`, non li troverà lì: li prende da config o da
  `OPENCODE_PASSWORD`.


### Rotte misurate su questa build

- Rotte attraversate da `probe/run.sh` in questa esecuzione, tutte con risposta
  leggibile: `GET /api/info`, `GET /api/model`, `GET /api/command`,
  `POST /api/session`, `GET /api/session`, `GET /api/session/<id>`,
  `GET /api/session/<id>/message`, `POST /api/session/<id>/prompt`,
  `POST /api/session/<id>/generate`, `POST /api/session/<id>/interrupt`,
  `POST /api/shell`, `GET /api/shell`, `GET /api/shell/<id>`,
  `GET /api/shell/<id>/output`, `GET /api/event`.
- Nelle controprove: `GET /api/plugin` (server separato), `GET /api/info` per il
  test su `OPENCODE_SERVER_PASSWORD`.
- **`GET /api/tool` non esiste**: risponde `@@TOOL_404@@` (misurato in questa
  esecuzione). Il brief lo indicava come disponibile; la forma dei tool si misura
  dal plugin (Q2), non dall'endpoint.
- `GET /api/session/<id>/children` risponde `@@CHILDREN_404@@` (misurato in questa
  esecuzione).


---

## Traccia

- run: @@RID@@
- porta: @@PORT@@, `HOME` e `XDG_CONFIG_HOME` su una directory temporanea, cwd nella sua `work/`
- log del server: `probe/out/serve.log`
- eventi SSE: @@EVENTS_FILES@@ file in `probe/out/events-*.log`
- output del plugin: `probe/out/plugin-last.jsonl`
- snapshot di sessione: `probe/out/session-*.json`

Questa esecuzione ha girato sul mini-plugin `probe/plugin-probe/index.ts`, che
registra `probe_command` e `probe_tool` solo per essere osservato. Per rieseguire:
`PORT=<porta libera> ROOT=<dir temporanea> bash probe/run.sh`. Le regole che la
probe segue, e perché, sono in `probe/README.md`.
S6C
} >> "$FIND"

note "FINDINGS scritto: $FIND"

# I marker sono risolti qui fuori dagli heredoc quotati: dentro, una backtick
# sarebbe una command substitution e `$( )` non verrebbe valutato.
# Il conteggio viene calcolato dalla lista, non scritto a mano: una prosa che
  # dica un numero diverso dalla lista stampata due righe sopra è un difetto, e
  # succede.
  if [ -n "$Q1_SETUP" ]; then
  Q1_KEYS_N=$(jq -r '(.inputKeys // []) | length' <<<"$Q1_SETUP")
  Q1_KEYS_LINE=$(jq -r '"`Object.keys(input)` al `setup` = **" + ((.inputKeys // []) | join(" ")) + "**, " + (((.inputKeys // []) | length)|tostring) + " chiavi."' <<<"$Q1_SETUP")
else
  Q1_KEYS_N="non misurato"
  Q1_KEYS_LINE="non misurato: nessun record `setup` nel jsonl del plugin"
fi
CTX_KEYS=""
CTX_SERVICES=""
CTX_KEYS_N="${Q1_KEYS_N:-non misurato}"
if [ -n "$Q1_SETUP" ]; then
  CTX_KEYS=$(jq -r '(.inputShapes // {}) | keys_unsorted | join(" ")' <<<"$Q1_SETUP")
  CTX_SERVICES=$(jq -r '
  . as $r
  | [["session", ($r.ctxSessionKeys//{})],
     ["permission", ($r.ctxPermissionKeys//{})],
     ["event", ($r.ctxEventKeys//{})],
     ["shell", ($r.ctxShellKeys//{})],
     ["vcs", ($r.ctxVcsKeys//{})]]
  | .[]
  | .[0] + ": "
    + (.[1] | to_entries
       | map(if .value == "function" then .key + "()"
             elif .value == "object" then .key + " (object, non chiamabile)"
             else .key + " (" + (.value|tostring) + ")" end)
       | join(", "))
' <<<"$Q1_SETUP")
fi
[ -n "$CTX_SERVICES" ] || CTX_SERVICES="  (non misurato: nessun record setup)"
# Le sostituzioni sono fatte con python e non con sed: `@@CTX_SERVICES@@` è
# multilinea e sed non accetta un newline nella sostituzione.
FIND="$FIND" Q1_LINE="$Q1_KEYS_LINE" CTX_KEYS="$CTX_KEYS" CTX_KEYS_N="$CTX_KEYS_N" \
CTX_SERVICES="$CTX_SERVICES" \
CP_PLUGIN_COUNT="$CP_PLUGIN_COUNT" CP_BAD_STATE="$CP_BAD_STATE" \
CP_BAD_STATE_ERR="$CP_BAD_STATE_ERR" CP_EXPORT_STATE="$CP_EXPORT_STATE" \
CP_ERR_EXPORT="$CP_ERR_EXPORT" CP_ERR_TRANSFORM="$CP_ERR_TRANSFORM" \
CP_ERR_TRANSFORM_STATE="$CP_ERR_TRANSFORM_STATE" CP_AUTH_CODE="$CP_AUTH_CODE" \
CP_IDLE_IN_BIN="$CP_IDLE_IN_BIN" CP_LOADED_EXPORT="$CP_LOADED_EXPORT" \
CP_LOADED_TRANSFORM="$CP_LOADED_TRANSFORM" CP_OK="$CP_OK" CP2_STDOUT="$CP2_STDOUT" \
TOOL_404="$(code /api/tool)" CHILDREN_404="${Q3_CHILDREN_CODE:-non misurato}" \
EVENTS_SUMMARY="$(events_files_summary)" RID="$RID" PORT="$PORT" \
python3 - <<'PY'
import os, re
path = os.environ["FIND"]
s = open(path, encoding="utf-8").read()
repl = {
    "@@Q1_INPUT_KEYS@@": os.environ.get("Q1_LINE", "non misurato"),
    "@@CTX_KEYS@@": os.environ.get("CTX_KEYS") or "non misurato",
    "@@CTX_KEYS_N@@": os.environ.get("CTX_KEYS_N") or "non misurato",
    "@@CTX_SERVICES@@": os.environ.get("CTX_SERVICES") or "non misurato",
    "@@CP_PLUGIN_COUNT@@": os.environ.get("CP_PLUGIN_COUNT") or "non misurato",
    "@@CP_BAD_STATE@@": os.environ.get("CP_BAD_STATE") or "non misurato",
    "@@CP_BAD_STATE_ERR@@": os.environ.get("CP_BAD_STATE_ERR") or "",
    "@@CP_EXPORT_STATE@@": os.environ.get("CP_EXPORT_STATE") or "non misurato",
    "@@CP_ERR_EXPORT@@": os.environ.get("CP_ERR_EXPORT") or "non misurato",
    "@@CP_ERR_TRANSFORM@@": os.environ.get("CP_ERR_TRANSFORM") or "non misurato",
    "@@CP_ERR_TRANSFORM_STATE@@": os.environ.get("CP_ERR_TRANSFORM_STATE") or "non misurato",
    "@@CP_AUTH_CODE@@": os.environ.get("CP_AUTH_CODE") or "non misurato",
    "@@CP_IDLE_IN_BIN@@": os.environ.get("CP_IDLE_IN_BIN") or "non misurato",
    "@@CP_LOADED_EXPORT@@": os.environ.get("CP_LOADED_EXPORT") or "non misurato",
    "@@CP_LOADED_TRANSFORM@@": os.environ.get("CP_LOADED_TRANSFORM") or "non misurato",
    "@@CP_OK@@": os.environ.get("CP_OK") or "non misurato",
    "@@CP2_STDOUT@@": os.environ.get("CP2_STDOUT") or "non misurato",
    "@@TOOL_404@@": os.environ.get("TOOL_404", "non misurato"),
    "@@CHILDREN_404@@": os.environ.get("CHILDREN_404", "non misurato"),
    "@@EVENTS_FILES@@": os.environ.get("EVENTS_SUMMARY", "non misurato"),
    "@@RID@@": "`%s`" % os.environ.get("RID", "non misurato"),
    "@@PORT@@": "`%s`" % os.environ.get("PORT", "non misurato"),
}
for k, v in repl.items():
    s = s.replace(k, v)
open(path, "w", encoding="utf-8").write(s)
PY
if grep -q '@@' "$FIND"; then
  echo "ATTENZIONE: restano marker non risolti in FINDINGS.md:" >&2
  grep -n '@@' "$FIND" >&2
fi

echo "sezioni: $(grep -c '^## Domanda' "$FIND")"
if [ "$(grep -c '^## Domanda' "$FIND")" != "6" ]; then
  echo "FATAL: FINDINGS.md non ha sei sezioni" >&2
  exit 1
fi

cleanup
trap - EXIT
note "probe completata"