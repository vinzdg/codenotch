//! Claude usage adapter (official), implemented from the upstream Codenotch's documented behaviour.
//! Endpoint: GET https://api.anthropic.com/api/oauth/usage
//! Headers: Authorization: Bearer <token>; anthropic-beta: oauth-2025-04-20; 15 s timeout
//! Rules (upstream's discipline):
//!   - the credential comes from Claude Code's own store (Windows: ~/.claude/.credentials.json), read only
//!   - accounts, plural: ~/.claude and every ~/.claude-<slug> holding a credential. That layout is not invented
//!     here — it is what CLAUDE_CONFIG_DIR points a shell at, and what the Mac app already reads several accounts
//!     by. Each account's windows carry its name in `group`, so the card stacks them exactly as Antigravity's
//!     model families stack, and a machine with one account produces byte-for-byte the old reading
//!   - 401 → re-read the credential once and retry (Claude Code may have just refreshed the token) → still
//!     failing means needsAuth; 403 is access denied, not proof of lost authentication
//!   - 429 → back off 60 s × 2^n capped at 15 min, Retry-After only raises it, even past the cap; the deadline is persisted
//!   - an expired token is never sent: the endpoint answers it with 429 + Retry-After ≈ 3600, not 401, so sending it
//!     reads as "rate limited" for as long as the token stays stale (upstream's credentialExpired, no network)
//!   - the token is renewed by running the standalone `claude -p` with an empty stdin shortly before it expires
//!     (upstream's ClaudeTokenRefresher). Only that CLI writes ~/.claude/.credentials.json — Claude Code inside the
//!     desktop app renews its own copy elsewhere — so without this the file rots eight hours after the last CLI run
//!   - never invent a percentage on failure: keep the last reading marked stale, and the UI shows how old it is
//!
//! Reply (snake_case): { limits:[{kind,percent,resets_at}], five_hour:{utilization,resets_at}, seven_day:{...} }
//! limits is the forward-compatible main shape; five_hour/seven_day are merged in as a fallback (a window that just rolled over disappears from limits).

use crate::AppState;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager};

pub const FIVE_HOURS_MS: u64 = 5 * 60 * 60 * 1000;
pub const SEVEN_DAYS_MS: u64 = 7 * 24 * 60 * 60 * 1000;

/// Invalid or unrepresentable lengths must not become plausible windows.
pub(crate) fn duration_from_seconds(seconds: f64) -> Option<u64> {
    let ms = seconds * 1000.0;
    (ms.is_finite() && ms >= 1.0 && ms < u64::MAX as f64).then_some(ms as u64)
}

pub(crate) fn duration_between_ms(start: Option<u64>, end: Option<u64>) -> Option<u64> {
    end?.checked_sub(start?).filter(|ms| *ms > 0)
}

/// Calendar months vary in length; preserve the UTC reset's time of day.
pub(crate) fn calendar_month_duration_ms(ending_at: Option<u64>) -> Option<u64> {
    let reset = chrono::DateTime::<chrono::Utc>::from_timestamp_millis(i64::try_from(ending_at?).ok()?)?;
    let start = reset.checked_sub_months(chrono::Months::new(1))?;
    u64::try_from((reset - start).num_milliseconds()).ok().filter(|ms| *ms > 0)
}

const ENDPOINT: &str = "https://api.anthropic.com/api/oauth/usage";
const POLL_ACTIVE_SECS: u64 = 60;
const POLL_IDLE_SECS: u64 = 300;
/// Per-account floor, including tray refreshes and failed attempts.
const MIN_FETCH_SECS: u64 = 300;
const BACKOFF_BASE_SECS: u64 = 60;
const BACKOFF_CAP_SECS: u64 = 900;
/// Renew when this close to expiry. Must stay under Claude Code's own five minutes: its start-up renews the token
/// only when now + 300 s >= expiresAt, so launching any earlier is a no-op that would be judged a failure
const RENEW_MARGIN_MS: u64 = 4 * 60 * 1000;
const RENEW_COOLDOWN_MS: u64 = 10 * 60 * 1000;
/// A token that did not renew is tried again, each wait twice the last, never more than an hour apart
const RENEW_RETRY_CAP_MS: u64 = 60 * 60 * 1000;
const RENEW_TIMEOUT_SECS: u64 = 30;
const EXPIRED_NOTE: &str = "Credential expired — run claude once in a terminal to renew it";

#[derive(Default)]
struct RefreshRequest {
    all: bool,
    accounts: Vec<String>,
}

impl RefreshRequest {
    fn all() -> Self { Self { all: true, accounts: Vec::new() } }

    fn merge(&mut self, other: Self) {
        if self.all || other.all {
            *self = Self::all();
        } else {
            for id in other.accounts {
                if !self.accounts.contains(&id) { self.accounts.push(id); }
            }
        }
    }

    fn includes(&self, p: &Profile) -> bool {
        self.all || self.accounts.iter().any(|id| id == p.slug.as_deref().unwrap_or("default"))
    }

    fn is_empty(&self) -> bool { !self.all && self.accounts.is_empty() }
}

static REFRESH: Mutex<RefreshRequest> = Mutex::new(RefreshRequest { all: false, accounts: Vec::new() });

fn take_refresh() -> RefreshRequest {
    std::mem::take(&mut *REFRESH.lock().unwrap_or_else(|e| e.into_inner()))
}

/// Immediate refresh from the tray or a command
pub fn request_refresh() {
    REFRESH.lock().unwrap_or_else(|e| e.into_inner()).merge(RefreshRequest::all());
}

/// Queue only this profile; the poller's existing account state still owns its retry deadline.
pub fn request_account_refresh(id: &str) {
    REFRESH.lock().unwrap_or_else(|e| e.into_inner())
        .merge(RefreshRequest { all: false, accounts: vec![id.to_string()] });
}

/// A targeted click wakes the poller without moving the next regular refresh of all accounts.
fn sleep_interruptible(deadline: u64, mut automatic: RefreshRequest) -> RefreshRequest {
    loop {
        let pending = take_refresh();
        let now = now_ms();
        if now >= deadline {
            automatic.merge(pending);
            return automatic;
        }
        if !pending.is_empty() { return pending; }
        std::thread::sleep(Duration::from_millis((deadline - now).min(1000)));
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

const CRED_NAMES: [&str; 2] = [".credentials.json", "credentials.json"];

/// One Claude Code account, as its config directory. `slug` is None for the default ~/.claude and
/// Some("work") for ~/.claude-work.
#[derive(Debug, Clone, PartialEq)]
struct Profile {
    dir: PathBuf,
    slug: Option<String>,
    label: Option<String>,
    /// Who is signed in, from Claude Code's `.claude.json`
    address: Option<String>,
}

impl Profile {
    fn name(&self) -> String {
        self.label.clone().unwrap_or_else(|| self.slug.clone().unwrap_or_else(|| "default".into()))
    }

    /// The heading the card files this account's windows under. The plan is what tells two accounts
    /// apart at a glance ("max" against "pro"); the slug is what stays unique when both plans match.
    fn group(&self, plan: Option<&str>) -> String {
        match plan {
            Some(p) if !p.is_empty() => format!("{} · {p}", self.name()),
            _ => self.name(),
        }
    }
}

/// Enabled accounts: the default and every folder Claude Code has signed in to.
fn profiles() -> Vec<Profile> {
    crate::claude_accounts::profiles(&crate::config::load()).into_iter()
        .filter(|p| p.enabled)
        .map(|p| Profile { dir: p.dir, slug: if p.id == "default" { None } else { Some(p.id) },
            label: if p.name == "Claude" { None } else { Some(p.name) }, address: p.address }).collect()
}

/// Every account directory, for anything that watches a profile's files (the session watcher)
pub fn profile_dirs() -> Vec<PathBuf> {
    profiles().into_iter().map(|p| p.dir).collect()
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct LimitWindow {
    pub id: String,
    pub label: String,
    /// 0.0–1.0 (fraction used)
    pub used: f64,
    /// Reset time, ms epoch (None = unknown)
    pub resets_at: Option<u64>,
    /// Full length of the window in ms (None = unknown; no deficit is shown)
    #[serde(default)]
    pub duration_ms: Option<u64>,
    /// Pure count window (no published denominator, e.g. Antigravity's requests today) — the cell shows ~N and the ring draws only its track
    #[serde(default)]
    pub count: Option<i64>,
    /// The number is ours, not the vendor's (upstream fidelity=.derived) — the card adds a ~ prefix
    #[serde(default)]
    pub derived: bool,
    /// The heading the window sits under on the card, for a provider that reports the same windows
    /// for several things (Antigravity: a 5-hour and a weekly lane per model family). None = ungrouped
    #[serde(default)]
    pub group: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ClaudeAccountUsage {
    pub id: String,
    pub name: String,
    pub status: String,
    pub note: String,
    pub fetched_at: u64,
    #[serde(default)]
    pub backoff_until: u64,
    #[serde(default)]
    pub consecutive_429: u32,
    #[serde(default)]
    pub last_rate_limit_at: u64,
    #[serde(default)]
    pub last_attempt_at: u64,
    /// Who is signed in and on what plan, for the card's line under its title
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub address: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plan: Option<String>,
    pub windows: Vec<LimitWindow>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct UsageSnapshot {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub accounts: Vec<ClaudeAccountUsage>,
    /// ok | stale | needsAuth | backoff | error
    pub status: String,
    pub windows: Vec<LimitWindow>,
    pub fetched_at: u64,
    pub note: String,
    #[serde(default)]
    pub backoff_until: u64,
}

fn store_path() -> std::path::PathBuf {
    crate::config::config_path().with_file_name("usage.json")
}

pub fn load_persisted() -> UsageSnapshot {
    std::fs::read_to_string(store_path())
        .ok()
        .and_then(|t| serde_json::from_str::<UsageSnapshot>(&t).ok())
        // The status it was saved with is the status it comes back with: a reading persisted a
        // minute before a restart is a minute old, not stale, and `fetched_at` came back with it,
        // so whatever reads this can tell the difference on its own.
        .unwrap_or_default()
}

fn persist(s: &UsageSnapshot) {
    if let Ok(t) = serde_json::to_string_pretty(s) {
        let _ = std::fs::write(store_path(), t);
    }
}

fn backoffs_path() -> PathBuf {
    store_path().with_file_name("usage-backoffs.json")
}

fn load_backoffs() -> Option<HashMap<String, u64>> {
    std::fs::read_to_string(backoffs_path()).ok().and_then(|text| serde_json::from_str(&text).ok())
}

fn persist_backoffs(accounts: &HashMap<String, Account>) {
    let deadlines: HashMap<&str, u64> = accounts.iter()
        .filter(|(_, account)| account.backoff_until > now_ms())
        .map(|(profile, account)| (profile.as_str(), account.backoff_until))
        .collect();
    if let Ok(text) = serde_json::to_string_pretty(&deadlines) {
        if let Err(error) = std::fs::write(backoffs_path(), text) {
            crate::applog(&format!("claude: could not persist back-off deadlines: {error}"));
        }
    }
}

#[derive(Default)]
struct Credential {
    token: String,
    /// ms epoch (None = the file names no expiry)
    expires_at: Option<u64>,
    /// "max" | "pro" | … as the credential names it, for the card's account heading
    plan: Option<String>,
}

impl Credential {
    fn expired(&self, now: u64) -> bool {
        self.expires_at.map(|e| e <= now).unwrap_or(false)
    }
}

/// Reads Claude Code's OAuth credential.
fn read_credentials(dir: &Path) -> Option<Credential> {
    for name in CRED_NAMES {
        let p = dir.join(name);
        let Ok(text) = std::fs::read_to_string(&p) else {
            continue;
        };
        let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) else {
            continue;
        };
        let oauth = v.get("claudeAiOauth").unwrap_or(&v);
        if let Some(tok) = oauth.get("accessToken").and_then(|x| x.as_str()) {
            // An empty token is signed out, not expired: fall through to the next
            // candidate file rather than report a credential that cannot be used.
            if tok.trim().is_empty() {
                continue;
            }
            let expires_at = oauth.get("expiresAt").and_then(|x| x.as_f64()).map(|ms| ms as u64);
            let plan = oauth.get("subscriptionType").and_then(|x| x.as_str()).map(String::from);
            return Some(Credential { token: tok.to_string(), expires_at, plan });
        }
    }
    None
}

/// For doctor: credential probe report (prints no secret values)
pub fn probe_credentials() -> String {
    let cli = match find_cli() {
        Some(p) => format!("renews via {}", p.display()),
        None => "no standalone claude CLI found to renew it".into(),
    };
    let list = profiles();
    if list.is_empty() {
        return format!("credential: no home directory to read ~/.claude from; {cli}");
    }
    let lines: Vec<String> = list
        .iter()
        .map(|p| match read_credentials(&p.dir) {
            Some(c) => format!(
                "credential[{}]: found (token {} chars, {}, plan {})",
                p.name(),
                c.token.len(),
                if c.expired(now_ms()) { "expired" } else { "valid" },
                c.plan.as_deref().unwrap_or("?")
            ),
            None => format!(
                "credential[{}]: {} not found (needsAuth; the desktop app may use another store — signing in once with the Claude Code CLI creates it)",
                p.name(),
                p.dir.join(CRED_NAMES[0]).display()
            ),
        })
        .collect();
    format!("{}; {cli}", lines.join("
  "))
}

// ---------------- token renewal (upstream's ClaudeTokenRefresher) ----------------

/// Anything under these belongs to the desktop app: its bundled Claude Code keeps its token in the desktop app's
/// own store and never writes ~/.claude/.credentials.json, so renewing with it would change nothing here
fn is_desktop_owned(p: &std::path::Path) -> bool {
    let s = p.to_string_lossy().to_ascii_lowercase().replace('/', "\\");
    s.contains("\\anthropicclaude\\") || s.contains("\\claude\\claude-code\\") || s.contains("\\windowsapps\\")
}

/// The command file names to try for a CLI, most specific first. Windows needs the
/// native exe before the .cmd shim; elsewhere there is only the bare name.
pub(crate) fn command_names(stem: &str) -> Vec<String> {
    if cfg!(windows) {
        vec![format!("{stem}.exe"), format!("{stem}.cmd")]
    } else {
        vec![stem.to_string()]
    }
}

/// The standalone Claude Code command: its own installer's location first, then global npm/pnpm/Volta, then PATH
pub(crate) fn find_cli() -> Option<std::path::PathBuf> {
    let names = command_names("claude");
    let mut v = Vec::new();
    let push_all = |dir: std::path::PathBuf, v: &mut Vec<std::path::PathBuf>| {
        for n in &names {
            v.push(dir.join(n));
        }
    };
    if let Some(h) = dirs::home_dir() {
        push_all(h.join(".local").join("bin"), &mut v);
    }
    if let Some(d) = dirs::config_dir() {
        push_all(d.join("npm"), &mut v);
    }
    if let Some(d) = dirs::data_local_dir() {
        push_all(d.join("pnpm"), &mut v);
    }
    if let Some(h) = dirs::home_dir() {
        push_all(h.join(".volta").join("bin"), &mut v);
        // npm's global prefix and nvm's per-version bin are where a Linux install usually lands
        push_all(h.join(".npm-global").join("bin"), &mut v);
        push_all(h.join(".bun").join("bin"), &mut v);
    }
    if let Some(path) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&path) {
            push_all(dir, &mut v);
        }
    }
    v.into_iter().find(|p| p.is_file() && !is_desktop_owned(p))
}

/// Whether a launch is worth making. Pure, so every branch is testable without a clock or a subprocess.
/// grok.rs times its CLI launches by the same rule.
pub(crate) fn should_renew(
    expires_at: Option<u64>,
    now: u64,
    attempted_for: Option<u64>,
    last_attempt: Option<u64>,
    failures: u32,
) -> bool {
    // Nothing read yet: never launch on a guess
    let Some(exp) = expires_at else { return false };
    // Plenty of time left — also where launching would do nothing, because the CLI's own gate has not opened
    if exp > now + RENEW_MARGIN_MS {
        return false;
    }
    let Some(t) = last_attempt else { return true };
    // A launch that failed to move the expiry leaves the same value here. One failed launch — asleep, offline, a
    // busy CLI — must not freeze the ring until someone opens a terminal, so the same token is tried again, but
    // on a doubling wait, so a token that cannot renew does not become a launch every tick
    let wait = if attempted_for == Some(exp) { retry_wait_ms(failures) } else { RENEW_COOLDOWN_MS };
    now.saturating_sub(t) >= wait
}

fn retry_wait_ms(failures: u32) -> u64 {
    RENEW_COOLDOWN_MS.saturating_mul(1u64 << failures.min(16)).min(RENEW_RETRY_CAP_MS)
}

/// `claude -p` with a null stdin starts up (which is where it renews an aged token), then exits non-zero for want
/// of a prompt: no conversation, no transcript. Output goes nowhere — a token could in principle be echoed into it.
fn run_renewal(cli: &std::path::Path, dir: &Path) -> std::io::Result<()> {
    use std::process::{Command, Stdio};
    let mut cmd = Command::new(cli);
    cmd.arg("-p").stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    // Launched from inside a Claude Code session, the child would take the host's auth and leave the file alone
    for (k, _) in std::env::vars_os() {
        let k = k.to_string_lossy();
        if k == "CLAUDECODE" || k.starts_with("CLAUDE_CODE_") {
            cmd.env_remove(k.as_ref());
        }
    }
    // Which account gets renewed is said here, never inherited: CLAUDE_CONFIG_DIR is not CLAUDE_CODE_*, so it
    // survives the loop above, and a Codenotch started from a shell pointed at another account used to renew
    // that one while the account on screen stayed expired.
    cmd.env("CLAUDE_CONFIG_DIR", dir);
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
    /// Renews if the token is about to expire. Some(true) = the expiry moved; judged on the outcome, never on the
    /// exit status, because refusing the empty prompt is a non-zero exit and a successful renewal at the same time
    fn maybe_renew(&mut self, cred: &Credential, dir: &Path, who: &str) -> Option<bool> {
        let _auth = crate::claude_auth::try_acquire()?;
        let now = now_ms();
        if !should_renew(cred.expires_at, now, self.attempted_for, self.last_attempt, self.failures) {
            return None;
        }
        if self.attempted_for != cred.expires_at {
            self.failures = 0;
        }
        self.last_attempt = Some(now);
        self.attempted_for = cred.expires_at;
        self.failures = self.failures.saturating_add(1);
        let Some(cli) = find_cli() else {
            crate::applog(&format!(
                "claude[{who}]: token about to expire and no standalone claude CLI found to renew it"
            ));
            return Some(false);
        };
        if let Err(e) = run_renewal(&cli, dir) {
            crate::applog(&format!("claude[{who}]: token renewal could not start ({}): {e}", cli.display()));
            return Some(false);
        }
        let after = read_credentials(dir).and_then(|c| c.expires_at);
        let renewed = matches!((after, cred.expires_at), (Some(a), Some(b)) if a > b);
        crate::applog(&if renewed {
            format!("claude[{who}]: token renewed via {}", cli.display())
        } else {
            format!("claude[{who}]: ran {} but the token expiry did not move", cli.display())
        });
        Some(renewed)
    }
}

fn parse_reset(v: &serde_json::Value) -> Option<u64> {
    v.as_str()
        .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
        .map(|d| d.timestamp_millis().max(0) as u64)
}

fn label_for(kind: &str) -> String {
    match kind {
        "session" => "Current session".into(),
        "seven_day" | "weekly_all" => "Weekly (all models)".into(),
        "seven_day_opus" | "weekly_opus" => "Weekly (Opus)".into(),
        "weekly_scoped" => "Weekly (model-scoped)".into(),
        other => {
            // Forward compatibility: an unknown kind gets a readable label
            let mut s = other.replace('_', " ");
            if let Some(c) = s.get_mut(0..1) {
                c.make_ascii_uppercase();
            }
            s
        }
    }
}

/// An Enterprise seat answers with `limits` empty and both named windows null; its usage is only in
/// `spend` (upstream #359, spendWindow): the amount used against the spend limit, each in minor units.
/// The share is used / limit rather than `spend.percent`, which is rounded to a whole percent.
/// Skipped when disabled or the limit is zero, so no "0 of 0" is invented.
fn spend_window(v: &serde_json::Value) -> Option<LimitWindow> {
    let s = v.get("spend")?;
    if s.get("enabled").and_then(|x| x.as_bool()) == Some(false) {
        return None;
    }
    let minor = |k: &str| s.get(k).and_then(|m| m.get("amount_minor")).and_then(|x| x.as_f64());
    let (used, limit) = (minor("used")?, minor("limit")?);
    if !(limit > 0.0) {
        return None;
    }
    let money = |k: &str, amount: f64| {
        let m = s.get(k);
        let exp = m.and_then(|m| m.get("exponent")).and_then(|x| x.as_i64()).unwrap_or(2).clamp(0, 6);
        let cur = m.and_then(|m| m.get("currency")).and_then(|x| x.as_str()).unwrap_or("");
        format!("{:.*} {cur}", exp as usize, amount / 10f64.powi(exp as i32)).trim_end().to_string()
    };
    Some(LimitWindow {
        id: "spend".into(),
        label: format!("Spend limit ({} / {})", money("used", used), money("limit", limit)),
        used: (used / limit).clamp(0.0, 1.0),
        ..Default::default()
    })
}
fn duration_for(kind: &str) -> Option<u64> {
    if matches!(kind, "session" | "five_hour") {
        Some(FIVE_HOURS_MS)
    } else if kind.starts_with("weekly_") || kind.starts_with("seven_day") {
        Some(SEVEN_DAYS_MS)
    } else {
        None
    }
}

fn parse_response(v: &serde_json::Value) -> Vec<LimitWindow> {
    let mut out: Vec<LimitWindow> = Vec::new();
    if let Some(arr) = v.get("limits").and_then(|x| x.as_array()) {
        for l in arr {
            let Some(kind) = l.get("kind").and_then(|x| x.as_str()) else {
                continue;
            };
            let Some(pct) = l.get("percent").and_then(|x| x.as_f64()) else {
                continue;
            };
            let resets = l.get("resets_at").and_then(parse_reset);
            if resets.is_none() {
                continue; // upstream rule: a window without a reset time is not shown
            }
            out.push(LimitWindow {
                id: kind.to_string(),
                label: label_for(kind),
                used: (pct / 100.0).clamp(0.0, 1.0),
                resets_at: resets,
                duration_ms: duration_for(kind),
                ..Default::default()
            });
        }
    }
    // Fallback merge: a window that just rolled over disappears from limits while the named field remains.
    // In practice the kinds in limits are weekly_all/weekly_scoped, not seven_day — deduplicating by id
    // alone would add the seven_day fallback a second time (the card showed "Weekly all" and
    // "Weekly (all models)" as twins). Three dedupe rules: id alias / same resets_at and percentage / same label.
    let aliases: [(&str, &str, &[&str]); 2] = [
        ("five_hour", "session", &["session", "five_hour"]),
        ("seven_day", "seven_day", &["seven_day", "weekly_all", "weekly"]),
    ];
    for (field, id, alias) in aliases {
        let Some(w) = v.get(field) else { continue };
        let Some(u) = w.get("utilization").and_then(|x| x.as_f64()) else { continue };
        let used = (u / 100.0).clamp(0.0, 1.0);
        let resets_at = w.get("resets_at").and_then(parse_reset);
        let label = label_for(id);
        let dup = out.iter().any(|x| {
            alias.contains(&x.id.as_str())
                || x.label == label
                || (resets_at.is_some()
                    && x.resets_at.map(|r| r / 1000) == resets_at.map(|r| r / 1000)
                    && (x.used - used).abs() < 0.005)
        });
        if dup {
            continue;
        }
        out.push(LimitWindow { id: id.into(), label, used, resets_at, duration_ms: duration_for(id), ..Default::default() });
    }
    if let Some(w) = spend_window(v) {
        out.push(w);
    }
    // session always comes first (upstream display order)
    out.sort_by_key(|w| if w.id == "session" { 0 } else { 1 });
    out
}

enum FetchErr {
    NeedsAuth,
    RateLimited(u64), // suggested wait in seconds (the Retry-After before the floor is applied)
    Other(String),
}

fn parse_retry_after(header: &str) -> Option<u64> {
    let header = header.trim();
    header.parse::<u64>().ok().or_else(|| {
        chrono::DateTime::parse_from_rfc2822(header).ok().map(|date| {
            date.timestamp().saturating_sub(chrono::Utc::now().timestamp()).max(0) as u64
        })
    })
}

fn fetch_once(token: &str) -> Result<Vec<LimitWindow>, FetchErr> {
    let resp = ureq::get(ENDPOINT)
        .set("Authorization", &format!("Bearer {token}"))
        .set("anthropic-beta", "oauth-2025-04-20")
        .timeout(Duration::from_secs(15))
        .call();
    match resp {
        Ok(r) => {
            let v: serde_json::Value = r
                .into_json()
                .map_err(|e| FetchErr::Other(format!("parse: {e}")))?;
            Ok(parse_response(&v))
        }
        Err(ureq::Error::Status(401, _)) => Err(FetchErr::NeedsAuth),
        Err(ureq::Error::Status(403, _)) => Err(FetchErr::Other(
            "Claude HTTP 403: access denied. Check network or account access; sign-in may still be valid.".into())),
        Err(ureq::Error::Status(429, r)) => {
            let ra = r
                .header("retry-after")
                .and_then(parse_retry_after)
                .unwrap_or(0);
            Err(FetchErr::RateLimited(ra))
        }
        Err(ureq::Error::Status(code, _)) => Err(FetchErr::Other(format!("HTTP {code}"))),
        Err(e) => Err(FetchErr::Other(format!("{e}"))),
    }
}

fn backoff_secs(consecutive: u32, retry_after_floor: u64) -> u64 {
    let exp = BACKOFF_BASE_SECS.saturating_mul(1u64 << consecutive.min(4));
    // The server's Retry-After is honoured in full: with expired tokens no longer
    // sent, a long one is a real rate limit, and retrying early only earns another.
    exp.clamp(BACKOFF_BASE_SECS, BACKOFF_CAP_SECS).max(retry_after_floor)
}

fn set_and_broadcast(app: &AppHandle, mutate: impl FnOnce(&mut UsageSnapshot)) {
    let st = app.state::<AppState>();
    let snap = {
        let mut u = st.usage.lock().unwrap();
        mutate(&mut u);
        u.clone()
    };
    persist(&snap);
    let _ = app.emit("usage", &snap);
}

/// What one account contributes to the shared reading. Kept across ticks so a refresh that fails for
/// one account keeps showing that account's last good windows, and never blanks the other one.
#[derive(Default)]
struct Account {
    renewer: Renewer,
    consecutive_429: u32,
    backoff_until: u64,
    windows: Vec<LimitWindow>,
    status: String,
    note: String,
    fetched_at: u64,
    last_fetch: u64,
    last_rate_limit_at: u64,
}

fn key(p: &Profile) -> String {
    p.dir.to_string_lossy().to_string()
}

/// The account's windows as they go on the card: its name in `group`, and for a secondary account an
/// id suffixed with the slug -- which is what keeps `by_id("session")` in the notch meaning the default
/// account's session and not whichever account answered first.
fn decorate(mut windows: Vec<LimitWindow>, p: &Profile, group: Option<&str>) -> Vec<LimitWindow> {
    for w in &mut windows {
        if let Some(g) = group {
            w.group = Some(g.to_string());
        }
        if let Some(slug) = &p.slug {
            w.id = format!("{}@{slug}", w.id);
        }
    }
    windows
}

/// Hands each account back the windows it contributed before the restart: a secondary account's ids
/// carry `@slug`, so both accounts come back from disk instead of only the default one.
fn split_persisted(snap: &UsageSnapshot, order: &[Profile]) -> HashMap<String, Vec<LimitWindow>> {
    let mut out: HashMap<String, Vec<LimitWindow>> = HashMap::new();
    for w in &snap.windows {
        let owner = order.iter().find(|p| match &p.slug {
            Some(sl) => w.id.ends_with(&format!("@{sl}")),
            None => !w.id.contains('@'),
        });
        if let Some(p) = owner {
            out.entry(key(p)).or_default().push(w.clone());
        }
    }
    out
}

fn restore_accounts(snap: &UsageSnapshot, order: &[Profile], backoffs: Option<&HashMap<String, u64>>, now: u64) -> HashMap<String, Account> {
    let mut windows = split_persisted(snap, order);
    order.iter().map(|p| {
        let profile_key = key(p);
        let id = p.slug.as_deref().unwrap_or("default");
        let saved = snap.accounts.iter().find(|account| account.id == id);
        let legacy = backoffs.map(|saved| saved.get(&profile_key).copied().unwrap_or(0)).unwrap_or(snap.backoff_until);
        // A crash between the two writes must not discard the longer server deadline.
        let deadline = saved.map(|account| account.backoff_until).unwrap_or(0).max(legacy);
        let fetched_at = saved.map(|account| account.fetched_at).unwrap_or(snap.fetched_at);
        let account = Account {
            windows: windows.remove(&profile_key).unwrap_or_else(|| saved.map(|account| decorate(account.windows.clone(), p, None)).unwrap_or_default()),
            fetched_at,
            status: saved.map(|account| account.status.clone()).unwrap_or_else(|| snap.status.clone()),
            note: saved.map(|account| account.note.clone()).unwrap_or_else(|| snap.note.clone()),
            backoff_until: if deadline > now { deadline } else { 0 },
            last_fetch: saved.map(|account| account.last_attempt_at).unwrap_or(0).max(fetched_at),
            consecutive_429: saved.map(|account| account.consecutive_429).unwrap_or(0),
            last_rate_limit_at: saved.map(|account| account.last_rate_limit_at).unwrap_or(0),
            ..Default::default()
        };
        (profile_key, account)
    }).collect()
}

pub(crate) fn should_fetch(last_fetch: u64, now: u64, windows: &[LimitWindow]) -> bool {
    last_fetch == 0 || now.saturating_sub(last_fetch) >= MIN_FETCH_SECS * 1000
        || windows.iter().any(|window| matches!(window.resets_at, Some(reset) if reset > last_fetch && reset <= now))
}

fn fetch_account(acc: &mut Account, token: &str, who: &str) -> Result<Vec<LimitWindow>, FetchErr> {
    acc.last_fetch = now_ms();
    crate::applog(&format!("claude[{who}]: GET /api/oauth/usage"));
    fetch_once(token)
}

/// One reading out of every account's, in profile order. The status is the best news any account has:
/// a second account that needs signing in must not dim a first one that just answered.
fn aggregate(order: &[Profile], accounts: &HashMap<String, Account>) -> UsageSnapshot {
    let rank = |s: &str| match s {
        "ok" => 0,
        "stale" => 1,
        "error" => 2,
        _ => 3, // needsAuth, and anything not set yet
    };
    let multi = order.len() > 1;
    let mut snap = UsageSnapshot::default();
    let mut notes: Vec<String> = Vec::new();
    let mut best = 4;
    for p in order {
        let Some(a) = accounts.get(&key(p)) else {
            continue;
        };
        snap.windows.extend(a.windows.iter().cloned());
        snap.accounts.push(ClaudeAccountUsage {
            id: p.slug.clone().unwrap_or_else(|| "default".into()), name: p.name(),
            status: a.status.clone(), note: a.note.clone(), fetched_at: a.fetched_at,
            backoff_until: a.backoff_until,
            consecutive_429: a.consecutive_429, last_rate_limit_at: a.last_rate_limit_at, last_attempt_at: a.last_fetch,
            address: p.address.clone(), plan: read_credentials(&p.dir).and_then(|c| c.plan),
            windows: a.windows.iter().cloned().map(|mut w| {
                if let Some(slug) = &p.slug { w.id = w.id.strip_suffix(&format!("@{slug}")).unwrap_or(&w.id).to_string(); }
                w.group = None; w
            }).collect(),
        });

        snap.fetched_at = snap.fetched_at.max(a.fetched_at);
        if !a.status.is_empty() && rank(a.status.as_str()) < best {
            best = rank(a.status.as_str());
            snap.status = a.status.clone();
        }
        if !a.note.is_empty() {
            notes.push(if multi { format!("{}: {}", p.name(), a.note) } else { a.note.clone() });
        }
        // The soonest deadline is the one worth waking for
        if a.backoff_until > 0 && (snap.backoff_until == 0 || a.backoff_until < snap.backoff_until) {
            snap.backoff_until = a.backoff_until;
        }
    }
    if snap.status.is_empty() {
        snap.status = if order.is_empty() { "absent" } else { "needsAuth" }.into();
    }
    snap.note = notes.join(" · ");
    snap
}

/// One account's turn: renew if the token is aging, then read it, exactly as the single-account loop did.
fn poll_account(p: &Profile, acc: &mut Account, group: Option<&str>) {
    let who = p.name();
    // Renewal stays responsive, but token rotation cannot cancel the endpoint's penalty.
    if let Some(cred) = read_credentials(&p.dir) {
        acc.renewer.maybe_renew(&cred, &p.dir, &who);
    }
    // No requests inside this account's back-off window
    if acc.backoff_until > now_ms() {
        return;
    }
    acc.backoff_until = 0;
    if !should_fetch(acc.last_fetch, now_ms(), &acc.windows) {
        return;
    }
    match read_credentials(&p.dir) {
        None => {
            acc.status = "needsAuth".into();
            acc.note = "No Claude Code credential found".into();
        }
        // Expired is not signed out: keep the last reading, dimmed and dated, and send nothing
        Some(cred) if cred.expired(now_ms()) => {
            acc.status = if acc.windows.is_empty() { "needsAuth" } else { "stale" }.into();
            acc.note = EXPIRED_NOTE.into();
        }
        Some(cred) => {
            let token = cred.token;
            // On 401 re-read the credential and retry once (Claude Code may have just refreshed it)
            let result = match fetch_account(acc, &token, &who) {
                Err(FetchErr::NeedsAuth) => match read_credentials(&p.dir) {
                    Some(c2) if c2.token != token && !c2.expired(now_ms()) => fetch_account(acc, &c2.token, &who),
                    _ => Err(FetchErr::NeedsAuth),
                },
                other => other,
            };
            match result {
                Ok(windows) => {
                    crate::claude_auth::usage_succeeded(p.slug.as_deref().unwrap_or("default"));
                    acc.consecutive_429 = 0;
                    acc.status = "ok".into();
                    acc.windows = decorate(windows, p, group);
                    acc.fetched_at = now_ms();
                    acc.note.clear();
                    acc.backoff_until = 0;
                }
                Err(FetchErr::NeedsAuth) => {
                    acc.status = "needsAuth".into();
                    acc.note = "Credential rejected (switched accounts?)".into();
                }
                Err(FetchErr::RateLimited(ra)) => {
                    if acc.windows.is_empty() { acc.status = "backoff".into(); }
                    acc.consecutive_429 = acc.consecutive_429.saturating_add(1);
                    let wait = backoff_secs(acc.consecutive_429 - 1, ra);
                    // The status is left alone: a refused refresh says nothing about the reading we are
                    // holding, which is exactly as old as it was a moment ago. Marking it stale here
                    // dimmed the ring on the first 429, which on Windows is often the first minute of a
                    // rate limit. Age decides, as it does on the Mac (`UsageStore` keeps the previous
                    // status until `staleAfter`), and the note says why it is not moving.
                    acc.note = format!("Rate limited, retrying in {wait}s");
                    acc.last_rate_limit_at = now_ms();
                    acc.backoff_until = acc.last_rate_limit_at.saturating_add(wait.saturating_mul(1000));
                }
                Err(FetchErr::Other(msg)) => {
                    // No reading at all is an error worth showing; a reading we could not refresh is
                    // just a reading, and its own age is what makes it stale.
                    if acc.windows.is_empty() {
                        acc.status = "error".into();
                    }
                    acc.note = msg;
                }
            }
        }
    }
}

fn poll_selected_accounts(order: &[Profile], accounts: &mut HashMap<String, Account>, requested: &RefreshRequest) {
    let multi = order.len() > 1;
    for p in order.iter().filter(|p| requested.includes(p)) {
        let group = if multi {
            Some(p.group(read_credentials(&p.dir).and_then(|c| c.plan).as_deref()))
        } else {
            None
        };
        let acc = accounts.entry(key(p)).or_default();
        poll_account(p, acc, group.as_deref());
    }
}

/// Regular polling and each account's retry are separate clocks. A throttled
/// profile must not turn the other profiles' five-minute cadence into 30 seconds.
fn next_scheduled_refresh(next_regular: u64, order: &[Profile], accounts: &HashMap<String, Account>) -> (u64, RefreshRequest) {
    let retry = order.iter().filter_map(|p| accounts.get(&key(p)))
        .map(|a| a.backoff_until).filter(|deadline| *deadline > 0).min();
    let Some(retry) = retry.filter(|deadline| *deadline < next_regular) else {
        return (next_regular, RefreshRequest::all());
    };
    let ids = order.iter().filter(|p| accounts.get(&key(p)).is_some_and(|a| a.backoff_until == retry))
        .map(|p| p.slug.clone().unwrap_or_else(|| "default".into())).collect();
    (retry, RefreshRequest { all: false, accounts: ids })
}

pub fn start(app: AppHandle) {
    std::thread::spawn(move || {
        // Broadcast the persisted old reading at startup (stale beats blank)
        let persisted = {
            let st = app.state::<AppState>();
            let snap = st.usage.lock().unwrap().clone();
            let _ = app.emit("usage", &snap);
            snap
        };
        let backoffs = load_backoffs();
        let mut accounts = restore_accounts(&persisted, &profiles(), backoffs.as_ref(), now_ms());
        let mut requested = RefreshRequest::all();
        let mut next_regular = now_ms();
        loop {
            // A sign-in the user started owns the credential until it finishes. Polling through it
            // reads a file being rewritten and reports a signed-out account mid-login.
            if crate::claude_auth::state().busy {
                // Leave requests queued while authentication owns the credentials.
                std::thread::sleep(Duration::from_secs(1));
                continue;
            }
            requested.merge(take_refresh());
            if now_ms() >= next_regular { requested.merge(RefreshRequest::all()); }
            // Re-read the list each tick: an account signed into or removed while this runs needs no restart
            let order = profiles();
            poll_selected_accounts(&order, &mut accounts, &requested);
            accounts.retain(|k, _| order.iter().any(|p| key(p) == *k));
            persist_backoffs(&accounts);
            let snap = aggregate(&order, &accounts);
            set_and_broadcast(&app, |u| *u = snap);
            // Preserve upstream renewal cadence; should_fetch owns the endpoint floor.
            let active = {
                let st = app.state::<AppState>();
                let store = st.store.lock().unwrap();
                let s = store.snapshot("en", "en", false, false);
                !s.sessions.is_empty()
            };
            let base = if active { POLL_ACTIVE_SECS } else { POLL_IDLE_SECS };
            if requested.all {
                next_regular = now_ms().saturating_add(base * 1000);
            }
            let (deadline, automatic) = next_scheduled_refresh(next_regular, &order, &accounts);
            requested = sleep_interruptible(deadline, automatic);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn claude_aliases_have_known_durations_only() {
        for (kind, expected) in [
            ("session", Some(FIVE_HOURS_MS)), ("five_hour", Some(FIVE_HOURS_MS)),
            ("weekly_all", Some(SEVEN_DAYS_MS)), ("weekly_scoped", Some(SEVEN_DAYS_MS)),
            ("weekly_opus", Some(SEVEN_DAYS_MS)), ("seven_day", Some(SEVEN_DAYS_MS)),
            ("seven_day_opus", Some(SEVEN_DAYS_MS)), ("seven_day_future", Some(SEVEN_DAYS_MS)),
            ("weekly_future", Some(SEVEN_DAYS_MS)), ("monthly", None), ("unknown", None),
        ] {
            let windows = parse_response(&serde_json::json!({"limits": [{
                "kind": kind, "percent": 60, "resets_at": "2026-10-10T00:00:00Z"
            }]}));
            assert_eq!(windows.len(), 1, "{kind}");
            assert_eq!(windows[0].duration_ms, expected, "{kind}");
        }
        let windows = parse_response(&serde_json::json!({
            "five_hour": {"utilization": 60, "resets_at": "2026-10-10T00:00:00Z"},
            "seven_day": {"utilization": 20, "resets_at": "2026-10-17T00:00:00Z"}
        }));
        assert_eq!(windows.iter().map(|w| w.duration_ms).collect::<Vec<_>>(),
            [Some(FIVE_HOURS_MS), Some(SEVEN_DAYS_MS)]);
    }

    #[test]
    fn old_persisted_usage_without_duration_still_deserializes() {
        let old = r#"{"status":"ok","windows":[{"id":"session","label":"Current session",
            "used":0.6,"resets_at":1791590400000}],"fetched_at":1791581400000,"note":"saved"}"#;
        let snap: UsageSnapshot = serde_json::from_str(old).unwrap();
        assert_eq!(snap.status, "ok");
        assert_eq!(snap.windows[0].used, 0.6);
        assert_eq!(snap.windows[0].duration_ms, None);
        assert_eq!(snap.backoff_until, 0);
        let mut snap = snap;
        snap.windows[0].duration_ms = Some(FIVE_HOURS_MS);
        snap.windows.push(LimitWindow { id: "requests".into(), count: Some(3), ..Default::default() });
        let json = serde_json::to_value(&snap).unwrap();
        assert_eq!(json["windows"][0]["duration_ms"], FIVE_HOURS_MS);
        let restored: UsageSnapshot = serde_json::from_value(json).unwrap();
        assert_eq!(restored.windows[0].duration_ms, Some(FIVE_HOURS_MS));
        assert_eq!(restored.windows[1].count, Some(3));
        assert_eq!(restored.windows[1].duration_ms, None);
    }

    #[test]
    fn duration_helpers_reject_invalid_lengths() {
        for seconds in [0.0, -1.0, f64::NAN, f64::INFINITY, f64::NEG_INFINITY, 1e30, 0.0001] {
            assert_eq!(duration_from_seconds(seconds), None, "{seconds}");
        }
        assert_eq!(duration_from_seconds(18000.0), Some(FIVE_HOURS_MS));
        assert_eq!(duration_from_seconds(1.25), Some(1250));
        assert_eq!(duration_between_ms(Some(10), Some(20)), Some(10));
        for (start, end) in [(None, Some(20)), (Some(10), None), (Some(10), Some(10)), (Some(20), Some(10))] {
            assert_eq!(duration_between_ms(start, end), None);
        }
        assert_eq!(calendar_month_duration_ms(None), None);
        assert_eq!(calendar_month_duration_ms(Some(u64::MAX)), None);
    }

    #[test]
    fn calendar_month_lengths_use_utc_and_clamp_month_end() {
        for (reset, days) in [
            ("2024-03-01T00:00:00Z", 29), ("2025-03-01T00:00:00Z", 28),
            ("2026-01-01T00:00:00Z", 31), ("2026-10-03T13:09:45.611Z", 30),
            ("2024-03-31T13:09:45.611Z", 31), ("2025-03-31T13:09:45.611Z", 31),
        ] {
            let ms = chrono::DateTime::parse_from_rfc3339(reset).unwrap().timestamp_millis() as u64;
            assert_eq!(calendar_month_duration_ms(Some(ms)), Some(days * 86_400_000), "{reset}");
        }
    }


    const EXP: u64 = 1_000_000_000;

    #[test]
    fn fetch_floor_applies_to_every_attempt() {
        assert!(should_fetch(0, EXP, &[]));
        assert!(!should_fetch(EXP, EXP + 60_000, &[]));
        assert!(!should_fetch(EXP, EXP + MIN_FETCH_SECS * 1000 - 1, &[]));
        assert!(should_fetch(EXP, EXP + MIN_FETCH_SECS * 1000, &[]));
        assert!(!should_fetch(EXP, EXP - 1, &[]));
    }

    #[test]
    fn a_rollover_bypasses_the_floor_only_once() {
        let reset = EXP + 60_000;
        let windows = vec![LimitWindow { resets_at: Some(reset), ..win("session") }];
        assert!(!should_fetch(EXP, reset - 1, &windows));
        assert!(should_fetch(EXP, reset, &windows));
        assert!(!should_fetch(reset, reset + 1, &windows));
        assert!(!should_fetch(reset + 1, reset + 60_000, &windows));
    }

    #[test]
    fn retry_after_accepts_seconds_and_http_dates() {
        assert_eq!(parse_retry_after(" 3600 "), Some(3600));
        assert_eq!(parse_retry_after("0"), Some(0));
        assert_eq!(parse_retry_after("Wed, 21 Oct 2015 07:28:00 GMT"), Some(0));
        assert_eq!(parse_retry_after("invalid"), None);
        assert_eq!(parse_retry_after(""), None);
        let future = chrono::Utc::now() + chrono::Duration::seconds(3600);
        let header = future.format("%a, %d %b %Y %H:%M:%S GMT").to_string();
        let seconds = parse_retry_after(&format!(" {header} ")).unwrap();
        assert!((3598..=3600).contains(&seconds));
    }

    #[test]
    fn each_profile_restores_its_own_future_deadline() {
        let order = vec![prof(None), prof(Some("work"))];
        let snap = UsageSnapshot { backoff_until: EXP + 100, ..Default::default() };
        let saved = HashMap::from([(key(&order[0]), EXP + 100), (key(&order[1]), EXP + 1000)]);
        let restored = restore_accounts(&snap, &order, Some(&saved), EXP);
        assert_eq!(restored[&key(&order[0])].backoff_until, EXP + 100);
        assert_eq!(restored[&key(&order[1])].backoff_until, EXP + 1000);
        let expired = restore_accounts(&snap, &order, Some(&saved), EXP + 101);
        assert_eq!(expired[&key(&order[0])].backoff_until, 0);
        assert_eq!(expired[&key(&order[1])].backoff_until, EXP + 1000);
    }

    #[test]
    fn legacy_deadline_is_restored_conservatively() {
        let order = vec![prof(None), prof(Some("work"))];
        let snap = UsageSnapshot { backoff_until: EXP + 100, ..Default::default() };
        let restored = restore_accounts(&snap, &order, None, EXP);
        assert!(restored.values().all(|account| account.backoff_until == EXP + 100));
        let expired = restore_accounts(&snap, &order, None, EXP + 100);
        assert!(expired.values().all(|account| account.backoff_until == 0));
        let empty = HashMap::new();
        let restored = restore_accounts(&snap, &order, Some(&empty), EXP);
        assert!(restored.values().all(|account| account.backoff_until == 0));
    }


    #[test]
    fn enterprise_seat_reads_its_spend_limit() {
        let v = serde_json::json!({
            "five_hour": null, "seven_day": null, "limits": [],
            "spend": {
                "used": {"amount_minor": 1214, "currency": "USD", "exponent": 2},
                "limit": {"amount_minor": 15000, "currency": "USD", "exponent": 2},
                "percent": 8, "enabled": true
            }
        });
        let ws = parse_response(&v);
        assert_eq!(ws.len(), 1);
        assert_eq!(ws[0].id, "spend");
        assert_eq!(ws[0].label, "Spend limit (12.14 USD / 150.00 USD)");
        assert!((ws[0].used - 1214.0 / 15000.0).abs() < 1e-9, "used / limit, not the rounded percent");
        assert_eq!(ws[0].resets_at, None);
    }

    #[test]
    fn spend_is_skipped_when_disabled_or_unlimited() {
        let off = serde_json::json!({"spend": {"enabled": false,
            "used": {"amount_minor": 1}, "limit": {"amount_minor": 100}}});
        assert!(parse_response(&off).is_empty());
        let zero = serde_json::json!({"spend": {"enabled": true,
            "used": {"amount_minor": 0}, "limit": {"amount_minor": 0}}});
        assert!(parse_response(&zero).is_empty());
    }

    #[test]
    fn plan_windows_still_come_first() {
        let v = serde_json::json!({
            "five_hour": {"utilization": 40.0, "resets_at": "2026-10-08T20:00:00Z"},
            "spend": {"enabled": true, "used": {"amount_minor": 1}, "limit": {"amount_minor": 100}}
        });
        let ids: Vec<_> = parse_response(&v).into_iter().map(|w| w.id).collect();
        assert_eq!(ids, ["session", "spend"]);
    }

    #[test]
    fn renews_only_inside_the_margin() {
        assert!(!should_renew(None, EXP, None, None, 0), "never launch on a guess");
        assert!(!should_renew(Some(EXP), EXP - RENEW_MARGIN_MS - 1, None, None, 0), "plenty of time left");
        assert!(should_renew(Some(EXP), EXP - RENEW_MARGIN_MS, None, None, 0));
        assert!(should_renew(Some(EXP), EXP + 3_600_000, None, None, 0), "already expired still renews");
    }

    #[test]
    fn a_new_token_waits_out_the_cooldown() {
        let now = EXP + 1;
        assert!(!should_renew(Some(EXP + 5), now, Some(EXP), Some(now - 1000), 1), "cooldown holds a new token back");
        assert!(should_renew(Some(EXP + 5), now, Some(EXP), Some(now - RENEW_COOLDOWN_MS), 1));
    }

    #[test]
    fn a_failed_token_is_retried_on_a_doubling_wait() {
        let now = EXP + 1;
        assert!(!should_renew(Some(EXP), now, Some(EXP), Some(now - RENEW_COOLDOWN_MS), 1), "no retry at the plain cooldown");
        assert!(should_renew(Some(EXP), now, Some(EXP), Some(now - 2 * RENEW_COOLDOWN_MS), 1), "retried after twice the cooldown");
        assert!(!should_renew(Some(EXP), now, Some(EXP), Some(now - 2 * RENEW_COOLDOWN_MS), 2), "the wait doubles");
        assert!(should_renew(Some(EXP), now, Some(EXP), Some(now - 4 * RENEW_COOLDOWN_MS), 2));
        assert!(!should_renew(Some(EXP), now, Some(EXP), Some(now - RENEW_RETRY_CAP_MS + 1), 30), "never a tight loop");
        assert!(should_renew(Some(EXP), now, Some(EXP), Some(now - RENEW_RETRY_CAP_MS), 30), "but never more than an hour apart");
    }

    #[test]
    fn retry_after_can_exceed_our_schedule_cap() {
        assert_eq!(backoff_secs(0, 3600), 3600);
        assert_eq!(backoff_secs(0, 0), BACKOFF_BASE_SECS);
        assert_eq!(backoff_secs(1, 300), 300);
        assert_eq!(backoff_secs(9, 0), BACKOFF_CAP_SECS);
    }

    #[test]
    fn desktop_bundled_cli_is_refused() {
        use std::path::Path;
        assert!(is_desktop_owned(Path::new(r"C:\Users\u\AppData\Local\AnthropicClaude\app-1.2.3\claude.exe")));
        assert!(is_desktop_owned(Path::new(r"C:\Users\u\AppData\Roaming\Claude\claude-code\2.1.0\claude.exe")));
        assert!(!is_desktop_owned(Path::new(r"C:\Users\u\.local\bin\claude.exe")));
        assert!(!is_desktop_owned(Path::new(r"C:\Users\u\AppData\Roaming\npm\claude.cmd")));
    }

    #[test]
    #[ignore = "Runs the installed standalone claude CLI; opt in for integration verification"]
    fn live_renewal_runs_the_standalone_cli() {
        let cli = find_cli().expect("a standalone claude CLI");
        assert!(!is_desktop_owned(&cli));
        let p = profiles().into_iter().next().expect("a profile");
        let before = read_credentials(&p.dir).and_then(|c| c.expires_at);
        let t = std::time::Instant::now();
        run_renewal(&cli, &p.dir).expect("spawned");
        assert!(t.elapsed() < Duration::from_secs(RENEW_TIMEOUT_SECS), "returned before the timeout");
        let after = read_credentials(&p.dir).and_then(|c| c.expires_at);
        assert!(after >= before, "the expiry never moves backwards");
        eprintln!("cli: {}", cli.display());
    }

    fn prof(slug: Option<&str>) -> Profile {
        Profile {
            dir: PathBuf::from(match slug {
                Some(s) => format!("/home/u/.claude-{s}"),
                None => "/home/u/.claude".to_string(),
            }),
            slug: slug.map(String::from),
            label: None,
            address: None,
        }
    }

    fn win(id: &str) -> LimitWindow {
        LimitWindow { id: id.into(), label: "Current session".into(), used: 0.5, ..Default::default() }
    }

    #[test]
    fn a_targeted_refresh_keeps_other_accounts_reading_and_backoff_untouched() {
        let mut order = vec![prof(None), prof(Some("work"))];
        for (index, p) in order.iter_mut().enumerate() {
            p.dir = std::env::temp_dir().join(format!("codenotch-no-credentials-{}-{index}", std::process::id()));
            assert!(!p.dir.exists(), "fixture must not contain a real credential");
        }
        let mut accounts = HashMap::new();
        accounts.insert(key(&order[0]), Account { windows: vec![win("session")], status: "ok".into(),
            fetched_at: 10, backoff_until: 123, consecutive_429: 3, ..Default::default() });
        let requested = RefreshRequest { all: false, accounts: vec!["work".into()] };
        poll_selected_accounts(&order, &mut accounts, &requested);
        assert_eq!(accounts[&key(&order[1])].status, "needsAuth");
        let untouched = &accounts[&key(&order[0])];
        assert_eq!(untouched.status, "ok");
        assert_eq!(untouched.fetched_at, 10);
        assert_eq!(untouched.windows[0].used, 0.5);
        assert_eq!(untouched.backoff_until, 123);
        assert_eq!(untouched.consecutive_429, 3);
        assert_eq!(aggregate(&order, &accounts).accounts.len(), 2);
    }

    #[test]
    fn refresh_requests_coalesce_accounts_and_a_full_refresh_still_covers_every_profile() {
        let mut request = RefreshRequest { all: false, accounts: vec!["work".into()] };
        request.merge(RefreshRequest { all: false, accounts: vec!["work".into(), "other".into()] });
        assert_eq!(request.accounts, vec!["work", "other"]);
        assert!(!request.includes(&prof(None)));
        assert!(request.includes(&prof(Some("work"))));
        request.merge(RefreshRequest::all());
        assert!(request.includes(&prof(None)));
        assert!(request.includes(&prof(Some("unlisted"))));
        assert!(request.accounts.is_empty(), "full refresh subsumes queued account clicks");
    }

    #[test]
    fn restarting_and_targeted_refresh_preserve_a_live_server_deadline_and_history() {
        let order = vec![prof(None), prof(Some("work"))];
        let deadline = now_ms().saturating_add(480_000);
        let persisted = UsageSnapshot { accounts: vec![ClaudeAccountUsage { id: "work".into(),
            status: "stale".into(), backoff_until: deadline, consecutive_429: 4, last_rate_limit_at: deadline - 480_000,
            note: "Rate limited, retrying in 480s".into(), ..Default::default() }], ..Default::default() };
        let mut accounts = restore_accounts(&persisted, &order, None, now_ms());
        poll_selected_accounts(&order, &mut accounts, &RefreshRequest { all: false, accounts: vec!["work".into()] });
        let account = &accounts[&key(&order[1])];
        assert_eq!(account.backoff_until, deadline, "a click or reload cannot extend or bypass Retry-After");
        assert_eq!(account.consecutive_429, 4);
        assert_eq!(account.last_rate_limit_at, deadline - 480_000);
        assert_eq!(account.note, "Rate limited, retrying in 480s");
        assert_eq!(aggregate(&order, &accounts).accounts[1].backoff_until, deadline);
    }

    #[test]
    fn restarting_preserves_the_official_floor_after_a_failed_account_attempt() {
        let order = vec![prof(None), prof(Some("work"))];
        let persisted = UsageSnapshot { accounts: vec![ClaudeAccountUsage {
            id: "work".into(), fetched_at: EXP - 600_000, last_attempt_at: EXP,
            status: "ok".into(), ..Default::default()
        }], ..Default::default() };
        let restored = restore_accounts(&persisted, &order, Some(&HashMap::new()), EXP + 60_000);
        let work = &restored[&key(&order[1])];
        assert_eq!(work.last_fetch, EXP);
        assert!(!should_fetch(work.last_fetch, EXP + 60_000, &work.windows));
        assert!(should_fetch(work.last_fetch, EXP + 300_000, &work.windows));
        assert!(should_fetch(restored[&key(&order[0])].last_fetch, EXP + 60_000, &[]));
        assert_eq!(aggregate(&order, &restored).accounts[1].last_attempt_at, EXP);
    }

    #[test]
    fn one_account_reads_exactly_as_before() {
        let w = decorate(vec![win("session")], &prof(None), None);
        assert_eq!(w[0].id, "session", "the only account keeps its ids");
        assert_eq!(w[0].group, None, "and stays ungrouped, so its card is the card that shipped");
    }

    #[test]
    fn a_second_account_is_suffixed_and_grouped() {
        let w = decorate(vec![win("session")], &prof(Some("work")), Some("work · pro"));
        assert_eq!(w[0].id, "session@work", "so by_id(\"session\") still means the default account");
        assert_eq!(w[0].group.as_deref(), Some("work · pro"));
    }

    #[test]
    fn the_group_pairs_the_name_with_the_plan() {
        assert_eq!(prof(None).group(Some("max")), "default · max");
        assert_eq!(prof(Some("work")).group(None), "work");
        assert_eq!(prof(Some("work")).group(Some("")), "work", "an empty plan adds no separator");
    }

    #[test]
    fn persisted_windows_go_back_to_the_account_that_made_them() {
        let order = vec![prof(None), prof(Some("work"))];
        let snap = UsageSnapshot {
            windows: vec![win("session"), win("session@work"), win("weekly@gone")],
            ..Default::default()
        };
        let split = split_persisted(&snap, &order);
        assert_eq!(split[&key(&order[0])].len(), 1);
        assert_eq!(split[&key(&order[1])][0].id, "session@work");
        assert_eq!(split.len(), 2, "windows from an account that is gone are dropped");
    }

    #[test]
    fn status_is_the_best_news_any_account_has() {
        let order = vec![prof(None), prof(Some("work"))];
        let mut accounts: HashMap<String, Account> = HashMap::new();
        accounts.insert(
            key(&order[0]),
            Account { status: "ok".into(), windows: vec![win("session")], fetched_at: 10, ..Default::default() },
        );
        accounts.insert(
            key(&order[1]),
            Account {
                status: "needsAuth".into(),
                note: "No Claude Code credential found".into(),
                ..Default::default()
            },
        );
        let snap = aggregate(&order, &accounts);
        assert_eq!(snap.status, "ok", "a signed-out second account must not dim the first");
        assert_eq!(snap.windows.len(), 1);
        assert_eq!(snap.fetched_at, 10);
        assert!(snap.note.starts_with("work: "), "the note names the account: {}", snap.note);
    }

    #[test]
    fn the_soonest_back_off_is_the_one_waited_out() {
        let order = vec![prof(None), prof(Some("work"))];
        let mut accounts: HashMap<String, Account> = HashMap::new();
        accounts.insert(key(&order[0]), Account { backoff_until: 900, ..Default::default() });
        accounts.insert(key(&order[1]), Account { backoff_until: 300, ..Default::default() });
        assert_eq!(aggregate(&order, &accounts).backoff_until, 300);
    }

    #[test]
    fn the_default_account_is_first_and_always_listed() {
        // Discovery reads the real home, so this asserts only what holds on any machine
        let list = profiles();
        assert!(!list.is_empty(), "the default account is listed even with no credential");
        assert_eq!(list[0].slug, None, "and comes first, so it owns the notch");
        let slugs: Vec<Option<String>> = list.iter().skip(1).map(|p| p.slug.clone()).collect();
        let mut sorted = slugs.clone();
        sorted.sort();
        assert_eq!(slugs, sorted, "secondary accounts are listed in name order");
        assert!(list.iter().skip(1).all(|p| p.slug.is_some()), "only the default account has no slug");
    }

    #[test]
    fn expired_is_judged_against_now() {
        let c = Credential { token: "t".into(), expires_at: Some(EXP), ..Default::default() };
        assert!(c.expired(EXP));
        assert!(!c.expired(EXP - 1));
        assert!(!Credential { token: "t".into(), expires_at: None, ..Default::default() }.expired(EXP));
    }
}
