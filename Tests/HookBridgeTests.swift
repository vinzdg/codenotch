import XCTest
@testable import Codenotch

final class HookBridgeTests: XCTestCase {
    private func payload(tool: String, input: String, cwd: String = "/Users/me/api") -> Data {
        Data("""
        {"session_id":"s1","cwd":"\(cwd)","hook_event_name":"PermissionRequest",
         "tool_name":"\(tool)","tool_input":\(input),"tool_use_id":"toolu_1"}
        """.utf8)
    }

    private func decision(_ body: Data) -> [String: Any]? {
        let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        return (root?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
    }

    func testEditBecomesADiffWithAPathRelativeToTheProject() throws {
        let request = try XCTUnwrap(PermissionRequest.decode(payload(tool: "Edit", input: """
        {"file_path":"/Users/me/api/src/auth.ts","old_string":"a\\nb","new_string":"c"}
        """)))
        XCTAssertEqual(request.project, "api")
        XCTAssertEqual(request.kind, .tool(name: "Edit", target: "src/auth.ts", preview: .init(lines: [
            .init(mark: .removed, text: "a"), .init(mark: .removed, text: "b"), .init(mark: .added, text: "c"),
        ])))
    }

    /// The edit from the live test: one line added between two unchanged ones
    /// shows as context, one green line, context — not the block twice over.
    func testEditShowsOnlyTheRealChangeWithContext() {
        let old = ["export function verify(token: string) {",
                   "  return jwt.verify(token, process.env.JWT_SECRET!);"]
        let new = ["export function verify(token: string) {",
                   "  if (!token) throw new Error(\"missing token\");",
                   "  return jwt.verify(token, process.env.JWT_SECRET!);"]
        XCTAssertEqual(PermissionRequest.diff(from: old, to: new).map(\.mark), [.context, .added, .context])
    }

    func testTheAskingProcessIsFoundInTheSessionRegistry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"pid":4242,"sessionId":"abc","cwd":"/p"}"#.utf8).write(to: directory.appendingPathComponent("4242.json"))
        try Data(#"{"pid":7,"sessionId":"other","cwd":"/p"}"#.utf8).write(to: directory.appendingPathComponent("7.json"))
        XCTAssertEqual(HookBridge.processID(forSession: "abc", in: [directory]), 4242)
        XCTAssertNil(HookBridge.processID(forSession: "missing", in: [directory]))
    }

    /// Leaving plan mode offers the modes Zed and the terminal offer, each
    /// answered with a setMode; there is no bare "Yes".
    func testExitPlanModeOffersTheNextMode() throws {
        let request = try XCTUnwrap(PermissionRequest.decode(payload(tool: "ExitPlanMode", input: """
        {"plan":"# Floating player\\n\\nReuse the lyrics window.\\n\\n## Steps\\n1. Build it"}
        """)))
        XCTAssertTrue(request.isPlan)
        guard case .tool(_, let target, let preview) = request.kind else { return XCTFail("not a tool") }
        XCTAssertEqual(target, "Floating player")
        XCTAssertEqual(preview?.lines.map(\.text), ["Reuse the lyrics window.", "## Steps", "1. Build it"])
        XCTAssertEqual(PermissionCard.toolChoices(request).map(\.label), [
            "Yes, and auto-accept edits", "Yes, manually approve edits", "Yes, and use auto mode",
            "Yes, and bypass permissions", "No, keep planning",
        ])
        let body = PermissionCard.toolChoices(request)[1].decision.responseBody(for: request)
        XCTAssertEqual((decision(body)?["updatedPermissions"] as? [[String: String]])?.first?["mode"], "default")
        // Without the input echoed back, an SDK host (Zed) ignores the allow.
        XCTAssertNotNil((decision(body)?["updatedInput"] as? [String: Any])?["plan"])
    }

    /// A payload with no transcript_path still finds its transcript by id.
    func testTheTranscriptIsFoundBySessionWhenThePayloadLeavesItOut() throws {
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("profile-\(UUID())")
        defer { try? FileManager.default.removeItem(at: profile) }
        let folder = profile.appendingPathComponent("projects/-Users-me-api")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("abc.jsonl"))
        let sessions = profile.appendingPathComponent("sessions")
        XCTAssertEqual(HookBridge.transcript(forSession: "abc", in: [sessions]),
                       folder.appendingPathComponent("abc.jsonl").path)
        XCTAssertNil(HookBridge.transcript(forSession: "zzz", in: [sessions]))
    }

    func testBashShowsItsDescriptionAndTheCommandBelow() throws {
        let request = try XCTUnwrap(PermissionRequest.decode(payload(
            tool: "Bash", input: #"{"command":"npm test","description":"Run the tests"}"#)))
        XCTAssertEqual(request.kind, .tool(name: "Bash", target: "Run the tests",
                                           preview: .init(lines: [.init(mark: .plain, text: "npm test")])))
    }

    /// The terminal's "Yes, and…" rows arrive as permission_suggestions, are
    /// worded like the terminal words them, and go back untouched.
    func testSuggestionsBecomeChoicesAndAreEchoedBack() throws {
        let data = Data("""
        {"cwd":"/p","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"python3 -c 1"},
         "permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"python3 -c *"}],"behavior":"allow","destination":"localSettings"},
                                   {"type":"setMode","mode":"acceptEdits","destination":"session"}]}
        """.utf8)
        let request = try XCTUnwrap(PermissionRequest.decode(data))
        XCTAssertEqual(request.suggestions.map(\.label),
                       ["Yes, and don't ask again for: python3 -c *", "Yes, allow all edits this session"])
        XCTAssertEqual(PermissionCard.toolChoices(request).map(\.label),
                       ["Yes", "Yes, and don't ask again for: python3 -c *", "Yes, allow all edits this session", "No"])

        let body = PermissionDecision.allowRemembering(request.suggestions[1].value).responseBody(for: request)
        let updated = try XCTUnwrap(decision(body)?["updatedPermissions"] as? [[String: String]])
        XCTAssertEqual(updated, [["type": "setMode", "mode": "acceptEdits", "destination": "session"]])
    }

    func testOtherHookEventsAreIgnored() {
        let data = Data(#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{}}"#.utf8)
        XCTAssertNil(PermissionRequest.decode(data))
    }

    func testAskUserQuestionIsDecodedAsQuestions() throws {
        let request = try XCTUnwrap(PermissionRequest.decode(payload(tool: "AskUserQuestion", input: """
        {"questions":[{"question":"Which target?","header":"Deploy","multiSelect":false,
          "options":[{"label":"Production","description":"live"},{"label":"Staging","description":""}]}]}
        """)))
        XCTAssertEqual(request.kind, .questions([.init(question: "Which target?", header: "Deploy",
                                                       options: ["Production", "Staging"], multiSelect: false)]))
    }

    func testAllowAndDenyReplies() throws {
        let request = try XCTUnwrap(PermissionRequest.decode(payload(tool: "Bash", input: #"{"command":"ls"}"#)))
        XCTAssertEqual(decision(PermissionDecision.allow.responseBody(for: request))?["behavior"] as? String, "allow")
        XCTAssertEqual(decision(PermissionDecision.deny.responseBody(for: request))?["behavior"] as? String, "deny")
        XCTAssertEqual(PermissionDecision.passThrough.responseBody(for: request), Data("{}".utf8))
    }

    /// Every allow echoes the input: an SDK host ignores an allow without it.
    func testAllowEchoesTheInput() throws {
        let request = try XCTUnwrap(PermissionRequest.decode(payload(tool: "Bash", input: #"{"command":"ls"}"#)))
        let updated = decision(PermissionDecision.allow.responseBody(for: request))?["updatedInput"] as? [String: String]
        XCTAssertEqual(updated, ["command": "ls"])
    }

    /// The answer rides back as the original input plus `answers`: anything
    /// dropped from `questions` would be dropped for the tool too.
    func testAnswerEchoesTheInputWithAnswers() throws {
        let request = try XCTUnwrap(PermissionRequest.decode(payload(tool: "AskUserQuestion", input: """
        {"questions":[{"question":"Which target?","options":[{"label":"Staging"}]}]}
        """)))
        let body = PermissionDecision.answer(["Which target?": "Staging"]).responseBody(for: request)
        let updated = try XCTUnwrap(decision(body)?["updatedInput"] as? [String: Any])
        XCTAssertEqual(updated["answers"] as? [String: String], ["Which target?": "Staging"])
        XCTAssertEqual((updated["questions"] as? [Any])?.count, 1)
    }

    /// The whole trip: a POST is held open until the notch answers it.
    @MainActor
    func testServerHoldsTheRequestUntilAnswered() async throws {
        let bridge = HookBridge()
        bridge.start(port: 11499)
        defer { Task { await bridge.stop() } }
        try await Task.sleep(nanoseconds: 300_000_000)

        var post = URLRequest(url: URL(string: "http://127.0.0.1:11499\(HookBridgeServer.path)")!)
        post.httpMethod = "POST"
        post.httpBody = payload(tool: "Bash", input: #"{"command":"ls"}"#)
        let response = Task { try await URLSession.shared.data(for: post).0 }

        for _ in 0..<50 where bridge.pending.isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
        let id = try XCTUnwrap(bridge.pending.first?.id)
        bridge.answer(id, .allow)

        let body = try await response.value
        XCTAssertEqual(decision(body)?["behavior"] as? String, "allow")
        XCTAssertTrue(bridge.pending.isEmpty)
    }

    /// A browser always sends Origin; Claude Code never does. A web page must
    /// not be able to put a card on the notch.
    @MainActor
    func testServerRefusesARequestWithAnOrigin() async throws {
        let bridge = HookBridge()
        bridge.start(port: 11498)
        defer { Task { await bridge.stop() } }
        try await Task.sleep(nanoseconds: 300_000_000)

        var post = URLRequest(url: URL(string: "http://127.0.0.1:11498\(HookBridgeServer.path)")!)
        post.httpMethod = "POST"
        post.setValue("https://example.com", forHTTPHeaderField: "Origin")
        post.httpBody = payload(tool: "Bash", input: #"{"command":"ls"}"#)
        let (_, response) = try await URLSession.shared.data(for: post)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 403)
        XCTAssertTrue(bridge.pending.isEmpty)
    }

    /// A card nobody answers hands the prompt back rather than hold the session.
    @MainActor
    func testUnansweredRequestIsHandedBack() async throws {
        let bridge = HookBridge(giveUpAfter: 0.2)
        let request = try XCTUnwrap(PermissionRequest.decode(payload(tool: "Bash", input: #"{"command":"ls"}"#)))
        let handedBack = expectation(description: "handed back")
        bridge.receive(request) { if $0 == .passThrough { handedBack.fulfill() } }
        XCTAssertEqual(bridge.pending.count, 1)
        await fulfillment(of: [handedBack], timeout: 2)
        XCTAssertTrue(bridge.pending.isEmpty)
    }

    // MARK: settings.json

    func testInstallKeepsOtherHooksAndRemovalRestoresThem() {
        let theirs: [String: Any] = [
            "model": "opus",
            "hooks": ["PermissionRequest": [["matcher": "Bash", "hooks": [["type": "command", "command": "x"]]]],
                      "Stop": [["hooks": [["type": "command", "command": "y"]]]]],
        ]
        let installed = ClaudeHookInstaller.installing(into: theirs)
        XCTAssertTrue(ClaudeHookInstaller.isInstalled(in: installed))
        XCTAssertEqual(((installed["hooks"] as? [String: Any])?["PermissionRequest"] as? [Any])?.count, 2)

        // Installing twice is still one entry of ours.
        let twice = ClaudeHookInstaller.installing(into: installed)
        XCTAssertEqual(((twice["hooks"] as? [String: Any])?["PermissionRequest"] as? [Any])?.count, 2)

        let removed = ClaudeHookInstaller.removing(from: twice)
        XCTAssertFalse(ClaudeHookInstaller.isInstalled(in: removed))
        XCTAssertEqual(NSDictionary(dictionary: removed), NSDictionary(dictionary: theirs))
    }

    func testRemovingTheOnlyHookLeavesNoEmptyHooksKey() {
        let removed = ClaudeHookInstaller.removing(from: ClaudeHookInstaller.installing(into: ["model": "opus"]))
        XCTAssertEqual(NSDictionary(dictionary: removed), NSDictionary(dictionary: ["model": "opus"]))
    }

    /// A prompt answered in the terminal shows up as a tool_result in the
    /// transcript, and that is what takes the card down.
    func testAnsweredElsewhereReadsTheTranscript() throws {
        let transcript = FileManager.default.temporaryDirectory.appendingPathComponent("hook-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: transcript) }
        try Data(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_9"}]}}"#.utf8).write(to: transcript)
        var request = try XCTUnwrap(PermissionRequest.decode(payload(tool: "Bash", input: #"{"command":"ls"}"#)))
        request.transcriptPath = transcript.path
        request.toolUseID = "toolu_9"
        XCTAssertFalse(HookBridge.answeredElsewhere(request))

        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n{\"type\":\"user\",\"message\":{\"content\":[{\"tool_use_id\":\"toolu_9\",\"type\":\"tool_result\"}]}}".utf8))
        try handle.close()
        XCTAssertTrue(HookBridge.answeredElsewhere(request))
    }

    /// Zed's payload names no tool_use_id; the call is matched by its input,
    /// so a card answered in Zed still comes down.
    func testAnsweredElsewhereFindsTheCallByInputWithoutAToolUseID() throws {
        let transcript = FileManager.default.temporaryDirectory.appendingPathComponent("hook-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: transcript) }
        try Data("""
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_old","input":{"command":"pwd"}}]}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_7","input":{"command":"ls"}}]}}
        """.utf8).write(to: transcript)
        var request = try XCTUnwrap(PermissionRequest.decode(payload(tool: "Bash", input: #"{"command":"ls"}"#)))
        request.transcriptPath = transcript.path
        request.toolUseID = nil
        XCTAssertFalse(HookBridge.answeredElsewhere(request))

        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n{\"type\":\"user\",\"message\":{\"content\":[{\"tool_use_id\":\"toolu_7\",\"type\":\"tool_result\"}]}}".utf8))
        try handle.close()
        XCTAssertTrue(HookBridge.answeredElsewhere(request))
    }
}
