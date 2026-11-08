import TrashFreeCore
import CoreServices
import Foundation

// Usage: tfscan <path> [--startup] [--threads N] [--runs N] [--tsv]
// Prints the scan's top-level breakdown so it can be diffed against `du -sk` or DaisyDisk.
// With --tsv, prints one row per run instead: target, run, threads, seconds, items, bytes.
var arguments = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    FileHandle.standardError.write(Data("usage: tfscan <path> [--startup] [--threads N] [--runs N] [--tsv]\n".utf8))
    exit(2)
}

func value(of flag: String) -> Int? {
    guard let index = arguments.firstIndex(of: flag) else { return nil }
    guard index + 1 < arguments.count, let number = Int(arguments[index + 1]), number > 0 else { usage() }
    arguments.removeSubrange(index...index + 1)
    return number
}

let threads = value(of: "--threads")
let runs = value(of: "--runs") ?? 1
let tsv = arguments.contains("--tsv")
let startup = arguments.contains("--startup")
let save = arguments.contains("--save")
if arguments.contains("--refresh") {
    guard let path = arguments.first(where: { !$0.hasPrefix("--") }) else { usage() }
    let url = URL(fileURLWithPath: path)
    let started = Date()
    guard let snapshot = ScanSnapshot.load(for: url) else { print("no snapshot"); exit(1) }
    let loaded = Date()
    guard let changed = snapshot.changes() else { print("history unusable; full scan needed"); exit(3) }
    let queried = Date()
    let eventID = FSEventsGetCurrentEventId()
    var options: ScanJob.Options = startup ? .startupDisk(expectedBytes: nil) : .init()
    options.workerCount = threads
    guard let result = ScanJob(refreshing: snapshot.result, changed: changed, options: options).run() else { exit(1) }
    let refreshed = Date()
    if save { try ScanSnapshot.save(result, eventID: eventID, volumeUUID: snapshot.volumeUUID) }
    print(String(format: "load\t%.3f\tquery\t%.3f\trefresh\t%.3f\ttotal\t%.3f\tfolders\t%d\titems\t%d\tbytes\t%lld",
                 loaded.timeIntervalSince(started), queried.timeIntervalSince(loaded), refreshed.timeIntervalSince(queried),
                 refreshed.timeIntervalSince(started), changed.count, result.itemCount, result.root.size))
    if let dump = ProcessInfo.processInfo.environment["TF_DUMP"] {
        var lines: [String] = []
        func walk(_ node: FileNode, _ path: String) {
            if node.isDirectory { node.children.forEach { walk($0, path + "/" + $0.name) } } else { lines.append("\(path)\t\(node.size)") }
        }
        walk(result.root, path)
        try? (lines.sorted().joined(separator: "\n") + "\n").write(toFile: dump, atomically: true, encoding: .utf8)
    }
    exit(0)
}
if arguments.contains("--load") {
    guard let path = arguments.first(where: { !$0.hasPrefix("--") }) else { usage() }
    let started = Date()
    guard let snapshot = ScanSnapshot.load(for: URL(fileURLWithPath: path)) else { print("no snapshot"); exit(1) }
    print(String(format: "load\t%.3f\titems\t%d\tbytes\t%lld", Date().timeIntervalSince(started), snapshot.result.itemCount, snapshot.result.root.size))
    exit(0)
}
guard let path = arguments.first(where: { !$0.hasPrefix("--") }) else { usage() }

for run in 1...runs {
    var options: ScanJob.Options = startup ? .startupDisk(expectedBytes: nil) : .init()
    options.workerCount = threads
    let job = ScanJob(url: URL(fileURLWithPath: path), options: options)
    let eventID = FSEventsGetCurrentEventId()
    guard let result = job.run() else { exit(1) }
    if save {
        let started = Date()
        try ScanSnapshot.save(result, eventID: eventID, volumeUUID: ScanSnapshot.volumeUUID(for: result.rootURL))
        FileHandle.standardError.write(Data(String(format: "saved in %.3f s\n", Date().timeIntervalSince(started)).utf8))
    }
    if let dump = ProcessInfo.processInfo.environment["TF_DUMP"] {
        var lines: [String] = []
        func walk(_ node: FileNode, _ path: String) {
            if node.isDirectory { node.children.forEach { walk($0, path + "/" + $0.name) } } else { lines.append("\(path)\t\(node.size)") }
        }
        walk(result.root, path)
        try? (lines.sorted().joined(separator: "\n") + "\n").write(toFile: dump, atomically: true, encoding: .utf8)
    }

    if tsv {
        let threadLabel = threads.map(String.init) ?? "default"
        print(String(format: "%@\t%d\t%@\t%.3f\t%d\t%lld", path, run, threadLabel, result.duration, result.itemCount, result.root.size))
        fflush(stdout)
        continue
    }
    print("total\t\(result.root.size)\t\(ByteSizeFormatter.string(fromByteCount: result.root.size))")
    print(String(format: "items\t%d\tseconds\t%.2f", result.itemCount, result.duration))
    for child in result.root.children.prefix(15) {
        print("\(child.name)\t\(child.size)\t\(ByteSizeFormatter.string(fromByteCount: child.size))")
    }
}
