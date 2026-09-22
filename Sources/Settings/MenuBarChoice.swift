import SwiftUI

/// A provider as the menu bar rows in Settings list it.
struct MenuBarChoice: Identifiable, Equatable {
    let id: String
    let name: String
    let glyph: ProviderGlyph

    /// What the menu bar could show, in the order it would show it: the
    /// store's own snapshots, which only ever hold the providers being read,
    /// narrowed to the ones the bar can summarise.
    static func listed(in snapshots: [ProviderSnapshot]) -> [MenuBarChoice] {
        snapshots.filter(StatusItemSummary.canSummarise).map { snapshot in
            MenuBarChoice(id: snapshot.id, name: snapshot.displayName, glyph: snapshot.glyph)
        }
    }
}
