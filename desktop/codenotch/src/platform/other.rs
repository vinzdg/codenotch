//! Stub so `cargo check` on macOS (and anything that is not Windows or Linux)
//! type-checks the crate. These helpers are not a third port.

use std::path::{Path, PathBuf};

pub fn default_notch_edge() -> &'static str {
    "top"
}

pub fn init() {}

pub fn drag_slides_along_edge() -> bool {
    false
}

pub fn cursor_state_db_candidates() -> Vec<PathBuf> {
    dirs::config_dir()
        .map(|c| c.join("Cursor").join("User").join("globalStorage").join("state.vscdb"))
        .into_iter()
        .collect()
}

pub fn open_path(path: &Path) {
    let _ = std::process::Command::new("open").arg(path).spawn();
}

pub fn open_url(url: &str) {
    let _ = std::process::Command::new("open").arg(url).spawn();
}

pub fn autostart_enabled() -> bool {
    false
}

pub fn autostart_enable() -> Result<String, String> {
    Err("autostart is not implemented on this OS".into())
}

pub fn autostart_disable() -> Result<String, String> {
    Ok("start at sign-in was not enabled".into())
}

pub fn system_locale() -> Option<String> {
    std::env::var("LANG").ok().and_then(|val| {
        if val.is_empty() || val == "C" || val == "POSIX" || val.starts_with("C.") {
            return None;
        }
        Some(val.split('.').next().unwrap_or(&val).replace('_', "-"))
    })
}

pub fn left_button_down() -> bool {
    false
}

pub fn session_warning() -> Option<String> {
    None
}
