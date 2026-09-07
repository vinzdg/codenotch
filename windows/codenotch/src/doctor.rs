//! `codenotch.exe doctor` — self-diagnosis: look instead of guessing.
//! Checks the config, port occupancy, watch roots, the newest session file and how its tail parses,
//! and writes to stdout plus %APPDATA%\codenotch\doctor.log.

use std::path::{Path, PathBuf};
use std::time::SystemTime;

fn collect(dir: &Path, depth: usize, out: &mut Vec<(PathBuf, SystemTime)>) {
    if depth > 10 {
        return;
    }
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        let p = e.path();
        if p.is_dir() {
            collect(&p, depth + 1, out);
        } else if crate::watcher::is_session_jsonl(&p) {
            if let Ok(m) = e.metadata() {
                if let Ok(t) = m.modified() {
                    out.push((p, t));
                }
            }
        }
    }
}

fn age_secs(t: SystemTime) -> u64 {
    SystemTime::now()
        .duration_since(t)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

pub fn run() -> String {
    let mut o = String::new();
    o += &format!("== Codenotch doctor v{} ==\n", env!("CARGO_PKG_VERSION"));

    let cfg = crate::config::load();
    o += &format!(
        "config: port={} lang={} ({})\n",
        cfg.port,
        cfg.lang,
        crate::config::config_path().display()
    );

    match std::net::TcpListener::bind(("127.0.0.1", cfg.port)) {
        Ok(_) => o += "port: free — no Codenotch instance is running\n",
        Err(_) => o += "port: in use — an instance is already running (quit it from the tray before starting a new build)\n",
    }

    for root in crate::watcher::roots() {
        if !root.exists() {
            o += &format!("root: {} [missing]\n", root.display());
            continue;
        }
        o += &format!("root: {} exists, scanning for the newest session…\n", root.display());
        let mut files = Vec::new();
        collect(&root, 0, &mut files);
        files.sort_by_key(|(_, m)| std::cmp::Reverse(*m));
        if files.is_empty() {
            o += "  (no session transcripts)\n";
        }
        for (p, m) in files.into_iter().take(5) {
            o += &format!("  updated {}s ago  {}\n", age_secs(m), p.display());
            match crate::watcher::tail_entry(&p) {
                Some(v) => {
                    o += &format!(
                        "    tail parses OK: type={} sessionId={}\n",
                        v.get("type").and_then(|x| x.as_str()).unwrap_or("?"),
                        v.get("sessionId").and_then(|x| x.as_str()).unwrap_or("(missing, the file name will be used)")
                    );
                }
                None => o += "    tail failed to parse (no valid JSON in the last 30 lines — please report this file)\n",
            }
        }
    }

    o += &format!("\nusage sources:\n  {}\n  {}\n", crate::usage::probe_credentials(), crate::codex::probe());
    o += &format!("  {}\n", crate::cursor::probe());
    o += &format!("  {}\n", crate::antigravity::probe());
    o += &format!("\nprovider glyphs:\n{}\n", crate::glyphs::probe());
    o += &format!("\nworking state:\n  {}\n", crate::activity::probe());

    o += "\nwatch.log (the most recent watcher log, if any):\n";
    if let Some(dir) = dirs::config_dir() {
        let p = dir.join("codenotch").join("watch.log");
        match std::fs::read_to_string(&p) {
            Ok(t) if !t.trim().is_empty() => {
                for line in t.lines().rev().take(20).collect::<Vec<_>>().into_iter().rev() {
                    o += &format!("  {}\n", line);
                }
            }
            _ => o += "  (empty — the app has not run yet, which is normal on first use, or an older build without the watcher)\n",
        }
    }
    o
}
