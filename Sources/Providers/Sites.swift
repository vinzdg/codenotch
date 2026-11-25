import Foundation

/// The site-specific halves of `WebSessionProvider`.
enum Sites {
    static let perplexity = WebSessionProvider.Site(
        id: "perplexity",
        displayName: "Perplexity",
        glyph: .third,
        origin: URL(string: "https://www.perplexity.ai/")!,
        script: """
        const response = await fetch('/rest/rate-limit/all', {
            credentials: 'include',
            headers: { 'Accept': 'application/json' }
        });
        const text = await response.text();
        // `sources.source_to_limit` is a long tail of connector quotas with
        // nothing to do with model usage; drop it so the rest stays legible.
        let trimmed = text;
        try { const p = JSON.parse(text); delete p.sources; trimmed = JSON.stringify(p); } catch (_) {}
        return JSON.stringify({ status: response.status, body: trimmed });
        """,
        associatedHosts: [],
        parse: PerplexityUsage.windows(fromJSON:)
    )

    static let deepSeek = WebSessionProvider.Site(
        id: "deepseek",
        displayName: "DeepSeek",
        glyph: .deepseek,
        origin: URL(string: "https://platform.deepseek.com/")!,
        script: #"""
        const readToken = () => {
            const extract = (value) => {
                if (typeof value === 'string' && value.trim()) return value.trim();
                if (!value || typeof value !== 'object') return null;
                for (const key of ['value', 'token', 'access_token', 'accessToken']) {
                    const candidate = extract(value[key]);
                    if (candidate) return candidate;
                }
                return null;
            };
            try {
                const raw = localStorage.getItem('userToken');
                if (!raw) return null;
                return extract(JSON.parse(raw)) || raw.trim() || null;
            } catch (_) {
                const raw = localStorage.getItem('userToken');
                return raw && raw.trim() ? raw.trim() : null;
            }
        };
        const token = readToken();
        const headers = { 'Accept': 'application/json', 'x-client-platform': 'web' };
        if (token) headers.Authorization = token.startsWith('Bearer ') ? token : 'Bearer ' + token;
        const now = new Date();
        const today = new Date(now); today.setHours(0, 0, 0, 0);
        const start = new Date(today); start.setDate(start.getDate() - 29);
        const end = new Date(today); end.setDate(end.getDate() + 1);
        const startSeconds = Math.floor(start.getTime() / 1000);
        const endSeconds = Math.floor(end.getTime() / 1000);
        const timeZoneSeconds = -now.getTimezoneOffset() * 60;
        const query = 'start=' + startSeconds + '&end=' + endSeconds + '&tz=' + timeZoneSeconds;
        const get = async (path) => {
            const response = await fetch(path, { credentials: 'include', headers });
            return { status: response.status, body: await response.text() };
        };
        const [summary, amount, cost] = await Promise.all([
            get('/api/v0/users/get_user_summary'),
            get('/api/v0/usage/by_api_key/amount?' + query),
            get('/api/v0/usage/by_api_key/cost?' + query)
        ]);
        const failed = [summary, amount, cost].find(item => item.status < 200 || item.status >= 300);
        return JSON.stringify({
            status: failed ? failed.status : 200,
            body: JSON.stringify({
                summary: summary.body, amount: amount.body, cost: cost.body,
                start: startSeconds, end: endSeconds, time_zone_seconds: timeZoneSeconds
            })
        });
        """#,
        fidelity: .derived,
        authProbeScript: #"""
        const extract = (value) => {
            if (typeof value === 'string' && value.trim()) return value.trim();
            if (!value || typeof value !== 'object') return null;
            for (const key of ['value', 'token', 'access_token', 'accessToken']) {
                const candidate = extract(value[key]);
                if (candidate) return candidate;
            }
            return null;
        };
        try {
            const raw = localStorage.getItem('userToken');
            if (!raw) return false;
            const token = extract(JSON.parse(raw)) || raw.trim();
            if (!token) return false;
            const response = await fetch('/api/v0/users/get_user_summary', {
                credentials: 'include', headers: {
                    'Accept': 'application/json',
                    'x-client-platform': 'web',
                    'Authorization': token.startsWith('Bearer ') ? token : 'Bearer ' + token
                }
            });
            if (response.status < 200 || response.status >= 300) {
                return JSON.stringify({ authenticated: false });
            }
            // An expired token still answers HTTP 200, with 40002 or 40003.
            const envelope = await response.json().catch(() => null);
            if (envelope && [40002, 40003].includes(envelope.code)) {
                return JSON.stringify({ authenticated: false });
            }
            const bytes = new TextEncoder().encode(token);
            const digest = await crypto.subtle.digest('SHA-256', bytes);
            const fingerprint = Array.from(new Uint8Array(digest))
                .map(byte => byte.toString(16).padStart(2, '0')).join('');
            return JSON.stringify({ authenticated: true, fingerprint });
        } catch (_) { return JSON.stringify({ authenticated: false }); }
        """#,
        associatedHosts: [],
        detailParse: DeepSeekUsage.detail(fromJSON:),
        parse: { json in
            let payload = try DeepSeekUsage.payload(fromJSON: json)
            let reading = try DeepSeekUsage.reading(fromJSON: payload.summary)
            let displayMode = Preferences.storedDeepSeekDisplayMode()
            return DeepSeekUsage.windows(from: reading, displayMode: displayMode)
        }
    )

    /// QianwenAI publishes model-call APIs but no usage or quota API, so the
    /// Token Plan is only readable through the console's own RPC gateway, and
    /// the session that authorizes it is the cookie on
    /// `platform-home.qianwenai.com`. `sec_token` is fetched
    /// fresh on every call rather than read from the console's
    /// `window.__QWEN_CONSOLE_SHARED_SEC_TOKEN__` cache — that call is the
    /// session liveness check anyway, and a token that had silently aged out
    /// would leave the usage call failing for a reason the app could not name.
    static let qianwen = WebSessionProvider.Site(
        id: "qianwenai",
        displayName: "QianwenAI",
        glyph: .qianwenAI,
        origin: URL(string: "https://platform.qianwenai.com/")!,
        script: #"""
        const infoResponse = await fetch('https://platform-home.qianwenai.com/tool/user/info.json', {
            credentials: 'include',
            headers: { 'Accept': 'application/json' }
        });
        let secToken = null;
        try {
            const info = JSON.parse(await infoResponse.text());
            const payload = info && info.payload ? info.payload : info;
            if (payload && String(payload.code) === '200' && payload.data && payload.data.secToken) {
                secToken = payload.data.secToken;
            }
        } catch (_) {}
        // Signed out is HTTP 200 on this platform, and the *body* is what says
        // so — `{"code":"ConsoleNeedLogin"}`. Only the envelope can decide
        // this, so the transport status is never the answer.
        if (!secToken) {
            return JSON.stringify({ status: 401, body: '{"code":"ConsoleNeedLogin"}' });
        }
        // `cornerstoneParam` is what the gateway's own validation asks for:
        // without it the platform answers 200 with
        // `{"data":{"success":false,"errorCode":"BadRequest"}}` and never
        // reaches the business layer at all. Only its presence is checked —
        // an empty object passes — but the fields are the ones the console's
        // own client fills, minus `switchAgent`, which its usage call skips.
        const cornerstoneParam = {
            domain: window.location.hostname,
            consoleSite: 'QIANWENAI',
            console: 'ONE_CONSOLE',
            xsp_lang: (window.ALIYUN_CONSOLE_CONFIG || {}).LOCALE || 'zh-CN',
            protocol: 'V2',
            productCode: 'p_efm'
        };
        const params = JSON.stringify({
            Api: 'zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage',
            Data: { cornerstoneParam: cornerstoneParam },
            V: '1.0'
        });
        const form = new URLSearchParams();
        form.set('product', 'sfm_bailian');
        form.set('action', 'BroadScopeAspnGateway');
        form.set('sec_token', secToken);
        form.set('region', 'cn-beijing');
        form.set('params', params);
        const response = await fetch('https://cs-data.qianwenai.com/data/api.json', {
            method: 'POST',
            credentials: 'include',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: form.toString()
        });
        const body = await response.text();
        let status = response.status;
        try {
            // The platform's own session-failure codes — the set the console's
            // own bundle keys its "session expired" dialogue off. All of them
            // ride under HTTP 200, and the gateway names the failure in
            // `data.errorCode`: the wrapper's `code` stays "200" straight
            // through a business failure, so both fields have to be read or
            // the marker never matches. Anything else — BadRequest, a 500, a
            // malformed envelope — keeps its status and its body, so the
            // parser is what rejects it.
            const envelope = JSON.parse(body);
            const data = (envelope && envelope.data) || {};
            const named = [envelope.code, data.errorCode, data.code];
            const signedOut = ['ConsoleNeedLogin', 'BailianGateway.Login.NotLogined', 'NO_LOGIN'];
            if (named.some((value) => signedOut.some(
                (marker) => String(value || '').trim().toLowerCase() === marker.toLowerCase()))) {
                status = 401;
            }
        } catch (_) {}
        return JSON.stringify({ status: status, body: body });
        """#,
        fidelity: .derived,
        authProbeScript: #"""
        try {
            const response = await fetch('https://platform-home.qianwenai.com/tool/user/info.json', {
                credentials: 'include',
                headers: { 'Accept': 'application/json' }
            });
            if (response.status < 200 || response.status >= 300) {
                return JSON.stringify({ authenticated: false });
            }
            const info = JSON.parse(await response.text());
            const payload = info && info.payload ? info.payload : info;
            if (!payload || String(payload.code) !== '200' || !payload.data
                || !payload.data.secToken) {
                return JSON.stringify({ authenticated: false });
            }
            // The digest, not the token: this is the session identity a switch
            // has to see change, and the raw session stays in the page.
            const bytes = new TextEncoder().encode(payload.data.secToken);
            const digest = await crypto.subtle.digest('SHA-256', bytes);
            const fingerprint = Array.from(new Uint8Array(digest))
                .map(byte => byte.toString(16).padStart(2, '0')).join('');
            return JSON.stringify({ authenticated: true, fingerprint });
        } catch (_) { return JSON.stringify({ authenticated: false }); }
        """#,
        // Sign-out has to take the gateway hosts and the platform's own account
        // host with it: the session cookie that answers all of them lives on
        // `account.qianwenai.com`, and `origin.host` is added by `signOut()`.
        // The Aliyun SSO step leaves its own cookie on `account.aliyun.com`; left
        // behind, the next sign-in would go straight through as the old account.
        associatedHosts: ["platform-home.qianwenai.com", "cs-data.qianwenai.com",
                          "account.qianwenai.com", "account.aliyun.com"],
        // The only site that polls while its sign-in window is open (see
        // `pollsDuringSignIn`): its probe is the console's own session check.
        pollsDuringSignIn: true,
        // The console's SPA only serves under `/home`, and its own route table
        // maps this plan page to `analytics/token-plan/individual` — the
        // default `origin/usage` answers 404 here.
        managePath: "home/analytics/token-plan/individual",
        // Role declarations, not the plan's period: "week" is the id of the one
        // allowance the Token Plan reports, and a monthly plan reports through
        // the same window (see `QianwenUsage`). Consumers resolve by id
        // (`ProviderSnapshot.headline`, `weeklyLimitWindow`/`weeklyWindow`), so
        // renaming this to match a period would resolve to nothing and draw an
        // empty ring. The same id in both means the notch draws one ring for
        // the one allowance rather than the same fact twice.
        headlineID: "week",
        weeklyID: "week",
        parse: { try QianwenUsage.windows(fromJSON: $0) }
    )

    /// Xiaomi MiMo's Token Plan is read the same way QianwenAI's is: the plan's
    /// own gateway (`token-plan-*.xiaomimimo.com/v1`) answers a `tp-` key only
    /// for `/models` and `/chat/completions` and 404s every usage path, so the
    /// numbers live on the platform console, authorized by the browser session
    /// cookie. The user signs in inside Codenotch's own WKWebView, and the site
    /// script reads the console's `tokenPlan/usage` (and `/detail` for the reset
    /// moment) with that session — never the key, never `~/.mimo` off disk.
    static let mimo = WebSessionProvider.Site(
        id: "mimo",
        displayName: "MiMo",
        glyph: .mimo,
        origin: URL(string: "https://platform.xiaomimimo.com/")!,
        script: #"""
        // The usage reading is the whole ring; `/detail` only names the reset
        // moment and the plan, so a failure there must not cost the quota.
        const usage = await fetch('/api/v1/tokenPlan/usage', {
            credentials: 'include',
            headers: { 'Accept': 'application/json' }
        });
        let detailBody = '';
        try {
            const detail = await fetch('/api/v1/tokenPlan/detail', {
                credentials: 'include',
                headers: { 'Accept': 'application/json' }
            });
            if (detail.status >= 200 && detail.status < 300) detailBody = await detail.text();
        } catch (_) {}
        return JSON.stringify({
            status: usage.status,
            body: JSON.stringify({ usage: await usage.text(), detail: detailBody })
        });
        """#,
        authProbeScript: #"""
        try {
            // Signed out is HTTP 401 here with a `loginUrl`, so the transport
            // status is what decides; a 200 that carries `code` 401 is the same
            // dead session one layer down.
            const response = await fetch('/api/v1/tokenPlan/usage', {
                credentials: 'include',
                headers: { 'Accept': 'application/json' }
            });
            if (response.status < 200 || response.status >= 300) {
                return JSON.stringify({ authenticated: false });
            }
            let envelope = null;
            try { envelope = JSON.parse(await response.text()); } catch (_) {}
            if (envelope && typeof envelope.code === 'number' && envelope.code !== 0) {
                return JSON.stringify({ authenticated: false });
            }
            // The account identity a switch has to see change: the `userId`
            // cookie the console session carries, digested. Two accounts would
            // share a fingerprint only if that cookie were httpOnly and absent,
            // which blunts account-switch detection but never the reading.
            let fingerprint = null;
            try {
                const match = document.cookie.match(/(?:^|;\s*)userId=([^;]*)/);
                let seed = match ? decodeURIComponent(match[1]) : null;
                if (!seed) {
                    const detail = await fetch('/api/v1/tokenPlan/detail', {
                        credentials: 'include',
                        headers: { 'Accept': 'application/json' }
                    });
                    const body = JSON.parse(await detail.text());
                    const plan = (body && body.data) || body;
                    seed = String((plan && plan.planCode) || '') + '|'
                         + String((plan && plan.currentPeriodEnd) || '');
                }
                const bytes = new TextEncoder().encode(seed);
                const digest = await crypto.subtle.digest('SHA-256', bytes);
                fingerprint = Array.from(new Uint8Array(digest))
                    .map(byte => byte.toString(16).padStart(2, '0')).join('');
            } catch (_) {}
            return JSON.stringify({ authenticated: true, fingerprint });
        } catch (_) { return JSON.stringify({ authenticated: false }); }
        """#,
        // Sign-out has to take Xiaomi's own SSO host with it: the session cookie
        // that authorizes the console lives behind `account.xiaomi.com`, and
        // `origin.host` is added by `signOut()`. Left behind, the next sign-in
        // would go straight through as the old account.
        associatedHosts: ["account.xiaomi.com"],
        // Confirm once when the window closes, the way DeepSeek does. The login
        // is a round-trip through Xiaomi's SSO host (`account.xiaomi.com`) and
        // back to the console, and the sign-in poll cannot reliably see a
        // logged-out -> logged-in change across that hop: it either samples the
        // console just before it hands off to SSO, or SSO returns it to the very
        // page it already probed (so the once-per-page dedup skips it). The final
        // authenticated state is confirmed on close instead — dependable, and it
        // keeps a request off the usage endpoint while a password is being typed.
        pollsDuringSignIn: false,
        // A refused read here is the site retiring its own console session
        // cookie, not the user signing out: the SSO session behind the page
        // still answers, so reloading the console mints a fresh cookie with no
        // credentials — the sign-in window opens "already logged in" the moment
        // after the ring went dark, and closing it brought the percentage back.
        // One 401 used to flip `hasSignedIn`, which every later refresh then
        // short-circuits on without touching the network, so the ring stayed
        // dark until that manual cycle by hand. One silent reload and one more
        // read automate it; if the reload is refused too, the session is
        // genuinely gone and it asks the user just as before.
        reloadsSessionOnAuthFailure: true,
        // The coding-plan screen, under a real path — the origin alone lands on a
        // marketing page that never offers the sign-in, and `/console/balance` is
        // not where the Token Plan reports. Both the sign-in window and the
        // manage link open this path. The origin itself stays the bare host: it
        // is what cookie clearing and the probe's `matchesOrigin` key on.
        managePath: "console/plan-manage",
        initialPath: "console/plan-manage",
        // The one allowance the Token Plan reports, under the plan's own period
        // rather than a calendar month (see `MiMoUsage`), so it is the headline
        // ring and there is no weekly one to declare.
        headlineID: "month",
        parse: { try MiMoUsage.windows(fromJSON: $0) }
    )

    /// MiniMax is signed into from Codenotch's own WKWebView, the same way
    /// DeepSeek is. Login lives on the regional platform origin; coding-plan
    /// remains is a www host, so the fetch is absolute and sign-out has to
    /// clear that host as well as the platform one.
    static func minimax(region: MiniMaxRegion) -> WebSessionProvider.Site {
        let remains = region.remainsURL.absoluteString
        // Absolute www URL: a relative path would be resolved against the
        // platform origin the WebView is sitting on, which does not serve
        // remains. 1004 is MiniMax's missing-cookie code and often rides
        // under HTTP 200, so the envelope has to become 401 or the session
        // stays signed in.
        let readRemains = """
        const response = await fetch('\(remains)', {
            credentials: 'include',
            headers: { 'Accept': 'application/json' }
        });
        let status = response.status;
        const body = await response.text();
        try {
            const parsed = JSON.parse(body);
            const resp = (parsed && parsed.base_resp)
                || (parsed && parsed.data && parsed.data.base_resp);
            const code = resp && resp.status_code;
            if (status === 1004 || Number(code) === 1004) status = 401;
        } catch (_) {}
        """
        return WebSessionProvider.Site(
            id: "minimax",
            displayName: "MiniMax",
            glyph: .minimax,
            origin: region.platformOrigin,
            script: """
            \(readRemains)
            return JSON.stringify({ status: status, body: body });
            """,
            fidelity: .derived,
            authProbeScript: """
            try {
                \(readRemains)
                if (status < 200 || status >= 300) {
                    return JSON.stringify({ authenticated: false });
                }
                let fingerprint = null;
                try {
                    const session = localStorage.getItem('access_token');
                    if (session) {
                        const bytes = new TextEncoder().encode(session);
                        const digest = await crypto.subtle.digest('SHA-256', bytes);
                        fingerprint = Array.from(new Uint8Array(digest))
                            .map(byte => byte.toString(16).padStart(2, '0')).join('');
                    }
                } catch (_) {}
                return JSON.stringify({ authenticated: true, fingerprint });
            } catch (_) { return JSON.stringify({ authenticated: false }); }
            """,
            // China's console lived on minimaxi.com before it moved to
            // minimax.cn; a session from then is still cleared on sign-out.
            associatedHosts: [region.remainsURL.host].compactMap { $0 }
                + (region == .china ? ["platform.minimaxi.com", "www.minimaxi.com"] : []),
            parse: { try MiniMaxUsage.windows(fromJSON: $0) }
        )
    }
    /// XyToken relay station (api.xytoken.xyb2b.com). Its wallet page calls
    /// POST /api/user/auth/refresh (empty body, authenticated solely by the
    /// HttpOnly `xy_token_api_refresh` cookie, which the server rotates on
    /// every call) and then GET /api/subscription/self with the short-lived
    /// bearer token that refresh returns. The cookie is invisible to page JS
    /// and unreachable for URLSession, so the sequence runs in the app's
    /// WebView: the user signs in once, and when the session is gone the ring
    /// asks for sign-in again.
    ///
    /// The station's refresh is a **session-pinned rotation**: the page keeps
    /// the session id (`data.session.sid`) from its first refresh and sends it
    /// back as `X-Auth-Session` on every later one, answering `409
    /// AUTH_REFRESH_RACE` (another client rotated first — retry) and `409
    /// AUTH_SESSION_MISMATCH` (the cookie now belongs to a different session —
    /// re-bootstrap without the header). This script follows the same contract,
    /// because the app is a *second* client on that cookie: the SPA in this very
    /// WebView refreshes it too, and a long-lived session that only ever
    /// refreshed without its identity is the one shape the station never sees
    /// from a browser. A page reload drops both globals, which turns the next
    /// refresh back into a bootstrap — exactly what the page itself does.
    ///
    /// The bearer token is kept in a page global for its own lifetime (15
    /// minutes); the idle schedule is 5 minutes, so caching it takes two
    /// rotations out of every three. Deliberately not localStorage: the page
    /// keeps its own token in memory only, and mirroring it to disk would widen
    /// a 15-minute credential's exposure for nothing.
    ///
    /// `authProbeScript` is what confirms a sign-in. Without it the sheet used
    /// to declare itself signed in the moment it opened — while it was still
    /// the login page — and the first fetch made from there answered 401 and
    /// cleared the flag for good, because nothing sets it back once the login
    /// really succeeds (`windowWillClose` only confirms a site that has a
    /// probe). The probe also reports `session.sid`, the identity an account
    /// switch has to change.
    ///
    /// What counts as signed in is the station's own definition, not "the
    /// refresh succeeded and a session came back": its console only accepts a
    /// *bundle* — access token, user, session — and it keeps the two-factor
    /// form on screen while it is merely a session. A probe that stops at
    /// `sid` committed a sign-in the site had not finished and closed the
    /// window on the code input (2026-10-29).
    ///
    /// The body is wrapped in try/catch and reports a `0` status instead of
    /// throwing: a rejected `fetch` — which is what a suspended WebView looks
    /// like after a wake — used to surface as an opaque "JavaScript exception"
    /// with no trace of *why*. The refresh's session timestamps ride along in
    /// the envelope so the provider can log what the station thinks the
    /// session's lifetime is, rather than the app inferring it.
    static let xytoken = WebSessionProvider.Site(
        id: "xytoken",
        displayName: "XyToken",
        glyph: .third,
        origin: URL(string: "https://api.xytoken.xyb2b.com/")!,
        script: """
        const now = Math.floor(Date.now() / 1000);
        const cached = window.__codenotchXyToken;
        let token = cached && cached.expiresAt > now + 60 ? cached.token : null;
        const fromCache = !!token;

        const remember = (data, requestId) => {
            if (!data) return;
            if (typeof data.access_token === 'string' && data.access_token) {
                window.__codenotchXyToken = {
                    token: data.access_token,
                    expiresAt: Number(data.access_expires_at) || 0
                };
            }
            const session = data.session || null;
            if (session && typeof session.sid === 'string' && session.sid) {
                window.__codenotchXySession = session.sid;
            }
            if (session) {
                window.__codenotchXySessionInfo =
                    'created=' + String(session.created_at || '') +
                    ' last_active=' + String(session.last_active_at || '') +
                    ' expires=' + String(session.expires_at || '') +
                    (requestId ? ' request=' + requestId : '');
            }
        };
        const forget = () => {
            window.__codenotchXyToken = null;
            window.__codenotchXySession = null;
        };

        const ask = async (expected) => {
            const headers = { 'Accept': 'application/json' };
            if (expected) headers['X-Auth-Session'] = expected;
            const r = await fetch('/api/user/auth/refresh', {
                method: 'POST',
                credentials: 'include',
                headers: headers
            });
            const body = await r.text();
            let parsed = null;
            try { parsed = JSON.parse(body); } catch (_) {}
            return {
                status: r.status,
                body: body,
                data: parsed && parsed.data,
                code: parsed && parsed.code,
                requestId: r.headers.get('X-Request-Id') || ''
            };
        };

        const refresh = async () => {
            const expected = window.__codenotchXySession || null;
            let result = await ask(expected);
            // Another client on this cookie rotated first: retry once, the way
            // the page's own client does. A mismatch means the cookie now
            // belongs to a different session, so the identity must go.
            if (result.status === 409 && result.code === 'AUTH_REFRESH_RACE') {
                await new Promise((resolve) => setTimeout(resolve, 150));
                result = await ask(expected);
            } else if (result.status === 409 && result.code === 'AUTH_SESSION_MISMATCH' && expected) {
                window.__codenotchXySession = null;
                result = await ask(null);
            }
            if (result.status < 200 || result.status >= 300) {
                if (result.status === 401 || result.status === 403) forget();
                return { status: result.status, body: result.body, requestId: result.requestId };
            }
            const fresh = result.data && result.data.access_token;
            if (!fresh) return { status: 502, body: result.body, requestId: result.requestId };
            remember(result.data, result.requestId);
            return { token: fresh, requestId: result.requestId };
        };

        const readSelf = (bearer) => fetch('/api/subscription/self', {
            credentials: 'include',
            headers: { 'Accept': 'application/json', 'Authorization': 'Bearer ' + bearer }
        });

        try {
            let refreshed = false;
            if (!token) {
                const result = await refresh();
                if (!result.token) return JSON.stringify({ status: result.status, body: result.body, requestId: result.requestId });
                token = result.token;
                refreshed = true;
            }

            let s = await readSelf(token);
            // A token taken from the cache can be dead before its own expiry —
            // the session was ended somewhere else. Ask for one fresh token
            // before reporting the session gone, because that report is what
            // signs the user out of the app.
            if (fromCache && (s.status === 401 || s.status === 403)) {
                forget();
                const result = await refresh();
                if (!result.token) return JSON.stringify({ status: result.status, body: result.body, requestId: result.requestId });
                token = result.token;
                refreshed = true;
                s = await readSelf(token);
            }

            const envelope = { status: s.status, body: await s.text() };
            // The station's own id for this response: the one thing its
            // server-side log can be searched by when a session ends and
            // nobody can say why.
            const selfRequestId = s.headers.get('X-Request-Id') || '';
            if (selfRequestId) envelope.requestId = selfRequestId;
            if (refreshed && window.__codenotchXySessionInfo) {
                envelope.session = window.__codenotchXySessionInfo;
            }
            return JSON.stringify(envelope);
        } catch (error) {
            return JSON.stringify({
                status: 0,
                body: 'script error: ' + String((error && error.message) || error)
            });
        }
        """,
        authProbeScript: #"""
        try {
            // A sign-in mints a new session; the token and the identity cached
            // for the old one must not answer for it.
            window.__codenotchXyToken = null;
            window.__codenotchXySession = null;
            window.__codenotchXySessionInfo = null;
            const r = await fetch('/api/user/auth/refresh', {
                method: 'POST',
                credentials: 'include',
                headers: { 'Accept': 'application/json' }
            });
            if (!r.ok) return JSON.stringify({ authenticated: false });
            let data = null;
            try { data = JSON.parse(await r.text()).data; } catch (_) {}
            // A session is not a sign-in. While the station waits for a second
            // factor it has already minted one — `sid` and all — and answers
            // this refresh `200`, but without the access token and user its own
            // console needs. Its frontend calls that "not signed in"
            // (`isAuthBundle`) and keeps the verification form on screen, so
            // committing on `sid` alone closed the window on the code input
            // (2026-10-29) — the one screen the app cannot get past for the
            // user. Ask for the same bundle the station asks itself for.
            const user = data && data.user;
            const session = data && data.session;
            const signedIn = !!data
                && typeof data.access_token === 'string' && data.access_token.length > 0
                && !!user && Number(user.id) > 0
                && !!session && typeof session.sid === 'string' && session.sid.length > 0;
            if (!signedIn) return JSON.stringify({ authenticated: false });
            return JSON.stringify({ authenticated: true, fingerprint: session.sid });
        } catch (_) { return JSON.stringify({ authenticated: false }); }
        """#,
        // The station moved its administrator MFA to a per-role requirement
        // ("Require MFA" on each role), and answers a session that has not
        // verified yet with `403 ADMIN_MFA_REQUIRED` — while still holding
        // that session, which is why its own session list shows it alive. The
        // app read that as a lost login, blanked the ring and stopped asking
        // (2026-10-29). Only this code: a `401` still means the session is
        // gone, and the other `403`s still mean the request was refused.
        mfaCodes: ["ADMIN_MFA_REQUIRED"],
        pollsDuringSignIn: true,
        // Role declarations, by the window ids `XyTokenUsage` derives — the
        // stable half of the station's `rule_key` (`day:1`, `week:1`), never the
        // reset schedule after the `|`. Consumers resolve by exact id
        // (`ProviderSnapshot.headline`, `weeklyLimitWindow`/`weeklyWindow`), so
        // these are what make the weekly-ring settings and the weekly watcher
        // apply here. The two differ (daily is the headline, weekly is the thin
        // second ring), so the notch draws one main ring plus the optional
        // weekly arc, as it does for Kimi and OpenCode — and declaring the
        // headline also stops it following the response's array order. If the
        // station ever renames them the ids resolve to nothing — a blank main
        // ring, no weekly arc — which is the answer every id-declaring provider
        // gives (see `QianwenUsage`), not the first window this used to fall
        // back to. The menu bar is out of reach either way: `StatusItemSummary`
        // needs a five-hour window or Claude/Codex. These ids were first written
        // as the whole `rule_key` — copied from the test fixture, which rewrites
        // it — and never matched the live `week:1|week:MON 00:00`, so the weekly
        // ring drew nothing until the id was narrowed to its stable half.
        headlineID: "day:1",
        weeklyID: "week:1",
        parse: XyTokenUsage.windows(fromJSON:)
    )

}
