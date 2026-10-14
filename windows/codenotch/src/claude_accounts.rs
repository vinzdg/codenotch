//! Named Claude profiles. Credentials stay in the official CLI's own folders.
use crate::{config::{ClaudeProfileConfig, Config}, AppState};
use serde::Serialize;
use std::path::{Path, PathBuf};
use tauri::{AppHandle, Emitter, Manager};

#[derive(Clone)]
pub struct Profile {
    pub id: String,
    pub name: String,
    pub dir: PathBuf,
    pub enabled: bool,
}

fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

fn directory(home: &Path, id: &str) -> Option<PathBuf> {
    if id == "default" { Some(home.join(".claude")) }
    else if valid_id(id) { Some(home.join(format!(".claude-{id}"))) }
    else { None }
}

pub fn profiles_at(home: &Path, cfg: &Config) -> Vec<Profile> {
    let mut ids = vec!["default".to_string()];
    if let Ok(entries) = std::fs::read_dir(home) {
        let mut found: Vec<String> = entries.flatten().filter_map(|e| {
            let name = e.file_name().to_string_lossy().to_string();
            let id = name.strip_prefix(".claude-")?;
            if id == "default" || !valid_id(id) || !e.path().is_dir() || !has_credential(&e.path()) { return None; }
            Some(id.to_string())
        }).collect();
        found.sort();
        ids.extend(found);
    }
    for p in &cfg.claude_profiles {
        if directory(home, &p.id).is_some() && !ids.contains(&p.id) { ids.push(p.id.clone()); }
    }
    ids.into_iter().filter_map(|id| {
        let dir = directory(home, &id)?;
        let saved = cfg.claude_profiles.iter().find(|p| p.id == id);
        let name = saved.map(|p| p.name.clone()).unwrap_or_else(|| if id == "default" { "Claude".into() } else { id.clone() });
        Some(Profile { id, dir, name, enabled: saved.map(|p| p.enabled).unwrap_or(true) })
    }).collect()
}

pub fn profiles(cfg: &Config) -> Vec<Profile> {
    dirs::home_dir().map(|home| profiles_at(&home, cfg)).unwrap_or_default()
}

fn has_credential(dir: &Path) -> bool {
    [".credentials.json", "credentials.json"].iter().any(|n| dir.join(n).is_file())
}

#[derive(Serialize)]
pub struct AccountView {
    id: String,
    name: String,
    enabled: bool,
    connected: bool,
    status: String,
    fetched_at: u64,
    backoff_until: u64,
    note: String,
    path: String,
}

#[tauri::command]
pub fn get_claude_accounts(app: AppHandle) -> Vec<AccountView> {
    let st = app.state::<AppState>();
    let profiles = profiles(&st.cfg.lock().unwrap());
    let usage = st.usage.lock().unwrap();
    profiles.into_iter().map(|p| {
        let snap = usage.accounts.iter().find(|s| s.id == p.id);
        AccountView { connected: has_credential(&p.dir), status: snap.map(|s| s.status.clone()).unwrap_or_else(|| "needsAuth".into()),
            fetched_at: snap.map(|s| s.fetched_at).unwrap_or(0), path: p.dir.to_string_lossy().to_string(),
            backoff_until: snap.map(|s| s.backoff_until).unwrap_or(0), note: snap.map(|s| s.note.clone()).unwrap_or_default(),
            id: p.id, name: p.name, enabled: p.enabled }
    }).collect()
}

fn checked_name(name: &str) -> Result<String, String> {
    let name = name.trim();
    if name.is_empty() || name.chars().count() > 40 || name.chars().any(char::is_control) {
        return Err("Use a name between 1 and 40 characters".into());
    }
    Ok(name.to_string())
}

fn slug(name: &str) -> String {
    let text: String = name.chars().map(|c| if c.is_ascii_alphanumeric() { c.to_ascii_lowercase() } else { '-' }).collect();
    let text = text.split('-').filter(|s| !s.is_empty()).collect::<Vec<_>>().join("-");
    if text.is_empty() { "account".into() } else { text }
}

#[tauri::command]
pub fn add_claude_account(app: AppHandle, name: String) -> Result<String, String> {
    let name = checked_name(&name)?;
    let home = dirs::home_dir().ok_or("Home directory unavailable")?;
    let st = app.state::<AppState>();
    let mut cfg = st.cfg.lock().unwrap();
    let mut next = cfg.clone();
    let base = slug(&name);
    let mut id = base.clone();
    let mut number = 2;
    while id == "default" || next.claude_profiles.iter().any(|p| p.id == id) || directory(&home, &id).ok_or("Invalid account name")?.exists() {
        id = format!("{base}-{number}"); number += 1;
    }
    let dir = directory(&home, &id).ok_or("Invalid account name")?;
    std::fs::create_dir(&dir).map_err(|_| "Unable to create the account folder")?;
    next.claude_profiles.push(ClaudeProfileConfig { id: id.clone(), name, enabled: true });
    if let Err(e) = crate::config::save_checked(&next) {
        let _ = std::fs::remove_dir(&dir); // only the newly-created, still-empty directory
        return Err(e);
    }
    *cfg = next;
    drop(cfg);
    changed(&app);
    Ok(id)
}

#[tauri::command]
pub fn update_claude_account(app: AppHandle, id: String, name: String, enabled: bool) -> Result<(), String> {
    let name = checked_name(&name)?;
    let st = app.state::<AppState>();
    let mut cfg = st.cfg.lock().unwrap();
    if !profiles(&cfg).iter().any(|p| p.id == id) { return Err("Unknown Claude account".into()); }
    let mut next = cfg.clone();
    if let Some(p) = next.claude_profiles.iter_mut().find(|p| p.id == id) { p.name = name; p.enabled = enabled; }
    else { next.claude_profiles.push(ClaudeProfileConfig { id, name, enabled }); }
    crate::config::save_checked(&next)?;
    *cfg = next;
    drop(cfg);
    changed(&app);
    Ok(())
}

#[tauri::command]
pub fn connect_claude_account(app: AppHandle, id: String) -> Result<(), String> {
    let cfg = app.state::<AppState>().cfg.lock().unwrap().clone();
    let p = profiles(&cfg).into_iter().find(|p| p.id == id).ok_or("Unknown Claude account")?;
    crate::claude_auth::start_profile_login(&p.dir, &p.id)
}

fn changed(app: &AppHandle) {
    crate::usage::request_refresh();
    let _ = app.emit("claude_accounts_changed", ());
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn profile_paths_cannot_escape_home() {
        let home = Path::new("/fixture");
        for id in ["../secret", "/tmp/x", "work/other", "work\\other", "", "."] { assert!(directory(home, id).is_none()); }
        assert_eq!(directory(home, "work-2").unwrap(), home.join(".claude-work-2"));
    }
    #[test]
    fn registered_accounts_remain_visible_before_first_login() {
        let mut cfg = Config::default();
        cfg.claude_profiles.push(ClaudeProfileConfig { id:"work".into(), name:"Trabalho".into(), enabled:false });
        let items = profiles_at(Path::new("/codenotch-nonexistent-fixture"), &cfg);
        assert_eq!(items.len(), 2);
        assert_eq!(items[1].name, "Trabalho");
        assert!(!items[1].enabled);
    }
    #[test]
    fn names_are_labels_and_never_shell_source() {
        assert!(checked_name(" ").is_err());
        assert!(checked_name("bad\nname").is_err());
        assert_eq!(slug("Client A $(run)"), "client-a-run");
        assert_eq!(slug("日本"), "account");
    }
}
