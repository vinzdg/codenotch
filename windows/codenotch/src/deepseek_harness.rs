//! DeepSeek Harness usage adapter.
//!
//! The Harness (`~/.dsh`) records a `usage` block on every assistant step of every
//! session transcript. Each transcript is `<session>/session.v4.jsonl.zstd`, one JSON
//! object per line, zstd-compressed:
//!
//! ```json
//! {"time":1792265428721,"data":{"usage":{"inputTokens":265134,"outputTokens":169,
//!   "cacheReadTokens":0,"cacheWriteTokens":0,"totalTokens":265303}}}
//! ```
//!
//! `inputTokens` counts prompt tokens that missed the cache and `cacheReadTokens` the ones
//! that hit it (they are disjoint: the observed cache-read total is two orders of magnitude
//! larger than the input total), so the three billable buckets are exactly those fields.
//!
//! The Harness publishes no limit, so the ring is a **derived** number: today's cost against
//! `DAILY_BUDGET_USD`, priced with DeepSeek's published flash rates (peak/off-peak). The card
//! says so with the `~` prefix and the note spells out the estimate.
//!
//! Fidelity: derived. Nothing here is a vendor-published percentage.

use crate::usage::{LimitWindow, UsageSnapshot};
use crate::AppState;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager};

const POLL_SECS: u64 = 60;
const MIN_TOPUP_USD: f64 = 2.0;
const BALANCE_ENDPOINT: &str = "https://api.deepseek.com/user/balance";

static REFRESH: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
static SESSION_CACHE: Mutex<Option<HashMap<PathBuf, (u64, Totals)>>> = Mutex::new(None);

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// `deepseek-flash` rates per 1M tokens: (cache hit, cache miss, output).
/// Peak is 01:00â€“04:00 and 06:00â€“10:00 UTC, Mondayâ€“Friday; off-peak is half.
fn rates(peak: bool) -> (f64, f64, f64) {
    if peak {
        (0.006, 0.30, 1.20)
    } else {
        (0.003, 0.15, 0.60)
    }
}

fn is_peak(ts_ms: u64) -> bool {
    use chrono::{Datelike, Timelike, Utc};
    let Some(dt) = chrono::DateTime::<Utc>::from_timestamp_millis(ts_ms as i64) else {
        return false;
    };
    if !matches!(dt.weekday(), chrono::Weekday::Mon
        | chrono::Weekday::Tue
        | chrono::Weekday::Wed
        | chrono::Weekday::Thu
        | chrono::Weekday::Fri)
    {
        return false;
    }
    let hour = dt.hour();
    (1..4).contains(&hour) || (6..10).contains(&hour)
}

/// Cost of one usage record, in USD.
pub fn cost_usd(ts_ms: u64, input: u64, cache_read: u64, output: u64) -> f64 {
    let (hit, miss, out) = rates(is_peak(ts_ms));
    (cache_read as f64 * hit + input as f64 * miss + output as f64 * out) / 1_000_000.0
}

#[derive(Debug, Default, Clone)]
pub struct Totals {
    pub tokens: u64,
    pub cost: f64,
    pub sessions: usize,
}

#[derive(Debug, Clone)]
pub struct BalanceReading {
    pub currency: String,
    pub raw_balance: f64,
    pub is_available: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct BalanceState {
    pub funded: f64,
    pub last_balance: f64,
    pub baseline_spent: f64,
    pub remaining: f64,
    pub spent: f64,
    pub tokens: u64,
    pub has_api_reading: bool,
    pub is_available: bool,
}

/// The Harness writes one zstd frame per line, concatenated. `StreamingDecoder`
/// stops at the first frame's end, so frames are walked using the decoder's own
/// `bytes_read_from_source`, which is authoritative about the boundary.
fn decode_frames(bytes: &[u8]) -> Option<Vec<u8>> {
    use std::io::{Cursor, Read as _};
    let mut cursor = Cursor::new(bytes);
    let mut decoder = ruzstd::FrameDecoder::new();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len() * 4 + 4096);
    let total = bytes.len() as u64;
    let mut frames = 0u32;

    while cursor.position() < total {
        frames += 1;
        if frames > 200_000 || decoder.reset(&mut cursor).is_err() {
            break;
        }
        let mut idle = 0u32;
        while !decoder.is_finished() {
            let before = cursor.position();
            if decoder
                .decode_blocks(&mut cursor, ruzstd::BlockDecodingStrategy::UptoBytes(256 * 1024))
                .is_err()
            {
                break;
            }
            let available = decoder.can_collect();
            if available > 0 {
                let mut buf = vec![0u8; available];
                if let Ok(n) = decoder.read(&mut buf) {
                    out.extend_from_slice(&buf[..n]);
                }
            }
            if cursor.position() == before && decoder.can_collect() == 0 {
                idle += 1;
                if idle > 4 {
                    break;
                }
            } else {
                idle = 0;
            }
        }
        let available = decoder.can_collect();
        if available > 0 {
            let mut buf = vec![0u8; available];
            if let Ok(n) = decoder.read(&mut buf) {
                out.extend_from_slice(&buf[..n]);
            }
        }
    }

    if out.is_empty() {
        None
    } else {
        Some(out)
    }
}
/// Decode one transcript and fold its usage into `totals` when the record falls in
/// `[start_ms, end_ms)`.
fn fold_session(path: &Path, start_ms: u64, end_ms: u64, totals: &mut Totals) -> bool {
    let Ok(bytes) = std::fs::read(path) else { return false };
    let Some(text) = decode_frames(&bytes) else { return false };

    let mut saw_any = false;
    for line in text.split(|b| *b == b'\n') {
        if line.len() < 2 || !line.windows(7).any(|w| w == b"\"usage\"") {
            continue;
        }
        let Ok(value) = serde_json::from_slice::<serde_json::Value>(line) else {
            continue;
        };
        let Some(usage) = value.get("data").and_then(|d| d.get("usage")) else {
            continue;
        };
        let ts = value.get("time").and_then(|t| t.as_u64()).unwrap_or(0);
        if ts < start_ms || ts >= end_ms {
            continue;
        }
        let get = |k: &str| usage.get(k).and_then(|v| v.as_u64()).unwrap_or(0);
        let input = get("inputTokens");
        let cache_read = get("cacheReadTokens");
        let output = get("outputTokens");
        totals.tokens += input + cache_read + get("cacheWriteTokens") + output;
        totals.cost += cost_usd(ts, input, cache_read, output);
        saw_any = true;
    }
    saw_any
}

/// Every `session.v4.jsonl.zstd` under the Harness data directory.
fn transcripts() -> Vec<PathBuf> {
    fn walk(dir: &Path, out: &mut Vec<PathBuf>, depth: usize) {
        if depth > 6 {
            return;
        }
        let Ok(entries) = std::fs::read_dir(dir) else { return };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                walk(&path, out, depth + 1);
            } else if path.file_name().and_then(|n| n.to_str()) == Some("session.v4.jsonl.zstd") {
                out.push(path);
            }
        }
    }
    let mut out = Vec::new();
    if let Some(home) = dirs::home_dir() {
        walk(&home.join(".dsh").join("sessions"), &mut out, 0);
    }
    out
}

fn modified_ms(path: &Path) -> Option<u64> {
    let modified = std::fs::metadata(path).ok()?.modified().ok()?;
    Some(modified.duration_since(UNIX_EPOCH).ok()?.as_millis() as u64)
}

/// Start of the local day containing `now_ms`, and the next midnight after it.
#[cfg(test)]
fn day_bounds(now_ms: u64) -> (u64, u64) {
    use chrono::{Local, TimeZone};
    let now = Local.timestamp_millis_opt(now_ms as i64).single().unwrap_or_else(Local::now);
    let start = now.date_naive().and_hms_opt(0, 0, 0).unwrap();
    let start = Local.from_local_datetime(&start).earliest().map(|d| d.timestamp_millis()).unwrap_or(0);
    (start as u64, start as u64 + 86_400_000)
}

pub fn totals_all() -> Option<Totals> {
    let files = transcripts();
    if files.is_empty() && read_api_key().is_none() {
        return None;
    }
    let mut guard = SESSION_CACHE.lock().unwrap_or_else(|e| e.into_inner());
    let cache = guard.get_or_insert_with(HashMap::new);
    let mut totals = Totals::default();
    for path in &files {
        let mtime = modified_ms(path).unwrap_or(0);
        if let Some((cached_mtime, cached_totals)) = cache.get(path) {
            if *cached_mtime == mtime && mtime > 0 {
                totals.tokens += cached_totals.tokens;
                totals.cost += cached_totals.cost;
                totals.sessions += cached_totals.sessions;
                continue;
            }
        }
        let mut file_totals = Totals::default();
        if fold_session(path, 0, u64::MAX, &mut file_totals) {
            file_totals.sessions = 1;
        }
        totals.tokens += file_totals.tokens;
        totals.cost += file_totals.cost;
        totals.sessions += file_totals.sessions;
        if mtime > 0 {
            cache.insert(path.clone(), (mtime, file_totals));
        }
    }
    Some(totals)
}

fn credentials_path() -> Option<PathBuf> {
    dirs::home_dir().map(|h| h.join(".dsh").join(".credentials.yaml"))
}

pub fn parse_api_key_from_yaml(text: &str) -> Option<String> {
    for line in text.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("DEEPSEEK_API_KEY:") {
            let key = rest.trim().trim_matches('"').trim_matches('\'').trim();
            if !key.is_empty() {
                return Some(key.to_string());
            }
        }
    }
    None
}

fn read_api_key() -> Option<String> {
    if let Some(path) = credentials_path() {
        if let Ok(text) = std::fs::read_to_string(path) {
            if let Some(key) = parse_api_key_from_yaml(&text) {
                return Some(key);
            }
        }
    }
    std::env::var("DEEPSEEK_API_KEY")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

pub fn parse_balance_json(v: &serde_json::Value) -> Option<BalanceReading> {
    let is_available = v.get("is_available").and_then(|x| x.as_bool()).unwrap_or(false);
    let infos = v.get("balance_infos")?.as_array()?;
    let mut candidates: Vec<BalanceReading> = Vec::new();
    for item in infos {
        let currency = item.get("currency").and_then(|x| x.as_str()).unwrap_or("USD").to_string();
        let raw_balance = item
            .get("total_balance")
            .and_then(|x| x.as_str().and_then(|s| s.parse::<f64>().ok()).or_else(|| x.as_f64()))
            .unwrap_or(0.0);
        candidates.push(BalanceReading {
            currency,
            raw_balance,
            is_available,
        });
    }
    candidates
        .iter()
        .find(|c| c.raw_balance > 0.0)
        .or_else(|| candidates.iter().find(|c| c.currency == "USD"))
        .or_else(|| candidates.first())
        .cloned()
}

fn fetch_balance() -> Option<BalanceReading> {
    let key = read_api_key()?;
    let agent = ureq::AgentBuilder::new().timeout(Duration::from_secs(15)).build();
    let resp = agent
        .get(BALANCE_ENDPOINT)
        .set("Authorization", &format!("Bearer {key}"))
        .set("Accept", "application/json")
        .call()
        .ok()?;
    let json = resp.into_json::<serde_json::Value>().ok()?;
    parse_balance_json(&json)
}

fn store_path() -> std::path::PathBuf {
    crate::config::config_path().with_file_name("deepseek-usage.json")
}

fn balance_state_path() -> std::path::PathBuf {
    crate::config::config_path().with_file_name("deepseek-balance.json")
}

fn load_balance_state() -> BalanceState {
    std::fs::read_to_string(balance_state_path())
        .ok()
        .and_then(|t| serde_json::from_str::<BalanceState>(&t).ok())
        .unwrap_or_default()
}

fn save_balance_state(state: &BalanceState) {
    if let Ok(t) = serde_json::to_string_pretty(state) {
        let _ = std::fs::write(balance_state_path(), t);
    }
}

pub fn compute_balance_state(
    prev: &BalanceState,
    local_spent: f64,
    tokens: u64,
    api: Option<BalanceReading>,
) -> BalanceState {
    if let Some(b) = api {
        let remaining = if b.is_available && b.raw_balance > 0.0 {
            b.raw_balance
        } else {
            0.0
        };
        let (funded, baseline_spent) = if !prev.has_api_reading {
            let f = (local_spent + remaining).max(prev.funded).max(MIN_TOPUP_USD);
            (f, 0.0)
        } else if remaining > prev.last_balance + 0.01 {
            if prev.last_balance <= 0.001 {
                (remaining.max(MIN_TOPUP_USD), local_spent)
            } else {
                let added = remaining - prev.last_balance;
                ((prev.funded + added).max(remaining).max(MIN_TOPUP_USD), prev.baseline_spent)
            }
        } else {
            let cycle_spent = (local_spent - prev.baseline_spent).max(0.0);
            let f = prev.funded.max(cycle_spent + remaining).max(MIN_TOPUP_USD);
            (f, prev.baseline_spent)
        };
        let depleted = !b.is_available || b.raw_balance <= 0.0;
        let final_remaining = if depleted { 0.0 } else { remaining };
        let spent = if depleted {
            funded
        } else {
            (funded - final_remaining).max(0.0)
        };
        BalanceState {
            funded,
            last_balance: final_remaining,
            baseline_spent,
            remaining: final_remaining,
            spent,
            tokens,
            has_api_reading: true,
            is_available: !depleted,
        }
    } else if prev.has_api_reading {
        let cycle_spent = (local_spent - prev.baseline_spent).max(0.0);
        let funded = prev.funded.max(cycle_spent + prev.remaining).max(MIN_TOPUP_USD);
        let remaining = if prev.is_available { prev.remaining } else { 0.0 };
        let spent = if !prev.is_available || remaining <= 0.0 {
            funded
        } else {
            (funded - remaining).max(0.0)
        };
        BalanceState {
            funded,
            last_balance: prev.last_balance,
            baseline_spent: prev.baseline_spent,
            remaining,
            spent,
            tokens,
            has_api_reading: true,
            is_available: prev.is_available,
        }
    } else {
        let funded = local_spent.max(prev.funded).max(MIN_TOPUP_USD);
        let spent = local_spent.min(funded);
        let remaining = (funded - spent).max(0.0);
        BalanceState {
            funded,
            last_balance: remaining,
            baseline_spent: 0.0,
            remaining,
            spent,
            tokens,
            has_api_reading: false,
            is_available: remaining > 0.0,
        }
    }
}

pub fn format_tokens(tokens: u64) -> String {
    if tokens >= 1_000_000 {
        format!("{:.1}M tokens", tokens as f64 / 1_000_000.0)
    } else {
        format!("{}k tokens", tokens / 1000)
    }
}

pub fn format_note(style: &str, spent: f64, funded: f64, remaining: f64, tokens: u64) -> String {
    let tok = format_tokens(tokens);
    match style {
        "spent" => format!("${:.2} of ${:.2} used \u{b7} ${:.2} left \u{b7} {}", spent, funded, remaining, tok),
        "compact" => format!("${:.2} / ${:.2} USD (${:.2} left)", spent, funded, remaining),
        _ => format!("${:.2} remaining of ${:.2} \u{b7} {}", remaining, funded, tok),
    }
}

pub fn load_persisted() -> UsageSnapshot {
    std::fs::read_to_string(store_path())
        .ok()
        .and_then(|t| serde_json::from_str::<UsageSnapshot>(&t).ok())
        .map(|mut s| {
            let style = crate::config::load().deepseek_display;
            let state = load_balance_state();
            if state.funded > 0.0 {
                let used = if !state.is_available || state.remaining <= 0.0 {
                    1.0
                } else {
                    (state.spent / state.funded).clamp(0.0, 1.0)
                };
                s.windows = vec![LimitWindow {
                    id: "credits".into(),
                    label: "Credits".into(),
                    used,
                    resets_at: None,
                    count: None,
                    derived: !state.has_api_reading,
                    group: None,
                    ..Default::default()
                }];
                s.note = format_note(&style, state.spent, state.funded, state.remaining, state.tokens);
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

pub fn request_refresh() {
    REFRESH.store(true, std::sync::atomic::Ordering::Relaxed);
}

pub fn apply_display(app: &AppHandle, style: &str) {
    let state = load_balance_state();
    if state.funded <= 0.0 {
        request_refresh();
        return;
    }
    let next_note = format_note(style, state.spent, state.funded, state.remaining, state.tokens);
    let snap = {
        let st = app.state::<AppState>();
        let mut guard = st.deepseek.lock().unwrap();
        guard.note = next_note;
        guard.clone()
    };
    persist(&snap);
    let _ = app.emit("deepseek", &snap);
}

pub fn snapshot_with_style(now_ms: u64, style: &str) -> UsageSnapshot {
    let Some(totals) = totals_all() else {
        return UsageSnapshot { status: "absent".into(), ..Default::default() };
    };
    let prev = load_balance_state();
    let api = fetch_balance();
    let state = compute_balance_state(&prev, totals.cost, totals.tokens, api);
    save_balance_state(&state);

    let used = if !state.is_available || state.remaining <= 0.0 {
        1.0
    } else if state.funded > 0.0 {
        (state.spent / state.funded).clamp(0.0, 1.0)
    } else {
        0.0
    };

    UsageSnapshot {
        status: "ok".into(),
        windows: vec![LimitWindow {
            id: "credits".into(),
            label: "Credits".into(),
            used,
            resets_at: None,
            count: None,
            derived: !state.has_api_reading,
            group: None,
            ..Default::default()
        }],
        fetched_at: now_ms,
        note: format_note(style, state.spent, state.funded, state.remaining, state.tokens),
        backoff_until: 0,
        ..Default::default()
    }
}

#[cfg(test)]
pub fn snapshot_at(now_ms: u64) -> UsageSnapshot {
    let style = crate::config::load().deepseek_display;
    snapshot_with_style(now_ms, &style)
}

pub fn start(app: AppHandle) {
    std::thread::spawn(move || {
        loop {
            let style = {
                let st = app.state::<AppState>();
                let c = st.cfg.lock().unwrap();
                crate::config::deepseek_display_or_default(&c.deepseek_display)
            };
            let snap = snapshot_with_style(now_ms(), &style);
            persist(&snap);
            {
                let st = app.state::<AppState>();
                *st.deepseek.lock().unwrap() = snap.clone();
            }
            let _ = app.emit("deepseek", &snap);
            crate::tray::refresh_menu(&app);
            for _ in 0..POLL_SECS {
                if REFRESH.swap(false, std::sync::atomic::Ordering::Relaxed) {
                    break;
                }
                std::thread::sleep(Duration::from_secs(1));
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    use chrono::TimeZone;

    fn utc(y: i32, mo: u32, d: u32, h: u32) -> u64 {
        chrono::Utc
            .with_ymd_and_hms(y, mo, d, h, 0, 0)
            .unwrap()
            .timestamp_millis() as u64
    }

    #[test]
    fn peak_and_offpeak_rates() {
        assert!(is_peak(utc(2026, 10, 19, 2)));
        assert!(!is_peak(utc(2026, 10, 19, 12)));
        assert!((cost_usd(utc(2026, 10, 19, 2), 1_000_000, 0, 0) - 0.30).abs() < 1e-9);
        assert!((cost_usd(utc(2026, 10, 19, 12), 1_000_000, 0, 0) - 0.15).abs() < 1e-9);
    }

    #[test]
    fn weekend_is_offpeak() {
        assert!(!is_peak(utc(2026, 10, 17, 2)));
    }

    #[test]
    fn cost_counts_cache_reads_on_the_hit_rate() {
        assert!((cost_usd(utc(2026, 10, 19, 12), 0, 10_000_000, 0) - 0.03).abs() < 1e-9);
    }

    #[test]
    fn depleted_balance_reports_100_percent_and_all_three_display_formats() {
        let prev = BalanceState::default();
        let api = Some(BalanceReading {
            currency: "USD".into(),
            raw_balance: -0.08,
            is_available: false,
        });
        let state = compute_balance_state(&prev, 1.45, 39_062_765, api);
        assert!(!state.is_available);
        assert_eq!(state.remaining, 0.0);
        assert_eq!(state.funded, 2.0);
        assert_eq!(state.spent, 2.0);
        assert_eq!(
            format_note("remaining", state.spent, state.funded, state.remaining, state.tokens),
            "$0.00 remaining of $2.00 · 39.1M tokens"
        );
        assert_eq!(
            format_note("spent", state.spent, state.funded, state.remaining, state.tokens),
            "$2.00 of $2.00 used · $0.00 left · 39.1M tokens"
        );
        assert_eq!(
            format_note("compact", state.spent, state.funded, state.remaining, state.tokens),
            "$2.00 / $2.00 USD ($0.00 left)"
        );
    }

    #[test]
    fn top_up_above_two_dollars_scales_funded_amount() {
        let prev = BalanceState {
            funded: 2.0,
            last_balance: 0.0,
            baseline_spent: 1.80,
            remaining: 0.0,
            spent: 2.0,
            tokens: 10_000_000,
            has_api_reading: true,
            is_available: false,
        };
        let after_topup = compute_balance_state(
            &prev,
            1.80,
            10_000_000,
            Some(BalanceReading {
                currency: "USD".into(),
                raw_balance: 10.0,
                is_available: true,
            }),
        );
        assert_eq!(after_topup.funded, 10.0);
        assert_eq!(after_topup.remaining, 10.0);
        assert_eq!(after_topup.spent, 0.0);

        let after_spend = compute_balance_state(
            &after_topup,
            4.30,
            25_000_000,
            Some(BalanceReading {
                currency: "USD".into(),
                raw_balance: 7.50,
                is_available: true,
            }),
        );
        assert_eq!(after_spend.funded, 10.0);
        assert_eq!(after_spend.remaining, 7.50);
        assert_eq!(after_spend.spent, 2.50);
        assert_eq!(
            format_note("remaining", after_spend.spent, after_spend.funded, after_spend.remaining, after_spend.tokens),
            "$7.50 remaining of $10.00 · 25.0M tokens"
        );
    }

    #[test]
    fn snapshot_shows_a_credits_ring() {
        let snap = snapshot_at(now_ms());
        eprintln!("deepseek snapshot: status={} note={}", snap.status, snap.note);
        assert!(snap.status == "ok" || snap.status == "absent");
        if snap.status == "ok" {
            assert!(snap.windows.iter().any(|w| w.id == "credits"));
            assert!(!snap.note.contains("session"));
        }
    }

    #[test]
    fn day_bounds_are_24h_apart() {
        let (start, end) = day_bounds(now_ms());
        assert_eq!(end - start, 86_400_000);
        assert!(now_ms() >= start);
    }
}
