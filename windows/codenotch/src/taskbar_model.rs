//! What each taskbar cell shows and where it sits, shared by native drawing and mouse input.
//! A cell is the notch's own: the window `ring_window` gives the ring, the weekly ring `weeklyOf`
//! gives the notch, the figure the notch prints, all drawn in the notch's 56-unit box.
//! No authentication, network access, window creation, or application state changes.

use crate::{config::{self, Config}, taskbar::Item, usage::{LimitWindow, UsageSnapshot}};
use std::time::{SystemTime, UNIX_EPOCH};

/// The notch's ring square, in the units every radius below is given in.
pub const UNITS: f32 = 56.0;
/// The headline track: radius 25, 5 wide.
const TRACK_EXTENT: f32 = 55.0;
/// The weekly ring drawn outside: radius 31, 2.4 wide.
const OUTSIDE_EXTENT: f32 = 64.4;
/// The box at Medium, in logical px: an outside weekly ring still clears a 48 px taskbar.
const BOX: f32 = 32.0;
/// The taskbar clock's own text size, at Medium.
const FONT: f32 = 12.0;
/// The notch's 6 px from ring to figure and 14 px between cells, against its 44 px box.
const TEXT_GAP: f32 = 6.0 * UNITS / 44.0;
const CELL_GAP: f32 = 14.0 * UNITS / 44.0;
/// The notch's `staleOf`: the Mac's `UsageStore.staleAfter`.
const STALE_MS: u64 = 15 * 60 * 1000;

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
    /// Used fraction of the ring's own window; None leaves the track empty.
    pub headline: Option<f32>,
    /// Used fraction of the weekly window, when the weekly ring has one to draw.
    pub weekly: Option<f32>,
    pub text: String,
    pub work_state: String,
    pub stale: bool,
    /// The ring's window is used up, so the glyph dims as the notch's does.
    pub spent: bool,
}

/// Physical client pixels. Drawing and hit testing both use these.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Slot {
    pub index: usize,
    /// The input rectangle runs to the middle of the gap on each side, so there is no dead space
    /// between cells. Adjacent slots share an edge, owned by the slot on the right.
    pub x: f32,
    pub width: f32,
    pub center_x: f32,
    pub center_y: f32,
    /// Pixels per unit of the 56-unit box.
    pub unit: f32,
    pub text_x: f32,
    pub font: f32,
}

impl Slot {
    pub fn contains(&self, x: f32, y: f32, height: f32) -> bool {
        x.is_finite() && y.is_finite() && height.is_finite()
            && x >= self.x && x < self.x + self.width && y >= 0.0 && y < height
    }
}

fn now_ms() -> u64 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as u64 }

fn by_id<'a>(windows: &'a [LimitWindow], id: &str) -> Option<&'a LimitWindow> {
    windows.iter().find(|window| window.id == id)
}

/// The notch's `weeklyOf`.
fn weekly_window<'a>(provider: &str, windows: &'a [LimitWindow], model: &str) -> Option<&'a LimitWindow> {
    let metered: Vec<&LimitWindow> = windows.iter().filter(|w| w.count.is_none()).collect();
    let by_id = |id: &str| metered.iter().copied().find(|w| w.id == id);
    match provider {
        "claude" => by_id("seven_day").or_else(|| by_id("weekly_all")).or_else(|| by_id("weekly")),
        "codex" => by_id("secondary"),
        "glm" | "opencode" | "commandcode" => by_id("weekly"),
        "cursor" | "grok" | "copilot" | "deepseek" | "qoder" => None,
        _ => {
            let family: Vec<_> = metered.iter().copied().filter(|w| crate::lane_family(w) == model).collect();
            let lanes = if family.is_empty() { metered } else { family };
            crate::tightest(lanes.into_iter().filter(|w| crate::lane_is(w, "weekly")))
        }
    }
}

fn stale(snap: &UsageSnapshot, now: u64) -> bool {
    snap.status == "stale" || (snap.fetched_at > 0 && now.saturating_sub(snap.fetched_at) > STALE_MS)
}

/// The notch's `claudeQuotaCurrent`: after sign-out, a refused request or the window's own reset,
/// a cached Claude reading draws nothing rather than look current.
fn claude_current(snap: &UsageSnapshot, window: &LimitWindow, now: u64) -> bool {
    snap.status == "ok" && snap.fetched_at > 0 && !stale(snap, now)
        && window.resets_at.is_none_or(|reset| reset > now)
}

fn used(window: &LimitWindow) -> Option<f32> {
    (window.count.is_none() && window.used.is_finite()).then(|| window.used.clamp(0.0, 1.0) as f32)
}

/// The notch's `smallPct`, `pctText` and `leftPctText`: whole percents, except where rounding
/// would read as nothing used or nothing left.
fn small_pct(v: f64) -> String {
    if v <= 0.0 { return "0".into(); }
    let t = (v * 10.0).round() / 10.0;
    if t < 0.1 { "<0.1".into() } else if t > 99.9 { ">99.9".into() } else { format!("{t:.1}") }
}

fn pct_text(used: f64) -> String {
    let v = used * 100.0;
    if v > 0.0 && v < 1.0 { small_pct(v) } else { format!("{}", v.round() as i64) }
}

fn left_pct_text(used: f64) -> String {
    let v = used * 100.0;
    if (v > 0.0 && v < 1.0) || (v > 99.0 && v < 100.0) {
        let left = (100.0 - v).max(0.0);
        if left > 99.9 { ">99.9".into() } else { small_pct(left) }
    } else { format!("{}", (100 - v.round() as i64).max(0)) }
}

/// The figure under a notch ring.
fn figure(snap: &UsageSnapshot, head: Option<&LimitWindow>, remaining: bool) -> String {
    if snap.status == "needsAuth" || snap.status == "none" { return "—".into(); }
    match head {
        Some(LimitWindow { count: Some(count), .. }) => format!("~{count}"),
        Some(window) if window.used.is_finite() => format!("{}{}%", if window.derived { "~" } else { "" },
            if remaining { left_pct_text(window.used) } else { pct_text(window.used) }),
        // The declared window is missing from a reply: a dash, not a wait.
        _ if snap.windows.is_empty() => "…".into(),
        _ => "—".into(),
    }
}

fn indicator(item: &Item, cfg: &Config, appearance: &Appearance, now: u64) -> Indicator {
    let snap = &item.snapshot;
    let current = |window: &&LimitWindow| item.provider != "claude" || claude_current(snap, window, now);
    let head = item.headline_id.as_deref().and_then(|id| by_id(&snap.windows, id)).filter(current);
    let work_state = match item.work_state.as_str() { "busy" => "busy", "waiting" => "waiting", _ => "idle" };
    // Inside, the weekly ring shares its gap with the activity arc, so it stands down while that shows.
    let ring_on = match appearance.weekly_ring.as_str() { "outside" => true, "inside" => work_state == "idle", _ => false };
    let weekly = ring_on.then(|| weekly_window(&item.provider, &snap.windows, &cfg.antigravity_model)).flatten()
        .filter(current)
        .filter(|week| head.is_none_or(|head| head.id != week.id))
        .and_then(used);
    Indicator {
        id: item.id.clone(), provider: item.provider.clone(),
        headline: head.and_then(used),
        weekly,
        text: figure(snap, head, appearance.shows_remaining),
        work_state: work_state.into(),
        stale: stale(snap, now),
        spent: head.is_some_and(|window| window.used >= 1.0),
    }
}

pub fn meter_fraction(used: f32, remaining: bool) -> f32 { if remaining { 1.0-used } else { used } }

pub fn from_items(items: &[Item], dark: bool, cfg: &Config) -> Frame {
    let watch = cfg.watch_limit as f32;
    let critical = cfg.critical_limit as f32;
    let critical = if critical.is_finite() { critical.clamp(0.02, 1.0) } else { 0.7 };
    let watch = if watch.is_finite() { watch } else { 0.5 }.clamp(0.01, (critical - 0.01).max(0.01));
    let appearance = Appearance::from_config(cfg);
    let now = now_ms();
    Frame {
        items: items.iter().map(|item| indicator(item, cfg, &appearance, now)).collect(),
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

/// Segoe UI Semibold advances in ems; the renderer turns on tabular figures, so every digit is as
/// wide as a 0 and a reading moving from 31% to 47% never resizes the strip.
fn advance(c: char) -> f32 {
    match c {
        '0'..='9' => 0.5552,
        '%' => 0.8403,
        '.' => 0.2412,
        '~' | '<' | '>' => 0.6943,
        '…' => 0.8135,
        _ => 1.0,
    }
}

pub(crate) fn text_width(text: &str, font: f32) -> f32 { text.chars().map(advance).sum::<f32>() * font }

/// An outside weekly ring needs the room around every cell, or the cells would shift when one
/// account's weekly reading comes or goes.
fn extent(frame: &Frame) -> f32 {
    if frame.appearance.weekly_ring == "outside" && frame.items.iter().any(|item| item.weekly.is_some()) { OUTSIDE_EXTENT }
    else { TRACK_EXTENT }
}

/// Unit, font and extent for an unconstrained row.
fn natural(frame: &Frame, height: f32, scale: f32) -> Option<(f32, f32, f32)> {
    if frame.items.is_empty() || !height.is_finite() || height <= 0.0 { return None; }
    let scale = if scale.is_finite() && scale > 0.0 { scale.clamp(0.5, 8.0) } else { 1.0 };
    let visual = scale * config::snap_scale(frame.appearance.size as f64) as f32;
    let extent = extent(frame);
    // Large asks for more than a taskbar is tall: the box stops where the stack meets its edges.
    let unit = (BOX * visual / UNITS).min(height / extent);
    Some((unit, FONT * visual, extent))
}

fn cell_width(item: &Indicator, unit: f32, font: f32, extent: f32) -> f32 {
    (extent + TEXT_GAP) * unit + text_width(&item.text, font)
}

/// Half a cell gap at each end, a whole one between cells.
fn row_width(frame: &Frame, unit: f32, font: f32, extent: f32) -> f32 {
    frame.items.iter().map(|item| cell_width(item, unit, font, extent) + CELL_GAP * unit).sum()
}

/// How wide the strip has to be to hold these cells, in physical pixels.
pub fn content_width(frame: &Frame, height: f32, scale: f32) -> f32 {
    natural(frame, height, scale).map(|(unit, font, extent)| row_width(frame, unit, font, extent).ceil()).unwrap_or(0.0)
}

/// Cells packed at the notch's spacing and centred in `width`. Given less room than the row needs,
/// the whole row shrinks to fit; no account is dropped.
pub fn layout(frame: &Frame, width: f32, height: f32, scale: f32) -> Vec<Slot> {
    if !width.is_finite() || width <= 0.0 { return Vec::new(); }
    let Some((mut unit, mut font, extent)) = natural(frame, height, scale) else { return Vec::new(); };
    let wanted = row_width(frame, unit, font, extent);
    if wanted > width {
        let fit = width / wanted;
        unit *= fit;
        font *= fit;
    }
    let gap = CELL_GAP * unit;
    let mut lefts = Vec::with_capacity(frame.items.len());
    let mut left = (width - row_width(frame, unit, font, extent)).max(0.0) / 2.0 + gap / 2.0;
    for item in &frame.items {
        lefts.push(left);
        left += cell_width(item, unit, font, extent) + gap;
    }
    // Each boundary is worked out once, so neighbours share it exactly.
    let mut edges: Vec<f32> = lefts.iter().map(|left| left - gap / 2.0).collect();
    edges[0] = 0.0;
    edges.push(width);
    lefts.iter().enumerate().map(|(index, &left)| Slot {
        index, x: edges[index], width: edges[index + 1] - edges[index],
        center_x: left + extent * unit / 2.0, center_y: height / 2.0,
        unit, text_x: left + (extent + TEXT_GAP) * unit, font,
    }).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn window(id: &str, used: f64) -> LimitWindow {
        LimitWindow { id: id.into(), used, ..Default::default() }
    }
    fn item(provider: &str, headline: Option<&str>, windows: Vec<LimitWindow>) -> Item {
        Item { id: format!("{provider}@fixture"), name: "Fixture".into(), provider: provider.into(),
            headline_id: headline.map(Into::into), work_state: "idle".into(),
            snapshot: UsageSnapshot { status: "ok".into(), fetched_at: now_ms(), windows, ..Default::default() } }
    }
    fn config() -> Config { Config { weekly_ring:"outside".into(), ..Default::default() } }
    fn indicator(item: Item) -> Indicator { from_items(&[item], true, &config()).items.remove(0) }
    fn claude() -> Item { item("claude", Some("session"), vec![window("session", 0.71), window("seven_day", 0.23)]) }

    #[test]
    fn the_figure_is_the_rings_own_window_as_in_the_notch() {
        let shown = indicator(claude());
        assert_eq!((shown.headline, shown.weekly, shown.text.as_str()), (Some(0.71), Some(0.23), "71%"));
        let shown = indicator(item("codex", Some("primary"), vec![window("primary", 0.62), window("secondary", 0.18)]));
        assert_eq!((shown.headline, shown.weekly, shown.text.as_str()), (Some(0.62), Some(0.18), "62%"));
    }
    #[test]
    fn a_count_window_keeps_its_track_and_prints_the_count() {
        let mut requests = window("requests", 0.0);
        requests.count = Some(1);
        requests.derived = true;
        let shown = indicator(item("gemini", Some("requests"), vec![requests]));
        assert_eq!((shown.headline, shown.weekly, shown.text.as_str()), (None, None, "~1"));
    }
    #[test]
    fn figures_follow_the_notchs_rounding() {
        for (used, text) in [(0.0, "0%"), (0.005, "0.5%"), (0.0004, "<0.1%"), (0.714, "71%"), (0.715, "72%"), (1.0, "100%")] {
            assert_eq!(indicator(item("cursor", Some("included"), vec![window("included", used)])).text, text);
        }
        let mut derived = window("today", 0.4);
        derived.derived = true;
        assert_eq!(indicator(item("deepseek", Some("today"), vec![derived])).text, "~40%");
        let remaining = |used| from_items(&[item("cursor", Some("included"), vec![window("included", used)])], true,
            &Config { notch_shows_remaining:true, ..config() }).items.remove(0).text;
        assert_eq!((remaining(0.71).as_str(), remaining(0.0005).as_str(), remaining(0.995).as_str()), ("29%", ">99.9%", "0.5%"));
    }
    #[test]
    fn signed_out_missing_and_loading_read_differently() {
        let mut signed_out = claude();
        signed_out.snapshot.status = "needsAuth".into();
        assert_eq!(indicator(signed_out).text, "—");
        assert_eq!(indicator(item("glm", Some("session"), vec![window("weekly", 0.3)])).text, "—");
        assert_eq!(indicator(item("glm", None, vec![])).text, "…");
        for used in [f64::NAN, f64::INFINITY] {
            let shown = indicator(item("glm", Some("session"), vec![window("session", used)]));
            assert_eq!((shown.headline, shown.text.as_str()), (None, "—"));
        }
    }
    #[test]
    fn the_weekly_ring_follows_the_setting_and_stands_down_inside_while_working() {
        let at = |placement: &str, state: &str| {
            let mut account = claude();
            account.work_state = state.into();
            from_items(&[account], true, &Config { weekly_ring:placement.into(), ..config() }).items.remove(0).weekly
        };
        assert_eq!((at("off", "idle"), at("outside", "busy"), at("inside", "idle"), at("inside", "waiting")),
            (None, Some(0.23), Some(0.23), None));
        let weekly_is_headline = item("glm", Some("weekly"), vec![window("weekly", 0.4)]);
        assert_eq!(indicator(weekly_is_headline).weekly, None);
        assert_eq!(indicator(item("commandcode", Some("monthly"), vec![window("monthly", 0.1), window("weekly", 0.5)])).weekly, Some(0.5));
        assert_eq!(indicator(item("cursor", Some("included"), vec![window("included", 0.1), window("weekly", 0.5)])).weekly, None);
    }
    #[test]
    fn antigravity_weekly_is_the_tightest_weekly_lane_of_the_chosen_family() {
        let mut lanes = vec![window("gemini-5h", 0.2), window("gemini-weekly", 0.3), window("3p-weekly", 0.9)];
        lanes[1].label = "Weekly Limit".into();
        lanes[2].label = "Weekly Limit".into();
        assert_eq!(indicator(item("gemini", Some("gemini-5h"), lanes)).weekly, Some(0.3));
    }
    #[test]
    fn a_claude_reading_past_its_reset_or_fifteen_minutes_draws_nothing() {
        let now = now_ms();
        let mut reset = claude();
        reset.snapshot.windows[0].resets_at = Some(now - 1);
        let shown = indicator(reset);
        assert_eq!((shown.headline, shown.text.as_str(), shown.weekly), (None, "—", Some(0.23)));
        let mut old = claude();
        old.snapshot.fetched_at = now - STALE_MS - 1;
        let shown = indicator(old);
        assert_eq!((shown.headline, shown.weekly, shown.stale), (None, None, true));
    }
    #[test]
    fn other_providers_keep_an_old_reading_and_mark_it_stale() {
        let mut old = item("codex", Some("primary"), vec![window("primary", 0.4)]);
        old.snapshot.fetched_at = now_ms() - STALE_MS - 1;
        let shown = indicator(old);
        assert_eq!((shown.headline, shown.stale), (Some(0.4), true));
        let mut saved = item("codex", Some("primary"), vec![window("primary", 0.4)]);
        saved.snapshot.status = "stale".into();
        assert!(indicator(saved).stale);
        assert!(!indicator(item("codex", Some("primary"), vec![window("primary", 0.4)])).stale);
    }
    #[test]
    fn a_used_up_window_dims_the_glyph_and_activity_is_normalised() {
        let mut full = item("cursor", Some("included"), vec![window("included", 1.0)]);
        full.work_state = "invalid".into();
        let shown = indicator(full);
        assert!(shown.spent);
        assert_eq!(shown.work_state, "idle");
        assert!(!indicator(claude()).spent);
    }
    #[test]
    fn remaining_mode_inverts_the_meter_but_colour_still_follows_what_was_used() {
        let used = from_items(&[claude()], true, &config());
        let remaining = from_items(&[claude()], true, &Config { notch_shows_remaining:true, ..config() });
        assert_eq!(remaining.items[0].headline, used.items[0].headline);
        assert!((meter_fraction(0.71, true) - 0.29).abs() < 0.001);
        assert_eq!(usage_color(0.71, &remaining), usage_color(0.71, &used));
    }
    #[test]
    fn invalid_thresholds_cannot_make_a_frame_nonfinite() {
        let frame = from_items(&[], false, &Config { watch_limit:f64::NAN, critical_limit:f64::INFINITY, ..config() });
        assert_eq!((frame.watch, frame.critical, frame.dark), (0.5, 0.7, false));
        let frame = from_items(&[], true, &Config { watch_limit:0.9, critical_limit:0.3, ..config() });
        assert!(frame.watch < frame.critical);
    }
    #[test]
    fn legacy_ramp_uses_watch_yellow_and_reaches_red_only_at_full_usage() {
        let mut cfg = Config { color_transition:"ramp".into(), ..config() };
        let frame = from_items(&[],true,&cfg);
        for (used,rgb) in [(0.0,[0,255,136]),(0.25,[121,255,68]),(0.5,[242,255,0]),(0.75,[249,159,0]),(1.0,[255,63,0])] {
            assert_eq!(usage_color(used,&frame),rgb);
        }
        cfg.color_transition = "hard_step".into();
        let step = from_items(&[],false,&cfg);
        assert_eq!(usage_color(0.0,&step),[0,163,86]);
        assert_eq!(usage_color(0.5,&step),[176,136,0]);
        assert_eq!(usage_color(0.9,&step),[255,63,0]);
    }

    fn frame(texts: &[&str], weekly_ring: &str, size: f64) -> Frame {
        let items: Vec<Item> = texts.iter().map(|_| claude()).collect();
        let mut frame = from_items(&items, true, &Config { weekly_ring:weekly_ring.into(), scale:size, ..config() });
        for (shown, text) in frame.items.iter_mut().zip(texts) { shown.text = (*text).into(); }
        frame
    }

    #[test]
    fn the_strip_is_as_wide_as_its_cells_and_no_wider() {
        let one = content_width(&frame(&["8%"], "off", 1.0), 42.0, 1.0);
        let two = content_width(&frame(&["8%", "~1"], "off", 1.0), 42.0, 1.0);
        assert!(one > 40.0 && one < 70.0, "one cell is a ring and its figure: {one}");
        assert!(two > one * 1.8 && two < one * 2.2);
        // The two cells that sat 164 px apart in a 328 px strip.
        assert!(content_width(&frame(&["8%", "~1"], "outside", 1.0), 63.0, 1.5) < 240.0);
        let same_digits = content_width(&frame(&["31%"], "off", 1.0), 42.0, 1.0);
        assert_eq!(same_digits, content_width(&frame(&["47%"], "off", 1.0), 42.0, 1.0));
    }
    #[test]
    fn cells_are_packed_centred_and_share_their_edges() {
        let shown = frame(&["8%", "100%", "~1"], "off", 1.0);
        let needed = content_width(&shown, 42.0, 1.0);
        for width in [needed, needed + 60.0] {
            let slots = layout(&shown, width, 42.0, 1.0);
            assert_eq!(slots.len(), 3);
            assert_eq!(slots[0].x, 0.0);
            assert_eq!(slots[2].x + slots[2].width, width);
            for pair in slots.windows(2) {
                assert_eq!(pair[0].x + pair[0].width, pair[1].x);
                assert!(!pair[0].contains(pair[1].x, 21.0, 42.0) && pair[1].contains(pair[1].x, 21.0, 42.0));
                let gap = pair[1].center_x - pair[0].text_x;
                assert!(gap > 0.0 && gap < 60.0, "packed, not spread: {gap}");
            }
            let margin_left = slots[0].center_x - slots[0].unit * TRACK_EXTENT / 2.0;
            let margin_right = width - (slots[2].text_x + text_width("~1", slots[2].font));
            assert!((margin_left - margin_right).abs() < 0.5, "centred: {margin_left} vs {margin_right}");
        }
    }
    #[test]
    fn the_stack_fits_the_taskbar_height_at_every_size() {
        for (placement, extent) in [("off", TRACK_EXTENT), ("outside", OUTSIDE_EXTENT)] {
            let mut previous = 0.0;
            for size in [0.8, 1.0, 1.25] {
                for scale in [1.0, 1.25, 1.5, 2.0] {
                    let height = 42.0 * scale;
                    let slot = layout(&frame(&["8%"], placement, size), 1000.0, height, scale)[0];
                    assert!(slot.unit * extent <= height + 0.001, "{placement} {size} {scale}");
                    assert!(slot.center_y == height / 2.0);
                }
                let slot = layout(&frame(&["8%"], placement, size), 1000.0, 42.0, 1.0)[0];
                assert!(slot.unit >= previous);
                previous = slot.unit;
            }
        }
    }
    #[test]
    fn a_narrow_space_shrinks_the_row_instead_of_dropping_accounts() {
        let shown = frame(&["8%", "10%", "~1", "—", "…"], "off", 1.0);
        let natural = layout(&shown, 1000.0, 42.0, 1.0)[0].unit;
        let slots = layout(&shown, 120.0, 42.0, 1.0);
        assert_eq!(slots.len(), 5);
        assert!(slots[0].unit < natural);
        let last = slots[4];
        assert!(last.text_x + text_width("…", last.font) <= 120.0 + 0.01);
    }
    #[test]
    fn invalid_geometry_has_no_slots() {
        let shown = frame(&["8%"], "off", 1.0);
        for width in [0.0, -1.0, f32::NAN, f32::INFINITY] { assert!(layout(&shown, width, 42.0, 1.0).is_empty()); }
        assert!(layout(&shown, 100.0, f32::NAN, 1.0).is_empty());
        assert!(layout(&frame(&[], "off", 1.0), 100.0, 42.0, 1.0).is_empty());
        assert_eq!(layout(&shown, 100.0, 42.0, f32::NAN), layout(&shown, 100.0, 42.0, 1.0));
        assert!(!layout(&shown, 100.0, 42.0, 1.0)[0].contains(f32::NAN, 21.0, 42.0));
    }
}
