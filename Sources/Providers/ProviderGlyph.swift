import SwiftUI

/// Which mark a provider cell draws.
enum ProviderGlyph: String, Codable, Equatable {
    case claude
    case devin
    case openai
    case third
    case cursor
    /// The raw value stays `gemini`: it is the key archived readings were
    /// written under, and renaming it would make every stored reading for this
    /// provider undecodable.
    case antigravity = "gemini"
    /// Gemini's own sparkle, for the provider that meters a raw API key.
    ///
    /// It cannot be called `gemini`: that raw value already names Antigravity's
    /// arch inside every archived snapshot, and swapping its meaning would
    /// redraw old readings as a mark they were never written for. So the
    /// sparkle gets a key of its own instead.
    case geminiSpark = "gemini-spark"
    case glm
    case qwen
    case gemma
    case meta
    case deepseek
    case mistral
    case grok
    case opencode
    case commandcode
    case copilot
    case kimi
    case kiro
    case minimax
    case ollama
    case ollamaLocal = "ollama-local"
    case lmstudio
    /// The QianwenAI platform's own console mark, which is a different emblem
    /// from the local Qwen model brand in `.qwen` — a ring wearing this one is
    /// the platform account, not a model.
    case qianwenAI = "qianwenai"
    /// A runtime-registered plugin's mark. The image itself is not an asset —
    /// it is loaded from the plugin's directory into `PluginGlyphStore`, keyed
    /// by provider id, and `ProviderGlyphView` resolves it there. One case
    /// serves every plugin: the enum is persisted inside `UsageArchive`, so a
    /// case per plugin would make today's archives undecodable to any build
    /// that predates the plugin, and a removed plugin would do the same in
    /// reverse.
    case external

    /// If an asset with this name is in the bundle it wins over the traced
    /// outline — drop a PDF/SVG export from Figma in and it is picked up.
    var assetName: String { self == .ollamaLocal ? "glyph-ollama" : "glyph-\(rawValue)" }

    /// How much to scale this mark so it reads the same size as the others.
    ///
    /// Every outline is normalised into the same unit box, which makes their
    /// *boxes* identical and their marks anything but: measured on screen at
    /// 16pt, the OpenAI knot covered 32px while the Gemini spark covered 25 —
    /// a fifth smaller — because a spark's points are thin and its corners are
    /// mostly empty. Boxes of equal size are not marks of equal size, and the
    /// eye reads the mark.
    ///
    /// Measured from a render rather than guessed: each value brings that
    /// glyph's ink to the same extent as Claude's.
    var opticalScale: CGFloat {
        switch self {
        case .claude: return 0.97
        case .cursor: return 0.97
        case .openai: return 0.94
        case .antigravity: return 1.0
        case .geminiSpark: return 1.0
        case .glm:    return 0.95
        case .grok:   return 1.0
        case .opencode: return 0.95
        case .commandcode: return 0.96
        case .copilot: return 0.96
        case .kimi:   return 0.95
        case .kiro:   return 0.95
        case .minimax: return 0.95
        case .ollama: return 0.95
        case .third:  return 1.0
        case .ollamaLocal: return 0.98
        case .lmstudio: return 0.96
        // The one value here measured off a render of the asset file rather
        // than of the app: this mark's ink fills 0.996 of its box, rasterised
        // with `rsvg-convert -w 512`. Claude's outline fills 0.997 at 0.97, so
        // the same scale brings this ink to the same extent.
        case .qianwenAI: return 0.97
        // A plugin's own scale comes from its manifest via `PluginGlyphStore`;
        // this is only the fallback when no plugin image is registered.
        case .external: return 1.0
        case .devin, .qwen, .gemma, .meta, .deepseek, .mistral: return 1.0
        }
    }

    var outline: [[CGPoint]] {
        switch self {
        case .claude: return GlyphOutline.claude
        case .openai: return GlyphOutline.openai
        case .third:  return GlyphOutline.third
        case .cursor: return GlyphOutline.cursor
        case .antigravity: return GlyphOutline.antigravity
        case .geminiSpark: return GlyphOutline.gemini
        // Fallbacks only: glyph-glm, glyph-opencode, glyph-commandcode and
        // glyph-kimi in the asset catalogue are drawn instead.
        case .glm:    return GlyphOutline.glm
        case .devin, .qwen, .gemma, .meta, .deepseek, .mistral, .lmstudio,
             .qianwenAI, .external: return []
        case .grok:   return GlyphOutline.grok
        case .opencode: return GlyphOutline.opencode
        case .commandcode: return GlyphOutline.commandcode
        case .copilot: return GlyphOutline.copilot
        case .kimi:   return GlyphOutline.kimi
        case .kiro:   return GlyphOutline.kiro
        // A fallback only: glyph-minimax in the asset catalogue is drawn instead.
        case .minimax: return GlyphOutline.minimax
        case .ollama, .ollamaLocal: return GlyphOutline.ollama
        }
    }
}

/// A traced outline scaled into the view's bounds, filled even-odd so the
/// counters inside a knot stay open.
struct GlyphShape: Shape {
    let outline: [[CGPoint]]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for loop in outline {
            guard let first = loop.first else { continue }
            path.move(to: point(first, in: rect))
            for p in loop.dropFirst() { path.addLine(to: point(p, in: rect)) }
            path.closeSubpath()
        }
        return path
    }

    private func point(_ p: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
    }
}

struct ProviderGlyphView: View {
    let glyph: ProviderGlyph
    var customIconFilename: String? = nil
    var size: CGFloat = Design.px(46)
    /// Which provider the glyph belongs to. Only consulted for `.external`:
    /// the plugin's image is looked up by id in `PluginGlyphStore`, so an
    /// archived reading drawn after its plugin was removed falls back to a
    /// generic mark rather than crashing or drawing nothing.
    var providerID: String? = nil

    var body: some View {
        Group {
            if let customIconFilename,
               let image = CustomIconStore.loadIcon(filename: customIconFilename) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else if glyph == .external {
                if let id = providerID, let entry = PluginGlyphStore.shared.entry(for: id) {
                    Image(nsImage: entry.image)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(entry.opticalScale)
                } else {
                    Image(systemName: "puzzlepiece.extension")
                        .resizable()
                        .scaledToFit()
                }            } else if let image = NSImage(named: glyph.assetName) {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
            } else {
                GlyphShape(outline: glyph.outline)
                    .fill(style: FillStyle(eoFill: true))
            }
        }
        // Scaled inside a frame of the fixed size, so the *layout* stays on a
        // single grid — every row still reserves the same width — while the ink
        // is evened out within it. A plugin's own scale was applied above.
        .scaleEffect(glyph == .external ? 1 : glyph.opticalScale)
        .frame(width: size, height: size)
    }
}
