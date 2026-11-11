//! Keeps the notch in Windows' topmost z-order band for the life of the session.
//!
//! `tao` (the windowing crate under Tauri 2) only calls `SetWindowPos` when its own
//! `ALWAYS_ON_TOP` flag changes value. That flag is `true` from window creation (`tauri.conf.json`
//! sets `alwaysOnTop`), so a later `window.set_always_on_top(true)` is a no-op — it never
//! reasserts anything with the OS. The `WS_EX_TOPMOST` extended-style bit and the window's actual
//! position in the z-order can disagree: the bit can survive while the window has sunk behind
//! ordinary windows anyway. See https://github.com/vinzdg/codenotch/issues/304 for the measurement
//! that pinned this down (60 of 60 samples with the notch behind an ordinary window, style bit
//! still set) and the two-contributor diagnosis this module implements.

use tauri::{AppHandle, Manager, WebviewWindow};

/// The foreground hook has no user-data parameter, so its callback reads the application handle
/// installed when the watchdog starts. `start_watchdog` is called once during app setup.
#[cfg(windows)]
static APP: std::sync::OnceLock<AppHandle> = std::sync::OnceLock::new();

/// Avoid repeating a diagnostic while one persistent z-order excursion causes many foreground
/// events. It is reset once the notch is observed back in the topmost band.
#[cfg(windows)]
static WAS_OUT: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// The foreground callback and the slow backstop run on different threads. Serialize the complete
/// observation and reassertion so a stale callback cannot reset and log the same excursion twice.
#[cfg(windows)]
static CHECK_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// True once the notch has left the topmost band, by either failure mode the issue describes:
/// its own `WS_EX_TOPMOST` bit cleared outright, or the bit surviving while an ordinary window
/// still sits in front of it in the real z-order. A single top-to-bottom walk answers both —
/// if the notch's own bit is already clear there is nothing to enumerate for.
#[cfg(windows)]
pub fn is_out_of_topmost_band(window: &WebviewWindow) -> bool {
    use windows::Win32::Foundation::{BOOL, HWND, LPARAM};
    use windows::Win32::UI::WindowsAndMessaging::{
        EnumWindows, GetWindowLongPtrW, IsWindowVisible, GWL_EXSTYLE, WS_EX_TOPMOST,
    };

    // `window.hwnd()` comes back typed against whatever `windows` version Tauri itself pulled in,
    // which can differ from the one this crate depends on directly (see `notchmenu.rs`'s
    // `give_back` for the same workaround) — so the raw pointer is carried across as `isize` and
    // rebuilt into this crate's own `HWND` before it touches any Win32 call below.
    let Ok(raw) = window.hwnd() else { return false };
    let hwnd = HWND(raw.0 as _);

    let ex_style = unsafe { GetWindowLongPtrW(hwnd, GWL_EXSTYLE) };
    if (ex_style as u32 & WS_EX_TOPMOST.0) == 0 {
        return true;
    }

    struct State {
        target: isize,
        found: bool,
        band_broken: bool,
    }
    unsafe extern "system" fn cb(hwnd: HWND, l: LPARAM) -> BOOL {
        let state = &mut *(l.0 as *mut State);
        if !IsWindowVisible(hwnd).as_bool() {
            return BOOL(1);
        }
        if hwnd.0 as isize == state.target {
            state.found = true;
            return BOOL(0);
        }
        let ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        if (ex as u32 & WS_EX_TOPMOST.0) == 0 {
            state.band_broken = true;
            return BOOL(0);
        }
        BOOL(1)
    }
    let mut state = State {
        target: hwnd.0 as isize,
        found: false,
        band_broken: false,
    };
    unsafe {
        let _ = EnumWindows(Some(cb), LPARAM(&mut state as *mut _ as isize));
    }
    !state.found || state.band_broken
}

#[cfg(not(windows))]
pub fn is_out_of_topmost_band(_window: &WebviewWindow) -> bool {
    false
}

/// Reasserts the notch at the top of the z-order with a direct Win32 call, bypassing `tao`'s
/// diffed `set_always_on_top` entirely.
#[cfg(windows)]
pub fn reassert(window: &WebviewWindow) {
    use windows::Win32::Foundation::HWND;
    use windows::Win32::UI::WindowsAndMessaging::{
        SetWindowPos, HWND_TOPMOST, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE,
    };
    let Ok(raw) = window.hwnd() else { return };
    let hwnd = HWND(raw.0 as _);
    unsafe {
        let _ = SetWindowPos(
            hwnd,
            HWND_TOPMOST,
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
        );
    }
}

#[cfg(not(windows))]
pub fn reassert(_window: &WebviewWindow) {}

/// Catches the unusual case where another application creates a topmost window without making it
/// foreground. Foreground changes are the ordinary, event-driven path.
#[cfg(windows)]
const BACKSTOP_POLL_MS: u64 = 30_000;

/// Check only while the notch can be enumerated. A hidden window remains allocated, but
/// `is_out_of_topmost_band` deliberately skips it as not visible; checking then would therefore
/// read as permanently broken and fill `run.log` with pointless reassertions.
#[cfg(windows)]
fn check(app: &AppHandle) {
    use std::sync::atomic::Ordering::SeqCst;

    let Ok(_checking) = CHECK_LOCK.lock() else {
        return;
    };
    // Mid-carry the notch's page is empty and the overlay draws it; do not fight that.
    if crate::DRAGGING.load(SeqCst) {
        return;
    }
    let Some(window) = app.get_webview_window("notch") else {
        return;
    };
    if !window.is_visible().unwrap_or(false) {
        return;
    }
    if !is_out_of_topmost_band(&window) {
        WAS_OUT.store(false, SeqCst);
        return;
    }
    reassert(&window);
    if !WAS_OUT.swap(true, SeqCst) {
        crate::applog("topmost watchdog: notch had left the topmost band, reasserted");
    }
}

/// The callback runs on the hook thread's message queue. There is no user-data argument in
/// `WINEVENTPROC`, so the handle comes from `APP`.
#[cfg(windows)]
unsafe extern "system" fn on_foreground(
    _hook: windows::Win32::UI::Accessibility::HWINEVENTHOOK,
    _event: u32,
    _window: windows::Win32::Foundation::HWND,
    _object_id: i32,
    _child_id: i32,
    _event_thread: u32,
    _event_time: u32,
) {
    if let Some(app) = APP.get() {
        check(app);
    }
}

/// Watches foreground changes with `EVENT_SYSTEM_FOREGROUND`, which captures the normal time an
/// application changes the z-order. A 30-second backstop handles a topmost window that appears
/// without becoming foreground. Both paths share the visibility and drag gates in `check`.
#[cfg(windows)]
pub fn start_watchdog(app: AppHandle) {
    let _ = APP.set(app.clone());
    check(&app);

    std::thread::spawn(|| {
        use windows::Win32::Foundation::HMODULE;
        use windows::Win32::UI::Accessibility::{SetWinEventHook, UnhookWinEvent};
        use windows::Win32::UI::WindowsAndMessaging::{
            DispatchMessageW, GetMessageW, EVENT_SYSTEM_FOREGROUND, MSG, WINEVENT_OUTOFCONTEXT,
        };

        let hook = unsafe {
            SetWinEventHook(
                EVENT_SYSTEM_FOREGROUND,
                EVENT_SYSTEM_FOREGROUND,
                HMODULE::default(),
                Some(on_foreground),
                0,
                0,
                WINEVENT_OUTOFCONTEXT,
            )
        };
        if hook.is_invalid() {
            crate::applog("topmost watchdog: could not install foreground hook");
            return;
        }

        let mut message = MSG::default();
        while unsafe { GetMessageW(&mut message, None, 0, 0).0 } > 0 {
            unsafe { DispatchMessageW(&message) };
        }

        unsafe {
            let _ = UnhookWinEvent(hook);
        }
    });

    std::thread::spawn(move || loop {
        std::thread::sleep(std::time::Duration::from_millis(BACKSTOP_POLL_MS));
        check(&app);
    });
}

#[cfg(not(windows))]
pub fn start_watchdog(_app: AppHandle) {}
