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
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager};

const POLL_SECS: u64 = 60;

/// What a day of Harness work is compared against. DeepSeek bills per token and the account
/// has no session window, so this is the operator's budget, not a vendor limit.
const DAILY_BUDGET_USD: f64 = 2.0;

static REFRESH: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

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
fn day_bounds(now_ms: u64) -> (u64, u64) {
    use chrono::{Local, TimeZone};
    let now = Local.timestamp_millis_opt(now_ms as i64).single().unwrap_or_else(Local::now);
    let start = now.date_naive().and_hms_opt(0, 0, 0).unwrap();
    let start = Local.from_local_datetime(&start).earliest().map(|d| d.timestamp_millis()).unwrap_or(0);
    (start as u64, start as u64 + 86_400_000)
}

/// Read today's usage. Returns `None` when the Harness has never recorded anything.
pub fn totals_today(now_ms: u64) -> Option<Totals> {
    let files = transcripts();
    if files.is_empty() {
        return None;
    }
    let (start, end) = day_bounds(now_ms);
    let mut totals = Totals::default();
    for path in &files {
        // A transcript is only ever appended to, so one last written before today holds nothing of
        // today's. Skipping it keeps a minute's poll from decompressing the whole history.
        if modified_ms(path).is_some_and(|m| m < start) {
            continue;
        }
        if fold_session(path, start, end, &mut totals) {
            totals.sessions += 1;
        }
    }
    Some(totals)
}

fn store_path() -> std::path::PathBuf {
    crate::config::config_path().with_file_name("deepseek-usage.json")
}

pub fn load_persisted() -> UsageSnapshot {
    std::fs::read_to_string(store_path())
        .ok()
        .and_then(|t| serde_json::from_str::<UsageSnapshot>(&t).ok())
        .map(|mut s| {
            // A reading from before midnight describes yesterday.
            let (start, _) = day_bounds(now_ms());
            if s.fetched_at < start && s.status == "ok" {
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

pub fn request_refresh() {
    REFRESH.store(true, std::sync::atomic::Ordering::Relaxed);
}

/// Build the snapshot for `now_ms`. Pure, so the tests can drive it.
pub fn snapshot_at(now_ms: u64) -> UsageSnapshot {
    let Some(totals) = totals_today(now_ms) else {
        return UsageSnapshot { status: "absent".into(), ..Default::default() };
    };
    let (_, end) = day_bounds(now_ms);
    let used = (totals.cost / DAILY_BUDGET_USD).clamp(0.0, 1.0);

    UsageSnapshot {
        status: "ok".into(),
        windows: vec![
            LimitWindow {
                id: "today".into(),
                label: "Today".into(),
                used,
                resets_at: Some(end),
                count: None,
                derived: true,
                group: None,
                ..Default::default()
            },
            LimitWindow {
                id: "tokens".into(),
                label: "Tokens today".into(),
                used: 0.0,
                resets_at: None,
                count: Some(totals.tokens as i64),
                derived: true,
                group: None,
                ..Default::default()
            },
        ],
        fetched_at: now_ms,
        note: format!(
            "~${:.2} of ${:.2} \u{b7} {}k tokens \u{b7} {} session{}",
            totals.cost,
            DAILY_BUDGET_USD,
            totals.tokens / 1000,
            totals.sessions,
            if totals.sessions == 1 { "" } else { "s" }
        ),
        backoff_until: 0,
        ..Default::default()
    }
}

pub fn start(app: AppHandle) {
    std::thread::spawn(move || {
        {
            let st = app.state::<AppState>();
            let snap = st.deepseek.lock().unwrap().clone();
            let _ = app.emit("deepseek", &snap);
        }
        loop {
            if REFRESH.swap(false, std::sync::atomic::Ordering::Relaxed) {
                let snap = snapshot_at(now_ms());
                persist(&snap);
                {
                    let st = app.state::<AppState>();
                    *st.deepseek.lock().unwrap() = snap.clone();
                }
                let _ = app.emit("deepseek", &snap);
                continue;
            }
            let snap = snapshot_at(now_ms());
            persist(&snap);
            {
                let st = app.state::<AppState>();
                *st.deepseek.lock().unwrap() = snap.clone();
            }
            let _ = app.emit("deepseek", &snap);
            std::thread::sleep(Duration::from_secs(POLL_SECS));
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
        // 2026-10-19 is a Monday; 02:00 UTC is peak, 12:00 UTC is off-peak.
        assert!(is_peak(utc(2026, 10, 19, 2)));
        assert!(!is_peak(utc(2026, 10, 19, 12)));
        assert!((cost_usd(utc(2026, 10, 19, 2), 1_000_000, 0, 0) - 0.30).abs() < 1e-9);
        assert!((cost_usd(utc(2026, 10, 19, 12), 1_000_000, 0, 0) - 0.15).abs() < 1e-9);
    }

    #[test]
    fn weekend_is_offpeak() {
        // 2026-10-17 is a Saturday: 02:00 UTC would be peak on a weekday.
        assert!(!is_peak(utc(2026, 10, 17, 2)));
    }

    #[test]
    fn cost_counts_cache_reads_on_the_hit_rate() {
        // 10M cache-read tokens at the off-peak hit rate = $0.03
        assert!((cost_usd(utc(2026, 10, 19, 12), 0, 10_000_000, 0) - 0.03).abs() < 1e-9);
    }

    #[test]
    fn snapshot_shows_a_derived_budget_ring() {
        let snap = snapshot_at(now_ms());
        // Either the Harness has data (ok) or it has none (absent); both are valid here.
        eprintln!("deepseek snapshot: status={} note={}", snap.status, snap.note);
        assert!(snap.status == "ok" || snap.status == "absent");
        if snap.status == "ok" {
            assert!(snap.windows.iter().any(|w| w.id == "today" && w.derived));
            assert!(snap.windows.iter().any(|w| w.id == "tokens"));
        }
    }

    #[test]
    fn day_bounds_are_24h_apart() {
        let (start, end) = day_bounds(now_ms());
        assert_eq!(end - start, 86_400_000);
        assert!(now_ms() >= start);
    }
}
