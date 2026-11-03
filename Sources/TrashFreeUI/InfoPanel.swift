import AppKit
import TrashFreeCore
import SwiftUI

/// The column on the right: the item under the pointer in the map (or the focused
/// folder) and its largest children.
struct InfoPanel: View {
    @ObservedObject var session: MapSession
    @Binding var highlight: Highlight?
    let subject: SegmentKind?

    @Environment(\.colorScheme) private var scheme
    @State private var clickOrigin = ClickOrigin()

    /// The item under the first click of a click sequence. The first click of a double
    /// click zooms into a folder and replaces the list, so the second click lands on
    /// another row, or on none, and has to act on this item instead.
    private final class ClickOrigin {
        var node: FileNode?
    }

    /// Children below this share of their parent fold into "Smaller objects".
    private static let listedFraction = 0.004
    private static let rowHeight: CGFloat = 26
    /// Name, size, and the gap under them.
    private static let headerHeight: CGFloat = 70
    /// Hidden space, the rule, and the two free-space rows under a volume's root.
    private static let volumeFooterHeight: CGFloat = 3 * rowHeight + 21

    private enum Dot {
        case color(Color)
        case hatched
        case empty
    }

    /// The list shows as many rows as fit and folds the rest into "Smaller objects", so
    /// a long folder never grows the panel. A taller panel used to push the window's
    /// layout around and resize the chart while the user hovered.
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                content(height: geometry.size.height)
                    .id(subjectKey)
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { click(nil) }
        }
        .animation(.easeOut(duration: Theme.Motion.hoverIn), value: subjectKey)
    }

    private var shown: SegmentKind { subject ?? .node(session.focus) }

    /// Identity of what the panel describes, so a change fades the new content in.
    private var subjectKey: String {
        switch shown {
        case .node(let node): return "n\(UInt(bitPattern: ObjectIdentifier(node).hashValue))-\(session.revision)"
        case .smaller(let parent, _): return "s\(UInt(bitPattern: ObjectIdentifier(parent).hashValue))"
        case .hidden: return "h"
        }
    }

    @ViewBuilder
    private func content(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch shown {
            case .node(let node):
                folder(node, height: height)
            case .smaller(let parent, let bytes):
                header(title: "Smaller objects", bytes: bytes, dot: .color(Theme.smallerObjects(scheme: scheme)))
                note("Items in \(session.displayName(of: parent)) too small to show on their own.")
            case .hidden(let bytes):
                header(title: "Hidden space", bytes: bytes, dot: .hatched)
                note("Used space the scan could not read: other users' and system files, local snapshots, and purgeable data.")
            }
        }
    }

    @ViewBuilder
    private func folder(_ node: FileNode, height: CGFloat) -> some View {
        let isFocus = node === session.focus
        let footer = node === session.root && session.volume != nil ? Self.volumeFooterHeight : 0
        // One row is kept for "Smaller objects".
        let maxRows = max(Int((height - Self.headerHeight - footer) / Self.rowHeight) - 1, 1)
        header(
            title: session.displayName(of: node),
            bytes: session.displayedSize(of: node),
            dot: isFocus && node.parent == nil ? nil : .color(Theme.segment(position: node.hue, depth: 1, scheme: scheme))
        )

        let rows = rows(for: node, maxRows: maxRows)
        ForEach(rows.listed, id: \.id) { child in
            row(name: child.name, bytes: session.size(of: child),
                dot: .color(Theme.segment(position: child.hue, depth: 1, scheme: scheme)), kind: .node(child))
        }
        if rows.smallerBytes > 0 {
            row(name: "Smaller objects", bytes: rows.smallerBytes, dot: .color(Theme.smallerObjects(scheme: scheme)),
                kind: .smaller(parent: node, bytes: rows.smallerBytes), minor: true)
        }
        if node === session.root, let volume = session.volume {
            if session.hiddenBytes > 0 {
                row(name: "Hidden space", bytes: session.hiddenBytes, dot: .hatched, kind: .hidden(bytes: session.hiddenBytes))
            }
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 10).padding(.horizontal, 8)
            row(name: "Free space", bytes: volume.freeBytes, dot: .empty, kind: nil)
            row(name: "Free incl. purgeable", bytes: volume.freeIncludingPurgeableBytes, dot: nil, kind: nil, minor: true)
        }
    }

    private func rows(for node: FileNode, maxRows: Int) -> (listed: [FileNode], smallerBytes: Int64) {
        guard node.isDirectory else { return ([], 0) }
        let total = session.size(of: node)
        let threshold = Double(total) * Self.listedFraction
        let children = node.children
            .filter { session.size(of: $0) > 0 }
            .sorted { session.size(of: $0) > session.size(of: $1) }
        let listed = Array(children.prefix { Double(session.size(of: $0)) >= threshold }.prefix(maxRows))
        let listedBytes = listed.reduce(Int64(0)) { $0 + session.size(of: $1) }
        return (listed, total - listedBytes)
    }

    private func header(title: String, bytes: Int64, dot: Dot?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if let dot { dotView(dot, size: 10) }
                Text(title)
                    .font(Theme.Font.panelTitle)
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(ByteSizeFormatter.string(fromByteCount: bytes))
                .font(Theme.Font.panelSize)
                .foregroundColor(Theme.text)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 14)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.panelNote)
            .foregroundColor(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func dotView(_ dot: Dot, size: CGFloat) -> some View {
        switch dot {
        case .color(let color):
            Circle().fill(color).frame(width: size, height: size)
        case .hatched:
            // The same hatching as the hidden-space arc, so the legend matches the map.
            Canvas { context, canvas in
                let circle = Path(ellipseIn: CGRect(origin: .zero, size: canvas))
                context.fill(circle, with: .color(Theme.hiddenFill(scheme: scheme)))
                context.clip(to: circle)
                var lines = Path()
                for x in stride(from: -canvas.height, through: canvas.width, by: 2.5) {
                    lines.move(to: CGPoint(x: x, y: canvas.height))
                    lines.addLine(to: CGPoint(x: x + canvas.height, y: 0))
                }
                context.stroke(lines, with: .color(Theme.hiddenHatch(scheme: scheme)), lineWidth: 0.75)
            }
            .frame(width: size, height: size)
        case .empty:
            Circle().strokeBorder(Theme.strongBorder, lineWidth: 1).frame(width: size, height: size)
        }
    }

    /// One line of the list. Hovering it emphasizes the matching arc; clicking a folder
    /// zooms into it. `minor` rows are set in secondary ink.
    private func row(name: String, bytes: Int64, dot: Dot?, kind: SegmentKind?, minor: Bool = false) -> some View {
        let isHighlighted = kind.map { highlight == .segment($0) } ?? false
        return HStack(spacing: 10) {
            ZStack {
                if let dot { dotView(dot, size: 8) }
            }
            .frame(width: 10)
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(minor ? Theme.secondaryText : Theme.text)
            Spacer(minLength: 12)
            Text(ByteSizeFormatter.string(fromByteCount: bytes))
                .foregroundColor(Theme.secondaryText)
        }
        .font(Theme.Font.panelRow)
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHighlighted ? Theme.hoverFill : .clear))
        .animation(Theme.Motion.hover, value: isHighlighted)
        .contentShape(Rectangle())
        .onHover { inside in
            guard let kind else { return }
            if inside { highlight = .segment(kind) }
            else if highlight == .segment(kind) { highlight = nil }
        }
        .onTapGesture { click(kind) }
        .modifier(DragToCollect(session: session, kind: kind))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isZoomable(kind) ? .isButton : [])
        .accessibilityAction {
            if case .node(let node) = kind { session.zoom(into: node) }
        }
        .modifier(ShowInFinderAction(session: session, node: kind?.node))
    }

    /// A click zooms into a folder row; a double click also shows the item in Finder.
    private func click(_ kind: SegmentKind?) {
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
            if let node = clickOrigin.node { session.showInFinder(node) }
            clickOrigin.node = nil
            return
        }
        clickOrigin.node = kind?.node
        if let node = kind?.node { session.zoom(into: node) }
    }

    private func isZoomable(_ kind: SegmentKind?) -> Bool {
        if case .node(let node) = kind { return node.isDirectory && !node.children.isEmpty }
        return false
    }
}

/// The double click's counterpart for assistive technologies.
private struct ShowInFinderAction: ViewModifier {
    let session: MapSession
    let node: FileNode?

    func body(content: Content) -> some View {
        if let node {
            content.accessibilityAction(named: "Show in Finder") { session.showInFinder(node) }
        } else {
            content
        }
    }
}

/// Lets a list row be dragged to the collector exactly like its arc in the map.
/// Rows that are not files or folders (smaller objects, hidden and free space) stay put.
private struct DragToCollect: ViewModifier {
    let session: MapSession
    let kind: SegmentKind?

    func body(content: Content) -> some View {
        if case .node(let node) = kind {
            content.onDrag { session.dragItem(for: node) } preview: { DragPreview(node: node) }
        } else {
            content
        }
    }
}
