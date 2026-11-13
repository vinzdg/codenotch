//! Mistral AI / Mistral Vibe monthly budget adapter.
//!
//! Endpoint: GET https://api.mistral.ai/v1/billing/budget (with optional plan metadata from
//! /v1/billing/subscription), authenticated with `Authorization: Bearer <MISTRAL_API_KEY>`.
//! Credentials are read-only and borrowed in precedence order:
//!   1. `MISTRAL_API_KEY` environment variable
//!   2. `%APPDATA%/codenotch/mistral.json` (`{"api_key":"..."}`)
//!   3. Mistral Vibe CLI `$VIBE_HOME/.env` or `~/.vibe/.env` (`MISTRAL_API_KEY=...`)
//!   4. OpenCode `auth.json` (`"mistral"` entry)
//!   5. Windows Credential Manager (`codenotch:mistral`)

use crate::usage::{LimitWindow, UsageSnapshot};
use crate::AppState;
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager};

const API: &str = "https://api.mistral.ai/v1";
const POLL_SECS: u64 = 300;
const BACKOFF_BASE_SECS: u64 = 60;
const BACKOFF_CAP_SECS: u64 = 900;
const THIRTY_DAYS_MS: u64 = 30 * 24 * 60 * 60 * 1000;

static REFRESH: AtomicBool = AtomicBool::new(false);
static BACKOFF_UNTIL: AtomicU64 = AtomicU64::new(0);
static CONSECUTIVE_429: AtomicU32 = AtomicU32::new(0);

pub fn request_refresh() {
    BACKOFF_UNTIL.store(0, Ordering::Relaxed);
    CONSECUTIVE_429.store(0, Ordering::Relaxed);
    REFRESH.store(true, Ordering::Relaxed);
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn store_path() -> PathBuf {
    crate::config::config_path().with_file_name("mistral-usage.json")
}

fn key_file() -> PathBuf {
    crate::config::config_path().with_file_name("mistral.json")
}

pub fn load_persisted() -> UsageSnapshot {
    std::fs::read_to_string(store_path())
        .ok()
        .and_then(|t| serde_json::from_str::<UsageSnapshot>(&t).ok())
        .map(|mut s| {
            if !s.windows.is_empty() {
                s.status = "stale".into();
            }
            BACKOFF_UNTIL.store(s.backoff_until, Ordering::Relaxed);
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

fn parse_env_key(text: &str) -> Option<String> {
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let line = line.strip_prefix("export ").map(str::trim_start).unwrap_or(line);
        let Some((k, v)) = line.split_once('=') else { continue };
        if k.trim() != "MISTRAL_API_KEY" {
            continue;
        }
        let v = v.trim();
        let unquoted = if let Some(rest) = v.strip_prefix('"') {
            rest.split_once('"').map(|(inner, _)| inner).unwrap_or(v)
        } else if let Some(rest) = v.strip_prefix('\'') {
            rest.split_once('\'').map(|(inner, _)| inner).unwrap_or(v)
        } else {
            v.split('#').next().unwrap_or(v).trim()
        };
        if !unquoted.is_empty() {
            return Some(unquoted.to_string());
        }
    }
    None
}

fn parse_key_json(text: &str) -> Option<String> {
    let v: Value = serde_json::from_str(text).ok()?;
    v.get("api_key")
        .or_else(|| v.get("apiKey"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
}

fn vibe_env_path() -> Option<PathBuf> {
    if let Ok(home) = std::env::var("VIBE_HOME") {
        let trimmed = home.trim();
        if !trimmed.is_empty() {
            return Some(PathBuf::from(trimmed).join(".env"));
        }
    }
    dirs::home_dir().map(|h| h.join(".vibe").join(".env"))
}

fn opencode_auth_key() -> Option<String> {
    let mut paths = Vec::new();
    if let Some(d) = dirs::data_local_dir() {
        paths.push(d.join("opencode").join("auth.json"));
    }
    if let Some(h) = dirs::home_dir() {
        paths.push(h.join(".local").join("share").join("opencode").join("auth.json"));
    }
    for path in paths {
        let Ok(text) = std::fs::read_to_string(path) else { continue };
        let Ok(root) = serde_json::from_str::<Value>(&text) else { continue };
        let Some(entry) = root.get("mistral") else { continue };
        let key = entry
            .as_str()
            .or_else(|| entry.get("key").and_then(Value::as_str))
            .or_else(|| entry.get("apiKey").and_then(Value::as_str))
            .or_else(|| entry.get("access").and_then(Value::as_str))
            .map(str::trim)
            .filter(|s| !s.is_empty());
        if let Some(k) = key {
            return Some(k.to_string());
        }
    }
    None
}

/// Credential Manager blobs carry no encoding marker: `cmdkey` and the Windows
/// credential dialog write UTF-16LE, while programmatic writers write plain UTF-8.
/// Sniff NUL bytes to tell them apart.
fn decode_cred_blob(bytes: &[u8]) -> Option<String> {
    let raw = if bytes.len() >= 2 && bytes.len() % 2 == 0 && bytes.contains(&0) {
        let u16s: Vec<u16> = bytes
            .chunks_exact(2)
            .map(|c| u16::from_le_bytes([c[0], c[1]]))
            .collect();
        String::from_utf16(&u16s).ok()?
    } else {
        String::from_utf8(bytes.to_vec()).ok()?
    };
    let trimmed = raw.trim_matches('\0').trim().to_string();
    (!trimmed.is_empty()).then_some(trimmed)
}

#[cfg(windows)]
fn cred_manager_key() -> Option<String> {
    use windows::core::PCWSTR;
    use windows::Win32::Security::Credentials::{CredFree, CredReadW, CREDENTIALW, CRED_TYPE_GENERIC};
    let target: Vec<u16> = "codenotch:mistral\0".encode_utf16().collect();
    let mut pcred: *mut CREDENTIALW = std::ptr::null_mut();
    unsafe {
        if CredReadW(PCWSTR(target.as_ptr()), CRED_TYPE_GENERIC, 0, &mut pcred).is_err() || pcred.is_null() {
            return None;
        }
        let c = &*pcred;
        let bytes = if c.CredentialBlobSize > 0 && !c.CredentialBlob.is_null() {
            std::slice::from_raw_parts(c.CredentialBlob, c.CredentialBlobSize as usize).to_vec()
        } else {
            Vec::new()
        };
        CredFree(pcred as *const core::ffi::c_void);
        decode_cred_blob(&bytes)
    }
}

#[cfg(not(windows))]
fn cred_manager_key() -> Option<String> {
    None
}

fn read_text(path: &Path) -> Option<String> {
    std::fs::read_to_string(path).ok()
}

fn credential() -> Option<(&'static str, String)> {
    if let Ok(key) = std::env::var("MISTRAL_API_KEY") {
        let trimmed = key.trim();
        if !trimmed.is_empty() {
            return Some(("MISTRAL_API_KEY", trimmed.to_string()));
        }
    }
    if let Some(k) = read_text(&key_file()).as_deref().and_then(parse_key_json) {
        return Some(("mistral.json", k));
    }
    if let Some(k) = vibe_env_path().and_then(|p| read_text(&p)).as_deref().and_then(parse_env_key) {
        return Some(("~/.vibe/.env", k));
    }
    if let Some(k) = opencode_auth_key() {
        return Some(("opencode/auth.json", k));
    }
    if let Some(k) = cred_manager_key() {
        return Some(("Credential Manager", k));
    }
    None
}

pub fn present() -> bool {
    credential().is_some()
}

pub fn probe() -> String {
    match credential() {
        Some((src, _)) => format!("mistral: credential from {src}"),
        None => "mistral: absent (no MISTRAL_API_KEY, mistral.json, or ~/.vibe/.env)".into(),
    }
}

// ---------------- API Fetch & Parsing ----------------

enum FetchError {
    Auth,
    RateLimited(Option<u64>),
    Other(String),
}

fn get_json(path: &str, token: &str) -> Result<Value, FetchError> {
    let resp = ureq::get(&format!("{API}{path}"))
        .set("Authorization", &format!("Bearer {token}"))
        .set("Accept", "application/json")
        .timeout(Duration::from_secs(15))
        .call();
    match resp {
        Ok(r) => r.into_json().map_err(|e| FetchError::Other(format!("invalid JSON: {e}"))),
        Err(ureq::Error::Status(401 | 403, _)) => Err(FetchError::Auth),
        Err(ureq::Error::Status(429, r)) => {
            let secs = r.header("Retry-After").and_then(|s| s.trim().parse::<u64>().ok());
            Err(FetchError::RateLimited(secs))
        }
        Err(ureq::Error::Status(code, _)) => Err(FetchError::Other(format!("HTTP {code}"))),
        Err(err) => Err(FetchError::Other(err.to_string())),
    }
}

fn format_currency(amount: f64, code: Option<&str>) -> String {
    match code.map(|c| c.to_ascii_uppercase()).as_deref() {
        None | Some("USD") => format!("${amount:.2}"),
        Some("EUR") => format!("€{amount:.2}"),
        Some("GBP") => format!("£{amount:.2}"),
        Some(other) => format!("{other} {amount:.2}"),
    }
}

fn parse_budget_window(obj: &Value, id: &str, name: &str) -> Option<LimitWindow> {
    let pct = obj.get("usage_percentage")?.as_f64()?;
    if !pct.is_finite() || pct < 0.0 {
        return None;
    }
    let used = (pct / 100.0).clamp(0.0, 1.0);
    let initial = obj
        .get("initial_budget")
        .and_then(Value::as_f64)
        .filter(|b| b.is_finite() && *b > 0.0);
    let currency = obj
        .get("currency")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let label = match initial {
        Some(total) => format!(
            "{name} ({} / {})",
            format_currency(used * total, currency),
            format_currency(total, currency)
        ),
        None => name.to_string(),
    };
    let resets_at = obj
        .get("reset_at")
        .and_then(Value::as_str)
        .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
        .map(|dt| dt.timestamp_millis().max(0) as u64);
    Some(LimitWindow {
        id: id.into(),
        label,
        used,
        resets_at,
        duration_ms: Some(THIRTY_DAYS_MS),
        ..Default::default()
    })
}

/// The budget endpoint returns either `{"vibe_budget": ..., "api_budget": ...}` or a flat
/// single-budget object; both describe the same monthly window, so one table drives both.
const BUDGETS: [(&str, &str); 2] = [("vibe_budget", "Vibe Budget"), ("api_budget", "API Budget")];

fn parse_budgets(v: &Value) -> Vec<LimitWindow> {
    let mut windows = Vec::new();
    for (id, label) in BUDGETS {
        if let Some(w) = v.get(id).and_then(|o| parse_budget_window(o, id.trim_end_matches("_budget"), label)) {
            windows.push(w);
        }
    }
    if windows.is_empty() {
        if let Some(w) = parse_budget_window(v, "api", "API Budget") {
            windows.push(w);
        }
    }
    // Highest usage first (keeping Vibe ahead of API on ties) so windows[0] drives the ring.
    windows.sort_by(|a, b| b.used.total_cmp(&a.used));
    windows
}

fn note_from_subscription(v: &Value) -> String {
    let Some(plan) = v.get("plan_name").and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()) else {
        return String::new();
    };
    let payg = v.get("vibe_payg_enabled").and_then(Value::as_bool).unwrap_or(false)
        || v.get("payg_enabled").and_then(Value::as_bool).unwrap_or(false);
    if payg {
        format!("{plan} plan · PAYG on")
    } else {
        format!("{plan} plan")
    }
}

fn read_once(prev: &UsageSnapshot) -> UsageSnapshot {
    let Some((_, token)) = credential() else {
        return UsageSnapshot { status: "absent".into(), ..Default::default() };
    };
    let now = now_ms();
    let until = BACKOFF_UNTIL.load(Ordering::Relaxed);
    if until > now {
        let mut s = prev.clone();
        if s.status != "ok" && !s.windows.is_empty() {
            s.status = "stale".into();
        }
        s.backoff_until = until;
        return s;
    }

    match get_json("/billing/budget", &token) {
        Ok(budget) => {
            CONSECUTIVE_429.store(0, Ordering::Relaxed);
            BACKOFF_UNTIL.store(0, Ordering::Relaxed);
            let windows = parse_budgets(&budget);
            if windows.is_empty() {
                return UsageSnapshot {
                    status: "none".into(),
                    fetched_at: now,
                    note: "Mistral reported no active budget on this account".into(),
                    ..Default::default()
                };
            }
            let note = get_json("/billing/subscription", &token)
                .ok()
                .map(|sub| note_from_subscription(&sub))
                .unwrap_or_default();
            UsageSnapshot {
                status: "ok".into(),
                windows,
                fetched_at: now,
                note,
                backoff_until: 0,
                ..Default::default()
            }
        }
        Err(FetchError::Auth) => UsageSnapshot {
            status: "needsAuth".into(),
            note: "Mistral API key was rejected — check MISTRAL_API_KEY or ~/.vibe/.env".into(),
            ..Default::default()
        },
        Err(FetchError::RateLimited(retry_after)) => {
            let n = CONSECUTIVE_429.fetch_add(1, Ordering::Relaxed);
            let secs = retry_after
                .unwrap_or_else(|| BACKOFF_BASE_SECS.saturating_mul(1u64 << n.min(4)))
                .clamp(BACKOFF_BASE_SECS, BACKOFF_CAP_SECS);
            let deadline = now + secs * 1000;
            BACKOFF_UNTIL.store(deadline, Ordering::Relaxed);
            let mut s = prev.clone();
            if !s.windows.is_empty() {
                s.status = "stale".into();
            } else {
                s.status = "backoff".into();
            }
            s.backoff_until = deadline;
            s.note = format!("Rate limited — retrying in {secs}s");
            s
        }
        Err(FetchError::Other(msg)) => {
            let mut s = prev.clone();
            if !s.windows.is_empty() {
                s.status = "stale".into();
            } else {
                s.status = "error".into();
            }
            s.note = format!("Live read failed ({msg})");
            s
        }
    }
}

pub fn start(app: AppHandle) {
    std::thread::spawn(move || {
        {
            let st = app.state::<AppState>();
            let snap = st.mistral.lock().unwrap().clone();
            let _ = app.emit("mistral", &snap);
        }
        let mut last_poll = 0u64;
        loop {
            let forced = REFRESH.swap(false, Ordering::Relaxed);
            let due = now_ms().saturating_sub(last_poll) >= POLL_SECS * 1000;
            if forced || due || last_poll == 0 {
                let prev = app.state::<AppState>().mistral.lock().unwrap().clone();
                let snap = read_once(&prev);
                last_poll = now_ms();
                if snap.status != "absent" {
                    persist(&snap);
                } else {
                    let _ = std::fs::remove_file(store_path());
                }
                {
                    let st = app.state::<AppState>();
                    *st.mistral.lock().unwrap() = snap.clone();
                }
                let _ = app.emit("mistral", &snap);
                crate::tray::refresh_menu(&app);
            }
            std::thread::sleep(Duration::from_secs(2));
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_vibe_and_api_budgets_highest_first() {
        let json: Value = serde_json::from_str(
            r#"{
                "vibe_budget": {
                    "usage_percentage": 54.5,
                    "initial_budget": 127.5,
                    "currency": "EUR",
                    "reset_at": "2026-12-01T00:00:00Z"
                },
                "api_budget": {
                    "usage_percentage": 0.0,
                    "initial_budget": 12.75,
                    "currency": "EUR",
                    "reset_at": "2026-12-01T00:00:00Z"
                }
            }"#,
        )
        .unwrap();
        let ws = parse_budgets(&json);
        assert_eq!(ws.len(), 2);
        assert_eq!(ws[0].id, "vibe");
        assert_eq!(ws[0].label, "Vibe Budget (€69.49 / €127.50)");
        assert!((ws[0].used - 0.545).abs() < 1e-9);
        assert!(ws[0].resets_at.is_some());
        assert_eq!(ws[0].duration_ms, Some(THIRTY_DAYS_MS));
        assert_eq!(ws[1].id, "api");
        assert_eq!(ws[1].label, "API Budget (€0.00 / €12.75)");
    }

    #[test]
    fn parses_flat_budget_and_rejects_invalid_percentage() {
        let flat: Value = serde_json::from_str(
            r#"{"usage_percentage": 125.0, "initial_budget": 20.0, "currency": "USD"}"#,
        )
        .unwrap();
        let ws = parse_budgets(&flat);
        assert_eq!(ws.len(), 1);
        assert_eq!(ws[0].id, "api");
        assert!((ws[0].used - 1.0).abs() < 1e-9);
        assert_eq!(ws[0].label, "API Budget ($20.00 / $20.00)");

        let neg: Value = serde_json::from_str(r#"{"usage_percentage": -5.0}"#).unwrap();
        assert!(parse_budgets(&neg).is_empty());
    }

    #[test]
    fn parses_vibe_dotenv_and_mistral_json() {
        assert_eq!(
            parse_env_key("# comment\nexport MISTRAL_API_KEY=\"sk-test-123\"\n"),
            Some("sk-test-123".into())
        );
        assert_eq!(
            parse_env_key("MISTRAL_API_KEY='sk-single' # trailing\n"),
            Some("sk-single".into())
        );
        assert_eq!(parse_key_json(r#"{"api_key":"  sk-json  "}"#), Some("sk-json".into()));
        assert_eq!(parse_key_json(r#"{"apiKey":"sk-camel"}"#), Some("sk-camel".into()));
    }

    #[test]
    fn formats_subscription_note() {
        let v: Value = serde_json::from_str(r#"{"plan_name":"EDU","payg_enabled":false,"vibe_payg_enabled":false}"#).unwrap();
        assert_eq!(note_from_subscription(&v), "EDU plan");
        let p: Value = serde_json::from_str(r#"{"plan_name":"Pro","payg_enabled":true}"#).unwrap();
        assert_eq!(note_from_subscription(&p), "Pro plan · PAYG on");
    }

    #[test]
    fn decodes_utf8_and_utf16le_credential_blobs() {
        assert_eq!(decode_cred_blob(b"  sk-utf8 \n"), Some("sk-utf8".into()));
        let utf16: Vec<u8> = "sk-utf16".encode_utf16().flat_map(|u| u.to_le_bytes()).collect();
        assert_eq!(decode_cred_blob(&utf16), Some("sk-utf16".into()));
        assert_eq!(decode_cred_blob(b""), None);
    }
}
