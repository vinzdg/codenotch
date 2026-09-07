//! Codex usage adapter, implemented from the upstream Codenotch's documented behaviour.
//!
//! Two data paths (the same trade-off upstream made in 1.5.0):
//!   1. Live: borrow the session Codex keeps in `~/.codex/auth.json` (`tokens.access_token` +
//!      `tokens.account_id`) and GET `https://chatgpt.com/backend-api/wham/usage`. The reply carries
//!      `rate_limit.{primary_window,secondary_window}` with `used_percent / limit_window_seconds /
//!      reset_at (seconds) | reset_after_seconds`, plus a top-level `plan_type`. That is the number
//!      for *now*, and it starts no process. The token is read only — never refreshed, never written
//!      back; 401/403 becomes needsAuth and Codex renews it on its own.
//!      (The earlier `codex app-server` JSON-RPC route spawned a node process tree every five
//!      minutes, needed taskkill to clean up, and only ever reported the weekly window; the
//!      five-hour window came back with the endpoint.)
//!   2. Fallback: Codex writes the limits it saw on each turn into the thread's rollout log
//!      `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, as lines like
//!      `{"timestamp":"…","type":"event_msg","payload":{"type":"token_count","rate_limits":{
//!         "primary":{"used_percent":0.0,"window_minutes":300,"resets_at":1790585719},
//!         "secondary":{…}|null,"plan_type":"free"}}}`
//!      The reset is **resets_at, absolute seconds** (the documented resets_in_seconds is accepted
//!      too). This is the number from the *last run* — reading a file always succeeds instantly, so
//!      the reading is marked stale by the line's own timestamp (> 5 min).
//!   Upstream finds the newest rollout through the thread index in state_5.sqlite; this port walks
//!   the dated directories newest-first and picks by mtime, with no SQLite involved (and none of
//!   the immutable/WAL pitfalls).
//!
//! Credentials are borrowed, never managed: the numbers come from Codex's own sign-in and Codex's
//! own endpoint. No sign-in and no session history at all means absent (no cell is shown).

use crate::usage::{LimitWindow, UsageSnapshot};
use crate::AppState;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager};

const POLL_SECS: u64 = 300; // Codex has no session state to key off, so a fixed 5 min (upstream cadence; a tray refresh interrupts it)
const TAIL_BYTES: u64 = 256 * 1024;
const CURRENT_FOR_MS: u64 = 5 * 60 * 1000;
const ENDPOINT: &str = "https://chatgpt.com/backend-api/wham/usage";
const BACKOFF_MIN_SECS: u64 = 60; // wait at least this long after a 429; Retry-After only raises it

static REFRESH: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
/// Retry deadline given by the server (ms epoch): neither a manual refresh nor a restart may bypass it
static BACKOFF_UNTIL: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

pub fn request_refresh() {
    REFRESH.store(true, std::sync::atomic::Ordering::Relaxed);
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn codex_home() -> Option<PathBuf> {
    dirs::home_dir().map(|h| h.join(".codex"))
}

fn store_path() -> PathBuf {
    crate::config::config_path().with_file_name("codex.json")
}

pub fn load_persisted() -> UsageSnapshot {
    std::fs::read_to_string(store_path())
        .ok()
        .and_then(|t| serde_json::from_str::<UsageSnapshot>(&t).ok())
        .map(|mut s| {
            if !s.windows.is_empty() {
                s.status = "stale".into();
            }
            BACKOFF_UNTIL.store(s.backoff_until, std::sync::atomic::Ordering::Relaxed);
            s
        })
        .unwrap_or_default()
}

fn persist(s: &UsageSnapshot) {
    if let Ok(t) = serde_json::to_string_pretty(s) {
        let _ = std::fs::write(store_path(), t);
    }
}

// ---------------- Locating the executable ----------------

/// Candidates in order: the native exe inside the global npm package (cleanest — no cmd/node
/// wrapper) → ~/.codex/bin → codex.exe / codex.cmd on PATH.
pub fn find_executable() -> Option<PathBuf> {
    let mut cands: Vec<PathBuf> = Vec::new();
    if let Some(appdata) = dirs::config_dir() {
        let pkg = appdata.join("npm").join("node_modules").join("@openai").join("codex");
        if let Ok(rd) = std::fs::read_dir(pkg.join("bin")) {
            for e in rd.flatten() {
                let n = e.file_name().to_string_lossy().to_lowercase();
                if n.starts_with("codex-") && n.contains("windows") && n.ends_with(".exe") {
                    cands.push(e.path());
                }
            }
        }
        if let Ok(rd) = std::fs::read_dir(pkg.join("vendor")) {
            // Newer packages keep the native exe at vendor/<triple>/codex/codex.exe
            for e in rd.flatten() {
                let p = e.path().join("codex").join("codex.exe");
                if p.exists() {
                    cands.push(p);
                }
            }
        }
        cands.push(appdata.join("npm").join("codex.cmd"));
    }
    if let Some(h) = codex_home() {
        cands.push(h.join("bin").join("codex.exe"));
        cands.push(h.join("bin").join("codex"));
    }
    if let Some(path) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&path) {
            cands.push(dir.join("codex.exe"));
            cands.push(dir.join("codex.cmd"));
        }
    }
    cands.into_iter().find(|p| p.is_file())
}

// ---------------- Live: the usage endpoint ----------------

fn auth_path() -> Option<PathBuf> {
    codex_home().map(|h| h.join("auth.json"))
}

struct Credential {
    access_token: String,
    account_id: String,
    /// chatgpt_plan_type from the id_token (pro / plus / free…), used only as a label
    plan: Option<String>,
    /// The access_token's exp has passed: the request is still sent (the server decides); this only changes the 401 wording
    expired: bool,
}

/// Second JWT segment (base64url) → claims. Used only for labels and a local expiry hint; nothing is verified here — that is the server's job
fn jwt_claims(token: &str) -> Option<serde_json::Value> {
    let part = token.split('.').nth(1)?;
    let raw = crate::antigravity::b64_decode(part)?;
    serde_json::from_slice(&raw).ok()
}

/// Reads Codex's sign-in state; a missing file or missing field both mean "not signed in"
fn load_credential() -> Option<Credential> {
    let text = std::fs::read_to_string(auth_path()?).ok()?;
    let v: serde_json::Value = serde_json::from_str(&text).ok()?;
    let tokens = v.get("tokens")?;
    let access_token = tokens.get("access_token")?.as_str()?.trim().to_string();
    let account_id = tokens.get("account_id")?.as_str()?.trim().to_string();
    if access_token.is_empty() || account_id.is_empty() {
        return None;
    }
    let expired = jwt_claims(&access_token)
        .and_then(|c| c.get("exp").and_then(|x| x.as_f64()))
        .map(|exp| exp * 1000.0 <= now_ms() as f64)
        .unwrap_or(false);
    let plan = tokens
        .get("id_token")
        .and_then(|x| x.as_str())
        .and_then(jwt_claims)
        .and_then(|c| {
            c.get("https://api.openai.com/auth")?
                .get("chatgpt_plan_type")?
                .as_str()
                .map(String::from)
        });
    Some(Credential { access_token, account_id, plan, expired })
}

enum LiveErr {
    NeedsAuth,
    /// Suggested wait in seconds (BACKOFF_MIN_SECS already applied)
    RateLimited(u64),
    Other(String),
}

fn fetch_usage(cred: &Credential) -> Result<serde_json::Value, LiveErr> {
    let resp = ureq::get(ENDPOINT)
        .set("Authorization", &format!("Bearer {}", cred.access_token))
        .set("ChatGPT-Account-Id", &cred.account_id)
        .set("Accept", "application/json")
        .set("Cache-Control", "no-cache, no-store")
        .set("User-Agent", concat!("codenotch/", env!("CARGO_PKG_VERSION"), " (Windows)"))
        .timeout(Duration::from_secs(15))
        .call();
    match resp {
        Ok(r) => r.into_json().map_err(|e| LiveErr::Other(format!("parse: {e}"))),
        Err(ureq::Error::Status(code @ (401 | 403), r)) => {
            // 401 is about the token; 403 can also be an edge node rejecting the user agent — record the status and the start of the body rather than folding both into "please sign in"
            let head: String = r
                .into_string()
                .unwrap_or_default()
                .chars()
                .filter(|c| !c.is_control())
                .take(160)
                .collect();
            crate::applog(&format!("codex: usage endpoint HTTP {code}: {head}"));
            Err(LiveErr::NeedsAuth)
        }
        Err(ureq::Error::Status(429, r)) => {
            let ra = r.header("retry-after").and_then(|s| s.trim().parse::<u64>().ok()).unwrap_or(0);
            Err(LiveErr::RateLimited(ra.max(BACKOFF_MIN_SECS)))
        }
        Err(ureq::Error::Status(code, _)) => Err(LiveErr::Other(format!("HTTP {code}"))),
        Err(e) => Err(LiveErr::Other(format!("{e}"))),
    }
}

/// Upstream's label rule: Codex names windows only by length, and "5h limit" says more than "primary"
fn label_for(window_minutes: Option<f64>, id: &str) -> String {
    match window_minutes {
        Some(m) if m > 0.0 => {
            if m < 60.0 {
                format!("{}m limit", m as i64)
            } else if m < 60.0 * 24.0 {
                format!("{}h limit", (m / 60.0) as i64)
            } else {
                let days = (m / (60.0 * 24.0)).round() as i64;
                match days {
                    7 => "Weekly limit".into(),
                    30 => "Monthly limit".into(),
                    d => format!("{d}d limit"),
                }
            }
        }
        _ => {
            if id == "primary" {
                "Current session".into()
            } else {
                "Longer window".into()
            }
        }
    }
}

fn num(v: Option<&serde_json::Value>) -> Option<f64> {
    v.and_then(|x| x.as_f64())
}

/// Usage reply → windows. `additional_rate_limits` and `code_review_rate_limit` meter something
/// else and stay out of the rings. The window id records which field it came from
/// (primary/secondary) and the label is derived from the length — the primary window is not
/// always five hours (a free plan has shown 30 days), and recognising only fixed lengths would
/// drop a window that is genuinely in use.
fn windows_from_usage(v: &serde_json::Value) -> Vec<LimitWindow> {
    let now = now_ms();
    let mut out = Vec::new();
    for (id, key) in [("primary", "primary_window"), ("secondary", "secondary_window")] {
        let Some(w) = v.pointer(&format!("/rate_limit/{key}")).filter(|x| x.is_object()) else { continue };
        let Some(pct) = num(w.get("used_percent")) else { continue };
        let resets_at = num(w.get("reset_at"))
            .map(|s| (s * 1000.0) as u64)
            .or_else(|| num(w.get("reset_after_seconds")).map(|s| now + (s * 1000.0) as u64));
        out.push(LimitWindow {
            id: id.into(),
            label: label_for(num(w.get("limit_window_seconds")).map(|s| s / 60.0), id),
            used: (pct / 100.0).clamp(0.0, 1.0),
            resets_at,
            ..Default::default()
        });
    }
    out
}

// ---------------- Fallback: the rollout snapshot ----------------

/// The most recently modified rollout: dated directories newest-first, looking only at the three most recent days that have files
pub fn newest_rollout() -> Option<PathBuf> {
    let root = codex_home()?.join("sessions");
    let mut days: Vec<PathBuf> = Vec::new();
    let mut years = list_dirs(&root);
    years.sort_by(|a, b| b.cmp(a));
    'outer: for y in years {
        let mut months = list_dirs(&y);
        months.sort_by(|a, b| b.cmp(a));
        for m in months {
            let mut ds = list_dirs(&m);
            ds.sort_by(|a, b| b.cmp(a));
            for d in ds {
                days.push(d);
                if days.len() >= 3 {
                    break 'outer;
                }
            }
        }
    }
    let mut best: Option<(SystemTime, PathBuf)> = None;
    for d in days {
        if let Ok(rd) = std::fs::read_dir(&d) {
            for e in rd.flatten() {
                let p = e.path();
                let name = p.file_name().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
                if !(name.starts_with("rollout-") && name.ends_with(".jsonl")) {
                    continue;
                }
                let Ok(md) = e.metadata() else { continue };
                let Ok(mt) = md.modified() else { continue };
                if best.as_ref().map(|(t, _)| mt > *t).unwrap_or(true) {
                    best = Some((mt, p));
                }
            }
        }
    }
    best.map(|(_, p)| p)
}

fn list_dirs(p: &Path) -> Vec<PathBuf> {
    std::fs::read_dir(p)
        .map(|rd| rd.flatten().map(|e| e.path()).filter(|p| p.is_dir()).collect())
        .unwrap_or_default()
}

pub fn tail_text(path: &Path) -> Option<String> {
    let mut f = std::fs::File::open(path).ok()?;
    let len = f.metadata().map(|m| m.len()).unwrap_or(0);
    let _ = f.seek(SeekFrom::Start(len.saturating_sub(TAIL_BYTES)));
    let mut raw = Vec::new();
    f.read_to_end(&mut raw).ok()?;
    Some(String::from_utf8_lossy(&raw).into_owned())
}

/// The last rate_limits snapshot at the tail of a rollout → (windows, recorded-at ms, plan)
pub fn snapshot_from_rollout(text: &str) -> Option<(Vec<LimitWindow>, Option<u64>, Option<String>)> {
    for line in text.lines().rev().filter(|l| l.contains("rate_limits")) {
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else { continue };
        // rate_limits may sit at the top level or under payload
        let rl = v
            .get("rate_limits")
            .or_else(|| v.pointer("/payload/rate_limits"))
            .filter(|x| x.is_object());
        let Some(rl) = rl else { continue };
        let recorded = v
            .get("timestamp")
            .and_then(|x| x.as_str())
            .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
            .map(|d| d.timestamp_millis().max(0) as u64);
        let now = now_ms();
        let mut out = Vec::new();
        for id in ["primary", "secondary"] {
            let Some(w) = rl.get(id).filter(|x| x.is_object()) else { continue };
            let Some(pct) = num(w.get("used_percent")) else { continue };
            let resets_at = num(w.get("resets_at"))
                .map(|s| (s * 1000.0) as u64)
                .or_else(|| num(w.get("resets_in_seconds")).map(|s| now + (s * 1000.0) as u64));
            out.push(LimitWindow {
                id: id.into(),
                label: label_for(num(w.get("window_minutes")), id),
                used: (pct / 100.0).clamp(0.0, 1.0),
                resets_at, ..Default::default()
            });
        }
        if out.is_empty() {
            continue;
        }
        let plan = rl.get("plan_type").and_then(|x| x.as_str()).map(String::from);
        return Some((out, recorded, plan));
    }
    None
}

// ---------------- Putting it together ----------------

/// Is Codex present on this machine (CLI installed, signed in, or has had sessions)? If not, no cell is shown
pub fn present() -> bool {
    find_executable().is_some()
        || auth_path().map(|p| p.is_file()).unwrap_or(false)
        || codex_home().map(|h| h.join("sessions").is_dir()).unwrap_or(false)
}

fn read_once() -> UsageSnapshot {
    let mut snap = UsageSnapshot::default();
    // Note attached to the fallback reading when the live read failed; needs_auth picks the empty state when there is no fallback either
    let mut live_note: Option<String> = None;
    let mut needs_auth = false;
    let held_until = BACKOFF_UNTIL.load(std::sync::atomic::Ordering::Relaxed);
    let now = now_ms();
    if held_until > now {
        snap.backoff_until = held_until;
        live_note = Some(format!("Rate limited — retrying in {}s", (held_until - now) / 1000));
    } else {
        match load_credential() {
            None => {
                if auth_path().map(|p| p.is_file()).unwrap_or(false) {
                    crate::applog("codex: auth.json has no usable access_token/account_id, falling back to the rollout");
                }
            }
            Some(cred) => match fetch_usage(&cred) {
                Ok(v) => {
                    let windows = windows_from_usage(&v);
                    if !windows.is_empty() {
                        let plan = v.get("plan_type").and_then(|x| x.as_str()).map(String::from).or(cred.plan);
                        snap.status = "ok".into();
                        snap.windows = windows;
                        snap.fetched_at = now_ms();
                        snap.note = plan.map(|p| format!("{} · via Codex", cap(&p))).unwrap_or_default();
                        return snap;
                    }
                    let keys: Vec<String> = v.as_object().map(|o| o.keys().cloned().collect()).unwrap_or_default();
                    crate::applog(&format!("codex: usage reply has no windows (top-level keys {keys:?}), falling back to the rollout"));
                    live_note = Some("Codex reported no usage windows".into());
                }
                Err(LiveErr::NeedsAuth) => {
                    needs_auth = true;
                    live_note = Some(if cred.expired {
                        "Codex sign-in expired — open Codex once to refresh it".into()
                    } else {
                        "Codex rejected its sign-in — sign in to Codex again".into()
                    });
                }
                Err(LiveErr::RateLimited(secs)) => {
                    let until = now_ms() + secs * 1000;
                    BACKOFF_UNTIL.store(until, std::sync::atomic::Ordering::Relaxed);
                    snap.backoff_until = until;
                    live_note = Some(format!("Rate limited — retrying in {secs}s"));
                    crate::applog(&format!("codex: usage endpoint returned 429, retrying in {secs}s"));
                }
                Err(LiveErr::Other(e)) => {
                    crate::applog(&format!("codex: live read failed ({e}), falling back to the rollout"));
                    live_note = Some(format!("Live read failed ({e})"));
                }
            },
        }
    }
    // Fallback: rollout
    match newest_rollout().and_then(|p| tail_text(&p)).and_then(|t| snapshot_from_rollout(&t)) {
        Some((windows, recorded, plan)) => {
            let rec = recorded.unwrap_or(0);
            let fresh = rec > 0 && now_ms().saturating_sub(rec) <= CURRENT_FOR_MS;
            snap.status = if fresh { "ok" } else { "stale" }.into();
            snap.windows = windows;
            snap.fetched_at = rec; // the recorded time is what counts; the UI shows Updated N ago from it
            snap.note = match plan {
                Some(p) => format!("{} · from last Codex run", cap(&p)),
                None => "from last Codex run".into(),
            };
            if let Some(n) = live_note {
                snap.note = format!("{n} · {}", snap.note);
            }
        }
        None => {
            snap.status = if needs_auth {
                "needsAuth"
            } else if present() {
                "none"
            } else {
                "absent"
            }
            .into();
            snap.note = match live_note {
                Some(n) => n,
                None if present() => "Codex has not recorded a usage snapshot yet".into(),
                None => String::new(),
            };
        }
    }
    snap
}

fn cap(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
        None => String::new(),
    }
}

fn broadcast(app: &AppHandle, snap: UsageSnapshot) {
    let st = app.state::<AppState>();
    *st.codex.lock().unwrap() = snap.clone();
    persist(&snap);
    let _ = app.emit("codex", &snap);
}

pub fn start(app: AppHandle) {
    std::thread::spawn(move || {
        {
            let st = app.state::<AppState>();
            let snap = st.codex.lock().unwrap().clone();
            let _ = app.emit("codex", &snap);
        }
        if !present() {
            broadcast(&app, UsageSnapshot { status: "absent".into(), ..Default::default() });
            // Codex is not installed: look again every 10 minutes
            loop {
                for _ in 0..600 {
                    if REFRESH.swap(false, std::sync::atomic::Ordering::Relaxed) {
                        break;
                    }
                    std::thread::sleep(Duration::from_secs(1));
                }
                if present() {
                    break;
                }
            }
        }
        loop {
            let snap = read_once();
            let hold = snap.backoff_until.saturating_sub(now_ms()) / 1000;
            broadcast(&app, snap);
            for _ in 0..POLL_SECS.max(hold) {
                if REFRESH.swap(false, std::sync::atomic::Ordering::Relaxed) {
                    break;
                }
                std::thread::sleep(Duration::from_secs(1));
            }
        }
    });
}

/// For doctor: contains no secrets
pub fn probe() -> String {
    let auth = match load_credential() {
        Some(c) => format!(
            "auth.json usable{}{}",
            if c.expired { " (access_token expired)" } else { "" },
            c.plan.map(|p| format!(", plan={p}")).unwrap_or_default()
        ),
        None if auth_path().map(|p| p.is_file()).unwrap_or(false) => "auth.json present but has no token".to_string(),
        None => "auth.json not found".to_string(),
    };
    let exe = find_executable();
    let roll = newest_rollout();
    let age = roll
        .as_ref()
        .and_then(|p| std::fs::metadata(p).ok())
        .and_then(|m| m.modified().ok())
        .and_then(|t| SystemTime::now().duration_since(t).ok())
        .map(|d| format!("{} min ago", d.as_secs() / 60))
        .unwrap_or_else(|| "?".into());
    format!(
        "Codex: {auth} | executable {} | newest rollout {} (modified {})",
        exe.map(|p| p.display().to_string()).unwrap_or_else(|| "not found".into()),
        roll.map(|p| p.display().to_string()).unwrap_or_else(|| "none".into()),
        age
    )
}
