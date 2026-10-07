// Run from the repository root: swift design/generate-app-icon.swift
import AppKit
import Foundation

let designDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let assetDirectory = designDirectory.deletingLastPathComponent()
    .appendingPathComponent("barNoticer/Assets.xcassets/AppIcon.appiconset")
let sourceURL = designDirectory.appendingPathComponent("barNoticer-icon.svg")
guard let source = NSImage(contentsOf: sourceURL),
      let sourceBitmap = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("Cannot render SVG at \(sourceURL.path)")
}

func png(size: Int) throws -> Data {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size * 4, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("Cannot create icon bitmap")
    }
    context.interpolationQuality = .high
    context.draw(sourceBitmap, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let image = context.makeImage(),
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        fatalError("Cannot encode icon PNG")
    }
    return data
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try png(size: points * scale).write(to: assetDirectory.appendingPathComponent(filename))
        images.append(["filename": filename, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}
let manifest: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    .write(to: assetDirectory.appendingPathComponent("Contents.json"))
try png(size: 512).write(to: designDirectory.appendingPathComponent("barNoticer-icon-preview.png"))
print("Generated 10 macOS icon assets from \(sourceURL.lastPathComponent)")
