// Usage: swift scripts/frames.swift <movie> <out-dir> <fps> [start-seconds] [end-seconds]
// Extracts frames from a screen recording (screencapture -v) as PNGs, so motion can be
// compared frame by frame. No ffmpeg needed.
import AVFoundation
import AppKit

let args = CommandLine.arguments
guard args.count >= 4, let fps = Double(args[3]) else {
    FileHandle.standardError.write("usage: frames.swift <movie> <out-dir> <fps> [start] [end]\n".data(using: .utf8)!)
    exit(2)
}
let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let out = URL(fileURLWithPath: args[2], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let duration = CMTimeGetSeconds(asset.duration)
let start = args.count > 4 ? Double(args[4])! : 0
let end = args.count > 5 ? min(Double(args[5])!, duration) : duration
let generator = AVAssetImageGenerator(asset: asset)
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero
generator.maximumSize = CGSize(width: 900, height: 900)
var index = 0
var t = start
while t < end {
    let time = CMTime(seconds: t, preferredTimescale: 600)
    if let image = try? generator.copyCGImage(at: time, actualTime: nil) {
        let rep = NSBitmapImageRep(cgImage: image)
        let name = String(format: "f%03d-%05.0fms.png", index, (t - start) * 1000)
        try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
        index += 1
    }
    t += 1 / fps
}
print("\(index) frames, movie \(String(format: "%.2f", duration))s")
