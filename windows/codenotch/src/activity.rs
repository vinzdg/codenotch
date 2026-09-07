//! "Is it working?" for the non-Claude providers (Claude's local sessions go through the hooks +
//! transcript-watcher engine, not here).
//!
//! None of the three has a state field like Claude Code's, so each is labelled with whatever it
//! can honestly provide (the same trade-off upstream made):
//!   - Cursor: the `composerHeaders` rows (JSON) in the editor's `state.vscdb` — `unfinishedRunAt`
//!     is set for the duration of a run and cleared when it ends; `hasBlockingPendingActions` /
//!     `hasPendingPlan` = waiting on you. This is **real state**. The database is in WAL mode, so
//!     it must be opened as a plain read-only connection (immutable ignores the WAL and shows the
//!     world as of the last checkpoint).
//!   - Codex: the desktop app keeps turn state in `thread_turns` inside
//!     `~/.codex/thread_history_1.sqlite` (status = inProgress with an empty completed_at = running)
//!     — real state. The CLI / VS Code extension fall back to classifying the last entry of the
//!     rollout, with a silence threshold that depends on the entry type.
//!   - Claude cloud sessions: no local transcript, so they are inferred from the desktop app's
//!     network throughput (marked ~).
//!   - Antigravity: transcript.jsonl is appended during a run (each step is written only once it
//!     completes, so status is always DONE and useless); written within the last 45 s = working
//!     (the model can think for a long time between steps, hence the wide window).
//! Polled every 2 s (upstream cadence), broadcast only on change. Cost discipline: database
//! connections stay open, nothing is re-queried unless the file's mtime changed, the rollout tail
//! is re-read only when its mtime changed, PowerShell runs only occasionally to find the network
//! process pid, and the thread runs at lowered priority.

use crate::AppState;
use serde::Serialize;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager};

const INTERVAL: Duration = Duration::from_secs(2);
const ANTIGRAVITY_STALE_MS: u64 = 45_000;

#[derive(Clone, Serialize, Debug, PartialEq)]
pub struct Activity {
    /// Provider id other than claude: codex / cursor / gemini
    pub provider: String,
    /// busy | waiting
    pub state: String,
    pub name: String,
    pub detail: String,
    /// ms epoch
    pub since: u64,
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn mtime_ms(p: &std::path::Path) -> Option<u64> {
    std::fs::metadata(p)
        .ok()?
        .modified()
        .ok()?
        .duration_since(UNIX_EPOCH)
        .ok()
        .map(|d| d.as_millis() as u64)
}


/// Persistent connection + change gating: the query runs again only when the database file (or its
/// -wal) changed mtime; otherwise the last result is reused. Cursor's state.vscdb is over 2 GB, and
/// reopening it every 2 s for a table scan slowed the whole machine (typing lagged).
struct DbCache {
    path: std::path::PathBuf,
    conn: Option<rusqlite::Connection>,
    sig: (u64, u64),
    last: Vec<Activity>,
    checked_once: bool,
}

impl DbCache {
    fn new(path: std::path::PathBuf) -> Self {
        Self { path, conn: None, sig: (0, 0), last: Vec::new(), checked_once: false }
    }
    fn signature(&self) -> (u64, u64) {
        let wal = {
            let mut o = self.path.as_os_str().to_owned();
            o.push("-wal");
            std::path::PathBuf::from(o)
        };
        (mtime_ms(&self.path).unwrap_or(0), mtime_ms(&wal).unwrap_or(0))
    }
    /// Calls f only when something changed (or on the first run); f returning None means the query failed → drop the connection and reopen next time
    fn refresh<F: FnOnce(&rusqlite::Connection) -> Option<Vec<Activity>>>(&mut self, f: F) -> Vec<Activity> {
        let sig = self.signature();
        if self.checked_once && sig == self.sig {
            return self.last.clone();
        }
        self.sig = sig;
        self.checked_once = true;
        if self.conn.is_none() {
            self.conn = open_ro(&self.path);
        }
        let Some(conn) = self.conn.as_ref() else {
            self.last.clear();
            return Vec::new();
        };
        match f(conn) {
            Some(v) => self.last = v,
            None => {
                self.conn = None;
                self.last.clear();
            }
        }
        self.last.clone()
    }
}

/// Everything the probe thread keeps between ticks
struct Ctx {
    cursor: DbCache,
    codex_turns: DbCache,
    codex_names: Option<rusqlite::Connection>,
    rollout_path: Option<std::path::PathBuf>,
    rollout_checked_at: u64,
    rollout_sig: u64,
    rollout_last: Vec<Activity>,
}

impl Ctx {
    fn new() -> Self {
        let home = dirs::home_dir().unwrap_or_default();
        Self {
            cursor: DbCache::new(crate::cursor::store_url().unwrap_or_default()),
            codex_turns: DbCache::new(home.join(".codex").join("thread_history_1.sqlite")),
            codex_names: None,
            rollout_path: None,
            rollout_checked_at: 0,
            rollout_sig: 0,
            rollout_last: Vec::new(),
        }
    }
}

// ---------------- Cursor ----------------

fn open_ro(path: &std::path::Path) -> Option<rusqlite::Connection> {
    use rusqlite::OpenFlags;
    if !path.is_file() {
        return None;
    }
    rusqlite::Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX).ok()
}

fn cursor_activity(ctx: &mut Ctx) -> Vec<Activity> {
    ctx.cursor.refresh(|conn| {
        let mut stmt = conn.prepare("SELECT value FROM composerHeaders WHERE isArchived = 0 ORDER BY recency DESC LIMIT 40").ok()?;
        let rows = stmt.query_map([], |r| r.get::<_, String>(0)).ok()?;
        let mut out = Vec::new();
        for json in rows.flatten() {
            let Ok(v) = serde_json::from_str::<serde_json::Value>(&json) else { continue };
            if v.get("composerId").and_then(|x| x.as_str()).is_none() {
                continue;
            }
            let blocked = v.get("hasBlockingPendingActions").and_then(|x| x.as_bool()) == Some(true)
                || v.get("hasPendingPlan").and_then(|x| x.as_bool()) == Some(true);
            let running = v.get("unfinishedRunAt").and_then(|x| x.as_f64());
            let state = if blocked {
                "waiting"
            } else if running.is_some() {
                "busy"
            } else {
                continue; // forty idle past conversations are not forty things happening now
            };
            let since = running
                .or_else(|| v.get("lastUpdatedAt").and_then(|x| x.as_f64()))
                .or_else(|| v.get("createdAt").and_then(|x| x.as_f64()))
                .map(|ms| ms as u64)
                .unwrap_or_else(now_ms);
            out.push(Activity {
                provider: "cursor".into(),
                state: state.into(),
                name: v.get("name").and_then(|x| x.as_str()).unwrap_or("Untitled chat").to_string(),
                detail: if blocked {
                    "needs your input".into()
                } else {
                    v.get("subtitle").and_then(|x| x.as_str()).unwrap_or("Working").to_string()
                },
                since,
            });
        }
        out.sort_by(|a, b| b.since.cmp(&a.since));
        Some(out)
    })
}

// ---------------- Codex ----------------

/// The last meaningful entry at the tail of a rollout says which step Codex is on.
/// Lines look like {"timestamp","type":"response_item"|"turn_context"|"event_msg"|…,"payload":{…}};
/// task_started/task_complete events are not always written, so the decision rests on the entry
/// type plus how long the file has been silent:
///   function call (a tool is running, or waiting for your approval) → busy, for up to 10 minutes;
///   tool output / user message / turn context / reasoning → the model is deciding the next step,
///   busy while silent for < 120 s (long thinking has to be tolerated);
///   assistant message → could be the final answer or narration along the way, busy while silent for < 4 s;
///   turn_aborted → idle. Bookkeeping lines such as token_count are skipped.
#[derive(Clone, Copy, PartialEq, Debug)]
enum CodexStep {
    Tool,
    Thinking,
    AsstMsg,
    Aborted,
}

fn codex_last_step(text: &str) -> Option<(CodexStep, u64)> {
    for line in text.lines().rev().filter(|l| !l.trim().is_empty()) {
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else { continue };
        let ts = v
            .get("timestamp")
            .and_then(|x| x.as_str())
            .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
            .map(|d| d.timestamp_millis().max(0) as u64)
            .unwrap_or(0);
        let kind = v.get("type").and_then(|x| x.as_str()).unwrap_or("");
        let p = v.get("payload").cloned().unwrap_or(serde_json::Value::Null);
        let pt = p.get("type").and_then(|x| x.as_str()).unwrap_or("");
        let step = match kind {
            "turn_context" => Some(CodexStep::Thinking),
            "response_item" => match pt {
                "function_call" | "local_shell_call" | "custom_tool_call" | "web_search_call" => Some(CodexStep::Tool),
                "function_call_output" | "custom_tool_call_output" | "reasoning" => Some(CodexStep::Thinking),
                "message" => match p.get("role").and_then(|x| x.as_str()).unwrap_or("") {
                    "assistant" => Some(CodexStep::AsstMsg),
                    "user" => Some(CodexStep::Thinking),
                    _ => None, // system/developer messages say nothing about state
                },
                _ => None,
            },
            "event_msg" => match pt {
                "turn_aborted" | "task_complete" => Some(CodexStep::Aborted), // newer builds do write task_complete: an explicit end
                "task_started" | "item_started" | "exec_command_begin" => Some(CodexStep::Thinking),
                "user_message" => Some(CodexStep::Thinking),
                "agent_message" => Some(CodexStep::AsstMsg),
                "agent_reasoning" | "agent_reasoning_raw_content" => Some(CodexStep::Thinking),
                _ => None, // token_count and other bookkeeping lines
            },
            _ => None,
        };
        if let Some(st) = step {
            return Some((st, ts));
        }
    }
    None
}

/// The desktop app's real state: table `thread_turns` in `~/.codex/thread_history_1.sqlite`
/// (status = inProgress / completed…, started_at in seconds, empty completed_at = still running).
/// The app maintains this turn table itself, which is far more reliable than a file mtime. Guard
/// against "inProgress forever after a crash": no new item for the thread in the last 10 minutes
/// (`thread_items.created_at_ms`) while the turn started more than 2 minutes ago → treated as stale.
fn codex_turns_in_progress(ctx: &mut Ctx) -> Vec<Activity> {
    let now = now_ms();
    if ctx.codex_names.is_none() {
        ctx.codex_names = dirs::home_dir().and_then(|h| open_ro(&h.join(".codex").join("state_5.sqlite")));
    }
    let names = ctx.codex_names.as_ref();
    ctx.codex_turns.refresh(|conn| {
        let mut stmt = conn
            .prepare("SELECT thread_id, started_at FROM thread_turns WHERE status = 'inProgress' ORDER BY started_at DESC LIMIT 8")
            .ok()?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, rusqlite::types::Value>(1)?))).ok()?;
        let mut out = Vec::new();
        for (thread_id, started) in rows.flatten() {
            let started_ms = match started {
                rusqlite::types::Value::Integer(i) => (i as u64) * if i > 10_000_000_000 { 1 } else { 1000 },
                rusqlite::types::Value::Real(f) => (f * if f > 10_000_000_000.0 { 1.0 } else { 1000.0 }) as u64,
                _ => 0,
            };
            // The thread's latest item: freshness, and whether it is waiting for approval
            let (last_ms, last_type): (Option<i64>, Option<String>) = conn
                .query_row(
                    "SELECT created_at_ms, item_type FROM thread_items WHERE thread_id = ?1 ORDER BY created_at_ms DESC LIMIT 1",
                    [&thread_id],
                    |r| Ok((r.get::<_, Option<i64>>(0)?, r.get::<_, Option<String>>(1)?)),
                )
                .unwrap_or((None, None));
            let last = last_ms.map(|v| v as u64).unwrap_or(started_ms);
            let fresh = now.saturating_sub(last) <= 10 * 60_000 || now.saturating_sub(started_ms) <= 2 * 60_000;
            if !fresh {
                continue;
            }
            let mut name = String::new();
            if let Some(c) = names {
                if let Ok((title, first, nick)) = c.query_row(
                    "SELECT COALESCE(title,''), COALESCE(first_user_message,''), COALESCE(agent_nickname,'') FROM threads WHERE id = ?1",
                    [&thread_id],
                    |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?)),
                ) {
                    name = if !title.trim().is_empty() {
                        title
                    } else if !first.trim().is_empty() {
                        first.chars().take(40).collect()
                    } else if !nick.trim().is_empty() {
                        format!("Agent {nick}")
                    } else {
                        String::new()
                    };
                }
            }
            if name.is_empty() {
                name = "Codex".into();
            }
            let lt = last_type.unwrap_or_default().to_lowercase();
            let waiting = lt.contains("approval") || lt.contains("permission") || lt.contains("request_user");
            out.push(Activity {
                provider: "codex".into(),
                state: if waiting { "waiting" } else { "busy" }.into(),
                name,
                detail: if waiting { "needs your input".into() } else { "Working".into() },
                since: started_ms,
            });
        }
        Some(out)
    })
}

fn codex_activity(ctx: &mut Ctx) -> Vec<Activity> {
    // 1. The desktop app's real state
    let turns = codex_turns_in_progress(ctx);
    if !turns.is_empty() {
        return turns;
    }
    // 2. CLI / extension: locate the rollout every 30 s; skip the 256 KB tail read when its mtime has not changed
    let now = now_ms();
    if now.saturating_sub(ctx.rollout_checked_at) > 30_000 || ctx.rollout_path.is_none() {
        ctx.rollout_checked_at = now;
        ctx.rollout_path = crate::codex::newest_rollout();
    }
    let Some(p) = ctx.rollout_path.clone() else { return vec![] };
    let mtime = mtime_ms(&p).unwrap_or(0);
    if mtime == ctx.rollout_sig {
        // Content unchanged: only re-evaluate whether the silence has timed out
        return ctx
            .rollout_last
            .iter()
            .filter(|a| now.saturating_sub(a.since) <= 10 * 60_000)
            .cloned()
            .collect();
    }
    ctx.rollout_sig = mtime;
    ctx.rollout_last.clear();
    if let Some(text) = crate::codex::tail_text(&p) {
        if let Some((step, ts)) = codex_last_step(&text) {
            let at = ts.max(mtime);
            let quiet = now.saturating_sub(at);
            let busy = match step {
                CodexStep::Tool => quiet <= 10 * 60_000,
                CodexStep::Thinking => quiet <= 120_000,
                CodexStep::AsstMsg => quiet <= 4_000,
                CodexStep::Aborted => false,
            };
            if busy {
                ctx.rollout_last = vec![Activity { provider: "codex".into(), state: "busy".into(), name: "Codex".into(), detail: "Working".into(), since: at }];
            }
        }
    }
    ctx.rollout_last.clone()
}

// ---------------- Claude desktop (cloud sessions): network-activity heuristic ----------------

/// Cloud sessions leave no local transcript, so the four-state engine cannot see them. Next best
/// thing: while output is streaming, the Claude desktop app keeps receiving data from the network
/// (Winsock goes through AFD IOCTLs, which land in the Other counter of the process I/O counters).
/// Sampled every 2 s; a rate above the threshold means "streaming". Explicitly marked as inferred
/// (~); the first 60 samples go to run.log so the threshold can be calibrated.
struct IoSample {
    at: u64,
    other: u64,
    read: u64,
}
static CLAUDE_IO: std::sync::Mutex<Option<IoSample>> = std::sync::Mutex::new(None);
static CLAUDE_LAST_ACTIVE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
const CLAUDE_RATE_BPS: f64 = 2_500.0; // socket traffic of the network service process only; the idle heartbeat is far below this, streaming far above
const CLAUDE_HOLD_MS: u64 = 10_000; // tool calls often leave 2–4 s gaps with zero traffic; holding for 10 s avoids flicker
static CLAUDE_HITS: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

/// Pid of the Claude desktop app's (Electron) network service child: its command line contains
/// `network.mojom.NetworkService`. All socket traffic goes through it, so the IOCTL noise of the
/// GPU/renderer processes (driver calls count as Other too) stays out. Found once and cached;
/// looked up again when the process disappears or every 5 minutes. The command line comes from
/// PowerShell, so that cost is paid only on a lookup.
static CLAUDE_NET_PID: std::sync::Mutex<(u32, u64)> = std::sync::Mutex::new((0, 0));

#[cfg(windows)]
fn claude_net_pid(maps: &crate::focus::ProcMaps) -> Option<u32> {
    let now = now_ms();
    {
        let g = CLAUDE_NET_PID.lock().unwrap();
        let (pid, at) = *g;
        if pid != 0 && maps.name.get(&pid).map(|n| n == "claude.exe").unwrap_or(false) && now.saturating_sub(at) < 5 * 60_000 {
            return Some(pid);
        }
        // Cache a miss for 60 s too: otherwise a PowerShell run every 2 s (a few hundred ms of CPU each) becomes the next source of lag
        if pid == 0 && at != 0 && now.saturating_sub(at) < 60_000 {
            return None;
        }
        // Claude desktop is not running at all: no need for PowerShell
        if !maps.name.values().any(|n| n == "claude.exe") {
            return None;
        }
    }
    let mut cmd = std::process::Command::new("powershell");
    cmd.args([
        "-NoProfile",
        "-NonInteractive",
        "-Command",
        "Get-CimInstance Win32_Process -Filter \"Name='claude.exe'\" | Where-Object { $_.CommandLine -like '*network.mojom.NetworkService*' } | Select-Object -First 1 -ExpandProperty ProcessId",
    ]);
    cmd.stdin(std::process::Stdio::null()).stderr(std::process::Stdio::null());
    use std::os::windows::process::CommandExt;
    cmd.creation_flags(0x0800_0000);
    let pid: u32 = match cmd.output().ok().and_then(|o| String::from_utf8_lossy(&o.stdout).trim().parse().ok()) {
        Some(p) => p,
        None => {
            *CLAUDE_NET_PID.lock().unwrap() = (0, now);
            return None;
        }
    };
    *CLAUDE_NET_PID.lock().unwrap() = (pid, now);
    crate::applog(&format!("claude net pid = {pid}"));
    Some(pid)
}

#[cfg(windows)]
fn claude_io_bytes() -> Option<(u64, u64)> {
    use windows::Win32::Foundation::CloseHandle;
    use windows::Win32::System::Threading::{GetProcessIoCounters, OpenProcess, IO_COUNTERS, PROCESS_QUERY_LIMITED_INFORMATION};
    let maps = crate::focus::proc_maps();
    let net_pid = claude_net_pid(&maps)?;
    let mut other = 0u64;
    let mut read = 0u64;
    let mut n = 0;
    for (pid, _name) in maps.name.iter() {
        if *pid != net_pid {
            continue;
        }
        unsafe {
            let Ok(h) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, *pid) else { continue };
            let mut io = IO_COUNTERS::default();
            if GetProcessIoCounters(h, &mut io).is_ok() {
                other = other.saturating_add(io.OtherTransferCount);
                read = read.saturating_add(io.ReadTransferCount);
                n += 1;
            }
            let _ = CloseHandle(h);
        }
    }
    if n == 0 {
        None
    } else {
        Some((other, read))
    }
}
#[cfg(not(windows))]
fn claude_io_bytes() -> Option<(u64, u64)> {
    None
}

fn claude_activity() -> Vec<Activity> {
    let now = now_ms();
    let Some((other, read)) = claude_io_bytes() else { return vec![] };
    let mut guard = CLAUDE_IO.lock().unwrap();
    let (rate_other, rate_read) = match guard.as_ref() {
        Some(prev) if now > prev.at && other >= prev.other && read >= prev.read => {
            let dt = (now - prev.at) as f64 / 1000.0;
            ((other - prev.other) as f64 / dt, (read - prev.read) as f64 / dt)
        }
        _ => (0.0, 0.0),
    };
    *guard = Some(IoSample { at: now, other, read });
    drop(guard);
    static SAMPLES: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
    if SAMPLES.fetch_add(1, std::sync::atomic::Ordering::Relaxed) < 240 {
        crate::applog(&format!("claude io: net {:.0} B/s, disk {:.0} B/s", rate_other, rate_read));
    }
    // Two consecutive samples (≈4 s) above the threshold; a single spike (heartbeat, sync) does not count
    if rate_other >= CLAUDE_RATE_BPS {
        if CLAUDE_HITS.fetch_add(1, std::sync::atomic::Ordering::Relaxed) >= 1 {
            CLAUDE_LAST_ACTIVE.store(now, std::sync::atomic::Ordering::Relaxed);
        }
    } else {
        CLAUDE_HITS.store(0, std::sync::atomic::Ordering::Relaxed);
    }
    let last = CLAUDE_LAST_ACTIVE.load(std::sync::atomic::Ordering::Relaxed);
    if last > 0 && now.saturating_sub(last) <= CLAUDE_HOLD_MS {
        vec![Activity { provider: "claude".into(), state: "busy".into(), name: "Claude".into(), detail: "Streaming (network)".into(), since: last }]
    } else {
        vec![]
    }
}

// ---------------- Antigravity ----------------

fn antigravity_activity() -> Vec<Activity> {
    let Some(root) = dirs::home_dir().map(|h| h.join(".gemini").join("antigravity").join("brain")) else { return vec![] };
    let Ok(rd) = std::fs::read_dir(&root) else { return vec![] };
    let mut newest: Option<(String, u64)> = None;
    for e in rd.flatten() {
        let t = e.path().join(".system_generated").join("logs").join("transcript.jsonl");
        let Some(m) = mtime_ms(&t) else { continue };
        if newest.as_ref().map(|(_, n)| m > *n).unwrap_or(true) {
            newest = Some((e.file_name().to_string_lossy().to_string(), m));
        }
    }
    let Some((_, at)) = newest else { return vec![] };
    if now_ms().saturating_sub(at) > ANTIGRAVITY_STALE_MS {
        return vec![];
    }
    vec![Activity { provider: "gemini".into(), state: "busy".into(), name: "Antigravity".into(), detail: "Working".into(), since: at }]
}

// ---------------- Putting it together ----------------

#[derive(Clone, Copy, Default)]
pub struct Presence {
    cursor: bool,
    codex: bool,
    gemini: bool,
}

fn presence() -> Presence {
    Presence { cursor: crate::cursor::present(), codex: crate::codex::present(), gemini: crate::antigravity::present() }
}

fn read_all(p: Presence, ctx: &mut Ctx) -> Vec<Activity> {
    let mut all = Vec::new();
    all.extend(claude_activity());
    if p.cursor {
        all.extend(cursor_activity(ctx));
    }
    if p.codex {
        all.extend(codex_activity(ctx));
    }
    if p.gemini {
        all.extend(antigravity_activity());
    }
    all
}

/// For doctor: the raw material behind the Codex working-state decision
pub fn probe() -> String {
    let now = now_ms();
    let Some(p) = crate::codex::newest_rollout() else { return "Codex activity: no rollout found".into() };
    let age = now.saturating_sub(mtime_ms(&p).unwrap_or(0)) / 1000;
    let step = crate::codex::tail_text(&p).and_then(|t| codex_last_step(&t));
    let tail: Vec<String> = crate::codex::tail_text(&p)
        .map(|t| {
            t.lines()
                .rev()
                .filter(|l| !l.trim().is_empty())
                .take(6)
                .map(|l| {
                    serde_json::from_str::<serde_json::Value>(l)
                        .map(|v| {
                            format!(
                                "{}/{}/{}",
                                v.get("type").and_then(|x| x.as_str()).unwrap_or("?"),
                                v.pointer("/payload/type").and_then(|x| x.as_str()).unwrap_or("-"),
                                v.pointer("/payload/role").and_then(|x| x.as_str()).unwrap_or("-")
                            )
                        })
                        .unwrap_or_else(|_| "(not a JSON line)".into())
                })
                .collect()
        })
        .unwrap_or_default();
    format!(
        "Codex activity: rollout={} modified {age}s ago | last step={:?} | last 6 lines (type/payload.type/role)=[{}]",
        p.display(),
        step.map(|(s, ts)| format!("{s:?} @{}s ago", now.saturating_sub(ts) / 1000)),
        tail.join(", ")
    )
}

#[cfg(windows)]
pub fn lower_thread_priority() {
    use windows::Win32::System::Threading::{GetCurrentThread, SetThreadPriority, THREAD_PRIORITY_BELOW_NORMAL};
    unsafe {
        let _ = SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);
    }
}
#[cfg(not(windows))]
pub fn lower_thread_priority() {}

pub fn start(app: AppHandle) {
    std::thread::spawn(move || {
        lower_thread_priority(); // the probe always yields to foreground input
        let mut ctx = Ctx::new();
        let mut last: Vec<Activity> = Vec::new();
        let mut pres = presence();
        let mut tick: u32 = 0;
        loop {
            // Presence checks (finding the exe, reading credentials) once a minute are plenty; the 2 s tick does only stats and a query
            if tick % 30 == 0 {
                pres = presence();
            }
            tick = tick.wrapping_add(1);
            let found = read_all(pres, &mut ctx);
            if found != last {
                // Log the first 20 state changes (with the Codex raw material) so thresholds can be calibrated
                static LOGGED: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
                if LOGGED.fetch_add(1, std::sync::atomic::Ordering::Relaxed) < 20 {
                    crate::applog(&format!("activity: {:?} | {}", found.iter().map(|a| format!("{}:{}", a.provider, a.state)).collect::<Vec<_>>(), probe()));
                }
                last = found.clone();
                {
                    let st = app.state::<AppState>();
                    *st.activity.lock().unwrap() = found.clone();
                }
                let _ = app.emit("activity", &found);
            }
            std::thread::sleep(INTERVAL);
        }
    });
}
