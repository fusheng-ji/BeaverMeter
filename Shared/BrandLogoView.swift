import AppKit
import SwiftUI

/// Shared artwork is a folder resource so the command-line preview renderer can
/// use exactly the same pixels as the app and the Widget extension.
@MainActor
enum BrandLogoAssets {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for variant: BrandVariant, template: Bool = false) -> NSImage? {
        let name = variant.assetName + (template ? "-template" : "")
        if let image = cache.object(forKey: name as NSString) { return image }
        let roots = [Bundle.main.resourceURL, Bundle.main.executableURL?.deletingLastPathComponent(),
                     Bundle(for: BundleMarker.self).resourceURL]
        for root in roots.compactMap({ $0 }) {
            let url = root.appendingPathComponent("BrandAssets").appendingPathComponent(name + ".png")
            if let image = NSImage(contentsOf: url) {
                image.isTemplate = template
                if template { image.size = NSSize(width: 18, height: 18) }
                cache.setObject(image, forKey: name as NSString)
                return image
            }
        }
        return variant == .standard ? nil : image(for: .standard, template: template)
    }

    private final class BundleMarker: NSObject {}
}

@MainActor
struct BrandLogoView: View {
    let variant: BrandVariant
    var size: CGFloat
    var template = false

    var body: some View {
        Group {
            if let image = BrandLogoAssets.image(for: variant, template: template) {
                Image(nsImage: image)
                    .renderingMode(template ? .template : .original)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("BeaverMeter, \(variant.displayName)")
    }
}
