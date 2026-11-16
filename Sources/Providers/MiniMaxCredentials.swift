import Foundation

/// Which MiniMax console a key or cookie belongs to.
///
/// The two regions do not share accounts: a China key asked of api.minimax.io
/// (or an international session cookie sent to www.minimax.cn) answers as an
/// auth failure, which would read as a signed-out plan that is merely pointed
/// at the other country.
enum MiniMaxRegion: String, Codable, CaseIterable {
    /// api.minimax.io / platform.minimax.io
    case international
    /// api.minimaxi.com / platform.minimax.cn
    case china

    var apiBase: URL {
        switch self {
        case .international: return URL(string: "https://api.minimax.io")!
        case .china:         return URL(string: "https://api.minimaxi.com")!
        }
    }

    /// China's console moved to minimax.cn: platform.minimaxi.com now answers
    /// 302 to platform.minimax.cn. The sign-in sheet only probes a page on
    /// this exact origin, so the old host left a finished sign-in unconfirmed
    /// (#516).
    var platformOrigin: URL {
        switch self {
        case .international: return URL(string: "https://platform.minimax.io")!
        case .china:         return URL(string: "https://platform.minimax.cn")!
        }
    }

    /// The console host the coding-plan remains JSON is served from. A session
    /// cookie is origin-scoped, so this is www rather than the API host, and it
    /// has to sit under the console's cookie domain: China's console sets its
    /// cookies on .minimax.cn, so www.minimaxi.com would never receive them.
    var remainsURL: URL {
        switch self {
        case .international:
            return URL(string: "https://www.minimax.io/v1/api/openplatform/coding_plan/remains")!
        case .china:
            return URL(string: "https://www.minimax.cn/v1/api/openplatform/coding_plan/remains")!
        }
    }

    var tokenPlanRemainsURL: URL {
        apiBase.appending(path: "v1/token_plan/remains")
    }

    var codingPlanRemainsURL: URL {
        apiBase.appending(path: "v1/api/openplatform/coding_plan/remains")
    }

    var displayName: String {
        switch self {
        case .international: return L10n.t("International")
        case .china:         return L10n.t("China")
        }
    }

    var codingPlanPage: URL {
        platformOrigin.appending(path: "user-center/payment/coding-plan")
    }
}

/// The MiniMax Coding Plan key and optional console session cookie.
///
/// Codenotch owns both: the user pastes them in Settings (or exports them),
/// and they live in the login keychain under service names no other app uses
/// — not `ollama-api-key`, which is Ollama's item on the same account.
/// Browser cookie databases are never opened: a Chrome or Safari session is
/// that browser's, and reading `Cookies.sqlite` / `Cookies.binarycookies`
/// would be taking a login that was not offered. A curl `-b` path to one of
/// those files is ignored rather than followed.
enum MiniMaxCredentials {
    static let apiKeyEnvironment = "MiniMax_CODING_API_KEY"
    static let apiKeyEnvironmentAlias = "MINIMAX_CODING_API_KEY"
    static let apiKeyEnvironmentFallback = "MINIMAX_API_KEY"
    static let cookieEnvironment = "MINIMAX_COOKIE"
    static let cookieHeaderEnvironment = "MINIMAX_COOKIE_HEADER"

    static let apiKeyService = "minimax-api-key"
    static let cookieService = "minimax-session-cookie"
    static let keychainAccount = "codenotch"

    /// Held until the item moves, for the reason spelled out in
    /// `CredentialCache`: a data read can prompt, and usage polling reaches
    /// this every minute. A stored key never expires on its own.
    private static let apiKeyCache = CredentialCache<String> { _ in false }
    private static let cookieCache = CredentialCache<String> { _ in false }

    private static func cachedAPIKey() -> String? {
        try? apiKeyCache.value(
            itemModifiedAt: { KeychainItem.modifiedAt(service: apiKeyService, account: keychainAccount) },
            reload: {
                guard let key = KeychainItem.read(service: apiKeyService, account: keychainAccount) else {
                    throw UsageProviderError.needsAuth
                }
                return key
            }
        )
    }

    private static func cachedCookie() -> String? {
        try? cookieCache.value(
            itemModifiedAt: { KeychainItem.modifiedAt(service: cookieService, account: keychainAccount) },
            reload: {
                guard let cookie = KeychainItem.read(service: cookieService, account: keychainAccount) else {
                    throw UsageProviderError.needsAuth
                }
                return cookie
            }
        )
    }

    /// The Coding Plan key, wherever it is found.
    /// `MiniMax_CODING_API_KEY` (then `MINIMAX_CODING_API_KEY`) wins over
    /// `MINIMAX_API_KEY` over the keychain: macOS env lookup is case-sensitive,
    /// so the mixed-case name MiniMax documents must be checked as itself or
    /// a generic pay-as-you-go key in front of it would report the wrong product.
    static func loadAPIKey(environment: [String: String] = ProcessInfo.processInfo.environment,
                           keychain: () -> String? = cachedAPIKey) -> String? {
        for key in [apiKeyEnvironment, apiKeyEnvironmentAlias, apiKeyEnvironmentFallback] {
            if let value = nonEmpty(environment[key]) { return value }
        }
        return keychain()
    }

    /// Whether a key is available, judged without a data read: the
    /// environment variables, else the item's attributes, which are free to
    /// ask about unlike its contents. Never the cache — that would not
    /// reflect a `store`/`delete` that just happened.
    static func isAPIKeyPresent(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        loadAPIKey(environment: environment, keychain: { nil }) != nil
            || KeychainItem.modifiedAt(service: apiKeyService, account: keychainAccount) != nil
    }

    static func storeAPIKey(_ key: String) {
        guard let trimmed = nonEmpty(key) else { return }
        apiKeyCache.forget()
        _ = KeychainItem.store(service: apiKeyService, account: keychainAccount, value: trimmed)
    }

    static func deleteAPIKey() {
        apiKeyCache.forget()
        _ = KeychainItem.delete(service: apiKeyService, account: keychainAccount)
    }

    /// The Cookie header value, wherever it is found. `MINIMAX_COOKIE` wins
    /// over `MINIMAX_COOKIE_HEADER` over the keychain. Both env vars are
    /// run through `normalizedCookieHeader`, so a pasted `curl -H 'Cookie: …'`
    /// is stored the same way a bare `name=value` pair is.
    static func loadCookieHeader(environment: [String: String] = ProcessInfo.processInfo.environment,
                                 keychain: () -> String? = cachedCookie) -> String? {
        if let cookie = cookieFromEnvironment(environment) { return cookie }
        return keychain().flatMap(normalizedCookieHeader(from:))
    }

    static func storeCookieHeader(_ raw: String) {
        guard let header = normalizedCookieHeader(from: raw) else { return }
        cookieCache.forget()
        _ = KeychainItem.store(service: cookieService, account: keychainAccount, value: header)
    }

    static func deleteCookieHeader() {
        cookieCache.forget()
        _ = KeychainItem.delete(service: cookieService, account: keychainAccount)
    }

    /// Accepts a bare cookie pair, a `Cookie:` header, or the `-H 'Cookie: …'`
    /// / `-b '…'` fragment of a curl command. Returns the header *value* (no
    /// `Cookie:` prefix), which is what `URLRequest` wants. Nil when there is
    /// nothing to send — including a curl command that never set a Cookie
    /// header, which must not be forwarded as if it were one, and a `-b` path
    /// to a browser cookie store, which must not be opened.
    static func normalizedCookieHeader(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let cookie = cookieFromCurlFlags(trimmed) { return cookie }
        let headerLine = cookieFromBareHeaderLine(trimmed)
        if headerLine.found { return headerLine.value }
        if looksLikeCurl(trimmed) { return nil }
        return trimmed
    }

    /// Identity for the settings row when a key or cookie is actually there.
    /// Attributes, not contents: the row is rebuilt on every render and has
    /// no business raising a keychain prompt to print a source name.
    static func account(region: MiniMaxRegion,
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderAccount? {
        guard isAPIKeyPresent(environment: environment) || isCookiePresent(environment: environment) else {
            return nil
        }
        return ProviderAccount(
            label: nil,
            plan: nil,
            source: "MiniMax",
            manageURL: region.codingPlanPage
        )
    }

    static func forgetCached() {
        apiKeyCache.forget()
        cookieCache.forget()
    }

    // MARK: - Private

    private static func isCookiePresent(environment: [String: String]) -> Bool {
        loadCookieHeader(environment: environment, keychain: { nil }) != nil
            || KeychainItem.modifiedAt(service: cookieService, account: keychainAccount) != nil
    }

    private static func cookieFromEnvironment(_ environment: [String: String]) -> String? {
        for key in [cookieEnvironment, cookieHeaderEnvironment] {
            if let raw = environment[key], let cookie = normalizedCookieHeader(from: raw) {
                return cookie
            }
        }
        return nil
    }

    /// `-H` / `--header` Cookie values, or `-b` / `--cookie` cookie strings.
    /// Flags after the value stay flags — taking `trimmed[Cookie:…]` would
    /// send `--compressed` and the rest of the command as the cookie.
    private static func cookieFromCurlFlags(_ text: String) -> String? {
        var index = text.startIndex
        while index < text.endIndex {
            guard let flag = nextFlag(in: text, from: index) else { return nil }
            switch flag.name {
            case "-H", "--header":
                if let argument = flag.argument, let cookie = cookieValue(fromHeaderArgument: argument) {
                    return cookie
                }
            case "-b", "--cookie":
                if let cookie = cookieString(fromCookieFlag: flag.argument) {
                    return cookie
                }
            default:
                break
            }
            if flag.end <= index {
                index = text.index(after: index)
            } else {
                index = flag.end
            }
        }
        return nil
    }

    /// A `Cookie:` header that is the whole paste, or a line of an HTTP dump.
    /// `Cookie:` inside JSON or another header is not a match: that would
    /// swallow the rest of a curl `--data-raw` body. An empty `Cookie:` is
    /// still a header — returning the word `Cookie:` as the value would send
    /// a name with no pair.
    private static func cookieFromBareHeaderLine(_ text: String) -> (found: Bool, value: String?) {
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let range = trimmed.range(of: "Cookie:", options: .caseInsensitive) else { continue }
            let prefix = trimmed[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            guard prefix.isEmpty else { continue }
            let value = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return (true, value.isEmpty ? nil : String(value))
        }
        return (false, nil)
    }

    private static func cookieValue(fromHeaderArgument argument: String) -> String? {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: "Cookie:", options: .caseInsensitive) else { return nil }
        let prefix = trimmed[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        guard prefix.isEmpty else { return nil }
        let value = trimmed[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : String(value)
    }

    /// `name=value` is a cookie. A path is a cookie *file* — Chrome and Safari
    /// keep those as SQLite / binarycookies, and opening one is a browser-store
    /// read. Relative names without `=` are still not a header; skip them.
    private static func cookieString(fromCookieFlag argument: String?) -> String? {
        guard let argument else { return nil }
        let value = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.contains("=") else { return nil }
        if looksLikeCookieStorePath(value) { return nil }
        return value
    }

    private static func looksLikeCookieStorePath(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("cookies.sqlite")
            || lower.contains("cookies.binarycookies")
            || lower.contains("/chrome/")
            || lower.contains("/chromium/")
            || lower.contains("/safari/")
            || lower.hasSuffix("/cookies")
            || lower.contains("/cookies/")
    }

    private struct CurlFlag {
        let name: String
        let argument: String?
        let end: String.Index
    }

    private static func nextFlag(in text: String, from start: String.Index) -> CurlFlag? {
        var index = start
        var atTokenStart = start == text.startIndex
            || text[text.index(before: start)].isWhitespace
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace {
                atTokenStart = true
                index = text.index(after: index)
                continue
            }
            if atTokenStart, character == "-" {
                return parseFlag(in: text, from: index)
            }
            if character == "'" || character == "\"" {
                let content = text.index(after: index)
                if let close = text[content...].firstIndex(of: character) {
                    index = text.index(after: close)
                } else {
                    return nil
                }
                atTokenStart = false
                continue
            }
            atTokenStart = false
            index = text.index(after: index)
        }
        return nil
    }

    private static func parseFlag(in text: String, from start: String.Index) -> CurlFlag? {
        guard start < text.endIndex, text[start] == "-" else { return nil }
        var index = text.index(after: start)
        guard index < text.endIndex else { return nil }

        let name: String
        if text[index] == "-" {
            index = text.index(after: index)
            while index < text.endIndex, !text[index].isWhitespace, text[index] != "=" {
                index = text.index(after: index)
            }
            name = String(text[start..<index])
            if index < text.endIndex, text[index] == "=" {
                index = text.index(after: index)
                let argument = parseArgument(in: text, from: index)
                return CurlFlag(name: name, argument: argument.value, end: argument.end)
            }
        } else {
            name = String(text[start...index])
            index = text.index(after: index)
            if index < text.endIndex, !text[index].isWhitespace, text[index] != "-" {
                let argument = parseArgument(in: text, from: index)
                return CurlFlag(name: name, argument: argument.value, end: argument.end)
            }
        }

        index = skipSpaces(in: text, from: index)
        if index < text.endIndex, text[index] != "-" {
            let argument = parseArgument(in: text, from: index)
            return CurlFlag(name: name, argument: argument.value, end: argument.end)
        }
        return CurlFlag(name: name, argument: nil, end: index)
    }

    private static func parseArgument(in text: String, from start: String.Index) -> (value: String, end: String.Index) {
        var index = start
        if index < text.endIndex, text[index] == "$" {
            let next = text.index(after: index)
            if next < text.endIndex, text[next] == "'" || text[next] == "\"" {
                index = next
            }
        }
        guard index < text.endIndex else { return ("", index) }

        let quote = text[index]
        if quote == "'" || quote == "\"" {
            let content = text.index(after: index)
            if let close = text[content...].firstIndex(of: quote) {
                return (String(text[content..<close]), text.index(after: close))
            }
            // Unclosed quote: rest of this line only, never the whole command.
            var end = content
            while end < text.endIndex, !text[end].isNewline {
                end = text.index(after: end)
            }
            return (String(text[content..<end]), end)
        }

        var end = index
        while end < text.endIndex {
            if text[end].isNewline { break }
            if text[end].isWhitespace {
                let next = text.index(after: end)
                if next < text.endIndex, text[next] == "-" { break }
            }
            end = text.index(after: end)
        }
        return (String(text[index..<end]), end)
    }

    private static func skipSpaces(in text: String, from start: String.Index) -> String.Index {
        var index = start
        while index < text.endIndex {
            if text[index] == "\\" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next].isNewline {
                    index = text.index(after: next)
                    continue
                }
            }
            if text[index].isWhitespace, !text[index].isNewline {
                index = text.index(after: index)
                continue
            }
            break
        }
        return index
    }

    private static func looksLikeCurl(_ text: String) -> Bool {
        let lower = text.lowercased()
        if hasToken(lower, "-h") || hasToken(lower, "--header")
            || hasToken(lower, "-b") || hasToken(lower, "--cookie") {
            return true
        }
        return text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .contains { lineLooksLikeCurlCommand($0) }
    }

    /// `$ curl …` and `/usr/bin/curl …` are still curl. A cookie pair that
    /// happens to mention the word must not be.
    private static func lineLooksLikeCurlCommand(_ line: Substring) -> Bool {
        let lower = line.lowercased()
        guard let range = lower.range(of: "curl") else { return false }
        let after = lower[range.upperBound...]
        let afterOK = after.isEmpty
            || after.first!.isWhitespace
            || after.hasPrefix("-")
            || after.hasPrefix(".exe")
        guard afterOK else { return false }
        let before = lower[..<range.lowerBound]
        guard let last = before.last(where: { !$0.isWhitespace }) else { return true }
        return last == "/" || last == "$" || last == "%" || last == ">" || last == "#"
    }

    private static func hasToken(_ text: String, _ token: String) -> Bool {
        var search = text.startIndex
        while let range = text.range(of: token, range: search..<text.endIndex) {
            let beforeOK = range.lowerBound == text.startIndex
                || text[text.index(before: range.lowerBound)].isWhitespace
            let after: Character? = range.upperBound < text.endIndex ? text[range.upperBound] : nil
            let afterOK = after == nil || after!.isWhitespace || after == "=" || after == "'" || after == "\""
            if beforeOK, afterOK { return true }
            search = range.upperBound
        }
        return false
    }

    /// Non-empty after trim: an empty key is worse than a missing one, it is
    /// a request that cannot succeed being sent all the same.
    private static func nonEmpty(_ value: String?) -> String? {
        value.flatMap { trimmed in
            let text = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }
}
