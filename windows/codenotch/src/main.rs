#![cfg_attr(all(not(debug_assertions), windows), windows_subsystem = "windows")]

mod autostart;
mod config;
mod doctor;
mod focus;
mod hooks_install;
mod i18n;
mod notchmenu;
mod server;
mod state;
mod tray;
mod traymenu;
mod usage;
mod claude_auth;
mod codex;
mod cursor;
mod grok;
mod antigravity;
mod glm;
mod opencode;
mod agy_cli;
mod glyphs;
mod trayicon;
mod activity;
mod diag;
mod dropzones;
mod watcher;
mod settings_window;
mod topmost;
mod updater;

use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager};

/// Logical size of the notch window: the 70 pt pill column on the right plus room for the hover card
/// and its tail on the left. `fitZoom` in ui/notch.html divides by the same width.
pub const NOTCH_W: f64 = 360.0;
/// Hand-bumped build tag, written to run.log at startup so a log can always be matched to the exe that wrote it.
pub const BUILD: &str = "r31";
/// The notch window's long side: the upright window's height, and both sides of the flat one.
///
/// Five cells make a 447 px pill; its fillets add 38.7 px at each end and the settings orb reaches
/// 28.5 px past the far one, so 520 cut both fillets and hid the orb. The card wants the same room:
/// 300 clipped it once it held three window blocks plus the session list, and 460 clipped
/// Antigravity's two model groups once the reading was stale and an agent was working.
pub const NOTCH_LONG: f64 = 650.0;

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
    /// GLM Coding Plan snapshot, read from the existing Z.AI tool credentials.
    pub glm: Mutex<usage::UsageSnapshot>,
    /// OpenCode Go plan snapshot, read with OpenCode's own sign-in (auth.json or opencode.db).
    pub opencode: Mutex<usage::UsageSnapshot>,
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
    /// The work area: the monitor less the taskbar and anything else docked to its edges.
    pub work: (i32, i32, i32, i32),
}

impl Screen {
    fn of(m: &tauri::window::Monitor) -> Self {
        let wa = m.work_area();
        Self {
            name: m.name().cloned(),
            x: m.position().x,
            y: m.position().y,
            w: m.size().width as i32,
            h: m.size().height as i32,
            scale: m.scale_factor(),
            work: (wa.position.x, wa.position.y, wa.size.width as i32, wa.size.height as i32),
        }
    }
    /// Where the notch may sit. Falls back to the whole monitor if the platform reports no usable
    /// work area, which would otherwise pin the notch to (0, 0) with no span to move along.
    fn area(&self) -> (i32, i32, i32, i32) {
        let (x, y, w, h) = self.work;
        if w > 0 && h > 0 {
            (x, y, w, h)
        } else {
            (self.x, self.y, self.w, self.h)
        }
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
/// The work area, not the monitor: a notch on the edge the taskbar is docked to would otherwise be
/// covered by it. The Mac places against `frame` rather than `visibleFrame` on purpose, but what it
/// overlaps there is the menu bar, which macOS lets a notch cover; the taskbar wins the z-order
/// among topmost windows and is a click target of its own, so it is room lost.
fn edge_origin(s: &Screen, edge: &str, ww: i32, wh: i32, ratio: f64) -> (i32, i32) {
    let (ax, ay, aw, ah) = s.area();
    let along = |span: i32, len: i32| -> i32 {
        let v = (span as f64 * ratio - len as f64 / 2.0).round() as i32;
        v.clamp(0, (span - len).max(0))
    };
    match edge {
        "left" => (ax, ay + along(ah, wh)),
        "top" => (ax + along(aw, ww), ay),
        "bottom" => (ax + along(aw, ww), ay + ah - wh),
        _ => (ax + aw - ww, ay + along(ah, wh)),
    }
}

/// The landing whose pill is being kept out of sight, or 0. Numbered so a fallback timer from one
/// landing can never reveal the next one early.
static LANDING: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
static LANDING_SEQ: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
/// The landing the page has confirmed it has painted empty for.
static LANDING_HIDDEN: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
/// Longest a landing stays out of sight if the page never reports a settled layout.
const LANDING_FALLBACK_MS: u64 = 700;

/// Places the notch on a screen at another scale without the change of scale showing.
///
/// Arriving there, Windows resizes the window by the ratio of the two scales before `place_notch`
/// puts it right, and the page then re-zooms itself for the new pixel ratio a debounce later, which
/// can bring one more zoom correction from `report_dpr`. All of that played out on screen as the
/// notch jumping sizes as it landed. Hiding the window did not help: a hidden WebView2 stops painting
/// and throttles its timers, so the page only caught up once it was shown again, in plain view.
///
/// So the window stays up and the page empties itself instead — the window is transparent, so an
/// empty page is an invisible notch — while the WebView keeps doing its layout. It is revealed when
/// the page reports a layout that has stopped changing (`report_dpr` with `settled`), not after a
/// guessed delay. At the same scale nothing is resized on arrival, so there is nothing to hide.
fn land_on_another_screen(app: &AppHandle, from_scale: f64, to_scale: f64) {
    if (from_scale - to_scale).abs() < 0.01 {
        return place_notch(app);
    }
    use std::sync::atomic::Ordering::SeqCst;
    let gen = LANDING_SEQ.fetch_add(1, SeqCst) + 1;
    LANDING.store(gen, SeqCst);
    let _ = app.emit_to("notch", "notch_landing", ());
    // Moved before the page has painted itself empty, the jump would show after all
    for _ in 0..40 {
        if LANDING_HIDDEN.load(SeqCst) == gen {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    place_notch(app);
    let app = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(LANDING_FALLBACK_MS));
        if LANDING.compare_exchange(gen, 0, SeqCst, SeqCst).is_ok() {
            applog("notch landing: no settled layout reported, shown anyway");
            let _ = app.emit_to("notch", "notch_reveal", ());
        }
    });
}

/// The page has painted itself empty for the landing in progress.
#[tauri::command]
fn notch_hidden() {
    use std::sync::atomic::Ordering::SeqCst;
    LANDING_HIDDEN.store(LANDING.load(SeqCst), SeqCst);
}

/// The screen the pointer is over, for a carry that can cross between them. None in the gap a
/// smaller screen leaves beside a larger one, where the carry stays on the screen it was last over.
fn screen_at(list: &[Screen], x: f64, y: f64) -> Option<&Screen> {
    list.iter()
        .find(|s| x >= s.x as f64 && x < (s.x + s.w) as f64 && y >= s.y as f64 && y < (s.y + s.h) as f64)
}

/// By where it is rather than by name, which the platform is not obliged to report.
fn same_screen(a: &Screen, b: &Screen) -> bool {
    (a.x, a.y, a.w, a.h) == (b.x, b.y, b.w, b.h)
}

/// `edge_origin` run backwards along one axis: where a window at `pos`, `len` long, has its centre,
/// as a fraction of the span from `start`. What a slide along the edge saves, so it lands exactly
/// where it was let go.
fn along_at(pos: i32, len: i32, start: i32, span: i32) -> f64 {
    (((pos - start) as f64 + len as f64 / 2.0) / span.max(1) as f64).clamp(0.0, 1.0)
}

/// How far the taskbar (or anything else outside the work area) covers each side of a window at
/// (x, y, ww, wh), in physical pixels: top, right, bottom, left. `edge_origin` keeps the pill itself
/// out of the taskbar, so what is left here is the window's other three sides — an upright notch is
/// taller than the work area is on a short screen — and the hover card is what the page moves.
fn work_insets(s: &Screen, x: i32, y: i32, ww: i32, wh: i32) -> [i32; 4] {
    let (wx, wy, waw, wah) = s.work;
    [
        (wy - y).clamp(0, wh),
        ((x + ww) - (wx + waw)).clamp(0, ww),
        ((y + wh) - (wy + wah)).clamp(0, wh),
        (wx - x).clamp(0, ww),
    ]
}

/// The last insets pushed to the page, in its CSS px, for a page that asks before it was listening.
static NOTCH_INSETS: Mutex<[f64; 4]> = Mutex::new([0.0; 4]);

/// Pins the notch to the configured edge of the configured monitor.
/// The notch window's logical size for an edge.
///
/// Upright on the left and right, the pill is a column and 360 wide is plenty; its length is what
/// needs room, hence `NOTCH_LONG`. Lying flat on the top and bottom it is a row: six 44 px rings,
/// their gaps, the padding, both fillets and the settings orb come to about 504 px, so a 360 px
/// window clipped the pill once a fifth provider was on. It is square, because the card opens above
/// or below the pill there instead of beside it, and so needs the pill's own depth on top of its
/// height — at 520 a stale Antigravity card scrolled.
pub fn notch_window_size(edge: &str) -> (f64, f64) {
    if config::edge_is_vertical(edge) {
        (NOTCH_W, NOTCH_LONG)
    } else {
        (NOTCH_LONG, NOTCH_LONG)
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
        // Never taller or wider than the screen: Large on a small, highly scaled display can ask for more
        let target = tauri::PhysicalSize::new(
            ((width * ms * size).round() as u32).min(mon.w.max(1) as u32),
            ((height * ms * size).round() as u32).min(mon.h.max(1) as u32),
        );
        let _ = w.set_size(target);
        zoom_notch(&w, ms, size);
        // Position from the window's measured physical size — deriving it from the scale factor
        // pushed the window past the right edge at 125 % / 150 % (the ring's right side was clipped).
        let (ww, wh) = w
            .outer_size()
            .map(|s| (s.width as i32, s.height as i32))
            .unwrap_or((target.width as i32, target.height as i32));
        let ratio = {
            let st = app.state::<AppState>();
            let c = st.cfg.lock().unwrap();
            c.along(&edge)
        };
        let (x, y) = edge_origin(&mon, &edge, ww, wh, ratio);
        let _ = w.set_position(tauri::PhysicalPosition::new(x, y));
        let mut placed = (x, y, ww, wh);
        if w.outer_size().map(|s| s.width != target.width).unwrap_or(false) {
            let _ = w.set_size(target);
            let (x, y) = edge_origin(&mon, &edge, target.width as i32, target.height as i32, ratio);
            let _ = w.set_position(tauri::PhysicalPosition::new(x, y));
            placed = (x, y, target.width as i32, target.height as i32);
        }
        // The page mirrors itself for the edge it is on; it cannot know that on its own.
        let _ = w.emit("notch_edge", &edge);
        // Nor can it see the taskbar: a card opened near the bottom of a side edge slid under it.
        // The page is `size` × the monitor scale smaller than the window in CSS px.
        let css = (ms * size).max(0.01);
        let insets = work_insets(&mon, placed.0, placed.1, placed.2, placed.3).map(|v| v as f64 / css);
        *NOTCH_INSETS.lock().unwrap() = insets;
        let _ = w.emit("notch_insets", insets);
        // Placement log line: the first thing to check when the notch is not visible. Appended, not
        // overwritten (#240) — place_notch runs after every drag as well as at startup, and a
        // truncating write wiped the rest of the session's diagnostic trail on every drag.
        applog(&format!(
            "notch placed build={BUILD}: edge={edge} pos=({x},{y}) size=({ww}x{wh}) inner={:?} win_scale={scale} mon_scale={ms} notch_size={size} monitor={:?}=({},{} {}x{}) work={:?} card_insets_css={insets:?}",
            w.inner_size().map(|s| (s.width, s.height)).unwrap_or((0, 0)),
            mon.name,
            mon.x,
            mon.y,
            mon.w,
            mon.h,
            mon.work
        ));
    }
}

/// How often the work area is re-read. It only changes by hand — the taskbar moved to another edge,
/// resized, or switched to auto-hide — so a second late is not noticeable.
const WORK_AREA_POLL_MS: u64 = 1000;

/// Puts the notch back on its edge when the work area moves under it.
///
/// Nothing hands us `WM_SETTINGCHANGE`, and the notch is placed against the work area now, so
/// moving the taskbar to another edge would otherwise leave the notch a taskbar's width from the
/// edge it is pinned to, floating in the gap the old taskbar left. Polled rather than hooked,
/// because hooking it means subclassing a window we do not own to catch something that happens
/// once in a session.
fn start_work_area_watch(app: AppHandle) {
    std::thread::spawn(move || {
        let mut last = target_screen(&app).map(|s| s.work);
        let mut last_theme = resolved_theme(&app);
        loop {
            std::thread::sleep(std::time::Duration::from_millis(WORK_AREA_POLL_MS));
            // Mid-drag the notch is following the pointer, and placing it again would fight that.
            if DRAGGING.load(std::sync::atomic::Ordering::SeqCst) {
                continue;
            }
            let system = resolved_theme(&app);
            if system != last_theme {
                applog(&format!("appearance changed: {last_theme} -> {system}"));
                last_theme = system;
                apply_theme(&app);
            }
            let now = target_screen(&app).map(|s| s.work);
            if now == last {
                continue;
            }
            applog(&format!("work area changed: {last:?} -> {now:?}"));
            last = now;
            place_notch(&app);
        }
    });
}

/// Older entry point name still used by tray.rs. Recentre puts the notch in the middle of the edge it
/// is on, and only sends it home to the primary monitor's right edge when the screen it was on is
/// gone — which is the case the button exists for, and the one where its own edge means nothing.
pub fn reset_bar(app: &AppHandle) {
    let stranded = {
        let st = app.state::<AppState>();
        let want = st.cfg.lock().unwrap().notch_monitor.clone();
        want.is_some_and(|name| !screens(app).iter().any(|s| s.name.as_deref() == Some(name.as_str())))
    };
    {
        let st = app.state::<AppState>();
        let mut c = st.cfg.lock().unwrap();
        if stranded {
            c.notch_edge = "right".into();
            c.notch_monitor = None;
        }
        // Only the edge it is on: the others keep wherever they were left, as on the Mac
        let edge = config::edge_or_right(&c.notch_edge);
        c.set_along(&edge, 0.5);
        config::save(&c);
    }
    place_notch(app);
}

/// Drag. The page calls this once after an Alt-press on the pill moves more than 4 px; from then on
/// a Rust thread follows the system cursor (WebView mousemove is unreliable once the window itself
/// starts moving). Only the axis along the notch's edge follows it: this slides the notch along the
/// edge it is on and never takes it to another, which is the move handle's job — the Mac's ⌥-drag
/// (`NotchWindowController.dragged`). Releasing it saves that place for that edge alone.
pub(crate) static DRAGGING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

#[cfg(windows)]
fn left_button_down() -> bool {
    use windows::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_LBUTTON};
    unsafe { (GetAsyncKeyState(VK_LBUTTON.0 as i32) as u16 & 0x8000) != 0 }
}
#[cfg(not(windows))]
fn left_button_down() -> bool {
    false
}

/// Which edge a point belongs to: the screen split into four triangles about its centre, as on the
/// Mac. Nearest-edge rather than hit testing the zones, which are thin — landing inside a 70 px strip
/// would be threading a needle.
pub(crate) fn edge_at(x: f64, y: f64, w: f64, h: f64) -> &'static str {
    let (left, right, top, bottom) = (x, w - x, y, h - y);
    let nearest = left.min(right).min(top).min(bottom);
    if nearest == right {
        "right"
    } else if nearest == left {
        "left"
    } else if nearest == top {
        "top"
    } else {
        "bottom"
    }
}

/// Carrying the notch by its move handle: the zones go up, the pointer picks one, and releasing
/// hands it over. The notch itself stays where it is until then — what is being chosen is a place on
/// the screen, not a distance moved, so nothing follows the pointer.
///
/// `depth` and `length` are the pill's own measurements standing upright, in the notch page's CSS px.
#[tauri::command]
fn begin_move(app: AppHandle, depth: f64, length: f64) {
    if DRAGGING.swap(true, std::sync::atomic::Ordering::SeqCst) {
        return;
    }
    std::thread::spawn(move || {
        let done = |app: &AppHandle| {
            dropzones::hide(app);
            DRAGGING.store(false, std::sync::atomic::Ordering::SeqCst);
            let _ = app.emit("move_end", ());
        };
        let Some(start) = target_screen(&app) else {
            done(&app);
            return;
        };
        let from = {
            let st = app.state::<AppState>();
            let c = st.cfg.lock().unwrap();
            config::edge_or_right(&c.notch_edge)
        };
        // The overlay is at the monitor's own scale; the notch page is that scale times its size
        let size = ui_scale(&app);
        // Every figure here is the work area's, to match the overlay window and the notch itself:
        // the zone drawn on the taskbar's edge has to sit where the notch will, and the edge the
        // pointer picks has to be read against the same rectangle the zones are drawn in.
        let zones_on = |s: &Screen, target: &str| {
            let (_, _, aw, ah) = s.area();
            dropzones::Zones {
                w: aw as f64 / s.scale,
                h: ah as f64 / s.scale,
                depth: depth * size,
                length: length * size,
                target: target.to_string(),
            }
        };
        let all = screens(&app);
        let mut mon = start.clone();
        let mut zones = zones_on(&mon, &from);
        dropzones::show(&app, &mon, &zones);
        let mut target = from.clone();
        while left_button_down() {
            if let Ok(cur) = app.cursor_position() {
                // Crossing onto another screen takes the zones with it. The silhouette is in logical
                // px, so it keeps its size on a screen at another scale, exactly as the notch will.
                if let Some(s) = screen_at(&all, cur.x, cur.y) {
                    if !same_screen(s, &mon) {
                        mon = s.clone();
                        zones = zones_on(&mon, &target);
                        dropzones::relocate(&app, &mon, &zones);
                    }
                }
                let (ax, ay, aw, ah) = mon.area();
                let next = edge_at(cur.x - ax as f64, cur.y - ay as f64, aw as f64, ah as f64);
                if next != target {
                    target = next.to_string();
                    zones.target = target.clone();
                    dropzones::retarget(&app, &zones);
                    let _ = app.emit("move_target", &target);
                }
            }
            std::thread::sleep(std::time::Duration::from_millis(16));
        }
        // The right edge of another screen is a move too, though the edge has the same name
        let mut crossed = !same_screen(&mon, &start);
        // A screen Windows will not name has nothing stable to remember it by, which is why the
        // picker in Settings lists those disabled. Saving `None` would not mean "this screen", it
        // means "the primary", so the notch would jump off it at the next placement. Take the edge
        // the carry chose and leave it on the screen it came from rather than record a move that
        // will not survive.
        let unnameable = crossed && mon.name.is_none();
        if unnameable {
            crossed = false;
        }
        applog(&format!(
            "notch carry: {from} -> {target} on {:?}{}",
            mon.name,
            if unnameable { " (unnamed screen, staying put)" } else { "" }
        ));
        if target != from || crossed || unnameable {
            {
                let st = app.state::<AppState>();
                let mut c = st.cfg.lock().unwrap();
                // It lands where it was last left on that edge — centred, like the zone it was
                // offered, on an edge it has never been slid along
                c.notch_edge = target.clone();
                if !unnameable {
                    c.notch_monitor = mon.name.clone();
                }
                config::save(&c);
            }
            if crossed {
                land_on_another_screen(&app, start.scale, mon.scale);
            } else {
                place_notch(&app);
            }
        }
        done(&app);
    });
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
        let Some(mon) = target_screen(&app) else {
            DRAGGING.store(false, std::sync::atomic::Ordering::SeqCst);
            return;
        };
        let edge = {
            let st = app.state::<AppState>();
            let c = st.cfg.lock().unwrap();
            config::edge_or_right(&c.notch_edge)
        };
        let vertical = config::edge_is_vertical(&edge);
        let (ww, wh) = (size.width as i32, size.height as i32);
        // The span `edge_origin` places against, so it cannot be slid under the taskbar
        let (ax, ay, aw, ah) = mon.area();
        let (mut last_x, mut last_y) = (start_pos.x, start_pos.y);
        let mut moved = false;
        loop {
            if !left_button_down() {
                break;
            }
            if let Ok(cur) = app.cursor_position() {
                let (nx, ny) = if vertical {
                    let y = (start_pos.y as f64 + (cur.y - start_cur.y)).round() as i32;
                    (start_pos.x, y.clamp(ay, (ay + ah - wh).max(ay)))
                } else {
                    let x = (start_pos.x as f64 + (cur.x - start_cur.x)).round() as i32;
                    (x.clamp(ax, (ax + aw - ww).max(ax)), start_pos.y)
                };
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
            let along = if vertical { along_at(last_y, wh, ay, ah) } else { along_at(last_x, ww, ax, aw) };
            {
                let st = app.state::<AppState>();
                let mut c = st.cfg.lock().unwrap();
                c.set_along(&edge, along);
                config::save(&c);
            }
            applog(&format!("notch slid along {edge} to {along:.3}"));
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
fn claude_sign_in() -> Result<(), String> { claude_auth::start_login() }

#[tauri::command]
fn get_claude_auth() -> claude_auth::AuthState { claude_auth::state() }

/// Asks one provider to read again, and says whether a reading is on its way. Claude's rate-limit
/// wait stands, as on the Mac: asking early spends a request and can double the wait.
pub(crate) fn refresh_provider(app: &AppHandle, provider: &str) -> bool {
    match provider {
        "claude" => {
            if app.state::<AppState>().usage.lock().unwrap().backoff_until > now_ms() {
                return false;
            }
            usage::request_refresh();
        }
        "codex" => codex::request_refresh(),
        "cursor" => cursor::request_refresh(),
        "grok" => grok::request_refresh(),
        "gemini" => antigravity::request_refresh(),
        "glm" => glm::request_refresh(),
        "opencode" => opencode::request_refresh(),
        _ => return false,
    }
    true
}

pub(crate) fn refresh_all(app: &AppHandle) {
    for provider in TRAY_PROVIDER_IDS {
        refresh_provider(app, provider);
    }
    let a = app.clone();
    std::thread::spawn(move || reload_glyphs(&a));
}

/// A click on a ring refetches that provider, as on the Mac.
#[tauri::command]
fn refresh_ring(app: AppHandle, provider: String) -> bool {
    refresh_provider(&app, &provider)
}

#[tauri::command]
fn get_antigravity(state: tauri::State<AppState>) -> usage::UsageSnapshot {
    state.antigravity.lock().unwrap().clone()
}

#[tauri::command]
fn get_glm(state: tauri::State<AppState>) -> usage::UsageSnapshot {
    state.glm.lock().unwrap().clone()
}

#[tauri::command]
fn get_opencode(state: tauri::State<AppState>) -> usage::UsageSnapshot {
    state.opencode.lock().unwrap().clone()
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

/// A provider's usage page, and the host the notch menu names it by.
pub(crate) fn provider_page(provider: &str) -> Option<(&'static str, &'static str)> {
    Some(match provider {
        "claude" => ("https://claude.ai/settings/usage", "claude.ai"),
        "codex" => ("https://chatgpt.com/#settings/Account", "chatgpt.com"),
        "cursor" => ("https://cursor.com/dashboard", "cursor.com"),
        "grok" => ("https://grok.com/?_s=usage", "grok.com"),
        "gemini" => ("https://antigravity.google", "antigravity.google"),
        "glm" => ("https://z.ai/manage-apikey/apikey-list", "z.ai"),
        "opencode" => ("https://opencode.ai", "opencode.ai"),
        _ => return None,
    })
}

pub(crate) fn open_provider_page(provider: &str) {
    let Some((url, _)) = provider_page(provider) else { return };
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

/// run.log never grows past this. The placement line used to rewrite the file on every drag,
/// which was the only thing that ever emptied it; appended instead, it needs a bound of its own.
const RUN_LOG_MAX_BYTES: u64 = 1024 * 1024;

pub fn applog(line: &str) {
    use std::io::Write;
    let log = config::config_path().with_file_name("run.log");
    // Past the cap the log starts again rather than growing for as long as the app runs.
    let full = std::fs::metadata(&log).map(|m| m.len() > RUN_LOG_MAX_BYTES).unwrap_or(false);
    let opened = if full {
        std::fs::File::create(&log)
    } else {
        std::fs::OpenOptions::new().create(true).append(true).open(&log)
    };
    if let Ok(mut f) = opened {
        let _ = writeln!(f, "{line}");
    }
}

/// Root cause: with two monitors (150 % / 200 %) WebView2 picked a devicePixelRatio of 2.0 while
/// the window was sized for the primary monitor's 1.5, so the page was 255 CSS px wide instead of
/// the designed 340 and every coordinate conversion was off (the watchdog misfired and the card
/// flashed away). Fix: the page reports its DPR, and when it differs from the primary monitor's
/// scale, set_zoom pulls the effective DPR back to that scale, restoring the 340 px width.
///
/// `settled` is true when the report comes at the end of a burst of resizes rather than partway
/// through one, which is what a landing on another screen waits for before it shows the notch.
#[tauri::command]
fn report_dpr(app: AppHandle, dpr: f64, w: f64, h: f64, settled: Option<bool>) {
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
    let mut corrected = false;
    if (dpr - want).abs() > 0.02
        && (target - *z).abs() > 0.01
        && (0.25..=4.0).contains(&target)
        && APPLIED.fetch_add(1, std::sync::atomic::Ordering::Relaxed) < 3
    {
        match win.set_zoom(target) {
            Ok(()) => {
                *z = target;
                corrected = true;
                applog(&format!("dpr correction: set_zoom({target:.3}) ok"));
            }
            Err(e) => applog(&format!("dpr correction failed: {e}")),
        }
    }
    // A correction resizes the page once more, and its own settled report follows; the landing is
    // shown on the first settled report that needed none
    if settled == Some(true) && !corrected && LANDING.swap(0, std::sync::atomic::Ordering::SeqCst) != 0 {
        let _ = app.emit_to("notch", "notch_reveal", ());
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
        let mut miss = 0u8;
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

            if click_through != Some(!inside) {
                set_click_through(&app, !inside);
                click_through = Some(!inside);
                // Show on hover opens on this and folds a moment after it goes false. The page cannot
                // tell on its own: once click-through is back on, it is sent nothing at all.
                let _ = app.emit_to("notch", "notch_pointer", inside);
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

/// The saved choice as a window theme. `None` is "follow Windows", which is also what an
/// unreadable value falls back to, and what a window gets when it is built without asking.
pub fn theme_choice(app: &AppHandle) -> Option<tauri::Theme> {
    let st = app.state::<AppState>();
    let c = st.cfg.lock().unwrap();
    match c.theme.as_str() {
        "light" => Some(tauri::Theme::Light),
        "dark" => Some(tauri::Theme::Dark),
        _ => None,
    }
}

/// Sets the appearance on the document before the page's own scripts run, so a window built for one
/// carry, or opened on a dark Windows under a light choice, never paints the other one first. The
/// element may not exist yet when this runs, which is the point of the retry.
pub fn theme_script(theme: &str) -> String {
    format!(
        "window.__CN_THEME__={theme:?};(function a(){{const d=document.documentElement;if(d){{d.dataset.theme=window.__CN_THEME__;}}else{{document.addEventListener('readystatechange',a,{{once:true}});}}}})();"
    )
}

/// Which of the two appearances is actually on: the choice, or what Windows is set to when it is
/// "system". Read from the notch window, whose theme tao keeps in step with Windows.
pub fn resolved_theme(app: &AppHandle) -> &'static str {
    match theme_choice(app) {
        Some(tauri::Theme::Light) => "light",
        Some(tauri::Theme::Dark) => "dark",
        _ => match app.get_webview_window("notch").and_then(|w| w.theme().ok()) {
            Some(tauri::Theme::Light) => "light",
            _ => "dark",
        },
    }
}

/// The pages switch their palette on this, rather than on `prefers-color-scheme`: correcting a live
/// window's theme does not reliably reach WebView2's own scheme, which left a dark Settings page
/// under light Mica, unreadable. Told plainly instead.
#[tauri::command]
fn get_theme_resolved(app: AppHandle) -> String {
    resolved_theme(&app).to_string()
}

/// Light, Dark, or whatever Windows is set to.
///
/// One call does both pages: WebView2 turns a window's theme into `prefers-color-scheme`, which is
/// what the pages' palettes are written against. `None` hands the choice back to Windows. Settings
/// also sits on Mica, which follows the system on its own, so it is asked for the matching variant
/// rather than left dark under a light page.
pub fn apply_theme(app: &AppHandle) {
    let theme = theme_choice(app);
    for label in ["notch", "settings", dropzones::LABEL] {
        if let Some(w) = app.get_webview_window(label) {
            let _ = w.set_theme(theme);
        }
    }
    settings_window::follow_theme(app, theme);
    let _ = app.emit("theme_resolved", resolved_theme(app));
}

/// Which appearance the pages draw in.
#[tauri::command]
fn get_theme(app: AppHandle) -> String {
    let st = app.state::<AppState>();
    let c = st.cfg.lock().unwrap();
    c.theme.clone()
}

/// Unknown values are refused rather than stored, as the other rows do.
#[tauri::command]
fn set_theme(app: AppHandle, theme: String) -> String {
    let value = {
        let st = app.state::<AppState>();
        let mut c = st.cfg.lock().unwrap();
        if ["system", "light", "dark"].contains(&theme.as_str()) {
            c.theme = theme;
            config::save(&c);
        }
        c.theme.clone()
    };
    apply_theme(&app);
    let _ = app.emit("theme", &value);
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

/// How the usage rings change colour as the allowance is used.
#[tauri::command]
fn get_color_transition(app: AppHandle) -> String {
    let st = app.state::<AppState>();
    let c = st.cfg.lock().unwrap();
    c.color_transition.clone()
}

/// Unknown values keep the existing hard steps. The notch redraws when it receives this event.
#[tauri::command]
fn set_color_transition(app: AppHandle, style: String) -> String {
    let value = {
        let st = app.state::<AppState>();
        let mut c = st.cfg.lock().unwrap();
        c.color_transition = config::color_transition_or_step(&style);
        config::save(&c);
        c.color_transition.clone()
    };
    let _ = app.emit("color_transition", &value);
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
        "codex" => by_id("primary"),
        "cursor" => by_id("included").or_else(|| by_id("api")),
        "grok" => by_id("credits").or_else(|| windows.first()),
        // The Mac sets headlineID "session", weeklyID "weekly". Without this the
        // plan falls through to Antigravity's lane picker and the ring shows the
        // tightest window it can find instead of the session.
        "glm" => by_id("session"),
        // The Mac sets headlineID "rolling", weeklyID "weekly".
        "opencode" => by_id("rolling"),
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
        "glm" => st.glm.lock().unwrap().clone(),
        "opencode" => st.opencode.lock().unwrap().clone(),
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

#[derive(serde::Serialize, Clone)]
struct UiFlags {
    notch_visible: bool,
    notch_on_hover: bool,
    tray_visible: bool,
}

fn ui_flags(c: &config::Config) -> UiFlags {
    UiFlags { notch_visible: c.notch_visible, notch_on_hover: c.notch_on_hover, tray_visible: c.tray_visible }
}

#[tauri::command]
fn get_ui_flags(app: AppHandle) -> UiFlags {
    let st = app.state::<AppState>();
    let c = st.cfg.lock().unwrap();
    ui_flags(&c)
}

/// Hiding both would leave the app running with nothing to click, so the tray icon is kept
/// whenever the notch is off. The answer says what was actually stored, so the settings window can
/// show the corrected state rather than a lie. Show on hover is not "off": the pill stays on screen.
#[tauri::command]
fn set_ui_flags(app: AppHandle, notch_visible: bool, tray_visible: bool, notch_on_hover: Option<bool>) -> UiFlags {
    let flags = {
        let st = app.state::<AppState>();
        let mut c = st.cfg.lock().unwrap();
        c.notch_visible = notch_visible;
        if let Some(on_hover) = notch_on_hover {
            c.notch_on_hover = on_hover;
        }
        c.tray_visible = if notch_visible { tray_visible } else { true };
        config::save(&c);
        ui_flags(&c)
    };
    apply_visibility(&app);
    flags
}

/// The notch menu's Keep open: the Mac's own shortcut between Always show and Show on hover
/// (`onToggleKeepOpen` flips `notchVisibility`), so it is the same setting from another place.
pub fn toggle_keep_open(app: &AppHandle) {
    {
        let st = app.state::<AppState>();
        let mut c = st.cfg.lock().unwrap();
        c.notch_on_hover = !c.notch_on_hover;
        config::save(&c);
    }
    apply_visibility(app);
}

pub fn keeps_open(app: &AppHandle) -> bool {
    let st = app.state::<AppState>();
    let c = st.cfg.lock().unwrap();
    !c.notch_on_hover
}

/// Puts the two switches into effect.
pub fn apply_visibility(app: &AppHandle) {
    let (notch, tray_on, flags) = {
        let st = app.state::<AppState>();
        let c = st.cfg.lock().unwrap();
        (c.notch_visible, c.tray_visible, ui_flags(&c))
    };
    // The page folds or stays open by these, and the Settings window redraws its Show row from them
    // when Keep open changed them from the notch's own menu
    let _ = app.emit("ui_flags", flags);
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

/// How much of the notch window the taskbar covers, in the page's CSS px: top, right, bottom, left.
#[tauri::command]
fn get_notch_insets() -> [f64; 4] {
    *NOTCH_INSETS.lock().unwrap()
}

/// Which screen edge the notch is pinned to.
#[tauri::command]
fn get_notch_edge(app: AppHandle) -> String {
    let st = app.state::<AppState>();
    let c = st.cfg.lock().unwrap();
    config::edge_or_right(&c.notch_edge)
}

/// Moving to another edge puts the notch where it was last left on that edge, or centred if it has
/// never been slid along it — each edge keeps its own place, as on the Mac.
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

#[tauri::command]
fn get_move_handle(app: AppHandle) -> bool {
    let st = app.state::<AppState>();
    let c = st.cfg.lock().unwrap();
    c.show_move_handle
}

#[tauri::command]
fn set_move_handle(app: AppHandle, on: bool) -> bool {
    {
        let st = app.state::<AppState>();
        let mut c = st.cfg.lock().unwrap();
        c.show_move_handle = on;
        config::save(&c);
    }
    let _ = app.emit("move_handle", on);
    on
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
        "glm" => "z.ai",
        "opencode" => "OpenCode",
        _ => "Claude",
    }
}

/// Every provider the tray menu can offer, in the order the notch shows them.
pub const TRAY_PROVIDER_IDS: [&str; 7] = ["claude", "codex", "glm", "opencode", "cursor", "grok", "gemini"];

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
        .plugin(tauri_plugin_updater::Builder::new().build())
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
            glm: Mutex::new(glm::load_persisted()),
            opencode: Mutex::new(opencode::load_persisted()),
            glyphs: Mutex::new(Default::default()),
            activity: Mutex::new(Vec::new()),
        })
        .invoke_handler(tauri::generate_handler![
            get_state,
            get_usage,
            claude_sign_in,
            get_claude_auth,
            updater::get_update_state,
            updater::check_for_update,
            updater::install_update,
            get_codex,
            get_cursor,
            get_grok,
            get_antigravity,
            get_glm,
            get_opencode,
            get_glyphs,
            get_activity,
            open_data_dir,
            drag_begin,
            refresh_ring,
            notchmenu::show_notch_menu,
            set_hot,
            report_dpr,
            notch_hidden,
            log_js,
            focus_session,
            dismiss_session,
            set_lang,
            get_scale,
            set_scale,
            get_weekly_ring,
            set_weekly_ring,
            get_color_transition,
            set_color_transition,
            get_theme,
            set_theme,
            get_theme_resolved,
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
            get_notch_insets,
            set_notch_edge,
            get_monitors,
            set_notch_monitor,
            open_settings,
            begin_move,
            get_move_handle,
            set_move_handle,
            dropzones::get_zones,
            settings_window::get_system_look,
            settings_window::quit_app,
            settings_window::open_author_page
        ])
        .setup(move |app| {
            let handle = app.handle().clone();
            place_notch(&handle);
            // Before the notch is shown: a window shown on the system appearance and corrected
            // after paints the wrong one for a frame, which is a black flash under a light choice
            apply_theme(&handle);
            if let Some(w) = handle.get_webview_window("notch") {
                let _ = w.show();
            }
            tray::setup(&handle)?;
            notchmenu::setup(&handle);
            start_menu_updater(handle.clone());
            updater::check_on_launch(&handle);
            // Honours the saved switches: a notch hidden last time stays hidden.
            apply_visibility(&handle);
            server::start(handle.clone(), port);
            watcher::start(handle.clone());
            usage::start(handle.clone());
            codex::start(handle.clone());
            cursor::start(handle.clone());
            grok::start(handle.clone());
            antigravity::start(handle.clone());
            glm::start(handle.clone());
            opencode::start(handle.clone());
            activity::start(handle.clone());
            // Collecting glyphs may read icon resources out of a few executables; do it off the main thread and push when done
            let gh = handle.clone();
            std::thread::spawn(move || reload_glyphs(&gh));
            start_pointer_watchdog(handle.clone());
            start_work_area_watch(handle.clone());
            topmost::start_watchdog(handle.clone());
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
    use super::{
        cursor_in_hot, notch_window_size, provider_page, ring_window, work_insets, Screen, HOT_PAD,
        NOTCH_W, TRAY_PROVIDER_IDS,
    };
    use crate::usage::LimitWindow;

    /// A provider added without a page of its own used to fall through to Claude's
    #[test]
    fn every_provider_opens_its_own_page() {
        let mut hosts: Vec<&str> = TRAY_PROVIDER_IDS
            .iter()
            .map(|id| provider_page(id).unwrap_or_else(|| panic!("{id} has no usage page")).1)
            .collect();
        hosts.sort();
        hosts.dedup();
        assert_eq!(hosts.len(), TRAY_PROVIDER_IDS.len());
        assert_eq!(provider_page("nobody"), None);
    }

    #[test]
    fn the_taskbar_is_measured_against_the_window() {
        // 3200 × 2000 with a 72 px taskbar along the bottom
        let s = Screen { name: None, x: 0, y: 0, w: 3200, h: 2000, scale: 1.5, work: (0, 0, 3200, 1928) };
        assert_eq!(work_insets(&s, 2768, 1376, 432, 624), [0, 0, 72, 0], "right edge, at the bottom");
        assert_eq!(work_insets(&s, 2768, 512, 432, 624), [0, 0, 0, 0], "right edge, clear of it");
        assert_eq!(work_insets(&s, 1000, 1928, 624, 624).map(|v| v <= 624), [true; 4], "never more than the window");
        // A taskbar on the left
        let s = Screen { work: (72, 0, 3128, 2000), ..s };
        assert_eq!(work_insets(&s, 0, 700, 432, 624), [0, 0, 0, 72]);
    }

    /// A slide along the edge saves `along_at` and the next placement reads it back through
    /// `edge_origin`, so the two must be exact inverses or the notch jumps when it is let go.
    #[test]
    fn a_slid_notch_lands_where_it_was_let_go() {
        let s = Screen { name: None, x: 0, y: 0, w: 3200, h: 2000, scale: 1.5, work: (0, 0, 3200, 1928) };
        for along in [0.2, 0.5, 0.73] {
            let (_, y) = super::edge_origin(&s, "right", 432, 624, along);
            assert!((super::along_at(y, 624, 0, 1928) - along).abs() < 1e-3, "right at {along}");
            let (x, _) = super::edge_origin(&s, "top", 624, 624, along);
            assert!((super::along_at(x, 624, 0, 3200) - along).abs() < 1e-3, "top at {along}");
        }
        // Pushed hard against an end, what it saves is the end it stopped at, not the pointer
        let (_, y) = super::edge_origin(&s, "right", 432, 624, 0.0);
        assert_eq!(super::edge_origin(&s, "right", 432, 624, super::along_at(y, 624, 0, 1928)).1, y);
    }

    /// A notch on the edge the taskbar is docked to used to sit under it.
    #[test]
    fn the_notch_is_placed_inside_the_work_area() {
        // 3200 × 2000 with a 72 px taskbar along the bottom
        let s = Screen { name: None, x: 0, y: 0, w: 3200, h: 2000, scale: 1.5, work: (0, 0, 3200, 1928) };
        for edge in ["left", "right", "top", "bottom"] {
            let (ww, wh) = if crate::config::edge_is_vertical(edge) { (432, 624) } else { (624, 624) };
            let (x, y) = super::edge_origin(&s, edge, ww, wh, 0.5);
            assert!(y + wh <= 1928, "{edge}: ({x},{y}) {ww}x{wh} reaches into the taskbar");
            assert_eq!(work_insets(&s, x, y, ww, wh), [0; 4], "{edge}: nothing covers it");
        }
        // A taskbar on the left moves the left edge in, and leaves the right one where it was
        let s = Screen { work: (72, 0, 3128, 2000), ..s };
        assert_eq!(super::edge_origin(&s, "left", 432, 624, 0.5).0, 72);
        assert_eq!(super::edge_origin(&s, "right", 432, 624, 0.5).0, 3200 - 432);
        // Nothing usable reported: the whole monitor, as before
        let s = Screen { work: (0, 0, 0, 0), ..s };
        assert_eq!(super::edge_origin(&s, "bottom", 624, 624, 1.0), (3200 - 624, 2000 - 624));
    }

    #[test]
    fn a_flat_notch_is_wide_enough_for_six_rings() {
        // 6 × 44 px rings + 5 × 14 px gaps + 36 px padding + 2 × 38.7 px fillets + the orb's 28.5 px reach
        let pill = 6.0 * 44.0 + 5.0 * 14.0 + 36.0 + 2.0 * (38.7 + 28.5);
        for edge in ["top", "bottom"] {
            let (w, h) = notch_window_size(edge);
            assert!(w >= pill, "{edge}: {w} px cannot hold a {pill} px pill");
            // `#card`'s max-height on a flat edge is the window less 150 px for the pill, the 30 px
            // gap and the margins, and the tallest card the page has measured is 400 px.
            assert!(h - 150.0 >= 400.0, "{edge}: {h} px leaves the card too little room");
        }
        for edge in ["left", "right"] {
            assert_eq!(notch_window_size(edge), (NOTCH_W, super::NOTCH_LONG));
        }
    }

    /// `fitZoom` treats a window wider than the page's design width as a DPI disagreement and zooms
    /// the layout to close the gap, so a design width left behind when the window is widened zooms
    /// the whole notch instead — and `placeCard`, which writes unzoomed styles from zoomed rects,
    /// then puts the card at the wrong place entirely.
    #[test]
    fn the_pages_design_widths_are_the_window_widths() {
        let page = include_str!("../ui/notch.html");
        let line = page
            .lines()
            .find(|l| l.trim_start().starts_with("const DESIGN_W_UPRIGHT"))
            .expect("notch.html declares its design widths on one line");
        let width_of = |key: &str| -> f64 {
            let after = line.split(key).nth(1).unwrap_or_else(|| panic!("{key} missing"));
            after
                .trim_start_matches('=')
                .chars()
                .take_while(|c| c.is_ascii_digit() || *c == '.')
                .collect::<String>()
                .parse()
                .unwrap_or_else(|_| panic!("{key} is not a number"))
        };
        assert_eq!(width_of("DESIGN_W_UPRIGHT"), notch_window_size("right").0);
        assert_eq!(width_of("DESIGN_W_FLAT"), notch_window_size("top").0);
    }

    /// A name declared in one palette and not the other keeps its dark value under a light page —
    /// black ink on a black surface, and nothing in the build would say so, since nothing reads the
    /// page. The two blocks are found by the ink they declare; `notch.html`'s third `:root` holds
    /// ring metrics rather than colours.
    #[test]
    fn both_palettes_declare_the_same_names() {
        let page = include_str!("../ui/notch.html");
        let mut palettes: Vec<Vec<String>> = Vec::new();
        let mut rest = page;
        while let Some(at) = rest.find(":root") {
            let after = &rest[at..];
            let Some(open) = after.find('{') else { break };
            let body = &after[open + 1..];
            let end = body.find('}').expect("a :root block closes");
            // Comments first: a `;` inside one splits a declaration in half and loses the name
            // after it, which fails this test for a palette that is perfectly fine.
            let mut declarations = String::new();
            let mut left = &body[..end];
            while let Some(open) = left.find("/*") {
                declarations.push_str(&left[..open]);
                match left[open..].find("*/") {
                    Some(close) => left = &left[open + close + 2..],
                    None => {
                        left = "";
                        break;
                    }
                }
            }
            declarations.push_str(left);
            let mut names: Vec<String> = declarations
                .split(';')
                .filter_map(|decl| decl.split(':').next())
                .map(str::trim)
                .filter(|name| name.starts_with("--"))
                .map(str::to_string)
                .collect();
            names.sort_unstable();
            if names.iter().any(|name| name == "--ink") {
                palettes.push(names);
            }
            rest = &body[end..];
        }
        assert_eq!(palettes.len(), 2, "one palette per appearance, dark and light");
        assert_eq!(palettes[0], palettes[1], "the two palettes declare different names");
        assert!(palettes[0].len() >= 15, "{:?} is too short to be the palette", palettes[0]);
    }

    /// Four triangles about the centre, so every point on the screen belongs to exactly one edge.
    #[test]
    fn a_carried_notch_lands_on_the_nearest_edge() {
        let (w, h) = (2560.0, 1440.0);
        assert_eq!(super::edge_at(2500.0, 700.0, w, h), "right");
        assert_eq!(super::edge_at(20.0, 700.0, w, h), "left");
        assert_eq!(super::edge_at(1280.0, 30.0, w, h), "top");
        assert_eq!(super::edge_at(1280.0, 1400.0, w, h), "bottom");
        // The corner diagonals are the boundaries: a step either side of one changes the answer
        assert_eq!(super::edge_at(690.0, 700.0, w, h), "left");
        assert_eq!(super::edge_at(700.0, 690.0, w, h), "top");
        // A pointer off the screen — in the gap a smaller one leaves — still answers the nearest edge
        assert_eq!(super::edge_at(-200.0, 700.0, w, h), "left");
    }

    /// A carry follows the pointer from one screen to the next, and holds on to the last one while
    /// the pointer crosses the gap a shorter screen leaves beside a taller one.
    #[test]
    fn a_carry_crosses_onto_whichever_screen_the_pointer_is_over() {
        let main = Screen { name: Some("1".into()), x: 0, y: 0, w: 2560, h: 1600, scale: 1.25, work: (0, 0, 2560, 1552) };
        // An older monitor to the right, shorter, and sitting 200 px lower
        let old = Screen { name: Some("2".into()), x: 2560, y: 200, w: 1920, h: 1080, scale: 1.0, work: (2560, 200, 1920, 1040) };
        let all = [main.clone(), old.clone()];
        assert_eq!(super::screen_at(&all, 100.0, 100.0).and_then(|s| s.name.clone()), main.name);
        assert_eq!(super::screen_at(&all, 3000.0, 700.0).and_then(|s| s.name.clone()), old.name);
        assert!(super::screen_at(&all, 3000.0, 100.0).is_none(), "above the shorter screen is on neither");
        assert!(super::screen_at(&all, 2560.0, 700.0).is_some(), "the shared border belongs to the right-hand one");
        assert!(super::same_screen(&main, &main.clone()));
        assert!(!super::same_screen(&main, &old));
        // The same place with no name reported is still the same screen
        assert!(super::same_screen(&Screen { name: None, ..old.clone() }, &old));
    }

    /// The pill sits in the middle of the window, so half of it, a fillet and the settings orb's reach
    /// all have to fit between the centre and each end.
    #[test]
    fn an_upright_notch_has_room_for_five_rings_and_the_orb() {
        // 5 cells (44 px ring + 6 px gap + 21 px percentage) + 4 × 14 px gaps + 36 px padding
        let pill = 5.0 * (44.0 + 6.0 + 21.0) + 4.0 * 14.0 + 36.0;
        for edge in ["left", "right"] {
            let (_, h) = notch_window_size(edge);
            assert!(h / 2.0 >= pill / 2.0 + 38.7 + 28.5, "{edge}: {h} px leaves no room for the orb");
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
    fn codex_means_its_core_window_and_cursor_its_included_usage() {
        assert_eq!(pick("codex", &[win("primary", 0.2), win("secondary", 0.9)]), Some("primary"));
        assert_eq!(pick("cursor", &[win("included", 0.3), win("api", 0.9)]), Some("included"));
        assert_eq!(pick("cursor", &[win("api", 0.9), win("on_demand", 0.95)]), Some("api"));
    }

    #[test]
    fn codex_never_substitutes_an_extra_bucket_for_core_usage() {
        assert_eq!(pick("codex", &[win("spark", 0.1), win("primary", 0.32)]), Some("primary"));
        assert_eq!(pick("codex", &[win("spark", 0.1), win("secondary", 0.4)]), None);
        assert_eq!(pick("codex", &[win("secondary", 0.4)]), None);
        assert_eq!(pick("codex", &[win("spark", 0.1), win("code-review", 0.2)]), None);
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
