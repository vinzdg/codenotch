import XCTest
import SwiftUI
@testable import Codenotch

/// Renders the permission card in both of its shapes, inside the real notch.
/// A smoke test for its layout, and a way to look at it: set
/// `PERMISSION_RENDER_DIR` and one PNG per shape is written there.
@MainActor
final class PermissionCardRenderTests: XCTestCase {
    private func request(_ tool: String, _ input: String, suggestions: String = "[]") throws -> PermissionRequest {
        try XCTUnwrap(PermissionRequest.decode(Data("""
        {"session_id":"s","cwd":"/Users/me/api","hook_event_name":"PermissionRequest",
         "tool_name":"\(tool)","tool_input":\(input),"permission_suggestions":\(suggestions)}
        """.utf8)))
    }

    func testOpenedIdleGroupRendersUnderItsHeader() throws {
        let now = Date()
        let session = { (name: String, state: AgentSession.State, minutes: Double) in
            AgentSession(id: name, name: name, detail: "Terminal · \(name)", state: state, waitingFor: nil,
                         since: now.addingTimeInterval(-minutes * 60), processID: 1)
        }
        let model = NotchViewModel()
        model.edge = .right
        model.snapshots = Fixtures.snapshots()
        model.now = now
        model.sessions = ["claude": [session("mayron-42", .busy, 4), session("cantio-70", .idle, 1),
                                     session("tideline-c9", .idle, 25), session("website", .idle, 40)]]
        model.isExpanded = true
        model.hoveredIndex = 0
        model.showsIdleSessions = true
        let renderer = ImageRenderer(content: NotchRootView(model: model)
            .frame(width: model.panelSize.width, height: model.panelSize.height)
            .background(Color(white: 0.2))
            .environment(\.colorScheme, .dark))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        if let dir = ProcessInfo.processInfo.environment["PERMISSION_RENDER_DIR"] {
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("idle-open.png"))
        }
    }

    func testCompletionCardRendersBesideItsRing() throws {
        let model = NotchViewModel()
        model.edge = .right
        model.snapshots = Fixtures.snapshots()
        model.isExpanded = true
        // Two waiting, so the first card shows "1 more waiting".
        model.completions = ["claude.1", "claude.2"].map { id in
            SessionCompletionWatcher.Event(
                session: AgentSession(id: id, name: "fix auth bug", detail: "iTerm2 · api",
                                      state: .idle, waitingFor: nil, since: Date(), processID: 1),
                reason: .finished, providerID: "claude")
        }
        let renderer = ImageRenderer(content: NotchRootView(model: model)
            .frame(width: model.panelSize.width, height: model.panelSize.height)
            .background(Color(white: 0.45))
            .environment(\.colorScheme, .dark))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        if let dir = ProcessInfo.processInfo.environment["PERMISSION_RENDER_DIR"] {
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("completion.png"))
        }
    }

    func testBothShapesRenderBesideTheClaudeRing() throws {
        let cases = [
            ("edit", try request("Edit", #"{"file_path":"/Users/me/api/src/auth/middleware.ts","old_string":"  jwt.verify(token);","new_string":"  if (!token) throw new AuthError('missing');\n  return jwt.verify(token);"}"#)),
            ("bash", try request("Bash", #"{"command":"python3 - <<'EOF'\nprint('hi')\nEOF","description":"Read permission suggestions"}"#, suggestions: #"[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"python3 -c *"}]},{"type":"setMode","mode":"auto"}]"#)),
            ("plan", try request("ExitPlanMode", ##"{"plan":"# Floating player window\n\nReuse the FloatingLyricsWindow class at a fixed size.\n\n## Steps\n1. Add a Show player row\n2. Glass / Black picker in Settings"}"##)),
            ("question", try request("AskUserQuestion", #"{"questions":[{"question":"Which deployment target?","options":[{"label":"Production"},{"label":"Staging"},{"label":"Local only"}]}]}"#)),
        ]
        for (name, request) in cases {
            let model = NotchViewModel()
            model.edge = .right
            model.snapshots = Fixtures.snapshots()
            model.isExpanded = true
            model.permissionRequests = [request]
            let renderer = ImageRenderer(content: NotchRootView(model: model)
                .frame(width: model.panelSize.width, height: model.panelSize.height)
                .background(Color(white: 0.45))
                .environment(\.colorScheme, .dark))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage, name)
            if let dir = ProcessInfo.processInfo.environment["PERMISSION_RENDER_DIR"] {
                let tiff = try XCTUnwrap(image.tiffRepresentation)
                let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
            }
            let height = PermissionCard.height(for: request, limit: model.permissionCardLimit)
            XCTAssertLessThanOrEqual(height, model.panelSize.height, "\(name) outgrows the panel")
            XCTAssertLessThanOrEqual(PermissionCard.width, model.panelSize.width, "the panel cannot hold the card's width")
        }
    }
}
