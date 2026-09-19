import Foundation
import Testing
@testable import Codenotch

struct PluginSnapshotPayloadTests {
    private let manifest = PluginManifest(
        schema: 1, id: "codemie-budget", displayName: "CodeMie Budget", version: "0.1.0",
        exec: PluginManifest.Exec(path: "/bin/sh", args: ["snapshot"], timeoutSeconds: nil),
        glyph: nil, signIn: nil, activity: nil)

    private func payload(_ json: String) throws -> PluginSnapshotPayload {
        try PluginSnapshotPayload.decoder().decode(PluginSnapshotPayload.self, from: Data(json.utf8))
    }

    @Test func mapsAMoneyWindowToASnapshot() throws {
        let decoded = try payload(#"""
        {
            "fidelity": "official",
            "plan": "CodeMie SSO",
            "headlineID": "budget",
            "account": {"label": "dev@example.com", "plan": "codemie-sso",
                        "source": "CodeMie CLI", "manageURL": "https://codemie.example.com"},
            "windows": [{
                "id": "budget", "label": "CLI budget", "usedFraction": 0.0842,
                "detail": "$4.21 of $50.00",
                "money": {"currency": "USD", "spent": 4.21, "remaining": 45.79},
                "resetsAt": "2026-10-01T00:00:00Z"
            }]
        }
        """#)

        let snapshot = decoded.snapshot(for: manifest)

        #expect(snapshot.id == "codemie-budget")
        #expect(snapshot.displayName == "CodeMie Budget")
        #expect(snapshot.glyph == .external)
        #expect(snapshot.fidelity == .official)
        #expect(snapshot.plan == "CodeMie SSO")
        #expect(snapshot.headlineID == "budget")
        #expect(snapshot.windows.count == 1)

        let window = try #require(snapshot.windows.first)
        #expect(window.id == "budget")
        #expect(window.label == "CLI budget")
        #expect(window.usedFraction != nil && abs(window.usedFraction! - 0.0842) < 0.0001)
        #expect(window.detail == "$4.21 of $50.00")
        #expect(window.money == UsageMoneyBreakdown(currency: "USD", spent: 4.21, remaining: 45.79))
        // 2026-10-01T00:00:00Z, verified against `date -u -j`.
        #expect(window.resetsAt != nil && abs(window.resetsAt!.timeIntervalSince1970 - 1_790_812_800) < 1)
    }

    @Test func parsesFractionalSecondsAndOffsetsInDates() throws {
        let decoded = try payload(#"""
        {"windows": [
            {"id": "a", "label": "A", "resetsAt": "2026-10-01T00:00:00.500Z"},
            {"id": "b", "label": "B", "resetsAt": "2026-10-01T02:00:00+02:00"}
        ]}
        """#)
        let snapshot = decoded.snapshot(for: manifest)
        let first = try #require(snapshot.windows.first?.resetsAt)
        let second = try #require(snapshot.windows.last?.resetsAt)
        #expect(abs(first.timeIntervalSince1970 - 1_790_812_800.5) < 0.001)
        #expect(abs(second.timeIntervalSince1970 - 1_790_812_800) < 1)
    }

    @Test func identityComesFromTheManifestNotThePayload() throws {
        // A payload has no id/displayName/glyph fields at all; what the cell
        // says is the manifest's business.
        let decoded = try payload(#"{"windows": []}"#)
        let snapshot = decoded.snapshot(for: manifest)
        #expect(snapshot.id == manifest.id)
        #expect(snapshot.displayName == manifest.displayName)
        #expect(snapshot.glyph == .external)
    }

    @Test func fidelityDefaultsToOfficial() throws {
        let decoded = try payload(#"{"windows": []}"#)
        #expect(decoded.snapshot(for: manifest).fidelity == .official)
    }

    @Test func anUnknownFidelityDegradesToDerived() throws {
        let decoded = try payload(#"{"fidelity": "vendor-pinkie-promise", "windows": []}"#)
        #expect(decoded.snapshot(for: manifest).fidelity == .derived)
    }

    @Test func mapsTheAccount() throws {
        let decoded = try payload(#"""
        {"windows": [], "account": {"label": "dev@example.com", "plan": "codemie-sso",
                                    "source": "CodeMie CLI", "manageURL": "https://codemie.example.com"}}
        """#)
        let account = try #require(decoded.providerAccount())
        #expect(account.label == "dev@example.com")
        #expect(account.plan == "codemie-sso")
        #expect(account.source == "CodeMie CLI")
        #expect(account.manageURL?.absoluteString == "https://codemie.example.com")
    }

    @Test func missingAccountStaysMissing() throws {
        let decoded = try payload(#"{"windows": []}"#)
        #expect(decoded.providerAccount() == nil)
    }

    @Test(arguments: ["https://example.com/usage", "HTTPS://example.com/usage"])
    func anHTTPSManageURLSurvives(url: String) throws {
        // URL schemes are case-insensitive; an uppercase HTTPS must survive too.
        let decoded = try payload(#"{"account": {"manageURL": "\#(url)"}, "windows": []}"#)
        #expect(decoded.providerAccount()?.manageURL == URL(string: url))
    }

    @Test(arguments: ["http://example.com/usage", "file:///etc/passwd",
                      "javascript:alert(1)", "codenotch://internal",
                      "example.com/usage", "//example.com/usage"])
    func aNonHTTPSManageURLIsDropped(url: String) throws {
        let decoded = try payload(#"{"account": {"manageURL": "\#(url)"}, "windows": []}"#)
        #expect(decoded.providerAccount()?.manageURL == nil)
    }

    @Test func externalGlyphSurvivesAnArchiveRoundTrip() throws {
        // The archive persists the glyph enum; one undecodable entry would
        // invalidate every archived reading, so `.external` has to round-trip.
        let data = try JSONEncoder().encode(ProviderGlyph.external)
        #expect(String(data: data, encoding: .utf8) == #""external""#)
        #expect(try JSONDecoder().decode(ProviderGlyph.self, from: data) == .external)
    }
}
