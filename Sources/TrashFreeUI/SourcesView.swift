import AppKit
import TrashFreeCore
import SwiftUI

/// The disk list: everything the user can map, one row each.
struct SourcesView: View {
    @ObservedObject var model: AppModel

    static let rowHeight: CGFloat = 64
    static let bottomInset: CGFloat = 12
    static let height = { (rows: Int) in Theme.titleBarHeight + CGFloat(rows) * rowHeight + bottomInset }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Clears the traffic lights.
                Color.clear.frame(width: 92)
                Text("Disks")
                    .font(Theme.Font.panelTitle)
                    .foregroundColor(Theme.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 16)
                ActionButton(title: "Scan Folder…", systemImage: "folder.badge.plus") { model.chooseFolderToScan() }
                    .padding(.trailing, 16)
            }
            .frame(height: Theme.titleBarHeight)

            VStack(spacing: 0) {
                ForEach(Array(model.sources.enumerated()), id: \.element.id) { index, source in
                    if index > 0 {
                        // Inset to the text column so the icons read as one column.
                        Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 68)
                    }
                    SourceRow(source: source, model: model)
                        .transition(.opacity)
                }
            }
            .animation(Theme.Motion.change, value: model.sources.map(\.id))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct SourceRow: View {
    let source: Source
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .light))
                .foregroundColor(Theme.secondaryText)
                .frame(width: 28)
                .padding(.leading, 24)
                .padding(.trailing, 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(source.name)
                    .font(Theme.Font.rowTitle)
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(Theme.Font.rowDetail)
                    .foregroundColor(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 24)

            ZStack(alignment: .leading) {
                usage
                    .id(stateKey)
                    .transition(.opacity)
            }
            .frame(width: 200, alignment: .leading)
            .padding(.trailing, 24)

            actions
                .frame(width: SplitButton.size.width, alignment: .trailing)
                .padding(.trailing, 16)
        }
        .frame(height: SourcesView.rowHeight)
        .animation(Theme.Motion.change, value: stateKey)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(source.name)
    }

    /// Changes when the row switches between idle, scanning, and scanned.
    private var stateKey: Int {
        switch source.state {
        case .idle: return 0
        case .scanning, .restoring: return 1
        case .scanned: return 2
        }
    }

    private var symbol: String {
        switch source.volume?.kind {
        case .startup?, .internalDisk?: return "internaldrive"
        case .external?, .diskImage?: return "externaldrive"
        case .network?: return "network"
        case nil: return "folder"
        }
    }

    private var subtitle: String {
        guard let volume = source.volume else { return source.url.path }
        let kind = volume.kindDescription
        return "\(ByteSizeFormatter.string(fromByteCount: volume.totalBytes)) · \(kind.prefix(1).uppercased() + kind.dropFirst())"
    }

    @ViewBuilder
    private var usage: some View {
        switch source.state {
        case .restoring, .scanning:
            let progress: Double = { if case .scanning(_, let value) = source.state { return value }; return 0 }()
            let updating: Bool = {
                if case .scanning(let job, _) = source.state { return job.isRefresh }
                return true
            }()
            lines(bar: ScanProgressBar(progress: progress)) {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(updating ? "Updating…" : "Scanning…")
                        .font(Theme.Font.rowDetail)
                        .foregroundColor(Theme.secondaryText)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(updating ? "Updating" : "Scanning")
            .accessibilityValue(Text("\(Int(progress * 100)) percent"))
        default:
            if let volume = source.volume {
                let nearlyFull = volume.usedFraction >= 0.9
                lines(bar: UsageBar(fraction: volume.usedFraction, color: nearlyFull ? Theme.warning : Theme.secondaryText)) {
                    Text("\(ByteSizeFormatter.string(fromByteCount: volume.freeBytes)) free")
                        .font(Theme.Font.rowDetail)
                        .foregroundColor(nearlyFull ? Theme.warning : Theme.secondaryText)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(ByteSizeFormatter.string(fromByteCount: volume.freeBytes)) free")
            } else if let result = source.result {
                Text(ByteSizeFormatter.string(fromByteCount: result.root.size))
                    .font(Theme.Font.rowDetail)
                    .foregroundColor(Theme.secondaryText)
            } else {
                Color.clear.frame(height: 1)
            }
        }
    }

    /// Lays the bar and its caption out on the same two lines as the name and subtitle,
    /// so the bar sits level with the name and the caption with the subtitle.
    private func lines<Bar: View, Detail: View>(bar: Bar, @ViewBuilder detail: () -> Detail) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(" ")
                .font(Theme.Font.rowTitle)
                .hidden()
                .frame(maxWidth: .infinity)
                .overlay(bar)
            Text(" ")
                .font(Theme.Font.rowDetail)
                .hidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) { detail() }
        }
    }

    private var menuEntries: [MenuEntry] {
        var entries: [MenuEntry] = []
        if source.result != nil {
            entries += [.item("Rescan") { model.rescan(source.id) }, .item("Forget Scan Result") { model.forgetScan(source.id) }, .separator]
        } else if source.volume == nil {
            entries += [.item("Remove") { model.forgetScan(source.id) }, .separator]
        }
        let url = source.url
        entries.append(.item("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        if !model.hasFullDiskAccess {
            entries += [.separator, .item("Allow Full Disk Access…") { model.requestAccess() }]
        }
        return entries
    }

    @ViewBuilder
    private var actions: some View {
        if source.isScanning {
            ActionButton(title: "Cancel", width: SplitButton.size.width) { model.cancelScan(source.id) }
        } else {
            // A finished scan is the one thing on the row worth doing next.
            SplitButton(
                title: source.result == nil ? "Scan" : "View",
                kind: source.result == nil ? .secondary : .primary,
                primary: {
                    if source.result == nil { model.scan(source.id) } else { model.view(source.id) }
                },
                entries: menuEntries
            )
        }
    }
}

/// How full a disk is.
struct UsageBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(color).frame(width: max(geometry.size.width * fraction, 4))
            }
        }
        .frame(height: 4)
    }
}

/// Scan progress: the filled part grows with the bytes found, and diagonal stripes run
/// across the whole bar the moment the scan starts, so the row reads as busy even before
/// the first bytes are counted. This is status, not decoration, so it animates even with
/// Reduce Motion on.
struct ScanProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Stripes(color: Theme.track, background: Theme.track.opacity(0.4))
                    .clipShape(Capsule())
                Stripes(color: Theme.secondaryText, background: Theme.text)
                    .clipShape(Capsule())
                    .frame(width: max(geometry.size.width * progress, 28))
                    .animation(.easeOut(duration: 0.3), value: progress)
            }
        }
        .frame(height: 6)
    }

    /// A barber pole: stripes slide right one period every 0.6s.
    private struct Stripes: View {
        let color: Color
        let background: Color

        var body: some View {
            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    let period: CGFloat = 10
                    let phase = CGFloat(timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.6) / 0.6) * period
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(background))
                    var stripes = Path()
                    var x = -size.height - period + phase
                    while x < size.width + size.height {
                        stripes.move(to: CGPoint(x: x, y: size.height))
                        stripes.addLine(to: CGPoint(x: x + size.height, y: 0))
                        stripes.addLine(to: CGPoint(x: x + size.height + period / 2, y: 0))
                        stripes.addLine(to: CGPoint(x: x + period / 2, y: size.height))
                        stripes.closeSubpath()
                        x += period
                    }
                    context.fill(stripes, with: .color(color))
                }
            }
        }
    }
}
