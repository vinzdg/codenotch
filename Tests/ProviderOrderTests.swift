import XCTest
@testable import Codenotch

/// The notch shows providers in the order the user arranges them, and a
/// provider missing from that order must still appear rather than vanish.
@MainActor
final class ProviderOrderTests: XCTestCase {
    private struct Stub: UsageProvider {
        let id: String
        let displayName: String
        let glyph = ProviderGlyph.third
        func fetchSnapshot() async throws -> ProviderSnapshot {
            ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                             fidelity: .official, status: .ok, windows: [])
        }
    }

    private func providers(_ ids: String...) -> [UsageProvider] {
        ids.map { Stub(id: $0, displayName: $0) }
    }

    func testTheNamedOrderWins() {
        let sorted = UsageStore.ordered(providers("a", "b", "c"), by: ["c", "a", "b"])
        XCTAssertEqual(sorted.map(\.id), ["c", "a", "b"])
    }

    /// Anything the order does not name trails the named ones, in its natural
    /// order — a provider added in a later version appears instead of
    /// vanishing behind a stale saved arrangement.
    func testUnnamedProvidersTrailingInNaturalOrder() {
        let sorted = UsageStore.ordered(providers("a", "b", "c", "d"), by: ["d", "b"])
        XCTAssertEqual(sorted.map(\.id), ["d", "b", "a", "c"])
    }

    func testAnEmptyOrderChangesNothing() {
        let sorted = UsageStore.ordered(providers("a", "b"), by: [])
        XCTAssertEqual(sorted.map(\.id), ["a", "b"])
    }

    func testReorderRearrangesTheLiveSnapshots() {
        let store = UsageStore(providers: providers("a", "b", "c"))
        store.reorder(["c", "a"])
        XCTAssertEqual(store.providerSummaries.map(\.id), ["c", "a", "b"])
    }
}
