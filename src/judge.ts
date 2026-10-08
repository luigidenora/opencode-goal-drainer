export interface GoalSpec {
  /** La condizione di completamento, in prosa. È il cuore del goal generico. */
  condition: string
  /** Criteri espliciti, se la condizione li ha. */
  accepts?: string[]
  /** Comando deterministico opzionale: se c'è, il giudice vede solo un gate verde. */
  verify?: string | null
}

export type Verdict = { status: "done" | "continue" | "blocked"; reason: string }

export function buildPrompt(spec: GoalSpec, v: { exitCode: number; tail: string; timedOut: boolean } | null): string {
  const lines: string[] = ["Obiettivo:", spec.condition, ""]
  if (spec.accepts && spec.accepts.length > 0) {
    lines.push("Criteri di accettazione:")
    for (const a of spec.accepts) lines.push("- " + a)
    lines.push("")
  }
  if (spec.verify) {
    lines.push("Comando di verifica: " + spec.verify)
    lines.push(
      "Esito: " + (v ? (v.timedOut ? "timeout (comando ucciso)" : "exit " + v.exitCode) : "non eseguito"),
    )
    lines.push("")
    if (v && v.tail.trim() !== "") {
      lines.push("Output:")
      lines.push(v.tail)
      lines.push("")
    }
  }
  lines.push(
    "Rispondi SOLO con questo JSON, nient'altro:",
    '{"status":"done|continue|blocked","reason":"max 120 caratteri"}',
    "",
    "Regole:",
    "- done solo se la condizione è soddisfatta e dimostrabile da quanto sopra e da quello che hai fatto finora.",
    "- blocked solo se manca un prerequisito che nessun lavoro può creare (dipendenza assente, dati assenti, permesso negato, credenziali mancanti).",
    "- NON usare blocked per dire che non hai ancora lavorato o che è difficile.",
    "- continue per tutto il resto; reason deve indicare la prossima azione concreta.",
  )
  return lines.join("\n")
}

export function parseVerdict(text: string): Verdict | null {
  const candidates: string[] = []
  const trimmed = text.trim()
  candidates.push(trimmed)
  const first = trimmed.indexOf("{")
  const last = trimmed.lastIndexOf("}")
  if (first !== -1 && last > first) candidates.push(trimmed.slice(first, last + 1))
  for (const m of trimmed.matchAll(/```(?:json)?\s*([\s\S]*?)```/g)) candidates.push(m[1].trim())
  for (const c of candidates) {
    try {
      const obj = JSON.parse(c)
      if (!obj || typeof obj !== "object") continue
      const status = obj.status
      const reason = obj.reason
      if (status !== "done" && status !== "continue" && status !== "blocked") continue
      if (typeof reason !== "string" || reason.trim() === "") continue
      return { status, reason: reason.trim().slice(0, 200) }
    } catch {
      continue
    }
  }
  return null
}

export async function judge(
  generate: (prompt: string) => Promise<string>,
  spec: GoalSpec,
  v: { exitCode: number; tail: string; timedOut: boolean } | null,
): Promise<Verdict> {
  const prompt = buildPrompt(spec, v)
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const text = await generate(prompt)
      const verdict = parseVerdict(text ?? "")
      if (verdict) return verdict
    } catch {
      /* un errore del giudice non può mai produrre done */
    }
  }
  return { status: "continue", reason: "giudice non raggiungibile" }
}

/**
 * Estrae un comando di verifica dalla condizione, se l'utente ne ha scritto uno.
 * Forme accettate: `Verify: <cmd>`, `` `cmd` `` come unica riga, oppure
 * "finché <cmd> non esce 0".
 */
export function extractVerify(condition: string): string | null {
  const m = /verify:\s*`?([^`\n]+)`?/i.exec(condition)
  if (m) return m[1].trim()
  const fence = /```(?:\w+)?\n([\s\S]*?)```/.exec(condition)
  if (fence) return fence[1].trim()
  return null
}
