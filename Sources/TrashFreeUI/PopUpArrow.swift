import AppKit
import SwiftUI

/// One entry in a `PopUpArrow` menu. A nil title draws a separator.
struct MenuEntry {
    let title: String?
    let action: () -> Void

    static func item(_ title: String, _ action: @escaping () -> Void) -> MenuEntry { MenuEntry(title: title, action: action) }
    static let separator = MenuEntry(title: nil, action: {})
}

/// The chevron half of a split button. SwiftUI's `Menu` ignores the label's color and
/// size on macOS, so this draws the chevron itself and opens an NSMenu under it.
struct PopUpArrow: NSViewRepresentable {
    let accessibilityLabel: String
    /// Drawn on an ink-filled button, so the chevron takes the canvas color.
    var isOnInk = false
    let entries: [MenuEntry]

    func makeNSView(context: Context) -> ArrowView {
        let view = ArrowView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.popUpButton)
        return view
    }

    func updateNSView(_ view: ArrowView, context: Context) {
        view.entries = entries
        view.isOnInk = isOnInk
        view.needsDisplay = true
        view.setAccessibilityLabel(accessibilityLabel)
    }

    final class ArrowView: NSView {
        var entries: [MenuEntry] = []
        var isOnInk = false

        override var isFlipped: Bool { true }

        override func viewDidChangeEffectiveAppearance() {
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            let width: CGFloat = 8
            let height: CGFloat = 4.5
            let origin = CGPoint(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2)
            let chevron = NSBezierPath()
            chevron.move(to: origin)
            chevron.line(to: CGPoint(x: origin.x + width / 2, y: origin.y + height))
            chevron.line(to: CGPoint(x: origin.x + width, y: origin.y))
            chevron.lineWidth = 1.5
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            // Ink on the canvas, canvas on an ink-filled button.
            let white = isOnInk ? !dark : dark
            NSColor(white: white ? 1 : 0, alpha: isOnInk ? 0.9 : 0.62).setStroke()
            chevron.stroke()
        }

        override func mouseDown(with event: NSEvent) { showMenu() }

        override func accessibilityPerformPress() -> Bool {
            showMenu()
            return true
        }

        private func showMenu() {
            let menu = NSMenu()
            for entry in entries {
                guard let title = entry.title else {
                    menu.addItem(.separator())
                    continue
                }
                let item = NSMenuItem(title: title, action: #selector(MenuTarget.run(_:)), keyEquivalent: "")
                let target = MenuTarget(entry.action)
                item.target = target
                item.representedObject = target
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: CGPoint(x: 0, y: bounds.height + 2), in: self)
        }
    }

    private final class MenuTarget: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func run(_ sender: Any?) { action() }
    }
}
