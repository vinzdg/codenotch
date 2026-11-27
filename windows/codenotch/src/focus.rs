//! Jump back to the right terminal: from the session's Claude CLI process PID, walk the parent chain
//! to the hosting terminal window, then SetForegroundWindow + FlashWindowEx. Returns false on failure (the page reports it).

#[cfg(windows)]
pub fn focus_terminal(claude_pid: u32) -> bool {
    use std::collections::HashMap;
    use windows::Win32::Foundation::{BOOL, HWND, LPARAM};
    use windows::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
        TH32CS_SNAPPROCESS,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        EnumWindows, FlashWindowEx, GetWindowTextLengthW, GetWindowThreadProcessId, IsIconic,
        IsWindowVisible, SetForegroundWindow, ShowWindow, FLASHWINFO, FLASHW_ALL, SW_RESTORE,
    };

    if claude_pid == 0 {
        return false;
    }

    // 1) Full pid -> ppid snapshot
    let mut ppid_map: HashMap<u32, u32> = HashMap::new();
    unsafe {
        let Ok(snap) = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) else {
            return false;
        };
        let mut entry = PROCESSENTRY32W {
            dwSize: std::mem::size_of::<PROCESSENTRY32W>() as u32,
            ..Default::default()
        };
        if Process32FirstW(snap, &mut entry).is_ok() {
            loop {
                ppid_map.insert(entry.th32ProcessID, entry.th32ParentProcessID);
                if Process32NextW(snap, &mut entry).is_err() {
                    break;
                }
            }
        }
        let _ = windows::Win32::Foundation::CloseHandle(snap);
    }

    // 2) claude's ancestor chain (itself included), at most 8 levels: node → shell → WindowsTerminal/conhost host…
    let mut chain: Vec<u32> = vec![claude_pid];
    let mut cur = claude_pid;
    for _ in 0..8 {
        match ppid_map.get(&cur) {
            Some(&p) if p != 0 && !chain.contains(&p) => {
                chain.push(p);
                cur = p;
            }
            _ => break,
        }
    }

    // 3) Enumerate visible top-level windows
    struct Cand {
        hwnd: isize,
        pid: u32,
    }
    let mut wins: Vec<Cand> = Vec::new();
    unsafe extern "system" fn cb(hwnd: HWND, l: LPARAM) -> BOOL {
        let v = &mut *(l.0 as *mut Vec<(isize, u32)>);
        if IsWindowVisible(hwnd).as_bool() && GetWindowTextLengthW(hwnd) > 0 {
            let mut pid = 0u32;
            GetWindowThreadProcessId(hwnd, Some(&mut pid));
            v.push((hwnd.0 as isize, pid));
        }
        BOOL(1)
    }
    let mut raw: Vec<(isize, u32)> = Vec::new();
    unsafe {
        let _ = EnumWindows(Some(cb), LPARAM(&mut raw as *mut _ as isize));
    }
    for (h, p) in raw {
        wins.push(Cand { hwnd: h, pid: p });
    }

    // 4) Score: the window's PID is on the ancestor chain (higher up = the real terminal host = higher
    //    score), or the window PID's parent is on the chain (the classic conhost case).
    let score_of = |pid: u32| -> Option<usize> {
        if let Some(i) = chain.iter().position(|&c| c == pid) {
            return Some(i);
        }
        if let Some(&pp) = ppid_map.get(&pid) {
            if let Some(i) = chain.iter().position(|&c| c == pp) {
                return Some(i);
            }
        }
        None
    };
    let best = wins
        .iter()
        .filter_map(|w| score_of(w.pid).map(|s| (s, w.hwnd)))
        .max_by_key(|(s, _)| *s);

    let Some((_, hwnd_raw)) = best else {
        return false;
    };
    unsafe {
        let hwnd = HWND(hwnd_raw as *mut core::ffi::c_void);
        if IsIconic(hwnd).as_bool() {
            let _ = ShowWindow(hwnd, SW_RESTORE);
        }
        let _ = SetForegroundWindow(hwnd);
        let fi = FLASHWINFO {
            cbSize: std::mem::size_of::<FLASHWINFO>() as u32,
            hwnd,
            dwFlags: FLASHW_ALL,
            uCount: 2,
            dwTimeout: 0,
        };
        let _ = FlashWindowEx(&fi);
    }
    true
}

#[cfg(not(windows))]
pub fn focus_terminal(claude_pid: u32) -> bool {
    if claude_pid == 0 {
        return false;
    }
    let maps = proc_maps();
    let chain = chain_of(claude_pid, &maps.ppid);
    if crate::x11_util::client_windows().into_iter().any(|w| {
        pid_hits_chain(w.pid, &chain, &maps) && crate::x11_util::activate_window(w.id)
    }) {
        return true;
    }
    let out = run_quiet("wmctrl", &["-l", "-p"]);
    for line in out.lines() {
        let mut parts = line.split_whitespace();
        let id = parts.next().unwrap_or("");
        let pid: u32 = parts.nth(2).and_then(|p| p.parse().ok()).unwrap_or(0);
        if pid == 0 || id.is_empty() {
            continue;
        }
        if pid_hits_chain(pid, &chain, &maps) {
            let _ = std::process::Command::new("wmctrl")
                .args(["-i", "-a", id])
                .stdin(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .status();
            return true;
        }
    }
    false
}

#[cfg(not(windows))]
fn run_quiet(program: &str, args: &[&str]) -> String {
    std::process::Command::new(program)
        .args(args)
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default()
}

// ---------------- Process and foreground helpers shared by seen-clears-it and the desktop jump-back ----------------

#[cfg(windows)]
pub struct ProcMaps {
    pub ppid: std::collections::HashMap<u32, u32>,
    pub name: std::collections::HashMap<u32, String>, // lower-case exe name
}

#[cfg(windows)]
pub fn proc_maps() -> ProcMaps {
    use windows::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
        TH32CS_SNAPPROCESS,
    };
    let mut m = ProcMaps {
        ppid: Default::default(),
        name: Default::default(),
    };
    unsafe {
        let Ok(snap) = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) else {
            return m;
        };
        let mut e = PROCESSENTRY32W {
            dwSize: std::mem::size_of::<PROCESSENTRY32W>() as u32,
            ..Default::default()
        };
        if Process32FirstW(snap, &mut e).is_ok() {
            loop {
                m.ppid.insert(e.th32ProcessID, e.th32ParentProcessID);
                let len = e.szExeFile.iter().position(|&c| c == 0).unwrap_or(260);
                m.name.insert(
                    e.th32ProcessID,
                    String::from_utf16_lossy(&e.szExeFile[..len]).to_lowercase(),
                );
                if Process32NextW(snap, &mut e).is_err() {
                    break;
                }
            }
        }
        let _ = windows::Win32::Foundation::CloseHandle(snap);
    }
    m
}

#[cfg(windows)]
pub fn fg_pid() -> u32 {
    use windows::Win32::UI::WindowsAndMessaging::{GetForegroundWindow, GetWindowThreadProcessId};
    unsafe {
        let hwnd = GetForegroundWindow();
        if hwnd.0.is_null() {
            return 0;
        }
        let mut pid = 0u32;
        GetWindowThreadProcessId(hwnd, Some(&mut pid));
        pid
    }
}

#[cfg(windows)]
pub fn chain_of(pid: u32, ppid: &std::collections::HashMap<u32, u32>) -> Vec<u32> {
    let mut chain = vec![pid];
    let mut cur = pid;
    for _ in 0..8 {
        match ppid.get(&cur) {
            Some(&p) if p != 0 && !chain.contains(&p) => {
                chain.push(p);
                cur = p;
            }
            _ => break,
        }
    }
    chain
}

/// Whether the foreground process belongs to a session's terminal window (itself on the chain, or its parent — the conhost case)
#[cfg(windows)]
pub fn pid_hits_chain(pid: u32, chain: &[u32], maps: &ProcMaps) -> bool {
    chain.contains(&pid)
        || maps
            .ppid
            .get(&pid)
            .map(|p| chain.contains(p))
            .unwrap_or(false)
}

/// Focus the Claude desktop app's main window (the jump-back target for desktop sessions: the largest visible window whose process name contains claude)
#[cfg(windows)]
pub fn focus_claude_desktop() -> bool {
    use windows::Win32::Foundation::{BOOL, HWND, LPARAM, RECT};
    use windows::Win32::UI::WindowsAndMessaging::{
        EnumWindows, FlashWindowEx, GetWindowRect, GetWindowTextLengthW, GetWindowThreadProcessId,
        IsIconic, IsWindowVisible, SetForegroundWindow, ShowWindow, FLASHWINFO, FLASHW_ALL,
        SW_RESTORE,
    };
    let maps = proc_maps();
    unsafe extern "system" fn cb(hwnd: HWND, l: LPARAM) -> BOOL {
        let v = &mut *(l.0 as *mut Vec<(isize, u32)>);
        if IsWindowVisible(hwnd).as_bool() && GetWindowTextLengthW(hwnd) > 0 {
            let mut pid = 0u32;
            GetWindowThreadProcessId(hwnd, Some(&mut pid));
            v.push((hwnd.0 as isize, pid));
        }
        BOOL(1)
    }
    let mut wins: Vec<(isize, u32)> = Vec::new();
    unsafe {
        let _ = EnumWindows(Some(cb), LPARAM(&mut wins as *mut _ as isize));
    }
    let mut best: Option<(isize, i64)> = None;
    for (h, pid) in wins {
        let Some(name) = maps.name.get(&pid) else {
            continue;
        };
        if !name.contains("claude") || name.contains("codenotch") {
            continue;
        }
        let mut r = RECT::default();
        let area = unsafe {
            if GetWindowRect(HWND(h as *mut core::ffi::c_void), &mut r).is_ok() {
                ((r.right - r.left) as i64) * ((r.bottom - r.top) as i64)
            } else {
                0
            }
        };
        if best.map(|(_, a)| area > a).unwrap_or(true) {
            best = Some((h, area));
        }
    }
    let Some((h, _)) = best else {
        return false;
    };
    unsafe {
        let hwnd = HWND(h as *mut core::ffi::c_void);
        if IsIconic(hwnd).as_bool() {
            let _ = ShowWindow(hwnd, SW_RESTORE);
        }
        let _ = SetForegroundWindow(hwnd);
        let fi = FLASHWINFO {
            cbSize: std::mem::size_of::<FLASHWINFO>() as u32,
            hwnd,
            dwFlags: FLASHW_ALL,
            uCount: 2,
            dwTimeout: 0,
        };
        let _ = FlashWindowEx(&fi);
    }
    true
}

#[cfg(not(windows))]
pub fn focus_claude_desktop() -> bool {
    if crate::x11_util::client_windows().into_iter().any(|w| {
        let blob = format!("{} {}", w.title, w.class_name).to_lowercase();
        blob.contains("claude") && !blob.contains("codenotch") && crate::x11_util::activate_window(w.id)
    }) {
        return true;
    }
    let out = run_quiet("wmctrl", &["-l", "-p"]);
    for line in out.lines() {
        let lower = line.to_lowercase();
        if !lower.contains("claude") || lower.contains("codenotch") {
            continue;
        }
        let id = line.split_whitespace().next().unwrap_or("");
        if id.is_empty() {
            continue;
        }
        let _ = std::process::Command::new("wmctrl")
            .args(["-i", "-a", id])
            .stdin(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .status();
        return true;
    }
    false
}

// ---------------- Linux / Unix process and foreground helpers ----------------

#[cfg(not(windows))]
pub struct ProcMaps {
    pub ppid: std::collections::HashMap<u32, u32>,
    pub name: std::collections::HashMap<u32, String>,
}

#[cfg(not(windows))]
pub fn proc_maps() -> ProcMaps {
    let mut m = ProcMaps {
        ppid: Default::default(),
        name: Default::default(),
    };
    let Ok(entries) = std::fs::read_dir("/proc") else {
        return m;
    };
    for entry in entries.flatten() {
        let pid: u32 = match entry.file_name().to_string_lossy().parse() {
            Ok(p) => p,
            Err(_) => continue,
        };
        let stat = std::fs::read_to_string(entry.path().join("stat")).unwrap_or_default();
        let ppid = stat
            .split_whitespace()
            .nth(3)
            .and_then(|p| p.parse().ok())
            .unwrap_or(0);
        m.ppid.insert(pid, ppid);
        let comm = std::fs::read_to_string(entry.path().join("comm"))
            .unwrap_or_default()
            .trim()
            .to_lowercase();
        m.name.insert(pid, comm);
    }
    m
}

#[cfg(not(windows))]
pub fn fg_pid() -> u32 {
    #[cfg(unix)]
    {
        return crate::x11_util::foreground_pid();
    }
    #[cfg(not(unix))]
    {
        0
    }
}

#[cfg(not(windows))]
pub fn chain_of(pid: u32, ppid: &std::collections::HashMap<u32, u32>) -> Vec<u32> {
    let mut chain = vec![pid];
    let mut cur = pid;
    for _ in 0..8 {
        match ppid.get(&cur) {
            Some(&p) if p != 0 && !chain.contains(&p) => {
                chain.push(p);
                cur = p;
            }
            _ => break,
        }
    }
    chain
}

#[cfg(not(windows))]
pub fn pid_hits_chain(pid: u32, chain: &[u32], maps: &ProcMaps) -> bool {
    chain.contains(&pid)
        || maps
            .ppid
            .get(&pid)
            .map(|p| chain.contains(p))
            .unwrap_or(false)
}
