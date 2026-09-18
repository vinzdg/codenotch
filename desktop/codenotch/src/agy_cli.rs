//! Official Antigravity CLI adapter using native Windows ConPTY.
//!
//! Executes `agy --print /usage` without keeping the full Antigravity IDE running.
//! Windows direct redirected pipes historically return empty output for Antigravity;
//! this module attaches the process to a native Windows Pseudo Console (ConPTY),
//! bounded inside a Windows JobObject with cleanup of all descendant processes on exit or timeout.
//!
//! Output is drained concurrently with bounded storage (64 KB) and sanitized of
//! terminal ANSI escape codes and CR characters.

use crate::usage::{LimitWindow, UsageSnapshot};
use std::path::{Path, PathBuf};
use std::time::Duration;

#[cfg(windows)]
use std::os::windows::ffi::OsStrExt;

/// Discover installed official Antigravity CLI (`agy.exe`).
/// Checks `%LOCALAPPDATA%\agy\bin\agy.exe` and `PATH` only (only `.exe` binaries).
pub fn find_agy() -> Option<PathBuf> {
    if let Some(local) = dirs::data_local_dir() {
        let candidate = local.join("agy").join("bin").join("agy.exe");
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    if let Some(path_var) = std::env::var_os("PATH") {
        return find_agy_in(&std::env::split_paths(&path_var).filter(|p| p.is_absolute()).collect::<Vec<_>>());
    }
    None
}

/// Helper for testing discovery in explicit directories without touching environment.
fn find_agy_in(dirs: &[PathBuf]) -> Option<PathBuf> {
    for dir in dirs {
        let candidate = dir.join("agy.exe");
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

/// Strips ANSI escape sequences (CSI, OSC, 2-character escapes) and normalizes line endings.
fn sanitize_terminal_output(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut chars = input.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\x1b' {
            match chars.peek() {
                Some(&'[') => {
                    chars.next();
                    // CSI sequence: consumes parameter and intermediate bytes, ends with 0x40..=0x7E
                    while let Some(&next) = chars.peek() {
                        chars.next();
                        if ('\x40'..='\x7e').contains(&next) {
                            break;
                        }
                    }
                }
                Some(&']') => {
                    chars.next();
                    // OSC sequence: consumes until BEL (\x07) or ST (\x1b\\)
                    while let Some(next) = chars.next() {
                        if next == '\x07' {
                            break;
                        }
                        if next == '\x1b' && chars.peek() == Some(&'\\') {
                            chars.next();
                            break;
                        }
                    }
                }
                Some(&next) if ('\x40'..='\x5f').contains(&next) => {
                    // 2-character escape sequence Fe
                    chars.next();
                }
                _ => {}
            }
        } else if c == '\r' {
            if chars.peek() == Some(&'\n') {
                // CRLF -> keep \n on next iteration
                continue;
            } else {
                out.push('\n');
            }
        } else {
            out.push(c);
        }
    }
    out
}

/// Parses official Antigravity CLI quota output into `LimitWindow` items.
/// Converts remaining percentage to fraction used (used = 1.0 - remaining / 100).
/// Returns an error on invalid or unrecognized format; never returns dummy 0% quotas.
fn parse_quota(text: &str) -> Result<Vec<LimitWindow>, String> {
    let clean = sanitize_terminal_output(text);
    if !clean.lines().any(|line| line.trim() == "Quota:") {
        return Err("CLI did not return a quota report".into());
    }
    let mut out = Vec::new();
    for line in clean.lines().filter(|line| line.contains("Limit Remaining")) {
        let (left, reset) = line.rsplit_once('%').ok_or("Invalid CLI quota row")?;
        let (label, remaining_str) = left
            .trim()
            .rsplit_once(char::is_whitespace)
            .ok_or("Missing quota percentage")?;
        let remaining = remaining_str
            .parse::<f64>()
            .map_err(|_| "Invalid quota percentage")?;
        if !remaining.is_finite() || !(0.0..=100.0).contains(&remaining) {
            return Err("Quota percentage is out of range".into());
        }
        let reset = chrono::DateTime::parse_from_rfc3339(reset.trim())
            .map_err(|_| "Invalid quota reset time")?
            .timestamp_millis();
        if reset <= 0 {
            return Err("Invalid quota reset time".into());
        }
        let label = label.split_whitespace().collect::<Vec<_>>().join(" ");
        let label = label
            .strip_suffix(" Remaining")
            .ok_or("Unknown quota label")?
            .to_string();
        let short_label = label
            .replace(" Models", "")
            .replace(" models", "")
            .replace(" and ", "/")
            .replace(" Weekly Limit", " · Weekly")
            .replace(" Five Hour Limit", " · 5h");
        // Grouped by model family and named by lane, as the Mac card shows them
        let group = [" Weekly Limit", " Five Hour Limit"]
            .iter()
            .find_map(|s| label.strip_suffix(s))
            .map(String::from);
        let lane = crate::antigravity::lane_name(&label).filter(|_| group.is_some());
        out.push(LimitWindow {
            label: lane.map_or(short_label, String::from),
            group,
            id: label,
            used: ((100.0 - remaining) / 100.0).clamp(0.0, 1.0),
            resets_at: Some(reset as u64),
            ..Default::default()
        });
    }
    if out.is_empty() {
        return Err("CLI returned no recognised quota windows".into());
    }
    crate::antigravity::order_lanes(&mut out);
    Ok(out)
}

/// Atomically writes data to `dest` by writing to a temporary file in the same directory,
/// syncing data to disk, and renaming to replace destination. If any step fails, the
/// existing destination is preserved untouched.
fn atomic_write(dest: &Path, data: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent)?;
    }
    static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let id = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let file_name = dest.file_name().and_then(|n| n.to_str()).unwrap_or("cache");
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    let temp_name = format!("{file_name}.tmp.{}.{}.{}", std::process::id(), now, id);
    let temp_path = dest.with_file_name(temp_name);

    let write_and_sync = || -> std::io::Result<()> {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp_path)?;
        file.write_all(data)?;
        file.sync_all()?;
        Ok(())
    };

    if let Err(e) = write_and_sync() {
        let _ = std::fs::remove_file(&temp_path);
        return Err(e);
    }

    if let Err(e) = std::fs::rename(&temp_path, dest) {
        let _ = std::fs::remove_file(&temp_path);
        return Err(e);
    }

    Ok(())
}

/// Serializes snapshot as JSON and atomically saves to `dest`.
pub fn save_persisted_to(dest: &Path, snap: &UsageSnapshot) -> std::io::Result<()> {
    let text = serde_json::to_string_pretty(snap)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    atomic_write(dest, text.as_bytes())
}

/// Quotes a command line argument according to Windows CommandLineToArgvW rules.
fn quote_arg(arg: &str) -> String {
    if arg.is_empty() {
        return "\"\"".to_string();
    }
    if !arg.contains([' ', '\t', '\n', '\x0b', '\"']) {
        return arg.to_string();
    }
    let mut res = String::with_capacity(arg.len() + 2);
    res.push('"');
    let mut backslashes = 0;
    for c in arg.chars() {
        if c == '\\' {
            backslashes += 1;
        } else {
            for _ in 0..(if c == '"' {backslashes * 2 + 1} else {backslashes}) { res.push('\\'); }
            backslashes = 0;
            res.push(c);
        }
    }
    for _ in 0..backslashes * 2 {
        res.push('\\');
    }
    res.push('"');
    res
}

/// Spawns a hidden process connected to a native Windows ConPTY (Pseudo Console) inside a JobObject.
/// Drains up to 64 KB of stdout concurrently, enforces timeout, and cleans up all descendants.
#[cfg(windows)]
fn run_cmd_conpty(
    program: &Path,
    args: &[&str],
    cwd: Option<&Path>,
    timeout: Duration,
) -> Result<String, String> {
    use std::io::Read;
    use std::os::windows::io::FromRawHandle;
    use windows::core::{PCWSTR, PWSTR};
    use windows::Win32::Foundation::{CloseHandle, HANDLE, WAIT_OBJECT_0};
    use windows::Win32::System::Console::{
        ClosePseudoConsole, CreatePseudoConsole, COORD, HPCON,
    };
    use windows::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, SetInformationJobObject,
        TerminateJobObject, JobObjectExtendedLimitInformation,
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    };
    use windows::Win32::System::Pipes::CreatePipe;
    use windows::Win32::System::Threading::{
        CreateProcessW, DeleteProcThreadAttributeList, GetExitCodeProcess,
        InitializeProcThreadAttributeList, ResumeThread, UpdateProcThreadAttribute,
        WaitForSingleObject, CREATE_SUSPENDED,
        EXTENDED_STARTUPINFO_PRESENT, LPPROC_THREAD_ATTRIBUTE_LIST,
        PROCESS_INFORMATION, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, STARTUPINFOEXW,
        STARTF_USESTDHANDLES,
    };

    if !program.is_file() {
        return Err(format!("Program not found: {}", program.display()));
    }

    struct Job(HANDLE);
    impl Drop for Job {
        fn drop(&mut self) {
            unsafe {
                let _ = CloseHandle(self.0);
            }
        }
    }

    let job = unsafe {
        let h = CreateJobObjectW(None, PCWSTR::null())
            .map_err(|e| format!("Cannot create CLI process job: {e}"))?;
        let job = Job(h);
        let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        SetInformationJobObject(
            job.0,
            JobObjectExtendedLimitInformation,
            &limits as *const _ as *const _,
            std::mem::size_of_val(&limits) as u32,
        )
        .map_err(|e| format!("Cannot configure CLI process job limits: {e}"))?;
        job
    };

    let mut in_read = HANDLE::default();
    let mut in_write = HANDLE::default();
    let mut out_read = HANDLE::default();
    let mut out_write = HANDLE::default();

    unsafe {
        CreatePipe(&mut in_read, &mut in_write, None, 0)
            .map_err(|e| format!("CreatePipe(in) failed: {e}"))?;
        if let Err(e) = CreatePipe(&mut out_read, &mut out_write, None, 0) {
            let _ = CloseHandle(in_read);
            let _ = CloseHandle(in_write);
            return Err(format!("CreatePipe(out) failed: {e}"));
        }
    }

    let console_size = COORD { X: 160, Y: 60 };
    let hpc_res = unsafe { CreatePseudoConsole(console_size, in_read, out_write, 0) };

    unsafe {
        let _ = CloseHandle(in_read);
        let _ = CloseHandle(out_write);
    }

    let hpc = match hpc_res {
        Ok(h) => h,
        Err(e) => {
            unsafe {
                let _ = CloseHandle(in_write);
                let _ = CloseHandle(out_read);
            }
            return Err(format!("CreatePseudoConsole failed: {e}"));
        }
    };

    struct PseudoConsoleGuard(HPCON);
    impl Drop for PseudoConsoleGuard {
        fn drop(&mut self) {
            unsafe {
                ClosePseudoConsole(self.0);
            }
        }
    }
    let _input_guard = Job(in_write);
    let pty_guard = PseudoConsoleGuard(hpc);
    let mut file = unsafe { std::fs::File::from_raw_handle(out_read.0 as _) };
    let reader_thread = std::thread::spawn(move || {
        let mut buf = Vec::new();
        let mut chunk = [0u8; 4096];
        while let Ok(n) = file.read(&mut chunk) {
            if n == 0 { break; }
            let keep = n.min(65537usize.saturating_sub(buf.len()));
            buf.extend_from_slice(&chunk[..keep]);
        }
        buf
    });

    let mut attr_size = 0usize;
    let _ = unsafe {
        InitializeProcThreadAttributeList(
            LPPROC_THREAD_ATTRIBUTE_LIST(std::ptr::null_mut()),
            1,
            0,
            &mut attr_size,
        )
    };

    let mut attr_storage = vec![0u8; attr_size];
    let attr_list = LPPROC_THREAD_ATTRIBUTE_LIST(attr_storage.as_mut_ptr() as *mut _);

    struct AttrListGuard(LPPROC_THREAD_ATTRIBUTE_LIST);
    impl Drop for AttrListGuard {
        fn drop(&mut self) {
            unsafe {
                DeleteProcThreadAttributeList(self.0);
            }
        }
    }

    let _attr_guard = unsafe {
        InitializeProcThreadAttributeList(attr_list, 1, 0, &mut attr_size)
            .map_err(|e| format!("InitializeProcThreadAttributeList failed: {e}"))?;
        AttrListGuard(attr_list)
    };

    unsafe {
        UpdateProcThreadAttribute(
            attr_list,
            0,
            PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE as usize,
            Some(hpc.0 as *const core::ffi::c_void),
            std::mem::size_of::<HPCON>(),
            None,
            None,
        )
        .map_err(|e| format!("UpdateProcThreadAttribute failed: {e}"))?;
    }

    let mut cmd_line_str = quote_arg(program.to_str().unwrap_or_default());
    let program_u16: Vec<u16> = program.as_os_str().encode_wide().chain(std::iter::once(0)).collect();
    for arg in args {
        cmd_line_str.push(' ');
        cmd_line_str.push_str(&quote_arg(arg));
    }
    let mut cmd_line_u16: Vec<u16> = cmd_line_str.encode_utf16().chain(std::iter::once(0)).collect();

    let cwd_u16: Option<Vec<u16>> = cwd.map(|p| p.as_os_str().encode_wide().chain(std::iter::once(0)).collect());

    let mut si_ex = STARTUPINFOEXW::default();
    si_ex.StartupInfo.cb = std::mem::size_of::<STARTUPINFOEXW>() as u32;
    // Prevent inherited parent output handles from bypassing the pseudo console.
    si_ex.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    si_ex.lpAttributeList = attr_list;

    let mut proc_info = PROCESS_INFORMATION::default();

    let spawn_res = unsafe {
        CreateProcessW(
            PCWSTR(program_u16.as_ptr()),
            PWSTR(cmd_line_u16.as_mut_ptr()),
            None,
            None,
            false,
            EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED,
            None,
            cwd_u16.as_ref().map_or(PCWSTR::null(), |v| PCWSTR(v.as_ptr())),
            &si_ex.StartupInfo,
            &mut proc_info,
        )
    };

    if let Err(e) = spawn_res {
        return Err(format!("CreateProcessW failed: {e}"));
    }

    if unsafe { AssignProcessToJobObject(job.0, proc_info.hProcess).is_err() } {
        unsafe {
            let _ = windows::Win32::System::Threading::TerminateProcess(proc_info.hProcess, 1);
            let _ = CloseHandle(proc_info.hThread);
            let _ = CloseHandle(proc_info.hProcess);
        }
        return Err("Cannot attach CLI process to job object".into());
    }

    let resumed = unsafe {
        let result = ResumeThread(proc_info.hThread);
        let _ = CloseHandle(proc_info.hThread);
        result != u32::MAX
    };
    let _process_guard = Job(proc_info.hProcess);
    if !resumed { drop(job); return Err("Cannot resume CLI process".into()); }

    let started = std::time::Instant::now();
    let mut exit_code = 0u32;
    let mut timed_out = false;

    loop {
        let wait = unsafe { WaitForSingleObject(proc_info.hProcess, 100) };
        if wait == WAIT_OBJECT_0 {
            let _ = unsafe { GetExitCodeProcess(proc_info.hProcess, &mut exit_code) };
            break;
        }
        if started.elapsed() >= timeout {
            timed_out = true;
            unsafe {
                let _ = TerminateJobObject(job.0, 1);
            }
            break;
        }
    }

    // Stop our remaining descendants before closing their console.
    drop(job);
    drop(pty_guard);

    let raw_bytes = reader_thread
        .join()
        .map_err(|_| "CLI output reader thread panicked".to_string())?;


    if timed_out {
        return Err("Antigravity CLI quota request timed out".into());
    }

    if exit_code != 0 {
        return Err(format!("Antigravity CLI failed with exit code {exit_code}"));
    }

    if raw_bytes.len() > 65536 {
        return Err("CLI quota output is too large".into());
    }

    let text = String::from_utf8_lossy(&raw_bytes);
    Ok(sanitize_terminal_output(&text))
}

#[cfg(not(windows))]
fn run_cmd_conpty(
    _program: &Path,
    _args: &[&str],
    _cwd: Option<&Path>,
    _timeout: Duration,
) -> Result<String, String> {
    Err("Antigravity CLI runner requires Windows".into())
}

/// Executes official `agy --print /usage` via native ConPTY.
pub fn read_quota() -> Result<Vec<LimitWindow>, String> {
    let agy = find_agy().ok_or("Antigravity CLI is not installed")?;
    let dir = crate::config::config_path().with_file_name("quota-work");
    std::fs::create_dir_all(&dir).map_err(|e| format!("Cannot create CLI working directory: {e}"))?;
    let output = run_cmd_conpty(&agy, &["--sandbox", "--print-timeout", "30s", "--print", "/usage"], Some(&dir), Duration::from_secs(70))?;
    parse_quota(&output)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quoted_paths_keep_backslashes() {
        assert_eq!(quote_arg(r"C:\Program Files\agy.exe"), r#""C:\Program Files\agy.exe""#);
        assert_eq!(quote_arg("path with space\\"), "\"path with space\\\\\"");
        assert_eq!(quote_arg("a\\\"b"), "\"a\\\\\\\"b\"");
    }

    #[test]
    #[ignore = "Runs the signed-in official CLI; opt in for integration verification"]
    fn live_quota() {
        let windows = read_quota().expect("official CLI quota");
        assert!(!windows.is_empty());
        println!("Official CLI returned {} quota windows", windows.len());
    }

    #[test]
    fn test_parse_quota_official_sample_and_errors() {
        let text = "Quota:\nGemini Models Weekly Limit Remaining 94% 2026-09-12T01:47:23Z\nGemini Models Five Hour Limit Remaining 78% 2026-09-10T06:12:31Z\nClaude and GPT models Weekly Limit Remaining 100% 2026-09-17T01:47:23Z\nClaude and GPT models Five Hour Limit Remaining 100% 2026-09-10T08:13:44Z";
        let windows = parse_quota(text).expect("valid sample quota");
        assert_eq!(windows.len(), 4);

        // Grouped by model and named by lane, 5-hour first, as the Mac card shows them
        assert_eq!(windows[0].id, "Gemini Models Five Hour Limit");
        assert_eq!(windows[0].label, "5-hour Limit");
        assert_eq!(windows[0].group.as_deref(), Some("Gemini Models"));
        assert!((windows[0].used - 0.22).abs() < 1e-5);
        assert!(windows[0].resets_at.is_some());

        assert_eq!(windows[1].id, "Gemini Models Weekly Limit");
        assert_eq!(windows[1].label, "Weekly Limit");
        assert_eq!(windows[1].group.as_deref(), Some("Gemini Models"));
        assert!((windows[1].used - 0.06).abs() < 1e-5);
        assert!(windows[1].resets_at.is_some());

        assert_eq!(windows[2].id, "Claude and GPT models Five Hour Limit");
        assert_eq!(windows[2].label, "5-hour Limit");
        assert_eq!(windows[2].group.as_deref(), Some("Claude and GPT models"));
        assert_eq!(windows[2].used, 0.0);
        assert!(windows[2].resets_at.is_some());

        assert_eq!(windows[3].id, "Claude and GPT models Weekly Limit");
        assert_eq!(windows[3].label, "Weekly Limit");
        assert_eq!(windows[3].group.as_deref(), Some("Claude and GPT models"));
        assert_eq!(windows[3].used, 0.0);
        assert!(windows[3].resets_at.is_some());

        for bad in [
            "",
            "authentication required",
            "Quota:\nunknown",
            &text.replace("94%", "101%"),
            &text.replace("94%", "-5%"),
            &text.replace("94%", "NaN%"),
            &text.replace("2026-09-12T01:47:23Z", "not-a-date"),
        ] {
            assert!(parse_quota(bad).is_err());
        }
    }

    #[test]
    fn test_sanitize_terminal_output() {
        let raw = "\x1b[?25h\x1b[32mQuota:\x1b[0m\r\nGemini Models Weekly Limit Remaining 94% 2026-09-12T01:47:23Z\r\n";
        let clean = sanitize_terminal_output(raw);
        assert_eq!(
            clean,
            "Quota:\nGemini Models Weekly Limit Remaining 94% 2026-09-12T01:47:23Z\n"
        );
        let parsed = parse_quota(&clean).expect("parsed sanitized quota");
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].label, "Weekly Limit");
    }

    #[test]
    fn test_missing_cli() {
        let temp = std::env::temp_dir().join(format!("codenotch-empty-test-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&temp);
        assert_eq!(find_agy_in(std::slice::from_ref(&temp)), None);
        let _ = std::fs::remove_dir_all(&temp);

        let non_existent = PathBuf::from(r"C:\non\existent\path\agy.exe");
        #[cfg(windows)]
        {
            let res = run_cmd_conpty(&non_existent, &["--print", "/usage"], None, Duration::from_secs(5));
            assert!(res.is_err());
        }
    }

    #[test]
    fn test_atomic_write_preserves_old_on_failure() {
        let dir = std::env::temp_dir().join(format!("codenotch-atomic-test-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let dest = dir.join("antigravity.json");

        assert!(atomic_write(&dest, b"initial quota data").is_ok());
        assert_eq!(std::fs::read_to_string(&dest).unwrap(), "initial quota data");

        assert!(atomic_write(&dest, b"updated quota data").is_ok());
        assert_eq!(std::fs::read_to_string(&dest).unwrap(), "updated quota data");

        let snap = UsageSnapshot {
            status: "ok".into(),
            windows: vec![LimitWindow {
                id: "gemini_weekly".into(),
                label: "Gemini · Weekly".into(),
                used: 0.06,
                resets_at: Some(1700000000000),
                ..Default::default()
            }],
            fetched_at: 1700000000000,
            note: "via Antigravity CLI".into(),
            ..Default::default()
        };
        assert!(save_persisted_to(&dest, &snap).is_ok());
        let read_back = std::fs::read_to_string(&dest).unwrap();
        assert!(read_back.contains("Gemini · Weekly"));

        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            let lock = std::fs::OpenOptions::new()
                .read(true)
                .share_mode(0)
                .open(&dest)
                .unwrap();
            assert!(atomic_write(&dest, b"failing content").is_err());
            drop(lock);
        }
        assert_eq!(std::fs::read_to_string(&dest).unwrap(), read_back);

        let _ = std::fs::remove_file(&dest);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(windows)]
    #[test]
    fn test_bounded_runner_and_no_deadlock() {
        let cmd = std::env::var_os("ComSpec")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(r"C:\Windows\System32\cmd.exe"));
        if !cmd.is_file() {
            return;
        }

        let out = run_cmd_conpty(&cmd, &["/c", "echo hello from conpty"], None, Duration::from_secs(10))
            .expect("harmless echo command");
        assert!(out.contains("hello from conpty"));

        // Large output test: generate thousands of lines, verify no deadlock and bounded output
        let out_large = run_cmd_conpty(
            &cmd,
            &["/c", "for /L %i in (1,1,1000) do @echo 012345678901234567890123456789012345678901234567890123456789"],
            None,
            Duration::from_secs(15),
        )
        .expect("harmless large output command");
        assert!(!out_large.is_empty());
        assert!(out_large.len() <= 65536);
    }

    #[cfg(windows)]
    #[test]
    fn test_timeout_cleanup_terminates_process() {
        let cmd = std::env::var_os("ComSpec")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(r"C:\Windows\System32\cmd.exe"));
        if !cmd.is_file() {
            return;
        }

        let start = std::time::Instant::now();
        // Ping command runs for ~9 seconds; timeout is set to 400ms
        let res = run_cmd_conpty(
            &cmd,
            &["/c", "ping -n 10 127.0.0.1 >nul"],
            None,
            Duration::from_millis(400),
        );
        let elapsed = start.elapsed();
        assert!(res.is_err());
        assert!(res.unwrap_err().contains("timed out"));
        assert!(elapsed < Duration::from_secs(5));
    }
}
