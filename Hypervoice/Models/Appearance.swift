import AppKit
import SwiftUI

extension Pref {
    static let theme = "appearance.theme"
    static let accent = "appearance.accent"
    static let darkness = "appearance.darkness"
    static let darkSidebar = "appearance.darkSidebar"
    static let textSize = "appearance.textSize"

    /// How dark dark mode goes: 0 is the system's grays, 1 is true black.
    static let defaultDarkness = 1.0
    /// The editors' body size; Script and Transcribe are a step smaller.
    static let defaultTextSize: Double = 17

    /// Back to how the app looks out of the box.
    static func resetAppearance() {
        for key in [theme, accent, darkness, darkSidebar, textSize] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

enum Theme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// The accent swatches macOS itself offers, plus following the system's choice.
enum AccentChoice: String, CaseIterable, Identifiable {
    case system, blue, purple, pink, red, orange, yellow, green, graphite
    var id: String { rawValue }
    var label: String { self == .system ? "System" : rawValue.capitalized }

    /// Nil follows the accent color set in System Settings.
    var color: Color? {
        switch self {
        case .system: nil
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .graphite: .gray
        }
    }
}

extension Color {
    /// The page every pane sits on: white in light mode; in dark mode, from the system's near-black (#1E1E1E)
    /// down to true black as `darkness` goes from 0 to 1.
    static func page(darkness: Double) -> Color {
        dynamic(light: .textBackgroundColor, dark: NSColor(white: pageWhite(darkness: darkness), alpha: 1))
    }

    /// The sidebar when it's darkened too: clear in light mode (the native material shows through), and in
    /// dark mode from the system's sidebar gray down to #0D0D0D, a step above the black page so the two stay apart.
    static func sidebar(darkness: Double) -> Color {
        dynamic(light: .clear, dark: NSColor(white: sidebarWhite(darkness: darkness), alpha: 1))
    }

    static func pageWhite(darkness: Double) -> Double { 0.118 * (1 - darkness) }
    static func sidebarWhite(darkness: Double) -> Double { 0.05 + 0.115 * (1 - darkness) }

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

extension EnvironmentValues {
    /// The editors' body size; captions and smaller text scale from it.
    @Entry var textSize: CGFloat = Pref.defaultTextSize
}

/// Applies the chosen theme to the whole app (windows, menus, sheets) and the accent as tint.
struct AppAppearance: ViewModifier {
    @AppStorage(Pref.theme) private var theme = Theme.system
    @AppStorage(Pref.accent) private var accent = AccentChoice.system
    @AppStorage(Pref.textSize) private var textSize = Pref.defaultTextSize

    func body(content: Content) -> some View {
        content
            .tint(accent.color)
            .environment(\.textSize, textSize)
            .onChange(of: theme, initial: true) { NSApp.appearance = theme.appearance }
    }
}

/// Puts a pane on the page color, toolbar strip included: the toolbar's own gray would band the top of a
/// darkened page, so it takes the page's color. Opaque, not hidden, so content can't scroll up behind the title.
struct PageBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(Pref.darkness) private var darkness = Pref.defaultDarkness

    func body(content: Content) -> some View {
        content
            .background(Color.page(darkness: darkness))
            .toolbarBackground(Color.page(darkness: darkness), for: .windowToolbar)
            .toolbarBackgroundVisibility(colorScheme == .dark && darkness > 0 ? .visible : .automatic, for: .windowToolbar)
    }
}

/// With "Darken the sidebar too" on, the sidebar follows the darkness slider in dark mode.
/// Off, it keeps the system's translucent material.
struct SidebarDarkening: ViewModifier {
    @AppStorage(Pref.darkness) private var darkness = Pref.defaultDarkness
    @AppStorage(Pref.darkSidebar) private var darkSidebar = false

    func body(content: Content) -> some View {
        if darkSidebar {
            content
                .scrollContentBackground(.hidden)
                .background(Color.sidebar(darkness: darkness))
        } else {
            content
        }
    }
}
