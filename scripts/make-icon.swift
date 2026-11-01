// Builds scripts/icon/AppIcon.icns from scripts/icon/icon-source.png.
//
// Usage: swift scripts/make-icon.swift
//
// The source art is a rounded square on a black, alpha-less background that fills nearly the whole
// canvas. This crops to the square, clips it to a rounded rectangle so the corners are transparent,
// and scales it onto the standard macOS icon grid (an 824 px body centred on a 1024 px canvas).

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconDir = root.appendingPathComponent("scripts/icon")
let sourceURL = iconDir.appendingPathComponent("icon-source.png")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

guard let src = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let source = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("Can't read \(sourceURL.path)") }

// MARK: Find the square: the bounding box of everything that isn't near-black.

let w = source.width, h = source.height
let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
var pixels = [UInt8](repeating: 0, count: w * h * 4)
pixels.withUnsafeMutableBytes { buf in
    let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
}
var minX = w, minY = h, maxX = -1, maxY = -1
for y in 0..<h {
    for x in 0..<w {
        let i = (y * w + x) * 4
        if Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) > 36 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
}
guard maxX > minX, maxY > minY else { fail("No artwork found in the source image") }
// Inset a little so the anti-aliased dark fringe along the straight edges is cut away.
let inset = 4
let side = min(maxX - minX, maxY - minY) - 2 * inset
let cropRect = CGRect(x: minX + inset, y: minY + inset, width: side, height: side)
guard let square = source.cropping(to: cropRect) else { fail("Crop failed") }
print("square: \(side) px at (\(minX + inset), \(minY + inset)) in a \(w)×\(h) source")

// MARK: Render the icon at any size.

/// Body is 824/1024 of the canvas; corner radius is 22.5% of the body, as in Apple's icon grid.
/// That radius is larger than the source's own corners, so no black survives the clip.
func render(_ size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: rgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let s = CGFloat(size)
    let body = s * 824 / 1024
    let rect = CGRect(x: (s - body) / 2, y: (s - body) / 2, width: body, height: body)
    let radius = body * 0.225
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    ctx.draw(square, in: rect)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("Can't write \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fail("Can't write \(url.path)") }
}

// MARK: Iconset → .icns

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    writePNG(render(points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    writePNG(render(points * 2), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
writePNG(render(512), to: iconDir.appendingPathComponent("icon-512.png"))

let icns = iconDir.appendingPathComponent("AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try! iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fail("iconutil failed") }
print("✓ \(icns.path)")
print("  previews: \(iconset.path)")
