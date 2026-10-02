//! A short-lived, non-taskbar card beside the configured notch edge, for any provider whose quota
//! window just renewed. It is a separate window so the user's "Hide" choice stays in force while an
//! alert can still be seen. Multiple alerts queued at once are shown one after another.

use crate::reset_watch::ResetEvent;
use crate::{config, glyphs, traymenu, AppState};
use serde::Serialize;
use std::collections::VecDeque;
use std::sync::{mpsc, Condvar, Mutex};
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindowBuilder};
#[cfg(windows)]
use windows::Win32::System::Diagnostics::Debug::MessageBeep;
#[cfg(windows)]
use windows::Win32::UI::WindowsAndMessaging::MB_ICONASTERISK;

const LABEL: &str = "reset-alert";
const CARD_W: f64 = 280.0;
const CARD_H: f64 = 150.0;
const SHOW_FOR: Duration = Duration::from_secs(6);
/// Logical px the pill occupies at the notch window's near edge on an upright edge (`#pill` in
/// notch.html is 70 px wide); used as an approximation of its depth when the notch lies flat too,
/// since a flat pill's own height is not a fixed constant the way its width is.
const PILL_DEPTH: f64 = 70.0;

#[derive(Default)]
struct QueueState {
    pending: VecDeque<QueuedAlert>,
    running: bool,
    dismissed: bool,
    active_token: u64,
}

struct QueuedAlert {
    event: ResetEvent,
    preview: bool,
}

#[derive(Default)]
pub struct AlertQueue {
    state: Mutex<QueueState>,
    changed: Condvar,
}

#[derive(Serialize)]
struct CardPayload {
    lang: String,
    edge: String,
    attached: bool,
    glyph: glyphs::Glyph,
    token: u64,
    title: String,
    subtitle: String,
    status: String,
    next: String,
    dismiss_label: String,
}

pub fn enqueue(app: &AppHandle, event: ResetEvent) {
    let state = app.state::<AppState>();
    let config = state.cfg.lock().unwrap();
    if config.reset_notifications {
        enqueue_unchecked(app, event, false);
    }
}

fn enqueue_unchecked(app: &AppHandle, event: ResetEvent, preview: bool) {
    let queue = &app.state::<AppState>().reset_alerts;
    let mut state = queue.state.lock().unwrap();
    state.pending.push_back(QueuedAlert { event, preview });
    if state.running {
        return;
    }
    state.running = true;
    let app = app.clone();
    std::thread::spawn(move || run(app));
}

fn run(app: AppHandle) {
    loop {
        let (queued, token) = {
            let queue = &app.state::<AppState>().reset_alerts;
            let mut state = queue.state.lock().unwrap();
            let Some(queued) = state.pending.pop_front() else {
                state.running = false;
                state.active_token = 0;
                return;
            };
            state.active_token = state.active_token.wrapping_add(1).max(1);
            state.dismissed = false;
            (queued, state.active_token)
        };
        if let Err(err) = show(&app, queued.event, token) {
            crate::applog(&format!("reset card: {err}"));
            if queued.preview {
                let _ = app.emit_to("settings", "reset_alert_preview_error", err);
            }
            close(&app);
            continue;
        }
        let queue = &app.state::<AppState>().reset_alerts;
        let state = queue.state.lock().unwrap();
        let _ = queue
            .changed
            .wait_timeout_while(state, SHOW_FOR, |s| !s.dismissed);
        close(&app);
    }
}

fn show(app: &AppHandle, event: ResetEvent, token: u64) -> Result<(), String> {
    let app_for_main = app.clone();
    let (sender, receiver) = mpsc::sync_channel(1);
    app.run_on_main_thread(move || {
        let result = show_on_main(&app_for_main, event, token);
        let _ = sender.send(result);
    })
    .map_err(|e| e.to_string())?;
    receiver
        .recv_timeout(Duration::from_secs(15))
        .map_err(|e| e.to_string())?
}

/// The pill's on-screen rectangle, derived from the notch window's own measured size rather than
/// recomputed from the monitor's scale factor and the configured notch size independently: at a
/// fractional monitor scale (125 %, 150 %) `place_notch` already absorbed rounding an independent
/// calculation here would not reproduce, and the two windows would drift apart right where this
/// card's tail is meant to meet the pill. Also doubles as this card's own px-per-logical-unit density,
/// so the card is drawn at the same size the notch itself currently is (Small/Medium/Large, per-monitor
/// DPI, all already folded into the notch window's measured size).
fn notch_geometry(app: &AppHandle) -> Option<(i32, i32, i32, i32)> {
    let w = app.get_webview_window("notch")?;
    let pos = w.outer_position().ok()?;
    let size = w.outer_size().ok()?;
    Some((pos.x, pos.y, size.width as i32, size.height as i32))
}

fn show_on_main(app: &AppHandle, event: ResetEvent, token: u64) -> Result<(), String> {
    let screen = crate::target_screen(app).ok_or("no display available")?;
    let (edge, cfg_scale, visible, lang) = {
        let st = app.state::<AppState>();
        let cfg = st.cfg.lock().unwrap();
        (
            config::edge_or_right(&cfg.notch_edge),
            config::snap_scale(cfg.scale),
            cfg.notch_visible,
            crate::resolved_lang(&cfg.lang),
        )
    };
    let vertical = config::edge_is_vertical(&edge);
    let geometry = notch_geometry(app);
    let density = geometry
        .map(|(_, _, w, h)| {
            let logical = if vertical { crate::NOTCH_W } else { crate::NOTCH_LONG };
            (if vertical { w } else { h }) as f64 / logical
        })
        .unwrap_or(screen.scale * cfg_scale);

    let glyph = app
        .state::<AppState>()
        .glyphs
        .lock()
        .unwrap()
        .get(&event.provider)
        .cloned()
        .unwrap_or_default();
    let now = crate::now_ms();
    let provider_name = crate::provider_label(&event.provider);
    let window_label = traymenu::label(&event.window_label, &lang);
    let payload = CardPayload {
        lang: lang.clone(),
        edge: edge.clone(),
        attached: visible,
        glyph,
        token,
        title: format!("{provider_name} {}", word_renewed(&lang)),
        subtitle: format!("{window_label} {}", word_renewed(&lang)),
        status: format!("{} · {}%", word_quota_available(&lang), traymenu::pct(event.used_fraction)),
        next: event
            .next_reset_at
            .map(|at| traymenu::reset_text(at, now, &lang))
            .unwrap_or_default(),
        dismiss_label: word_dismiss(&lang).to_string(),
    };
    let json = serde_json::to_string(&payload).map_err(|e| e.to_string())?;
    let script = format!(
        "{};window.__RESET_ALERT__={json};",
        crate::theme_script(crate::resolved_theme(app))
    );
    // Two alerts close enough together that the first's close() had not yet run (a fast double
    // click on Preview, mainly) would otherwise fail `build` outright with "already exists".
    if let Some(stale) = app.get_webview_window(LABEL) {
        let _ = stale.destroy();
    }
    let window = WebviewWindowBuilder::new(app, LABEL, WebviewUrl::App("reset-alert.html".into()))
        .title("Codenotch")
        .inner_size(CARD_W, CARD_H)
        .decorations(false)
        .transparent(true)
        .shadow(false)
        .resizable(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .visible(false)
        .focused(false)
        .theme(crate::theme_choice(app))
        .initialization_script(script)
        .build()
        .map_err(|e| e.to_string())?;

    let (ax, ay, aw, ah) = screen.area();
    let width = ((CARD_W * density).round() as u32).min(aw.max(1) as u32);
    let height = ((CARD_H * density).round() as u32).min(ah.max(1) as u32);
    window
        .set_size(tauri::PhysicalSize::new(width, height))
        .map_err(|e| e.to_string())?;

    let (x, y) = match geometry {
        // Beside (or above/below) the pill's own measured rectangle, not the screen edge: a notch
        // dragged along its edge, or a taskbar docked to it, can leave the pill short of flush.
        Some((nx, ny, nw, nh)) => {
            let pill = (PILL_DEPTH * density).round() as i32;
            match edge.as_str() {
                "left" => (nx + pill, ny + nh / 2 - height as i32 / 2),
                "top" => (nx + nw / 2 - width as i32 / 2, ny + pill),
                "bottom" => (nx + nw / 2 - width as i32 / 2, ny + nh - pill - height as i32),
                _ => (nx + nw - pill - width as i32, ny + nh / 2 - height as i32 / 2),
            }
        }
        // The notch window could not be measured (very unlikely, since it exists from launch): fall
        // back to a plain clearance from the work area's own edge.
        None => {
            let inset = ((if visible { 100.0 } else { 8.0 }) * density).round() as i32;
            let along = |span: i32, len: i32| {
                ((span as f64 * 0.5 - len as f64 / 2.0).round() as i32).clamp(0, (span - len).max(0))
            };
            match edge.as_str() {
                "left" => (ax + inset, ay + along(ah, height as i32)),
                "top" => (ax + along(aw, width as i32), ay + inset),
                "bottom" => (ax + along(aw, width as i32), ay + ah - height as i32 - inset),
                _ => (ax + aw - width as i32 - inset, ay + along(ah, height as i32)),
            }
        }
    };
    let x = x.clamp(ax, ax + aw - width as i32);
    let y = y.clamp(ay, ay + ah - height as i32);
    window
        .set_position(tauri::PhysicalPosition::new(x, y))
        .map_err(|e| e.to_string())?;
    // Moving a freshly built window onto a monitor at a different scale than the one it was created
    // on can have Windows silently reconvert its physical size for the new monitor — the same quirk
    // `place_notch` works around at 125 %/150 %. Re-checked and, if needed, redone once, the same way.
    if window.outer_size().map(|s| (s.width, s.height) != (width, height)).unwrap_or(false) {
        let _ = window.set_size(tauri::PhysicalSize::new(width, height));
        let _ = window.set_position(tauri::PhysicalPosition::new(x, y));
    }
    window.show().map_err(|e| e.to_string())?;

    let sound_on = app.state::<AppState>().cfg.lock().unwrap().reset_notification_sound;
    if sound_on {
        play_notification_sound();
    }
    Ok(())
}

#[cfg(windows)]
fn play_notification_sound() {
    let _ = unsafe { MessageBeep(MB_ICONASTERISK) };
}

#[cfg(not(windows))]
fn play_notification_sound() {}

fn word_renewed(lang: &str) -> &'static str {
    match lang {
        "pt-BR" => "renovado",
        "ru" => "обновлён",
        "zh" => "已更新",
        "zh-Hant" => "已更新",
        "ja" => "更新されました",
        "uk" => "оновлено",
        "ko" => "갱신됨",
        _ => "renewed",
    }
}

fn word_quota_available(lang: &str) -> &'static str {
    match lang {
        "pt-BR" => "Cota disponível",
        "ru" => "Лимит снова доступен",
        "zh" => "额度已恢复",
        "zh-Hant" => "額度已恢復",
        "ja" => "利用枠が回復しました",
        "uk" => "Ліміт знову доступний",
        "ko" => "사용 가능 한도가 회복되었습니다",
        _ => "Quota available",
    }
}

fn word_dismiss(lang: &str) -> &'static str {
    match lang {
        "pt-BR" => "Fechar",
        "ru" => "Закрыть",
        "zh" => "关闭",
        "zh-Hant" => "關閉",
        "ja" => "閉じる",
        "uk" => "Закрити",
        "ko" => "닫기",
        _ => "Dismiss",
    }
}

fn close(app: &AppHandle) {
    let app_for_main = app.clone();
    let (sender, receiver) = mpsc::sync_channel(1);
    if app
        .run_on_main_thread(move || {
            if let Some(window) = app_for_main.get_webview_window(LABEL) {
                let _ = window.destroy();
            }
            let _ = sender.send(());
        })
        .is_ok()
    {
        let _ = receiver.recv_timeout(Duration::from_secs(15));
    }
}

pub fn disable(app: &AppHandle) {
    let queue = &app.state::<AppState>().reset_alerts;
    let mut state = queue.state.lock().unwrap();
    state.pending.clear();
    state.dismissed = true;
    queue.changed.notify_all();
}

#[tauri::command]
pub fn dismiss_reset_alert(app: AppHandle, token: u64) {
    let queue = &app.state::<AppState>().reset_alerts;
    let mut state = queue.state.lock().unwrap();
    if state.active_token == token {
        state.dismissed = true;
        queue.changed.notify_all();
    }
}

#[tauri::command]
pub fn preview_reset_alert(app: AppHandle) -> Result<(), String> {
    if crate::target_screen(&app).is_none() {
        return Err("No display available for the reset card".into());
    }
    let now = crate::now_ms();
    enqueue_unchecked(
        &app,
        ResetEvent {
            provider: "codex".into(),
            window_label: "5h limit".into(),
            used_fraction: 0.0,
            next_reset_at: Some(now + 300 * 60_000),
        },
        true,
    );
    Ok(())
}
