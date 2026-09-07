//! codenotch-hook: the minimal client Claude Code's hooks call.
//! Duties: 1) report the event plus stdin JSON to the main app; 2) launch the main app if it is not running.
//! Iron rule: never block Claude Code — ~2 s total budget, and every failure exits 0 silently.

use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::Duration;

const DEFAULT_PORT: u16 = 48666;
const MAX_STDIN: u64 = 256 * 1024;

fn main() {
    let event = std::env::args().nth(1).unwrap_or_else(|| "ping".into());

    // The hook's stdin is the JSON Claude Code provides (session_id / cwd / prompt / message…)
    let mut body = String::new();
    let _ = std::io::stdin().take(MAX_STDIN).read_to_string(&mut body);

    let port = read_port();
    let ppid = parent_pid();

    if send(port, &event, ppid, &body).is_ok() {
        return;
    }
    // Main app not running: launch it detached, then retry briefly
    spawn_main();
    for _ in 0..20 {
        std::thread::sleep(Duration::from_millis(100));
        if send(port, &event, ppid, &body).is_ok() {
            return;
        }
    }
    // Give up quietly — never affect Claude Code
}

/// Pulls "port": N out of %APPDATA%\codenotch\config.json (hand-rolled scan, no dependency)
fn read_port() -> u16 {
    let path = match std::env::var("APPDATA") {
        Ok(a) => format!("{a}\\codenotch\\config.json"),
        Err(_) => return DEFAULT_PORT,
    };
    let Ok(txt) = std::fs::read_to_string(path) else {
        return DEFAULT_PORT;
    };
    if let Some(i) = txt.find("\"port\"") {
        let digits: String = txt[i + 6..]
            .chars()
            .skip_while(|c| !c.is_ascii_digit())
            .take_while(|c| c.is_ascii_digit())
            .collect();
        if let Ok(p) = digits.parse() {
            return p;
        }
    }
    DEFAULT_PORT
}

fn send(port: u16, event: &str, ppid: u32, body: &str) -> std::io::Result<()> {
    let addr = std::net::SocketAddr::from(([127, 0, 0, 1], port));
    let mut s = TcpStream::connect_timeout(&addr, Duration::from_millis(300))?;
    s.set_write_timeout(Some(Duration::from_millis(700)))?;
    s.set_read_timeout(Some(Duration::from_millis(700)))?;
    let req = format!(
        "POST /event?e={}&ppid={} HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        event,
        ppid,
        body.len(),
        body
    );
    s.write_all(req.as_bytes())?;
    let mut buf = [0u8; 64];
    let _ = s.read(&mut buf); // wait for a response fragment to confirm delivery; failure does not matter
    Ok(())
}

/// Launches the main app detached: no inherited handles, no window, never waits
fn spawn_main() {
    let Ok(me) = std::env::current_exe() else { return };
    let Some(dir) = me.parent() else { return };
    let exe = dir.join("codenotch.exe");
    if !exe.exists() {
        return;
    }
    let mut cmd = std::process::Command::new(exe);
    cmd.stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const DETACHED_PROCESS: u32 = 0x0000_0008;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(DETACHED_PROCESS | CREATE_NO_WINDOW);
    }
    let _ = cmd.spawn();
}

/// Parent process PID (≈ the Claude Code CLI process) via NtQueryInformationProcess, no dependency
#[cfg(windows)]
fn parent_pid() -> u32 {
    #[repr(C)]
    struct Pbi {
        exit_status: isize,
        peb: usize,
        affinity_mask: usize,
        base_priority: isize,
        unique_process_id: usize,
        inherited_from_unique_process_id: usize,
    }
    extern "system" {
        fn NtQueryInformationProcess(
            handle: isize,
            class: u32,
            info: *mut Pbi,
            len: u32,
            ret_len: *mut u32,
        ) -> i32;
    }
    unsafe {
        let mut pbi = std::mem::zeroed::<Pbi>();
        let mut ret = 0u32;
        // -1 = GetCurrentProcess()
        if NtQueryInformationProcess(
            -1,
            0,
            &mut pbi,
            std::mem::size_of::<Pbi>() as u32,
            &mut ret,
        ) == 0
        {
            return pbi.inherited_from_unique_process_id as u32;
        }
    }
    0
}

#[cfg(not(windows))]
fn parent_pid() -> u32 {
    std::os::unix::process::parent_id()
}
