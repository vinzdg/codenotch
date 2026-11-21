//! Minimal X11 helpers for Linux (pointer state and foreground window).

use x11rb::connection::Connection;
use x11rb::protocol::xproto::{AtomEnum, ConnectionExt, KeyButMask};

/// Root-window coordinates (physical pixels), for hit-testing against `outer_position`.
pub fn pointer_root_position() -> Option<(f64, f64)> {
    let (conn, screen) = connect()?;
    let root = conn.setup().roots[screen].root;
    let reply = conn.query_pointer(root).ok()?.reply().ok()?;
    Some((reply.root_x as f64, reply.root_y as f64))
}

pub fn primary_button_down() -> bool {
    let Some((conn, screen)) = connect() else {
        return false;
    };
    let root = conn.setup().roots[screen].root;
    let reply = match conn.query_pointer(root) {
        Ok(r) => r.reply(),
        Err(_) => return false,
    };
    match reply {
        Ok(p) => (p.mask & KeyButMask::BUTTON1) == KeyButMask::BUTTON1,
        Err(_) => false,
    }
}

pub fn foreground_pid() -> u32 {
    let Some((conn, screen)) = connect() else {
        return 0;
    };
    let root = conn.setup().roots[screen].root;
    let Some(net_active) = atom(&conn, b"_NET_ACTIVE_WINDOW") else {
        return 0;
    };
    let Some(window) = property_u32(&conn, root, net_active, AtomEnum::WINDOW) else {
        return 0;
    };
    if window == 0 {
        return 0;
    }
    let Some(net_pid) = atom(&conn, b"_NET_WM_PID") else {
        return 0;
    };
    property_u32(&conn, window, net_pid, AtomEnum::CARDINAL).unwrap_or(0)
}

fn property_u32(
    conn: &x11rb::rust_connection::RustConnection,
    window: u32,
    property: u32,
    type_: AtomEnum,
) -> Option<u32> {
    let cookie = conn.get_property(false, window, property, type_, 0, 1).ok()?;
    let prop = cookie.reply().ok()?;
    prop.value32().and_then(|mut v| v.next())
}

fn atom(conn: &x11rb::rust_connection::RustConnection, name: &[u8]) -> Option<u32> {
    conn.intern_atom(false, name)
        .ok()?
        .reply()
        .ok()
        .map(|r| r.atom)
}

/// Input shape of the notch window only. Root-pointer hit tests disagreed with the pill
/// (run.log r41: cursor at (25,181), pill at y=0) and `set_ignore_cursor_events` then
/// swallowed the hover. These rectangles are window-local, same space as the page's hot rects.
/// `pass_all` is the drag: the pointer has to be able to leave the pill.
pub fn sync_input_shape(rects: &[[f64; 4]], pass_all: bool) {
    let Some((conn, screen)) = connect() else { return };
    let root = conn.setup().roots[screen].root;
    let Some(window) = notch_window(&conn, root) else {
        static MISSING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
        if MISSING
            .compare_exchange(false, true, std::sync::atomic::Ordering::Relaxed, std::sync::atomic::Ordering::Relaxed)
            .is_ok()
        {
            crate::applog("linux input shape: notch window not in the client list yet");
        }
        return;
    };
    let Some(geom) = conn.get_geometry(window).ok().and_then(|c| c.reply().ok()) else { return };
    let rectangles = if pass_all || rects.is_empty() {
        vec![x11rb::protocol::xproto::Rectangle {
            x: 0,
            y: 0,
            width: geom.width,
            height: geom.height,
        }]
    } else {
        input_rects(rects)
    };
    use x11rb::protocol::shape::{ConnectionExt as _, SK, SO};
    use x11rb::protocol::xproto::ClipOrdering;
    let mut targets = vec![window];
    descendants(&conn, window, 4, &mut targets);
    let mut failed = false;
    for target in &targets {
        match conn.shape_rectangles(SO::SET, SK::INPUT, ClipOrdering::UNSORTED, *target, 0, 0, &rectangles) {
            Ok(cookie) => {
                if cookie.check().is_err() {
                    failed = true;
                }
            }
            Err(_) => failed = true,
        }
    }
    let _ = conn.flush();
    static LAST: std::sync::Mutex<String> = std::sync::Mutex::new(String::new());
    let signature = format!("{window}:{}:{pass_all}:{failed}:{}", rectangles.len(), geom.width);
    let mut last = LAST.lock().unwrap();
    if *last != signature {
        *last = signature;
        crate::applog(&format!(
            "linux input shape: window={window} size={}x{} targets={} rects={} pass_all={pass_all} failed={failed}",
            geom.width,
            geom.height,
            targets.len(),
            rectangles.len()
        ));
    }
}

fn input_rects(rects: &[[f64; 4]]) -> Vec<x11rb::protocol::xproto::Rectangle> {
    use x11rb::protocol::xproto::Rectangle;
    const PAD: f64 = 16.0;
    let mut out = Vec::new();
    for r in rects {
        if r[2] < 1.0 || r[3] < 1.0 {
            continue;
        }
        let x = (r[0] - PAD).floor() as i16;
        let y = (r[1] - PAD).floor() as i16;
        let w = (r[2] + PAD * 2.0).ceil().clamp(1.0, 4000.0) as u16;
        let h = (r[3] + PAD * 2.0).ceil().clamp(1.0, 4000.0) as u16;
        out.push(Rectangle { x, y, width: w, height: h });
    }
    out
}

fn notch_window(conn: &x11rb::rust_connection::RustConnection, root: u32) -> Option<u32> {
    client_ids(conn, root).into_iter().find(|id| {
        let (title, _) = window_names(conn, *id);
        title.contains("Codenotch notch")
    })
}

fn descendants(conn: &x11rb::rust_connection::RustConnection, window: u32, depth: u8, out: &mut Vec<u32>) {
    if depth == 0 {
        return;
    }
    for child in child_windows(conn, window) {
        if !out.contains(&child) {
            out.push(child);
            descendants(conn, child, depth - 1, out);
        }
    }
}

fn child_windows(conn: &x11rb::rust_connection::RustConnection, window: u32) -> Vec<u32> {
    conn.query_tree(window)
        .ok()
        .and_then(|c| c.reply().ok())
        .map(|tree| tree.children)
        .unwrap_or_default()
}

fn connect() -> Option<(x11rb::rust_connection::RustConnection, usize)> {
    if std::env::var_os("DISPLAY").is_none() {
        return None;
    }
    let (conn, screen) = x11rb::connect(None).ok()?;
    Some((conn, screen))
}

pub struct ClientWindow {
    pub id: u32,
    pub pid: u32,
    pub title: String,
    pub class_name: String,
}

pub fn client_windows() -> Vec<ClientWindow> {
    let Some((conn, screen)) = connect() else {
        return Vec::new();
    };
    let root = conn.setup().roots[screen].root;
    let mut out = Vec::new();
    for id in client_ids(&conn, root) {
        let (title, class_name) = window_names(&conn, id);
        out.push(ClientWindow {
            id,
            pid: pid_of(&conn, id),
            title,
            class_name,
        });
    }
    out
}

pub fn activate_window(id: u32) -> bool {
    let Some((conn, screen)) = connect() else {
        return false;
    };
    let root = conn.setup().roots[screen].root;
    let _ = conn.map_window(id);
    let aux = x11rb::protocol::xproto::ConfigureWindowAux::new()
        .stack_mode(x11rb::protocol::xproto::StackMode::ABOVE);
    let _ = conn.configure_window(id, &aux);
    let Some(kind) = atom(&conn, b"_NET_ACTIVE_WINDOW") else {
        return false;
    };
    send_message(&conn, root, id, kind, [1, 0, 0, 0, 0])
}

pub fn raise_window_titled(title: &str) -> bool {
    let Some(id) = find_title(title) else {
        return false;
    };
    let Some((conn, _)) = connect() else {
        return false;
    };
    let aux = x11rb::protocol::xproto::ConfigureWindowAux::new()
        .stack_mode(x11rb::protocol::xproto::StackMode::ABOVE);
    let Ok(cookie) = conn.configure_window(id, &aux) else {
        return false;
    };
    cookie.check().is_ok() && conn.flush().is_ok()
}

/// The notch window is in the client list and lacks `_NET_WM_STATE_ABOVE`.
pub fn notch_missing_above() -> bool {
    let Some(id) = find_title("Codenotch notch") else {
        return false;
    };
    !has_state(id, b"_NET_WM_STATE_ABOVE")
}

pub fn raise_notch_above() -> bool {
    let Some(id) = find_title("Codenotch notch") else {
        return false;
    };
    let Some((conn, screen)) = connect() else {
        return false;
    };
    let root = conn.setup().roots[screen].root;
    let Some(state) = atom(&conn, b"_NET_WM_STATE") else {
        return false;
    };
    let Some(above) = atom(&conn, b"_NET_WM_STATE_ABOVE") else {
        return false;
    };
    send_message(&conn, root, id, state, [1, above, 0, 0, 1])
}

pub fn capture_root(x: i32, y: i32, w: i32, h: i32) -> Option<Vec<u8>> {
    if w <= 0 || h <= 0 || x < 0 || y < 0 || w > 4096 || h > 4096 {
        return None;
    }
    let (conn, screen) = connect()?;
    let root = conn.setup().roots[screen].root;
    let reply = conn
        .get_image(
            x11rb::protocol::xproto::ImageFormat::Z_PIXMAP,
            root,
            x as i16,
            y as i16,
            w as u16,
            h as u16,
            u32::MAX,
        )
        .ok()?
        .reply()
        .ok()?;
    let need = (w as usize).saturating_mul(h as usize).saturating_mul(4);
    if reply.data.len() < need {
        return None;
    }
    Some(reply.data[..need].to_vec())
}

pub fn bell() {
    let Some((conn, _)) = connect() else {
        return;
    };
    let _ = conn.bell(0);
    let _ = conn.flush();
}

fn find_title(title: &str) -> Option<u32> {
    client_windows()
        .into_iter()
        .find(|w| w.title.contains(title))
        .map(|w| w.id)
}

fn has_state(window: u32, name: &[u8]) -> bool {
    let Some((conn, _)) = connect() else {
        return false;
    };
    let Some(state) = atom(&conn, b"_NET_WM_STATE") else {
        return false;
    };
    let Some(want) = atom(&conn, name) else {
        return false;
    };
    let Ok(cookie) = conn.get_property(false, window, state, AtomEnum::ATOM, 0, 64) else {
        return false;
    };
    let Ok(reply) = cookie.reply() else {
        return false;
    };
    reply.value32().is_some_and(|atoms| atoms.into_iter().any(|a| a == want))
}

fn send_message(
    conn: &x11rb::rust_connection::RustConnection,
    root: u32,
    window: u32,
    kind: u32,
    data: [u32; 5],
) -> bool {
    use x11rb::protocol::xproto::{ClientMessageData, ClientMessageEvent, EventMask};
    let event = ClientMessageEvent {
        response_type: x11rb::protocol::xproto::CLIENT_MESSAGE_EVENT,
        format: 32,
        sequence: 0,
        window,
        type_: kind,
        data: ClientMessageData::from(data),
    };
    let mask = EventMask::SUBSTRUCTURE_REDIRECT | EventMask::SUBSTRUCTURE_NOTIFY;
    let Ok(cookie) = conn.send_event(false, root, mask, &event) else {
        return false;
    };
    cookie.check().is_ok() && conn.flush().is_ok()
}

fn client_ids(conn: &x11rb::rust_connection::RustConnection, root: u32) -> Vec<u32> {
    let Some(list) = atom(conn, b"_NET_CLIENT_LIST") else {
        return Vec::new();
    };
    let Ok(cookie) = conn.get_property(false, root, list, AtomEnum::WINDOW, 0, 1024) else {
        return Vec::new();
    };
    let Ok(reply) = cookie.reply() else {
        return Vec::new();
    };
    reply.value32().map(|v| v.collect()).unwrap_or_default()
}

fn pid_of(conn: &x11rb::rust_connection::RustConnection, window: u32) -> u32 {
    let Some(net_pid) = atom(conn, b"_NET_WM_PID") else {
        return 0;
    };
    property_u32(conn, window, net_pid, AtomEnum::CARDINAL).unwrap_or(0)
}

fn window_names(conn: &x11rb::rust_connection::RustConnection, window: u32) -> (String, String) {
    let title = named(conn, window, b"_NET_WM_NAME").or_else(|| wm_name(conn, window)).unwrap_or_default();
    (title, wm_class(conn, window))
}

fn named(conn: &x11rb::rust_connection::RustConnection, window: u32, name: &[u8]) -> Option<String> {
    let property = atom(conn, name)?;
    let bytes = raw_prop(conn, window, property)?;
    Some(cstring_lossy(&bytes))
}

fn wm_name(conn: &x11rb::rust_connection::RustConnection, window: u32) -> Option<String> {
    let bytes = raw_prop(conn, window, u32::from(AtomEnum::WM_NAME))?;
    Some(cstring_lossy(&bytes))
}

fn wm_class(conn: &x11rb::rust_connection::RustConnection, window: u32) -> String {
    let Some(bytes) = raw_prop(conn, window, u32::from(AtomEnum::WM_CLASS)) else {
        return String::new();
    };
    bytes
        .split(|b| *b == 0)
        .filter(|s| !s.is_empty())
        .map(|s| String::from_utf8_lossy(s).into_owned())
        .collect::<Vec<_>>()
        .join(" ")
}

fn raw_prop(conn: &x11rb::rust_connection::RustConnection, window: u32, property: u32) -> Option<Vec<u8>> {
    let cookie = conn.get_property(false, window, property, AtomEnum::ANY, 0, 1024).ok()?;
    let reply = cookie.reply().ok()?;
    if reply.value.is_empty() {
        None
    } else {
        Some(reply.value)
    }
}

fn cstring_lossy(bytes: &[u8]) -> String {
    let end = bytes.iter().position(|b| *b == 0).unwrap_or(bytes.len());
    String::from_utf8_lossy(&bytes[..end]).into_owned()
}
