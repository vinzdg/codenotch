//! Claude profiles. Credentials stay in the official CLI's own folders.
use crate::{config::{ClaudeProfileConfig, Config}, AppState};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, SystemTime};
use tauri::{AppHandle, Emitter, Manager};

#[derive(Clone)]
pub struct Profile {
    pub id: String,
    pub name: String,
    pub dir: PathBuf,
    pub enabled: bool,
    pub address: Option<String>,
}

fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

fn directory(home: &Path, id: &str) -> Option<PathBuf> {
    if id == "default" { Some(home.join(".claude")) }
    else if valid_id(id) { Some(home.join(format!(".claude-{id}"))) }
    else { None }
}

/// Claude Code's own record of the account. The default profile keeps it beside its folder, at
/// `~/.claude.json`; a `CLAUDE_CONFIG_DIR` profile keeps it inside. The Mac's `accountFileURL`.
fn account_file(home: &Path, id: &str, dir: &Path) -> PathBuf {
    if id == "default" { home.join(".claude.json") } else { dir.join(".claude.json") }
}

#[derive(Deserialize)]
struct AccountFile {
    #[serde(rename = "oauthAccount")]
    oauth_account: Option<OauthAccount>,
}

#[derive(Deserialize)]
struct OauthAccount {
    #[serde(rename = "emailAddress")]
    email_address: Option<String>,
}

type Stamp = (Option<SystemTime>, u64);

/// The file also holds Claude Code's project history and is rewritten often, while the taskbar and
/// the poller ask for profiles every few hundred milliseconds: parse it only when it changes.
static ADDRESSES: Mutex<BTreeMap<PathBuf, (Stamp, Option<String>)>> = Mutex::new(BTreeMap::new());

fn signed_in_address(path: &Path) -> Option<String> {
    let meta = std::fs::metadata(path).ok()?;
    let stamp = (meta.modified().ok(), meta.len());
    let mut cache = ADDRESSES.lock().unwrap_or_else(|e| e.into_inner());
    if let Some((seen, address)) = cache.get(path) {
        if *seen == stamp { return address.clone(); }
    }
    let address = std::fs::read(path).ok()
        .and_then(|bytes| serde_json::from_slice::<AccountFile>(&bytes).ok())
        .and_then(|file| file.oauth_account?.email_address)
        .filter(|address| !address.is_empty());
    cache.insert(path.to_path_buf(), (stamp, address.clone()));
    address
}

/// `Gmail` for a gmail.com address, `Acme` for someone@acme.co.uk: the domain, because that is
/// what tells a personal login from a work one. The Mac's `ClaudeProfile.accountLabel`.
fn account_label(address: &str) -> Option<String> {
    let (_, domain) = address.rsplit_once('@')?;
    let first = domain.split('.').next()?;
    if !first.chars().any(char::is_alphabetic) { return None; }
    let mut chars = first.chars();
    let head = chars.next()?;
    Some(head.to_uppercase().chain(chars).collect())
}

/// The Mac's `ClaudeProfile.displayName`: the account's own name once it has signed in, the folder
/// before that.
fn display_name(id: &str, address: Option<&str>) -> String {
    match address.and_then(account_label) {
        Some(label) => format!("Claude {label}"),
        None if id == "default" => "Claude".into(),
        None => format!("Claude ({id})"),
    }
}

/// The Mac's `ClaudeProfile.displayNames`: a lone account is just Claude, and only accounts whose
/// names would collide pay for the whole address.
fn display_names(accounts: &[(String, Option<String>)]) -> Vec<String> {
    if accounts.len() == 1 { return vec!["Claude".into()]; }
    let names: Vec<String> = accounts.iter().map(|(id, address)| display_name(id, address.as_deref())).collect();
    names.iter().zip(accounts).map(|(name, (_, address))| {
        match address {
            Some(address) if names.iter().filter(|other| *other == name).count() > 1 => format!("Claude {address}"),
            _ => name.clone(),
        }
    }).collect()
}

/// `~/.claude` and every `~/.claude-<slug>` Claude Code has signed in to, as the Mac's
/// `ClaudeProfile.discover`: no credential, no account, so a folder whose sign-in never finished
/// is not one.
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
    let accounts: Vec<(String, PathBuf, Option<String>)> = ids.into_iter().filter_map(|id| {
        let dir = directory(home, &id)?;
        let address = signed_in_address(&account_file(home, &id, &dir));
        Some((id, dir, address))
    }).collect();
    let names = display_names(&accounts.iter().map(|(id, _, address)| (id.clone(), address.clone())).collect::<Vec<_>>());
    accounts.into_iter().zip(names).map(|((id, dir, address), name)| {
        let enabled = cfg.claude_profiles.iter().find(|p| p.id == id).map(|p| p.enabled).unwrap_or(true);
        Profile { id, name, dir, enabled, address }
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
    address: Option<String>,
    enabled: bool,
    connected: bool,
    status: String,
    fetched_at: u64,
    backoff_until: u64,
    note: String,
}

#[tauri::command]
pub fn get_claude_accounts(app: AppHandle) -> Vec<AccountView> {
    let st = app.state::<AppState>();
    let profiles = profiles(&st.cfg.lock().unwrap());
    let usage = st.usage.lock().unwrap();
    let mut views: Vec<AccountView> = profiles.into_iter().map(|p| {
        let snap = usage.accounts.iter().find(|s| s.id == p.id);
        AccountView { connected: has_credential(&p.dir), status: snap.map(|s| s.status.clone()).unwrap_or_else(|| "needsAuth".into()),
            fetched_at: snap.map(|s| s.fetched_at).unwrap_or(0),
            backoff_until: snap.map(|s| s.backoff_until).unwrap_or(0), note: snap.map(|s| s.note.clone()).unwrap_or_default(),
            id: p.id, name: p.name, address: p.address, enabled: p.enabled }
    }).collect();
    // An account being added has no credential yet, so it is listed only while its sign-in runs.
    let auth = crate::claude_auth::state();
    if let Some(id) = auth.profile_id.filter(|id| auth.busy && !views.iter().any(|v| &v.id == id)) {
        views.push(AccountView { name: display_name(&id, None), id, address: None, enabled: true, connected: false,
            status: "needsAuth".into(), fetched_at: 0, backoff_until: 0, note: String::new() });
    }
    views
}

/// A new account's folder, numbered from 2 so it reads as the second account until its sign-in
/// gives it a name.
fn next_id(home: &Path, cfg: &Config) -> String {
    (2u32..).map(|n| n.to_string())
        .find(|id| !cfg.claude_profiles.iter().any(|p| &p.id == id) && directory(home, id).is_some_and(|dir| !dir.exists()))
        .unwrap_or_default()
}

/// Long enough to sign in through a browser, short enough that an abandoned account goes away.
const NEW_ACCOUNT_SIGN_IN: Duration = Duration::from_secs(5 * 60);

/// Makes the next account's folder and opens Claude Code's sign-in in it. A sign-in that does not
/// finish, in time or at all, takes the folder with it.
#[tauri::command]
pub fn add_claude_account(app: AppHandle) -> Result<String, String> {
    let home = dirs::home_dir().ok_or("Home directory unavailable")?;
    let id = next_id(&home, &app.state::<AppState>().cfg.lock().unwrap());
    let dir = directory(&home, &id).ok_or("Unable to create the account folder")?;
    std::fs::create_dir(&dir).map_err(|_| "Unable to create the account folder")?;
    let handle = app.clone();
    let folder = dir.clone();
    let started = crate::claude_auth::start_profile_login_within(&dir, &id, NEW_ACCOUNT_SIGN_IN, move |_| {
        if !has_credential(&folder) { let _ = std::fs::remove_dir_all(&folder); }
        changed(&handle);
    });
    if let Err(e) = started {
        let _ = std::fs::remove_dir(&dir); // only the newly-created, still-empty directory
        return Err(e);
    }
    changed(&app);
    Ok(id)
}

#[tauri::command]
pub fn set_claude_account_enabled(app: AppHandle, id: String, enabled: bool) -> Result<(), String> {
    let st = app.state::<AppState>();
    let mut cfg = st.cfg.lock().unwrap();
    let profile = profiles(&cfg).into_iter().find(|p| p.id == id).ok_or("Unknown Claude account")?;
    let mut next = cfg.clone();
    if let Some(p) = next.claude_profiles.iter_mut().find(|p| p.id == id) { p.enabled = enabled; }
    else { next.claude_profiles.push(ClaudeProfileConfig { id, name: profile.name, enabled }); }
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
    fn only_folders_claude_code_has_signed_in_to_are_accounts() {
        let home = std::env::temp_dir().join(format!("codenotch-profiles-{}", std::process::id()));
        for (folder, signed_in) in [(".claude-work", true), (".claude-2", false), (".claude-mem", false)] {
            std::fs::create_dir_all(home.join(folder)).unwrap();
            if signed_in { std::fs::write(home.join(folder).join(".credentials.json"), "{}").unwrap(); }
        }
        let mut cfg = Config::default();
        cfg.claude_profiles.push(ClaudeProfileConfig { id:"2".into(), name:String::new(), enabled:true });
        cfg.claude_profiles.push(ClaudeProfileConfig { id:"work".into(), name:String::new(), enabled:false });
        let items = profiles_at(&home, &cfg);
        let _ = std::fs::remove_dir_all(&home);
        assert_eq!(items.iter().map(|p| p.id.as_str()).collect::<Vec<_>>(), ["default", "work"]);
        assert_eq!((items[0].name.as_str(), items[1].name.as_str()), ("Claude", "Claude (work)"));
        assert!(!items[1].enabled);
        assert_eq!(profiles_at(Path::new("/codenotch-nonexistent-fixture"), &cfg)[0].name, "Claude");
    }
    #[test]
    fn the_default_account_file_sits_beside_its_folder_and_the_others_inside() {
        let home = Path::new("/fixture");
        assert_eq!(account_file(home, "default", &home.join(".claude")), home.join(".claude.json"));
        assert_eq!(account_file(home, "work", &home.join(".claude-work")), home.join(".claude-work").join(".claude.json"));
    }
    #[test]
    fn names_come_from_the_signed_in_domain_as_on_the_mac() {
        assert_eq!(account_label("me@gmail.com").as_deref(), Some("Gmail"));
        assert_eq!(account_label("me@acme.co.uk").as_deref(), Some("Acme"));
        for unusable in ["no-at-sign", "me@", "me@.com", "me@1.com", "me@-.com"] { assert_eq!(account_label(unusable), None, "{unusable}"); }
        let named = |accounts: &[(&str, Option<&str>)]| display_names(&accounts.iter()
            .map(|(id, address)| (id.to_string(), address.map(Into::into))).collect::<Vec<_>>());
        assert_eq!(named(&[("default", Some("me@gmail.com"))]), ["Claude"]);
        assert_eq!(named(&[("default", Some("me@gmail.com")), ("work", Some("me@acme.com"))]), ["Claude Gmail", "Claude Acme"]);
        assert_eq!(named(&[("default", None), ("2", None)]), ["Claude", "Claude (2)"]);
        assert_eq!(named(&[("default", Some("a@gmail.com")), ("2", Some("b@gmail.com")), ("3", None)]),
            ["Claude a@gmail.com", "Claude b@gmail.com", "Claude (3)"]);
    }
    #[test]
    fn a_new_account_takes_the_next_free_number() {
        let mut cfg = Config::default();
        let home = Path::new("/codenotch-nonexistent-fixture");
        assert_eq!(next_id(home, &cfg), "2");
        cfg.claude_profiles.push(ClaudeProfileConfig { id:"2".into(), name:String::new(), enabled:true });
        assert_eq!(next_id(home, &cfg), "3");
    }
}
