import AppKit
import SwiftUI

public struct RootView: View {
    @StateObject private var model = AppModel()
    @State private var window: NSWindow?

    public init() {}

    public var body: some View {
        ZStack {
            switch model.screen {
            case .sources:
                SourcesView(model: model)
                    .transition(.opacity)
            case .map(let session):
                MapView(session: session)
                    .id(ObjectIdentifier(session))
                    .transition(.opacity)
            }
        }
        // The window resizes at the same time, so the screens crossfade rather than slide.
        .animation(Theme.Motion.screen, value: isMap)
        .frame(minWidth: 720, minHeight: 200)
        .background(Theme.background)
        .ignoresSafeArea()
        .background(WindowReader { window = $0 })
        .sheet(isPresented: Binding(
            get: { model.accessRequest != nil },
            set: { if !$0 { model.cancelAccessRequest() } }
        )) {
            if let request = model.accessRequest {
                AccessSheet(model: model, request: request)
            }
        }
        .onChange(of: isMap) { _ in fitWindow() }
        .onChange(of: model.accessRequest == nil) { _ in fitWindow() }
        .onChange(of: model.sources.count) { _ in fitWindow() }
        .onChange(of: window) { _ in fitWindow() }
    }

    private var isMap: Bool {
        if case .map = model.screen { return true }
        return false
    }

    /// The window fits the disk list, and grows for the map.
    private func fitWindow() {
        guard let window else { return }
        var height: CGFloat = isMap
            ? 600
            : SourcesView.height(model.sources.count)
        // A sheet taller than its window would be cut off at the bottom.
        if model.accessRequest != nil {
            height = max(height, AccessSheet.height + Theme.titleBarHeight + 40)
        }
        // The title bar is transparent and content runs edge to edge, so frame == content.
        var frame = window.frame
        let delta = height - frame.height
        guard abs(delta) > 1 else { return }
        frame.size.height += delta
        frame.origin.y -= delta
        frame.size.width = max(frame.width, 800)
        window.setFrame(frame, display: true, animate: true)
    }
}

/// Hands back the hosting NSWindow once the view is in one, and centers its traffic
/// lights in the title strip.
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            context.coordinator.lights.attach(to: window)
            onWindow(window)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        let lights = TrafficLights()
    }
}

/// The window buttons sit in a 52pt title strip, centered 26pt from the top-left
/// corner, instead of the standard 28pt bar. An empty NSToolbar would give
/// that height, but on macOS 26 it paints an opaque band over the content, so this
/// moves the buttons directly, the way Electron implements `trafficLightPosition`.
/// AppKit lays the title bar out again on every resize, so the position is
/// re-applied after each one.
@MainActor
final class TrafficLights {
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    /// A light/dark switch also lays the title bar out again.
    private var appearanceObservation: NSKeyValueObservation?

    func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        observers.forEach(NotificationCenter.default.removeObserver)
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didBecomeKeyNotification,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.layout() }
            }
        }
        appearanceObservation = window.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.layout() } }
        }
        layout()
    }

    private func layout() {
        guard let window, !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let minimize = window.standardWindowButton(.miniaturizeButton),
              let zoom = window.standardWindowButton(.zoomButton),
              let container = close.superview?.superview else { return }
        let height = Theme.titleBarHeight
        let buttonSize = close.frame.size
        // Keep AppKit's own spacing between the buttons.
        let spacing = minimize.frame.minX - close.frame.minX
        let left = 26 - buttonSize.width / 2

        var frame = container.frame
        frame.size.height = height
        frame.origin.y = window.frame.height - height
        container.frame = frame

        for (index, button) in [close, minimize, zoom].enumerated() {
            button.setFrameOrigin(CGPoint(x: left + CGFloat(index) * spacing, y: (height - buttonSize.height) / 2))
        }
    }
}
