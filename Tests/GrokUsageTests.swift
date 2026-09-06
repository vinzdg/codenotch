import XCTest
@testable import Codenotch

/// grok.com's Usage card is fed by a gRPC-web protobuf RPC with no published
/// schema, so every layout fact is pinned here — ported from the fixtures
/// CodexBar and alex-core captured against live responses.
final class GrokUsageTests: XCTestCase {
    private func varint(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        var v = value
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    private func frame(_ payload: [UInt8], flags: UInt8 = 0x00) -> [UInt8] {
        let n = payload.count
        return [flags, UInt8(n >> 24), UInt8((n >> 16) & 0xFF),
                UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] + payload
    }

    private func body(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
    }

    private func payload(percent: Float, reset: UInt64) -> [UInt8] {
        var bits = percent.bitPattern.littleEndian
        let fixed = withUnsafeBytes(of: &bits) { Array($0) }
        return [0x0D] + fixed + [0x10] + varint(reset)
    }

    func testReadsAFramedBillingResponse() throws {
        let w = try GrokUsage.windows(
            fromBody: body(frame(payload(percent: 42.5, reset: 1_800_000_000))),
            now: Date(timeIntervalSince1970: 1_799_000_000))
        XCTAssertEqual(w.map(\.id), ["weekly"])
        XCTAssertEqual(w[0].label, "Weekly limit")
        XCTAssertEqual(w[0].usedFraction ?? -1, 0.425, accuracy: 0.0001)
        XCTAssertEqual(w[0].resetsAt?.timeIntervalSince1970 ?? -1, 1_800_000_000, accuracy: 1)
    }

    /// Captured fixture from CodexBar: an unframed protobuf payload, which grok
    /// sometimes returns instead of a framed one.
    func testReadsAnUnframedPayload() throws {
        let hex = "0a3f0d7f6a9c3f12001a002206088097f3d0062a060880b191d206"
            + "3a07080215a9389b3f3a07080115d6ea183c421208011206088097f3d0061a060880b191d206"
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            bytes.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        let w = try GrokUsage.windows(fromBody: body(bytes),
                                      now: Date(timeIntervalSince1970: 1_780_000_000))
        XCTAssertEqual(w[0].usedFraction ?? -1, 0.01222, accuracy: 0.0001)
        XCTAssertEqual(w[0].resetsAt?.timeIntervalSince1970 ?? -1, 1_782_864_000, accuracy: 1)
    }

    /// A period with no percent recorded is nothing used yet — 0%, not unknown.
    func testNoUsageYetReadsAsZero() throws {
        let bytes: [UInt8] = [
            0x00, 0x00, 0x00, 0x00, 0x37, 0x0A, 0x35, 0x12, 0x00, 0x1A, 0x00, 0x22, 0x06, 0x08,
            0x80, 0xDA, 0xCF, 0xCF, 0x06, 0x2A, 0x06, 0x08, 0x80, 0x97, 0xF3, 0xD0, 0x06, 0x32,
            0x09, 0x0A, 0x05, 0x08, 0xEA, 0x0F, 0x10, 0x04, 0x12, 0x00, 0x32, 0x09, 0x0A, 0x05,
            0x08, 0xEA, 0x0F, 0x10, 0x03, 0x12, 0x00, 0x32, 0x09, 0x0A, 0x05, 0x08, 0xEA, 0x0F,
            0x10, 0x02, 0x12, 0x00, 0x80, 0x00, 0x00, 0x00, 0x0F, 0x67, 0x72, 0x70, 0x63, 0x2D,
            0x73, 0x74, 0x61, 0x74, 0x75, 0x73, 0x3A, 0x30, 0x0D, 0x0A,
        ]
        let w = try GrokUsage.windows(fromBody: body(bytes),
                                      now: Date(timeIntervalSince1970: 1_768_000_000))
        XCTAssertEqual(w[0].usedFraction ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(w[0].resetsAt?.timeIntervalSince1970 ?? -1, 1_780_272_000, accuracy: 1)
    }

    func testGarbageIsNotMistakenForAReading() {
        for bytes in [[UInt8](), [0x00, 0x00, 0x00, 0x00],
                      [0x00, 0x00, 0x00, 0x00, 0x04, 0x0D, 0x00],
                      [0x08, 0x80]] as [[UInt8]] {
            XCTAssertThrowsError(try GrokUsage.windows(fromBody: body(bytes))) { error in
                guard case UsageProviderError.badResponse = error else {
                    return XCTFail("expected badResponse, got \(error)")
                }
            }
        }
        XCTAssertThrowsError(try GrokUsage.windows(fromBody: "not base64!!!")) { error in
            guard case UsageProviderError.badResponse = error else {
                return XCTFail("expected badResponse, got \(error)")
            }
        }
    }

    /// An unauthenticated RPC means the WebView session lapsed — the remedy is
    /// the sign-in modal, so this maps to needsAuth rather than a generic error.
    func testAnUnauthenticatedRPCAsksToSignIn() {
        let trailer = Array("grpc-status: 16\r\ngrpc-message: token expired\r\n".utf8)
        XCTAssertThrowsError(
            try GrokUsage.windows(fromBody: body(frame(trailer, flags: 0x80)))) { error in
            guard case UsageProviderError.needsAuth = error else {
                return XCTFail("expected needsAuth, got \(error)")
            }
        }
    }

    /// Several timestamps can ride along; the reset is the nearest future one,
    /// never one already past.
    func testTheResetIsTheNearestFutureTimestamp() throws {
        var fixed = Float(33).bitPattern.littleEndian
        var bytes: [UInt8] = [0x0D] + withUnsafeBytes(of: &fixed) { Array($0) }
        bytes += [0x10] + varint(1_800_000_000) // period start, already past
        bytes += [0x18] + varint(1_802_592_000) // billing end
        let w = try GrokUsage.windows(fromBody: body(frame(bytes)),
                                      now: Date(timeIntervalSince1970: 1_800_001_800))
        XCTAssertEqual(w[0].resetsAt?.timeIntervalSince1970 ?? -1, 1_802_592_000, accuracy: 1)
    }
}
