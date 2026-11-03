import Foundation

/// One file or folder in a scan tree.
///
/// Kept deliberately small (no URL, no UUID) because a full startup-disk scan holds
/// millions of these. Paths are rebuilt from the parent chain on demand.
public final class FileNode: Identifiable {
    public let name: String
    public let isDirectory: Bool
    public internal(set) var size: Int64
    public internal(set) var children: [FileNode] = []
    public internal(set) unowned(unsafe) var parent: FileNode?
    /// Midpoint of this node along the scan root's byte range, in 0...1. Drives its hue,
    /// so colors stay put while the user zooms around.
    public internal(set) var hue: Float = 0

    public var id: ObjectIdentifier { ObjectIdentifier(self) }

    init(name: String, isDirectory: Bool, size: Int64 = 0, parent: FileNode?) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.parent = parent
    }

    public var depth: Int {
        var depth = 0
        var node = parent
        while let current = node {
            depth += 1
            node = current.parent
        }
        return depth
    }

    /// Ancestors from the scan root down to and including `self`.
    public var chain: [FileNode] {
        var result: [FileNode] = [self]
        var node = parent
        while let current = node {
            result.append(current)
            node = current.parent
        }
        return result.reversed()
    }

    public func isDescendant(of ancestor: FileNode) -> Bool {
        var node = parent
        while let current = node {
            if current === ancestor { return true }
            node = current.parent
        }
        return false
    }

    /// The node's location, given the URL the scan started from.
    public func url(under rootURL: URL) -> URL {
        let components = chain.dropFirst().map(\.name)
        return components.reduce(rootURL) { $0.appendingPathComponent($1) }
    }

    /// Detaches the node and subtracts its size from every ancestor.
    public func removeFromParent() {
        guard let parent else { return }
        parent.children.removeAll { $0 === self }
        var node: FileNode? = parent
        while let current = node {
            current.size -= size
            node = current.parent
        }
        self.parent = nil
    }

    // MARK: Post-scan passes

    /// Sums sizes bottom-up, drops empty entries, and sorts children largest first.
    @discardableResult
    func aggregate() -> Int64 {
        guard isDirectory else { return size }
        var total: Int64 = 0
        for child in children { total += child.aggregate() }
        children.removeAll { $0.size == 0 }
        children.sort { $0.size > $1.size }
        size = total
        return total
    }

    func assignHues(offset: Double, total: Double) {
        guard total > 0 else { return }
        hue = Float((offset + Double(size) / 2) / total)
        var childOffset = offset
        for child in children {
            child.assignHues(offset: childOffset, total: total)
            childOffset += Double(child.size)
        }
    }
}
