//! Detect confirmed quota renewals from consecutive, fresh readings, for any provider the notch
//! reads — Claude, Codex, Cursor, GLM, OpenCode, Grok and Antigravity alike. The archived snapshot
//! shown on launch is never an observation here, and nothing fires until a provider's own poll has
//! confirmed the change: this only reacts to what `snapshot_of` already holds, on the same cadence
//! every other reading updates at, so no provider needs its own copy of this logic.

use crate::usage::{LimitWindow, UsageSnapshot};
use std::collections::{HashMap, HashSet};

const FRESH_FOR_MS: u64 = 5 * 60 * 1000;
const MIN_USED: f64 = 0.10;
const MIN_DATE_ADVANCE_MS: u64 = 60 * 1000;
/// A flat stand-down after firing, since windows here range from a 5-hour Codex limit to a monthly
/// Cursor cycle: long enough that a reading which jitters right after a reset cannot double-count it,
/// short enough that a provider whose window is itself under an hour is not muted past its own reset.
const COOLDOWN_MS: u64 = 15 * 60 * 1000;

#[derive(Clone, Debug)]
pub struct ResetEvent {
    pub provider: String,
    /// The window's own published name ("5h limit", "Weekly limit", "Included usage", …), untranslated —
    /// `traymenu::label` carries the same English keys the rest of the app already translates from.
    pub window_label: String,
    pub used_fraction: f64,
    pub next_reset_at: Option<u64>,
}

#[derive(Clone, Debug)]
struct TrackedWindow {
    used: f64,
    peak: f64,
    resets_at: Option<u64>,
    last_alerted_at: Option<u64>,
    last_alerted_next_reset: Option<u64>,
}

impl TrackedWindow {
    fn baseline(window: &LimitWindow) -> Self {
        Self {
            used: window.used,
            peak: window.used,
            resets_at: window.resets_at,
            last_alerted_at: None,
            last_alerted_next_reset: None,
        }
    }
}

/// One provider's memory of its own windows. Every provider polls on its own schedule, so each gets
/// its own watcher rather than one shared clock the fastest provider would reset for the others.
#[derive(Default)]
pub struct ResetWatcher {
    last_fetched_at: u64,
    windows: HashMap<String, TrackedWindow>,
}

impl ResetWatcher {
    pub fn observe(&mut self, provider: &str, snapshot: &UsageSnapshot, now: u64) -> Vec<ResetEvent> {
        // An older rollout, an archived reading, and an error must not bridge two live observations.
        let fresh = snapshot.status == "ok"
            && snapshot.fetched_at > 0
            && snapshot.fetched_at <= now.saturating_add(60_000)
            && now.saturating_sub(snapshot.fetched_at) <= FRESH_FOR_MS;
        if !fresh {
            *self = Self::default();
            return Vec::new();
        }
        if snapshot.fetched_at <= self.last_fetched_at {
            return Vec::new();
        }
        self.last_fetched_at = snapshot.fetched_at;

        let mut alerts = Vec::new();
        let mut seen = HashSet::new();
        for window in &snapshot.windows {
            // A named group (Codex's Spark/Code review) is a sub-limit, not the account's own quota;
            // a pure count window (Antigravity's requests today) has no fraction to have renewed.
            if window.group.is_some() || window.count.is_some() {
                continue;
            }
            if !window.used.is_finite() || !(0.0..=1.0).contains(&window.used) || !seen.insert(window.id.clone())
            {
                continue;
            }
            let Some(previous) = self.windows.get_mut(&window.id) else {
                self.windows.insert(window.id.clone(), TrackedWindow::baseline(window));
                continue;
            };

            let elapsed = previous
                .resets_at
                .is_some_and(|deadline| deadline <= snapshot.fetched_at);
            let date_rolled = match (previous.resets_at, window.resets_at) {
                (Some(before), Some(after)) => {
                    elapsed
                        && after > snapshot.fetched_at
                        && after.saturating_sub(before) >= MIN_DATE_ADVANCE_MS
                        && previous
                            .last_alerted_next_reset
                            .is_none_or(|last| after > last)
                }
                _ => false,
            };
            // A percentage drop, for providers whose reading has no reset timestamp at all. Kept only
            // when the preceding deadline is unknown or has passed, so a correction to a live
            // percentage before a known deadline is not called a reset.
            let dropped = previous.used - window.used + f64::EPSILON >= MIN_USED
                && (previous.resets_at.is_none() || elapsed);
            let outside_cooldown = previous
                .last_alerted_at
                .is_none_or(|last| snapshot.fetched_at.saturating_sub(last) >= COOLDOWN_MS);
            let reset = previous.peak + f64::EPSILON >= MIN_USED
                && outside_cooldown
                && (date_rolled || dropped);
            if reset {
                alerts.push(ResetEvent {
                    provider: provider.to_string(),
                    window_label: window.label.clone(),
                    used_fraction: window.used,
                    next_reset_at: window.resets_at,
                });
                previous.peak = window.used;
                previous.last_alerted_at = Some(snapshot.fetched_at);
                previous.last_alerted_next_reset = window.resets_at;
            } else {
                previous.peak = previous.peak.max(window.used);
            }
            previous.used = window.used;
            previous.resets_at = window.resets_at;
        }
        self.windows.retain(|id, _| seen.contains(id));
        alerts
    }
}

/// Watches every provider the tray menu knows about, each with its own `ResetWatcher`, and turns a
/// detected renewal into a card via `reset_alert::enqueue`. Polled rather than hooked into each
/// provider's own loop: providers already publish to `AppState` on their own schedule, so reading
/// that shared state here is the one place this needs to exist, instead of a copy of this file
/// wired into `codex.rs`, `cursor.rs`, `glm.rs`, `opencode.rs`, `grok.rs` and `antigravity.rs`.
pub fn start(app: tauri::AppHandle) {
    std::thread::spawn(move || {
        let mut watchers: HashMap<&'static str, ResetWatcher> = HashMap::new();
        loop {
            let now = crate::now_ms();
            for &id in crate::TRAY_PROVIDER_IDS.iter() {
                let snap = crate::snapshot_of(&app, id);
                let watcher = watchers.entry(id).or_default();
                for event in watcher.observe(id, &snap, now) {
                    crate::reset_alert::enqueue(&app, event);
                }
            }
            std::thread::sleep(std::time::Duration::from_secs(5));
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: u64 = 1_800_000_000_000;

    fn window(id: &str, used: f64, resets_at: Option<u64>) -> LimitWindow {
        LimitWindow { id: id.into(), used, resets_at, ..Default::default() }
    }

    fn snapshot(at: u64, windows: Vec<LimitWindow>) -> UsageSnapshot {
        UsageSnapshot { status: "ok".into(), fetched_at: at, windows, ..Default::default() }
    }

    #[test]
    fn each_real_window_resets_once_even_when_both_roll_together() {
        let mut watcher = ResetWatcher::default();
        let before = snapshot(
            NOW - 2_000,
            vec![
                window("primary", 0.64, Some(NOW - 1_000)),
                window("secondary", 0.52, Some(NOW - 1_000)),
            ],
        );
        assert!(watcher.observe("codex", &before, NOW).is_empty());
        let after = snapshot(
            NOW,
            vec![
                window("primary", 0.02, Some(NOW + 300 * 60_000)),
                window("secondary", 0.01, Some(NOW + 10_080 * 60_000)),
            ],
        );
        let alerts = watcher.observe("codex", &after, NOW);
        assert_eq!(alerts.len(), 2);
        assert!(alerts.iter().all(|e| e.provider == "codex"));
        assert!(watcher.observe("codex", &after, NOW).is_empty());
        let repeated = snapshot(NOW + 1_000, after.windows);
        assert!(watcher.observe("codex", &repeated, NOW + 1_000).is_empty());
    }

    #[test]
    fn little_use_and_grouped_or_count_only_windows_do_not_alert() {
        let mut watcher = ResetWatcher::default();
        let before = snapshot(
            NOW - 2_000,
            vec![
                window("primary", 0.09, Some(NOW - 1_000)),
                LimitWindow { id: "spark".into(), used: 0.90, resets_at: Some(NOW - 1_000), group: Some("Spark".into()), ..Default::default() },
                LimitWindow { id: "requests".into(), count: Some(50), resets_at: Some(NOW - 1_000), ..Default::default() },
            ],
        );
        watcher.observe("codex", &before, NOW);
        let after = snapshot(
            NOW,
            vec![
                window("primary", 0.0, Some(NOW + 300 * 60_000)),
                LimitWindow { id: "spark".into(), used: 0.0, resets_at: Some(NOW + 300 * 60_000), group: Some("Spark".into()), ..Default::default() },
                LimitWindow { id: "requests".into(), count: Some(0), resets_at: Some(NOW + 300 * 60_000), ..Default::default() },
            ],
        );
        assert!(watcher.observe("codex", &after, NOW).is_empty());
    }

    #[test]
    fn stale_and_missing_readings_start_a_new_baseline() {
        let old = snapshot(NOW - 2_000, vec![window("primary", 0.80, Some(NOW - 1_000))]);
        let renewed = snapshot(NOW, vec![window("primary", 0.0, Some(NOW + 300 * 60_000))]);
        let mut watcher = ResetWatcher::default();
        watcher.observe("codex", &old, NOW);
        let mut stale = old.clone();
        stale.status = "stale".into();
        assert!(watcher.observe("codex", &stale, NOW).is_empty());
        assert!(watcher.observe("codex", &renewed, NOW).is_empty());
        let mut watcher = ResetWatcher::default();
        assert!(watcher.observe("codex", &renewed, NOW).is_empty());
        assert!(watcher.observe("codex", &snapshot(NOW, vec![]), NOW).is_empty());
    }

    #[test]
    fn a_future_deadline_and_small_timestamp_drift_are_not_resets() {
        let mut watcher = ResetWatcher::default();
        watcher.observe("claude", &snapshot(NOW - 2_000, vec![window("primary", 0.55, Some(NOW + 60_000))]), NOW);
        assert!(watcher
            .observe("claude", &snapshot(NOW, vec![window("primary", 0.1, Some(NOW + 61_000))]), NOW)
            .is_empty());
        let mut watcher = ResetWatcher::default();
        watcher.observe("claude", &snapshot(NOW - 2_000, vec![window("primary", 0.55, Some(NOW - 1_000))]), NOW);
        assert!(watcher
            .observe("claude", &snapshot(NOW, vec![window("primary", 0.55, Some(NOW + 1_000))]), NOW)
            .is_empty());
    }

    #[test]
    fn a_large_drop_without_timestamps_can_confirm_a_reset() {
        let mut watcher = ResetWatcher::default();
        watcher.observe("cursor", &snapshot(NOW - 2_000, vec![window("included", 0.50, None)]), NOW);
        let alerts = watcher.observe("cursor", &snapshot(NOW, vec![window("included", 0.02, None)]), NOW);
        assert_eq!(alerts.len(), 1);
        assert_eq!(alerts[0].provider, "cursor");
        assert_eq!(alerts[0].next_reset_at, None);
        assert!(watcher
            .observe("cursor", &snapshot(NOW + 1_000, vec![window("included", 0.50, None)]), NOW + 1_000)
            .is_empty());
        assert!(watcher
            .observe("cursor", &snapshot(NOW + 2_000, vec![window("included", 0.02, None)]), NOW + 2_000)
            .is_empty());
    }

    #[test]
    fn different_providers_track_their_windows_independently() {
        let mut codex = ResetWatcher::default();
        let mut claude = ResetWatcher::default();
        codex.observe("codex", &snapshot(NOW - 2_000, vec![window("primary", 0.80, Some(NOW - 1_000))]), NOW);
        claude.observe("claude", &snapshot(NOW - 2_000, vec![window("primary", 0.05, Some(NOW - 1_000))]), NOW);
        let codex_alerts = codex.observe("codex", &snapshot(NOW, vec![window("primary", 0.0, Some(NOW + 300 * 60_000))]), NOW);
        let claude_alerts = claude.observe("claude", &snapshot(NOW, vec![window("primary", 0.0, Some(NOW + 300 * 60_000))]), NOW);
        assert_eq!(codex_alerts.len(), 1, "used past the 10% floor rolls over");
        assert!(claude_alerts.is_empty(), "under the 10% floor stays quiet");
    }
}
