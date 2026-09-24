use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::PathBuf;

/// The Mac's notch sizes, as multiples of the designed size: Small, Medium, Large.
pub const SIZES: [f64; 3] = [0.8, 1.0, 1.25];

/// The nearest of `SIZES`, so a scale saved by the old 40–100 % slider still lands on a size that
/// exists. 0.9, halfway between Small and Medium, counts as Medium.
pub fn snap_scale(scale: f64) -> f64 {
    if scale < 0.9 {
        SIZES[0]
    } else if scale < 1.125 || !scale.is_finite() {
        SIZES[1]
    } else {
        SIZES[2]
    }
}

/// One ring on the notch: which provider. (A `window` key from older builds is ignored.)
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TraySlot {
    pub provider: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    #[serde(default = "default_port")]
    pub port: u16,
    /// "auto" | "zh" | "zh-Hant" | "en" | "ja" | "ko" | "pt-BR" | "ru" | "uk"
    #[serde(default = "default_lang")]
    pub lang: String,
    #[serde(default)]
    pub bar_x: Option<i32>,
    #[serde(default)]
    pub bar_y: Option<i32>,
    /// Logical width of the bar (wheel-adjustable, 220-520); None = default 360
    #[serde(default)]
    pub bar_w: Option<u32>,
    /// Allow dragging + wheel resizing (tray toggle, off by default to prevent accidental drags)
    #[serde(default)]
    pub drag_enabled: bool,
    /// The one position every edge used to share, read once so `load` can hand it to the edge the
    /// notch is on and never written again. `notch_along` replaces it.
    #[serde(default = "default_notch_y", skip_serializing)]
    pub notch_y: f64,
    /// Where along each edge the notch sits: the window centre as a fraction of that edge's span in
    /// the work area, 0 = top/left, 1 = bottom/right, 0.5 = centred (the default for an edge with
    /// no entry). One per edge, as the Mac keeps one offset per edge: sliding it along the right
    /// edge should not also move it on the top.
    #[serde(default)]
    pub notch_along: BTreeMap<String, f64>,
    /// Which screen edge the notch is pinned to: "right" (the default), "left", "top" or "bottom".
    #[serde(default = "default_notch_edge")]
    pub notch_edge: String,
    /// Which monitor the notch lives on, by the system's device name (`\\.\DISPLAY2`). None, or a
    /// name no longer attached, means the primary monitor — so unplugging a screen cannot strand it.
    #[serde(default)]
    pub notch_monitor: Option<String>,
    /// Notch size as a multiple of the designed size, one of `SIZES`. The whole notch scales: the
    /// window grows and its WebView zooms, so the rings, text and hover card keep their proportions.
    #[serde(default = "default_scale")]
    pub scale: f64,
    /// Where the weekly limit gets a ring of its own: "off", "inside" or "outside".
    #[serde(default = "default_weekly_ring")]
    pub weekly_ring: String,
    /// How a usage ring changes colour: "hard_step" or "ramp".
    #[serde(default = "default_color_transition")]
    pub color_transition: String,
    /// Which appearance the pages draw in: "system", "light" or "dark".
    #[serde(
        default = "default_theme",
        deserialize_with = "deserialize_theme_or_system"
    )]
    pub theme: String,
    /// Which providers the notch itself shows, in order. Empty means every provider that has
    /// something to report — the original behaviour, and the default. Superseded by `notch_slots`,
    /// kept so an existing config migrates cleanly.
    #[serde(default)]
    pub notch_providers: Vec<String>,
    /// Which providers get a ring on the notch, in order. An empty list means every provider.
    #[serde(default)]
    pub notch_slots: Vec<TraySlot>,
    /// Antigravity's lane on the ring, as the Mac app's "Notch reads": "automatic", "5h" or "weekly"
    #[serde(default = "default_antigravity_limit")]
    pub antigravity_limit: String,
    /// The model family that choice looks at, as the Mac app's "Model data": "gemini" or "3p"
    #[serde(default = "default_antigravity_model")]
    pub antigravity_model: String,
    /// One-shot migration flag: a config saved before the GLM ring existed gets GLM added to the
    /// notch once; an explicit later un-tick is respected and never overridden.
    #[serde(default)]
    pub glm_notch_fixed: bool,
    /// The same one-shot migration for the OpenCode ring.
    #[serde(default)]
    pub opencode_notch_fixed: bool,
    /// false = the pill is kept off the screen edge entirely; the tray icon is then the only way in
    #[serde(default = "yes")]
    pub notch_visible: bool,
    /// true = the Mac's Show on hover: the notch rests as a small pill at the edge and opens when the
    /// pointer reaches it. Only means anything while `notch_visible` is true. The Mac's default, and a
    /// fresh install's; a config written before this existed keeps the always-open notch it had (see
    /// `load`), so nobody's notch starts folding on an update.
    #[serde(default = "yes")]
    pub notch_on_hover: bool,
    /// false = the tray icon is hidden. Refused while the notch is also hidden, because that would
    /// leave the app running with no way to reach it.
    #[serde(default = "yes")]
    pub tray_visible: bool,
    /// false = no arc above the notch to carry it by. Nothing is lost: Appearance → Edge moves it too.
    #[serde(default = "yes")]
    pub show_move_handle: bool,
}

fn default_notch_y() -> f64 {
    0.5
}
fn default_notch_edge() -> String {
    "right".into()
}

/// The four edges, in the order Settings lists them.
pub const EDGES: [&str; 4] = ["left", "right", "top", "bottom"];

/// An unreadable edge means the right-hand one, the layout every earlier build used.
pub fn edge_or_right(value: &str) -> String {
    if EDGES.contains(&value) {
        value.to_string()
    } else {
        "right".into()
    }
}

/// True for the edges the notch stands upright on (the pill is a column); false for top and bottom,
/// where it lies flat (the pill is a row) and the window's width and height swap.
pub fn edge_is_vertical(edge: &str) -> bool {
    matches!(edge, "left" | "right")
}

/// Show on hover is the default for a fresh install, as on the Mac, but a config saved before the
/// setting existed was saved by a notch that was always open, and it stays that way: its owner never
/// chose a folding notch, so an update is not where they should meet one.
fn keep_open_on_upgrade(cfg: &mut Config, raw: Option<&str>) {
    let saved_without_it = raw
        .and_then(|t| serde_json::from_str::<serde_json::Value>(t).ok())
        .is_some_and(|v| v.get("notch_on_hover").is_none());
    if saved_without_it {
        cfg.notch_on_hover = false;
    }
}

/// Migration: the one position every edge used to share becomes the position for the edge the notch
/// was on, so an existing config keeps its place; the other edges start centred. `notch_y` is never
/// written back, so this runs once and a later `load` finds `notch_along` already filled in.
fn carry_shared_position(cfg: &mut Config) {
    if cfg.notch_along.is_empty() && (cfg.notch_y - 0.5).abs() > f64::EPSILON {
        let edge = edge_or_right(&cfg.notch_edge);
        let along = cfg.notch_y;
        cfg.set_along(&edge, along);
    }
}

impl Config {
    /// Where the notch sits along `edge`: centred until it has been slid somewhere on that edge.
    pub fn along(&self, edge: &str) -> f64 {
        self.notch_along.get(edge).copied().unwrap_or(0.5).clamp(0.0, 1.0)
    }
    pub fn set_along(&mut self, edge: &str, along: f64) {
        self.notch_along.insert(edge.to_string(), along.clamp(0.0, 1.0));
    }
}

fn default_scale() -> f64 {
    1.0
}
fn default_weekly_ring() -> String {
    "off".into()
}
fn default_color_transition() -> String {
    "hard_step".into()
}
fn default_theme() -> String {
    "system".into()
}

/// An unreadable value follows Windows, which is what someone who never opened this row gets.
pub fn theme_or_system(value: &str) -> String {
    match value {
        "light" | "dark" => value.to_string(),
        _ => default_theme(),
    }
}

/// A malformed theme must not leave the JSON parser mid-value and discard the user's other choices.
fn deserialize_theme_or_system<'de, D>(deserializer: D) -> Result<String, D::Error>
where
    D: serde::Deserializer<'de>,
{
    Ok(Option::<serde_json::Value>::deserialize(deserializer)
        .ok()
        .flatten()
        .and_then(|value| value.as_str().map(theme_or_system))
        .unwrap_or_else(default_theme))
}

/// A second arc changes how every reading looks, so an unreadable value means off rather than a
/// guess at what was meant.
pub fn weekly_ring_or_off(value: &str) -> String {
    match value {
        "inside" | "outside" => value.to_string(),
        _ => default_weekly_ring(),
    }
}

/// A new colour blend is opt-in, so an unknown value keeps the existing hard steps.
pub fn color_transition_or_step(value: &str) -> String {
    match value {
        "ramp" => value.to_string(),
        _ => default_color_transition(),
    }
}
fn yes() -> bool {
    true
}
fn default_antigravity_limit() -> String {
    "automatic".into()
}
fn default_antigravity_model() -> String {
    "gemini".into()
}

fn default_port() -> u16 {
    48666
}
fn default_lang() -> String {
    "auto".into()
}

impl Default for Config {
    fn default() -> Self {
        Self {
            port: default_port(),
            lang: default_lang(),
            bar_x: None,
            bar_y: None,
            bar_w: None,
            drag_enabled: false,
            notch_y: default_notch_y(),
            notch_along: BTreeMap::new(),
            notch_edge: default_notch_edge(),
            notch_monitor: None,
            scale: default_scale(),
            weekly_ring: default_weekly_ring(),
            color_transition: default_color_transition(),
            theme: default_theme(),
            notch_providers: Vec::new(), // empty = show them all
            notch_slots: Vec::new(),     // filled in by load(), from notch_providers
            antigravity_limit: default_antigravity_limit(),
            antigravity_model: default_antigravity_model(),
            glm_notch_fixed: true, // a fresh install picks from the full list already
            opencode_notch_fixed: true,
            notch_visible: true,
            notch_on_hover: true,
            tray_visible: true,
            show_move_handle: true,
        }
    }
}

pub fn config_path() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("codenotch")
        .join("config.json")
}

pub fn load() -> Config {
    let path = config_path();
    let raw = std::fs::read_to_string(&path).ok();
    let mut cfg: Config = raw
        .as_deref()
        .and_then(|t| serde_json::from_str(t).ok())
        .unwrap_or_default();
    keep_open_on_upgrade(&mut cfg, raw.as_deref());

    // Migration: before slots existed the notch was a plain provider list, one ring each. That is
    // exactly a list of slots, so nobody's choice is lost and nobody has to reconfigure anything.
    if cfg.notch_slots.is_empty() {
        cfg.notch_slots = cfg
            .notch_providers
            .iter()
            .map(|p| TraySlot { provider: p.clone() })
            .collect();
    }

    carry_shared_position(&mut cfg);
    // A selection saved before GLM existed gets the GLM ring back exactly once.
    migrate_glm_notch(&mut cfg, &raw);
    // Likewise for OpenCode.
    migrate_opencode_notch(&mut cfg, &raw);

    // Both hidden would leave the app unreachable: no pill, no tray icon, no way to open settings.
    if !cfg.notch_visible && !cfg.tray_visible {
        cfg.tray_visible = true;
    }

    // The old slider's 40–100 %, or a hand-edited file, lands on one of the three sizes
    cfg.scale = snap_scale(cfg.scale);
    cfg.weekly_ring = weekly_ring_or_off(&cfg.weekly_ring);
    cfg.color_transition = color_transition_or_step(&cfg.color_transition);
    cfg.theme = theme_or_system(&cfg.theme);
    cfg
}

fn migrate_glm_notch(cfg: &mut Config, raw: &Option<String>) {
    let predates = raw
        .as_deref()
        .and_then(|t| serde_json::from_str::<serde_json::Value>(t).ok())
        .map(|v| v.get("glm_notch_fixed").is_none())
        .unwrap_or(false);
    if !predates {
        return;
    }
    if !cfg.notch_slots.is_empty() && !cfg.notch_slots.iter().any(|s| s.provider == "glm") {
        cfg.notch_slots.push(TraySlot { provider: "glm".into() });
    }
    cfg.glm_notch_fixed = true;
}

fn migrate_opencode_notch(cfg: &mut Config, raw: &Option<String>) {
    let predates = raw
        .as_deref()
        .and_then(|t| serde_json::from_str::<serde_json::Value>(t).ok())
        .map(|v| v.get("opencode_notch_fixed").is_none())
        .unwrap_or(false);
    if !predates {
        return;
    }
    if !cfg.notch_slots.is_empty() && !cfg.notch_slots.iter().any(|s| s.provider == "opencode") {
        cfg.notch_slots.push(TraySlot { provider: "opencode".into() });
    }
    cfg.opencode_notch_fixed = true;
}

pub fn save(cfg: &Config) {
    let path = config_path();
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(txt) = serde_json::to_string_pretty(cfg) {
        let _ = std::fs::write(path, txt);
    }
}

#[cfg(test)]
mod tests {
    use super::{
        carry_shared_position, color_transition_or_step, keep_open_on_upgrade, snap_scale, theme_or_system,
        weekly_ring_or_off, Config,
    };

    /// Show on hover is the Mac's default, so a fresh install gets it — but an update must not start
    /// folding a notch whose owner has only ever known it open.
    #[test]
    fn only_a_fresh_install_starts_on_hover() {
        let mut fresh = Config::default();
        keep_open_on_upgrade(&mut fresh, None);
        assert!(fresh.notch_on_hover, "no config file: the Mac's default");

        let mut upgraded = Config::default();
        keep_open_on_upgrade(&mut upgraded, Some(r#"{"notch_visible":true}"#));
        assert!(!upgraded.notch_on_hover, "saved before the setting existed: stays open");

        for chosen in [true, false] {
            let mut c = Config { notch_on_hover: chosen, ..Default::default() };
            keep_open_on_upgrade(&mut c, Some(&format!(r#"{{"notch_on_hover":{chosen}}}"#)));
            assert_eq!(c.notch_on_hover, chosen, "a choice already made is kept");
        }
    }

    /// The Mac keeps one offset per edge; sliding the notch along one must not move it on another.
    #[test]
    fn each_edge_keeps_its_own_place() {
        let mut c = Config::default();
        assert_eq!(c.along("right"), 0.5, "an edge never slid along is centred");
        c.set_along("right", 0.2);
        assert_eq!(c.along("right"), 0.2);
        assert_eq!(c.along("top"), 0.5, "sliding it on the right left the top where it was");
        c.set_along("top", 7.0);
        assert_eq!(c.along("top"), 1.0, "and it can never be put past the end of an edge");
    }

    #[test]
    fn the_shared_position_moves_to_the_edge_the_notch_was_on() {
        let mut c = Config { notch_y: 0.3, notch_edge: "left".into(), ..Default::default() };
        carry_shared_position(&mut c);
        assert_eq!(c.along("left"), 0.3, "an existing config keeps its place");
        assert_eq!(c.along("right"), 0.5, "the edges it was not on start centred");
        // Once carried over, a later load leaves it alone even though notch_y still reads 0.3
        c.set_along("left", 0.8);
        carry_shared_position(&mut c);
        assert_eq!(c.along("left"), 0.8);
        // A centred config has nothing to carry, so nothing is written for it
        let mut centred = Config::default();
        carry_shared_position(&mut centred);
        assert!(centred.notch_along.is_empty());
    }

    #[test]
    fn the_shared_position_is_read_but_never_written_again() {
        let mut v = serde_json::to_value(Config { notch_y: 0.3, ..Default::default() }).unwrap();
        assert!(v.get("notch_y").is_none(), "{v}");
        v["notch_y"] = serde_json::json!(0.3);
        let back: Config = serde_json::from_value(v).unwrap();
        assert_eq!(back.notch_y, 0.3);
    }

    #[test]
    fn a_saved_scale_snaps_to_the_nearest_size() {
        assert_eq!(snap_scale(0.4), 0.8);
        assert_eq!(snap_scale(0.85), 0.8);
        assert_eq!(snap_scale(0.9), 1.0);
        assert_eq!(snap_scale(1.0), 1.0);
        assert_eq!(snap_scale(1.2), 1.25);
        assert_eq!(snap_scale(3.0), 1.25);
    }

    #[test]
    fn only_the_two_placements_are_kept() {
        assert_eq!(weekly_ring_or_off("inside"), "inside");
        assert_eq!(weekly_ring_or_off("outside"), "outside");
        assert_eq!(weekly_ring_or_off("Inside"), "off");
        assert_eq!(weekly_ring_or_off(""), "off");
        assert_eq!(color_transition_or_step("ramp"), "ramp");
        assert_eq!(color_transition_or_step("Ramp"), "hard_step");
        assert_eq!(color_transition_or_step(""), "hard_step");
        assert_eq!(theme_or_system("light"), "light");
        assert_eq!(theme_or_system("dark"), "dark");
        assert_eq!(theme_or_system("Dark"), "system");
        assert_eq!(theme_or_system(""), "system");
    }

    #[test]
    fn theme_preserves_the_rest_of_a_config_when_it_is_missing_or_malformed() {
        let old: Config = serde_json::from_str(r#"{"notch_visible":false}"#).unwrap();
        assert_eq!(old.theme, "system", "an existing config follows Windows");
        assert!(!old.notch_visible, "the existing choice survives");

        for (raw, expected) in [
            (r#""light""#, "light"),
            (r#""dark""#, "dark"),
            (r#""Light""#, "system"),
            ("true", "system"),
            ("[]", "system"),
            ("{}", "system"),
            ("null", "system"),
        ] {
            let cfg: Config =
                serde_json::from_str(&format!(r#"{{"theme":{raw},"notch_visible":false}}"#))
                    .unwrap();
            assert_eq!(cfg.theme, expected, "{raw} resolves safely");
            assert!(
                !cfg.notch_visible,
                "{raw} did not discard the rest of the config"
            );
        }

        let saved = serde_json::to_value(Config {
            theme: "light".into(),
            ..Default::default()
        })
        .unwrap();
        assert_eq!(
            saved.get("theme").and_then(|value| value.as_str()),
            Some("light")
        );
    }
}
