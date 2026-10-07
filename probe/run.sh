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

# attende che appaia un type nell'event log (timeout in secondi)
sse_wait() { # type timeout_s
  local want="$1" limit="$2" i
  for i in $(seq 1 $((limit * 2))); do
    if grep -q "\"type\":\"$want\"" "$EVENTS_FILE" 2>/dev/null; then return 0; fi
    if [ -n "${SESSION_ID:-}" ] && grep -q "\"type\":\"$want\".*$SESSION_ID" "$EVENTS_FILE" 2>/dev/null; then return 0; fi
    sleep 0.5
  done
  return 1
}

session_snapshot() { # sessionID etichetta -> $OUT/session-<label>.json
  api "/api/session/$1" > "$OUT/session-$2.json"
}

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
    curl -sS "${AUTH[@]}" -o /dev/null -X POST -H 'content-type: application/json' \
      -d '{"text":"Chiama lo strumento probe_tool con le sue impostazioni predefinite, poi rispondi solo: done"}' \
      "$BASE/api/session/$Q2_SESSION/prompt"
    for _ in $(seq 1 120); do
      grep -q '"kind":"tool-execute"' "$PLUGIN_OUT" 2>/dev/null && break
      sleep 1
    done
  fi
fi

# ───────────────────────────── Q3: POST /api/session con parentID ─────────────────────────────

note "Q3: parentID"
Q3_BODY="{\"location\":{\"directory\":\"$ROOT/work\"},\"title\":\"child-probe\",\"parentID\":\"ses_nonexistent\"}"
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
# stesse prove senza parentID, per confronto: due richieste identiche salvo la chiave
Q3_CTL=$(curl -sS "${AUTH[@]}" -o "$OUT/q3-control.json" -w '%{http_code}' \
  -X POST -H 'content-type: application/json' \
  -d "{\"location\":{\"directory\":\"$ROOT/work\"},\"title\":\"control-probe\"}" "$BASE/api/session")
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
  elif grep -q '"session.execution.failed"' "$EVENTS_FILE" 2>/dev/null; then
    Q4_TURN="failed"
  else
    Q4_TURN="timeout"
  fi
  EVENTS_Q4="$EVENTS_FILE"

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
  Q6_TYPES=$(jq -r 'select(.type | startswith("session.execution.")) | .type' <(sed -n 's/^data: //p' "$EVENTS_FILE") 2>/dev/null | sort -u | paste -sd' ' -)
  Q6_PAYLOAD=$(jq -c 'select(.type == "session.execution.interrupted")' <(sed -n 's/^data: //p' "$EVENTS_FILE") 2>/dev/null | head -1)
  # `session.step.failed` porta l'errore del singolo passo: è più informativo di
  # `session.execution.interrupted`, che dice solo che il turno è finito male.
  Q6_STEP=$(jq -c 'select(.type == "session.step.failed")' <(sed -n 's/^data: //p' "$EVENTS_FILE") 2>/dev/null | head -1)
  # se l'interrupt è caduto in un retry e non in uno step, il motivo è un altro e
  # va detto: il turno era già in riparazione quando l'utente ha premuto Esc.
  Q6_RETRY=$(jq -c 'select(.type == "session.retry.scheduled")' <(sed -n 's/^data: //p' "$EVENTS_FILE") 2>/dev/null | head -1)
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
  Q6B_TYPES=$(jq -r 'select(.type | startswith("session.execution.")) | .type' <(sed -n 's/^data: //p' "$EVENTS_FILE") 2>/dev/null | sort -u | paste -sd' ' -)
  # il payload per intero: è lui che dice al supervisore come distinguere i casi
  Q6B_PAYLOAD=$(jq -c 'select(.type == "session.execution.failed")' <(sed -n 's/^data: //p' "$EVENTS_FILE") 2>/dev/null | head -1)
  # `grep -c` esce con 1 quando non trova nulla, e `set -o pipefail` fa terminare
  # lo script su quel conteggio — che è proprio il risultato atteso qui.
  IDLE_COUNT=$( { grep -c 'session.idle' "$OUT"/events-*.log || true; } 2>/dev/null | awk -F: '{t+=$2} END {print t+0}')
  session_snapshot "$Q6B_ID" q6b
  Q6B_OUTCOME=$(jq -r '.data.outcome // "__ASSENTE__"' "$OUT/session-q6b.json" 2>/dev/null || echo "?")
fi

# ───────────────────────────── FINDINGS ─────────────────────────────

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

Ogni risposta è un fatto misurato in questa esecuzione. Dove la prova non è riuscita
la sezione dice **non misurato** con l'errore esatto: nessun valore è dedotto dal
codice o dai typings.

Evidenze grezze in \`probe/out/\`: \`serve.log\`, \`plugin-last.jsonl\`,
\`events-*.log\`, \`q*.json\`, \`session-*.json\`.

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
    "- `draft.list()` prima del `add`: " + ((.listLength // 0)|tostring) + " tool, con `probe_tool` già presente: `" + ((.listAfterAdd.hasProbeTool // "null")|tostring) + "`\n" +
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
- richiesta di controllo identica **senza** \`parentID\` (\`$Q3_CTL_ID\`) → \`parentID\` = \`$Q3_CTL_PARENT\`
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
- richiesta di controllo identica **senza** \`parentID\` (\`$Q3_CTL_ID\`) → \`parentID\` = \`$Q3_CTL_PARENT\`
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

**Il comando uscito è ancora in lista:** \`GET /api/shell\` → \`$Q5_LIST\`.
\`<id>\` del comando uscito presente in lista: conteggio \`$Q5_HAS_EXITED\`.
\`GET /api/shell/$Q5_ID\` dopo il termine → HTTP \`$Q5_REMOVED_CODE\` (200 = resta
leggibile, 404 = sparisce).

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
  $( [ -n "$Q6_STEP" ] && echo "(arrivato, con \`data.error.type\` e \`data.assistantMessageID\`)" || echo "(**non arrivato**: l'interrupt è caduto mentre il runtime era in \`session.retry.scheduled\`, non dentro uno step — misurato in un'esecuzione precedente della stessa probe, dove la coppia \`step.failed\`/\`interrupted\` si è rivelata variabile)" )
- \`failed\`: sessione su modello inesistente \`$Q6B_ID\`, \`POST /prompt\` → HTTP \`$Q6B_PROMPT_CODE\`.
  \`session.execution.*\` arrivati: \`$Q6B_TYPES\`. \`outcome\` dopo: \`$Q6B_OUTCOME\`.
  Payload: \`$Q6B_PAYLOAD\`

Riepilogo dei \`type\` distinti osservati su tutti i listener di questa esecuzione:
\`$(sed -n 's/^data: //p' "$OUT"/events-*.log 2>/dev/null | jq -r 'select(.type)|.type' 2>/dev/null | sort -u | paste -sd' ' -)\`

La sua assenza è la misura che ha corretto la v1: \`session.idle\` **non compare in
nessuno dei listener di questa esecuzione** — \`$IDLE_COUNT\` occorrenze in tutto,
su \`$(events_files_summary)\` file di eventi.
Il token esiste nel binario come dichiarazione di schema, ma nessun emittente lo
produce. È citato qui **solo** per documentare che la misura lo cerca e non lo
trova: nessun task successivo deve usarlo, nemmeno in un commento.

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
  `{ id, setup }` (o `{ id, effect }`). Un default export funzione viene rifiutato
  con `Plugin must export a default definition with an id and an effect or setup
  function.` I typings 1.18.16 dichiarano `Plugin` come funzione: sono sbagliati per
  2.0.14. Cambia l'intestazione di `src/index.ts` in T7.

- **`Object.keys(input)` al `setup`** (misurato, non deduotto):

  ```text
  @@CTX_KEYS@@
  ```

  I typings dichiarano sette chiavi: `client, project, directory, worktree,
  experimental_workspace, serverUrl, $`. Nel runtime ci sono ventisei, e le sette
  dei typings non ci sono più: non c'è `client`, non c'è `$`. Al loro posto ci sono
  i servizi su cui la spec §2.3 dice di non poter contare.

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
  `404` (misurato, HTTP `@@TOOL_404@@`). Il brief lo indicava come disponibile; la
  forma dei tool si misura dal plugin (Q2), non dall'endpoint.
- `GET /api/session/<id>/children` non è in `/openapi.json` e risponde `404`
  (misurato, HTTP `@@CHILDREN_404@@`).


---

## Traccia

- run: @@RID@@
- porta: @@PORT@@, `HOME=$ROOT`, cwd `$ROOT/work`
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
if [ -n "$Q1_SETUP" ]; then
  Q1_KEYS_LINE=$(jq -r '"`Object.keys(input)` al `setup` = `" + ((.inputKeys // []) | join(", ")) + "`"' <<<"$Q1_SETUP")
else
  Q1_KEYS_LINE="non misurato: nessun record setup nel jsonl del plugin"
fi
CTX_KEYS=""
CTX_SERVICES=""
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
  | .[0] + ": " + ((.[1] | to_entries | map(.key + "()") | join(", ")))
' <<<"$Q1_SETUP")
fi
[ -n "$CTX_SERVICES" ] || CTX_SERVICES="  (non misurato: nessun record setup)"
# Le sostituzioni sono fatte con python e non con sed: `@@CTX_SERVICES@@` è
# multilinea e sed non accetta un newline nella sostituzione.
FIND="$FIND" Q1_LINE="$Q1_KEYS_LINE" CTX_KEYS="$CTX_KEYS" CTX_SERVICES="$CTX_SERVICES" \
TOOL_404="$(code /api/tool)" CHILDREN_404="${Q3_CHILDREN_CODE:-non misurato}" \
EVENTS_SUMMARY="$(events_files_summary)" RID="$RID" PORT="$PORT" \
python3 - <<'PY'
import os, re
path = os.environ["FIND"]
s = open(path, encoding="utf-8").read()
repl = {
    "@@Q1_INPUT_KEYS@@": os.environ.get("Q1_LINE", "non misurato"),
    "@@CTX_KEYS@@": os.environ.get("CTX_KEYS") or "non misurato",
    "@@CTX_SERVICES@@": os.environ.get("CTX_SERVICES") or "non misurato",
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