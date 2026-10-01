#!/usr/bin/env swift
// Regenerates the macOS AppIcon set from the square logo master, clipping the
// four corners to a rounded rectangle and leaving a transparent margin around
// it, following the Apple macOS icon template (824 pt body on a 1024 pt canvas).
//
// Usage: swift scripts/make_app_icon.swift [body-ratio] [corner-radius-ratio]
//   body-ratio:          icon body size / canvas size (default 0.8047 = 824/1024;
//                        use 1.0 for no margin)
//   corner-radius-ratio: corner radius / icon body size (default 0.2237)

import AppKit
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = root.appendingPathComponent("Design/Logo/beaver-logo-head-only.png")
let outputDir = root.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset")
let arguments = Array(CommandLine.arguments.dropFirst())
let bodyRatio = arguments.first.flatMap(Double.init) ?? 824.0 / 1024.0
let radiusRatio = arguments.dropFirst().first.flatMap(Double.init) ?? 0.2237

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

func render(size: Int) -> Data {
    let dimension = CGFloat(size)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("Cannot create context") }

    let bodySize = dimension * bodyRatio
    let inset = (dimension - bodySize) / 2
    let rect = CGRect(x: inset, y: inset, width: bodySize, height: bodySize)
    let radius = bodySize * radiusRatio
    context.interpolationQuality = .high
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.clip()
    context.draw(cgImage, in: rect)

    guard let output = context.makeImage(),
          let png = NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:]) else {
        fatalError("Cannot encode PNG")
    }
    return png
}

for (name, size) in pixelSizes.sorted(by: { $0.key < $1.key }) {
    try render(size: size).write(to: outputDir.appendingPathComponent(name))
    print("wrote \(name) (\(size)x\(size))")
}
