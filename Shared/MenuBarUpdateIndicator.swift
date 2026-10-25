import AppKit

/// The indicator adds no status-item width and never uses provider/account data
/// as an image-cache key. A newer version changes its text, not its artwork.
struct MenuBarUpdateIndicator {
    struct ImageKey: Hashable {
        let variant: BrandVariant
        let hasUpdate: Bool
    }

    let variant: BrandVariant
    let available: AvailableUpdate?
    var imageKey: ImageKey { ImageKey(variant: variant, hasUpdate: available != nil) }

    func accessibilityText(usageDescription: String) -> String {
        (["BeaverMeter", usageDescription, variant.displayName]
         + (available.map { ["Update to BeaverMeter \($0.version) available"] } ?? []))
            .joined(separator: ", ")
    }

    func tooltip(usageDescription: String) -> String {
        (["BeaverMeter", usageDescription]
         + (available.map { ["Update \($0.version) available"] } ?? [])
         + ["Click to open"])
            .joined(separator: " · ")
    }
}

@MainActor
enum MenuBarUpdateAssets {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = BrandVariant.allCases.count * 2
        cache.totalCostLimit = BrandVariant.allCases.count * 2 * 72 * 72 * 4
        return cache
    }()

    static func image(for indicator: MenuBarUpdateIndicator) -> NSImage? {
        let key = "\(indicator.variant.rawValue):\(indicator.imageKey.hasUpdate)" as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let base = BrandLogoAssets.image(for: indicator.variant, template: true) else { return nil }
        let image: NSImage
        if indicator.imageKey.hasUpdate {
            guard let marked = addingDot(to: base) else { return base }
            image = marked
        } else { image = base }
        cache.setObject(image, forKey: key, cost: 72 * 72 * 4)
        return image
    }

    private static func addingDot(to base: NSImage) -> NSImage? {
        // Match the 4x menu-mark source. A transparent halo separates the dot
        // from the outline; its alpha remains a native light/dark template mask.
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 72, pixelsHigh: 72,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 72 * 4, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        base.draw(in: NSRect(x: 0, y: 0, width: 72, height: 72), from: .zero,
                  operation: .copy, fraction: 1)
        let cg = context.cgContext
        cg.setBlendMode(.clear)
        cg.fillEllipse(in: CGRect(x: 49, y: 49, width: 20, height: 20))
        cg.setBlendMode(.normal)
        cg.setFillColor(NSColor.black.cgColor)
        cg.fillEllipse(in: CGRect(x: 52, y: 52, width: 14, height: 14))
        bitmap.size = base.size
        let image = NSImage(size: base.size)
        image.addRepresentation(bitmap)
        image.isTemplate = true
        return image
    }
}
