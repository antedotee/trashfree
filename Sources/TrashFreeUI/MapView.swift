import AppKit
import TrashFreeCore
import SwiftUI

/// The map screen: toolbar with history and path, chart, info panel, collector.
struct MapView: View {
    @ObservedObject var session: MapSession
    @State private var highlight: Highlight?
    @State private var subject: SegmentKind?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .frame(height: Theme.titleBarHeight)
            HStack(alignment: .top, spacing: 0) {
                SunburstChart(session: session, highlight: $highlight, subject: $subject)
                    .padding(.top, 24)
                    .padding(.horizontal, 12)
                InfoPanel(session: session, highlight: $highlight, subject: subject)
                    .frame(width: 264)
                    .padding(.top, 20)
                    .padding(.trailing, 24)
            }
            CollectorView(session: session)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            // Clears the traffic lights.
            Color.clear.frame(width: 84)
            HistoryButton(systemName: "chevron.left", label: "Back", action: session.goBack)
                .keyboardShortcut("[", modifiers: .command)
            HistoryButton(systemName: "chevron.right", label: "Forward", action: session.goForward)
                .keyboardShortcut("]", modifiers: .command)
                .disabled(session.forwardStack.isEmpty)
            Color.clear.frame(width: 10)
            // The breadcrumb fits itself to everything right of the history buttons.
            Breadcrumb(session: session)
                .padding(.trailing, 24)
        }
    }
}

/// A chevron with a quiet hover wash; dims when unavailable.
private struct HistoryButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle(cornerRadius: 6))
        .accessibilityLabel(label)
    }
}

/// The path from the disk list to the focused folder. Earlier steps are links in
/// secondary ink; the current folder is the only one at full ink.
///
/// When the path is wider than the toolbar, the middle crumbs give up width and fade out
/// at the cut. The first and the current crumb keep their names, and hovering a squeezed
/// crumb widens it to its full name while its neighbours make room.
struct Breadcrumb: View {
    @ObservedObject var session: MapSession
    @State private var hovered: Int?

    private struct Crumb {
        let title: String
        let isCurrent: Bool
        let action: () -> Void
    }

    private static let padding: CGFloat = 7
    private static let separatorWidth: CGFloat = 13
    /// Below this a squeezed crumb shows only its fade; the current folder always fits.
    private static let minimumWidth: CGFloat = 12
    private static let height: CGFloat = 26

    var body: some View {
        let chain = session.focus.chain
        let crumbs = [Crumb(title: "Disks", isCurrent: false) { session.showSources() }]
            + chain.enumerated().map { index, node in
                Crumb(title: session.displayName(of: node), isCurrent: index == chain.count - 1) {
                    session.jump(to: node)
                }
            }
        GeometryReader { geometry in
            let widths = Self.widths(for: crumbs, available: geometry.size.width, expanded: hovered)
            HStack(spacing: 0) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.compact.right")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.tertiaryText)
                            .frame(width: Self.separatorWidth)
                            .accessibilityHidden(true)
                    }
                    button(crumb, width: widths[index], natural: Self.naturalWidth(of: crumb), index: index)
                }
            }
            .frame(height: geometry.size.height)
        }
        .frame(height: Self.height)
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: hovered)
        .animation(Theme.Motion.change, value: chain.count)
    }

    private func button(_ crumb: Crumb, width: CGFloat, natural: CGFloat, index: Int) -> some View {
        let clipped = width < natural - 0.5
        return Button(action: crumb.action) {
            Text(crumb.title)
                .font(crumb.isCurrent ? Theme.Font.breadcrumbCurrent : Theme.Font.breadcrumb)
                .foregroundColor(crumb.isCurrent ? Theme.text : Theme.secondaryText)
                .lineLimit(1)
                .fixedSize()
                .frame(width: max(width - Self.padding * 2, 0), alignment: .leading)
                .mask(FadeMask(fade: clipped ? 14 : 0))
                .clipped()
                .padding(.horizontal, Self.padding)
                .frame(height: Self.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle(cornerRadius: 6))
        .onHover { inside in
            if inside { hovered = index } else if hovered == index { hovered = nil }
        }
        .accessibilityLabel(crumb.title)
    }

    private static func naturalWidth(of crumb: Crumb) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 13, weight: crumb.isCurrent ? .medium : .regular)
        let text = (crumb.title as NSString).size(withAttributes: [.font: font]).width
        return ceil(text) + padding * 2
    }

    /// Crumb widths that fit `available`. Pinned crumbs (the first, the current one, and
    /// the hovered one) keep their natural width. The rest share what is left: a crumb
    /// narrower than an even share keeps its width, and wider ones get the share.
    private static func widths(for crumbs: [Crumb], available: CGFloat, expanded: Int?) -> [CGFloat] {
        let natural = crumbs.map(naturalWidth(of:))
        let room = available - CGFloat(max(crumbs.count - 1, 0)) * separatorWidth
        guard natural.reduce(0, +) > room else { return natural }
        var pinned: Set<Int> = [0, crumbs.count - 1]
        if let expanded { pinned.insert(expanded) }
        // A very deep path cannot pin "Disks" as well; the current folder wins.
        if natural[crumbs.count - 1] + natural[0] + CGFloat(crumbs.count - 2) * minimumWidth > room {
            pinned.remove(0)
        }
        var widths = natural
        let others = crumbs.indices.filter { !pinned.contains($0) }.sorted { natural[$0] < natural[$1] }
        var remaining = room - pinned.reduce(0) { $0 + natural[$1] }
        for (position, index) in others.enumerated() {
            let share = remaining / CGFloat(others.count - position)
            if natural[index] <= share {
                remaining -= natural[index]
            } else {
                for rest in others[position...] { widths[rest] = max(share, minimumWidth) }
                break
            }
        }
        return widths
    }
}

/// Opaque, with the last `fade` points fading out, so a clipped label reads as cut off
/// rather than chopped.
private struct FadeMask: View {
    let fade: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: fade)
        }
    }
}
