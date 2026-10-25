#!/usr/bin/env swift
// Exports color mascot masters and the hand-drawn Classic Beaver outline SVG as menu templates.
// Run from any directory:
// swift -module-cache-path /tmp/beavermeter-brand-cache scripts/make_brand_assets.swift

import AppKit
import CoreGraphics
import Foundation
import WebKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let masters = root.appendingPathComponent("Design/Logo")
let output = root.appendingPathComponent("Design/BrandAssets")
let variants: [(id: String, title: String, subtitle: String)] = [
    ("standard", "Classic Beaver", "EVERY DAY"),
    ("newYear", "New Year", "JAN 1"),
    ("lunarNewYear", "Lunar New Year", "NEW YEAR'S EVE – DAY 7"),
    ("lanternFestival", "Lantern Festival", "LUNAR JAN 15"),
    ("dragonBoat", "Dragon Boat", "LUNAR MAY 5"),
    ("midAutumn", "Mid-Autumn", "LUNAR AUG 15"),
    ("programmerDay", "Programmers' Day", "OCT 24 · 1024"),
    ("halloween", "Halloween", "OCT 31"),
    ("christmas", "Christmas", "DEC 24 – 26")
]

func context(width: Int, height: Int) -> CGContext {
    guard let result = CGContext(data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("Cannot allocate bitmap \(width)×\(height)")
    }
    result.interpolationQuality = .high
    result.setAllowsAntialiasing(true)
    return result
}

func write(_ context: CGContext, to url: URL) throws {
    guard let image = context.makeImage(), let png = NSBitmapImageRep(cgImage: image)
        .representation(using: .png, properties: [:]) else { fatalError("Cannot encode \(url.path)") }
    try png.write(to: url, options: .atomic)
}

func read(_ id: String) -> CGImage {
    let url = masters.appendingPathComponent("beaver-\(id).png")
    guard let image = NSImage(contentsOf: url),
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fatalError("Cannot open master \(url.path)")
    }
    return cg
}

// Bounds are measured from real alpha, never from the colour of the artwork.
func alphaBounds(_ image: CGImage) -> CGRect {
    let canvas = context(width: image.width, height: image.height)
    canvas.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = canvas.data!.assumingMemoryBound(to: UInt8.self)
    var minX = image.width, minY = image.height, maxX = -1, maxY = -1
    for y in 0..<image.height {
        for x in 0..<image.width where bytes[y * canvas.bytesPerRow + x * 4 + 3] > 8 {
            minX = min(minX, x); minY = min(minY, y)
            maxX = max(maxX, x); maxY = max(maxY, y)
        }
    }
    guard maxX >= minX, maxY >= minY else { fatalError("Empty master") }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

func aspectFit(_ source: CGSize, in rect: CGRect) -> CGRect {
    let scale = min(rect.width / source.width, rect.height / source.height)
    let size = CGSize(width: source.width * scale, height: source.height * scale)
    return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
        width: size.width, height: size.height)
}

func rounded(_ context: CGContext, _ rect: CGRect, radius: CGFloat) {
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.fillPath()
}

func text(_ text: String, in rect: CGRect, size: CGFloat, weight: NSFont.Weight,
          colour: NSColor, alignment: NSTextAlignment = .center) {
    let paragraph = NSMutableParagraphStyle(); paragraph.alignment = alignment
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: colour, .paragraphStyle: paragraph
    ]
    (text as NSString).draw(in: rect, withAttributes: attributes)
}

// A large SVG rendering keeps the specimen sharp; native-size examples use the
// exact packaged mask. This sheet changes only when the menu artwork changes.
func exportMenuStudy(mask: CGImage, outline: CGImage) throws {
    let sheet = context(width: 1248, height: 592)
    sheet.setFillColor(NSColor(white: 0.87, alpha: 1).cgColor)
    sheet.fill(CGRect(x: 0, y: 0, width: 1248, height: 592))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: sheet, flipped: false)
    defer { NSGraphicsContext.restoreGraphicsState() }
    let classic = NSImage(contentsOf: output.appendingPathComponent("beaver-standard.png"))!
        .cgImage(forProposedRect: nil, context: nil, hints: nil)!
    for (index, title) in ["Classic Beaver", "Light outline", "Dark outline"].enumerated() {
        let x = CGFloat(48 + index * 392)
        let dark = index == 2
        let ink = NSColor(white: dark ? 1 : 0.12, alpha: 1)
        sheet.setFillColor((index == 0 ? NSColor(srgbRed: 0.97, green: 0.95, blue: 0.91, alpha: 1)
                            : NSColor(white: dark ? 0.12 : 0.98, alpha: 1)).cgColor)
        rounded(sheet, CGRect(x: x, y: 48, width: 368, height: 496), radius: 36)
        text(title, in: CGRect(x: x, y: 432, width: 368, height: 40), size: 28, weight: .semibold, colour: ink)
        func tinted(_ image: CGImage) -> CGImage {
            guard dark else { return image }
            let canvas = context(width: image.width, height: image.height)
            let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            canvas.draw(image, in: rect)
            canvas.setBlendMode(.sourceIn)
            canvas.setFillColor(ink.cgColor); canvas.fill(rect)
            return canvas.makeImage()!
        }
        sheet.draw(index == 0 ? classic : tinted(outline), in: CGRect(x: x + 84, y: 210, width: 200, height: 200))
        if index == 0 {
            text("Original character", in: CGRect(x: x, y: 86, width: 368, height: 34), size: 22, weight: .regular, colour: ink)
        } else {
            let image = tinted(mask)
            sheet.draw(image, in: CGRect(x: x + 92, y: 140, width: 36, height: 36))
            sheet.draw(image, in: CGRect(x: x + 238, y: 122, width: 72, height: 72))
            text("18 pt", in: CGRect(x: x + 40, y: 66, width: 140, height: 32), size: 22, weight: .regular, colour: ink)
            text("2× detail", in: CGRect(x: x + 202, y: 66, width: 140, height: 32), size: 22, weight: .regular, colour: ink)
        }
    }
    let directory = root.appendingPathComponent("screenshots")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try write(sheet, to: directory.appendingPathComponent("menu-bar-logo-study.png"))
}

func exportColorArtwork() throws {
    let images = variants.map { read($0.id) }
    let masterSize = images[0].width
    precondition(masterSize > 0 && images.allSatisfy { $0.width == masterSize && $0.height == masterSize },
                 "All masters must use the same square canvas to retain their face scale")
    // Keep the complete master canvas: never crop or fit individual accessory
    // bounds. Every outfit has the same scale and a 16px runtime safety inset.
    let masterScale: CGFloat = 480 / CGFloat(masterSize)
    let frame = CGRect(x: 16, y: 16, width: 480, height: 480)

    for (index, variant) in variants.enumerated() {
        let canvas = context(width: 512, height: 512)
        let bounds = alphaBounds(images[index])
        let visible = CGRect(x: frame.minX + bounds.minX * masterScale,
                             y: frame.minY + bounds.minY * masterScale,
                             width: bounds.width * masterScale, height: bounds.height * masterScale)
        precondition(CGRect(x: 4, y: 4, width: 504, height: 504).contains(visible),
                     "Artwork exceeds safe export bounds: \(variant.id)")
        canvas.draw(images[index], in: frame)
        try write(canvas, to: output.appendingPathComponent("beaver-\(variant.id).png"))
        print("Exported \(variant.id): 512px colour")
    }

    let gallery = context(width: 1800, height: 1830)
    gallery.setFillColor(NSColor(srgbRed: 0.963, green: 0.945, blue: 0.912, alpha: 1).cgColor)
    gallery.fill(CGRect(x: 0, y: 0, width: 1800, height: 1830))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: gallery, flipped: false)
    text("BEAVERMETER", in: CGRect(x: 80, y: 1715, width: 1640, height: 40), size: 28,
         weight: .semibold, colour: NSColor(srgbRed: 0.46, green: 0.32, blue: 0.23, alpha: 1))
    text("A little change with the season.", in: CGRect(x: 80, y: 1644, width: 1640, height: 65),
         size: 46, weight: .semibold, colour: NSColor(srgbRed: 0.20, green: 0.18, blue: 0.15, alpha: 1))

    for (index, variant) in variants.enumerated() {
        let x = CGFloat(index % 3) * 540 + 90
        let y = 1080 - CGFloat(index / 3) * 490
        let card = CGRect(x: x, y: y, width: 540, height: 466)
        gallery.setFillColor(NSColor(srgbRed: 0.989, green: 0.978, blue: 0.958, alpha: 1).cgColor)
        rounded(gallery, card.insetBy(dx: 12, dy: 8), radius: 28)
        let logo = NSImage(contentsOf: output.appendingPathComponent("beaver-\(variant.id).png"))!
            .cgImage(forProposedRect: nil, context: nil, hints: nil)!
        gallery.draw(logo, in: aspectFit(CGSize(width: 512, height: 512),
            in: CGRect(x: x + 110, y: y + 135, width: 320, height: 308)))
        text(variant.title, in: CGRect(x: x + 15, y: y + 68, width: 510, height: 42),
             size: 30, weight: .semibold, colour: NSColor(srgbRed: 0.23, green: 0.20, blue: 0.17, alpha: 1))
        text(variant.subtitle, in: CGRect(x: x + 15, y: y + 32, width: 510, height: 28),
             size: 18, weight: .medium, colour: NSColor(srgbRed: 0.53, green: 0.47, blue: 0.40, alpha: 1))
    }
    text("ONE BEAVER. NINE EDITIONS.", in: CGRect(x: 100, y: 35, width: 1600, height: 30),
         size: 18, weight: .medium, colour: NSColor(srgbRed: 0.53, green: 0.47, blue: 0.40, alpha: 1))
    NSGraphicsContext.restoreGraphicsState()
    try write(gallery, to: masters.appendingPathComponent("holiday-collection.png"))
    print("Exported holiday-collection.png (1800×1830)")
}

// Rasterize the editable SVG with native WebKit, just like provider assets.
// The fixed viewBox preserves the drawing's safe margin and transparent canvas.
@MainActor
final class MenuTemplateRenderer: NSObject, WKNavigationDelegate {
    let webView: WKWebView

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 72, height: 72), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func start() { webView.loadHTMLString("<html><body></body></html>", baseURL: nil) }

    func fail(_ error: Error) {
        FileHandle.standardError.write(Data("Menu template export failed: \(error)\n".utf8))
        exit(1)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            do {
                let source = try String(contentsOf: masters.appendingPathComponent("beaver-menu-outline.svg"), encoding: .utf8)
                let script = #"""
                const svg = new DOMParser().parseFromString(source, 'image/svg+xml').documentElement;
                const allowed = new Set(['svg', 'g', 'path', 'ellipse', 'title']);
                if (svg.tagName !== 'svg' || svg.getAttribute('viewBox') !== '0 0 64 64' ||
                    [...svg.querySelectorAll('*')].some(element => !allowed.has(element.tagName))) {
                    throw new Error('Expected a self-contained 64×64 vector logo');
                }
                svg.style.color = '#000';
                const results = [];
                for (const size of [72, 512]) {
                    svg.setAttribute('width', size); svg.setAttribute('height', size);
                    const canvas = document.createElement('canvas');
                    canvas.width = canvas.height = size;
                    const image = new Image();
                    const url = URL.createObjectURL(new Blob([new XMLSerializer().serializeToString(svg)], {type:'image/svg+xml'}));
                    try {
                        await new Promise((resolve, reject) => { image.onload = resolve; image.onerror = reject; image.src = url; });
                        canvas.getContext('2d').drawImage(image, 0, 0, size, size);
                        results.push(canvas.toDataURL('image/png'));
                    } finally { URL.revokeObjectURL(url); }
                }
                return results;
                """#
                let value: Any = try await withCheckedThrowingContinuation { continuation in
                    webView.callAsyncJavaScript(script, arguments: ["source": source], in: nil, in: .page) {
                        continuation.resume(with: $0)
                    }
                }
                guard let encoded = value as? [String], encoded.count == 2 else { throw CocoaError(.coderReadCorrupt) }
                let data = try encoded.map { item in
                    guard let payload = item.split(separator: ",", maxSplits: 1).last,
                          let png = Data(base64Encoded: String(payload)) else { throw CocoaError(.coderReadCorrupt) }
                    return png
                }
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                for variant in variants {
                    try data[0].write(to: output.appendingPathComponent("beaver-\(variant.id)-template.png"), options: .atomic)
                }
                print("Exported \(variants.count) outline menu templates; colour artwork preserved")
                if !CommandLine.arguments.contains("--templates-only") { try exportColorArtwork() }
                guard let mask = NSBitmapImageRep(data: data[0])?.cgImage,
                      let outline = NSBitmapImageRep(data: data[1])?.cgImage else { throw CocoaError(.coderReadCorrupt) }
                try exportMenuStudy(mask: mask, outline: outline)
                NSApplication.shared.terminate(nil)
            } catch { fail(error) }
        }
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
MainActor.assumeIsolated {
    let renderer = MenuTemplateRenderer()
    // Missing WebKit callbacks must not leave the command running indefinitely.
    let watchdog = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { _ in
        FileHandle.standardError.write(Data("Menu template export timed out\n".utf8))
        exit(1)
    }
    renderer.start()
    withExtendedLifetime(renderer) { application.run() }
    watchdog.invalidate()
}
