import AppKit

/// Turns registry events into live providers — once the user has approved
/// them. A plugin whose content hash matches the pinned approval registers
/// and honors the ordinary connected toggle; anything else (new, changed,
/// never approved) goes onto the pending list that Settings renders with an
/// Enable button, and its provider is not registered. The hash covers the
/// manifest and the executable, so a silent binary swap re-pends the plugin.
@MainActor
final class PluginCoordinator {
    /// A plugin waiting for the user's explicit approval, as the Settings row
    /// needs it.
    struct PendingPlugin: Equatable, Identifiable {
        let id: String
        let displayName: String
        let execPath: String
        let execArgs: [String]
        let contentHash: String
        /// The plugin's own folder, so the row can offer to show the manifest
        /// before anyone enables it.
        let directory: URL
        /// What "Sign in" on the row would run, when the manifest declares
        /// one — shown for the same reason the exec line is.
        var signInCommand: [String]? = nil

        /// What would run, printed the way a shell would need it typed:
        /// each word quoted when it holds anything beyond plain path and
        /// option characters, so a space inside one argument cannot read as
        /// two, and `-c 'curl … | sh'` is visibly one script.
        var commandLine: String {
            Self.render([execPath] + execArgs)
        }

        var signInCommandLine: String? {
            signInCommand.map(Self.render)
        }

        static func render(_ words: [String]) -> String {
            words.map(shellQuoted).joined(separator: " ")
        }

        private static let bareWord = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-_./=:@%+,"))

        static func shellQuoted(_ word: String) -> String {
            guard word.isEmpty || !word.unicodeScalars.allSatisfy(bareWord.contains) else { return word }
            return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }

        var shortHash: String { String(contentHash.prefix(12)) }

        var manifestURL: URL { directory.appendingPathComponent("plugin.json") }
    }

    private let registry: PluginRegistry
    private let store: UsageStore
    private let preferences: Preferences
    private weak var activity: ActivityCoordinator?

    /// Read by Settings through a closure; kept current by every mutation of
    /// `pending`. Not `@Published` — the coordinator is not an
    /// `ObservableObject`, and the sheet re-reads on appear and after approve.
    private(set) var pendingPlugins: [PendingPlugin] = []
    private var pending: [String: PluginRegistry.RegisteredPlugin] = [:]
    /// What is registered right now, kept so a revocation can hand the same
    /// build back to the pending list without a rescan.
    private var approved: [String: PluginRegistry.RegisteredPlugin] = [:]

    init(registry: PluginRegistry,
         store: UsageStore,
         preferences: Preferences,
         activity: ActivityCoordinator? = nil) {
        self.registry = registry
        self.store = store
        self.preferences = preferences
        self.activity = activity
    }

    /// Plugins found at launch, already partitioned by the caller against the
    /// stored approvals. Approved ones are in the store's initial provider
    /// array and have already been through `reconcile`, so this only does what
    /// launch cannot have done yet: glyphs and activity monitors.
    func bootstrap(approved: [PluginRegistry.RegisteredPlugin],
                   pending: [PluginRegistry.RegisteredPlugin]) {
        for plugin in approved {
            self.approved[plugin.manifest.id] = plugin
            registerGlyph(for: plugin)
            if let monitor = Self.activityMonitor(for: plugin.manifest) {
                activity?.setMonitor(monitor, for: plugin.manifest.id)
            }
        }
        for plugin in pending {
            trackPending(plugin)
        }
        registry.seed(approved + pending)
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

    /// Re-check every plugin against the built-in set as it stands now —
    /// asked for when that set changes, so a plugin whose id or name a new
    /// custom endpoint has taken is dropped rather than kept until relaunch.
    func rescan() {
        registry.requestRescan()
    }

    /// Pin the pending plugin's current hash and register it. Approving is
    /// the only path that connects a plugin: there is no auto-connect.
    func approve(pluginID: String) {
        guard let plugin = pending.removeValue(forKey: pluginID) else { return }
        preferences.approvePlugin(pluginID, hash: plugin.contentHash)
        publishPending()
        register(plugin)
    }

    /// Forget the approval. The provider goes; the plugin, still on disk and
    /// unchanged, returns to the pending list under the hash it had, so
    /// enabling it again is one click and re-dropping it later is not
    /// silent.
    func revoke(pluginID: String) {
        guard let plugin = approved[pluginID] else { return }
        preferences.revokePlugin(pluginID)
        unregister(pluginID)
        trackPending(plugin)
        Log.usage.info("plugin approval revoked: \(pluginID, privacy: .public)")
    }

    private func apply(_ change: PluginRegistry.Change) {
        let changed = Set(change.added.map(\.manifest.id))
        for id in change.removedIDs {
            unregister(id)
            pending.removeValue(forKey: id)
            publishPending()
            // Gone from disk, not merely changed: the approval goes with it.
            // Reinstalling the same bytes asks again — a plugin the user
            // deleted must not come back running because something
            // re-dropped it.
            if !changed.contains(id) {
                preferences.revokePlugin(id)
            }
        }
        for plugin in change.added {
            if preferences.approvedHash(forPlugin: plugin.manifest.id) == plugin.contentHash {
                register(plugin)
            } else {
                trackPending(plugin)
            }
        }
    }

    private func unregister(_ id: String) {
        approved.removeValue(forKey: id)
        store.deregister(providerID: id)
        activity?.removeMonitor(for: id)
        PluginGlyphStore.shared.remove(providerID: id)
    }

    private func register(_ plugin: PluginRegistry.RegisteredPlugin) {
        let manifest = plugin.manifest
        approved[manifest.id] = plugin
        registerGlyph(for: plugin)
        store.register(registry.provider(for: plugin))
        if let monitor = Self.activityMonitor(for: manifest) {
            activity?.setMonitor(monitor, for: manifest.id)
        }
        Log.usage.info("plugin registered: \(manifest.id, privacy: .public) (\(manifest.displayName, privacy: .public))")
    }

    private func trackPending(_ plugin: PluginRegistry.RegisteredPlugin) {
        pending[plugin.manifest.id] = plugin
        publishPending()
        Log.usage.info("plugin pending approval: \(plugin.manifest.id, privacy: .public)")
    }

    private func publishPending() {
        pendingPlugins = pending.values.map { plugin in
            PendingPlugin(id: plugin.manifest.id,
                          displayName: plugin.manifest.displayName,
                          execPath: plugin.manifest.exec.path,
                          execArgs: plugin.manifest.exec.args,
                          contentHash: plugin.contentHash,
                          directory: plugin.directory,
                          signInCommand: plugin.manifest.signIn?.run)
        }.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
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
