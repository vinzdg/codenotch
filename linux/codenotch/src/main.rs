#![cfg_attr(all(not(debug_assertions), windows), windows_subsystem = "windows")]

mod autostart;
mod config;
mod doctor;
mod focus;
mod hooks_install;
mod i18n;
mod open;
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
mod hover;

use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager};

/// Logical size of the notch window: the 70 pt pill column on the right plus room for the hover card
/// and its tail on the left. `fitZoom` in ui/notch.html divides by the same width.
pub const NOTCH_W: f64 = 360.0;
/// Hand-bumped build tag, written to run.log at startup so a log can always be matched to the exe that wrote it.
pub const BUILD: &str = "r44";
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

/// Which screen contains a desktop point, if any.
fn screen_at(list: &[Screen], x: i32, y: i32) -> Option<&Screen> {
    list.iter().find(|s| s.contains(x, y))
}

/// The monitor the notch should sit on: the configured one while it is still attached, else the
/// screen under the cursor (what the user is looking at). GTK's "primary" is often the other
/// display on a two-monitor Linux desktop.
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
    if let Ok(pos) = app.cursor_position() {
        if let Some(s) = screen_at(&list, pos.x.round() as i32, pos.y.round() as i32) {
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

/// GTK/WebKit often answers 0×0 for outer_size on a frameless transparent window. Using that
/// as the width puts the notch entirely off the right (or bottom) edge.
fn usable_physical_size(w: &tauri::WebviewWindow, target: &tauri::PhysicalSize<u32>) -> (i32, i32) {
    match w.outer_size() {
        Ok(s) if s.width > 1 && s.height > 1 => (s.width as i32, s.height as i32),
        _ => (target.width as i32, target.height as i32),
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
        // GTK reports outer_size 0×0 for an unmapped/transparent window; treating that as real
        // width parked the pill past the monitor's right edge (nothing to hover).
        let (ww, wh) = usable_physical_size(&w, &target);
        // The position along the edge comes from the config (it persists across a drag)
        let ratio = {
            let st = app.state::<AppState>();
            let c = st.cfg.lock().unwrap();
            c.notch_y.clamp(0.0, 1.0)
        };
        let (x, y) = edge_origin(&mon, &edge, ww, wh, ratio);
        let _ = w.set_position(tauri::PhysicalPosition::new(x, y));
        if w.outer_size().ok().is_some_and(|s| s.width > 1 && s.width != target.width) {
            let _ = w.set_size(target);
            let (x, y) = edge_origin(&mon, &edge, target.width as i32, target.height as i32, ratio);
            let _ = w.set_position(tauri::PhysicalPosition::new(x, y));
        }
        // The page mirrors itself for the edge it is on; it cannot know that on its own.
        let _ = w.emit("notch_edge", &edge);
        // Placement log line: the first thing to check when the notch is not visible
        let all = screens(app);
        let cursor = app.cursor_position().ok().map(|p| (p.x.round() as i32, p.y.round() as i32));
        let listed = all
            .iter()
            .map(|s| format!("{:?}@({},{} {}x{})", s.name, s.x, s.y, s.w, s.h))
            .collect::<Vec<_>>()
            .join("; ");
        applog(&format!(
            "notch placed build={BUILD}: edge={edge} pos=({x},{y}) size=({ww}x{wh}) inner={:?} win_scale={scale} mon_scale={ms} notch_size={size} monitor={:?}=({},{} {}x{}) cursor={cursor:?} screens=[{listed}]",
            w.inner_size().map(|s| (s.width, s.height)).unwrap_or((0, 0)),
            mon.name,
            mon.x,
            mon.y,
            mon.w,
            mon.h
        ));
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
static POINTER_HELD: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

#[cfg(windows)]
fn left_button_down() -> bool {
    use windows::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_LBUTTON};
    unsafe { (GetAsyncKeyState(VK_LBUTTON.0 as i32) as u16 & 0x8000) != 0 }
}
#[cfg(not(windows))]
fn left_button_down() -> bool {
    POINTER_HELD.load(std::sync::atomic::Ordering::SeqCst)
}

#[tauri::command]
fn drag_end() {
    POINTER_HELD.store(false, std::sync::atomic::Ordering::SeqCst);
}

#[tauri::command]
fn drag_begin(app: AppHandle) {
    if DRAGGING.swap(true, std::sync::atomic::Ordering::SeqCst) {
        return;
    }
    POINTER_HELD.store(true, std::sync::atomic::Ordering::SeqCst);
    std::thread::spawn(move || {
        let Some(w) = app.get_webview_window("notch") else {
            POINTER_HELD.store(false, std::sync::atomic::Ordering::SeqCst);
            DRAGGING.store(false, std::sync::atomic::Ordering::SeqCst);
            return;
        };
        let (Ok(start_cur), Ok(start_pos), Ok(size)) = (app.cursor_position(), w.outer_position(), w.outer_size()) else {
            POINTER_HELD.store(false, std::sync::atomic::Ordering::SeqCst);
            DRAGGING.store(false, std::sync::atomic::Ordering::SeqCst);
            return;
        };
        let all = screens(&app);
        if all.is_empty() {
            POINTER_HELD.store(false, std::sync::atomic::Ordering::SeqCst);
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
        POINTER_HELD.store(false, std::sync::atomic::Ordering::SeqCst);
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
    crate::open::folder(&dir);
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
    crate::open::url(url);
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
fn set_hot(app: AppHandle, rects: Vec<[f64; 4]>, expanded: bool) {
    *HOT.lock().unwrap() = rects.clone();
    EXPANDED.store(expanded, std::sync::atomic::Ordering::Relaxed);
    #[cfg(target_os = "linux")]
    apply_linux_hot_shape(&app, &rects, expanded);
    #[cfg(not(target_os = "linux"))]
    let _ = app;
    if expanded {
        antigravity::request_hover_refresh();
    }
}

/// GTK's `set_ignore_cursor_events(true)` punches a 1×1 input region and never restores it.
/// Clip hit-testing to the hot rectangles (pill, and while open: tail + card + the gap).
/// A full-window input region makes WebKit invent mousemove coordinates in empty space,
/// which hid and reopened the card on top of the previous paint.
#[cfg(target_os = "linux")]
fn linux_region_from_rects(rects: &[[f64; 4]]) -> Option<gtk::cairo::Region> {
    use gtk::cairo::{RectangleInt, Region};
    if rects.is_empty() {
        return None;
    }
    let pad = HOT_PAD as i32;
    let mut acc: Option<Region> = None;
    for r in rects {
        let rec = RectangleInt::new(
            (r[0] as i32 - pad).max(0),
            (r[1] as i32 - pad).max(0),
            (r[2] as i32 + pad * 2).max(1),
            (r[3] as i32 + pad * 2).max(1),
        );
        match &acc {
            None => acc = Some(Region::create_rectangle(&rec)),
            Some(rg) => {
                let _ = rg.union_rectangle(&rec);
            }
        }
    }
    // Pill ↔ card gap, same rule as cursor_in_hot, so the pointer can cross without dropping.
    if rects.len() > 1 {
        let x0 = rects.iter().map(|r| r[0]).fold(f64::MAX, f64::min) as i32 - pad;
        let y0 = rects.iter().map(|r| r[1]).fold(f64::MAX, f64::min) as i32 - pad;
        let x1 = rects.iter().map(|r| r[0] + r[2]).fold(f64::MIN, f64::max) as i32 + pad;
        let y1 = rects.iter().map(|r| r[1] + r[3]).fold(f64::MIN, f64::max) as i32 + pad;
        let box_rec = RectangleInt::new(x0.max(0), y0.max(0), (x1 - x0).max(1), (y1 - y0).max(1));
        if let Some(rg) = &acc {
            let _ = rg.union_rectangle(&box_rec);
        }
    }
    acc
}

#[cfg(target_os = "linux")]
fn linux_apply_input_region(widget: &impl gtk::prelude::WidgetExt, region: Option<&gtk::cairo::Region>) {
    use gtk::cairo::{RectangleInt, Region};
    widget.input_shape_combine_region(region);
    if let Some(gdk_win) = widget.window() {
        if let Some(region) = region {
            gdk_win.input_shape_combine_region(region, 0, 0);
        } else {
            let full = Region::create_rectangle(&RectangleInt::new(
                0,
                0,
                gdk_win.width().max(1),
                gdk_win.height().max(1),
            ));
            gdk_win.input_shape_combine_region(&full, 0, 0);
        }
    }
}

#[cfg(target_os = "linux")]
fn apply_linux_hot_shape(app: &AppHandle, rects: &[[f64; 4]], expanded: bool) {
    let _ = expanded;
    // Re-applying the same region makes GDK send LeaveNotify while the cursor is still on the
    // pill; that used to hide the card and immediately reopen it, stacking two paints.
    let key: Vec<[i32; 4]> = rects
        .iter()
        .map(|r| [r[0] as i32, r[1] as i32, r[2] as i32, r[3] as i32])
        .collect();
    {
        static LAST: Mutex<Vec<[i32; 4]>> = Mutex::new(Vec::new());
        let mut last = LAST.lock().unwrap();
        if *last == key {
            return;
        }
        *last = key;
    }
    let app = app.clone();
    let rects = rects.to_vec();
    let _ = app.clone().run_on_main_thread(move || {
        let Some(w) = app.get_webview_window("notch") else { return };
        let region = linux_region_from_rects(&rects);
        if region.is_none() {
            return;
        }
        match w.gtk_window() {
            Ok(gtk_win) => linux_apply_input_region(&gtk_win, region.as_ref()),
            Err(e) => applog(&format!("linux input-shape: gtk_window failed: {e}")),
        }
        let rects_view = rects;
        let _ = w.with_webview(move |webview| {
            let region = linux_region_from_rects(&rects_view);
            linux_apply_input_region(&webview.inner(), region.as_ref());
        });
    });
}

/// Setting `WS_EX_TRANSPARENT` by hand instead looks like it should work, and does not: it applies
/// to the notch window, but WebView2 keeps child HWNDs that hit-testing descends into and they
/// never get the bit. `WS_EX_LAYERED` is what makes the window answer as one surface, so the helper
/// that sets both is the only route. Clearing it again is safe — the notch is not otherwise layered
/// (its transparency is DWM composition), so the window returns to the styles it had.
#[cfg(not(target_os = "linux"))]
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
#[cfg(not(target_os = "linux"))]
const LEAVE_MS: u64 = 300;
/// GDK never sees the pointer once it leaves the overlay, so 300 ms of "still inside" is really
/// "stuck open". Two ticks is enough to cross from the pill onto the card.
#[cfg(target_os = "linux")]
const LINUX_LEAVE_MS: u64 = 100;

/// Root-window pointer in physical pixels. GDK's Device::position_double freezes on the last
/// coordinate that hit this process, so a cursor that has already left the notch still looks
/// "inside" and the usage card never collapses.
#[cfg(target_os = "linux")]
fn linux_root_cursor() -> Option<(f64, f64)> {
    use std::ptr;
    use std::sync::{Mutex, OnceLock};
    use x11::xlib;

    struct Dpy(*mut xlib::Display);
    unsafe impl Send for Dpy {}

    static DPY: OnceLock<Mutex<Dpy>> = OnceLock::new();
    let mut guard = DPY
        .get_or_init(|| Mutex::new(Dpy(unsafe { xlib::XOpenDisplay(ptr::null()) })))
        .lock()
        .ok()?;
    if guard.0.is_null() {
        guard.0 = unsafe { xlib::XOpenDisplay(ptr::null()) };
    }
    let dpy = guard.0;
    if dpy.is_null() {
        return None;
    }
    unsafe {
        let root = xlib::XDefaultRootWindow(dpy);
        let mut root_ret = 0;
        let mut child = 0;
        let mut rx = 0;
        let mut ry = 0;
        let mut wx = 0;
        let mut wy = 0;
        let mut mask = 0;
        let ok = xlib::XQueryPointer(
            dpy,
            root,
            &mut root_ret,
            &mut child,
            &mut rx,
            &mut ry,
            &mut wx,
            &mut wy,
            &mut mask,
        );
        if ok == 0 {
            None
        } else {
            Some((rx as f64, ry as f64))
        }
    }
}

fn notch_pointer_sample(app: &AppHandle) -> Option<(f64, f64, i32, i32, Option<(f64, f64)>, Vec<[f64; 4]>)> {
    let w = app.get_webview_window("notch")?;
    let pos = w.outer_position().ok()?;
    #[cfg(target_os = "linux")]
    let (cx, cy) = linux_root_cursor()?;
    #[cfg(not(target_os = "linux"))]
    let cur = app.cursor_position().ok()?;
    #[cfg(not(target_os = "linux"))]
    let (cx, cy) = (cur.x, cur.y);
    let size = w.outer_size().ok().map(|s| (s.width as f64, s.height as f64));
    let rects = HOT.lock().unwrap().clone();
    Some((cx - pos.x as f64, cy - pos.y as f64, pos.x, pos.y, size, rects))
}

fn start_pointer_watchdog(app: AppHandle) {
    std::thread::spawn(move || {
        #[cfg(target_os = "linux")]
        let need = (LINUX_LEAVE_MS / WATCHDOG_MS).max(1) as u8;
        #[cfg(not(target_os = "linux"))]
        let need = (LEAVE_MS / WATCHDOG_MS).max(1) as u8;
        let mut miss = 0u8;
        // Last value pushed: this changes only when the cursor crosses an edge
        #[cfg(not(target_os = "linux"))]
        let mut click_through: Option<bool> = None;
        loop {
            std::thread::sleep(std::time::Duration::from_millis(WATCHDOG_MS));
            let sample = {
                #[cfg(target_os = "linux")]
                {
                    // XQueryPointer is safe off the GTK thread; do not ask GDK for the cursor.
                    notch_pointer_sample(&app)
                }
                #[cfg(not(target_os = "linux"))]
                {
                    notch_pointer_sample(&app)
                }
            };
            let Some((lx, ly, pos_x, pos_y, size, rects)) = sample else { continue };
            let inside = cursor_in_hot(&rects, lx, ly, size);

            // Linux: do not call set_ignore_cursor_events — see apply_linux_hot_shape. The page
            // still needs a pointer_hover poke: WebKitGTK often withholds mousemove on a
            // transparent overlay until the window has been clicked.
            #[cfg(not(target_os = "linux"))]
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
                    "watchdog: cursor_rel=({lx:.0},{ly:.0}) inside={inside} rects={rects:?} winpos=({pos_x},{pos_y})"
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
                    applog(&format!(
                        "watchdog pointer_left cursor_rel=({lx:.0},{ly:.0}) winpos=({pos_x},{pos_y})"
                    ));
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
    tray_visible: bool,
}

#[tauri::command]
fn get_ui_flags(app: AppHandle) -> UiFlags {
    let st = app.state::<AppState>();
    let c = st.cfg.lock().unwrap();
    UiFlags { notch_visible: c.notch_visible, tray_visible: c.tray_visible }
}

/// Hiding both would leave the app running with nothing to click, so the tray icon is kept
/// whenever the notch is off. The answer says what was actually stored, so the settings window can
/// show the corrected state rather than a lie.
#[tauri::command]
fn set_ui_flags(app: AppHandle, notch_visible: bool, tray_visible: bool) -> UiFlags {
    let flags = {
        let st = app.state::<AppState>();
        let mut c = st.cfg.lock().unwrap();
        c.notch_visible = notch_visible;
        c.tray_visible = if notch_visible { tray_visible } else { true };
        config::save(&c);
        UiFlags { notch_visible: c.notch_visible, tray_visible: c.tray_visible }
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
    let list = screens(&app);
    let chosen = target_screen(&app);
    list.iter()
        .enumerate()
        .map(|(i, s)| MonitorInfo {
            id: s.name.clone(),
            label: format!("{}  {} × {}", i + 1, s.w, s.h),
            primary: i == 0,
            current: chosen.as_ref().is_some_and(|c| c.name == s.name && c.x == s.x && c.y == s.y),
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

#[cfg(target_os = "linux")]
const NOTCH_HTML: &str = include_str!("../ui/notch.html");
#[cfg(not(target_os = "linux"))]
const NOTCH_HTML: &str = "";
#[cfg(target_os = "linux")]
pub const SETTINGS_HTML: &str = include_str!("../ui/settings.html");
#[cfg(not(target_os = "linux"))]
pub const SETTINGS_HTML: &str = "";
#[cfg(target_os = "linux")]
pub const HOVER_HTML: &str = include_str!("../ui/hover.html");
#[cfg(not(target_os = "linux"))]
pub const HOVER_HTML: &str = "";

/// WebKitGTK's GPU path (DMA-BUF / EGL) often fails to present on NVIDIA/Wayland and inside an
/// AppImage, which leaves Settings as a blank white surface and the transparent notch invisible.
/// These have to be in the environment before GTK creates the first WebView.
#[cfg(target_os = "linux")]
fn prepare_linux_webview() {
    // SAFETY: called from `main` before any other threads or GTK/WebKit init.
    unsafe {
        // Before GTK opens its display: the hover watchdog uses a second X connection.
        let _ = x11::xlib::XInitThreads();
        for (key, value) in [
            ("GDK_BACKEND", "x11"),
            ("WEBKIT_DISABLE_COMPOSITING_MODE", "1"),
            ("WEBKIT_DISABLE_DMABUF_RENDERER", "1"),
            ("WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS", "1"),
        ] {
            if std::env::var_os(key).is_none() {
                std::env::set_var(key, value);
            }
        }
    }
}

#[cfg(not(target_os = "linux"))]
fn prepare_linux_webview() {}

pub fn new_linux_load_flag() -> std::sync::Arc<std::sync::atomic::AtomicBool> {
    std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false))
}

/// Turns off hardware acceleration on an already-created view and, if the custom protocol never
/// commits a page, injects the HTML directly. Do not call `set_sandbox_enabled` after spawn: WebKit
/// treats that as a fatal g_error.
pub fn tune_linux_webview(
    w: &tauri::WebviewWindow,
    label: &str,
    html: &'static str,
    loaded: std::sync::Arc<std::sync::atomic::AtomicBool>,
) {
    #[cfg(target_os = "linux")]
    {
        use std::sync::atomic::Ordering;
        applog(&format!(
            "{label} url={}",
            w.url().map(|u| u.to_string()).unwrap_or_else(|e| e.to_string())
        ));
        let label_gpu = label.to_string();
        let label_load = label.to_string();
        let label_fail = label.to_string();
        let loaded_ok = loaded.clone();
        if let Err(e) = w.with_webview(move |webview| {
            use webkit2gtk::{HardwareAccelerationPolicy, LoadEvent, SettingsExt, WebViewExt};
            let inner = webview.inner();
            if let Some(settings) = inner.settings() {
                settings.set_hardware_acceleration_policy(HardwareAccelerationPolicy::Never);
            }
            inner.connect_load_changed(move |_, event| {
                crate::applog(&format!("{label_load} webkit load-changed: {event:?}"));
                if matches!(event, LoadEvent::Committed | LoadEvent::Finished) {
                    loaded_ok.store(true, Ordering::SeqCst);
                }
            });
            inner.connect_load_failed(move |_, _, uri, err| {
                crate::applog(&format!("{label_fail} webkit load-failed {uri}: {err}"));
                false
            });
            crate::applog(&format!("{label_gpu}: linux webview tuned (software)"));
        }) {
            applog(&format!("{label}: with_webview failed: {e}"));
        }
        let w2 = w.clone();
        let app = w.app_handle().clone();
        let label_wait = label.to_string();
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(800));
            let _ = app.run_on_main_thread(move || {
                if loaded.load(Ordering::SeqCst) {
                    return;
                }
                applog(&format!("{label_wait}: no webkit load after 800ms, injecting html"));
                let label_inj = label_wait.clone();
                let loaded_inj = loaded.clone();
                if let Err(e) = w2.with_webview(move |webview| {
                    use webkit2gtk::WebViewExt;
                    webview.inner().load_html(html, Some("tauri://localhost"));
                    loaded_inj.store(true, Ordering::SeqCst);
                    crate::applog(&format!("{label_inj}: load_html injected"));
                }) {
                    applog(&format!("{label_wait}: load_html with_webview failed: {e}"));
                }
            });
        });
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = (w, label, html, loaded);
    }
}

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
    prepare_linux_webview();
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
                    _ => Err("usage: codenotch autostart on|off".into()),
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
    applog(&format!(
        "start build={BUILD} compositing={} dmabuf={} sandbox={} gdk={}",
        std::env::var("WEBKIT_DISABLE_COMPOSITING_MODE").unwrap_or_default(),
        std::env::var("WEBKIT_DISABLE_DMABUF_RENDERER").unwrap_or_default(),
        std::env::var("WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS").unwrap_or_default(),
        std::env::var("GDK_BACKEND").unwrap_or_default()
    ));

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
            drag_end,
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
            settings_window::open_author_page,
            hover::hover_show,
            hover::hover_hide,
            hover::hover_keep,
            hover::hover_fit,
            hover::get_hover_html
        ])
        .setup(move |app| {
            let handle = app.handle().clone();
            if let Some(w) = handle.get_webview_window("notch") {
                #[cfg(target_os = "linux")]
                {
                    // WebKitGTK often never paints a focusable:false overlay, so hover never starts.
                    let _ = w.set_focusable(true);
                }
                tune_linux_webview(&w, "notch", NOTCH_HTML, new_linux_load_flag());
                let _ = w.show();
            }
            if let Some(w) = handle.get_webview_window("hover") {
                tune_linux_webview(&w, "hover", HOVER_HTML, new_linux_load_flag());
                let _ = w.hide();
            } else {
                hover::ensure(&handle);
            }
            place_notch(&handle);
            #[cfg(target_os = "linux")]
            {
                // The compositor only assigns a real size after the window is mapped.
                for delay_ms in [80_u64, 300, 1200] {
                    let h = handle.clone();
                    std::thread::spawn(move || {
                        std::thread::sleep(std::time::Duration::from_millis(delay_ms));
                        let hh = h.clone();
                        let _ = h.run_on_main_thread(move || place_notch(&hh));
                    });
                }
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
            // Persist the config (codenotch-hook reads the port from it) and the real
            // launch path (AppImage or exe) so autostart and the hook can find us later.
            {
                let st = handle.state::<AppState>();
                let c = st.cfg.lock().unwrap();
                config::save(&c);
            }
            config::persist_launch_path();
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("Codenotch failed to start");
}

#[cfg(test)]
mod tests {
    use super::{cursor_in_hot, notch_window_size, ring_window, screen_at, Screen, HOT_PAD, NOTCH_H, NOTCH_W};
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

    #[test]
    fn screen_at_picks_the_containing_monitor() {
        let xiaomi = Screen { name: Some("xiaomi".into()), x: 0, y: 0, w: 1080, h: 1920, scale: 1.0 };
        let dp1 = Screen { name: Some("DP-1".into()), x: 1080, y: 256, w: 2560, h: 1440, scale: 1.0 };
        let list = [xiaomi, dp1];
        assert_eq!(screen_at(&list, 100, 100).and_then(|s| s.name.clone()).as_deref(), Some("xiaomi"));
        assert_eq!(screen_at(&list, 3280, 716).and_then(|s| s.name.clone()).as_deref(), Some("DP-1"));
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
