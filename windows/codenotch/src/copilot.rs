//! GitHub Copilot usage adapter, ported from the Mac app's `GitHubCopilotProvider` /
//! `GitHubCopilotUsage` / `GitHubCopilotCredentials`.
//!
//! Data path (the same bargain the other providers strike: borrow a session already on the machine):
//!   1. Credential, the first of these found: `GH_TOKEN`, then `GITHUB_TOKEN`, from the environment
//!      Codenotch was started with; then `oauth_token` under the `github.com:` block of GitHub CLI's
//!      `hosts.yml`, which on Windows is `%APPDATA%\GitHub CLI\hosts.yml` (`GH_CONFIG_DIR` and
//!      `XDG_CONFIG_HOME` are honoured first, `~/.config/gh` last, the way `gh` itself resolves it);
//!      then `gh auth token --hostname github.com`, run hidden with a short timeout, since GitHub
//!      CLI keeps the token in Windows Credential Manager when it can, in which case `hosts.yml`
//!      names the user but holds no token and only the CLI can hand it over.
//!      The file is only ever read; signing in and refreshing are `gh auth login`'s job.
//!   2. Endpoint: `GET https://api.github.com/copilot_internal/user`
//!      (`Authorization: Bearer …`, `Accept: application/json`, `X-GitHub-Api-Version: 2022-11-28`),
//!      the one GitHub's own editors ask for the quota panel. Reply:
//!      ```text
//!      { "copilot_plan": "individual", "quota_reset_date": "2026-10-01T00:00:00Z",
//!        "quota_snapshots": {
//!          "premium_interactions": { "entitlement": 300, "remaining": 294, "used": 6, "unlimited": false },
//!          "chat":                 { "entitlement": 50,  "remaining": 48,  "used": 2, "unlimited": false },
//!          "completions":          { "entitlement": 2000, "remaining": 1990, "used": 10, "unlimited": false } } }
//!      ```
//!      Every metered quota with a published entitlement becomes a window, the premium requests
//!      first since that is the one Copilot's own panel leads with; an `unlimited` quota, or one
//!      with an entitlement of 0, is not a limit and draws nothing. All of them reset together at
//!      midnight UTC on the first of the month.
//!
//! Token values never reach logs, events or the UI; the card names the account and the plan.

use crate::usage::{calendar_month_duration_ms, LimitWindow, UsageSnapshot};
use crate::AppState;
use std::path::PathBuf;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager};

const ENDPOINT: &str = "https://api.github.com/copilot_internal/user";
const POLL_SECS: u64 = 300;
/// `gh auth token` only reads Credential Manager and prints; this is generous for that.
const GH_TIMEOUT: Duration = Duration::from_secs(10);
/// Copilot's panel leads with premium requests; then the two flat allowances; anything new after.
const ORDER: [&str; 3] = ["premium_interactions", "chat", "completions"];

static REFRESH: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

pub fn request_refresh() {
    REFRESH.store(true, std::sync::atomic::Ordering::Relaxed);
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

fn store_path() -> PathBuf {
    crate::config::config_path().with_file_name("copilot.json")
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

// ---------------- Locating GitHub CLI ----------------

fn non_empty(v: Option<String>) -> Option<String> {
    v.map(|s| s.trim().to_string()).filter(|s| !s.is_empty())
}

fn env_token() -> Option<String> {
    non_empty(std::env::var("GH_TOKEN").ok()).or_else(|| non_empty(std::env::var("GITHUB_TOKEN").ok()))
}

/// Where `gh` keeps `hosts.yml`, in the order `gh` itself looks: an explicit `GH_CONFIG_DIR`, an
/// XDG home, then Roaming AppData on Windows, and `~/.config/gh` as the Unix default (a WSL or
/// Git-Bash habit that carries over).
fn config_dirs() -> Vec<PathBuf> {
    let mut v = Vec::new();
    if let Some(d) = non_empty(std::env::var("GH_CONFIG_DIR").ok()) {
        v.push(PathBuf::from(d));
    }
    if let Some(d) = non_empty(std::env::var("XDG_CONFIG_HOME").ok()) {
        v.push(PathBuf::from(d).join("gh"));
    }
    if let Some(d) = dirs::config_dir() {
        v.push(d.join("GitHub CLI"));
    }
    if let Some(h) = dirs::home_dir() {
        v.push(h.join(".config").join("gh"));
    }
    v
}

/// The first `hosts.yml` that exists, or where the first candidate would be (for doctor)
pub fn hosts_path() -> Option<PathBuf> {
    let dirs = config_dirs();
    dirs.iter().map(|d| d.join("hosts.yml")).find(|p| p.is_file()).or_else(|| dirs.first().map(|d| d.join("hosts.yml")))
}

/// Candidates in order: the MSI's Program Files install, the per-user installers, winget's
/// link directory, scoop, then `gh.exe` on PATH. No `.cmd` wrapper is ever launched.
pub fn find_executable() -> Option<PathBuf> {
    let mut cands: Vec<PathBuf> = Vec::new();
    for var in ["ProgramFiles", "ProgramFiles(x86)"] {
        if let Some(d) = std::env::var_os(var) {
            cands.push(PathBuf::from(d).join("GitHub CLI").join("gh.exe"));
        }
    }
    if let Some(local) = dirs::data_local_dir() {
        cands.push(local.join("Programs").join("GitHub CLI").join("gh.exe"));
        cands.push(local.join("Microsoft").join("WinGet").join("Links").join("gh.exe"));
    }
    if let Some(h) = dirs::home_dir() {
        cands.push(h.join("scoop").join("shims").join("gh.exe"));
    }
    if let Some(path) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&path) {
            cands.push(dir.join("gh.exe"));
        }
    }
    cands.into_iter().find(|p| p.is_file())
}

/// Something on this machine can hand over a GitHub session: a token in the environment, a
/// GitHub CLI config, or the CLI itself. Otherwise the provider stays off the notch.
pub fn present() -> bool {
    env_token().is_some() || hosts_path().map(|p| p.is_file()).unwrap_or(false) || find_executable().is_some()
}

/// `gh auth token --hostname github.com`, hidden, bounded by `GH_TIMEOUT`. The CLI reads the token
/// back out of Credential Manager; nothing here can make it sign in.
fn gh_token() -> Option<String> {
    use std::process::{Command, Stdio};
    let exe = find_executable()?;
    let mut cmd = Command::new(&exe);
    cmd.args(["auth", "token", "--hostname", "github.com"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    let mut child = cmd.spawn().ok()?;
    let mut stdout = child.stdout.take()?;
    // Drained on its own thread so a CLI that never exits cannot wedge the poller on the pipe.
    let reader = std::thread::spawn(move || {
        use std::io::Read;
        let mut s = String::new();
        let _ = stdout.read_to_string(&mut s);
        s
    });
    let deadline = Instant::now() + GH_TIMEOUT;
    let ok = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status.success(),
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(100)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                break false;
            }
        }
    };
    let out = reader.join().ok()?;
    if ok { non_empty(Some(out)) } else { None }
}

// ---------------- Credentials (borrowed, never written) ----------------

#[derive(Debug, PartialEq)]
pub struct Creds {
    token: String,
    pub username: Option<String>,
    /// "GitHub" for an environment token, "GitHub CLI" for one the CLI holds
    pub source: &'static str,
}

/// One YAML line, `key: value`, with the quotes `gh` never writes but a hand edit might
fn yaml_value<'a>(line: &'a str, key: &str) -> Option<&'a str> {
    let rest = line.strip_prefix(key)?.strip_prefix(':')?;
    let v = rest.trim().trim_matches(|c: char| c == '"' || c == '\'');
    if v.is_empty() { None } else { Some(v) }
}

/// `user` and `oauth_token` under the `github.com:` block. Every indented line of that block is
/// looked at, so the newer `users:` sub-map is read too; a GitHub Enterprise host block before or
/// after it is skipped whole.
pub fn parse_hosts(text: &str) -> (Option<String>, Option<String>) {
    let mut lines = text.lines();
    let Some(_) = lines.find(|l| l.trim() == "github.com:") else { return (None, None) };
    let mut user = None;
    let mut token = None;
    for line in lines {
        if !line.starts_with(' ') && !line.starts_with('\t') {
            break;
        }
        let t = line.trim();
        if let Some(v) = yaml_value(t, "user") {
            user.get_or_insert_with(|| v.to_string());
        }
        if let Some(v) = yaml_value(t, "oauth_token") {
            token.get_or_insert_with(|| v.to_string());
        }
    }
    (user, token)
}

/// Injectable inputs keep the order testable without a real token or a running CLI.
pub fn pick(env: Option<String>, hosts: Option<&str>, command: impl FnOnce() -> Option<String>) -> Option<Creds> {
    let (username, file_token) = hosts.map(parse_hosts).unwrap_or((None, None));
    if let Some(token) = env {
        return Some(Creds { token, username, source: "GitHub" });
    }
    if let Some(token) = file_token {
        return Some(Creds { token, username, source: "GitHub CLI" });
    }
    // Trimmed here as well as in gh_token: the CLI prints the token with a newline, and a header
    // built from the raw line would be refused.
    let token = non_empty(command())?;
    Some(Creds { token, username, source: "GitHub CLI" })
}

/// Re-read every time: `gh auth login` and `gh auth refresh` rotate the token underneath us.
fn read_credentials() -> Option<Creds> {
    let hosts = hosts_path().and_then(|p| std::fs::read_to_string(p).ok());
    pick(env_token(), hosts.as_deref(), gh_token)
}

/// For doctor: contains no secret values
pub fn probe() -> String {
    let hosts = hosts_path();
    let file = match &hosts {
        Some(p) if p.is_file() => format!("{} found", p.display()),
        Some(p) => format!("{} not found", p.display()),
        None => "cannot locate the home directory".into(),
    };
    let cli = match find_executable() {
        Some(p) => format!("gh at {}", p.display()),
        None => "gh.exe not found".into(),
    };
    let env = if env_token().is_some() { "GH_TOKEN/GITHUB_TOKEN set" } else { "no environment token" };
    match read_credentials() {
        Some(c) => format!(
            "GitHub Copilot: session borrowed via {} (token {} chars{}); {file}; {cli}; {env}",
            c.source,
            c.token.len(),
            c.username.as_deref().map(|u| format!(", user {u}")).unwrap_or_default()
        ),
        None => format!("GitHub Copilot: no GitHub session (run gh auth login); {file}; {cli}; {env}"),
    }
}

// ---------------- Parsing ----------------

fn number(v: Option<&serde_json::Value>) -> Option<f64> {
    v.and_then(|x| x.as_f64())
}

/// Seconds or milliseconds since the epoch, RFC 3339, or a bare `YYYY-MM-DD` — the field has been
/// all four. A zero is "not stated", not 1970. The bare date is what a Business account's
/// `quota_reset_date` carries, and Copilot's allowances reset at midnight UTC, so that is the
/// instant it names.
fn date_ms(v: Option<&serde_json::Value>) -> Option<u64> {
    if let Some(n) = number(v) {
        if n <= 0.0 {
            return None;
        }
        let ms = if n > 10_000_000_000.0 { n } else { n * 1000.0 };
        return Some(ms as u64);
    }
    let s = v.and_then(|x| x.as_str())?;
    if let Ok(d) = chrono::DateTime::parse_from_rfc3339(s) {
        return Some(d.timestamp_millis().max(0) as u64);
    }
    chrono::NaiveDate::parse_from_str(s, "%Y-%m-%d")
        .ok()
        .and_then(|d| d.and_hms_opt(0, 0, 0))
        .map(|dt| dt.and_utc().timestamp_millis().max(0) as u64)
}

/// The names Copilot's own panel uses; anything new is the wire id made readable
pub fn label(id: &str) -> String {
    match id {
        "premium_interactions" => "Premium requests".into(),
        "chat" => "Chat requests".into(),
        "completions" => "Completions".into(),
        _ => {
            let mut out = String::with_capacity(id.len());
            for (i, word) in id.split('_').filter(|w| !w.is_empty()).enumerate() {
                if i > 0 {
                    out.push(' ');
                }
                let mut chars = word.chars();
                if let Some(c) = chars.next() {
                    out.extend(c.to_uppercase());
                    out.push_str(chars.as_str());
                }
            }
            out
        }
    }
}

/// The plan name, for the card's account line
pub fn plan(v: &serde_json::Value) -> Option<String> {
    non_empty(v.get("copilot_plan").or_else(|| v.get("plan")).and_then(|x| x.as_str()).map(|s| s.to_string()))
}

fn monthly_duration_ms(reset: Option<u64>) -> Option<u64> {
    use chrono::{Datelike, Timelike};
    let date = chrono::DateTime::<chrono::Utc>::from_timestamp_millis(i64::try_from(reset?).ok()?)?;
    if date.day() != 1 || date.hour() != 0 || date.minute() != 0 || date.second() != 0 {
        return None;
    }
    calendar_month_duration_ms(reset)
}

fn window(id: &str, quota: &serde_json::Value, root: &serde_json::Value) -> Option<LimitWindow> {
    if quota.get("unlimited").and_then(|x| x.as_bool()) == Some(true) {
        return None;
    }
    let entitlement = number(quota.get("entitlement"))?;
    if entitlement <= 0.0 {
        return None;
    }
    let remaining = number(quota.get("remaining"));
    let consumed = number(quota.get("used")).unwrap_or_else(|| (entitlement - remaining.unwrap_or(entitlement)).max(0.0));
    let resets_at = date_ms(quota.get("reset_date"))
        .or_else(|| date_ms(quota.get("reset_at")))
        .or_else(|| date_ms(quota.get("resets_at")))
        .or_else(|| date_ms(root.get("quota_reset_date")));
    Some(LimitWindow {
        id: id.to_string(),
        label: label(id),
        used: (consumed / entitlement).clamp(0.0, 1.0),
        resets_at,
        duration_ms: monthly_duration_ms(resets_at),
        ..Default::default()
    })
}

/// reply → (windows, note). An empty list with a note means the account has nothing metered.
pub fn parse(v: &serde_json::Value) -> (Vec<LimitWindow>, String) {
    let Some(quotas) = v.get("quota_snapshots").and_then(|x| x.as_object()) else {
        return (Vec::new(), "GitHub Copilot returned no quota snapshots".into());
    };
    let mut keys: Vec<&str> = ORDER.iter().copied().filter(|k| quotas.contains_key(*k)).collect();
    let mut rest: Vec<&str> = quotas.keys().map(|k| k.as_str()).filter(|k| !ORDER.contains(k)).collect();
    rest.sort_unstable();
    keys.append(&mut rest);
    let out: Vec<LimitWindow> = keys.iter().filter_map(|k| window(k, &quotas[*k], v)).collect();
    if out.is_empty() {
        return (out, "GitHub Copilot reported no metered quotas".into());
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
        .set("Accept", "application/json")
        .set("X-GitHub-Api-Version", "2022-11-28")
        .set("User-Agent", "Codenotch")
        .call()
    {
        Ok(r) => r.into_json::<serde_json::Value>().map_err(|e| FetchErr::Other(format!("parse: {e}"))),
        Err(ureq::Error::Status(401, _)) | Err(ureq::Error::Status(403, _)) => Err(FetchErr::NeedsAuth),
        Err(ureq::Error::Status(429, _)) => Err(FetchErr::RateLimited),
        Err(ureq::Error::Status(code, _)) => Err(FetchErr::Other(format!("HTTP {code}"))),
        Err(e) => Err(FetchErr::Other(format!("{e}"))),
    }
}

fn read_once(prev: &UsageSnapshot) -> UsageSnapshot {
    let mut snap = prev.clone();
    let Some(creds) = read_credentials() else {
        snap.status = "needsAuth".into();
        snap.note = "Run gh auth login — Codenotch borrows the GitHub CLI's session.".into();
        return snap;
    };
    match fetch_once(&creds.token) {
        Ok(v) => {
            let (windows, note) = parse(&v);
            snap.fetched_at = now_ms();
            if windows.is_empty() {
                snap.status = "none".into();
                snap.windows.clear();
                snap.note = note;
            } else {
                snap.status = "ok".into();
                snap.windows = windows;
                let mut parts: Vec<String> = Vec::new();
                if let Some(u) = creds.username {
                    parts.push(u);
                }
                if let Some(p) = plan(&v) {
                    parts.push(p);
                }
                parts.push(format!("via {}", creds.source));
                snap.note = parts.join(" · ");
            }
        }
        Err(FetchErr::NeedsAuth) => {
            snap.status = "needsAuth".into();
            snap.note = "GitHub session was rejected — run gh auth login again".into();
        }
        Err(FetchErr::RateLimited) => {
            snap.status = if snap.windows.is_empty() { "error" } else { "stale" }.into();
            snap.note = "GitHub is rate limiting; the last reading stands".into();
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
    *st.copilot.lock().unwrap() = snap.clone();
    persist(&snap);
    let _ = app.emit("copilot", &snap);
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
            let snap = st.copilot.lock().unwrap().clone();
            let _ = app.emit("copilot", &snap);
        }
        if !present() {
            broadcast(&app, UsageSnapshot { status: "absent".into(), ..Default::default() });
            loop {
                sleep_interruptible(600); // GitHub CLI is not installed: look again every 10 minutes
                if present() {
                    break;
                }
            }
        }
        loop {
            let prev = {
                let st = app.state::<AppState>();
                let s = st.copilot.lock().unwrap().clone();
                s
            };
            let snap = read_once(&prev);
            if snap.status == "error" || snap.status == "stale" {
                crate::applog(&format!("copilot: {}", snap.note));
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
    fn monthly_duration_requires_a_first_of_month_utc_reset() {
        for (reset, days) in [
            ("2024-03-01", 29), ("2025-03-01", 28), ("2026-01-01", 31),
            ("2026-10-01T01:00:00+01:00", 30),
        ] {
            let (ws, _) = parse(&serde_json::json!({"quota_reset_date": reset,
                "quota_snapshots": {"premium_interactions": {"entitlement": 300, "used": 30}}
            }));
            assert_eq!(ws[0].duration_ms, Some(days * 86_400_000), "{reset}");
        }
        for reset in [serde_json::Value::Null, serde_json::json!("invalid"),
            serde_json::json!("2026-10-02"), serde_json::json!("2026-10-01T00:01:00Z"),
            serde_json::json!("2026-10-01T00:00:01Z"), serde_json::json!("2026-10-01T00:00:00+01:00")] {
            let (ws, _) = parse(&serde_json::json!({"quota_reset_date": reset.clone(),
                "quota_snapshots": {"chat": {"entitlement": 50, "used": 5}}
            }));
            assert_eq!(ws[0].duration_ms, None, "{reset}");
        }
    }

    #[test]
    fn quota_specific_reset_controls_its_monthly_duration() {
        let (ws, _) = parse(&serde_json::json!({"quota_reset_date": "2026-10-01",
            "quota_snapshots": {"chat": {"entitlement": 50, "used": 5, "reset_date": "2025-03-01"}}
        }));
        assert_eq!(ws[0].duration_ms, Some(28 * 86_400_000));
    }


    const REPLY: &str = r#"{"copilot_plan":"individual","quota_reset_date":"2026-10-01T00:00:00Z",
        "quota_snapshots":{
          "chat":{"entitlement":50,"remaining":48,"used":2,"unlimited":false},
          "completions":{"entitlement":2000,"remaining":1990,"used":10,"unlimited":false},
          "premium_interactions":{"entitlement":300,"remaining":294,"used":6,"unlimited":false}}}"#;

    #[test]
    fn reads_copilot_quotas_premium_first() {
        let v: serde_json::Value = serde_json::from_str(REPLY).unwrap();
        let (w, note) = parse(&v);
        assert!(note.is_empty());
        assert_eq!(w.iter().map(|x| x.id.as_str()).collect::<Vec<_>>(), ["premium_interactions", "chat", "completions"]);
        assert_eq!(w[0].label, "Premium requests");
        assert!((w[0].used - 0.02).abs() < 1e-9);
        assert!((w[1].used - 0.04).abs() < 1e-9);
        assert_eq!(w[0].resets_at, Some(1_790_812_800_000), "midnight UTC on 1 October 2026");
        assert!(w.iter().all(|w| w.duration_ms == Some(30 * 86_400_000)));
        assert_eq!(plan(&v).as_deref(), Some("individual"));
    }

    #[test]
    fn used_is_derived_from_remaining_when_the_reply_omits_it() {
        let v: serde_json::Value = serde_json::from_str(
            r#"{"quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":150,"reset_date":1790812800}}}"#,
        )
        .unwrap();
        let (w, _) = parse(&v);
        assert_eq!(w.len(), 1);
        assert!((w[0].used - 0.5).abs() < 1e-9);
        assert_eq!(w[0].resets_at, Some(1_790_812_800_000), "seconds are scaled to milliseconds");
    }

    /// The shape a Business account actually answers with (numbers changed): no `used`, a
    /// negative `remaining` once the seat is over its allowance, `unlimited` chat and
    /// completions, a bare-date `quota_reset_date` and a `quota_reset_at` of 0.
    #[test]
    fn a_business_seat_over_its_allowance_reads_full_and_resets_on_the_first() {
        let v: serde_json::Value = serde_json::from_str(
            r#"{"copilot_plan":"business","quota_reset_date":"2026-10-01",
              "quota_snapshots":{
                "chat":{"entitlement":0,"remaining":0,"unlimited":true,"percent_remaining":100.0,"quota_reset_at":0},
                "completions":{"entitlement":0,"remaining":0,"unlimited":true,"percent_remaining":100.0,"quota_reset_at":0},
                "premium_interactions":{"entitlement":20000,"remaining":-4321,"credits_used":24321,"overage_count":4321,
                  "unlimited":false,"percent_remaining":0.0,"has_quota":false,"quota_reset_at":0}}}"#,
        )
        .unwrap();
        let (w, note) = parse(&v);
        assert!(note.is_empty());
        assert_eq!(w.len(), 1, "unlimited chat and completions draw nothing");
        assert_eq!(w[0].id, "premium_interactions");
        assert_eq!(w[0].used, 1.0, "over the allowance is full, not 121 %");
        assert_eq!(w[0].resets_at, Some(1_790_812_800_000), "the bare date is midnight UTC on 1 October 2026");
        assert_eq!(plan(&v).as_deref(), Some("business"));
        assert_eq!(date_ms(Some(&serde_json::json!(0))), None, "a zero reset is unstated, not 1970");
    }

    #[test]
    fn unlimited_and_zero_entitlement_are_not_limits() {
        let v: serde_json::Value = serde_json::from_str(
            r#"{"quota_snapshots":{
              "chat":{"entitlement":0,"remaining":0,"used":0,"unlimited":false},
              "completions":{"entitlement":0,"remaining":0,"used":0,"unlimited":true}}}"#,
        )
        .unwrap();
        let (w, note) = parse(&v);
        assert!(w.is_empty());
        assert!(!note.is_empty());
    }

    #[test]
    fn a_new_quota_lands_after_the_known_ones_with_a_readable_name() {
        let v: serde_json::Value = serde_json::from_str(
            r#"{"quota_snapshots":{
              "agent_mode_requests":{"entitlement":10,"used":1},
              "premium_interactions":{"entitlement":300,"used":6}}}"#,
        )
        .unwrap();
        let (w, _) = parse(&v);
        assert_eq!(w.iter().map(|x| x.id.as_str()).collect::<Vec<_>>(), ["premium_interactions", "agent_mode_requests"]);
        assert_eq!(w[1].label, "Agent Mode Requests");
    }

    #[test]
    fn overspend_is_clamped_to_full() {
        let v: serde_json::Value =
            serde_json::from_str(r#"{"quota_snapshots":{"premium_interactions":{"entitlement":300,"used":420}}}"#).unwrap();
        let (w, _) = parse(&v);
        assert_eq!(w[0].used, 1.0);
    }

    const HOSTS: &str = "github.com:\n    user: octocat\n    oauth_token: cli-token\n    git_protocol: https\n";

    #[test]
    fn environment_token_wins_but_the_file_still_names_the_user() {
        let c = pick(Some("env-token".into()), Some(HOSTS), || panic!("gh must not be launched")).unwrap();
        assert_eq!(c.token, "env-token");
        assert_eq!(c.username.as_deref(), Some("octocat"));
        assert_eq!(c.source, "GitHub");
    }

    #[test]
    fn the_cli_file_is_read_before_the_cli_is_asked() {
        let c = pick(None, Some(HOSTS), || panic!("gh must not be launched")).unwrap();
        assert_eq!(c.token, "cli-token");
        assert_eq!(c.source, "GitHub CLI");
    }

    #[test]
    fn a_credential_manager_sign_in_falls_through_to_the_cli() {
        // What gh writes when the token went to Windows Credential Manager: a user, no token.
        let hosts = "github.com:\n    users:\n        octocat:\n    git_protocol: https\n    user: octocat\n";
        let c = pick(None, Some(hosts), || Some("from-gh\n".into())).unwrap();
        assert_eq!(c.token, "from-gh");
        assert_eq!(c.username.as_deref(), Some("octocat"));
        assert!(pick(None, Some(hosts), || None).is_none());
        assert!(pick(None, None, || None).is_none());
    }

    #[test]
    fn only_the_github_com_block_is_read() {
        let hosts = "ghe.example.com:\n    user: alice\n    oauth_token: enterprise\ngithub.com:\n    user: bob\n    oauth_token: public\n";
        let c = pick(None, Some(hosts), || None).unwrap();
        assert_eq!(c.token, "public");
        assert_eq!(c.username.as_deref(), Some("bob"));
        let only_ghe = "ghe.example.com:\n    user: alice\n    oauth_token: enterprise\n";
        assert_eq!(parse_hosts(only_ghe), (None, None), "an Enterprise token is never sent to api.github.com");
    }

    #[test]
    fn quoted_values_are_unquoted() {
        assert_eq!(parse_hosts("github.com:\n  user: \"octocat\"\n  oauth_token: 'tok'\n"), (Some("octocat".into()), Some("tok".into())));
    }
}
