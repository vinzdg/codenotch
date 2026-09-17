//! Start at sign-in. Windows: HKCU\...\Run (per user, no administrator). Linux: an XDG
//! autostart .desktop in ~/.config/autostart. The command carries --silent.

use std::path::PathBuf;
#[cfg(windows)]
use std::process::Command;

#[cfg(windows)]
const RUN_KEY: &str = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run";
#[cfg(windows)]
const NAME: &str = "Codenotch";

#[cfg(not(windows))]
const DESKTOP_NAME: &str = "codenotch.desktop";

#[cfg(windows)]
fn reg(args: &[&str]) -> Option<(bool, String)> {
    let mut c = Command::new("reg");
    c.args(args);
    {
        use std::os::windows::process::CommandExt;
        c.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    c.output().ok().map(|o| {
        let text = format!(
            "{}{}",
            String::from_utf8_lossy(&o.stdout),
            String::from_utf8_lossy(&o.stderr)
        );
        (o.status.success(), text)
    })
}

fn exe_for_autostart() -> Result<PathBuf, String> {
    crate::config::launch_path().ok_or_else(|| "cannot locate the program".into())
}

fn quote_exec(path: &std::path::Path) -> String {
    let s = path.display().to_string();
    format!("\"{}\" --silent", s.replace('\\', "\\\\").replace('"', "\\\""))
}

#[cfg(not(windows))]
fn desktop_path() -> Result<PathBuf, String> {
    let dir = dirs::config_dir()
        .ok_or_else(|| "cannot find the user config directory".to_string())?
        .join("autostart");
    Ok(dir.join(DESKTOP_NAME))
}

pub fn is_enabled() -> bool {
    #[cfg(windows)]
    {
        return reg(&["query", RUN_KEY, "/v", NAME])
            .map(|(ok, out)| ok && out.contains(NAME))
            .unwrap_or(false);
    }
    #[cfg(not(windows))]
    {
        let Ok(path) = desktop_path() else {
            return false;
        };
        let Ok(text) = std::fs::read_to_string(path) else {
            return false;
        };
        !text.lines().any(|l| {
            let t = l.trim();
            t.eq_ignore_ascii_case("Hidden=true") || t.eq_ignore_ascii_case("X-GNOME-Autostart-enabled=false")
        })
    }
}

pub fn enable() -> Result<String, String> {
    let exe = exe_for_autostart()?;
    let val = quote_exec(&exe);
    #[cfg(windows)]
    {
        match reg(&["add", RUN_KEY, "/v", NAME, "/t", "REG_SZ", "/d", &val, "/f"]) {
            Some((true, _)) => Ok("start at sign-in enabled (silent until a session appears)".into()),
            Some((false, out)) => Err(out),
            None => Err("reg.exe failed to run".into()),
        }
    }
    #[cfg(not(windows))]
    {
        let path = desktop_path()?;
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        }
        let body = format!(
            "[Desktop Entry]\nType=Application\nName=Codenotch\nComment=Usage notch for Claude, Codex, Cursor and Antigravity\nExec={val}\nTerminal=false\nX-GNOME-Autostart-enabled=true\n"
        );
        std::fs::write(&path, body).map_err(|e| e.to_string())?;
        Ok("start at sign-in enabled (silent until a session appears)".into())
    }
}

pub fn disable() -> Result<String, String> {
    #[cfg(windows)]
    {
        match reg(&["delete", RUN_KEY, "/v", NAME, "/f"]) {
            Some((true, _)) => Ok("start at sign-in disabled".into()),
            Some((false, out)) => {
                if out.to_lowercase().contains("unable to find") || out.contains("找不到") {
                    // reg.exe answers in the OS language; "找不到" is the Chinese "unable to find"
                    Ok("start at sign-in was not enabled".into())
                } else {
                    Err(out)
                }
            }
            None => Err("reg.exe failed to run".into()),
        }
    }
    #[cfg(not(windows))]
    {
        let path = desktop_path()?;
        match std::fs::remove_file(&path) {
            Ok(()) => Ok("start at sign-in disabled".into()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                Ok("start at sign-in was not enabled".into())
            }
            Err(e) => Err(e.to_string()),
        }
    }
}
