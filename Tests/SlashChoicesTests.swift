import XCTest
@testable import Codenotch

@MainActor
final class SlashChoicesTests: XCTestCase {
    private func model() -> DockChatModel {
        let m = DockChatModel()
        m.setTargetsForTesting([.init(id: "a", name: "x", state: .idle, since: Date(), pid: getpid(), app: "Code",
                                      providerID: "claude", repository: nil, ancestry: [1], tty: nil,
                                      sessionsDirectory: URL(fileURLWithPath: "/tmp"),
                                      projectsDirectory: URL(fileURLWithPath: "/tmp"))], selected: "a")
        return m
    }

    func testPickingModelListsTheModelsInThePill() {
        let m = model()
        m.composed(display: "/mode", outgoing: "/mode", images: 0)
        XCTAssertEqual(m.slashMatches.first?.name, "model")
        m.acceptSlash(send: true)
        XCTAssertEqual(m.slashMatches.map(\.name).first, "model default", "the models, not a send")
        m.composed(display: "/model ", outgoing: "/model ", images: 0)
        XCTAssertEqual(m.slashMatches.count, 5)
        m.composed(display: "/model so", outgoing: "/model so", images: 0)
        XCTAssertEqual(m.slashMatches.map(\.name), ["model sonnet"])
        m.composed(display: "", outgoing: "", images: 0)
        XCTAssertTrue(m.slashMatches.isEmpty)
    }

    func testPickerCommandsAreMarked() {
        XCTAssertTrue(SlashCommand(name: "config", summary: "").opensInTerminal)
        XCTAssertFalse(SlashCommand(name: "compact", summary: "").opensInTerminal)
        XCTAssertEqual(SlashCommand(name: "fast", summary: "").choices?.map(\.name), ["fast on", "fast off"])
        XCTAssertNil(SlashCommand.builtIn.first { $0.name == "agents" }, "removed in Claude Code 2.1")
    }
}
