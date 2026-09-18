use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;

const CREATE_NO_WINDOW: u32 = 0x0800_0000;
const RUN_KEY: &str = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run";
const AUTOSTART_NAME: &str = "Codenotch";

pub fn default_notch_edge() -> &'static str {
    "right"
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
    let mut cmd = Command::new("explorer");
    cmd.arg(path.as_os_str()).creation_flags(CREATE_NO_WINDOW);
    let _ = cmd.spawn();
}

pub fn open_url(url: &str) {
    let mut cmd = Command::new("cmd");
    cmd.args(["/C", "start", "", url]).creation_flags(CREATE_NO_WINDOW);
    let _ = cmd.spawn();
}

fn reg(args: &[&str]) -> Option<(bool, String)> {
    Command::new("reg")
        .args(args)
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .ok()
        .map(|o| {
            let text = format!(
                "{}{}",
                String::from_utf8_lossy(&o.stdout),
                String::from_utf8_lossy(&o.stderr)
            );
            (o.status.success(), text)
        })
}

pub fn autostart_enabled() -> bool {
    reg(&["query", RUN_KEY, "/v", AUTOSTART_NAME])
        .map(|(ok, out)| ok && out.contains(AUTOSTART_NAME))
        .unwrap_or(false)
}

pub fn autostart_enable() -> Result<String, String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let val = format!("\"{}\" --silent", exe.display());
    match reg(&["add", RUN_KEY, "/v", AUTOSTART_NAME, "/t", "REG_SZ", "/d", &val, "/f"]) {
        Some((true, _)) => Ok("start at sign-in enabled (silent until a session appears)".into()),
        Some((false, out)) => Err(out),
        None => Err("reg.exe failed to run".into()),
    }
}

pub fn autostart_disable() -> Result<String, String> {
    match reg(&["delete", RUN_KEY, "/v", AUTOSTART_NAME, "/f"]) {
        Some((true, _)) => Ok("start at sign-in disabled".into()),
        Some((false, out)) => {
            if out.to_lowercase().contains("unable to find") || out.contains("找不到") {
                Ok("start at sign-in was not enabled".into())
            } else {
                Err(out)
            }
        }
        None => Err("reg.exe failed to run".into()),
    }
}

pub fn system_locale() -> Option<String> {
    unsafe {
        use windows::Win32::Globalization::GetUserDefaultLocaleName;
        let mut buf = [0u16; 85];
        let n = GetUserDefaultLocaleName(&mut buf);
        if n > 0 {
            Some(String::from_utf16_lossy(&buf[..(n as usize - 1)]).to_lowercase())
        } else {
            None
        }
    }
}

pub fn left_button_down() -> bool {
    use windows::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_LBUTTON};
    unsafe { (GetAsyncKeyState(VK_LBUTTON.0 as i32) as u16 & 0x8000) != 0 }
}
