import Foundation
import XCTest
@testable import Codenotch

/// A translation of a string that carries values has to take those values in
/// a way `String(format:)` can read them. Get it wrong and nothing warns you:
/// the lookup hands back the translation, the arguments go in the English
/// order, and a number read as an object crashes the app (#237 — Simplified
/// Chinese swapped `%lld` and `%@` in the 80% alert, and every Chinese Mac
/// with a provider past 80% crashed at launch).
final class CatalogFormatTests: XCTestCase {
    private enum Kind: Equatable { case object, integer, double, cString }
    private struct Spec: Equatable { let position: Int?; let kind: Kind }

    /// The conversions `String.LocalizationValue` emits and translators use.
    private static let token = try! NSRegularExpression(
        pattern: #"%(%|(\d+\$)?[-+ 0#']*(\d+|\*)?(\.\d+)?(hh|h|ll|l|q|L|z|t|j)?([@dDiuUxXoOfFeEgGcCsSpaA]))"#
    )

    /// The specifiers in `text`, or nil when a `%` starts no valid one — a
    /// stray percent that `String(format:)` would try to read an argument for.
    private func specifiers(in text: String) -> [Spec]? {
        let ns = text as NSString
        var specs: [Spec] = []
        var index = 0
        while index < ns.length {
            let found = ns.range(of: "%", range: NSRange(location: index, length: ns.length - index))
            guard found.location != NSNotFound else { break }
            guard let match = Self.token.firstMatch(in: text, options: .anchored,
                                                    range: NSRange(location: found.location, length: ns.length - found.location))
            else { return nil }
            if ns.substring(with: match.range(at: 1)) != "%" {
                let conversion = ns.substring(with: match.range(at: 6))
                let kind: Kind = conversion == "@" ? .object
                    : "fFeEgGaA".contains(conversion) ? .double
                    : "sS".contains(conversion) ? .cString : .integer
                let position = match.range(at: 2).location == NSNotFound
                    ? nil : Int(ns.substring(with: match.range(at: 2)).dropLast())
                specs.append(Spec(position: position, kind: kind))
            }
            index = match.range.location + match.range.length
        }
        return specs
    }

    private func loadStrings() throws -> [String: [String: String]] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../Sources/Localizable.xcstrings")
            .standardizedFileURL
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError {
            throw XCTSkip("macOS privacy restricts reading the source catalog at \(url.path)")
        }
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        var result: [String: [String: String]] = [:]
        for (key, entry) in strings {
            let localizations = (entry as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
            var values: [String: String] = [:]
            for (language, localization) in localizations {
                if let unit = (localization as? [String: Any])?["stringUnit"] as? [String: Any],
                   let value = unit["value"] as? String {
                    values[language] = value
                }
            }
            result[key] = values
        }
        return result
    }

    /// Keys with a value in them: the only ones `String(format:)` ever reads.
    private func formattedKeys(_ strings: [String: [String: String]]) -> [String: [String: String]] {
        strings.filter { key, _ in
            ["%@", "%lld", "%d", "%f"].contains { key.contains($0) }
        }
    }

    /// `"\(value)% deficit"` becomes the key `%@%% deficit`: Swift doubles a
    /// literal percent beside an interpolation. A catalog key with it single
    /// is never looked up, and its translations never show.
    func testEveryFormattedKeyIsOneSwiftCanProduce() throws {
        let unreachable = formattedKeys(try loadStrings()).keys
            .filter { specifiers(in: $0) == nil }
            .sorted()
        XCTAssertEqual(unreachable, [],
                       "a literal % beside a value must be written %% in the key, or it is never matched")
    }

    func testEveryTranslationTakesItsValuesInAWayTheKeyCanSupply() throws {
        var broken: [String] = []
        for (key, translations) in formattedKeys(try loadStrings()) {
            guard let expected = specifiers(in: key) else { continue }
            let kinds = expected.map(\.kind)
            for (language, value) in translations.sorted(by: { $0.key < $1.key }) {
                guard let found = specifiers(in: value) else {
                    broken.append("\(language): a stray % in \"\(value)\" for \"\(key)\"")
                    continue
                }
                let ok: Bool
                if found.contains(where: { $0.position != nil }) {
                    // Reordered: every value numbered, each exactly once, each
                    // read as the kind the key supplies in that place.
                    let positions = found.compactMap(\.position)
                    ok = positions.count == found.count
                        && positions.sorted() == Array(1...max(kinds.count, 1)).prefix(kinds.count).map { $0 }
                        && found.allSatisfy { spec in
                            guard let position = spec.position, position <= kinds.count else { return false }
                            return kinds[position - 1] == spec.kind
                        }
                } else {
                    ok = found.map(\.kind) == kinds
                }
                if !ok {
                    broken.append("\(language): \"\(value)\" does not take the values of \"\(key)\" in order — number them (%1$@, %2$lld) to reorder")
                }
            }
        }
        XCTAssertEqual(broken.sorted(), [], broken.sorted().joined(separator: "\n"))
    }

    /// The crash itself, end to end, in the language that had it.
    func testTheEightyPercentAlertBodyFormatsInSimplifiedChinese() {
        let body = L10n.t("\(99)% of its \("weekly") limit used.", locale: Locale(identifier: "zh-Hans"))
        XCTAssertTrue(body.contains("99"), body)
        XCTAssertTrue(body.contains("weekly"), body)
    }

    func testTheEightyPercentAlertBodyFormatsInTraditionalChinese() {
        let body = L10n.t("\(99)% of its \("weekly") limit used.", locale: Locale(identifier: "zh-Hant"))
        XCTAssertTrue(body.contains("99"), body)
        XCTAssertTrue(body.contains("weekly"), body)
    }
    func testTheEightyPercentAlertBodyFormatsInKorean() {
        let body = L10n.t("\(99)% of its \("weekly") limit used.", locale: Locale(identifier: "ko"))
        XCTAssertTrue(body.contains("99"), body)
        XCTAssertTrue(body.contains("weekly"), body)
    }


    /// Uzbek puts the limit's name before the number, so its translation is
    /// the numbered kind — `%2$@` then `%1$lld`. If the positions were ever
    /// dropped, `String(format:)` would read 99 as an object and crash.
    func testTheEightyPercentAlertBodyFormatsInUzbek() {
        let body = L10n.t("\(99)% of its \("weekly") limit used.", locale: Locale(identifier: "uz"))
        XCTAssertTrue(body.contains("99"), body)
        XCTAssertTrue(body.contains("weekly"), body)
    }

    func testTheEightyPercentAlertBodyFormatsInSpanish() {
        let body = L10n.t("\(99)% of its \("weekly") limit used.", locale: Locale(identifier: "es"))
        XCTAssertTrue(body.contains("99"), body)
        XCTAssertTrue(body.contains("weekly"), body)
    }

    /// Turkish also names the limit before the number — `%2$@` then `%1$lld`.
    func testTheEightyPercentAlertBodyFormatsInTurkish() {
        let body = L10n.t("\(99)% of its \("weekly") limit used.", locale: Locale(identifier: "tr"))
        XCTAssertTrue(body.contains("99"), body)
        XCTAssertTrue(body.contains("weekly"), body)
    }
}
