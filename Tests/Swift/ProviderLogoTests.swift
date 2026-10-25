import AppKit
import SwiftUI
import XCTest

@MainActor
final class ProviderLogoTests: XCTestCase {
    func testAllBundledLogosHaveTransparentMasksAndIndependentCachedVariants() throws {
        for provider in MeterProvider.allCases {
            let original = try XCTUnwrap(ProviderLogoAssets.image(for: provider, scheme: .light))
            let template = try XCTUnwrap(ProviderLogoAssets.image(for: provider, scheme: .dark))
            XCTAssertFalse(original.isTemplate)
            XCTAssertTrue(template.isTemplate)
            XCTAssertTrue(original === ProviderLogoAssets.image(for: provider, scheme: .light))
            XCTAssertFalse(original === template)
            let light = try pixels(original)
            let dark = try pixels(template)
            XCTAssertEqual(light.count, 256 * 256 * 4)
            var transparent = 0
            var visible = 0
            var colored = 0
            for offset in stride(from: 0, to: light.count, by: 4) {
                XCTAssertEqual(light[offset + 3], dark[offset + 3])
                if light[offset + 3] == 0 { transparent += 1 } else { visible += 1 }
                XCTAssertEqual(dark[offset], dark[offset + 1])
                XCTAssertEqual(dark[offset + 1], dark[offset + 2])
                if light[offset] != light[offset + 1] || light[offset + 1] != light[offset + 2] { colored += 1 }
            }
            XCTAssertGreaterThan(transparent, 1000)
            XCTAssertGreaterThan(visible, 1000)
            if provider == .claude || provider == .deepseek { XCTAssertGreaterThan(colored, 1000) }
        }
    }

    private func pixels(_ image: NSImage) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        var bytes = [UInt8](repeating: 0, count: 256 * 256 * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 256, height: 256,
                bitsPerComponent: 8, bytesPerRow: 256 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 256, height: 256))
        }
        return bytes
    }
}
