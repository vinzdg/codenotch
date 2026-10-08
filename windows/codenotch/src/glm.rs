//! GLM Coding Plan usage adapter (Z.ai), ported from the upstream macOS GLMUsage/GLMCredentials.
//!
//! Endpoint: GET {console}/api/monitor/usage/quota/limit — the monitor Z.ai's own plan
//! page reads. Authenticated with a raw API key — no "Bearer" scheme — borrowed from
//! whichever coding tool already holds one. Sources, in order:
//!   1. a manual key file next to the config: glm.json {"api_key":"...","base_url":"https://api.z.ai"}
//!   1b. Claude Code: ~/.claude/settings.json env.ANTHROPIC_AUTH_TOKEN, claimed only when
//!      env.ANTHROPIC_BASE_URL points at a Z.ai console
//!   2. ZCode's plan key: ~/.zcode/v2/config.json, an enabled builtin:*-coding-plan entry
//!      with a plaintext apiKey; the baseURL beside it decides which console (z.ai or bigmodel.cn).
//!      Older ZCode only — recent builds no longer write this file, and everything below applies.
//!   3. ZCode's credentials: ~/.zcode/v2/credentials.json — one plan key per account as
//!      `account-provider:…:api-key`, else the sign-in tokens `oauth:zai:access_token` and
//!      `oauth:bigmodel:access_token`. Every value is encrypted at rest behind an `enc:v1:`
//!      marker and decrypted with ZCode's own construction (AES-256-GCM, keyed by the SHA-256
//!      of a machine secret), mirrored rather than asked for; a value that does not decrypt
//!      is skipped, not sent
//!   4. OpenCode: ~/.local/share/opencode/auth.json (or %APPDATA%/opencode/auth.json),
//!      keyed under a handful of provider names
//! Two Z.ai quirks are load-bearing (both documented upstream):
//!   - errors ride in under an HTTP 200 ({code:401,success:false} is an expired key on the
//!     wire), so the envelope is read before the payload is trusted;
//!   - windows are identified by length — (unit=3,number=5) is the rolling 5-hour session,
//!     (unit=6,number=1) the weekly allowance, TIME_LIMIT the monthly MCP budget — not by
//!     the type token, which differs between token plans and credit plans.

use crate::usage::{LimitWindow, UsageSnapshot};
use crate::AppState;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager};

const POLL_SECS: u64 = 300;
const BACKOFF_BASE_SECS: u64 = 60;
const BACKOFF_CAP_SECS: u64 = 900;

static REFRESH: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
static BACKOFF_UNTIL: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
static CONSECUTIVE_429: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

pub fn request_refresh() {
    // A manual "Refresh now" means the user wants a fresh attempt: clear the penalty
    // box (the poll loop's own cadence is untouched).
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

fn store_path() -> std::path::PathBuf {
    crate::config::config_path().with_file_name("glm-usage.json")
}

fn key_file() -> std::path::PathBuf {
    crate::config::config_path().with_file_name("glm.json")
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

struct Credential {
    token: String,
    /// Monitor console base: https://api.z.ai or https://open.bigmodel.cn
    base: String,
    source: String,
}

fn is_zai_host(host: &str) -> bool {
    host == "api.z.ai"
        || host.ends_with(".z.ai")
        || host == "open.bigmodel.cn"
        || host.ends_with(".bigmodel.cn")
}

fn console_for_host(host: &str) -> &'static str {
    if host.ends_with("bigmodel.cn") {
        "https://open.bigmodel.cn"
    } else {
        "https://api.z.ai"
    }
}

fn host_of(url: &str) -> Option<String> {
    let s = url.trim();
    if s.is_empty() {
        return None;
    }
    // No scheme: treat the string as a host itself (a bare "api.z.ai" or "api.z.ai:10443")
    let rest = s.split_once("://").map(|(_, r)| r).unwrap_or(s);
    rest.split('/')
        .next()
        .map(|h| h.split(':').next().unwrap_or(h).to_string())
        .filter(|h| !h.is_empty())
}

fn read_json(p: &std::path::Path) -> Option<serde_json::Value> {
    std::fs::read_to_string(p).ok().and_then(|t| serde_json::from_str(&t).ok())
}

fn non_empty(v: Option<&serde_json::Value>) -> Option<String> {
    v.and_then(|x| x.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// glm.json {"api_key":"...","base_url":"https://api.z.ai"} — the one key the user writes by hand
fn manual_key() -> Option<Credential> {
    let root = read_json(&key_file())?;
    let token = non_empty(root.get("api_key").or_else(|| root.get("apiKey")))?;
    let base = non_empty(root.get("base_url").or_else(|| root.get("baseURL")))
        .and_then(|u| host_of(&u))
        .filter(|h| is_zai_host(h))
        .map(|h| console_for_host(&h).to_string())
        .unwrap_or_else(|| "https://api.z.ai".into());
    Some(Credential { token, base, source: "glm.json".into() })
}

/// ~/.claude/settings.json → env.ANTHROPIC_AUTH_TOKEN plus env.ANTHROPIC_BASE_URL.
///
/// The documented way to point Claude Code at the plan, and the Mac's first source. The base URL
/// is what makes this a GLM key: `ANTHROPIC_AUTH_TOKEN` aimed at api.anthropic.com is somebody's
/// Anthropic key, and claiming it would read the wrong account and report it under GLM's name.
fn claude_code_key() -> Option<Credential> {
    let home = dirs::home_dir()?;
    let root = read_json(&home.join(".claude").join("settings.json"))?;
    let env = root.get("env")?;
    let token = non_empty(env.get("ANTHROPIC_AUTH_TOKEN"))
        .or_else(|| non_empty(env.get("ANTHROPIC_API_KEY")))?;
    let host = non_empty(env.get("ANTHROPIC_BASE_URL")).and_then(|u| host_of(&u))?;
    if !is_zai_host(&host) {
        return None;
    }
    Some(Credential { token, base: console_for_host(&host).to_string(), source: "Claude Code".into() })
}

/// ~/.zcode/v2/config.json → an enabled builtin:*-coding-plan provider with the plan key pasted in
fn zcode_plan_key() -> Option<Credential> {
    let home = dirs::home_dir()?;
    let root = read_json(&home.join(".zcode").join("v2").join("config.json"))?;
    let providers = root.get("provider")?.as_object()?;
    let mut ids: Vec<&String> = providers.keys().collect();
    ids.sort();
    for id in ids {
        if !id.contains("coding-plan") {
            continue;
        }
        let Some(provider) = providers[id].as_object() else { continue };
        if provider.get("enabled").and_then(|x| x.as_bool()) == Some(false) {
            continue;
        }
        let Some(options) = provider.get("options").and_then(|x| x.as_object()) else { continue };
        let Some(key) = non_empty(options.get("apiKey")) else { continue };
        let base = options
            .get("baseURL")
            .and_then(|x| x.as_str())
            .and_then(|u| host_of(u))
            .filter(|h| is_zai_host(h))
            .map(|h| console_for_host(&h).to_string())
            .unwrap_or_else(|| "https://api.z.ai".into());
        return Some(Credential { token: key, base, source: "ZCode".into() });
    }
    None
}

/// Every value in ZCode's credentials file is wrapped as
/// `enc:v1:<iv>.<tag>.<ciphertext>` with base64url parts: AES-256-GCM, the key the SHA-256
/// of a secret that is `$ZCODE_CREDENTIAL_SECRET` when set, else
/// `zcode-credential-fallback:<platform>:<home>:<user>`. The platform slot holds `win32` here —
/// that is what Node reports on Windows, not `windows`.
fn zcode_secret_from(env_override: Option<&str>, home: &str, user: &str) -> String {
    if let Some(s) = env_override.map(str::trim).filter(|s| !s.is_empty()) {
        return s.to_string();
    }
    format!("zcode-credential-fallback:win32:{home}:{user}")
}

fn zcode_secret() -> Option<String> {
    let home = dirs::home_dir()?;
    let env = std::env::var("ZCODE_CREDENTIAL_SECRET").ok();
    // Node's userInfo() can fail where USERNAME is merely absent; either way the slot reads unknown.
    let user = std::env::var("USERNAME").unwrap_or_else(|_| "unknown".into());
    Some(zcode_secret_from(env.as_deref(), &home.to_string_lossy(), &user))
}

/// The plaintext, or None when the value cannot be read — bad shape, wrong part lengths, a tag
/// that does not verify, or bytes that are not text. None means "try the next key", never "send
/// what we have": a wrong guess reads on the monitor as a signed-out plan.
///
/// A value without the marker passes through untouched, the way ZCode's own decrypt treats it:
/// older builds wrote the token in the clear, and those files are still out there.
fn zcode_decrypt(value: &str, secret: &str) -> Option<String> {
    use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
    use ring::{aead, digest};

    const PREFIX: &str = "enc:v1:";
    if !value.starts_with(PREFIX) {
        return Some(value.to_string());
    }
    let mut parts = value[PREFIX.len()..].split('.');
    let (iv, tag, ct) = (parts.next()?, parts.next()?, parts.next()?);
    if parts.next().is_some() {
        return None;
    }
    let iv = URL_SAFE_NO_PAD.decode(iv).ok()?;
    let tag = URL_SAFE_NO_PAD.decode(tag).ok()?;
    let ct = URL_SAFE_NO_PAD.decode(ct).ok()?;
    if iv.len() != 12 || tag.len() != 16 {
        return None;
    }
    let digest = digest::digest(&digest::SHA256, secret.as_bytes());
    let key = aead::LessSafeKey::new(aead::UnboundKey::new(&aead::AES_256_GCM, digest.as_ref()).ok()?);
    let nonce = aead::Nonce::try_assume_unique_for_key(&iv).ok()?;
    let mut buf = [ct, tag].concat();
    let plain = key.open_in_place(nonce, aead::Aad::empty(), &mut buf).ok()?;
    let text = std::str::from_utf8(plain).ok()?;
    if text.is_empty() {
        return None;
    }
    Some(text.to_string())
}

/// ZCode files the plan key per account as
/// `account-provider:coding-plan:<provider>:account:<id>:api-key` — the shape its own store
/// validates with `^account-provider:.+:api-key$`.
fn is_account_api_key(key: &str) -> bool {
    key.starts_with("account-provider:")
        && key.ends_with(":api-key")
        && key.len() > "account-provider:".len() + ":api-key".len()
}

/// ~/.zcode/v2/credentials.json → the plan key, or the sign-in token.
///
/// The account key comes first: it is the plan's own credential, where the sign-in token is a
/// login session that happens to be accepted too. With several accounts the keys sort, so the
/// answer is stable rather than a directory-listing lottery.
fn zcode_credentials() -> Option<Credential> {
    let home = dirs::home_dir()?;
    let root = read_json(&home.join(".zcode").join("v2").join("credentials.json"))?;
    let obj = root.as_object()?;
    let secret = zcode_secret()?;
    let read = |v: Option<&serde_json::Value>| -> Option<String> {
        let raw = non_empty(v)?;
        zcode_decrypt(&raw, &secret).filter(|s| !s.is_empty())
    };
    let mut ids: Vec<&String> = obj.keys().filter(|k| is_account_api_key(k)).collect();
    ids.sort();
    for id in ids {
        if let Some(token) = read(obj.get(id)) {
            let base = if id.to_lowercase().contains("bigmodel") {
                "https://open.bigmodel.cn"
            } else {
                "https://api.z.ai"
            };
            return Some(Credential { token, base: base.into(), source: "ZCode".into() });
        }
    }
    if let Some(token) = read(obj.get("oauth:zai:access_token")) {
        return Some(Credential { token, base: "https://api.z.ai".into(), source: "ZCode".into() });
    }
    if let Some(token) = read(obj.get("oauth:bigmodel:access_token")) {
        return Some(Credential { token, base: "https://open.bigmodel.cn".into(), source: "ZCode".into() });
    }
    None
}

/// OpenCode auth.json — the provider ids OpenCode's own sign-in writes, most specific first
fn opencode_key() -> Option<Credential> {
    let ids = ["zai-coding-plan", "zai", "z-ai", "z.ai", "glm", "zhipu", "zhipuai"];
    let home = dirs::home_dir()?;
    let mut paths = vec![home.join(".local").join("share").join("opencode").join("auth.json")];
    if let Some(appdata) = dirs::config_dir() {
        paths.push(appdata.join("opencode").join("auth.json"));
    }
    for p in paths {
        let Some(root) = read_json(&p).and_then(|v| v.as_object().map(|o| o.clone())) else { continue };
        for id in ids {
            let Some(entry) = root.get(id) else { continue };
            if let Some(token) = non_empty(Some(entry)) {
                let base = if id.starts_with("zhipu") { "https://open.bigmodel.cn" } else { "https://api.z.ai" };
                return Some(Credential { token, base: base.into(), source: "OpenCode".into() });
            }
            if let Some(obj) = entry.as_object() {
                for field in ["apiKey", "api_key", "token", "key", "accessToken", "auth_token"] {
                    if let Some(token) = non_empty(obj.get(field)) {
                        let base = if id.starts_with("zhipu") { "https://open.bigmodel.cn" } else { "https://api.z.ai" };
                        return Some(Credential { token, base: base.into(), source: "OpenCode".into() });
                    }
                }
            }
        }
    }
    None
}

fn load_credential() -> Option<Credential> {
    manual_key()
        .or_else(claude_code_key)
        .or_else(zcode_plan_key)
        .or_else(zcode_credentials)
        .or_else(opencode_key)
}

/// Is any GLM key source present on this machine? If not, no cell is shown.
pub fn present() -> bool {
    let mut any = key_file().is_file();
    if let Some(home) = dirs::home_dir() {
        any = any || claude_code_key().is_some();
        any = any || home.join(".zcode").join("v2").join("config.json").is_file();
        any = any || home.join(".zcode").join("v2").join("credentials.json").is_file();
        any = any || home.join(".local").join("share").join("opencode").join("auth.json").is_file();
    }
    if let Some(appdata) = dirs::config_dir() {
        any = any || appdata.join("opencode").join("auth.json").is_file();
    }
    any
}

// ---------------- The monitor endpoint ----------------

enum FetchErr {
    NeedsAuth,
    RateLimited(u64),
    Other(String),
}

fn fetch(cred: &Credential) -> Result<serde_json::Value, FetchErr> {
    let url = format!("{}/api/monitor/usage/quota/limit", cred.base);
    let resp = ureq::get(&url)
        // The monitor takes the key raw — no "Bearer" scheme, matching
        // `GLMProvider.swift`. Prefixing it is exactly what an auth failure
        // looks like from here.
        .set("Authorization", &cred.token)
        .set("Accept", "application/json")
        .set("User-Agent", concat!("codenotch/", env!("CARGO_PKG_VERSION"), " (Windows)"))
        .timeout(Duration::from_secs(15))
        .call();
    match resp {
        Ok(r) => r.into_json().map_err(|e| FetchErr::Other(format!("parse: {e}"))),
        Err(ureq::Error::Status(401 | 403, _)) => Err(FetchErr::NeedsAuth),
        Err(ureq::Error::Status(429, r)) => {
            let ra = r.header("retry-after").and_then(|s| s.trim().parse::<u64>().ok()).unwrap_or(0);
            Err(FetchErr::RateLimited(ra))
        }
        Err(ureq::Error::Status(code, _)) => Err(FetchErr::Other(format!("HTTP {code}"))),
        Err(e) => Err(FetchErr::Other(format!("{e}"))),
    }
}

/// The window identity comes from its length, not its type token (token plans answer
/// TOKENS_LIMIT, credit plans CREDIT_LIMIT, both encode the length the same way).
fn window_id(limit: &serde_json::Value) -> String {
    let ty = limit.get("type").and_then(|x| x.as_str()).unwrap_or("");
    if ty == "TIME_LIMIT" {
        return "mcp".into();
    }
    match (limit.get("unit").and_then(|x| x.as_i64()), limit.get("number").and_then(|x| x.as_i64())) {
        (Some(3), Some(5)) => "session".into(),
        (Some(6), Some(1)) => "weekly".into(),
        (Some(u), Some(n)) => format!("window-{u}x{n}"),
        _ => ty.to_lowercase().is_empty().then(|| "unknown".to_string()).unwrap_or_else(|| ty.to_lowercase()),
    }
}

fn label_for(id: &str, unit: Option<i64>, number: Option<i64>) -> String {
    match id {
        "session" => "Current session".into(),
        "weekly" => "Weekly".into(),
        "mcp" => "MCP (1 month)".into(),
        _ if id.starts_with("window-") => match unit {
            Some(3) => format!("Usage ({} h)", number.unwrap_or(0)),
            Some(6) => format!("Usage ({} wk)", number.unwrap_or(0)),
            _ => "Usage".into(),
        },
        _ => "Usage".into(),
    }
}

fn rank(id: &str) -> u8 {
    match id {
        "session" => 0,
        "weekly" => 1,
        "mcp" => 2,
        _ => 3,
    }
}

fn windows_from(v: &serde_json::Value) -> Vec<LimitWindow> {
    let Some(limits) = v.pointer("/data/limits").and_then(|x| x.as_array()) else {
        return Vec::new();
    };
    let mut out: Vec<LimitWindow> = Vec::new();
    for l in limits {
        // Without a percentage there is nothing to draw; a bare count from an unnamed
        // allowance would be a reading with an invented scale.
        let Some(pct) = l.get("percentage").and_then(|x| x.as_f64()) else { continue };
        let id = window_id(l);
        let unit = l.get("unit").and_then(|x| x.as_i64());
        let number = l.get("number").and_then(|x| x.as_i64());
        // Milliseconds since the epoch. The MCP row never carries a reset time, and — unlike
        // Claude's windows — a row is not dropped for lacking one: a percentage with no
        // countdown is still a reading.
        let resets_at = l.get("nextResetTime").and_then(|x| x.as_f64()).map(|ms| ms.max(0.0) as u64);
        out.push(LimitWindow {
            label: label_for(&id, unit, number),
            used: (pct / 100.0).clamp(0.0, 1.0),
            resets_at,
            id,
            ..Default::default()
        });
    }
    out.sort_by(|a, b| rank(&a.id).cmp(&rank(&b.id)).then_with(|| a.id.cmp(&b.id)));
    out
}

// ---------------- Putting it together ----------------

fn cap(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
        None => String::new(),
    }
}

fn read_once() -> UsageSnapshot {
    let mut snap = UsageSnapshot::default();
    let held_until = BACKOFF_UNTIL.load(std::sync::atomic::Ordering::Relaxed);
    let now = now_ms();
    if held_until > now {
        snap.backoff_until = held_until;
        snap.note = format!("Rate limited — retrying in {}s", (held_until - now) / 1000);
        return snap;
    }
    let Some(cred) = load_credential() else {
        snap.status = if present() { "needsAuth" } else { "absent" }.into();
        if present() {
            snap.note = "No usable Z.ai key found (ZCode, OpenCode or a glm.json key file)".into();
        }
        return snap;
    };
    match fetch(&cred) {
        Ok(v) => {
            // The envelope first: errors ride in under an HTTP 200 on this endpoint.
            let code = v.get("code").and_then(|x| x.as_i64()).unwrap_or(0);
            let success = v.get("success").and_then(|x| x.as_bool()).unwrap_or(false);
            if code == 401 || code == 403 || (!success && code != 200) {
                if code == 401 || code == 403 {
                    snap.status = "needsAuth".into();
                    snap.note = "Z.ai rejected the key — renew it in the tool that holds it".into();
                } else {
                    // The code, never the upstream prose. A provider's own error
                    // text can carry account details, and the log is the first
                    // thing people paste into an issue.
                    snap.status = "error".into();
                    snap.note = format!("Z.ai monitor refused the request ({code})");
                    crate::applog(&format!("glm: monitor answered code={code}"));
                }
                return snap;
            }
            let windows = windows_from(&v);
            if windows.is_empty() {
                snap.status = "stale".into();
                snap.note = "The plan reported no usage windows".into();
                crate::applog("glm: reply carried no usable limits, keeping the last reading");
                return snap;
            }
            let level = v.pointer("/data/level").and_then(|x| x.as_str()).map(cap).unwrap_or_default();
            snap.status = "ok".into();
            snap.windows = windows;
            snap.fetched_at = now_ms();
            snap.note = if level.is_empty() {
                format!("via {}", cred.source)
            } else {
                format!("{level} · via {}", cred.source)
            };
            CONSECUTIVE_429.store(0, std::sync::atomic::Ordering::Relaxed);
        }
        Err(FetchErr::NeedsAuth) => {
            snap.status = "needsAuth".into();
            snap.note = "Z.ai rejected the key — renew it in the tool that holds it".into();
        }
        Err(FetchErr::RateLimited(ra)) => {
            let n = CONSECUTIVE_429.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1;
            let exp = BACKOFF_BASE_SECS.saturating_mul(1u64 << (n - 1).min(4));
            let wait = exp.clamp(BACKOFF_BASE_SECS, BACKOFF_CAP_SECS).max(ra);
            let until = now_ms() + wait * 1000;
            BACKOFF_UNTIL.store(until, std::sync::atomic::Ordering::Relaxed);
            snap.backoff_until = until;
            snap.note = format!("Rate limited — retrying in {wait}s");
            crate::applog(&format!("glm: 429 (x{n}), retrying in {wait}s"));
        }
        Err(FetchErr::Other(e)) => {
            snap.status = "error".into();
            snap.note = format!("Live read failed ({e})");
            crate::applog(&format!("glm: live read failed ({e})"));
        }
    }
    snap
}

fn broadcast(app: &AppHandle, snap: UsageSnapshot) {
    let st = app.state::<AppState>();
    *st.glm.lock().unwrap() = snap.clone();
    persist(&snap);
    let _ = app.emit("glm", &snap);
}

pub fn start(app: AppHandle) {
    std::thread::spawn(move || {
        {
            let st = app.state::<AppState>();
            let snap = st.glm.lock().unwrap().clone();
            let _ = app.emit("glm", &snap);
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

/// For doctor: names the source and console, never the key
pub fn probe() -> String {
    match load_credential() {
        Some(c) => format!("GLM: key via {} → {} console", c.source, c.base),
        None if present() => "GLM: sources present but no usable key (nothing decrypted)".into(),
        None => "GLM: no key source (ZCode, OpenCode or glm.json)".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::{is_account_api_key, zcode_decrypt, zcode_secret_from};

    /// Sealed outside this codebase by ZCode's own construction, so a passing test proves the
    /// notch reads ZCode's files rather than its own writing. Same vectors the Mac tests use.
    const SECRET: &str = "codenotch-test-secret";
    const SEALED_OAUTH: &str =
        "enc:v1:AAECAwQFBgcICQoL.Ry_i-Pdd5-Q9anxf-qmhuw.F8EQAm0pm9G8_FWoIA";
    const SEALED_ACCOUNT: &str =
        "enc:v1:EBESExQVFhcYGRob.uwR9hDp2bhbEHb7rLSi-4A.t8lOm_4Hb-lm_4iiqmz2L5hPZw";

    #[test]
    fn decrypts_known_vectors() {
        assert_eq!(zcode_decrypt(SEALED_OAUTH, SECRET).as_deref(), Some("zai-token-xyz"));
        assert_eq!(
            zcode_decrypt(SEALED_ACCOUNT, SECRET).as_deref(),
            Some("plan-api-key.abc123")
        );
    }

    /// A wrong secret fails closed: None means "try the next key", never "send what we have".
    #[test]
    fn a_wrong_secret_fails_closed() {
        assert_eq!(zcode_decrypt(SEALED_OAUTH, "somebody-elses-secret"), None);
    }

    /// One flipped bit in the ciphertext or the tag breaks the seal, and the whole value with it.
    #[test]
    fn a_tampered_ciphertext_fails_closed() {
        // Flipped mid-part, where every bit survives decoding: the last character of a
        // two-character quantum carries padding bits, and a flip there can decode to the very
        // same bytes — no tamper at all.
        fn flip(value: &str, part: usize) -> String {
            let mut pieces: Vec<String> = value.split('.').map(str::to_string).collect();
            let mut chars: Vec<char> = pieces[part].chars().collect();
            chars[3] = if chars[3] == 'A' { 'B' } else { 'A' };
            pieces[part] = chars.into_iter().collect();
            pieces.join(".")
        }
        assert_eq!(
            zcode_decrypt(&flip(SEALED_OAUTH, 2), SECRET),
            None,
            "a tampered ciphertext must not read"
        );
        assert_eq!(
            zcode_decrypt(&flip(SEALED_OAUTH, 1), SECRET),
            None,
            "a tampered tag must not read"
        );
    }

    #[test]
    fn bad_shapes_are_none() {
        // No parts at all.
        assert_eq!(zcode_decrypt("enc:v1:uJqn18qD-not-a-real-key", SECRET), None);
        // An IV of one byte where twelve are required.
        assert_eq!(zcode_decrypt("enc:v1:QQ.uwR9hDp2bhbEHb7rLSi-4A.eA", SECRET), None);
        // Not base64url.
        assert_eq!(zcode_decrypt("enc:v1:***.uwR9hDp2bhbEHb7rLSi-4A.eA", SECRET), None);
        // Four parts where three are required.
        assert_eq!(zcode_decrypt("enc:v1:a.b.c.d", SECRET), None);
    }

    /// Older ZCode wrote the token in the clear; those values pass through, the way ZCode's own
    /// decrypt treats them.
    #[test]
    fn plaintext_passes_through() {
        assert_eq!(zcode_decrypt("zai-token-xyz", SECRET).as_deref(), Some("zai-token-xyz"));
    }

    #[test]
    fn the_secret_prefers_the_override_then_place_and_user() {
        assert_eq!(
            zcode_secret_from(Some("  env-secret\t"), r"C:\Users\test", "test"),
            "env-secret"
        );
        assert_eq!(
            zcode_secret_from(None, r"C:\Users\test", "test"),
            r"zcode-credential-fallback:win32:C:\Users\test:test"
        );
        // A blank override is no override: whitespace alone must not become a secret nobody
        // can reproduce.
        assert_eq!(
            zcode_secret_from(Some("   "), r"C:\Users\test", "test"),
            r"zcode-credential-fallback:win32:C:\Users\test:test"
        );
    }

    #[test]
    fn only_well_formed_account_keys_match() {
        assert!(is_account_api_key(
            "account-provider:coding-plan:account:zai-individual-coding-plan:account:u1:api-key"
        ));
        assert!(!is_account_api_key("account-provider::api-key"));
        assert!(!is_account_api_key("oauth:zai:access_token"));
    }
}
