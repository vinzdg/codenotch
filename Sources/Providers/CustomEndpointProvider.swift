import Foundation

/// Refuses to carry the key across a redirect.
///
/// The endpoint's address comes from the user, but where it *redirects* to does
/// not. Following a 302 with `URLSession`'s default policy re-sends every header,
/// so a hostile or merely misconfigured endpoint could hand the key to another
/// host. There is nothing a usage probe needs from a redirect, so it stops.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
public enum CustomEndpointDetectionResult: Equatable, Sendable {
    case matched(CustomEndpointUsagePreset)
    case needsAuth
    case unavailable
    case unsupported
}

public actor CustomEndpointNetwork {
    public static let shared = CustomEndpointNetwork()

    private let noRedirects = NoRedirects()
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    private enum RawHTTPResult {
        case success(Data)
        case needsAuth
        case notFound
        case unavailable
    }

    private func requestRaw(url: URL, apiKey: String, headerKey: String) async -> RawHTTPResult {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 6
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            let header = headerKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if header.lowercased() == "authorization" && !key.lowercased().hasPrefix("bearer ") {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            } else {
                request.setValue(key, forHTTPHeaderField: header.isEmpty ? "Authorization" : header)
            }
        }
        do {
            let (data, response) = try await session.data(for: request, delegate: noRedirects)
            guard let http = response as? HTTPURLResponse else {
                return .unavailable
            }
            switch http.statusCode {
            case 200...299:
                return .success(data)
            case 401, 403:
                return .needsAuth
            case 404:
                return .notFound
            default:
                return .unavailable
            }
        } catch {
            return .unavailable
        }
    }

    private func presetResponse(url: URL, apiKey: String, headerKey: String) async throws -> Data {
        let result = await requestRaw(url: url, apiKey: apiKey, headerKey: headerKey)
        switch result {
        case .success(let data):
            return data
        case .needsAuth:
            throw UsageProviderError.needsAuth
        case .notFound:
            throw UsageProviderError.badResponse(status: 404)
        case .unavailable:
            throw UsageProviderError.badResponse(status: 503)
        }
    }

    func fetchPresetUsage(
        _ preset: CustomEndpointUsagePreset,
        baseURL: String,
        apiKey: String,
        headerKey: String
    ) async throws -> CustomEndpointPresetReading {
        guard let url = CustomEndpointPresetUsage.presetURL(preset, baseURL: baseURL) else {
            throw UsageProviderError.badResponse(status: 400)
        }
        let data = try await presetResponse(url: url, apiKey: apiKey, headerKey: headerKey)
        guard let reading = CustomEndpointPresetUsage.parsePreset(preset, data: data) else {
            throw UsageProviderError.badResponse(status: 503)
        }
        return reading
    }

    func detectPreset(
        baseURL: String,
        apiKey: String,
        headerKey: String
    ) async -> CustomEndpointDetectionResult {
        // Validate base URL first; never probe a base with userinfo, query, or fragment
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseComponents = URLComponents(string: trimmed),
              let scheme = baseComponents.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = baseComponents.host, !host.isEmpty,
              baseComponents.user == nil, baseComponents.password == nil,
              baseComponents.query == nil, baseComponents.fragment == nil else {
            return .unsupported
        }

        // Candidate endpoints: OpenRouter (/api/v1/key if canonical), /metrics, New-API (/api/usage/token), LiteLLM (/key/info)
        enum ProbeTarget: Hashable {
            case openRouter(URL)
            case metrics(URL)
            case newAPI(URL)
            case liteLLM(URL)
            case abacus(URL)
        }

        var targets: [ProbeTarget] = []
        if let abacusURL = CustomEndpointPresetUsage.presetURL(.abacus, baseURL: baseURL) {
            targets.append(.abacus(abacusURL))
        }
        if let openRouterURL = CustomEndpointPresetUsage.presetURL(.openRouter, baseURL: baseURL) {
            targets.append(.openRouter(openRouterURL))
        }
        if let metricsURL = CustomEndpointPresetUsage.presetURL(.vllm, baseURL: baseURL) {
            targets.append(.metrics(metricsURL))
        }
        if let newAPIURL = CustomEndpointPresetUsage.presetURL(.newAPI, baseURL: baseURL) {
            targets.append(.newAPI(newAPIURL))
        }
        if let liteLLMURL = CustomEndpointPresetUsage.presetURL(.litellm, baseURL: baseURL) {
            targets.append(.liteLLM(liteLLMURL))
        }

        if targets.isEmpty {
            return .unsupported
        }

        var results: [ProbeTarget: RawHTTPResult] = [:]
        await withTaskGroup(of: (ProbeTarget, RawHTTPResult).self) { group in
            for target in targets {
                let targetURL: URL
                switch target {
                case .openRouter(let url), .metrics(let url), .newAPI(let url), .liteLLM(let url), .abacus(let url):
                    targetURL = url
                }
                group.addTask {
                    if Task.isCancelled { return (target, .unavailable) }
                    let res = await self.requestRaw(url: targetURL, apiKey: apiKey, headerKey: headerKey)
                    return (target, res)
                }
            }
            for await (target, res) in group {
                results[target] = res
            }
        }

        if Task.isCancelled {
            return .unavailable
        }

        if let abacusTarget = targets.first(where: { if case .abacus = $0 { return true }; return false }),
           let res = results[abacusTarget],
           case .success(let data) = res,
           CustomEndpointPresetUsage.parsePreset(.abacus, data: data) != nil {
            return .matched(.abacus)
        }

        // Evaluate in priority order: OpenRouter, vLLM, llamaCpp, New-API, LiteLLM
        if let openRouterTarget = targets.first(where: { if case .openRouter = $0 { return true }; return false }),
           let res = results[openRouterTarget] {
            if case .success(let data) = res, CustomEndpointPresetUsage.parsePreset(.openRouter, data: data) != nil {
                return .matched(.openRouter)
            }
        }

        if let metricsTarget = targets.first(where: { if case .metrics = $0 { return true }; return false }),
           let res = results[metricsTarget] {
            if case .success(let data) = res {
                if CustomEndpointPresetUsage.parsePreset(.vllm, data: data) != nil {
                    return .matched(.vllm)
                }
                if CustomEndpointPresetUsage.parsePreset(.llamaCpp, data: data) != nil {
                    return .matched(.llamaCpp)
                }
            }
        }

        if let newAPITarget = targets.first(where: { if case .newAPI = $0 { return true }; return false }),
           let res = results[newAPITarget] {
            if case .success(let data) = res, CustomEndpointPresetUsage.parsePreset(.newAPI, data: data) != nil {
                return .matched(.newAPI)
            }
        }

        if let liteLLMTarget = targets.first(where: { if case .liteLLM = $0 { return true }; return false }),
           let res = results[liteLLMTarget] {
            if case .success(let data) = res, CustomEndpointPresetUsage.parsePreset(.litellm, data: data) != nil {
                return .matched(.litellm)
            }
        }

        // No match found. Classify:
        // 1. Any 401/403 -> .needsAuth
        // 2. Any transport failure, redirect, or non-404 non-2xx -> .unavailable
        // 3. Otherwise (all 404 or malformed 2xx) -> .unsupported
        var hasNeedsAuth = false
        var hasUnavailable = false
        for res in results.values {
            switch res {
            case .needsAuth:
                hasNeedsAuth = true
            case .unavailable:
                hasUnavailable = true
            case .notFound, .success:
                break
            }
        }

        if hasNeedsAuth {
            return .needsAuth
        }
        if hasUnavailable {
            return .unavailable
        }
        return .unsupported
    }

    /// What a plausible `/models` reply holds. Anything past this is not a list
    /// someone is going to pick from.
    static let maxModels = 200
    static let maxModelIDLength = 200

    public func testEndpoint(
        baseURL: String,
        apiKey: String,
        headerKey: String = "Authorization"
    ) async -> (health: CustomEndpointHealth, latencyMs: Int, models: [String], error: String?) {
        guard CustomEndpoint.isValidURL(baseURL), let url = URL(string: baseURL) else {
            return (.unreachable, 0, [], L10n.t("The address must start with http:// or https://"))
        }

        let modelsURL: URL
        if baseURL.hasSuffix("/models") {
            modelsURL = url
        } else if baseURL.hasSuffix("/") {
            modelsURL = url.appendingPathComponent("models")
        } else {
            modelsURL = url.appendingPathComponent("models")
        }

        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 6.0

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            let header = headerKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if header.lowercased() == "authorization" && !trimmedKey.lowercased().hasPrefix("bearer ") {
                request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
            } else {
                request.setValue(trimmedKey, forHTTPHeaderField: header.isEmpty ? "Authorization" : header)
            }
        }

        let start = DispatchTime.now()
        do {
            let (data, response) = try await URLSession.shared.data(for: request, delegate: noRedirects)
            let elapsedNano = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            let latencyMs = max(1, Int(elapsedNano / 1_000_000))

            guard let httpResponse = response as? HTTPURLResponse else {
                return (.unreachable, latencyMs, [], L10n.t("Not an HTTP endpoint"))
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                return (.unreachable, latencyMs, [], L10n.t("The endpoint answered \(httpResponse.statusCode)"))
            }

            // Parse models from {"data": [{"id": "model-name"}]} or {"models": [...]}
            var discoveredModels: [String] = []
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let list = json["data"] as? [[String: Any]] {
                    discoveredModels = list.compactMap { $0["id"] as? String }.sorted()
                } else if let list = json["models"] as? [[String: Any]] {
                    discoveredModels = list.compactMap { ($0["name"] as? String) ?? ($0["id"] as? String) }.sorted()
                }
            }

            let health: CustomEndpointHealth = latencyMs > 800 ? .slow : .online
            // Bounded before it is stored: this list is JSON-encoded into the
            // defaults plist and decoded again on every provider property access,
            // so an endpoint answering with a hundred thousand ids would bloat the
            // plist and stall the picker. No real endpoint lists more than a few.
            let bounded = discoveredModels
                .filter { !$0.isEmpty && $0.count <= Self.maxModelIDLength }
                .prefix(Self.maxModels)
            return (health, latencyMs, Array(bounded), nil)
        } catch {
            let elapsedNano = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            let latencyMs = Int(elapsedNano / 1_000_000)
            // The code, never the endpoint's own words. A URLError's description can
            // carry the host and path, and this string is shown in Settings and kept
            // in the endpoint's saved health. The kind of failure is what helps.
            let reason = (error as? URLError)?.code == .timedOut
                ? L10n.t("The endpoint did not answer in time")
                : L10n.t("Could not reach the endpoint")
            return (.unreachable, latencyMs, [], reason)
        }
    }

    public func fetchJSONUsage(
        usageURL: String,
        apiKey: String,
        headerKey: String,
        recordsPath: String,
        modelField: String,
        tokenField: String,
        modelFilter: String?
    ) async throws -> Double {
        guard let url = URL(string: usageURL), CustomEndpoint.isValidURL(usageURL) else {
            throw UsageProviderError.badResponse(status: 400)
        }
        let data = try await presetResponse(url: url, apiKey: apiKey, headerKey: headerKey)
        guard let tokens = Self.parseJSONUsage(
            data: data,
            recordsPath: recordsPath,
            modelField: modelField,
            tokenField: tokenField,
            modelFilter: modelFilter
        ) else {
            throw UsageProviderError.badResponse(status: 503)
        }
        return tokens
    }

    static func parseJSONUsage(
        data: Data,
        recordsPath: String,
        modelField: String,
        tokenField: String,
        modelFilter: String?
    ) -> Double? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let recordsVal = recordsPath.isEmpty ? root : value(at: recordsPath, in: root)
        guard let records = recordsVal as? [[String: Any]] else { return nil }
        if records.isEmpty {
            return 0.0
        }
        let selected = records.filter { record in
            guard let modelFilter, !modelFilter.isEmpty else { return true }
            return (value(at: modelField, in: record) as? String) == modelFilter
        }
        guard !selected.isEmpty else { return nil }
        var totalTokens: Double = 0.0
        for record in selected {
            guard let rawVal = value(at: tokenField, in: record) else { return nil }
            // Reject booleans (which are NSNumbers in Objective-C runtime bridge)
            if let num = rawVal as? NSNumber {
                if CFGetTypeID(num) == CFBooleanGetTypeID() {
                    return nil
                }
                let d = num.doubleValue
                guard d.isFinite, d >= 0 else { return nil }
                totalTokens += d
            } else {
                return nil
            }
        }
        return totalTokens / 1_000_000
    }

    private static func value(at path: String, in root: Any) -> Any? {
        if path.isEmpty { return root }
        return path.split(separator: ".").reduce(root) { value, component in
            if let object = value as? [String: Any] {
                return object[String(component)]
            }
            if let array = value as? [Any], let index = Int(component), array.indices.contains(index) {
                return array[index]
            }
            return nil
        }
    }

    public func scanCommonLocalPorts() async -> [CustomEndpointPreset] {
        let candidates: [(name: String, port: Int, defaultModel: String, glyph: String, color: String)] = [
            ("Local vLLM", 8000, "", "ollama", "#10B981"),
            ("Local llama.cpp", 8080, "", "lmstudio", "#8B5CF6"),
            ("Local LM Studio / Proxy", 1234, "", "lmstudio", "#8B5CF6"),
            ("Local Ollama", 11434, "", "ollama-local", "#14B8A6"),
            ("Local AI Server", 5000, "", "openai", "#3B82F6")
        ]

        var found: [CustomEndpointPreset] = []
        await withTaskGroup(of: CustomEndpointPreset?.self) { group in
            for candidate in candidates {
                group.addTask {
                    let baseURL = "http://localhost:\(candidate.port)/v1"
                    guard let url = URL(string: "\(baseURL)/models") else { return nil }
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 1.2
                    guard let (_, res) = try? await URLSession.shared.data(for: req),
                          let http = res as? HTTPURLResponse,
                          (200...299).contains(http.statusCode) else {
                        return nil
                    }
                    return CustomEndpointPreset(
                        id: "detected-\(candidate.port)",
                        name: "\(candidate.name) (:\(candidate.port))",
                        baseURL: baseURL,
                        headerKey: "Authorization",
                        defaultModel: candidate.defaultModel,
                        iconPreset: candidate.glyph,
                        accentColorHex: candidate.color
                    )
                }
            }
            for await preset in group {
                if let preset {
                    found.append(preset)
                }
            }
        }
        return found.sorted { $0.name < $1.name }
    }
}

actor CustomEndpointProvider: UsageProvider {
    nonisolated let id: String
    private let endpointID: String
    private let session: URLSession
    private let network: CustomEndpointNetwork
    private let endpointLoader: @Sendable (String) -> CustomEndpoint?

    init(
        endpoint: CustomEndpoint,
        session: URLSession = .shared,
        network: CustomEndpointNetwork = .shared,
        endpointLoader: @escaping @Sendable (String) -> CustomEndpoint? = { CustomEndpointProvider.storedEndpoint(id: $0) }
    ) {
        self.endpointID = endpoint.id
        self.id = endpoint.providerID
        self.session = session
        self.network = network
        self.endpointLoader = endpointLoader
    }

    nonisolated static func storedEndpoint(id: String) -> CustomEndpoint? {
        Preferences.storedCustomEndpoints().first(where: { $0.id == id })
    }

    nonisolated var glyph: ProviderGlyph {
        if let current = Self.storedEndpoint(id: endpointID),
           let iconPreset = current.iconPreset,
           let presetGlyph = ProviderGlyph(rawValue: iconPreset) {
            return presetGlyph
        }
        return .openai
    }

    nonisolated var displayName: String {
        Self.storedEndpoint(id: endpointID)?.name ?? L10n.t("Custom Endpoint")
    }

    nonisolated var customIconFilename: String? {
        Self.storedEndpoint(id: endpointID)?.customIconFilename
    }

    nonisolated var isVisibleWhenAbsent: Bool { false }

    nonisolated func account() -> ProviderAccount? {
        guard let current = Self.storedEndpoint(id: endpointID) else { return nil }
        let modelSummary = current.selectedModel.isEmpty ? current.baseURL : current.selectedModel

        // Only use manageURL for strictly https schemes to prevent launching arbitrary schemes
        var safeManageURL: URL? = nil
        if let url = URL(string: current.baseURL), url.scheme?.lowercased() == "https" {
            safeManageURL = url
        }

        return ProviderAccount(
            label: current.name,
            plan: modelSummary,
            source: L10n.t("Custom Endpoint"),
            manageURL: safeManageURL
        )
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance(L10n.t("Configure endpoint details and credentials in Settings."))
    }

    func signOut() async {
        if let current = Self.storedEndpoint(id: endpointID) {
            current.deleteAPIKey()
        }
    }

    nonisolated func presentSignIn() {}

    nonisolated func forgetCachedCredential() {}

    private static func usageDayKey(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    private static func nextMonthlyResetDate() -> Date {
        let calendar = Calendar.current
        let now = Date()
        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: now),
              let startOfNextMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: nextMonth)) else {
            return now.addingTimeInterval(30 * 86400)
        }
        return startOfNextMonth
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        guard var current = endpointLoader(endpointID) else {
            throw UsageProviderError.needsAuth
        }
        guard current.isEnabled else {
            throw UsageProviderError.needsAuth
        }
        guard CustomEndpoint.isValidURL(current.baseURL) else {
            throw UsageProviderError.badResponse(status: 400)
        }
        if current.usageSource == .jsonEndpoint, let preset = current.usagePreset {
            let key = current.usageAuthentication == .apiKey ? (current.apiKey ?? "") : ""
            let reading = try await network.fetchPresetUsage(
                preset, baseURL: current.baseURL, apiKey: key, headerKey: current.headerKey
            )
            let window: LimitWindow
            switch reading {
            case .tokens(let tokens):
                let text = tokens > 0 && tokens < 1_000
                    ? "\(tokens)"
                    : CustomEndpoint.formatTokenMillions(Double(tokens) / 1_000_000)
                window = LimitWindow(
                    id: "preset-tokens", label: L10n.t("Tokens Since Server Start"),
                    usedText: text, detail: String(format: L10n.t("%@ tokens"), text),
                    prefersUsedText: true
                )
            case .spendUSD(let amount, let period):
                let text = String(format: "$%.2f", amount)
                window = LimitWindow(
                    id: "preset-spend",
                    label: L10n.t(period == .month ? "Spend This Month" : "Total Spend"),
                    usedText: text, detail: text, prefersUsedText: true
                )
            case .quota(let used, let granted):
                let text = "\(used)"
                let fraction = granted.flatMap { $0 > 0 ? Double(used) / Double($0) : nil }
                window = LimitWindow(
                    id: "preset-quota", label: L10n.t("Quota Used"),
                    usedFraction: fraction, usedText: text,
                    detail: granted.flatMap { $0 > 0 ? "\(used) / \($0)" : nil } ?? text,
                    prefersUsedText: true
                )
            case .credits(let left, let monthly, let total):
                // The ring tracks the monthly allowance; credits bought on top
                // are reported beside it rather than folded into the plan.
                let usedOfMonthly = max(0, monthly - min(left, monthly))
                let fmt = CustomEndpointPresetUsage.formatCredits
                let leftText = String(format: L10n.t("%@ left"), fmt(left))
                let extra = total - monthly
                let detail = extra >= 1
                    ? String(format: L10n.t("%@ credits left · %@ monthly + %@ extra"),
                             fmt(left), fmt(monthly), fmt(extra))
                    : String(format: L10n.t("%@ of %@ monthly credits left"), fmt(left), fmt(monthly))
                window = LimitWindow(
                    id: "preset-credits", label: L10n.t("Credits"),
                    usedFraction: min(max(usedOfMonthly / monthly, 0), 1),
                    usedText: leftText, detail: detail,
                    prefersUsedText: true
                )
            }
            var snapshot = ProviderSnapshot(
                id: id, displayName: current.name,
                glyph: current.iconPreset.flatMap(ProviderGlyph.init(rawValue:)) ?? .openai,
                fidelity: .official, status: .ok, windows: [window],
                headlineID: window.id, weeklyID: nil, block: nil, kind: .usage
            )
            snapshot.customIconFilename = current.customIconFilename
            return snapshot
        }

        let needsUsageKey = current.usageSource != .jsonEndpoint
            || current.usageAuthentication == .apiKey
        let apiKey = needsUsageKey ? (current.apiKey ?? "") : ""
        var usageTokens: Double?
        if current.usageSource == .jsonEndpoint,
           current.trackingUnit == .tokens,
           let usageURL = current.usageURL,
           let recordsPath = current.usageRecordsPath,
           let modelField = current.usageModelField,
           let tokenField = current.usageTokenField {
            usageTokens = try await CustomEndpointNetwork.shared.fetchJSONUsage(
                usageURL: usageURL,
                apiKey: apiKey,
                headerKey: current.headerKey,
                recordsPath: recordsPath,
                modelField: modelField,
                tokenField: tokenField,
                modelFilter: current.usageModelFilter
            )
        }

        // Live network probe to verify reachability and authentication
        let probe = await CustomEndpointNetwork.shared.testEndpoint(
            baseURL: current.baseURL,
            apiKey: apiKey,
            headerKey: current.headerKey
        )

        if probe.health == .unreachable {
            if usageTokens != nil {
                // A public usage endpoint is enough to populate this provider.
            } else if let err = probe.error, err.contains("401") || err.contains("403") {
                throw UsageProviderError.needsAuth
            } else {
                throw UsageProviderError.badResponse(status: 503)
            }
        }
        if let tokens = usageTokens {
            let totalTokens = max(0, Int((tokens * 1_000_000).rounded()))
            let day = Self.usageDayKey()
            var history = current.usageHistory.filter { $0.day != day }
            history.append(CustomEndpointUsageDay(day: day, totalTokens: totalTokens))
            current.usageHistory = Array(history.sorted { $0.day < $1.day }.suffix(31))
            current.currentTokensUsedM = tokens
            Preferences.updateStoredCustomEndpoint(current)
        }

        var windows: [LimitWindow] = []

        switch current.trackingUnit {
        case .currency:
            let spend = current.computedSpendUSD
            let budget = current.monthlyBudgetUSD

            if let budget = budget, budget > 0 {
                let remaining = max(0.0, budget - spend)
                let isRemaining = current.displayRemaining
                let displayFraction = isRemaining ? current.remainingFraction : current.usedFraction
                let usedFormatted = String(format: "$%.2f", isRemaining ? remaining : spend)
                let budgetFormatted = String(format: "$%.2f", budget)
                let detailText = isRemaining
                    ? String(format: L10n.t("%@ / %@ remaining"), usedFormatted, budgetFormatted)
                    : "\(usedFormatted) / \(budgetFormatted)"
                let label = isRemaining ? L10n.t("Remaining Budget") : L10n.t("Monthly Budget")

                // Exhaustion band is based on spend fraction so 100% remaining is ample
                let spendFraction = min(max(spend / budget, 0.0), 1.0)
                let bandOverride = isRemaining ? UsageBand.band(for: spendFraction) : nil

                windows.append(
                    LimitWindow(
                        id: "monthly-budget",
                        group: nil,
                        label: label,
                        usedFraction: displayFraction,
                        remaining: nil,
                        used: nil,
                        usedText: usedFormatted,
                        detail: detailText,
                        resetsAt: Self.nextMonthlyResetDate(),
                        duration: 30 * 86400,
                        bandOverride: bandOverride,
                        prefersUsedText: current.showCurrency
                    )
                )
            } else {
                let usedFormatted = String(format: "$%.2f", spend)
                windows.append(
                    LimitWindow(
                        id: "spend-tracking",
                        group: nil,
                        label: L10n.t("Total Spend"),
                        usedFraction: nil,
                        remaining: nil,
                        used: nil,
                        usedText: usedFormatted,
                        detail: usedFormatted,
                        resetsAt: nil,
                        duration: nil,
                        prefersUsedText: true
                    )
                )
            }

        case .tokens:
            let tokensUsed = current.computedTokensUsedM
            let budget = current.monthlyBudgetTokensM

            if let budget = budget, budget > 0 {
                let remaining = max(0.0, budget - tokensUsed)
                let isRemaining = current.displayRemaining
                let displayFraction = isRemaining ? current.remainingFraction : current.usedFraction
                let usedFormatted = CustomEndpoint.formatTokenMillions(isRemaining ? remaining : tokensUsed)
                let budgetFormatted = CustomEndpoint.formatTokenMillions(budget)
                let detailText = isRemaining
                    ? String(format: L10n.t("%@ / %@ tokens remaining"), usedFormatted, budgetFormatted)
                    : String(format: L10n.t("%@ / %@ tokens"), usedFormatted, budgetFormatted)
                let label = isRemaining ? L10n.t("Remaining Tokens") : L10n.t("Monthly Tokens")

                let tokensFraction = min(max(tokensUsed / budget, 0.0), 1.0)
                let bandOverride = isRemaining ? UsageBand.band(for: tokensFraction) : nil

                windows.append(
                    LimitWindow(
                        id: "token-budget",
                        group: nil,
                        label: label,
                        usedFraction: displayFraction,
                        remaining: nil,
                        used: nil,
                        usedText: usedFormatted,
                        detail: detailText,
                        resetsAt: Self.nextMonthlyResetDate(),
                        duration: 30 * 86400,
                        bandOverride: bandOverride,
                        prefersUsedText: current.showCurrency
                    )
                )
            } else {
                let usedFormatted = CustomEndpoint.formatTokenMillions(tokensUsed)
                let detailText = String(format: L10n.t("%@ tokens"), usedFormatted)
                windows.append(
                    LimitWindow(
                        id: "token-tracking",
                        group: nil,
                        label: L10n.t("Tokens Used"),
                        usedFraction: nil,
                        remaining: nil,
                        used: nil,
                        usedText: usedFormatted,
                        detail: detailText,
                        resetsAt: nil,
                        duration: nil,
                        prefersUsedText: true
                    )
                )
            }
        }

        let headlineID = windows.first?.id

        var snapshot = ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .derived,
            status: .ok,
            windows: windows,
            headlineID: headlineID,
            weeklyID: nil,
            block: nil,
            kind: .usage
        )
        snapshot.customIconFilename = current.customIconFilename
        snapshot.customUsageHistory = current.usageHistory.isEmpty ? nil : current.usageHistory
        return snapshot
    }
}
