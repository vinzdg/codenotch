//! Grok usage adapter, ported from the Mac app's `GrokLocalProvider` / `GrokUsage` / `GrokCredentials`.
//!
//! Data path (the same bargain the other providers strike: borrow the CLI's own session):
//!   1. Credential: Grok CLI signs in through `auth.x.ai` and writes the session to
//!      `%USERPROFILE%\.grok\auth.json`. Codenotch only ever reads it — refreshing is the CLI's
//!      job, and writing a new access token would race it for the file. The access token lives
//!      about six hours and only a running CLI renews it, so on a machine where grok is seldom run
//!      the file goes stale and the endpoint rejects it. Shortly before expiry Codenotch therefore
//!      runs `grok models` once, windowless (see "Token renewal"): the CLI renews the token from
//!      its refresh token as it starts and rewrites the file itself, and listing models spends no
//!      Grok Build allowance.
//!      The file is an object keyed by `<issuer>::<client_id>`; each entry carries `key` (the
//!      bearer token), `expires_at` and `email`.
//!   2. Endpoint: `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`
//!      (`Authorization: Bearer …`, `X-XAI-Token-Auth: xai-grok-cli`, `Accept: application/json`),
//!      the same one the CLI's own `/usage` asks. Reply:
//!      ```text
//!      { "config": { "currentPeriod": { "type": "USAGE_PERIOD_TYPE_WEEKLY", "start": …, "end": … },
//!                    "creditUsagePercent": 8.0,
//!                    "productUsage": [{ "product": "GrokBuild", "usagePercent": 8.0 }],
//!                    "billingPeriodStart": …, "billingPeriodEnd": … } }
//!      ```
//!      The credits payload is the ring: a weekly Grok Build allowance, and the only number this
//!      endpoint actually states. Grok's own charge date is not in it — `billingPeriodEnd` is a
//!      calendar-month usage ledger, not a bill — so none is shown rather than guessed at.
//!
//! Only a session minted by xAI itself is used. The file can also hold a customer IdP's token,
//! meant for that customer's private proxy; sending it to the public `cli-chat-proxy.grok.com`
//! would hand someone else's credential to the wrong host, so entries are filtered by issuer.
//! Read only, never written; token values never reach logs, events or the UI.

use crate::usage::{duration_between_ms, LimitWindow, UsageSnapshot};
use crate::AppState;
use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager};

const ENDPOINT: &str = "https://cli-chat-proxy.grok.com/v1/billing?format=credits";
const POLL_SECS: u64 = 300;

/// Only a session minted by xAI itself (see the module doc).
const TRUSTED_ISSUER: &str = "https://auth.x.ai";

static REFRESH: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

pub fn request_refresh() {
    REFRESH.store(true, std::sync::atomic::Ordering::Relaxed);
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// Windows: %USERPROFILE%\.grok\auth.json (macOS: ~/.grok/auth.json)
pub fn auth_path() -> Option<PathBuf> {
    dirs::home_dir().map(|h| h.join(".grok").join("auth.json"))
}

fn store_path() -> PathBuf {
    crate::config::config_path().with_file_name("grok.json")
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
    auth_path().map(|p| p.is_file()).unwrap_or(false)
}

// ---------------- Credentials ----------------

pub struct Creds {
    token: String,
    /// ms epoch; 0 = the entry did not say
    pub expires_at: u64,
    pub email: Option<String>,
}

impl Creds {
    pub fn is_expired(&self) -> bool {
        self.expires_at > 0 && self.expires_at <= now_ms()
    }
}

fn iso_ms(v: Option<&serde_json::Value>) -> Option<u64> {
    v.and_then(|x| x.as_str())
        .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
        .map(|d| d.timestamp_millis().max(0) as u64)
}

fn is_trusted(key: &str, entry: &serde_json::Value) -> bool {
    // The issuer is the part before `::`, compared whole: a prefix match also let
    // `https://auth.x.ai.example.com::id` through.
    key.split("::").next() == Some(TRUSTED_ISSUER)
        || entry.get("oidc_issuer").and_then(|x| x.as_str()) == Some(TRUSTED_ISSUER)
}

/// One signed-in CLI is the ordinary case; if several entries sit there, the one still live wins,
/// otherwise the first trusted one — matching the Mac app.
pub fn pick(root: &serde_json::Value) -> Option<Creds> {
    let map = root.as_object()?;
    let mut trusted: Vec<Creds> = Vec::new();
    for (key, entry) in map {
        if !is_trusted(key, entry) {
            continue;
        }
        let token = entry.get("key").and_then(|x| x.as_str()).unwrap_or_default();
        if token.is_empty() {
            continue;
        }
        trusted.push(Creds {
            token: token.to_string(),
            expires_at: iso_ms(entry.get("expires_at")).unwrap_or(0),
            email: entry.get("email").and_then(|x| x.as_str()).map(|s| s.to_string()),
        });
    }
    let now = now_ms();
    if let Some(i) = trusted.iter().position(|c| c.expires_at == 0 || c.expires_at > now) {
        return Some(trusted.swap_remove(i));
    }
    trusted.into_iter().next()
}

/// Re-read every time: the CLI rotates the token, and holding on to an old value signs us out
fn read_credentials() -> Option<Creds> {
    let path = auth_path()?;
    let text = std::fs::read_to_string(path).ok()?;
    let root: serde_json::Value = serde_json::from_str(&text).ok()?;
    pick(&root)
}

// ---------------- Token renewal (usage.rs's Claude renewer, pointed at the Grok CLI) ----------------

const RENEW_TIMEOUT_SECS: u64 = 30;

/// The Grok CLI: its own installer's `~/.grok/bin` first, then PATH
pub fn find_cli() -> Option<PathBuf> {
    let names = crate::usage::command_names("grok");
    let mut v = Vec::new();
    if let Some(h) = dirs::home_dir() {
        for n in &names {
            v.push(h.join(".grok").join("bin").join(n));
        }
    }
    if let Some(path) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&path) {
            for n in &names {
                v.push(dir.join(n));
            }
        }
    }
    v.into_iter().find(|p| p.is_file())
}

/// `grok models` starts up (where the CLI renews an aged token), prints the model list and exits:
/// no session, no transcript, no allowance spent. Output goes nowhere.
fn run_renewal(cli: &std::path::Path) -> std::io::Result<()> {
    use std::process::{Command, Stdio};
    let mut cmd = Command::new(cli);
    cmd.arg("models").stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    // Which session gets renewed is said here, never inherited: a GROK_HOME pointed elsewhere would
    // renew that copy while the file read here stayed stale
    if let Some(dir) = auth_path().as_deref().and_then(|p| p.parent()) {
        cmd.env("GROK_HOME", dir);
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    let mut child = cmd.spawn()?;
    let deadline = std::time::Instant::now() + Duration::from_secs(RENEW_TIMEOUT_SECS);
    while child.try_wait()?.is_none() {
        if std::time::Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    Ok(())
}

#[derive(Default)]
struct Renewer {
    attempted_for: Option<u64>,
    last_attempt: Option<u64>,
    /// Launches in a row that left `attempted_for` where it was
    failures: u32,
}

impl Renewer {
    /// Renews if the token is about to expire. Some(true) = the expiry moved; judged on the file, never on
    /// the exit status
    fn maybe_renew(&mut self, creds: &Creds) -> Option<bool> {
        let expires_at = (creds.expires_at > 0).then_some(creds.expires_at);
        let now = now_ms();
        // The CLI renews at its own five-minute mark, as Claude Code does, so the Claude timing and
        // retry policy carry over unchanged
        if !crate::usage::should_renew(expires_at, now, self.attempted_for, self.last_attempt, self.failures) {
            return None;
        }
        if self.attempted_for != expires_at {
            self.failures = 0;
        }
        self.last_attempt = Some(now);
        self.attempted_for = expires_at;
        self.failures = self.failures.saturating_add(1);
        let Some(cli) = find_cli() else {
            crate::applog("grok: token about to expire and no grok CLI found to renew it");
            return Some(false);
        };
        if let Err(e) = run_renewal(&cli) {
            crate::applog(&format!("grok: token renewal could not start ({}): {e}", cli.display()));
            return Some(false);
        }
        let after = read_credentials().map(|c| c.expires_at).unwrap_or(0);
        let renewed = after > creds.expires_at;
        crate::applog(&if renewed {
            format!("grok: token renewed via {}", cli.display())
        } else {
            format!("grok: ran {} but the token expiry did not move", cli.display())
        });
        Some(renewed)
    }
}

/// For doctor: contains no secret values
pub fn probe() -> String {
    let Some(p) = auth_path() else { return "Grok: cannot locate the home directory".into() };
    if !p.is_file() {
        return format!("Grok: {} not found (CLI not installed, or not signed in)", p.display());
    }
    match read_credentials() {
        // No account email: doctor output is what people paste into issues.
        Some(c) => format!(
            "Grok: session borrowed (token {} chars, {}); {}",
            c.token.len(),
            if c.is_expired() { "expired — run grok login" } else { "live" },
            match find_cli() {
                Some(p) => format!("renews via {}", p.display()),
                None => "no grok CLI found to renew it".into(),
            }
        ),
        None => format!(
            "Grok: {} exists but holds no usable xAI session (only a customer IdP entry, or the CLI is signed out)",
            p.display()
        ),
    }
}

// ---------------- Parsing ----------------

fn pct(v: Option<&serde_json::Value>) -> Option<f64> {
    v.and_then(|x| x.as_f64()).map(|p| (p / 100.0).clamp(0.0, 1.0))
}

/// "GrokBuild" → "Grok Build". The wire name is one word; the usage modal writes two.
pub fn humanize(name: &str) -> String {
    let mut out = String::with_capacity(name.len() + 2);
    for c in name.chars() {
        if c.is_uppercase() && !out.is_empty() {
            out.push(' ');
        }
        out.push(c);
    }
    out
}

/// credits → (windows, note). An empty list with a note means the account has nothing metered.
pub fn parse_credits(v: &serde_json::Value) -> (Vec<LimitWindow>, String) {
    let Some(config) = v.get("config") else {
        return (Vec::new(), "Grok returned no billing config".into());
    };
    let current = config.get("currentPeriod");
    let current_end = iso_ms(current.and_then(|p| p.get("end")));
    let resets_at = current_end.or_else(|| iso_ms(config.get("billingPeriodEnd")));
    let start = if current_end.is_some() {
        iso_ms(current.and_then(|p| p.get("start")))
    } else {
        iso_ms(config.get("billingPeriodStart"))
    };
    let duration_ms = duration_between_ms(start, resets_at);

    let mut out: Vec<LimitWindow> = Vec::new();
    let products = config.get("productUsage").and_then(|x| x.as_array());
    let headline_label = products
        .and_then(|p| p.first())
        .and_then(|p| p.get("product"))
        .and_then(|x| x.as_str())
        .map(humanize);

    if let Some(used) = pct(config.get("creditUsagePercent")) {
        out.push(LimitWindow {
            id: "credits".into(),
            label: headline_label.unwrap_or_else(|| "Grok Build".into()),
            used,
            resets_at,
            duration_ms,
            ..Default::default()
        });
    } else if let Some(products) = products {
        for product in products {
            let Some(used) = pct(product.get("usagePercent")) else { continue };
            let wire = product.get("product").and_then(|x| x.as_str());
            let label = wire.map(humanize).unwrap_or_else(|| "Usage".into());
            // The ring reads the window whose id is "credits"; using the wire name for the first
            // one left a valid bar on the card and a dash on the cell.
            let id = if out.is_empty() { "credits".to_string() } else { wire.unwrap_or(&label).to_string() };
            out.push(LimitWindow { id, label, used, resets_at, duration_ms, ..Default::default() });
        }
    }

    // A weekly plan pool (X Premium+, SuperGrok) states its window in `currentPeriod` and omits
    // the percentages until usage lands, so the branches above find nothing on a fresh period.
    // Grok's own /usage still shows a "Weekly limit" bar at 0 %, so mirror that rather than
    // reporting the account as unmetered.
    if out.is_empty() {
        let weekly = current
            .and_then(|p| p.get("type"))
            .and_then(|x| x.as_str())
            .map(|t| t.contains("WEEKLY"))
            .unwrap_or(false);
        if weekly {
            out.push(LimitWindow {
                id: "credits".into(),
                label: "Weekly limit".into(),
                used: 0.0,
                resets_at,
                ..Default::default()
            });
        }
    }

    if out.is_empty() {
        return (out, "Grok has nothing metered on this account yet".into());
    }
    (out, String::new())
}

enum FetchErr {
    NeedsAuth,
    RateLimited,
    Other(String),
}

fn fetch_once(token: &str) -> Result<serde_json::Value, FetchErr> {
    let agent = ureq::AgentBuilder::new().timeout(Duration::from_secs(15)).build();
    match agent
        .get(ENDPOINT)
        .set("Authorization", &format!("Bearer {token}"))
        .set("X-XAI-Token-Auth", "xai-grok-cli")
        .set("Accept", "application/json")
        .call()
    {
        Ok(r) => r.into_json::<serde_json::Value>().map_err(|e| FetchErr::Other(format!("parse: {e}"))),
        Err(ureq::Error::Status(401, _)) | Err(ureq::Error::Status(403, _)) => Err(FetchErr::NeedsAuth),
        Err(ureq::Error::Status(429, _)) => Err(FetchErr::RateLimited),
        Err(ureq::Error::Status(code, _)) => Err(FetchErr::Other(format!("HTTP {code}"))),
        Err(e) => Err(FetchErr::Other(format!("{e}"))),
    }
}

fn read_once(prev: &UsageSnapshot, renewer: &mut Renewer) -> UsageSnapshot {
    let mut snap = prev.clone();
    let Some(mut creds) = read_credentials() else {
        snap.status = "needsAuth".into();
        snap.note = "Run grok login — it signs in and refreshes the token this reads.".into();
        return snap;
    };
    if renewer.maybe_renew(&creds) == Some(true) {
        if let Some(fresh) = read_credentials() {
            creds = fresh;
        }
    }
    // An expired token is still worth sending: the CLI may have refreshed the file since it was
    // written, and only the endpoint can say. A 401 below is what actually decides it.
    match fetch_once(&creds.token) {
        Ok(v) => {
            let (windows, note) = parse_credits(&v);
            snap.fetched_at = now_ms();
            if windows.is_empty() {
                snap.status = "none".into();
                snap.windows.clear();
                snap.note = note;
            } else {
                snap.status = "ok".into();
                snap.windows = windows;
                snap.note = match creds.email {
                    Some(e) => format!("{e} · via Grok CLI"),
                    None => "via Grok CLI".into(),
                };
            }
        }
        Err(FetchErr::NeedsAuth) => {
            snap.status = "needsAuth".into();
            snap.note = "Grok session was rejected — run grok login again".into();
        }
        Err(FetchErr::RateLimited) => {
            snap.status = if snap.windows.is_empty() { "error" } else { "stale" }.into();
            snap.note = "Grok is rate limiting; the last reading stands".into();
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
    *st.grok.lock().unwrap() = snap.clone();
    persist(&snap);
    let _ = app.emit("grok", &snap);
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
            let snap = st.grok.lock().unwrap().clone();
            let _ = app.emit("grok", &snap);
        }
        if !present() {
            broadcast(&app, UsageSnapshot { status: "absent".into(), ..Default::default() });
            loop {
                sleep_interruptible(600); // Grok CLI is not installed: look again every 10 minutes
                if present() {
                    break;
                }
            }
        }
        let mut renewer = Renewer::default();
        loop {
            let prev = {
                let st = app.state::<AppState>();
                let s = st.grok.lock().unwrap().clone();
                s
            };
            let snap = read_once(&prev, &mut renewer);
            if snap.status == "error" || snap.status == "stale" {
                crate::applog(&format!("grok: {}", snap.note));
            }
            broadcast(&app, snap);
            sleep_interruptible(POLL_SECS);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn product_windows_use_matching_current_or_billing_bounds() {
        for (period, expected) in [
            (serde_json::json!({"start": "2026-09-05T08:21:18Z", "end": "2026-09-12T08:21:18Z"}),
                Some(crate::usage::SEVEN_DAYS_MS)),
            (serde_json::json!({"start": "2026-09-05T08:21:18Z", "end": "invalid"}), Some(30 * 86_400_000)),
            (serde_json::json!({"end": "2026-09-12T08:21:18Z"}), None),
            (serde_json::json!({"start": "2026-09-12T08:21:18Z", "end": "2026-09-12T08:21:18Z"}), None),
            (serde_json::json!({"start": "2026-09-13T08:21:18Z", "end": "2026-09-12T08:21:18Z"}), None),
        ] {
            let (ws, _) = parse_credits(&serde_json::json!({"config": {
                "currentPeriod": period,
                "billingPeriodStart": "2026-09-01T00:00:00Z", "billingPeriodEnd": "2026-10-01T00:00:00Z",
                "productUsage": [{"product": "GrokBuild", "usagePercent": 8}, {"product": "Other", "usagePercent": 5}]
            }}));
            assert_eq!(ws.len(), 2);
            assert!(ws.iter().all(|w| w.duration_ms == expected), "{ws:?}");
        }
        let (ws, _) = parse_credits(&serde_json::json!({"config": {"creditUsagePercent": 8}}));
        assert_eq!(ws[0].duration_ms, None);
    }


    #[test]
    fn picks_only_the_xai_session_and_prefers_a_live_one() {
        let root: serde_json::Value = serde_json::from_str(
            r#"{
              "https://idp.example.com::abc": { "key": "private-proxy", "oidc_issuer": "https://idp.example.com" },
              "https://auth.x.ai::dead": { "key": "old", "expires_at": "2000-01-01T00:00:00Z" },
              "https://auth.x.ai::live": { "key": "good", "expires_at": "2999-01-01T00:00:00Z", "email": "a@b.c" }
            }"#,
        )
        .unwrap();
        let c = pick(&root).expect("a trusted entry");
        assert_eq!(c.token, "good");
        assert_eq!(c.email.as_deref(), Some("a@b.c"));
        assert!(!c.is_expired());
    }

    #[test]
    fn a_lookalike_issuer_is_not_trusted() {
        let root: serde_json::Value = serde_json::from_str(
            r#"{ "https://auth.x.ai.example.com::cli": { "key": "not-xai", "expires_at": "2999-01-01T00:00:00Z" } }"#,
        )
        .unwrap();
        assert!(pick(&root).is_none());
    }

    #[test]
    fn a_customer_idp_entry_alone_is_not_used() {
        let root: serde_json::Value =
            serde_json::from_str(r#"{ "https://idp.example.com::abc": { "key": "private-proxy" } }"#).unwrap();
        assert!(pick(&root).is_none());
    }

    #[test]
    fn credits_percent_becomes_the_headline_window() {
        let v: serde_json::Value = serde_json::from_str(
            r#"{ "config": { "currentPeriod": { "type": "USAGE_PERIOD_TYPE_WEEKLY",
                                                "start": "2026-09-05T08:21:18Z", "end": "2026-09-12T08:21:18Z" },
                             "creditUsagePercent": 8.0,
                             "productUsage": [{ "product": "GrokBuild", "usagePercent": 8.0 }] } }"#,
        )
        .unwrap();
        let (w, note) = parse_credits(&v);
        assert!(note.is_empty());
        assert_eq!(w.len(), 1);
        assert_eq!(w[0].id, "credits");
        assert_eq!(w[0].label, "Grok Build");
        assert!((w[0].used - 0.08).abs() < 1e-9);
        assert!(w[0].resets_at.is_some());
        assert_eq!(w[0].duration_ms, Some(crate::usage::SEVEN_DAYS_MS));
    }

    #[test]
    fn a_fresh_weekly_period_reads_as_zero_rather_than_unmetered() {
        let v: serde_json::Value = serde_json::from_str(
            r#"{ "config": { "currentPeriod": { "type": "USAGE_PERIOD_TYPE_WEEKLY", "end": "2026-09-12T08:21:18Z" } } }"#,
        )
        .unwrap();
        let (w, note) = parse_credits(&v);
        assert!(note.is_empty());
        assert_eq!(w.len(), 1);
        assert_eq!(w[0].id, "credits");
        assert_eq!(w[0].used, 0.0);
        assert_eq!(w[0].duration_ms, None, "the Mac's fresh weekly fallback does not attach a duration");
    }

    #[test]
    fn nothing_metered_says_so_instead_of_inventing_a_ring() {
        let v: serde_json::Value = serde_json::from_str(r#"{ "config": {} }"#).unwrap();
        let (w, note) = parse_credits(&v);
        assert!(w.is_empty());
        assert!(!note.is_empty());
    }

    #[test]
    fn wire_product_names_are_split_for_display() {
        assert_eq!(humanize("GrokBuild"), "Grok Build");
        assert_eq!(humanize("Usage"), "Usage");
    }

    fn creds(expires_at: u64) -> Creds {
        Creds { token: "t".into(), expires_at, email: None }
    }

    // Neither case may reach the CLI: both are decided before any launch.
    #[test]
    fn a_session_without_an_expiry_is_never_renewed_on_a_guess() {
        let mut r = Renewer::default();
        assert_eq!(r.maybe_renew(&creds(0)), None);
        assert_eq!(r.last_attempt, None);
    }

    #[test]
    fn a_live_session_is_left_alone() {
        let mut r = Renewer::default();
        assert_eq!(r.maybe_renew(&creds(now_ms() + 60 * 60 * 1000)), None);
        assert_eq!(r.last_attempt, None);
    }
}
