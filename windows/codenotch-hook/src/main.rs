//! codenotch-hook: the minimal client Claude Code's hooks call.
//! Duties: 1) report the event plus stdin JSON to the main app; 2) launch the main app if it is not running.
//! Iron rule: never block Claude Code — ~2 s total budget, and every failure exits 0 silently.

use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::{Duration, Instant};

const TOTAL_BUDGET: Duration = Duration::from_secs(2);
const IO_TIMEOUT: Duration = Duration::from_millis(150);

const DEFAULT_PORT: u16 = 48666;
const MAX_STDIN: u64 = 256 * 1024;

fn main() {
    let event = std::env::args().nth(1).unwrap_or_else(|| "ping".into());

    // The hook's stdin is the JSON Claude Code provides (session_id / cwd / prompt / message…)
    let mut body = String::new();
    let _ = std::io::stdin().take(MAX_STDIN).read_to_string(&mut body);

    let deadline = Instant::now() + TOTAL_BUDGET;
    let ppid = parent_pid();

    if send(read_port(), &event, ppid, &body, deadline).is_ok() {
        return;
    }
    // Main app not running: launch it detached, then retry briefly
    spawn_main();
    while Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(50).min(deadline.saturating_duration_since(Instant::now())));
        if send(read_port(), &event, ppid, &body, deadline).is_ok() {
            return;
        }
    }
    // Give up quietly — never affect Claude Code
}

/// Pulls "port": N out of %APPDATA%\codenotch\config.json (hand-rolled scan, no dependency)
fn read_port() -> u16 {
    #[cfg(windows)]
    let path = std::env::var_os("APPDATA").map(|dir| std::path::PathBuf::from(dir).join("codenotch/config.json"));
    #[cfg(not(windows))]
    let path = std::env::var_os("XDG_CONFIG_HOME").filter(|dir| !dir.is_empty())
        .map(std::path::PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|dir| std::path::PathBuf::from(dir).join(".config")))
        .map(|dir| dir.join("codenotch/config.json"));
    let Some(path) = path else { return DEFAULT_PORT };
    let Ok(txt) = std::fs::read_to_string(path) else {
        return DEFAULT_PORT;
    };
    port_from_config(&txt).unwrap_or(DEFAULT_PORT)
}

fn port_from_config(txt: &str) -> Option<u16> {
    let after_key = txt.split_once("\"port\"")?.1.trim_start().strip_prefix(':')?.trim_start();
    let end = after_key.find(|c: char| !c.is_ascii_digit()).unwrap_or(after_key.len());
    let rest = after_key[end..].trim_start();
    if !rest.starts_with([',', '}']) {
        return None;
    }
    after_key[..end].parse::<u16>().ok().filter(|port| *port != 0)
}

fn timeout(deadline: Instant) -> std::io::Result<Duration> {
    let left = deadline.saturating_duration_since(Instant::now());
    if left.is_zero() {
        return Err(std::io::Error::new(std::io::ErrorKind::TimedOut, "hook deadline reached"));
    }
    Ok(left.min(IO_TIMEOUT))
}

fn send(port: u16, event: &str, ppid: u32, body: &str, deadline: Instant) -> std::io::Result<()> {
    let addr = std::net::SocketAddr::from(([127, 0, 0, 1], port));
    let mut s = TcpStream::connect_timeout(&addr, timeout(deadline)?)?;
    s.set_write_timeout(Some(timeout(deadline)?))?;
    let req = format!(
        "POST /event?e={}&ppid={} HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        event,
        ppid,
        body.len(),
        body
    );
    s.write_all(req.as_bytes())?;
    let mut buf = [0u8; 64];
    let mut count = 0;
    while count < buf.len() && !buf[..count].ends_with(b"\r\n") {
        s.set_read_timeout(Some(timeout(deadline)?))?;
        let read = s.read(&mut buf[count..count + 1])?;
        if read == 0 { break; }
        count += read;
    }
    if !buf[..count].starts_with(b"HTTP/1.1 200 ") && !buf[..count].starts_with(b"HTTP/1.0 200 ") {
        return Err(std::io::Error::other("event server did not acknowledge the event"));
    }
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
    cmd.arg("--hook-start");
    cmd.stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const DETACHED_PROCESS: u32 = 0x0000_0008;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        // DETACHED_PROCESS alone still inherits Claude's job, whose cleanup kills descendants.
        const CREATE_BREAKAWAY_FROM_JOB: u32 = 0x0100_0000;
        cmd.creation_flags(DETACHED_PROCESS | CREATE_NO_WINDOW | CREATE_BREAKAWAY_FROM_JOB);
        match cmd.spawn() {
            Ok(_) => return,
            Err(e) if e.raw_os_error() == Some(5) => {
                // Some hosts forbid breakaway. Retain auto-start there without changing their job.
                cmd.creation_flags(DETACHED_PROCESS | CREATE_NO_WINDOW);
            }
            Err(_) => return,
        }
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;

    #[test]
    fn port_parser_accepts_persisted_json_and_rejects_invalid_values() {
        assert_eq!(port_from_config("\u{feff}{\"port\": 39666, \"scale\": 1}"), Some(39666));
        for json in [r#"{"port":null,"scale":123}"#, r#"{"port":-1}"#, r#"{"port":65536}"#, r#"{"port":0}"#, r#"{"port":12.5}"#, ""] {
            assert_eq!(port_from_config(json), None, "{json}");
        }
    }

    #[test]
    fn expired_deadline_prevents_connecting() {
        assert_eq!(send(1, "ping", 0, "{}", Instant::now()).unwrap_err().kind(), std::io::ErrorKind::TimedOut);
    }

    #[test]
    fn unresponsive_listener_cannot_hold_the_hook_past_its_deadline() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        let started = Instant::now();
        assert!(send(port, "running", 0, "{}", started + Duration::from_millis(100)).is_err());
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn server_must_acknowledge_delivery() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        let peer = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
            let mut bytes = [0; 4096];
            let _ = stream.read(&mut bytes).unwrap();
            stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok").unwrap();
        });
        assert!(send(port, "running", 0, "{}", Instant::now() + TOTAL_BUDGET).is_ok());
        peer.join().unwrap();
    }
}
