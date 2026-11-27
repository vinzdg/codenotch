import XCTest
@testable import Codenotch

final class ClaudePendingQuestionTests: XCTestCase {
    private func tail(_ records: [[String: Any]]) -> Data {
        Data(records.map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }
            .joined(separator: "\n").utf8)
    }

    private func use(_ id: String, _ name: String, _ input: [String: Any]) -> [String: Any] {
        ["type": "assistant", "message": ["content": [["type": "tool_use", "id": id, "name": name, "input": input]]]]
    }

    func testAQuestionWithChoices() throws {
        let q = try XCTUnwrap(ClaudePendingQuestion.read(tail: tail([use("t1", "AskUserQuestion", [
            "questions": [["question": "Which colour?", "options": [
                ["label": "Blue", "description": "calm"], ["label": "Red", "description": "loud"]]]],
        ])])))
        XCTAssertEqual(q.title, "Which colour?")
        XCTAssertEqual(q.choices.map(\.label), ["Blue", "Red"])
        XCTAssertEqual(q.choices.map(\.key), ["1", "2"])
    }

    func testAToolWaitingIsAPermissionPrompt() throws {
        let q = try XCTUnwrap(ClaudePendingQuestion.read(tail: tail([use("t2", "Bash", ["command": "rm -rf build"])])))
        XCTAssertEqual(q.title, "Allow: Running rm -rf build?")
        XCTAssertEqual(q.choices.count, 3)
    }

    func testAnAnsweredOneIsNotShown() {
        let result: [String: Any] = ["type": "user", "message": ["content": [
            ["type": "tool_result", "tool_use_id": "t3", "content": "ok"]]]]
        XCTAssertNil(ClaudePendingQuestion.read(tail: tail([use("t3", "Read", ["file_path": "/a"]), result])))
    }
}
