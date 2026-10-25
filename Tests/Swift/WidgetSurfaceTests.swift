import AppKit
import SwiftUI
import WidgetKit
import XCTest

@MainActor
final class WidgetSurfaceTests: XCTestCase {
    func testFullColorDarkSurfacesUseOpaqueNeutralCardsAndOriginalOuterBackground() throws {
        let outer = try pixels(WidgetSurfaceBackground())
        XCTAssertEqual(outer, try pixels(Color(red: 0.065, green: 0.07, blue: 0.085)))
        XCTAssertTrue(opaque(outer))

        let expected = try pixels(Color(white: 0.12))
        for provider in MeterProvider.allCases {
            let card = try pixels(WidgetSurfaceBackground(provider: provider))
            XCTAssertEqual(card, expected, provider.rawValue)
            XCTAssertTrue(opaque(card), provider.rawValue)
        }
    }

    func testFullColorLightModeKeepsOriginalPixels() throws {
        for provider in MeterProvider.allCases {
            let actual = try pixels(WidgetSurfaceBackground(provider: provider), scheme: .light)
            let original = try pixels(RoundedRectangle(cornerRadius: 0)
                .fill(BrandStyle.provider(provider, .light).opacity(0.08)), scheme: .light)
            XCTAssertEqual(actual, original, provider.rawValue)
        }
        XCTAssertEqual(try pixels(WidgetSurfaceBackground(), scheme: .light),
                       try pixels(Color(red: 0.965, green: 0.970, blue: 0.980), scheme: .light))
    }

    func testFullColorDarkSurfacesDoNotSampleWallpaperWithEitherTransparencySetting() throws {
        for provider in [nil] + MeterProvider.allCases.map(Optional.some) {
            let surface = WidgetSurfaceBackground(provider: provider)
            let expected = try pixels(surface)
            for reduceTransparency in [false, true] {
                let options = WidgetAccessibilityOptions(reduceTransparency: reduceTransparency)
                XCTAssertEqual(try pixels(surface.background(Color.black), accessibility: options), expected)
                XCTAssertEqual(try pixels(surface.background(Color.white), accessibility: options), expected)
            }
        }
    }

    func testReducedColorDesignBranchesLeaveCardBackgroundAndBorderTransparentOverBothWallpapers() throws {
        // Environment injection selects our design branch; ImageRenderer does not apply the host's color filters.
        for mode in [WidgetRenderingMode.vibrant, .accented] {
            for scheme in [ColorScheme.light, .dark] {
                for provider in MeterProvider.allCases {
                    let background = WidgetSurfaceBackground(provider: provider, cornerRadius: 12)
                    let card = Color.clear.modifier(WidgetCardSurface(provider: provider, cornerRadius: 12))
                    for reduceTransparency in [false, true] {
                        for increaseContrast in [false, true] {
                            let options = WidgetAccessibilityOptions(reduceTransparency: reduceTransparency,
                                                                     increaseContrast: increaseContrast)
                            for wallpaper in [Color.black, .white] {
                                // Nonempty scenes test observable compositing without empty-renderer cache artifacts.
                                let expected = try pixels(wallpaper, scheme: scheme, mode: mode,
                                                          accessibility: options)
                                let backgroundPixels = try pixels(background.background(wallpaper), scheme: scheme,
                                                                  mode: mode, accessibility: options)
                                let cardPixels = try pixels(card.background(wallpaper), scheme: scheme, mode: mode,
                                                            accessibility: options)
                                let context = "\(provider.rawValue), \(mode), \(scheme), wallpaper \(wallpaper), reduceTransparency \(reduceTransparency), increaseContrast \(increaseContrast)"
                                XCTAssertTrue(backgroundPixels == expected, "Card background changed wallpaper: \(context)")
                                XCTAssertTrue(cardPixels == expected, "Card background or border changed wallpaper: \(context)")
                            }
                        }
                    }
                }
            }
        }
    }

    func testReducedColorDesignBranchesRetainOuterContainerFill() throws {
        for mode in [WidgetRenderingMode.vibrant, .accented] {
            for scheme in [ColorScheme.light, .dark] {
                let outer = try pixels(WidgetSurfaceBackground(), scheme: scheme, mode: mode)
                XCTAssertEqual(outer, try pixels(WidgetSurfaceBackground(), scheme: scheme))
                XCTAssertTrue(opaque(outer))
            }
        }
    }

    func testDarkAndReducedColorDesignBranchesUseOpaqueLegibleTextColors() throws {
        let glyph = Text("80%").font(.system(size: 24, weight: .semibold))
        let cases: [(ColorScheme, WidgetRenderingMode)] = [
            (.dark, .fullColor), (.dark, .vibrant), (.light, .vibrant), (.dark, .accented), (.light, .accented)
        ]
        for (scheme, mode) in cases {
            let primary = try pixels(glyph.modifier(WidgetPrimaryText()), scheme: scheme, mode: mode)
            let secondary = try pixels(glyph.modifier(WidgetSecondaryText()), scheme: scheme, mode: mode)
            XCTAssertEqual(primary, try pixels(glyph.foregroundStyle(Color.white), scheme: scheme))
            XCTAssertEqual(secondary, try pixels(glyph.foregroundStyle(Color(white: 0.78)), scheme: scheme))

            // The retained dark container supplies this local contrast. Desktop wallpaper adaptation is host behavior.
            let darkContainer = try pixels(WidgetSurfaceBackground(), scheme: .dark, mode: mode)
            XCTAssertGreaterThanOrEqual(try minimumOpaqueGlyphContrast(primary, over: darkContainer), 7)
            XCTAssertGreaterThanOrEqual(try minimumOpaqueGlyphContrast(secondary, over: darkContainer), 4.5)
        }
    }

    func testIncreasedContrastStrengthensFullColorBorderAndPromotesSecondaryText() throws {
        let card = Color.clear.modifier(WidgetCardSurface(provider: .codex, cornerRadius: 0))
        let normal = try pixels(card)
        let increased = try pixels(card, accessibility: WidgetAccessibilityOptions(increaseContrast: true))
        let edge = (40 * 80) * 4
        XCTAssertGreaterThan(increased[edge], normal[edge])

        let glyph = Text("80%").font(.system(size: 24, weight: .semibold))
        let cases: [(ColorScheme, WidgetRenderingMode)] = [
            (.light, .fullColor), (.dark, .fullColor), (.light, .vibrant), (.dark, .vibrant),
            (.light, .accented), (.dark, .accented)
        ]
        for (scheme, mode) in cases {
            let options = WidgetAccessibilityOptions(reduceTransparency: true, increaseContrast: true)
            let secondary = try pixels(glyph.modifier(WidgetSecondaryText()), scheme: scheme, mode: mode,
                                       accessibility: options)
            let primary = try pixels(glyph.modifier(WidgetPrimaryText()), scheme: scheme, mode: mode,
                                     accessibility: options)
            XCTAssertEqual(secondary, primary)
        }
    }

    private func opaque(_ image: [UInt8]) -> Bool {
        stride(from: 3, to: image.count, by: 4).allSatisfy { image[$0] == 255 }
    }

    private func minimumOpaqueGlyphContrast(_ glyph: [UInt8], over background: [UInt8]) throws -> Double {
        func luminance(_ bytes: [UInt8], at offset: Int) -> Double {
            let channels = (0..<3).map { channel -> Double in
                let value = Double(bytes[offset + channel]) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
        }
        let contrasts = stride(from: 0, to: glyph.count, by: 4).compactMap { offset -> Double? in
            guard glyph[offset + 3] == 255 else { return nil }
            let foreground = luminance(glyph, at: offset), backdrop = luminance(background, at: offset)
            return (max(foreground, backdrop) + 0.05) / (min(foreground, backdrop) + 0.05)
        }
        return try XCTUnwrap(contrasts.min(), "The text fixture must contain opaque glyph interiors.")
    }

    private func pixels<V: View>(
        _ view: V, scheme: ColorScheme = .dark, mode: WidgetRenderingMode = .fullColor,
        accessibility: WidgetAccessibilityOptions = WidgetAccessibilityOptions()
    ) throws -> [UInt8] {
        let renderer = ImageRenderer(content: view.frame(width: 80, height: 80)
            .environment(\.colorScheme, scheme)
            .environment(\.widgetRenderingMode, mode)
            .environment(\.widgetAccessibilityOverride, accessibility))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        var bytes = [UInt8](repeating: 0, count: 80 * 80 * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 80, height: 80,
                bitsPerComponent: 8, bytesPerRow: 80 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 80, height: 80))
        }
        return bytes
    }
}
