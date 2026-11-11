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

    private func scan(_ indexer: CostIndexer) {
        let done = expectation(description: "pass changed something")
        indexer.onChange = { done.fulfill() }
        indexer.scan()
        wait(for: [done], timeout: 5)
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
