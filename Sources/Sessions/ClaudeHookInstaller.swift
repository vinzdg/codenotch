import Foundation

/// Adds and removes Codenotch's `PermissionRequest` hook in a Claude Code
/// profile's `settings.json` — and touches nothing else in it.
///
/// Only ever run from the Settings toggle: `settings.json` is the user's own
/// file, so it changes when they ask and not otherwise. Our entry is found by
/// its URL, which is what lets removal leave every other hook exactly where it
/// was. The first write keeps a copy beside the file (`settings.json.codenotch-backup`).
enum ClaudeHookInstaller {
    static var url: String { "http://127.0.0.1:\(HookBridgeServer.defaultPort)\(HookBridgeServer.path)" }

    /// A little past `HookBridge.giveUpAfter`, so the notch hands the prompt
    /// back to the terminal before Claude Code times the hook out itself.
    static let timeout = 310

    static func settingsFile(for profile: ClaudeProfile) -> URL {
        profile.configDirectory.appendingPathComponent("settings.json")
    }

    static func isInstalled(in settings: [String: Any]) -> Bool {
        entries(settings).contains(where: isOurs)
    }

    static func installing(into settings: [String: Any]) -> [String: Any] {
        var settings = removing(from: settings)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var entries = hooks["PermissionRequest"] as? [Any] ?? []
        entries.append([
            "matcher": "*",
            "hooks": [["type": "http", "url": url, "timeout": timeout]],
        ] as [String: Any])
        hooks["PermissionRequest"] = entries
        settings["hooks"] = hooks
        return settings
    }

    static func removing(from settings: [String: Any]) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        let kept = self.entries(settings).filter { !isOurs($0) }
        if kept.isEmpty { hooks["PermissionRequest"] = nil } else { hooks["PermissionRequest"] = kept }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        return settings
    }

    // MARK: File

    static func isInstalled(profile: ClaudeProfile) -> Bool {
        (try? read(settingsFile(for: profile))).map(isInstalled(in:)) ?? false
    }

    static func setInstalled(_ installed: Bool, profile: ClaudeProfile,
                             fileManager: FileManager = .default) throws {
        let file = settingsFile(for: profile)
        let current = try read(file)
        guard isInstalled(in: current) != installed else { return }
        let backup = file.appendingPathExtension("codenotch-backup")
        if fileManager.fileExists(atPath: file.path), !fileManager.fileExists(atPath: backup.path) {
            try fileManager.copyItem(at: file, to: backup)
        }
        let next = installed ? installing(into: current) : removing(from: current)
        let data = try JSONSerialization.data(withJSONObject: next,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: file, options: .atomic)
    }

    /// A missing file is an empty one; a file that is not a JSON object is an
    /// error, so we never overwrite something we could not read.
    private static func read(_ file: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return object
    }

    private static func entries(_ settings: [String: Any]) -> [Any] {
        (settings["hooks"] as? [String: Any])?["PermissionRequest"] as? [Any] ?? []
    }

    private static func isOurs(_ entry: Any) -> Bool {
        let hooks = (entry as? [String: Any])?["hooks"] as? [[String: Any]] ?? []
        return hooks.contains { ($0["url"] as? String) == url }
    }
}
