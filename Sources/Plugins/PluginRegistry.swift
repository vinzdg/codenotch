import CryptoKit
import Foundation

/// Discovers and watches plugin manifests under the plugins directory
/// (`~/Library/Application Support/Codenotch/Plugins`; debug builds can
/// override it with `CODENOTCH_PLUGINS_DIR`).
///
/// Registration is the vendor's installer writing a directory containing a
/// `plugin.json`; unregistration is deleting it. The registry scans at launch
/// and re-scans when the directory changes, diffing the validated set so the
/// coordinator sees only what actually changed. One malformed manifest is
/// logged and skipped — it must never take the other plugins down with it.
final class PluginRegistry {
    /// A manifest that passed validation, plus where it lives (the glyph
    /// image resolves relative to this).
    struct RegisteredPlugin: Equatable, Sendable {
        let manifest: PluginManifest
        let directory: URL
        /// SHA-256 over every file in the plugin directory — the value an
        /// approval pins. Being part of `Equatable` means a silent edit to any
        /// of them diffs as a re-registration, which re-pends the plugin
        /// downstream.
        let contentHash: String
    }

    struct Change: Equatable {
        /// Newly registered, or re-registered with different content.
        let added: [RegisteredPlugin]
        /// Removed outright, or re-registered (an id in both lists changed).
        let removedIDs: [String]

        static let none = Change(added: [], removedIDs: [])
    }

    let directory: URL
    /// The built-in provider ids, asked of the caller because they live in
    /// `AppDelegate` and a registry has no business reaching across the app.
    private let builtInIDs: () -> Set<String>
    /// The built-in display names, for impersonation rejection — same reasoning
    /// as `builtInIDs`.
    private let builtInDisplayNames: () -> Set<String>
    private let fileManager: FileManager
    /// Called on an internal queue with each real change. Re-entrancy is the
    /// consumer's problem (`PluginCoordinator` hops to the main actor).
    var onChange: ((Change) -> Void)?

    private let queue = DispatchQueue(label: "codenotch.plugins.registry", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var pluginSources: [String: DispatchSourceFileSystemObject] = [:]
    private var debounce: DispatchWorkItem?
    /// Queue-confined. Set by `stop`, cleared by `start`; a late watch event
    /// after `stop` must not arm a rescan that re-creates watches.
    private var stopped = false
    private var current: [String: RegisteredPlugin] = [:]

    init(directory: URL,
         builtInIDs: @escaping () -> Set<String>,
         builtInDisplayNames: @escaping () -> Set<String> = { [] },
         fileManager: FileManager = .default) {
        self.directory = directory
        self.builtInIDs = builtInIDs
        self.builtInDisplayNames = builtInDisplayNames
        self.fileManager = fileManager
    }

    /// SHA-256 over the whole plugin directory: every entry in path order,
    /// each as its relative path, its kind, and — for a file — its size and
    /// bytes, for a symlink its target. A symlink may only point back inside
    /// the directory (`node_modules/.bin` style), where its target's bytes
    /// are in the hash too; one that leaves it makes the directory
    /// unhashable, because whatever runs through it is not pinned. The
    /// manifest is one of those files,
    /// and so is any script the manifest's executable runs, which is why
    /// executables and absolute arguments are confined to the directory:
    /// the hash covers all the code Codenotch hands to the kernel, not just
    /// the first hop. A root-owned executable outside it (`/bin/sh`) is not
    /// hashed — the user's processes cannot change it, and pinning its bytes
    /// would only re-ask after every macOS update.
    ///
    /// Nil when anything cannot be read — an unreadable file is unhashable,
    /// so the plugin is skipped rather than registered unpinned. `.DS_Store`
    /// is the one name ignored: revealing the folder in Finder must not
    /// re-pend the plugin.
    static func contentHash(pluginDirectory: URL, fileManager: FileManager = .default) -> String? {
        let root = pluginDirectory.standardizedFileURL
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
            options: []
        ) else { return nil }
        var entries: [(relative: String, url: URL)] = []
        for case let url as URL in enumerator where url.lastPathComponent != ".DS_Store" {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root.path + "/") else { return nil }
            entries.append((String(path.dropFirst(root.path.count + 1)), url))
        }
        entries.sort { $0.relative.utf8.lexicographicallyPrecedes($1.relative.utf8) }

        var hasher = SHA256()
        for entry in entries {
            guard let values = try? entry.url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            else { return nil }
            hasher.update(data: Data(entry.relative.utf8))
            hasher.update(data: Data([0]))
            if values.isSymbolicLink == true {
                guard let target = try? fileManager.destinationOfSymbolicLink(atPath: entry.url.path),
                      PluginTrust.isInside(entry.url.path, directory: root)
                else { return nil }
                hasher.update(data: Data("link\0\(target)\0".utf8))
            } else if values.isDirectory == true {
                hasher.update(data: Data("dir\0".utf8))
            } else {
                guard let data = try? Data(contentsOf: entry.url, options: .mappedIfSafe) else { return nil }
                hasher.update(data: Data("file\0\(data.count)\0".utf8))
                hasher.update(data: data)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func defaultDirectory(
        applicationSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory,
                                                           in: .userDomainMask)[0],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        // Debug builds only: a release that followed an environment variable would
        // let any launcher redirect Codenotch's plugins to a folder it controls.
        #if DEBUG
        if let override = environment["CODENOTCH_PLUGINS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        #endif
        return applicationSupport
            .appendingPathComponent("Codenotch", isDirectory: true)
            .appendingPathComponent("Plugins", isDirectory: true)
    }

    // MARK: - Scanning

    /// The validated plugin set as it stands right now. Safe to call from
    /// anywhere; the diff state is only touched on `queue`.
    func scan() -> [RegisteredPlugin] {
        guard PluginTrust.isTrustedDirectory(directory, fileManager: fileManager) else {
            Log.usage.error(
                "plugins directory untrusted, refusing to scan: \(self.directory.path, privacy: .public)")
            return []
        }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let plugins: [RegisteredPlugin] = entries.compactMap { pluginDirectory in
            guard (try? pluginDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { return nil }
            return inspect(pluginDirectory)
        }
        // Two directories declaring the same manifest id would crash the
        // dictionaries downstream; one buggy installer is not a process DoS.
        // The first directory wins, the rest are logged and skipped.
        var seen = Set<String>()
        return plugins.filter { plugin in
            guard seen.insert(plugin.manifest.id).inserted else {
                Log.usage.error(
                    "plugin \(plugin.directory.lastPathComponent, privacy: .public) skipped: duplicate id \(plugin.manifest.id, privacy: .public)")
                return false
            }
            return true
        }
    }

    /// One plugin directory through every check — folder and manifest trust,
    /// decoding, validation, hashing. Nil, with the reason logged, when any
    /// of them fails.
    func inspect(_ pluginDirectory: URL) -> RegisteredPlugin? {
        let name = pluginDirectory.lastPathComponent
        guard PluginTrust.isTrustedDirectory(pluginDirectory, fileManager: fileManager) else {
            Log.usage.error("plugin \(name, privacy: .public) skipped: untrusted directory")
            return nil
        }
        let manifestURL = pluginDirectory.appendingPathComponent("plugin.json")
        guard PluginTrust.isTrustedManifest(manifestURL, fileManager: fileManager) else {
            Log.usage.error("plugin \(name, privacy: .public) skipped: untrusted manifest")
            return nil
        }
        guard let data = fileManager.contents(atPath: manifestURL.path) else { return nil }
        do {
            let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
            let validated = try manifest.validated(builtInIDs: builtInIDs(),
                                                   builtInDisplayNames: builtInDisplayNames(),
                                                   pluginDirectory: pluginDirectory,
                                                   fileManager: fileManager)
            guard let hash = Self.contentHash(pluginDirectory: pluginDirectory, fileManager: fileManager) else {
                Log.usage.error("plugin \(name, privacy: .public) skipped: directory unreadable, or a symlink in it leaves it")
                return nil
            }
            return RegisteredPlugin(manifest: validated, directory: pluginDirectory, contentHash: hash)
        } catch {
            Log.usage.error(
                "plugin \(name, privacy: .public) skipped: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Whether the plugin on disk is still exactly this one — same manifest,
    /// same hash, still trusted. Asked immediately before every run, because
    /// the watcher's half-second debounce and a poll already scheduled are a
    /// window, and a root-owned executable in a user-writable directory can
    /// be swapped for a user-owned one without any watch seeing it.
    func isCurrent(_ plugin: RegisteredPlugin) -> Bool {
        inspect(plugin.directory) == plugin
    }

    /// Re-scan on the next turn of the queue, as if the directory had
    /// changed — the provider asks for this when `isCurrent` says no, so a
    /// plugin that changed under it re-pends (or, if it no longer validates,
    /// is dropped) instead of failing every poll until the next launch.
    func requestRescan() {
        queue.async { self.scheduleRescan() }
    }

    /// The provider for an approved plugin, wired to re-check the plugin
    /// before every run.
    func provider(for plugin: RegisteredPlugin) -> ExternalPluginProvider {
        ExternalPluginProvider(
            plugin: plugin,
            verify: { [weak self] in self?.isCurrent(plugin) ?? false },
            onTamper: { [weak self] in self?.requestRescan() })
    }

    /// Plugins registered at launch, so the first rescan after `start()` does
    /// not report them all as newly added. Called by the coordinator after it
    /// has bootstrapped them.
    func seed(_ plugins: [RegisteredPlugin]) {
        queue.async {
            self.current = Dictionary(plugins.map { ($0.manifest.id, $0) },
                                      uniquingKeysWith: { first, _ in first })
        }
    }

    // MARK: - Watching

    /// Scan now, then keep the set current as the directory changes. The first
    /// scan is reported through `onChange` as additions against an empty set.
    ///
    /// The directory is created if missing: a vendor installer registering the
    /// first-ever plugin must not have to wait for an app restart just because
    /// there was nothing to watch at launch.
    func start() {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        queue.async {
            self.stopped = false
            self.rescan()
        }

        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            Log.usage.error("plugin directory not watchable: \(self.directory.path, privacy: .public)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self] in self?.scheduleRescan() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    /// Synchronous on the queue: when `stop` returns, every rescan armed
    /// before it has run and the flag is set, so nothing — a late event, an
    /// in-flight debounce — can report or re-create watches behind its back.
    /// Must never be called from the registry's own queue.
    func stop() {
        debounce?.cancel()
        source?.cancel()
        source = nil
        queue.sync {
            self.stopped = true
            for (_, pluginSource) in self.pluginSources { pluginSource.cancel() }
            self.pluginSources.removeAll()
        }
    }

    /// Directory events arrive in bursts (an installer writes the manifest and
    /// then the glyph); one rescan after the burst settles covers them all.
    private func scheduleRescan() {
        guard !stopped else { return }
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            // Armed before `stop`, fired after it: the flag is checked again
            // here so that window cannot run a rescan that re-creates watches.
            guard let self, !self.stopped else { return }
            self.rescan()
        }
        debounce = item
        queue.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    /// The root watch sees plugin directories come and go, but a vnode event
    /// does not propagate upwards: a manifest rewritten *inside* a plugin
    /// directory never fires on the root, and a silent edit is exactly what
    /// the content hash exists to catch. So every immediate subdirectory gets
    /// a watch of its own, refreshed after each rescan — valid plugin or not,
    /// because a botched install that is fixed a moment later must be noticed
    /// too. Runs on `queue`, from `rescan`.
    ///
    /// Watches cover the root and one subdirectory level; a file nested
    /// deeper is still in the hash, and `isCurrent` re-checks the whole
    /// directory before every run, so a deeper edit is caught at the next
    /// poll rather than the next launch.
    private func updateWatches() {
        let subdirectories = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        let paths = Set(subdirectories.compactMap { url in
            ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
                ? url.path : nil
        })
        let stale = pluginSources.keys.filter { !paths.contains($0) }
        for path in stale {
            pluginSources.removeValue(forKey: path)?.cancel()
        }
        for path in paths where pluginSources[path] == nil {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: queue)
            source.setEventHandler { [weak self] in self?.scheduleRescan() }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            pluginSources[path] = source
        }
    }

    private func rescan() {
        // `scan` already drops duplicate ids; `uniquingKeysWith` keeps the
        // crash out of reach even if that ever changes.
        let found = Dictionary(scan().map { ($0.manifest.id, $0) },
                               uniquingKeysWith: { first, _ in first })
        var added: [RegisteredPlugin] = []
        var removed: [String] = []
        for (id, plugin) in found {
            if current[id] != plugin {
                if current[id] != nil { removed.append(id) }
                added.append(plugin)
            }
        }
        for id in current.keys where found[id] == nil {
            removed.append(id)
        }
        current = found
        // Not gated on the diff: a brand-new empty subdirectory changes nothing
        // yet, but still needs its watch before the installer writes into it.
        updateWatches()
        let change = Change(added: added, removedIDs: removed)
        guard change != .none else { return }
        onChange?(change)
    }
}

/// The ids and display names a plugin may not claim: every provider that is
/// not itself a plugin, as they stand *now*. Not frozen at launch, because
/// custom endpoints join and leave while the app runs and a name the user
/// gives one of them is taken from then on. Read from the registry's queue,
/// written from the main actor, hence the lock.
final class BuiltInProviderSet: @unchecked Sendable {
    private let lock = NSLock()
    private var storedIDs: Set<String> = []
    private var storedDisplayNames: Set<String> = []

    var ids: Set<String> { lock.withLock { storedIDs } }
    var displayNames: Set<String> { lock.withLock { storedDisplayNames } }

    /// Plugins are left out: a registered plugin must not become a built-in
    /// its own next rescan collides with.
    func replace(with providers: [UsageProvider]) {
        let builtIns = providers.filter { !$0.isPlugin }
        lock.withLock {
            storedIDs = Set(builtIns.map(\.id))
            storedDisplayNames = Set(builtIns.map(\.displayName))
        }
    }
}
