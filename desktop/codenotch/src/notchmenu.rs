//! The notch's right-click menu, the Mac's Refresh now and Quit Codenotch. Windows adds the ring's
//! usage page: a left click used to open it, and a left click now refreshes the ring instead.

use crate::i18n::tr;
use tauri::menu::{CheckMenuItemBuilder, MenuBuilder, MenuItemBuilder};
use tauri::{AppHandle, Manager, Window};

/// Tauri hands every menu event to every handler, the tray's included, so these ids carry their own
/// prefix and each handler ignores the other's.
const PREFIX: &str = "notch:";

pub fn setup(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("notch") {
        w.on_menu_event(|w, ev| handle(w.app_handle(), ev.id().as_ref()));
    }
}

#[tauri::command]
pub fn show_notch_menu(window: Window, provider: Option<String>) -> Result<(), String> {
    let app = window.app_handle();
    let lang = crate::tray::language(app);
    let err = |e: tauri::Error| e.to_string();
    let mut menu = MenuBuilder::new(app).item(
        &MenuItemBuilder::with_id(format!("{PREFIX}refresh"), tr(&lang, "refresh_now"))
            .build(app)
            .map_err(err)?,
    );
    let page = provider
        .as_deref()
        .and_then(|p| crate::provider_page(p).map(|(_, host)| (p, host)));
    if let Some((id, host)) = page {
        let open = MenuItemBuilder::with_id(
            format!("{PREFIX}open:{id}"),
            tr(&lang, "open_host").replace("%@", host),
        )
        .build(app)
        .map_err(err)?;
        menu = menu.item(&open);
    }
    // Checked while the notch is always open; unticking it is Show on hover
    let keep_open = CheckMenuItemBuilder::with_id(format!("{PREFIX}keep_open"), tr(&lang, "keep_open"))
        .checked(crate::keeps_open(app))
        .build(app)
        .map_err(err)?;
    let quit = MenuItemBuilder::with_id(format!("{PREFIX}quit"), tr(&lang, "quit_app"))
        .build(app)
        .map_err(err)?;
    let menu = menu.separator().item(&keep_open).separator().item(&quit).build().map_err(err)?;
    #[cfg(windows)]
    let before = foreground();
    // Returns once the menu has closed
    window.popup_menu(&menu).map_err(err)?;
    #[cfg(windows)]
    if let Ok(notch) = window.hwnd() {
        give_back(before, notch.0 as isize);
    }
    Ok(())
}

#[cfg(windows)]
fn foreground() -> isize {
    unsafe { windows::Win32::UI::WindowsAndMessaging::GetForegroundWindow().0 as isize }
}

/// Windows dismisses a popup menu properly only when its owner is in front, so showing one brings the
/// notch forward and typing stops reaching the editor. The Mac's panel never takes focus; handing it
/// back once the menu closes ends in the same place. Left alone when something else took the front
/// meanwhile, such as a window the dismissing click landed on.
#[cfg(windows)]
fn give_back(before: isize, notch: isize) {
    use windows::Win32::Foundation::HWND;
    use windows::Win32::UI::WindowsAndMessaging::SetForegroundWindow;
    if before == 0 || before == notch || foreground() != notch {
        return;
    }
    unsafe {
        let _ = SetForegroundWindow(HWND(before as _));
    }
}

fn handle(app: &AppHandle, id: &str) {
    let Some(item) = id.strip_prefix(PREFIX) else {
        return;
    };
    if let Some(provider) = item.strip_prefix("open:") {
        crate::open_provider_page(provider);
        return;
    }
    match item {
        "refresh" => crate::refresh_all(app),
        "keep_open" => crate::toggle_keep_open(app),
        "quit" => app.exit(0),
        _ => {}
    }
}
