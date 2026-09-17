//! Open a folder or URL with the host's usual handler. Windows uses explorer/cmd so the
//! GUI-subsystem process does not flash a console; Linux uses xdg-open.

use std::path::Path;
use std::process::Command;

#[cfg(windows)]
fn hide(cmd: &mut Command) {
    use std::os::windows::process::CommandExt;
    cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
}

#[cfg(not(windows))]
fn hide(_cmd: &mut Command) {}

pub fn folder(path: &Path) {
    let mut cmd = if cfg!(windows) {
        let mut c = Command::new("explorer");
        c.arg(path.as_os_str());
        c
    } else {
        let mut c = Command::new("xdg-open");
        c.arg(path.as_os_str());
        c
    };
    hide(&mut cmd);
    let _ = cmd.spawn();
}

pub fn url(url: &str) {
    let mut cmd = if cfg!(windows) {
        let mut c = Command::new("cmd");
        c.args(["/C", "start", "", url]);
        c
    } else {
        let mut c = Command::new("xdg-open");
        c.arg(url);
        c
    };
    hide(&mut cmd);
    let _ = cmd.spawn();
}
