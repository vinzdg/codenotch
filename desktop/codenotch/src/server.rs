//! Local event server: receives codenotch-hook's POST /event?e=<event>&ppid=<pid>
//! with the Claude Code hook's stdin JSON as the body. Lenient parsing: no missing field is an error.

use crate::state::HookEvent;
use crate::AppState;
use std::io::Read;
use tauri::{AppHandle, Manager};

pub fn start(app: AppHandle, port: u16) {
    std::thread::spawn(move || {
        let server = match tiny_http::Server::http(("127.0.0.1", port)) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("[codenotch] failed to bind port {port}: {e} (is another instance running?)");
                return;
            }
        };
        for mut req in server.incoming_requests() {
            let url = req.url().to_string();
            if url.starts_with("/event") {
                // codenotch-hook only ever POSTs. A GET is also what a web page can send with no
                // Origin header at all (an image tag), so nothing but POST is taken (#165).
                if *req.method() != tiny_http::Method::Post {
                    let _ = req.respond(
                        tiny_http::Response::from_string("method not allowed").with_status_code(405),
                    );
                    continue;
                }
                // Cross-Origin / CSRF protection:
                // Reject untrusted browser requests attempting to forge events or poison local state.
                if is_forbidden(&req) {
                    let _ = req.respond(
                        tiny_http::Response::from_string("forbidden").with_status_code(403),
                    );
                    continue;
                }

                let mut body = String::new();
                let _ = req.as_reader().take(256 * 1024).read_to_string(&mut body);

                let ev = parse(&url, &body);
                let state = app.state::<AppState>();
                let changed = {
                    let mut store = state.store.lock().unwrap();
                    store.apply(ev)
                };
                if changed {
                    crate::broadcast(&app);
                }
            }
            let _ = req.respond(tiny_http::Response::from_string("ok"));
        }
    });
}

fn query_param(url: &str, key: &str) -> String {
    let q = url.split_once('?').map(|x| x.1).unwrap_or("");
    for pair in q.split('&') {
        let mut it = pair.splitn(2, '=');
        if it.next() == Some(key) {
            return it.next().unwrap_or("").to_string();
        }
    }
    String::new()
}

fn parse(url: &str, body: &str) -> HookEvent {
    let v: serde_json::Value = serde_json::from_str(body).unwrap_or(serde_json::Value::Null);
    let s = |k: &str| v.get(k).and_then(|x| x.as_str()).unwrap_or("").to_string();
    // tool_input.command (Bash etc.) feeds the "last action" summary
    let tool_cmd = v
        .get("tool_input")
        .and_then(|t| t.get("command"))
        .and_then(|c| c.as_str())
        .unwrap_or("")
        .to_string();
    HookEvent {
        e: query_param(url, "e"),
        session_id: {
            let id = s("session_id");
            if id.is_empty() { "unknown".into() } else { id }
        },
        ppid: query_param(url, "ppid").parse().unwrap_or(0),
        cwd: s("cwd"),
        prompt: s("prompt"),
        message: s("message"),
        tool_name: s("tool_name"),
        tool_cmd,
        model: s("model"),
        src: "hook",
    }
}

/// Browser cross-origin / CSRF guard for incoming HTTP requests.
///
/// Any webpage running in a user's browser (e.g. on evil.com) can issue cross-origin
/// HTTP requests to loopback `http://127.0.0.1:<port>/event`. Browsers attach `Origin`
/// (identifying the calling site) and Fetch Metadata (`Sec-Fetch-Site: cross-site`) to
/// cross-origin requests.
///
/// If an incoming request to `/event` contains an `Origin` header that does not match
/// `127.0.0.1` or `localhost`, or carries `Sec-Fetch-Site: cross-site`, we reject it
/// with a 403 Forbidden response to prevent cross-site request forgery and state poisoning.
///
/// Native callers like `codenotch-hook` communicate directly over loopback TCP without
/// browser `Origin` or `Sec-Fetch-Site` headers, allowing them to succeed seamlessly.
pub(crate) fn is_forbidden(req: &tiny_http::Request) -> bool {
    is_forbidden_headers(req.headers())
}

pub(crate) fn is_forbidden_headers(headers: &[tiny_http::Header]) -> bool {
    let mut origin_count = 0;
    for h in headers {
        if h.field.equiv("Origin") {
            origin_count += 1;
            if origin_count > 1 || !is_allowed_origin(h.value.as_str()) {
                return true;
            }
        }
        if h.field.equiv("Sec-Fetch-Site")
            && h.value.as_str().trim().eq_ignore_ascii_case("cross-site")
        {
            return true;
        }
    }
    false
}

/// Checks if an `Origin` header refers to loopback (`127.0.0.1` or `localhost`).
///
/// Accepts schemes `http://` and `https://` with optional port (e.g. `http://localhost:5173`).
/// Rejects `null`, arbitrary external domains, IP-suffix spoofing (`127.0.0.1.attacker.com`),
/// domain prefixes (`evil-localhost.com`), and userinfo/path/query/fragment tricks.
pub(crate) fn is_allowed_origin(origin: &str) -> bool {
    let s = origin.trim();
    if s.is_empty() || s.eq_ignore_ascii_case("null") {
        return false;
    }

    // Strip http:// or https:// scheme if present.
    let rest = if let Some(stripped) = s
        .strip_prefix("http://")
        .or_else(|| s.strip_prefix("https://"))
    {
        stripped
    } else if s.contains("://") {
        // Disallow non-http(s) schemes (e.g. file://, ftp://, javascript://)
        return false;
    } else {
        s
    };

    // An origin cannot contain userinfo (@), path (/), backslash (\), query (?), or fragment (#).
    if rest.contains(['@', '/', '\\', '?', '#']) {
        return false;
    }

    // Isolate host and optional port.
    let (host, port_opt) = if rest.starts_with('[') {
        // IPv6 bracketed host, e.g. [::1] or [::1]:8080
        if let Some(end) = rest.find(']') {
            let h = &rest[..=end];
            let after = &rest[end + 1..];
            let p = if let Some(stripped) = after.strip_prefix(':') {
                Some(stripped)
            } else if after.is_empty() {
                None
            } else {
                return false;
            };
            (h, p)
        } else {
            return false;
        }
    } else {
        match rest.split_once(':') {
            Some((h, p)) => (h, Some(p)),
            None => (rest, None),
        }
    };

    // If port is specified, it must be a valid 16-bit integer (1..=65535).
    if let Some(port) = port_opt {
        match port.parse::<u16>() {
            Ok(p) if p > 0 => {}
            _ => return false,
        }
    }

    host.eq_ignore_ascii_case("127.0.0.1")
        || host.eq_ignore_ascii_case("localhost")
        || host == "[::1]"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allowed_loopback_origins() {
        assert!(is_allowed_origin("http://127.0.0.1:48666"));
        assert!(is_allowed_origin("http://localhost:5173"));
        assert!(is_allowed_origin("http://127.0.0.1"));
        assert!(is_allowed_origin("http://localhost"));
        assert!(is_allowed_origin("https://127.0.0.1:48666"));
        assert!(is_allowed_origin("https://localhost:3000"));
        assert!(is_allowed_origin("127.0.0.1:48666"));
        assert!(is_allowed_origin("localhost:5173"));
        assert!(is_allowed_origin("127.0.0.1"));
        assert!(is_allowed_origin("localhost"));
        assert!(is_allowed_origin("http://[::1]:8080"));
        assert!(is_allowed_origin("http://[::1]"));
        assert!(is_allowed_origin("http://LOCALHOST:3000"));
    }

    #[test]
    fn rejected_untrusted_origins() {
        assert!(!is_allowed_origin("null"));
        assert!(!is_allowed_origin(""));
        assert!(!is_allowed_origin("   "));
        assert!(!is_allowed_origin("https://evil.com"));
        assert!(!is_allowed_origin("http://attacker.com:8080"));
        assert!(!is_allowed_origin("https://evil-localhost.com"));
        assert!(!is_allowed_origin("https://localhost.attacker.com"));
        assert!(!is_allowed_origin("http://127.0.0.1.attacker.com"));
        assert!(!is_allowed_origin("http://attacker.com:127.0.0.1"));
        assert!(!is_allowed_origin("http://localhost@attacker.com"));
        assert!(!is_allowed_origin("http://attacker.com/localhost"));
        assert!(!is_allowed_origin("http://attacker.com?localhost"));
        assert!(!is_allowed_origin("http://attacker.com#localhost"));
        assert!(!is_allowed_origin("file:///etc/passwd"));
        assert!(!is_allowed_origin("javascript:alert(1)"));
        assert!(!is_allowed_origin("http://localhost:abc"));
        assert!(!is_allowed_origin("http://localhost:70000"));
        assert!(!is_allowed_origin("http://localhost:0"));
        assert!(!is_allowed_origin("http://localhost:"));
    }

    #[test]
    fn hook_request_without_origin_is_allowed() {
        let headers = [
            tiny_http::Header::from_bytes(&b"Host"[..], &b"127.0.0.1:48666"[..]).unwrap(),
            tiny_http::Header::from_bytes(&b"Content-Type"[..], &b"application/json"[..]).unwrap(),
        ];
        assert!(!is_forbidden_headers(&headers));
    }

    #[test]
    fn untrusted_origin_is_forbidden() {
        let headers = [
            tiny_http::Header::from_bytes(&b"Host"[..], &b"127.0.0.1:48666"[..]).unwrap(),
            tiny_http::Header::from_bytes(&b"Origin"[..], &b"https://evil.com"[..]).unwrap(),
        ];
        assert!(is_forbidden_headers(&headers));
    }

    #[test]
    fn multiple_origins_are_forbidden() {
        let headers = [
            tiny_http::Header::from_bytes(&b"Origin"[..], &b"http://localhost:3000"[..]).unwrap(),
            tiny_http::Header::from_bytes(&b"Origin"[..], &b"http://127.0.0.1:48666"[..]).unwrap(),
        ];
        assert!(is_forbidden_headers(&headers));
    }

    #[test]
    fn trusted_origin_is_allowed() {
        let headers = [
            tiny_http::Header::from_bytes(&b"Host"[..], &b"127.0.0.1:48666"[..]).unwrap(),
            tiny_http::Header::from_bytes(&b"Origin"[..], &b"http://localhost:3000"[..]).unwrap(),
        ];
        assert!(!is_forbidden_headers(&headers));

        let headers_ip = [
            tiny_http::Header::from_bytes(&b"Host"[..], &b"127.0.0.1:48666"[..]).unwrap(),
            tiny_http::Header::from_bytes(&b"Origin"[..], &b"http://127.0.0.1:48666"[..]).unwrap(),
        ];
        assert!(!is_forbidden_headers(&headers_ip));
    }

    #[test]
    fn cross_site_sec_fetch_site_is_forbidden() {
        // cross-site without Origin
        let headers = [
            tiny_http::Header::from_bytes(&b"Host"[..], &b"127.0.0.1:48666"[..]).unwrap(),
            tiny_http::Header::from_bytes(&b"Sec-Fetch-Site"[..], &b"cross-site"[..]).unwrap(),
        ];
        assert!(is_forbidden_headers(&headers));

        // cross-site even with localhost Origin
        let headers_with_origin = [
            tiny_http::Header::from_bytes(&b"Origin"[..], &b"http://localhost:3000"[..]).unwrap(),
            tiny_http::Header::from_bytes(&b"Sec-Fetch-Site"[..], &b"cross-site"[..]).unwrap(),
        ];
        assert!(is_forbidden_headers(&headers_with_origin));
    }

    #[test]
    fn same_origin_sec_fetch_site_is_allowed() {
        let headers = [
            tiny_http::Header::from_bytes(&b"Host"[..], &b"127.0.0.1:48666"[..]).unwrap(),
            tiny_http::Header::from_bytes(&b"Sec-Fetch-Site"[..], &b"same-origin"[..]).unwrap(),
        ];
        assert!(!is_forbidden_headers(&headers));
    }

    #[test]
    fn null_origin_is_forbidden() {
        let headers = [tiny_http::Header::from_bytes(&b"Origin"[..], &b"null"[..]).unwrap()];
        assert!(is_forbidden_headers(&headers));
    }

    #[test]
    fn http_server_rejection_integration() {
        let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
        let port = server.server_addr().to_ip().unwrap().port();

        let handle = std::thread::spawn(move || {
            for req in server.incoming_requests().take(4) {
                let url = req.url().to_string();
                if url.starts_with("/event") && is_forbidden(&req) {
                    let _ = req.respond(
                        tiny_http::Response::from_string("forbidden").with_status_code(403),
                    );
                    continue;
                }
                let _ = req.respond(tiny_http::Response::from_string("ok"));
            }
        });

        let url = format!("http://127.0.0.1:{port}/event?e=test");

        // 1. Hook request (no Origin, no Sec-Fetch-Site) -> 200 OK
        let resp = ureq::post(&url).call().unwrap();
        assert_eq!(resp.status(), 200);

        // 2. Untrusted Origin -> 403 Forbidden
        let err = ureq::post(&url)
            .set("Origin", "https://malicious.com")
            .call()
            .unwrap_err();
        if let ureq::Error::Status(code, resp) = err {
            assert_eq!(code, 403);
            assert_eq!(resp.into_string().unwrap(), "forbidden");
        } else {
            panic!("expected status error, got {err:?}");
        }

        // 3. Sec-Fetch-Site: cross-site -> 403 Forbidden
        let err = ureq::post(&url)
            .set("Sec-Fetch-Site", "cross-site")
            .call()
            .unwrap_err();
        if let ureq::Error::Status(code, resp) = err {
            assert_eq!(code, 403);
            assert_eq!(resp.into_string().unwrap(), "forbidden");
        } else {
            panic!("expected status error, got {err:?}");
        }

        // 4. Localhost Origin -> 200 OK
        let resp = ureq::post(&url)
            .set("Origin", "http://localhost:3000")
            .call()
            .unwrap();
        assert_eq!(resp.status(), 200);

        handle.join().unwrap();
    }
}
