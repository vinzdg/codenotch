import CoreServices
import XCTest
@testable import Codenotch

/// The indexer's file cursor: a pass reads only what was appended since the
/// last one, and a replaced file (new inode) is read again from the start.
/// The size/inode check runs for every transcript on every pass (#500), so it
/// has to stay correct while staying cheap.
final class CostIndexerTests: XCTestCase {
    private var dir: URL!
    private var store: CostStore!

    override func setUpWithError() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CostIndexerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("proj"),
                                                withIntermediateDirectories: true)
        // The enumerator reports /private/var/...; resolvingSymlinksInPath() maps it
        // back to /var, so take the real path to key cursors the way the indexer does.
        dir = URL(fileURLWithPath: try XCTUnwrap(realpath(tmp.path, nil).map { p in
            defer { free(p) }; return String(cString: p) }))
        store = try XCTUnwrap(CostStore(url: dir.appendingPathComponent("costs.sqlite")))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func line(_ id: String) -> String {
        #"{"type":"assistant","cwd":"/tmp/p","sessionId":"s1","requestId":"\#(id)","timestamp":"2026-10-28T10:00:00.000Z","message":{"model":"claude-sonnet","usage":{"input_tokens":10,"output_tokens":5}}}"# + "\n"
    }

    private func scan(_ indexer: CostIndexer, _ pass: CostIndexer.Pass = .everything) {
        let done = expectation(description: "pass changed something")
        indexer.onChange = { done.fulfill() }
        indexer.scan(pass)
        wait(for: [done], timeout: 5)
    }

    private func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 15, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting until \(what)") }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    // MARK: Reading only what was written (#500 follow-up)
    //
    // Every write to any transcript used to set off a pass over the whole
    // history: thousands of files listed, stat()ed and looked up, every few
    // seconds while any session was running. FSEvents says which files were
    // written, and those are the only ones that can have anything new.

    func testAPassOverChangedFilesReadsOnlyThose() throws {
        let a = dir.appendingPathComponent("proj/a.jsonl")
        let b = dir.appendingPathComponent("proj/b.jsonl")
        try line("a1").write(to: a, atomically: false, encoding: .utf8)
        try line("b1").write(to: b, atomically: false, encoding: .utf8)
        let indexer = try XCTUnwrap(CostIndexer(store: store, root: dir))
        scan(indexer)
        XCTAssertEqual(store.stats().events, 2)

        try append(line("a2"), to: a)
        try append(line("b2"), to: b)
        scan(indexer, .files([a.path]))
        XCTAssertEqual(store.stats().events, 3)
        XCTAssertEqual(store.fileCursor(b.path)?.offset, line("b1").utf8.count, "a file nobody reported was read")

        scan(indexer, .everything)
        XCTAssertEqual(store.stats().events, 4)
    }

    func testFileEventsAskForTheTranscriptsWrittenTo() {
        let file = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
        let modified = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
        let created = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
        let folder = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
        let pass = CostIndexer.pass(forEventPaths: ["/r/p/a.jsonl",
                                                    "/r/p/b.jsonl",
                                                    "/r/p/a.jsonl",
                                                    "/r/p/notes.txt",
                                                    "/r/p/s1/subagents",
                                                    "/r/p/s1/subagents/agent-1.jsonl",
                                                    "/r/.cache/c.jsonl"],
                                    flags: [file | modified, file | created | modified, file | modified,
                                            file | modified, folder | created, file | created, file | modified],
                                    root: "/r")
        XCTAssertEqual(pass, .files(["/r/p/a.jsonl", "/r/p/b.jsonl", "/r/p/s1/subagents/agent-1.jsonl"]))
    }

    func testEventsThatLoseTrackOfFilesAskForEverything() {
        let file = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified)
        let lost: [(String, FSEventStreamEventFlags)] = [
            // Events dropped, or coalesced into "look under here yourself".
            ("/r/p", FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)),
            ("", FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)),
            ("", FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)),
            // A folder moved in brings its transcripts with no event of their own.
            ("/r/p", FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed)),
        ]
        for (path, flags) in lost {
            XCTAssertEqual(CostIndexer.pass(forEventPaths: ["/r/p/a.jsonl", path], flags: [file, flags], root: "/r"),
                           .everything, "\(path) \(flags)")
        }
    }

    // Only what is below the root decides hidden: the folders above it,
    // `~/.claude` among them, never do — nor do those of a path that does
    // not start with the root as given.
    func testOnlyWhatIsBelowTheRootCanBeHidden() {
        let written = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified)
        XCTAssertEqual(CostIndexer.pass(forEventPaths: ["/u/.claude/projects/p/a.jsonl"], flags: [written],
                                        root: "/u/.claude/projects"),
                       .files(["/u/.claude/projects/p/a.jsonl"]))
        XCTAssertEqual(CostIndexer.pass(forEventPaths: ["/u/.dotfiles/claude/projects/p/a.jsonl"], flags: [written],
                                        root: "/u/.claude/projects"),
                       .files(["/u/.dotfiles/claude/projects/p/a.jsonl"]))
    }

    // `~/.claude` symlinked into a dotfiles folder, as dotfile managers set
    // it up: FSEvents and the enumerator both name the files by where they
    // really are, which is under a dotted folder above the root.
    func testWritingUnderASymlinkedConfigFolderIsRead() throws {
        let real = dir.appendingPathComponent(".dotfiles/claude/projects/p")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent(".claude"),
                                                   withDestinationURL: dir.appendingPathComponent(".dotfiles/claude"))
        let file = real.appendingPathComponent("a.jsonl")
        try line("a1").write(to: file, atomically: false, encoding: .utf8)
        // Hidden below the root, which a full pass never reads either.
        let hidden = dir.appendingPathComponent(".dotfiles/claude/projects/.trash/b.jsonl")
        try FileManager.default.createDirectory(at: hidden.deletingLastPathComponent(), withIntermediateDirectories: true)
        try line("b1").write(to: hidden, atomically: false, encoding: .utf8)
        Thread.sleep(forTimeInterval: 0.5)
        let indexer = try XCTUnwrap(CostIndexer(store: store, root: dir.appendingPathComponent(".claude/projects")))
        indexer.start()
        waitUntil("the first pass read it") { store.stats().events == 1 }
        try append(line("b2"), to: hidden)
        try append(line("a2"), to: file)
        waitUntil("the write was read") { store.stats().events == 2 }
        XCTAssertNil(store.fileCursor(hidden.path), "a hidden transcript was read")
    }

    func testPassesWaitingTogetherAreMerged() {
        let a = CostIndexer.Pass.files(["/r/a.jsonl"])
        let b = CostIndexer.Pass.files(["/r/b.jsonl"])
        XCTAssertEqual(a.merged(with: b), .files(["/r/a.jsonl", "/r/b.jsonl"]))
        XCTAssertEqual(a.merged(with: .everything), .everything)
        XCTAssertEqual(CostIndexer.Pass.everything.merged(with: b), .everything)
    }

    // Through FSEvents for real: a write to one transcript is read, and a
    // transcript nobody wrote to is not looked at. Its cursor is wound back
    // by hand, which only a pass over the whole history would notice.
    func testWritingATranscriptReadsThatTranscriptAlone() throws {
        let a = dir.appendingPathComponent("proj/a.jsonl")
        let b = dir.appendingPathComponent("proj/b.jsonl")
        try line("a1").write(to: a, atomically: false, encoding: .utf8)
        try line("b1").write(to: b, atomically: false, encoding: .utf8)
        // Files written just before a stream starts can still be reported to it.
        Thread.sleep(forTimeInterval: 0.5)
        let indexer = try XCTUnwrap(CostIndexer(store: store, root: dir))
        indexer.start()
        waitUntil("the first pass read both") { store.stats().events == 2 }

        let cursor = try XCTUnwrap(store.fileCursor(b.path))
        store.commit(events: [], path: b.path, inode: cursor.inode, size: cursor.size, offset: 0, mtime: 0)
        try append(line("a2"), to: a)
        waitUntil("the write was read") { store.stats().events == 3 }
        XCTAssertEqual(store.fileCursor(b.path)?.offset, 0, "a transcript nobody wrote to was read")
    }

    func testAppendIsReadIncrementallyAndReplacementIsReread() throws {
        let file = dir.appendingPathComponent("proj/s1.jsonl")
        try line("a").write(to: file, atomically: false, encoding: .utf8)
        let indexer = try XCTUnwrap(CostIndexer(store: store, root: dir))

        scan(indexer)
        XCTAssertEqual(store.stats().events, 1)
        XCTAssertEqual(store.fileCursor(file.path)?.offset, line("a").utf8.count)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line("b").utf8))
        try handle.close()
        scan(indexer)
        XCTAssertEqual(store.stats().events, 2)

        // atomically: true writes a new file and renames it over, so the inode changes.
        let oldInode = store.fileCursor(file.path)?.inode
        try line("c").write(to: file, atomically: true, encoding: .utf8)
        scan(indexer)
        XCTAssertNotEqual(store.fileCursor(file.path)?.inode, oldInode)
        XCTAssertEqual(store.stats().events, 3)
    }
}
