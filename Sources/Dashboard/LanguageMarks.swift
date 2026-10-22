import Cocoa

// Real language marks, bundled as vector SVG from simple-icons (CC0 1.0, public
// domain). AppKit rasterises SVG through its own image rep, so these stay crisp
// at any size and cost about a kilobyte each.
//
// Each mark is tinted to its brand colour. On a dark panel a brand that is
// nearly black would disappear, so those are blended toward white until their
// luminance clears a floor. The hue survives and the glyph stays visible.
enum LanguageMarks {
    struct Mark {
        let asset: String
        let image: NSImage
        let color: NSColor
    }

    // Anything missing here falls back to the caller's SF Symbol, so an unknown
    // language still gets a sensible icon.
    private static let assetFor: [String: String] = [
        "typescript": "typescript",
        "javascript": "javascript",
        "python": "python",
        "swift": "swift",
        "markdown": "markdown",
        "json": "json",
        "css": "css",
        "yaml": "yaml",
        "shell": "shell",
        "html": "html",
        "toml": "toml",
        "ruby": "ruby",
        "rust": "rust",
        "go": "go",
        "c": "c",
        "c++": "cpp",
        "java": "java",
        "xml": "xml",
    ]

    private static var loadCache: [String: Mark] = [:]
    private static var tintCache: [String: NSImage] = [:]

    static func assetName(for language: String) -> String? { assetFor[language.lowercased()] }

    static func mark(for language: String) -> Mark? {
        guard let asset = assetFor[language.lowercased()] else { return nil }
        if let cached = loadCache[asset] { return cached }
        guard let url = assetURL(asset),
              let image = NSImage(contentsOf: url) else { return nil }
        let mark = Mark(asset: asset, image: image, color: brandColor(at: url) ?? .labelColor)
        loadCache[asset] = mark
        return mark
    }

    // The bundled copy is the shipping path. The working-directory copy exists so
    // the offscreen render harness, which is not an app bundle, sees the same
    // marks during development. A launched app has a different working directory,
    // so it never picks that one up.
    private static func assetURL(_ asset: String) -> URL? {
        if let bundled = Bundle.main.url(forResource: asset, withExtension: "svg", subdirectory: "languages") {
            return bundled
        }
        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("images/languages/\(asset).svg")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    // The fill is baked into the bundled file, so read it back rather than keep a
    // second table of brand colours that could drift from the assets.
    private static func brandColor(at url: URL) -> NSColor? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let key = text.range(of: "fill=\"#"),
              let end = text[key.upperBound...].firstIndex(of: "\"") else { return nil }
        let hex = String(text[key.upperBound..<end])
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255,
                       alpha: 1)
    }

    static func tinted(_ mark: Mark, dark: Bool, size: CGFloat) -> NSImage {
        let key = "\(mark.asset)-\(dark)-\(Int(size))"
        if let cached = tintCache[key] { return cached }
        let color = dark ? lightened(mark.color) : mark.color
        let out = NSImage(size: NSSize(width: size, height: size))
        out.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        mark.image.draw(in: rect)
        color.set()
        rect.fill(using: .sourceIn)
        out.unlockFocus()
        tintCache[key] = out
        return out
    }

    private static func luminance(_ color: NSColor) -> CGFloat {
        let c = color.usingColorSpace(.sRGB) ?? color
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }

    private static func lightened(_ color: NSColor, floor: CGFloat = 0.42) -> NSColor {
        var c = color.usingColorSpace(.sRGB) ?? color
        var steps = 0
        while luminance(c) < floor && steps < 12 {
            c = NSColor(srgbRed: c.redComponent + (1 - c.redComponent) * 0.22,
                        green: c.greenComponent + (1 - c.greenComponent) * 0.22,
                        blue: c.blueComponent + (1 - c.blueComponent) * 0.22,
                        alpha: 1)
            steps += 1
        }
        return c
    }
}
