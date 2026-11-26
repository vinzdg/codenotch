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

    /// Qwen.ai's Plus/Pro allowance has no API in `qwen code`'s OAuth protocol:
    /// that token is scoped to model calls and the CLI only learns it is out of
    /// credits when a request comes back 402. The number behind the console's
    /// Usage & Billing page lives on an entitlement service keyed by the *web*
    /// session, so the user signs into `chat.qwen.ai` in Codenotch's own
    /// WKWebView and the page script borrows its access token — the same shape
    /// as QianwenAI's and MiMo's console reading, never the CLI's token file.
    static let qwenAI = WebSessionProvider.Site(
        id: "qwenai",
        displayName: "Qwen.ai",
        glyph: .qwenAI,
        origin: URL(string: "https://chat.qwen.ai/")!,
        script: #"""
        // The console keeps its bearer in page storage (the native-app UA uses
        // a cookie instead, which a normal WKWebView never claims). If it is
        // absent, the console's own `/auths/refresh` mints one from the session
        // cookie — ask before treating the page as signed out.
        const readToken = () => {
            try {
                const state = JSON.parse(localStorage.getItem('qwen_access_token_state') || 'null');
                let token = (state && typeof state.token === 'string') ? state.token : '';
                const expiresAt = Number(state && state.expiresAt);
                if (token && Number.isFinite(expiresAt) && expiresAt > 0) {
                    // The console stores milliseconds; older entries are seconds.
                    const deadline = expiresAt > 100000000000 ? expiresAt : expiresAt * 1000;
                    if (deadline <= Date.now()) token = '';
                }
                if (token) return token;
            } catch (_) {}
            return localStorage.getItem('token') || '';
        };
        let token = readToken();
        if (!token) {
            try {
                const refresh = await fetch('/auths/refresh', {
                    credentials: 'include', headers: { 'Accept': 'application/json' }
                });
                if (refresh.ok) {
                    const body = await refresh.json();
                    token = (body && (body.access_token || (body.data && body.data.access_token))) || '';
                }
            } catch (_) {}
        }
        if (!token) {
            return JSON.stringify({ status: 401,
                body: '{"errorCode":"NOT_LOGIN","httpCode":401,"success":false}' });
        }
        // The console's own default query fields. The entitlement host is on
        // `qwen.com`, not `qwen.ai`, and answers CORS for this origin with
        // credentials, so the same bearer works from the page.
        const common = 'biz_id=ai_qwen&chat_client=h5&device=pc&fr=pc&pr=qwen-i18n&la='
            + encodeURIComponent(navigator.language || 'en-US') + '&tz='
            + encodeURIComponent(Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC')
            + '&wv=0.3.52';
        const headers = {
            'Accept': 'application/json',
            'Authorization': 'Bearer ' + token,
            'Version': '0.3.52',
            'source': 'h5'
        };
        const entitlement = async (path) => {
            try {
                const response = await fetch('https://sg-entitlement.qwen.com' + path, {
                    credentials: 'include', headers: headers
                });
                const text = await response.text();
                let status = response.status;
                try {
                    const body = JSON.parse(text);
                    // Signed out is HTTP 200 with a body-level NOT_LOGIN on this
                    // service; the transport status alone would call it a ring.
                    if (body && (body.success === false || body.errorCode === 'NOT_LOGIN'
                        || Number(body.httpCode) === 401)) status = 401;
                } catch (_) {}
                return { status: status, text: text };
            } catch (_) {
                return { status: 0, text: '' };
            }
        };
        // `agent/usage` owns the percentage and the reset; the credits history
        // only supplies the "credits left" count for the tooltip.
        const usage = await entitlement('/api/entitlement/agent/usage?' + common);
        const credits = await entitlement(
            '/api/entitlement/credits/credits/history?pageNum=1&pageSize=20&' + common);
        return JSON.stringify({
            status: usage.status,
            body: JSON.stringify({ usage: usage.text, credits: credits.text })
        });
        """#,
        fidelity: .derived,
        authProbeScript: #"""
        try {
            // The console's own session state is the liveness signal. The
            // entitlement credit-status endpoint this probed first is feature-flagged:
            // on an account without that flag it answers success:false even
            // with a valid web session, so a finished login was never committed
            // and the ring stayed dark until the button was pressed twice.
            const state = JSON.parse(localStorage.getItem('qwen_access_token_state') || 'null');
            let token = (state && typeof state.token === 'string') ? state.token : '';
            const expiresAt = Number(state && state.expiresAt);
            if (token && Number.isFinite(expiresAt) && expiresAt > 0) {
                const deadline = expiresAt > 100000000000 ? expiresAt : expiresAt * 1000;
                if (deadline <= Date.now()) token = '';
            }
            if (!token) token = localStorage.getItem('token') || '';
            if (!token) {
                // A live web cookie can mint a fresh bearer, as it does on a
                // normal console reload.
                const refresh = await fetch('/auths/refresh', {
                    credentials: 'include', headers: { 'Accept': 'application/json' }
                });
                if (refresh.ok) {
                    const body = await refresh.json();
                    token = (body && (body.access_token || (body.data && body.data.access_token))) || '';
                }
            }
            if (!token) return JSON.stringify({ authenticated: false });
            // The digest, not the token: the account identity a switch has to
            // see change, while the bearer stays in the page's own storage.
            const bytes = new TextEncoder().encode(token);
            const digest = await crypto.subtle.digest('SHA-256', bytes);
            const fingerprint = Array.from(new Uint8Array(digest))
                .map(byte => byte.toString(16).padStart(2, '0')).join('');
            return JSON.stringify({ authenticated: true, fingerprint });
        } catch (_) { return JSON.stringify({ authenticated: false }); }
        """#,
        // The account details behind these bodies are not ours to record.
        logsResponseBody: false,
        // Sign-out has to take the entitlement host (and the SSO host behind
        // the web login) with it, or the next sign-in walks straight back in
        // as the previous account.
        associatedHosts: ["sg-entitlement.qwen.com", "sg-member.qwen.com", "auth.qwen.ai"],
        // The login lands back on this origin and the token appears in its
        // page storage, so watch the sheet and commit a finished login as it
        // happens. The probe is local and cheap — it never asks a throttled
        // endpoint — and the close path still confirms a login completed in a
        // popup that leaves this page's URL unchanged.
        pollsDuringSignIn: true,
        // An expired web bearer is best recovered by refreshing the page: the
        // console mints a fresh one from its own cookie, the way it does on a
        // normal visit. Only a second refusal declares the session dead.
        reloadsSessionOnAuthFailure: true,
        // The manage link opens Usage & Billing, but the sign-in window must
        // open the console's own `/auth` page: its guard bounces protected
        // routes (including `/settings/usage-billing`) to the chat home while
        // signed out, which is why the first popup appeared to lose the page
        // it was opening. `/auth` is the route the console itself presents for
        // logging in, and a completed login redirects back to this origin —
        // a URL change the sign-in poll can see and commit.
        managePath: "settings/usage-billing",
        initialPath: "auth",
        // One weekly allowance: the console's `remainingPercent` and its reset
        // moment describe the coding credits, not a balance or a spend.
        headlineID: "week",
        weeklyID: "week",
        parse: { try QwenAIUsage.windows(fromJSON: $0) }
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

}
