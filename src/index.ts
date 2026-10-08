import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs"
import { resolve } from "node:path"
import { hasBlocked, nextOpen, parseBacklog, setStatus, type Item, type ItemStatus } from "./backlog.ts"
import { extractVerify, judge, type GoalSpec } from "./judge.ts"
import {
  acquireLease,
  isTerminal,
  readState,
  renewLease,
  writeState,
  type GoalState,
} from "./store.ts"
import { changedPaths, fingerprintSync, stalled, verifySync } from "./verifier.ts"

const LEASE_TTL_MS = 15 * 60 * 1000
const WATCHDOG_MS = 30 * 60 * 1000
const VERIFY_TIMEOUT_MS = 10 * 60 * 1000
const SOURCE = "goal-drainer"
// Il server non conserva `metadata` sulle synthetic: il payload porta solo `text`.
const MARK = "[[goal-drainer]]"
const CLEAR_ALIASES = ["clear", "stop", "off", "reset", "none", "cancel"]

const ACTIVE_ROOTS = new Set<string>()

const GO_MONTHLY_LIMIT_USD: Record<string, number> = {
  "opencode-go/space-bunny": 30,
  "opencode-go/muse-spark-1.3-contributor": 60,
  "opencode-go/muse-spark-1.2-contributor": 60,
  "opencode-go/deepseek-v4-pro": 15,
  "opencode-go/deepseek-v4.1-flash": 60,
  "opencode-go/deepseek-v4-flash": 30,
  "opencode-go/deepseek-v4-flash-vision-exp": 15,
  "opencode-go/qwen3.7-plus": 60,
  "opencode-go/qwen3.8-flash": 30,
  "opencode-go/qwen3.8-max": 15,
  "opencode-go/glm-5.2": 60,
  "opencode-go/glm-5.3": 15,
  "opencode-go/glm-5.3-flash": 60,
  "opencode-go/mimo-v2.5": 60,
  "opencode-go/mimo-v2.5-pro": 15,
  "opencode-go/mimo-v2.6-flash": 60,
  "opencode-go/mimo-v2.6-pro": 15,
  "opencode-go/minimax-m2.7": 60,
  "opencode-go/minimax-m3": 60,
  "opencode-go/kimi-k2.7-code": 60,
  "opencode-go/kimi-k3": 15,
  "opencode-go/longcat-2.0": 60,
  "opencode-go/hy3": 60,
  "opencode-go/hy4-preview": 30,
  "opencode-go/grok-4.6": 15,
  "opencode-go/grok-4.7": 15,
  "opencode-go/gpt-6-luna": 15,
  "opencode-go/gpt-5.6-luna": 15,
}

interface Options {
  budgetPercent: number
  autoApprove: boolean
  stallTurns: number
  verifyTimeoutMs: number
  watchdogMs: number
  maxTurns: number
  monthlyLimitsUSD: Record<string, number>
}

function options(raw: Record<string, unknown>): Options {
  return {
    budgetPercent: typeof raw.budgetPercent === "number" ? raw.budgetPercent : 10,
    autoApprove: raw.autoApprove !== false,
    stallTurns: typeof raw.stallTurns === "number" ? raw.stallTurns : 5,
    verifyTimeoutMs: typeof raw.verifyTimeoutMs === "number" ? raw.verifyTimeoutMs : VERIFY_TIMEOUT_MS,
    watchdogMs: typeof raw.watchdogMs === "number" ? raw.watchdogMs : WATCHDOG_MS,
    maxTurns: typeof raw.maxTurns === "number" ? raw.maxTurns : 0,
    monthlyLimitsUSD: { ...GO_MONTHLY_LIMIT_USD, ...((raw.monthlyLimitsUSD as Record<string, number>) ?? {}) },
  }
}

function budgetExceeded(s: GoalState, o: Options): { exceeded: boolean; reason?: string } {
  for (const [model, usage] of Object.entries(s.spend)) {
    const limit = o.monthlyLimitsUSD[model]
    if (!limit) continue
    const cap = (o.budgetPercent / 100) * limit
    if (usage.cost >= cap) {
      return {
        exceeded: true,
        reason: `tetto ${o.budgetPercent}% su ${model}: $${usage.cost.toFixed(4)} >= $${cap.toFixed(2)}`,
      }
    }
  }
  return { exceeded: false }
}

export const GoalDrainer = {
  id: SOURCE,
  async setup(input: any) {
    const o = options((input.options as Record<string, unknown>) ?? {})
    const root: string =
      input.location?.directory ?? input.location?.project?.canonical ?? process.cwd()
    if (ACTIVE_ROOTS.has(root)) return () => {}
    ACTIVE_ROOTS.add(root)

    const session = input.session
    const events = input.event
    const permission = input.permission
    const tool = input.tool
    const command = input.command

    const state: { s: GoalState | null; sessionID: string | null } = { s: null, sessionID: null }
    const controller = new AbortController()
    let lastEventAt = Date.now()
    let lastModel: string | null = null
    // Testo dell'ultimo prompt iniettato dal plugin (synthetic o risposta di comando).
    // Serve a non scambiare la propria voce per un intervento umano: il server non
    // conserva `metadata`, e le risposte dei comandi sono prompt utente a tutti gli effetti.
    let lastInjected: string | null = null

    const save = () => {
      if (state.s) writeState(root, state.s)
    }
    const say = async (sid: string, text: string) => {
      lastInjected = text
      try {
        await session.synthetic({ sessionID: sid, text: `${MARK}\n${text}`, metadata: { source: SOURCE } })
      } catch {
        /* il watchdog fermerà il goal */
      }
    }
    const finish = (status: GoalState["status"], reason: string) => {
      if (!state.s) return
      state.s.status = status
      state.s.lastReason = reason
      state.s.updatedAt = Date.now()
      save()
    }
    const generate = async (sid: string, prompt: string): Promise<string> => {
      const r = await session.generate({ sessionID: sid, prompt })
      return typeof r === "string" ? r : (r?.text ?? r?.data?.text ?? "")
    }

    const mark = (item: Item, status: ItemStatus, evidence: Item["evidence"]) => {
      const p = resolve(root, state.s!.backlogPath!)
      writeFileSync(p, setStatus(readFileSync(p, "utf8"), item.id, status, evidence))
    }

    /** Un turno è finito: valuta il goal. Vale sia per la modalità condition sia per la backlog. */
    const onTurnEnd = async () => {
      const s = state.s
      if (!s || s.status !== "running" || !state.sessionID) return
      const sid = state.sessionID
      const now = Date.now()
      if (!renewLease(s, sid, now, LEASE_TTL_MS)) return finish("stopped", "lease perso")
      s.turns += 1
      if (o.maxTurns > 0 && s.turns >= o.maxTurns) {
        return finish("failed", `raggiunto maxTurns (${o.maxTurns})`)
      }
      const budget = budgetExceeded(s, o)
      if (budget.exceeded) return finish("failed", budget.reason!)

      if (s.mode === "backlog") return onBacklogTurn()
      return onConditionTurn()
    }

    /** Modalità generica: una condizione, giudicata dal modello. Come /goal di Claude Code. */
    const onConditionTurn = async () => {
      const s = state.s!
      const sid = state.sessionID!
      let v = null
      if (s.verify) {
        v = verifySync({ command: s.verify, cwd: root, timeoutMs: o.verifyTimeoutMs })
        if (v.exitCode !== 0) {
          s.redStreak += 1
          s.lastReason = v.timedOut ? "verifica in timeout" : `verifica rossa (exit ${v.exitCode})`
          let unchanged = false
          try {
            const fp = fingerprintSync(root, changedPaths(root))
            unchanged = s.fingerprint !== null && s.fingerprint === fp
            s.fingerprint = fp
          } catch {
            unchanged = false
          }
          if (unchanged && s.redStreak >= o.stallTurns) {
            return finish("failed", "verifica rossa senza progressi: nessun file modificato")
          }
          save()
          return say(sid, `Check rosso${v.timedOut ? " (timeout)" : ` (exit ${v.exitCode})`}.\nOutput:\n${v.tail}`)
        }
        s.redStreak = 0
      }
      const spec: GoalSpec = { condition: s.condition!, verify: s.verify }
      const verdict = await judge((p) => generate(sid, p), spec, v)
      s.lastReason = verdict.reason
      save()
      if (verdict.status === "done") return finish("achieved", verdict.reason)
      if (verdict.status === "blocked") return finish("failed", verdict.reason)
      return say(sid, verdict.reason)
    }

    /** Modalità backlog: più item, ognuno con il suo Verify. */
    const onBacklogTurn = async () => {
      const s = state.s!
      const sid = state.sessionID!
      const p = resolve(root, s.backlogPath!)
      let items = parseBacklog(readFileSync(p, "utf8"))
      let item = s.current ? items.find((i) => i.id === s.current) ?? nextOpen(items) : nextOpen(items)
      if (!item) {
        const blocked = items.filter((i) => i.status === "blocked").length
        return finish(blocked > 0 ? "failed" : "achieved", blocked > 0 ? `coda svuotata con ${blocked} bloccati` : "coda svuotata")
      }
      if (!item.verify) {
        mark(item, "invalid", { date: new Date().toISOString().slice(0, 10), reason: "Verify: assente o vuoto" })
        s.current = null
        save()
        return onBacklogTurn()
      }
      s.current = item.id
      save()
      const v = verifySync({ command: item.verify, cwd: root, timeoutMs: o.verifyTimeoutMs })
      if (v.exitCode !== 0) {
        s.redStreak += 1
        s.lastReason = v.timedOut ? "verifica in timeout" : `verifica rossa (exit ${v.exitCode})`
        let unchanged = false
        try {
          const fp = fingerprintSync(root, changedPaths(root))
          unchanged = s.fingerprint !== null && s.fingerprint === fp
          s.fingerprint = fp
        } catch {
          unchanged = false
        }
        if (unchanged && s.redStreak >= o.stallTurns) {
          mark(item, "blocked", {
            date: new Date().toISOString().slice(0, 10),
            turns: s.redStreak,
            exitCode: v.exitCode,
            reason: "nessun progresso con verifica rossa",
          })
          s.current = null
          s.redStreak = 0
          save()
          return onBacklogTurn()
        }
        save()
        return say(sid, `Check rosso${v.timedOut ? " (timeout)" : ` (exit ${v.exitCode})`}.\nOutput:\n${v.tail}`)
      }
      s.redStreak = 0
      save()
      const spec: GoalSpec = { condition: item.title, accepts: item.accepts, verify: item.verify }
      const verdict = await judge((g) => generate(sid, g), spec, v)
      s.lastReason = verdict.reason
      if (verdict.status === "done") {
        mark(item, "done", {
          date: new Date().toISOString().slice(0, 10),
          turns: s.turns,
          exitCode: 0,
          reason: verdict.reason,
        })
        s.current = null
        save()
        return onBacklogTurn()
      }
      if (verdict.status === "blocked") {
        mark(item, "blocked", {
          date: new Date().toISOString().slice(0, 10),
          turns: s.turns,
          exitCode: 0,
          reason: verdict.reason,
        })
        s.current = null
        save()
        return onBacklogTurn()
      }
      save()
      return say(sid, verdict.reason)
    }

    const onEvent = async (ev: any) => {
      lastEventAt = Date.now()
      const type: string = ev?.type ?? ""
      const sid: string | undefined = ev?.data?.sessionID
      if (!state.s || !state.sessionID) return

      if (type === "session.form.created" && sid === state.sessionID) {
        return finish("stopped", "form aperto: il goal non attende un umano")
      }
      if (type === "session.inbox.enqueued" && sid === state.sessionID) {
        const text = String(ev?.data?.item?.payload?.text ?? "")
        const mine = text.startsWith(MARK) || (lastInjected !== null && text === lastInjected)
        if (!mine && state.s.status === "running") {
          state.s.status = "paused-utente"
          state.s.lastReason = "input umano in arrivo"
          save()
        }
        return
      }
      if (type === "session.step.started" && sid === state.sessionID) {
        const m = ev?.data?.model
        if (m?.id) lastModel = `${m.providerID}/${m.id}`
        return
      }
      if (type === "session.usage.updated" && sid === state.sessionID) {
        const key = lastModel ?? "unknown"
        const cost = typeof ev?.data?.cost === "number" ? ev.data.cost : 0
        const t = ev?.data?.tokens ?? {}
        const prev =
          state.s.spend[key] ??
          { cost: 0, tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } } }
        state.s.spend[key] = {
          cost: prev.cost + cost,
          tokens: {
            input: prev.tokens.input + (t.input ?? 0),
            output: prev.tokens.output + (t.output ?? 0),
            reasoning: prev.tokens.reasoning + (t.reasoning ?? 0),
            cache: {
              read: prev.tokens.cache.read + (t.cache?.read ?? 0),
              write: prev.tokens.cache.write + (t.cache?.write ?? 0),
            },
          },
        }
        save()
        return
      }
      if (sid !== state.sessionID) return
      if (type === "session.execution.succeeded") return onTurnEnd()
      if (type === "session.execution.failed" || type === "session.execution.interrupted") {
        if (state.s.status !== "running") return
        state.s.redStreak = 0
        state.s.lastReason =
          type === "session.execution.interrupted" ? "turno interrotto" : "turno fallito"
        save()
        return
      }
      if (type === "session.permission.updated" && o.autoApprove) {
        const req = ev?.data?.request ?? ev?.data
        const action = req?.action
        if (action !== "edit" && action !== "write" && action !== "shell") return
        const resource = String(req?.resource ?? "")
        if (resource.includes("..")) return
        if (resource.startsWith("/") && !resource.startsWith(root)) return
        try {
          await permission.reply({ sessionID: sid, requestID: req?.id, decision: "once" })
        } catch {
          /* una richiesta già risolta è un no-op */
        }
      }
    }

    const ensureLease = (sid: string): { ok: boolean; message: string } => {
      const now = Date.now()
      const lease = acquireLease(readState(root), sid, now, LEASE_TTL_MS)
      if (!lease.ok) return { ok: false, message: `goal non avviato: ${lease.reason}` }
      state.s = lease.state!
      state.sessionID = sid
      return { ok: true, message: "" }
    }

    /** Imposta un goal generico: /goal <condizione> */
    const setCondition = async (sid: string, condition: string) => {
      const r = ensureLease(sid)
      if (!r.ok) return r
      const s = state.s!
      s.mode = "condition"
      s.condition = condition
      s.verify = extractVerify(condition)
      s.backlogPath = null
      s.current = null
      s.status = "running"
      s.turns = 0
      s.redStreak = 0
      s.lastReason = null
      s.fingerprint = null
      s.startedAt = Date.now()
      save()
      return { ok: true, message: `goal impostato` }
    }

    /** Imposta il drenaggio di una backlog: /goal drain <path> */
    const setBacklog = async (sid: string, backlogPath: string) => {
      const p = resolve(root, backlogPath)
      if (!existsSync(p)) return { ok: false, message: `backlog non trovata: ${p}` }
      const r = ensureLease(sid)
      if (!r.ok) return r
      const s = state.s!
      s.mode = "backlog"
      s.condition = null
      s.verify = null
      s.backlogPath = backlogPath.replace(root + "/", "")
      s.current = null
      s.status = "running"
      s.turns = 0
      s.redStreak = 0
      s.lastReason = null
      s.fingerprint = null
      s.startedAt = Date.now()
      save()
      return { ok: true, message: `drenaggio avviato su ${s.backlogPath}` }
    }

    const clear = (reason: string) => {
      if (!state.s) return
      finish("cleared", reason)
    }

    const report = (): string => {
      const s = state.s
      const spend =
        Object.entries(s?.spend ?? {})
          .map(
            ([m, u]) =>
              `  ${m}: $${u.cost.toFixed(4)}${
                o.monthlyLimitsUSD[m]
                  ? ` / $${((o.budgetPercent / 100) * o.monthlyLimitsUSD[m]).toFixed(2)} (${o.budgetPercent}% del mensile)`
                  : " (nessun tetto noto)"
              }`,
          )
          .join("\n") || "  (nessuna spesa registrata)"
      const elapsed = s?.startedAt ? Math.round((Date.now() - s.startedAt) / 1000) : 0
      const head = [
        `Stato: ${s?.status ?? "idle"}`,
        s?.mode === "backlog" ? `Modalità: backlog (${s.backlogPath})` : `Modalità: condizione`,
        s?.condition ? `Condizione: ${s.condition}` : null,
        s?.verify ? `Verify: ${s.verify}` : null,
        s?.current ? `Item corrente: ${s.current}` : null,
        `Turni: ${s?.turns ?? 0}   durata: ${elapsed}s   streak rosso: ${s?.redStreak ?? 0}`,
        `Ultimo esito: ${s?.lastReason ?? "—"}`,
      ].filter(Boolean)
      return [...head, "Spesa (solo i modelli Go scalano l'abbonamento):", spend].join("\n")
    }

    const backlogReport = (): string => {
      const s = state.s
      const p = resolve(root, s?.backlogPath ?? "docs/backlog.md")
      if (!existsSync(p)) return "Nessuna backlog nota. Usa: /goal drain <percorso>"
      const items = parseBacklog(readFileSync(p, "utf8"))
      const by = (st: ItemStatus) =>
        items.filter((i) => i.status === st).map((i) => i.id).join(", ") || "—"
      return [
        `done:     ${by("done")}`,
        `bloccati: ${by("blocked")}`,
        `invalidi: ${by("invalid")}`,
        `aperti:   ${by("open")}`,
      ].join("\n")
    }

    await tool.transform((draft: any) => {
      draft.add({
        name: "goal_control",
        description:
          "Controlla il goal. Azioni: set (imposta una condizione di completamento), status, clear, drain (drena una backlog markdown), retry (riapre un item bloccato), report (dettaglio della backlog).",
        args: {
          type: "object",
          properties: {
            action: {
              type: "string",
              enum: ["set", "status", "clear", "drain", "retry", "report"],
              description: "Cosa fare",
            },
            condition: {
              type: "string",
              description: "Per action=set: la condizione di completamento, in prosa. Es: 'tutti i test passano' oppure 'README.md ha una sezione Install'.",
            },
            backlogPath: { type: "string", description: "Per action=drain: percorso della backlog" },
            itemId: { type: "string", description: "Per action=retry: id dell'item" },
          },
          required: ["action"],
        },
        execute: async (args: any, context: any) => {
          const sid = context?.sessionID ?? state.sessionID
          const a = args?.action
          if (a === "set") {
            if (!args?.condition) return { content: "serve condition" }
            const r = await setCondition(sid, String(args.condition))
            return { content: r.ok ? `Goal impostato: ${args.condition}` : r.message }
          }
          if (a === "drain") {
            const r = await setBacklog(sid, args?.backlogPath ?? "docs/backlog.md")
            return { content: r.message }
          }
          if (a === "clear") {
            clear("azzerato dall'utente")
            return { content: "Goal azzerato." }
          }
          if (a === "retry") {
            if (!args?.itemId) return { content: "serve itemId" }
            const p = resolve(root, state.s?.backlogPath ?? "docs/backlog.md")
            if (!existsSync(p)) return { content: `backlog non trovata: ${p}` }
            writeFileSync(p, setStatus(readFileSync(p, "utf8"), args.itemId, "open", {}))
            if (state.s) {
              state.s.status = "running"
              state.s.current = null
              save()
            }
            return { content: `Item ${args.itemId} riaperto.` }
          }
          if (a === "report") return { content: backlogReport() }
          return { content: report() }
        },
      })
    })

    if (command?.transform) {
      try {
        await command.transform((draft: any) => {
          draft.add({
            name: "goal",
            description:
              "Imposta una condizione di completamento e ci lavora finché non è soddisfatta. Uso: /goal <condizione> · /goal · /goal clear · /goal drain <backlog> · /goal retry <id>",
            execute: async (invocation: any) => {
              const sid: string = invocation?.sessionID ?? state.sessionID
              const delivery = invocation?.delivery ?? "steer"
              const args = String(invocation?.prompt?.text ?? "").trim()
              const [verb, ...rest] = args.split(/\s+/).filter(Boolean)
              const reply = async (text: string) => {
                lastInjected = text
                await session.prompt({ sessionID: sid, text, delivery })
              }

              if (!verb || verb === "status" || verb === "report") {
                if (verb === "report" && state.s?.mode === "backlog") {
                  return reply(report() + "\n\n" + backlogReport())
                }
                return reply(report())
              }
              if (CLEAR_ALIASES.includes(verb.toLowerCase())) {
                clear("azzerato dall'utente")
                return reply("Goal azzerato.")
              }
              if (verb === "retry") {
                const id = rest[0]
                if (!id) return reply("Serve un id: /goal retry B-04")
                const p = resolve(root, state.s?.backlogPath ?? "docs/backlog.md")
                if (!existsSync(p)) return reply(`Backlog non trovata: ${p}`)
                writeFileSync(p, setStatus(readFileSync(p, "utf8"), id, "open", {}))
                if (state.s) {
                  state.s.status = "running"
                  state.s.current = null
                  save()
                }
                return reply(`Item ${id} riaperto. Riprendo.`)
              }
              if (verb === "drain") {
                const r = await setBacklog(sid, rest[0] ?? "docs/backlog.md")
                if (!r.ok) return reply(r.message)
                return reply(
                  `${r.message}. Lavora sugli item uno alla volta: esegui il comando Verify: dell'item corrente e, se fallisce, correggi il codice. Non chiedere conferma.`,
                )
              }
              // Tutto il resto è una condizione di completamento.
              const condition = args
              const r = await setCondition(sid, condition)
              if (!r.ok) return reply(r.message)
              const hasVerify = extractVerify(condition)
              return reply(
                [
                  `Goal impostato: ${condition}`,
                  hasVerify ? `Gate deterministico: \`${hasVerify}\`` : null,
                  `Ci lavoro finché non è soddisfatto. Per fermarmi: /goal clear.`,
                ]
                  .filter(Boolean)
                  .join("\n"),
              )
            },
          })
        })
      } catch {
        /* il tool resta usabile a mano */
      }
    }

    const watchdog = setInterval(() => {
      if (state.s?.status === "running" && Date.now() - lastEventAt > o.watchdogMs) {
        finish("stopped", "watchdog: nessun evento terminale")
      }
    }, 60_000)

    if (events?.subscribe) {
      ;(async () => {
        try {
          for await (const ev of events.subscribe({ signal: controller.signal })) {
            await onEvent(ev)
          }
        } catch {
          /* stream chiuso: il cleanup ferma tutto */
        }
      })()
    }

    return () => {
      controller.abort()
      clearInterval(watchdog)
      ACTIVE_ROOTS.delete(root)
      if (state.s && !isTerminal(state.s.status)) {
        state.s.lease.expiresAt = 0
        save()
      }
    }
  },
}

export default GoalDrainer
