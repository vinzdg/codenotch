import AppKit

/// Turns registry events into live providers: registers them with the store,
/// connects never-seen plugin ids by default, loads their glyphs, and attaches
/// any declared activity monitor. Owns the `PluginRegistry`'s lifetime.
///
/// Connecting by default is the one place plugins differ from discovered
/// Claude profiles: a manifest exists because someone ran the vendor's
/// installer on purpose, whereas a `~/.claude-work` directory can appear
/// without the user ever asking Codenotch to watch it. A toggle-off afterwards
/// persists through the ordinary `connectedProviders` mechanism — "novel"
/// means novel, not forced on every launch.
@MainActor
final class PluginCoordinator {
    private let registry: PluginRegistry
    private let store: UsageStore
    private let preferences: Preferences
    private weak var activity: ActivityCoordinator?

    init(registry: PluginRegistry,
         store: UsageStore,
         preferences: Preferences,
         activity: ActivityCoordinator) {
        self.registry = registry
        self.store = store
        self.preferences = preferences
        self.activity = activity
    }

    /// Plugins found at launch are already in the store's initial provider
    /// array and have already been through `reconcile`, so this only does what
    /// launch cannot have done yet: glyphs and activity monitors.
    func bootstrap(_ plugins: [PluginRegistry.RegisteredPlugin]) {
        for plugin in plugins {
            registerGlyph(for: plugin)
            if let monitor = Self.activityMonitor(for: plugin.manifest) {
                activity?.setMonitor(monitor, for: plugin.manifest.id)
            }
        }
        registry.seed(plugins)
    }

    func start() {
        registry.onChange = { [weak self] change in
            Task { @MainActor [weak self] in self?.apply(change) }
        }
        registry.start()
    }

    func stop() {
        registry.stop()
    }

    private func apply(_ change: PluginRegistry.Change) {
        for id in change.removedIDs {
            store.deregister(providerID: id)
            activity?.removeMonitor(for: id)
            PluginGlyphStore.shared.remove(providerID: id)
        }
        for plugin in change.added {
            let manifest = plugin.manifest
            registerGlyph(for: plugin)
            let provider = ExternalPluginProvider(manifest: manifest)
            if !preferences.seenProviders.contains(manifest.id) {
                preferences.setConnected(true, for: manifest.id)
            }
            store.register(provider)
            if let monitor = Self.activityMonitor(for: manifest) {
                activity?.setMonitor(monitor, for: manifest.id)
            }
            Log.usage.info("plugin registered: \(manifest.id, privacy: .public) (\(manifest.displayName, privacy: .public))")
        }
    }

    private func registerGlyph(for plugin: PluginRegistry.RegisteredPlugin) {
        guard let glyph = plugin.manifest.glyph,
              let image = NSImage(contentsOf: plugin.directory.appendingPathComponent(glyph.image))
        else { return }
        PluginGlyphStore.shared.register(image: image,
                                         opticalScale: glyph.opticalScale ?? 1,
                                         for: plugin.manifest.id)
    }

    /// The only activity kind this build knows: watch a Claude Code config
    /// directory's session registry, so a plugin wrapping `claude` gets the
    /// same live-session ring as a built-in Claude profile.
    private static func activityMonitor(for manifest: PluginManifest) -> (any AgentActivityMonitor)? {
        guard let activity = manifest.activity,
              activity.type == PluginManifest.Activity.claudeSessions else { return nil }
        let configDir = URL(fileURLWithPath: (activity.configDir as NSString).expandingTildeInPath,
                            isDirectory: true)
        return ClaudeSessionMonitor(
            directory: configDir.appendingPathComponent("sessions", isDirectory: true),
            projects: configDir.appendingPathComponent("projects", isDirectory: true)
        )
    }
}
