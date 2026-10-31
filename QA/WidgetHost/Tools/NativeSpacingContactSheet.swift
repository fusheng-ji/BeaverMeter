import AppKit
import Foundation

/// Offline composition of existing synthetic captures. Never opens a window,
/// activates an app, reads Accessibility, collects data or edits capture records.
@main
enum NativeSpacingContactSheet {
    struct Capture: Decodable {
        let caseID: String
        let family: String
        let appearance: String
        let screenshot: String
    }

    struct Cell {
        let capture: Capture
        let image: NSImage
        let pixels: CGSize
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static let families = ["small", "medium", "large", "extra-large"]
    static let appearances = ["light", "dark"]
    static let padding: CGFloat = 24
    static let captionHeight: CGFloat = 40
    static let headerHeight: CGFloat = 76

    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("Contact sheet: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 1 else { throw Failure("Pass the existing native captures.json path.") }
        let manifest = URL(fileURLWithPath: arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        let directory = manifest.deletingLastPathComponent()
        let captures = try JSONDecoder().decode([Capture].self, from: Data(contentsOf: manifest))
        let grouped = Dictionary(grouping: captures, by: \.caseID)
        guard grouped.count == 5, captures.count == 40 else { throw Failure("Expected five cases and 40 existing captures.") }
        for caseID in grouped.keys.sorted() {
            try autoreleasepool {
                guard caseID.hasPrefix("antigravity-"),
                      caseID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
                      let records = grouped[caseID], records.count == 8 else {
                    throw Failure("Unsafe case identity or incomplete case coverage.")
                }
                var cells: [Cell] = []
                for appearance in appearances {
                    for family in families {
                        let matches = records.filter { $0.family == family && $0.appearance == appearance }
                        guard matches.count == 1, let capture = matches.first else {
                            throw Failure("Duplicate or missing family/appearance in \(caseID).")
                        }
                        // All images must remain beside the captures manifest. Do not
                        // follow arbitrary paths or symlinks from a record.
                        let filename = URL(fileURLWithPath: capture.screenshot).lastPathComponent
                        let source = directory.appendingPathComponent(filename).resolvingSymlinksInPath()
                        guard source.deletingLastPathComponent() == directory,
                              source.pathExtension.lowercased() == "png",
                              let bitmap = NSBitmapImageRep(data: try Data(contentsOf: source)),
                              let cgImage = bitmap.cgImage else { throw Failure("Invalid local capture image.") }
                        let pixels = CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
                        guard pixels.width > 0, pixels.height > 0 else { throw Failure("Empty capture image.") }
                        cells.append(Cell(capture: capture, image: NSImage(cgImage: cgImage, size: pixels), pixels: pixels))
                    }
                }
                let destination = directory.appendingPathComponent("contact-sheet-\(caseID).png")
                try draw(caseID: caseID, cells: cells, to: destination)
                print(destination.path)
            }
        }
    }

    static func draw(caseID: String, cells: [Cell], to destination: URL) throws {
        let widths = families.map { family in
            cells.filter { $0.capture.family == family }.map(\.pixels.width).max()!
        }
        let imageHeight = cells.map(\.pixels.height).max()!
        let rowHeight = captionHeight + imageHeight
        let width = widths.reduce(0, +) + padding * CGFloat(families.count + 1)
        let height = headerHeight + rowHeight * 2 + padding * 3
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw Failure("Cannot allocate offscreen contact sheet.")
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: width, height: height)).fill()
        text(caseID, frame: CGRect(x: padding, y: height - padding - 31, width: width - padding * 2, height: 32),
             size: 26, weight: .semibold)
        text("Existing native WidgetKit captures · original image proportions · no review status changed",
             frame: CGRect(x: padding, y: height - padding - 58, width: width - padding * 2, height: 24),
             size: 18, weight: .regular)
        for (row, appearance) in appearances.enumerated() {
            let top = height - headerHeight - padding - CGFloat(row) * (rowHeight + padding)
            var x = padding
            for (column, family) in families.enumerated() {
                let cell = cells.first { $0.capture.family == family && $0.capture.appearance == appearance }!
                text("\(family) · \(appearance)",
                     frame: CGRect(x: x, y: top - captionHeight + 8, width: widths[column], height: 28),
                     size: 21, weight: .semibold)
                let scale = min(widths[column] / cell.pixels.width, imageHeight / cell.pixels.height, 1)
                let size = CGSize(width: cell.pixels.width * scale, height: cell.pixels.height * scale)
                let frame = CGRect(x: x + (widths[column] - size.width) / 2,
                                   y: top - captionHeight - size.height, width: size.width, height: size.height)
                cell.image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
                x += widths[column] + padding
            }
        }
        context.flushGraphics()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw Failure("PNG encoding failed.") }
        try data.write(to: destination, options: .atomic)
    }

    static func text(_ value: String, frame: CGRect, size: CGFloat, weight: NSFont.Weight) {
        (value as NSString).draw(in: frame, withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1)
        ])
    }
}
