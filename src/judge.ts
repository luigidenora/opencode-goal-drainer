import type { Item } from "./backlog.ts"
import type { VerifyResult } from "./verifier.ts"

export type Verdict = { status: "done" | "continue" | "blocked"; reason: string }

const DONE = "done"
const CONT = "continue"
const BLOCK = "blocked"

export function buildPrompt(item: Item, v: VerifyResult): string {
  const accepts = item.accepts.length > 0 ? item.accepts.map((a) => "- " + a).join("\n") : "- (nessun criterio esplicito)"
  const tail = v.tail.trim() === "" ? "(nessun output)" : v.tail
  return [
    "Obiettivo: " + item.title,
    "",
    "Criteri di accettazione:",
    accepts,
    "",
    "Comando di verifica: " + (item.verify ?? "(assente)"),
    "Esito: exit " + (v.timedOut ? "timeout (comando ucciso)" : String(v.exitCode)),
    "",
    "Output:",
    tail,
    "",
    "Rispondi SOLO con questo JSON, nient'altro:",
    '{"status":"done|continue|blocked","reason":"max 120 caratteri"}',
    "",
    "Regole:",
    "- done solo se ogni criterio elencato sopra è soddisfatto e dimostrato da quanto precede.",
    "- blocked solo se manca un prerequisito che nessun lavoro può creare (dipendenza assente, dati assenti, permesso negato).",
    "- NON usare blocked per dire che non hai ancora lavorato.",
    "- continue per tutto il resto; reason deve indicare la prossima azione concreta.",
  ].join("\n")
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
      if (status !== DONE && status !== CONT && status !== BLOCK) continue
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
  item: Item,
  v: VerifyResult,
): Promise<Verdict> {
  const prompt = buildPrompt(item, v)
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const text = await generate(prompt)
      const verdict = parseVerdict(text ?? "")
      if (verdict) return verdict
    } catch {
      // un errore del giudice non può mai produrre done
    }
  }
  return { status: "continue", reason: "giudice non raggiungibile" }
}
