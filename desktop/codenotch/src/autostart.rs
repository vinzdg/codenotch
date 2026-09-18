//! Start at sign-in. Windows writes HKCU\...\Run; Linux writes an XDG autostart desktop file.

pub fn is_enabled() -> bool {
    crate::platform::autostart_enabled()
}

pub fn enable() -> Result<String, String> {
    crate::platform::autostart_enable()
}

pub fn disable() -> Result<String, String> {
    crate::platform::autostart_disable()
}
