import XCTest
@testable import Codenotch

final class ClaudeConversationTests: XCTestCase {
    func testYourWordsAndClaudesNotTheTools() {
        let records: [[String: Any]] = [
            ["type": "user", "uuid": "1", "message": ["content": "fix the header"]],
            ["type": "assistant", "uuid": "2", "message": ["content": [
                ["type": "text", "text": "Looking at it."], ["type": "tool_use", "name": "Read", "input": [:]]]]],
            ["type": "user", "uuid": "3", "message": ["content": [["type": "tool_result", "content": "file"]]]],
            ["type": "user", "uuid": "4", "message": ["content": "<command-name>/model</command-name>"]],
            ["type": "assistant", "uuid": "5", "message": ["content": [["type": "text", "text": "Done."]]]],
        ]
        let data = Data(records.map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }
            .joined(separator: "\n").utf8)
        let messages = ClaudeConversation.read(tail: data)
        XCTAssertEqual(messages.map(\.text), ["fix the header", "Looking at it.", "Done."])
        XCTAssertEqual(messages.map(\.role), [.you, .claude, .claude])
    }
}
