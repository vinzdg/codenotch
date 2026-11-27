import Foundation

/// Where a session is working: the repository its folder belongs to, and the
/// branch checked out there. Read from the files git keeps, not by running
/// git — this is looked up each time the list of sessions changes.
enum SessionPlace {
    struct Repository: Equatable {
        /// The repository's folder name, or the session's own folder when it
        /// is not in one.
        let name: String
        let branch: String?
    }

    static func repository(at directory: String?) -> Repository? {
        guard let directory, !directory.isEmpty else { return nil }
        var url = URL(fileURLWithPath: directory).standardizedFileURL
        let start = url
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        for _ in 0..<12 {
            let git = url.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: git.path) {
                return Repository(name: url.lastPathComponent, branch: branch(gitPath: git))
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path || url.path == home { break }
            url = parent
        }
        return Repository(name: start.lastPathComponent, branch: nil)
    }

    /// The branch named in HEAD. `.git` can be a file pointing elsewhere — a
    /// worktree — which is followed once.
    private static func branch(gitPath: URL) -> String? {
        var directory = gitPath
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: gitPath.path, isDirectory: &isDirectory)
        if !isDirectory.boolValue,
           let pointer = try? String(contentsOf: gitPath, encoding: .utf8),
           let line = pointer.split(separator: "\n").first, line.hasPrefix("gitdir: ") {
            let target = String(line.dropFirst("gitdir: ".count))
            directory = target.hasPrefix("/")
                ? URL(fileURLWithPath: target)
                : gitPath.deletingLastPathComponent().appendingPathComponent(target)
        }
        guard let head = try? String(contentsOf: directory.appendingPathComponent("HEAD"), encoding: .utf8)
        else { return nil }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref: refs/heads/") { return String(trimmed.dropFirst("ref: refs/heads/".count)) }
        return trimmed.isEmpty ? nil : String(trimmed.prefix(7))
    }
}
