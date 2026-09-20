//! Start at sign-in: an HKCU\...\Run registry value (per user, no administrator needed).
//! The command carries --silent: wait in the background, show no bar without sessions, appear when one starts.
//! Implemented with reg.exe, so no new dependency.

#[cfg(windows)]
use std::process::Command;

#[cfg(windows)]
const RUN_KEY: &str = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run";
#[cfg(windows)]
const NAME: &str = "Codenotch";

#[cfg(windows)]
fn reg(args: &[&str]) -> Option<(bool, String)> {
    let mut c = Command::new("reg");
    c.args(args);
    #[cfg(windows)]
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

#[cfg(windows)]
pub fn is_enabled() -> bool {
    reg(&["query", RUN_KEY, "/v", NAME])
        .map(|(ok, out)| ok && out.contains(NAME))
        .unwrap_or(false)
}

#[cfg(windows)]
pub fn enable() -> Result<String, String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let val = format!("\"{}\" --silent", exe.display());
    match reg(&["add", RUN_KEY, "/v", NAME, "/t", "REG_SZ", "/d", &val, "/f"]) {
        Some((true, _)) => Ok("start at sign-in enabled (silent until a session appears)".into()),
        Some((false, out)) => Err(out),
        None => Err("reg.exe failed to run".into()),
    }
}

#[cfg(windows)]
pub fn disable() -> Result<String, String> {
    match reg(&["delete", RUN_KEY, "/v", NAME, "/f"]) {
        Some((true, _)) => Ok("start at sign-in disabled".into()),
        Some((false, out)) => {
            if out.to_lowercase().contains("unable to find") || out.contains("找不到") { // reg.exe answers in the OS language; "找不到" is the Chinese "unable to find"
                Ok("start at sign-in was not enabled".into())
            } else {
                Err(out)
            }
        }
        None => Err("reg.exe failed to run".into()),
    }
}

// ---------------------------------------------------------------------------
// Linux / other unix: the XDG autostart directory. Same contract as the
// registry value on Windows — per user, no administrator rights, and the
// command carries --silent so the notch waits in the background.
// ---------------------------------------------------------------------------

#[cfg(not(windows))]
fn desktop_entry_path() -> Option<std::path::PathBuf> {
    let dir = dirs::config_dir()?.join("autostart");
    Some(dir.join("codenotch.desktop"))
}

#[cfg(not(windows))]
pub fn is_enabled() -> bool {
    desktop_entry_path().is_some_and(|p| p.is_file())
}

#[cfg(not(windows))]
pub fn enable() -> Result<String, String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let path = desktop_entry_path().ok_or("no XDG config directory")?;
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let entry = format!(
        "[Desktop Entry]\nType=Application\nName=Codenotch\nExec=\"{}\" --silent\nTerminal=false\nX-GNOME-Autostart-enabled=true\n",
        exe.display()
    );
    std::fs::write(&path, entry).map_err(|e| e.to_string())?;
    Ok("start at sign-in enabled (silent until a session appears)".into())
}

#[cfg(not(windows))]
pub fn disable() -> Result<String, String> {
    let path = desktop_entry_path().ok_or("no XDG config directory")?;
    match std::fs::remove_file(&path) {
        Ok(()) => Ok("start at sign-in disabled".into()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok("start at sign-in was not enabled".into()),
        Err(e) => Err(e.to_string()),
    }
}
