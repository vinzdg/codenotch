// Optional integration test: real OpenCode, synthetic localhost model, no
// credentials or inference service. All OpenCode state lives in a temp tree.
import assert from "node:assert/strict"
import http from "node:http"
import { spawn } from "node:child_process"
import { mkdtemp, mkdir, readFile, readdir, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { fileURLToPath } from "node:url"

const root = await mkdtemp(join(tmpdir(), "codenotch-opencode-smoke-"))
const activity = join(root, "activity")
const plugin = fileURLToPath(new URL("../../Sources/Resources/codenotch-opencode.mjs", import.meta.url))
const plugins = join(root, "config", "opencode", "plugins")
await mkdir(plugins, { recursive: true })
// Exercise the same global .js auto-discovery as the Settings installer.
await writeFile(join(plugins, "codenotch.js"), await readFile(plugin))
const delay = ms => new Promise(resolve => setTimeout(resolve, ms))
const mock = http.createServer(async (req, res) => {
  let raw = ""
  for await (const chunk of req) raw += chunk
  const body = JSON.parse(raw || "{}")
  const messages = body.messages || []
  const last = messages.at(-1)
  const content = typeof last?.content === "string" ? last.content : JSON.stringify(last?.content)
  let tool
  if (last?.role === "user" && content?.includes("SMOKE_PERMISSION")) {
    tool = { id: "call_smoke", type: "function", function: { name: "bash", arguments: JSON.stringify({ command: "pwd", description: "Synthetic approval test" }) } }
  }
  if (last?.role === "user" && content?.includes("SMOKE_QUESTION")) {
    tool = { id: "call_smoke", type: "function", function: { name: "question", arguments: JSON.stringify({ questions: [{ header: "Test", question: "Synthetic test?", options: [{ label: "Continue", description: "Finish this synthetic test" }] }] }) } }
  }
  const delta = tool ? { tool_calls: [{ index: 0, ...tool }] } : { content: "Synthetic completion." }
  const finish = tool ? "tool_calls" : "stop"
  const chunk = (delta, finish_reason = null) => ({ id: "chatcmpl-smoke", object: "chat.completion.chunk", created: 1, model: "model", choices: [{ index: 0, delta, finish_reason }] })
  if (body.stream) {
    res.writeHead(200, { "Content-Type": "text/event-stream" })
    res.write(`data: ${JSON.stringify(chunk({ role: "assistant" }))}\n\n`)
    res.write(`data: ${JSON.stringify(chunk(delta))}\n\n`)
    res.write(`data: ${JSON.stringify(chunk({}, finish))}\n\n`)
    res.end("data: [DONE]\n\n")
  } else {
    res.writeHead(200, { "Content-Type": "application/json" })
    res.end(JSON.stringify({ id: "chatcmpl-smoke", object: "chat.completion", created: 1, model: "model", choices: [{ index: 0, message: { role: "assistant", content: "Synthetic completion." }, finish_reason: "stop" }], usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 } }))
  }
})
await new Promise(resolve => mock.listen(0, "127.0.0.1", resolve))
const allocator = http.createServer()
await new Promise(resolve => allocator.listen(0, "127.0.0.1", resolve))
const port = allocator.address().port
await new Promise(resolve => allocator.close(resolve))
const config = {
  enabled_providers: ["synthetic"], model: "synthetic/model",
  permission: { bash: "ask", question: "allow" },
  provider: { synthetic: { npm: "@ai-sdk/openai-compatible", name: "Synthetic",
    options: { baseURL: `http://127.0.0.1:${mock.address().port}/v1`, apiKey: "synthetic" },
    models: { model: { name: "Synthetic", tool_call: true, limit: { context: 8192, output: 1024 } } } } },
}
await mkdir(join(root, "project"))
const child = spawn(process.env.OPENCODE_BIN || "opencode", ["serve", "--hostname", "127.0.0.1", "--port", String(port)], {
  cwd: join(root, "project"), stdio: ["ignore", "pipe", "pipe"], env: {
    ...process.env,
    XDG_CONFIG_HOME: join(root, "config"), XDG_DATA_HOME: join(root, "data"),
    XDG_CACHE_HOME: join(root, "cache"), XDG_STATE_HOME: join(root, "state"),
    OPENCODE_CONFIG_CONTENT: JSON.stringify(config), CODENOTCH_ACTIVITY_DIR: activity,
    OPENCODE_DISABLE_DEFAULT_PLUGINS: "true", OPENCODE_DISABLE_CLAUDE_CODE: "true",
    OPENCODE_DISABLE_EXTERNAL_SKILLS: "true", OPENCODE_DISABLE_LSP_DOWNLOAD: "true",
    OPENCODE_DISABLE_MODELS_FETCH: "true", OPENCODE_DISABLE_AUTOUPDATE: "true",
    OPENCODE_SERVER_PASSWORD: "", OPENCODE_SERVER_USERNAME: "",
  },
})
let logs = ""
child.stdout.on("data", data => { logs += data })
child.stderr.on("data", data => { logs += data })
async function api(path, body) {
  const response = await fetch(`http://127.0.0.1:${port}${path}`, {
    ...(body ? { method: "POST", body: JSON.stringify(body), headers: { "Content-Type": "application/json" } } : {}),
    signal: AbortSignal.timeout(30_000),
  })
  if (!response.ok) throw new Error(`${path}: ${response.status} ${await response.text()}`)
  return response.status === 204 ? null : response.json()
}
async function until(fn) {
  const end = Date.now() + 25_000
  while (Date.now() < end) {
    const result = await fn().catch(() => null)
    if (result) return result
    await delay(100)
  }
  throw new Error("Timed out waiting for synthetic integration state")
}
async function envelope() {
  const names = await readdir(activity)
  return JSON.parse(await readFile(join(activity, names.find(n => n.endsWith(".json"))), "utf8"))
}
try {
  await until(() => api("/global/health"))
  for (const mode of ["DONE", "PERMISSION", "QUESTION"]) {
    const session = await api("/session", { title: `Synthetic ${mode}` })
    await api(`/session/${session.id}/prompt_async`, { model: { providerID: "synthetic", modelID: "model" }, parts: [{ type: "text", text: `SMOKE_${mode}` }] })
    if (mode !== "DONE") {
      const route = mode === "PERMISSION" ? "permission" : "question"
      const pending = await until(async () => (await api(`/${route}`)).find(p => p.sessionID === session.id))
      await until(async () => (await envelope()).sessions.some(s => s.sessionID === session.id && s.state === "waiting"))
      await api(`/${route}/${pending.id}/reply`, mode === "PERMISSION" ? { reply: "reject" } : { answers: [["Continue"]] })
    }
    const result = await until(async () => {
      const value = await envelope()
      const started = value.events.some(e => e.session.sessionID === session.id && e.session.state === "busy")
      return started && value.sessions.some(s => s.sessionID === session.id && s.state === "idle") ? value : null
    })
    const states = result.events.filter(e => e.session.sessionID === session.id).map(e => e.session.state)
    assert.ok(states.includes("busy"))
    if (mode !== "DONE") assert.ok(states.includes("waiting"))
    assert.equal(states.at(-1), "idle")
    console.log(`${mode}: ${states.join(" → ")}`)
    await writeFile(join(root, `${mode.toLowerCase()}.json`), JSON.stringify(result, null, 2))
  }
  console.log(`Smoke test passed; synthetic evidence: ${root}`)
} finally {
  await writeFile(join(root, "opencode.log"), logs)
  child.kill("SIGTERM")
  mock.closeAllConnections()
  mock.close()
  console.log(`Isolated test directory: ${root}`)
}
