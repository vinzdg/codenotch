#![cfg_attr(all(not(debug_assertions), windows), windows_subsystem = "windows")]

mod autostart;
mod config;
mod doctor;
mod focus;
mod hooks_install;
mod i18n;
mod server;
mod state;
mod tray;
mod usage;
mod codex;
mod cursor;
mod antigravity;
mod glyphs;
mod activity;
mod diag;
mod watcher;

use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager};

/// Logical size of the notch window: the 70 pt pill column on the right plus room for the hover card on the left.
pub const NOTCH_W: f64 = 340.0;
/// Hand-bumped build tag, written to run.log at startup so a log can always be matched to the exe that wrote it.
pub const BUILD: &str = "r33";
pub const NOTCH_H: f64 = 460.0; // 300 clipped the card once it held three window blocks plus the session list
const COMPACT_W: f64 = 10.0;
const COMPACT_H: f64 = 88.0;

/// Tracks the actual window shell, independently from whether the hover card is visible.
static SHELL_EXPANDED: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

pub struct AppState {
    pub store: Mutex<state::Store>,
    pub cfg: Mutex<config::Config>,
    pub usage: Mutex<usage::UsageSnapshot>,
    /// Codex snapshot (same UsageSnapshot shape; status may also be none/absent)
    pub codex: Mutex<usage::UsageSnapshot>,
    pub cursor: Mutex<usage::UsageSnapshot>,
    pub antigravity: Mutex<usage::UsageSnapshot>,
    /// Provider glyph cache, collected at launch and again on a tray refresh
    pub glyphs: Mutex<std::collections::HashMap<String, glyphs::Glyph>>,
    /// Working state of the non-Claude providers (Cursor reports it; Codex and Antigravity are inferred from recent writes)
    pub activity: Mutex<Vec<activity::Activity>>,
}

#[derive(Debug, Clone, Serialize)]
struct NotchUiConfig {
    side: String,
    position: f64,
    scale: f64,
    providers: Vec<String>,
    pinned: bool,
}

impl From<&config::Config> for NotchUiConfig {
    fn from(cfg: &config::Config) -> Self {
        Self {
            side: cfg.notch_side.clone(),
            position: cfg.notch_y,
            scale: cfg.notch_scale,
            providers: cfg.visible_providers.clone(),
            pinned: cfg.notch_pinned,
        }
    }
}

fn notch_geometry(
    cfg: &config::Config,
    expanded: bool,
    monitor_position: (i32, i32),
    monitor_size: (u32, u32),
    monitor_scale: f64,
) -> ((u32, u32), (i32, i32)) {
    let (logical_w, logical_h) = if expanded || cfg.notch_pinned {
        (NOTCH_W * cfg.notch_scale, NOTCH_H * cfg.notch_scale)
    } else {
        (COMPACT_W, COMPACT_H)
    };
    let width = (logical_w * monitor_scale).round().max(1.0) as u32;
    let height = (logical_h * monitor_scale).round().max(1.0) as u32;
    let x = if cfg.notch_side == "left" {
        monitor_position.0
    } else {
        monitor_position.0 + monitor_size.0 as i32 - width as i32
    };
    let monitor_height = monitor_size.1 as i32;
    let y = (monitor_position.1 as f64 + monitor_height as f64 * cfg.notch_y.clamp(0.0, 1.0)
        - height as f64 / 2.0)
        .round() as i32;
    let y = y.clamp(
        monitor_position.1,
        monitor_position.1 + (monitor_height - height as i32).max(0),
    );
    ((width, height), (x, y))
}

#[derive(Debug, Deserialize)]
struct NotchUiUpdate {
    side: String,
    position: f64,
    scale: f64,
    providers: Vec<String>,
    pinned: bool,
}

fn resolved_lang(raw: &str) -> String {
    if raw == "auto" {
        i18n::resolve_auto().to_string()
    } else {
        raw.to_string()
    }
}

pub fn broadcast(app: &AppHandle) {
    let st = app.state::<AppState>();
    let snap = {
        let store = st.store.lock().unwrap();
        let cfg = st.cfg.lock().unwrap();
        store.snapshot(&cfg.lang, &resolved_lang(&cfg.lang), false)
    };
    let _ = app.emit("state", &snap);
}

/// Places either the full notch or its compact resting bar on the selected edge of the primary monitor.
pub fn place_notch(app: &AppHandle) {
    let Some(w) = app.get_webview_window("notch") else {
        return;
    };
    let scale = w.scale_factor().unwrap_or(1.0);
    if let Ok(Some(mon)) = w.primary_monitor() {
        let cfg = {
            let st = app.state::<AppState>();
            let cfg = st.cfg.lock().unwrap().clone();
            cfg
        };
        let expanded = cfg.notch_pinned
            || SHELL_EXPANDED.load(std::sync::atomic::Ordering::SeqCst);
        let ms = mon.scale_factor();
        let ((target_w, target_h), (x, y)) = notch_geometry(
            &cfg,
            expanded,
            (mon.position().x, mon.position().y),
            (mon.size().width, mon.size().height),
            ms,
        );
        let target = tauri::PhysicalSize::new(target_w, target_h);
        let _ = w.set_size(target);
        // Resize is asynchronous on GTK/Windows, so use the requested target rather than the
        // temporarily stale outer_size. This keeps the chosen edge fixed during expansion.
        let (ww, wh) = (target.width as i32, target.height as i32);
        let _ = w.set_position(tauri::PhysicalPosition::new(x, y));
        #[cfg(target_os = "linux")]
        {
            // GTK applies resize asynchronously. KWin clamps the first move using the old width
            // (340 px while retracting), so re-anchor after the new geometry reached X11.
            let delayed = w.clone();
            std::thread::spawn(move || {
                std::thread::sleep(std::time::Duration::from_millis(60));
                let _ = delayed.set_size(target);
                std::thread::sleep(std::time::Duration::from_millis(20));
                let _ = delayed.set_position(tauri::PhysicalPosition::new(x, y));
            });
        }
        // Placement log line: the first thing to check when the notch is not visible
        let log = config::config_path().with_file_name("run.log");
        let _ = std::fs::write(
            log,
            format!(
                "notch placed build={BUILD}: expanded={expanded} side={} scale={:.2} pos=({x},{y}) size=({ww}x{wh}) inner={:?} win_scale={scale} mon_scale={ms} monitor=({},{} {}x{})\n",
                cfg.notch_side,
                cfg.notch_scale,
                w.inner_size().map(|s| (s.width, s.height)).unwrap_or((0, 0)),
                mon.position().x,
                mon.position().y,
                mon.size().width,
                mon.size().height
            ),
        );
    }
}

/// Older entry point name still used by tray.rs
pub fn reset_bar(app: &AppHandle) {
    {
        let st = app.state::<AppState>();
        let mut c = st.cfg.lock().unwrap();
        c.notch_y = 0.5;
        config::save(&c);
    }
    place_notch(app);
}

/// Drag along the right edge. The page calls this once after a press on the pill moves more than
/// 4 px; from then on a Rust thread follows the system cursor (WebView mousemove is unreliable
/// once the window itself starts moving). Releasing the left button ends the drag and the centre
/// ratio is written back to the config.
static DRAGGING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

#[cfg(windows)]
fn left_button_down() -> bool {
    use windows::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_LBUTTON};
    unsafe { (GetAsyncKeyState(VK_LBUTTON.0 as i32) as u16 & 0x8000) != 0 }
}
#[cfg(not(windows))]
fn left_button_down() -> bool {
    false
}

#[tauri::command]
fn drag_begin(app: AppHandle) {
    if DRAGGING.swap(true, std::sync::atomic::Ordering::SeqCst) {
        return;
    }
    std::thread::spawn(move || {
        let Some(w) = app.get_webview_window("notch") else {
            DRAGGING.store(false, std::sync::atomic::Ordering::SeqCst);
            return;
        };
        let (Ok(start_cur), Ok(start_pos), Ok(size), Ok(Some(mon))) =
            (app.cursor_position(), w.outer_position(), w.outer_size(), w.primary_monitor())
        else {
            DRAGGING.store(false, std::sync::atomic::Ordering::SeqCst);
            return;
        };
        let (my, mh) = (mon.position().y, mon.size().height as i32);
        let wh = size.height as i32;
        let lo = my;
        let hi = my + (mh - wh).max(0);
        let mut last_y = start_pos.y;
        let mut moved = false;
        loop {
            if !left_button_down() {
                break;
            }
            if let Ok(cur) = app.cursor_position() {
                let ny = (start_pos.y as f64 + (cur.y - start_cur.y)).round() as i32;
                let ny = ny.clamp(lo, hi);
                if ny != last_y {
                    last_y = ny;
                    moved = true;
                    let _ = w.set_position(tauri::PhysicalPosition::new(start_pos.x, ny));
                }
            }
            std::thread::sleep(std::time::Duration::from_millis(8));
        }
        if moved {
            let ratio = ((last_y + wh / 2 - my) as f64 / mh as f64).clamp(0.0, 1.0);
            let st = app.state::<AppState>();
            let mut c = st.cfg.lock().unwrap();
            c.notch_y = ratio;
            config::save(&c);
            applog(&format!("notch drag: y={last_y} ratio={ratio:.3}"));
        }
        DRAGGING.store(false, std::sync::atomic::Ordering::SeqCst);
        let _ = app.emit("drag_end", moved);
    });
}
pub fn place_bar(app: &AppHandle) {
    place_notch(app);
}
pub fn toggle_drag(app: &AppHandle) {
    // The notch stays welded to the edge; kept as a no-op for the tray menu code path
    let _ = app;
}

pub fn apply_lang(app: &AppHandle, lang: &str) {
    {
        let st = app.state::<AppState>();
        let mut c = st.cfg.lock().unwrap();
        c.lang = lang.to_string();
        config::save(&c);
    }
    if let Some(tray) = app.tray_by_id("main") {
        if let Ok(menu) = tray::build_menu(app, lang) {
            let _ = tray.set_menu(Some(menu));
        }
    }
    broadcast(app);
}

/// The notch must never take focus: WS_EX_NOACTIVATE + WS_EX_TOOLWINDOW
#[cfg(windows)]
fn noactivate(app: &AppHandle) {
    use windows::Win32::UI::WindowsAndMessaging::{
        GetWindowLongPtrW, SetWindowLongPtrW, GWL_EXSTYLE, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW,
    };
    if let Some(w) = app.get_webview_window("notch") {
        if let Ok(h) = w.hwnd() {
            unsafe {
                let hwnd =
                    windows::Win32::Foundation::HWND(h.0 as isize as *mut core::ffi::c_void);
                let ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
                SetWindowLongPtrW(
                    hwnd,
                    GWL_EXSTYLE,
                    ex | WS_EX_NOACTIVATE.0 as isize | WS_EX_TOOLWINDOW.0 as isize,
                );
            }
        }
    }
}
#[cfg(not(windows))]
fn noactivate(_app: &AppHandle) {}

/// Wry creates its GTK WebView with a 200 × 200 size request. Without clearing that request GTK
/// refuses to shrink the containing window to the 10 × 88 resting bar.
#[cfg(target_os = "linux")]
fn allow_compact_window(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("notch") {
        let _ = w.with_webview(|webview| {
            use gtk::prelude::WidgetExt;
            webview.inner().set_size_request(1, 1);
        });
    }
}

#[cfg(not(target_os = "linux"))]
fn allow_compact_window(_app: &AppHandle) {}

// ---------------- commands ----------------

#[tauri::command]
fn get_state(state: tauri::State<AppState>) -> state::Snapshot {
    let store = state.store.lock().unwrap();
    let cfg = state.cfg.lock().unwrap();
    store.snapshot(&cfg.lang, &resolved_lang(&cfg.lang), false)
}

#[tauri::command]
fn get_notch_config(state: tauri::State<AppState>) -> NotchUiConfig {
    let cfg = state.cfg.lock().unwrap();
    NotchUiConfig::from(&*cfg)
}

#[tauri::command]
fn set_notch_config(app: AppHandle, update: NotchUiUpdate) -> NotchUiConfig {
    let ui = {
        let st = app.state::<AppState>();
        let mut cfg = st.cfg.lock().unwrap();
        cfg.notch_side = update.side;
        cfg.notch_y = update.position;
        cfg.notch_scale = update.scale;
        cfg.visible_providers = update.providers;
        cfg.notch_pinned = update.pinned;
        cfg.normalize_notch();
        config::save(&cfg);
        NotchUiConfig::from(&*cfg)
    };
    if ui.pinned {
        SHELL_EXPANDED.store(true, std::sync::atomic::Ordering::SeqCst);
    }
    place_notch(&app);
    let _ = app.emit("notch_config", &ui);
    ui
}

#[tauri::command]
fn set_shell_expanded(app: AppHandle, expanded: bool) -> bool {
    let pinned = {
        let st = app.state::<AppState>();
        let pinned = st.cfg.lock().unwrap().notch_pinned;
        pinned
    };
    let actual = expanded || pinned;
    SHELL_EXPANDED.store(actual, std::sync::atomic::Ordering::SeqCst);
    place_notch(&app);
    let _ = app.emit("shell_expanded", actual);
    actual
}

#[tauri::command]
fn get_usage(state: tauri::State<AppState>) -> usage::UsageSnapshot {
    state.usage.lock().unwrap().clone()
}

#[tauri::command]
fn refresh_usage(app: AppHandle) {
    {
        let st = app.state::<AppState>();
        let mut u = st.usage.lock().unwrap();
        u.backoff_until = 0;
    }
    usage::request_refresh();
    codex::request_refresh();
    cursor::request_refresh();
    antigravity::request_refresh();
}

#[tauri::command]
fn get_antigravity(state: tauri::State<AppState>) -> usage::UsageSnapshot {
    state.antigravity.lock().unwrap().clone()
}

#[tauri::command]
fn get_activity(state: tauri::State<AppState>) -> Vec<activity::Activity> {
    state.activity.lock().unwrap().clone()
}

#[tauri::command]
fn get_glyphs(state: tauri::State<AppState>) -> std::collections::HashMap<String, glyphs::Glyph> {
    state.glyphs.lock().unwrap().clone()
}

/// Collects the glyphs again and pushes them to the page (tray refresh, or the user just dropped in an override)
pub fn reload_glyphs(app: &AppHandle) {
    let m = glyphs::collect();
    let st = app.state::<AppState>();
    *st.glyphs.lock().unwrap() = m.clone();
    let _ = app.emit("glyphs", &m);
}

#[tauri::command]
fn open_data_dir() {
    let dir = config::config_path().parent().map(|p| p.to_path_buf()).unwrap_or_default();
    let _ = std::fs::create_dir_all(glyphs::user_dir());
    let mut cmd = std::process::Command::new("explorer");
    cmd.arg(dir.as_os_str());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000);
    }
    let _ = cmd.spawn();
}

#[tauri::command]
fn get_cursor(state: tauri::State<AppState>) -> usage::UsageSnapshot {
    state.cursor.lock().unwrap().clone()
}

#[tauri::command]
fn get_codex(state: tauri::State<AppState>) -> usage::UsageSnapshot {
    state.codex.lock().unwrap().clone()
}

/// A click on a cell opens that provider's usage page
#[tauri::command]
fn open_provider_page(provider: String) {
    let url = match provider.as_str() {
        "codex" => "https://chatgpt.com/#settings/Account",
        "cursor" => "https://cursor.com/dashboard",
        "gemini" => "https://antigravity.google",
        _ => "https://claude.ai/settings/usage",
    };
    let mut cmd = std::process::Command::new("cmd");
    cmd.args(["/C", "start", "", url]);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000);
    }
    let _ = cmd.spawn();
}

/// Card expansion state: Some(hot rectangles, in **physical pixels** relative to the window's
/// top-left as x,y,w,h) = expanded; None = collapsed. The page converts the rectangles with its
/// own devicePixelRatio before reporting them, so no scale conversion happens on this side —
/// WebView2's DPR and the window's scale_factor can disagree (see report_dpr).
static HOT: Mutex<Option<Vec<[f64; 4]>>> = Mutex::new(None);

#[tauri::command]
fn set_expanded(on: bool, rects: Option<Vec<[f64; 4]>>) {
    *HOT.lock().unwrap() = if on { Some(rects.unwrap_or_default()) } else { None };
}

/// The WebView zoom currently applied (1.0 = uncorrected)
#[cfg(windows)]
static ZOOM: Mutex<f64> = Mutex::new(1.0);

pub fn applog(line: &str) {
    use std::io::Write;
    let log = config::config_path().with_file_name("run.log");
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(log) {
        let _ = writeln!(f, "{line}");
    }
}

/// Root cause: with two monitors (150 % / 200 %) WebView2 picked a devicePixelRatio of 2.0 while
/// the window was sized for the primary monitor's 1.5, so the page was 255 CSS px wide instead of
/// the designed 340 and every coordinate conversion was off (the watchdog misfired and the card
/// flashed away). Fix: the page reports its DPR, and when it differs from the primary monitor's
/// scale, set_zoom pulls the effective DPR back to that scale, restoring the 340 px width.
#[tauri::command]
fn report_dpr(app: AppHandle, dpr: f64, w: f64, h: f64) {
    // This correction exists for WebView2 on Windows. WebKitGTK already keeps its viewport and
    // monitor scale in sync; changing its zoom can instead create resize/re-render loops.
    #[cfg(not(windows))]
    {
        let _ = app;
        applog(&format!(
            "dpr report: dpr={dpr:.3} viewport={w:.0}x{h:.0} (native WebKitGTK scaling)"
        ));
        return;
    }

    #[cfg(windows)]
    {
        let Some(win) = app.get_webview_window("notch") else {
            return;
        };
        let want = win
            .primary_monitor()
            .ok()
            .flatten()
            .map(|m| m.scale_factor())
            .unwrap_or_else(|| win.scale_factor().unwrap_or(1.0));
        let mut z = ZOOM.lock().unwrap();
        let base = if *z > 0.0 { dpr / *z } else { dpr };
        let target = if base > 0.0 { want / base } else { 1.0 };
        applog(&format!(
            "dpr report: dpr={dpr:.3} viewport={w:.0}x{h:.0} monitor_scale={want:.3} zoom_applied={:.3} -> target_zoom={target:.3}",
            *z
        ));
        // Oscillation guard: at most three corrections per process (if the DPR does not follow the zoom, stop chasing it)
        static APPLIED: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
        if (dpr - want).abs() > 0.02
            && (target - *z).abs() > 0.01
            && (0.25..=4.0).contains(&target)
            && APPLIED.fetch_add(1, std::sync::atomic::Ordering::Relaxed) < 3
        {
            match win.set_zoom(target) {
                Ok(()) => {
                    *z = target;
                    applog(&format!("dpr correction: set_zoom({target:.3}) ok"));
                }
                Err(e) => applog(&format!("dpr correction failed: {e}")),
            }
        }
    }
}

/// WebView2's mouseleave is unreliable inside a NOACTIVATE transparent window — a cursor that
/// leaves quickly often produces no WM_MOUSELEAVE, and the card stays up. Rather than trust DOM
/// events, the Rust side watches the system cursor while the card is expanded and emits
/// pointer_left once the cursor is outside; the page collapses after its 250 ms grace period.
/// "Outside the window" is not the test, though: the window has a 340×460 transparent area, so
/// the cursor is compared against the hot rectangles the page reports (pill, card, and the gap
/// between them), and two consecutive misses (300 ms) count as leaving.
#[cfg(windows)]
fn start_pointer_watchdog(app: AppHandle) {
    std::thread::spawn(move || {
        let mut miss = 0u8;
        loop {
            std::thread::sleep(std::time::Duration::from_millis(150));
            let rects = match HOT.lock().unwrap().clone() {
                Some(r) => r,
                None => {
                    miss = 0;
                    continue;
                }
            };
            let Some(w) = app.get_webview_window("notch") else { continue };
            let (Ok(pos), Ok(cur)) = (w.outer_position(), app.cursor_position()) else { continue };
            // Cursor position relative to the window's top-left, in physical pixels; the hot rectangles are physical too, so no scale conversion
            let lx = cur.x - pos.x as f64;
            let ly = cur.y - pos.y as f64;
            const PAD: f64 = 10.0;
            let in_window = w
                .outer_size()
                .map(|s| lx >= 0.0 && ly >= 0.0 && lx < s.width as f64 && ly < s.height as f64)
                .unwrap_or(true);
            let mut inside = in_window && rects.iter().any(|r| {
                lx >= r[0] - PAD && ly >= r[1] - PAD && lx < r[0] + r[2] + PAD && ly < r[1] + r[3] + PAD
            });
            // The gap between hot rectangles (pill and card) counts as inside: use the bounding box of all of them
            if !inside && in_window && rects.len() > 1 {
                let x0 = rects.iter().map(|r| r[0]).fold(f64::MAX, f64::min);
                let y0 = rects.iter().map(|r| r[1]).fold(f64::MAX, f64::min);
                let x1 = rects.iter().map(|r| r[0] + r[2]).fold(f64::MIN, f64::max);
                let y1 = rects.iter().map(|r| r[1] + r[3]).fold(f64::MIN, f64::max);
                inside = lx >= x0 && ly >= y0 && lx < x1 && ly < y1;
            }
            static LOGGED: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
            if LOGGED.fetch_add(1, std::sync::atomic::Ordering::Relaxed) < 12 {
                applog(&format!(
                    "watchdog: cursor_rel=({lx:.0},{ly:.0}) inside={inside} rects={rects:?} winpos=({},{})",
                    pos.x, pos.y
                ));
            }
            if inside {
                miss = 0;
            } else {
                miss += 1;
                if miss >= 2 {
                    miss = 0;
                    *HOT.lock().unwrap() = None;
                    let _ = app.emit("pointer_left", ());
                }
            }
        }
    });
}

/// Log channel for the page: JS writes key diagnostics into run.log (if invoke itself fails, the page reports on screen instead)
#[tauri::command]
fn log_js(msg: String) {
    applog(&format!("js: {}", msg.chars().take(600).collect::<String>()));
}

#[tauri::command]
fn open_usage_page() {
    let mut cmd = std::process::Command::new("cmd");
    cmd.args(["/C", "start", "", "https://claude.ai/settings/usage"]);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    let _ = cmd.spawn();
}

#[tauri::command]
fn focus_session(app: AppHandle, id: String) -> bool {
    let ppid = {
        let st = app.state::<AppState>();
        let store = st.store.lock().unwrap();
        store.ppid_of(&id)
    };
    match ppid {
        Some(p) => focus::focus_terminal(p),
        None => focus::focus_claude_desktop(),
    }
}

#[tauri::command]
fn dismiss_session(app: AppHandle, id: String) {
    {
        let st = app.state::<AppState>();
        let mut store = st.store.lock().unwrap();
        store.dismiss(&id);
    }
    broadcast(&app);
}

#[tauri::command]
fn set_lang(app: AppHandle, lang: String) {
    apply_lang(&app, &lang);
}

/// Seen-clears-it: looking at a session acknowledges it (engine behaviour, unchanged)
#[cfg(windows)]
fn ack_scan(app: &AppHandle) -> bool {
    let need = {
        let st = app.state::<AppState>();
        let store = st.store.lock().unwrap();
        store.has_done()
    };
    if !need {
        return false;
    }
    let fg = focus::fg_pid();
    if fg == 0 {
        return false;
    }
    let maps = focus::proc_maps();
    let fg_name = maps.name.get(&fg).cloned().unwrap_or_default();
    let fg_is_claude_desktop = fg_name.contains("claude") && !fg_name.contains("codenotch");
    let st = app.state::<AppState>();
    let mut store = st.store.lock().unwrap();
    store.ack_done(|s| {
        if s.ppid == 0 {
            fg_is_claude_desktop
        } else {
            focus::pid_hits_chain(fg, &focus::chain_of(s.ppid, &maps.ppid), &maps)
        }
    })
}
#[cfg(not(windows))]
fn ack_scan(_app: &AppHandle) -> bool {
    false
}

// ---------------- main ----------------

#[cfg(windows)]
fn attach_console() {
    use windows::Win32::System::Console::{AttachConsole, ATTACH_PARENT_PROCESS};
    unsafe {
        let _ = AttachConsole(ATTACH_PARENT_PROCESS);
    }
}
#[cfg(not(windows))]
fn attach_console() {}

/// Wayland deliberately does not expose global window/cursor coordinates and compositors are
/// free to ignore an application's absolute position request. Codenotch is an edge-pinned
/// utility, so on Linux prefer XWayland when the session provides it. Native Wayland remains the
/// fallback on Wayland-only systems and can be requested with CODENOTCH_NATIVE_WAYLAND=1.
#[cfg(target_os = "linux")]
fn configure_linux_display_backend() {
    let native_wayland = std::env::var("CODENOTCH_NATIVE_WAYLAND")
        .map(|v| matches!(v.as_str(), "1" | "true" | "yes"))
        .unwrap_or(false);
    if !native_wayland
        && std::env::var_os("WAYLAND_DISPLAY").is_some()
        && std::env::var_os("DISPLAY").is_some()
    {
        std::env::set_var("GDK_BACKEND", "x11");
    }
}

#[cfg(not(target_os = "linux"))]
fn configure_linux_display_backend() {}

fn report(r: Result<String, String>) {
    let msg = match r {
        Ok(m) => format!("OK: {m}"),
        Err(e) => format!("FAILED: {e}"),
    };
    println!("{msg}");
    let log = config::config_path().with_file_name("install.log");
    let _ = std::fs::write(log, &msg);
}

fn main() {
    // Must run before Tauri/GTK is initialized.
    configure_linux_display_backend();
    attach_console();
    let args: Vec<String> = std::env::args().collect();
    if let Some(cmd) = args.get(1) {
        match cmd.as_str() {
            "install-hooks" => {
                report(hooks_install::install());
                return;
            }
            "uninstall-hooks" => {
                report(hooks_install::uninstall());
                return;
            }
            "autostart" => {
                let r = match args.get(2).map(|s| s.as_str()) {
                    Some("on") => autostart::enable(),
                    Some("off") => autostart::disable(),
                    _ => Err("usage: codenotch.exe autostart on|off".into()),
                };
                report(r);
                return;
            }
            "doctor" => {
                let out = if args.get(2).map(|s| s.as_str()) == Some("deep") { diag::run() } else { doctor::run() };
                println!("{out}");
                let log = config::config_path().with_file_name("doctor.log");
                let _ = std::fs::write(log, &out);
                return;
            }
            _ => {}
        }
    }

    let cfg = config::load();
    let port = cfg.port;
    SHELL_EXPANDED.store(cfg.notch_pinned, std::sync::atomic::Ordering::SeqCst);

    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            // Launching a freshly built exe while the old one is still running lands here: the new
            // instance is turned away and what stays on screen is the old process. Say so loudly.
            applog(&format!("single instance: another launch was refused; the running instance is build={BUILD} — quit it from the tray first if you just rebuilt"));
            let _ = app.emit("notice", format!("Codenotch is already running ({BUILD}) — quit it from the tray before starting a new build"));
        }))
        .manage(AppState {
            store: Mutex::new(Default::default()),
            cfg: Mutex::new(cfg),
            usage: Mutex::new(usage::load_persisted()),
            codex: Mutex::new(codex::load_persisted()),
            cursor: Mutex::new(cursor::load_persisted()),
            antigravity: Mutex::new(antigravity::load_persisted()),
            glyphs: Mutex::new(Default::default()),
            activity: Mutex::new(Vec::new()),
        })
        .invoke_handler(tauri::generate_handler![
            get_state,
            get_notch_config,
            set_notch_config,
            set_shell_expanded,
            get_usage,
            get_codex,
            get_cursor,
            get_antigravity,
            get_glyphs,
            get_activity,
            open_data_dir,
            drag_begin,
            open_provider_page,
            refresh_usage,
            open_usage_page,
            set_expanded,
            report_dpr,
            log_js,
            focus_session,
            dismiss_session,
            set_lang
        ])
        .setup(move |app| {
            let handle = app.handle().clone();
            allow_compact_window(&handle);
            #[cfg(not(target_os = "linux"))]
            place_notch(&handle);
            noactivate(&handle);
            if let Some(w) = handle.get_webview_window("notch") {
                let _ = w.show();
            }
            // GTK/X11 reports 0x0 for a hidden window. Place it only after it has been realized,
            // otherwise the right-edge calculation lands one whole monitor width too far right.
            #[cfg(target_os = "linux")]
            {
                place_notch(&handle);
                applog(&format!(
                    "linux display: GDK_BACKEND={} WAYLAND_DISPLAY={} DISPLAY={}",
                    std::env::var("GDK_BACKEND").unwrap_or_else(|_| "auto".into()),
                    std::env::var("WAYLAND_DISPLAY").unwrap_or_else(|_| "unset".into()),
                    std::env::var("DISPLAY").unwrap_or_else(|_| "unset".into())
                ));
            }
            tray::setup(&handle)?;
            server::start(handle.clone(), port);
            watcher::start(handle.clone());
            usage::start(handle.clone());
            codex::start(handle.clone());
            cursor::start(handle.clone());
            antigravity::start(handle.clone());
            activity::start(handle.clone());
            // Collecting glyphs may read icon resources out of a few executables; do it off the main thread and push when done
            let gh = handle.clone();
            std::thread::spawn(move || reload_glyphs(&gh));
            // The global-coordinate watchdog is a WebView2/Win32 workaround. Native DOM pointer
            // events are reliable on WebKitGTK; Wayland returns unusable (0,0) global coordinates.
            #[cfg(windows)]
            start_pointer_watchdog(handle.clone());
            // Seen-clears-it scan
            let acker = handle.clone();
            std::thread::spawn(move || {
                activity::lower_thread_priority();
                loop {
                    std::thread::sleep(std::time::Duration::from_millis(1500));
                    if ack_scan(&acker) {
                        broadcast(&acker);
                    }
                }
            });
            // Stale session cleanup
            let sweeper = handle.clone();
            std::thread::spawn(move || loop {
                std::thread::sleep(std::time::Duration::from_secs(30));
                let changed = {
                    let st = sweeper.state::<AppState>();
                    let mut s = st.store.lock().unwrap();
                    s.sweep()
                };
                if changed {
                    broadcast(&sweeper);
                }
            });
            // Persist the config (codenotch-hook reads the port from it)
            {
                let st = handle.state::<AppState>();
                let c = st.cfg.lock().unwrap();
                config::save(&c);
            }
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("Codenotch failed to start");
}

#[cfg(test)]
mod notch_geometry_tests {
    use super::*;

    #[test]
    fn resting_bar_and_full_notch_share_the_exact_edge_and_vertical_anchor() {
        let cfg = config::Config::default();
        let monitor_position = (1920, 0);
        let monitor_size = (1920, 1080);
        let (full_size, full_pos) =
            notch_geometry(&cfg, true, monitor_position, monitor_size, 1.0);
        let (bar_size, bar_pos) =
            notch_geometry(&cfg, false, monitor_position, monitor_size, 1.0);

        assert_eq!(full_size, (279, 377));
        assert_eq!(bar_size, (10, 88));
        assert_eq!(full_pos.0 + full_size.0 as i32, 3840);
        assert_eq!(bar_pos.0 + bar_size.0 as i32, 3840);
        let full_center = full_pos.1 as f64 + full_size.1 as f64 / 2.0;
        let bar_center = bar_pos.1 as f64 + bar_size.1 as f64 / 2.0;
        assert!((full_center - bar_center).abs() <= 0.5);
    }

    #[test]
    fn left_edge_setting_keeps_both_states_on_the_same_edge() {
        let cfg = config::Config {
            notch_side: "left".into(),
            notch_y: 0.25,
            ..Default::default()
        };
        let (_, full_pos) = notch_geometry(&cfg, true, (1920, 0), (1920, 1080), 1.0);
        let (_, bar_pos) = notch_geometry(&cfg, false, (1920, 0), (1920, 1080), 1.0);
        assert_eq!(full_pos.0, 1920);
        assert_eq!(bar_pos.0, 1920);
    }
}
