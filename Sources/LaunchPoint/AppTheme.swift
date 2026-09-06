import SwiftUI

/// Flat palette shared by the selected app icon and in-app controls.
enum AppTheme {
    static let paper = Color(red: 0.949, green: 0.941, blue: 0.918)
    static let charcoal = Color(red: 0.125, green: 0.141, blue: 0.157)
    static let blue = Color(red: 0.204, green: 0.471, blue: 0.965)

    static let panelBackground = paper.opacity(0.97)
    static let secondaryText = charcoal.opacity(0.62)
    static let subtleFill = charcoal.opacity(0.055)
    static let separator = charcoal.opacity(0.12)

    // Settings uses a cooler, layered surface so dense controls remain legible
    // without changing the warmer launchpad palette.
    static let settingsCanvas = Color(red: 0.945, green: 0.953, blue: 0.968)
    static let settingsCard = Color.white.opacity(0.92)
    static let settingsStroke = Color(red: 0.84, green: 0.865, blue: 0.90).opacity(0.95)
    static let settingsShadow = Color.black.opacity(0.10)
    static let settingsBlue = Color(red: 0.18, green: 0.42, blue: 0.95)
    static let settingsLavender = Color(red: 0.47, green: 0.40, blue: 0.92)
    static let settingsMint = Color(red: 0.10, green: 0.62, blue: 0.52)
    static let settingsTeal = Color(red: 0.06, green: 0.54, blue: 0.68)
    static let settingsOrange = Color(red: 0.91, green: 0.49, blue: 0.18)
    static let settingsPink = Color(red: 0.80, green: 0.25, blue: 0.57)
}
