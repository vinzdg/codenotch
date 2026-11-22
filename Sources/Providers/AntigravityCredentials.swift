import Foundation
import SQLite3
import os

/// The three flavors of Antigravity installations and tools.
enum AntigravityFlavor: String, CaseIterable, Sendable {
    case ide = "ide"
    case cli = "cli"
    case acp = "acp"

    var displayName: String {
        switch self {
        case .ide: return "Antigravity IDE"
        case .cli: return "Antigravity CLI"
        case .acp: return "Antigravity ACP"
        }
    }

    /// Isolated `antigravity-acp` data directories maintained by T3 Code under
    /// `~/.t3/userdata/providers/antigravity/<hash>/antigravity-acp`.
    static func t3ACPDataDirectories(home: URL = URL(fileURLWithPath: NSHomeDirectory()),
                                     fileManager: FileManager = .default) -> [URL] {
        let root = home
            .appendingPathComponent(".t3")
            .appendingPathComponent("userdata")
            .appendingPathComponent("providers")
            .appendingPathComponent("antigravity")
        let names = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        return names.sorted().compactMap { name in
            let dir = root.appendingPathComponent(name).appendingPathComponent("antigravity-acp")
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                return nil
            }
            return dir
        }
    }

    static func t3BrainDirectories(home: URL = URL(fileURLWithPath: NSHomeDirectory()),
                                   fileManager: FileManager = .default) -> [URL] {
        t3ACPDataDirectories(home: home, fileManager: fileManager)
            .map { $0.appendingPathComponent("brain") }
            .filter { fileManager.fileExists(atPath: $0.path) }
    }

    func brainDirectories(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> [URL] {
        let gemini = home.appendingPathComponent(".gemini")
        switch self {
        case .ide:
            return [
                gemini.appendingPathComponent("antigravity").appendingPathComponent("brain"),
                gemini.appendingPathComponent("antigravity-ide").appendingPathComponent("brain")
            ].filter { FileManager.default.fileExists(atPath: $0.path) }
        case .cli:
            return [
                gemini.appendingPathComponent("antigravity-cli").appendingPathComponent("brain")
            ].filter { FileManager.default.fileExists(atPath: $0.path) }
        case .acp:
            let standard = [
                gemini.appendingPathComponent("antigravity-acp").appendingPathComponent("brain")
            ].filter { FileManager.default.fileExists(atPath: $0.path) }
            return standard + Self.t3BrainDirectories(home: home)
        }
    }

    func lastActivityDate(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> Date? {
        let dirs = brainDirectories(home: home)
        let requestDates = dirs.compactMap { AntigravityActivity.read(root: $0).lastRequest }
        if let newestRequest = requestDates.max() {
            return newestRequest
        }
        let dirDates = dirs.compactMap { dir in
            (try? FileManager.default.attributesOfItem(atPath: dir.path))?[.modificationDate] as? Date
        }
        return dirDates.max()
    }

    static func runningFlavors(processTable: String? = nil) -> Set<AntigravityFlavor> {
        let table = processTable ?? AntigravityBridge.run("/bin/ps", ["-Ao", "pid,command"])
        var running: Set<AntigravityFlavor> = []
        for line in table.split(separator: "\n") {
            if AntigravityBridge.isIDE(line) { running.insert(.ide) }
            if AntigravityBridge.isCLI(line) { running.insert(.cli) }
            if AntigravityBridge.isACP(line) { running.insert(.acp) }
        }
        return running
    }

    /// Ranks candidates when one or more are active:
    /// 1. Live running process first
    /// 2. Most recently active (latest transcript activity date in brain/)
    /// 3. Deterministic tie-breaker: IDE > ACP > CLI
    static func rankCandidates(_ candidates: [FlavorCandidate]) -> [FlavorCandidate] {
        candidates.sorted { lhs, rhs in
            if lhs.isRunning != rhs.isRunning {
                return lhs.isRunning && !rhs.isRunning
            }
            if let lDate = lhs.lastActivity, let rDate = rhs.lastActivity {
                if lDate != rDate { return lDate > rDate }
            } else if lhs.lastActivity != nil {
                return true
            } else if rhs.lastActivity != nil {
                return false
            }
            let precedence: [AntigravityFlavor: Int] = [.ide: 0, .acp: 1, .cli: 2]
            return (precedence[lhs.flavor] ?? 99) < (precedence[rhs.flavor] ?? 99)
        }
    }
}

struct FlavorCandidate: Equatable, Sendable {
    let flavor: AntigravityFlavor
    let credentials: AntigravityCredentials?
    let isRunning: Bool
    let lastActivity: Date?
    let canProvideQuota: Bool
    let isActive: Bool

    init(flavor: AntigravityFlavor, credentials: AntigravityCredentials?,
         isRunning: Bool, lastActivity: Date?,
         canProvideQuota: Bool, isActive: Bool) {
        self.flavor = flavor
        self.credentials = credentials
        self.isRunning = isRunning
        self.lastActivity = lastActivity
        self.canProvideQuota = canProvideQuota
        self.isActive = isActive
    }
}

/// The OAuth token Antigravity holds for a Google account.
///
/// Borrowed, like every other credential here — Antigravity signs in, this only
/// reads what it stored.
struct AntigravityCredentials: Equatable {
    let accessToken: String
    let expiresAt: Date
    /// `consumer` for a personal Google account; enterprise installs differ.
    let authMethod: String
    let projectId: String?
    let email: String?
    let refreshToken: String?
    let clientID: String?
    let clientSecret: String?
    let tokenURI: String?
    let sourceName: String?

    init(accessToken: String, expiresAt: Date, authMethod: String = "consumer",
         projectId: String? = nil, email: String? = nil,
         refreshToken: String? = nil, clientID: String? = nil,
         clientSecret: String? = nil, tokenURI: String? = nil,
         sourceName: String? = nil) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.authMethod = authMethod
        self.projectId = projectId
        self.email = email
        self.refreshToken = refreshToken
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.tokenURI = tokenURI
        self.sourceName = sourceName
    }
    var isExpired: Bool { expiresAt <= Date() }

    static let service = "gemini"
    static let account = "antigravity"
    static let acpAccount = "antigravity-acp"

    /// Held until it expires, for the reason spelled out in `CredentialCache`.
    private static let cache = CredentialCache<AntigravityCredentials> { $0.isExpired }
    private static let profileCachesLock = NSLock()
    private static var profileCaches: [String: CredentialCache<AntigravityCredentials>] = [:]

    private static let flavorCachesLock = NSLock()
    private static var flavorCaches: [String: CredentialCache<AntigravityCredentials>] = [:]

    private static func cacheKey(for flavor: AntigravityFlavor, profile: AntigravityProfile) -> String {
        "\(profile.id):\(flavor.rawValue)"
    }

    static func cache(for flavor: AntigravityFlavor, profile: AntigravityProfile = .default()) -> CredentialCache<AntigravityCredentials> {
        let key = cacheKey(for: flavor, profile: profile)
        flavorCachesLock.lock()
        defer { flavorCachesLock.unlock() }
        if let existing = flavorCaches[key] {
            return existing
        }
        let newCache = CredentialCache<AntigravityCredentials> { $0.isExpired }
        flavorCaches[key] = newCache
        return newCache
    }

    private static func cache(for profile: AntigravityProfile) -> CredentialCache<AntigravityCredentials> {
        if profile.slug == nil { return cache }
        profileCachesLock.lock()
        defer { profileCachesLock.unlock() }
        if let existing = profileCaches[profile.id] {
            return existing
        }
        let newCache = CredentialCache<AntigravityCredentials> { $0.isExpired }
        profileCaches[profile.id] = newCache
        return newCache
    }

    static func forgetCached() {
        cache.forget()
        flavorCachesLock.lock()
        for c in flavorCaches.values { c.forget() }
        flavorCachesLock.unlock()
    }

    static func forgetCached(for profile: AntigravityProfile) {
        cache(for: profile).forget()
        flavorCachesLock.lock()
        for flavor in AntigravityFlavor.allCases {
            flavorCaches[cacheKey(for: flavor, profile: profile)]?.forget()
        }
        flavorCachesLock.unlock()
    }

    private static let profilePromptsLock = NSLock()
    private static var profilePrompts: [String: PromptPermission] = [:]

    private static func prompt(for profileID: String) -> PromptPermission {
        profilePromptsLock.lock()
        defer { profilePromptsLock.unlock() }
        if let existing = profilePrompts[profileID] {
            return existing
        }
        let newPrompt = PromptPermission()
        profilePrompts[profileID] = newPrompt
        return newPrompt
    }

    /// A person asked macOS for this login again: the next read may show the
    /// dialogue. `forgetCached` grants nothing, because it is not only a click.
    static func askAgain() {
        askAgain(for: .default())
    }

    static func askAgain(for profile: AntigravityProfile) {
        prompt(for: profile.id).grant()
        cache(for: profile).forget()
        for flavor in AntigravityFlavor.allCases {
            cache(for: flavor, profile: profile).forget()
        }
    }

    /// Stands in for the keychain in tests, which have none to read.
    nonisolated(unsafe) static var readKeychainForTesting: ((_ interactive: Bool) -> (OSStatus, Data?))?

    /// Whatever a previous fetch already read, without asking macOS again.
    static var held: AntigravityCredentials? { cache.held }

    static func held(for profile: AntigravityProfile) -> AntigravityCredentials? {
        cache(for: profile).held
    }

    static func held(for flavor: AntigravityFlavor, profile: AntigravityProfile = .default()) -> AntigravityCredentials? {
        cache(for: flavor, profile: profile).held
    }

    static func updateHeld(_ credentials: AntigravityCredentials, for profile: AntigravityProfile = .default()) {
        cache(for: profile).updateHeld(credentials)
        if profile.slug == nil {
            cache.updateHeld(credentials)
        }
    }

    static func updateHeld(_ credentials: AntigravityCredentials,
                           for flavor: AntigravityFlavor,
                           profile: AntigravityProfile = .default()) {
        cache(for: flavor, profile: profile).updateHeld(credentials)
        updateHeld(credentials, for: profile)
    }

    static func acpTokenURLs(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> [URL] {
        let acpDir = home.appendingPathComponent(".gemini/antigravity-acp")
        let standard = [
            acpDir.appendingPathComponent("acp_token.json"),
            acpDir.appendingPathComponent("antigravity-oauth-token")
        ]
        let t3 = AntigravityFlavor.t3ACPDataDirectories(home: home)
            .map { $0.appendingPathComponent("antigravity-oauth-token") }
        return standard + t3
    }

    static func cliTokenURLs(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> [URL] {
        let gemini = home.appendingPathComponent(".gemini")
        return [
            gemini.appendingPathComponent("antigravity-cli/antigravity-oauth-token"),
            gemini.appendingPathComponent("antigravity-cli/oauth_creds.json"),
            gemini.appendingPathComponent("oauth_creds.json")
        ]
    }

    private static func newestModificationDate(of urls: [URL]) -> Date? {
        urls.compactMap { url in
            (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }.max()
    }

    /// Whether Antigravity has filed a credential at all, judged from the
    /// item's attributes rather than its contents — those are not behind the
    /// access prompt the secret is, so this can be asked freely.
    static func isSignedIn(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> Bool {
        if KeychainItem.modifiedAt(service: service, account: account) != nil { return true }
        if KeychainItem.modifiedAt(service: service, account: acpAccount) != nil { return true }
        if acpTokenURLs(home: home).contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return true
        }
        if cliTokenURLs(home: home).contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return true
        }
        let ompDBPath = home.appendingPathComponent(".omp/agent/agent.db").path
        if FileManager.default.fileExists(atPath: ompDBPath) { return true }
        return false
    }

    static func hasCredential(for profile: AntigravityProfile) -> Bool {
        if profile.slug == nil { return isSignedIn() }
        if FileManager.default.fileExists(atPath: profile.authURL.path) { return true }
        let dbPath = profile.configDirectory.appendingPathComponent("agent.db").path
        if FileManager.default.fileExists(atPath: dbPath), readOMPCredentials(at: URL(fileURLWithPath: dbPath)) != nil {
            return true
        }
        return false
    }

    static func isSignedIn(for profile: AntigravityProfile) -> Bool {
        hasCredential(for: profile)
    }

    /// Antigravity stores through Go's `keyring` package, which base64-encodes
    /// the payload behind this marker rather than writing raw JSON the way
    /// Claude Code does. Decoding it is not optional: without stripping the
    /// prefix the value is not JSON at all.
    private static let goKeyringPrefix = "go-keyring-base64:"

    static func load() throws -> AntigravityCredentials {
        try load(for: .default())
    }

    static func load(for profile: AntigravityProfile) throws -> AntigravityCredentials {
        if profile.slug == nil {
            return try cache.value(
                itemModifiedAt: {
                    let keychainMod = KeychainItem.modifiedAt(service: service, account: account)
                    let acpKeychainMod = KeychainItem.modifiedAt(service: service, account: acpAccount)
                    let acpTokenMod = newestModificationDate(of: acpTokenURLs())
                    let cliTokenMod = newestModificationDate(of: cliTokenURLs())
                    let ompPath = ("~/.omp/agent/agent.db" as NSString).expandingTildeInPath
                    let ompMod = (try? FileManager.default.attributesOfItem(atPath: ompPath))?[.modificationDate] as? Date
                    return [keychainMod, acpKeychainMod, acpTokenMod, cliTokenMod, ompMod].compactMap { $0 }.max()
                },
                reload: { try read(for: profile) }
            )
        }
        return try cache(for: profile).value(
            itemModifiedAt: {
                let jsonMod = (try? FileManager.default.attributesOfItem(atPath: profile.authURL.path))?[.modificationDate] as? Date
                let agentDB = profile.configDirectory.appendingPathComponent("agent.db").path
                let dbMod = (try? FileManager.default.attributesOfItem(atPath: agentDB))?[.modificationDate] as? Date
                return [jsonMod, dbMod].compactMap { $0 }.max()
            },
            reload: { try read(for: profile) }
        )
    }

    static func load(for flavor: AntigravityFlavor,
                     profile: AntigravityProfile = .default()) throws -> AntigravityCredentials {
        try cache(for: flavor, profile: profile).value(
            itemModifiedAt: {
                modificationDate(for: flavor, profile: profile)
            },
            reload: {
                let interactive = prompt(for: profile.id).take()
                guard let creds = read(for: flavor, profile: profile, interactive: interactive) else {
                    throw UsageProviderError.needsAuth
                }
                return creds
            }
        )
    }

    static func modificationDate(for flavor: AntigravityFlavor,
                                 profile: AntigravityProfile = .default(),
                                 home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> Date? {
        switch flavor {
        case .ide:
            return KeychainItem.modifiedAt(service: service, account: account)
        case .cli:
            if profile.slug != nil {
                let jsonMod = (try? FileManager.default.attributesOfItem(atPath: profile.authURL.path))?[.modificationDate] as? Date
                let agentDB = profile.configDirectory.appendingPathComponent("agent.db").path
                let dbMod = (try? FileManager.default.attributesOfItem(atPath: agentDB))?[.modificationDate] as? Date
                return [jsonMod, dbMod].compactMap { $0 }.max()
            }
            let cliMod = newestModificationDate(of: cliTokenURLs(home: home))
            let ompPath = home.appendingPathComponent(".omp/agent/agent.db").path
            let ompMod = (try? FileManager.default.attributesOfItem(atPath: ompPath))?[.modificationDate] as? Date
            return [cliMod, ompMod].compactMap { $0 }.max()
        case .acp:
            let keychainMod = KeychainItem.modifiedAt(service: service, account: acpAccount)
            let tokenMod = newestModificationDate(of: acpTokenURLs(home: home))
            return [keychainMod, tokenMod].compactMap { $0 }.max()
        }
    }

    /// Read credentials specifically for a flavor.
    static func read(for flavor: AntigravityFlavor,
                     profile: AntigravityProfile = .default(),
                     interactive: Bool = false) -> AntigravityCredentials? {
        switch flavor {
        case .ide:
            return readIDECredentials(interactive: interactive)
        case .cli:
            return readCLICredentials(for: profile)
        case .acp:
            return readACPCredentials(interactive: interactive)
        }
    }

    /// Reads file-backed ACP/CLI credentials without touching the macOS Keychain,
    /// so Settings can recognise CLI/ACP logins before the first fetch without
    /// risking a keychain prompt.
    static func readFileBacked(for profile: AntigravityProfile = .default(),
                               home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> AntigravityCredentials? {
        if profile.slug != nil {
            return readCLICredentials(for: profile, home: home)
        }
        return readACPFileCredentials(home: home) ?? readCLICredentials(for: profile, home: home)
    }

    private static func readIDECredentials(interactive: Bool = false) -> AntigravityCredentials? {
        let (status, data) = readKeychainForTesting?(interactive) ?? KeychainSecret.read(
            query: [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecReturnData: true,
                kSecMatchLimit: kSecMatchLimitOne
            ],
            interactive: interactive,
            rescue: (service: service, account: account)
        )
        guard status == errSecSuccess, let data, let decoded = decode(data) else {
            return nil
        }
        return AntigravityCredentials(
            accessToken: decoded.accessToken,
            expiresAt: decoded.expiresAt,
            authMethod: decoded.authMethod,
            projectId: decoded.projectId,
            email: decoded.email,
            refreshToken: decoded.refreshToken,
            clientID: decoded.clientID,
            clientSecret: decoded.clientSecret,
            tokenURI: decoded.tokenURI,
            sourceName: "Antigravity IDE"
        )
    }

    static func readACPFileCredentials(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> AntigravityCredentials? {
        let candidates = acpTokenURLs(home: home)
            .compactMap { url -> (url: URL, modified: Date)? in
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                    return nil
                }
                return (url, (attrs[.modificationDate] as? Date) ?? .distantPast)
            }
            .sorted { $0.modified > $1.modified }

        for candidate in candidates {
            if let fileCreds = readJSONCredentials(at: candidate.url.path) {
                return AntigravityCredentials(
                    accessToken: fileCreds.accessToken,
                    expiresAt: fileCreds.expiresAt,
                    authMethod: fileCreds.authMethod,
                    projectId: fileCreds.projectId,
                    email: fileCreds.email,
                    refreshToken: fileCreds.refreshToken,
                    clientID: fileCreds.clientID,
                    clientSecret: fileCreds.clientSecret,
                    tokenURI: fileCreds.tokenURI,
                    sourceName: "Antigravity ACP"
                )
            }
        }
        return nil
    }

    private static func readACPCredentials(interactive: Bool = false,
                                           home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> AntigravityCredentials? {
        let (status, data) = (readKeychainForTesting != nil ? (errSecItemNotFound, nil as Data?) : KeychainSecret.read(
            query: [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: acpAccount,
                kSecReturnData: true,
                kSecMatchLimit: kSecMatchLimitOne
            ],
            interactive: interactive,
            rescue: (service: service, account: acpAccount)
        ))
        if status == errSecSuccess, let data, let decoded = decode(data) {
            return AntigravityCredentials(
                accessToken: decoded.accessToken,
                expiresAt: decoded.expiresAt,
                authMethod: decoded.authMethod,
                projectId: decoded.projectId,
                email: decoded.email,
                refreshToken: decoded.refreshToken,
                clientID: decoded.clientID,
                clientSecret: decoded.clientSecret,
                tokenURI: decoded.tokenURI,
                sourceName: "Antigravity ACP"
            )
        }

        return readACPFileCredentials(home: home)
    }

    private static func readCLICredentials(for profile: AntigravityProfile = .default(),
                                           home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> AntigravityCredentials? {
        if profile.slug != nil {
            if let creds = readJSONCredentials(at: profile.authURL.path) {
                return AntigravityCredentials(
                    accessToken: creds.accessToken,
                    expiresAt: creds.expiresAt,
                    authMethod: creds.authMethod,
                    projectId: creds.projectId,
                    email: creds.email,
                    refreshToken: creds.refreshToken,
                    clientID: creds.clientID,
                    clientSecret: creds.clientSecret,
                    tokenURI: creds.tokenURI,
                    sourceName: profile.sourceName
                )
            }
            let agentDB = profile.configDirectory.appendingPathComponent("agent.db")
            if let omp = readOMPCredentials(at: agentDB) {
                return AntigravityCredentials(
                    accessToken: omp.accessToken,
                    expiresAt: omp.expiresAt,
                    authMethod: omp.authMethod,
                    projectId: omp.projectId,
                    email: omp.email,
                    refreshToken: omp.refreshToken,
                    clientID: omp.clientID,
                    clientSecret: omp.clientSecret,
                    tokenURI: omp.tokenURI,
                    sourceName: profile.sourceName
                )
            }
            return nil
        }

        for url in cliTokenURLs(home: home) {
            if let creds = readJSONCredentials(at: url.path) {
                return AntigravityCredentials(
                    accessToken: creds.accessToken,
                    expiresAt: creds.expiresAt,
                    authMethod: creds.authMethod,
                    projectId: creds.projectId,
                    email: creds.email,
                    refreshToken: creds.refreshToken,
                    clientID: creds.clientID,
                    clientSecret: creds.clientSecret,
                    tokenURI: creds.tokenURI,
                    sourceName: "Antigravity CLI"
                )
            }
        }

        if let omp = readOMPCredentials(at: home.appendingPathComponent(".omp/agent/agent.db")) {
            return AntigravityCredentials(
                accessToken: omp.accessToken,
                expiresAt: omp.expiresAt,
                authMethod: omp.authMethod,
                projectId: omp.projectId,
                email: omp.email,
                refreshToken: omp.refreshToken,
                clientID: omp.clientID,
                clientSecret: omp.clientSecret,
                tokenURI: omp.tokenURI,
                sourceName: "Antigravity CLI"
            )
        }
        return nil
    }

    private static func read(for profile: AntigravityProfile) throws -> AntigravityCredentials {
        if profile.slug != nil {
            if let creds = readCLICredentials(for: profile) {
                return creds
            }
            Log.usage.error("antigravity credentials read failed for \(profile.id, privacy: .public)")
            throw UsageProviderError.needsAuth
        }

        let interactive = prompt(for: profile.id).take()
        let running = AntigravityFlavor.runningFlavors()
        var candidates: [FlavorCandidate] = []
        for flavor in AntigravityFlavor.allCases {
            let isRunning = running.contains(flavor)
            let creds = read(for: flavor, profile: profile, interactive: interactive)
            let lastActivity = flavor.lastActivityDate()
            let canProvide = isRunning || (creds != nil && (!creds!.isExpired || creds!.refreshToken != nil))
            let isActive = isRunning || (canProvide && (lastActivity != nil || (creds != nil && !creds!.isExpired)))
            candidates.append(FlavorCandidate(
                flavor: flavor,
                credentials: creds,
                isRunning: isRunning,
                lastActivity: lastActivity,
                canProvideQuota: canProvide,
                isActive: isActive
            ))
        }

        let active = candidates.filter { $0.isActive && $0.canProvideQuota }
        let ranked = AntigravityFlavor.rankCandidates(active.isEmpty ? candidates.filter { $0.credentials != nil } : active)

        if let chosen = ranked.first?.credentials {
            return chosen
        }

        if let ompCreds = readOMPCredentials() {
            return ompCreds
        }

        Log.usage.error("antigravity credentials read failed for \(profile.id, privacy: .public)")
        throw UsageProviderError.needsAuth
    }

    static func read() throws -> AntigravityCredentials {
        try read(for: .default())
    }

    /// Refreshes an expired or refresh-only credential using Google's OAuth token endpoint.
    static func refresh(credentials: AntigravityCredentials, session: URLSession = .shared) async throws -> AntigravityCredentials {
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty,
              let clientID = credentials.clientID, !clientID.isEmpty,
              let clientSecret = credentials.clientSecret, !clientSecret.isEmpty else {
            return credentials
        }

        let tokenURL = URL(string: credentials.tokenURI ?? "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParams = [
            "client_id": clientID,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        let bodyString = bodyParams.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }.joined(separator: "&")
        request.httpBody = Data(bodyString.utf8)
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UsageProviderError.credentialExpired
        }

        struct TokenResponse: Decodable {
            let access_token: String
            let expires_in: Double?
            let token_type: String?
            let id_token: String?
        }

        guard let tokenResp = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw UsageProviderError.badResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 200)
        }

        var email = credentials.email
        if email == nil, let idToken = tokenResp.id_token {
            email = parseEmail(fromIDToken: idToken)
        }

        let expiry = Date().addingTimeInterval(tokenResp.expires_in ?? 3600)
        return AntigravityCredentials(
            accessToken: tokenResp.access_token,
            expiresAt: expiry,
            authMethod: credentials.authMethod,
            projectId: credentials.projectId,
            email: email,
            refreshToken: credentials.refreshToken,
            clientID: credentials.clientID,
            clientSecret: credentials.clientSecret,
            tokenURI: credentials.tokenURI,
            sourceName: credentials.sourceName
        )
    }

    private static func readOMPCredentials(at dbURL: URL = URL(fileURLWithPath: ("~/.omp/agent/agent.db" as NSString).expandingTildeInPath)) -> AntigravityCredentials? {
        guard let db = SQLiteStore.open(dbURL) else { return nil }
        defer { sqlite3_close(db) }

        let sql = "SELECT data FROM auth_credentials WHERE provider = 'google-antigravity' ORDER BY updated_at DESC LIMIT 1;"
        let rows = SQLiteStore.rows(in: db, sql: sql)
        guard let first = rows.first, let data = first.data(using: .utf8) else { return nil }

        struct OMPPayload: Decodable {
            let access: String?
            let expires: Double?
            let projectId: String?
            let email: String?
        }

        guard let payload = try? JSONDecoder().decode(OMPPayload.self, from: data),
              let token = payload.access else { return nil }

        let expiry = payload.expires.map { Date(timeIntervalSince1970: $0 / 1000.0) } ?? Date.distantFuture
        return AntigravityCredentials(
            accessToken: token,
            expiresAt: expiry,
            authMethod: "consumer",
            projectId: payload.projectId,
            email: payload.email,
            sourceName: "Antigravity CLI"
        )
    }

    private static func readJSONCredentials(at path: String = ("~/.gemini/oauth_creds.json" as NSString).expandingTildeInPath) -> AntigravityCredentials? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return decode(data)
    }

    /// Split out so the decoding can be tested against a real stored value
    /// without a keychain.
    static func decode(_ data: Data) -> AntigravityCredentials? {
        if let acp = decodeACP(data) {
            return acp
        }

        struct Stored: Decodable {
            struct Token: Decodable {
                let access_token: String
                /// RFC 3339 with fractional seconds *and an offset* —
                /// "2026-08-31T21:53:49.575961+07:00". Not UTC, and not
                /// milliseconds since the epoch like Claude's. Parsing it as
                /// either is how a token that is live reads as long expired.
                let expiry: String
            }
            let auth_method: String
            let token: Token
            let id_token_email: String?
        }

        // File-backed `antigravity-oauth-token` writes this same envelope as
        // raw JSON, while Keychain stores it base64-encoded behind Go keyring's
        // prefix.
        let payload: Data
        if let rawStored = try? JSONDecoder().decode(Stored.self, from: data),
           let expiry = parse(rawStored.token.expiry) {
            return AntigravityCredentials(accessToken: rawStored.token.access_token,
                                          expiresAt: expiry,
                                          authMethod: rawStored.auth_method,
                                          email: rawStored.id_token_email)
        } else {
            guard var text = String(data: data, encoding: .utf8) else { return nil }
            if text.hasPrefix(goKeyringPrefix) {
                text = String(text.dropFirst(goKeyringPrefix.count))
            }
            guard let decoded = Data(base64Encoded: text) else { return nil }
            payload = decoded
        }

        guard let stored = try? JSONDecoder().decode(Stored.self, from: payload),
              let expiry = parse(stored.token.expiry)
        else { return nil }

        return AntigravityCredentials(accessToken: stored.token.access_token,
                                      expiresAt: expiry,
                                      authMethod: stored.auth_method,
                                      email: stored.id_token_email)
    }

    /// Decodes raw JSON credentials, such as those stored by Antigravity ACP or oauth_creds.json.
    static func decodeACP(_ data: Data) -> AntigravityCredentials? {
        struct ACPPayload: Decodable {
            let client_id: String?
            let client_secret: String?
            let refresh_token: String?
            let access_token: String?
            let token_uri: String?
            let project_id: String?
            let projectId: String?
            let email: String?
            let expiry_date: Double?
        }

        guard let payload = try? JSONDecoder().decode(ACPPayload.self, from: data) else {
            return nil
        }

        let isACP = payload.refresh_token != nil && (payload.client_id != nil || payload.token_uri != nil)
        let token = payload.access_token ?? ""

        guard isACP || !token.isEmpty else { return nil }

        let expiry = payload.expiry_date.map { Date(timeIntervalSince1970: $0 / 1000.0) }
            ?? (token.isEmpty ? Date.distantPast : Date.distantFuture)

        return AntigravityCredentials(
            accessToken: token,
            expiresAt: expiry,
            authMethod: "consumer",
            projectId: payload.projectId ?? payload.project_id,
            email: payload.email,
            refreshToken: payload.refresh_token,
            clientID: payload.client_id,
            clientSecret: payload.client_secret,
            tokenURI: payload.token_uri,
            sourceName: isACP ? "Antigravity (ACP)" : nil
        )
    }

    private static func parseEmail(fromIDToken idToken: String) -> String? {
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = json["email"] as? String else {
            return nil
        }
        return email
    }

    static func parse(_ value: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}
