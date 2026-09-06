import Foundation

/// Parses grok.com's own Usage card.
///
/// The card is fed by `POST /grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig`
/// (gRPC-web + protobuf), which `Sites.grok` calls from inside the signed-in
/// page. The fetch script base64s the raw bytes into the body string, so this
/// takes base64 rather than JSON.
///
/// There is no published schema. The layout is reverse-engineered from the web
/// bundle and proven against live captures by CodexBar and alex-core, whose
/// fixtures are pinned in `GrokUsageTests`: top-level field 1 holds a nested
/// message whose fixed32 field 1 is the weekly SuperGrok credit-pool usage in
/// percent (0–100), and varint timestamps in the 1.7e9–2.1e9 range carry the
/// billing period. An omitted percent beside a usage period means 0% used, per
/// proto3 — not "unknown".
enum GrokUsage {
    /// One window: the weekly SuperGrok pool.
    static func windows(fromBody base64: String, now: Date = Date()) throws -> [LimitWindow] {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            throw UsageProviderError.badResponse(status: 0)
        }
        let reading = try reading(from: Array(data), now: now)
        return [LimitWindow(
            id: "weekly",
            label: "Weekly limit",
            usedFraction: reading.usedPercent / 100,
            resetsAt: reading.resetsAt
        )]
    }

    struct Reading {
        /// 0–100.
        let usedPercent: Double
        let resetsAt: Date?
    }

    static func reading(from bytes: [UInt8], now: Date) throws -> Reading {
        try validateTrailers(bytes)

        var payloads = dataFrames(in: bytes)
        if payloads.isEmpty, looksLikeProtobuf(bytes) {
            payloads = [bytes]
        }
        guard !payloads.isEmpty else {
            throw UsageProviderError.badResponse(status: 0)
        }

        var fixed32: [(path: [UInt64], value: Float, order: Int)] = []
        var varints: [(path: [UInt64], value: UInt64)] = []
        for payload in payloads {
            let scan = scanProtobuf(payload, depth: 0, path: [], order: fixed32.count)
            fixed32.append(contentsOf: scan.fixed32)
            varints.append(contentsOf: scan.varints)
        }

        let percent = fixed32
            .filter { $0.path.last == 1 && $0.value.isFinite && (0...100).contains($0.value) }
            .min { a, b in
                a.path.count == b.path.count ? a.order < b.order : a.path.count < b.path.count
            }
            .map { Double($0.value) }

        let nowS = Int64(now.timeIntervalSince1970)
        let futureResets = varints.compactMap { field -> (path: [UInt64], reset: Int64)? in
            guard (1_700_000_000...2_100_000_000).contains(field.value) else { return nil }
            let reset = Int64(field.value)
            return reset > nowS ? (field.path, reset) : nil
        }
        let reset = futureResets.first { $0.path == [1, 5, 1] }?.reset
            ?? futureResets.map(\.reset).min()

        let hasUsagePeriod = varints.contains {
            $0.path.starts(with: [1, 6])
                || ($0.path == [1, 8, 1] && ($0.value == 1 || $0.value == 2))
        }
        if let percent {
            return Reading(usedPercent: percent,
                           resetsAt: reset.map { Date(timeIntervalSince1970: Double($0)) })
        }
        // A period with no percent recorded: nothing used yet, not "unknown".
        if fixed32.isEmpty, reset != nil, hasUsagePeriod {
            return Reading(usedPercent: 0,
                           resetsAt: reset.map { Date(timeIntervalSince1970: Double($0)) })
        }
        throw UsageProviderError.badResponse(status: 0)
    }

    // MARK: - gRPC-web framing

    /// Each frame is a flag byte plus a big-endian length. Trailer frames
    /// (0x80) carry `grpc-status`; anything non-zero is the RPC failing.
    /// 16 is "not signed in" — the user remedy is the sign-in modal, so that
    /// maps to `needsAuth` rather than a generic error.
    private static func validateTrailers(_ bytes: [UInt8]) throws {
        for frame in frames(in: bytes) ?? [] where frame.flags & 0x80 != 0 {
            guard let text = String(bytes: frame.payload, encoding: .utf8) else { continue }
            // `components(separatedBy:)`, not `split(separator:)`: "\r\n" is
            // one grapheme cluster, so splitting on the "\n" character never
            // fires and the status line is never seen.
            for line in text.components(separatedBy: CharacterSet.newlines) {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2,
                      parts[0].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).lowercased() == "grpc-status",
                      let status = Int(parts[1].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines))
                else { continue }
                if status == 16 || status == 7 { throw UsageProviderError.needsAuth }
                if status != 0 { throw UsageProviderError.badResponse(status: 0) }
            }
        }
    }

    private struct Frame {
        let flags: UInt8
        let payload: [UInt8]
    }

    /// Nil when the bytes are not valid framing at all.
    private static func frames(in bytes: [UInt8]) -> [Frame]? {
        var out: [Frame] = []
        var index = 0
        while index < bytes.count {
            guard index + 5 <= bytes.count else { return nil }
            let flags = bytes[index]
            let length = (Int(bytes[index + 1]) << 24) | (Int(bytes[index + 2]) << 16)
                | (Int(bytes[index + 3]) << 8) | Int(bytes[index + 4])
            let start = index + 5
            guard start + length <= bytes.count else { return nil }
            out.append(Frame(flags: flags, payload: Array(bytes[start ..< start + length])))
            index = start + length
        }
        return out
    }

    private static func dataFrames(in bytes: [UInt8]) -> [[UInt8]] {
        (frames(in: bytes) ?? []).filter { $0.flags & 0x80 == 0 }.map(\.payload)
    }

    private static func looksLikeProtobuf(_ bytes: [UInt8]) -> Bool {
        guard let first = bytes.first else { return false }
        let field = first >> 3
        return field > 0 && [0, 1, 2, 5].contains(first & 0x07)
    }

    // MARK: - Protobuf scan

    private struct Scan {
        var fixed32: [(path: [UInt64], value: Float, order: Int)] = []
        var varints: [(path: [UInt64], value: UInt64)] = []
    }

    /// Walks fields generically — wire types 0 (varint) and 5 (fixed32) are
    /// collected, type 2 (length-delimited) is descended into, the rest are
    /// skipped. Paths name the nesting, so the usage percent is found by
    /// position rather than by trusting any one build's layout.
    private static func scanProtobuf(_ data: [UInt8], depth: Int, path: [UInt64],
                                     order: Int) -> Scan {
        var scan = Scan()
        var index = 0
        var nextOrder = order

        func readVarint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while index < data.count, shift < 64 {
                let byte = data[index]
                index += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }

        while index < data.count {
            let fieldStart = index
            guard let key = readVarint(), key != 0 else {
                index = fieldStart + 1
                continue
            }
            let fieldNumber = key >> 3
            let wireType = key & 0x07
            let fieldPath = path + [fieldNumber]

            switch wireType {
            case 0:
                guard let value = readVarint() else {
                    index = fieldStart + 1
                    continue
                }
                scan.varints.append((fieldPath, value))
            case 1:
                guard index + 8 <= data.count else { return scan }
                index += 8
            case 2:
                guard let length = readVarint(),
                      length <= data.count - index
                else {
                    index = fieldStart + 1
                    continue
                }
                if depth < 4 {
                    let nested = scanProtobuf(Array(data[index ..< index + Int(length)]),
                                              depth: depth + 1, path: fieldPath,
                                              order: nextOrder)
                    nextOrder += nested.fixed32.count
                    scan.fixed32.append(contentsOf: nested.fixed32)
                    scan.varints.append(contentsOf: nested.varints)
                }
                index += Int(length)
            case 5:
                guard index + 4 <= data.count else { return scan }
                let bits = UInt32(data[index]) | (UInt32(data[index + 1]) << 8)
                    | (UInt32(data[index + 2]) << 16) | (UInt32(data[index + 3]) << 24)
                scan.fixed32.append((fieldPath, Float(bitPattern: bits), nextOrder))
                nextOrder += 1
                index += 4
            default:
                index = fieldStart + 1
            }
        }
        return scan
    }
}
