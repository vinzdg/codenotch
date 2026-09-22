import Foundation
import Testing
@testable import Codenotch

struct PluginSnapshotPayloadTests {
    private let manifest = PluginManifest(
        schema: 1, id: "plugin-codemie-budget", displayName: "CodeMie Budget", version: "0.1.0",
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

        #expect(snapshot.id == "plugin-codemie-budget")
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

    // MARK: - Bounds

    @Test func windowsBeyondTheCapAreDropped() throws {
        let many = (0..<40).map { #"{"id": "w\#($0)", "label": "W \#($0)", "usedFraction": 0.1}"# }
        let decoded = try payload(#"{"windows": [\#(many.joined(separator: ","))]}"#)
        #expect(decoded.snapshot(for: manifest).windows.count == PluginSnapshotPayload.Bounds.windows)
    }

    @Test func textIsCutToLength() throws {
        let long = String(repeating: "x", count: 1_000)
        let decoded = try payload(#"""
        {"plan": "\#(long)", "headlineID": "\#(long)",
         "account": {"label": "\#(long)", "plan": "\#(long)", "source": "\#(long)"},
         "windows": [{"id": "\#(long)", "label": "\#(long)", "group": "\#(long)",
                      "usedText": "\#(long)", "detail": "\#(long)",
                      "money": {"currency": "\#(long)", "spent": 1, "remaining": 1}}]}
        """#)
        let snapshot = decoded.snapshot(for: manifest)
        let window = try #require(snapshot.windows.first)
        let short = PluginSnapshotPayload.Bounds.shortText
        let text = PluginSnapshotPayload.Bounds.text
        #expect(snapshot.plan?.count == short)
        #expect(snapshot.headlineID?.count == short)
        #expect(window.id.count == short)
        #expect(window.label.count == short)
        #expect(window.group?.count == short)
        #expect(window.money?.currency.count == short)
        #expect(window.usedText?.count == text)
        #expect(window.detail?.count == text)
        let account = try #require(decoded.providerAccount())
        #expect(account.label?.count == text)
        #expect(account.plan?.count == text)
        #expect(account.source.count == text)
    }

    @Test func numbersAreClampedAndNonNumbersDropped() throws {
        let decoded = try payload(#"""
        {"windows": [
            {"id": "a", "label": "A", "usedFraction": 250, "remaining": -5, "used": -1,
             "money": {"currency": "USD", "spent": -3, "remaining": 1e300}, "duration": -60},
            {"id": "b", "label": "B", "usedFraction": -1},
            {"id": "c", "label": "C", "usedFraction": 1.2}
        ]}
        """#)
        let windows = decoded.snapshot(for: manifest).windows
        #expect(windows[0].usedFraction == PluginSnapshotPayload.Bounds.fractionCeiling)
        #expect(windows[0].remaining == 0)
        #expect(windows[0].used == 0)
        #expect(windows[0].money?.spent == 0)
        #expect(windows[0].money?.remaining == PluginSnapshotPayload.Bounds.moneyCeiling)
        #expect(windows[0].duration == 0)
        #expect(windows[1].usedFraction == 0)
        #expect(windows[2].usedFraction == 1.2, "a little over is an overage worth showing")
    }

    @Test func resetsAtOutsideTheHorizonIsDropped() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let decoded = try payload(#"""
        {"windows": [
            {"id": "far", "label": "Far", "resetsAt": "2099-01-01T00:00:00Z"},
            {"id": "past", "label": "Past", "resetsAt": "1970-01-02T00:00:00Z"},
            {"id": "soon", "label": "Soon", "resetsAt": "2026-10-01T00:00:00Z"}
        ]}
        """#)
        let windows = decoded.snapshot(for: manifest, now: now).windows
        #expect(windows[0].resetsAt == nil)
        #expect(windows[1].resetsAt == nil)
        #expect(windows[2].resetsAt != nil)
    }

    @Test func retryAfterIsClamped() {
        func hint(_ value: String) -> TimeInterval? {
            PluginSnapshotPayload.retryAfter(in: Data(#"{"retryAfterSeconds": \#(value)}"#.utf8))
        }
        #expect(hint("120") == 120)
        #expect(hint("0") == 1)
        #expect(hint("-5") == 1)
        #expect(hint("999999") == 3_600)
        #expect(PluginSnapshotPayload.retryAfter(in: Data("nope".utf8)) == nil)
    }

    @Test func aPluginSnapshotIsMarkedAsAPlugin() throws {
        let decoded = try payload(#"{"windows": []}"#)
        #expect(decoded.snapshot(for: manifest).isPlugin)
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
