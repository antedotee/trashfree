import TrashFreeCore
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
guard let path = arguments.first(where: { !$0.hasPrefix("--") }) else { usage() }

for run in 1...runs {
    var options: ScanJob.Options = startup ? .startupDisk(expectedBytes: nil) : .init()
    options.workerCount = threads
    let job = ScanJob(url: URL(fileURLWithPath: path), options: options)
    guard let result = job.run() else { exit(1) }

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
