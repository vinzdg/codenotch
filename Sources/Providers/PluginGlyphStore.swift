import AppKit

/// Images for plugin-provided glyphs, keyed by provider id.
///
/// `ProviderGlyph.external` is one enum case serving every plugin, so the
/// mark itself has to live somewhere id-keyed — here. `PluginRegistry`
/// populates the store as plugins come and go; `ProviderGlyphView` reads it.
/// An archived reading whose plugin has since been removed simply finds no
/// image and draws the fallback symbol — the archive stays decodable either
/// way, which is the whole reason the glyph is not an asset-catalog entry.
final class PluginGlyphStore {
    static let shared = PluginGlyphStore()

    struct Entry {
        let image: NSImage
        /// The manifest's `opticalScale`, applied exactly like a built-in's.
        let opticalScale: CGFloat
    }

    private var entries: [String: Entry] = [:]
    private let lock = NSLock()

    func register(image: NSImage, opticalScale: CGFloat, for providerID: String) {
        image.isTemplate = true
        lock.withLock { entries[providerID] = Entry(image: image, opticalScale: opticalScale) }
    }

    func remove(providerID: String) {
        lock.withLock { _ = entries.removeValue(forKey: providerID) }
    }

    func entry(for providerID: String) -> Entry? {
        lock.withLock { entries[providerID] }
    }

    /// Tests leave images behind between cases; the store is a process-wide
    /// singleton and a glyph from a previous test is indistinguishable from a
    /// real registration.
    func removeAll() {
        lock.withLock { entries.removeAll() }
    }
}
