//! User-initiated sign-in through the standalone Claude Code CLI. OAuth stays in
//! the CLI: no codes, tokens, browser URLs or credential writes cross widget IPC.
use serde::Serialize;
use std::{process::{Child, Command, Stdio}, sync::{atomic::{AtomicBool, Ordering}, Mutex}, time::{Duration, Instant}};

static BUSY: AtomicBool = AtomicBool::new(false);
static MESSAGE: Mutex<String> = Mutex::new(String::new());

/// The lock guards one short line of status text. A panic while it is held would
/// poison it and take the whole card down with `unwrap`, which is a steep price
/// for a string nobody has to trust — so take it back and carry on.
fn message() -> std::sync::MutexGuard<'static, String> {
    MESSAGE.lock().unwrap_or_else(|e| e.into_inner())
}

#[derive(Serialize)]
pub struct AuthState { pub busy: bool, pub message: String }

pub fn state() -> AuthState {
    AuthState { busy: BUSY.load(Ordering::Acquire), message: message().clone() }
}

/// Shared with background renewal so the two native clients cannot rotate the
/// same credential at once. Drop also releases the gate on spawn/error paths.
pub struct AuthGuard;
pub fn try_acquire() -> Option<AuthGuard> {
    BUSY.compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire).ok().map(|_| AuthGuard)
}
impl Drop for AuthGuard {
    fn drop(&mut self) { BUSY.store(false, Ordering::Release); }
}

pub fn usage_succeeded() {
    if !BUSY.load(Ordering::Acquire) { message().clear(); }
}

// No interpolated shell input: even paths containing apostrophes arrive in env.
const LOGIN_SCRIPT: &str = "$Host.UI.RawUI.WindowTitle = 'Codenotch - Claude sign-in'; Write-Host 'Complete sign-in in your browser. Paste any code in this window.'; & $env:CODENOTCH_CLAUDE_CLI auth login --claudeai; $loginResult = $LASTEXITCODE; if ($loginResult -eq 0) { Write-Host 'Sign-in complete. Codenotch will refresh automatically.'; Start-Sleep -Seconds 2 } else { Write-Host 'Sign-in failed or cancelled. Retry from Codenotch.'; Start-Sleep -Seconds 8 }; exit $loginResult";

fn login_command(cli: &std::path::Path) -> Result<Command, String> {
    let root = std::env::var_os("SystemRoot").ok_or("Windows directory unavailable.")?;
    let mut cmd = Command::new(std::path::PathBuf::from(root).join("System32/WindowsPowerShell/v1.0/powershell.exe"));
    cmd.args(["-NoLogo", "-NoProfile", "-Command", LOGIN_SCRIPT]).env("CODENOTCH_CLAUDE_CLI", cli);
    cmd.current_dir(dirs::home_dir().ok_or("Home directory unavailable.")?);
    // A widget launched inside a Claude session must not inherit that session's
    // auth or take the headless refresh-token login branch instead of the browser.
    for (key, _) in std::env::vars_os() {
        let k = key.to_string_lossy();
        if k == "CLAUDECODE" || k.starts_with("CLAUDE_CODE_")
            || matches!(k.as_ref(), "CLAUDE_CONFIG_DIR" | "ANTHROPIC_API_KEY" | "ANTHROPIC_AUTH_TOKEN") {
            cmd.env_remove(&key);
        }
    }
    #[cfg(windows)] {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0000_0010); // visible console only after a user's click
    }
    Ok(cmd)
}

fn terminate(child: &mut Child) {
    #[cfg(windows)] {
        use std::os::windows::process::CommandExt;
        if let Some(root) = std::env::var_os("SystemRoot") {
            // A .cmd CLI may have node children: terminate only this owned tree.
            let _ = Command::new(std::path::PathBuf::from(root).join("System32/taskkill.exe"))
                .args(["/PID", &child.id().to_string(), "/T", "/F"])
                .creation_flags(0x0800_0000).stdout(Stdio::null()).stderr(Stdio::null()).status();
        }
    }
    let _ = child.kill();
    let _ = child.wait();
}

fn wait_child(child: &mut Child, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return status.success(),
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(250)),
            _ => { terminate(child); return false; }
        }
    }
}

pub fn start_login() -> Result<(), String> {
    let cli = crate::usage::find_cli().ok_or("Claude Code CLI not found. Install the standalone CLI first.")?;
    let guard = try_acquire().ok_or("Claude sign-in or renewal is already running.")?;
    let mut cmd = login_command(&cli)?;
    let mut child = cmd.spawn().map_err(|_| "Unable to open Claude sign-in window.")?;
    *message() = "Complete sign-in in the browser or terminal window.".into();
    std::thread::spawn(move || {
        let ok = wait_child(&mut child, Duration::from_secs(15 * 60));
        *message() = if ok { "Sign-in complete. Refreshing usage..." } else {
            "Sign-in cancelled, failed or timed out. Try again."
        }.into();
        drop(guard);
        crate::usage::request_refresh();
    });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn gate_excludes_login_and_renewal_and_releases_on_drop() {
        let guard = try_acquire().unwrap();
        assert!(try_acquire().is_none());
        assert!(state().busy);
        drop(guard);
        assert!(!state().busy);
        assert!(try_acquire().is_some());
    }
    #[test]
    #[cfg(windows)]
    fn paths_are_data_not_shell_source() {
        let path = std::path::Path::new(r"C:\fixture with spaces\O'Brien\claude.cmd");
        let cmd = login_command(path).unwrap();
        assert!(cmd.get_args().all(|arg| !arg.to_string_lossy().contains("O'Brien")));
        assert!(cmd.get_envs().any(|(k,v)| k == "CODENOTCH_CLAUDE_CLI" && v == Some(path.as_os_str())));
    }
    #[test]
    #[cfg(windows)]
    fn failed_exit_and_timeout_are_reaped() {
        use std::os::windows::process::CommandExt;
        let root = std::path::PathBuf::from(std::env::var_os("SystemRoot").unwrap());
        let shell = root.join("System32/WindowsPowerShell/v1.0/powershell.exe");
        let mut child = Command::new(&shell)
            .args(["-NoProfile", "-NonInteractive", "-Command", "exit 7"]).creation_flags(0x0800_0000).spawn().unwrap();
        assert!(!wait_child(&mut child, Duration::from_secs(5)));
        let mut child = Command::new(&shell)
            .args(["-NoProfile", "-NonInteractive", "-Command", "exit 0"]).creation_flags(0x0800_0000).spawn().unwrap();
        assert!(wait_child(&mut child, Duration::from_secs(5)));
        let mut child = Command::new(root.join("System32/WindowsPowerShell/v1.0/powershell.exe"))
            .args(["-NoProfile", "-Command", "Start-Sleep -Seconds 30"])
            .creation_flags(0x0800_0000).spawn().unwrap();
        let start = Instant::now();
        assert!(!wait_child(&mut child, Duration::from_millis(300)));
        assert!(start.elapsed() < Duration::from_secs(5));
        assert!(child.try_wait().unwrap().is_some());
    }
}
