import AppKit
import Foundation
import SwiftUI

public enum CustomEndpointHealth: String, Codable, Equatable, Sendable {
    case online
    case slow
    case unreachable
    case idle

    public var title: String {
        switch self {
        case .online: return L10n.t("Online")
        case .slow: return L10n.t("Slow")
        case .unreachable: return L10n.t("Unreachable")
        case .idle: return L10n.t("Not Checked")
        }
    }

    public var color: Color {
        switch self {
        case .online: return .green
        case .slow: return .yellow
        case .unreachable: return .red
        case .idle: return .secondary
        }
    }
}

public enum CustomEndpointTrackingUnit: String, Codable, CaseIterable, Sendable {
    case currency = "currency"
    case tokens = "tokens"
}

public enum CustomEndpointUsageSource: String, Codable, CaseIterable, Sendable {
    case manual = "manual"
    case jsonEndpoint = "jsonEndpoint"
}

public enum CustomEndpointUsageAuthentication: String, Codable, CaseIterable, Sendable {
    case apiKey = "apiKey"
    case none = "none"
}

public struct CustomEndpointUsageDay: Codable, Equatable, Sendable {
    public let day: String
    public let totalTokens: Int

    public init(day: String, totalTokens: Int) {
        self.day = day
        self.totalTokens = totalTokens
    }
}

public struct CustomEndpoint: Identifiable, Codable, Equatable, Sendable {
    public static let keychainService = "com.vinzdg.codenotch.custom-endpoint"

    public static func keychainAccount(for endpointID: String) -> String {
        "endpoint-\(endpointID)"
    }

    public static func isValidURL(_ string: String) -> Bool {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = url.host, !host.isEmpty else {
            return false
        }
        return true
    }

    public var id: String
    public var name: String
    public var baseURL: String
    public var headerKey: String
    public var selectedModel: String
    public var availableModels: [String]
    public var isEnabled: Bool
    public var accentColorHex: String
    public var iconPreset: String?
    /// Exact OpenCode provider key, set only when activity monitoring is enabled.
    public var openCodeProviderID: String?
    public var customIconFilename: String?
    public var usageSource: CustomEndpointUsageSource
    public var usagePreset: CustomEndpointUsagePreset?
    public var usageURL: String?
    public var usageRecordsPath: String?
    public var usageModelField: String?
    public var usageTokenField: String?
    public var usageModelFilter: String?
    public var usageAuthentication: CustomEndpointUsageAuthentication
    public var usageHistory: [CustomEndpointUsageDay]
    public var trackingUnit: CustomEndpointTrackingUnit
    public var monthlyBudgetUSD: Double?
    public var currentSpendUSD: Double?
    public var monthlyBudgetTokensM: Double?
    public var currentTokensUsedM: Double?
    public var displayRemaining: Bool
    public var showCurrency: Bool
    public var lastLatencyMs: Int?
    public var lastHealthStatus: CustomEndpointHealth
    public var lastCheckedAt: Date?

    public init(
        id: String = UUID().uuidString,
        name: String,
        baseURL: String,
        headerKey: String = "Authorization",
        selectedModel: String = "",
        availableModels: [String] = [],
        isEnabled: Bool = true,
        accentColorHex: String = "#6366F1",
        iconPreset: String? = "openai",
        openCodeProviderID: String? = nil,
        customIconFilename: String? = nil,
        usageSource: CustomEndpointUsageSource = .manual,
        usagePreset: CustomEndpointUsagePreset? = nil,
        usageURL: String? = nil,
        usageRecordsPath: String? = nil,
        usageModelField: String? = nil,
        usageTokenField: String? = nil,
        usageModelFilter: String? = nil,
        usageAuthentication: CustomEndpointUsageAuthentication = .apiKey,
        usageHistory: [CustomEndpointUsageDay] = [],
        trackingUnit: CustomEndpointTrackingUnit = .currency,
        monthlyBudgetUSD: Double? = nil,
        currentSpendUSD: Double? = nil,
        monthlyBudgetTokensM: Double? = nil,
        currentTokensUsedM: Double? = nil,
        displayRemaining: Bool = false,
        showCurrency: Bool = false,
        lastLatencyMs: Int? = nil,
        lastHealthStatus: CustomEndpointHealth = .idle,
        lastCheckedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.headerKey = headerKey
        self.selectedModel = selectedModel
        self.availableModels = availableModels
        self.isEnabled = isEnabled
        self.accentColorHex = accentColorHex
        self.iconPreset = iconPreset
        self.openCodeProviderID = openCodeProviderID
        self.customIconFilename = customIconFilename
        self.usageSource = usageSource
        self.usagePreset = usagePreset
        self.usageURL = usageURL
        self.usageRecordsPath = usageRecordsPath
        self.usageModelField = usageModelField
        self.usageTokenField = usageTokenField
        self.usageModelFilter = usageModelFilter
        self.usageAuthentication = usageAuthentication
        self.usageHistory = usageHistory
        self.trackingUnit = trackingUnit
        self.monthlyBudgetUSD = monthlyBudgetUSD
        self.currentSpendUSD = currentSpendUSD
        self.monthlyBudgetTokensM = monthlyBudgetTokensM
        self.currentTokensUsedM = currentTokensUsedM
        self.displayRemaining = displayRemaining
        self.showCurrency = showCurrency
        self.lastLatencyMs = lastLatencyMs
        self.lastHealthStatus = lastHealthStatus
        self.lastCheckedAt = lastCheckedAt
    }

    /// A plaintext key found in the defaults plist, waiting to be moved to the
    /// keychain. Decode-only and never encoded, so it disappears the first time
    /// the list is written back. Nil for anything written since.
    public var legacyAPIKey: String?

    public var apiKey: String? {
        KeychainItem.read(service: Self.keychainService, account: Self.keychainAccount(for: id))
    }

    public func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainItem.delete(service: Self.keychainService, account: Self.keychainAccount(for: id))
        } else {
            _ = KeychainItem.store(service: Self.keychainService, account: Self.keychainAccount(for: id), value: trimmed)
        }
    }

    public func deleteAPIKey() {
        KeychainItem.delete(service: Self.keychainService, account: Self.keychainAccount(for: id))
    }

    public var computedSpendUSD: Double {
        currentSpendUSD ?? 0
    }

    public var computedTokensUsedM: Double {
        currentTokensUsedM ?? 0
    }

    public var remainingTokensFraction: Double {
        guard let budget = monthlyBudgetTokensM, budget > 0 else { return 0 }
        let spent = computedTokensUsedM
        return min(max((budget - spent) / budget, 0.0), 1.0)
    }

    public var usedTokensFraction: Double {
        guard let budget = monthlyBudgetTokensM, budget > 0 else { return 0 }
        let spentFraction = min(max(computedTokensUsedM / budget, 0.0), 1.0)
        return displayRemaining ? (1.0 - spentFraction) : spentFraction
    }

    public var remainingFraction: Double {
        switch trackingUnit {
        case .currency:
            guard let budget = monthlyBudgetUSD, budget > 0 else { return 0 }
            let spent = computedSpendUSD
            return min(max((budget - spent) / budget, 0.0), 1.0)
        case .tokens:
            return remainingTokensFraction
        }
    }

    public var usedFraction: Double {
        switch trackingUnit {
        case .currency:
            guard let budget = monthlyBudgetUSD, budget > 0 else { return 0 }
            let spentFraction = min(max(computedSpendUSD / budget, 0.0), 1.0)
            return displayRemaining ? (1.0 - spentFraction) : spentFraction
        case .tokens:
            return usedTokensFraction
        }
    }

    public static func formatTokenMillions(_ millions: Double) -> String {
        if millions >= 1000 {
            return String(format: "%.1fB", millions / 1000.0)
        } else if millions >= 10 {
            return String(format: "%.0fM", millions)
        } else if millions >= 1 {
            let rounded = (millions * 10).rounded() / 10
            if rounded.truncatingRemainder(dividingBy: 1) == 0 {
                return String(format: "%.0fM", rounded)
            } else {
                return String(format: "%.1fM", rounded)
            }
        } else if millions > 0 {
            let thousands = millions * 1000
            let roundedK = (thousands * 10).rounded() / 10
            if roundedK.truncatingRemainder(dividingBy: 1) == 0 {
                return String(format: "%.0fk", roundedK)
            } else {
                return String(format: "%.1fk", roundedK)
            }
        } else {
            return "0M"
        }
    }

    public var providerID: String {
        "custom-endpoint-\(id)"
    }

    // MARK: - Codable (Never stores apiKey in UserDefaults)

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case baseURL
        case headerKey
        case selectedModel
        case availableModels
        case isEnabled
        case accentColorHex
        case iconPreset
        case openCodeProviderID
        case customIconFilename
        case usageSource
        case usagePreset
        case usageURL
        case usageRecordsPath
        case usageModelField
        case usageTokenField
        case usageModelFilter
        case usageAuthentication
        case usageHistory
        case trackingUnit
        case monthlyBudgetUSD
        case budgetMonthlyUSD
        case currentSpendUSD
        case directSpendUSD
        case monthlyBudgetTokensM
        case currentTokensUsedM
        case displayRemaining
        case showCurrency
        case lastLatencyMs
        case lastHealthStatus
        case lastCheckedAt
        case legacyApiKey = "apiKey"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.baseURL = try container.decode(String.self, forKey: .baseURL)
        self.headerKey = try container.decodeIfPresent(String.self, forKey: .headerKey) ?? "Authorization"
        self.selectedModel = try container.decodeIfPresent(String.self, forKey: .selectedModel) ?? ""
        self.availableModels = try container.decodeIfPresent([String].self, forKey: .availableModels) ?? []
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.accentColorHex = try container.decodeIfPresent(String.self, forKey: .accentColorHex) ?? "#6366F1"
        self.iconPreset = try container.decodeIfPresent(String.self, forKey: .iconPreset)
        self.openCodeProviderID = try container.decodeIfPresent(String.self, forKey: .openCodeProviderID)
        self.customIconFilename = try container.decodeIfPresent(String.self, forKey: .customIconFilename)
        self.usageSource = try container.decodeIfPresent(CustomEndpointUsageSource.self, forKey: .usageSource) ?? .manual
        self.usagePreset = try container.decodeIfPresent(CustomEndpointUsagePreset.self, forKey: .usagePreset)
        self.usageURL = try container.decodeIfPresent(String.self, forKey: .usageURL)
        self.usageRecordsPath = try container.decodeIfPresent(String.self, forKey: .usageRecordsPath)
        self.usageModelField = try container.decodeIfPresent(String.self, forKey: .usageModelField)
        self.usageTokenField = try container.decodeIfPresent(String.self, forKey: .usageTokenField)
        self.usageModelFilter = try container.decodeIfPresent(String.self, forKey: .usageModelFilter)
        self.usageAuthentication = try container.decodeIfPresent(CustomEndpointUsageAuthentication.self, forKey: .usageAuthentication) ?? .apiKey
        self.usageHistory = try container.decodeIfPresent([CustomEndpointUsageDay].self, forKey: .usageHistory) ?? []
        self.trackingUnit = try container.decodeIfPresent(CustomEndpointTrackingUnit.self, forKey: .trackingUnit) ?? .currency
        self.monthlyBudgetUSD = try container.decodeIfPresent(Double.self, forKey: .monthlyBudgetUSD)
            ?? container.decodeIfPresent(Double.self, forKey: .budgetMonthlyUSD)
        self.currentSpendUSD = try container.decodeIfPresent(Double.self, forKey: .currentSpendUSD)
            ?? container.decodeIfPresent(Double.self, forKey: .directSpendUSD)
        self.monthlyBudgetTokensM = try container.decodeIfPresent(Double.self, forKey: .monthlyBudgetTokensM)
        self.currentTokensUsedM = try container.decodeIfPresent(Double.self, forKey: .currentTokensUsedM)
        self.displayRemaining = try container.decodeIfPresent(Bool.self, forKey: .displayRemaining) ?? false
        self.showCurrency = try container.decodeIfPresent(Bool.self, forKey: .showCurrency) ?? false
        self.lastLatencyMs = try container.decodeIfPresent(Int.self, forKey: .lastLatencyMs)
        self.lastHealthStatus = try container.decodeIfPresent(CustomEndpointHealth.self, forKey: .lastHealthStatus) ?? .idle
        self.lastCheckedAt = try container.decodeIfPresent(Date.self, forKey: .lastCheckedAt)

        // A key written by an earlier build of this feature, still in the defaults
        // plist. Only carried here — moving it is `Preferences`' job, once, because
        // this initialiser runs on every decode and every provider property access
        // decodes the list again. Writing the keychain from here meant a `SecItemAdd`
        // several times per repaint, and the plaintext was never removed from the
        // plist because `didSet` does not fire during `Preferences.init`.
        self.legacyAPIKey = try container.decodeIfPresent(String.self, forKey: .legacyApiKey)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(headerKey, forKey: .headerKey)
        try container.encode(selectedModel, forKey: .selectedModel)
        try container.encode(availableModels, forKey: .availableModels)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(accentColorHex, forKey: .accentColorHex)
        try container.encodeIfPresent(iconPreset, forKey: .iconPreset)
        try container.encodeIfPresent(openCodeProviderID, forKey: .openCodeProviderID)
        try container.encodeIfPresent(customIconFilename, forKey: .customIconFilename)
        if usageSource != .manual {
            try container.encode(usageSource, forKey: .usageSource)
        }
        try container.encodeIfPresent(usagePreset, forKey: .usagePreset)
        try container.encodeIfPresent(usageURL, forKey: .usageURL)
        try container.encodeIfPresent(usageRecordsPath, forKey: .usageRecordsPath)
        try container.encodeIfPresent(usageModelField, forKey: .usageModelField)
        try container.encodeIfPresent(usageTokenField, forKey: .usageTokenField)
        try container.encodeIfPresent(usageModelFilter, forKey: .usageModelFilter)
        try container.encode(usageHistory, forKey: .usageHistory)
        if usageSource == .jsonEndpoint {
            try container.encode(usageAuthentication, forKey: .usageAuthentication)
        }
        if trackingUnit != .currency {
            try container.encode(trackingUnit, forKey: .trackingUnit)
        }
        try container.encodeIfPresent(monthlyBudgetUSD, forKey: .monthlyBudgetUSD)
        try container.encodeIfPresent(currentSpendUSD, forKey: .currentSpendUSD)
        try container.encodeIfPresent(monthlyBudgetTokensM, forKey: .monthlyBudgetTokensM)
        try container.encodeIfPresent(currentTokensUsedM, forKey: .currentTokensUsedM)
        if displayRemaining {
            try container.encode(displayRemaining, forKey: .displayRemaining)
        }
        if showCurrency {
            try container.encode(showCurrency, forKey: .showCurrency)
        }
        try container.encodeIfPresent(lastLatencyMs, forKey: .lastLatencyMs)
        try container.encode(lastHealthStatus, forKey: .lastHealthStatus)
        try container.encodeIfPresent(lastCheckedAt, forKey: .lastCheckedAt)
        // Notice: legacyApiKey is intentionally never encoded!
    }
}

extension Array where Element == CustomEndpointUsageDay {
    var codexUsage: CodexTokenUsage {
        var previous = 0
        let buckets = sorted { $0.day < $1.day }.map { sample in
            let delta = sample.totalTokens >= previous ? sample.totalTokens - previous : sample.totalTokens
            previous = sample.totalTokens
            return CodexTokenUsage.DailyBucket(startDate: sample.day, tokens: delta)
        }
        return CodexTokenUsage(dailyUsageBuckets: buckets)
    }
}
public struct CustomEndpointPreset: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let baseURL: String
    public let headerKey: String
    public let defaultModel: String
    public let iconPreset: String
    public let accentColorHex: String

    public static let templates: [CustomEndpointPreset] = [
        CustomEndpointPreset(
            id: "openrouter",
            name: "OpenRouter",
            baseURL: "https://openrouter.ai/api/v1",
            headerKey: "Authorization",
            defaultModel: "openai/gpt-4o",
            iconPreset: "openai",
            accentColorHex: "#6366F1"
        ),
        CustomEndpointPreset(
            id: "groq",
            name: "Groq",
            baseURL: "https://api.groq.com/openai/v1",
            headerKey: "Authorization",
            defaultModel: "llama-3.3-70b-versatile",
            iconPreset: "grok",
            accentColorHex: "#F97316"
        ),
        CustomEndpointPreset(
            id: "together",
            name: "Together AI",
            baseURL: "https://api.together.xyz/v1",
            headerKey: "Authorization",
            defaultModel: "meta-llama/Llama-3.3-70B-Instruct-Turbo",
            iconPreset: "meta",
            accentColorHex: "#06B6D4"
        ),
        CustomEndpointPreset(
            id: "mistral",
            name: "Mistral AI",
            baseURL: "https://api.mistral.ai/v1",
            headerKey: "Authorization",
            defaultModel: "mistral-large-latest",
            iconPreset: "mistral",
            accentColorHex: "#F59E0B"
        ),
        CustomEndpointPreset(
            id: "deepinfra",
            name: "DeepInfra",
            baseURL: "https://api.deepinfra.com/v1/openai",
            headerKey: "Authorization",
            defaultModel: "meta-llama/Meta-Llama-3.1-70B-Instruct",
            iconPreset: "deepseek",
            accentColorHex: "#3B82F6"
        ),
        CustomEndpointPreset(
            id: "vllm",
            name: "Local vLLM",
            baseURL: "http://localhost:8000/v1",
            headerKey: "Authorization",
            defaultModel: "",
            iconPreset: "ollama",
            accentColorHex: "#10B981"
        ),
        CustomEndpointPreset(
            id: "llamacpp",
            name: "Local llama.cpp",
            baseURL: "http://localhost:8080/v1",
            headerKey: "Authorization",
            defaultModel: "",
            iconPreset: "lmstudio",
            accentColorHex: "#8B5CF6"
        ),
        CustomEndpointPreset(
            id: "ollamaproxy",
            name: "Local Ollama Proxy",
            baseURL: "http://localhost:11434/v1",
            headerKey: "Authorization",
            defaultModel: "",
            iconPreset: "ollama-local",
            accentColorHex: "#14B8A6"
        )
    ]
}

public enum CustomIconStore {
    private static var customIconsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let codenotchDir = appSupport.appendingPathComponent("Codenotch", isDirectory: true)
        let iconsDir = codenotchDir.appendingPathComponent("CustomIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: iconsDir, withIntermediateDirectories: true)
        return iconsDir
    }

    public static func saveIcon(image: NSImage, for endpointID: String) -> String? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        let filename = "\(endpointID).png"
        let fileURL = customIconsDirectory.appendingPathComponent(filename)
        do {
            try pngData.write(to: fileURL)
            return filename
        } catch {
            return nil
        }
    }

    public static func loadIcon(filename: String) -> NSImage? {
        let fileURL = customIconsDirectory.appendingPathComponent(filename)
        return NSImage(contentsOf: fileURL)
    }

    public static func deleteIcon(filename: String) {
        let fileURL = customIconsDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: fileURL)
    }
}
