//! What is behind the folded pill, so the pill can be drawn in whichever colour stands out there.
//! Opt-in (Appearance → Adaptive pill), since it reads the screen. Off, or with the notch open, the
//! thread here sleeps until it is told otherwise: it neither reads nor wakes.
//!
//! Folded, the pill is all the notch shows, and it sits over whatever window or wallpaper reaches
//! the screen edge: a black pill vanishes on a dark one, a light pill on a light one. So while it is
//! folded, a strip of the screen beside it is read twice a second and reduced to one average
//! luminance, and the page is told when the other pill would clearly stand out more — what the
//! iPhone's home indicator does. That one number is all that is kept of the pixels.
//!
//! Beside the pill rather than under it: what a screen read sees of the notch window depends on
//! whether it is click-through at that moment (`set_click_through`), and beside the pill the page
//! draws nothing while folded, so the answer is the same either way.

use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager};

use crate::AppState;

struct Watch {
    enabled: bool,
    /// The strip to read, in physical pixels relative to the notch window. None while the notch is open.
    probe: Option<[f64; 4]>,
    /// Bumped on every change, so the thread can tell a new fold from the one it is already reading
    changed: u64,
}

static WATCH: Mutex<Watch> = Mutex::new(Watch { enabled: false, probe: None, changed: 0 });
static WAKE: Condvar = Condvar::new();

pub fn set_probe(probe: Option<[f64; 4]>) {
    let mut w = WATCH.lock().unwrap();
    if w.probe != probe {
        w.probe = probe;
        w.changed += 1;
        WAKE.notify_one();
    }
}

/// Switching it off hands the pill back to Theme at once, rather than leaving the last answer standing
pub fn set_enabled(app: &AppHandle, on: bool) {
    {
        let mut w = WATCH.lock().unwrap();
        w.enabled = on;
        w.changed += 1;
    }
    WAKE.notify_one();
    if !on {
        let _ = app.emit_to("notch", "pill_backdrop", "off");
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Backdrop {
    Light,
    Dark,
}

impl Backdrop {
    fn as_str(self) -> &'static str {
        match self {
            Backdrop::Light => "light",
            Backdrop::Dark => "dark",
        }
    }
}

/// Relative luminance of the two pills the page draws, #000 and #f5f5f7
const DARK_PILL: f64 = 0.0;
const LIGHT_PILL: f64 = 0.914;
/// How much more the other pill has to stand out before the pill changes, so a backdrop near the
/// middle, or a page scrolling past one, does not make it flicker
const HYSTERESIS: f64 = 1.5;

fn contrast(a: f64, b: f64) -> f64 {
    (a.max(b) + 0.05) / (a.min(b) + 0.05)
}

/// The backdrop the pill should be drawn for, given the one it is drawn for now
pub fn next(now: Backdrop, luminance: f64) -> Backdrop {
    let dark_pill = contrast(DARK_PILL, luminance);
    let light_pill = contrast(LIGHT_PILL, luminance);
    match now {
        Backdrop::Light if light_pill > dark_pill * HYSTERESIS => Backdrop::Dark,
        Backdrop::Dark if dark_pill > light_pill * HYSTERESIS => Backdrop::Light,
        _ => now,
    }
}

/// Mean relative luminance of 32-bit BGRA pixels
pub fn luminance(bgra: &[u8]) -> Option<f64> {
    let (pixels, _) = bgra.as_chunks::<4>();
    if pixels.is_empty() {
        return None;
    }
    let linear = |c: u8| {
        let c = c as f64 / 255.0;
        if c <= 0.04045 {
            c / 12.92
        } else {
            ((c + 0.055) / 1.055).powf(2.4)
        }
    };
    let sum: f64 = pixels
        .iter()
        .map(|[b, g, r, _]| 0.2126 * linear(*r) + 0.7152 * linear(*g) + 0.0722 * linear(*b))
        .sum();
    Some(sum / pixels.len() as f64)
}

const INTERVAL: Duration = Duration::from_millis(500);
/// The fold's clip takes 360 ms, and until it is done the strip is still covered by the open notch
const SETTLE: Duration = Duration::from_millis(450);
/// A read that fails (the session locked, the screen asleep) is tried again this much later
const RETRY: Duration = Duration::from_secs(5);

#[derive(Debug, PartialEq)]
enum Step {
    /// Nothing to read: sleep until set_enabled or set_probe changes something
    Park,
    Wait(Duration),
    Read([f64; 4]),
}

fn step(enabled: bool, probe: Option<[f64; 4]>, due: Instant, now: Instant) -> Step {
    let Some(rect) = probe.filter(|_| enabled) else { return Step::Park };
    match due.checked_duration_since(now) {
        Some(left) if !left.is_zero() => Step::Wait(left),
        _ => Step::Read(rect),
    }
}

pub fn start(app: AppHandle) {
    WATCH.lock().unwrap().enabled = app.state::<AppState>().cfg.lock().unwrap().adaptive_pill;
    std::thread::spawn(move || {
        let mut backdrop = Backdrop::Light;
        // While the page shows Theme's pill (before the first answer, and after switching off), the
        // next answer starts from that pill, so a middling backdrop does not flip it for nothing
        let mut themed = true;
        let mut seen = 0;
        let mut due = Instant::now();
        // Said once per fold even when unchanged, so a page that reloaded is not left guessing
        let mut told = false;
        loop {
            let rect = {
                let mut w = WATCH.lock().unwrap();
                loop {
                    if w.changed != seen {
                        seen = w.changed;
                        due = Instant::now() + SETTLE;
                        told = false;
                    }
                    if !w.enabled {
                        themed = true;
                    }
                    match step(w.enabled, w.probe, due, Instant::now()) {
                        Step::Park => w = WAKE.wait(w).unwrap(),
                        Step::Wait(left) => w = WAKE.wait_timeout(w, left).unwrap().0,
                        Step::Read(rect) => break rect,
                    }
                }
            };
            let Some(y) = read(&app, rect) else {
                due = Instant::now() + RETRY;
                continue;
            };
            due = Instant::now() + INTERVAL;
            if themed {
                backdrop = themed_backdrop(&app);
            }
            let now = next(backdrop, y);
            if now != backdrop || !told {
                backdrop = now;
                told = true;
                themed = false;
                let _ = app.emit_to("notch", "pill_backdrop", backdrop.as_str());
            }
        }
    });
}

/// The backdrop Theme's own pill is drawn for: the light pill is the one for a dark backdrop
fn themed_backdrop(app: &AppHandle) -> Backdrop {
    if crate::resolved_theme(app) == "light" {
        Backdrop::Dark
    } else {
        Backdrop::Light
    }
}

fn read(app: &AppHandle, rect: [f64; 4]) -> Option<f64> {
    let w = app.get_webview_window("notch")?;
    if !w.is_visible().ok()? {
        return None;
    }
    let pos = w.outer_position().ok()?;
    let [x, y, width, height] = rect.map(|v| v.round() as i32);
    luminance(&capture(pos.x + x, pos.y + y, width, height)?)
}

/// The screen's pixels in a rectangle of physical screen coordinates, as BGRA
#[cfg(windows)]
fn capture(x: i32, y: i32, w: i32, h: i32) -> Option<Vec<u8>> {
    use windows::Win32::Foundation::HWND;
    use windows::Win32::Graphics::Gdi::{
        BitBlt, CreateCompatibleBitmap, CreateCompatibleDC, DeleteDC, DeleteObject, GetDC, GetDIBits, ReleaseDC,
        SelectObject, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS, SRCCOPY,
    };
    if w <= 0 || h <= 0 {
        return None;
    }
    unsafe {
        let screen = GetDC(HWND::default());
        if screen.is_invalid() {
            return None;
        }
        let mem = CreateCompatibleDC(screen);
        let bitmap = CreateCompatibleBitmap(screen, w, h);
        let old = SelectObject(mem, bitmap);
        let copied = BitBlt(mem, 0, 0, w, h, screen, x, y, SRCCOPY).is_ok();
        // GetDIBits wants the bitmap out of the DC
        SelectObject(mem, old);
        let mut info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: w,
                biHeight: -h,
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        let mut pixels = vec![0u8; (w * h * 4) as usize];
        let rows = if copied {
            GetDIBits(mem, bitmap, 0, h as u32, Some(pixels.as_mut_ptr().cast()), &mut info, DIB_RGB_COLORS)
        } else {
            0
        };
        let _ = DeleteObject(bitmap);
        let _ = DeleteDC(mem);
        ReleaseDC(HWND::default(), screen);
        (rows == h).then_some(pixels)
    }
}

#[cfg(not(windows))]
fn capture(_x: i32, _y: i32, _w: i32, _h: i32) -> Option<Vec<u8>> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plain(r: u8, g: u8, b: u8) -> Vec<u8> {
        [b, g, r, 255].repeat(64)
    }

    #[test]
    fn a_plain_colour_reads_as_its_own_luminance() {
        assert_eq!(luminance(&plain(0, 0, 0)), Some(0.0));
        assert!((luminance(&plain(255, 255, 255)).unwrap() - 1.0).abs() < 1e-9);
        assert_eq!(luminance(&[]), None);
    }

    #[test]
    fn the_light_pill_constant_is_its_colour() {
        assert!((luminance(&plain(0xf5, 0xf5, 0xf7)).unwrap() - LIGHT_PILL).abs() < 0.001);
    }

    #[test]
    fn a_dark_backdrop_gets_the_light_pill_and_a_light_one_the_black() {
        let editor = luminance(&plain(0x1e, 0x1e, 0x1e)).unwrap();
        let window = luminance(&plain(0xf3, 0xf3, 0xf3)).unwrap();
        assert_eq!(next(Backdrop::Light, 0.0), Backdrop::Dark);
        assert_eq!(next(Backdrop::Light, editor), Backdrop::Dark);
        assert_eq!(next(Backdrop::Dark, 1.0), Backdrop::Light);
        assert_eq!(next(Backdrop::Dark, window), Backdrop::Light);
    }

    #[test]
    fn a_middling_backdrop_keeps_whichever_pill_it_has() {
        // #767676: both pills stand out from it by about the same, 4.6 and 4.2 to 1
        let grey = luminance(&plain(0x76, 0x76, 0x76)).unwrap();
        assert_eq!(next(Backdrop::Light, grey), Backdrop::Light);
        assert_eq!(next(Backdrop::Dark, grey), Backdrop::Dark);
    }

    #[test]
    fn it_only_wakes_while_switched_on_and_folded() {
        let (now, strip) = (Instant::now(), Some([0.0, 0.0, 12.0, 79.0]));
        assert_eq!(step(false, strip, now, now), Step::Park, "switched off: no timer at all");
        assert_eq!(step(true, None, now, now), Step::Park, "the notch open: no timer at all");
        assert_eq!(step(true, strip, now + SETTLE, now), Step::Wait(SETTLE));
        assert_eq!(step(true, strip, now, now + INTERVAL), Step::Read([0.0, 0.0, 12.0, 79.0]));
    }

    /// Reads the real screen, so it needs a desktop session: `cargo test -- --ignored reads_the_screen`
    #[test]
    #[ignore]
    fn reads_the_screen() {
        let pixels = capture(0, 0, 8, 8).expect("GDI answered");
        assert_eq!(pixels.len(), 8 * 8 * 4);
        assert!(luminance(&pixels).is_some());
    }

    #[test]
    fn text_on_a_white_page_is_still_a_white_page() {
        let mut page = plain(255, 255, 255);
        for px in page.chunks_mut(4).step_by(8) {
            px[..3].fill(0);
        }
        assert_eq!(next(Backdrop::Dark, luminance(&page).unwrap()), Backdrop::Light);
    }
}
