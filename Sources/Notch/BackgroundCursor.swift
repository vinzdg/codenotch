import AppKit

/// **Lets the notch set the cursor while Codenotch is not the active app** —
/// which, the notch being a non-activating panel, is nearly always.
///
/// The window server only takes cursor changes from the frontmost app; ours
/// were overridden by it the moment they were made, so the hand never closed
/// on a carried notch. `SetsCursorInBackground` is the window server's own
/// switch for this, the one menu-bar utilities use. Looked up at run time: if
/// a later macOS drops it, this does nothing rather than failing to launch.
enum BackgroundCursor {
    private typealias DefaultConnection = @convention(c) () -> Int32
    private typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    private static var enabled = false

    static func enable() {
        guard !enabled else { return }
        enabled = true
        guard let handle = dlopen(nil, RTLD_NOW),
              let connection = dlsym(handle, "_CGSDefaultConnection"),
              let set = dlsym(handle, "CGSSetConnectionProperty")
        else { return }
        let cid = unsafeBitCast(connection, to: DefaultConnection.self)()
        _ = unsafeBitCast(set, to: SetProperty.self)(
            cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}
