//! OpenCode Go usage adapter, ported from the upstream macOS OpenCodeProvider/OpenCodeUsage.
//!
//! Endpoint: GET https://opencode.ai/zen/go/v1/usage — the Go plan's rolling (5 h), weekly and
//! monthly windows, the same figures the OpenCode dashboard shows:
//!   {"usage":{"rolling":{"status":"ok","percent":12,"resetsAt":"2026-09-06T12:31:06.611Z"},
//!             "weekly":{...},"monthly":{...}}}
//! `percent` is *used*, so the ring needs no inversion.
//!
//! The credential is borrowed from OpenCode's own sign-in, never written. Sources, in order:
//!   1. auth.json → `opencode-go` ({"type":"api","key":...}): the Go plan's API key, the one the
//!      Mac reads and what OpenCode wrote before 1.18;
//!   2. opencode.db → the `credential` table. OpenCode 1.18 moved sign-in into SQLite and signs in
//!      to OpenCode itself over OAuth: an active `opencode` (or `opencode-go`) row whose value is
//!      {"type":"oauth","access":...,"expires":ms,"metadata":{"orgID":...}}. The access token is the
//!      API key OpenCode sends to Zen, alongside an `x-opencode-org-id` header naming the org;
//!   3. auth.json → an `opencode` oauth entry, the same token when the database cannot be opened.
//! Both files live in OpenCode's XDG data dir, which on Windows is still ~/.local/share/opencode.
//!
//! Two upstream quirks worth knowing: a valid credential with no Go plan answers 401, the same as
//! a bad one — so a 401 is checked against the Zen model list with the same token, which answers
//! 200 to any valid sign-in, to tell "no Go plan" from "signed out"; and Zen pay-as-you-go credit
//! has no usage API at all, so this covers the Go windows only.
//!
//! SQLite opening rule, as for Cursor: `mode=ro` first (it sees a token OpenCode just rotated into
//! the WAL), then `immutable=1`. Token values never reach logs, events or the UI.

use crate::usage::{LimitWindow, UsageSnapshot};
use crate::AppState;
use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager};

const USAGE_URL: &str = "https://opencode.ai/zen/go/v1/usage";
const MODELS_URL: &str = "https://opencode.ai/zen/v1/models";
const POLL_SECS: u64 = 300;
const BACKOFF_BASE_SECS: u64 = 60;
const BACKOFF_CAP_SECS: u64 = 900;

static REFRESH: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
static BACKOFF_UNTIL: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
static CONSECUTIVE_429: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

pub fn request_refresh() {
    BACKOFF_UNTIL.store(0, std::sync::atomic::Ordering::Relaxed);
    CONSECUTIVE_429.store(0, std::sync::atomic::Ordering::Relaxed);
    REFRESH.store(true, std::sync::atomic::Ordering::Relaxed);
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn store_path() -> PathBuf {
    crate::config::config_path().with_file_name("opencode-usage.json")
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

// ---------------- Credentials (borrowed, never written) ----------------

#[derive(Debug, PartialEq)]
struct Credential {
    token: String,
    /// Sent as x-opencode-org-id; only an OAuth sign-in carries one
    org: Option<String>,
    /// ms epoch; only an OAuth sign-in carries one
    expires: Option<u64>,
    source: &'static str,
}

/// OpenCode's data dirs: $XDG_DATA_HOME/opencode when set, else ~/.local/share/opencode
fn data_dirs() -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Some(x) = std::env::var_os("XDG_DATA_HOME").filter(|x| !x.is_empty()) {
        out.push(PathBuf::from(x).join("opencode"));
    }
    if let Some(home) = dirs::home_dir() {
        let p = home.join(".local").join("share").join("opencode");
        if !out.contains(&p) {
            out.push(p);
        }
    }
    out
}

fn non_empty(v: Option<&serde_json::Value>) -> Option<String> {
    v.and_then(|x| x.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// One stored credential value, in either shape OpenCode writes: {"type":"api","key"} or
/// {"type":"oauth","access","expires","metadata":{"orgID"}}. A bare string is the key itself.
fn credential_from(entry: &serde_json::Value, source: &'static str) -> Option<Credential> {
    if let Some(token) = non_empty(Some(entry)) {
        return Some(Credential { token, org: None, expires: None, source });
    }
    let obj = entry.as_object()?;
    if obj.get("type").and_then(|t| t.as_str()) == Some("oauth") {
        let token = non_empty(obj.get("access"))?;
        let org = non_empty(obj.get("metadata").and_then(|m| m.get("orgID")));
        let expires = obj.get("expires").and_then(|e| e.as_u64());
        return Some(Credential { token, org, expires, source });
    }
    let token = ["key", "apiKey", "api_key", "token", "accessToken"]
        .iter()
        .find_map(|f| non_empty(obj.get(*f)))?;
    Some(Credential { token, org: None, expires: None, source })
}

fn read_auth_json(dir: &std::path::Path) -> Option<serde_json::Value> {
    std::fs::read_to_string(dir.join("auth.json")).ok().and_then(|t| serde_json::from_str(&t).ok())
}

/// mode=ro first, immutable=1 as the fallback (see the module doc)
fn open_ro(path: &std::path::Path) -> Option<rusqlite::Connection> {
    use rusqlite::OpenFlags;
    if !path.is_file() {
        return None;
    }
    let works = |c: &rusqlite::Connection| {
        c.prepare("SELECT 1 FROM credential LIMIT 1").and_then(|mut s| s.query([]).map(|_| ())).is_ok()
    };
    if let Ok(c) = rusqlite::Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    ) {
        if works(&c) {
            return Some(c);
        }
    }
    let mut uri = String::from("file:///");
    uri.push_str(&path.to_string_lossy().replace('\\', "/").trim_start_matches('/').replace('#', "%23").replace('?', "%3F"));
    uri.push_str("?immutable=1");
    rusqlite::Connection::open_with_flags(
        &uri,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .ok()
    .filter(works)
}

/// The active `opencode-go` row, else the active `opencode` one. Another integration's row is that
/// vendor's key, and claiming it would read the wrong account under OpenCode's name.
fn credential_from_db(conn: &rusqlite::Connection) -> Option<Credential> {
    let rows: Vec<(String, String)> = conn
        .prepare(
            "SELECT integration_id, value FROM credential \
             WHERE integration_id IN ('opencode-go', 'opencode') AND COALESCE(active, 1) != 0 \
             ORDER BY time_updated DESC",
        )
        .and_then(|mut s| {
            s.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))
                .map(|it| it.flatten().collect())
        })
        .ok()?;
    ["opencode-go", "opencode"].iter().find_map(|id| {
        rows.iter()
            .filter(|(i, _)| i == id)
            .find_map(|(_, v)| serde_json::from_str::<serde_json::Value>(v).ok().and_then(|v| credential_from(&v, "OpenCode")))
    })
}

fn load_credential() -> Option<Credential> {
    let dirs = data_dirs();
    // 1. the Go plan's own key, as OpenCode wrote it before 1.18 (and the Mac reads it)
    for d in &dirs {
        if let Some(c) = read_auth_json(d).and_then(|r| r.get("opencode-go").and_then(|e| credential_from(e, "OpenCode"))) {
            return Some(c);
        }
    }
    // 2. OpenCode 1.18+: the sign-in lives in opencode.db
    for d in &dirs {
        if let Some(c) = open_ro(&d.join("opencode.db")).and_then(|conn| credential_from_db(&conn)) {
            return Some(c);
        }
    }
    // 3. the same OAuth sign-in mirrored into auth.json
    for d in &dirs {
        let Some(root) = read_auth_json(d) else { continue };
        if let Some(c) = root.get("opencode").filter(|e| e.get("type").and_then(|t| t.as_str()) == Some("oauth")).and_then(|e| credential_from(e, "OpenCode")) {
            return Some(c);
        }
    }
    None
}

/// Is OpenCode on this machine at all? If not, no cell is shown.
pub fn present() -> bool {
    data_dirs().iter().any(|d| d.join("auth.json").is_file() || d.join("opencode.db").is_file())
}

// ---------------- The usage endpoint ----------------

enum FetchErr {
    Unauthorized,
    Forbidden,
    RateLimited(u64),
    Other(String),
}

fn get(url: &str, cred: &Credential) -> ureq::Request {
    let mut req = ureq::get(url)
        .set("Authorization", &format!("Bearer {}", cred.token))
        .set("Accept", "application/json")
        .set("User-Agent", concat!("codenotch/", env!("CARGO_PKG_VERSION"), " (Windows)"))
        .timeout(Duration::from_secs(15));
    if let Some(org) = &cred.org {
        req = req.set("x-opencode-org-id", org);
    }
    req
}

fn fetch(cred: &Credential) -> Result<serde_json::Value, FetchErr> {
    match get(USAGE_URL, cred).call() {
        Ok(r) => r.into_json().map_err(|e| FetchErr::Other(format!("parse: {e}"))),
        Err(ureq::Error::Status(401, _)) => Err(FetchErr::Unauthorized),
        Err(ureq::Error::Status(403, _)) => Err(FetchErr::Forbidden),
        Err(ureq::Error::Status(429, r)) => {
            let ra = r.header("retry-after").and_then(|s| s.trim().parse::<u64>().ok()).unwrap_or(0);
            Err(FetchErr::RateLimited(ra))
        }
        Err(ureq::Error::Status(code, _)) => Err(FetchErr::Other(format!("HTTP {code}"))),
        Err(e) => Err(FetchErr::Other(format!("{e}"))),
    }
}

/// Does Zen accept this sign-in at all? Asked only after the usage endpoint's 401, which cannot
/// tell a bad credential from one without a Go plan.
fn signed_in(cred: &Credential) -> bool {
    matches!(get(MODELS_URL, cred).call(), Ok(r) if r.status() == 200)
}

/// "2026-09-06T12:31:06.611Z" → ms epoch
fn parse_reset(stamp: &str) -> Option<u64> {
    chrono::DateTime::parse_from_rfc3339(stamp.trim()).ok().map(|d| d.timestamp_millis().max(0) as u64)
}

fn windows_from(v: &serde_json::Value) -> Vec<LimitWindow> {
    let Some(usage) = v.get("usage") else { return Vec::new() };
    [("rolling", "5-hour Limit"), ("weekly", "Weekly limit"), ("monthly", "Monthly limit")]
        .iter()
        .filter_map(|(id, label)| {
            let entry = usage.get(*id)?;
            let pct = entry.get("percent").and_then(|x| x.as_f64())?;
            Some(LimitWindow {
                id: (*id).into(),
                label: (*label).into(),
                used: (pct / 100.0).clamp(0.0, 1.0),
                resets_at: entry.get("resetsAt").and_then(|x| x.as_str()).and_then(parse_reset),
                ..Default::default()
            })
        })
        .collect()
}

// ---------------- Putting it together ----------------

fn read_once() -> UsageSnapshot {
    let mut snap = UsageSnapshot::default();
    let held_until = BACKOFF_UNTIL.load(std::sync::atomic::Ordering::Relaxed);
    let now = now_ms();
    if held_until > now {
        snap.backoff_until = held_until;
        snap.note = format!("Rate limited — retrying in {}s", (held_until - now) / 1000);
        return snap;
    }
    if !present() {
        snap.status = "absent".into();
        return snap;
    }
    let Some(cred) = load_credential() else {
        snap.status = "needsAuth".into();
        snap.note = "Run opencode auth login to sign in to OpenCode.".into();
        return snap;
    };
    // An expired token is still sent: OpenCode refreshes it whenever it runs, and only the
    // endpoint can say whether this copy is still good.
    match fetch(&cred) {
        Ok(v) => {
            let windows = windows_from(&v);
            if windows.is_empty() {
                snap.status = "stale".into();
                snap.note = "The Go plan reported no usage windows".into();
                crate::applog("opencode: reply carried no usable windows, keeping the last reading");
                return snap;
            }
            snap.status = "ok".into();
            snap.windows = windows;
            snap.fetched_at = now_ms();
            snap.note = format!("Go · via {}", cred.source);
            CONSECUTIVE_429.store(0, std::sync::atomic::Ordering::Relaxed);
        }
        Err(FetchErr::Forbidden) => {
            snap.status = "none".into();
            snap.fetched_at = now_ms();
            snap.note = "No OpenCode Go subscription on this account".into();
        }
        Err(FetchErr::Unauthorized) => {
            if signed_in(&cred) {
                snap.status = "none".into();
                snap.fetched_at = now_ms();
                snap.note = "No OpenCode Go subscription on this account".into();
            } else {
                let expired = cred.expires.is_some_and(|e| e <= now_ms());
                snap.status = "needsAuth".into();
                snap.note = if expired {
                    "OpenCode's sign-in has expired — open OpenCode to renew it".into()
                } else {
                    "OpenCode rejected the sign-in — run opencode auth login".into()
                };
            }
            crate::applog(&format!("opencode: usage endpoint answered 401, status={}", snap.status));
        }
        Err(FetchErr::RateLimited(ra)) => {
            let n = CONSECUTIVE_429.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1;
            let exp = BACKOFF_BASE_SECS.saturating_mul(1u64 << (n - 1).min(4));
            let wait = exp.clamp(BACKOFF_BASE_SECS, BACKOFF_CAP_SECS).max(ra);
            let until = now_ms() + wait * 1000;
            BACKOFF_UNTIL.store(until, std::sync::atomic::Ordering::Relaxed);
            snap.backoff_until = until;
            snap.note = format!("Rate limited — retrying in {wait}s");
            crate::applog(&format!("opencode: 429 (x{n}), retrying in {wait}s"));
        }
        Err(FetchErr::Other(e)) => {
            snap.status = "error".into();
            snap.note = format!("Live read failed ({e})");
            crate::applog(&format!("opencode: live read failed ({e})"));
        }
    }
    snap
}

fn broadcast(app: &AppHandle, snap: UsageSnapshot) {
    let st = app.state::<AppState>();
    *st.opencode.lock().unwrap() = snap.clone();
    persist(&snap);
    let _ = app.emit("opencode", &snap);
}

pub fn start(app: AppHandle) {
    std::thread::spawn(move || {
        {
            let st = app.state::<AppState>();
            let snap = st.opencode.lock().unwrap().clone();
            let _ = app.emit("opencode", &snap);
        }
        if !present() {
            broadcast(&app, UsageSnapshot { status: "absent".into(), ..Default::default() });
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

/// For doctor: names the source and kind, never the token
pub fn probe() -> String {
    match load_credential() {
        Some(c) => format!(
            "OpenCode: {} via {}{}",
            if c.org.is_some() { "OAuth sign-in" } else { "API key" },
            c.source,
            if c.expires.is_some_and(|e| e <= now_ms()) { " (expired — open OpenCode to renew)" } else { "" }
        ),
        None if present() => "OpenCode: installed but not signed in (no opencode-go key or OAuth credential)".into(),
        None => "OpenCode: not installed (no ~/.local/share/opencode)".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn go_windows_parse_in_headline_order() {
        let v: serde_json::Value = serde_json::from_str(
            r#"{"usage":{
              "monthly":{"status":"ok","percent":40,"resetsAt":"2026-10-03T13:09:45.611Z"},
              "rolling":{"status":"ok","percent":12.5,"resetsAt":"2026-09-06T12:31:06.611Z"},
              "weekly":{"status":"ok","percent":0,"resetsAt":"2026-09-07T00:00:00Z"}}}"#,
        )
        .unwrap();
        let ws = windows_from(&v);
        let ids: Vec<&str> = ws.iter().map(|w| w.id.as_str()).collect();
        assert_eq!(ids, ["rolling", "weekly", "monthly"]);
        assert_eq!(ws[0].used, 0.125);
        assert_eq!(ws[1].used, 0.0, "0 % is a reading, not a gap");
        assert_eq!(ws[0].resets_at, Some(1788697866611));
        assert_eq!(ws[1].resets_at, Some(1788739200000));
    }

    #[test]
    fn a_reply_without_usage_has_no_windows() {
        let v: serde_json::Value = serde_json::from_str(r#"{"type":"error"}"#).unwrap();
        assert!(windows_from(&v).is_empty());
    }

    #[test]
    fn oauth_credential_carries_org_and_expiry() {
        let v: serde_json::Value = serde_json::from_str(
            r#"{"type":"oauth","methodID":"device","refresh":"rt_x","access":"st_abc","expires":1792854570201,
                "metadata":{"server":"https://opencode.ai/console","orgID":"org_1","orgName":"Personal"}}"#,
        )
        .unwrap();
        let c = credential_from(&v, "OpenCode").unwrap();
        assert_eq!(c.token, "st_abc");
        assert_eq!(c.org.as_deref(), Some("org_1"));
        assert_eq!(c.expires, Some(1792854570201));
    }

    #[test]
    fn api_key_and_bare_string_shapes_both_read() {
        let v: serde_json::Value = serde_json::from_str(r#"{"type":"api","key":"sk-go"}"#).unwrap();
        assert_eq!(credential_from(&v, "OpenCode").unwrap().token, "sk-go");
        assert_eq!(credential_from(&serde_json::json!("sk-bare"), "OpenCode").unwrap().token, "sk-bare");
        assert!(credential_from(&serde_json::json!({"type":"oauth","access":""}), "OpenCode").is_none());
    }

    fn db_with(rows: &[(&str, &str, Option<i64>, i64)]) -> rusqlite::Connection {
        let c = rusqlite::Connection::open_in_memory().unwrap();
        c.execute_batch(
            "CREATE TABLE credential (id text PRIMARY KEY, integration_id text, label text NOT NULL,
             value text NOT NULL, connector_id text, method_id text, active integer,
             time_created integer NOT NULL, time_updated integer NOT NULL)",
        )
        .unwrap();
        for (i, (integration, value, active, updated)) in rows.iter().enumerate() {
            c.execute(
                "INSERT INTO credential VALUES (?1, ?2, 'x', ?3, NULL, NULL, ?4, 0, ?5)",
                rusqlite::params![format!("cred_{i}"), integration, value, active, updated],
            )
            .unwrap();
        }
        c
    }

    #[test]
    fn db_picks_the_opencode_sign_in_and_ignores_other_vendors() {
        let c = db_with(&[
            ("openrouter", r#"{"type":"api","key":"sk-or"}"#, None, 5),
            ("opencode", r#"{"type":"oauth","access":"st_new","metadata":{"orgID":"org_1"}}"#, Some(1), 3),
        ]);
        let got = credential_from_db(&c).unwrap();
        assert_eq!(got.token, "st_new");
        assert_eq!(got.org.as_deref(), Some("org_1"));

        let only_other = db_with(&[("openrouter", r#"{"type":"api","key":"sk-or"}"#, None, 5)]);
        assert_eq!(credential_from_db(&only_other), None);
    }

    #[test]
    fn db_prefers_a_go_key_and_skips_inactive_rows() {
        let c = db_with(&[
            ("opencode", r#"{"type":"oauth","access":"st_oauth"}"#, Some(1), 9),
            ("opencode-go", r#"{"type":"api","key":"sk-go"}"#, None, 1),
        ]);
        assert_eq!(credential_from_db(&c).unwrap().token, "sk-go");

        let c = db_with(&[
            ("opencode", r#"{"type":"oauth","access":"st_old"}"#, Some(0), 9),
            ("opencode", r#"{"type":"oauth","access":"st_live"}"#, Some(1), 1),
        ]);
        assert_eq!(credential_from_db(&c).unwrap().token, "st_live");
    }
}
