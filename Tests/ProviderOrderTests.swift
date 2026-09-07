import XCTest
@testable import Codenotch

/// The order the rings sit in is the user's, and it has to survive a provider
/// set that changes underneath it — Claude Code contributes one provider per
/// `~/.claude-<slug>` found at launch, so an id can turn up on a Mac that has
/// never seen it and disappear from one that has.
final class ProviderOrderTests: XCTestCase {

    private func arrange(_ ids: [String], by order: [String]) -> [String] {
        ProviderOrder.arrange(ids, by: order, id: { $0 })
    }

    /// Never chosen is not the same as having chosen the order the app ships
    /// with — which is what lets a later version change that order for everyone
    /// who has no opinion.
    func testAnEmptyOrderLeavesTheBuiltInOrderAlone() {
        XCTAssertEqual(arrange(["claude", "cursor", "codex"], by: []),
                       ["claude", "cursor", "codex"])
    }

    func testProvidersFollowTheStoredOrder() {
        XCTAssertEqual(arrange(["claude", "cursor", "codex"], by: ["codex", "claude", "cursor"]),
                       ["codex", "claude", "cursor"])
    }

    /// The regression that matters. A provider added by a new version, or a
    /// profile directory created this morning, is in nobody's stored order —
    /// and a strict sort would silently hide it.
    func testAProviderTheOrderHasNeverSeenStillAppears() {
        let arranged = arrange(["claude", "cursor", "opencode"], by: ["cursor", "claude"])
        XCTAssertEqual(arranged, ["cursor", "claude", "opencode"])
        XCTAssertEqual(arranged.count, 3, "a provider the stored order predates must not vanish")
    }

    /// A `~/.claude-work` that is not on this Mac today. Ordinary, not
    /// corruption — and it must not shift anything else.
    func testAStoredIDWithNoProviderIsIgnored() {
        XCTAssertEqual(arrange(["claude", "cursor"], by: ["cursor", "claude-work", "claude"]),
                       ["cursor", "claude"])
    }

    /// What `UsageStore.order` relies on when it re-applies the order to an
    /// already-sorted `snapshots`: the rings must not shuffle.
    func testArrangingTwiceChangesNothing() {
        let order = ["codex", "claude"]
        let once = arrange(["claude", "cursor", "codex"], by: order)
        XCTAssertEqual(arrange(once, by: order), once)
    }

    /// Settings can only show what was discovered at launch, so writing its list
    /// verbatim would forget where an absent profile sat.
    func testAProfileNotOnThisMacKeepsItsPlace() {
        XCTAssertEqual(
            ProviderOrder.remember(["cursor", "claude"], keeping: ["claude", "cursor", "claude-work"]),
            ["cursor", "claude", "claude-work"]
        )
    }

    func testRememberDoesNotDuplicateAnIDItAlreadyHas() {
        XCTAssertEqual(ProviderOrder.remember(["claude", "cursor"], keeping: ["claude"]),
                       ["claude", "cursor"])
    }

    // MARK: - Coming back on

    private func on(_ ids: String...) -> (String) -> Bool {
        { ids.contains($0) }
    }

    /// The rule: after the ones already connected, not back where it used to
    /// sit. `glm` was first, and does not get to be first again.
    func testAReconnectedProviderJoinsTheEndOfTheConnectedOnes() {
        XCTAssertEqual(
            ProviderOrder.joiningConnected("glm",
                                           in: ["glm", "claude", "codex", "gemini"],
                                           isConnected: on("claude", "codex")),
            ["claude", "codex", "glm", "gemini"]
        )
    }

    /// "The end of the connected ones" with none connected is the top, not the
    /// bottom — the first thing switched on has nothing to queue behind.
    func testTheFirstProviderSwitchedOnGoesToTheTop() {
        XCTAssertEqual(
            ProviderOrder.joiningConnected("codex",
                                           in: ["claude", "codex", "cursor"],
                                           isConnected: on()),
            ["codex", "claude", "cursor"]
        )
    }

    /// It joins the connected block, not the switched-off one it was sitting
    /// in — even when that means moving up past other switched-off rows.
    func testItDoesNotSettleAmongTheOtherSwitchedOffOnes() {
        XCTAssertEqual(
            ProviderOrder.joiningConnected("opencode",
                                           in: ["claude", "glm", "gemini", "opencode"],
                                           isConnected: on("claude")),
            ["claude", "opencode", "glm", "gemini"]
        )
    }

    /// Arriving must not reshuffle the arrangement it is arriving into.
    func testTheConnectedOrderIsUndisturbed() {
        let after = ProviderOrder.joiningConnected("glm",
                                                   in: ["glm", "codex", "claude", "cursor"],
                                                   isConnected: on("codex", "claude", "cursor"))

        XCTAssertEqual(after.filter { $0 != "glm" }, ["codex", "claude", "cursor"])
        XCTAssertEqual(after.last, "glm")
    }
}
