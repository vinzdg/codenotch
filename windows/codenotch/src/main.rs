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
mod traymenu;
mod usage;
mod codex;
mod cursor;
mod grok;
mod antigravity;
mod agy_cli;
mod glyphs;
mod trayicon;
mod activity;
mod diag;
mod watcher;
mod settings_window;

use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager};

/// Logical size of the notch window: the 70 pt pill column on the right plus room for the hover card
/// and its tail on the left. `fitZoom` in ui/notch.html divides by the same width.
pub const NOTCH_W: f64 = 360.0;
/// Hand-bumped build tag, written to run.log at startup so a log can always be matched to the exe that wrote it.
pub const BUILD: &str = "r31";
pub const NOTCH_H: f64 = 520.0; // 300 clipped the card once it held three window blocks plus the session list; 460 clipped Antigravity's two model groups once the reading was stale and an agent was working

pub struct AppState {
    pub store: Mutex<state::Store>,
    pub cfg: Mutex<config::Config>,
    pub usage: Mutex<usage::UsageSnapshot>,
    /// Codex snapshot (same UsageSnapshot shape; status may also be none/absent)
    pub codex: Mutex<usage::UsageSnapshot>,
    pub cursor: Mutex<usage::UsageSnapshot>,
    /// Grok Build credits, read from the Grok CLI's own session
    pub grok: Mutex<usage::UsageSnapshot>,
    pub antigravity: Mutex<usage::UsageSnapshot>,
    /// Provider glyph cache, collected at launch and again on a tray refresh
    pub glyphs: Mutex<std::collections::HashMap<String, glyphs::Glyph>>,
    /// Working state of the non-Claude providers (Cursor reports it; Codex and Antigravity are inferred from recent writes)
    pub activity: Mutex<Vec<activity::Activity>>,
}

fn resolved_lang(raw: &str) -> String {
    if raw == "auto" {
        i18n::resolve_auto().to_string()
    } else {
        raw.to_string()
    }
}

/// The notch size chosen in Settings: Small, Medium or Large, as a multiple of the designed size.
pub fn ui_scale(app: &AppHandle) -> f64 {
    let st = app.state::<AppState>();
    let c = st.cfg.lock().unwrap();
    config::snap_scale(c.scale)
}

pub fn broadcast(app: &AppHandle) {
    let st = app.state::<AppState>();
    let snap = {
        let store = st.store.lock().unwrap();
        let cfg = st.cfg.lock().unwrap();
        store.snapshot(&cfg.lang, &resolved_lang(&cfg.lang), i18n::clock_24h(), false)
    };
    let _ = app.emit("state", &snap);
}

/// A monitor reduced to the numbers placement needs, so the borrowed `Monitor` does not have to be
/// held across the config lock.
#[derive(Clone, Debug)]
pub struct Screen {
    pub name: Option<String>,
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
    pub scale: f64,
}

impl Screen {
    fn of(m: &tauri::window::Monitor) -> Self {
        Self {
            name: m.name().cloned(),
            x: m.position().x,
            y: m.position().y,
            w: m.size().width as i32,
            h: m.size().height as i32,
            scale: m.scale_factor(),
        }
    }
    fn contains(&self, x: i32, y: i32) -> bool {
        x >= self.x && x < self.x + self.w && y >= self.y && y < self.y + self.h
    }
}

/// Every attached monitor, primary first so a stale name always falls back to something sensible.
pub fn screens(app: &AppHandle) -> Vec<Screen> {
    let Some(w) = app.get_webview_window("notch") else {
        return Vec::new();
    };
    let primary = w.primary_monitor().ok().flatten().map(|m| Screen::of(&m));
    let mut out: Vec<Screen> = Vec::new();
    if let Some(p) = primary.clone() {
        out.push(p);
    }
    if let Ok(all) = w.available_monitors() {
        for m in all {
            let s = Screen::of(&m);
            if !out.iter().any(|o| o.name == s.name && o.x == s.x && o.y == s.y) {
                out.push(s);
            }
        }
    }
    out
}

/// The monitor the notch should sit on: the configured one while it is still attached, else primary.
fn target_screen(app: &AppHandle) -> Option<Screen> {
    let want = {
        let st = app.state::<AppState>();
        let c = st.cfg.lock().unwrap();
        c.notch_monitor.clone()
    };
    let list = screens(app);
    if let Some(name) = want {
        if let Some(s) = list.iter().find(|s| s.name.as_deref() == Some(name.as_str())) {
            return Some(s.clone());
        }
    }
    list.into_iter().next()
}

/// The window's top-left corner for an edge, a position ratio along it and a measured window size.
/// `ratio` is the *centre* of the notch along the edge, so 0.5 is the middle whatever the size.
fn edge_origin(s: &Screen, edge: &str, ww: i32, wh: i32, ratio: f64) -> (i32, i32) {
    let along = |span: i32, len: i32| -> i32 {
        let v = (span as f64 * ratio - len as f64 / 2.0).round() as i32;
        v.clamp(0, (span - len).max(0))
    };
    match edge {
        "left" => (s.x, s.y + along(s.h, wh)),
        "top" => (s.x + along(s.w, ww), s.y),
        "bottom" => (s.x + along(s.w, ww), s.y + s.h - wh),
        _ => (s.x + s.w - ww, s.y + along(s.h, wh)),
    }
}

/// Pins the notch to the configured edge of the configured monitor.
/// The notch window's logical size for an edge.
///
/// Upright on the left and right, the pill is a column and 360 wide is plenty. Lying flat on the
/// top and bottom it is a row: five 56 px rings, their gaps, the padding and both fillets already
/// come to about 424 px, so a 360 px window clipped the pill once a fifth provider was on. The
/// flat window keeps the full height too, for the hover card that opens below or above the pill.
pub fn notch_window_size(edge: &str) -> (f64, f64) {
    if config::edge_is_vertical(edge) {
        (NOTCH_W, NOTCH_H)
    } else {
        (NOTCH_H, NOTCH_H)
    }
}

pub fn place_notch(app: &AppHandle) {
    let Some(w) = app.get_webview_window("notch") else {
        return;
    };
    let scale = w.scale_factor().unwrap_or(1.0);
    if let Some(mon) = target_screen(app) {
        // Two monitors at different scales (150 % and 200 % in practice): the physical size can
        // end up converted with the *other* monitor's scale factor depending on where the window
        // is created and then moved, leaving the WebView ~256 logical px wide instead of 340.
        // So the physical size is pinned straight from mon.scale_factor() before placing the
        // window; if it still reports a different scale afterwards, it is pinned once more.
        let ms = mon.scale;
        let size = ui_scale(app);
        // Read here, not with the ratio below, because the window's shape depends on it.
        let edge = {
            let st = app.state::<AppState>();
            let c = st.cfg.lock().unwrap();
            config::edge_or_right(&c.notch_edge)
        };
        let (width, height) = notch_window_size(&edge);
        let target = tauri::PhysicalSize::new((width * ms * size).round() as u32, (height * ms * size).round() as u32);
        let _ = w.set_size(target);
        zoom_notch(&w, ms, size);
        // Position from the window's measured physical size — deriving it from the scale factor
        // pushed the window past the right edge at 125 % / 150 % (the ring's right side was clipped).
        let (ww, wh) = w
            .outer_size()
            .map(|s| (s.width as i32, s.height as i32))
            .unwrap_or((target.width as i32, target.height as i32));
        // The position along the edge comes from the config (it persists across a drag)
        let ratio = {
            let st = app.state::<AppState>();
            let c = st.cfg.lock().unwrap();
            c.notch_y.clamp(0.0, 1.0)
        };
        let (x, y) = edge_origin(&mon, &edge, ww, wh, ratio);
        let _ = w.set_position(tauri::PhysicalPosition::new(x, y));
        if w.outer_size().map(|s| s.width != target.width).unwrap_or(false) {
            let _ = w.set_size(target);
            let (x, y) = edge_origin(&mon, &edge, target.width as i32, target.height as i32, ratio);
            let _ = w.set_position(tauri::PhysicalPosition::new(x, y));
        }
        // The page mirrors itself for the edge it is on; it cannot know that on its own.
        let _ = w.emit("notch_edge", &edge);
        // Placement log line: the first thing to check when the notch is not visible
        let log = config::config_path().with_file_name("run.log");
        let _ = std::fs::write(
            log,
            format!(
                "notch placed build={BUILD}: edge={edge} pos=({x},{y}) size=({ww}x{wh}) inner={:?} win_scale={scale} mon_scale={ms} notch_size={size} monitor={:?}=({},{} {}x{})\n",
                w.inner_size().map(|s| (s.width, s.height)).unwrap_or((0, 0)),
                mon.name,
                mon.x,
                mon.y,
                mon.w,
                mon.h
            ),
        );
    }
}

/// Older entry point name still used by tray.rs. Recentre also brings the notch back to the primary
/// monitor's right edge: a notch lost on a screen that has since been unplugged is exactly what this
/// button is for, so the monitor choice has to go with the position.
pub fn reset_bar(app: &AppHandle) {
    {
        let st = app.state::<AppState>();
        let mut c = st.cfg.lock().unwrap();
        c.notch_y = 0.5;
        c.notch_edge = "right".into();
        c.notch_monitor = None;
        config::save(&c);
    }
    place_notch(app);
}

/// Drag. The page calls this once after a press on the pill moves more than 4 px; from then on a
/// Rust thread follows the system cursor (WebView mousemove is unreliable once the window itself
/// starts moving). The window is free in both axes while the button is down; releasing it snaps the
/// notch to the nearest edge of whichever monitor it was dropped on, and that edge, that monitor and
/// the position along the edge are written back to the config.
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
        let (Ok(start_cur), Ok(start_pos), Ok(size)) = (app.cursor_position(), w.outer_position(), w.outer_size()) else {
            DRAGGING.store(false, std::sync::atomic::Ordering::SeqCst);
            return;
        };
        let all = screens(&app);
        if all.is_empty() {
            DRAGGING.store(false, std::sync::atomic::Ordering::SeqCst);
            return;
        }
        let (ww, wh) = (size.width as i32, size.height as i32);
        // The whole desktop, so the window can be carried across monitors before it is dropped
        let (vx0, vy0) = (all.iter().map(|s| s.x).min().unwrap(), all.iter().map(|s| s.y).min().unwrap());
        let (vx1, vy1) = (
            all.iter().map(|s| s.x + s.w).max().unwrap(),
            all.iter().map(|s| s.y + s.h).max().unwrap(),
        );
        let (mut last_x, mut last_y) = (start_pos.x, start_pos.y);
        let mut moved = false;
        loop {
            if !left_button_down() {
                break;
            }
            if let Ok(cur) = app.cursor_position() {
                let nx = ((start_pos.x as f64 + (cur.x - start_cur.x)).round() as i32).clamp(vx0, (vx1 - ww).max(vx0));
                let ny = ((start_pos.y as f64 + (cur.y - start_cur.y)).round() as i32).clamp(vy0, (vy1 - wh).max(vy0));
                if nx != last_x || ny != last_y {
                    last_x = nx;
                    last_y = ny;
                    moved = true;
                    let _ = w.set_position(tauri::PhysicalPosition::new(nx, ny));
                }
            }
            std::thread::sleep(std::time::Duration::from_millis(8));
        }
        if moved {
            // Dropped: the monitor under the window's centre owns it, and the nearest of that
            // monitor's four edges is where it snaps back to.
            let (cx, cy) = (last_x + ww / 2, last_y + wh / 2);
            let mon = all
                .iter()
                .find(|s| s.contains(cx, cy))
                .cloned()
                .unwrap_or_else(|| all[0].clone());
            let d = [
                ("left", (cx - mon.x).max(0)),
                ("right", (mon.x + mon.w - cx).max(0)),
                ("top", (cy - mon.y).max(0)),
                ("bottom", (mon.y + mon.h - cy).max(0)),
            ];
            let edge = d.iter().min_by_key(|(_, v)| *v).map(|(e, _)| *e).unwrap_or("right");
            let ratio = if config::edge_is_vertical(edge) {
                ((cy - mon.y) as f64 / mon.h.max(1) as f64).clamp(0.0, 1.0)
            } else {
                ((cx - mon.x) as f64 / mon.w.max(1) as f64).clamp(0.0, 1.0)
            };
            {
                let st = app.state::<AppState>();
                let mut c = st.cfg.lock().unwrap();
                c.notch_y = ratio;
                c.notch_edge = edge.into();
                c.notch_monitor = mon.name.clone();
                config::save(&c);
            }
            applog(&format!(
                "notch drag: dropped at ({last_x},{last_y}) -> edge={edge} ratio={ratio:.3} monitor={:?}",
                mon.name
            ));
            place_notch(&app);
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
    // Through refresh_menu, which makes sure the swap happens on the main thread: doing it from the
    // settings window's thread left the tray with a menu that would never open again.
    tray::refresh_menu(app);
    broadcast(app);
}

// ---------------- commands ----------------

#[tauri::command]
fn get_state(state: tauri::State<AppState>) -> state::Snapshot {
    let store = state.store.lock().unwrap();
    let cfg = state.cfg.lock().unwrap();
    store.snapshot(&cfg.lang, &resolved_lang(&cfg.lang), i18n::clock_24h(), false)
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
    grok::request_refresh();
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
fn get_grok(state: tauri::State<AppState>) -> usage::UsageSnapshot {
    state.grok.lock().unwrap().clone()
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
        "grok" => "https://grok.com/?_s=usage",
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

/// Hot rectangles in **physical pixels**, window-relative, as x,y,w,h: the pill, plus the card
/// while it is open. The page converts by its own devicePixelRatio before reporting, so no scale
/// conversion happens here — WebView2's DPR and the window's scale_factor can disagree (see
/// report_dpr).
///
/// Empty means click-through: before the page has reported, one lost click on the notch beats
/// eating every click aimed at the window behind it.
static HOT: Mutex<Vec<[f64; 4]>> = Mutex::new(Vec::new());

/// Read only by the collapse timer — the click gate goes by the rectangles, since the pill is
/// clickable whether or not the card is up.
static EXPANDED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

#[tauri::command]
fn set_hot(rects: Vec<[f64; 4]>, expanded: bool) {
    *HOT.lock().unwrap() = rects;
    EXPANDED.store(expanded, std::sync::atomic::Ordering::Relaxed);
    if expanded {
        antigravity::request_hover_refresh();
    }
}

/// Setting `WS_EX_TRANSPARENT` by hand instead looks like it should work, and does not: it applies
/// to the notch window, but WebView2 keeps child HWNDs that hit-testing descends into and they
/// never get the bit. `WS_EX_LAYERED` is what makes the window answer as one surface, so the helper
/// that sets both is the only route. Clearing it again is safe — the notch is not otherwise layered
/// (its transparency is DWM composition), so the window returns to the styles it had.
fn set_click_through(app: &AppHandle, on: bool) {
    let Some(w) = app.get_webview_window("notch") else { return };
    let _ = w.set_ignore_cursor_events(on);
}

/// The WebView zoom currently applied (1.0 = uncorrected)
static ZOOM: Mutex<f64> = Mutex::new(1.0);
/// The page's devicePixelRatio without that zoom, as last reported; 0 until the page first reports
static BASE_DPR: Mutex<f64> = Mutex::new(0.0);

/// Keeps the notch page at its designed 360 × 520 CSS px in a window `size` times larger: the
/// WebView zooms by `size` on top of whatever brings its DPR back to the monitor's scale, so the
/// rings, text and hover card scale together, as the Mac's size does.
fn zoom_notch(w: &tauri::WebviewWindow, monitor_scale: f64, size: f64) {
    let base = match *BASE_DPR.lock().unwrap() {
        b if b > 0.0 => b,
        _ => monitor_scale,
    };
    let target = monitor_scale * size / base;
    let mut z = ZOOM.lock().unwrap();
    if (target - *z).abs() > 0.001 {
        match w.set_zoom(target) {
            Ok(()) => *z = target,
            Err(e) => applog(&format!("notch zoom failed: {e}")),
        }
    }
}

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
    let Some(win) = app.get_webview_window("notch") else { return };
    let want = target_screen(&app)
        .map(|s| s.scale)
        .unwrap_or_else(|| win.scale_factor().unwrap_or(1.0))
        * ui_scale(&app);
    let mut z = ZOOM.lock().unwrap();
    let base = if *z > 0.0 { dpr / *z } else { dpr };
    *BASE_DPR.lock().unwrap() = base;
    let target = if base > 0.0 { want / base } else { 1.0 };
    applog(&format!(
        "dpr report: dpr={dpr:.3} viewport={w:.0}x{h:.0} want_dpr={want:.3} zoom_applied={:.3} -> target_zoom={target:.3}",
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

/// Slack around every hot rectangle: this is sampled on a timer, so a cursor arriving at the pill
/// has to count as arrived slightly early, or a quick click lands between two polls while the
/// window is still click-through and goes to whatever is behind it.
const HOT_PAD: f64 = 10.0;

/// Is the cursor on something the window is there for? `window` is the outer size in physical
/// pixels, or None when it could not be read.
fn cursor_in_hot(rects: &[[f64; 4]], lx: f64, ly: f64, window: Option<(f64, f64)>) -> bool {
    if rects.is_empty() {
        return false;
    }
    let in_window = window
        .map(|(w, h)| lx >= 0.0 && ly >= 0.0 && lx < w && ly < h)
        .unwrap_or(true);
    if !in_window {
        return false;
    }
    if rects.iter().any(|r| {
        lx >= r[0] - HOT_PAD
            && ly >= r[1] - HOT_PAD
            && lx < r[0] + r[2] + HOT_PAD
            && ly < r[1] + r[3] + HOT_PAD
    }) {
        return true;
    }
    // The gap between hot rectangles (pill and card) counts as inside: use the bounding box of all of them
    if rects.len() > 1 {
        let x0 = rects.iter().map(|r| r[0]).fold(f64::MAX, f64::min);
        let y0 = rects.iter().map(|r| r[1]).fold(f64::MAX, f64::min);
        let x1 = rects.iter().map(|r| r[0] + r[2]).fold(f64::MIN, f64::max);
        let y1 = rects.iter().map(|r| r[1] + r[3]).fold(f64::MIN, f64::max);
        return lx >= x0 && ly >= y0 && lx < x1 && ly < y1;
    }
    false
}

/// Was 150 ms, when this only decided whether the card stayed up. It now also gates whether a click
/// reaches the notch, and at 150 ms a click arriving in the wrong sample went to the window behind.
const WATCHDOG_MS: u64 = 50;
/// Kept at the original 300 ms rather than falling out of the faster poll, which would make the
/// card twitchy.
const LEAVE_MS: u64 = 300;
/// How long the cursor has to be off an auto-hidden notch before it slides away again. Longer than
/// the card's own grace period: losing the pill the instant the pointer slips off it, while reading
/// the card, is the thing that makes an auto-hiding strip annoying.
const AUTOHIDE_LEAVE_MS: u64 = 900;
/// How deep into the screen edge the cursor has to reach to bring an auto-hidden notch back, in
/// logical pixels. Thin, because the edge is a place the pointer arrives at deliberately.
const REVEAL_BAND: f64 = 4.0;

/// How long a peek offers the notch, matching the Mac's `PeekDuration.standard`. Its reasoning
/// holds here: under a second or two the notch is gone before a glance lands on it, and much past
/// ten it stops reading as an offer and becomes a thing parked on the edge to be waited out.
const PEEK_MS: u64 = 5_000;

/// When the current peek runs out, as ms since the epoch; 0 = not peeking.
static PEEK_UNTIL: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

fn peek_active() -> bool {
    let until = PEEK_UNTIL.load(std::sync::atomic::Ordering::Relaxed);
    until != 0 && now_ms() < until
}

/// Shows an auto-hidden notch for a few seconds — the way in when it is not under the pointer and
/// the edge it hides at is on some other screen. The pointer watchdog holds it open until the
/// offer runs out, and hands back to the ordinary hover fold if the pointer arrives meanwhile, so
/// a peek that turns into use does not snatch itself away mid-read.
pub fn peek_notch(app: &AppHandle) {
    let auto = {
        let st = app.state::<AppState>();
        let c = st.cfg.lock().unwrap();
        c.notch_visible && c.notch_autohide
    };
    if !auto {
        return; // Always-show has nothing to offer, and Hide means the notch is off, not shy
    }
    PEEK_UNTIL.store(now_ms() + PEEK_MS, std::sync::atomic::Ordering::Relaxed);
    if let Some(w) = app.get_webview_window("notch") {
        let _ = w.show();
    }
    applog("autohide: peeking");
}

/// The strip of screen edge that brings an auto-hidden notch back: only the edge it is pinned to,
/// and only along the pill's own extent, so reaching for a scrollbar elsewhere on that edge does
/// not summon it. Before the page has reported a rectangle the whole window edge is used — the
/// window is the notch's own area, so that is the safe default rather than a dead strip.
fn reveal_hit(edge: &str, rects: &[[f64; 4]], lx: f64, ly: f64, ww: f64, wh: f64, band: f64) -> bool {
    let (ax0, ax1, ay0, ay1) = match rects.first() {
        Some(r) => (r[0], r[0] + r[2], r[1], r[1] + r[3]),
        None => (0.0, ww, 0.0, wh),
    };
    let along_x = lx >= ax0 && lx <= ax1;
    let along_y = ly >= ay0 && ly <= ay1;
    match edge {
        "left" => lx >= 0.0 && lx <= band && along_y,
        "top" => ly >= 0.0 && ly <= band && along_x,
        "bottom" => ly >= wh - band && ly <= wh && along_x,
        _ => lx >= ww - band && lx <= ww && along_y,
    }
}

/// WebView2's mouseleave is unreliable inside a NOACTIVATE transparent window — a cursor that
/// leaves quickly often produces no WM_MOUSELEAVE, and the card stays up. Rather than trust DOM
/// events, the Rust side watches the system cursor and emits pointer_left once it is outside; the
/// page collapses after its 250 ms grace period. "Outside the window" is not the test, though: the
/// window is mostly transparent, so the cursor is compared against the hot rectangles the page
/// reports (pill, card, and the gap between them).
///
/// It also gates click-through (#106), which is why it runs whether or not the card is open. That
/// ordering is load-bearing: the window ignores the cursor while it is click-through, so the page
/// gets no mousemove out there and cannot see the pointer arriving. This loop does, and hands the
/// window its input back in time for the page to open the card.
fn start_pointer_watchdog(app: AppHandle) {
    std::thread::spawn(move || {
        let need = (LEAVE_MS / WATCHDOG_MS).max(1) as u8;
        let away_need = (AUTOHIDE_LEAVE_MS / WATCHDOG_MS).max(1) as u16;
        let mut miss = 0u8;
        let mut away = 0u16;
        // Last value pushed: this changes only when the cursor crosses an edge
        let mut click_through: Option<bool> = None;
        loop {
            std::thread::sleep(std::time::Duration::from_millis(WATCHDOG_MS));
            let Some(w) = app.get_webview_window("notch") else { continue };
            let (Ok(pos), Ok(cur)) = (w.outer_position(), app.cursor_position()) else { continue };
            let rects = HOT.lock().unwrap().clone();
            // Cursor position relative to the window's top-left, in physical pixels; the hot rectangles are physical too, so no scale conversion
            let lx = cur.x - pos.x as f64;
            let ly = cur.y - pos.y as f64;
            let size = w.outer_size().ok().map(|s| (s.width as f64, s.height as f64));
            let inside = cursor_in_hot(&rects, lx, ly, size);

            // Auto-hide. This loop already has everything it needs — the cursor, the window's
            // corner and the pill's own rectangle — so the reveal costs no second poll.
            let (auto, edge) = {
                let st = app.state::<AppState>();
                let c = st.cfg.lock().unwrap();
                (c.notch_visible && c.notch_autohide, config::edge_or_right(&c.notch_edge))
            };
            if auto {
                let (ww, wh) = size.unwrap_or((0.0, 0.0));
                let band = REVEAL_BAND * w.scale_factor().unwrap_or(1.0);
                let peeking = peek_active();
                if !w.is_visible().unwrap_or(true) {
                    if reveal_hit(&edge, &rects, lx, ly, ww, wh, band) {
                        let _ = w.show();
                        applog("autohide: revealed at the edge");
                    }
                    // Off the screen there is nothing to be click-through for, and no card to collapse
                    away = 0;
                    miss = 0;
                    continue;
                }
                // A peek holds it open on its own. Without this the fold below would take it away
                // again within the second, because during a peek the pointer is almost never on it.
                if inside || peeking {
                    away = 0;
                } else {
                    away += 1;
                    if away >= away_need {
                        away = 0;
                        EXPANDED.store(false, std::sync::atomic::Ordering::Relaxed);
                        let _ = app.emit("pointer_left", ());
                        let _ = w.hide();
                        applog("autohide: hidden again");
                        continue;
                    }
                }
            } else {
                away = 0;
            }

            if click_through != Some(!inside) {
                set_click_through(&app, !inside);
                click_through = Some(!inside);
                applog(&format!(
                    "click-through {} at cursor_rel=({lx:.0},{ly:.0}) rects={rects:?}",
                    if inside { "off (cursor on the notch)" } else { "on (cursor elsewhere)" }
                ));
            }

            static LOGGED: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
            if LOGGED.fetch_add(1, std::sync::atomic::Ordering::Relaxed) < 12 {
                applog(&format!(
                    "watchdog: cursor_rel=({lx:.0},{ly:.0}) inside={inside} rects={rects:?} winpos=({},{})",
                    pos.x, pos.y
                ));
            }

            if !EXPANDED.load(std::sync::atomic::Ordering::Relaxed) {
                miss = 0;
                continue;
            }
            if inside {
                miss = 0;
            } else {
                miss += 1;
                if miss >= need {
                    miss = 0;
                    EXPANDED.store(false, std::sync::atomic::Ordering::Relaxed);
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

// ---------------- notch size ----------------

#[tauri::command]
fn get_scale(app: AppHandle) -> f64 {
    ui_scale(&app)
}

/// Settings' Small, Medium or Large. The notch window is resized and zoomed around its centre.
#[tauri::command]
fn set_scale(app: AppHandle, scale: f64) -> f64 {
    let value = {
        let st = app.state::<AppState>();
        let mut c = st.cfg.lock().unwrap();
        c.scale = config::snap_scale(scale);
        config::save(&c);
        c.scale
    };
    place_notch(&app);
    value
}

/// Where the weekly limit's ring sits, if it is drawn at all.
#[tauri::command]
fn get_weekly_ring(app: AppHandle) -> String {
    let st = app.state::<AppState>();
    let c = st.cfg.lock().unwrap();
    c.weekly_ring.clone()
}

/// Unknown values are refused rather than stored. The notch draws its own rings, so it is told.
#[tauri::command]
fn set_weekly_ring(app: AppHandle, placement: String) -> String {
    let value = {
        let st = app.state::<AppState>();
        let mut c = st.cfg.lock().unwrap();
        if ["off", "inside", "outside"].contains(&placement.as_str()) {
            c.weekly_ring = placement;
            config::save(&c);
        }
        c.weekly_ring.clone()
    };
    let _ = app.emit("weekly_ring", &value);
    value
}

// ---------------- tray icon readings ----------------

/// The tightest metered window, ties going to the lower id so the choice never flickers. A `count`
/// window (Antigravity's requests today) has no published denominator, so it is never a candidate.
fn tightest<'a>(
    windows: impl Iterator<Item = &'a usage::LimitWindow>,
) -> Option<&'a usage::LimitWindow> {
    windows
        .filter(|w| w.count.is_none())
        .max_by(|a, b| a.used.total_cmp(&b.used).then_with(|| b.id.cmp(&a.id)))
}

/// The window a provider's ring shows, declared per provider as the macOS providers declare
/// `headlineID`: a window dropping out of a reply shows a dash instead of promoting another one
/// into its place. `headlineOf` in ui/notch.html is the same rule, so the ring and the tray agree.
fn ring_window<'a>(
    provider: &str,
    windows: &'a [usage::LimitWindow],
    antigravity_limit: &str,
    antigravity_model: &str,
) -> Option<&'a usage::LimitWindow> {
    let by_id = |id: &str| windows.iter().find(|w| w.id == id);
    match provider {
        "claude" => by_id("session"),
        "codex" => windows.first(),
        "cursor" => by_id("included").or_else(|| by_id("api")),
        "grok" => by_id("credits").or_else(|| windows.first()),
        _ => antigravity_lane(windows, antigravity_limit, antigravity_model),
    }
}

/// Antigravity's lane, chosen as the Mac app's "Notch reads" and "Model data" choose it: within the
/// model family (or every lane, if none belongs to it), the tightest lane of the chosen cadence; on
/// Automatic, the tightest lane that still has room, or the tightest of all once every one is spent.
fn antigravity_lane<'a>(
    windows: &'a [usage::LimitWindow],
    limit: &str,
    model: &str,
) -> Option<&'a usage::LimitWindow> {
    let family: Vec<_> = windows.iter().filter(|w| lane_family(w) == model).collect();
    let lanes = if family.is_empty() { windows.iter().collect() } else { family };
    if limit != "automatic" {
        if let Some(w) = tightest(lanes.iter().copied().filter(|w| lane_is(w, limit))) {
            return Some(w);
        }
    }
    tightest(lanes.iter().copied().filter(|w| w.used < 1.0))
        .or_else(|| tightest(lanes.iter().copied()))
        .or_else(|| lanes.first().copied())
}

/// "gemini" or "3p", from the language server's `gemini-5h` ids or the CLI's "Gemini Models …" ones
fn lane_family(w: &usage::LimitWindow) -> &'static str {
    let id = w.id.to_lowercase();
    if id.starts_with("gemini") {
        "gemini"
    } else if id.starts_with("3p") || id.starts_with("claude") {
        "3p"
    } else {
        ""
    }
}

/// Whether a lane is the 5-hour or the weekly one, by the words the Mac app looks for
fn lane_is(w: &usage::LimitWindow, limit: &str) -> bool {
    let text = format!("{} {}", w.id, w.label).to_lowercase();
    match limit {
        "weekly" => text.contains("weekly"),
        _ => ["5h", "5-hour", "five hour", "five-hour", "hourly", "session"]
            .iter()
            .any(|k| text.contains(k)),
    }
}

/// Ids match the ones the page uses, so the tray, the settings window and the notch all agree.
pub(crate) fn snapshot_of(app: &AppHandle, id: &str) -> usage::UsageSnapshot {
    let st = app.state::<AppState>();
    match id {
        "codex" => st.codex.lock().unwrap().clone(),
        "cursor" => st.cursor.lock().unwrap().clone(),
        "grok" => st.grok.lock().unwrap().clone(),
        "gemini" => st.antigravity.lock().unwrap().clone(),
        _ => st.usage.lock().unwrap().clone(),
    }
}

/// A provider's ring as a whole percentage, for the tray icon and the settings picker. A count
/// window has no percentage to draw, so it is a dash.
pub(crate) fn ring_fraction(app: &AppHandle, provider: &str) -> Option<f64> {
    let snap = snapshot_of(app, provider);
    if snap.status == "absent" {
        return None;
    }
    let (limit, model) = {
        let st = app.state::<AppState>();
        let c = st.cfg.lock().unwrap();
        (c.antigravity_limit.clone(), c.antigravity_model.clone())
    };
    ring_window(provider, &snap.windows, &limit, &model)
        .filter(|w| w.count.is_none())
        .map(|w| w.used.clamp(0.0, 1.0))
}

pub(crate) fn ring_pct(app: &AppHandle, provider: &str) -> Option<u32> {
    let snap = snapshot_of(app, provider);
    if snap.status == "absent" {
        return None;
    }
    let (limit, model) = {
        let st = app.state::<AppState>();
        let c = st.cfg.lock().unwrap();
        (c.antigravity_limit.clone(), c.antigravity_model.clone())
    };
    ring_window(provider, &snap.windows, &limit, &model)
        .filter(|w| w.count.is_none())
        .map(|w| (w.used * 100.0).round().clamp(0.0, 100.0) as u32)
}

/// One provider and its ring's current number, for the settings window's picker.
#[derive(serde::Serialize)]
struct TrayOption {
    id: String,
    label: String,
    status: String,
    used: Option<u32>,
}

#[tauri::command]
fn get_tray_options(app: AppHandle) -> Vec<TrayOption> {
    TRAY_PROVIDER_IDS
        .iter()
        .map(|id| TrayOption {
            id: (*id).to_string(),
            label: provider_label(id).to_string(),
            status: snapshot_of(&app, id).status,
            used: ring_pct(&app, id),
        })
        .collect()
}

/// Antigravity's "Notch reads" and "Model data", as the Mac app has them.
#[derive(serde::Serialize)]
struct AntigravityPrefs {
    limit: String,
    model: String,
}

#[tauri::command]
fn get_antigravity_prefs(app: AppHandle) -> AntigravityPrefs {
    let st = app.state::<AppState>();
    let c = st.cfg.lock().unwrap();
    AntigravityPrefs { limit: c.antigravity_limit.clone(), model: c.antigravity_model.clone() }
}

/// Unknown values are refused rather than stored. The notch draws its own rings, so it is told.
#[tauri::command]
fn set_antigravity_prefs(app: AppHandle, limit: String, model: String) -> AntigravityPrefs {
    let prefs = {
        let st = app.state::<AppState>();
        let mut c = st.cfg.lock().unwrap();
        if ["automatic", "5h", "weekly"].contains(&limit.as_str()) {
            c.antigravity_limit = limit;
        }
        if ["gemini", "3p"].contains(&model.as_str()) {
            c.antigravity_model = model;
        }
        config::save(&c);
        AntigravityPrefs { limit: c.antigravity_limit.clone(), model: c.antigravity_model.clone() }
    };
    let _ = app.emit("antigravity_prefs", &prefs);
    tray::refresh_menu(&app);
    prefs
}

/// Which providers get a ring on the notch. An empty list means every provider.
#[tauri::command]
fn get_notch_slots(app: AppHandle) -> Vec<config::TraySlot> {
    let st = app.state::<AppState>();
    let c = st.cfg.lock().unwrap();
    c.notch_slots.clone()
}

#[tauri::command]
fn set_notch_slots(app: AppHandle, slots: Vec<config::TraySlot>) {
    let list = {
        let st = app.state::<AppState>();
        let mut c = st.cfg.lock().unwrap();
        c.notch_slots = slots;
        // Kept in step so an older build reading this file still shows the right providers
        c.notch_providers = c.notch_slots.iter().map(|s| s.provider.clone()).collect();
        config::save(&c);
        c.notch_slots.clone()
    };
    // The notch is a separate window and draws its own cells, so it has to be told.
    let _ = app.emit("notch_slots", list);
}

/// The application's own icon, so the settings window shows what the taskbar shows.
#[tauri::command]
fn get_app_icon() -> Option<String> {
    trayicon::app_mark_data_url()
}

// ---------------- what is on screen at all ----------------

#[derive(serde::Serialize)]
struct UiFlags {
    notch_visible: bool,
    notch_autohide: bool,
    tray_visible: bool,
}

#[tauri::command]
fn get_ui_flags(app: AppHandle) -> UiFlags {
    let st = app.state::<AppState>();
    let c = st.cfg.lock().unwrap();
    UiFlags { notch_visible: c.notch_visible, notch_autohide: c.notch_autohide, tray_visible: c.tray_visible }
}

/// Hiding both would leave the app running with nothing to click, so the tray icon is kept
/// whenever the notch is off. Auto-hide is not "off": the notch is still reachable at its edge, so
/// it does not hold the tray icon on. The answer says what was actually stored, so the settings
/// window can show the corrected state rather than a lie.
#[tauri::command]
fn set_ui_flags(app: AppHandle, notch_visible: bool, notch_autohide: bool, tray_visible: bool) -> UiFlags {
    let flags = {
        let st = app.state::<AppState>();
        let mut c = st.cfg.lock().unwrap();
        c.notch_visible = notch_visible;
        c.notch_autohide = notch_visible && notch_autohide;
        c.tray_visible = if notch_visible { tray_visible } else { true };
        config::save(&c);
        UiFlags {
            notch_visible: c.notch_visible,
            notch_autohide: c.notch_autohide,
            tray_visible: c.tray_visible,
        }
    };
    apply_visibility(&app);
    flags
}

/// Puts the two switches into effect.
pub fn apply_visibility(app: &AppHandle) {
    let (notch, tray_on) = {
        let st = app.state::<AppState>();
        let c = st.cfg.lock().unwrap();
        (c.notch_visible, c.tray_visible)
    };
    if let Some(w) = app.get_webview_window("notch") {
        if notch {
            let _ = w.show();
            place_notch(app);
        } else {
            let _ = w.hide();
        }
    }
    if let Some(t) = app.tray_by_id("main") {
        let _ = t.set_visible(tray_on);
    }
    // The peek item comes and goes with the Show setting, and this is where that setting lands
    tray::refresh_menu(app);
}

// ---------------- settings that used to live in the tray menu ----------------

#[tauri::command]
fn get_lang(app: AppHandle) -> String {
    let st = app.state::<AppState>();
    let c = st.cfg.lock().unwrap();
    c.lang.clone()
}

/// The settings WebView must use the same Windows locale as the tray. WebView2's
/// navigator.language can describe the browser runtime rather than the user locale.
#[tauri::command]
fn get_lang_resolved(app: AppHandle) -> String {
    let st = app.state::<AppState>();
    let c = st.cfg.lock().unwrap();
    resolved_lang(&c.lang)
}

#[tauri::command]
fn get_autostart() -> bool {
    autostart::is_enabled()
}

#[tauri::command]
fn set_autostart(on: bool) -> Result<String, String> {
    if on {
        autostart::enable()
    } else {
        autostart::disable()
    }
}

#[tauri::command]
fn get_hooks_installed() -> bool {
    hooks_install::is_installed()
}

#[tauri::command]
fn set_hooks_installed(on: bool) -> Result<String, String> {
    if on {
        hooks_install::install()
    } else {
        hooks_install::uninstall()
    }
}

#[tauri::command]
fn reset_notch_position(app: AppHandle) {
    reset_bar(&app);
}

/// Which screen edge the notch is pinned to.
#[tauri::command]
fn get_notch_edge(app: AppHandle) -> String {
    let st = app.state::<AppState>();
    let c = st.cfg.lock().unwrap();
    config::edge_or_right(&c.notch_edge)
}

/// Moving to another edge keeps the position along it, so the notch stays where the eye expects it:
/// a notch two thirds down the right-hand edge arrives two thirds along the top one.
#[tauri::command]
fn set_notch_edge(app: AppHandle, edge: String) -> String {
    let value = {
        let st = app.state::<AppState>();
        let mut c = st.cfg.lock().unwrap();
        c.notch_edge = config::edge_or_right(&edge);
        config::save(&c);
        c.notch_edge.clone()
    };
    place_notch(&app);
    value
}

/// One attached monitor, as Settings lists it.
#[derive(serde::Serialize)]
pub struct MonitorInfo {
    /// The system device name (`\\.\DISPLAY2`); absent on a monitor the platform will not name,
    /// which then cannot be chosen explicitly and falls back to primary.
    pub id: Option<String>,
    /// "1  2560 × 1440" — enough to tell two identical screens apart by where they sit
    pub label: String,
    pub primary: bool,
    pub current: bool,
}

#[tauri::command]
fn get_monitors(app: AppHandle) -> Vec<MonitorInfo> {
    let want = {
        let st = app.state::<AppState>();
        let c = st.cfg.lock().unwrap();
        c.notch_monitor.clone()
    };
    let list = screens(&app);
    let chosen = target_screen(&app).and_then(|s| s.name);
    list.iter()
        .enumerate()
        .map(|(i, s)| MonitorInfo {
            id: s.name.clone(),
            label: format!("{}  {} × {}", i + 1, s.w, s.h),
            primary: i == 0,
            // With no explicit choice the primary monitor is the one in use
            current: if want.is_some() { s.name == chosen } else { i == 0 },
        })
        .collect()
}

/// `None` (or a name that is no longer attached) means the primary monitor.
#[tauri::command]
fn set_notch_monitor(app: AppHandle, id: Option<String>) {
    {
        let st = app.state::<AppState>();
        let mut c = st.cfg.lock().unwrap();
        c.notch_monitor = id.filter(|s| !s.is_empty());
        config::save(&c);
    }
    place_notch(&app);
}

#[tauri::command]
fn open_settings(app: AppHandle) {
    settings_window::open(&app);
}

/// Epoch milliseconds. Every polling module keeps its own copy of this; the tray menu's wording
/// needs one that is not private to a poller.
pub fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

pub fn provider_label(id: &str) -> &'static str {
    match id {
        "codex" => "Codex",
        "cursor" => "Cursor",
        "grok" => "Grok",
        "gemini" => "Antigravity",
        _ => "Claude",
    }
}

/// Every provider the tray menu can offer, in the order the notch shows them.
pub const TRAY_PROVIDER_IDS: [&str; 5] = ["claude", "codex", "cursor", "grok", "gemini"];

/// Keeps the tray menu current. macOS rebuilds its menu as it opens; Tauri has no such hook, so it
/// is rebuilt whenever a reading changes, and once a minute besides — otherwise "Resets in 12 min"
/// sits there being wrong while nothing else happens.
fn start_menu_updater(app: AppHandle) {
    std::thread::spawn(move || {
        let mut last: Option<Vec<Option<i64>>> = None;
        let mut ticked = std::time::Instant::now();
        loop {
            std::thread::sleep(std::time::Duration::from_secs(2));
            let values: Vec<Option<i64>> = TRAY_PROVIDER_IDS
                .iter()
                .map(|id| ring_fraction(&app, id).map(|f| (f * 1000.0).round() as i64))
                .collect();
            let changed = last.as_ref() != Some(&values);
            if !changed && ticked.elapsed() < std::time::Duration::from_secs(60) {
                continue;
            }
            if changed {
                last = Some(values);
            }
            ticked = std::time::Instant::now();
            tray::refresh_menu(&app);
        }
    });
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

fn report(r: Result<String, String>) {
    let msg = match r {
        Ok(m) => format!("OK: {m}"),
        Err(e) => format!("FAILED: {e}"),
    };
    println!("{msg}");
    let log = config::config_path().with_file_name("install.log");
    let _ = std::fs::write(log, &msg);
}

/// The subcommands that print to the parent console; only those may attach to it.
const CONSOLE_CMDS: [&str; 4] = ["install-hooks", "uninstall-hooks", "autostart", "doctor"];

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if let Some(cmd) = args.get(1) {
        // Attaching on the GUI path too tied the notch to whatever cmd.exe launched it: closing that
        // window sends CTRL_CLOSE_EVENT to every process on the console, and with no handler the
        // default action ends the process. The exe is already windows_subsystem = "windows", so the
        // GUI run wants no console at all.
        if CONSOLE_CMDS.contains(&cmd.as_str()) {
            attach_console();
        }
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

    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            // Opening Codenotch again while it runs brings Settings forward, as on the Mac: with the
            // tray icon hidden it is the way back. Logged too, for a rebuild that was not picked up.
            applog(&format!("single instance: another launch was refused; the running instance is build={BUILD} — quit it from the tray first if you just rebuilt"));
            settings_window::open(app);
        }))
        .manage(AppState {
            store: Mutex::new(Default::default()),
            cfg: Mutex::new(cfg),
            usage: Mutex::new(usage::load_persisted()),
            codex: Mutex::new(codex::load_persisted()),
            cursor: Mutex::new(cursor::load_persisted()),
            grok: Mutex::new(grok::load_persisted()),
            antigravity: Mutex::new(antigravity::load_persisted()),
            glyphs: Mutex::new(Default::default()),
            activity: Mutex::new(Vec::new()),
        })
        .invoke_handler(tauri::generate_handler![
            get_state,
            get_usage,
            get_codex,
            get_cursor,
            get_grok,
            get_antigravity,
            get_glyphs,
            get_activity,
            open_data_dir,
            drag_begin,
            open_provider_page,
            refresh_usage,
            open_usage_page,
            set_hot,
            report_dpr,
            log_js,
            focus_session,
            dismiss_session,
            set_lang,
            get_scale,
            set_scale,
            get_weekly_ring,
            set_weekly_ring,
            get_tray_options,
            get_notch_slots,
            set_notch_slots,
            get_antigravity_prefs,
            set_antigravity_prefs,
            get_app_icon,
            get_ui_flags,
            set_ui_flags,
            get_lang,
            get_lang_resolved,
            get_autostart,
            set_autostart,
            get_hooks_installed,
            set_hooks_installed,
            reset_notch_position,
            get_notch_edge,
            set_notch_edge,
            get_monitors,
            set_notch_monitor,
            open_settings,
            settings_window::get_system_look,
            settings_window::quit_app,
            settings_window::open_author_page
        ])
        .setup(move |app| {
            let handle = app.handle().clone();
            place_notch(&handle);
            if let Some(w) = handle.get_webview_window("notch") {
                let _ = w.show();
            }
            tray::setup(&handle)?;
            start_menu_updater(handle.clone());
            // Honours the saved switches: a notch hidden last time stays hidden.
            apply_visibility(&handle);
            server::start(handle.clone(), port);
            watcher::start(handle.clone());
            usage::start(handle.clone());
            codex::start(handle.clone());
            cursor::start(handle.clone());
            grok::start(handle.clone());
            antigravity::start(handle.clone());
            activity::start(handle.clone());
            // Collecting glyphs may read icon resources out of a few executables; do it off the main thread and push when done
            let gh = handle.clone();
            std::thread::spawn(move || reload_glyphs(&gh));
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
mod tests {
    use super::{cursor_in_hot, notch_window_size, reveal_hit, ring_window, HOT_PAD, NOTCH_H, NOTCH_W};
    use crate::usage::LimitWindow;

    #[test]
    fn a_flat_notch_is_wide_enough_for_five_rings() {
        // 5 × 56 px rings + 4 × 14 px gaps + 36 px padding + 2 × 26 px fillets
        let pill = 5.0 * 56.0 + 4.0 * 14.0 + 36.0 + 2.0 * 26.0;
        for edge in ["top", "bottom"] {
            let (w, h) = notch_window_size(edge);
            assert!(w >= pill, "{edge}: {w} px cannot hold a {pill} px pill");
            assert_eq!(h, NOTCH_H, "{edge}: the hover card still needs the full height");
        }
        for edge in ["left", "right"] {
            assert_eq!(notch_window_size(edge), (NOTCH_W, NOTCH_H));
        }
    }

    /// Real values from the run.log in #106: a 2560×1600 display at 150 %.
    const PILL: [f64; 4] = [405.0, 183.5, 105.0, 323.0];
    const CARD: [f64; 4] = [21.0, 142.5, 369.0, 262.0];
    const WINDOW: Option<(f64, f64)> = Some((510.0, 690.0));

    #[test]
    fn nothing_is_hot_before_the_page_reports() {
        assert!(!cursor_in_hot(&[], 450.0, 300.0, WINDOW));
    }

    #[test]
    fn the_pill_is_hot() {
        assert!(cursor_in_hot(&[PILL], 450.0, 300.0, WINDOW));
    }

    // ---- auto-hide reveal strip ----
    // A 500 x 600 window whose pill sits between y = 200 and y = 400 on the right-hand edge.
    const RW: f64 = 500.0;
    const RH: f64 = 600.0;
    const RPILL: [f64; 4] = [420.0, 200.0, 80.0, 200.0];

    #[test]
    fn the_edge_reveals_only_beside_the_pill() {
        // at the edge, level with the pill
        assert!(reveal_hit("right", &[RPILL], 498.0, 300.0, RW, RH, 5.0));
        // at the edge, but far above it — a scrollbar, not the notch
        assert!(!reveal_hit("right", &[RPILL], 498.0, 40.0, RW, RH, 5.0));
    }

    #[test]
    fn reaching_short_of_the_edge_does_not_reveal() {
        assert!(!reveal_hit("right", &[RPILL], 470.0, 300.0, RW, RH, 5.0));
    }

    #[test]
    fn each_edge_watches_its_own_side() {
        let flat: [f64; 4] = [150.0, 0.0, 200.0, 100.0];
        assert!(reveal_hit("top", &[flat], 250.0, 2.0, RW, RH, 5.0));
        assert!(!reveal_hit("top", &[flat], 250.0, RH - 2.0, RW, RH, 5.0));
        assert!(reveal_hit("bottom", &[flat], 250.0, RH - 2.0, RW, RH, 5.0));
        assert!(reveal_hit("left", &[[0.0, 200.0, 80.0, 200.0]], 2.0, 300.0, RW, RH, 5.0));
    }

    #[test]
    fn before_the_page_reports_the_whole_window_edge_answers() {
        // Otherwise an auto-hidden notch that has never rendered could not be summoned at all
        assert!(reveal_hit("right", &[], 498.0, 40.0, RW, RH, 5.0));
    }

    #[test]
    fn a_peek_holds_the_notch_open_and_then_stops() {
        use super::{peek_active, PEEK_UNTIL};
        use std::sync::atomic::Ordering;
        let was = PEEK_UNTIL.load(Ordering::Relaxed);

        PEEK_UNTIL.store(0, Ordering::Relaxed);
        assert!(!peek_active(), "no peek has been asked for");

        PEEK_UNTIL.store(super::now_ms() + 5_000, Ordering::Relaxed);
        assert!(peek_active(), "the offer is still open");

        // Expiry is what hands the notch back to the hover fold; a peek that never ended would
        // leave an auto-hiding notch parked on the edge for good.
        PEEK_UNTIL.store(super::now_ms().saturating_sub(1), Ordering::Relaxed);
        assert!(!peek_active(), "the offer has run out");

        PEEK_UNTIL.store(was, Ordering::Relaxed);
    }

    #[test]
    fn the_transparent_area_beside_the_pill_is_not() {
        assert!(!cursor_in_hot(&[PILL], 0.0, 297.0, WINDOW));
        assert!(!cursor_in_hot(&[PILL], 100.0, 400.0, WINDOW));
    }

    #[test]
    fn the_card_is_hot_while_it_is_open() {
        assert!(!cursor_in_hot(&[PILL], 100.0, 250.0, WINDOW));
        assert!(cursor_in_hot(&[PILL, CARD], 100.0, 250.0, WINDOW));
    }

    #[test]
    fn the_tail_leaves_no_cold_strip_between_the_pill_and_the_card() {
        // The shipped layout at 150 %, from the CSS: the card stops 100 px from the edge and the
        // tail spans the rest, its tip under the pill's edge. A pointer crossing along the tail is
        // hot on one rectangle alone at every step, so it never leans on the bounding box.
        const WIDE: Option<(f64, f64)> = Some((540.0, 690.0));
        const WIDE_PILL: [f64; 4] = [435.0, 183.5, 105.0, 323.0];
        const TAIL: [f64; 4] = [388.5, 318.0, 48.0, 54.0];
        let y = TAIL[1] + TAIL[3] / 2.0;
        for x in (CARD[0] + CARD[2]) as i32..WIDE_PILL[0] as i32 {
            let x = x as f64;
            assert!(
                [WIDE_PILL, TAIL, CARD].iter().any(|r| cursor_in_hot(&[*r], x, y, WIDE)),
                "cold at x={x}"
            );
        }
    }

    /// Far enough apart that the pads do not meet — the case the bounding box exists for.
    const FAR_A: [f64; 4] = [0.0, 0.0, 50.0, 50.0];
    const FAR_B: [f64; 4] = [200.0, 0.0, 50.0, 50.0];

    #[test]
    fn a_wide_gap_is_bridged_by_the_bounding_box() {
        assert!(cursor_in_hot(&[FAR_A, FAR_B], 125.0, 25.0, None));
    }

    #[test]
    fn the_bounding_box_needs_two_rectangles_to_bridge_anything() {
        assert!(!cursor_in_hot(&[FAR_A], 125.0, 25.0, None));
    }

    #[test]
    fn the_pad_reaches_slightly_past_the_pill() {
        assert!(cursor_in_hot(&[PILL], PILL[0] - HOT_PAD + 1.0, 300.0, WINDOW));
        assert!(!cursor_in_hot(&[PILL], PILL[0] - HOT_PAD - 1.0, 300.0, WINDOW));
    }

    #[test]
    fn a_cursor_off_the_window_is_never_hot() {
        assert!(!cursor_in_hot(&[PILL], 515.0, 300.0, WINDOW));
        assert!(!cursor_in_hot(&[PILL], 450.0, -5.0, WINDOW));
    }

    #[test]
    fn an_unreadable_window_size_falls_back_to_the_rectangles() {
        assert!(cursor_in_hot(&[PILL], 450.0, 300.0, None));
        assert!(!cursor_in_hot(&[PILL], 100.0, 300.0, None));
    }

    fn win(id: &str, used: f64) -> LimitWindow {
        LimitWindow { id: id.into(), used, ..Default::default() }
    }

    fn pick<'a>(provider: &str, windows: &'a [LimitWindow]) -> Option<&'a str> {
        ring_window(provider, windows, "automatic", "gemini").map(|w| w.id.as_str())
    }

    fn lane<'a>(windows: &'a [LimitWindow], limit: &str, model: &str) -> Option<&'a str> {
        ring_window("gemini", windows, limit, model).map(|w| w.id.as_str())
    }

    /// The four lanes Antigravity's language server reported on a real machine
    fn bridge() -> [LimitWindow; 4] {
        [win("gemini-weekly", 0.03), win("gemini-5h", 0.0), win("3p-weekly", 0.5), win("3p-5h", 0.9)]
    }

    #[test]
    fn claude_means_the_session_even_when_the_week_is_fuller() {
        assert_eq!(pick("claude", &[win("session", 0.10), win("weekly_all", 0.60)]), Some("session"));
    }

    #[test]
    fn a_missing_declared_window_is_a_dash_not_a_stand_in() {
        assert_eq!(pick("claude", &[win("weekly_all", 0.60)]), None);
    }

    #[test]
    fn codex_means_its_first_window_and_cursor_its_included_usage() {
        assert_eq!(pick("codex", &[win("primary", 0.2), win("secondary", 0.9)]), Some("primary"));
        assert_eq!(pick("cursor", &[win("included", 0.3), win("api", 0.9)]), Some("included"));
        assert_eq!(pick("cursor", &[win("api", 0.9), win("on_demand", 0.95)]), Some("api"));
    }

    #[test]
    fn antigravity_reads_only_gemini_lanes_unless_told_otherwise() {
        assert_eq!(lane(&bridge(), "automatic", "gemini"), Some("gemini-weekly"));
        assert_eq!(lane(&bridge(), "automatic", "3p"), Some("3p-5h"));
    }

    #[test]
    fn notch_reads_picks_the_five_hour_or_the_weekly_lane() {
        assert_eq!(lane(&bridge(), "5h", "gemini"), Some("gemini-5h"));
        assert_eq!(lane(&bridge(), "weekly", "3p"), Some("3p-weekly"));
    }

    #[test]
    fn the_cli_names_its_lanes_differently_and_still_matches() {
        let cli = [
            win("Gemini Models Weekly Limit", 0.2),
            win("Gemini Models Five Hour Limit", 0.1),
            win("Claude and GPT models Five Hour Limit", 0.7),
        ];
        assert_eq!(lane(&cli, "5h", "gemini"), Some("Gemini Models Five Hour Limit"));
        assert_eq!(lane(&cli, "automatic", "3p"), Some("Claude and GPT models Five Hour Limit"));
    }

    #[test]
    fn a_spent_lane_leads_only_once_every_lane_is_spent() {
        let one_spent = [win("gemini-5h", 1.0), win("gemini-weekly", 0.4)];
        assert_eq!(lane(&one_spent, "automatic", "gemini"), Some("gemini-weekly"));
        let all_spent = [win("gemini-weekly", 1.0), win("gemini-5h", 1.0)];
        assert_eq!(lane(&all_spent, "automatic", "gemini"), Some("gemini-5h"));
    }

    #[test]
    fn a_request_count_still_leads_when_it_is_all_there_is() {
        let requests = LimitWindow { id: "requests".into(), count: Some(79), ..Default::default() };
        assert_eq!(pick("gemini", std::slice::from_ref(&requests)), Some("requests"));
    }
}
