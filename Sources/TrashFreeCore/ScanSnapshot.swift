import CoreServices
import Foundation

/// A finished scan saved to disk, so the next launch can show it at once and then
/// rescan only the folders FSEvents says changed.
///
/// File layout, little-endian:
///   header: magic "TFS5", eventID u64, scan date f64, duration f64, itemCount u64,
///           volume UUID (36 bytes, empty-padded), root path length u32 + UTF-8
///   nodes in preorder: name length u16, name UTF-8, isDirectory u8, file ID u64,
///                      then for files size i64, clone ID u64, device i32; for folders
///                      child count u32
///   shared streams: count u32, then per stream: device i32, clone ID u64,
///                   held by original u8, holder node index u32, twin count u32,
///                   twins (parent node index u32, name length u16, name, size i64,
///                   file ID u64)
///   Node indexes count nodes in preorder from 0.
/// Preorder with child counts rebuilds every parent link with one stack and no IDs.
public struct ScanSnapshot {
    public let result: ScanResult
    /// FSEvents ID taken before the scan's walk began, so changes during the walk replay.
    public let eventID: FSEventStreamEventId
    public let scannedAt: Date
    public let volumeUUID: String

    static let magic: [UInt8] = Array("TFS5".utf8)

    /// Where snapshots live. Caches, because losing one only costs a full scan.
    public static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.kartikyadav.trashfree/Scans", isDirectory: true)
    }

    public static func file(for rootURL: URL) -> URL {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in rootURL.standardizedFileURL.path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return directory.appendingPathComponent(String(hash, radix: 16) + ".tfscan")
    }

    /// The UUID FSEvents keys its history by; a different one means the history is not ours.
    public static func volumeUUID(for url: URL) -> String {
        var info = stat()
        guard stat(url.path, &info) == 0, let uuid = FSEventsCopyUUIDForDevice(info.st_dev) else { return "" }
        return CFUUIDCreateString(nil, uuid) as String
    }

    // MARK: Changes since the snapshot

    /// Folders that changed under the snapshot's root since it was taken, from FSEvents
    /// history. nil means the history cannot be trusted and the caller must scan in full:
    /// a different volume, dropped or wrapped events, or a change to the root itself.
    public func changes() -> [String: RefreshDepth]? {
        changesOrReason().changes
    }

    /// The changed folders, or why the history cannot be used.
    public func changesOrReason() -> (changes: [String: RefreshDepth]?, reason: String?) {
        guard !volumeUUID.isEmpty, volumeUUID == Self.volumeUUID(for: result.rootURL) else {
            return (nil, "volume UUID \(volumeUUID) is now \(Self.volumeUUID(for: result.rootURL))")
        }
        let root = result.rootURL.path
        // FSEvents names folders by their real path: /private/var for /var, and
        // /System/Volumes/Data/... for folders the startup disk reaches through firmlinks.
        var aliases = [(real: Self.realpath(root) ?? root, spelled: root)]
        if root == "/" { aliases.append((real: "/System/Volumes/Data", spelled: "")) }
        let collector = ChangeCollector(root: root, aliases: aliases)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(collector).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            let collector = Unmanaged<ChangeCollector>.fromOpaque(info!).takeUnretainedValue()
            let names = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            for index in 0..<min(count, names.count) { collector.add(names[index], flags: Int(flags[index])) }
        }
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [root] as CFArray,
                                               eventID, 0, FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes))
        else { return (nil, "could not create an FSEvents stream") }
        let queue = DispatchQueue(label: "dev.kartikyadav.trashfree.fsevents")
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamRelease(stream)
            return (nil, "could not start an FSEvents stream")
        }
        // Replaying history takes milliseconds; the deadline only guards a stuck daemon.
        let finished = collector.done.wait(timeout: .now() + 10) == .success
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        return queue.sync {
            if !finished { return (nil, "history did not finish within 10 s") }
            if collector.mustRescanAll { return (nil, collector.rejection) }
            return (collector.changed, nil)
        }
    }

    private final class ChangeCollector {
        let root: String
        let aliases: [(real: String, spelled: String)]
        var changed: [String: RefreshDepth] = [:]
        var mustRescanAll = false
        var rejection: String?
        let done = DispatchSemaphore(value: 0)
        private var finished = false

        init(root: String, aliases: [(real: String, spelled: String)]) {
            self.root = root
            self.aliases = aliases.filter { $0.real != $0.spelled }
        }

        private func spelled(_ path: String) -> String {
            for alias in aliases where path == alias.real || path.hasPrefix(alias.real + "/") {
                let rest = path.dropFirst(alias.real.count)
                let joined = alias.spelled + rest
                return joined.isEmpty ? "/" : joined
            }
            return path
        }

        func add(_ path: String, flags: Int) {
            guard !finished else { return }
            if flags & kFSEventStreamEventFlagHistoryDone != 0 {
                finished = true
                done.signal()
                return
            }
            let trimmed = spelled(path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path)
            let lost = kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged
                | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount
            if flags & lost != 0 || (flags & kFSEventStreamEventFlagMustScanSubDirs != 0 && trimmed == root) {
                mustRescanAll = true
                rejection = String(format: "flags 0x%x at %@", flags, path)
                return
            }
            if flags & kFSEventStreamEventFlagMustScanSubDirs != 0 {
                changed[trimmed] = .subtree
            } else if changed[trimmed] == nil {
                changed[trimmed] = .entries
            }
        }
    }

    // MARK: Writing

    public static func save(_ result: ScanResult, eventID: FSEventStreamEventId, volumeUUID: String) throws {
        var out = Data()
        out.reserveCapacity(result.itemCount * 24 + 1024)
        out.append(contentsOf: magic)
        append(&out, eventID)
        append(&out, Date().timeIntervalSince1970)
        append(&out, result.duration)
        append(&out, UInt64(result.itemCount))
        var uuid = Array(volumeUUID.utf8.prefix(36))
        uuid += [UInt8](repeating: 0, count: 36 - uuid.count)
        out.append(contentsOf: uuid)
        let rootPath = Array(result.rootURL.path.utf8)
        append(&out, UInt32(rootPath.count))
        out.append(contentsOf: rootPath)

        var referenced = Set<ObjectIdentifier>()
        for claim in result.sharedStreams.values {
            if let holder = claim.holder { referenced.insert(ObjectIdentifier(holder)) }
            for twin in claim.skipped { referenced.insert(ObjectIdentifier(twin.parent)) }
        }
        var indexes: [ObjectIdentifier: UInt32] = [:]
        var index: UInt32 = 0
        var stack: [FileNode] = [result.root]
        while let node = stack.popLast() {
            if referenced.contains(ObjectIdentifier(node)) { indexes[ObjectIdentifier(node)] = index }
            index += 1
            let name = Array(node.name.utf8.prefix(Int(UInt16.max)))
            append(&out, UInt16(name.count))
            out.append(contentsOf: name)
            out.append(node.isDirectory ? 1 : 0)
            append(&out, node.fileID)
            if node.isDirectory {
                append(&out, UInt32(node.children.count))
                stack.append(contentsOf: node.children.reversed())
            } else {
                append(&out, node.size)
                append(&out, node.cloneID)
                append(&out, node.device)
            }
        }
        let streams = result.sharedStreams.filter { $0.value.holder.map { indexes[ObjectIdentifier($0)] != nil } ?? false }
        append(&out, UInt32(streams.count))
        for (key, claim) in streams {
            append(&out, key.device)
            append(&out, key.cloneID)
            out.append(claim.heldByOriginal ? 1 : 0)
            append(&out, indexes[ObjectIdentifier(claim.holder!)]!)
            let twins = claim.skipped.filter { indexes[ObjectIdentifier($0.parent)] != nil }
            append(&out, UInt32(twins.count))
            for twin in twins {
                append(&out, indexes[ObjectIdentifier(twin.parent)]!)
                let name = Array(twin.name.utf8.prefix(Int(UInt16.max)))
                append(&out, UInt16(name.count))
                out.append(contentsOf: name)
                append(&out, twin.size)
                append(&out, twin.fileID)
            }
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = file(for: result.rootURL)
        // The file lists every file name the user has, so only the user may read it.
        let temporary = url.appendingPathExtension("tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: out, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    public static func remove(for rootURL: URL) {
        try? FileManager.default.removeItem(at: file(for: rootURL))
    }

    // MARK: Reading

    /// nil when there is no snapshot or it cannot be read; the caller then scans.
    public static func load(for rootURL: URL) -> ScanSnapshot? {
        guard let data = try? Data(contentsOf: file(for: rootURL), options: .mappedIfSafe) else { return nil }
        return data.withUnsafeBytes { raw -> ScanSnapshot? in
            var reader = Reader(raw)
            guard reader.bytes(4) == magic,
                  let eventID = reader.read(UInt64.self),
                  let scannedAt = reader.read(Double.self),
                  let duration = reader.read(Double.self),
                  let itemCount = reader.read(UInt64.self),
                  let uuidBytes = reader.bytes(36),
                  let pathLength = reader.read(UInt32.self),
                  let pathBytes = reader.bytes(Int(pathLength)),
                  String(decoding: pathBytes, as: UTF8.self) == rootURL.path
            else { return nil }
            let uuid = String(decoding: uuidBytes.prefix { $0 != 0 }, as: UTF8.self)

            // (folder, children still to read)
            var open: [(FileNode, Int)] = []
            var root: FileNode?
            var nodes: [FileNode] = []
            nodes.reserveCapacity(Int(itemCount) + 1)
            while root == nil || !open.isEmpty {
                guard let nameLength = reader.read(UInt16.self),
                      let name = reader.string(Int(nameLength)),
                      let kind = reader.read(UInt8.self), let fileID = reader.read(UInt64.self) else { return nil }
                let parent = open.last?.0
                let node: FileNode
                if kind == 1 {
                    guard let count = reader.read(UInt32.self) else { return nil }
                    node = FileNode(name: name, isDirectory: true, parent: parent)
                    node.fileID = fileID
                    nodes.append(node)
                    node.children.reserveCapacity(Int(count))
                    parent?.children.append(node)
                    if root == nil { root = node }
                    if count > 0 { open.append((node, Int(count))) } else { Self.close(&open) }
                } else {
                    guard let size = reader.read(Int64.self), let cloneID = reader.read(UInt64.self),
                          let device = reader.read(Int32.self) else { return nil }
                    node = FileNode(name: name, isDirectory: false, size: size, parent: parent)
                    node.fileID = fileID
                    node.cloneID = cloneID
                    node.device = device
                    nodes.append(node)
                    parent?.children.append(node)
                    Self.close(&open)
                }
            }
            guard let root, let sharedCount = reader.read(UInt32.self) else { return nil }
            var shared: [DataStreamKey: DataStreamClaim] = [:]
            shared.reserveCapacity(Int(sharedCount))
            for _ in 0..<sharedCount {
                guard let device = reader.read(Int32.self), let cloneID = reader.read(UInt64.self),
                      let original = reader.read(UInt8.self), let holder = reader.read(UInt32.self),
                      Int(holder) < nodes.count, let twinCount = reader.read(UInt32.self) else { return nil }
                var claim = DataStreamClaim(holder: nodes[Int(holder)], heldByOriginal: original == 1)
                for _ in 0..<twinCount {
                    guard let parent = reader.read(UInt32.self), Int(parent) < nodes.count,
                          let nameLength = reader.read(UInt16.self), let name = reader.string(Int(nameLength)),
                          let size = reader.read(Int64.self), let twinID = reader.read(UInt64.self) else { return nil }
                    claim.skipped.append(SkippedTwin(parent: nodes[Int(parent)], name: name, size: size, fileID: twinID))
                }
                shared[DataStreamKey(device: device, cloneID: cloneID)] = claim
            }
            root.aggregate()
            root.assignHues(offset: 0, total: Double(root.size))
            let result = ScanResult(root: root, rootURL: rootURL, duration: duration, itemCount: Int(itemCount),
                                    sharedStreams: shared)
            return ScanSnapshot(result: result, eventID: eventID,
                                scannedAt: Date(timeIntervalSince1970: scannedAt), volumeUUID: uuid)
        }
    }

    /// Counts one finished child against its folder, popping every folder that is now full.
    private static func realpath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func close(_ open: inout [(FileNode, Int)]) {
        while var last = open.popLast() {
            last.1 -= 1
            if last.1 > 0 { open.append(last); return }
        }
    }

    private static func append<T>(_ data: inout Data, _ value: T) {
        withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
    }

    private struct Reader {
        let raw: UnsafeRawBufferPointer
        var offset = 0
        init(_ raw: UnsafeRawBufferPointer) { self.raw = raw }

        mutating func read<T>(_: T.Type) -> T? {
            guard offset + MemoryLayout<T>.size <= raw.count else { return nil }
            defer { offset += MemoryLayout<T>.size }
            return raw.loadUnaligned(fromByteOffset: offset, as: T.self)
        }

        mutating func string(_ count: Int) -> String? {
            guard count >= 0, offset + count <= raw.count else { return nil }
            defer { offset += count }
            let bytes = UnsafeRawBufferPointer(rebasing: raw[offset..<offset + count])
            return String(decoding: bytes.bindMemory(to: UInt8.self), as: UTF8.self)
        }

        mutating func bytes(_ count: Int) -> [UInt8]? {
            guard count >= 0, offset + count <= raw.count else { return nil }
            defer { offset += count }
            return Array(raw[offset..<offset + count])
        }
    }
}
