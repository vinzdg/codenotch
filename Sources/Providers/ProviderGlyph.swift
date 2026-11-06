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
    case kilo
    case kiro
    case amp
    case apify
    case minimax
    case ollama
    case ollamaLocal = "ollama-local"
    case lmstudio
    case llamaCpp = "llamacpp"
    /// The QianwenAI platform's own console mark, which is a different emblem
    /// from the local Qwen model brand in `.qwen` — a ring wearing this one is
    /// the platform account, not a model.
    case qoder
    case qianwenAI = "qianwenai"

    // System Activity Monitor glyphs
    case ram = "system-ram"
    case cpu = "system-cpu"
    case thermals = "system-thermals"
    case network = "system-network"
    case energy = "system-energy"
    case fan = "system-fan"

    var systemSymbolName: String? {
        switch self {
        case .ram: return "memorychip"
        case .cpu: return "cpu"
        case .thermals: return "thermometer.medium"
        case .network: return "network"
        case .energy: return "bolt.fill"
        case .fan: return "fanblades.fill"
        default: return nil
        }
    }

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
        case .kilo:   return 0.97
        case .kiro:   return 0.95
        case .amp:    return 1.0
        // The asset's viewBox is cropped to the ink, so the mark fills its box
        // the way Claude's outline does and takes the same scale.
        case .apify:  return 0.97
        case .minimax: return 0.95
        case .ollama: return 0.95
        case .third:  return 1.0
        case .ollamaLocal: return 0.98
        case .lmstudio: return 0.96
        case .llamaCpp: return 1.0
        // The one value here measured off a render of the asset file rather
        // than of the app: this mark's ink fills 0.996 of its box, rasterised
        // with `rsvg-convert -w 512`. Claude's outline fills 0.997 at 0.97, so
        // the same scale brings this ink to the same extent.
        case .qianwenAI, .qoder: return 0.97
        case .devin, .qwen, .gemma, .meta, .deepseek, .mistral,
             .ram, .cpu, .thermals, .network, .energy, .fan: return 1.0
        }
    }

    var outline: [[CGPoint]] {
        if systemSymbolName != nil { return [] }
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
             .qianwenAI, .qoder, .amp, .apify, .llamaCpp: return []
        case .grok:   return GlyphOutline.grok
        case .opencode: return GlyphOutline.opencode
        case .commandcode: return GlyphOutline.commandcode
        case .copilot: return GlyphOutline.copilot
        case .kimi:   return GlyphOutline.kimi
        case .kilo:   return GlyphOutline.kilo
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

struct SpiderShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midX = rect.midX
        let midY = rect.midY
        let w = rect.width
        let h = rect.height

        // Abdomen & Cephalothorax
        let abdomenRect = CGRect(x: midX - w * 0.16, y: midY - h * 0.05, width: w * 0.32, height: h * 0.36)
        path.addEllipse(in: abdomenRect)

        let headRect = CGRect(x: midX - w * 0.11, y: midY - h * 0.28, width: w * 0.22, height: h * 0.20)
        path.addEllipse(in: headRect)

        // 8 Curved Legs
        let legOffsets: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (-0.08, -0.20, -0.40, -0.42),
            (-0.10, -0.12, -0.46, -0.20),
            (-0.10, -0.02, -0.46, 0.12),
            (-0.08, 0.08, -0.40, 0.36)
        ]

        for (sx, sy, kx, ky) in legOffsets {
            // Left leg
            path.move(to: CGPoint(x: midX + sx * w, y: midY + sy * h))
            path.addLine(to: CGPoint(x: midX + kx * w, y: midY + ky * h))
            path.addLine(to: CGPoint(x: midX + (kx - 0.04) * w, y: midY + (ky + 0.10) * h))

            // Right leg
            path.move(to: CGPoint(x: midX - sx * w, y: midY + sy * h))
            path.addLine(to: CGPoint(x: midX - kx * w, y: midY + ky * h))
            path.addLine(to: CGPoint(x: midX - (kx - 0.04) * w, y: midY + (ky + 0.10) * h))
        }

        return path
    }
}

struct ProviderGlyphView: View {
    let glyph: ProviderGlyph
    var customIconFilename: String? = nil
    var size: CGFloat = Design.px(46)

    @State private var fanDegrees: Double = 0
    @State private var globeAngle: Double = 0
    @State private var thermometerOffset: CGFloat = 0
    @State private var gradientOffset: CGFloat = 0

    var body: some View {
        Group {
            if let customIconFilename,
               let image = CustomIconStore.loadIcon(filename: customIconFilename) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else if glyph == .ram {
                ZStack {
                    SpiderShape()
                        .stroke(Palette.textPrimary, lineWidth: 1.8)
                    SpiderShape()
                        .fill(Palette.textPrimary)
                }
            } else if glyph == .fan {
                Image(systemName: "fanblades.fill")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .rotationEffect(.degrees(fanDegrees))
                    .onAppear {
                        withAnimation(.linear(duration: 2.0).repeatForever(autoreverses: false)) {
                            fanDegrees = 360
                        }
                    }
            } else if glyph == .cpu {
                Image(systemName: "cpu")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .overlay(
                        LinearGradient(
                            colors: [Color.green, Color.red, Color.green],
                            startPoint: UnitPoint(x: 0 - gradientOffset, y: 0),
                            endPoint: UnitPoint(x: 1 + gradientOffset, y: 1)
                        )
                        .mask(
                            Image(systemName: "cpu")
                                .resizable()
                                .scaledToFit()
                        )
                    )
                    .onAppear {
                        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                            gradientOffset = 0.8
                        }
                    }
            } else if glyph == .network {
                Image(systemName: "globe")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .rotation3DEffect(.degrees(globeAngle), axis: (x: 0, y: 1, z: 0))
                    .onAppear {
                        withAnimation(.linear(duration: 3.0).repeatForever(autoreverses: false)) {
                            globeAngle = 360
                        }
                    }
            } else if glyph == .thermals {
                Image(systemName: "thermometer.medium")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .offset(y: thermometerOffset)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                            thermometerOffset = -3
                        }
                    }
            } else if let systemSymbol = glyph.systemSymbolName {
                Image(systemName: systemSymbol)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
            } else if let image = NSImage(named: glyph.assetName) {
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
        // is evened out within it.
        .scaleEffect(glyph.opticalScale)
        .frame(width: size, height: size)
    }
}
