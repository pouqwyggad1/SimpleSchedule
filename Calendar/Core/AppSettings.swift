import Observation
import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Как в системе"
        case .light: "Светлая"
        case .dark: "Темная"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// App Sandbox redirects the standard preferences domain to this app's container.
@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    private var storedBackgroundOpacity: Double

    /// Opacity of the backing surface, never of its foreground controls or text.
    var backgroundOpacity: Double {
        get { storedBackgroundOpacity }
        set {
            let value = Self.clampedOpacity(newValue)
            storedBackgroundOpacity = value
            defaults.set(value, forKey: "appearance.backgroundOpacity")
        }
    }

    var theme: AppTheme {
        didSet {
            defaults.set(theme.rawValue, forKey: "appearance.theme")
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: "appearance.backgroundOpacity") != nil {
            storedBackgroundOpacity = Self.clampedOpacity(defaults.double(forKey: "appearance.backgroundOpacity"))
        } else {
            storedBackgroundOpacity = 0.3
        }
        theme = AppTheme(rawValue: defaults.string(forKey: "appearance.theme") ?? "") ?? .system
    }

    private static func clampedOpacity(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0.05, value)) : 0.3
    }
}
