import CoreServices
import Darwin
import Foundation
import Testing
@testable import TrashFreeCore

/// Every file in a scan tree with its counted size, keyed by path under the root.
private func files(_ result: ScanResult) -> [String: Int64] {
    var map: [String: Int64] = [:]
    func walk(_ node: FileNode, _ path: String) {
        if node.isDirectory { node.children.forEach { walk($0, path + "/" + $0.name) } } else { map[path] = node.size }
    }
    walk(result.root, "")
    return map
}

/// Bytes per folder. The fixture's hard links span /links and /other, and either twin may
/// carry the bytes from one scan to the next, so those two folders are compared summed.
private func folderTotals(_ result: ScanResult) -> [String: Int64] {
    var map: [String: Int64] = [:]
    func walk(_ node: FileNode, _ path: String) {
        guard node.isDirectory else { return }
        let key = path == "/links" || path == "/other" ? "/links+other" : path
        map[key, default: 0] += node.size
        node.children.forEach { walk($0, path + "/" + $0.name) }
    }
    walk(result.root, "")
    return map
}

private func write(_ bytes: Int, to url: URL) throws {
    try Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 13) }).write(to: url)
}

@Suite("Refresh", .serialized)
struct RefreshTests {
    @Test("a refresh after adds, deletes, growth and a new folder equals a full scan")
    func matchesFullScan() throws {
        let fixture = try Fixture()
        let before = try #require(ScanJob(url: fixture.root).run())
        let fm = FileManager.default

        try write(70_000, to: fixture.root.appendingPathComponent("a/b/c/added"))
        try fm.removeItem(at: fixture.root.appendingPathComponent("sparse"))
        try fm.createDirectory(at: fixture.root.appendingPathComponent("a/new/deeper"), withIntermediateDirectories: true)
        try write(40_000, to: fixture.root.appendingPathComponent("a/new/deeper/inside"))
        let handle = try FileHandle(forWritingTo: fixture.root.appendingPathComponent("a/b/c/file1"))
        handle.seekToEndOfFile()
        handle.write(Data(repeating: 3, count: 90_000))
        try handle.close()

        let changed: [String: RefreshDepth] = [
            fixture.path("a/b/c"): .entries, fixture.root.path: .entries, fixture.path("a"): .entries,
            fixture.path("a/new"): .entries, fixture.path("a/new/deeper"): .entries,
        ]
        let refreshed = try #require(ScanJob(refreshing: before, changed: changed).run())
        let full = try #require(ScanJob(url: fixture.root).run())
        #expect(refreshed.root.size == full.root.size)
        #expect(folderTotals(refreshed) == folderTotals(full))
        #expect(files(refreshed)["/a/new/deeper/inside"] == fixture.allocated("a/new/deeper/inside"))
        #expect(files(refreshed)["/sparse"] == nil)
    }

    @Test("relisting a folder whose hard link is counted elsewhere still counts the bytes once")
    func sharedStreamAcrossFolders() throws {
        let fixture = try Fixture()
        let before = try #require(ScanJob(url: fixture.root).run())
        // Relist both folders holding links to "original", one at a time and together.
        for folders in [["links"], ["other"], ["links", "other"]] {
            let changed = Dictionary(uniqueKeysWithValues: folders.map { (fixture.path($0), RefreshDepth.entries) })
            let refreshed = try #require(ScanJob(refreshing: before, changed: changed).run())
            #expect(refreshed.root.size == fixture.expectedBytes, "relisted \(folders)")
        }
        // Clones the same way.
        let clones = try #require(ScanJob(refreshing: before, changed: [fixture.path("clones"): .entries]).run())
        #expect(clones.root.size == fixture.expectedBytes)
    }

    @Test("a new clone of a file counted in an untouched folder is not counted again")
    func newCloneOfCountedFile() throws {
        let fixture = try Fixture()
        let before = try #require(ScanJob(url: fixture.root).run())
        // iCloud's staging folder does this: it gains a clone of a file stored elsewhere.
        #expect(clonefile(fixture.path("a/b/c/file1"), fixture.path("clones/staged"), 0) == 0)
        let refreshed = try #require(ScanJob(refreshing: before, changed: [fixture.path("clones"): .entries]).run())
        let full = try #require(ScanJob(url: fixture.root).run())
        #expect(refreshed.root.size == full.root.size)
        #expect(refreshed.root.size == fixture.expectedBytes)
    }

    @Test("when the counted twin is deleted, its clone elsewhere takes over the bytes")
    func countedTwinDeleted() throws {
        let fixture = try Fixture()
        let first = try #require(ScanJob(url: fixture.root).run())
        #expect(clonefile(fixture.path("a/b/c/file1"), fixture.path("clones/staged"), 0) == 0)
        let second = try #require(ScanJob(refreshing: first, changed: [fixture.path("clones"): .entries]).run())
        try FileManager.default.removeItem(atPath: fixture.path("a/b/c/file1"))
        let third = try #require(ScanJob(refreshing: second, changed: [fixture.path("a/b/c"): .entries]).run())
        let full = try #require(ScanJob(url: fixture.root).run())
        #expect(third.root.size == full.root.size)
        #expect(folderTotals(third) == folderTotals(full))
    }

    @Test("a folder replaced by renaming another over it is listed anew, though only its parent changed")
    func replacedFolder() throws {
        let fixture = try Fixture()
        let before = try #require(ScanJob(url: fixture.root).run())
        let staging = fixture.root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("inner"), withIntermediateDirectories: true)
        try write(150_000, to: staging.appendingPathComponent("inner/new"))
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("a"))
        #expect(rename(staging.path, fixture.path("a")) == 0)
        let refreshed = try #require(ScanJob(refreshing: before, changed: [fixture.root.path: .entries]).run())
        let full = try #require(ScanJob(url: fixture.root).run())
        #expect(folderTotals(refreshed) == folderTotals(full))
        #expect(files(refreshed)["/a/inner/new"] != nil)
        #expect(files(refreshed)["/a/b/c/file1"] == nil)
    }

    @Test("a subtree refresh relists everything below the folder")
    func subtree() throws {
        let fixture = try Fixture()
        let before = try #require(ScanJob(url: fixture.root).run())
        try write(30_000, to: fixture.root.appendingPathComponent("a/b/c/deep"))
        let refreshed = try #require(ScanJob(refreshing: before, changed: [fixture.path("a"): .subtree]).run())
        let full = try #require(ScanJob(url: fixture.root).run())
        #expect(folderTotals(refreshed) == folderTotals(full))
    }

    @Test("a snapshot loads back the same tree")
    func roundTrip() throws {
        let fixture = try Fixture()
        defer { ScanSnapshot.remove(for: fixture.root) }
        let result = try #require(ScanJob(url: fixture.root).run())
        try ScanSnapshot.save(result, eventID: 42, volumeUUID: "UUID")
        let loaded = try #require(ScanSnapshot.load(for: fixture.root))
        #expect(loaded.eventID == 42)
        #expect(loaded.volumeUUID == "UUID")
        #expect(files(loaded.result) == files(result))
        #expect(folderTotals(loaded.result) == folderTotals(result))
        #expect(loaded.result.sharedStreams.count == result.sharedStreams.count)
        #expect(ScanSnapshot.load(for: fixture.root.appendingPathComponent("a")) == nil)
    }

    @Test("FSEvents history since a snapshot names the folders that changed")
    func historyEndToEnd() throws {
        let fixture = try Fixture()
        defer { ScanSnapshot.remove(for: fixture.root) }
        let eventID = FSEventsGetCurrentEventId()
        let before = try #require(ScanJob(url: fixture.root).run())
        try ScanSnapshot.save(before, eventID: eventID, volumeUUID: ScanSnapshot.volumeUUID(for: fixture.root))
        try write(80_000, to: fixture.root.appendingPathComponent("a/b/later"))
        // fseventsd writes history with up to a second or so of latency.
        Thread.sleep(forTimeInterval: 3)

        let snapshot = try #require(ScanSnapshot.load(for: fixture.root))
        let changed = try #require(snapshot.changes())
        #expect(changed[fixture.path("a/b")] != nil)
        let refreshed = try #require(ScanJob(refreshing: snapshot.result, changed: changed).run())
        let full = try #require(ScanJob(url: fixture.root).run())
        #expect(folderTotals(refreshed) == folderTotals(full))
    }
}
