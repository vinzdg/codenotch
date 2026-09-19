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
    struct RegisteredPlugin: Equatable {
        let manifest: PluginManifest
        let directory: URL
        /// SHA-256 over the `plugin.json` bytes followed by the exec binary's
        /// bytes — the value an approval pins. Being part of `Equatable` means a
        /// silent binary swap diffs as a re-registration, which re-pends the
        /// plugin downstream.
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

    /// SHA-256 of the manifest bytes followed by the executable's bytes. Nil when
    /// the executable cannot be read — an unreadable binary is unapprovable, so
    /// the plugin is skipped rather than registered unhashable.
    static func contentHash(manifestData: Data, manifest: PluginManifest) -> String? {
        guard let execData = try? Data(contentsOf: URL(fileURLWithPath: manifest.exec.path),
                                       options: .mappedIfSafe)
        else { return nil }
        var hasher = SHA256()
        hasher.update(data: manifestData)
        hasher.update(data: execData)
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
            guard PluginTrust.isTrustedDirectory(pluginDirectory, fileManager: fileManager) else {
                Log.usage.error(
                    "plugin \(pluginDirectory.lastPathComponent, privacy: .public) skipped: untrusted directory")
                return nil
            }
            let manifestURL = pluginDirectory.appendingPathComponent("plugin.json")
            guard PluginTrust.isTrustedManifest(manifestURL, fileManager: fileManager) else {
                Log.usage.error(
                    "plugin \(pluginDirectory.lastPathComponent, privacy: .public) skipped: untrusted manifest")
                return nil
            }
            guard let data = fileManager.contents(atPath: manifestURL.path) else { return nil }
            do {
                let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
                let validated = try manifest.validated(builtInIDs: builtInIDs(),
                                                       builtInDisplayNames: builtInDisplayNames(),
                                                       pluginDirectory: pluginDirectory,
                                                       fileManager: fileManager)
                guard let hash = Self.contentHash(manifestData: data, manifest: validated) else {
                    Log.usage.error(
                        "plugin \(pluginDirectory.lastPathComponent, privacy: .public) skipped: executable unreadable")
                    return nil
                }
                return RegisteredPlugin(manifest: validated, directory: pluginDirectory,
                                        contentHash: hash)
            } catch {
                Log.usage.error(
                    "plugin \(pluginDirectory.lastPathComponent, privacy: .public) skipped: \(error.localizedDescription, privacy: .public)")
                return nil
            }
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
    /// That is also the detection boundary: watches cover the root and one
    /// subdirectory level, so an exec binary living outside the plugin tree
    /// (or nested deeper) that is overwritten in place is caught only at the
    /// next launch scan. Either way, `approve` pins the bytes as they are at
    /// approval time.
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
