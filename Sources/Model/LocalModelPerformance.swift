import Foundation
import SwiftUI

/// The latest completed native Ollama response, not a quota or a PC health score.
struct LocalModelPerformance: Equatable {
    let outputTokens: Int
    let generationSeconds: TimeInterval
    let measuredAt: Date
    /// The clock was ours, not the runtime's: the generating phase as polled,
    /// against the runtime's token count. A tilde marks it in the tooltip;
    /// the headline under the ring drops it for room.
    let isApproximate: Bool

    init?(outputTokens: Int, durationNanoseconds: Int64, measuredAt: Date = Date(),
          isApproximate: Bool = false) {
        guard outputTokens > 0, durationNanoseconds > 0 else { return nil }
        self.outputTokens = outputTokens
        generationSeconds = Double(durationNanoseconds) / 1_000_000_000
        self.measuredAt = measuredAt
        self.isApproximate = isApproximate
    }

    /// LM Studio reports seconds as a floating-point count.
    init?(outputTokens: Int, seconds: TimeInterval, measuredAt: Date = Date(),
          isApproximate: Bool = false) {
        guard seconds.isFinite, seconds > 0, seconds < 1_000_000_000 else { return nil }
        self.init(outputTokens: outputTokens, durationNanoseconds: Int64(seconds * 1_000_000_000),
                  measuredAt: measuredAt, isApproximate: isApproximate)
    }

    /// From the runtime's own rate, when that is what it reported.
    init?(outputTokens: Int, tokensPerSecond: Double, measuredAt: Date = Date()) {
        guard tokensPerSecond.isFinite, tokensPerSecond > 0, outputTokens > 0 else { return nil }
        self.init(outputTokens: outputTokens, seconds: Double(outputTokens) / tokensPerSecond,
                  measuredAt: measuredAt)
    }

    var fidelity: Fidelity { .derived }
    var tokensPerSecond: Double { Double(outputTokens) / generationSeconds }
    private var qualifier: String { isApproximate ? "~" : "" }
    var speedText: String {
        tokensPerSecond < 0.1 ? "\(qualifier)<0.1 tok/s"
            : "\(qualifier)\(tokensPerSecond.formatted(.number.precision(.fractionLength(0...1)))) tok/s"
    }
    var headlineText: String {
        guard tokensPerSecond >= 1 else { return "<1 tok/s" }
        // Whole tokens only: the label is scaled down to fit the ring's column,
        // and the tenth costs two characters of font size for a digit nobody
        // reads at that size. The approximate qualifier goes the same way;
        // the tooltip's `speedText` keeps both.
        let rounded = tokensPerSecond.rounded()
        guard rounded >= 1000 else { return "\(Int(rounded)) tok/s" }
        let value = rounded.formatted(.number.notation(.compactName).precision(.significantDigits(1...2)))
        return "\(value) t/s"
    }

    enum Band: Equatable {
        case veryFast, smooth, slow, verySlow

        var label: String {
            switch self {
            case .veryFast: return "Very fast"
            case .smooth: return "Smooth"
            case .slow: return "Slow"
            case .verySlow: return "Very slow"
            }
        }
        var color: Color {
            switch self {
            case .veryFast: return Palette.generationFast
            case .smooth: return Palette.ample
            case .slow: return Palette.watch
            case .verySlow: return Palette.generationSlow
            }
        }
    }

    var band: Band {
        switch tokensPerSecond {
        case ..<10: return .verySlow
        case ..<20: return .slow
        case ..<40: return .smooth
        default:    return .veryFast
        }
    }

    static func parse(_ item: [String: Any], now: Date = Date()) -> LocalModelPerformance? {
        guard item["done"] as? Bool == true, item["error"] == nil,
              let count = positiveInteger(item["eval_count"]),
              let duration = positiveInteger(item["eval_duration"]),
              let tokens = Int(exactly: count) else { return nil }
        return LocalModelPerformance(outputTokens: tokens, durationNanoseconds: duration, measuredAt: now)
    }

    private static func positiveInteger(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        // Int64(string) rejects overflow, fractions and non-finite JSON numbers.
        guard let integer = Int64(number.stringValue), integer > 0 else { return nil }
        return integer
    }
}
