import Foundation

extension Sites {
    enum QoderRegion: String, CaseIterable, Identifiable {
        case global, china
        var id: String { rawValue }
        var origin: URL {
            URL(string: self == .china ? "https://qoder.com.cn/" : "https://qoder.com/")!
        }
    }

    // Observe only the website's frontend build tag on same-origin usage
    // requests, never Cookie/Authorization. No historical build is pinned.
    static let qoderBuildVersionScript = #"""
    (() => {
        const usagePath = '/api/v2/me/usages/big_model_credits';
        const matches = value => {
            try {
                const url = new URL(value, location.href);
                return url.origin === location.origin && url.pathname === usagePath;
            } catch (_) { return false; }
        };
        const remember = value => {
            if (typeof value === 'string' && /^[a-zA-Z0-9._-]{1,64}$/.test(value))
                window.__qoderBuildVersion = value;
        };
        const originalFetch = window.fetch;
        window.fetch = function(input, options) {
            if (matches(input instanceof Request ? input.url : input)) {
                const headers = new Headers(options && options.headers
                    || (input instanceof Request ? input.headers : undefined));
                remember(headers.get('Bx-V'));
            }
            return originalFetch.apply(this, arguments);
        };
        const originalOpen = XMLHttpRequest.prototype.open;
        const originalHeader = XMLHttpRequest.prototype.setRequestHeader;
        XMLHttpRequest.prototype.open = function(method, url) {
            this.__qoderUsageRequest = matches(url);
            return originalOpen.apply(this, arguments);
        };
        XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
            if (this.__qoderUsageRequest && String(name).toLowerCase() === 'bx-v')
                remember(value);
            return originalHeader.apply(this, arguments);
        };
    })();
    """#

    /// Requests stay in the matching WebKit origin. No imported cookies or UA
    /// spoofing; a rejected browser request leaves usage unavailable.
    static func qoder(region: QoderRegion) -> WebSessionProvider.Site {
        WebSessionProvider.Site(
            id: "qoder",
            displayName: "Qoder",
            glyph: .qoder,
            origin: region.origin,
            script: """
            const headers = {'Accept': 'application/json, text/plain, */*', 'X-Requested-With': 'XMLHttpRequest'};
            if (window.__qoderBuildVersion) headers['Bx-V'] = window.__qoderBuildVersion;
            const response = await fetch('/api/v2/me/usages/big_model_credits', {credentials: 'include', headers});
            return JSON.stringify({status: response.status, body: await response.text()});
            """,
            authProbeScript: """
            const headers = {'Accept': 'application/json, text/plain, */*', 'X-Requested-With': 'XMLHttpRequest'};
            if (window.__qoderBuildVersion) headers['Bx-V'] = window.__qoderBuildVersion;
            const response = await fetch('/api/v2/me/usages/big_model_credits', {credentials: 'include', headers});
            if (!response.ok) return false;
            try {
                const p = await response.json();
                const quota = p.totalQuota ?? p.total_quota;
                const summary = quota && (quota.quotaSummary ?? quota.quota_summary);
                const used = summary && (summary.usedValue ?? summary.used_value);
                const limit = summary && (summary.limitValue ?? summary.limit_value);
                return typeof used === 'number' && Number.isFinite(used) && used >= 0
                    && typeof limit === 'number' && Number.isFinite(limit) && limit >= 0;
            } catch (_) { return false; }
            """,
            sessionKey: "qoder.\(region.rawValue).signedIn",
            forbiddenMessage: L10n.t("Qoder refused the browser request. Open Sign in to check your session or complete website verification."),
            logsResponseBody: false,
            managePath: "account/usage",
            initialPath: "account/usage",
            bootstrapScript: qoderBuildVersionScript,
            headlineID: "credits",
            parse: QoderUsage.windows(fromJSON:)
        )
    }
}
