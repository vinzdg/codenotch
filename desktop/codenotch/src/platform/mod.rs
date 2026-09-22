//! OS-specific helpers kept in one place so providers stay unaware of Windows vs Linux.
//!
//! Windows behaviour is preserved in `windows.rs`. Linux-only discovery and XDG
//! integration live in `linux.rs`.

use std::path::{Path, PathBuf};

#[cfg(target_os = "windows")]
mod windows;
#[cfg(target_os = "linux")]
mod linux;
#[cfg(not(any(target_os = "windows", target_os = "linux")))]
mod other;

#[cfg(target_os = "windows")]
use windows as os;
#[cfg(target_os = "linux")]
use linux as os;
#[cfg(not(any(target_os = "windows", target_os = "linux")))]
use other as os;

/// Screen edge the notch pins to when the user has not chosen one yet.
pub fn default_notch_edge() -> &'static str {
    os::default_notch_edge()
}

/// Open the X11 connection (Linux) on the UI thread before any drag follows the pointer.
pub fn init() {
    os::init();
}

/// Linux slides the notch along its current edge. Windows still picks the pill up and drops it
/// onto the nearest edge, which is how that port has always moved between sides.
pub fn drag_slides_along_edge() -> bool {
    os::drag_slides_along_edge()
}

/// Cursor editor `state.vscdb`: an existing file if one is found, otherwise the
/// canonical expected path (so `present()` can keep using `is_file()`).
pub fn cursor_state_db() -> Option<PathBuf> {
    let candidates = os::cursor_state_db_candidates();
    candidates
        .iter()
        .find(|p| p.is_file())
        .cloned()
        .or_else(|| candidates.into_iter().next())
}

pub fn open_path(path: &Path) {
    os::open_path(path);
}

pub fn open_url(url: &str) {
    os::open_url(url);
}

pub fn autostart_enabled() -> bool {
    os::autostart_enabled()
}

pub fn autostart_enable() -> Result<String, String> {
    os::autostart_enable()
}

pub fn autostart_disable() -> Result<String, String> {
    os::autostart_disable()
}

/// Raw locale tag (`en-US`, `pt-BR`, `zh-TW`, …) for UI language detection.
pub fn system_locale() -> Option<String> {
    os::system_locale()
}

/// Whether the primary mouse button is currently held. Used to follow a drag
/// after the WebView reports the press: DOM mouseup is unreliable once the
/// window itself starts moving.
pub fn left_button_down() -> bool {
    os::left_button_down()
}

/// Why placement may be wrong on this session (Wayland without X11, …). None on Windows.
pub fn session_warning() -> Option<String> {
    os::session_warning()
}

#[cfg(test)]
mod tests {
    use super::cursor_state_db;

    #[test]
    fn cursor_state_db_names_the_editor_store() {
        let path = cursor_state_db().expect("a config dir exists");
        assert_eq!(path.file_name().and_then(|n| n.to_str()), Some("state.vscdb"));
        let text = path.to_string_lossy();
        assert!(
            text.contains("Cursor"),
            "editor store is Cursor/…, not the lowercase CLI dir: {text}"
        );
        assert!(
            !text.contains(".config/cursor/") && !text.contains(".config\\cursor\\"),
            "must not pick ~/.config/cursor (CLI): {text}"
        );
    }
}
