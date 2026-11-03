import TrashFreeCore
import Foundation

// Usage: tfscan <path> [--startup]
// Prints the scan's top-level breakdown so it can be diffed against `du -sk` or DaisyDisk.
let arguments = CommandLine.arguments.dropFirst()
guard let path = arguments.first(where: { !$0.hasPrefix("--") }) else {
    FileHandle.standardError.write(Data("usage: tfscan <path> [--startup]\n".utf8))
    exit(2)
}

let job = ScanJob(
    url: URL(fileURLWithPath: path),
    options: arguments.contains("--startup") ? .startupDisk(expectedBytes: nil) : .init()
)
guard let result = job.run() else { exit(1) }

print("total\t\(result.root.size)\t\(ByteSizeFormatter.string(fromByteCount: result.root.size))")
print(String(format: "items\t%d\tseconds\t%.2f", result.itemCount, result.duration))
for child in result.root.children.prefix(15) {
    print("\(child.name)\t\(child.size)\t\(ByteSizeFormatter.string(fromByteCount: child.size))")
}
