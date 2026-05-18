import SwiftUI

/// Persisted app-level preferences. Reading code uses `@AppStorage` directly
/// at the point of use; this enum just holds the keys, defaults, and the
/// strongly-typed enums backing each value so the keys stay consistent.
enum AppSettings {
    static let appearanceKey = "app.appearance"
    static let accentColorKey = "app.accentColor"
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum AppAccent: String, CaseIterable, Identifiable {
    case blue, indigo, purple, pink, red, orange, yellow, green, teal, mint, brown, gray
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .blue: return .blue
        case .indigo: return .indigo
        case .purple: return .purple
        case .pink: return .pink
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .teal: return .teal
        case .mint: return .mint
        case .brown: return .brown
        case .gray: return .gray
        }
    }
    var label: String { rawValue.capitalized }
}
