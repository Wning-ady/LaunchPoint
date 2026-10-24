import AppKit
import Foundation
import ImageIO

/// Verifies that an opaque square app icon gets a rounded mask while an icon
/// that already has transparent corners keeps those corners transparent.
@main
struct IconNormalizationFixture {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("LaunchPointIconFixture-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let opaqueApp = try makeApp(root: root, name: "Opaque", rounded: false)
        let roundedApp = try makeApp(root: root, name: "Rounded", rounded: true)
        let paddedApp = try makeApp(root: root, name: "Padded", rounded: false, inset: 24)
        let blankResourceApp = try makeApp(root: root, name: "BlankResource",
                                           rounded: false, blankResource: true)
        let scanned = AppScanner.scan(sources: [root.path])
        guard let opaque = scanned.first(where: { $0.url == opaqueApp }),
              let rounded = scanned.first(where: { $0.url == roundedApp }),
              let padded = scanned.first(where: { $0.url == paddedApp }),
              let blankResource = scanned.first(where: { $0.url == blankResourceApp }) else {
            throw FixtureError("Fixture apps were not discovered")
        }

        let opaqueCorners = alphaSamples(of: opaque.icon)
        let roundedCorners = alphaSamples(of: rounded.icon)
        let paddedCorners = alphaSamples(of: padded.icon)
        let opaqueNearCorners = nearCornerSamples(of: opaque.icon)
        try require(opaqueCorners.allSatisfy { $0 < 32 },
                    "Opaque square icon was not rounded: \(opaqueCorners)")
        try require(opaqueNearCorners.allSatisfy { $0 < 32 },
                    "Opaque square icon still has visible near-corner pixels: \(opaqueNearCorners)")
        try require(roundedCorners.allSatisfy { $0 < 32 },
                    "Existing rounded icon lost transparent corners: \(roundedCorners)")
        try require(paddedCorners.allSatisfy { $0 < 32 },
                    "Padded square icon was not rounded: \(paddedCorners)")
        try require(hasVisiblePixels(blankResource.icon),
                    "Blank declared resource did not fall back to a visible icon")
        print("PASS opaque-square-rounded=true padded-square-rounded=true transparent-corners-preserved=true blank-resource-fallback=true")
    }

    private static func makeApp(root: URL, name: String, rounded: Bool,
                                inset: Int = 0, blankResource: Bool = false) throws -> URL {
        let fm = FileManager.default
        let app = root.appendingPathComponent("\(name).app", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try Data().write(to: macOS.appendingPathComponent(name))

        let plist: NSDictionary = [
            "CFBundleIdentifier": "com.waning.launchpoint.fixture.\(name.lowercased())",
            "CFBundleName": name,
            "CFBundleExecutable": name,
            "CFBundlePackageType": "APPL",
            "CFBundleIconFile": "Icon.png",
        ]
        guard plist.write(to: app.appendingPathComponent("Contents/Info.plist"),
                          atomically: true) else {
            throw FixtureError("Unable to write \(name) Info.plist")
        }

        let side = 256
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                      width: side,
                                      height: side,
                                      bitsPerComponent: 8,
                                      bytesPerRow: side * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw FixtureError("Unable to create fixture image context") }
        context.setFillColor(blankResource ? NSColor.clear.cgColor : NSColor.systemGreen.cgColor)
        let artworkRect = CGRect(x: inset, y: inset,
                                 width: side - inset * 2,
                                 height: side - inset * 2)
        if rounded {
            context.addPath(CGPath(roundedRect: artworkRect,
                                   cornerWidth: 44,
                                   cornerHeight: 44,
                                   transform: nil))
            context.fillPath()
        } else {
            context.fill(artworkRect)
        }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                resources.appendingPathComponent("Icon.png") as CFURL,
                "public.png" as CFString,
                1,
                nil
              ) else { throw FixtureError("Unable to create fixture icon") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError("Unable to finalize fixture icon")
        }
        return app
    }

    private static func alphaSamples(of image: NSImage) -> [UInt8] {
        var rect = NSRect(x: 0, y: 0, width: 160, height: 160)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let provider = cgImage.dataProvider,
              let data = provider.data,
              let bytes = CFDataGetBytePtr(data) else { return [255] }
        let side = cgImage.width
        let info = cgImage.alphaInfo
        let alphaIndex = info == .first || info == .premultipliedFirst ? 0 : 3
        let points = [(0, 0), (side - 1, 0), (0, side - 1), (side - 1, side - 1)]
        return points.map { x, y in bytes[(y * cgImage.bytesPerRow) + x * 4 + alphaIndex] }
    }

    private static func nearCornerSamples(of image: NSImage) -> [UInt8] {
        var rect = NSRect(x: 0, y: 0, width: 160, height: 160)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let provider = cgImage.dataProvider,
              let data = provider.data,
              let bytes = CFDataGetBytePtr(data) else { return [255] }
        let side = cgImage.width
        let info = cgImage.alphaInfo
        let alphaIndex = info == .first || info == .premultipliedFirst ? 0 : 3
        let points = [(16, 16), (24, 16), (16, 24), (24, 24),
                      (side - 25, 16), (side - 17, 16),
                      (16, side - 25), (16, side - 17)]
        return points.map { x, y in bytes[(y * cgImage.bytesPerRow) + x * 4 + alphaIndex] }
    }

    private static func hasVisiblePixels(_ image: NSImage) -> Bool {
        var rect = NSRect(x: 0, y: 0, width: 64, height: 64)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let provider = cgImage.dataProvider,
              let data = provider.data,
              let bytes = CFDataGetBytePtr(data) else { return false }
        let info = cgImage.alphaInfo
        let alphaIndex = info == .first || info == .premultipliedFirst ? 0 : 3
        for y in 0..<cgImage.height {
            for x in 0..<cgImage.width {
                if bytes[y * cgImage.bytesPerRow + x * 4 + alphaIndex] >= 8 { return true }
            }
        }
        return false
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw FixtureError(message) }
    }

    private struct FixtureError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
