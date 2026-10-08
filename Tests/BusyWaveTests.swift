import AppKit
import SwiftUI
import XCTest
@testable import Codenotch

final class BusyWaveTests: XCTestCase {
    /// `ProviderGlyph` is not `CaseIterable`, so a glyph added later has to be
    /// appended here by hand to be covered.
    private let allGlyphs: [ProviderGlyph] = [
        .claude, .devin, .openai, .third, .cursor, .antigravity, .geminiSpark,
        .glm, .qwen, .gemma, .meta, .deepseek, .mistral, .grok, .opencode,
        .commandcode, .copilot, .kimi, .kilo, .kiro, .amp, .apify, .minimax,
        .ollama, .ollamaLocal, .lmstudio, .llamaCpp, .qoder, .qianwenAI,
    ]

    func testEveryGlyphHasAnOpaqueBrandColour() {
        for glyph in allGlyphs {
            XCTAssertEqual(NSColor(glyph.brandColor).alphaComponent, 1, accuracy: 0.001, "\(glyph)")
        }
    }

    func testMonochromeBrandsFallBackToTextPrimary() {
        XCTAssertEqual(ProviderGlyph.cursor.brandColor, Palette.textPrimary)
    }

    func testClaudeIsTerracotta() throws {
        let rgb = try XCTUnwrap(NSColor(ProviderGlyph.claude.brandColor).usingColorSpace(.sRGB))
        XCTAssertEqual(rgb.redComponent, CGFloat(0xD9) / 255, accuracy: 0.01)
        XCTAssertEqual(rgb.greenComponent, CGFloat(0x77) / 255, accuracy: 0.01)
        XCTAssertEqual(rgb.blueComponent, CGFloat(0x57) / 255, accuracy: 0.01)
    }
}
