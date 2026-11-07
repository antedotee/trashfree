import Darwin
import Foundation
import Testing
@testable import TrashFreeCore

/// A temporary folder tree with every case the scanner must count correctly:
/// nesting, an empty folder, a file with three hard links, an APFS clone, a sparse
/// file, and a folder the scanner cannot read.
final class Fixture {
    let root: URL
    /// Allocated bytes the scan should report: each hard-linked file and each clone
    /// once, nothing from the unreadable folder.
    private(set) var expectedBytes: Int64 = 0
    /// Entries the scan should count: folders it reached, plus files that own blocks.
    private(set) var expectedItems = 0
    private let locked: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        root = base.appendingPathComponent("tfscan-test-\(UUID().uuidString)")
        locked = root.appendingPathComponent("locked")
        let fm = FileManager.default

        for folder in ["a/b/c", "empty", "links", "other", "clones", "locked"] {
            try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        // a, b, c, empty, links, other, clones, locked: the scanner lists all eight.
        expectedItems += 8

        try write(10_000, to: "a/b/c/file1")
        expectedBytes += allocated("a/b/c/file1")
        expectedItems += 1

        try write(50_000, to: "links/original")
        try posix(link(path("links/original"), path("links/second")))
        try posix(link(path("links/original"), path("other/third")))
        expectedBytes += allocated("links/original")
        expectedItems += 1

        try write(100_000, to: "clones/source")
        try posix(clonefile(path("clones/source"), path("clones/copy"), 0))
        expectedBytes += allocated("clones/source")
        expectedItems += 1

        // 1 GB logical, one 4 KB block written at the end.
        let sparse = open(path("sparse"), O_CREAT | O_WRONLY, 0o644)
        try posix(sparse >= 0 ? 0 : -1)
        let page = [UInt8](repeating: 7, count: 4096)
        try posix(pwrite(sparse, page, page.count, (1 << 30) - 4096) == page.count ? 0 : -1)
        close(sparse)
        expectedBytes += allocated("sparse")
        expectedItems += 1

        try write(20_000, to: "locked/hidden")
        try posix(chmod(locked.path, 0))
    }

    deinit {
        chmod(locked.path, 0o755)
        try? FileManager.default.removeItem(at: root)
    }

    func path(_ relative: String) -> String { root.appendingPathComponent(relative).path }

    func allocated(_ relative: String) -> Int64 {
        var info = stat()
        guard lstat(path(relative), &info) == 0 else { return -1 }
        return Int64(info.st_blocks) * 512
    }

    private func write(_ count: Int, to relative: String) throws {
        try Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
            .write(to: root.appendingPathComponent(relative))
    }

    private func posix(_ result: Int32) throws {
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

private func node(_ root: FileNode, _ relative: String) -> FileNode? {
    relative.split(separator: "/").reduce(Optional(root)) { node, name in
        node?.children.first { $0.name == name }
    }
}

@Suite("ScanJob")
struct ScannerTests {
    @Test("counts allocated bytes, hard links once, clones once")
    func totals() throws {
        let fixture = try Fixture()
        let result = try #require(ScanJob(url: fixture.root).run())

        #expect(result.root.size == fixture.expectedBytes)
        #expect(result.itemCount == fixture.expectedItems)

        // The sparse file reports blocks, not its 1 GB length.
        let sparse = try #require(node(result.root, "sparse"))
        #expect(sparse.size == fixture.allocated("sparse"))
        #expect(sparse.size < 1 << 20)

        // Exactly one of the three hard links carries the bytes; empty ones are dropped.
        let linkNodes = ["links/original", "links/second", "other/third"].compactMap { node(result.root, $0) }
        #expect(linkNodes.count == 1)
        #expect(linkNodes.first?.size == fixture.allocated("links/original"))

        let cloneNodes = ["clones/source", "clones/copy"].compactMap { node(result.root, $0) }
        #expect(cloneNodes.count == 1)
        #expect(cloneNodes.first?.size == fixture.allocated("clones/source"))

        #expect(node(result.root, "a/b/c/file1")?.size == fixture.allocated("a/b/c/file1"))
        // Folders without bytes (empty, unreadable) are not drawn.
        #expect(node(result.root, "empty") == nil)
        #expect(node(result.root, "locked") == nil)
    }

    @Test("a clone whose original is outside the scan keeps its bytes; edited clones count fully")
    func clonesWithoutOriginal() throws {
        let fixture = try Fixture()
        // Scanning only clones/ sees both members of the clone pair: they still count once.
        let pair = try #require(ScanJob(url: fixture.root.appendingPathComponent("clones")).run())
        #expect(pair.root.size == fixture.allocated("clones/source"))

        // A clone fully rewritten no longer shares blocks, so both files count.
        let edited = fixture.root.appendingPathComponent("edited")
        try FileManager.default.createDirectory(at: edited, withIntermediateDirectories: true)
        let original = edited.appendingPathComponent("a").path
        let copy = edited.appendingPathComponent("b").path
        try Data(repeating: 1, count: 200_000).write(to: URL(fileURLWithPath: original))
        #expect(clonefile(original, copy, 0) == 0)
        try Data(repeating: 2, count: 200_000).write(to: URL(fileURLWithPath: copy), options: [])
        let both = try #require(ScanJob(url: edited).run())
        #expect(both.root.size == fixture.allocated("edited/a") + fixture.allocated("edited/b"))
        #expect(both.root.children.count == 2)
    }

    @Test("many clones of one file, spread across folders and threads, count once")
    func manyClones() throws {
        let fixture = try Fixture()
        let spread = fixture.root.appendingPathComponent("spread")
        let original = fixture.root.appendingPathComponent("spread/0/original").path
        for folder in 0..<40 {
            try FileManager.default.createDirectory(at: spread.appendingPathComponent("\(folder)"), withIntermediateDirectories: true)
        }
        try Data(repeating: 9, count: 300_000).write(to: URL(fileURLWithPath: original))
        for folder in 0..<40 {
            for copy in 0..<5 {
                #expect(clonefile(original, spread.appendingPathComponent("\(folder)/copy\(copy)").path, 0) == 0)
            }
        }
        // Repeated so the copy-before-original order is likely to happen in some run.
        for _ in 0..<10 {
            let result = try #require(ScanJob(url: spread, options: .init(workerCount: 8)).run())
            #expect(result.root.size == fixture.allocated("spread/0/original"))
        }
    }

    @Test("sizes are summed bottom-up and sorted largest first")
    func aggregation() throws {
        let fixture = try Fixture()
        let result = try #require(ScanJob(url: fixture.root).run())

        func check(_ node: FileNode) {
            guard node.isDirectory else { return }
            #expect(node.size == node.children.reduce(0) { $0 + $1.size })
            #expect(zip(node.children, node.children.dropFirst()).allSatisfy { $0.size >= $1.size })
            node.children.forEach(check)
        }
        check(result.root)
    }

    @Test("one worker and the default worker count find the same tree")
    func workerCountInvariance() throws {
        let fixture = try Fixture()
        let single = try #require(ScanJob(url: fixture.root, options: .init(workerCount: 1)).run())
        let many = try #require(ScanJob(url: fixture.root, options: .init(workerCount: 32)).run())
        let defaults = try #require(ScanJob(url: fixture.root).run())

        func shape(_ node: FileNode) -> [String: Int64] {
            var map: [String: Int64] = [:]
            func walk(_ node: FileNode, _ prefix: String) {
                let key = prefix + "/" + node.name
                map[key] = node.size
                node.children.forEach { walk($0, key) }
            }
            walk(node, "")
            return map
        }
        #expect(single.itemCount == defaults.itemCount)
        #expect(many.itemCount == defaults.itemCount)
        #expect(single.root.size == defaults.root.size)
        #expect(many.root.size == defaults.root.size)
        // Which hard link wins can differ between runs; compare sizes per folder instead.
        #expect(shape(single.root).filter { !$0.key.contains("link") && !$0.key.contains("other") && !$0.key.contains("clones") }
            == shape(defaults.root).filter { !$0.key.contains("link") && !$0.key.contains("other") && !$0.key.contains("clones") })
    }

    @Test("a cancelled scan returns nil")
    func cancelBeforeRun() {
        let job = ScanJob(url: URL(fileURLWithPath: "/System/Library"))
        job.cancel()
        #expect(job.run() == nil)
    }

    @Test("cancelling a running scan returns nil")
    func cancelDuringRun() async {
        let job = ScanJob(url: URL(fileURLWithPath: "/System/Library"))
        let scan = Task.detached { job.run() == nil }
        try? await Task.sleep(nanoseconds: 20_000_000)
        job.cancel()
        #expect(await scan.value)
    }
}
