use serde::{Deserialize, Serialize};
use std::path::PathBuf;

pub const PROVIDERS: [&str; 4] = ["claude", "codex", "cursor", "gemini"];

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    #[serde(default = "default_port")]
    pub port: u16,
    /// "auto" | "zh" | "en" | "ja" | "ko"
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
    /// Vertical position of the notch: the window centre as a fraction of the primary monitor's height (0 = top, 1 = bottom), default 0.5; saved after a drag
    #[serde(default = "default_notch_y")]
    pub notch_y: f64,
    /// Screen edge used by the notch: "left" or "right".
    #[serde(default = "default_notch_side")]
    pub notch_side: String,
    /// Scale applied to the 340 × 460 design surface. The smaller default keeps the notch discreet.
    #[serde(default = "default_notch_scale")]
    pub notch_scale: f64,
    /// Providers the user chose to render, in display order.
    #[serde(default = "default_visible_providers")]
    pub visible_providers: Vec<String>,
    /// Pinned keeps the normal pill visible; otherwise the idle shell retracts to a black edge bar.
    #[serde(default)]
    pub notch_pinned: bool,
}

fn default_notch_y() -> f64 {
    0.5
}

fn default_notch_side() -> String {
    "right".into()
}

fn default_notch_scale() -> f64 {
    0.82
}

fn default_visible_providers() -> Vec<String> {
    PROVIDERS.iter().map(|p| (*p).to_string()).collect()
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
            notch_side: default_notch_side(),
            notch_scale: default_notch_scale(),
            visible_providers: default_visible_providers(),
            notch_pinned: false,
        }
    }
}

impl Config {
    pub fn normalize_notch(&mut self) {
        if self.notch_side != "left" && self.notch_side != "right" {
            self.notch_side = default_notch_side();
        }
        self.notch_y = self.notch_y.clamp(0.0, 1.0);
        self.notch_scale = self.notch_scale.clamp(0.65, 1.15);
        let mut seen = std::collections::HashSet::new();
        self.visible_providers.retain(|provider| {
            PROVIDERS.contains(&provider.as_str()) && seen.insert(provider.clone())
        });
        if self.visible_providers.is_empty() {
            self.visible_providers.push("claude".into());
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
    let mut cfg: Config = std::fs::read_to_string(&path)
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default();
    cfg.normalize_notch();
    cfg
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
    use super::*;

    #[test]
    fn legacy_config_gets_compact_notch_defaults() {
        let cfg: Config = serde_json::from_str(r#"{"port":48666,"lang":"auto"}"#).unwrap();
        assert_eq!(cfg.notch_side, "right");
        assert_eq!(cfg.notch_scale, 0.82);
        assert_eq!(cfg.visible_providers, default_visible_providers());
        assert!(!cfg.notch_pinned);
    }

    #[test]
    fn notch_preferences_are_sanitized() {
        let mut cfg = Config {
            notch_side: "bottom".into(),
            notch_y: 2.0,
            notch_scale: 4.0,
            visible_providers: vec!["codex".into(), "codex".into(), "unknown".into()],
            ..Default::default()
        };
        cfg.normalize_notch();
        assert_eq!(cfg.notch_side, "right");
        assert_eq!(cfg.notch_y, 1.0);
        assert_eq!(cfg.notch_scale, 1.15);
        assert_eq!(cfg.visible_providers, vec!["codex"]);
    }

    #[test]
    fn at_least_one_provider_remains_visible() {
        let mut cfg = Config {
            visible_providers: vec![],
            ..Default::default()
        };
        cfg.normalize_notch();
        assert_eq!(cfg.visible_providers, vec!["claude"]);
    }

    #[test]
    fn small_scale_survives_config_roundtrip() {
        let cfg = Config {
            notch_scale: 0.7,
            ..Default::default()
        };
        let encoded = serde_json::to_string(&cfg).unwrap();
        let mut decoded: Config = serde_json::from_str(&encoded).unwrap();
        decoded.normalize_notch();
        assert_eq!(decoded.notch_scale, 0.7);
    }
}
