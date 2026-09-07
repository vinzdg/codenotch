import AVFoundation
import AppKit

/// The sound a finished session makes.
///
/// Plays the audio file itself rather than handing a name to `NSSound`.
/// `NSSound(named:)` resolves a system alert, and a system alert is routed
/// through the interface-sound-effects channel — which System Settings → Sound
/// can switch off, and which a good number of people have switched off, since
/// it is also what makes the Mac click and swoosh at them all day. On such a
/// machine `NSSound.play()` returns true and nothing is heard. Reading the same
/// file into an `AVAudioPlayer` puts it on the ordinary output path, where the
/// only thing that silences it is the volume control.
enum SessionChime {
    /// A turn ended. Short and unremarkable — this fires whenever any window
    /// finishes, which on a busy afternoon is often.
    static let defaultFinished = "Glass"
    /// A session is blocked on you. Two-toned, so it reads as different from
    /// the ordinary one without being an alarm.
    static let defaultBlocked = "Funk"

    /// Where macOS keeps alert sounds, most specific first, so a user's own
    /// file shadows a system one of the same name.
    private static let directories = [
        "\(NSHomeDirectory())/Library/Sounds",
        "/Library/Sounds",
        "/System/Library/Sounds"
    ]

    private static let extensions = ["aiff", "aif", "m4a", "wav", "caf"]

    /// Every sound the picker can offer, by name, in the order macOS lists them.
    static var available: [String] {
        var seen = Set<String>()
        var names: [String] = []
        for directory in directories {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            for file in files.sorted() {
                let url = URL(fileURLWithPath: file)
                guard extensions.contains(url.pathExtension.lowercased()) else { continue }
                let name = url.deletingPathExtension().lastPathComponent
                if seen.insert(name).inserted { names.append(name) }
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func url(for name: String) -> URL? {
        for directory in directories {
            for ext in extensions {
                let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).\(ext)")
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    /// Plays the named sound, if it is still there. Returns whether it started.
    ///
    /// The player is held for the length of the sound: a stack local is
    /// deallocated on the way out of this function and stops mid-note.
    ///
    /// The return value is not decoration — it is what a test can assert on,
    /// and asserting on it is what keeps `play()` out of the log interpolation
    /// below. See the comment there.
    @discardableResult
    static func play(_ name: String) -> Bool {
        guard let url = url(for: name) else {
            Log.usage.error("no sound file named \(name, privacy: .public)")
            return false
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            playing = player
            // On its own line, and never inside the log interpolation below.
            // Logger's interpolations are autoclosures evaluated only when the
            // level is enabled, so a `play()` written into one does not happen
            // at all on an ordinary run — the app logs nothing and plays
            // nothing, and every part of it looks correct.
            let started = player.play()
            Log.usage.debug("chime \(name, privacy: .public): \(started, privacy: .public)")
            return started
        } catch {
            // Worth falling back for rather than going silent: whatever stops
            // AVFoundation reading the file — an unreadable custom sound, a
            // format it will not open — has nothing to do with NSSound.
            Log.usage.error("chime \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return NSSound(named: name)?.play() ?? false
        }
    }

    private static var playing: AVAudioPlayer?
}
