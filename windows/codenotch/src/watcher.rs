//! Transcript watcher: the fallback data source for the Claude Code **desktop app**.
//! Background: on Windows the desktop app has a known bug (2026-05) where settings.json hooks do
//! not fire, so the appends to ~/.claude/projects/**/*.jsonl are watched instead and the session
//! state is inferred from them:
//!   - the file is being appended                              → running
//!   - last line = plain assistant text, quiet for > 2.5 s     → done
//!   - last line = assistant tool_use, quiet for > 20 s        → attention (waiting for approval; inferred, a slow tool can be misread)
//! Arbitration: a session with fresh hook data in state.rs (within 5 min) ignores this inference
//! (the CLI's hooks are more accurate).

use crate::state::HookEvent;
use crate::AppState;
use notify::{RecursiveMode, Watcher};
use std::collections::HashMap;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, RecvTimeoutError};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Manager};

const QUIET_DONE_MS: u64 = 2_500;
const QUIET_ATTN_MS: u64 = 20_000;
/// Last entry is a user message and the file has been quiet for a long time: probably a stopped or
/// abandoned turn, and the light must not stay green forever (the threshold tolerates long thinking —
/// too short and "thinking hard" reads as done)
const QUIET_USER_DONE_MS: u64 = 75_000;
/// Self-healing rescan period and freshness window: never assume notify delivers every event
const RESCAN_SECS: u64 = 45;
const FRESH_WINDOW_MS: u64 = 10 * 60 * 1000;
/// A single message (including whole-file writes) often exceeds 16 KB; the tail window must be large enough, or a truncated last line fails to parse and the watcher stays silent forever
const TAIL_BYTES: u64 = 256 * 1024;

/// Run log: %APPDATA%\codenotch\watch.log (cleared at startup to keep troubleshooting simple)
pub fn wlog(msg: &str) {
    let Some(dir) = dirs::config_dir() else { return };
    let p = dir.join("codenotch").join("watch.log");
    if let Some(parent) = p.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&p) {
        let _ = writeln!(f, "[{}] {}", now_ms(), msg);
    }
}

#[derive(Clone, Copy, PartialEq)]
enum Kind {
    User,
    AsstText,
    AsstTool,
    Other,
}

struct Trk {
    session: String,
    cwd: String,
    last_append: u64,
    kind: Kind,
    sent: &'static str, // last state pushed, to avoid repeats
    /// The last user entry carries an interruption marker ("[Request interrupted...]") — a forced stop is judged done quickly
    interrupted: bool,
    prompt: String,
    model: String,
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Watch roots: the CLI's ~/.claude/projects plus the desktop app's (Cowork) session mirrors
/// (each desktop session has its own .claude/projects under %APPDATA%\Claude\local-agent-mode-sessions)
pub fn roots() -> Vec<PathBuf> {
    let mut v = Vec::new();
    if let Some(h) = dirs::home_dir() {
        v.push(h.join(".claude").join("projects"));
    }
    if let Some(c) = dirs::config_dir() {
        v.push(c.join("Claude").join("local-agent-mode-sessions"));
    }
    // If the desktop app is packaged (MSIX), its AppData is virtualised and the real files live under
    // %LOCALAPPDATA%\Packages\<package containing claude/anthropic>\LocalCache\Roaming\Claude\...
    if let Some(local) = dirs::data_local_dir() {
        if let Ok(rd) = std::fs::read_dir(local.join("Packages")) {
            for e in rd.flatten() {
                let name = e.file_name().to_string_lossy().to_lowercase();
                if name.contains("claude") || name.contains("anthropic") {
                    v.push(
                        e.path()
                            .join("LocalCache")
                            .join("Roaming")
                            .join("Claude")
                            .join("local-agent-mode-sessions"),
                    );
                }
            }
        }
    }
    v
}

/// Accept only real session transcripts: inside a .claude tree, excluding audit logs and sub-agents
pub fn is_session_jsonl(p: &Path) -> bool {
    if p.extension().map(|e| e == "jsonl").unwrap_or(false) == false {
        return false;
    }
    let name = p.file_name().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
    if name == "audit.jsonl" {
        return false;
    }
    let mut in_claude = false;
    for c in p.components() {
        let s = c.as_os_str().to_string_lossy();
        if s == "subagents" {
            return false;
        }
        if s == ".claude" {
            in_claude = true;
        }
    }
    in_claude
}

pub fn start(app: AppHandle) {
    std::thread::spawn(move || {
        crate::activity::lower_thread_priority();
        let (tx, rx) = channel();
        let Ok(mut w) = notify::recommended_watcher(move |res| {
            let _ = tx.send(res);
        }) else {
            return;
        };
        // Clear the previous log
        if let Some(dir) = dirs::config_dir() {
            let _ = std::fs::write(dir.join("codenotch").join("watch.log"), "");
        }
        wlog(&format!("watcher started v{}", env!("CARGO_PKG_VERSION")));
        let mut pending: Vec<PathBuf> = roots();
        let mut watching = 0usize;
        let mut last_retry = std::time::Instant::now();
        pending.retain(|r| {
            if r.exists() && w.watch(r, RecursiveMode::Recursive).is_ok() {
                watching += 1;
                wlog(&format!("watching: {}", r.display()));
                false
            } else {
                wlog(&format!("not available yet (retrying every 60 s): {}", r.display()));
                true
            }
        });
        let mut tracks: HashMap<PathBuf, Trk> = HashMap::new();
        rescan(&app, &mut tracks); // scan once at startup: adopt sessions that were already active
        let mut last_scan = std::time::Instant::now();
        // Throttling (this was the system-wide lag): while the desktop app streams, the transcript
        // fires dozens of modify events per second, and each one used to do a 256 KB tail read plus
        // JSON parse, competing with the Claude desktop app for the same file's I/O and CPU. Now a
        // file is ingested at most once per INGEST_MIN_GAP; the rest collapse into a dirty flag.
        const INGEST_MIN_GAP: Duration = Duration::from_millis(800);
        let mut last_ingest: HashMap<PathBuf, std::time::Instant> = HashMap::new();
        let mut dirty: std::collections::HashSet<PathBuf> = Default::default();
        loop {
            match rx.recv_timeout(Duration::from_millis(400)) {
                Ok(Ok(ev)) => {
                    for p in ev.paths {
                        if is_session_jsonl(&p) {
                            dirty.insert(p);
                        }
                    }
                    // Drain the events already queued in one go instead of waking up for each
                    while let Ok(Ok(ev)) = rx.try_recv() {
                        for p in ev.paths {
                            if is_session_jsonl(&p) {
                                dirty.insert(p);
                            }
                        }
                    }
                }
                Ok(Err(_)) => {}
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => return,
            }
            if !dirty.is_empty() {
                let now = std::time::Instant::now();
                let due: Vec<PathBuf> = dirty
                    .iter()
                    .filter(|p| {
                        last_ingest
                            .get(*p)
                            .map(|t| now.duration_since(*t) >= INGEST_MIN_GAP)
                            .unwrap_or(true)
                    })
                    .cloned()
                    .collect();
                for p in due {
                    dirty.remove(&p);
                    last_ingest.insert(p.clone(), now);
                    ingest(&app, &mut tracks, &p);
                }
                if last_ingest.len() > 512 {
                    last_ingest.retain(|_, t| now.duration_since(*t) < Duration::from_secs(600));
                }
            }
            evaluate(&app, &mut tracks);
            // Periodic self-healing rescan: new session directories, and a safety net for missed notify events
            if last_scan.elapsed() > Duration::from_secs(RESCAN_SECS) {
                last_scan = std::time::Instant::now();
                rescan(&app, &mut tracks);
            }
            // Roots that do not exist yet are retried every 60 s (e.g. the CLI has never run)
            if !pending.is_empty() && last_retry.elapsed() > Duration::from_secs(60) {
                last_retry = std::time::Instant::now();
                pending.retain(|r| {
                    !(r.exists() && w.watch(r, RecursiveMode::Recursive).is_ok())
                });
            }
            let _ = watching; // keep the thread alive even if everything failed, and wait for the retry
        }
    });
}

pub struct TailInfo {
    /// Latest conversation entry (user/assistant, skipping bookkeeping lines)
    pub entry: serde_json::Value,
    /// Most recent real user input (skipping tool_result-type user entries)
    pub prompt: String,
    /// The session's actual model (message.model of an assistant entry)
    pub model: String,
}

/// User input text: content is a string, or the text blocks of an array; entries with tool_result do not count
fn user_text(v: &serde_json::Value) -> Option<String> {
    let c = v.pointer("/message/content")?;
    if let Some(s) = c.as_str() {
        let s = s.trim();
        return (!s.is_empty()).then(|| s.chars().take(120).collect());
    }
    if let Some(arr) = c.as_array() {
        if arr
            .iter()
            .any(|b| b.get("type").and_then(|t| t.as_str()) == Some("tool_result"))
        {
            return None;
        }
        for b in arr {
            if b.get("type").and_then(|t| t.as_str()) == Some("text") {
                if let Some(s) = b.get("text").and_then(|x| x.as_str()) {
                    let s = s.trim();
                    if !s.is_empty() {
                        return Some(s.chars().take(120).collect());
                    }
                }
            }
        }
    }
    None
}

/// Reads the file tail and walks backwards: main entry + latest user input + model, all in one pass
/// (the last line may be partial, a huge line cut by the tail window, or bookkeeping — all of those step back)
pub fn tail_info(path: &Path) -> Option<TailInfo> {
    let mut f = std::fs::File::open(path).ok()?;
    let len = f.metadata().map(|m| m.len()).unwrap_or(0);
    let start = len.saturating_sub(TAIL_BYTES);
    f.seek(SeekFrom::Start(start)).ok()?;
    let mut raw = Vec::new();
    f.read_to_end(&mut raw).ok()?;
    let buf = String::from_utf8_lossy(&raw);
    let mut entry: Option<serde_json::Value> = None;
    let mut prompt = String::new();
    let mut model = String::new();
    for line in buf.lines().rev().filter(|l| !l.trim().is_empty()).take(80) {
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        let t = v.get("type").and_then(|x| x.as_str()).unwrap_or("");
        if t != "user" && t != "assistant" {
            continue;
        }
        if entry.is_none() {
            entry = Some(v.clone());
        }
        if model.is_empty() && t == "assistant" {
            if let Some(m) = v.pointer("/message/model").and_then(|x| x.as_str()) {
                model = m.to_string();
            }
        }
        if prompt.is_empty() && t == "user" {
            if let Some(p) = user_text(&v) {
                prompt = p;
            }
        }
        if entry.is_some() && !model.is_empty() && !prompt.is_empty() {
            break;
        }
    }
    entry.map(|e| TailInfo {
        entry: e,
        prompt,
        model,
    })
}

/// Simplified entry point for doctor
pub fn tail_entry(path: &Path) -> Option<serde_json::Value> {
    tail_info(path).map(|t| t.entry)
}

/// Updates the tracking info and pushes running
fn ingest(app: &AppHandle, tracks: &mut HashMap<PathBuf, Trk>, path: &Path) {
    let Some(info) = tail_info(path) else {
        return;
    };
    let v = info.entry;
    // Transcript fields are camelCase (sessionId), unlike the snake_case of the hook stdin!
    let session = v
        .get("sessionId")
        .and_then(|x| x.as_str())
        .map(|s| s.to_string())
        .unwrap_or_else(|| {
            path.file_stem()
                .map(|s| s.to_string_lossy().to_string())
                .unwrap_or_default()
        });
    if session.is_empty() {
        return;
    }
    let mut cwd = v
        .get("cwd")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    // A desktop session's cwd is an internal outputs path that means nothing to the user; use a friendly label
    if cwd.contains("local-agent-mode-sessions") {
        cwd = "Claude desktop".to_string();
    }
    let typ = v.get("type").and_then(|x| x.as_str()).unwrap_or("");
    let kind = match typ {
        "user" => Kind::User,
        "assistant" => {
            let has_tool = v
                .get("message")
                .and_then(|m| m.get("content"))
                .and_then(|c| c.as_array())
                .map(|arr| {
                    arr.iter()
                        .any(|b| b.get("type").and_then(|t| t.as_str()) == Some("tool_use"))
                })
                .unwrap_or(false);
            if has_tool {
                Kind::AsstTool
            } else {
                Kind::AsstText
            }
        }
        _ => Kind::Other,
    };
    let interrupted = typ == "user"
        && v.get("message")
            .map(|m| m.to_string().to_lowercase().contains("interrupt"))
            .unwrap_or(false);
    let t = tracks.entry(path.to_path_buf()).or_insert(Trk {
        session: session.clone(),
        cwd: cwd.clone(),
        last_append: 0,
        kind,
        sent: "",
        interrupted: false,
        prompt: String::new(),
        model: String::new(),
    });
    t.session = session;
    if !cwd.is_empty() {
        t.cwd = cwd;
    }
    t.last_append = now_ms();
    t.kind = kind;
    t.interrupted = interrupted;
    if !info.prompt.is_empty() {
        t.prompt = info.prompt;
    }
    if !info.model.is_empty() {
        t.model = info.model;
    }
    // Push running on every append (prompt/model updates travel with it);
    // whether it is actually broadcast is decided by state.apply's visible-change check
    t.sent = "running";
    push(app, "running", t);
}

/// Self-healing rescan: walk the roots and re-ingest every session file whose mtime is newer than
/// our recorded last_append and inside the freshness window — new session directories and lost
/// notify events are both covered by it
fn walk(dir: &Path, depth: usize, out: &mut Vec<PathBuf>) {
    if depth > 10 {
        return;
    }
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        let p = e.path();
        if p.is_dir() {
            walk(&p, depth + 1, out);
        } else if is_session_jsonl(&p) {
            out.push(p);
        }
    }
}

fn rescan(app: &AppHandle, tracks: &mut HashMap<PathBuf, Trk>) {
    let now = now_ms();
    let mut found = Vec::new();
    for r in roots() {
        if r.exists() {
            walk(&r, 0, &mut found);
        }
    }
    for p in found {
        let Some(mtime) = std::fs::metadata(&p)
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_millis() as u64)
        else {
            continue;
        };
        if now.saturating_sub(mtime) > FRESH_WINDOW_MS {
            continue; // only recently active ones matter
        }
        let known = tracks.get(&p).map(|t| t.last_append).unwrap_or(0);
        if mtime > known {
            ingest(app, tracks, &p);
        }
    }
}

/// Quiet-time decision: done / attention (inferred)
fn evaluate(app: &AppHandle, tracks: &mut HashMap<PathBuf, Trk>) {
    let now = now_ms();
    for t in tracks.values_mut() {
        if t.last_append == 0 {
            continue;
        }
        let quiet = now.saturating_sub(t.last_append);
        match t.kind {
            Kind::AsstText if quiet > QUIET_DONE_MS && t.sent != "done" => {
                t.sent = "done";
                push(app, "done", t);
            }
            Kind::AsstTool if quiet > QUIET_ATTN_MS && t.sent != "attention" => {
                t.sent = "attention";
                push(app, "attention", t);
            }
            // Forced stop: the last user entry carries the interruption marker, judged done quickly
            Kind::User if t.interrupted && quiet > QUIET_DONE_MS && t.sent != "done" => {
                t.sent = "done";
                push(app, "done", t);
            }
            // Last user entry and long silence (75 s): the turn was abandoned or stopped (the threshold tolerates long thinking)
            Kind::User if quiet > QUIET_USER_DONE_MS && t.sent != "done" => {
                t.sent = "done";
                push(app, "done", t);
            }
            // Safety valve: any other type silent for 5 minutes must not keep the green light on forever
            Kind::Other if quiet > 5 * 60_000 && t.sent != "done" => {
                t.sent = "done";
                push(app, "done", t);
            }
            _ => {}
        }
    }
}

static PUSH_LOGGED: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

fn push(app: &AppHandle, e: &str, t: &Trk) {
    // The first 30 pushes go to the log for doctor/troubleshooting (then silence, to keep the log small)
    if PUSH_LOGGED.fetch_add(1, std::sync::atomic::Ordering::Relaxed) < 30 {
        wlog(&format!("push {} session={} cwd={}", e, t.session, t.cwd));
    }
    let ev = HookEvent {
        e: e.to_string(),
        session_id: t.session.clone(),
        ppid: 0,
        cwd: t.cwd.clone(),
        prompt: t.prompt.clone(),
        message: String::new(),
        tool_name: String::new(),
        tool_cmd: String::new(),
        model: t.model.clone(),
        src: "watch",
    };
    let changed = {
        let st = app.state::<AppState>();
        let mut store = st.store.lock().unwrap();
        store.apply(ev)
    };
    if changed {
        crate::broadcast(app);
    }
}
