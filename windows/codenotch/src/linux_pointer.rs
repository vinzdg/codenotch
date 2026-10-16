//! Native input regions avoid polling a stale global pointer under XWayland.
use std::{cell::RefCell, rc::Rc, time::Duration};

use gtk::{glib, prelude::*};
use tauri::{AppHandle, Manager, WebviewWindow};

const LEAVE_GRACE: Duration = Duration::from_millis(250);
type PendingLeave = Rc<RefCell<Option<glib::SourceId>>>;

fn cancel_leave(pending: &PendingLeave) {
    if let Some(source) = pending.borrow_mut().take() {
        source.remove();
    }
}

/// Install once, with the GTK window's lifecycle, on the main thread.
pub fn install(window: &WebviewWindow) -> tauri::Result<()> {
    let gtk_window = window.gtk_window()?;
    let pending: PendingLeave = Rc::new(RefCell::new(None));
    gtk_window.add_events(gtk::gdk::EventMask::ENTER_NOTIFY_MASK | gtk::gdk::EventMask::LEAVE_NOTIFY_MASK);

    let leave_window = window.clone();
    let leave_pending = pending.clone();
    gtk_window.connect_leave_notify_event(move |_, event| {
        if event.detail() != gtk::gdk::NotifyType::Inferior {
            cancel_leave(&leave_pending);
            let window = leave_window.clone();
            let pending = leave_pending.clone();
            *leave_pending.borrow_mut() = Some(glib::timeout_add_local_once(LEAVE_GRACE, move || {
                pending.borrow_mut().take();
                let _ = window.eval("window.codenotchPointer(false)");
            }));
        }
        glib::Propagation::Proceed
    });

    let enter_window = window.clone();
    let enter_pending = pending.clone();
    gtk_window.connect_enter_notify_event(move |_, event| {
        if event.detail() != gtk::gdk::NotifyType::Inferior {
            cancel_leave(&enter_pending);
            let _ = enter_window.eval("window.codenotchPointer(true)");
        }
        glib::Propagation::Proceed
    });
    gtk_window.connect_destroy(move |_| cancel_leave(&pending));
    Ok(())
}

/// `rects` are physical pixels; GDK input regions use logical coordinates.
pub fn set_hot(app: &AppHandle, rects: Vec<[f64; 4]>) {
    let handle = app.clone();
    let _ = app.run_on_main_thread(move || {
        let Some(window) = handle.get_webview_window("notch") else { return };
        let Ok(gtk_window) = window.gtk_window() else { return };
        let Some(gdk_window) = gtk_window.window() else { return };
        let scale = gtk_window.scale_factor().max(1) as f64;
        let region = gtk::cairo::Region::create();
        for [x, y, width, height] in rects {
            if ![x, y, width, height].iter().all(|n| n.is_finite()) || width <= 0.0 || height <= 0.0 {
                continue;
            }
            let left = (x / scale).floor() as i32;
            let top = (y / scale).floor() as i32;
            let right = ((x + width) / scale).ceil() as i32;
            let bottom = ((y + height) / scale).ceil() as i32;
            let _ = region.union_rectangle(&gtk::cairo::RectangleInt::new(left, top, right - left, bottom - top));
        }
        gdk_window.input_shape_combine_region(&region, 0, 0);
    });
}
