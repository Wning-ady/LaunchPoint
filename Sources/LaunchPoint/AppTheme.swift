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
}
