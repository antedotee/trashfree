import AppKit
import TrashFreeCore
import SwiftUI

extension SegmentKind: Equatable {
    static func == (lhs: SegmentKind, rhs: SegmentKind) -> Bool {
        switch (lhs, rhs) {
        case (.node(let a), .node(let b)): return a === b
        case (.smaller(let a, _), .smaller(let b, _)): return a === b
        case (.hidden, .hidden): return true
        default: return false
        }
    }
}

/// What the pointer is over: an arc, or the center disc (which zooms out, and shows
/// the focused folder in the panel).
enum Highlight: Equatable {
    case segment(SegmentKind)
    case center
}

/// Hover emphasis per arc, eased in and out so moving across the map reads as one
/// continuous motion instead of segments flicking on and off. Every retarget starts
/// from the value currently on screen, so fast pointer movement never jumps.
struct HoverFade {
    private struct Entry {
        let kind: SegmentKind
        let from: Double
        let rising: Bool
        let start: Date
    }

    private var entries: [Entry] = []

    mutating func retarget(to target: SegmentKind?, at date: Date) {
        var next: [Entry] = []
        for entry in entries {
            let value = Self.value(of: entry, at: date)
            if let target, entry.kind == target {
                next.append(entry.rising ? entry : Entry(kind: target, from: value, rising: true, start: date))
            } else if value > 0.001 {
                next.append(entry.rising ? Entry(kind: entry.kind, from: value, rising: false, start: date) : entry)
            }
        }
        if let target, !next.contains(where: { $0.kind == target }) {
            next.append(Entry(kind: target, from: 0, rising: true, start: date))
        }
        entries = next
    }

    func emphasis(of kind: SegmentKind, at date: Date) -> Double {
        guard let entry = entries.first(where: { $0.kind == kind }) else { return 0 }
        return Self.value(of: entry, at: date)
    }

    func isSettled(at date: Date) -> Bool {
        entries.allSatisfy { date.timeIntervalSince($0.start) >= Self.duration(of: $0) }
    }

    private static func duration(of entry: Entry) -> TimeInterval {
        entry.rising ? Theme.Motion.hoverIn * (1 - entry.from) : Theme.Motion.hoverOut * entry.from
    }

    private static func value(of entry: Entry, at date: Date) -> Double {
        let duration = duration(of: entry)
        let linear = duration <= 0 ? 1 : min(max(date.timeIntervalSince(entry.start) / duration, 0), 1)
        let eased = 1 - pow(1 - linear, 3)
        return entry.rising ? entry.from + (1 - entry.from) * eased : entry.from * (1 - eased)
    }
}

/// The sunburst. Draws the focused folder's layout with Canvas, hit-tests the pointer
/// against ring and angle, and animates zooms between a folder and its descendants.
struct SunburstChart: View {
    @ObservedObject var session: MapSession
    @Binding var highlight: Highlight?
    /// The arc the info panel previews while the pointer rests on it. Nil means the
    /// panel lists the focused folder. Once the pointer is off every arc, the panel goes
    /// back to the focused folder, as DaisyDisk's does. Hovering a row emphasizes its arc
    /// without replacing the list under the pointer.
    @Binding var subject: SegmentKind?

    @Environment(\.colorScheme) private var scheme
    @State private var chart: ChartView?
    @State private var transition: ZoomTransition?
    @State private var morph: LayoutMorph?
    @State private var fade = HoverFade()
    @State private var isFading = false
    @State private var fadeToken = 0
    /// Pointer bookkeeping that must not invalidate the view on every mouse move.
    @State private var pointer = PointerState()

    private final class PointerState {
        var token = 0
        var clearPending = false
    }

    /// How long the pointer may sit over empty space before the arc emphasis fades.
    /// Crossing the gap between a short file and the next folder would otherwise
    /// blink the emphasis off and on.
    private static let linger: TimeInterval = 0.14

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let scale = Self.scale(for: size)
            ZStack {
                TimelineView(.animation(minimumInterval: nil, paused: transition == nil && morph == nil && !isFading)) { timeline in
                    Canvas { context, canvasSize in
                        draw(in: &context, size: canvasSize, scale: scale, date: timeline.date)
                    }
                }
                centerLabel(scale: scale)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard transition == nil else { return }
                switch phase {
                case .active(let point): hover(hitTest(point, size: size, scale: scale))
                case .ended: hover(nil)
                }
            }
            .onTapGesture(coordinateSpace: .local) { point in
                guard transition == nil else { return }
                switch hitTest(point, size: size, scale: scale) {
                case .center: session.zoomOut()
                case .segment(.node(let node)): session.zoom(into: node)
                default: break
                }
            }
            .onDrag {
                guard case .segment(.node(let node)) = highlight else { return NSItemProvider() }
                return session.dragItem(for: node)
            } preview: {
                dragPreview
            }
        }
        .onAppear { chart = ChartView(layout: session.layout(for: session.focus), rotation: 0) }
        .onChange(of: ObjectIdentifier(session.focus)) { _ in focusChanged() }
        .onChange(of: session.revision) { _ in contentsChanged() }
        .onChange(of: session.focusRequests) { _ in
            highlight = nil
            subject = nil
        }
        .onChange(of: highlight) { newValue in highlightChanged(newValue) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Disk map of \(session.displayName(of: session.focus))")
        .accessibilityValue(Text(ByteSizeFormatter.string(fromByteCount: session.focus.size)))
    }

    // MARK: Hover

    private func hover(_ target: Highlight?) {
        if let target {
            if pointer.clearPending {
                pointer.token += 1
                pointer.clearPending = false
            }
            let newSubject: SegmentKind? = if case .segment(let kind) = target { kind } else { nil }
            if subject != newSubject { subject = newSubject }
            guard highlight != target else { return }
            highlight = target
            return
        }
        guard highlight != nil || subject != nil, !pointer.clearPending else { return }
        pointer.token += 1
        pointer.clearPending = true
        let token = pointer.token
        let leaving = highlight
        let pointer = pointer
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.linger) {
            guard pointer.token == token else { return }
            pointer.clearPending = false
            subject = nil
            // The info panel may have taken over the highlight in the meantime.
            if highlight == leaving { highlight = nil }
        }
    }

    private func highlightChanged(_ newValue: Highlight?) {
        let now = Date()
        if case .segment(let kind) = newValue {
            fade.retarget(to: kind, at: now)
        } else {
            fade.retarget(to: nil, at: now)
        }
        isFading = true
        fadeToken += 1
        let token = fadeToken
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.hoverOut + 0.03) {
            if fadeToken == token && fade.isSettled(at: Date()) { isFading = false }
        }
    }

    // MARK: Geometry

    static func scale(for size: CGSize) -> Double {
        let available = min(size.width, size.height) / 2 - 8
        return max(available / RingGeometry.outerRadius, 0.2)
    }

    private func hitTest(_ point: CGPoint, size: CGSize, scale: Double) -> Highlight? {
        guard let chart else { return nil }
        let dx = point.x - size.width / 2
        let dy = point.y - size.height / 2
        let radius = (dx * dx + dy * dy).squareRoot() / scale
        if radius < RingGeometry.holeRadius { return .center }
        guard let depth = RingGeometry.depth(atRadius: radius) else { return nil }
        var fraction = atan2(dy, dx) / (2 * .pi) - chart.rotation
        fraction -= fraction.rounded(.down)
        return chart.layout.arc(atDepth: depth, fraction: fraction).map { .segment($0.kind) }
    }

    // MARK: Focus changes

    private func focusChanged() {
        let focus = session.focus
        let layout = session.layout(for: focus)
        highlight = nil
        subject = nil
        guard let current = chart else {
            chart = ChartView(layout: layout, rotation: 0)
            return
        }
        let previous = current.layout.focus

        if focus.isDescendant(of: previous), let arc = current.layout.arc(for: focus) {
            let inner = ChartView(layout: layout, rotation: ZoomTransition.innerRotation(outer: current, focusArc: arc))
            begin(ZoomTransition(outer: current, inner: inner, zoomingIn: true), landing: inner)
        } else if previous.isDescendant(of: focus), let arc = layout.arc(for: previous) {
            let rotation = focus.parent == nil ? 0 : current.rotation - ((arc.start + arc.end) / 2 - 0.5)
            let outer = ChartView(layout: layout, rotation: rotation)
            begin(ZoomTransition(outer: outer, inner: current, zoomingIn: false), landing: outer)
        } else {
            chart = ChartView(layout: layout, rotation: 0)
        }
    }

    /// Items were collected, put back, or deleted: the same folder is laid out again and
    /// the arcs slide to their new angles. Zooms are handled by `focusChanged`.
    private func contentsChanged() {
        // What the pointer was on may just have left the map.
        if case .segment(.node(let node)) = highlight, session.size(of: node) <= 0 { highlight = nil }
        if case .node(let node) = subject, session.size(of: node) <= 0 { subject = nil }
        guard let current = chart, current.layout.focus === session.focus else { return }
        let layout = session.layout(for: session.focus)
        chart = ChartView(layout: layout, rotation: current.rotation)
        guard transition == nil else { return }
        let next = LayoutMorph(from: current.layout, to: layout)
        morph = next
        DispatchQueue.main.asyncAfter(deadline: .now() + LayoutMorph.duration) {
            if morph?.started == next.started { morph = nil }
        }
    }

    private func begin(_ zoom: ZoomTransition?, landing: ChartView) {
        chart = landing
        morph = nil
        // The zoom plays even with Reduce Motion on: it is the only thing that shows
        // where the user went, and the user asked for it.
        guard let zoom else {
            transition = nil
            return
        }
        transition = zoom
        DispatchQueue.main.asyncAfter(deadline: .now() + ZoomTransition.duration) {
            if transition?.started == zoom.started { transition = nil }
        }
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize, scale: Double, date: Date) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        if let transition, !transition.isFinished(at: date) {
            let t = transition.position(at: date)
            let frame = transition.frame(at: t)
            for arc in transition.context {
                let projected = frame.project(arc)
                fill(arc, projected, opacity: 1 - t, in: &context, center: center, scale: scale, date: date)
            }
            let focus = frame.project(transition.focusArc)
            fill(transition.focusArc, focus, opacity: min(1, (1 - t) * 3), in: &context, center: center, scale: scale, date: date)
            for arc in transition.descendants {
                let projected = frame.project(arc)
                let overflow = projected.depth - Double(SunburstLayout.maxDepth)
                guard overflow < 1 else { continue }
                fill(arc, projected, opacity: overflow > 0 ? 1 - overflow : 1, in: &context, center: center, scale: scale, date: date)
            }
            return
        }
        guard let chart else { return }
        if let morph, !morph.isFinished(at: date) {
            let t = morph.position(at: date)
            for track in morph.tracks {
                let start = track.from.0 + (track.to.0 - track.from.0) * t
                let end = track.from.1 + (track.to.1 - track.from.1) * t
                fill(track.arc, (chart.rotation + start, chart.rotation + end, Double(track.arc.depth)),
                     opacity: 1, in: &context, center: center, scale: scale, date: date)
            }
            return
        }
        for arc in chart.layout.arcs {
            let projected = (chart.rotation + arc.start, chart.rotation + arc.end, Double(arc.depth))
            fill(arc, projected, opacity: 1, in: &context, center: center, scale: scale, date: date)
        }
    }

    private func fill(
        _ arc: Arc,
        _ projected: (start: Double, end: Double, depth: Double),
        opacity: Double,
        in context: inout GraphicsContext,
        center: CGPoint,
        scale: Double,
        date: Date
    ) {
        guard opacity > 0.01, projected.end > projected.start else { return }
        let inner = RingGeometry.radius(atDepth: projected.depth - 1) * scale
        let outer = RingGeometry.radius(atDepth: projected.depth) * scale - 0.5
        guard outer > inner + 0.3 else { return }
        let path = Self.wedge(center: center, inner: inner, outer: outer,
                              start: projected.start * 2 * .pi, end: projected.end * 2 * .pi)
        let emphasis = fade.emphasis(of: arc.kind, at: date)
        var layer = context
        layer.opacity = opacity
        // Full rings are two concentric circles; even-odd fill leaves the hole open.
        layer.fill(path, with: .color(color(for: arc, depth: projected.depth, emphasis: emphasis)), style: FillStyle(eoFill: true))
        if case .hidden = arc.kind {
            hatch(path, in: layer)
        }
        layer.stroke(path, with: .color(Theme.background), lineWidth: 1)
    }

    private func hatch(_ path: Path, in context: GraphicsContext) {
        var clipped = context
        clipped.clip(to: path, style: FillStyle(eoFill: true))
        let bounds = path.boundingRect
        var lines = Path()
        var x = bounds.minX - bounds.height
        while x < bounds.maxX {
            lines.move(to: CGPoint(x: x, y: bounds.maxY))
            lines.addLine(to: CGPoint(x: x + bounds.height, y: bounds.minY))
            x += 5
        }
        clipped.stroke(lines, with: .color(Theme.hiddenHatch(scheme: scheme)), lineWidth: 0.75)
    }

    private func color(for arc: Arc, depth: Double, emphasis: Double) -> Color {
        switch arc.kind {
        case .node(let node):
            return Theme.segment(position: node.hue, depth: Int(depth.rounded()), emphasis: emphasis, scheme: scheme)
        case .smaller:
            return Theme.smallerObjects(emphasis: emphasis, scheme: scheme)
        case .hidden:
            return Theme.hiddenFill(emphasis: emphasis, scheme: scheme)
        }
    }

    static func wedge(center: CGPoint, inner: Double, outer: Double, start: Double, end: Double) -> Path {
        var path = Path()
        if end - start >= 2 * .pi - 1e-6 {
            path.addEllipse(in: CGRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2))
            if inner > 0 {
                path.addEllipse(in: CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2))
            }
            return path
        }
        path.addArc(center: center, radius: outer, startAngle: .radians(start), endAngle: .radians(end), clockwise: false)
        if inner > 0 {
            path.addArc(center: center, radius: inner, startAngle: .radians(end), endAngle: .radians(start), clockwise: true)
        } else {
            path.addLine(to: center)
        }
        path.closeSubpath()
        return path
    }

    // MARK: Overlays

    private func centerLabel(scale: Double) -> some View {
        let focus = session.focus
        let parts = ByteSizeFormatter.string(fromByteCount: session.displayedSize(of: focus)).split(separator: " ")
        let zoomOutHint = highlight == .center && focus.parent != nil
        let diameter = RingGeometry.holeRadius * 2 * scale
        let factor = min(max(scale, 0.8), 1.4)
        return VStack(spacing: 1) {
            Image(systemName: "arrow.up")
                .font(.system(size: 10 * factor, weight: .medium))
                .foregroundColor(Theme.secondaryText)
                .opacity(zoomOutHint ? 1 : 0)
                .offset(y: zoomOutHint ? 0 : 3)
            Text(parts.first.map(String.init) ?? "")
                .font(.system(size: 17 * factor, weight: .medium).monospacedDigit())
                .foregroundColor(Theme.text)
            Text(parts.dropFirst().joined(separator: " "))
                .font(.system(size: 11 * factor))
                .foregroundColor(Theme.secondaryText)
        }
        .opacity(transition == nil ? 1 : 0.6)
        .frame(width: diameter, height: diameter)
        .background(Circle().fill(zoomOutHint ? Theme.hoverFill : Color.clear))
        .animation(Theme.Motion.hover, value: zoomOutHint)
    }

    @ViewBuilder
    private var dragPreview: some View {
        if case .segment(.node(let node)) = highlight {
            DragPreview(node: node)
        }
    }
}

/// What follows the pointer while an item is dragged toward the collector, from the
/// map or from the list.
struct DragPreview: View {
    let node: FileNode

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: node.isDirectory ? "folder" : "doc")
                .font(.system(size: 16))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name).font(.system(size: 12, weight: .medium))
                Text(ByteSizeFormatter.string(fromByteCount: node.size)).font(.system(size: 11).monospacedDigit())
                    .foregroundColor(Theme.secondaryText)
            }
        }
        .foregroundColor(Theme.text)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.background))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.strongBorder, lineWidth: 1))
    }
}
