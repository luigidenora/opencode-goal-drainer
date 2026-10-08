import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs"
import { dirname, resolve } from "node:path"
import { hasBlocked, nextOpen, parseBacklog, setStatus, type Item, type ItemStatus } from "./backlog.ts"
import { judge } from "./judge.ts"
import { acquireLease, readState, renewLease, writeState, type GoalState } from "./store.ts"
import { changedPaths, fingerprintSync, stalled, verifySync } from "./verifier.ts"

const LEASE_TTL_MS = 15 * 60 * 1000
const WATCHDOG_MS = 30 * 60 * 1000
const VERIFY_TIMEOUT_MS = 10 * 60 * 1000
const MAX_TURNS_PER_RUN = 200
const SOURCE = "goal-drainer"
// Il server non conserva il campo `metadata` sulle synthetic: il payload porta solo
// `text`. Il marcatore nel testo è l'unico modo per distinguere una continuazione
// del drainer da un prompt dell'utente.
const MARK = "[[goal-drainer]]"

// Registro in-process delle directory già servite da un'istanza attiva.
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
  maxTurnsPerRun: number
  monthlyLimitsUSD: Record<string, number>
}

function options(raw: Record<string, unknown>): Options {
  return {
    budgetPercent: typeof raw.budgetPercent === "number" ? raw.budgetPercent : 10,
    autoApprove: raw.autoApprove !== false,
    stallTurns: typeof raw.stallTurns === "number" ? raw.stallTurns : 5,
    verifyTimeoutMs: typeof raw.verifyTimeoutMs === "number" ? raw.verifyTimeoutMs : VERIFY_TIMEOUT_MS,
    watchdogMs: typeof raw.watchdogMs === "number" ? raw.watchdogMs : WATCHDOG_MS,
    maxTurnsPerRun: typeof raw.maxTurnsPerRun === "number" ? raw.maxTurnsPerRun : MAX_TURNS_PER_RUN,
    monthlyLimitsUSD: { ...GO_MONTHLY_LIMIT_USD, ...((raw.monthlyLimitsUSD as Record<string, number>) ?? {}) },
  }
}

function readBacklog(p: string): string {
  return readFileSync(p, "utf8")
}

function budgetExceeded(s: GoalState, o: Options): { exceeded: boolean; reason?: string } {
  for (const [model, usage] of Object.entries(s.spend)) {
    const limit = o.monthlyLimitsUSD[model]
    if (!limit) continue
    const cap = (o.budgetPercent / 100) * limit
    if (usage.cost >= cap) {
      return { exceeded: true, reason: `tetto ${o.budgetPercent}% su ${model}: $${usage.cost.toFixed(4)} >= $${cap.toFixed(2)}` }
    }
  }
  return { exceeded: false }
}

export const GoalDrainer = {
  id: SOURCE,
  async setup(input: any) {
    const o = options((input.options as Record<string, unknown>) ?? {})
    const root: string = input.location?.directory ?? input.location?.project?.canonical ?? process.cwd()
    // Due istanze del plugin sulla stessa directory (per esempio caricato sia dal
    // path globale sia da .opencode/plugins/ del progetto) inietterebbero due
    // continuazioni per turno. La seconda si disattiva e lo dichiara.
    if (ACTIVE_ROOTS.has(root)) {
      return () => {}
    }
    ACTIVE_ROOTS.add(root)
    const session = input.session
    const events = input.event
    const permission = input.permission
    const vcs = input.vcs
    const tool = input.tool
    const command = input.command

    const state: { s: GoalState | null; sessionID: string | null } = { s: null, sessionID: null }
    const controller = new AbortController()
    let lastEventAt = Date.now()
    let lastModel: string | null = null
    let listener: Promise<void> | null = null

    const save = () => {
      if (state.s) writeState(root, state.s)
    }

    const say = async (sid: string, text: string) => {
      try {
        await session.synthetic({ sessionID: sid, text: `${MARK}\n${text}`, metadata: { source: SOURCE } })
      } catch {
        /* la continuazione non è riuscita: il watchdog fermerà il goal */
      }
    }

    const stop = (reason: string) => {
      if (!state.s) return
      state.s.status = "stopped"
      state.s.lastReason = reason
      state.s.updatedAt = Date.now()
      save()
    }

    const mark = (item: Item, status: ItemStatus, evidence: Item["evidence"]) => {
      const p = resolve(root, state.s!.backlogPath)
      const updated = setStatus(readBacklog(p), item.id, status, evidence)
      writeFileSync(p, updated)
    }

    const generate = async (sid: string, prompt: string): Promise<string> => {
      const r = await session.generate({ sessionID: sid, prompt })
      return typeof r === "string" ? r : (r?.text ?? r?.data?.text ?? "")
    }

    const onTurnEnd = async () => {
      const s = state.s
      if (!s || s.status !== "running" || !state.sessionID) return
      const sid = state.sessionID
      const now = Date.now()
      if (!renewLease(s, sid, now, LEASE_TTL_MS)) return stop("lease perso")
      s.turns += 1
      if (s.turns > o.maxTurnsPerRun) return stop(`raggiunto maxTurnsPerRun (${o.maxTurnsPerRun})`)

      const budget = budgetExceeded(s, o)
      if (budget.exceeded) return stop(budget.reason!)

      let items = parseBacklog(readBacklog(resolve(root, s.backlogPath)))
      let item = s.current ? items.find((i) => i.id === s.current) ?? nextOpen(items) : nextOpen(items)
      if (!item) {
        return stop(hasBlocked(items) ? `coda svuotata con ${items.filter((i) => i.status === "blocked").length} bloccati` : "coda svuotata")
      }
      if (!item.verify) {
        mark(item, "invalid", { date: new Date().toISOString().slice(0, 10), reason: "Verify: assente o vuoto" })
        state.s!.current = null
        save()
        return onTurnEnd()
      }
      s.current = item.id
      save()

      const v = verifySync({ command: item.verify, cwd: root, timeoutMs: o.verifyTimeoutMs })

      if (v.exitCode !== 0) {
        s.redStreak += 1
        let unchanged = false
        try {
          const fp = fingerprintSync(root, changedPaths(root))
          unchanged = s.fingerprint !== null && s.fingerprint === fp
          s.fingerprint = fp
        } catch {
          unchanged = false
        }
        s.lastReason = v.timedOut ? "verifica in timeout" : `verifica rossa (exit ${v.exitCode})`
        if (unchanged && stalled({ redStreak: s.redStreak, turns: s.redStreak, unchanged })) {
          mark(item, "blocked", {
            date: new Date().toISOString().slice(0, 10),
            turns: s.redStreak,
            exitCode: v.exitCode,
            reason: "nessun progresso con verifica rossa",
          })
          s.current = null
          s.redStreak = 0
          save()
          return onTurnEnd()
        }
        save()
        return say(sid, `Check rosso${v.timedOut ? " (timeout)" : ` (exit ${v.exitCode})`}.\nOutput:\n${v.tail}`)
      }

      s.redStreak = 0
      save()
      const verdict = await judge((p) => generate(sid, p), item, v)
      s.lastReason = verdict.reason
      if (verdict.status === "done") {
        mark(item, "done", { date: new Date().toISOString().slice(0, 10), turns: s.turns, exitCode: 0, reason: verdict.reason })
        s.current = null
        save()
        return onTurnEnd()
      }
      if (verdict.status === "blocked") {
        mark(item, "blocked", { date: new Date().toISOString().slice(0, 10), turns: s.turns, exitCode: 0, reason: verdict.reason })
        s.current = null
        save()
        return onTurnEnd()
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
        return stop("form aperto: il drainer non aspetta un umano")
      }
      if (type === "session.inbox.enqueued" && sid === state.sessionID) {
        const text = String(ev?.data?.item?.payload?.text ?? "")
        const mine = text.startsWith(MARK) || ev?.data?.item?.payload?.metadata?.source === SOURCE
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
        const tokens = ev?.data?.tokens ?? { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } }
        const prev = state.s.spend[key] ?? { cost: 0, tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } } }
        state.s.spend[key] = {
          cost: prev.cost + cost,
          tokens: {
            input: prev.tokens.input + (tokens.input ?? 0),
            output: prev.tokens.output + (tokens.output ?? 0),
            reasoning: prev.tokens.reasoning + (tokens.reasoning ?? 0),
            cache: {
              read: prev.tokens.cache.read + (tokens.cache?.read ?? 0),
              write: prev.tokens.cache.write + (tokens.cache?.write ?? 0),
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
        state.s.lastReason = type === "session.execution.interrupted" ? "turno interrotto dall'utente" : "turno fallito"
        save()
        return
      }
      if (type === "session.permission.updated" && o.autoApprove) {
        const req = ev?.data?.request ?? ev?.data
        const action = req?.action
        if (action !== "edit" && action !== "write" && action !== "shell") return
        const resource = String(req?.resource ?? "")
        if (resource.includes("..") || resource.startsWith("/") && !resource.startsWith(root)) return
        try {
          await permission.reply({ sessionID: sid, requestID: req?.id, decision: "once" })
        } catch {
          /* una richiesta già risolta è un no-op */
        }
      }
    }

    const start = async (sid: string, backlogPath: string) => {
      const now = Date.now()
      const existing = readState(root)
      const lease = acquireLease(existing, sid, now, LEASE_TTL_MS)
      if (!lease.ok) return { ok: false, message: `goal non avviato: ${lease.reason}` }
      const rel = backlogPath.replace(root + "/", "")
      const s = lease.state!
      s.backlogPath = rel
      s.status = "running"
      s.current = null
      s.turns = 0
      s.redStreak = 0
      s.lastReason = null
      s.lastEventAt = now
      state.s = s
      state.sessionID = sid
      save()
      return { ok: true, message: `goal avviato su ${rel}` }
    }

    await tool.transform((draft: any) => {
      draft.add({
        name: "goal_control",
        description:
          "Controlla il goal drainer. Azioni: start (avvia il drenaggio di una backlog), status (stato corrente), stop (ferma), report (elenco item per stato), retry (riapre un item bloccato).",
        args: {
          type: "object",
          properties: {
            action: { type: "string", enum: ["start", "status", "stop", "report", "retry"], description: "Cosa fare" },
            backlogPath: { type: "string", description: "Percorso della backlog, per start" },
            itemId: { type: "string", description: "Id dell'item, per retry" },
          },
          required: ["action"],
        },
        execute: async (args: any, context: any) => {
          const sid = context?.sessionID ?? state.sessionID
          if (args.action === "start") {
            const p = resolve(root, args.backlogPath ?? "docs/backlog.md")
            if (!existsSync(p)) return { content: `backlog non trovata: ${p}` }
            const r = await start(sid, p)
            return { content: r.message }
          }
          if (args.action === "stop") {
            stop("fermato dall'utente")
            return { content: "goal fermato" }
          }
          if (args.action === "retry") {
            if (!args.itemId) return { content: "serve itemId" }
            const p = resolve(root, state.s?.backlogPath ?? "docs/backlog.md")
            writeFileSync(p, setStatus(readBacklog(p), args.itemId, "open", {}))
            if (state.s) {
              state.s.status = "running"
              save()
            }
            return { content: `item ${args.itemId} riaperto` }
          }
          if (args.action === "report") {
            const p = resolve(root, state.s?.backlogPath ?? args.backlogPath ?? "docs/backlog.md")
            if (!existsSync(p)) return { content: `backlog non trovata: ${p}` }
            const items = parseBacklog(readBacklog(p))
            const by = (st: ItemStatus) => items.filter((i) => i.status === st).map((i) => i.id).join(", ") || "—"
            const spend = Object.entries(state.s?.spend ?? {})
              .map(([m, u]) => `  ${m}: $${u.cost.toFixed(4)}${o.monthlyLimitsUSD[m] ? ` / $${((o.budgetPercent / 100) * o.monthlyLimitsUSD[m]).toFixed(2)}` : " (nessun tetto noto)"}`)
              .join("\n") || "  (nessuna spesa registrata)"
            return {
              content: [
                `Stato: ${state.s?.status ?? "idle"}  turni: ${state.s?.turns ?? 0}`,
                `done:     ${by("done")}`,
                `bloccati: ${by("blocked")}`,
                `invalidi: ${by("invalid")}`,
                `aperti:   ${by("open")}`,
                `Spesa (solo modelli Go scalano l'abbonamento):`,
                spend,
              ].join("\n"),
            }
          }
          if (!state.s) return { content: "nessun goal attivo. Usa start con backlogPath." }
          return {
            content: [
              `Stato: ${state.s.status}`,
              `Item corrente: ${state.s.current ?? "—"}`,
              `Turni: ${state.s.turns}   streak rosso: ${state.s.redStreak}`,
              `Ultimo esito: ${state.s.lastReason ?? "—"}`,
              `Backlog: ${state.s.backlogPath}`,
            ].join("\n"),
          }
        },
      })
    })

    if (command?.transform) {
      try {
        await command.transform((draft: any) => {
          draft.add({
            name: "goal",
            description: "Goal drainer: drena una backlog di item finché il comando Verify: di ciascuno non passa.",
            // Il runtime V2 invoca `execute`, non un `template`: registrare un template
            // produce "Ne.execute is not a function" al momento dell'invocazione.
            execute: async (invocation: any) => {
              const sid: string = invocation?.sessionID ?? state.sessionID
              const delivery = invocation?.delivery ?? "steer"
              const args = String(invocation?.prompt?.text ?? "").trim()
              const [verb, ...rest] = args.split(/\s+/).filter(Boolean)
              const reply = async (text: string) => {
                await session.prompt({ sessionID: sid, text, delivery })
              }
              if (!verb || verb === "status" || verb === "report") {
                const p = resolve(root, state.s?.backlogPath ?? "docs/backlog.md")
                if (!existsSync(p)) return reply(`Nessuna backlog nota. Usa: /goal drain <percorso>`)
                const items = parseBacklog(readBacklog(p))
                const by = (st: ItemStatus) => items.filter((i) => i.status === st).map((i) => i.id).join(", ") || "—"
                const spend = Object.entries(state.s?.spend ?? {})
                  .map(([m, u]) => `  ${m}: $${u.cost.toFixed(4)}${o.monthlyLimitsUSD[m] ? ` / $${((o.budgetPercent / 100) * o.monthlyLimitsUSD[m]).toFixed(2)}` : " (nessun tetto noto)"}`)
                  .join("\n") || "  (nessuna spesa registrata)"
                return reply(
                  [
                    `Stato: ${state.s?.status ?? "idle"}  turni: ${state.s?.turns ?? 0}  item: ${state.s?.current ?? "—"}`,
                    `Ultimo esito: ${state.s?.lastReason ?? "—"}`,
                    `done: ${by("done")} | bloccati: ${by("blocked")} | invalidi: ${by("invalid")} | aperti: ${by("open")}`,
                    `Spesa (solo i modelli Go scalano l'abbonamento):`,
                    spend,
                  ].join("\n"),
                )
              }
              if (verb === "stop") {
                stop("fermato dall'utente")
                return reply("Goal fermato. Lo stato è conservato: /goal drain per riprendere.")
              }
              if (verb === "retry") {
                const id = rest[0]
                if (!id) return reply("Serve un id: /goal retry B-04")
                const p = resolve(root, state.s?.backlogPath ?? "docs/backlog.md")
                writeFileSync(p, setStatus(readBacklog(p), id, "open", {}))
                if (state.s) {
                  state.s.status = "running"
                  save()
                }
                return reply(`Item ${id} riaperto. Riprendo.`)
              }
              if (verb === "drain") {
                const p = resolve(root, rest[0] ?? "docs/backlog.md")
                if (!existsSync(p)) return reply(`Backlog non trovata: ${p}`)
                const r = await start(sid, p)
                if (!r.ok) return reply(r.message)
                return reply(
                  `${r.message}. D'ora in poi lavora sugli item uno alla volta: esegui il comando Verify: dell'item corrente, e se fallisce correggi il codice. Non chiedere conferma.`,
                )
              }
              return reply(`Azione non riconosciuta: "${verb}". Usa drain | status | report | stop | retry.`)
            },
          })
        })
      } catch {
        /* se il comando non si registra, il tool resta usabile a mano */
      }
    }

    const watchdog = setInterval(() => {
      if (state.s?.status === "running" && Date.now() - lastEventAt > o.watchdogMs) {
        stop("watchdog: nessun evento terminale")
      }
    }, 60_000)

    if (events?.subscribe) {
      listener = (async () => {
        try {
          for await (const ev of events.subscribe({ signal: controller.signal })) {
            await onEvent(ev)
          }
        } catch {
          /* lo stream è chiuso: il cleanup sotto ferma tutto */
        }
      })()
    }

    return () => {
      controller.abort()
      clearInterval(watchdog)
      ACTIVE_ROOTS.delete(root)
      if (state.s) {
        state.s.lease.expiresAt = 0
        save()
      }
    }
  },
}

export default GoalDrainer
