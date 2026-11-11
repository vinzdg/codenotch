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
            var windows = [LimitWindow(
                id: "spend",
                label: L10n.t("Account usage (\(reading.currency))"),
                usedFraction: reading.usedFraction,
                money: UsageMoneyBreakdown(currency: reading.currency,
                                           spent: reading.spent,
                                           remaining: reading.balance)
            )]
            if let availableTokens = reading.availableTokens {
                windows.append(LimitWindow(id: "available-tokens",
                                           label: "Available tokens (estimate)",
                                           detail: "\(LimitWindow.compact(availableTokens)) available"))
            }
            return windows
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
            associatedHosts: [region.remainsURL.host].compactMap { $0 },
            parse: { try MiniMaxUsage.windows(fromJSON: $0) }
        )
    }

}
