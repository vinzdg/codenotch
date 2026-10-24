//! Quota selection and physical layout shared by native drawing and mouse input.
//! No authentication, network access, window creation, or application state changes.

use crate::{config::{self, Config}, taskbar::Item, usage::LimitWindow};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Clone, Debug, PartialEq)]
pub struct Frame {
    pub items: Vec<Indicator>,
    pub dark: bool,
    /// Fractions used, matching the settings sliders (0..1).
    pub watch: f32,
    pub critical: f32,
    pub appearance: Appearance,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Appearance {
    pub weekly_ring: String,
    pub weekly_dashed: bool,
    pub color_transition: String,
    pub size: f32,
    pub shows_remaining: bool,
}

impl Appearance {
    pub fn from_config(cfg: &Config) -> Self {
        Self { weekly_ring:config::weekly_ring_or_off(&cfg.weekly_ring),
            weekly_dashed:cfg.weekly_ring_dashed,
            color_transition:config::color_transition_or_step(&cfg.color_transition),
            size:config::snap_scale(cfg.scale) as f32, shows_remaining:cfg.notch_shows_remaining }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Indicator {
    pub id: String,
    pub provider: String,
    pub inner: Option<f32>,
    pub outer: Option<f32>,
    pub inner_weekly: bool,
    pub outer_weekly: bool,
    pub text: String,
    pub work_state: String,
    pub dimmed: bool,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Slot {
    pub index: usize,
    pub x: f32,
    pub width: f32,
    pub center_x: f32,
    pub center_y: f32,
    pub radius: f32,
    pub logo_size: f32,
    pub text_x: f32,
}

impl Slot {
    /// The entire client rectangle accepts input, including transparent pixels.
    /// Adjacent slots share an edge; only the slot to its right owns that edge.
    pub fn contains(&self, x: f32, y: f32, height: f32) -> bool {
        x.is_finite() && y.is_finite() && height.is_finite()
            && x >= self.x && x < self.x + self.width && y >= 0.0 && y < height
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum CodexWindow { FiveHour, Weekly }

fn by_id<'a>(windows: &'a [LimitWindow], id: &str) -> Option<&'a LimitWindow> {
    windows.iter().find(|window| window.id == id)
}

fn duration_label(label: &str, value: &str, units: &[&str]) -> bool {
    label.strip_prefix(value).is_some_and(|unit| units.contains(&unit.trim_start()))
}

fn codex_window(window: &LimitWindow) -> Option<CodexWindow> {
    if !matches!(window.id.as_str(), "primary" | "secondary") { return None; }
    // The adapter derives this label from duration in every data source. Primary
    // and secondary identify buckets, so neither implies a particular duration.
    let label = window.label.split_whitespace().collect::<Vec<_>>().join(" ").to_lowercase();
    let duration = label.strip_suffix(" limit").unwrap_or(&label);
    if label == "limite de 5 horas"
        || duration_label(duration, "5", &["h", "hour", "hours"])
        || duration_label(duration, "300", &["m", "min", "minute", "minutes"])
    { return Some(CodexWindow::FiveHour); }
    if label == "limite semanal" || duration == "weekly"
        || duration_label(duration, "7", &["d", "day", "days"])
        || duration_label(duration, "168", &["h", "hour", "hours"])
    { return Some(CodexWindow::Weekly); }
    None
}

fn headline(item: &Item) -> Option<&LimitWindow> {
    let windows = &item.snapshot.windows;
    match item.provider.as_str() {
        "claude" => by_id(windows, "session").or_else(|| by_id(windows, "five_hour")).or_else(|| by_id(windows, "spend")),
        "codex" => windows.iter().find(|window| codex_window(window) == Some(CodexWindow::FiveHour)),
        provider => {
            let default = match provider {
                "cursor" => Some("included"), "glm" => Some("session"), "opencode" => Some("rolling"),
                "grok" => Some("credits"), "copilot" => Some("premium_interactions"),
                "deepseek" => Some("credits"), "commandcode" => Some("monthly"), "qoder" => Some("quota"),
                _ => None,
            };
            item.headline_id.as_deref().filter(|id| !id.is_empty()).or(default)
                .and_then(|id| by_id(windows, id))
                .or_else(|| if provider == "cursor" { by_id(windows, "api") } else if provider == "deepseek" { by_id(windows, "today") } else { None })
        }
    }
}

fn weekly<'a>(item: &'a Item, cfg: &Config) -> Option<&'a LimitWindow> {
    let windows = &item.snapshot.windows;
    match item.provider.as_str() {
        "claude" => by_id(windows, "seven_day").or_else(|| by_id(windows, "weekly_all")).or_else(|| by_id(windows, "weekly")),
        "codex" => windows.iter().find(|window| codex_window(window) == Some(CodexWindow::Weekly)),
        "glm" | "opencode" => by_id(windows,"weekly"),
        "gemini" => {
            let family:Vec<_> = windows.iter().filter(|w| crate::lane_family(w) == cfg.antigravity_model).collect();
            let lanes:Vec<_> = if family.is_empty() { windows.iter().collect() } else { family };
            crate::tightest(lanes.into_iter().filter(|w| crate::lane_is(w,"weekly")))
        }
        _ => None,
    }
}

fn fraction(window: Option<&LimitWindow>) -> Option<f32> {
    let window = window?;
    if window.count.is_some() || !window.used.is_finite() { return None; }
    // Keep the actual fraction for smooth colour ramps; only the label is rounded.
    Some(window.used.clamp(0.0, 1.0) as f32)
}

fn live_fraction(item: &Item, window: Option<&LimitWindow>, now: u64) -> Option<f32> {
    if item.provider == "claude" && (item.snapshot.status != "ok" || item.snapshot.fetched_at == 0
        || now.saturating_sub(item.snapshot.fetched_at) > 15 * 60 * 1000
        || window.is_some_and(|w| w.resets_at.is_some_and(|reset| reset <= now))) { return None; }
    fraction(window)
}

pub fn meter_fraction(used: f32, remaining: bool) -> f32 { if remaining { 1.0-used } else { used } }

pub fn from_items(items: &[Item], dark: bool, cfg: &Config) -> Frame {
    let watch = cfg.watch_limit as f32;
    let critical = cfg.critical_limit as f32;
    let critical = if critical.is_finite() { critical.clamp(0.02, 1.0) } else { 0.7 };
    let watch = if watch.is_finite() { watch } else { 0.5 }.clamp(0.01, (critical - 0.01).max(0.01));
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as u64;
    let appearance = Appearance::from_config(cfg);
    Frame {
        items: items.iter().map(|item| {
            let dual = matches!(item.provider.as_str(), "claude" | "codex");
            let main = headline(item);
            let weekly = weekly(item,cfg);
            let session = live_fraction(item,main,now);
            let week = live_fraction(item,weekly,now);
            let same = main.zip(weekly).is_some_and(|(a,b)| a.id == b.id);
            // The weekly option controls an additional ring. A sole available
            // weekly quota remains the primary outer ring, as in the original notch.
            let (inner,outer,inner_weekly,outer_weekly) = match (session,week,same,appearance.weekly_ring.as_str()) {
                (Some(main),Some(week),false,"outside") => (Some(main),Some(week),false,true),
                (Some(main),Some(week),false,"inside") => (Some(week),Some(main),true,false),
                (Some(main),_,_,_) => (None,Some(main),false,same),
                (None,Some(week),_,_) => (None,Some(week),false,true),
                _ => (None,None,false,false),
            };
            let shown = if dual { week.or_else(|| if main.is_some_and(|w| w.id == "spend") { session } else { None }) } else { session };
            Indicator {
                id: item.id.clone(), provider: item.provider.clone(),
                inner, outer, inner_weekly, outer_weekly,
                // Core Claude/Codex numbers are weekly; Enterprise can publish
                // only a spend quota. A missing quota never means 0%.
                text: shown.map(|used| format!("{}%", if appearance.shows_remaining { 100-(used*100.0).round() as u32 } else { (used*100.0).round() as u32 })).unwrap_or_else(|| "—".into()),
                work_state: match item.work_state.as_str() { "busy" => "busy", "waiting" => "waiting", _ => "idle" }.into(),
                dimmed: item.snapshot.status != "ok" || item.snapshot.fetched_at == 0
                    || now.saturating_sub(item.snapshot.fetched_at) > 15 * 60 * 1000,
            }
        }).collect(),
        dark, watch, critical, appearance,
    }
}

/// Same palette and interpolation as the original notch. In ramp mode the
/// watch threshold is yellow and 100% is red; critical applies to hard steps.
pub fn usage_color(value: f32, frame: &Frame) -> [u8;3] {
    let ample = if frame.dark { [0,255,136] } else { [0,163,86] };
    let watch = if frame.dark { [242,255,0] } else { [176,136,0] };
    let critical = [255,63,0];
    let value = if value.is_finite() { value.clamp(0.0,1.0) } else { 0.0 };
    if frame.appearance.color_transition != "ramp" {
        return if value >= frame.critical { critical } else if value >= frame.watch { watch } else { ample };
    }
    let (a,b,t) = if value < frame.watch {
        (ample,watch,value/frame.watch)
    } else { (watch,critical,(value-frame.watch)/(1.0-frame.watch)) };
    std::array::from_fn(|i| (a[i] as f32 + (b[i] as f32-a[i] as f32)*t).round() as u8)
}

/// All dimensions are physical client pixels. Every account gets a full-height
/// rectangular slot; drawing and hit testing must use these same coordinates.
/// Below 80 logical pixels per slot, circles/logo shrink and text must be clipped
/// or hidden by the renderer. Accounts are never silently dropped to make room.
pub fn layout(count: usize, width: f32, height: f32, scale: f32, size: f32) -> Vec<Slot> {
    if count == 0 || !width.is_finite() || !height.is_finite() || width <= 0.0 || height <= 0.0 { return Vec::new(); }
    let scale = if scale.is_finite() && scale > 0.0 { scale.clamp(0.5, 8.0) } else { 1.0 };
    let size = config::snap_scale(size as f64) as f32;
    let visual = scale * size;
    (0..count).map(|index| {
        // Calculate each shared boundary once by the same formula, avoiding a
        // cumulative rounding gap between input rectangles at fractional DPI.
        let x = (width as f64 * index as f64 / count as f64) as f32;
        let right = (width as f64 * (index + 1) as f64 / count as f64) as f32;
        let slot_width = right - x;
        let padding = (4.0 * scale).min(slot_width * 0.25).min(height * 0.25);
        let compact = ((slot_width - 2.0 * padding) / (72.0 * visual)).clamp(0.0, 1.0);
        let radius = (17.0 * visual * compact).min((height * 0.5 - (2.0 * scale).min(height * 0.25)).max(0.0));
        let logo_size = (18.0 * visual * compact).min(radius * 1.3);
        let gap = 6.0 * visual * compact;
        let text_width = 32.0 * visual * compact;
        let group_width = radius * 2.0 + gap + text_width;
        let start = x + (slot_width - group_width) * 0.5;
        Slot { index, x, width: slot_width, center_x: start + radius, center_y: height * 0.5,
            radius, logo_size, text_x: start + radius * 2.0 + gap }
    }).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::usage::UsageSnapshot;

    fn window(id: &str, label: &str, used: f64) -> LimitWindow {
        LimitWindow { id: id.into(), label: label.into(), used, ..Default::default() }
    }
    fn item(provider: &str, windows: Vec<LimitWindow>) -> Item {
        Item { id: format!("{provider}@fixture"), name: "Fixture".into(), provider: provider.into(), headline_id: None,
            work_state: "idle".into(), snapshot: UsageSnapshot { status: "ok".into(), fetched_at: u64::MAX, windows, ..Default::default() } }
    }
    fn config() -> Config { Config { weekly_ring:"outside".into(), ..Default::default() } }
    fn indicator(item: Item) -> Indicator { from_items(&[item], true, &config()).items.remove(0) }

    #[test]
    fn codex_weekly_primary_is_outer_only_and_shows_nine_percent() {
        let shown = indicator(item("codex", vec![window("primary", "Weekly limit", 0.09)]));
        assert_eq!((shown.inner, shown.outer, shown.text.as_str()), (None, Some(0.09), "9%"));
    }
    #[test]
    fn claude_windows_are_independent_and_alias_priority_matches_the_ui() {
        let shown = indicator(item("claude", vec![window("seven_day_sonnet", "", 0.99), window("weekly_all", "", 0.23), window("session", "", 0.71)]));
        assert_eq!((shown.inner, shown.outer, shown.text.as_str()), (Some(0.71), Some(0.23), "23%"));
        let shown = indicator(item("claude", vec![window("weekly_all", "", 0.8), window("seven_day", "", 0.2), window("five_hour", "", 0.4)]));
        assert_eq!((shown.inner, shown.outer), (Some(0.4), Some(0.2)));
    }
    #[test]
    fn core_codex_roles_follow_duration_not_bucket_or_headline_override() {
        let mut account = item("codex", vec![window("primary", "Weekly limit", 0.18), window("secondary", "5h limit", 0.62)]);
        account.headline_id = Some("primary".into());
        let shown = indicator(account);
        assert_eq!((shown.inner, shown.outer, shown.text.as_str()), (Some(0.62), Some(0.18), "18%"));
        for label in ["Monthly limit", "Current session", "Longer window", "24h limit", "weekly review"] {
            let shown = indicator(item("codex", vec![window("primary", label, 0.35)]));
            assert_eq!((shown.inner, shown.outer, shown.text.as_str()), (None, None, "—"));
        }
    }
    #[test]
    fn spark_review_and_model_windows_never_substitute_for_core_quotas() {
        let shown = indicator(item("codex", vec![window("spark", "5h limit", 0.8), window("code-review", "Weekly limit", 0.9)]));
        assert_eq!((shown.inner, shown.outer, shown.text.as_str()), (None, None, "—"));
        let shown = indicator(item("claude", vec![window("session", "", 0.57), window("seven_day_sonnet", "", 0.9)]));
        assert_eq!((shown.inner, shown.outer, shown.text.as_str()), (None, Some(0.57), "—"));
    }
    #[test]
    fn missing_corrupt_counts_and_real_zero_remain_distinct() {
        for used in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            let shown = indicator(item("claude", vec![window("weekly_all", "", used)]));
            assert_eq!((shown.outer, shown.text.as_str()), (None, "—"));
        }
        let mut counted = window("weekly_all", "", 0.6); counted.count = Some(42);
        assert_eq!(indicator(item("claude", vec![counted])).outer, None);
        let zero = indicator(item("claude", vec![window("weekly_all", "", 0.0)]));
        assert_eq!((zero.outer, zero.text.as_str()), (Some(0.0), "0%"));
        assert_eq!(indicator(item("claude", vec![])).text, "—");
    }
    #[test]
    fn used_fraction_is_clamped_without_losing_smooth_colour_precision() {
        for (used, expected, text) in [(-0.2, 0.0, "0%"), (1.2, 1.0, "100%"), (0.714, 0.714, "71%"), (0.715, 0.715, "72%"), (0.497, 0.497, "50%")] {
            let shown = indicator(item("claude", vec![window("weekly_all", "", used)]));
            assert_eq!((shown.outer, shown.text.as_str()), (Some(expected), text));
        }
    }
    #[test]
    fn other_providers_keep_the_selected_headline_and_single_outer_arc() {
        let mut account = item("gemini", vec![window("chosen", "", 0.42), window("other", "", 0.9)]);
        account.headline_id = Some("chosen".into());
        let shown = indicator(account);
        assert_eq!((shown.inner, shown.outer, shown.text.as_str()), (None, Some(0.42), "42%"));
        assert_eq!(indicator(item("cursor", vec![window("api", "", 0.3)])).outer, Some(0.3));
    }
    #[test]
    fn status_marks_saved_values_and_activity_stays_per_account() {
        let mut saved = item("claude", vec![window("weekly_all", "", 0.23)]);
        saved.snapshot.status = "stale".into(); saved.work_state = "waiting".into();
        let shown = indicator(saved);
        assert!(shown.dimmed); assert_eq!(shown.outer, None); assert_eq!(shown.text, "—"); assert_eq!(shown.work_state, "waiting");
        let mut unknown = item("codex", vec![]); unknown.snapshot.fetched_at = 0; unknown.work_state = "invalid".into();
        assert!(indicator(unknown).dimmed);
        assert_eq!(indicator(item("codex", vec![])).work_state, "idle");
        assert!(!indicator(item("codex", vec![])).dimmed);
    }
    #[test]
    fn claude_hides_expired_or_old_quotas_without_blanketing_a_fresh_account() {
        let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() as u64;
        let mut saved = item("claude", vec![window("session", "", 0.71), window("weekly_all", "", 0.23)]);
        saved.snapshot.fetched_at = now;
        saved.snapshot.windows[0].resets_at = Some(now - 1);
        let frame = from_items(std::slice::from_ref(&saved), true, &config());
        let shown = &frame.items[0];
        assert_eq!((shown.inner, shown.outer, shown.text.as_str()), (None, Some(0.23), "23%"));
        saved.snapshot.fetched_at = now - 16 * 60 * 1000;
        let fresh = item("claude", vec![window("weekly_all", "", 0.4)]);
        let frame = from_items(&[saved, fresh], true, &config());
        assert_eq!((frame.items[0].outer, frame.items[0].text.as_str()), (None, "—"));
        assert_eq!((frame.items[1].outer, frame.items[1].text.as_str()), (Some(0.4), "40%"));
    }
    #[test]
    fn remaining_mode_inverts_meter_and_text_but_warning_colour_still_uses_consumption() {
        let account = item("claude", vec![window("session", "", 0.71), window("weekly_all", "", 0.23)]);
        let used = from_items(std::slice::from_ref(&account), true, &config());
        let remaining = from_items(&[account], true, &Config { notch_shows_remaining:true, ..config() });
        assert_eq!(remaining.items[0].text, "77%");
        assert_eq!(remaining.items[0].inner, used.items[0].inner);
        assert!(remaining.appearance.shows_remaining);
        assert!((meter_fraction(0.71, true) - 0.29).abs() < 0.001);
        assert_eq!(usage_color(0.71, &remaining), usage_color(0.71, &used));
        assert_eq!(meter_fraction(0.0, true), 1.0);
        assert_eq!(meter_fraction(1.0, true), 0.0);
    }
    #[test]
    fn enterprise_spend_only_is_a_single_primary_limit() {
        let shown = indicator(item("claude", vec![window("spend", "Spend limit", 0.31)]));
        assert_eq!((shown.inner, shown.outer, shown.text.as_str()), (None, Some(0.31), "31%"));
    }
    #[test]
    fn invalid_thresholds_cannot_make_a_frame_nonfinite() {
        let frame = from_items(&[], false, &Config { watch_limit:f64::NAN, critical_limit:f64::INFINITY, ..config() });
        assert_eq!((frame.watch, frame.critical, frame.dark), (0.5, 0.7, false));
        let frame = from_items(&[], true, &Config { watch_limit:0.9, critical_limit:0.3, ..config() });
        assert!(frame.watch < frame.critical);
    }
    #[test]
    fn saved_weekly_position_changes_only_the_extra_ring_and_keeps_the_weekly_number() {
        let account = item("claude",vec![window("session","",0.71),window("weekly_all","",0.23)]);
        for (placement,inner,outer,inner_weekly,outer_weekly) in [
            ("off",None,Some(0.71),false,false),
            ("inside",Some(0.23),Some(0.71),true,false),
            ("outside",Some(0.71),Some(0.23),false,true),
        ] {
            let cfg = Config { weekly_ring:placement.into(),weekly_ring_dashed:true,..config() };
            let frame = from_items(std::slice::from_ref(&account),true,&cfg);
            let shown = &frame.items[0];
            assert_eq!((shown.inner,shown.outer,shown.inner_weekly,shown.outer_weekly),(inner,outer,inner_weekly,outer_weekly));
            assert_eq!(shown.text,"23%");
            assert!(frame.appearance.weekly_dashed);
        }
        let weekly_only = item("codex",vec![window("primary","Weekly limit",0.09)]);
        for placement in ["off","inside","outside"] {
            let frame = from_items(std::slice::from_ref(&weekly_only),true,&Config { weekly_ring:placement.into(),..config() });
            assert_eq!((frame.items[0].inner,frame.items[0].outer,frame.items[0].outer_weekly),(None,Some(0.09),true));
        }
    }
    #[test]
    fn legacy_ramp_uses_watch_yellow_and_reaches_red_only_at_full_usage() {
        let mut cfg = Config { color_transition:"ramp".into(), ..config() };
        let frame = from_items(&[],true,&cfg);
        for (used,rgb) in [(0.0,[0,255,136]),(0.25,[121,255,68]),(0.5,[242,255,0]),(0.75,[249,159,0]),(1.0,[255,63,0])] {
            assert_eq!(usage_color(used,&frame),rgb);
        }
        cfg.critical_limit = 0.9;
        assert_eq!(usage_color(0.75,&frame),usage_color(0.75,&from_items(&[],true,&cfg)));
        cfg.color_transition = "hard_step".into();
        let step = from_items(&[],false,&cfg);
        assert_eq!(usage_color(0.0,&step),[0,163,86]);
        assert_eq!(usage_color(0.5,&step),[176,136,0]);
        assert_eq!(usage_color(0.9,&step),[255,63,0]);
    }
    #[test]
    fn saved_size_and_other_provider_weekly_limits_are_applied_without_changing_hit_slots() {
        let items = [item("glm",vec![window("session","",0.2),window("weekly","",0.8)])];
        let cfg = Config { scale:1.25,weekly_ring:"inside".into(),..config() };
        let frame = from_items(&items,true,&cfg);
        assert_eq!((frame.appearance.size,frame.items[0].inner,frame.items[0].outer),(1.25,Some(0.8),Some(0.2)));
        let mut previous = 0.0;
        for size in [0.8,1.0,1.25] {
            let slot = layout(3,280.0,42.0,1.0,size)[0];
            assert!(slot.radius > previous && slot.center_y-slot.radius >= 0.0);
            assert!(slot.contains(slot.x+1.0,21.0,42.0));
            previous = slot.radius;
        }
    }
    #[test]
    fn ordinary_layout_keeps_requested_visual_sizes_at_each_dpi() {
        for scale in [1.0, 1.25, 1.5, 2.0] {
            let slots = layout(3, 280.0 * scale, 42.0 * scale, scale, 1.0);
            for slot in slots {
                assert!((slot.radius - 17.0 * scale).abs() < 0.001);
                assert!((slot.logo_size - 18.0 * scale).abs() < 0.001);
                assert!(slot.contains(slot.center_x, slot.center_y, 42.0 * scale));
            }
        }
    }
    #[test]
    fn compact_layout_keeps_every_account_with_shared_edges_and_no_draw_overlap() {
        for count in [1, 2, 3, 5, 8, 16, 40] {
            let slots = layout(count, 280.0, 42.0, 1.0, 1.0);
            assert_eq!(slots.len(), count); assert_eq!(slots[0].x, 0.0);
            for (index, slot) in slots.iter().enumerate() {
                assert_eq!(slot.index, index); assert!(slot.width > 0.0);
                assert!(slot.center_x - slot.radius >= slot.x);
                assert!(slot.text_x >= slot.center_x + slot.radius);
                assert!(slot.text_x <= slot.x + slot.width);
                assert!(slot.center_y - slot.radius >= 0.0);
                assert!(slot.contains(slot.center_x, slot.center_y, 42.0));
                if let Some(next) = slots.get(index + 1) {
                    assert_eq!(slot.x + slot.width, next.x);
                    assert!(!slot.contains(next.x, slot.center_y, 42.0));
                    assert!(next.contains(next.x, next.center_y, 42.0));
                }
            }
            let last = slots.last().unwrap(); assert_eq!(last.x + last.width, 280.0);
            assert!(!last.contains(280.0, 21.0, 42.0));
            assert!(!last.contains(last.center_x, 42.0, 42.0));
        }
    }
    #[test]
    fn invalid_geometry_has_no_interactive_slots_or_nonfinite_coordinates() {
        for width in [0.0, -1.0, f32::NAN, f32::INFINITY] { assert!(layout(3, width, 42.0, 1.0, 1.0).is_empty()); }
        assert!(layout(0, 280.0, 42.0, 1.0, 1.0).is_empty());
        for scale in [0.0, -1.0, f32::NAN, f32::INFINITY] {
            assert_eq!(layout(3, 280.0, 42.0, scale, 1.0), layout(3, 280.0, 42.0, 1.0, 1.0));
        }
        let slot = layout(1, 280.0, 42.0, 1.0, 1.0)[0];
        assert!(!slot.contains(f32::NAN, 21.0, 42.0));
    }
}
