import AppKit
import XCTest

@MainActor
final class MenuBarUpdateIndicatorTests: XCTestCase {
    private func update(_ version: String = "1.0.1") -> AvailableUpdate {
        AvailableUpdate(version: version, releaseURL: ReleaseUpdateConfiguration.releaseURL(version: version), build: "2")
    }

    func testReminderAppearsClearsAndKeepsTargetVersionInTooltipAndAccessibility() {
        let normal = MenuBarUpdateIndicator(variant: .standard, available: nil)
        let available = MenuBarUpdateIndicator(variant: .standard, available: update())
        let cleared = MenuBarUpdateIndicator(variant: .standard, available: nil)
        XCTAssertFalse(normal.imageKey.hasUpdate)
        XCTAssertTrue(available.imageKey.hasUpdate)
        XCTAssertNotEqual(normal.imageKey, available.imageKey)
        XCTAssertEqual(cleared.imageKey, normal.imageKey)
        XCTAssertTrue(available.tooltip(usageDescription: "Usage summary").contains("Update 1.0.1 available"))
        XCTAssertTrue(available.accessibilityText(usageDescription: "Usage summary").contains("Update to BeaverMeter 1.0.1"))
        XCTAssertFalse(cleared.tooltip(usageDescription: "Usage summary").contains("1.0.1"))
        XCTAssertFalse(cleared.accessibilityText(usageDescription: "Usage summary").contains("available"))
    }

    func testVersionChangesDoNotAddImageCacheKeysAndVariantChangesPreserveTheBadge() {
        let first = MenuBarUpdateIndicator(variant: .standard, available: update())
        let newer = MenuBarUpdateIndicator(variant: .standard, available: update("1.0.2"))
        XCTAssertEqual(first.imageKey, newer.imageKey)
        XCTAssertNotEqual(first.tooltip(usageDescription: ""), newer.tooltip(usageDescription: ""))
        var keys: Set<MenuBarUpdateIndicator.ImageKey> = []
        for variant in BrandVariant.allCases {
            let badged = MenuBarUpdateIndicator(variant: variant, available: update())
            let plain = MenuBarUpdateIndicator(variant: variant, available: nil)
            XCTAssertTrue(badged.imageKey.hasUpdate)
            XCTAssertEqual(badged.imageKey.variant, variant)
            XCTAssertTrue(badged.accessibilityText(usageDescription: "").contains(variant.displayName))
            keys.insert(badged.imageKey)
            keys.insert(plain.imageKey)
        }
        XCTAssertEqual(keys.count, BrandVariant.allCases.count * 2)
    }

    func testBadgedArtworkUsesTheSameTemplateFootprintAndReusesItsVersionIndependentImage() throws {
        for variant in BrandVariant.allCases {
            let plain = try XCTUnwrap(MenuBarUpdateAssets.image(for: .init(variant: variant, available: nil)))
            let badged = try XCTUnwrap(MenuBarUpdateAssets.image(for: .init(variant: variant, available: update())))
            let newer = try XCTUnwrap(MenuBarUpdateAssets.image(for: .init(variant: variant, available: update("1.0.2"))))
            let cleared = try XCTUnwrap(MenuBarUpdateAssets.image(for: .init(variant: variant, available: nil)))
            XCTAssertEqual(plain.size, NSSize(width: 18, height: 18))
            XCTAssertEqual(badged.size, plain.size)
            XCTAssertTrue(plain.isTemplate)
            XCTAssertTrue(badged.isTemplate)
            XCTAssertTrue(badged === newer)
            XCTAssertTrue(plain === cleared)
            XCTAssertNotEqual(try alphaMask(plain), try alphaMask(badged), "The available state must add visible pixels")
            XCTAssertEqual(try alphaMask(plain), try alphaMask(cleared), "Clearing the update must restore the original mark")
        }
    }

    func testPlainMarkMatchesTheMasterPackagedWithTheHostlessTestBundle() throws {
        let resources = try XCTUnwrap(Bundle(for: Self.self).resourceURL).appendingPathComponent("BrandAssets")
        for variant in BrandVariant.allCases {
            let master = try XCTUnwrap(NSImage(contentsOf: resources.appendingPathComponent(variant.assetName + "-template.png")))
            let loaded = try XCTUnwrap(BrandLogoAssets.image(for: variant, template: true))
            XCTAssertEqual(try alphaMask(loaded), try alphaMask(master), variant.rawValue)
        }
    }

    private func alphaMask(_ image: NSImage) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        var bytes = [UInt8](repeating: 0, count: 72 * 72 * 4)
        try bytes.withUnsafeMutableBytes { data in
            let context = try XCTUnwrap(CGContext(data: data.baseAddress, width: 72, height: 72,
                bitsPerComponent: 8, bytesPerRow: 72 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 72, height: 72))
        }
        return stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }
    }
}
