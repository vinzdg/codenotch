import XCTest
@testable import Codenotch

final class ClaudeLiveActivityTests: XCTestCase {
    private func tail(_ records: [[String: Any]]) -> Data {
        // A cut first line, as a real tail starts mid-record.
        var text = "{\"type\":\"assist\n"
        for record in records {
            text += String(data: try! JSONSerialization.data(withJSONObject: record), encoding: .utf8)! + "\n"
        }
        return Data(text.utf8)
    }

    private let prompt: [String: Any] = [
        "type": "user", "timestamp": "2026-11-27T03:00:00.000Z",
        "message": ["role": "user", "content": "fix the sidebar"],
    ]

    private func reply(id: String, tokens: Int, blocks: [[String: Any]]) -> [String: Any] {
        ["type": "assistant",
         "message": ["id": id, "content": blocks, "usage": ["output_tokens": tokens]]]
    }

    func testARunningToolIsSaidAsTheTerminalSaysIt() throws {
        let data = tail([prompt, reply(id: "m1", tokens: 120, blocks: [
            ["type": "text", "text": "Let me look."],
            ["type": "tool_use", "name": "Edit", "input": ["file_path": "/x/Sources/DockChatView.swift"]],
        ])])
        let live = try XCTUnwrap(ClaudeLiveActivity.read(tail: data))
        XCTAssertEqual(live.doing, "Editing DockChatView.swift")
        XCTAssertEqual(live.tokens, 120)
        XCTAssertEqual(live.startedAt, ISO8601DateFormatter().date(from: "2026-11-27T03:00:00Z"))
    }

    func testAToolResultBackMeansItIsThinkingAgain() throws {
        let result: [String: Any] = ["type": "user", "message": ["content": [
            ["type": "tool_result", "tool_use_id": "t1", "content": "ok"]]]]
        let data = tail([prompt,
                         reply(id: "m1", tokens: 50, blocks: [["type": "tool_use", "name": "Read",
                                                               "input": ["file_path": "/a/b.swift"]]]),
                         result])
        let live = try XCTUnwrap(ClaudeLiveActivity.read(tail: data))
        XCTAssertNil(live.doing, "between tools it is thinking, which has no description")
        XCTAssertEqual(live.tokens, 50, "the tool result is not a new prompt; the turn goes on")
    }

    func testOneReplyWrittenAsSeveralRecordsIsCountedOnce() throws {
        let data = tail([prompt,
                         reply(id: "m1", tokens: 300, blocks: [["type": "thinking", "thinking": "…"]]),
                         reply(id: "m1", tokens: 300, blocks: [["type": "text", "text": "Done."]]),
                         reply(id: "m2", tokens: 40, blocks: [["type": "tool_use", "name": "Bash",
                                                               "input": ["command": "make build",
                                                                         "description": "Build the app"]]])])
        let live = try XCTUnwrap(ClaudeLiveActivity.read(tail: data))
        XCTAssertEqual(live.tokens, 340)
        XCTAssertEqual(live.doing, "Running build the app")
    }

    func testOnlyThisTurnCounts() throws {
        let earlier = reply(id: "old", tokens: 9_000, blocks: [["type": "text", "text": "before"]])
        let data = tail([["type": "user", "message": ["content": "first"]], earlier,
                         prompt, reply(id: "new", tokens: 10, blocks: [["type": "text", "text": "hi"]])])
        XCTAssertEqual(try XCTUnwrap(ClaudeLiveActivity.read(tail: data)).tokens, 10)
    }

    func testASubagentsRecordsAreNotTheSessions() throws {
        var side = reply(id: "s1", tokens: 999, blocks: [["type": "tool_use", "name": "Grep",
                                                          "input": ["pattern": "foo"]]])
        side["isSidechain"] = true
        let data = tail([prompt, reply(id: "m1", tokens: 5, blocks: [["type": "tool_use", "name": "Task",
                                                                     "input": ["description": "Explore the code"]]]),
                         side])
        let live = try XCTUnwrap(ClaudeLiveActivity.read(tail: data))
        XCTAssertEqual(live.doing, "Agent: Explore the code")
        XCTAssertEqual(live.tokens, 5)
    }

    func testATurnThatStartedBeforeTheTailStillSaysWhatItIsDoing() throws {
        let data = tail([reply(id: "m9", tokens: 70, blocks: [["type": "tool_use", "name": "Read",
                                                               "input": ["file_path": "/a/Notes.md"]]])])
        let live = try XCTUnwrap(ClaudeLiveActivity.read(tail: data))
        XCTAssertEqual(live.doing, "Reading Notes.md")
        XCTAssertEqual(live.tokens, 0, "only part of the turn is in view: no count that could fall")
        XCTAssertNil(live.startedAt, "the turn's start is not in the tail")
    }

    func testTokensReadLikeTheTerminal() {
        XCTAssertEqual(ClaudeLiveActivity.tokensText(980), "↓ 980")
        XCTAssertEqual(ClaudeLiveActivity.tokensText(2_340), "↓ 2.3k")
    }
}
