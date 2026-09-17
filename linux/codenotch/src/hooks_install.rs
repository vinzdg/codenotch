//! Merges the hook helper into ~/.claude/settings.json without overwriting the user's own hooks.
//! Identification: the command contains "codenotch-hook". A backup is written first.
//! On Linux the binary is copied to ~/.local/share/codenotch/ so an AppImage unmount cannot
//! leave Claude Code pointing at a vanished FUSE path.

use serde_json::{json, Value};
use std::path::PathBuf;

/// (Claude Code event name, whether it needs a matcher, the internal event reported to Codenotch)
const WIRING: &[(&str, bool, &str)] = &[
    ("SessionStart", false, "session_start"),
    ("UserPromptSubmit", false, "running"),
    ("PreToolUse", true, "running"),
    ("PostToolUse", true, "running"),
    ("Notification", false, "attention"),
    ("Stop", false, "done"),
    ("SessionEnd", false, "session_end"),
];

fn settings_path() -> Option<PathBuf> {
    dirs::home_dir().map(|h| h.join(".claude").join("settings.json"))
}

fn is_ours(entry: &Value) -> bool {
    entry["hooks"]
        .as_array()
        .map(|hs| {
            hs.iter().any(|h| {
                h["command"]
                    .as_str()
                    .map(|c| c.contains("codenotch-hook") || c.contains("eatbean-hook") || c.contains("pacman-hook"))
                    .unwrap_or(false)
            })
        })
        .unwrap_or(false)
}

fn load(path: &PathBuf) -> Value {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_else(|| json!({}))
}

fn backup_and_write(path: &PathBuf, root: &Value) -> Result<(), String> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    if path.exists() {
        let ts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let _ = std::fs::copy(path, path.with_extension(format!("json.codenotch-bak-{ts}")));
    }
    let txt = serde_json::to_string_pretty(root).map_err(|e| e.to_string())?;
    std::fs::write(path, txt).map_err(|e| e.to_string())
}

pub fn is_installed() -> bool {
    settings_path()
        .and_then(|p| std::fs::read_to_string(p).ok())
        .map(|t| t.contains("codenotch-hook"))
        .unwrap_or(false)
}

fn hook_bin_name() -> &'static str {
    if cfg!(windows) {
        "codenotch-hook.exe"
    } else {
        "codenotch-hook"
    }
}

fn find_bundled_hook() -> Option<PathBuf> {
    let name = hook_bin_name();
    let mut cands = Vec::new();
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            cands.push(dir.join(name));
            cands.push(dir.join("..").join("lib").join("codenotch").join(name));
            cands.push(dir.join("..").join("lib").join("Codenotch").join(name));
        }
    }
    if let Ok(appdir) = std::env::var("APPDIR") {
        let root = PathBuf::from(appdir);
        cands.push(root.join("usr").join("bin").join(name));
        cands.push(root.join("usr").join("lib").join("codenotch").join(name));
        cands.push(root.join("usr").join("lib").join("Codenotch").join(name));
    }
    cands.into_iter().find(|p| p.is_file())
}

/// Stable path Claude Code will call. Windows keeps the helper beside the app; Linux copies it
/// out of the AppImage mount.
fn install_hook_path(src: &PathBuf) -> Result<PathBuf, String> {
    #[cfg(windows)]
    {
        Ok(src.clone())
    }
    #[cfg(not(windows))]
    {
        let dest = dirs::data_local_dir()
            .ok_or("cannot find the user data directory")?
            .join("codenotch")
            .join(hook_bin_name());
        if let Some(dir) = dest.parent() {
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        }
        std::fs::copy(src, &dest).map_err(|e| format!("cannot copy hook to {}: {e}", dest.display()))?;
        use std::os::unix::fs::PermissionsExt;
        let mut perm = std::fs::metadata(&dest).map_err(|e| e.to_string())?.permissions();
        perm.set_mode(0o755);
        std::fs::set_permissions(&dest, perm).map_err(|e| e.to_string())?;
        Ok(dest)
    }
}

pub fn install() -> Result<String, String> {
    let path = settings_path().ok_or("cannot find the user directory")?;
    let bundled = find_bundled_hook().ok_or_else(|| format!("missing {}", hook_bin_name()))?;
    let hook_exe = install_hook_path(&bundled)?;
    if !hook_exe.exists() {
        return Err(format!("missing {}", hook_exe.display()));
    }

    let mut root = load(&path);
    if !root.is_object() {
        root = json!({});
    }
    if !root["hooks"].is_object() {
        root["hooks"] = json!({});
    }

    for (event, need_matcher, internal) in WIRING {
        let arr = root["hooks"][*event].as_array().cloned().unwrap_or_default();
        // Remove our own older entries first
        let mut arr: Vec<Value> = arr.into_iter().filter(|e| !is_ours(e)).collect();
        let cmd = format!("\"{}\" {}", hook_exe.display(), internal);
        let mut entry = json!({
            "hooks": [{ "type": "command", "command": cmd, "timeout": 5 }]
        });
        if *need_matcher {
            entry["matcher"] = json!("*");
        }
        arr.push(entry);
        root["hooks"][*event] = json!(arr);
    }

    backup_and_write(&path, &root)?;
    Ok(format!("wrote {} ({} events)", path.display(), WIRING.len()))
}

pub fn uninstall() -> Result<String, String> {
    let path = settings_path().ok_or("cannot find the user directory")?;
    if !path.exists() {
        return Ok("settings.json does not exist, nothing to uninstall".into());
    }
    let mut root = load(&path);
    let Some(hooks) = root["hooks"].as_object_mut() else {
        return Ok("no hooks configuration found".into());
    };
    let mut removed = 0;
    for (_, v) in hooks.iter_mut() {
        if let Some(arr) = v.as_array() {
            let filtered: Vec<Value> = arr.iter().filter(|e| !is_ours(e)).cloned().collect();
            removed += arr.len() - filtered.len();
            *v = json!(filtered);
        }
    }
    backup_and_write(&path, &root)?;
    Ok(format!("removed {removed} Codenotch hook(s)"))
}
