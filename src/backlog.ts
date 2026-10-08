export type ItemStatus = "open" | "done" | "blocked" | "invalid"

export interface Item {
  id: string
  title: string
  status: ItemStatus
  accepts: string[]
  verify: string | null
  evidence: { date?: string; turns?: number; exitCode?: number | null; reason?: string }
}

const MARKERS: Record<string, ItemStatus> = {
  " ": "open",
  x: "done",
  "!": "blocked",
  "?": "invalid",
}

function stripEvidence(block: string): { body: string; evidence: Item["evidence"] } {
  const lines = block.split("\n")
  const evidence: Item["evidence"] = {}
  const body: string[] = []
  let inEvidence = false
  for (const line of lines) {
    if (/^evidence:/i.test(line.trim())) {
      inEvidence = true
      continue
    }
    if (inEvidence) {
      const m = /^(\w+):\s*(.*)$/.exec(line.trim())
      if (m) {
        const key = m[1]
        const value = m[2].replace(/^["']|["']$/g, "")
        if (key === "exitCode") evidence.exitCode = Number(value)
        else if (key === "turns") evidence.turns = Number(value)
        else if (key === "date") evidence.date = value
        else if (key === "reason") evidence.reason = value
      }
      continue
    }
    body.push(line)
  }
  return { body: body.join("\n"), evidence }
}

export function parseBacklog(markdown: string): Item[] {
  const blocks = markdown.split(/^## /m).slice(1)
  const items: Item[] = []
  for (const raw of blocks) {
    const header = raw.slice(0, raw.indexOf("\n") === -1 ? raw.length : raw.indexOf("\n"))
    const m = /^(\[[ x!?]\])\s*(\S+)\s*(?:—|-)?\s*(.*)$/.exec(header.trim())
    if (!m) continue
    const { body, evidence } = stripEvidence(raw)
    const accepts: string[] = []
    let verify: string | null = null
    let inAccepts = false
    for (const line of body.split("\n").slice(1)) {
      const t = line.trim()
      if (/^Accetta:/i.test(t)) {
        inAccepts = true
        continue
      }
      if (/^Verify:/i.test(t)) {
        inAccepts = false
        const rest = t.replace(/^Verify:\s*/i, "")
        const ticks = rest.match(/`([^`]*)`/)
        verify = (ticks ? ticks[1] : rest).trim()
        continue
      }
      if (t.startsWith("- ")) {
        if (inAccepts) accepts.push(t.slice(2).trim())
        continue
      }
      if (t === "") continue
      inAccepts = false
    }
    items.push({
      id: m[2],
      title: m[3].trim(),
      status: MARKERS[m[1][1]] ?? "invalid",
      accepts,
      verify: verify && verify.length > 0 ? verify : null,
      evidence,
    })
  }
  return items
}

export function renderEvidence(e: Item["evidence"]): string {
  const parts: string[] = []
  if (e.date) parts.push(`date: ${e.date}`)
  if (e.turns !== undefined) parts.push(`turns: ${e.turns}`)
  if (e.exitCode !== undefined && e.exitCode !== null) parts.push(`exitCode: ${e.exitCode}`)
  if (e.reason) parts.push(`reason: ${e.reason}`)
  return parts.join("\n")
}

export function setStatus(
  markdown: string,
  id: string,
  status: ItemStatus,
  evidence: Item["evidence"],
): string {
  const marker = status === "done" ? "x" : status === "blocked" ? "!" : status === "invalid" ? "?" : " "
  const lines = markdown.split("\n")
  // Trova i confini del blocco dell'item: dalla sua intestazione alla prossima
  // intestazione di pari livello, o alla fine del documento.
  let start = -1
  let end = lines.length
  for (let i = 0; i < lines.length; i++) {
    const h = /^## \[[ x!?]\]\s*(\S+)/.exec(lines[i])
    if (!h) continue
    if (start === -1 && h[1] === id) {
      start = i
      continue
    }
    if (start !== -1) {
      end = i
      break
    }
  }
  if (start === -1) return markdown

  const head = lines[start].replace(/^## \[[ x!?]\]\s*\S+/, `## [${marker}] ${id}`)
  const body = lines
    .slice(start + 1, end)
    .filter((l) => !/^evidence:/i.test(l.trim()))
    .filter((l) => !/^\s*(date|turns|exitCode|reason):/.test(l))
  while (body.length > 0 && body[body.length - 1].trim() === "") body.pop()

  const tail: string[] = []
  if (evidence && Object.keys(evidence).length > 0) {
    tail.push("", "evidence:", ...renderEvidence(evidence).split("\n"))
  }

  const out = [...lines.slice(0, start), head, ...body, ...tail, "", ...lines.slice(end)]
  // normalizza: una sola riga vuota prima della prossima intestazione
  return out.join("\n").replace(/\n{3,}/g, "\n\n").replace(/\n+$/, "\n")
}

export function nextOpen(items: Item[]): Item | null {
  for (const i of items) if (i.status === "open" || i.status === "invalid") return i
  return null
}

export function hasBlocked(items: Item[]): boolean {
  return items.some((i) => i.status === "blocked")
}
