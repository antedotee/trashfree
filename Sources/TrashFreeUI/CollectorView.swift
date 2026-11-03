import AppKit
import TrashFreeCore
import SwiftUI
import UniformTypeIdentifiers

/// The drop target in the bottom-left corner. Items dragged here from the map (or from
/// Finder, if they are inside the scanned folder) wait for a single "Move to Trash".
struct CollectorView: View {
    @ObservedObject var session: MapSession
    @State private var isTargeted = false
    @State private var showsList = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 14) {
            Button { showsList.toggle() } label: { well }
                .buttonStyle(.plain)
                .disabled(session.collected.isEmpty)
                .popover(isPresented: $showsList, arrowEdge: .top) { list }
                .accessibilityLabel("Collector")

            ZStack(alignment: .leading) {
                if session.collected.isEmpty || session.isDragging {
                    Text(hint)
                        .font(Theme.Font.hint)
                        .foregroundColor(session.isDragging ? Theme.text : Theme.secondaryText)
                        .id(hint)
                        .transition(.opacity)
                } else {
                    HStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(session.collected.count) \(session.collected.count == 1 ? "item" : "items")")
                                .font(Theme.Font.rowTitle)
                                .foregroundColor(Theme.text)
                            Text(ByteSizeFormatter.string(fromByteCount: session.collectedBytes))
                                .font(Theme.Font.rowDetail)
                                .foregroundColor(Theme.secondaryText)
                        }
                        HStack(spacing: 8) {
                            // One click: the items go to the Trash, where they can still be
                            // put back from Finder, so a second confirmation adds nothing.
                            ActionButton(title: "Move to Trash", kind: .destructive) {
                                showsList = false
                                session.deleteCollected()
                            }
                            ActionButton(title: "Clear") { session.clearCollected() }
                        }
                    }
                    .transition(.opacity)
                }
            }
            .animation(Theme.Motion.change, value: session.collected.isEmpty)
            .animation(Theme.Motion.change, value: hint)
            Spacer()
        }
        .padding(.trailing, 12)
        .frame(height: 56)
        // While a segment is dragged, the whole strip lights up as the place to drop it.
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(isTargeted ? Theme.pressedFill : session.isDragging ? Theme.hoverFill : .clear)
                .padding(.leading, -6)
                .padding(.vertical, -6))
        .animation(Theme.Motion.hover, value: session.isDragging)
        .animation(Theme.Motion.hover, value: isTargeted)
        .contentShape(Rectangle())
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted, perform: accept)
        .alert("Some items could not be deleted", isPresented: Binding(
            get: { session.deletionError != nil },
            set: { if !$0 { session.deletionError = nil } }
        )) {
            Button("OK") { session.deletionError = nil }
        } message: {
            Text(session.deletionError ?? "")
        }
    }

    private var hint: String {
        if isTargeted { return "Release to collect" }
        if session.isDragging { return "Drop here to collect" }
        return "Drag items here to collect them for deletion"
    }

    private var well: some View {
        let empty = session.collected.isEmpty
        return ZStack {
            Circle()
                .fill(empty ? (isTargeted ? Theme.hoverFill : Color.clear) : Theme.primaryFill)
            Circle()
                .strokeBorder(isTargeted || session.isDragging ? Theme.text : Theme.strongBorder,
                              style: StrokeStyle(lineWidth: 1.5, dash: empty && !isTargeted ? [3, 3] : []))
                .opacity(empty || isTargeted ? 1 : 0)
            if empty {
                Image(systemName: "trash")
                    .font(.system(size: 15))
                    .foregroundColor(isTargeted ? Theme.text : Theme.secondaryText)
            } else {
                Text("\(session.collected.count)")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundColor(Theme.primaryText)
                    .contentTransition(.numericText())
            }
        }
        .frame(width: 44, height: 44)
        .scaleEffect(reduceMotion ? 1 : isTargeted ? 1.14 : session.isDragging ? 1.05 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isTargeted)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: session.isDragging)
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: session.collected.count)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(session.collected, id: \.id) { node in
                CollectedRow(name: node.name, isDirectory: node.isDirectory, bytes: node.size) {
                    session.uncollect(node)
                    if session.collected.isEmpty { showsList = false }
                }
            }
        }
        .padding(8)
        .frame(width: 320)
        .animation(Theme.Motion.change, value: session.collected.count)
    }

    private func accept(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    if let node = session.node(for: url) { session.collect(node) }
                }
            }
        }
        return accepted
    }
}

/// One collected item in the collector's list. Hovering it reveals the button that puts
/// it back on the map.
private struct CollectedRow: View {
    let name: String
    let isDirectory: Bool
    let bytes: Int64
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(QuietButtonStyle(cornerRadius: 4))
            .opacity(hovering ? 1 : 0)
            .accessibilityLabel("Put \(name) back")
            Image(systemName: isDirectory ? "folder" : "doc")
                .foregroundColor(Theme.secondaryText)
                .frame(width: 16)
            Text(name).lineLimit(1).truncationMode(.middle).foregroundColor(Theme.text)
            Spacer(minLength: 16)
            Text(ByteSizeFormatter.string(fromByteCount: bytes)).foregroundColor(Theme.secondaryText)
        }
        .font(Theme.Font.panelRow)
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Theme.hoverFill : .clear))
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: hovering)
    }
}
