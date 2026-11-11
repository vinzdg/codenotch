//! Per-account taskbar activity and refresh. A Claude transcript under its own
//! config directory identifies its account; desktop network traffic and a hook's
//! working directory do not, so neither is assigned to an arbitrary account.
use crate::{activity::Activity, state::{Session, ST_ATTENTION, ST_RUNNING}, AppState};
use std::{collections::HashMap, path::{Component, Path}, sync::{Mutex, OnceLock}, time::{Instant, SystemTime, UNIX_EPOCH}};
use tauri::{AppHandle, Manager};

const MAX_OWNERS: usize = 400;

#[derive(Default)]
struct SessionOwners {
    // None means the same session id was observed in two profiles: ownership is ambiguous.
    accounts: HashMap<String, (Option<String>, Instant)>,
}

impl SessionOwners {
    fn record(&mut self, session: &str, account: &str) {
        if !self.accounts.contains_key(session) && self.accounts.len() >= MAX_OWNERS {
            if let Some(oldest) = self.accounts.iter().min_by_key(|(_, (_, at))| *at).map(|(id, _)| id.clone()) {
                self.accounts.remove(&oldest);
            }
        }
        self.accounts.entry(session.to_string()).and_modify(|(owner, at)| {
            if owner.as_deref() != Some(account) { *owner = None; }
            *at = Instant::now();
        }).or_insert_with(|| (Some(account.to_string()), Instant::now()));
    }

    fn owns(&self, session: &str, account: &str) -> bool {
        self.accounts.get(session).and_then(|(owner, _)| owner.as_deref()) == Some(account)
    }
}

fn owners() -> &'static Mutex<SessionOwners> {
    static OWNERS: OnceLock<Mutex<SessionOwners>> = OnceLock::new();
    OWNERS.get_or_init(|| Mutex::new(SessionOwners::default()))
}

/// Require the actual home/config/projects layout, not just a .claude-like
/// directory somewhere inside a Cowork mirror or another project's path.
fn profile_from_path(path: &Path, home: &Path) -> Option<String> {
    let mut relative = path.strip_prefix(home).ok()?.components();
    let Component::Normal(config) = relative.next()? else { return None; };
    let Component::Normal(projects) = relative.next()? else { return None; };
    if projects != "projects" { return None; }
    let config = config.to_str()?;
    if config == ".claude" { return Some("default".into()); }
    let id = config.strip_prefix(".claude-")?;
    if id == "default" || id.is_empty() || id.len() > 64 || !id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-') {
        return None;
    }
    Some(id.to_string())
}

/// Called by the watcher after reading a session id from a transcript. No
/// credential is read and no filesystem walk is added to the activity tick.
pub fn record_session_profile(path: &Path, session_id: &str) {
    if session_id.is_empty() || session_id.len() > 256 { return; }
    let Some(home) = dirs::home_dir() else { return; };
    let Some(account) = profile_from_path(path, &home) else { return; };
    owners().lock().unwrap_or_else(|e| e.into_inner()).record(session_id, &account);
}

fn claude_state(sessions: &[Session], account: &str, owners: &SessionOwners) -> &'static str {
    let mut busy = false;
    for session in sessions.iter().filter(|s| owners.owns(&s.id, account)) {
        if session.state == ST_ATTENTION { return "waiting"; }
        if session.state == ST_RUNNING { busy = true; }
    }
    if busy { "busy" } else { "idle" }
}

fn provider_state(activities: &[Activity], provider: &str) -> &'static str {
    let mut busy = false;
    for activity in activities.iter().filter(|a| a.provider == provider) {
        if activity.state == "waiting" { return "waiting"; }
        if activity.state == "busy" { busy = true; }
    }
    if busy { "busy" } else { "idle" }
}

pub fn work_state(app: &AppHandle, provider: &str, account_id: Option<&str>) -> String {
    let st = app.state::<AppState>();
    if provider == "claude" {
        let sessions = st.store.lock().unwrap().snapshot("en", "en", false, false).sessions;
        let owners = owners().lock().unwrap_or_else(|e| e.into_inner());
        claude_state(&sessions, account_id.unwrap_or("default"), &owners).into()
    } else {
        let activities = st.activity.lock().unwrap();
        provider_state(&activities, provider).into()
    }
}

fn refresh_allowed(auth_busy: bool, backoff_until: u64, now: u64) -> bool {
    !auth_busy && backoff_until <= now
}

/// True means a refresh was queued. False means the account is signing in or
/// waiting out its own rate limit or minimum interval; clicking never clears these protections.
#[tauri::command]
pub fn refresh_taskbar_item(app: AppHandle, id: String) -> Result<bool, String> {
    if let Some(account_id) = id.strip_prefix("claude@") {
        let st = app.state::<AppState>();
        let cfg = st.cfg.lock().unwrap().clone();
        if !crate::claude_accounts::profiles(&cfg).iter().any(|p| p.id == account_id && p.enabled) {
            return Err("Unknown or paused Claude account".into());
        }
        let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0);
        let (backoff_until, due) = {
            let usage = st.usage.lock().unwrap();
            usage.accounts.iter().find(|a| a.id == account_id)
                .map(|a| (a.backoff_until, crate::usage::should_fetch(a.last_attempt_at.max(a.fetched_at), now, &a.windows)))
                .unwrap_or_else(|| if account_id == "default" && usage.accounts.is_empty() {
                    (usage.backoff_until, crate::usage::should_fetch(usage.fetched_at, now, &usage.windows))
                } else { (0, true) })
        };
        if !due || !refresh_allowed(crate::claude_auth::state().busy, backoff_until, now) { return Ok(false); }
        crate::usage::request_account_refresh(account_id);
        return Ok(true);
    }
    if id == "claude" || !crate::TRAY_PROVIDER_IDS.contains(&id.as_str()) {
        return Err("Unknown taskbar account".into());
    }
    Ok(crate::refresh_provider(&app, &id))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::{HookEvent, Store};

    fn sessions(events: &[(&str, &str)]) -> Vec<Session> {
        let mut store = Store::default();
        for (id, state) in events {
            store.apply(HookEvent { e: state.to_string(), session_id: id.to_string(), ppid: 0, cwd: String::new(),
                prompt: String::new(), message: String::new(), tool_name: String::new(), tool_cmd: String::new(),
                model: String::new(), src: "hook" });
        }
        store.snapshot("en", "en", false, false).sessions
    }

    #[test]
    fn activity_is_owned_by_the_transcript_profile_and_unknown_sessions_stay_unassigned() {
        let sessions = sessions(&[("personal", "running"), ("work", "attention"), ("unknown", "attention")]);
        let mut owners = SessionOwners::default();
        owners.record("personal", "default");
        owners.record("work", "work");
        assert_eq!(claude_state(&sessions, "default", &owners), "busy");
        assert_eq!(claude_state(&sessions, "work", &owners), "waiting");
        assert_eq!(claude_state(&sessions, "other", &owners), "idle");
        assert_eq!(claude_state(&sessions, "default", &SessionOwners::default()), "idle");
    }

    #[test]
    fn mirrored_or_conflicting_session_ids_do_not_animate_the_wrong_account() {
        let home = Path::new("/fixture/user");
        assert_eq!(profile_from_path(&home.join(".claude-work/projects/p/session.jsonl"), home).as_deref(), Some("work"));
        assert_eq!(profile_from_path(&home.join(".claude/projects/p/session.jsonl"), home).as_deref(), Some("default"));
        assert_eq!(profile_from_path(&home.join("AppData/Claude/local-agent-mode-sessions/s/.claude/projects/p/session.jsonl"), home), None);
        assert_eq!(profile_from_path(&home.join(".claude-work/other/session.jsonl"), home), None);
        assert_eq!(profile_from_path(&home.join(".claude-default/projects/p/session.jsonl"), home), None);
        let mut owners = SessionOwners::default();
        owners.record("same-id", "default");
        owners.record("same-id", "work");
        owners.record("same-id", "default");
        let sessions = sessions(&[("same-id", "running")]);
        assert_eq!(claude_state(&sessions, "default", &owners), "idle");
        assert_eq!(claude_state(&sessions, "work", &owners), "idle");
    }

    #[test]
    fn provider_activity_and_account_backoff_remain_isolated() {
        let activity = |provider: &str, state: &str| Activity { provider: provider.into(), state: state.into(),
            name: String::new(), detail: String::new(), since: 0 };
        let activities = vec![activity("claude", "waiting"), activity("codex", "busy"), activity("cursor", "waiting")];
        assert_eq!(provider_state(&activities, "codex"), "busy");
        assert_eq!(provider_state(&activities, "cursor"), "waiting");
        assert_eq!(provider_state(&activities, "gemini"), "idle");
        assert!(!refresh_allowed(false, 200, 100));
        assert!(refresh_allowed(false, 0, 100), "another account's deadline cannot block this account");
        assert!(!refresh_allowed(true, 0, 100), "authentication still owns the credential");
    }
}
