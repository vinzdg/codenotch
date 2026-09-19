import Foundation

/// Ownership and permission checks for everything the plugin system trusts.
///
/// A plugin folder and its manifest belong to this user alone: anything
/// group/world-writable, symlinked, or owned by someone else is refused,
/// because the folder is the whole registration boundary. An executable is
/// allowed to be a system binary owned by root (`/bin/sh` is a legitimate
/// plugin target), but the same writability and symlink rules apply — the
/// approval hash pins its bytes, so a root-owned system binary is safe to
/// run and a user-writable impostor is not trusted silently.
enum PluginTrust {
    /// A directory that is not a symlink, is owned by the current user, and
    /// is not writable by group or other.
    static func isTrustedDirectory(_ url: URL, fileManager: FileManager = .default) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
              values.isDirectory == true, values.isSymbolicLink != true
        else { return false }
        return isOwnedAndNotShared(url, allowedOwners: [getuid()], fileManager: fileManager)
    }

    /// A regular file, not a symlink, owned by the current user, not
    /// group/world-writable. Used for `plugin.json`.
    static func isTrustedManifest(_ url: URL, fileManager: FileManager = .default) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]),
              values.isRegularFile == true, values.isSymbolicLink != true
        else { return false }
        return isOwnedAndNotShared(url, allowedOwners: [getuid()], fileManager: fileManager)
    }

    /// A regular file, not a symlink, not group/world-writable, owned by the
    /// current user or by root (system executables).
    static func isTrustedExecutable(_ url: URL, fileManager: FileManager = .default) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]),
              values.isRegularFile == true, values.isSymbolicLink != true
        else { return false }
        return isOwnedAndNotShared(url, allowedOwners: [getuid(), 0], fileManager: fileManager)
    }

    private static func isOwnedAndNotShared(_ url: URL, allowedOwners: [uid_t],
                                            fileManager: FileManager) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let owner = attributes[.ownerAccountID] as? NSNumber,
              allowedOwners.contains(owner.uint32Value),
              let permissions = attributes[.posixPermissions] as? NSNumber
        else { return false }
        return permissions.uint16Value & 0o022 == 0
    }
}
