//! Native taskbar input and lifecycle. Only our own child HWND is created.
//! Rendering and state stay on Tauri's main thread; no second message loop is used.
#![deny(unreachable_patterns, non_upper_case_globals, non_snake_case)]

use crate::{taskbar_model::{self, Frame}, taskbar_render::Renderer};
use std::{cell::{Cell, RefCell}, collections::HashMap, rc::Rc,
    sync::{atomic::{AtomicU64, Ordering}, OnceLock}, time::{Duration, Instant}};
use tauri::AppHandle;
use windows::{core::w, Win32::{
    Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, WPARAM},
    Graphics::Gdi::{BeginPaint, EndPaint, InvalidateRect, PAINTSTRUCT},
    System::LibraryLoader::GetModuleHandleW,
    UI::{Controls, HiDpi::{AreDpiAwarenessContextsEqual, GetThreadDpiAwarenessContext,
        GetWindowDpiAwarenessContext, SetThreadDpiAwarenessContext, DPI_AWARENESS_CONTEXT},
        Input::KeyboardAndMouse::{TrackMouseEvent, TRACKMOUSEEVENT, TME_LEAVE},
        WindowsAndMessaging::{self as wm, *}},
}};

const ANIMATION_TIMER: usize = 1;
const RECOVERY_TIMER: usize = 2;
const MAX_RECOVERY_ATTEMPTS: u8 = 3;
static GENERATION: AtomicU64 = AtomicU64::new(0);
static WINDOW_CLASS: OnceLock<Result<usize, String>> = OnceLock::new();

thread_local! { static STRIP: RefCell<Option<Rc<NativeState>>> = const { RefCell::new(None) }; }

#[derive(Default)]
struct Input {
    hovered: Option<String>, pressed: Option<String>, right_pressed: Option<String>,
    right_down: bool, tracking_leave: bool,
}

impl Input {
    fn release_left(&mut self, selected: Option<String>) -> Option<String> {
        let pressed = self.pressed.take();
        selected.filter(|id| pressed.as_ref() == Some(id))
    }
    fn release_right(&mut self, selected: Option<String>) -> bool {
        let matched = self.right_down && self.right_pressed == selected;
        self.right_down = false;
        self.right_pressed = None;
        matched
    }
}

struct Data {
    frame: Frame, scale: f32, width: u32, height: u32, input: Input,
    renderer: Option<Renderer>, renderer_size: Option<(u32, u32)>,
    recovery_attempts: u8, animation_timer: bool, recovery_timer: bool,
    refreshing: HashMap<String, Instant>,
}

struct NativeState {
    app: Option<AppHandle>, hwnd: Cell<HWND>, generation: u64, hover_epoch: Cell<u64>,
    closed: Cell<bool>, closing: Cell<bool>, drawing: Cell<bool>, started: Instant, data: RefCell<Data>,
}

#[derive(Clone)]
enum Action {
    Hover { id: String, x: f64, width: f64, epoch: u64 },
    Leave { epoch: u64 }, Refresh(String), Settings,
}

fn native_error(operation: &str, error: &windows::core::Error) -> String {
    format!("Native taskbar: {operation}; code=0x{:08X}", error.code().0 as u32)
}

fn log_error(operation: &str, error: &windows::core::Error) {
    crate::applog(&native_error(operation, error));
}

fn current_state() -> Option<Rc<NativeState>> { STRIP.with(|slot| slot.borrow().clone()) }

fn valid_scale(scale: f32) -> bool { scale.is_finite() && (0.5..=8.0).contains(&scale) }

fn register_class() -> Result<HINSTANCE, String> {
    WINDOW_CLASS.get_or_init(|| unsafe {
        let instance = HINSTANCE(GetModuleHandleW(None).map_err(|error| native_error("get module", &error))?.0);
        let class = WNDCLASSEXW {
            cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
            style: CS_HREDRAW | CS_VREDRAW, lpfnWndProc: Some(window_proc), hInstance: instance,
            hCursor: LoadCursorW(None, IDC_HAND).unwrap_or_default(),
            lpszClassName: w!("CodenotchNativeTaskbar"), ..Default::default()
        };
        if RegisterClassExW(&class) == 0 { return Err(native_error("register class", &windows::core::Error::from_win32())); }
        Ok(instance.0 as usize)
    }).clone().map(|instance| HINSTANCE(instance as _))
}

struct DpiScope(Option<DPI_AWARENESS_CONTEXT>);
impl DpiScope {
    unsafe fn parent(parent: HWND) -> Result<Self, String> {
        let parent_context = GetWindowDpiAwarenessContext(parent);
        let thread_context = GetThreadDpiAwarenessContext();
        if parent_context.0.is_null() || thread_context.0.is_null() {
            return Err("Native taskbar: DPI context unavailable".into());
        }
        if AreDpiAwarenessContextsEqual(parent_context, thread_context).as_bool() { return Ok(Self(None)); }
        let previous = SetThreadDpiAwarenessContext(parent_context);
        if previous.0.is_null() { return Err(native_error("set creation DPI", &windows::core::Error::from_win32())); }
        Ok(Self(Some(previous)))
    }
}
impl Drop for DpiScope {
    fn drop(&mut self) { if let Some(previous) = self.0 { unsafe {
        if SetThreadDpiAwarenessContext(previous).0.is_null() { log_error("restore creation DPI", &windows::core::Error::from_win32()); }
    } } }
}

/// Main thread only. The watcher positions/shows the returned child after creation.
pub fn create(app: AppHandle, parent: HWND, width: u32, height: u32, scale: f32, frame: Frame) -> Result<isize, String> {
    if width == 0 || height == 0 || width > 4096 || height > 4096 || !valid_scale(scale) {
        return Err("Native taskbar: invalid dimensions or scale".into());
    }
    if hwnd().is_some() { return Err("Native taskbar: child already exists".into()); }
    unsafe {
        if !IsWindow(parent).as_bool() { return Err("Native taskbar: parent unavailable".into()); }
        let _dpi = DpiScope::parent(parent)?;
        let instance = register_class()?;
        let state = Rc::new(NativeState {
            app: Some(app), hwnd: Cell::new(HWND::default()), generation: GENERATION.fetch_add(1, Ordering::Relaxed).wrapping_add(1),
            hover_epoch: Cell::new(0), closed: Cell::new(false), closing: Cell::new(false), drawing: Cell::new(false), started: Instant::now(),
            data: RefCell::new(Data { frame, scale, width, height, input: Input::default(), renderer: None,
                renderer_size: None, recovery_attempts: 0, animation_timer: false, recovery_timer: false,
                refreshing: HashMap::new() }),
        });
        STRIP.with(|slot| *slot.borrow_mut() = Some(state.clone()));
        let created = CreateWindowExW(WS_EX_NOACTIVATE | WS_EX_NOREDIRECTIONBITMAP,
            w!("CodenotchNativeTaskbar"), w!(""), WS_CHILD | WS_CLIPSIBLINGS,
            0, 0, width as i32, height as i32, parent, None, instance, Some(Rc::as_ptr(&state) as *const _));
        let window = match created {
            Ok(window) => window,
            Err(error) => {
                STRIP.with(|slot| { if slot.borrow().as_ref().is_some_and(|current| Rc::ptr_eq(current, &state)) { slot.replace(None); } });
                return Err(native_error("create child", &error));
            }
        };
        if let Err(error) = draw(&state, true) {
            let message = native_error("initialize renderer", &error);
            let _ = DestroyWindow(window);
            return Err(message);
        }
        reconcile_timers(&state);
        if state.closed.get() { return Err("Native taskbar: child destroyed during creation".into()); }
        Ok(window.0 as isize)
    }
}

/// Main thread only. Does not quit Tauri or destroy any shell window.
pub fn destroy() {
    if let Some(state) = current_state() { unsafe {
        if IsWindow(state.hwnd.get()).as_bool() {
            state.closing.set(true);
            if let Err(error) = DestroyWindow(state.hwnd.get()) { state.closing.set(false); log_error("destroy child", &error); }
        }
    } }
}

/// Main thread only. No provider or credential access occurs while drawing.
pub fn update(frame: Frame, scale: f32) {
    if !valid_scale(scale) { return; }
    let Some(state) = current_state() else { return; };
    if state.closed.get() || state.closing.get() { return; }
    let reset_hover = {
        let mut data = state.data.borrow_mut();
        // Cells are packed to their figures, so a new figure can move the ones after it.
        let changed_layout = data.scale != scale || data.frame.appearance != frame.appearance
            || data.frame.items.iter().map(|item| (&item.id, &item.text))
            .ne(frame.items.iter().map(|item| (&item.id, &item.text)));
        data.refreshing.retain(|id, until| *until > Instant::now() && frame.items.iter().any(|item| &item.id == id));
        data.frame = frame;
        data.scale = scale;
        if changed_layout {
            let had_hover = data.input.hovered.take().is_some();
            data.input.pressed = None;
            data.input.right_pressed = None;
            data.input.right_down = false;
            had_hover
        } else { false }
    };
    if reset_hover { leave_action(&state); }
    reconcile_timers(&state);
    unsafe { let _ = InvalidateRect(state.hwnd.get(), None, false); }
}

/// Main thread only: a native HWND is never moved across threads in Rust state.
pub fn hwnd() -> Option<HWND> {
    current_state().filter(|state| !state.closed.get() && !state.closing.get())
        .map(|state| state.hwnd.get()).filter(|window| unsafe { IsWindow(*window).as_bool() })
}

fn target(data: &Data, x: f32, y: f32) -> Option<(usize, f32, f32)> {
    if y < 0.0 || y >= data.height as f32 || !x.is_finite() || !y.is_finite() { return None; }
    taskbar_model::layout(&data.frame, data.width as f32, data.height as f32, data.scale)
        .into_iter().find(|slot| slot.contains(x, y, data.height as f32))
        // The card centres on the ring and its tail points at it, not at the whole cell.
        .map(|slot| (slot.index, slot.center_x - slot.unit * taskbar_model::UNITS / 2.0, slot.unit * taskbar_model::UNITS))
}

fn bump_hover(state: &NativeState) -> u64 {
    let epoch = state.hover_epoch.get().wrapping_add(1);
    state.hover_epoch.set(epoch);
    epoch
}

fn leave_action(state: &Rc<NativeState>) {
    let epoch = bump_hover(state);
    defer(state, Action::Leave { epoch });
}

fn defer(state: &Rc<NativeState>, action: Action) {
    let Some(app) = state.app.clone() else { return; };
    let generation = state.generation;
    std::thread::spawn(move || {
        // The delay keeps a pass over the strip from opening a card; one already open just moves.
        if matches!(action, Action::Hover { .. }) && !crate::taskbar::hover_open() { std::thread::sleep(Duration::from_millis(140)); }
        let handle = app.clone();
        let _ = app.run_on_main_thread(move || {
            let Some(current) = current_state() else { return; };
            if current.generation != generation || current.closed.get() || current.closing.get() { return; }
            match action {
                Action::Hover { id, x, width, epoch } => {
                    if current.hover_epoch.get() != epoch || current.data.borrow().input.hovered.as_deref() != Some(id.as_str()) { return; }
                    let _ = crate::taskbar::show_taskbar_hover(handle, id, x, width);
                }
                Action::Leave { epoch } => {
                    if current.hover_epoch.get() == epoch { crate::taskbar::hide_taskbar_hover(handle); }
                }
                Action::Refresh(id) => {
                    if !current.data.borrow().frame.items.iter().any(|item| item.id == id) { return; }
                    match crate::taskbar_activity::refresh_taskbar_item(handle, id.clone()) {
                        Ok(true) => {
                            current.data.borrow_mut().refreshing.insert(id, Instant::now() + Duration::from_secs(1));
                            reconcile_timers(&current);
                            unsafe { let _ = InvalidateRect(current.hwnd.get(), None, false); }
                        }
                        Ok(false) => (),
                        Err(_) => crate::applog("Native taskbar: refresh rejected"),
                    }
                }
                Action::Settings => {
                    crate::taskbar::hide_taskbar_hover(handle.clone());
                    crate::settings_window::open(&handle);
                }
            }
        });
    });
}

fn animated(data: &Data, now: Instant) -> bool {
    data.frame.items.iter().any(|item| matches!(item.work_state.as_str(), "busy" | "waiting"))
        || data.refreshing.values().any(|until| *until > now)
}

fn reconcile_timers(state: &Rc<NativeState>) {
    if state.closed.get() || state.closing.get() { return; }
    let window = state.hwnd.get();
    let visible = unsafe { IsWindowVisible(window).as_bool() };
    let changes = {
        let mut data = state.data.borrow_mut();
        let animation = visible && data.width > 0 && data.height > 0 && data.renderer.is_some() && animated(&data, Instant::now());
        let recovery = visible && !state.drawing.get() && data.width > 0 && data.height > 0 && data.renderer.is_none();
        let changes = [(ANIMATION_TIMER, animation, data.animation_timer), (RECOVERY_TIMER, recovery, data.recovery_timer)];
        data.animation_timer = animation;
        data.recovery_timer = recovery;
        changes
    };
    for (id, wanted, running) in changes {
        if wanted == running { continue; }
        unsafe {
            if wanted {
                // The notch steps its spin and pulse about ten times a second; 50 ms catches every step.
                if SetTimer(window, id, if id == ANIMATION_TIMER { 50 } else { 500 }, None) == 0 {
                    critical_close(state, "start drawing timer", &windows::core::Error::from_win32());
                    return;
                }
            } else { let _ = KillTimer(window, id); }
        }
    }
}

/// Graphics calls may pump messages. Release every RefCell borrow before entering COM.
fn draw(state: &Rc<NativeState>, recreate: bool) -> windows::core::Result<()> {
    if state.closed.get() || state.closing.get() { return Ok(()); }
    if state.drawing.replace(true) { return Ok(()); }
    struct Drawing<'a>(&'a Cell<bool>);
    impl Drop for Drawing<'_> { fn drop(&mut self) { self.0.set(false); } }
    let _drawing = Drawing(&state.drawing);
    let (renderer, renderer_size, frame, scale, width, height, pressed) = {
        let mut data = state.data.borrow_mut();
        if data.width == 0 || data.height == 0 { return Ok(()); }
        let now = Instant::now();
        data.refreshing.retain(|_, until| *until > now);
        // A click refreshes as the notch's does: the ring presses in while the reading is fetched.
        let held = data.input.pressed.as_deref().or(data.input.right_pressed.as_deref());
        let pressed: Vec<usize> = data.frame.items.iter().enumerate()
            .filter(|(_, item)| data.refreshing.contains_key(&item.id) || held == Some(item.id.as_str()))
            .map(|(index, _)| index).collect();
        (data.renderer.take(), data.renderer_size, data.frame.clone(), data.scale, data.width, data.height, pressed)
    };
    let Some(mut renderer) = renderer else {
        if !recreate { return Ok(()); }
        let mut renderer = Renderer::new(state.hwnd.get(), width, height)?;
        if state.closed.get() || state.closing.get() { return Ok(()); }
        renderer.draw(&frame, scale, &pressed, state.started.elapsed().as_secs_f32())?;
        if !state.closed.get() && !state.closing.get() {
            crate::applog(&format!("Native taskbar: renderer {}", renderer.driver()));
            let mut data = state.data.borrow_mut();
            data.renderer = Some(renderer);
            data.renderer_size = Some((width, height));
            data.recovery_attempts = 0;
        }
        return Ok(());
    };
    if renderer_size != Some((width, height)) { renderer.resize(width, height)?; }
    if state.closed.get() || state.closing.get() { return Ok(()); }
    renderer.draw(&frame, scale, &pressed, state.started.elapsed().as_secs_f32())?;
    if !state.closed.get() && !state.closing.get() {
        let mut data = state.data.borrow_mut();
        data.renderer = Some(renderer);
        data.renderer_size = Some((width, height));
        data.recovery_attempts = 0;
    }
    Ok(())
}

fn drawing_failed(state: &Rc<NativeState>, operation: &str, error: &windows::core::Error) {
    log_error(operation, error);
    let exhausted = {
        let mut data = state.data.borrow_mut();
        data.renderer = None;
        data.renderer_size = None;
        data.recovery_attempts = data.recovery_attempts.saturating_add(1);
        data.recovery_attempts >= MAX_RECOVERY_ATTEMPTS
    };
    if exhausted { critical_close(state, "renderer recovery exhausted", error); }
    else { reconcile_timers(state); }
}

fn critical_close(state: &Rc<NativeState>, operation: &str, error: &windows::core::Error) {
    if state.closing.replace(true) || state.closed.get() { return; }
    log_error(operation, error);
    unsafe {
        let _ = KillTimer(state.hwnd.get(), ANIMATION_TIMER);
        let _ = KillTimer(state.hwnd.get(), RECOVERY_TIMER);
        if let Err(error) = PostMessageW(state.hwnd.get(), wm::WM_CLOSE, WPARAM(0), LPARAM(0)) {
            log_error("post critical close", &error);
            if let Err(error) = DestroyWindow(state.hwnd.get()) { log_error("critical destroy", &error); }
        }
    }
}

unsafe extern "system" fn window_proc(window: HWND, message: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if message == wm::WM_NCCREATE {
        let create = &*(lparam.0 as *const CREATESTRUCTW);
        let raw = create.lpCreateParams as *const NativeState;
        if raw.is_null() { return LRESULT(0); }
        // One strong reference belongs to this HWND until WM_NCDESTROY. A local
        // reference per callback also survives destruction reentrant from COM.
        Rc::increment_strong_count(raw);
        (*raw).hwnd.set(window);
        SetWindowLongPtrW(window, GWLP_USERDATA, raw as isize);
        return LRESULT(1);
    }
    let raw = GetWindowLongPtrW(window, GWLP_USERDATA) as *const NativeState;
    if raw.is_null() { return DefWindowProcW(window, message, wparam, lparam); }
    Rc::increment_strong_count(raw);
    let current = Rc::from_raw(raw);
    let x = lparam.0 as u16 as i16 as f32;
    let y = (lparam.0 >> 16) as u16 as i16 as f32;
    match message {
        wm::WM_NCHITTEST => return LRESULT(HTCLIENT as isize),
        wm::WM_MOUSEACTIVATE => return LRESULT(MA_NOACTIVATE as isize),
        wm::WM_ERASEBKGND => return LRESULT(1),
        wm::WM_PAINT => {
            let mut paint = PAINTSTRUCT::default();
            let _ = BeginPaint(window, &mut paint);
            if let Err(error) = draw(&current, false) { drawing_failed(&current, "draw", &error); }
            reconcile_timers(&current);
            let _ = EndPaint(window, &paint);
            return LRESULT(0);
        }
        wm::WM_MOUSEMOVE => {
            let (changed, selected, track) = {
                let mut data = current.data.borrow_mut();
                let selected = target(&data, x, y).map(|(index, x, width)| (data.frame.items[index].id.clone(), x, width));
                let hovered = selected.as_ref().map(|(id, _, _)| id.clone());
                let changed = data.input.hovered != hovered;
                data.input.hovered = hovered;
                let track = !data.input.tracking_leave;
                data.input.tracking_leave = true;
                (changed, selected, track)
            };
            if track {
                let mut tracking = TRACKMOUSEEVENT { cbSize: std::mem::size_of::<TRACKMOUSEEVENT>() as u32,
                    dwFlags: TME_LEAVE, hwndTrack: window, dwHoverTime: 0 };
                if let Err(error) = TrackMouseEvent(&mut tracking) { critical_close(&current, "track mouse leave", &error); }
            }
            if changed {
                let epoch = bump_hover(&current);
                match selected {
                    Some((id, x, width)) => defer(&current, Action::Hover { id, x: x as f64, width: width as f64, epoch }),
                    None => defer(&current, Action::Leave { epoch }),
                }
                let _ = InvalidateRect(window, None, false);
            }
            return LRESULT(0);
        }
        Controls::WM_MOUSELEAVE => {
            current.data.borrow_mut().input = Input::default();
            leave_action(&current);
            let _ = InvalidateRect(window, None, false);
            return LRESULT(0);
        }
        wm::WM_LBUTTONDOWN | wm::WM_LBUTTONUP | wm::WM_RBUTTONDOWN | wm::WM_RBUTTONUP => {
            let action = {
                let mut data = current.data.borrow_mut();
                let selected = target(&data, x, y).map(|(index, _, _)| data.frame.items[index].id.clone());
                match message {
                    wm::WM_LBUTTONDOWN => { data.input.pressed = selected; None }
                    wm::WM_LBUTTONUP => {
                        data.input.release_left(selected).map(Action::Refresh)
                    }
                    wm::WM_RBUTTONDOWN => { data.input.right_down = true; data.input.right_pressed = selected; None }
                    wm::WM_RBUTTONUP => {
                        data.input.release_right(selected).then_some(Action::Settings)
                    }
                    _ => None,
                }
            };
            if let Some(action) = action { defer(&current, action); }
            let _ = InvalidateRect(window, None, false);
            return LRESULT(0);
        }
        wm::WM_CONTEXTMENU => { defer(&current, Action::Settings); return LRESULT(0); }
        wm::WM_CANCELMODE | wm::WM_CAPTURECHANGED => {
            let mut data = current.data.borrow_mut();
            data.input.pressed = None;
            data.input.right_pressed = None;
            data.input.right_down = false;
            drop(data);
            let _ = InvalidateRect(window, None, false);
        }
        wm::WM_SIZE => {
            let width = lparam.0 as u16 as u32;
            let height = (lparam.0 >> 16) as u16 as u32;
            let had_hover = {
                let mut data = current.data.borrow_mut();
                data.width = width;
                data.height = height;
                let had_hover = data.input.hovered.is_some();
                data.input = Input::default();
                had_hover
            };
            if had_hover { leave_action(&current); }
            reconcile_timers(&current);
            let _ = InvalidateRect(window, None, false);
        }
        wm::WM_SHOWWINDOW | wm::WM_WINDOWPOSCHANGED => {
            let result = DefWindowProcW(window, message, wparam, lparam);
            reconcile_timers(&current);
            if !IsWindowVisible(window).as_bool() {
                current.data.borrow_mut().input = Input::default();
                leave_action(&current);
            }
            return result;
        }
        wm::WM_TIMER if wparam.0 == ANIMATION_TIMER => {
            reconcile_timers(&current);
            if IsWindowVisible(window).as_bool() { let _ = InvalidateRect(window, None, false); }
            return LRESULT(0);
        }
        wm::WM_TIMER if wparam.0 == RECOVERY_TIMER => {
            if IsWindowVisible(window).as_bool() {
                if let Err(error) = draw(&current, true) { drawing_failed(&current, "recover renderer", &error); }
            }
            reconcile_timers(&current);
            return LRESULT(0);
        }
        wm::WM_CLOSE => {
            current.closing.set(true);
            if let Err(error) = DestroyWindow(window) { log_error("close child", &error); }
            return LRESULT(0);
        }
        wm::WM_DESTROY => {
            current.closing.set(true);
            let _ = KillTimer(window, ANIMATION_TIMER);
            let _ = KillTimer(window, RECOVERY_TIMER);
            return LRESULT(0);
        }
        wm::WM_NCDESTROY => {
            current.closed.set(true);
            SetWindowLongPtrW(window, GWLP_USERDATA, 0);
            let renderer = current.data.borrow_mut().renderer.take();
            drop(renderer);
            STRIP.with(|slot| {
                if slot.borrow().as_ref().is_some_and(|state| Rc::ptr_eq(state, &current)) { slot.replace(None); }
            });
            if let Some(app) = current.app.clone() {
                // The callback clears only native bookkeeping synchronously and
                // defers its WebView operations beyond this WndProc.
                crate::taskbar::native_destroyed(&app, window.0 as isize);
            }
            let result = DefWindowProcW(window, message, wparam, lparam);
            drop(Rc::from_raw(raw)); // Release the HWND's reference, not another thread's state.
            return result;
        }
        _ => (),
    }
    DefWindowProcW(window, message, wparam, lparam)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::taskbar_model::Indicator;

    fn frame() -> Frame {
        Frame { dark: true, watch: 0.5, critical: 0.7, appearance:crate::taskbar_model::Appearance::from_config(&crate::config::Config::default()), items: ["claude@home", "claude@work"].into_iter().map(|id| Indicator {
            id: id.into(), provider: "claude".into(), headline: Some(0.28), weekly: Some(0.12),
            text: "28%".into(), work_state: "idle".into(), stale: false, spent: false,
        }).collect() }
    }

    fn test_state() -> Rc<NativeState> {
        Rc::new(NativeState {
            app: None, hwnd: Cell::new(HWND::default()), generation: GENERATION.fetch_add(1, Ordering::Relaxed).wrapping_add(1),
            hover_epoch: Cell::new(0), closed: Cell::new(false), closing: Cell::new(false), drawing: Cell::new(false), started: Instant::now(),
            data: RefCell::new(Data { frame: frame(), scale: 1.0, width: 280, height: 42, input: Input::default(),
                renderer: None, renderer_size: None, recovery_attempts: 0, animation_timer: false, recovery_timer: false,
                refreshing: HashMap::new() }),
        })
    }

    #[test]
    fn releases_require_the_account_pressed_even_when_accounts_move() {
        let mut input = Input::default();
        input.pressed = Some("claude@home".into());
        assert_eq!(input.release_left(Some("claude@work".into())), None);
        input.pressed = Some("claude@home".into());
        assert_eq!(input.release_left(Some("claude@home".into())).as_deref(), Some("claude@home"));
        assert_eq!(input.release_left(Some("claude@home".into())), None, "a second release must not refresh twice");
        input.right_down = true;
        input.right_pressed = Some("claude@home".into());
        assert!(!input.release_right(Some("claude@work".into())));
        assert!(!input.release_right(Some("claude@home".into())));
    }

    #[test]
    fn temporary_refresh_animation_expires_without_changing_the_provider_state() {
        let state = test_state();
        let now = Instant::now();
        let mut data = state.data.borrow_mut();
        assert!(!animated(&data, now));
        data.refreshing.insert("claude@home".into(), now + Duration::from_secs(1));
        assert!(animated(&data, now));
        assert!(!animated(&data, now + Duration::from_secs(2)));
        assert!(data.frame.items.iter().all(|item| item.work_state == "idle"));
        data.frame.items[1].work_state = "waiting".into();
        assert!(animated(&data, now + Duration::from_secs(2)));
    }

    #[test]
    fn paint_without_a_renderer_leaves_the_pending_recovery_timer_armed() {
        let state = test_state();
        state.data.borrow_mut().recovery_timer = true;
        draw(&state, false).unwrap();
        assert!(!state.drawing.get(), "the drawing guard must be released on an early return");
        assert!(state.data.borrow().recovery_timer, "a paint cannot cancel the retry needed to restore graphics");
    }

    #[test]
    fn destroying_the_native_child_releases_state_and_never_posts_application_quit() {
        unsafe {
            let instance = register_class().unwrap();
            let parent = CreateWindowExW(WINDOW_EX_STYLE(0), w!("STATIC"), w!(""), WS_POPUP,
                0, 0, 320, 80, None, None, instance, None).unwrap();
            struct Window(HWND);
            impl Drop for Window { fn drop(&mut self) { unsafe { if IsWindow(self.0).as_bool() { let _ = DestroyWindow(self.0); } } } }
            let _parent = Window(parent);
            let state = test_state();
            let weak = Rc::downgrade(&state);
            STRIP.with(|slot| slot.replace(Some(state.clone())));
            let child = CreateWindowExW(WS_EX_NOACTIVATE | WS_EX_NOREDIRECTIONBITMAP,
                w!("CodenotchNativeTaskbar"), w!(""), WS_CHILD | WS_CLIPSIBLINGS, 0, 0, 280, 42,
                parent, None, instance, Some(Rc::as_ptr(&state) as *const _)).unwrap();
            let _child = Window(child);
            assert_eq!(hwnd(), Some(child));
            let focus = windows::Win32::UI::Input::KeyboardAndMouse::GetFocus();
            assert_eq!(SendMessageW(child, wm::WM_MOUSEACTIVATE, WPARAM(parent.0 as usize), LPARAM(0)).0, MA_NOACTIVATE as isize);
            assert_eq!(windows::Win32::UI::Input::KeyboardAndMouse::GetFocus(), focus);
            SendMessageW(child, wm::WM_APP + 77, WPARAM(0), LPARAM(0));
            assert!(!state.closed.get(), "unrelated messages must not match a message constant as a catch-all");
            assert!(state.data.borrow().input.hovered.is_none());
            destroy();
            assert!(state.closed.get());
            assert!(!IsWindow(child).as_bool());
            assert!(hwnd().is_none());
            let mut message = MSG::default();
            assert!(!PeekMessageW(&mut message, None, wm::WM_QUIT, wm::WM_QUIT, PM_NOREMOVE).as_bool(),
                "the strip must never stop Tauri's event loop");
            drop(state);
            assert!(weak.upgrade().is_none(), "WM_NCDESTROY must release the HWND's owned reference");
        }
    }
}
