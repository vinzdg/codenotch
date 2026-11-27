import XCTest
@testable import Codenotch

final class SlashCommandTests: XCTestCase {
    func testNamesThatStartWithTheQueryComeFirst() {
        let commands = [SlashCommand(name: "context", summary: ""), SlashCommand(name: "compact", summary: ""),
                        SlashCommand(name: "accompany", summary: ""), SlashCommand(name: "model", summary: "")]
        XCTAssertEqual(SlashCommand.matching("comp", in: commands).map(\.name), ["compact", "accompany"])
        XCTAssertEqual(SlashCommand.matching("", in: commands, limit: 2).count, 2)
        XCTAssertTrue(SlashCommand.matching("zzz", in: commands).isEmpty)
    }

    func testARepositorysCommandsAndSkillsAreFound() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let commands = repo.appendingPathComponent(".claude/commands/frontend")
        let skill = repo.appendingPathComponent(".claude/skills/release-notes")
        try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        try "---\ndescription: \"Lint the UI\"\n---\nRun the linter.".write(
            to: commands.appendingPathComponent("lint.md"), atomically: true, encoding: .utf8)
        try "---\nname: notes\ndescription: Write release notes\n---\n".write(
            to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let found = SlashCommand.available(cwd: repo.path)
        XCTAssertEqual(found.first { $0.name == "frontend:lint" }?.summary, "Lint the UI")
        XCTAssertEqual(found.first { $0.name == "notes" }?.summary, "Write release notes")
        XCTAssertNotNil(found.first { $0.name == "compact" }, "the built-ins are always there")
    }
}
