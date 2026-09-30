import { mkdir, rename, unlink, writeFile } from "node:fs/promises"
import { homedir } from "node:os"
import { join } from "node:path"
import { randomUUID } from "node:crypto"

// This is an OpenCode plugin. Only export the plugin: OpenCode treats each
// exported function as an entry point. No prompts, answers, keys or tool
// arguments are written to the status channel.
export default async function Codenotch({ client }) {
  const root = process.env.CODENOTCH_ACTIVITY_DIR ||
    join(homedir(), "Library", "Application Support", "Codenotch", "OpenCode")
  const instanceID = randomUUID()
  const file = join(root, `${instanceID}.json`)
  const startedAt = Math.round(Date.now() - process.uptime() * 1000)
  const sessions = new Map()
  const events = []
  const recorded = new Map()
  let sequence = 0
  let queue = Promise.resolve()
  let closed = false
  const text = (value, max = 200) => typeof value === "string" ? value.slice(0, max) : ""

  function get(id) {
    if (!sessions.has(id)) {
      // Bound long-lived servers without evicting a session asking for input.
      if (sessions.size >= 64) {
        const old = [...sessions.values()].find(s => s.state === "idle" || s.state === "ended")
        if (!old) return
        record({ ...old, state: "ended" })
        sessions.delete(old.sessionID)
        recorded.delete(old.sessionID)
      }
      sessions.set(id, { sessionID: id, parentID: null, title: "OpenCode",
        providerID: "", modelID: "", state: "idle", since: Date.now(),
        pending: new Map(), failed: false })
    }
    return sessions.get(id)
  }

  function snapshot(s) {
    return { sessionID: s.sessionID, parentID: s.parentID, title: s.title,
      providerID: s.providerID, modelID: s.modelID, state: s.state,
      reason: s.state === "waiting" ? [...s.pending.values()][0] : null, since: s.since }
  }

  function record(s) {
    const value = snapshot(s)
    const serialized = JSON.stringify(value)
    if (recorded.get(s.sessionID) === serialized) return
    recorded.set(s.sessionID, serialized)
    events.push({ sequence: ++sequence, at: Date.now(), session: value })
    if (events.length > 256) events.splice(0, events.length - 256)
  }

  function state(s, value) {
    if (s.state !== value) {
      s.state = value
      s.since = Date.now()
    }
    record(s)
  }

  async function lookup(operation) {
    let timeout
    try {
      return await Promise.race([
        Promise.resolve().then(operation).catch(() => null),
        new Promise(resolve => { timeout = setTimeout(() => resolve(null), 1500) }),
      ])
    } finally {
      clearTimeout(timeout)
    }
  }

  async function metadata(s) {
    // Metadata may arrive after busy. Re-publish the current state once its
    // provider is known, so a fast turn still has an observable busy crossing.
    const before = JSON.stringify(snapshot(s))
    if (!s.loaded) {
      const result = await lookup(() => client.session.get({ path: { id: s.sessionID } }))
      const info = result?.data
      if (info) {
        s.title = text(info.title) || "OpenCode"
        s.parentID = text(info.parentID) || null
        s.loaded = true
      }
    }
    if (!s.providerID) {
      const result = await lookup(() => client.session.messages({ path: { id: s.sessionID }, query: { limit: 4 } }))
      for (const message of [...(result?.data || [])].reverse()) {
        const info = message.info
        const provider = info?.providerID || info?.model?.providerID
        if (!provider) continue
        s.providerID = text(provider)
        s.modelID = text(info.modelID || info.model?.modelID)
        break
      }
    }
    if (JSON.stringify(snapshot(s)) !== before) record(s)
  }

  async function save() {
    await mkdir(root, { recursive: true, mode: 0o700 })
    const body = JSON.stringify({ version: 1, instanceID, pid: process.pid, startedAt,
      sequence, sessions: [...sessions.values()].filter(s => s.state !== "ended").map(snapshot), events })
    const temporary = `${file}.tmp`
    await writeFile(temporary, body, { mode: 0o600 })
    await rename(temporary, file)
  }

  async function consume(event) {
    const p = event?.properties || {}
    const type = event?.type
    const id = text(p.sessionID || p.info?.sessionID ||
      (type === "session.updated" || type === "session.deleted" ? p.info?.id : ""))
    if (!id) return
    const relevant = ["session.status", "session.error", "session.deleted", "session.updated",
      "message.updated", "permission.asked", "permission.replied", "question.asked",
      "question.replied", "question.rejected", "permission.v2.asked", "permission.v2.replied",
      "question.v2.asked", "question.v2.replied", "question.v2.rejected"]
    if (!relevant.includes(type)) return
    const s = get(id)
    if (!s) return
    const start = sequence
    if (type === "message.updated") {
      const info = p.info || {}
      const provider = info.providerID || info.model?.providerID
      if (provider) {
        const model = text(info.modelID || info.model?.modelID)
        if (s.providerID !== text(provider) || s.modelID !== model) {
          s.providerID = text(provider)
          s.modelID = model
          record(s)
        }
      }
    } else if (type === "session.updated") {
      s.title = text(p.info?.title) || s.title
      s.parentID = text(p.info?.parentID) || null
      record(s)
    } else if (type === "session.deleted" || type === "session.error") {
      s.failed = true
      s.pending.clear()
      state(s, "ended")
    } else if (type === "session.status") {
      const status = p.status?.type
      if (status === "busy" || status === "retry") {
        s.failed = false
        state(s, s.pending.size ? "waiting" : "busy")
      } else if (status === "idle") {
        s.pending.clear()
        state(s, s.failed ? "ended" : "idle")
      }
    } else if (type.endsWith(".asked")) {
      if (!text(p.id)) return
      s.pending.set(text(p.id), type.startsWith("permission") ? "approval" : "question")
      state(s, "waiting")
    } else {
      if (!s.pending.has(text(p.requestID))) return
      s.pending.delete(text(p.requestID))
      // Reply events remove requests; they do not themselves complete a turn.
      state(s, s.pending.size ? "waiting" : (s.failed ? "ended" : "busy"))
    }
    if (s.state !== "ended") await metadata(s)
    if (sequence !== start) await save()
  }

  return {
    event: ({ event }) => {
      if (closed) return queue
      // OpenCode dispatches hook promises without awaiting them. Serializing
      // preserves event order and prevents overlapping atomic file writes.
      queue = queue.then(() => consume(event)).catch(async () => {
        // Status reporting must never break an agent turn. A later event can
        // retry the write. Withdraw a stale busy file if publication failed.
        await unlink(file).catch(() => {})
      })
      return queue
    },
    dispose: async () => {
      closed = true
      await queue
      await unlink(file).catch(() => {})
      await unlink(`${file}.tmp`).catch(() => {})
    },
  }
}
