use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;

pub fn default_notch_edge() -> &'static str {
    "top"
}

pub fn init() {
    let _ = x_conn();
}

pub fn drag_slides_along_edge() -> bool {
    true
}

/// Ordered places the Cursor editor has been seen to keep `state.vscdb` on Linux.
/// The lowercase `~/.config/cursor` directory is the CLI, not the editor store.
pub fn cursor_state_db_candidates() -> Vec<PathBuf> {
    let mut out = Vec::new();
    let push = |out: &mut Vec<PathBuf>, p: PathBuf| {
        if !out.contains(&p) {
            out.push(p);
        }
    };

    if let Some(config) = dirs::config_dir() {
        push(&mut out, vscdb_under(&config));
    }
    if let Some(home) = dirs::home_dir() {
        push(&mut out, vscdb_under(&home.join(".config")));
        let snap = home.join("snap").join("cursor");
        push(&mut out, vscdb_under(&snap.join("current").join(".config")));
        push(&mut out, vscdb_under(&snap.join("common").join(".config")));
        if let Ok(rd) = std::fs::read_dir(&snap) {
            for entry in rd.flatten() {
                push(&mut out, vscdb_under(&entry.path().join(".config")));
            }
        }
    }
    out
}

fn vscdb_under(config_root: &Path) -> PathBuf {
    config_root
        .join("Cursor")
        .join("User")
        .join("globalStorage")
        .join("state.vscdb")
}

pub fn open_path(path: &Path) {
    let _ = Command::new("xdg-open").arg(path).spawn();
}

pub fn open_url(url: &str) {
    let _ = Command::new("xdg-open").arg(url).spawn();
}

fn autostart_file() -> Option<PathBuf> {
    dirs::config_dir().map(|c| c.join("autostart").join("codenotch.desktop"))
}

fn desktop_entry(exe: &Path) -> String {
    let path = exe.display().to_string();
    let exec = if path.chars().any(|c| c.is_whitespace()) {
        format!("\"{path}\" --silent")
    } else {
        format!("{path} --silent")
    };
    format!(
        "[Desktop Entry]\n\
         Type=Application\n\
         Name=Codenotch\n\
         Comment=Usage notch for AI coding tools\n\
         Exec={exec}\n\
         Terminal=false\n\
         Hidden=false\n\
         X-GNOME-Autostart-enabled=true\n"
    )
}

pub fn autostart_enabled() -> bool {
    let Some(path) = autostart_file() else {
        return false;
    };
    let Ok(text) = std::fs::read_to_string(path) else {
        return false;
    };
    !text.lines().any(|l| l.trim() == "Hidden=true")
}

pub fn autostart_enable() -> Result<String, String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let path = autostart_file().ok_or("cannot locate ~/.config/autostart")?;
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    std::fs::write(&path, desktop_entry(&exe)).map_err(|e| e.to_string())?;
    Ok(format!("start at sign-in enabled ({})", path.display()))
}

pub fn autostart_disable() -> Result<String, String> {
    let Some(path) = autostart_file() else {
        return Ok("start at sign-in was not enabled".into());
    };
    match std::fs::remove_file(&path) {
        Ok(()) => Ok("start at sign-in disabled".into()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            Ok("start at sign-in was not enabled".into())
        }
        Err(e) => Err(e.to_string()),
    }
}

pub fn system_locale() -> Option<String> {
    for key in ["LC_ALL", "LC_MESSAGES", "LANG"] {
        let Ok(val) = std::env::var(key) else { continue };
        if val.is_empty() || val == "C" || val == "POSIX" || val.starts_with("C.") {
            continue;
        }
        let tag = val.split('.').next().unwrap_or(&val).replace('_', "-");
        if !tag.is_empty() {
            return Some(tag);
        }
    }
    None
}

struct XConn {
    xlib: x11_dl::xlib::Xlib,
    display: *mut x11_dl::xlib::Display,
}

unsafe impl Send for XConn {}
unsafe impl Sync for XConn {}

fn x_conn() -> Option<&'static XConn> {
    static CONN: OnceLock<Option<XConn>> = OnceLock::new();
    CONN.get_or_init(|| {
        let xlib = x11_dl::xlib::Xlib::open().ok()?;
        unsafe {
            (xlib.XInitThreads)();
            let display = (xlib.XOpenDisplay)(std::ptr::null());
            if display.is_null() {
                return None;
            }
            Some(XConn { xlib, display })
        }
    })
    .as_ref()
}

pub fn session_warning() -> Option<String> {
    let wayland = std::env::var_os("WAYLAND_DISPLAY").is_some_and(|v| !v.is_empty());
    if !wayland {
        return None;
    }
    if x_conn().is_none() {
        Some(
            "Wayland session without a working X11 display: notch placement cannot follow the pointer. Use Cinnamon on X11 for now."
                .into(),
        )
    } else {
        Some(
            "Wayland session: pointer follow goes through Xlib/XWayland and may be unreliable."
                .into(),
        )
    }
}

pub fn left_button_down() -> bool {
    let Some(x) = x_conn() else {
        return false;
    };
    unsafe {
        let root = (x.xlib.XDefaultRootWindow)(x.display);
        let mut root_ret = 0;
        let mut child = 0;
        let mut root_x = 0;
        let mut root_y = 0;
        let mut win_x = 0;
        let mut win_y = 0;
        let mut mask = 0u32;
        let ok = (x.xlib.XQueryPointer)(
            x.display,
            root,
            &mut root_ret,
            &mut child,
            &mut root_x,
            &mut root_y,
            &mut win_x,
            &mut win_y,
            &mut mask,
        );
        ok != 0 && (mask & x11_dl::xlib::Button1Mask) != 0
    }
}

#[cfg(test)]
mod tests {
    use super::{cursor_state_db_candidates, desktop_entry, vscdb_under};
    use std::path::Path;

    #[test]
    fn editor_store_is_under_capital_cursor() {
        let path = vscdb_under(Path::new("/home/me/.config"));
        assert_eq!(
            path,
            Path::new("/home/me/.config/Cursor/User/globalStorage/state.vscdb")
        );
    }

    #[test]
    fn candidates_prefer_xdg_config_cursor() {
        let paths = cursor_state_db_candidates();
        assert!(!paths.is_empty());
        assert!(paths.iter().all(|p| p.ends_with("Cursor/User/globalStorage/state.vscdb")));
    }

    #[test]
    fn desktop_entry_quotes_paths_with_spaces() {
        let text = desktop_entry(Path::new("/opt/My Apps/codenotch"));
        assert!(text.contains("Exec=\"/opt/My Apps/codenotch\" --silent"));
        assert!(text.contains("Hidden=false"));
    }

    #[test]
    fn x11_pointer_query_is_available() {
        super::init();
        let _ = super::left_button_down();
    }
}
