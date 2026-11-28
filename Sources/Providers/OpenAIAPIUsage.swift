import Foundation

enum OpenAIAPIUsage {
    static let endpoint = URL(string: "https://api.openai.com/v1/organization/usage/completions")!

    struct Page: Decodable {
        struct Bucket: Decodable {
            struct Result: Decodable {
                let numModelRequests: Int
                let inputTokens: Int
                let inputCachedTokens: Int?
                let outputTokens: Int
            }
            let startTime: Int
            let endTime: Int
            let results: [Result]
        }
        let data: [Bucket]
        let hasMore: Bool
        let nextPage: String?
    }

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    static func metrics(key: String, now: Date, session: URLSession = .shared) async throws -> CodexTokenUsage {
        let start = utc.date(byAdding: .day, value: -29, to: utc.startOfDay(for: now))!
        return try await metrics(start: Int(start.timeIntervalSince1970)) { cursor in
            try await OpenAIAPICosts.page(from: endpoint, key: key, start: start, end: now,
                                         cursor: cursor, session: session)
        }
    }

    static func metrics(start: Int, fetch: (String?) async throws -> Page) async throws -> CodexTokenUsage {
        var cursor: String?
        var seen = Set<String>()
        var previous = start
        var requests = 0
        var input = 0
        var cached = 0
        var hasCacheMetric = true
        var output = 0
        var days = [CodexTokenUsage.DailyBucket]()
        func add(_ lhs: Int, _ rhs: Int) throws -> Int {
            let (sum, overflow) = lhs.addingReportingOverflow(rhs)
            guard rhs >= 0, !overflow else { throw UsageProviderError.badResponse(status: 200) }
            return sum
        }
        for _ in 0..<4 {
            let page = try await fetch(cursor)
            for bucket in page.data {
                guard bucket.startTime >= previous, bucket.endTime > bucket.startTime else {
                    throw UsageProviderError.badResponse(status: 200)
                }
                previous = bucket.endTime
                var tokens = 0
                for row in bucket.results {
                    requests = try add(requests, row.numModelRequests)
                    input = try add(input, row.inputTokens)
                    output = try add(output, row.outputTokens)
                    if let n = row.inputCachedTokens {
                        cached = try add(cached, n)
                    } else {
                        hasCacheMetric = false
                    }
                    tokens = try add(tokens, add(row.inputTokens, row.outputTokens))
                }
                let day = utc.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(bucket.startTime)))
                let stamp = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
                days.append(.init(startDate: stamp, tokens: tokens))
            }
            if !page.hasMore {
                return CodexTokenUsage(dailyUsageBuckets: days, apiMetrics: .init(
                    requests: requests, input: input, cachedInput: hasCacheMetric ? cached : nil, output: output))
            }
            guard let next = page.nextPage, !next.isEmpty, seen.insert(next).inserted else { break }
            cursor = next
        }
        throw UsageProviderError.badResponse(status: 200)
    }
}
