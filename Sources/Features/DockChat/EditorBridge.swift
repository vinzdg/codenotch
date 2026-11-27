import AppKit
import Darwin
import Foundation

/// Types into a terminal inside VS Code (or Cursor, Windsurf, VSCodium) without
/// bringing the editor forward.
///
/// Nothing outside an editor can type into its terminal panel in the
/// background, so Codenotch installs a small extension there. Each editor
/// window's extension listens on a socket of its own, finds the terminal whose
/// shell is the session's parent, and types the line into it.
enum EditorBridge {
    enum Outcome: Equatable { case sent, noTerminal, unreachable, outdated }

    static let editors: [String: String] = [
        "com.microsoft.VSCode": "code",
        "com.microsoft.VSCodeInsiders": "code-insiders",
        "com.todesktop.230313mzl4w4u92": "cursor",
        "com.exafunction.windsurf": "windsurf",
        "com.vscodium": "codium",
    ]

    static var socketDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Codenotch/editor-sockets")
    }

    /// Asks every editor window that is listening. `ancestry` is the session's
    /// process and its parents: the terminal whose shell is among them is its own.
    static func send(_ line: String, ancestry: [pid_t]) -> Outcome {
        let sockets = (try? FileManager.default.contentsOfDirectory(
            at: socketDirectory, includingPropertiesForKeys: nil)) ?? []
        var reached = false
        let request: [String: Any] = ["text": line, "ancestry": ancestry.map(Int.init)]
        guard let body = try? JSONSerialization.data(withJSONObject: request) else { return .unreachable }
        for socket in sockets where socket.pathExtension == "sock" {
            guard let reply = exchange(body + Data("\n".utf8), at: socket.path) else {
                // A window that has gone leaves its socket behind.
                try? FileManager.default.removeItem(at: socket)
                continue
            }
            reached = true
            if let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
               object["ok"] as? Bool == true {
                return .sent
            }
        }
        return reached ? .noTerminal : .unreachable
    }

    /// Escape into the session's terminal, through the editor's helper —
    /// only a helper that knows the request. An older one took it for a
    /// message with no words, sent a bare Return, and said it had worked:
    /// the session went on, and the pill said it had stopped. So each
    /// window is asked its version first, and one too old is left alone.
    static func interrupt(ancestry: [pid_t]) -> Outcome {
        let sockets = (try? FileManager.default.contentsOfDirectory(
            at: socketDirectory, includingPropertiesForKeys: nil)) ?? []
        guard let ask = try? JSONSerialization.data(withJSONObject: ["list": true]),
              let body = try? JSONSerialization.data(
                withJSONObject: ["interrupt": true, "ancestry": ancestry.map(Int.init)]) else { return .unreachable }
        var reached = false
        var outdated = false
        for socket in sockets where socket.pathExtension == "sock" {
            guard let version = version(at: socket, ask: ask) else { continue }
            guard supportsInterrupt(version) else {
                outdated = true
                upgradeOnce()
                continue
            }
            reached = true
            guard let reply = exchange(body + Data("\n".utf8), at: socket.path),
                  let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else { continue }
            if object["ok"] as? Bool == true { return .sent }
        }
        if outdated { return .outdated }
        return reached ? .noTerminal : .unreachable
    }

    /// Keys with no Return — a choice from a list — through the helper.
    static func keys(_ keys: String, ancestry: [pid_t]) -> Outcome {
        let sockets = (try? FileManager.default.contentsOfDirectory(
            at: socketDirectory, includingPropertiesForKeys: nil)) ?? []
        guard let ask = try? JSONSerialization.data(withJSONObject: ["list": true]),
              let body = try? JSONSerialization.data(
                withJSONObject: ["keys": keys, "ancestry": ancestry.map(Int.init)]) else { return .unreachable }
        var outdated = false
        for socket in sockets where socket.pathExtension == "sock" {
            guard let version = version(at: socket, ask: ask) else { continue }
            guard atLeast(version, minor: 4) else { outdated = true; upgradeOnce(); continue }
            guard let reply = exchange(body + Data("\n".utf8), at: socket.path),
                  let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else { continue }
            if object["ok"] as? Bool == true { return .sent }
        }
        return outdated ? .outdated : .unreachable
    }

    private static func atLeast(_ version: String, minor: Int) -> Bool {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return false }
        return parts[0] > 0 || parts[1] >= minor
    }

    /// 0.3.0 is the first helper that knows Escape.
    private static func supportsInterrupt(_ version: String) -> Bool {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return false }
        return parts[0] > 0 || parts[1] >= 3
    }

    struct Terminal: Sendable {
        let pid: pid_t
        /// "Terminal 2", or "Terminal 2 — build" when it has a name of its own.
        let label: String
    }

    /// Every terminal in every editor window that is listening. A window
    /// still running an older helper, with no list to give, has the new one
    /// installed for its next reload.
    static func listTerminals() -> [Terminal] {
        let sockets = (try? FileManager.default.contentsOfDirectory(
            at: socketDirectory, includingPropertiesForKeys: nil)) ?? []
        guard let body = try? JSONSerialization.data(withJSONObject: ["list": true]) else { return [] }
        var found: [Terminal] = []
        for socket in sockets where socket.pathExtension == "sock" {
            guard let reply = exchange(body + Data("\n".utf8), at: socket.path),
                  let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else { continue }
            guard let terminals = object["terminals"] as? [[String: Any]] else {
                upgradeOnce()
                continue
            }
            // A window on an older helper still lists; it gets the new one
            // for its next reload.
            if object["version"] as? String != version { upgradeOnce() }
            for terminal in terminals {
                guard let pid = terminal["pid"] as? Int, pid > 0,
                      let index = terminal["index"] as? Int else { continue }
                let name = (terminal["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                let generic: Set<String> = ["zsh", "bash", "fish", "sh", "node", "claude", "-zsh", ""]
                // Claude Code titles its terminal with its own version number
                // — "2.1.332" — which says nothing about which terminal it is.
                let versionLike = name.allSatisfy { $0.isNumber || $0 == "." }
                let label = generic.contains(name.lowercased()) || versionLike
                    ? L10n.t("Terminal \(index + 1)")
                    : L10n.t("Terminal \(index + 1) — \(name)")
                found.append(Terminal(pid: pid_t(pid), label: label))
            }
        }
        return found
    }

    nonisolated(unsafe) private static var upgraded = false

    /// In the background: installing takes seconds, and it was being done
    /// in the middle of a stop, which then waited for it.
    private static func upgradeOnce() {
        guard !upgraded else { return }
        upgraded = true
        DispatchQueue.global(qos: .utility).async {
            for bundle in editors.keys {
                guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
                else { continue }
                _ = install(into: app)
            }
        }
    }

    /// Each window's helper version, by socket, asked once rather than on
    /// every stop. A window reloaded with a newer helper has a new socket.
    nonisolated(unsafe) private static var versions: [String: String] = [:]
    private static let versionsLock = NSLock()

    private static func forgetVersions() {
        versionsLock.lock()
        versions = [:]
        versionsLock.unlock()
    }

    private static func version(at socket: URL, ask: Data) -> String? {
        // Keyed by the socket file as it is now: a newer helper taking over
        // a window's socket makes a new file, and is asked again.
        let stamp = (try? FileManager.default.attributesOfItem(atPath: socket.path)[.modificationDate] as? Date)
            .map { "\($0.timeIntervalSince1970)" } ?? ""
        let key = socket.path + "|" + stamp
        versionsLock.lock()
        let known = versions[key]
        versionsLock.unlock()
        if let known { return known }
        guard let listed = exchange(ask + Data("\n".utf8), at: socket.path),
              let info = try? JSONSerialization.jsonObject(with: listed) as? [String: Any] else { return nil }
        let found = info["version"] as? String ?? "0"
        versionsLock.lock()
        versions[key] = found
        versionsLock.unlock()
        return found
    }

    private static func exchange(_ data: Data, at path: String) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        guard written == data.count else { return nil }
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            reply.append(contentsOf: buffer[0..<count])
            if reply.last == UInt8(ascii: "\n") { break }
        }
        return reply.isEmpty ? nil : reply
    }

    // MARK: - Installing the extension

    /// The helper's name carries its generation. An editor swaps in an
    /// *updated* extension only when its window is reloaded, so a helper that
    /// learned to stop a session sat unused behind the old one; a *new*
    /// extension starts at once in every open window. Each generation is
    /// therefore installed under a name of its own, and the ones before it
    /// are taken away.
    static let extensionName = "codenotch-dock-chat-4"
    static let extensionID = "codenotch.\(extensionName)"
    static let earlierIDs = ["codenotch.codenotch-dock-chat", "codenotch.codenotch-dock-chat-3"]
    static let version = "0.4.0"

    /// Installs the extension into the editor `app` with its own command line
    /// tool. Running windows pick it up without a restart.
    static func install(into app: NSRunningApplication) -> Bool {
        guard let bundle = app.bundleIdentifier, let tool = editors[bundle],
              let appURL = app.bundleURL else { return false }
        let cli = appURL.appendingPathComponent("Contents/Resources/app/bin/\(tool)")
        guard FileManager.default.isExecutableFile(atPath: cli.path),
              let vsix = buildVSIX() else { return false }
        defer { try? FileManager.default.removeItem(at: vsix.deletingLastPathComponent()) }
        let output = TerminalTabFocus.run(cli.path, ["--install-extension", vsix.path, "--force"], timeout: 60)
        Log.usage.info("dock chat extension install: \(output ?? "nil", privacy: .public)")
        let installed = output?.localizedCaseInsensitiveContains("successfully installed") == true
        if installed {
            for earlier in earlierIDs {
                _ = TerminalTabFocus.run(cli.path, ["--uninstall-extension", earlier], timeout: 60)
            }
            forgetVersions()
        }
        return installed
    }

    private static func buildVSIX() -> URL? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codenotch-vsix-\(UUID().uuidString)")
        let files: [String: String] = [
            "extension.vsixmanifest": manifest,
            "[Content_Types].xml": contentTypes,
            "extension/package.json": packageJSON,
            "extension/extension.js": extensionJS,
        ]
        do {
            for (path, text) in files {
                let url = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch { return nil }
        let vsix = root.appendingPathComponent("codenotch-dock-chat.vsix")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = root
        process.arguments = ["-q", "-r", vsix.path, "extension.vsixmanifest", "[Content_Types].xml", "extension"]
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        return process.terminationStatus == 0 ? vsix : nil
    }

    private static let packageJSON = """
    {
      "name": "\(extensionName)",
      "displayName": "Codenotch Dock Chat",
      "description": "Lets Codenotch's pill by the Dock type into the terminal a Claude Code session runs in.",
      "publisher": "codenotch",
      "version": "\(version)",
      "engines": { "vscode": "^1.75.0" },
      "activationEvents": ["onStartupFinished"],
      "main": "./extension.js"
    }
    """

    private static let extensionJS = #"""
    const vscode = require('vscode');
    const VERSION = '\#(version)';
    const net = require('net');
    const fs = require('fs');
    const path = require('path');
    const os = require('os');

    function activate(context) {
      const dir = path.join(os.homedir(), 'Library', 'Application Support', 'Codenotch', 'editor-sockets');
      fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
      const sock = path.join(dir, `${process.pid}.sock`);
      try { fs.unlinkSync(sock); } catch (e) {}
      const server = net.createServer((conn) => {
        let buffer = '';
        conn.on('data', (chunk) => {
          buffer += chunk;
          const end = buffer.indexOf('\n');
          if (end < 0) return;
          handle(buffer.slice(0, end))
            .then((reply) => conn.end(JSON.stringify(reply) + '\n'))
            .catch((error) => conn.end(JSON.stringify({ ok: false, error: String(error) }) + '\n'));
        });
      });
      server.listen(sock, () => { try { fs.chmodSync(sock, 0o600); } catch (e) {} });
      context.subscriptions.push({ dispose() { server.close(); try { fs.unlinkSync(sock); } catch (e) {} } });
    }

    async function processOf(terminal) {
      // Some terminals never say what their process is; don't wait on them.
      return Promise.race([
        terminal.processId,
        new Promise((resolve) => setTimeout(() => resolve(undefined), 400)),
      ]);
    }

    async function handle(line) {
      const request = JSON.parse(line);
      if (request.list) {
        const terminals = [];
        const all = vscode.window.terminals;
        for (let index = 0; index < all.length; index++) {
          terminals.push({ index, name: all[index].name, pid: (await processOf(all[index])) || 0 });
        }
        return { ok: true, version: VERSION, terminals };
      }
      if (request.keys !== undefined) {
        // Keys as they are, no Return: a number to pick from a list the
        // session is showing.
        const ancestry = new Set(request.ancestry || []);
        const all = vscode.window.terminals;
        const pids = await Promise.all(all.map(processOf));
        const index = pids.findIndex((pid) => pid && ancestry.has(pid));
        if (index < 0) return { ok: false, error: 'no terminal' };
        all[index].sendText(String(request.keys), false);
        return { ok: true };
      }
      if (request.interrupt) {
        // Escape, as a person presses it to stop Claude mid-turn. Every
        // terminal asked at once, so a stop is not kept waiting on them.
        const ancestry = new Set(request.ancestry || []);
        const all = vscode.window.terminals;
        const pids = await Promise.all(all.map(processOf));
        const index = pids.findIndex((pid) => pid && ancestry.has(pid));
        if (index < 0) return { ok: false, error: 'no terminal' };
        all[index].sendText('\x1b', false);
        return { ok: true };
      }
      const ancestry = new Set(request.ancestry || []);
      for (const terminal of vscode.window.terminals) {
        const pid = await processOf(terminal);
        if (pid && ancestry.has(pid)) {
          if (request.probe) return { ok: true, terminal: terminal.name };
          // The Return separately, so a TUI does not take text and Return
          // together for a paste and keep the Return as a new line.
          terminal.sendText(request.text, false);
          await new Promise((resolve) => setTimeout(resolve, 60));
          terminal.sendText('\r', false);
          return { ok: true };
        }
      }
      return { ok: false, error: 'no terminal' };
    }

    function deactivate() {}
    module.exports = { activate, deactivate };
    """#

    private static let manifest = """
    <?xml version="1.0" encoding="utf-8"?>
    <PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
      <Metadata>
        <Identity Language="en-US" Id="\(extensionName)" Version="\(version)" Publisher="codenotch"/>
        <DisplayName>Codenotch Dock Chat</DisplayName>
        <Description xml:space="preserve">Lets Codenotch's pill by the Dock type into the terminal a Claude Code session runs in.</Description>
        <Properties><Property Id="Microsoft.VisualStudio.Code.Engine" Value="^1.75.0"/></Properties>
      </Metadata>
      <Installation><InstallationTarget Id="Microsoft.VisualStudio.Code"/></Installation>
      <Dependencies/>
      <Assets><Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/></Assets>
    </PackageManifest>
    """

    private static let contentTypes = """
    <?xml version="1.0" encoding="utf-8"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension=".json" ContentType="application/json"/><Default Extension=".js" ContentType="application/javascript"/><Default Extension=".vsixmanifest" ContentType="text/xml"/></Types>
    """
}
