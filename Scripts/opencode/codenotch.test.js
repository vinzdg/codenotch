import test from "node:test"
import assert from "node:assert/strict"
import { mkdtemp, readdir, readFile, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import plugin from "../../Sources/Resources/codenotch-opencode.mjs"

async function fixture(t, options = {}) {
  const root = await mkdtemp(join(tmpdir(), "codenotch-opencode-"))
  const previous = process.env.CODENOTCH_ACTIVITY_DIR
  process.env.CODENOTCH_ACTIVITY_DIR = root
  const hooks = await plugin({ directory: "/tmp/project", client: { session: {
    get: async () => ({ data: { title: "Synthetic test", parentID: options.parentID } }),
    messages: async () => ({ data: [{ info: { role: "user", model: { providerID: "llamacpp", modelID: "qwen" } } }] }),
  } } })
  t.after(async () => {
    await hooks.dispose()
    if (previous === undefined) delete process.env.CODENOTCH_ACTIVITY_DIR
    else process.env.CODENOTCH_ACTIVITY_DIR = previous
    await rm(root, { recursive: true, force: true })
  })
  return {
    hooks, root,
    send: (type, properties = {}) => hooks.event({ event: { type, properties: { sessionID: "ses_test", ...properties } } }),
    read: async () => {
      const file = (await readdir(root)).find(name => name.endsWith(".json"))
      return file ? JSON.parse(await readFile(join(root, file), "utf8")) : null
    },
  }
}

test("structured busy, approvals, questions, and idle preserve ordered transitions", async t => {
  const f = await fixture(t)
  // OpenCode does not await event-hook promises. Exercise the same dispatch.
  const operations = [
    f.send("session.status", { status: { type: "busy" } }),
    f.send("permission.asked", { id: "per_1", metadata: { secret: "NEVER_WRITE" } }),
    f.send("session.status", { status: { type: "busy" } }),
    f.send("question.asked", { id: "que_1", questions: ["NEVER_WRITE"] }),
    f.send("permission.replied", { requestID: "per_1" }),
    f.send("question.replied", { requestID: "que_1", answers: ["NEVER_WRITE"] }),
    f.send("session.status", { status: { type: "idle" } }),
  ]
  await Promise.all(operations)
  const body = await f.read()
  assert.equal(body.version, 1)
  assert.equal(body.sessions[0].state, "idle")
  assert.equal(body.sessions[0].providerID, "llamacpp")
  assert.equal(body.sessions[0].modelID, "qwen")
  assert.ok(body.events.some(e => e.session.state === "waiting" && e.session.reason === "approval"))
  assert.ok(body.events.some(e => e.session.state === "waiting" && e.session.reason === "question"))
  assert.equal(body.events.at(-1).session.state, "idle")
  assert.ok(!JSON.stringify(body).includes("NEVER_WRITE"))
  assert.deepEqual(body.events.map(e => e.sequence), body.events.map((_, i) => i + 1))
  const count = body.sequence
  await f.send("session.idle") // deprecated duplicate must not notify twice
  assert.equal((await f.read()).sequence, count)
})

test("v2 requests and rejections restore busy only after the last request", async t => {
  const f = await fixture(t)
  await f.send("session.status", { status: { type: "busy" } })
  await f.send("permission.v2.asked", { id: "per_a", action: "edit", resources: ["NEVER_WRITE"] })
  await f.send("question.v2.asked", { id: "que_a" })
  await f.send("permission.v2.replied", { requestID: "per_a", reply: "reject" })
  assert.equal((await f.read()).sessions[0].state, "waiting")
  await f.send("question.v2.rejected", { requestID: "que_a" })
  assert.equal((await f.read()).sessions[0].state, "busy")
  const count = (await f.read()).sequence
  await f.send("permission.replied", { requestID: "unknown" })
  assert.equal((await f.read()).sequence, count)
})

test("errors and aborts withdraw a session without reporting successful idle", async t => {
  const f = await fixture(t)
  await f.send("session.status", { status: { type: "busy" } })
  await f.send("session.error", { error: { name: "MessageAbortedError" } })
  await f.send("session.status", { status: { type: "idle" } })
  let body = await f.read()
  assert.equal(body.sessions.length, 0)
  assert.equal(body.events.at(-1).session.state, "ended")
  await f.send("session.status", { status: { type: "busy" } })
  assert.equal((await f.read()).sessions[0].state, "busy")
  await f.hooks.dispose()
  assert.deepEqual(await readdir(f.root), [])
})

test("journal is bounded and can preserve new turns after rollover", async t => {
  const f = await fixture(t)
  for (let i = 0; i < 270; i++) {
    await f.send("session.status", { status: { type: i % 2 ? "idle" : "busy" } })
  }
  const body = await f.read()
  assert.equal(body.events.length, 256)
  assert.equal(body.events.at(-1).sequence, body.sequence)
  assert.equal(body.events.at(-1).session.state, body.sessions[0].state)
})

test("session limit evicts idle history while retaining an approval request", async t => {
  const f = await fixture(t)
  await f.send("permission.asked", { id: "per_waiting" })
  for (let i = 0; i < 70; i++) {
    await f.send("session.status", { sessionID: `ses_${i}`, status: { type: "idle" } })
  }
  const body = await f.read()
  assert.equal(body.sessions.length, 64)
  assert.equal(body.sessions.find(s => s.sessionID === "ses_test").state, "waiting")
  assert.ok(body.events.some(e => e.session.state === "ended"))
})

test("message model identity and parent session are retained, message text is omitted", async t => {
  const f = await fixture(t, { parentID: "ses_parent" })
  await f.send("message.updated", { info: { sessionID: "ses_test", providerID: "local-runtime", modelID: "qwen-local", content: "NEVER_WRITE" } })
  await f.send("session.status", { status: { type: "busy" } })
  const body = await f.read()
  assert.equal(body.sessions[0].providerID, "local-runtime")
  assert.equal(body.sessions[0].parentID, "ses_parent")
  assert.ok(!JSON.stringify(body).includes("NEVER_WRITE"))
})
