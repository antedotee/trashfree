import AppKit
import Combine
import TrashFreeCore
import SwiftUI

/// Something the user can scan: a mounted volume or a folder they picked.
struct Source: Identifiable {
    enum Target {
        case volume(Volume)
        case folder(URL)
    }

    enum ScanState {
        case idle
        case scanning(ScanJob, progress: Double)
        case scanned(ScanResult)
    }

    let id: String
    var target: Target
    var state: ScanState = .idle

    var url: URL {
        switch target {
        case .volume(let volume): return volume.url
        case .folder(let url): return url
        }
    }

    var volume: Volume? {
        if case .volume(let volume) = target { return volume }
        return nil
    }

    var name: String {
        switch target {
        case .volume(let volume): return volume.name
        case .folder(let url): return FileManager.default.displayName(atPath: url.path)
        }
    }

    var isScanning: Bool {
        if case .scanning = state { return true }
        return false
    }

    var result: ScanResult? {
        if case .scanned(let result) = state { return result }
        return nil
    }
}

@MainActor
public final class AppModel: ObservableObject {
    enum Screen {
        case sources
        case map(MapSession)
    }

    /// Where the Full Disk Access request stands. `sourceID` is the scan waiting on it;
    /// nil when the user opened the request from a menu without scanning.
    enum AccessRequest: Equatable {
        /// The sheet explains what access is for.
        case asking(sourceID: String?)
        /// System Settings is open; the app checks for the grant every second.
        case waiting(sourceID: String?)

        var sourceID: String? {
            switch self {
            case .asking(let id), .waiting(let id): return id
            }
        }
    }

    @Published private(set) var sources: [Source] = []
    @Published private(set) var screen: Screen = .sources
    @Published private(set) var accessRequest: AccessRequest?
    @Published private(set) var hasFullDiskAccess = FullDiskAccess.isGranted

    private var progressTimer: Timer?
    private var accessTimer: Timer?
    private var volumeObservers: [NSObjectProtocol] = []

    private enum Defaults {
        /// Set when the user chose to scan without Full Disk Access; they are not asked
        /// again until they ask for it themselves.
        static let declined = "FullDiskAccessDeclined"
        /// A scan waiting for the grant, kept across the relaunch macOS may require.
        static let pendingScan = "ScanAfterRelaunch"
    }

    public init() {
        reloadVolumes()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            volumeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadVolumes() }
            })
        }
        // Coming back from System Settings is the likeliest moment the grant appears.
        volumeObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAccess() }
        })
        resumePendingScan()
    }

    /// Rebuilds the volume rows, keeping scan state for volumes that are still mounted.
    func reloadVolumes() {
        let existing = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let volumes = Volume.browsable().map { volume -> Source in
            var source = existing[volume.id] ?? Source(id: volume.id, target: .volume(volume))
            source.target = .volume(volume)
            return source
        }
        let folders = sources.filter { $0.volume == nil }
        sources = volumes + folders
    }

    // MARK: Full Disk Access

    /// Starts a scan, asking for Full Disk Access first if the app has never had it
    /// and the user has not declined it.
    func scan(_ sourceID: String) {
        hasFullDiskAccess = FullDiskAccess.isGranted
        if hasFullDiskAccess || UserDefaults.standard.bool(forKey: Defaults.declined) {
            startScan(sourceID)
        } else if accessRequest == nil {
            accessRequest = .asking(sourceID: sourceID)
        }
    }

    /// Opens the request without a scan behind it, from a row's menu.
    func requestAccess() {
        guard !FullDiskAccess.isGranted else {
            hasFullDiskAccess = true
            return
        }
        accessRequest = .asking(sourceID: nil)
    }

    func openAccessSettings() {
        guard let request = accessRequest else { return }
        FullDiskAccess.openSettings()
        accessRequest = .waiting(sourceID: request.sourceID)
        // macOS may quit and reopen the app to apply the grant; the scan resumes then.
        if let id = request.sourceID {
            UserDefaults.standard.set(id, forKey: Defaults.pendingScan)
        }
        accessTimer?.invalidate()
        accessTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAccess() }
        }
    }

    func scanWithoutAccess() {
        UserDefaults.standard.set(true, forKey: Defaults.declined)
        let id = accessRequest?.sourceID
        endAccessRequest()
        if let id { startScan(id) }
    }

    func cancelAccessRequest() {
        endAccessRequest()
    }

    func relaunchForAccess() {
        if let id = accessRequest?.sourceID {
            UserDefaults.standard.set(id, forKey: Defaults.pendingScan)
        }
        FullDiskAccess.relaunch()
    }

    private func checkAccess() {
        hasFullDiskAccess = FullDiskAccess.isGranted
        guard hasFullDiskAccess, let request = accessRequest else { return }
        // A grant replaces an earlier "scan without access".
        UserDefaults.standard.removeObject(forKey: Defaults.declined)
        endAccessRequest()
        NSApp.activate(ignoringOtherApps: true)
        if let id = request.sourceID { startScan(id) }
    }

    private func endAccessRequest() {
        accessTimer?.invalidate()
        accessTimer = nil
        accessRequest = nil
        UserDefaults.standard.removeObject(forKey: Defaults.pendingScan)
    }

    /// After a relaunch for the grant, picks the waiting scan back up.
    private func resumePendingScan() {
        guard let id = UserDefaults.standard.string(forKey: Defaults.pendingScan) else { return }
        UserDefaults.standard.removeObject(forKey: Defaults.pendingScan)
        if id.hasPrefix("folder:") {
            let url = URL(fileURLWithPath: String(id.dropFirst("folder:".count)))
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            sources.append(Source(id: id, target: .folder(url)))
        }
        guard sources.contains(where: { $0.id == id }) else { return }
        scan(id)
    }

    // MARK: Scanning

    private func startScan(_ sourceID: String) {
        guard let index = sources.firstIndex(where: { $0.id == sourceID }), !sources[index].isScanning else { return }
        let source = sources[index]
        let options: ScanJob.Options
        if let volume = source.volume {
            options = volume.kind == .startup
                ? .startupDisk(expectedBytes: volume.usedBytes)
                : .init(expectedBytes: volume.usedBytes)
        } else {
            options = .init()
        }
        let job = ScanJob(url: source.url, options: options)
        sources[index].state = .scanning(job, progress: 0)
        job.start { [weak self] result in
            MainActor.assumeIsolated { self?.finish(sourceID: sourceID, job: job, result: result) }
        }
        startProgressTimer()
    }

    func cancelScan(_ sourceID: String) {
        guard let index = sources.firstIndex(where: { $0.id == sourceID }),
              case .scanning(let job, _) = sources[index].state else { return }
        job.cancel()
        sources[index].state = .idle
    }

    func forgetScan(_ sourceID: String) {
        guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { return }
        if sources[index].volume == nil {
            sources.remove(at: index)
        } else {
            sources[index].state = .idle
        }
    }

    /// Asks for a folder with the standard open panel, then scans it.
    func chooseFolderToScan() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder to scan"
        // `begin` instead of `runModal`: a modal loop inside a button action blocks the
        // caller (and accessibility clients) until the panel closes.
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url?.standardizedFileURL else { return }
            MainActor.assumeIsolated { self?.addFolder(url) }
        }
    }

    private func addFolder(_ url: URL) {
        let id = "folder:" + url.path
        if !sources.contains(where: { $0.id == id }) {
            sources.append(Source(id: id, target: .folder(url)))
        }
        scan(id)
    }

    private func finish(sourceID: String, job: ScanJob, result: ScanResult?) {
        guard let index = sources.firstIndex(where: { $0.id == sourceID }),
              case .scanning(let current, _) = sources[index].state, current === job else { return }
        guard let result else {
            sources[index].state = .idle
            return
        }
        sources[index].state = .scanned(result)
        view(sourceID)
    }

    private func startProgressTimer() {
        guard progressTimer == nil else { return }
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickProgress() }
        }
    }

    private func tickProgress() {
        var anyScanning = false
        for index in sources.indices {
            if case .scanning(let job, _) = sources[index].state {
                sources[index].state = .scanning(job, progress: job.progress)
                anyScanning = true
            }
        }
        if !anyScanning {
            progressTimer?.invalidate()
            progressTimer = nil
        }
    }

    // MARK: Navigation

    func view(_ sourceID: String) {
        guard let source = sources.first(where: { $0.id == sourceID }), let result = source.result else { return }
        screen = .map(MapSession(sourceID: sourceID, name: source.name, result: result, volume: source.volume, model: self))
    }

    func showSources() {
        reloadVolumes()
        screen = .sources
    }

    func volumeChanged(_ volume: Volume) {
        guard let index = sources.firstIndex(where: { $0.id == volume.id }) else { return }
        sources[index].target = .volume(volume)
    }
}

/// One open map: the scanned tree, where the user is in it, and what they collected.
@MainActor
final class MapSession: ObservableObject {
    let sourceID: String
    let name: String
    let result: ScanResult
    @Published private(set) var volume: Volume?
    @Published private(set) var focus: FileNode
    @Published private(set) var backStack: [FileNode] = []
    @Published private(set) var forwardStack: [FileNode] = []
    /// Items waiting in the collector. They leave the map at once, so the user sees
    /// the space they are about to free; un-collecting puts them back.
    @Published private(set) var collected: [FileNode] = [] {
        didSet {
            excludedBytes = Self.excludedBytes(for: collected)
            revision += 1
        }
    }
    /// Bytes collected inside each folder (keyed by the folder), for every ancestor of
    /// a collected item, including the item itself.
    private var excludedBytes: [ObjectIdentifier: Int64] = [:]
    /// True from the moment a segment is dragged out of the map until the mouse button
    /// comes up, so the collector can show it is ready to receive.
    @Published private(set) var isDragging = false
    /// Bumped when the user asks for the focused folder again (its crumb), so the panel
    /// drops whatever it was showing and lists the folder.
    @Published private(set) var focusRequests = 0
    private var dragWatch: Timer?
    @Published var deletionError: String?
    /// Bumped whenever the map's contents change (deletion, collecting), so layouts
    /// rebuild.
    @Published private(set) var revision = 0

    private weak var model: AppModel?

    init(sourceID: String, name: String, result: ScanResult, volume: Volume?, model: AppModel) {
        self.sourceID = sourceID
        self.name = name
        self.result = result
        self.volume = volume
        self.focus = result.root
        self.model = model
    }

    var root: FileNode { result.root }

    func displayName(of node: FileNode) -> String {
        node === root ? name : node.name
    }

    func url(of node: FileNode) -> URL {
        node.url(under: result.rootURL)
    }

    /// The layout for a folder. The volume root's circle covers the whole disk, so free
    /// space is an empty wedge and unscanned bytes show as hidden space.
    func layout(for node: FileNode) -> SunburstLayout {
        let size = { [excludedBytes] (node: FileNode) in node.size - (excludedBytes[ObjectIdentifier(node)] ?? 0) }
        if node === root, let volume {
            return SunburstLayout(
                focus: node,
                total: max(volume.totalBytes, node.size),
                leadingGap: volume.freeBytes + collectedBytes,
                hiddenBytes: hiddenBytes,
                size: size
            )
        }
        return SunburstLayout(focus: node, total: max(size(node), 1), size: size)
    }

    /// Size with collected items taken out.
    func size(of node: FileNode) -> Int64 {
        node.size - (excludedBytes[ObjectIdentifier(node)] ?? 0)
    }

    /// A volume root reports the disk's used space, hidden space included.
    func displayedSize(of node: FileNode) -> Int64 {
        node === root ? size(of: node) + hiddenBytes : size(of: node)
    }

    func isCollected(_ node: FileNode) -> Bool {
        collected.contains { $0 === node || node.isDescendant(of: $0) }
    }

    private static func excludedBytes(for collected: [FileNode]) -> [ObjectIdentifier: Int64] {
        var result: [ObjectIdentifier: Int64] = [:]
        for item in collected {
            var node: FileNode? = item
            while let current = node {
                result[ObjectIdentifier(current), default: 0] += item.size
                node = current.parent
            }
        }
        return result
    }

    var hiddenBytes: Int64 {
        guard let volume else { return 0 }
        return max(volume.usedBytes - root.size, 0)
    }

    // MARK: Navigation

    func zoom(into node: FileNode) {
        guard node !== focus, node.isDirectory, !node.children.isEmpty, size(of: node) > 0 else { return }
        backStack.append(focus)
        forwardStack.removeAll()
        focus = node
    }

    func zoomOut() {
        guard let parent = focus.parent else { return }
        backStack.append(focus)
        forwardStack.removeAll()
        focus = parent
    }

    func jump(to node: FileNode) {
        guard node !== focus else {
            focusRequests += 1
            return
        }
        backStack.append(focus)
        forwardStack.removeAll()
        focus = node
    }

    func goBack() {
        guard let previous = backStack.popLast() else {
            model?.showSources()
            return
        }
        forwardStack.append(focus)
        focus = previous
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(focus)
        focus = next
    }

    func showSources() {
        model?.showSources()
    }

    /// Opens a folder in a Finder window, or selects a file in its folder. Packages such
    /// as apps are selected too, because opening one would launch it.
    func showInFinder(_ node: FileNode) {
        let url = url(of: node)
        let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
        if node.isDirectory && !isPackage {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // MARK: Collector

    func collect(_ node: FileNode) {
        guard node !== root else { return }
        // Collecting a folder supersedes anything already collected inside it.
        guard !collected.contains(where: { node.isDescendant(of: $0) }) else { return }
        var next = collected.filter { $0 !== node && !$0.isDescendant(of: node) }
        next.append(node)
        collected = next
        // The focused folder may now be empty; show its nearest ancestor that is not.
        while size(of: focus) <= 0, let parent = focus.parent {
            focus = parent
        }
    }

    /// Resolves a dropped file URL to its node in this scan.
    func node(for url: URL) -> FileNode? {
        let rootComponents = result.rootURL.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.count > rootComponents.count, Array(components.prefix(rootComponents.count)) == rootComponents else { return nil }
        var node = root
        for name in components.dropFirst(rootComponents.count) {
            guard let child = node.children.first(where: { $0.name == name }) else { return nil }
            node = child
        }
        return node
    }

    var collectedBytes: Int64 { collected.reduce(0) { $0 + $1.size } }

    func uncollect(_ node: FileNode) {
        collected.removeAll { $0 === node }
    }

    func clearCollected() {
        collected.removeAll()
    }

    /// The pasteboard item for dragging `node` to the collector (or to Finder).
    func dragItem(for node: FileNode) -> NSItemProvider {
        beginDrag()
        let provider = NSItemProvider(object: url(of: node) as NSURL)
        provider.suggestedName = node.name
        return provider
    }

    /// Called when a drag starts. SwiftUI's `onDrag` reports no end, so this watches
    /// the mouse button instead.
    private func beginDrag() {
        isDragging = true
        dragWatch?.invalidate()
        dragWatch = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            timer.invalidate()
            MainActor.assumeIsolated { self?.isDragging = false }
        }
    }

    /// Moves every collected item to the Trash and removes it from the map.
    func deleteCollected() {
        var failures: [String] = []
        for node in collected {
            do {
                try FileManager.default.trashItem(at: url(of: node), resultingItemURL: nil)
                if focus === node || focus.isDescendant(of: node) {
                    focus = node.parent ?? root
                }
                node.removeFromParent()
            } catch {
                failures.append("\(node.name): \(error.localizedDescription)")
            }
        }
        backStack.removeAll { $0.chain.first !== root }
        forwardStack.removeAll()
        collected.removeAll()
        if let refreshed = volume?.refreshed() {
            volume = refreshed
            model?.volumeChanged(refreshed)
        }
        revision += 1
        deletionError = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }
}
