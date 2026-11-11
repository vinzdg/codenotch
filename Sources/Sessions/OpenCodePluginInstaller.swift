import Foundation

enum OpenCodePluginInstaller {
    enum Failure: Error { case missingResource }

    static var pluginsDirectory: URL {
        let root = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return root.appendingPathComponent("opencode/plugins")
    }

    /// Only called by the explicit Settings button. Preserve an earlier or
    /// user-edited bridge outside the loader's .js/.ts extension set.
    static func install(directory: URL = pluginsDirectory, source: URL? = nil) throws {
        guard let source = source ?? Bundle.main.url(forResource: "codenotch-opencode", withExtension: "mjs")
        else { throw Failure.missingResource }
        let data = try Data(contentsOf: source)
        let target = directory.appendingPathComponent("codenotch.js")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let existing = try? Data(contentsOf: target) {
            if existing == data { return }
            let backup = directory.appendingPathComponent("codenotch.\(UUID().uuidString).backup")
            try existing.write(to: backup, options: .atomic)
        }
        try data.write(to: target, options: .atomic)
    }
}
