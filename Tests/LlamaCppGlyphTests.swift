import AppKit
import SwiftUI
import XCTest
@testable import Codenotch

@MainActor
final class LlamaCppGlyphTests: XCTestCase {
    func testOfficialMarkRendersAtPickerAndNotchSizes() throws {
        XCTAssertNotNil(NSImage(named: ProviderGlyph.llamaCpp.assetName))
        for size: CGFloat in [16, 28, 46] {
            let renderer = ImageRenderer(content: ProviderGlyphView(glyph: .llamaCpp, size: size)
                .foregroundStyle(.white))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(renderer.nsImage?.tiffRepresentation)))
            var ink = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                    ink += 1
                }
            }
            let coverage = Double(ink) / Double(bitmap.pixelsWide * bitmap.pixelsHigh)
            XCTAssertGreaterThan(coverage, 0.1)
            XCTAssertLessThan(coverage, 0.85)
        }
        XCTAssertNotNil(Bundle.main.url(forResource: "LlamaBrand-LICENSE", withExtension: "txt"))
        XCTAssertNotNil(Bundle.main.url(forResource: "LlamaBrand-NOTICE", withExtension: "txt"))
    }

    func testLlamaCppPresetAndSavedEndpointKeepRuntimeIdentity() throws {
        let preset = try XCTUnwrap(CustomEndpointPreset.templates.first { $0.id == "llamacpp" })
        XCTAssertEqual(preset.iconPreset, ProviderGlyph.llamaCpp.rawValue)
        let endpoint = CustomEndpoint(name: "llama.cpp", baseURL: preset.baseURL,
                                      selectedModel: "local-model", iconPreset: preset.iconPreset)
        let saved = try JSONDecoder().decode(CustomEndpoint.self, from: JSONEncoder().encode(endpoint))
        XCTAssertEqual(saved.selectedModel, "local-model")
        XCTAssertEqual(saved.iconPreset, "llamacpp")
    }
}
