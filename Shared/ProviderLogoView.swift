import AppKit
import SwiftUI
import WidgetKit

@MainActor
enum ProviderLogoAssets {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 8
        cache.totalCostLimit = 2 * 1024 * 1024
        return cache
    }()

    static func image(for provider: MeterProvider, scheme: ColorScheme) -> NSImage? {
        let name = provider.rawValue + (scheme == .dark ? "-template" : "")
        if let image = cache.object(forKey: name as NSString) { return image }
        let roots = [Bundle.main.resourceURL, Bundle.main.executableURL?.deletingLastPathComponent(),
                     Bundle(for: BundleMarker.self).resourceURL]
        for root in roots.compactMap({ $0 }) {
            let url = root.appendingPathComponent("ProviderAssets/\(name).png")
            if let image = NSImage(contentsOf: url) {
                image.isTemplate = scheme == .dark
                cache.setObject(image, forKey: name as NSString, cost: 256 * 256 * 4)
                return image
            }
        }
        return nil
    }

    private final class BundleMarker: NSObject {}
}

@MainActor
struct ProviderLogoView: View {
    let provider: MeterProvider
    var size: CGFloat = 18
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var usesTemplate: Bool { colorScheme == .dark || renderingMode != .fullColor }

    var body: some View {
        Group {
            if let image = ProviderLogoAssets.image(for: provider, scheme: usesTemplate ? .dark : .light) {
                Image(nsImage: image)
                    .renderingMode(usesTemplate ? .template : .original)
                    .resizable().interpolation(.high).scaledToFit()
                    .foregroundStyle(.white)
            } else {
                // A missing asset still identifies the service without pretending
                // to be an official logo. Asset validation catches this at build QA.
                Text(String(provider.displayName.prefix(1))).font(.system(size: size * 0.8, weight: .bold))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(provider.displayName)
    }
}
