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
        parse: PerplexityUsage.windows(fromJSON:)
    )

    /// SuperGrok's weekly pool, from the same RPC the Usage card itself reads.
    ///
    /// `GetGrokCreditsConfig` is gRPC-web + protobuf with no published schema —
    /// see `GrokUsage` for the layout. The script posts the empty request frame
    /// and base64s the raw bytes into the body, so the Swift side parses bytes
    /// it can pin tests against rather than JSON shaped by page code.
    static let grok = WebSessionProvider.Site(
        id: "grok",
        displayName: "Grok",
        glyph: .grok,
        origin: URL(string: "https://grok.com/")!,
        script: """
        const response = await fetch('/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig', {
            method: 'POST',
            credentials: 'include',
            headers: {
                'Content-Type': 'application/grpc-web+proto',
                'x-grpc-web': '1',
                'Accept': 'application/grpc-web+proto'
            },
            body: new Uint8Array([0, 0, 0, 0, 0])
        });
        const bytes = new Uint8Array(await response.arrayBuffer());
        let bin = '';
        for (let i = 0; i < bytes.length; i++) { bin += String.fromCharCode(bytes[i]); }
        return JSON.stringify({ status: response.status, body: btoa(bin) });
        """,
        parse: { try GrokUsage.windows(fromBody: $0) }
    )

}
