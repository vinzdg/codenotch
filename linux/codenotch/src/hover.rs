//! Linux hover card lives in its own opaque window. The transparent notch WebView
//! (software compositor) keeps the previous paint when the HTML is replaced, so Codex
//! and Cursor stacked in one card. A second, non-transparent window paints one provider
//! at a time and can be hidden for real when the pointer leaves.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, PhysicalSize, WebviewUrl, WebviewWindowBuilder};

const LABEL: &str = "hover";
const CARD_W: f64 = 260.0;
const GAP: i32 = 10;
const HIDE_MS: u64 = 250;

static GEN: AtomicU64 = AtomicU64::new(0);
static LAST_HTML: Mutex<String> = Mutex::new(String::new());
static LAST_CELL: Mutex<Vec<f64>> = Mutex::new(Vec::new());

pub fn ensure(app: &AppHandle) {
    if app.get_webview_window(LABEL).is_some() {
        return;
    }
    let loaded = crate::new_linux_load_flag();
    let mut builder = WebviewWindowBuilder::new(app, LABEL, WebviewUrl::App("hover.html".into()))
        .title("Codenotch")
        .inner_size(CARD_W, 160.0)
        .decorations(false)
        .transparent(false)
        .shadow(false)
        .resizable(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .visible(false)
        .background_color(tauri::window::Color(0x0a, 0x0a, 0x0a, 255));
    builder = builder.on_page_load({
        let loaded = loaded.clone();
        move |_w, payload| {
            if matches!(payload.event(), tauri::webview::PageLoadEvent::Finished) {
                loaded.store(true, Ordering::SeqCst);
            }
        }
    });
    match builder.build() {
        Ok(w) => {
            crate::tune_linux_webview(&w, "hover", crate::HOVER_HTML, loaded);
            let _ = w.hide();
            crate::applog("hover window ready (opaque)");
        }
        Err(e) => crate::applog(&format!("hover window: {e}")),
    }
}

fn bump() -> u64 {
    GEN.fetch_add(1, Ordering::Relaxed) + 1
}

fn paint(w: &tauri::WebviewWindow, html: &str) {
    *LAST_HTML.lock().unwrap() = html.to_string();
    let payload = serde_json::to_string(html).unwrap_or_else(|_| "\"\"".into());
    let js = format!(
        "(function(){{var c=document.getElementById('card');if(!c)return;c.innerHTML={payload};var h=Math.ceil(c.scrollHeight);var t=window.__TAURI__;if(t&&t.core)t.core.invoke('hover_fit',{{w:260,h:h}});}})()"
    );
    if let Err(e) = w.eval(&js) {
        crate::applog(&format!("hover paint eval failed: {e}"));
    }
    let _ = w.emit("hover_paint", html);
}

#[tauri::command]
pub fn hover_show(app: AppHandle, html: String, cell: Vec<f64>) {
    bump();
    crate::applog(&format!(
        "hover_show bytes={} head={:?}",
        html.len(),
        html.chars().take(48).collect::<String>()
    ));
    let handle = app.clone();
    let _ = app.run_on_main_thread(move || {
        ensure(&handle);
        let Some(w) = handle.get_webview_window(LABEL) else { return };
        paint(&w, &html);
        *LAST_CELL.lock().unwrap() = cell.clone();
        place_hover(&handle, &w, &cell);
        let _ = w.show();
    });
}

#[tauri::command]
pub fn hover_keep() {
    bump();
}

#[tauri::command]
pub fn get_hover_html() -> String {
    LAST_HTML.lock().unwrap().clone()
}

#[tauri::command]
pub fn hover_hide(app: AppHandle) {
    let gen = GEN.load(Ordering::Relaxed);
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(HIDE_MS));
        if GEN.load(Ordering::Relaxed) != gen {
            return;
        }
        let handle = app.clone();
        let _ = app.run_on_main_thread(move || {
            if GEN.load(Ordering::Relaxed) != gen {
                return;
            }
            *LAST_HTML.lock().unwrap() = String::new();
            if let Some(w) = handle.get_webview_window(LABEL) {
                let _ = w.hide();
                let _ = w.eval("var c=document.getElementById('card');if(c)c.innerHTML='';");
                crate::applog("hover_hide");
            }
        });
    });
}

fn place_hover(app: &AppHandle, w: &tauri::WebviewWindow, cell: &[f64]) {
    if cell.len() < 4 {
        return;
    }
    let Some(notch) = app.get_webview_window("notch") else { return };
    let Ok(pos) = notch.outer_position() else { return };
    let h = w.outer_size().map(|s| s.height as i32).unwrap_or(160);
    let cx = cell[0];
    let cy = cell[1];
    let ch = cell[3];
    let x = pos.x + cx as i32 - CARD_W as i32 - GAP;
    let y = pos.y + cy as i32 + (ch as i32) / 2 - h / 2;
    let _ = w.set_position(PhysicalPosition::new(x.max(0), y.max(0)));
}

#[tauri::command]
pub fn hover_fit(app: AppHandle, w: f64, h: f64) {
    let handle = app.clone();
    let _ = app.run_on_main_thread(move || {
        let Some(win) = handle.get_webview_window(LABEL) else { return };
        let width = 260u32;
        let height = (h.round() as u32).clamp(72, 480);
        let _ = win.set_size(PhysicalSize::new(width, height));
        let cell = LAST_CELL.lock().unwrap().clone();
        place_hover(&handle, &win, &cell);
    });
    let _ = w;
}
