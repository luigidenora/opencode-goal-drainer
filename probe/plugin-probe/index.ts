/**
 * goal-drainer plugin-probe
 *
 * Risponde a due domande della probe che non si possono chiedere al server,
 * perché vivono nel runtime del plugin:
 *
 *   Q1  `command.transform` espone `add`? Il comando si registra dal plugin?
 *   Q2  forma esatta dell'editor di `tool.transform`, e cosa ricevono
 *       `args` e `context` dentro `execute`.
 *
 * Fatti di opencode 2.0.14 che il probe registra invece di assumere:
 *
 *   - il default export NON è una funzione: è un oggetto `{ id, setup }`
 *     (o `{ id, effect }`). Un default export funzione viene rifiutato con
 *     "Plugin must export a default definition with an id and an effect or setup
 *     function."
 *   - l'oggetto che arriva a `setup` contiene `app, location, options, agent,
 *     aisdk, command, event, experimental, generate, model, provider, integration,
 *     mcp, permission, plugin, reference, rpc, skill, storage, tool, vcs,
 *     websearch, worktree, session, shell`. I typings `@opencode-ai/plugin`
 *     1.18.16 dichiarano solo client/project/directory/worktree/
 *     experimental_workspace/serverUrl/$: nessun command, nessun tool. Per
 *     guardare il runtime reale qui è tutto `any`, e il fatto è dichiarato.
 *   - `command.transform(cb)` e `tool.transform(cb)` NON restituiscono un editor:
 *     prendono una callback. La callback riceve il draft e l'editor è il suo
 *     unico argomento. Chiamarle con `{}` fa fallire il plugin con
 *     "disabled plugin after transform failure … 'pe' is not a function".
 *
 * Ogni scrittura appende una riga JSON a $PROBE_PLUGIN_OUT (JSONL).
 */

import { appendFileSync } from "node:fs"

const OUT = process.env.PROBE_PLUGIN_OUT ?? "/tmp/opencode/plugin-probe.jsonl"
const TOOL_NAME = "probe_tool"
const COMMAND_NAME = "probe_command"

// I transform vengono riapplicati più volte dal runtime (reload, change di
// location). Si registra solo la prima applicazione per state: altrimenti il
// JSONL diventa illeggibile e `add` registra il comando più volte.
let commandDraftSeen = false
let toolDraftSeen = false

function write(entry: Record<string, unknown>) {
  try {
    appendFileSync(OUT, JSON.stringify({ at: new Date().toISOString(), ...entry }) + "\n")
  } catch (e) {
    console.error("plugin-probe: cannot write " + OUT, String(e))
  }
}

/** {chiave: "function"|"object"|"array"|"string"|…} da Object.keys, senza il prototype. */
function shapes(value: any): Record<string, string> | null {
  if (value === null || value === undefined) return null
  if (typeof value !== "object" && typeof value !== "function") return { __value: typeof value }
  const out: Record<string, string> = {}
  for (const key of Object.keys(value)) {
    const v = value[key]
    out[key] = v === null ? "null" : Array.isArray(v) ? "array" : typeof v
  }
  return out
}

function src(fn: any): string | null {
  if (typeof fn !== "function") return null
  try {
    return Function.prototype.toString.call(fn)
  } catch (e) {
    return "toString threw: " + String(e)
  }
}

// ───────────────────────────── Q1: command.transform ─────────────────────────────

function probeCommand(ctx: any) {
  const q: Record<string, unknown> = {
    serviceType: typeof ctx?.command,
    serviceKeys: shapes(ctx?.command),
    transformType: typeof ctx?.command?.transform,
    transformArity: ctx?.command?.transform?.length ?? null,
    transformSource: src(ctx?.command?.transform),
  }
  if (typeof ctx?.command?.transform !== "function") {
    q.note = "command.transform assente: nessuna chiamata eseguita"
    return q
  }

  try {
    q.transformReturnType = typeof ctx.command.transform((draft: any) => {
      if (commandDraftSeen) return
      commandDraftSeen = true
      const entry: Record<string, unknown> = {
        kind: "command-transform-draft",
        draftKeys: draft ? Object.keys(draft) : null,
        draftEntryTypes: shapes(draft),
        addType: typeof draft?.add,
        addArity: typeof draft?.add === "function" ? draft.add.length : null,
        addSource: src(draft?.add),
      }
      if (typeof draft?.add !== "function") {
        write(entry)
        return
      }
      // Il primo tentativo scopre la forma minima. `{name,description,template}`
      // è quello che si sa essere plausibile per un comando: si registra
      // l'esito, e solo se va a buon fine si cercano le varianti.
      try {
        const r = draft.add({
          name: COMMAND_NAME,
          description: "Probe command. Chiama /probe_command con un argomento qualsiasi.",
          template: "$ARGUMENTS",
        })
        entry.addAttempt = { payload: "{name,description,template}", ok: true, returned: String(r) }
      } catch (e: any) {
        entry.addAttempt = {
          payload: "{name,description,template}",
          ok: false,
          error: (e?.name ?? "Error") + ": " + (e?.message ?? String(e)),
        }
        // forma alternativa: solo name
        try {
          const r2 = draft.add({ name: COMMAND_NAME })
          entry.addAttemptFallback = { payload: "{name}", ok: true, returned: String(r2) }
        } catch (e2: any) {
          entry.addAttemptFallback = {
            payload: "{name}",
            ok: false,
            error: (e2?.name ?? "Error") + ": " + (e2?.message ?? String(e2)),
          }
        }
      }

      // il comando è davvero nel registro? `command.list()` non è un array: la
      // forma va misurata, non dedotta.
      try {
        const listed: any = ctx.command.list()
        entry.listAfterAdd = {
          type: typeof listed,
          isArray: Array.isArray(listed),
          isPromise: typeof listed?.then === "function",
          keys: listed && typeof listed === "object" ? Object.keys(listed) : null,
          raw: typeof listed === "string" ? listed : String(listed).slice(0, 200),
        }
        if (typeof listed?.then === "function") {
          listed
            .then((v: any) => {
              write({
                kind: "command-list-resolved",
                isArray: Array.isArray(v),
                length: Array.isArray(v) ? v.length : null,
                names: Array.isArray(v) ? v.map((c: any) => c?.name ?? c?.id ?? String(c)) : null,
                hasProbeCommand: Array.isArray(v)
                  ? v.some((c: any) => (c?.name ?? c?.id) === COMMAND_NAME)
                  : null,
              })
            })
            .catch((e: any) => write({ kind: "command-list-resolved", error: String(e) }))
        }
      } catch (e: any) {
        entry.listAfterAdd = { error: (e?.name ?? "Error") + ": " + (e?.message ?? String(e)) }
      }

      write(entry)
    })
    q.transformCallReturned = q.transformReturnType
  } catch (e: any) {
    q.transformCallError = (e?.name ?? "Error") + ": " + (e?.message ?? String(e))
  }
  return q
}

// ───────────────────────────── Q2: tool.transform + execute ─────────────────────────────

function probeTool(ctx: any) {
  const q: Record<string, unknown> = {
    serviceType: typeof ctx?.tool,
    serviceKeys: shapes(ctx?.tool),
    transformType: typeof ctx?.tool?.transform,
    transformArity: ctx?.tool?.transform?.length ?? null,
    transformSource: src(ctx?.tool?.transform),
  }
  if (typeof ctx?.tool?.transform !== "function") {
    q.note = "tool.transform assente"
    return q
  }

  try {
    q.transformReturnType = typeof ctx.tool.transform((draft: any) => {
      if (toolDraftSeen) return
      toolDraftSeen = true
      const entry: Record<string, unknown> = {
        kind: "tool-transform-draft",
        draftKeys: draft ? Object.keys(draft) : null,
        draftEntryTypes: shapes(draft),
        listType: typeof draft?.list,
        getType: typeof draft?.get,
        namespaceType: typeof draft?.namespace,
        addType: typeof draft?.add,
        updateType: typeof draft?.update,
        removeType: typeof draft?.remove,
        addArity: typeof draft?.add === "function" ? draft.add.length : null,
        addSource: src(draft?.add),
      }

      if (typeof draft?.list === "function") {
        try {
          const list = draft.list()
          entry.listLength = Array.isArray(list) ? list.length : null
          entry.listNames = Array.isArray(list) ? list.map((t: any) => t?.name ?? t?.id ?? null) : null
        } catch (e: any) {
          entry.listError = (e?.name ?? "Error") + ": " + (e?.message ?? String(e))
        }
      }

      if (typeof draft?.add !== "function") {
        write(entry)
        return
      }

      entry.addAttempt = (() => {
        try {
          draft.add({
            name: TOOL_NAME,
            description:
              "Probe tool. Devi chiamare questo strumento una volta, poi rispondi solo con la parola done.",
            args: {},
            execute: async (args: any, context: any) => {
              write({
                kind: "tool-execute",
                toolName: TOOL_NAME,
                argsKeys: Object.keys(args ?? {}),
                argsShapes: shapes(args),
                contextKeys: Object.keys(context ?? {}),
                contextShapes: shapes(context),
                contextSessionID: context?.sessionID ?? null,
                contextMessageID: context?.messageID ?? null,
                contextAgent: context?.agent ?? null,
                contextDirectory: context?.directory ?? null,
                contextWorktree: context?.worktree ?? null,
                contextAbortType: typeof context?.abort,
                contextAbortAborted: context?.abort?.aborted ?? null,
                contextMetadataType: typeof context?.metadata,
                contextAskType: typeof context?.ask,
              })
              return "probe_tool eseguito"
            },
          })
          return { ok: true }
        } catch (e: any) {
          return { ok: false, error: (e?.name ?? "Error") + ": " + (e?.message ?? String(e)) }
        }
      })()
      if (typeof draft?.list === "function") {
        try {
          const after = draft.list()
          entry.listAfterAdd = {
            length: Array.isArray(after) ? after.length : null,
            hasProbeTool: Array.isArray(after) ? after.some((t: any) => (t?.name ?? t?.id) === TOOL_NAME) : null,
          }
        } catch (e: any) {
          entry.listAfterAdd = { error: (e?.name ?? "Error") + ": " + (e?.message ?? String(e)) }
        }
      }
      if (typeof draft?.get === "function") {
        entry.getAfterAdd = (() => {
          try {
            const got = draft.get(TOOL_NAME)
            return { ok: true, type: typeof got, keys: got && typeof got === "object" ? Object.keys(got) : null }
          } catch (e: any) {
            return { ok: false, error: (e?.name ?? "Error") + ": " + (e?.message ?? String(e)) }
          }
        })()
      }
      write(entry)
    })
    q.transformCallReturned = q.transformReturnType
  } catch (e: any) {
    q.transformCallError = (e?.name ?? "Error") + ": " + (e?.message ?? String(e))
  }
  return q
}

// ───────────────────────────── definizione ─────────────────────────────

const definition = {
  id: "goal-drainer-plugin-probe",
  setup: async (input: any, options?: any) => {
    const q1 = probeCommand(input)
    const q2 = probeTool(input)
    write({
      kind: "setup",
      pid: process.pid,
      cwd: process.cwd(),
      inputKeys: Object.keys(input ?? {}),
      inputShapes: shapes(input),
      serverUrl: input?.serverUrl ? String(input.serverUrl) : null,
      directory: input?.directory ?? null,
      worktree: input?.worktree ?? null,
      project: input?.project ?? null,
      options: options ?? null,
      // campi che la spec dà per assenti: li si misura, non si deducono
      ctxPermissionKeys: shapes(input?.permission),
      ctxSessionKeys: shapes(input?.session),
      ctxEventKeys: shapes(input?.event),
      ctxShellKeys: shapes(input?.shell),
      ctxVcsKeys: shapes(input?.vcs),
      q1,
      q2,
    })

    // NOTA: nessuna chiave `command` o `tool` negli hooks restituiti. In 2.0.14 il
    // runtime chiama `hooks.command(draft)` / `hooks.tool(draft)` come transform, e
    // un oggetto lì dentro disabilita il plugin. I tool si registrano con
    // `input.tool.transform(draft => draft.add(...))`, non con la mappa dei typings.
    return {
      event: async ({ event }: any) => {
        const type = event?.type
        if (typeof type === "string" && type.startsWith("session.execution.")) {
          write({ kind: "plugin-event", type, keys: event ? Object.keys(event) : null, data: event?.data })
        }
      },
    }
  },
}

export default definition