//! Command Code GOAT quota, using the desktop app's read-only auth.json key.
//! Mirrors the macOS provider's /alpha billing requests and monthly headline.

use crate::usage::{LimitWindow, UsageSnapshot};
use crate::AppState;
use serde_json::Value;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager};

const API: &str = "https://api.commandcode.ai/alpha";
const POLL_SECS: u64 = 300;
static REFRESH: AtomicBool = AtomicBool::new(false);
static BACKOFF_UNTIL: AtomicU64 = AtomicU64::new(0);

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn auth_path() -> Option<PathBuf> {
    dirs::home_dir().map(|home| home.join(".commandcode").join("auth.json"))
}

fn store_path() -> PathBuf {
    crate::config::config_path().with_file_name("commandcode-usage.json")
}

pub fn present() -> bool {
    auth_path().is_some_and(|path| path.is_file())
        || std::env::var("COMMAND_CODE_API_KEY").is_ok_and(|key| !key.trim().is_empty())
}

fn credential() -> Option<String> {
    if let Ok(key) = std::env::var("COMMAND_CODE_API_KEY") {
        if !key.trim().is_empty() {
            return Some(key.trim().to_owned());
        }
    }
    let path = auth_path()?;
    let root: Value = serde_json::from_str(&std::fs::read_to_string(path).ok()?).ok()?;
    root.get("apiKey")?
        .as_str()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
}

pub fn load_persisted() -> UsageSnapshot {
    std::fs::read_to_string(store_path())
        .ok()
        .and_then(|text| serde_json::from_str::<UsageSnapshot>(&text).ok())
        .map(|mut snap| {
            if !snap.windows.is_empty() {
                snap.status = "stale".into();
            }
            BACKOFF_UNTIL.store(snap.backoff_until, Ordering::Relaxed);
            snap
        })
        .unwrap_or_default()
}

pub fn request_refresh() {
    REFRESH.store(true, Ordering::Relaxed);
}

enum FetchError {
    Auth,
    RateLimited,
    Other(String),
}

fn get(path: &str, token: &str, query: &[(&str, &str)]) -> Result<Value, FetchError> {
    let mut request = ureq::get(&format!("{API}{path}"))
        .set("Authorization", &format!("Bearer {token}"))
        .set("User-Agent", "command-code-desktop")
        .set("x-command-code-version", "desktop")
        .set("Accept", "application/json")
        .timeout(Duration::from_secs(15));
    for (key, value) in query {
        request = request.query(key, value);
    }
    match request.call() {
        Ok(response) => response
            .into_json()
            .map_err(|e| FetchError::Other(format!("invalid JSON: {e}"))),
        Err(ureq::Error::Status(401 | 403, _)) => Err(FetchError::Auth),
        Err(ureq::Error::Status(429, _)) => Err(FetchError::RateLimited),
        Err(ureq::Error::Status(code, _)) => Err(FetchError::Other(format!("HTTP {code}"))),
        Err(error) => Err(FetchError::Other(error.to_string())),
    }
}

fn reset_at(value: Option<&Value>) -> Option<u64> {
    let value = value?;
    if let Some(stamp) = value.as_str() {
        return chrono::DateTime::parse_from_rfc3339(stamp)
            .ok()
            .map(|date| date.timestamp_millis().max(0) as u64);
    }
    let number = value.as_f64()?;
    if number <= 0.0 || !number.is_finite() {
        return None;
    }
    Some(if number > 1_000_000_000_000.0 {
        number as u64
    } else {
        (number * 1000.0) as u64
    })
}

fn window(id: &str, label: &str, value: &Value) -> Option<LimitWindow> {
    let cap = value.get("cap")?.as_f64()?;
    if cap <= 0.0 || !cap.is_finite() {
        return None;
    }
    let used = value.get("used").and_then(Value::as_f64).unwrap_or(0.0);
    Some(LimitWindow {
        id: id.into(),
        label: label.into(),
        used: (used / cap).clamp(0.0, 1.0),
        resets_at: reset_at(value.get("resetAt")),
        ..Default::default()
    })
}

fn windows_from(summary: &Value, credits: &Value, subscription: &Value) -> Vec<LimitWindow> {
    let used = summary
        .get("totalCost")
        .and_then(Value::as_f64)
        .unwrap_or(0.0);
    let remaining = credits
        .pointer("/credits/monthlyCredits")
        .and_then(Value::as_f64)
        .unwrap_or(0.0);
    let cap = used + remaining;
    if cap <= 0.0 || !cap.is_finite() {
        return Vec::new();
    }
    let sub = subscription.get("data").unwrap_or(subscription);
    let mut windows = vec![LimitWindow {
        id: "monthly".into(),
        label: "Monthly limit".into(),
        used: (used / cap).clamp(0.0, 1.0),
        resets_at: reset_at(sub.get("currentPeriodEnd")),
        ..Default::default()
    }];
    if let Some(w) = credits
        .pointer("/windowLimits/fiveHour")
        .and_then(|v| window("fiveHour", "5h limit", v))
    {
        windows.push(w);
    }
    if let Some(w) = credits
        .pointer("/windowLimits/weekly")
        .and_then(|v| window("weekly", "Weekly limit", v))
    {
        windows.push(w);
    }
    windows
}

fn fetch(token: &str) -> Result<Vec<LimitWindow>, FetchError> {
    let whoami = get("/whoami", token, &[])?;
    let org = whoami.pointer("/org/id").and_then(Value::as_str);
    let org_query = org.map(|id| vec![("orgId", id)]).unwrap_or_default();
    let credits = get("/billing/credits", token, &org_query)?;
    let subscription = get("/billing/subscriptions", token, &org_query)?;
    let sub = subscription.get("data").unwrap_or(&subscription);
    let since = sub.get("currentPeriodStart").and_then(Value::as_str);
    let mut summary_query = org_query;
    if let Some(since) = since {
        summary_query.push(("since", since));
    }
    let summary = get("/usage/summary", token, &summary_query)?;
    if !summary.is_object() || !credits.is_object() {
        return Err(FetchError::Other("invalid billing response".into()));
    }
    Ok(windows_from(&summary, &credits, &subscription))
}

fn read_once() -> UsageSnapshot {
    let mut snap = UsageSnapshot::default();
    if !present() {
        snap.status = "absent".into();
        return snap;
    }
    let until = BACKOFF_UNTIL.load(Ordering::Relaxed);
    if until > now_ms() {
        snap.status = "backoff".into();
        snap.backoff_until = until;
        snap.note = "Command Code is rate limited; retrying shortly".into();
        return snap;
    }
    let Some(token) = credential() else {
        snap.status = "needsAuth".into();
        snap.note = "Sign in with the Command Code app to read your usage".into();
        return snap;
    };
    match fetch(&token) {
        Ok(windows) if !windows.is_empty() => {
            BACKOFF_UNTIL.store(0, Ordering::Relaxed);
            snap.status = "ok".into();
            snap.windows = windows;
            snap.fetched_at = now_ms();
            snap.note = "Command Code billing".into();
        }
        Ok(_) => {
            snap.status = "none".into();
            snap.note = "Command Code has nothing metered on this account yet".into();
        }
        Err(FetchError::Auth) => {
            snap.status = "needsAuth".into();
            snap.note =
                "Command Code rejected its sign-in; sign in again in the Command Code app".into();
        }
        Err(FetchError::RateLimited) => {
            let until = now_ms() + 60_000;
            BACKOFF_UNTIL.store(until, Ordering::Relaxed);
            snap.status = "backoff".into();
            snap.backoff_until = until;
            snap.note = "Command Code is rate limited; retrying shortly".into();
        }
        Err(FetchError::Other(error)) => {
            snap.status = "error".into();
            snap.note = format!("Command Code read failed ({error})");
        }
    }
    snap
}

fn broadcast(app: &AppHandle, mut snap: UsageSnapshot) {
    let state = app.state::<AppState>();
    let mut previous = state.commandcode.lock().unwrap();
    if snap.windows.is_empty()
        && !previous.windows.is_empty()
        && snap.status != "absent"
        && snap.status != "none"
    {
        snap.windows = previous.windows.clone();
        snap.fetched_at = previous.fetched_at;
    }
    *previous = snap.clone();
    drop(previous);
    if let Ok(text) = serde_json::to_string_pretty(&snap) {
        let _ = std::fs::write(store_path(), text);
    }
    let _ = app.emit("commandcode", &snap);
    crate::tray::refresh_menu(app);
}

pub fn start(app: AppHandle) {
    std::thread::spawn(move || loop {
        broadcast(&app, read_once());
        for _ in 0..POLL_SECS {
            if REFRESH.swap(false, Ordering::Relaxed) {
                break;
            }
            std::thread::sleep(Duration::from_secs(1));
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn monthly_and_extra_windows_match_command_code_billing() {
        let summary = serde_json::json!({"totalCost":50.5});
        let credits = serde_json::json!({"credits":{"monthlyCredits":19.5},"windowLimits":{
            "fiveHour":{"used":0,"cap":14,"resetAt":0},
            "weekly":{"used":22.45,"cap":35,"resetAt":1787857355088_u64}}});
        let sub = serde_json::json!({"data":{"currentPeriodEnd":"2026-09-13T15:21:27.000Z"}});
        let windows = windows_from(&summary, &credits, &sub);
        assert_eq!(
            windows.iter().map(|w| w.id.as_str()).collect::<Vec<_>>(),
            ["monthly", "fiveHour", "weekly"]
        );
        assert!((windows[0].used - 50.5 / 70.0).abs() < 0.0001);
        assert_eq!(windows[1].resets_at, None);
        assert_eq!(windows[2].resets_at, Some(1787857355088));
    }

    #[test]
    fn zero_cap_does_not_invent_usage() {
        assert!(windows_from(
            &serde_json::json!({"totalCost":0}),
            &serde_json::json!({"credits":{}}),
            &serde_json::json!({})
        )
        .is_empty());
    }
}
