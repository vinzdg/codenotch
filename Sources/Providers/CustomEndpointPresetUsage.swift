import Foundation

public enum CustomEndpointUsagePreset: String, Codable, CaseIterable, Sendable {
    case litellm
    case openRouter
    case newAPI
    case vllm
    case llamaCpp
    case abacus
}

enum CustomEndpointSpendPeriod: Equatable {
    case month
    case lifetime
}

enum CustomEndpointPresetReading: Equatable {
    case tokens(Int)
    case spendUSD(Double, period: CustomEndpointSpendPeriod)
    case quota(used: Int, granted: Int?)
    /// Abacus.AI subscription credits: what is left, the plan's monthly
    /// allowance, and everything available this cycle (allowance plus any
    /// credits bought on top).
    case credits(left: Double, monthly: Double, total: Double)
}

enum CustomEndpointFileImportError: LocalizedError, Equatable {
    case fileTooLarge
    case invalidJSON
    case unsupportedVersion
    case unsupportedUnit
    case unknownFields
    case invalidField
    case invalidURL
    case crossOriginURL

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return "File exceeds maximum size of 64 KiB."
        case .invalidJSON:
            return "File contains malformed JSON."
        case .unsupportedVersion:
            return "Unsupported format version; only version 1 is supported."
        case .unsupportedUnit:
            return "Unsupported unit; only 'tokens' is supported."
        case .unknownFields:
            return "File contains unrecognized fields."
        case .invalidField:
            return "Field paths must be non-empty and at most 128 characters."
        case .invalidURL:
            return "Usage URL must be an http or https URL without userinfo, query, or fragment."
        case .crossOriginURL:
            return "Usage URL must match the base URL's scheme, host, and port."
        }
    }
}

struct CustomEndpointJSONPresetFile: Codable, Equatable {
    let version: Int
    let unit: String
    let usageURL: String
    let recordsPath: String
    let modelField: String
    let tokenField: String
    let modelFilter: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case unit
        case usageURL
        case recordsPath
        case modelField
        case tokenField
        case modelFilter
    }

    static func importMapping(_ data: Data, baseURL: String) throws -> CustomEndpointJSONPresetFile {
        guard data.count <= 64 * 1024 else {
            throw CustomEndpointFileImportError.fileTooLarge
        }

        guard let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = jsonObject as? [String: Any] else {
            throw CustomEndpointFileImportError.invalidJSON
        }

        let allowedKeys = Set(CodingKeys.allCases.map(\.rawValue))
        for key in dict.keys {
            if !allowedKeys.contains(key) {
                throw CustomEndpointFileImportError.unknownFields
            }
        }

        let decoder = JSONDecoder()
        guard let file = try? decoder.decode(CustomEndpointJSONPresetFile.self, from: data) else {
            throw CustomEndpointFileImportError.invalidJSON
        }

        guard file.version == 1 else {
            throw CustomEndpointFileImportError.unsupportedVersion
        }

        guard file.unit == "tokens" else {
            throw CustomEndpointFileImportError.unsupportedUnit
        }

        // recordsPath may be empty (meaning root is array), but if present must be <= 128 chars.
        guard file.recordsPath.count <= 128 else {
            throw CustomEndpointFileImportError.invalidField
        }

        // modelField and tokenField must be non-empty and <= 128 chars.
        guard !file.modelField.isEmpty, file.modelField.count <= 128,
              !file.tokenField.isEmpty, file.tokenField.count <= 128 else {
            throw CustomEndpointFileImportError.invalidField
        }

        if let modelFilter = file.modelFilter {
            guard modelFilter.count <= 128 else {
                throw CustomEndpointFileImportError.invalidField
            }
        }

        // Validate usageURL structure and same-origin against baseURL
        let usageTrimmed = file.usageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let usageComponents = URLComponents(string: usageTrimmed),
              let usageScheme = usageComponents.scheme?.lowercased(),
              (usageScheme == "http" || usageScheme == "https"),
              let usageHost = usageComponents.host?.lowercased(), !usageHost.isEmpty,
              usageComponents.user == nil, usageComponents.password == nil,
              usageComponents.query == nil, usageComponents.fragment == nil else {
            throw CustomEndpointFileImportError.invalidURL
        }

        let baseTrimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseComponents = URLComponents(string: baseTrimmed),
              let baseScheme = baseComponents.scheme?.lowercased(),
              (baseScheme == "http" || baseScheme == "https"),
              let baseHost = baseComponents.host?.lowercased(), !baseHost.isEmpty,
              baseComponents.user == nil, baseComponents.password == nil,
              baseComponents.query == nil, baseComponents.fragment == nil else {
            throw CustomEndpointFileImportError.invalidURL
        }

        let baseEffectivePort = baseComponents.port ?? (baseScheme == "https" ? 443 : 80)
        let usageEffectivePort = usageComponents.port ?? (usageScheme == "https" ? 443 : 80)

        guard usageScheme == baseScheme,
              usageHost == baseHost,
              usageEffectivePort == baseEffectivePort else {
            throw CustomEndpointFileImportError.crossOriginURL
        }

        return file
    }
}

enum CustomEndpointPresetUsage {
    static func presetURL(_ preset: CustomEndpointUsagePreset, baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }

        if preset == .openRouter {
            guard scheme == "https", host.lowercased() == "openrouter.ai",
                  components.port == nil,
                  components.percentEncodedPath == "/api/v1" || components.percentEncodedPath == "/api/v1/" else {
                return nil
            }
            components.percentEncodedPath = "/api/v1/key"
        } else if preset == .abacus {
            // Only Abacus's own RouteLLM host carries the credits endpoint; never
            // send an Abacus-shaped request to anything else.
            guard scheme == "https", host.lowercased() == "routellm.abacus.ai",
                  components.port == nil else {
                return nil
            }
            components.percentEncodedPath = "/api/v0/_getOrganizationComputePoints"
        } else {
            var path = components.percentEncodedPath
            while path.hasSuffix("/") { path.removeLast() }
            if path == "/v1" {
                path = ""
            } else if path.hasSuffix("/v1") {
                path.removeLast(3)
            }
            let suffix: String
            switch preset {
            case .litellm: suffix = "/key/info"
            case .newAPI: suffix = "/api/usage/token"
            case .vllm, .llamaCpp: suffix = "/metrics"
            case .openRouter, .abacus: return nil
            }
            components.percentEncodedPath = path + suffix
        }
        return components.url
    }

    static func parsePreset(_ preset: CustomEndpointUsagePreset, data: Data) -> CustomEndpointPresetReading? {
        switch preset {
        case .litellm:
            guard let value = try? JSONDecoder().decode(LiteLLMResponse.self, from: data),
                  value.info.spend.isFinite, value.info.spend >= 0 else { return nil }
            return .spendUSD(value.info.spend, period: .lifetime)
        case .openRouter:
            guard let value = try? JSONDecoder().decode(OpenRouterResponse.self, from: data),
                  value.data.usageMonthly.isFinite, value.data.usageMonthly >= 0 else { return nil }
            return .spendUSD(value.data.usageMonthly, period: .month)
        case .newAPI:
            guard let value = try? JSONDecoder().decode(NewAPIResponse.self, from: data),
                  value.data.object == "token_usage", value.data.totalUsed >= 0,
                  value.data.totalGranted.map({ $0 >= 0 }) ?? true else { return nil }
            return .quota(used: value.data.totalUsed,
                          granted: value.data.unlimitedQuota == true ? nil : value.data.totalGranted)
        case .vllm:
            return parseCounters(data, prompt: "vllm:prompt_tokens_total", completion: "vllm:generation_tokens_total")
        case .llamaCpp:
            return parseCounters(data, prompt: "llamacpp:prompt_tokens_total", completion: "llamacpp:tokens_predicted_total")
        case .abacus:
            guard let value = try? JSONDecoder().decode(AbacusCreditsResponse.self, from: data),
                  value.success else { return nil }
            let r = value.result
            let users = max(1.0, r.userCount ?? 1)
            let monthly = r.normalMonthlyCredits * users
            guard r.computePointsLeft.isFinite, r.computePointsLeft >= 0,
                  monthly.isFinite, monthly > 0,
                  r.totalComputePoints.isFinite, r.totalComputePoints >= 0 else { return nil }
            return .credits(left: r.computePointsLeft, monthly: monthly,
                            total: max(r.totalComputePoints, monthly))
        }
    }

    private struct AbacusCreditsResponse: Decodable {
        struct Result: Decodable {
            let computePointsLeft: Double
            let totalComputePoints: Double
            let normalMonthlyCredits: Double
            let userCount: Double?
        }
        let success: Bool
        let result: Result
    }

    /// 934 -> "934", 19_065 -> "19.1K", 20_000 -> "20K".
    static func formatCredits(_ value: Double) -> String {
        let v = max(0, value)
        if v < 1_000 { return String(format: "%.0f", v.rounded()) }
        let k = (v / 100).rounded() / 10
        return k.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0fK", k) : String(format: "%.1fK", k)
    }

    private struct LiteLLMResponse: Decodable {
        struct Info: Decodable { let spend: Double }
        let info: Info
    }

    private struct OpenRouterResponse: Decodable {
        struct Usage: Decodable {
            let usageMonthly: Double
            enum CodingKeys: String, CodingKey { case usageMonthly = "usage_monthly" }
        }
        let data: Usage
    }

    private struct NewAPIResponse: Decodable {
        struct Usage: Decodable {
            let object: String
            let totalUsed: Int
            let totalGranted: Int?
            let unlimitedQuota: Bool?
            enum CodingKeys: String, CodingKey {
                case object
                case totalUsed = "total_used"
                case totalGranted = "total_granted"
                case unlimitedQuota = "unlimited_quota"
            }
        }
        let data: Usage
    }

    private struct Label: Hashable, Comparable {
        let key: String
        let value: String

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.key == rhs.key ? lhs.value < rhs.value : lhs.key < rhs.key
        }
    }

    private static func parseCounters(_ data: Data, prompt: String, completion: String) -> CustomEndpointPresetReading? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var totals: [String: Int] = [:]
        var series: [String: Set<[Label]>] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let boundary = line.firstIndex(where: { $0 == "{" || $0.isWhitespace }) else {
                if line == prompt || line == completion { return nil }
                continue
            }
            let name = String(line[..<boundary])
            guard name == prompt || name == completion else { continue }
            var remainder = line[boundary...]
            var labels: [Label] = []
            if remainder.first == "{" {
                guard let close = closingBrace(in: remainder),
                      let parsed = parseLabels(remainder[remainder.index(after: remainder.startIndex)..<close]) else {
                    return nil
                }
                labels = parsed
                remainder = remainder[remainder.index(after: close)...]
            }
            guard remainder.first?.isWhitespace == true else { return nil }
            let fields = remainder.split(whereSeparator: \.isWhitespace)
            guard fields.count == 1 || fields.count == 2,
                  let value = integerSample(fields[0]),
                  fields.count == 1 || (Double(fields[1]).map { $0.isFinite } == true),
                  series[name, default: []].insert(labels).inserted else { return nil }
            let (sum, overflow) = totals[name, default: 0].addingReportingOverflow(value)
            guard !overflow else { return nil }
            totals[name] = sum
        }
        guard let first = totals[prompt], let second = totals[completion] else { return nil }
        let (sum, overflow) = first.addingReportingOverflow(second)
        return overflow ? nil : .tokens(sum)
    }

    private static func integerSample(_ sample: Substring) -> Int? {
        if let integer = Int(sample) { return integer >= 0 ? integer : nil }
        guard let number = Double(sample), number.isFinite, number >= 0 else { return nil }
        return Int(exactly: number)
    }

    private static func closingBrace(in text: Substring) -> Substring.Index? {
        var quoted = false
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if escaped { escaped = false; continue }
            if quoted && character == "\\" { escaped = true; continue }
            if character == "\"" { quoted.toggle() }
            if character == "}" && !quoted { return index }
        }
        return nil
    }

    private static func parseLabels(_ text: Substring) -> [Label]? {
        if text.isEmpty { return [] }
        var labels: [Label] = []
        var keys = Set<String>()
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let start = cursor
            while cursor < text.endIndex && (text[cursor].isLetter || text[cursor].isNumber || text[cursor] == "_") {
                cursor = text.index(after: cursor)
            }
            guard start < cursor, let first = text[start...].first,
                  first.isLetter || first == "_", cursor < text.endIndex, text[cursor] == "=" else { return nil }
            let key = String(text[start..<cursor])
            guard keys.insert(key).inserted else { return nil }
            cursor = text.index(after: cursor)
            guard cursor < text.endIndex, text[cursor] == "\"" else { return nil }
            cursor = text.index(after: cursor)
            var value = ""
            var closed = false
            while cursor < text.endIndex {
                let character = text[cursor]
                cursor = text.index(after: cursor)
                if character == "\"" { closed = true; break }
                if character == "\\" {
                    guard cursor < text.endIndex else { return nil }
                    switch text[cursor] {
                    case "n": value.append("\n")
                    case "\\": value.append("\\")
                    case "\"": value.append("\"")
                    default: return nil
                    }
                    cursor = text.index(after: cursor)
                } else {
                    value.append(character)
                }
            }
            guard closed else { return nil }
            labels.append(Label(key: key, value: value))
            if cursor == text.endIndex { break }
            guard text[cursor] == "," else { return nil }
            cursor = text.index(after: cursor)
            guard cursor < text.endIndex else { return nil }
        }
        return labels.sorted()
    }
}
