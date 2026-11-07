import Darwin
import Foundation

/// A finished scan: the tree plus the location it was rooted at.
public struct ScanResult {
    public let root: FileNode
    public let rootURL: URL
    public let duration: TimeInterval
    public let itemCount: Int
}

/// A parallel directory walk built on `getattrlistbulk(2)`.
///
/// Workers pop directories off one shared LIFO stack, list them in a single syscall
/// batch, and push the subdirectories back. Depth-first order keeps the frontier small.
/// Each worker is the only writer of the directory it lists, so the tree itself needs no
/// lock; the lock guards only the stack and the progress counters.
public final class ScanJob: @unchecked Sendable {
    public struct Options {
        /// Bytes the scan is expected to find, e.g. a volume's used space. When set,
        /// progress follows bytes found; otherwise it follows the share of the tree walked.
        public var expectedBytes: Int64?
        /// Mount points the walk may cross. Every other mount point is a different disk.
        public var enteredMountPoints: (String) -> Bool
        /// Directories never listed.
        public var excludedPaths: Set<String>
        /// Threads listing directories at once. nil picks the default.
        public var workerCount: Int?

        public init(
            expectedBytes: Int64? = nil,
            enteredMountPoints: @escaping (String) -> Bool = { _ in false },
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
    private let sharedDataLock = NSLock()
    private var seenDataStreams = Set<DataStreamKey>()

    public init(url: URL, options: Options = Options()) {
        self.rootURL = url
        self.options = options
        self.root = FileNode(name: url.path == "/" ? "/" : url.lastPathComponent, isDirectory: true, parent: nil)
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
        stack = [WorkItem(node: root, path: rootURL.path, weight: 1)]
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

        root.aggregate()
        root.assignHues(offset: 0, total: Double(root.size))
        return ScanResult(root: root, rootURL: rootURL, duration: Date().timeIntervalSince(started), itemCount: items)
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
            if subdirectoryCount > 0 || (stack.isEmpty && busyWorkers == 0) {
                condition.broadcast()
            }
        }
    }

    private struct Listing {
        var subdirectories: [(FileNode, String)] = []
        var bytes: Int64 = 0
        var itemCount = 0
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
        request.forkattr = Attr.extCloneID | Attr.extFlags

        let parentPath = item.path == "/" ? "" : item.path
        var children: [FileNode] = []

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

                if objectType == Attr.typeDirectory {
                    let mountStatus = returned.dirattr & Attr.dirMountStatus != 0 ? reader.read(UInt32.self) : 0
                    let path = parentPath + "/" + name
                    if mountStatus & Attr.mountTrigger != 0 { continue }
                    if mountStatus & Attr.mountPoint != 0 && !options.enteredMountPoints(path) { continue }
                    if options.excludedPaths.contains(path) { continue }
                    let node = FileNode(name: name, isDirectory: true, parent: item.node)
                    children.append(node)
                    listing.subdirectories.append((node, path))
                } else {
                    let linkCount = returned.fileattr & Attr.fileLinkCount != 0 ? reader.read(UInt32.self) : 1
                    var allocated = returned.fileattr & Attr.fileAllocSize != 0 ? reader.read(Int64.self) : 0
                    let cloneID = returned.forkattr & Attr.extCloneID != 0 ? reader.read(UInt64.self) : 0
                    let flags = returned.forkattr & Attr.extFlags != 0 ? reader.read(UInt64.self) : 0
                    let mayShareData = linkCount > 1 || flags & Attr.mayShareBlocks != 0
                    if mayShareData && cloneID != 0 && !claimDataStream(device: device, cloneID: cloneID) {
                        allocated = 0
                    }
                    guard allocated > 0 else { continue }
                    children.append(FileNode(name: name, isDirectory: false, size: allocated, parent: item.node))
                    listing.bytes += allocated
                }
                listing.itemCount += 1
            }
        }
        item.node.children = children
        return listing
    }

    private struct DataStreamKey: Hashable {
        let device: Int32
        let cloneID: UInt64
    }

    /// True the first time a data stream shared by hard links or APFS clones is seen, so
    /// its blocks count once. Without this, Preboot's cloned cryptexes triple its size.
    private func claimDataStream(device: Int32, cloneID: UInt64) -> Bool {
        sharedDataLock.lock()
        defer { sharedDataLock.unlock() }
        return seenDataStreams.insert(DataStreamKey(device: device, cloneID: cloneID)).inserted
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
    static let common = cmnReturnedAttrs | cmnName | cmnError | cmnDevID | cmnObjType
    static let dirMountStatus: UInt32 = 0x0000_0004
    static let fileLinkCount: UInt32 = 0x0000_0001
    static let fileAllocSize: UInt32 = 0x0000_0004
    static let extCloneID: UInt32 = 0x0000_0100
    static let extFlags: UInt32 = 0x0000_0200
    static let mayShareBlocks: UInt64 = 0x0000_0001
    static let mountPoint: UInt32 = 0x0000_0001
    static let mountTrigger: UInt32 = 0x0000_0002
    /// `VDIR` from `enum vtype` in sys/vnode.h.
    static let typeDirectory: UInt32 = 2
}
