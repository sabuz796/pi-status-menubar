// Renders the app icon from images/app-icon.svg into a macOS .iconset.
//
// The SVG is the single source of truth. Nothing binary is checked in: the
// .icns is regenerated on every build.
//
// The artwork is clipped to the macOS icon shape, a superellipse with exponent
// 5, which is the standard approximation of the Big Sur and later squircle. A
// sharp-cornered square reads as broken next to every system app, so the shape
// is applied here rather than left to the artwork.
//
// Usage: AppIcon <source.svg> <output.iconset>

import Cocoa

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: AppIcon <source.svg> <output.iconset>\n".utf8))
    exit(2)
}
let sourcePath = arguments[1]
let outputPath = arguments[2]

// The sizes macOS expects in an .iconset. Each entry is the pixel size of the
// file and the logical size it represents.
let variants: [(name: String, pixels: Int, points: Int)] = [
    ("icon_16x16.png", 16, 16),
    ("icon_16x16@2x.png", 32, 16),
    ("icon_32x32.png", 32, 32),
    ("icon_32x32@2x.png", 64, 32),
    ("icon_128x128.png", 128, 128),
    ("icon_128x128@2x.png", 256, 128),
    ("icon_256x256.png", 256, 256),
    ("icon_256x256@2x.png", 512, 256),
    ("icon_512x512.png", 512, 512),
    ("icon_512x512@2x.png", 1024, 512),
]

// The macOS icon shape: a superellipse |x/a|^n + |y/a|^n = 1 with n = 5.
// A radius of 22.37% of the shape size matches the system's own icons.
let exponent = 5.0
let radiusFraction = 0.2237

func superellipsePath(in rect: NSRect) -> NSBezierPath {
    let path = NSBezierPath()
    let a = rect.width / 2
    let center = NSPoint(x: rect.midX, y: rect.midY)
    let steps = 1440
    let power = 2.0 / exponent
    for step in 0...steps {
        let t = Double(step) / Double(steps) * 2 * Double.pi
        let cosT = cos(t), sinT = sin(t)
        let x = center.x + a * copysign(pow(abs(cosT), power), cosT)
        let y = center.y + a * copysign(pow(abs(sinT), power), sinT)
        if step == 0 {
            path.move(to: NSPoint(x: x, y: y))
        } else {
            path.line(to: NSPoint(x: x, y: y))
        }
    }
    path.close()
    return path
}

guard let artwork = NSImage(contentsOfFile: sourcePath) else {
    FileHandle.standardError.write(Data("AppIcon: cannot read \(sourcePath)\n".utf8))
    exit(1)
}

let fm = FileManager.default
try? fm.removeItem(atPath: outputPath)
try! fm.createDirectory(atPath: outputPath, withIntermediateDirectories: true)

for variant in variants {
    let pixels = variant.pixels
    guard let context = CGContext(data: nil,
                                   width: pixels,
                                   height: pixels,
                                   bitsPerComponent: 8,
                                   bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        FileHandle.standardError.write(Data("AppIcon: no bitmap context\n".utf8))
        exit(1)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

    // Clip to the icon shape, then paint the artwork into the clipped area.
    let bounds = NSRect(x: 0, y: 0, width: pixels, height: pixels)
    let shape = superellipsePath(in: bounds.insetBy(dx: 0, dy: 0))
    shape.addClip()
    artwork.draw(in: bounds)

    NSGraphicsContext.restoreGraphicsState()

    guard let image = context.makeImage() else {
        FileHandle.standardError.write(Data("AppIcon: cannot make image\n".utf8))
        exit(1)
    }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: variant.points, height: variant.points)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("AppIcon: cannot encode \(variant.name)\n".utf8))
        exit(1)
    }
    try! data.write(to: URL(fileURLWithPath: outputPath).appendingPathComponent(variant.name))
}

print("AppIcon: wrote \(variants.count) sizes to \(outputPath)")
