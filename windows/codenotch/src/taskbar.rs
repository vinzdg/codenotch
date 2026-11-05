//! A non-activating child in an empty part of the primary taskbar.
//! Only our window is parented; Explorer is never resized, subclassed, or injected into.
use crate::{usage::UsageSnapshot, AppState};
use serde::Serialize;
use std::sync::{atomic::{AtomicBool, AtomicU64, Ordering}, Mutex};
use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindowBuilder};

#[cfg(not(windows))]
const STRIP: &str = "taskbar";
const DETAILS: &str = "taskbar-details";
const HOVER: &str = "taskbar-hover";
static READY: AtomicBool = AtomicBool::new(false);
static STATUS: Mutex<String> = Mutex::new(String::new());
#[cfg(windows)]
static CHILD: Mutex<ChildState> = Mutex::new(ChildState { hwnd: 0, parent: 0, generation: 0, creating: false, error: String::new() });
#[cfg(windows)]
static APPLY_REVISION: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
#[cfg(windows)]
struct ChildState { hwnd: isize, parent: isize, generation: u64, creating: bool, error: String }
// The same webview is reused while crossing indicators or refreshing readings. An epoch
// cancels a pending leave timer without a thread racing a newer hover and hiding its card.
static HOVER_STATE: Mutex<HoverState> = Mutex::new(HoverState {
    item_id: None, bounds: None, anchor: None, content_height: None,
    epoch: 0, show_epoch: 0, over_strip: false, held: false, ready: false,
});

struct HoverState {
    item_id: Option<String>,
    bounds: Option<Rect>,
    anchor: Option<HoverAnchor>,
    content_height: Option<f64>,
    epoch: u64,
    show_epoch: u64,
    over_strip: bool,
    held: bool,
    ready: bool,
}

struct StripGeometry { bounds: Rect, screen: Rect, scale: f64 }

fn strip_visible(app: &AppHandle) -> bool { strip_geometry(app).is_some() }

/// Native window coordinates are physical pixels, also used by the hover anchors.
fn strip_geometry(app: &AppHandle) -> Option<StripGeometry> {
    #[cfg(windows)] {
        use windows::Win32::{Foundation::{HWND, RECT}, Graphics::Gdi::{GetMonitorInfoW, MonitorFromWindow, MONITORINFO, MONITOR_DEFAULTTOPRIMARY},
            UI::{HiDpi::GetDpiForWindow, WindowsAndMessaging::{GetWindowRect, IsWindow, IsWindowVisible}}};
        let _ = app;
        let raw = CHILD.lock().unwrap().hwnd;
        let hwnd = HWND(raw as _);
        unsafe {
            if raw == 0 || !IsWindow(hwnd).as_bool() || !IsWindowVisible(hwnd).as_bool() { return None; }
            let mut bounds = RECT::default();
            GetWindowRect(hwnd, &mut bounds).ok()?;
            let mut monitor = MONITORINFO { cbSize:std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
            if !GetMonitorInfoW(MonitorFromWindow(hwnd,MONITOR_DEFAULTTOPRIMARY),&mut monitor).as_bool() { return None; }
            let screen = monitor.rcMonitor;
            Some(StripGeometry {
                bounds:Rect { left:bounds.left, top:bounds.top, right:bounds.right, bottom:bounds.bottom },
                screen:Rect { left:screen.left, top:screen.top, right:screen.right, bottom:screen.bottom },
                scale:GetDpiForWindow(hwnd).max(96) as f64 / 96.0,
            })
        }
    }
    #[cfg(not(windows))] {
        let strip = app.get_webview_window(STRIP)?;
        if !strip.is_visible().ok()? { return None; }
        let position = strip.outer_position().ok()?;
        let size = strip.outer_size().ok()?;
        let monitor = strip.current_monitor().ok()??;
        let origin = monitor.position();
        let screen = monitor.size();
        Some(StripGeometry {
            bounds:Rect { left:position.x, top:position.y, right:position.x+size.width as i32, bottom:position.y+size.height as i32 },
            screen:Rect { left:origin.x, top:origin.y, right:origin.x+screen.width as i32, bottom:origin.y+screen.height as i32 },
            scale:monitor.scale_factor(),
        })
    }
}

#[cfg(windows)]
fn native_frame(app: &AppHandle) -> crate::taskbar_model::Frame {
    let items = get_taskbar_items(app.clone());
    let cfg = app.state::<AppState>().cfg.lock().unwrap().clone();
    crate::taskbar_model::from_items(&items,crate::resolved_theme(app) != "light",&cfg)
}

/// Called only for our own native window. Defer WebView operations beyond WndProc.
#[cfg(windows)]
pub(crate) fn native_destroyed(app: &AppHandle, hwnd: isize) {
    let generation = {
        let mut child = CHILD.lock().unwrap();
        if child.hwnd != hwnd { None }
        else { child.hwnd=0; child.parent=0; child.creating=false; Some(child.generation) }
    };
    let Some(generation) = generation else { return; };
    READY.store(false, Ordering::Release);
    APPLY_REVISION.fetch_add(1, Ordering::AcqRel);
    crate::applog("taskbar child: native window destroyed; waiting for Explorer");
    let app = app.clone();
    std::thread::spawn(move || {
        let handle = app.clone();
        let _ = app.run_on_main_thread(move || {
            if CHILD.lock().unwrap().generation != generation { return; }
            hide_hover_now(&handle);
            if let Some(details) = handle.get_webview_window(DETAILS) { let _ = details.close(); }
        });
    });
}

#[derive(Clone, Serialize)]
pub struct Options { mode: String, supported: bool, status: String }

#[tauri::command]
pub fn get_taskbar_options(app: AppHandle) -> Options {
    let st = app.state::<AppState>();
    let cfg = st.cfg.lock().unwrap();
    Options { mode: cfg.taskbar_mode.clone(), supported: cfg!(windows), status: STATUS.lock().unwrap().clone() }
}

#[tauri::command]
pub fn set_taskbar_options(app: AppHandle, mode: String) -> Result<Options, String> {
    if !["off", "left", "right"].contains(&mode.as_str()) { return Err("Invalid taskbar position".into()); }
    if mode != "off" && !cfg!(windows) { return Err("Taskbar display requires Windows".into()); }
    {
        let st = app.state::<AppState>();
        let mut cfg = st.cfg.lock().unwrap();
        let mut next = cfg.clone();
        if mode != "off" { next.notch_visible = false; next.tray_visible = true; }
        else if next.taskbar_mode != "off" { next.notch_visible = true; }
        next.taskbar_mode = mode;
        crate::config::save_checked(&next)?;
        *cfg = next;
    }
    hide_hover_now(&app);
    crate::apply_visibility(&app);
    let options = get_taskbar_options(app.clone());
    let _ = app.emit("taskbar_options", &options);
    Ok(options)
}

/// The notch's `providers()`, after its Claude accounts.
const NOTCH_ORDER: [&str; 10] = ["codex", "glm", "deepseek", "opencode", "commandcode", "cursor", "grok", "copilot", "gemini", "qoder"];

#[derive(Serialize)]
pub struct Item { pub(crate) id: String, pub(crate) name: String, pub(crate) provider: String, pub(crate) headline_id: Option<String>, pub(crate) work_state: String, pub(crate) snapshot: UsageSnapshot }

#[tauri::command]
pub fn get_taskbar_items(app: AppHandle) -> Vec<Item> {
    let st = app.state::<AppState>();
    let cfg = st.cfg.lock().unwrap().clone();
    let usage = st.usage.lock().unwrap().clone();
    let mut items = Vec::new();
    // Use account-owned status and timestamps, never the provider's aggregate.
    let profiles = crate::claude_accounts::profiles(&cfg);
    for p in profiles.into_iter().filter(|p| p.enabled && (cfg.notch_slots.is_empty() || cfg.notch_slots.iter().any(|s| s.provider == "claude"))) {
        let snapshot = if let Some(a) = usage.accounts.iter().find(|a| a.id == p.id) {
            UsageSnapshot { status: a.status.clone(), windows: a.windows.clone(), fetched_at: a.fetched_at,
                note: a.note.clone(), backoff_until: a.backoff_until, ..Default::default() }
        } else if p.id == "default" && usage.accounts.is_empty() {
            let mut snap = usage.clone();
            snap.windows.retain(|w| !w.id.contains('@'));
            snap
        } else { UsageSnapshot { status: "needsAuth".into(), ..Default::default() } };
        let headline_id = crate::ring_window("claude", &snapshot.windows, "automatic", "gemini").map(|w| w.id.clone());
        let work_state = crate::taskbar_activity::work_state(&app, "claude", Some(&p.id));
        items.push(Item { id: format!("claude@{}", p.id), headline_id, work_state, name: p.name,
            provider: "claude".into(), snapshot });
    }
    for id in NOTCH_ORDER {
        if !cfg.notch_slots.is_empty() && !cfg.notch_slots.iter().any(|s| s.provider == id) { continue; }
        let snapshot = crate::snapshot_of(&app, id);
        if snapshot.status == "absent" { continue; }
        let headline_id = crate::ring_window(id, &snapshot.windows, &cfg.antigravity_limit, &cfg.antigravity_model).map(|w| w.id.clone());
        let work_state = crate::taskbar_activity::work_state(&app, id, None);
        items.push(Item { id: id.into(), headline_id, work_state, name: crate::provider_label(id).into(), provider: id.into(), snapshot });
    }
    items
}

#[tauri::command]
pub fn taskbar_ready(window: tauri::WebviewWindow) {
    if window.label() == DETAILS { let _ = window.show(); let _ = window.set_focus(); }
    else if window.label() == HOVER {
        let pending = {
            let mut state = HOVER_STATE.lock().unwrap();
            state.ready = true;
            if state.over_strip || state.held { state.item_id.clone().zip(state.bounds) } else { None }
        };
        if let Some((id, bounds)) = pending {
            let app = window.app_handle();
            let enabled = app.state::<AppState>().cfg.lock().unwrap().taskbar_mode != "off";
            let strip_visible = strip_visible(&app);
            if enabled && strip_visible {
                // The pointer may have crossed to another account while the first webview
                // was loading, before its event listener existed. Re-send the latest id.
                let _ = window.emit("taskbar_hover_item", &id);
                place_hover(&window, bounds, true);
            }
        }
    }
}

/// Anchors are physical pixels relative to the strip, reported with the webview's own
/// devicePixelRatio. WebView2's DPR can differ from Tauri's scale factor on mixed-DPI setups.
#[tauri::command]
pub fn show_taskbar_hover(app: AppHandle, id: String, anchor_x: f64, anchor_width: f64) -> Result<(), String> {
    if !anchor_x.is_finite() || !anchor_width.is_finite() || anchor_width <= 0.0 {
        return Err("Invalid taskbar hover anchor".into());
    }
    if !get_taskbar_items(app.clone()).iter().any(|item| item.id == id) {
        return Err("Unknown taskbar account".into());
    }
    let epoch = {
        let mut state = HOVER_STATE.lock().unwrap();
        state.epoch = state.epoch.wrapping_add(1);
        state.show_epoch = state.epoch;
        state.item_id = Some(id.clone());
        state.over_strip = true;
        state.held = false;
        state.epoch
    };
    // A synchronous webview creation from an IPC handler can deadlock WebView2.
    std::thread::spawn(move || {
        let handle = app.clone();
        let _ = app.run_on_main_thread(move || show_hover_on_main(&handle, id, anchor_x, anchor_width, epoch));
    });
    Ok(())
}

#[tauri::command]
pub fn hide_taskbar_hover(app: AppHandle) {
    let epoch = {
        let mut state = HOVER_STATE.lock().unwrap();
        state.over_strip = false;
        state.epoch = state.epoch.wrapping_add(1);
        state.epoch
    };
    schedule_hover_hide(app, epoch);
}

/// Where the card is in its window, in screen px: the part nearest the strip, as tall as the page
/// measured it. The rest of the window is empty.
fn card_rect(bounds: Rect, strip: Rect, content_height: f64) -> Rect {
    let height = (content_height.round() as i32).clamp(0, bounds.bottom - bounds.top);
    if bounds.top >= strip.bottom { Rect { bottom: bounds.top + height, ..bounds } }
    else { Rect { top: bounds.bottom - height, ..bounds } }
}

/// The window is mostly empty, so only the card takes the pointer: elsewhere clicks go through to
/// what is behind it. The pointer on the card also holds it open, as on the notch.
fn watch_card_pointer(app: AppHandle) {
    std::thread::spawn(move || {
        let (mut shown, mut inside) = (false, false);
        loop {
            std::thread::sleep(std::time::Duration::from_millis(30));
            let Some(window) = app.get_webview_window(HOVER) else { continue };
            if !window.is_visible().unwrap_or(false) { shown = false; continue; }
            let card = {
                let state = HOVER_STATE.lock().unwrap();
                state.bounds.zip(state.anchor).zip(state.content_height)
                    .map(|((bounds, anchor), height)| card_rect(bounds, anchor.strip, height))
            };
            let now = card.zip(app.cursor_position().ok()).is_some_and(|(r, p)|
                p.x >= r.left as f64 && p.x < r.right as f64 && p.y >= r.top as f64 && p.y < r.bottom as f64);
            if shown && now == inside { continue; }
            if shown || now { hold_taskbar_hover(app.clone(), now); }
            shown = true;
            inside = now;
            let _ = window.set_ignore_cursor_events(!now);
        }
    });
}

/// A card is up or on its way, so moving to another ring switches it at once.
pub(crate) fn hover_open() -> bool { HOVER_STATE.lock().unwrap().item_id.is_some() }

/// Crossing the small gap into the card keeps it open without activating either window.
#[tauri::command]
pub fn hold_taskbar_hover(app: AppHandle, held: bool) {
    let epoch = {
        let mut state = HOVER_STATE.lock().unwrap();
        if state.item_id.is_none() { return; }
        state.held = held;
        state.epoch = state.epoch.wrapping_add(1);
        state.epoch
    };
    if !held { schedule_hover_hide(app, epoch); }
}

/// Only the tooltip may report its natural content height. Measurements from a previously
/// hovered account are discarded instead of resizing the current account's card.
#[tauri::command]
pub fn report_taskbar_hover_size(app: AppHandle, window: tauri::WebviewWindow, id: String, height: f64, dpr: f64) -> Result<(), String> {
    if window.label() != HOVER { return Err("Only the taskbar tooltip can report its size".into()); }
    let Some(height) = measured_hover_height(height, dpr) else { return Err("Invalid taskbar tooltip size".into()); };
    let pending = {
        let mut state = HOVER_STATE.lock().unwrap();
        if state.item_id.as_deref() != Some(&id) { return Ok(()); }
        state.content_height = Some(height);
        let Some(anchor) = state.anchor else { return Ok(()); };
        let Some(bounds) = anchor.position() else { return Ok(()); };
        let unchanged = state.bounds == Some(bounds);
        state.bounds = Some(bounds);
        (state.show_epoch, bounds, unchanged)
    };
    let handle = app.clone();
    app.run_on_main_thread(move || {
        let show = {
            let state = HOVER_STATE.lock().unwrap();
            if state.show_epoch != pending.0 || state.item_id.as_deref() != Some(&id) || state.bounds != Some(pending.1) { return; }
            state.ready && (state.over_strip || state.held)
        };
        let enabled = handle.state::<AppState>().cfg.lock().unwrap().taskbar_mode != "off";
        let strip_visible = strip_visible(&handle);
        if let Some(w) = handle.get_webview_window(HOVER) {
            if pending.2 && w.is_visible().unwrap_or(false) { return; }
            place_hover(&w, pending.1, show && enabled && strip_visible);
        }
    }).map_err(|error| error.to_string())
}

fn schedule_hover_hide(app: AppHandle, epoch: u64) {
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(180));
        let handle = app.clone();
        let _ = app.run_on_main_thread(move || {
            let hide = {
                let mut state = HOVER_STATE.lock().unwrap();
                if state.epoch != epoch || state.over_strip || state.held { false }
                else {
                    state.item_id = None;
                    state.bounds = None;
                    state.anchor = None;
                    state.content_height = None;
                    true
                }
            };
            if hide { if let Some(w) = handle.get_webview_window(HOVER) { let _ = w.hide(); } }
        });
    });
}

fn hide_hover_now(app: &AppHandle) {
    {
        let mut state = HOVER_STATE.lock().unwrap();
        state.epoch = state.epoch.wrapping_add(1);
        state.item_id = None;
        state.show_epoch = state.epoch;
        state.bounds = None;
        state.anchor = None;
        state.content_height = None;
        state.over_strip = false;
        state.held = false;
    }
    if let Some(w) = app.get_webview_window(HOVER) { let _ = w.hide(); }
}

fn show_hover_on_main(app: &AppHandle, id: String, anchor_x: f64, anchor_width: f64, epoch: u64) {
    {
        let state = HOVER_STATE.lock().unwrap();
        if state.show_epoch != epoch || (!state.over_strip && !state.held) { return; }
    }
    if app.state::<AppState>().cfg.lock().unwrap().taskbar_mode == "off" { return; }
    let Some(geometry) = strip_geometry(app) else { return; };
    let anchor = HoverAnchor { strip: geometry.bounds, screen: geometry.screen,
        x: anchor_x, width: anchor_width, scale: geometry.scale };
    let bounds = {
        let mut state = HOVER_STATE.lock().unwrap();
        if state.show_epoch != epoch || (!state.over_strip && !state.held) { return; }
        let Some(bounds) = anchor.position() else { return; };
        state.anchor = Some(anchor);
        state.bounds = Some(bounds);
        bounds
    };
    if let Some(w) = app.get_webview_window(HOVER) {
        let _ = w.emit("taskbar_hover_item", &id);
        let ready = HOVER_STATE.lock().unwrap().ready;
        // An open card travels to the new ring now. A hidden one shows once the page has measured
        // the new account, so it never comes up for a frame with the last one's contents.
        place_hover(&w, bounds, ready && w.is_visible().unwrap_or(false));
        return;
    }
    HOVER_STATE.lock().unwrap().ready = false;
    // JSON encoding prevents an account identifier from becoming executable script.
    let item_json = serde_json::to_string(&id).unwrap_or_else(|_| "null".into());
    let script = format!("window.__CODENOTCH_TASKBAR_HOVER__=true;window.__CODENOTCH_TASKBAR_ITEM_ID__={item_json};");
    // The notch's own page, showing only its card: the taskbar's card is the notch's.
    let result = WebviewWindowBuilder::new(app, HOVER, WebviewUrl::App("notch.html".into()))
        .title("Codenotch").inner_size(CARD_WIDTH, 360.0).resizable(false)
        .decorations(false).transparent(true).shadow(false).skip_taskbar(true).always_on_top(true)
        .focused(false).focusable(false).visible(false).initialization_script(script).build();
    if let Ok(w) = result {
        static WATCHING: AtomicBool = AtomicBool::new(false);
        if !WATCHING.swap(true, Ordering::AcqRel) { watch_card_pointer(app.clone()); }
        place_hover(&w, bounds, false);
        w.on_window_event(|event| {
            if matches!(event, tauri::WindowEvent::Destroyed) { HOVER_STATE.lock().unwrap().ready = false; }
        });
    }
}

/// The Mac's `NotchMotion.glide`: the card is one object that travels between rings and resizes
/// on the way, which reads far better than one card leaving and another arriving.
const GLIDE_MS: f64 = 300.0;
static GLIDE: AtomicU64 = AtomicU64::new(0);

#[cfg(windows)]
fn glide(window: &tauri::WebviewWindow, from: i32, to: Rect) {
    use windows::Win32::{Foundation::HWND, UI::WindowsAndMessaging::{SetWindowPos, HWND_TOPMOST, SWP_NOACTIVATE}};
    let epoch = GLIDE.fetch_add(1, Ordering::AcqRel).wrapping_add(1);
    let window = window.clone();
    std::thread::spawn(move || {
        let started = std::time::Instant::now();
        loop {
            std::thread::sleep(std::time::Duration::from_millis(15));
            let t = (started.elapsed().as_secs_f64() * 1000.0 / GLIDE_MS).min(1.0);
            let left = from + ((to.left - from) as f64 * (1.0 - (1.0 - t).powi(3))).round() as i32;
            let step = window.clone();
            let posted = window.app_handle().run_on_main_thread(move || {
                if GLIDE.load(Ordering::Acquire) != epoch { return; }
                if let Ok(raw) = step.hwnd() { unsafe {
                    let _ = SetWindowPos(HWND(raw.0 as _), HWND_TOPMOST, left, to.top, to.right - to.left, to.bottom - to.top, SWP_NOACTIVATE);
                } }
            });
            if posted.is_err() || t >= 1.0 || GLIDE.load(Ordering::Acquire) != epoch { return; }
        }
    });
}

fn place_hover(window: &tauri::WebviewWindow, bounds: Rect, show: bool) {
    // Where the hovered ring is, for the tail, in physical px from the card window's left edge
    let anchor = HOVER_STATE.lock().unwrap().anchor;
    if let Some(anchor) = anchor {
        let ring = anchor.strip.left as f64 + (anchor.x + anchor.width / 2.0).clamp(0.0, (anchor.strip.right - anchor.strip.left) as f64);
        let glide = window.is_visible().unwrap_or(false);
        let _ = window.emit("taskbar_hover_tail", serde_json::json!({ "x": ring - bounds.left as f64, "below": bounds.top >= anchor.strip.bottom, "glide": glide }));
    }
    #[cfg(windows)] {
        use windows::Win32::{Foundation::{HWND, RECT}, UI::WindowsAndMessaging::{GetWindowRect, SetWindowPos, HWND_TOPMOST, SWP_NOACTIVATE, SWP_SHOWWINDOW}};
        if let Ok(raw) = window.hwnd() { unsafe {
            let mut current = RECT::default();
            let visible = window.is_visible().unwrap_or(false);
            if show && visible && GetWindowRect(HWND(raw.0 as _), &mut current).is_ok() && current.left != bounds.left {
                // Its new height now, from where it is; then the way across
                let _ = SetWindowPos(HWND(raw.0 as _), HWND_TOPMOST, current.left, bounds.top,
                    bounds.right - bounds.left, bounds.bottom - bounds.top, SWP_NOACTIVATE);
                glide(window, current.left, bounds);
                return;
            }
            GLIDE.fetch_add(1, Ordering::AcqRel); // a placement that is not a glide ends any glide
            if show && !window.is_visible().unwrap_or(false) {
                // Place while hidden, then let Tauri restore its native/webview visibility
                // before reinforcing the non-activating placement. The window is unfocusable.
                let _ = SetWindowPos(HWND(raw.0 as _), HWND_TOPMOST, bounds.left, bounds.top,
                    bounds.right - bounds.left, bounds.bottom - bounds.top, SWP_NOACTIVATE);
                let _ = window.show();
            }
            let flags = if show { SWP_NOACTIVATE | SWP_SHOWWINDOW } else { SWP_NOACTIVATE };
            let _ = SetWindowPos(HWND(raw.0 as _), HWND_TOPMOST, bounds.left, bounds.top,
                bounds.right - bounds.left, bounds.bottom - bounds.top, flags);
        } }
    }
    #[cfg(not(windows))] {
        let _ = window.set_size(tauri::PhysicalSize::new((bounds.right - bounds.left) as u32, (bounds.bottom - bounds.top) as u32));
        let _ = window.set_position(tauri::PhysicalPosition::new(bounds.left, bounds.top));
        if show { let _ = window.show(); }
    }
}

#[tauri::command]
pub fn open_taskbar_details(app: AppHandle) {
    hide_hover_now(&app);
    std::thread::spawn(move || {
        let handle = app.clone();
        let _ = app.run_on_main_thread(move || {
            if let Some(w) = handle.get_webview_window(DETAILS) { let _ = w.show(); let _ = w.set_focus(); return; }
            let mut builder = WebviewWindowBuilder::new(&handle, DETAILS, WebviewUrl::App("taskbar.html".into()))
                .title("Codenotch · Uso das contas").inner_size(380.0, 430.0).resizable(false)
                .decorations(false).shadow(true).skip_taskbar(true).always_on_top(true).visible(false)
                .initialization_script("window.__CODENOTCH_TASKBAR_DETAILS__=true;");
            let placement = strip_geometry(&handle).map(|geometry| {
                let Rect { left, top, bottom, .. } = geometry.bounds;
                let Rect { left:sx, top:sy, right:sr, bottom:sb } = geometry.screen;
                let scale = geometry.scale;
                let width = (380.0 * scale).min((sr-sx) as f64 - 16.0);
                let height = (430.0 * scale).min((sb-sy) as f64 - 16.0);
                let x = (left as f64).clamp(sx as f64 + 8.0, sr as f64 - width - 8.0);
                let above = top as f64 - height - 8.0;
                let y = if above >= sy as f64 { above } else { bottom as f64 + 8.0 };
                let y = y.clamp(sy as f64 + 8.0, sb as f64 - height - 8.0);
                (scale,width,height,x,y)
            });
            if let Some((scale,width,height,_,_)) = placement { builder = builder.inner_size(width/scale,height/scale); }
            match builder.build() {
                Ok(w) => {
                    if let Some((_,_,_,x,y)) = placement { let _ = w.set_position(tauri::PhysicalPosition::new(x as i32,y as i32)); }
                    let blur = w.clone();
                    w.on_window_event(move |event| { if matches!(event, tauri::WindowEvent::Focused(false)) { let _ = blur.close(); } });
                }
                Err(_) => crate::settings_window::open(&handle),
            }
        });
    });
}

pub fn start(app: &AppHandle) {
    #[cfg(windows)] {
        // Explorer may not exist yet at logon. The watcher creates the child only when its
        // real parent exists, and recreates it after Explorer restarts.
        READY.store(false, Ordering::Release);
        let handle = app.clone();
        std::thread::spawn(move || native::watch(handle));
    }
    #[cfg(not(windows))] { let _ = app; }
}

/// Physical-pixel layout, independently testable without Explorer or WebView2.
#[derive(Clone, Copy, Debug, PartialEq)]
struct Rect { left: i32, top: i32, right: i32, bottom: i32 }

#[derive(Clone, Copy, Debug, PartialEq)]
enum ChildDisposition { Disabled, Waiting, Create, Recreate, Keep }

fn child_disposition(enabled: bool, parent: Option<isize>, child_parent: Option<isize>) -> ChildDisposition {
    if !enabled { return ChildDisposition::Disabled; }
    let Some(parent) = parent else { return ChildDisposition::Waiting; };
    match child_parent {
        None => ChildDisposition::Create,
        Some(current) if current != parent => ChildDisposition::Recreate,
        Some(_) => ChildDisposition::Keep,
    }
}

fn parent_client_rect(screen: Rect, origin_x: i32, origin_y: i32) -> Rect {
    Rect { left:screen.left-origin_x, top:screen.top-origin_y, right:screen.right-origin_x, bottom:screen.bottom-origin_y }
}

fn needs_child_placement(desired: Rect, actual: Option<Rect>, visible: bool) -> bool {
    !visible || actual != Some(desired)
}

#[derive(Clone, Copy)]
struct HoverAnchor { strip: Rect, screen: Rect, x: f64, width: f64, scale: f64 }

impl HoverAnchor {
    /// As tall as the tallest card, whichever card it holds: a WebView redrawn at a new size shows
    /// a frame of its old layout, which moving between rings of different heights made a flash.
    fn position(self) -> Option<Rect> {
        hover_position(self.strip, self.screen, self.x, self.width, self.scale, CARD_ROOM * self.scale)
    }
}

fn measured_hover_height(height: f64, dpr: f64) -> Option<f64> {
    if !height.is_finite() || height <= 0.0 || !dpr.is_finite() || !(0.5..=8.0).contains(&dpr) { return None; }
    Some(height.clamp(40.0, 600.0) * dpr)
}

/// The tallest card and its tail, in logical px: what `measured_hover_height` lets a card measure.
const CARD_ROOM: f64 = 600.0;
/// The notch card's width on a flat edge, `body[data-edge="bottom"] #card` in notch.html.
const CARD_WIDTH: f64 = 246.0;
/// The notch's TAIL_GAP: the tail's point stops this far short of what it points at.
const TAIL_GAP: f64 = 10.5;

/// Popup geometry stays in physical pixels, including monitors left/above the primary.
fn hover_position(strip: Rect, screen: Rect, anchor_x: f64, anchor_width: f64, scale: f64, content_height: f64) -> Option<Rect> {
    if !anchor_x.is_finite() || !anchor_width.is_finite() || anchor_width <= 0.0 || !scale.is_finite() || scale <= 0.0 || !content_height.is_finite() || content_height <= 0.0 {
        return None;
    }
    let gap = (8.0 * scale).round().max(1.0) as i32;
    let tail_gap = (TAIL_GAP * scale).round().max(1.0) as i32;
    let available_width = screen.right - screen.left - 2 * gap;
    let available_height = screen.bottom - screen.top - 2 * gap;
    if available_width <= 0 || available_height <= 0 || strip.right <= strip.left || strip.bottom <= strip.top { return None; }
    let width = ((CARD_WIDTH * scale).round() as i32).min(available_width);
    let height = (content_height.round() as i32).max(1).min(available_height);
    // A partially clipped indicator anchors to its visible part of the strip.
    let center = strip.left as f64 + (anchor_x + anchor_width / 2.0).clamp(0.0, (strip.right - strip.left) as f64);
    let x = (center.round() as i32 - width / 2).clamp(screen.left + gap, screen.right - width - gap);
    let above = strip.top - height - tail_gap;
    let y = if above >= screen.top + gap { above } else { strip.bottom + tail_gap };
    let y = y.clamp(screen.top + gap, screen.bottom - height - gap);
    Some(Rect { left: x, top: y, right: x + width, bottom: y + height })
}

/// A maximized app's invisible frame can extend across the taskbar. Only the actual client
/// area covering this monitor indicates fullscreen; a fullscreen app on another monitor does not.
fn client_covers_monitor(client: Rect, monitor: Rect) -> bool {
    client.left <= monitor.left + 1 && client.top <= monitor.top + 1
        && client.right >= monitor.right - 1 && client.bottom >= monitor.bottom - 1
}

fn shell_surface(class: &str, process: &str) -> bool {
    ["Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "NotifyIconOverflowWindow"].contains(&class)
        || ["startmenuexperiencehost.exe", "searchhost.exe", "searchapp.exe", "shellexperiencehost.exe"].contains(&process)
        || (process == "explorer.exe" && ["XamlExplorerHostIslandWindow", "MultitaskingViewFrame"].contains(&class))
}

/// Keep a stable placement when activation merely changes overlapping UIA children. Real new
/// taskbar buttons still invalidate it as soon as a complete layout reading sees the collision.
fn position_still_free(bar: Rect, occupied: &[Rect], position: Rect, gap: i32) -> bool {
    position.left >= bar.left + gap && position.right <= bar.right - gap
        && position.top == bar.top + 3 && position.bottom == bar.bottom - 3
        && !occupied.iter().any(|r| r.bottom > bar.top && r.top < bar.bottom
            && r.right + gap > position.left && r.left - gap < position.right)
}

fn refresh_position(bar: Rect, occupied: Option<&[Rect]>, previous: Option<Rect>, right: bool, wanted: i32, gap: i32, minimum: i32) -> Option<Rect> {
    // UIA sometimes yields no tree while Explorer animates Start or activates a taskbar app.
    // A missing reading is not proof that the last verified empty area became occupied.
    let Some(occupied) = occupied else { return previous; };
    let candidate = free_position(bar, occupied, right, wanted, gap, minimum);
    if let (Some(old), Some(next)) = (previous, candidate) {
        if old.right - old.left == next.right - next.left && position_still_free(bar, occupied, old, gap) { return Some(old); }
    }
    candidate
}

fn free_position(bar: Rect, occupied: &[Rect], right: bool, wanted: i32, gap: i32, minimum: i32) -> Option<Rect> {
    if bar.right - bar.left < minimum || bar.bottom <= bar.top || bar.bottom - bar.top > bar.right - bar.left { return None; }
    let mut blocks: Vec<(i32, i32)> = occupied.iter()
        .filter(|r| r.bottom > bar.top && r.top < bar.bottom && r.right > bar.left && r.left < bar.right)
        .map(|r| ((r.left - gap).max(bar.left), (r.right + gap).min(bar.right))).collect();
    blocks.sort();
    let mut gaps = Vec::new();
    let mut edge = bar.left + gap;
    for (left, stop) in blocks {
        if left - edge >= minimum { gaps.push((edge, left)); }
        edge = edge.max(stop);
    }
    if bar.right - gap - edge >= minimum { gaps.push((edge, bar.right - gap)); }
    let middle = bar.left + (bar.right - bar.left) / 2;
    gaps = gaps.into_iter().map(|(left,stop)| if right { (left.max(middle),stop) } else { (left,stop.min(middle)) })
        .filter(|(left,stop)| stop-left>=minimum).collect();
    if right { gaps.reverse(); }
    let (left, stop) = gaps.into_iter().next()?;
    let width = wanted.min(stop - left);
    let x = if right { stop - width } else { left };
    Some(Rect { left: x, right: x + width, top: bar.top + 3, bottom: bar.bottom - 3 })
}

#[cfg(windows)]
mod native {
    use super::*;
    use windows::{core::{Interface, PWSTR}, Win32::{Foundation::{CloseHandle, HWND, POINT, RECT}, System::{Com::{CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED},
        Threading::{OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_FORMAT, PROCESS_QUERY_LIMITED_INFORMATION}},
        Graphics::Gdi::{ClientToScreen, GetMonitorInfoW, MonitorFromWindow, MONITORINFO, MONITOR_DEFAULTTOPRIMARY},
        UI::{Accessibility::*, WindowsAndMessaging::*}}};
    static LAST_NATIVE_ERROR: Mutex<String> = Mutex::new(String::new());
    fn log_native_error(operation: &str, error: &windows::core::Error) {
        let line = format!("taskbar child: {operation} failed, code=0x{:08x}", error.code().0 as u32);
        let mut last = LAST_NATIVE_ERROR.lock().unwrap();
        if *last != line { crate::applog(&line); *last = line; }
    }
    fn child_error(message: &str) {
        READY.store(false, Ordering::Release);
        let mut child = CHILD.lock().unwrap();
        child.error = message.into();
        child.creating = false;
    }
    fn ensure_child(app: &AppHandle, parent: isize) {
        {
            let mut child = CHILD.lock().unwrap();
            if child.creating { return; }
            child.creating = true;
        }
        let handle = app.clone();
        if app.run_on_main_thread(move || {
            let bar = HWND(parent as _);
            if handle.state::<AppState>().cfg.lock().unwrap().taskbar_mode == "off" || !unsafe { IsWindow(bar).as_bool() } {
                CHILD.lock().unwrap().creating = false;
                return;
            }
            if let Some(hwnd) = crate::taskbar_native::hwnd() {
                if unsafe { IsWindow(hwnd).as_bool() && GetParent(hwnd).is_ok_and(|p| p == bar) } {
                    let mut child = CHILD.lock().unwrap();
                    child.hwnd = hwnd.0 as isize;
                    child.parent = parent;
                    child.creating = false;
                    READY.store(true, Ordering::Release);
                    return;
                }
                crate::taskbar_native::destroy();
            }
            READY.store(false, Ordering::Release);
            {
                let mut child = CHILD.lock().unwrap();
                child.generation = child.generation.wrapping_add(1);
                child.parent = parent;
                child.hwnd = 0;
                child.creating = true;
            }
            let scale = unsafe { windows::Win32::UI::HiDpi::GetDpiForWindow(bar) }.max(96) as f32 / 96.0;
            let frame = native_frame(&handle);
            let width = (280.0 * scale).round() as u32;
            let height = (42.0 * scale).round() as u32;
            match crate::taskbar_native::create(handle.clone(), bar, width, height, scale, frame) {
                Ok(hwnd) => {
                    let mut child = CHILD.lock().unwrap();
                    child.hwnd = hwnd;
                    child.parent = parent;
                    child.error.clear();
                    child.creating = false;
                    READY.store(true, Ordering::Release);
                    crate::applog("taskbar child: native indicators created with Explorer as parent");
                }
                Err(reason) => {
                    crate::applog(&format!("taskbar child: native creation failed: {reason}"));
                    child_error("Unable to create the taskbar child window. Use the tray to open Settings.");
                }
            }
        }).is_err() {
            child_error("Unable to schedule taskbar child creation.");
        }
    }
    fn rect(hwnd: HWND) -> Option<Rect> {
        let mut r = RECT::default();
        unsafe { GetWindowRect(hwnd, &mut r).ok()?; }
        Some(Rect { left:r.left, top:r.top, right:r.right, bottom:r.bottom })
    }
    fn class(hwnd: HWND) -> String {
        let mut text = [0u16; 256];
        let len = unsafe { GetClassNameW(hwnd, &mut text) };
        String::from_utf16_lossy(&text[..len.max(0) as usize])
    }
    fn client_rect(hwnd: HWND) -> Option<Rect> {
        let mut client = RECT::default();
        let mut origin = POINT::default();
        unsafe {
            GetClientRect(hwnd, &mut client).ok()?;
            if !ClientToScreen(hwnd, &mut origin).as_bool() { return None; }
        }
        Some(Rect { left:origin.x, top:origin.y, right:origin.x + client.right - client.left, bottom:origin.y + client.bottom - client.top })
    }
    fn foreground_process(hwnd: HWND, cache: &mut Option<(isize, u32, String)>) -> &str {
        let mut pid = 0;
        unsafe { GetWindowThreadProcessId(hwnd, Some(&mut pid)); }
        if cache.as_ref().is_none_or(|(window, process, _)| *window != hwnd.0 as isize || *process != pid) {
            let mut path = [0u16; 1024];
            let mut size = path.len() as u32;
            let mut name = String::new();
            unsafe {
                if let Ok(process) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) {
                    if QueryFullProcessImageNameW(process, PROCESS_NAME_FORMAT(0), PWSTR(path.as_mut_ptr()), &mut size).is_ok() {
                        let full = String::from_utf16_lossy(&path[..size as usize]);
                        name = full.rsplit('\\').next().unwrap_or("").to_ascii_lowercase();
                    }
                    let _ = CloseHandle(process);
                }
            }
            *cache = Some((hwnd.0 as isize, pid, name));
        }
        &cache.as_ref().unwrap().2
    }
    fn desktop_visible(bar: HWND, bounds: Rect, foreground: HWND, process_cache: &mut Option<(isize, u32, String)>) -> Result<(), &'static str> {
        unsafe {
            if !IsWindowVisible(bar).as_bool() { return Err("hidden_taskbar"); }
            let mut monitor = MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
            if !GetMonitorInfoW(MonitorFromWindow(bar, MONITOR_DEFAULTTOPRIMARY), &mut monitor).as_bool() { return Err("monitor_unavailable"); }
            let m = monitor.rcMonitor;
            if bounds.top < m.top || bounds.bottom > m.bottom || bounds.bottom - bounds.top < 20 { return Err("autohidden_taskbar"); }
            let kind = class(foreground);
            if shell_surface(&kind, "") { return Ok(()); }
            let screen = Rect { left:m.left, top:m.top, right:m.right, bottom:m.bottom };
            let client = client_rect(foreground).or_else(|| {
                let style = GetWindowLongPtrW(foreground, GWL_STYLE) as u32;
                if style & (WS_CAPTION.0 | WS_THICKFRAME.0) == 0 { rect(foreground) } else { None }
            });
            if !client.is_some_and(|r| client_covers_monitor(r, screen)) { return Ok(()); }
            if shell_surface(&kind, foreground_process(foreground, process_cache)) { Ok(()) } else { Err("fullscreen_application") }
        }
    }
    fn occupied(uia: &IUIAutomation, bar: HWND, bounds: Rect, strip: HWND) -> Option<Vec<Rect>> {
        unsafe {
            let root = uia.ElementFromHandle(bar).ok()?;
            let walker = uia.RawViewWalker().ok()?;
            let own_root = if strip.0.is_null() { None } else { uia.ElementFromHandle(strip).ok() };
            let mut pending = vec![walker.GetFirstChildElement(&root).ok()?];
            let mut visited = 0;
            let mut occupied = Vec::new();
            while let Some(e) = pending.pop() {
                visited += 1;
                if visited > 1600 { return None; }
                if let Ok(sibling) = walker.GetNextSiblingElement(&e) { pending.push(sibling); }
                let native = e.CurrentNativeWindowHandle().unwrap_or_default();
                // Skip the whole owned subtree before traversing DOM controls. Renderer nodes
                // may belong to another process, so PID alone cannot identify our webview.
                let ours = (!strip.0.is_null() && (native == strip || (!native.0.is_null() && IsChild(strip, native).as_bool())))
                    || e.CurrentProcessId().unwrap_or(0) == std::process::id() as i32
                    || own_root.as_ref().is_some_and(|own| uia.CompareElements(&e, own).unwrap_or_default().as_bool());
                if ours || e.CurrentIsOffscreen().unwrap_or_default().as_bool() { continue; }
                if let Ok(child) = walker.GetFirstChildElement(&e) { pending.push(child); }
                let kind = e.CurrentControlType().ok()?;
                if ![UIA_ButtonControlTypeId, UIA_ListItemControlTypeId, UIA_MenuItemControlTypeId,
                    UIA_TextControlTypeId, UIA_ImageControlTypeId, UIA_HyperlinkControlTypeId].contains(&kind) { continue; }
                let r = e.CurrentBoundingRectangle().ok()?;
                if r.right > r.left && r.bottom > r.top && r.right - r.left < (bounds.right - bounds.left) / 2 {
                    occupied.push(Rect { left:r.left, top:r.top, right:r.right, bottom:r.bottom });
                }
            }
            if let Ok(tray) = FindWindowExW(bar, None, windows::core::w!("TrayNotifyWnd"), None) {
                if let Some(mut r) = rect(tray) { r.right = bounds.right; occupied.push(r); }
            }
            if occupied.is_empty() { return None; }
            Some(occupied)
        }
    }
    pub fn watch(app: AppHandle) {
        let initialized = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED).is_ok() };
        if !initialized { *STATUS.lock().unwrap() = "Windows taskbar accessibility is unavailable".into(); return; }
        let uia: windows::core::Result<IUIAutomation> = unsafe { CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER) };
        let Ok(uia) = uia else { unsafe { CoUninitialize(); } return; };
        if let Ok(uia2) = uia.cast::<IUIAutomation2>() { unsafe { let _ = uia2.SetConnectionTimeout(400); let _ = uia2.SetTransactionTimeout(400); } }
        use std::time::{Duration, Instant};
        let mut previous = (0, None);
        let mut layout_key = None;
        let mut cached_position = None;
        let mut layout_status = String::new();
        let mut layout_reason = "no_space";
        let mut pending_change = None::<Instant>;
        let mut last_verified = None::<Instant>;
        let mut process_cache = None;
        let mut last_foreground = 0;
        let mut last_reason = String::new();
        let mut next_layout_read = Instant::now();
        let mut next_create = Instant::now();
        let mut next_z_check = Instant::now();
        let mut next_frame = Instant::now();
        let mut last_frame = None;
        // What the cells need, in physical px, from the last frame sent; 0 until there is one.
        let mut wanted_width = 0;
        let mut last_wanted = 0;
        loop {
            let now = Instant::now();
            let foreground = unsafe { GetForegroundWindow() };
            let foreground_changed = last_foreground != foreground.0 as isize;
            last_foreground = foreground.0 as isize;
            let reassert = foreground_changed || now >= next_z_check;
            if reassert { next_z_check = now + Duration::from_secs(1); }
            let cfg = app.state::<AppState>().cfg.lock().unwrap().clone();
            let enabled = cfg.taskbar_mode != "off";
            if !enabled {
                // An already queued frame can be discarded while disabled. Force
                // a fresh one when enabled again, even if provider data is unchanged.
                last_frame = None;
                next_frame = now;
            }
            let bar = if enabled { unsafe { FindWindowW(windows::core::w!("Shell_TrayWnd"), None) }.ok() } else { None };
            let (child_hwnd, generation, creation_error) = {
                let child = CHILD.lock().unwrap();
                (child.hwnd, child.generation, child.error.clone())
            };
            let child_parent = if child_hwnd != 0 && unsafe { IsWindow(HWND(child_hwnd as _)).as_bool() } {
                unsafe { GetParent(HWND(child_hwnd as _)) }.ok().map(|p| p.0 as isize)
            } else { None };
            let disposition = child_disposition(enabled, bar.map(|w| w.0 as isize), child_parent);
            if matches!(disposition, ChildDisposition::Create | ChildDisposition::Recreate) && now >= next_create {
                if let Some(bar) = bar { ensure_child(&app, bar.0 as isize); }
                next_create = now + Duration::from_secs(if creation_error.is_empty() { 2 } else { 5 });
            }
            let mut message = String::new();
            let mut reason: String = match disposition {
                ChildDisposition::Disabled => "disabled".into(),
                ChildDisposition::Waiting => { message = "Waiting for the Windows taskbar".into(); "waiting_explorer".into() }
                ChildDisposition::Create | ChildDisposition::Recreate => {
                    message = if creation_error.is_empty() { "Waiting for the taskbar child window".into() } else { creation_error.clone() };
                    if creation_error.is_empty() { "creating_child".into() } else { creation_error }
                }
                ChildDisposition::Keep => "loading_child".into(),
            };
            let layout = if disposition == ChildDisposition::Keep && READY.load(Ordering::Acquire) {
                bar.and_then(|bar| {
                    if let Some(bounds) = rect(bar) {
                        match desktop_visible(bar, bounds, foreground, &mut process_cache) {
                            Ok(()) => Some((bar, bounds)),
                            Err(hidden) => { reason = hidden.into(); None }
                        }
                    } else { reason = "taskbar_bounds_unavailable".into(); None }
                })
            } else { None };
            let position = if let Some((bar, bounds)) = layout {
                let scale = unsafe { windows::Win32::UI::HiDpi::GetDpiForWindow(bar) }.max(96) as f64 / 96.0;
                // The strip is as wide as its cells, so a figure gaining a digit resizes it. That
                // rereads the free space but keeps the position it had until the reading is in.
                let wanted = if wanted_width > 0 { wanted_width } else { (100.0 * scale) as i32 };
                let key = (bar.0 as isize, bounds, cfg.taskbar_mode == "right", scale.to_bits(), generation);
                if last_wanted != wanted { last_wanted = wanted; next_layout_read = now; }
                if layout_key != Some(key) {
                    layout_key = Some(key);
                    cached_position = None;
                    layout_status.clear();
                    pending_change = None;
                    last_verified = None;
                    next_layout_read = now;
                }
                if now >= next_layout_read {
                    if let Some(blocks) = occupied(&uia, bar, bounds, HWND(child_hwnd as _)) {
                        let candidate = refresh_position(bounds, Some(&blocks), cached_position, cfg.taskbar_mode == "right",
                            wanted, (8.0 * scale) as i32, wanted.min((100.0 * scale) as i32));
                        last_verified = Some(now);
                        // Explorer may briefly report a complete but transitional layout during
                        // activation. Confirm a collision/no-space reading after 300 ms before
                        // moving or hiding; a real new button is never covered indefinitely.
                        let settling = cached_position.is_some() && candidate != cached_position
                            && pending_change.is_none_or(|first| now.duration_since(first) < Duration::from_millis(300));
                        if settling {
                            if pending_change.is_none() { pending_change = Some(now); }
                            next_layout_read = now + Duration::from_millis(300);
                            layout_reason = "layout_settling";
                        } else {
                            cached_position = candidate;
                            pending_change = None;
                            next_layout_read = now + Duration::from_secs(if candidate.is_some() { 2 } else { 1 });
                            layout_status = if candidate.is_none() { "No free space on the taskbar. Try the other side.".into() } else { String::new() };
                            layout_reason = if candidate.is_some() { "visible" } else { "no_space" };
                        }
                    } else {
                        if last_verified.is_none_or(|last| now.duration_since(last) >= Duration::from_secs(6)) {
                            cached_position = None;
                            pending_change = None;
                            layout_status = "Windows did not expose the taskbar buttons. Use the tray to open Settings.".into();
                            layout_reason = "uia_unavailable";
                        }
                        next_layout_read = now + Duration::from_millis(500);
                    }
                }
                message = layout_status.clone();
                reason = layout_reason.into();
                cached_position
            } else {
                layout_key = None;
                cached_position = None;
                layout_status.clear();
                pending_change = None;
                last_verified = None;
                next_layout_read = now;
                None
            };
            *STATUS.lock().unwrap() = message;
            if reason != last_reason {
                crate::applog(&format!("taskbar child: {reason}"));
                last_reason = reason;
            }
            // Read existing in-memory provider snapshots only; never start a usage query.
            // Activity and limits stay current even when no details WebView exists.
            if enabled && child_parent.is_some() && READY.load(Ordering::Acquire) && now >= next_frame {
                next_frame = now + Duration::from_millis(500);
                if let Some(bar) = bar {
                    let scale = unsafe { windows::Win32::UI::HiDpi::GetDpiForWindow(bar) }.max(96) as f32 / 96.0;
                    let frame = native_frame(&app);
                    // The strip's height is the taskbar's less the 3 px free_position leaves each side.
                    let height = rect(bar).map(|r| r.bottom - r.top - 6).unwrap_or(0) as f32;
                    wanted_width = crate::taskbar_model::content_width(&frame, height, scale) as i32;
                    let key = (generation,scale.to_bits(),frame.clone());
                    if last_frame.as_ref() != Some(&key) {
                        last_frame = Some(key);
                        let handle = app.clone();
                        let _ = app.run_on_main_thread(move || {
                            if CHILD.lock().unwrap().generation != generation { return; }
                            if handle.state::<AppState>().cfg.lock().unwrap().taskbar_mode != "off" {
                                crate::taskbar_native::update(frame,scale);
                            }
                        });
                    }
                }
            }
            let moved = position != previous.1 || generation != previous.0;
            previous = (generation, position);
            if moved || (position.is_some() && reassert) {
                let revision = APPLY_REVISION.fetch_add(1, Ordering::AcqRel).wrapping_add(1);
                let parent = bar.map(|w| w.0 as isize);
                let handle = app.clone();
                let _ = app.run_on_main_thread(move || {
                    if APPLY_REVISION.load(Ordering::Acquire) != revision || CHILD.lock().unwrap().generation != generation { return; }
                    let Some(hwnd) = crate::taskbar_native::hwnd() else { return; };
                    if let Some(r) = position {
                        if handle.state::<AppState>().cfg.lock().unwrap().taskbar_mode == "off" { return; }
                        let Some(parent) = parent else { return; };
                        let bar = HWND(parent as _);
                        if !unsafe { IsWindow(bar).as_bool() && GetParent(hwnd).is_ok_and(|p| p == bar) } { return; }
                        let mut origin = POINT::default();
                        if !unsafe { ClientToScreen(bar, &mut origin).as_bool() } {
                            log_native_error("ClientToScreen", &windows::core::Error::from_win32());
                            return;
                        }
                        let local = parent_client_rect(r, origin.x, origin.y);
                        let was_visible = unsafe { IsWindowVisible(hwnd).as_bool() };
                        let actual = rect(hwnd);
                        // A newer order-only callback can supersede an earlier placement while
                        // the UI thread is busy. Compare the real HWND instead of trusting moved.
                        if needs_child_placement(r, actual, was_visible) {
                            if actual != Some(r) {
                                hide_hover_now(&handle);
                                if let Some(details) = handle.get_webview_window(DETAILS) { let _ = details.close(); }
                            }
                            unsafe {
                                if let Err(error) = SetWindowPos(hwnd, HWND_TOP, local.left, local.top, local.right-local.left, local.bottom-local.top, SWP_NOACTIVATE) {
                                    log_native_error("position child", &error);
                                    return;
                                }
                            }
                            unsafe {
                                if let Err(error) = SetWindowPos(hwnd, HWND_TOP, local.left, local.top, local.right-local.left, local.bottom-local.top, SWP_NOACTIVATE | SWP_SHOWWINDOW) {
                                    log_native_error("show child", &error);
                                }
                            }
                            crate::applog(&format!("taskbar child: screen=({},{}) {}x{}, client=({},{})", r.left,r.top,r.right-r.left,r.bottom-r.top,local.left,local.top));
                        } else {
                            unsafe {
                                if let Err(error) = SetWindowPos(hwnd, HWND_TOP, 0,0,0,0,SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE) { log_native_error("order child", &error); }
                            }
                        }
                        // Cards deliberately remain independent top-level windows so the taskbar
                        // cannot clip them. Only the child strip inherits the shell's z-order.
                        for label in [HOVER, DETAILS] {
                            if let Some(card) = handle.get_webview_window(label) {
                                if card.is_visible().unwrap_or(false) { crate::topmost::reassert(&card); }
                            }
                        }
                    } else {
                        hide_hover_now(&handle);
                        unsafe { let _ = ShowWindow(hwnd,SW_HIDE); }
                        if let Some(details) = handle.get_webview_window(DETAILS) { let _ = details.close(); }
                    }
                });
            }
            std::thread::sleep(Duration::from_millis(150));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const BAR: Rect = Rect { left:0, top:1040, right:1920, bottom:1080 };
    fn r(left:i32, right:i32) -> Rect { Rect { left, right, ..BAR } }
    #[test]
    fn both_marked_areas_avoid_apps_and_system_tray() {
        let occupied = [r(700,1200), r(1720,1920)];
        let left = free_position(BAR, &occupied, false, 280, 8, 100).unwrap();
        let right = free_position(BAR, &occupied, true, 280, 8, 100).unwrap();
        assert_eq!((left.left,left.right), (8,288));
        assert_eq!((right.left,right.right), (1432,1712));
    }
    #[test]
    fn widgets_and_overlapping_controls_are_reserved() {
        let result = free_position(BAR, &[r(0,200),r(180,260),r(700,1200)], false, 280, 8,100).unwrap();
        assert_eq!(result.left,268);
    }
    #[test]
    fn full_taskbar_hides_panel_instead_of_covering_buttons() {
        assert!(free_position(BAR,&[r(0,1920)],false,280,8,100).is_none());
        assert!(free_position(BAR,&[r(0,1000),r(1060,1920)],true,280,8,100).is_none());
    }
    #[test]
    fn a_crowded_left_side_does_not_silently_move_to_the_right() {
        let occupied = [r(0,1100),r(1720,1920)];
        assert!(free_position(BAR,&occupied,false,280,8,100).is_none());
        assert!(free_position(BAR,&occupied,true,280,8,100).is_some());
    }
    #[test]
    fn negative_monitor_coordinates_and_narrow_gap() {
        let bar = Rect { left:-1920, right:0, ..BAR };
        let occupied = [Rect { left:-1700,right:0,..BAR }];
        let result = free_position(bar,&occupied,false,280,8,100).unwrap();
        assert_eq!((result.left,result.right),(-1912,-1708));
    }
    #[test]
    fn hover_tracks_each_indicator_and_stays_above_the_taskbar() {
        let screen = Rect { left:0, top:0, right:1920, bottom:1080 };
        let strip = Rect { left:800, top:1043, right:1080, bottom:1077 };
        let first = hover_position(strip, screen, 0.0, 40.0, 1.0, 360.0).unwrap();
        let next = hover_position(strip, screen, 48.0, 40.0, 1.0, 360.0).unwrap();
        assert_eq!((first.left, first.top, first.right, first.bottom), (697, 672, 943, 1032));
        assert_eq!(next.left - first.left, 48);
    }
    #[test]
    fn hover_clamps_at_both_edges_and_handles_a_top_taskbar() {
        let screen = Rect { left:0, top:0, right:1920, bottom:1080 };
        let left = hover_position(Rect { left:8, top:3, right:288, bottom:37 }, screen, 0.0, 40.0, 1.0, 360.0).unwrap();
        assert_eq!((left.left, left.top), (8, 48));
        let right = hover_position(Rect { left:1632, top:1043, right:1912, bottom:1077 }, screen, 240.0, 40.0, 1.0, 360.0).unwrap();
        assert_eq!(right.right, 1912);
    }
    #[test]
    fn hover_uses_physical_anchors_and_monitor_dpi_on_negative_monitor() {
        let screen = Rect { left:-2880, top:-200, right:0, bottom:1420 };
        let strip = Rect { left:-1500, top:1360, right:-1080, bottom:1414 };
        let popup = hover_position(strip, screen, 72.0, 60.0, 1.5, 540.0).unwrap();
        assert_eq!(popup, Rect { left:-1582, top:804, right:-1213, bottom:1344 });
    }
    #[test]
    fn hover_shrinks_to_small_monitors_and_rejects_invalid_geometry() {
        let screen = Rect { left:0, top:0, right:280, bottom:250 };
        let strip = Rect { left:8, top:214, right:272, bottom:248 };
        let popup = hover_position(strip, screen, -50.0, 40.0, 1.0, 360.0).unwrap();
        assert_eq!(popup, Rect { left:8, top:8, right:254, bottom:242 });
        assert!(hover_position(strip, screen, f64::NAN, 40.0, 1.0, 360.0).is_none());
        assert!(hover_position(strip, screen, 0.0, 0.0, 1.0, 360.0).is_none());
        assert!(hover_position(strip, screen, 0.0, 40.0, 0.0, 360.0).is_none());
    }
    #[test]
    fn maximized_client_is_visible_despite_its_invisible_frame_covering_the_screen() {
        let monitor = Rect { left:0, top:0, right:1920, bottom:1080 };
        let invisible_frame = Rect { left:-8, top:-8, right:1928, bottom:1088 };
        let client = Rect { left:0, top:31, right:1920, bottom:1040 };
        assert!(client_covers_monitor(invisible_frame, monitor), "the old outer-frame test misclassified this maximized app");
        assert!(!client_covers_monitor(client, monitor));
    }
    #[test]
    fn fullscreen_gate_is_specific_to_the_monitor_it_covers() {
        let primary = Rect { left:0, top:0, right:1920, bottom:1080 };
        let secondary = Rect { left:-1920, top:0, right:0, bottom:1080 };
        assert!(client_covers_monitor(primary, primary));
        assert!(client_covers_monitor(secondary, secondary));
        assert!(!client_covers_monitor(secondary, primary));
        assert!(!client_covers_monitor(Rect { bottom:1040, ..primary }, primary));
    }
    #[test]
    fn start_and_search_hosts_are_exempt_without_exempting_other_fullscreen_apps() {
        assert!(shell_surface("Windows.UI.Core.CoreWindow", "startmenuexperiencehost.exe"));
        assert!(shell_surface("Windows.UI.Core.CoreWindow", "searchhost.exe"));
        assert!(shell_surface("XamlExplorerHostIslandWindow", "explorer.exe"));
        assert!(shell_surface("Shell_TrayWnd", ""));
        assert!(!shell_surface("Windows.UI.Core.CoreWindow", "movieplayer.exe"));
        assert!(!shell_surface("CabinetWClass", "explorer.exe"));
        assert!(!shell_surface("Chrome_WidgetWin_1", "chrome.exe"));
    }
    #[test]
    fn a_missing_uia_reading_keeps_verified_space_without_guessing_an_initial_position() {
        let known = free_position(BAR, &[r(700,1200),r(1720,1920)], false, 280, 8,100);
        assert_eq!(refresh_position(BAR, None, known, false,280,8,100), known);
        assert_eq!(refresh_position(BAR, None, None, false,280,8,100), None);
    }
    #[test]
    fn activation_keeps_stable_space_but_real_new_buttons_invalidate_it() {
        let known = Rect { left:300, top:1043, right:580, bottom:1077 };
        let unchanged = [r(700,1200),r(1720,1920)];
        assert_eq!(refresh_position(BAR, Some(&unchanged), Some(known), false,280,8,100), Some(known));
        let new_buttons = [r(300,600),r(700,1200),r(1720,1920)];
        let moved = refresh_position(BAR, Some(&new_buttons), Some(known), false,280,8,100).unwrap();
        assert_eq!((moved.left,moved.right), (8,288));
        assert_eq!(refresh_position(BAR, Some(&[r(0,1920)]), Some(known), false,280,8,100), None);
    }
    #[test]
    fn the_card_window_keeps_its_size_and_the_card_sits_on_the_strips_side_of_it() {
        let anchor = HoverAnchor {
            strip: Rect { left:-1500, top:1360, right:-1080, bottom:1414 },
            screen: Rect { left:-2880, top:-200, right:0, bottom:1420 },
            x:72.0, width:60.0, scale:1.5,
        };
        let window = anchor.position().unwrap();
        assert_eq!(window, Rect { left:-1582, top:444, right:-1213, bottom:1344 }, "the tallest card's room, 16 px above the strip");
        let card = card_rect(window, anchor.strip, measured_hover_height(180.0, 1.5).unwrap());
        assert_eq!((card.left, card.top, card.right, card.bottom), (window.left, 1074, window.right, window.bottom));
        assert_eq!(card_rect(window, anchor.strip, 5000.0), window, "never more than the window");
        let top_strip = Rect { left:8, top:3, right:288, bottom:37 };
        let below = HoverAnchor { strip: top_strip, screen: Rect { left:0, top:0, right:1920, bottom:1080 }, x:0.0, width:40.0, scale:1.0 }.position().unwrap();
        assert_eq!((below.top, below.bottom), (48, 648));
        assert_eq!(card_rect(below, top_strip, 200.0), Rect { bottom:248, ..below }, "under a top taskbar the card hangs from the window's top");
    }
    #[test]
    fn measured_content_is_bounded_and_invalid_sizes_are_rejected() {
        assert_eq!(measured_hover_height(80.0,1.5),Some(120.0));
        assert_eq!(measured_hover_height(20.0,1.5),Some(60.0));
        assert_eq!(measured_hover_height(950.0,1.5),Some(900.0));
        for height in [0.0,-5.0,f64::NAN,f64::INFINITY] { assert!(measured_hover_height(height,1.0).is_none()); }
        for dpr in [0.0,0.1,8.1,f64::NAN,f64::INFINITY] { assert!(measured_hover_height(180.0,dpr).is_none()); }
        let screen = Rect { left:0, top:0, right:280, bottom:250 };
        let strip = Rect { left:8, top:214, right:272, bottom:248 };
        let popup = hover_position(strip,screen,0.0,40.0,1.0,measured_hover_height(950.0,1.0).unwrap()).unwrap();
        assert_eq!((popup.top,popup.bottom),(8,242));
    }
    #[test]
    fn child_lifecycle_waits_for_explorer_and_recreates_only_after_parent_changes() {
        assert_eq!(child_disposition(true,None,None),ChildDisposition::Waiting);
        assert_eq!(child_disposition(true,Some(10),None),ChildDisposition::Create);
        assert_eq!(child_disposition(true,Some(10),Some(10)),ChildDisposition::Keep);
        assert_eq!(child_disposition(true,Some(20),Some(10)),ChildDisposition::Recreate);
        assert_eq!(child_disposition(false,Some(10),Some(10)),ChildDisposition::Disabled);
        assert_eq!(child_disposition(false,None,None),ChildDisposition::Disabled);
    }
    #[test]
    fn child_positions_use_parent_client_coordinates_without_changing_popup_screen_coordinates() {
        let screen = Rect { left:-1710, top:1063, right:-1430, bottom:1097 };
        let local = parent_client_rect(screen,-1920,1060);
        assert_eq!(local,Rect { left:210,top:3,right:490,bottom:37 });
        assert_eq!((local.right-local.left,local.bottom-local.top),(280,34));
        let popup = hover_position(screen,Rect { left:-1920,top:20,right:0,bottom:1100 },0.0,40.0,1.0,180.0).unwrap();
        assert_eq!((popup.left,popup.bottom),(-1813,1052));
    }
    #[test]
    fn a_latest_order_callback_still_applies_geometry_if_the_earlier_placement_was_superseded() {
        let old = Rect { left:8,top:1043,right:288,bottom:1077 };
        let desired = Rect { left:1400,right:1680,..old };
        assert!(needs_child_placement(desired,Some(old),true));
        assert!(!needs_child_placement(desired,Some(desired),true));
        assert!(needs_child_placement(desired,Some(desired),false));
    }
    #[cfg(windows)]
    #[test]
    fn native_child_is_clipped_to_its_hidden_parent_and_destroyed_with_it() {
        use windows::{core::w, Win32::{Foundation::HWND, Graphics::Gdi::ClientToScreen, UI::{HiDpi::{AreDpiAwarenessContextsEqual,GetThreadDpiAwarenessContext,GetWindowDpiAwarenessContext},WindowsAndMessaging::*}}};
        struct HiddenWindow(HWND);
        impl Drop for HiddenWindow { fn drop(&mut self) { unsafe { let _ = DestroyWindow(self.0); } } }
        unsafe {
            let parent = CreateWindowExW(WINDOW_EX_STYLE(0),w!("STATIC"),w!(""),WS_POPUP,100,100,320,48,None,None,None,None).unwrap();
            let _cleanup = HiddenWindow(parent);
            let child = CreateWindowExW(WINDOW_EX_STYLE(0),w!("STATIC"),w!(""),WS_CHILD | WS_VISIBLE,12,3,200,42,parent,None,None,None).unwrap();
            assert_eq!(GetParent(child).unwrap(),parent);
            assert_ne!(GetWindowLongPtrW(child,GWL_STYLE) as u32 & WS_CHILD.0,0);
            assert_eq!(GetWindowLongPtrW(child,GWL_STYLE) as u32 & WS_POPUP.0,0);
            assert!(!IsWindowVisible(child).as_bool(),"a hidden parent also hides a WS_VISIBLE child");
            assert!(AreDpiAwarenessContextsEqual(GetThreadDpiAwarenessContext(),GetWindowDpiAwarenessContext(parent)).as_bool());
            let mut origin = windows::Win32::Foundation::POINT::default();
            assert!(ClientToScreen(parent,&mut origin).as_bool());
            let mut bounds = windows::Win32::Foundation::RECT::default();
            GetWindowRect(child,&mut bounds).unwrap();
            let local = parent_client_rect(Rect { left:bounds.left,top:bounds.top,right:bounds.right,bottom:bounds.bottom },origin.x,origin.y);
            assert_eq!(local,Rect { left:12,top:3,right:212,bottom:45 });
            DestroyWindow(parent).unwrap();
            assert!(!IsWindow(child).as_bool());
        }
    }
}
