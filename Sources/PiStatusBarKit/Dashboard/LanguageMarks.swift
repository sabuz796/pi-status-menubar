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

    // One table per language: its bundled vector mark if there is one, and
    // the SF Symbol every caller falls back to. Keys are lowercased language
    // names as languageName(forExtension:) produces them. Anything missing
    // gets the generic "doc".
    private static let iconFor: [String: (asset: String?, symbol: String)] = [
        "typescript": ("typescript", "curlybraces"),
        "javascript": ("javascript", "curlybraces"),
        "json": ("json", "curlybraces"),
        "markdown": ("markdown", "doc.text"),
        "css": ("css", "paintbrush"),
        "shell": ("shell", "terminal"),
        "yaml": ("yaml", "list.bullet.rectangle"),
        "toml": ("toml", "list.bullet.rectangle"),
        "xml": ("xml", "list.bullet.rectangle"),
        "python": ("python", "chevron.left.forwardslash.chevron.right"),
        "swift": ("swift", "chevron.left.forwardslash.chevron.right"),
        "html": ("html", "chevron.left.forwardslash.chevron.right"),
        "c": ("c", "chevron.left.forwardslash.chevron.right"),
        "c++": ("cpp", "chevron.left.forwardslash.chevron.right"),
        "rust": ("rust", "chevron.left.forwardslash.chevron.right"),
        "go": ("go", "chevron.left.forwardslash.chevron.right"),
        "java": ("java", "chevron.left.forwardslash.chevron.right"),
        "ruby": ("ruby", "chevron.left.forwardslash.chevron.right"),
        "sql": (asset: nil, symbol: "cylinder"),
        "text": (asset: nil, symbol: "doc.plaintext"),
    ]

    private static var loadCache: [String: Mark] = [:]
    private static var tintCache: [String: NSImage] = [:]

    static func symbol(for language: String) -> String {
        iconFor[language.lowercased()]?.symbol ?? "doc"
    }

    static func mark(for language: String) -> Mark? {
        guard let entry = iconFor[language.lowercased()], let asset = entry.asset else { return nil }
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
