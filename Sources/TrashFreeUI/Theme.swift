import AppKit
import SwiftUI

/// A neutral black-and-white system that follows the system appearance. Ink is alpha
/// black on white (alpha white on near-black in dark mode), so every gray has zero
/// channel spread. The only hues are the map's data colors and the destructive and
/// nearly-full states.
enum Theme {
    static let background = adaptive(light: .white, dark: NSColor(white: 0.075, alpha: 1))
    static let text = ink(light: 0.9, dark: 0.92)
    static let secondaryText = ink(light: 0.62, dark: 0.58)
    /// Metadata that is still read, such as sizes on minor rows; kept above 4.5:1.
    static let tertiaryText = ink(light: 0.5, dark: 0.46)
    static let hairline = ink(light: 0.1, dark: 0.11)
    static let strongBorder = ink(light: 0.18, dark: 0.2)
    static let hoverFill = ink(light: 0.045, dark: 0.07)
    static let pressedFill = ink(light: 0.09, dark: 0.13)
    /// Resting fill for a control that has to read as a button with no border.
    static let controlFill = ink(light: 0.06, dark: 0.1)
    static let track = ink(light: 0.08, dark: 0.12)
    /// The filled primary button: ink on canvas, inverted.
    static let primaryFill = ink(light: 0.88, dark: 0.92)
    static let primaryPressed = ink(light: 0.74, dark: 0.78)
    /// Hover wash for a control; on an ink-filled control it lightens instead.
    static func hoverWash(onInk: Bool) -> Color { onInk ? primaryText.opacity(0.14) : hoverFill }
    static let primaryText = adaptive(light: .white, dark: NSColor(white: 0.075, alpha: 1))
    static let destructive = adaptive(
        light: NSColor(srgbRed: 0.78, green: 0.16, blue: 0.16, alpha: 1),
        dark: NSColor(srgbRed: 1, green: 0.45, blue: 0.42, alpha: 1))
    /// A disk that is nearly full.
    static let warning = destructive

    /// The type scale. SF Pro throughout; weights stay at 400 for reading and 500–600
    /// for labels and titles. Numbers use tabular figures so sizes line up and don't
    /// jitter while a scan or hover updates them.
    enum Font {
        static let pageTitle = SwiftUI.Font.system(size: 20, weight: .semibold)
        static let pageSubtitle = SwiftUI.Font.system(size: 13)
        static let rowTitle = SwiftUI.Font.system(size: 14, weight: .medium)
        static let rowDetail = SwiftUI.Font.system(size: 12).monospacedDigit()
        static let control = SwiftUI.Font.system(size: 13, weight: .medium)
        static let breadcrumb = SwiftUI.Font.system(size: 13)
        static let breadcrumbCurrent = SwiftUI.Font.system(size: 13, weight: .medium)
        static let panelTitle = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let panelSize = SwiftUI.Font.system(size: 26).monospacedDigit()
        static let panelRow = SwiftUI.Font.system(size: 13).monospacedDigit()
        static let panelNote = SwiftUI.Font.system(size: 12)
        static let hint = SwiftUI.Font.system(size: 13)
    }

    /// Height of the title strip. The traffic lights, history buttons, and breadcrumb
    /// share one 52pt band instead of the standard 28pt title bar.
    static let titleBarHeight: CGFloat = 52

    // MARK: Motion

    enum Motion {
        /// Hover and color changes: short enough to never trail the pointer.
        static let hoverIn: TimeInterval = 0.12
        static let hoverOut: TimeInterval = 0.2
        static let hover = Animation.easeOut(duration: 0.15)
        static let press = Animation.easeOut(duration: 0.12)
        /// Content that appears or changes in place (rows, crumbs, panel).
        static let change = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.22)
        static let screen = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.25)
    }

    // MARK: Map colors

    /// Ring-1 colors along the scan root's byte range. Low-chroma tones (fjord, sea
    /// glass, moss, birch, clay, lingonberry, heather) so the map carries the branch
    /// encoding without turning the window into a rainbow.
    private static let ramp: [(Double, Double, Double)] = [
        (0.42, 0.56, 0.69),
        (0.45, 0.65, 0.62),
        (0.55, 0.65, 0.46),
        (0.79, 0.66, 0.40),
        (0.78, 0.53, 0.43),
        (0.69, 0.47, 0.53),
        (0.55, 0.50, 0.68),
    ]

    /// Segment color. Hue follows the node's position around the scan root, so every
    /// folder keeps its color while the user zooms. Deeper rings fade toward the canvas;
    /// `emphasis` (0...1) pulls the color toward the ink for hover.
    static func segment(position: Float, depth: Int, emphasis: Double = 0, scheme: ColorScheme) -> Color {
        let scaled = min(max(Double(position), 0), 1) * Double(ramp.count - 1)
        let index = min(Int(scaled), ramp.count - 2)
        let f = scaled - Double(index)
        let a = ramp[index], b = ramp[index + 1]
        var rgb = (a.0 + (b.0 - a.0) * f, a.1 + (b.1 - a.1) * f, a.2 + (b.2 - a.2) * f)
        let dark = scheme == .dark
        let canvas = dark ? 0.075 : 1.0
        let fade = min(Double(max(depth - 1, 0)) * (dark ? 0.09 : 0.1), dark ? 0.45 : 0.5)
        rgb = mix(rgb, canvas, fade)
        rgb = mix(rgb, dark ? 1 : 0, 0.25 * emphasis)
        return Color(.sRGB, red: rgb.0, green: rgb.1, blue: rgb.2)
    }

    /// "Smaller objects": neutral, so it never reads as another folder.
    static func smallerObjects(emphasis: Double = 0, scheme: ColorScheme) -> Color {
        neutral(scheme == .dark ? 0.22 + 0.12 * emphasis : 0.17 + 0.14 * emphasis, scheme: scheme)
    }

    /// Hidden space is drawn as a neutral fill with darker hatching.
    static func hiddenFill(emphasis: Double = 0, scheme: ColorScheme) -> Color {
        neutral(scheme == .dark ? 0.12 + 0.1 * emphasis : 0.06 + 0.1 * emphasis, scheme: scheme)
    }

    static func hiddenHatch(scheme: ColorScheme) -> Color {
        neutral(scheme == .dark ? 0.42 : 0.36, scheme: scheme)
    }

    /// An opaque gray `amount` of the way from canvas to ink, for map fills that must
    /// not let the separator strokes show through.
    private static func neutral(_ amount: Double, scheme: ColorScheme) -> Color {
        let canvas = scheme == .dark ? 0.075 : 1.0
        let value = canvas + ((scheme == .dark ? 1 : 0) - canvas) * amount
        return Color(.sRGB, red: value, green: value, blue: value)
    }

    private static func mix(_ rgb: (Double, Double, Double), _ target: Double, _ t: Double) -> (Double, Double, Double) {
        (rgb.0 + (target - rgb.0) * t, rgb.1 + (target - rgb.1) * t, rgb.2 + (target - rgb.2) * t)
    }

    // MARK: Helpers

    private static func ink(light: CGFloat, dark: CGFloat) -> Color {
        adaptive(light: NSColor(white: 0, alpha: light), dark: NSColor(white: 1, alpha: dark))
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}
