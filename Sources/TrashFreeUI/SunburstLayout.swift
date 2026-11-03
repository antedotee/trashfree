import TrashFreeCore
import Foundation

/// What one arc of the chart stands for.
enum SegmentKind {
    case node(FileNode)
    /// Children of `parent` too thin to draw on their own, merged into one gray arc.
    case smaller(parent: FileNode, bytes: Int64)
    /// Used space the scan could not account for (unreadable or purgeable data).
    case hidden(bytes: Int64)

    var bytes: Int64 {
        switch self {
        case .node(let node): return node.size
        case .smaller(_, let bytes), .hidden(let bytes): return bytes
        }
    }

    var node: FileNode? {
        if case .node(let node) = self { return node }
        return nil
    }
}

/// One arc, in chart-relative units: `start`/`end` are fractions of the full circle and
/// `depth` is the ring index (1 = innermost ring around the center).
struct Arc {
    let kind: SegmentKind
    let depth: Int
    let start: Double
    let end: Double
}

/// Every arc for one focused folder, plus what the chart needs to read it back.
struct SunburstLayout {
    static let maxDepth = 12
    /// Arcs narrower than this merge into "smaller objects". DaisyDisk's maps settle
    /// around 0.6 degrees; thinner slivers read as noise.
    static let minimumFraction = 0.6 / 360

    let focus: FileNode
    let arcs: [Arc]
    /// Arcs grouped by ring and sorted by `start`, for hit testing.
    private let rings: [[Arc]]

    /// - Parameters:
    ///   - total: Bytes the full circle stands for. A volume's root view uses the disk's
    ///     capacity so free space shows as an empty wedge before the first folder.
    ///   - leadingGap: Bytes of empty wedge before the first child (free space).
    ///   - hiddenBytes: Used bytes the scan did not find, drawn last.
    ///   - size: A node's size as the map should show it. Collected items count as zero,
    ///     so they leave the map while they wait in the collector.
    init(focus: FileNode, total: Int64, leadingGap: Int64 = 0, hiddenBytes: Int64 = 0,
         size: (FileNode) -> Int64 = { $0.size }) {
        self.focus = focus
        let total = Double(max(total, 1))
        var arcs: [Arc] = []

        func place(_ parent: FileNode, from start: Double, depth: Int) {
            var cursor = start
            var placedBytes: Int64 = 0
            let parentSize = size(parent)
            // Children are stored largest first; collecting can change that order.
            let children = parentSize == parent.size
                ? parent.children
                : parent.children.filter { size($0) > 0 }.sorted { size($0) > size($1) }
            for child in children {
                let bytes = size(child)
                let fraction = Double(bytes) / total
                // Everything after the first sliver is smaller still.
                guard fraction >= Self.minimumFraction else { break }
                arcs.append(Arc(kind: .node(child), depth: depth, start: cursor, end: cursor + fraction))
                if child.isDirectory && depth < Self.maxDepth {
                    place(child, from: cursor, depth: depth + 1)
                }
                cursor += fraction
                placedBytes += bytes
            }
            let rest = parentSize - placedBytes
            if rest > 0 && Double(rest) / total >= Self.minimumFraction / 4 {
                arcs.append(Arc(kind: .smaller(parent: parent, bytes: rest), depth: depth, start: cursor, end: cursor + Double(rest) / total))
            }
        }

        let gap = Double(leadingGap) / total
        place(focus, from: gap, depth: 1)
        if hiddenBytes > 0 {
            let start = gap + Double(size(focus)) / total
            let end = min(start + Double(hiddenBytes) / total, 1)
            arcs.append(Arc(kind: .hidden(bytes: hiddenBytes), depth: 1, start: start, end: end))
            arcs.append(Arc(kind: .hidden(bytes: hiddenBytes), depth: 2, start: start, end: end))
        }

        var rings = Array(repeating: [Arc](), count: Self.maxDepth + 1)
        for arc in arcs { rings[arc.depth].append(arc) }
        for index in rings.indices { rings[index].sort { $0.start < $1.start } }
        self.arcs = arcs
        self.rings = rings
    }

    func arc(atDepth depth: Int, fraction: Double) -> Arc? {
        guard depth >= 1 && depth < rings.count else { return nil }
        let ring = rings[depth]
        var low = 0
        var high = ring.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let arc = ring[mid]
            if fraction < arc.start { high = mid - 1 }
            else if fraction >= arc.end { low = mid + 1 }
            else { return arc }
        }
        return nil
    }

    func arc(for node: FileNode) -> Arc? {
        arcs.first { $0.kind.node === node }
    }
}

extension Arc {
    /// Identity that survives a relayout, so the same arc can be matched across two
    /// layouts of one folder. Hidden space appears on two rings, so depth is part of it.
    var key: ArcKey {
        switch kind {
        case .node(let node): return ArcKey(object: ObjectIdentifier(node), role: 0, depth: depth)
        case .smaller(let parent, _): return ArcKey(object: ObjectIdentifier(parent), role: 1, depth: depth)
        case .hidden: return ArcKey(object: nil, role: 2, depth: depth)
        }
    }
}

struct ArcKey: Hashable {
    let object: ObjectIdentifier?
    let role: Int
    let depth: Int
}

/// A relayout of the same folder, after items were collected or put back. Matched arcs
/// slide to their new angles, arcs that left the map close up where they stood, and arcs
/// that came back open from there.
struct LayoutMorph {
    static let duration: TimeInterval = 0.4

    let to: SunburstLayout
    let started = Date()
    /// Every arc to draw, with its angles at the start and the end of the morph.
    let tracks: [(arc: Arc, from: (Double, Double), to: (Double, Double))]

    init(from: SunburstLayout, to: SunburstLayout) {
        self.to = to
        let old = Dictionary(from.arcs.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let new = Dictionary(to.arcs.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var tracks: [(Arc, (Double, Double), (Double, Double))] = []
        for arc in to.arcs {
            if let previous = old[arc.key] {
                tracks.append((arc, (previous.start, previous.end), (arc.start, arc.end)))
            } else {
                // Opens from the point where its parent's arc puts it.
                tracks.append((arc, (arc.start, arc.start), (arc.start, arc.end)))
            }
        }
        for arc in from.arcs where new[arc.key] == nil {
            let middle = (arc.start + arc.end) / 2
            tracks.append((arc, (arc.start, arc.end), (middle, middle)))
        }
        self.tracks = tracks
    }

    func position(at date: Date) -> Double {
        let linear = min(max(date.timeIntervalSince(started) / Self.duration, 0), 1)
        return linear < 0.5 ? 4 * linear * linear * linear : 1 - pow(-2 * linear + 2, 3) / 2
    }

    func isFinished(at date: Date) -> Bool {
        date.timeIntervalSince(started) >= Self.duration
    }
}

/// Ring geometry in points, before scaling to the view. The first rings are thick; deep
/// levels become thin bands, as in DaisyDisk.
enum RingGeometry {
    static let holeRadius: Double = 35
    static let thickRings = 5
    static let thickWidth: Double = 26
    static let thinWidth: Double = 6
    static var outerRadius: Double { radius(atDepth: Double(SunburstLayout.maxDepth)) }

    /// Boundary radius after `depth` rings. Continuous so rings can slide during zooms;
    /// negative depths shrink into the center.
    static func radius(atDepth depth: Double) -> Double {
        if depth <= 0 { return max(holeRadius * (1 + depth), 0) }
        let thick = min(depth, Double(thickRings))
        let thin = max(depth - Double(thickRings), 0)
        return holeRadius + thick * thickWidth + thin * thinWidth
    }

    static func depth(atRadius radius: Double) -> Int? {
        guard radius >= holeRadius else { return nil }
        var depth = 1
        while depth <= SunburstLayout.maxDepth {
            if radius < self.radius(atDepth: Double(depth)) { return depth }
            depth += 1
        }
        return nil
    }
}

/// What the chart shows when idle: one folder's layout, turned by `rotation` (a fraction
/// of a turn added to every arc).
struct ChartView {
    let layout: SunburstLayout
    let rotation: Double
}

/// A zoom between an outer folder and one of its descendants, in either direction.
///
/// Everything is drawn in the outer layout's coordinates. A window over those fractions
/// narrows from the full circle to the inner folder's span while rings slide inward by
/// the inner folder's depth. The inner folder's own layout supplies its descendants, so
/// the last frame matches the destination exactly. The inner folder's direction on
/// screen stays fixed, as DaisyDisk does.
struct ZoomTransition {
    static let duration: TimeInterval = 0.4

    let outer: ChartView
    let inner: ChartView
    let zoomingIn: Bool
    let started = Date()
    /// Outer arcs outside the inner folder, which fade out as the window narrows.
    let context: [Arc]
    /// The inner folder's arc, which shrinks into the center hole.
    let focusArc: Arc
    /// Inner layout arcs mapped into outer coordinates.
    let descendants: [Arc]

    var destination: ChartView { zoomingIn ? inner : outer }

    init?(outer: ChartView, inner: ChartView, zoomingIn: Bool) {
        let focus = inner.layout.focus
        guard let focusArc = outer.layout.arc(for: focus) else { return nil }
        self.outer = outer
        self.inner = inner
        self.zoomingIn = zoomingIn
        self.focusArc = focusArc
        context = outer.layout.arcs.filter { arc in
            switch arc.kind {
            case .node(let node): return node !== focus && !node.isDescendant(of: focus)
            case .smaller(let parent, _): return parent !== focus && !parent.isDescendant(of: focus)
            case .hidden: return true
            }
        }
        let span = focusArc.end - focusArc.start
        descendants = inner.layout.arcs.map { arc in
            Arc(kind: arc.kind, depth: arc.depth + focusArc.depth,
                start: focusArc.start + arc.start * span, end: focusArc.start + arc.end * span)
        }
    }

    /// Eased zoom position at `date`: 0 shows the outer folder, 1 the inner one.
    func position(at date: Date) -> Double {
        let linear = min(max(date.timeIntervalSince(started) / Self.duration, 0), 1)
        let eased = linear < 0.5 ? 4 * linear * linear * linear : 1 - pow(-2 * linear + 2, 3) / 2
        return zoomingIn ? eased : 1 - eased
    }

    func isFinished(at date: Date) -> Bool {
        date.timeIntervalSince(started) >= Self.duration
    }

    struct Frame {
        let windowStart: Double
        let windowWidth: Double
        let rotation: Double
        let depthShift: Double
        let t: Double

        /// Screen fractions (rotation applied) and fractional ring depth for an arc.
        func project(_ arc: Arc) -> (start: Double, end: Double, depth: Double) {
            (rotation + (arc.start - windowStart) / windowWidth,
             rotation + (arc.end - windowStart) / windowWidth,
             Double(arc.depth) - depthShift)
        }
    }

    func frame(at t: Double) -> Frame {
        let windowStart = focusArc.start * t
        let windowWidth = 1 + (focusArc.end - 1) * t - windowStart
        let mid = (focusArc.start + focusArc.end) / 2
        let screenMidOuter = outer.rotation + mid
        let screenMidInner = inner.rotation + 0.5
        let screenMid = screenMidOuter + (Self.shortestTurn(from: screenMidOuter, to: screenMidInner)) * t
        let rotation = screenMid - (mid - windowStart) / windowWidth
        return Frame(windowStart: windowStart, windowWidth: windowWidth, rotation: rotation,
                     depthShift: Double(focusArc.depth) * t, t: t)
    }

    /// Rotation that keeps `focus` pointing where it pointed in `outer`.
    static func innerRotation(outer: ChartView, focusArc: Arc) -> Double {
        outer.rotation + (focusArc.start + focusArc.end) / 2 - 0.5
    }

    private static func shortestTurn(from a: Double, to b: Double) -> Double {
        var delta = (b - a).truncatingRemainder(dividingBy: 1)
        if delta > 0.5 { delta -= 1 }
        if delta < -0.5 { delta += 1 }
        return delta
    }
}
