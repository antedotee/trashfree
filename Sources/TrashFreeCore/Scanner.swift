import Darwin
import Foundation
import os

/// A finished scan: the tree plus the location it was rooted at.
///
/// The tree is handed from the scanning threads to the app, and from the app to the
/// snapshot writer; each hand-off waits for the previous owner to finish writing it.
public struct ScanResult: @unchecked Sendable {
    public let root: FileNode
    public let rootURL: URL
    public let duration: TimeInterval
    public let itemCount: Int
    /// Data streams more than one file pointed at, and which file's bytes were counted.
    /// A refresh starts from these, so relisting one folder never counts a clone or hard
    /// link whose twin elsewhere already carries the bytes.
    let sharedStreams: [DataStreamKey: DataStreamClaim]

    init(root: FileNode, rootURL: URL, duration: TimeInterval, itemCount: Int,
         sharedStreams: [DataStreamKey: DataStreamClaim] = [:]) {
        self.root = root
        self.rootURL = rootURL
        self.duration = duration
        self.itemCount = itemCount
        self.sharedStreams = sharedStreams
    }
}

struct DataStreamKey: Hashable {
    let device: Int32
    let cloneID: UInt64
}

struct DataStreamClaim {
    /// The file whose bytes were counted, or nil while a refresh relists the folder it
    /// was in: the first twin listed then takes over.
    var holder: FileNode?
    var heldByOriginal: Bool
    /// Twins listed with no bytes, kept so a refresh can promote one if the holder goes.
    var skipped: [SkippedTwin] = []
    var collided: Bool { !skipped.isEmpty }
}

struct SkippedTwin {
    let parent: FileNode
    let name: String
    let size: Int64
    let fileID: UInt64
}

/// How much of a folder a refresh relists.
public enum RefreshDepth {
    /// The folder's own entries; subfolders that still exist keep their scanned contents.
    case entries
    /// The folder and everything under it.
    case subtree
}

/// A parallel directory walk built on `getattrlistbulk(2)`.
///
/// Workers pop directories off one shared LIFO stack, list them in a single syscall
/// batch, and push the subdirectories back. Depth-first order keeps the frontier small.
/// Each worker is the only writer of the directory it lists, so the tree itself needs no
/// lock; the lock guards only the stack and the progress counters.
public final class ScanJob: @unchecked Sendable {
    public struct Options: Sendable {
        /// Bytes the scan is expected to find, e.g. a volume's used space. When set,
        /// progress follows bytes found; otherwise it follows the share of the tree walked.
        public var expectedBytes: Int64?
        /// Mount points the walk may cross. Every other mount point is a different disk.
        public var enteredMountPoints: @Sendable (String) -> Bool
        /// Directories never listed.
        public var excludedPaths: Set<String>
        /// Threads listing directories at once. nil picks the default.
        public var workerCount: Int?

        public init(
            expectedBytes: Int64? = nil,
            enteredMountPoints: @escaping @Sendable (String) -> Bool = { _ in false },
            excludedPaths: Set<String> = [],
            workerCount: Int? = nil
        ) {
            self.expectedBytes = expectedBytes
            self.enteredMountPoints = enteredMountPoints
            self.excludedPaths = excludedPaths
            self.workerCount = workerCount
        }

        /// Rules for the startup disk. The APFS volumes under /System/Volumes (VM, Preboot,
        /// Update...) share its container, so they count toward its used space.
        /// /System/Volumes/Data is skipped because its folders are already reached through
        /// the firmlinks at / (Users, Applications...). /Volumes holds only other disks'
        /// mount points, and a stale Time Machine mount there blocks the listing forever.
        /// Preboot/Cryptexes are graft mounts of the cryptex disk images that Preboot
        /// already stores as files, so walking them would count those bytes twice.
        public static func startupDisk(expectedBytes: Int64?) -> Options {
            Options(
                expectedBytes: expectedBytes,
                enteredMountPoints: { $0.hasPrefix("/System/Volumes/") },
                excludedPaths: ["/Volumes", "/System/Volumes/Data", "/System/Volumes/Preboot/Cryptexes", "/dev"]
            )
        }
    }

    private struct WorkItem {
        let node: FileNode
        let path: String
        /// Share of the whole walk this directory's subtree represents.
        let weight: Double
        /// Reuse the subfolders the node already has instead of listing them again.
        var keepsSubfolders = false
    }

    public let rootURL: URL
    private let options: Options
    private let root: FileNode
    private let condition = NSCondition()
    private var stack: [WorkItem] = []
    private var busyWorkers = 0
    private var completedWeight = 0.0
    private var bytesFound: Int64 = 0
    private var itemsFound = 0
    private var isCancelled = false
    private let dataStreamShards = (0..<64).map { _ in OSAllocatedUnfairLock(initialState: [DataStreamKey: DataStreamClaim]()) }
    private let initialItems: [WorkItem]
    /// Folders a refresh found gone; claims inside them are released at the end.
    private let removedFolders = OSAllocatedUnfairLock(initialState: [FileNode]())
    /// True for a job that updates an earlier scan instead of walking from scratch.
    public let isRefresh: Bool

    public init(url: URL, options: Options = Options()) {
        self.rootURL = url
        self.options = options
        self.root = FileNode(name: url.path == "/" ? "/" : url.lastPathComponent, isDirectory: true, parent: nil)
        self.initialItems = [WorkItem(node: root, path: url.path, weight: 1)]
        self.isRefresh = false
    }

    /// Updates an earlier scan in place by relisting only `changed` folders (absolute
    /// paths, as FSEvents reports them). A folder missing from the tree refreshes its
    /// nearest scanned ancestor, which then finds it as new. The earlier tree must not be
    /// read by anything else until the job finishes.
    public init(refreshing previous: ScanResult, changed: [String: RefreshDepth], options: Options = Options()) {
        self.rootURL = previous.rootURL
        self.options = options
        self.root = previous.root
        self.isRefresh = true

        let rootPath = previous.rootURL.path
        let base = rootPath == "/" ? "" : rootPath
        var targets: [ObjectIdentifier: (node: FileNode, path: String, depth: RefreshDepth)] = [:]
        for (rawPath, depth) in changed {
            let path = rawPath.hasSuffix("/") && rawPath.count > 1 ? String(rawPath.dropLast()) : rawPath
            guard path == rootPath || path.hasPrefix(base + "/") else { continue }
            var node = previous.root
            var nodePath = rootPath
            var depth = depth
            for name in path.dropFirst(base.count).split(separator: "/") {
                guard let child = node.children.first(where: { $0.isDirectory && $0.name == name }) else {
                    // Not in the tree: new, or a folder the scan left out. Its parent's
                    // listing decides which.
                    depth = .entries
                    break
                }
                node = child
                nodePath = base + nodePath.dropFirst(base.count) + "/" + name
            }
            let key = ObjectIdentifier(node)
            if targets[key]?.depth != .subtree { targets[key] = (node, nodePath, depth) }
        }
        // A subtree refresh already covers every folder below it.
        let subtrees = targets.values.filter { $0.depth == .subtree }.map(\.node)
        let kept = targets.values.filter { target in
            !subtrees.contains { $0 !== target.node && target.node.isDescendant(of: $0) }
        }
        let weight = 1 / Double(max(kept.count, 1))
        self.initialItems = kept.map { WorkItem(node: $0.node, path: $0.path, weight: weight, keepsSubfolders: $0.depth == .entries) }

        // Files in relisted folders are listed again, so they leave the claims; a claim
        // whose counted file was among them is released for the first twin listed.
        let relistedFolders = Set(kept.filter { $0.depth == .entries }.map { ObjectIdentifier($0.node) })
        let relistedTrees = kept.filter { $0.depth == .subtree }.map(\.node)
        let isRelisted = { (folder: FileNode) in
            relistedFolders.contains(ObjectIdentifier(folder))
                || relistedTrees.contains { folder === $0 || folder.isDescendant(of: $0) }
        }
        // Every stream counted outside the relisted folders stays claimed, so a file listed
        // again (or newly cloned) there is not counted a second time. Built per shard
        // without locking, then handed over.
        var seeds = [[DataStreamKey: DataStreamClaim]](repeating: [:], count: dataStreamShards.count)
        var walk: [FileNode] = [previous.root]
        while let folder = walk.popLast() {
            let relisted = isRelisted(folder)
            for child in folder.children {
                if child.isDirectory {
                    walk.append(child)
                } else if !relisted && child.cloneID != 0 {
                    let key = DataStreamKey(device: child.device, cloneID: child.cloneID)
                    seeds[Self.shard(for: key.cloneID)][key] = DataStreamClaim(holder: child, heldByOriginal: child.ownsStream)
                }
            }
        }
        for (key, claim) in previous.sharedStreams {
            var carried = seeds[Self.shard(for: key.cloneID)][key] ?? DataStreamClaim(holder: nil, heldByOriginal: false)
            carried.skipped = claim.skipped.filter { !isRelisted($0.parent) }
            // Promoted or not, a stream with twins outside the relisted folders stays known.
            if carried.holder == nil && carried.skipped.isEmpty { continue }
            seeds[Self.shard(for: key.cloneID)][key] = carried
        }
        for (index, shard) in seeds.enumerated() {
            let seeded = shard
            dataStreamShards[index].withLock { $0 = seeded }
        }
    }

    private static func shard(for cloneID: UInt64) -> Int {
        Int(truncatingIfNeeded: (cloneID &* 0x9E37_79B9_7F4A_7C15) >> 58)
    }

    /// 0...1, for a progress bar. Never reaches 1 before the scan finishes.
    public var progress: Double {
        condition.lock()
        defer { condition.unlock() }
        let fraction: Double
        if let expected = options.expectedBytes, expected > 0 {
            fraction = Double(bytesFound) / Double(expected)
        } else {
            fraction = completedWeight
        }
        return min(max(fraction, 0), 0.99)
    }

    public func cancel() {
        condition.lock()
        isCancelled = true
        condition.broadcast()
        condition.unlock()
    }

    /// Runs the scan on background threads. `completion` runs on the main queue with nil
    /// when the scan was cancelled.
    public func start(completion: @escaping (ScanResult?) -> Void) {
        spawnCoordinator { result in
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Blocking variant for command-line use.
    public func run() -> ScanResult? {
        let done = DispatchSemaphore(value: 0)
        var output: ScanResult?
        spawnCoordinator { result in
            output = result
            done.signal()
        }
        done.wait()
        return output
    }

    private func spawnCoordinator(_ finish: @escaping (ScanResult?) -> Void) {
        let coordinator = Thread { [self] in finish(execute()) }
        // Aggregation recurses once per directory level.
        coordinator.stackSize = 16 << 20
        coordinator.qualityOfService = .userInitiated
        coordinator.start()
    }

    private func execute() -> ScanResult? {
        // Listing an evicted iCloud folder otherwise blocks until it downloads, forever
        // if its app is gone and sync is off. With this policy the kernel fails the call
        // instead and the folder's bytes surface as hidden space.
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        let started = Date()
        stack = initialItems
        let group = DispatchGroup()
        let workers = max(1, options.workerCount ?? ProcessInfo.processInfo.activeProcessorCount)
        for _ in 0..<(workers - 1) {
            group.enter()
            let worker = Thread { [self] in
                work()
                group.leave()
            }
            worker.qualityOfService = .userInitiated
            worker.start()
        }
        work()
        group.wait()

        condition.lock()
        let cancelled = isCancelled
        let items = itemsFound
        condition.unlock()
        guard !cancelled else { return nil }

        let removed = Set(removedFolders.withLock { $0 }.map(ObjectIdentifier.init))
        let isGone = { (node: FileNode) -> Bool in
            guard !removed.isEmpty else { return false }
            var current: FileNode? = node
            while let folder = current {
                if removed.contains(ObjectIdentifier(folder)) { return true }
                current = folder.parent
            }
            return false
        }
        var shared: [DataStreamKey: DataStreamClaim] = [:]
        for shard in dataStreamShards {
            let collided = shard.withLock { claims in claims.filter { $0.value.collided || $0.value.holder == nil } }
            for (key, claim) in collided {
                var kept = claim
                kept.skipped.removeAll { isGone($0.parent) }
                if let holder = kept.holder, isGone(holder) { kept.holder = nil }
                if kept.holder == nil {
                    // The counted file is gone; a twin in a folder the refresh kept takes over.
                    guard !kept.skipped.isEmpty else { continue }
                    let twin = kept.skipped.removeFirst()
                    let node = FileNode(name: twin.name, isDirectory: false, size: twin.size, parent: twin.parent)
                    node.fileID = twin.fileID
                    node.cloneID = key.cloneID
                    node.device = key.device
                    twin.parent.children.append(node)
                    kept.holder = node
                }
                if kept.collided { shared[key] = kept }
            }
        }
        root.aggregate()
        root.assignHues(offset: 0, total: Double(root.size))
        return ScanResult(root: root, rootURL: rootURL, duration: Date().timeIntervalSince(started),
                          itemCount: isRefresh ? root.nodeCount : items, sharedStreams: shared)
    }

    // MARK: Worker

    private func work() {
        let bufferSize = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        condition.lock()
        while true {
            while stack.isEmpty && busyWorkers > 0 && !isCancelled {
                condition.wait()
            }
            if isCancelled || (stack.isEmpty && busyWorkers == 0) {
                condition.broadcast()
                condition.unlock()
                return
            }
            let item = stack.removeLast()
            busyWorkers += 1
            condition.unlock()

            let listing = list(item, buffer: buffer, bufferSize: bufferSize)

            condition.lock()
            busyWorkers -= 1
            let subdirectoryCount = listing.subdirectories.count
            let share = item.weight / Double(subdirectoryCount + 1)
            completedWeight += share
            bytesFound += listing.bytes
            itemsFound += listing.itemCount
            for (node, path) in listing.subdirectories {
                stack.append(WorkItem(node: node, path: path, weight: share))
            }
            completedWeight += listing.keptWeight * share
            if subdirectoryCount > 0 || (stack.isEmpty && busyWorkers == 0) {
                condition.broadcast()
            }
        }
    }

    private struct Listing {
        var subdirectories: [(FileNode, String)] = []
        var bytes: Int64 = 0
        var itemCount = 0
        /// Subfolders reused from the earlier scan, which need no listing.
        var keptWeight = 0.0
    }

    private func list(_ item: WorkItem, buffer: UnsafeMutableRawPointer, bufferSize: Int) -> Listing {
        var listing = Listing()
        let fd = open(item.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return listing }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = Attr.common
        request.dirattr = Attr.dirMountStatus
        request.fileattr = Attr.fileLinkCount | Attr.fileAllocSize
        // Not ATTR_CMNEXT_EXT_FLAGS: like CLONE_REFCNT and PRIVATESIZE, it sends APFS down
        // a slow per-file path (one 83k-file folder listed in 8 s with it, 0.23 s without).
        // `sharesBlocks` fetches it only for the few files that need it.
        request.forkattr = Attr.extCloneID

        let parentPath = item.path == "/" ? "" : item.path
        var children: [FileNode] = []
        var previousSubfolders: [String: FileNode] = [:]
        if item.keepsSubfolders {
            for child in item.node.children where child.isDirectory { previousSubfolders[child.name] = child }
        }

        while true {
            let count = getattrlistbulk(fd, &request, buffer, bufferSize, UInt64(FSOPT_ATTR_CMN_EXTENDED))
            if count <= 0 { break }
            var entry = buffer
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                defer { entry += length }
                var reader = AttributeReader(entry + 4)
                let returned = reader.read(attribute_set_t.self)

                // The kernel packs fields in bit order, except ATTR_CMN_ERROR comes first.
                if returned.commonattr & Attr.cmnError != 0 { _ = reader.read(UInt32.self) }
                guard returned.commonattr & Attr.cmnName != 0 else { continue }
                let name = reader.readString()
                let device = returned.commonattr & Attr.cmnDevID != 0 ? reader.read(Int32.self) : 0
                let objectType = returned.commonattr & Attr.cmnObjType != 0 ? reader.read(UInt32.self) : 0
                let fileID = returned.commonattr & Attr.cmnFileID != 0 ? reader.read(UInt64.self) : 0

                if objectType == Attr.typeDirectory {
                    let mountStatus = returned.dirattr & Attr.dirMountStatus != 0 ? reader.read(UInt32.self) : 0
                    let path = parentPath + "/" + name
                    if mountStatus & Attr.mountTrigger != 0 { continue }
                    if mountStatus & Attr.mountPoint != 0 && !options.enteredMountPoints(path) { continue }
                    if options.excludedPaths.contains(path) { continue }
                    if let kept = previousSubfolders[name], kept.fileID == fileID {
                        children.append(kept)
                        listing.keptWeight += 1
                    } else {
                        let node = FileNode(name: name, isDirectory: true, parent: item.node)
                        node.fileID = fileID
                        children.append(node)
                        listing.subdirectories.append((node, path))
                    }
                } else {
                    let linkCount = returned.fileattr & Attr.fileLinkCount != 0 ? reader.read(UInt32.self) : 1
                    let allocated = returned.fileattr & Attr.fileAllocSize != 0 ? reader.read(Int64.self) : 0
                    let cloneID = returned.forkattr & Attr.extCloneID != 0 ? reader.read(UInt64.self) : 0
                    guard allocated > 0 else { continue }
                    let node = FileNode(name: name, isDirectory: false, size: allocated, parent: item.node)
                    node.fileID = fileID
                    node.cloneID = cloneID
                    node.device = device
                    if cloneID != 0 && !countsDataStream(device: device, cloneID: cloneID, fileID: fileID, linkCount: linkCount,
                                                         node: node, at: fd) {
                        continue
                    }
                    children.append(node)
                    listing.bytes += allocated
                }
                listing.itemCount += 1
            }
        }
        if item.keepsSubfolders {
            let listed = Set(children.lazy.filter(\.isDirectory).map(ObjectIdentifier.init))
            let gone = previousSubfolders.values.filter { !listed.contains(ObjectIdentifier($0)) }
            if !gone.isEmpty { removedFolders.withLock { $0.append(contentsOf: gone) } }
        }
        item.node.children = children
        return listing
    }

    /// Whether this file's blocks should be added to the total.
    ///
    /// Each data stream (device, clone ID) counts once. The first file to claim it is
    /// counted, whatever its kind; a later file under a taken key is skipped only if it
    /// really shares blocks. Most files never get here twice, so the slow EXT_FLAGS lookup
    /// runs only on collisions, and only for files whose clone ID differs from their file ID.
    private func countsDataStream(device: Int32, cloneID: UInt64, fileID: UInt64, linkCount: UInt32,
                                  node: FileNode, at directory: Int32) -> Bool {
        let key = DataStreamKey(device: device, cloneID: cloneID)
        let skip = { [self] in
            let twin = SkippedTwin(parent: node.parent!, name: node.name, size: node.size, fileID: node.fileID)
            dataStreamShards[Self.shard(for: cloneID)].withLock { $0[key]?.skipped.append(twin) }
            return false
        }
        switch claimDataStream(key, fileID: fileID, node: node) {
        case .claimed:
            return true
        case .takenByOriginal where linkCount > 1 || cloneID != fileID:
            // A file whose clone ID names another file that was already counted: its clone.
            // iCloud Drive keeps such a clone of every synced file in CloudDocs, so this is
            // the common collision, and skipping the lookup here saves one slow call each.
            return skip()
        case .takenByOriginal, .takenByCopy:
            return sharesData(cloneID: cloneID, fileID: fileID, linkCount: linkCount, at: directory, name: node.name)
                ? skip() : true
        }
    }

    /// Whether a file's blocks may also belong to another file, so it must be counted once.
    ///
    /// Hard links share their file. APFS gives a file that was never cloned, and a clone's
    /// original, a clone ID equal to its file ID; claiming those is harmless, because no
    /// unrelated file has that ID. A file whose clone ID differs is a clone copy, or a file
    /// whose clone ID only numbers it inside an asset store (AssetsV2 files with clone IDs
    /// like 26 that hold different data). Only those need EXT_FLAGS, fetched one file at a time.
    private func sharesData(cloneID: UInt64, fileID: UInt64, linkCount: UInt32, at directory: Int32, name: String) -> Bool {
        if linkCount > 1 || cloneID == fileID { return true }
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = Attr.cmnReturnedAttrs
        request.forkattr = Attr.extFlags
        var reply = (length: UInt32(0), returned: attribute_set_t(), flags: UInt64(0))
        let status = withUnsafeMutableBytes(of: &reply) { bytes in
            getattrlistat(directory, name, &request, bytes.baseAddress, bytes.count,
                          UInt(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED))
        }
        guard status == 0, reply.returned.forkattr & Attr.extFlags != 0 else { return true }
        return reply.flags & Attr.mayShareBlocks != 0
    }

    /// True the first time a data stream shared by hard links or APFS clones is seen, so
    /// its blocks count once. Without this, Preboot's cloned cryptexes triple its size.
    /// Most files pass through here, so the set is split into shards with their own locks.
    private enum Claim { case claimed, takenByOriginal, takenByCopy }

    /// Claims a data stream. An original is a file whose clone ID is its own file ID; once
    /// an original holds a key, the key is marked so, even if a copy claimed it first.
    private func claimDataStream(_ key: DataStreamKey, fileID: UInt64, node: FileNode) -> Claim {
        let isOriginal = key.cloneID == fileID
        return dataStreamShards[Self.shard(for: key.cloneID)].withLock { claims in
            guard var claim = claims[key] else {
                claims[key] = DataStreamClaim(holder: node, heldByOriginal: isOriginal)
                return .claimed
            }
            if claim.holder == nil {
                // Released by a refresh: the earlier holder was in a folder being relisted.
                claim.holder = node
                claim.heldByOriginal = isOriginal
                claims[key] = claim
                return .claimed
            }
            let heldByOriginal = claim.heldByOriginal
            if isOriginal { claim.heldByOriginal = true }
            claims[key] = claim
            return heldByOriginal ? .takenByOriginal : .takenByCopy
        }
    }
}

/// Sequential reader over one getattrlistbulk entry.
private struct AttributeReader {
    private var cursor: UnsafeMutableRawPointer

    init(_ start: UnsafeMutableRawPointer) { cursor = start }

    mutating func read<T>(_: T.Type) -> T {
        let value = cursor.loadUnaligned(as: T.self)
        cursor += MemoryLayout<T>.size
        return value
    }

    mutating func readString() -> String {
        let reference = cursor.loadUnaligned(as: attrreference_t.self)
        let string = String(cString: (cursor + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
        cursor += MemoryLayout<attrreference_t>.size
        return string
    }
}

/// `sys/attr.h` constants, typed as `attrgroup_t` (some exceed Int32 as C macros).
private enum Attr {
    static let cmnName: UInt32 = 0x0000_0001
    static let cmnObjType: UInt32 = 0x0000_0008
    static let cmnDevID: UInt32 = 0x0000_0002
    static let cmnError: UInt32 = 0x2000_0000
    static let cmnReturnedAttrs: UInt32 = 0x8000_0000
    /// ATTR_CMN_FILEID packs after OBJTYPE (bit 3) and before the dir/file groups.
    static let cmnFileID: UInt32 = 0x0200_0000
    static let common = cmnReturnedAttrs | cmnName | cmnError | cmnDevID | cmnObjType | cmnFileID
    static let dirMountStatus: UInt32 = 0x0000_0004
    static let fileLinkCount: UInt32 = 0x0000_0001
    static let fileAllocSize: UInt32 = 0x0000_0004
    static let extCloneID: UInt32 = 0x0000_0100
    static let extFlags: UInt32 = 0x0000_0200
    /// EF_MAY_SHARE_BLOCKS from sys/attr.h.
    static let mayShareBlocks: UInt64 = 0x0000_0001
    static let mountPoint: UInt32 = 0x0000_0001
    static let mountTrigger: UInt32 = 0x0000_0002
    /// `VDIR` from `enum vtype` in sys/vnode.h.
    static let typeDirectory: UInt32 = 2
}
