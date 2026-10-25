#!/usr/bin/env swift
// Regenerates AppIcon from the approved A1-v2 square artwork, retaining its
// sage-teal background and lower-left emergence composition. Seasonal outfits
// never replace Finder's icon. The rounded body keeps macOS's outer margin.
//
// Usage: swift -module-cache-path /tmp/beavermeter-brand-cache scripts/make_app_icon.swift [body-ratio] [corner-radius-ratio]
//   body-ratio: icon body size / canvas size (default 824/1024)
//   corner-radius-ratio: corner radius / icon body size (default 0.2237)

import AppKit
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = root.appendingPathComponent("Design/Logo/beaver-app-icon.png")
let outputDir = root.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset")
let arguments = Array(CommandLine.arguments.dropFirst())
let bodyRatio = arguments.first.flatMap(Double.init) ?? 824.0 / 1024.0
let radiusRatio = arguments.dropFirst().first.flatMap(Double.init) ?? 0.2237
precondition((0.5...1).contains(bodyRatio), "Body ratio must be between 0.5 and 1")
precondition((0...0.5).contains(radiusRatio), "Corner radius ratio must be between 0 and 0.5")

let pixelSizes: [String: Int] = [
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
]

guard let image = NSImage(contentsOf: source),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("Cannot read \(source.path)")
}
precondition(cgImage.width == cgImage.height, "AppIcon artwork must use a square canvas")

func render(size: Int) -> Data {
    let dimension = CGFloat(size)
    guard let context = CGContext(data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("Cannot create context")
    }
    let bodySize = dimension * bodyRatio
    let inset = (dimension - bodySize) / 2
    let rect = CGRect(x: inset, y: inset, width: bodySize, height: bodySize)
    let body = CGPath(roundedRect: rect, cornerWidth: bodySize * radiusRatio,
                      cornerHeight: bodySize * radiusRatio, transform: nil)
    context.interpolationQuality = .high
    context.addPath(body)
    context.clip()
    // Fit the full approved square, without alpha cropping, additional
    // gradients, or a separate plate underneath the character.
    context.draw(cgImage, in: rect)
    guard let output = context.makeImage(),
          let png = NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:]) else {
        fatalError("Cannot encode PNG")
    }
    return png
}

try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
for (name, size) in pixelSizes.sorted(by: { $0.key < $1.key }) {
    try render(size: size).write(to: outputDir.appendingPathComponent(name))
    print("wrote \(name) (\(size)x\(size))")
}
