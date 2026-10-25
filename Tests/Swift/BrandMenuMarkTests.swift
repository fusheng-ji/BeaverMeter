import AppKit
import XCTest

final class BrandMenuMarkTests: XCTestCase {
    func testEveryOutfitPackagesTheSameOpenOutlineMark() throws {
        let root = try XCTUnwrap(Bundle(for: Self.self).resourceURL).appendingPathComponent("BrandAssets")
        var reference: [UInt8]?
        for variant in BrandVariant.allCases {
            let url = root.appendingPathComponent(variant.assetName + "-template.png")
            let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: url)))
            XCTAssertEqual(image.pixelsWide, 72)
            XCTAssertEqual(image.pixelsHigh, 72)
            let cgImage = try XCTUnwrap(image.cgImage)
            var bytes = [UInt8](repeating: 0, count: 72 * 72 * 4)
            try bytes.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 72, height: 72,
                    bitsPerComponent: 8, bytesPerRow: 72 * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 72, height: 72))
            }
            let alpha = stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }
            XCTAssertTrue(alpha.contains { $0 > 0 && $0 < 255 }, "Curves need antialiased edges")
            let coverage = Double(alpha.filter { $0 > 127 }.count) / Double(alpha.count)
            XCTAssertGreaterThan(coverage, 0.15, "Outline must remain visible at menu-bar size")
            XCTAssertLessThan(coverage, 0.35, "Body must stay open instead of becoming a filled silhouette")
            XCTAssertTrue(alpha.prefix(72).allSatisfy { $0 == 0 })
            XCTAssertTrue(alpha.suffix(72).allSatisfy { $0 == 0 })
            XCTAssertTrue((0..<72).allSatisfy { alpha[$0 * 72] == 0 && alpha[$0 * 72 + 71] == 0 },
                          "The outline must leave a transparent margin on every edge")
            if let reference { XCTAssertEqual(alpha, reference) } else { reference = alpha }
        }
    }
}
