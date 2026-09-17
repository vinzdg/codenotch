//! The tray icon, and the provider marks the settings window shows.
//!
//! The icon draws no readings: those live in the tray menu, as they do in the Mac's menu bar. What
//! is left here is the mark itself and the base64/PNG plumbing the settings window needs to show an
//! installed app's own icon.

/// The application's own icon, at tray size.
///
/// NOT `icons/tray.png`: that one is a monochrome outline in pure black, which reads on a light
/// taskbar and is invisible on a dark one — the Windows 11 default. Recolouring it does not rescue
/// it either, because the shape is an outline with an empty middle: only 98 of its 1024 pixels are
/// fully opaque, so at 16 pixels it is a faint grey ring whichever colour it is drawn in.
/// `icons/tray-color.png` is the 32x32 frame lifted straight out of `icons/icon.ico`, the real
/// application icon, which carries its own colour and is legible on any taskbar. Windows, unlike
/// macOS, does not tint tray icons, so a template mark is not an option.
pub fn app_mark() -> Option<tauri::image::Image<'static>> {
    tauri::image::Image::from_bytes(include_bytes!("../icons/tray-color.png")).ok()
}

/// The same icon as a `data:` URL, so the settings window shows what the taskbar shows.
pub fn app_mark_data_url() -> Option<String> {
    png_data_url(include_bytes!("../icons/tray-color.png"))
}

/// Wraps PNG bytes that are already encoded (the bundled tray mark, or a provider's own icon) as a
/// `data:` URL.
pub fn png_data_url(png: &[u8]) -> Option<String> {
    if png.is_empty() {
        return None;
    }
    Some(format!("data:image/png;base64,{}", b64_encode(png)))
}

/// Base64 without pulling in a crate for it — the only encoder the app needs.
fn b64_encode(bytes: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for c in bytes.chunks(3) {
        let b = [c[0], *c.get(1).unwrap_or(&0), *c.get(2).unwrap_or(&0)];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        out.push(T[(n >> 18) as usize & 63] as char);
        out.push(T[(n >> 12) as usize & 63] as char);
        out.push(if c.len() > 1 { T[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if c.len() > 2 { T[n as usize & 63] as char } else { '=' });
    }
    out
}
