//! Cursor usage adapter, implemented from the upstream Codenotch's documented behaviour.
//!
//! Data path (same trade-off as upstream: borrow the editor's own session):
//!   1. Credential: the editor keeps its sign-in in the global state database it inherited from
//!      VS Code, `%APPDATA%\Cursor\User\globalStorage\state.vscdb` (SQLite, table ItemTable(key,value)):
//!      `cursorAuth/accessToken` + `cursorAuth/stripeMembershipAuthId`, joined into the cookie
//!      `WorkosCursorSessionToken=<authId>::<token>`. Non-secret identity cache:
//!      `cursorAuth/cachedEmail`, `cursorAuth/stripeMembershipType` (only the plan is shown).
//!      Newer builds seal the token with Electron safeStorage: `cursor-safe-storage:v1:` + base64 of
//!      `v10` | 12-byte nonce | AES-256-GCM ciphertext+tag, keyed by `os_crypt.encrypted_key` in
//!      `%APPDATA%\Cursor\Local State` (`DPAPI` + a blob only this Windows user can unprotect).
//!   2. Endpoint: `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`
//!      (Connect JSON, `Authorization: Bearer <token>`, body `{}`) — the editor's own Usage panel, which
//!      knows the weekly allowance (see `parse_dashboard`). Fallback, and the older source:
//!      `GET https://cursor.com/api/usage-summary` (Cookie + Accept: application/json, 15 s).
//!      Reply:
//!      ```text
//!      { billingCycleEnd, membershipType, isUnlimited,
//!        individualUsage: { plan: { totalPercentUsed, apiPercentUsed, used, limit, breakdown },
//!                           onDemand: { enabled, used, limit } } }
//!      ```
//!      Cursor meters a percentage of the allowance, not requests: the dashboard's
//!      "Included usage · N% used" is totalPercentUsed. On the free plan used/limit are always 0
//!      (the allowance arrives as breakdown.bonus), so reading used/limit would report 10 % as 0 %.
//!      0 is a reading, not a gap (upstream's lesson). "API usage" is listed separately when
//!      apiPercentUsed > 0; "On demand" when onDemand has a real limit.
//!
//! SQLite opening rule: `mode=ro` first (it sees the token the editor just rotated into the WAL),
//! then `immutable=1` (once the editor has exited and the -shm is gone, mode=ro fails to open; by
//! then the WAL has been checkpointed, so ignoring it costs nothing).
//! Read only, never written; token values never reach logs, events or the UI.

use crate::usage::{duration_between_ms, LimitWindow, UsageSnapshot};
use crate::AppState;
use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager};

const ENDPOINT: &str = "https://cursor.com/api/usage-summary";
const DASHBOARD_ENDPOINT: &str = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage";
const POLL_SECS: u64 = 300;

static REFRESH: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

pub fn request_refresh() {
    REFRESH.store(true, std::sync::atomic::Ordering::Relaxed);
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Windows: %APPDATA%\Cursor\User\globalStorage\state.vscdb (macOS: ~/Library/Application Support/Cursor/...)
pub fn store_url() -> Option<PathBuf> {
    dirs::config_dir().map(|c| c.join("Cursor").join("User").join("globalStorage").join("state.vscdb"))
}

fn store_path() -> PathBuf {
    crate::config::config_path().with_file_name("cursor.json")
}

pub fn load_persisted() -> UsageSnapshot {
    std::fs::read_to_string(store_path())
        .ok()
        .and_then(|t| serde_json::from_str::<UsageSnapshot>(&t).ok())
        .map(|mut s| {
            if !s.windows.is_empty() {
                s.status = "stale".into();
            }
            s
        })
        .unwrap_or_default()
}

fn persist(s: &UsageSnapshot) {
    if let Ok(t) = serde_json::to_string_pretty(s) {
        let _ = std::fs::write(store_path(), t);
    }
}

pub fn present() -> bool {
    store_url().map(|p| p.is_file()).unwrap_or(false)
}

// ---------------- SQLite, read only ----------------

/// mode=ro first, immutable=1 as the fallback (see the module doc)
fn open_ro(path: &std::path::Path) -> Option<rusqlite::Connection> {
    use rusqlite::OpenFlags;
    if !path.is_file() {
        return None;
    }
    if let Ok(c) = rusqlite::Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    ) {
        // Actually verify that reads work (with the -shm missing, open can succeed and the first query fail)
        if c.prepare("SELECT 1 FROM ItemTable LIMIT 1").and_then(|mut s| s.query([]).map(|_| ())).is_ok() {
            return Some(c);
        }
    }
    // Only the URI form takes immutable=1; a Windows path becomes file:///C:/... with \ → /
    let mut uri = String::from("file:///");
    uri.push_str(&path.to_string_lossy().replace('\\', "/").trim_start_matches('/').replace('#', "%23").replace('?', "%3F"));
    uri.push_str("?immutable=1");
    rusqlite::Connection::open_with_flags(
        &uri,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .ok()
}

fn item(conn: &rusqlite::Connection, key: &str) -> Option<String> {
    conn.query_row("SELECT value FROM ItemTable WHERE key = ?1", [key], |r| r.get::<_, String>(0))
        .ok()
        .filter(|s| !s.is_empty())
}

struct Creds {
    token: String,
    cookie: String,
    plan: Option<String>,
}

const SAFE_STORAGE_PREFIX: &str = "cursor-safe-storage:";

/// The safeStorage AES key: `os_crypt.encrypted_key` in the editor's `Local State`, unwrapped by DPAPI
#[cfg(windows)]
fn safe_storage_key() -> Option<Vec<u8>> {
    use base64::{engine::general_purpose::STANDARD, Engine as _};
    use windows::Win32::Foundation::{LocalFree, HLOCAL};
    use windows::Win32::Security::Cryptography::{CryptUnprotectData, CRYPT_INTEGER_BLOB};

    let path = dirs::config_dir()?.join("Cursor").join("Local State");
    let state: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(path).ok()?).ok()?;
    let wrapped = STANDARD.decode(state.get("os_crypt")?.get("encrypted_key")?.as_str()?).ok()?;
    let mut blob = wrapped.strip_prefix(b"DPAPI")?.to_vec();
    let input = CRYPT_INTEGER_BLOB { cbData: blob.len() as u32, pbData: blob.as_mut_ptr() };
    let mut out = CRYPT_INTEGER_BLOB::default();
    unsafe {
        CryptUnprotectData(&input, None, None, None, None, 0, &mut out).ok()?;
        let key = std::slice::from_raw_parts(out.pbData, out.cbData as usize).to_vec();
        let _ = LocalFree(HLOCAL(out.pbData as _));
        Some(key)
    }
}

#[cfg(not(windows))]
fn safe_storage_key() -> Option<Vec<u8>> {
    None
}

/// A value without the safeStorage marker passes through untouched (older builds wrote it in the clear).
/// None means the seal could not be opened: sending the sealed text only earns a 401.
fn unseal(value: String) -> Option<String> {
    let Some(sealed) = value.strip_prefix(SAFE_STORAGE_PREFIX) else { return Some(value) };
    open_safe_storage(sealed, &safe_storage_key()?)
}

fn open_safe_storage(sealed: &str, key: &[u8]) -> Option<String> {
    use base64::{engine::general_purpose::STANDARD, Engine as _};
    use ring::aead;

    let raw = STANDARD.decode(sealed.strip_prefix("v1:")?).ok()?;
    let body = raw.strip_prefix(b"v10")?;
    if body.len() < 12 + 16 {
        return None;
    }
    let (nonce, ct) = body.split_at(12);
    let key = aead::LessSafeKey::new(aead::UnboundKey::new(&aead::AES_256_GCM, key).ok()?);
    let nonce = aead::Nonce::try_assume_unique_for_key(nonce).ok()?;
    let mut buf = ct.to_vec();
    let plain = key.open_in_place(nonce, aead::Aad::empty(), &mut buf).ok()?;
    std::str::from_utf8(plain).ok().filter(|s| !s.is_empty()).map(str::to_string)
}

/// Re-read every time: the editor rotates the token, and holding on to an old value signs us out
fn read_credentials() -> Option<Creds> {
    let path = store_url()?;
    let conn = open_ro(&path)?;
    let token = unseal(item(&conn, "cursorAuth/accessToken")?)?;
    let auth_id = item(&conn, "cursorAuth/stripeMembershipAuthId")?;
    let plan = item(&conn, "cursorAuth/stripeMembershipType");
    Some(Creds { cookie: session_cookie(&auth_id, &token), token, plan })
}

/// cursor.com's own cookie: the bare user id (the auth id is `<provider>|<user id>`), then `::` URL-encoded
fn session_cookie(auth_id: &str, token: &str) -> String {
    let user_id = auth_id.rsplit('|').next().unwrap_or(auth_id);
    format!("WorkosCursorSessionToken={user_id}%3A%3A{token}")
}

/// For doctor: contains no secret values
pub fn probe() -> String {
    let Some(p) = store_url() else { return "Cursor: cannot locate %APPDATA%".into() };
    if !p.is_file() {
        return format!("Cursor: {} not found (not installed, or not signed in)", p.display());
    }
    match read_credentials() {
        Some(c) => format!(
            "Cursor: session borrowed (cookie {} chars, plan={})",
            c.cookie.len(),
            c.plan.unwrap_or_else(|| "?".into())
        ),
        None => format!("Cursor: {} exists but cursorAuth/* could not be read (editor not signed in, or SQLite failed to open)", p.display()),
    }
}

// ---------------- Parsing ----------------

fn pct(v: Option<&serde_json::Value>) -> Option<f64> {
    v.and_then(|x| x.as_f64()).map(|p| (p / 100.0).clamp(0.0, 1.0))
}

fn parse_iso(v: Option<&serde_json::Value>) -> Option<u64> {
    v.and_then(|x| x.as_str())
        .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
        .map(|d| d.timestamp_millis().max(0) as u64)
}

/// usage-summary → (windows, note). When there are no windows the note says why (Unlimited / free plan without an allowance)
pub fn parse_summary(v: &serde_json::Value) -> (Vec<LimitWindow>, String) {
    let resets_at = parse_iso(v.get("billingCycleEnd"));
    let duration_ms = duration_between_ms(parse_iso(v.get("billingCycleStart")), resets_at);
    let usage = v.get("individualUsage").cloned().unwrap_or(serde_json::Value::Null);
    let plan = usage.get("plan").cloned().unwrap_or(serde_json::Value::Null);
    let mut out = Vec::new();
    // Headline = the dashboard number; 0 is a reading too
    if let Some(total) = pct(plan.get("totalPercentUsed")) {
        out.push(LimitWindow { id: "included".into(), label: "Included usage".into(), used: total, resets_at, duration_ms, ..Default::default() });
    }
    if let Some(api) = pct(plan.get("apiPercentUsed")) {
        if api > 0.0 {
            out.push(LimitWindow { id: "api".into(), label: "API usage".into(), used: api, resets_at, duration_ms, ..Default::default() });
        }
    }
    if let Some(od) = usage.get("onDemand") {
        let enabled = od.get("enabled").and_then(|x| x.as_bool()).unwrap_or(false);
        let limit = od.get("limit").and_then(|x| x.as_f64()).unwrap_or(0.0);
        let used = od.get("used").and_then(|x| x.as_f64());
        if enabled && limit > 0.0 {
            if let Some(u) = used {
                out.push(LimitWindow {
                    id: "on_demand".into(),
                    label: "On demand".into(),
                    used: (u / limit).clamp(0.0, 1.0),
                    resets_at, duration_ms, ..Default::default()
                });
            }
        }
    }
    if !out.is_empty() {
        return (out, String::new());
    }
    let membership = v.get("membershipType").and_then(|x| x.as_str()).unwrap_or("this");
    let note = if v.get("isUnlimited").and_then(|x| x.as_bool()) == Some(true) {
        format!("Unlimited on the {membership} plan — nothing to meter")
    } else {
        format!("The {membership} plan has nothing for Cursor to meter yet")
    };
    (out, note)
}

fn parse_ms(v: Option<&serde_json::Value>) -> Option<u64> {
    v.and_then(|x| x.as_str().and_then(|s| s.parse().ok()).or_else(|| x.as_u64())).filter(|&ms| ms > 0)
}

/// GetCurrentPeriodUsage → windows. This is what the editor's own Usage panel shows, including the
/// weekly allowance of the newer plans (usage-summary still reports the monthly cycle there, at 0 %).
/// Cycle bounds are epoch-ms strings; spend limits are cents.
pub fn parse_dashboard(v: &serde_json::Value) -> Vec<LimitWindow> {
    let resets_at = parse_ms(v.get("billingCycleEnd"));
    let duration_ms = duration_between_ms(parse_ms(v.get("billingCycleStart")), resets_at);
    let plan = v.get("planUsage").cloned().unwrap_or(serde_json::Value::Null);
    let mut out = Vec::new();
    if let Some(total) = pct(plan.get("totalPercentUsed")) {
        out.push(LimitWindow { id: "included".into(), label: "Included usage".into(), used: total, resets_at, duration_ms, ..Default::default() });
    }
    if let Some(api) = pct(plan.get("apiPercentUsed")).filter(|&a| a > 0.0) {
        out.push(LimitWindow { id: "api".into(), label: "API usage".into(), used: api, resets_at, duration_ms, ..Default::default() });
    }
    let spend = v.get("spendLimitUsage");
    let limit = spend.and_then(|s| s.get("individualLimit")).and_then(|x| x.as_f64()).unwrap_or(0.0);
    if limit > 0.0 {
        let used = spend.and_then(|s| s.get("individualUsed")).and_then(|x| x.as_f64()).unwrap_or(0.0);
        out.push(LimitWindow { id: "on_demand".into(), label: "On demand".into(), used: (used / limit).clamp(0.0, 1.0), resets_at, duration_ms, ..Default::default() });
    }
    out
}

enum FetchErr {
    NeedsAuth,
    Other(String),
}

fn status_err(e: ureq::Error) -> FetchErr {
    match e {
        ureq::Error::Status(401 | 403, _) => FetchErr::NeedsAuth,
        ureq::Error::Status(code, _) => FetchErr::Other(format!("HTTP {code}")),
        e => FetchErr::Other(format!("{e}")),
    }
}

fn fetch_dashboard(token: &str) -> Result<serde_json::Value, FetchErr> {
    let agent = ureq::AgentBuilder::new().timeout(Duration::from_secs(15)).build();
    agent
        .post(DASHBOARD_ENDPOINT)
        .set("Authorization", &format!("Bearer {token}"))
        .set("Content-Type", "application/json")
        .set("Connect-Protocol-Version", "1")
        .send_string("{}")
        .map_err(status_err)?
        .into_json::<serde_json::Value>()
        .map_err(|e| FetchErr::Other(format!("parse: {e}")))
}

fn fetch_once(cookie: &str) -> Result<serde_json::Value, FetchErr> {
    let agent = ureq::AgentBuilder::new().timeout(Duration::from_secs(15)).build();
    agent
        .get(ENDPOINT)
        .set("Cookie", cookie)
        .set("Accept", "application/json")
        .call()
        .map_err(status_err)?
        .into_json::<serde_json::Value>()
        .map_err(|e| FetchErr::Other(format!("parse: {e}")))
}

fn cap(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
        None => String::new(),
    }
}

fn read_once(prev: &UsageSnapshot) -> UsageSnapshot {
    let mut snap = prev.clone();
    let Some(creds) = read_credentials() else {
        snap.status = "needsAuth".into();
        snap.note = "Sign in to Cursor (the editor) to see usage.".into();
        return snap;
    };
    if let Ok(v) = fetch_dashboard(&creds.token) {
        let windows = parse_dashboard(&v);
        if !windows.is_empty() {
            snap.fetched_at = now_ms();
            snap.status = "ok".into();
            snap.windows = windows;
            snap.note = creds.plan.as_deref().map(|p| format!("{} · via Cursor", cap(p))).unwrap_or_default();
            return snap;
        }
    }
    match fetch_once(&creds.cookie) {
        Ok(v) => {
            let (windows, note) = parse_summary(&v);
            snap.fetched_at = now_ms();
            if windows.is_empty() {
                snap.status = "none".into();
                snap.windows.clear();
                snap.note = note;
            } else {
                snap.status = "ok".into();
                snap.windows = windows;
                snap.note = match (&creds.plan, v.get("membershipType").and_then(|x| x.as_str())) {
                    (_, Some(m)) => format!("{} · via Cursor", cap(m)),
                    (Some(p), None) => format!("{} · via Cursor", cap(p)),
                    _ => String::new(),
                };
            }
        }
        Err(FetchErr::NeedsAuth) => {
            snap.status = "needsAuth".into();
            snap.note = "Cursor session was rejected — sign in again in the editor".into();
        }
        Err(FetchErr::Other(msg)) => {
            // Stale beats invented: keep the old reading, marked stale
            snap.status = if snap.windows.is_empty() { "error" } else { "stale" }.into();
            snap.note = msg;
        }
    }
    snap
}

fn broadcast(app: &AppHandle, snap: UsageSnapshot) {
    let st = app.state::<AppState>();
    *st.cursor.lock().unwrap() = snap.clone();
    persist(&snap);
    let _ = app.emit("cursor", &snap);
}

fn sleep_interruptible(secs: u64) {
    for _ in 0..secs {
        if REFRESH.swap(false, std::sync::atomic::Ordering::Relaxed) {
            return;
        }
        std::thread::sleep(Duration::from_secs(1));
    }
}

pub fn start(app: AppHandle) {
    std::thread::spawn(move || {
        {
            let st = app.state::<AppState>();
            let snap = st.cursor.lock().unwrap().clone();
            let _ = app.emit("cursor", &snap);
        }
        if !present() {
            broadcast(&app, UsageSnapshot { status: "absent".into(), ..Default::default() });
            loop {
                sleep_interruptible(600); // Cursor is not installed: look again every 10 minutes
                if present() {
                    break;
                }
            }
        }
        loop {
            let prev = {
                let st = app.state::<AppState>();
                let s = st.cursor.lock().unwrap().clone();
                s
            };
            let snap = read_once(&prev);
            if snap.status == "error" || snap.status == "stale" {
                crate::applog(&format!("cursor: {}", snap.note));
            }
            broadcast(&app, snap);
            sleep_interruptible(POLL_SECS);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn summary(start: serde_json::Value, end: serde_json::Value) -> Vec<LimitWindow> {
        parse_summary(&serde_json::json!({
            "billingCycleStart": start, "billingCycleEnd": end,
            "individualUsage": {"plan": {"totalPercentUsed": 10, "apiPercentUsed": 20},
                "onDemand": {"enabled": true, "used": 5, "limit": 10}}
        })).0
    }

    fn seal(plain: &str, key: &[u8], nonce: [u8; 12]) -> String {
        use base64::{engine::general_purpose::STANDARD, Engine as _};
        use ring::aead;
        let k = aead::LessSafeKey::new(aead::UnboundKey::new(&aead::AES_256_GCM, key).unwrap());
        let mut buf = plain.as_bytes().to_vec();
        k.seal_in_place_append_tag(aead::Nonce::assume_unique_for_key(nonce), aead::Aad::empty(), &mut buf).unwrap();
        format!("v1:{}", STANDARD.encode([b"v10".as_slice(), &nonce, &buf].concat()))
    }

    #[test]
    fn safe_storage_values_open_with_the_right_key_only() {
        let key = [7u8; 32];
        let sealed = seal("tok", &key, [1; 12]);
        assert_eq!(open_safe_storage(&sealed, &key).as_deref(), Some("tok"));
        assert_eq!(open_safe_storage(&sealed, &[8u8; 32]), None);
        assert_eq!(open_safe_storage("not base64!", &key), None);
    }

    #[test]
    fn clear_tokens_pass_through_unseal() {
        assert_eq!(unseal("plain.jwt.value".into()).as_deref(), Some("plain.jwt.value"));
    }

    #[test]
    fn the_cookie_carries_the_bare_user_id() {
        assert_eq!(session_cookie("google-oauth2|user_01", "t"), "WorkosCursorSessionToken=user_01%3A%3At");
        assert_eq!(session_cookie("user_01", "t"), "WorkosCursorSessionToken=user_01%3A%3At");
    }

    #[test]
    fn the_weekly_dashboard_reading_is_the_headline() {
        let ws = parse_dashboard(&serde_json::json!({
            "billingCycleStart": "1794399884850", "billingCycleEnd": "1795004684850",
            "planUsage": {"autoPercentUsed": 19.458288190682556, "totalPercentUsed": 19.458288190682556},
            "spendLimitUsage": {"limitType": "user"}
        }));
        assert_eq!(ws.len(), 1);
        assert_eq!(ws[0].id, "included");
        assert!((ws[0].used - 0.19458).abs() < 1e-4);
        assert_eq!(ws[0].resets_at, Some(1795004684850));
        assert_eq!(ws[0].duration_ms, Some(7 * 86_400_000));
    }

    #[test]
    fn dashboard_spend_limits_become_on_demand() {
        let ws = parse_dashboard(&serde_json::json!({
            "planUsage": {"totalPercentUsed": 0},
            "spendLimitUsage": {"individualLimit": 2000, "individualUsed": 500}
        }));
        assert_eq!(ws.iter().map(|w| (w.id.as_str(), w.used)).collect::<Vec<_>>(), [("included", 0.0), ("on_demand", 0.25)]);
    }

    /// Reads this machine's signed-in editor; prints nothing secret
    #[test]
    #[ignore]
    fn live_usage_summary() {
        let creds = read_credentials().expect("could not read or unseal the Cursor session");
        match fetch_dashboard(&creds.token) {
            Ok(v) => println!("{:?}", parse_dashboard(&v).iter().map(|w| (&w.label, w.used, w.duration_ms)).collect::<Vec<_>>()),
            Err(FetchErr::NeedsAuth) => panic!("session rejected (401/403)"),
            Err(FetchErr::Other(e)) => panic!("{e}"),
        }
    }

    #[test]
    fn every_cursor_window_uses_the_reported_billing_cycle() {
        let ws = summary(serde_json::json!("2024-02-24T03:32:15.933Z"),
            serde_json::json!("2024-03-24T04:32:15.933+01:00"));
        assert_eq!(ws.iter().map(|w| w.id.as_str()).collect::<Vec<_>>(), ["included", "api", "on_demand"]);
        assert!(ws.iter().all(|w| w.duration_ms == Some(29 * 86_400_000)));
    }

    #[test]
    fn missing_invalid_or_nonpositive_billing_cycles_are_unknown() {
        let end = serde_json::json!("2026-10-01T00:00:00Z");
        for start in [serde_json::Value::Null, serde_json::json!("invalid"), end.clone(),
            serde_json::json!("2026-10-02T00:00:00Z")] {
            assert!(summary(start, end.clone()).iter().all(|w| w.duration_ms.is_none()));
        }
        for end in [serde_json::Value::Null, serde_json::json!("invalid")] {
            assert!(summary(serde_json::json!("2026-09-01T00:00:00Z"), end)
                .iter().all(|w| w.duration_ms.is_none()));
        }
    }
}
