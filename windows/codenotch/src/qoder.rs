//! Qoder usage adapter.
//!
//! Data path (same trade-off as the other cells: borrow the tool's own sign-in, read only):
//!   1. The official `@qoder-ai/qoder-agent-sdk` (npm) exposes `getUsageInfo()` on the daemon
//!      account plane — a read-only account query that runs no inference and spends no credits.
//!   2. The SDK is Node, this app is Rust, so the read goes through the bundled sidecar
//!      `qoder-usage.cjs`: start the daemon with `qodercliAuth()` (the local signed-in qodercli
//!      session), call `getUsageInfo()`, print one JSON object, stop the daemon, exit.
//!      The Qoder Desktop credential vault (DPAPI-protected `auth.v1.dat`) is never touched.
//!   3. `UsageInfo` (all fields optional, so every window is published only when its number is):
//!      `totalUsagePercentage`, `userQuota` / `addOnQuota` buckets {total, used, remaining,
//!      percentage, unit}, `orgResourcePackage`, `expiresAt` (plan renewal), `isQuotaExceeded`,
//!      `userType`. The `session` credits block is deliberately ignored: it meters the sidecar's
//!      own fresh daemon session (~0 by definition), not the user's IDE sessions.
//!
//! Placement: the sidecar needs `node` on PATH (or CODENOTCH_QODER_NODE) and the SDK in a
//! `node_modules` beside it — `%APPDATA%\codenotch\qoder-sdk\` (drop qoder-usage.cjs there and
//! `npm install @qoder-ai/qoder-agent-sdk`), next to the exe, or in the bundle resources.
//! Absent either → status absent/needsAuth with a note; the cell simply does not light up.

use crate::usage::{LimitWindow, UsageSnapshot};
use crate::AppState;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager};

const POLL_SECS: u64 = 300;
/// The sidecar starts a daemon (its handshake budget is 60 s, and a cold start measured ~18 s on
/// the machine this was built against), reads once, and stops it. A runaway node must never hang
/// the poll thread, so the whole run stays bounded.
const RUN_TIMEOUT: Duration = Duration::from_secs(120);

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

/// The Qoder data directory marks the install; its absence means no cell (never a zero).
fn qoder_home() -> Option<PathBuf> {
    let dir = dirs::home_dir()?.join(".qoder");
    dir.is_dir().then_some(dir)
}

/// Where the sidecar may live, in probe order. `node_modules` resolution follows the script's own
/// directory, so the SDK must be installed next to whichever copy runs.
fn sidecar_candidates() -> Vec<PathBuf> {
    let mut v = Vec::new();
    if let Ok(p) = std::env::var("CODENOTCH_QODER_SIDECAR") {
        if !p.is_empty() {
            v.push(PathBuf::from(p));
        }
    }
    if let Some(d) = crate::config::config_path().parent() {
        v.push(d.join("qoder-sdk").join("qoder-usage.cjs"));
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(d) = exe.parent() {
            v.push(d.join("qoder-usage.cjs"));
            v.push(d.join("resources").join("qoder-usage.cjs"));
        }
    }
    v
}

fn sidecar_path() -> Option<PathBuf> {
    sidecar_candidates().into_iter().find(|p| p.is_file())
}

fn node_program() -> String {
    std::env::var("CODENOTCH_QODER_NODE")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "node".to_string())
}

fn store_path() -> PathBuf {
    crate::config::config_path().with_file_name("qoder-usage.json")
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
    qoder_home().is_some()
}

/// Spawns the sidecar hidden, drains stdout, and enforces RUN_TIMEOUT. Returns the raw JSON text.
fn run_sidecar(script: &PathBuf) -> Result<String, String> {
    let dir = script.parent().map(|p| p.to_path_buf()).unwrap_or_default();
    let mut cmd = Command::new(node_program());
    cmd.arg(script)
        .current_dir(&dir)
        .stdout(Stdio::piped())
        // Never read: a pipe nobody drains fills, and the daemon's logging would then stall the
        // sidecar until the timeout killed it, every poll.
        .stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    let mut child = cmd.spawn().map_err(|e| format!("node: {e} (install Node.js or set CODENOTCH_QODER_NODE)"))?;
    let mut stdout = child.stdout.take().ok_or_else(|| "no stdout pipe".to_string())?;
    let reader = std::thread::spawn(move || {
        use std::io::Read;
        let mut buf = Vec::new();
        let _ = stdout.read_to_end(&mut buf);
        buf
    });
    let started = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(s)) => break Some(s),
            Ok(None) => {
                if started.elapsed() >= RUN_TIMEOUT {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err("sidecar timed out".into());
                }
                std::thread::sleep(Duration::from_millis(100));
            }
            Err(_) => break None,
        }
    };
    let buf = reader.join().map_err(|_| "stdout reader panicked".to_string())?;
    let text = String::from_utf8_lossy(&buf).trim().to_string();
    match status {
        Some(s) if s.success() => Ok(text),
        // The sidecar prints its own JSON error envelope on exit 1; parse it like a success
        Some(_) if text.starts_with('{') => Ok(text),
        Some(s) => Err(format!("sidecar exited with {}", s.code().map(|c| c.to_string()).unwrap_or_else(|| "a signal".into()))),
        None => Err("sidecar process could not be waited on".into()),
    }
}

// ---------------- Parsing ----------------

/// A percentage may arrive as a fraction (0–1) or as points (0–100); accept both, clamp to a
/// fraction. Anything unparseable publishes no window rather than an invented one.
fn fraction(pct: Option<&serde_json::Value>, used: Option<&serde_json::Value>, total: Option<&serde_json::Value>) -> Option<f64> {
    // Used over total first: it cannot be misread. A bare percentage is either points or a
    // fraction, and at the bottom of the range the two collide — 1 % read as a fraction is a
    // full ring — so it is only the answer when the counts are missing.
    let used_total = used.and_then(|u| u.as_f64()).zip(total.and_then(|t| t.as_f64()));
    if let Some((used, total)) = used_total.filter(|(_, total)| *total > 0.0) {
        return Some((used / total).clamp(0.0, 1.0));
    }
    let f = pct?.as_f64()?;
    let f = if f > 1.5 { f / 100.0 } else { f };
    Some(f.clamp(0.0, 1.0))
}

fn num(v: &serde_json::Value, key: &str) -> Option<f64> {
    v.get(key).and_then(|x| x.as_f64())
}

/// Does this bucket carry anything to meter? A signed-in standard account reports
/// `userQuota {total:0, used:0, remaining:0, percentage:0}` while its real consumption lives in
/// the add-on bucket, and turning that empty object into a 0 % ring would read as "nothing used".
fn has_signal(q: &serde_json::Value) -> bool {
    num(q, "total").unwrap_or(0.0) > 0.0
        || num(q, "used").unwrap_or(0.0) > 0.0
        || num(q, "percentage").unwrap_or(0.0) > 0.0
}

/// A bucket that exists and meters something.
fn bucket<'a>(v: &'a serde_json::Value, key: &str) -> Option<&'a serde_json::Value> {
    v.get(key).filter(|x| x.is_object()).filter(|q| has_signal(q))
}

/// `expiresAt` is a millisecond timestamp, and a plan that never expires answers with the
/// far-future sentinel (253402214400000 ≈ year 9999). "Renews in 8000 years" is worse than no
/// date at all, so anything past 2100 is read as no renewal.
const NO_RENEWAL_AFTER_MS: u64 = 4_102_444_800_000;

fn expiry(v: &serde_json::Value) -> Option<u64> {
    v.get("expiresAt")
        .and_then(|x| x.as_f64())
        .map(|t| t.max(0.0) as u64)
        .filter(|t| *t < NO_RENEWAL_AFTER_MS)
}

/// `personal_professional` reads better as a name than as a code.
fn humanise(s: &str) -> String {
    let spaced = s.replace('_', " ");
    let mut chars = spaced.chars();
    match chars.next() {
        Some(c) => c.to_uppercase().collect::<String>() + chars.as_str(),
        None => spaced,
    }
}

/// UsageInfo JSON → (windows, note). Windows come only from buckets that carry a real number;
/// an empty list with a note is honest ("the plan publishes no quota bucket to meter").
pub fn windows_from(v: &serde_json::Value) -> (Vec<LimitWindow>, String) {
    let mut out = Vec::new();
    let resets_at = expiry(v);
    let user_type = v.get("userType").and_then(|x| x.as_str()).unwrap_or("Qoder");

    match bucket(v, "userQuota") {
        Some(q) => {
            if let Some(used) = fraction(q.get("percentage"), q.get("used"), q.get("total")) {
                out.push(LimitWindow { id: "quota".into(), label: "Plan usage".into(), used, resets_at, ..Default::default() });
            }
        }
        // No plan bucket to meter: the account's own total figure is what Qoder itself shows.
        None => {
            if let Some(p) = num(v, "totalUsagePercentage") {
                let p = (if p > 1.5 { p / 100.0 } else { p }).clamp(0.0, 1.0);
                out.push(LimitWindow { id: "quota".into(), label: "Total usage".into(), used: p, resets_at, ..Default::default() });
            }
        }
    }

    if let Some(a) = bucket(v, "addOnQuota") {
        if let Some(used) = fraction(a.get("percentage"), a.get("used"), a.get("total")) {
            out.push(LimitWindow { id: "addon".into(), label: "Add-on credits".into(), used, resets_at: None, ..Default::default() });
        }
    }

    if let Some(o) = v.get("orgResourcePackage").filter(|x| x.is_object()) {
        let available = o.get("available").and_then(|x| x.as_bool()).unwrap_or(true);
        if available {
            if let Some(used) = fraction(o.get("percentage"), o.get("used"), o.get("cap")) {
                out.push(LimitWindow { id: "org".into(), label: "Organization package".into(), used, resets_at: None, ..Default::default() });
            }
        }
    }

    // The card headline shows the ring; the note carries what the ring cannot: credits left.
    // Whichever bucket actually meters the account is the one worth quoting.
    let mut bits: Vec<String> = vec![humanise(user_type)];
    let credits = ["userQuota", "addOnQuota", "orgResourcePackage"]
        .iter()
        .find_map(|k| bucket(v, k));
    if let Some(q) = credits {
        if let Some(rem) = num(q, "remaining") {
            let unit = q.get("unit").and_then(|x| x.as_str()).unwrap_or("credits");
            bits.push(format!("{rem:.0} {unit} left"));
        }
    }
    if v.get("isQuotaExceeded").and_then(|x| x.as_bool()) == Some(true) {
        bits.push("quota exceeded".into());
    }
    (out, bits.join(" · "))
}

enum Run {
    Ok(serde_json::Value),
    NeedsAuth(String),
    Other(String),
}

fn read_once_raw() -> Run {
    let Some(script) = sidecar_path() else {
        return Run::NeedsAuth(
            "Install the sidecar: copy qoder-usage.cjs to %APPDATA%\\codenotch\\qoder-sdk and run npm install @qoder-ai/qoder-agent-sdk there".into(),
        );
    };
    match run_sidecar(&script) {
        Err(e) => Run::Other(e),
        Ok(text) => match serde_json::from_str::<serde_json::Value>(&text) {
            Err(e) => Run::Other(format!("sidecar JSON: {e}")),
            Ok(v) => {
                if let Some(err) = v.get("error").and_then(|x| x.as_str()) {
                    let msg = v.get("message").and_then(|x| x.as_str()).unwrap_or(err).to_string();
                    return match err {
                        "needsAuth" | "sdk_missing" => Run::NeedsAuth(match err {
                            "sdk_missing" => "The SDK is not installed next to the sidecar — run npm install @qoder-ai/qoder-agent-sdk in the qoder-sdk folder".into(),
                            _ => format!("qodercli is not signed in — run the qodercli login ({msg})"),
                        }),
                        other => Run::Other(format!("{other}: {msg}")),
                    };
                }
                let usage = v.get("usage");
                match usage {
                    None | Some(serde_json::Value::Null) => Run::NeedsAuth("getUsageInfo returned nothing — sign in to qodercli".into()),
                    Some(u) => Run::Ok(u.clone()),
                }
            }
        },
    }
}

fn read_once(prev: &UsageSnapshot) -> UsageSnapshot {
    let mut snap = prev.clone();
    if !present() {
        snap.status = "absent".into();
        snap.windows.clear();
        snap.note = String::new();
        return snap;
    }
    match read_once_raw() {
        Run::Ok(u) => {
            let (windows, note) = windows_from(&u);
            snap.fetched_at = now_ms();
            if windows.is_empty() {
                snap.status = "none".into();
                snap.windows.clear();
                snap.note = format!("{note} — the plan publishes no quota bucket to meter");
            } else {
                snap.status = "ok".into();
                snap.windows = windows;
                snap.note = format!("{note} · via Qoder");
            }
        }
        Run::NeedsAuth(msg) => {
            snap.status = "needsAuth".into();
            snap.note = msg;
        }
        Run::Other(msg) => {
            snap.status = if snap.windows.is_empty() { "error" } else { "stale" }.into();
            snap.note = msg;
        }
    }
    snap
}

/// For doctor: contains no secret values
pub fn probe() -> String {
    let home = match qoder_home() {
        Some(d) => d.display().to_string(),
        None => return "Qoder: ~/.qoder not found (not installed)".into(),
    };
    let side = match sidecar_path() {
        Some(p) => format!("sidecar {}", p.display()),
        None => "sidecar not installed (see qoder-sdk in %APPDATA%\\codenotch)".into(),
    };
    let mut node_cmd = Command::new(node_program());
    node_cmd.arg("--version").stdout(Stdio::null()).stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        node_cmd.creation_flags(0x0800_0000);
    }
    let node = node_cmd
        .spawn()
        .map(|_| "node ok")
        .unwrap_or("node not found");
    format!("Qoder: home {home}; {side}; {node}")
}

fn broadcast(app: &AppHandle, snap: UsageSnapshot) {
    let st = app.state::<AppState>();
    *st.qoder.lock().unwrap() = snap.clone();
    persist(&snap);
    let _ = app.emit("qoder", &snap);
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
            let snap = st.qoder.lock().unwrap().clone();
            let _ = app.emit("qoder", &snap);
        }
        if !present() {
            broadcast(&app, UsageSnapshot { status: "absent".into(), ..Default::default() });
            loop {
                sleep_interruptible(600); // Qoder is not installed: look again every 10 minutes
                if present() {
                    break;
                }
            }
        }
        loop {
            let prev = {
                let st = app.state::<AppState>();
                let s = st.qoder.lock().unwrap().clone();
                s
            };
            let snap = read_once(&prev);
            if snap.status == "error" || snap.status == "stale" {
                crate::applog(&format!("qoder: {}", snap.note));
            }
            broadcast(&app, snap);
            sleep_interruptible(POLL_SECS);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn j(t: &str) -> serde_json::Value {
        serde_json::from_str(t).unwrap()
    }

    #[test]
    fn quota_bucket_percent_points_and_fraction() {
        let (w, note) = windows_from(&j(r#"{"userType":"Pro","expiresAt":1760000000000,"userQuota":{"used":40,"total":100,"remaining":60,"percentage":40,"unit":"credits"}}"#));
        assert_eq!(w.len(), 1);
        assert_eq!(w[0].id, "quota");
        assert!((w[0].used - 0.4).abs() < 1e-9, "percent points normalize");
        assert_eq!(w[0].resets_at, Some(1760000000000));
        assert!(note.contains("60 credits left"), "{note}");

        let (w, _) = windows_from(&j(r#"{"userQuota":{"percentage":0.25}}"#));
        assert_eq!(w.len(), 1);
        assert!((w[0].used - 0.25).abs() < 1e-9, "fraction passes through");
    }

    #[test]
    fn one_percent_with_counts_is_not_a_full_ring() {
        let (w, _) = windows_from(&j(r#"{"userQuota":{"used":1,"total":100,"percentage":1}}"#));
        assert!((w[0].used - 0.01).abs() < 1e-9, "{}", w[0].used);
    }

    #[test]
    fn used_over_total_without_percentage() {
        let (w, _) = windows_from(&j(r#"{"userQuota":{"used":3,"total":12}}"#));
        assert!((w[0].used - 0.25).abs() < 1e-9);
    }

    #[test]
    fn total_usage_percentage_alone_makes_the_headline() {
        let (w, note) = windows_from(&j(r#"{"userType":"Free","totalUsagePercentage":72.5}"#));
        assert_eq!(w.len(), 1);
        assert!((w[0].used - 0.725).abs() < 1e-9);
        assert!(note.contains("Free"), "{note}");
    }

    #[test]
    fn missing_numbers_publish_nothing() {
        // An empty object is "no quota to meter", not 0 %
        let (w, _) = windows_from(&j("{}"));
        assert!(w.is_empty());
        let (w, _) = windows_from(&j(r#"{"userQuota":{"total":0,"used":0}}"#));
        assert!(w.is_empty(), "zero total is a gap, not 0 %");
    }

    #[test]
    fn addon_and_org_packages_appear_when_metered() {
        let (w, _) = windows_from(&j(r#"{
            "userQuota":{"percentage":50},
            "addOnQuota":{"used":20,"total":100,"remaining":80,"unit":"credits"},
            "orgResourcePackage":{"used":10,"cap":40,"available":true}
        }"#));
        let ids: Vec<&str> = w.iter().map(|x| x.id.as_str()).collect();
        assert_eq!(ids, ["quota", "addon", "org"]);
        assert!((w[1].used - 0.2).abs() < 1e-9);
        assert!((w[2].used - 0.25).abs() < 1e-9);
    }

    #[test]
    fn unavailable_org_package_is_skipped() {
        let (w, _) = windows_from(&j(r#"{"orgResourcePackage":{"used":10,"cap":40,"percentage":25,"available":false}}"#));
        assert!(w.is_empty());
    }

    #[test]
    fn exceeded_flag_reaches_the_note() {
        let (_, note) = windows_from(&j(r#"{"totalUsagePercentage":100,"isQuotaExceeded":true,"userType":"Pro"}"#));
        assert!(note.contains("quota exceeded"), "{note}");
    }

    // The shape a signed-in standard account actually returns: an all-zero plan bucket, the real
    // figure in totalUsagePercentage, and the consumption in the add-on pool.
    #[test]
    fn an_empty_plan_bucket_yields_to_the_account_total() {
        let (w, note) = windows_from(&j(r#"{
            "userType":"personal_standard","totalUsagePercentage":96,"isQuotaExceeded":false,
            "expiresAt":253402214400000,
            "userQuota":{"total":0,"used":0,"remaining":0,"percentage":0,"unit":"credits"},
            "addOnQuota":{"total":2100,"used":2000,"remaining":100,"percentage":96,"unit":"credits"}
        }"#));
        let ids: Vec<&str> = w.iter().map(|x| x.id.as_str()).collect();
        assert_eq!(ids, ["quota", "addon"], "no 0 % ring from the empty plan bucket");
        assert_eq!(w[0].label, "Total usage");
        assert!((w[0].used - 0.96).abs() < 1e-9);
        assert!(note.contains("100 credits left"), "{note}");
        assert!(note.contains("Personal standard"), "{note}");
    }

    #[test]
    fn the_far_future_expiry_sentinel_is_not_a_renewal_date() {
        let (w, _) = windows_from(&j(r#"{"userQuota":{"used":10,"total":100},"expiresAt":253402214400000}"#));
        assert_eq!(w[0].resets_at, None, "year 9999 means the plan does not renew");
        let (w, _) = windows_from(&j(r#"{"userQuota":{"used":10,"total":100},"expiresAt":1790000000000}"#));
        assert_eq!(w[0].resets_at, Some(1790000000000));
    }
}
