import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Read-only evidence from the private WidgetKit QA surface. No UI actions,
/// screenshots, production windows, settings, accounts or process control.
@main
enum NativeWidgetBounds {
    static let title = "BeaverMeter QA"
    static let kind = "BeaverMeterWidgetQA"
    static let casePrefix = "WidgetQA.case."
    static let cardPrefix = "WidgetQA.card."
    static let fitPrefix = "WidgetQA.fit."
    static let leafPrefix = "WidgetQA.leaf."

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    struct Options {
        var caseID: String?
        var family: String?
        var appearance: String?
        var windowID: UInt32?
        var selfTest = false

        init(_ arguments: [String]) throws {
            var index = 0
            while index < arguments.count {
                let key = arguments[index]
                if key == "--self-test" { selfTest = true; index += 1; continue }
                guard index + 1 < arguments.count else { throw Failure("Missing value for \(key).") }
                let value = arguments[index + 1]
                switch key {
                case "--case": caseID = value
                case "--family":
                    let aliases = ["small": "systemSmall", "medium": "systemMedium",
                                   "large": "systemLarge", "extra-large": "systemExtraLarge"]
                    family = aliases[value] ?? value
                    guard ["systemSmall", "systemMedium", "systemLarge", "systemExtraLarge"].contains(family!) else {
                        throw Failure("Unsupported family.")
                    }
                case "--appearance":
                    guard ["light", "dark"].contains(value) else { throw Failure("Unsupported appearance.") }
                    appearance = value
                case "--window-id":
                    guard let number = UInt32(value) else { throw Failure("Invalid window ID.") }
                    windowID = number
                default: throw Failure("Unknown argument \(key).")
                }
                index += 2
            }
            guard !selfTest || arguments == ["--self-test"] else { throw Failure("Self-test accepts no AX filters.") }
        }
    }

    struct Node {
        let id: Int
        let parentID: Int?
        let depth: Int
        let role: String
        let identifier: String?
        let label: String?
        let value: String?
        let bounds: CGRect?
        let hasChildren: Bool
    }

    struct Insets: Equatable {
        let horizontal: Double
        let vertical: Double

        static func parse(_ value: String?, label: String? = nil) -> Insets? {
            guard let raw = metadata(label: label, value: value)["safeInsets"] else { return nil }
            let pieces = raw.split(separator: ",", omittingEmptySubsequences: false)
            guard pieces.count == 2,
                  let h = Double(pieces[0].trimmingCharacters(in: .whitespaces)),
                  let v = Double(pieces[1].trimmingCharacters(in: .whitespaces)),
                  h.isFinite, v.isFinite, h >= 0, v >= 0 else { return nil }
            return Insets(horizontal: h, vertical: v)
        }
    }

    struct DetailChoice: Equatable {
        let level: String
        let source: String
    }

    static func main() {
        do {
            let options = try Options(Array(CommandLine.arguments.dropFirst()))
            if options.selfTest { try selfTest(); return }
            let report = try inspect(options)
            try write(report)
            if report["status"] as? String != "passed" { exit(2) }
        } catch {
            try? write(["schemaVersion": 1, "scope": "private-widgetkit-qa-bounds",
                        "status": "blocked", "readOnly": true, "error": error.localizedDescription])
            exit(2)
        }
    }

    static func metadata(_ value: String?) -> [String: String] {
        var result: [String: String] = [:]
        for piece in (value ?? "").split(separator: ";") {
            let parts = piece.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, !value.isEmpty { result[key] = value }
        }
        return result
    }

    /// WidgetKit Remote can expose a group's accessibility label through
    /// AXDescription while dropping AXValue. Merge by key so partial AXValue
    /// metadata does not discard label-only fields; AXValue remains authoritative.
    static func metadata(label: String?, value: String?) -> [String: String] {
        metadata(label).merging(metadata(value)) { _, value in value }
    }

    static func metadata(_ node: Node) -> [String: String] {
        metadata(label: node.label, value: node.value)
    }

    static func chosenDetail(fits: [Node], leaves: [Node]) -> DetailChoice? {
        let levels = ["full", "withoutActivityDetails", "withoutActivity", "withoutWindowReset", "withoutSubscription", "primaryOnly"]
        if !fits.isEmpty {
            guard fits.count == 1, let level = metadata(fits[0])["detailLevel"], levels.contains(level) else { return nil }
            return DetailChoice(level: level, source: "fit-group")
        }
        // WidgetKit Remote can flatten ViewThatFits' wrappers. Its selected
        // variant's visible logo retains the same metadata on an actual leaf.
        // Do not infer a level from card budgets or absent/offscreen elements.
        let logos = leaves.filter { $0.identifier == leafPrefix + "logo" }
        guard logos.count == 1, let bounds = logos[0].bounds, valid(bounds),
              let level = metadata(logos[0])["detailLevel"], levels.contains(level) else { return nil }
        return DetailChoice(level: level, source: "visible-logo")
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        guard let value = attribute(element, name) as? String, !value.isEmpty else { return nil }
        return String(value.prefix(1_024))
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute),
              let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        let result = CGRect(origin: point, size: dimensions)
        return valid(result) ? result : nil
    }

    static func valid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) && rect.width > 0 && rect.height > 0
    }

    static func rect(_ value: CGRect) -> [String: Double] {
        ["x": value.minX, "y": value.minY, "width": value.width, "height": value.height]
    }

    static func tree(_ window: AXUIElement, deadline: Date) throws -> [Node] {
        var pending: [(AXUIElement, Int?, Int)] = [(window, nil, 0)]
        var cursor = 0
        var nodes: [Node] = []
        while cursor < pending.count {
            guard Date() < deadline, nodes.count < 1_500 else { throw Failure("AX traversal exceeded its time/node budget.") }
            let (element, parentID, depth) = pending[cursor]
            cursor += 1
            if (attribute(element, "AXHidden") as? Bool) == true { continue }
            let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            guard depth < 30 || children.isEmpty else { throw Failure("AX traversal exceeded its depth budget.") }
            let id = nodes.count
            nodes.append(Node(id: id, parentID: parentID, depth: depth,
                              role: string(element, kAXRoleAttribute) ?? "unknown",
                              identifier: string(element, kAXIdentifierAttribute),
                              label: string(element, kAXTitleAttribute) ?? string(element, kAXDescriptionAttribute),
                              value: string(element, kAXValueAttribute), bounds: frame(element), hasChildren: !children.isEmpty))
            pending.append(contentsOf: children.map { ($0, id, depth + 1) })
        }
        return nodes
    }

    static func descends(_ node: Node, from ancestor: Int, in nodes: [Node]) -> Bool {
        var id: Int? = node.id
        while let current = id {
            if current == ancestor { return true }
            id = nodes[current].parentID
        }
        return false
    }

    static func closestCard(_ node: Node, in nodes: [Node]) -> Int? {
        var parent = node.parentID
        while let id = parent {
            if nodes[id].identifier?.hasPrefix(cardPrefix) == true { return id }
            parent = nodes[id].parentID
        }
        return nil
    }

    static func pixelScale(_ bounds: CGRect) throws -> (Double, UInt32) {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { throw Failure("No active display metadata.") }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { throw Failure("Cannot read display metadata.") }
        let matches = displays.prefix(Int(count)).filter { CGDisplayBounds($0).intersection(bounds).width > 0 && CGDisplayBounds($0).intersection(bounds).height > 0 }
        guard matches.count == 1, let display = matches.first,
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
              }) else { throw Failure("Widget must lie on one display with an actual backing scale.") }
        let scale = Double(screen.backingScaleFactor)
        guard scale.isFinite, scale >= 1 else { throw Failure("Invalid display backing scale.") }
        return (scale, display)
    }

    /// Positive numbers mean overflow. This compares actual AX leaf frames,
    /// not a claimed padding constant or an offscreen view measurement.
    static func overflow(_ leaf: CGRect, safeRect: CGRect) -> [String: Double] {
        ["left": max(0, safeRect.minX - leaf.minX), "top": max(0, safeRect.minY - leaf.minY),
         "right": max(0, leaf.maxX - safeRect.maxX), "bottom": max(0, leaf.maxY - safeRect.maxY)]
    }

    static func inside(_ leaf: CGRect, safeRect: CGRect, tolerance: Double) -> Bool {
        valid(leaf) && valid(safeRect) && tolerance.isFinite && tolerance >= 0 &&
            overflow(leaf, safeRect: safeRect).values.allSatisfy { $0 <= tolerance + 0.000_001 }
    }

    static func inspect(_ options: Options) throws -> [String: Any] {
        guard AXIsProcessTrusted() else { throw Failure("Read-only Accessibility access is unavailable; no prompt was opened.") }
        let deadline = Date().addingTimeInterval(15)
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui")
        guard !applications.isEmpty else { throw Failure("NotificationCenter is not running.") }
        let cgWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var reports: [[String: Any]] = []
        for application in applications {
            let app = AXUIElementCreateApplication(application.processIdentifier)
            AXUIElementSetMessagingTimeout(app, 0.5)
            let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
            for window in windows {
                guard string(window, kAXTitleAttribute) == title else { continue }
                guard Date() < deadline else { throw Failure("AX window inspection exceeded its time budget.") }
                guard let bounds = frame(window) else { throw Failure("QA window has no valid actual AX frame.") }
                let matches = cgWindows.filter { row in
                    guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == application.processIdentifier,
                          (row[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
                          ((row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0) > 0,
                          let cgBounds = cgFrame(row) else { return false }
                    return zip([bounds.minX, bounds.minY, bounds.width, bounds.height],
                               [cgBounds.minX, cgBounds.minY, cgBounds.width, cgBounds.height]).allSatisfy { abs($0.0 - $0.1) <= 2 }
                }
                guard matches.count == 1, let cgWindow = matches.first,
                      let windowID = (cgWindow[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
                if let selected = options.windowID, selected != windowID { continue }
                let nodes = try tree(window, deadline: deadline)
                let cases = nodes.filter { node in
                    guard let identifier = node.identifier, identifier.hasPrefix(casePrefix),
                          metadata(node)["kind"] == kind else { return false }
                    let info = metadata(node)
                    if let expected = options.caseID, identifier != casePrefix + expected { return false }
                    if let expected = options.family, info["family"] != expected { return false }
                    if let expected = options.appearance, info["colorScheme"] != expected { return false }
                    return true
                }
                guard !cases.isEmpty else { continue }
                let (scale, display) = try pixelScale(bounds)
                let tolerance = 1 / scale
                var issues: [String] = []
                if cases.count != 1 { issues.append("Expected exactly one visible private QA case branch.") }
                var caseReports: [[String: Any]] = []
                for caseNode in cases {
                    var branch = nodes.filter { descends($0, from: caseNode.id, in: nodes) }
                    // Parents are retained in each row; only the selected case branch is reported.
                    branch.sort { $0.id < $1.id }
                    let cards = branch.filter { $0.identifier?.hasPrefix(cardPrefix) == true }
                    let leaves = branch.filter { node in
                        node.identifier?.hasPrefix(leafPrefix) == true || (node.role == kAXStaticTextRole && !node.hasChildren)
                    }
                    if cards.isEmpty { issues.append("No actual card AX identity/frame is exposed.") }
                    if Set(cards.compactMap(\.identifier)).count != cards.count { issues.append("Duplicate card identities in the visible case branch.") }
                    var cardReports: [[String: Any]] = []
                    for card in cards {
                        let children = branch.filter { closestCard($0, in: nodes) == card.id }
                        let metadataValues = [card] + children
                        let insetsFound = metadataValues.compactMap { Insets.parse($0.value, label: $0.label) }
                        let insets = insetsFound.first
                        if insets == nil || insetsFound.contains(where: { $0 != insets }) { issues.append("Card \(card.id) has missing or inconsistent safe inset metadata.") }
                        let fits = children.filter { $0.identifier?.hasPrefix(fitPrefix) == true }
                        let cardLeaves = leaves.filter { closestCard($0, in: nodes) == card.id }
                        let detailChoice = chosenDetail(fits: fits, leaves: cardLeaves)
                        if detailChoice == nil { issues.append("Card \(card.id) has no unique visible fit choice.") }
                        if !cardLeaves.contains(where: { $0.identifier == leafPrefix + "logo" }) {
                            issues.append("Card \(card.id) has no actual logo leaf frame.")
                        }
                        if !cardLeaves.contains(where: { $0.role == kAXStaticTextRole || $0.identifier?.hasPrefix(leafPrefix + "text") == true }) {
                            issues.append("Card \(card.id) has no actual text leaf frame.")
                        }
                        var safe: CGRect?
                        if let frame = card.bounds, let insets {
                            let candidate = frame.insetBy(dx: insets.horizontal, dy: insets.vertical)
                            if valid(candidate) { safe = candidate }
                        }
                        if safe == nil { issues.append("Card \(card.id) has no valid actual safe rectangle.") }
                        var leafReports: [[String: Any]] = []
                        for leaf in cardLeaves {
                            var row = nodeJSON(leaf)
                            let passes = leaf.bounds.flatMap { frame in safe.map { inside(frame, safeRect: $0, tolerance: tolerance) } } ?? false
                            row["insideSafeRect"] = passes
                            if let frame = leaf.bounds, let safe {
                                row["overflowPoints"] = overflow(frame, safeRect: safe)
                                row["overflowPhysicalPixels"] = overflow(frame, safeRect: safe).mapValues { $0 * scale }
                            }
                            if !passes { issues.append("Leaf \(leaf.id) exceeds the safe rectangle or has no actual AX frame.") }
                            leafReports.append(row)
                        }
                        var cardRow = nodeJSON(card)
                        cardRow["safeInsets"] = insets.map { ["horizontal": $0.horizontal, "vertical": $0.vertical] } ?? [:]
                        cardRow["safeRect"] = safe.map(rect) ?? [:]
                        cardRow["chosenDetailLevel"] = detailChoice.map { $0.level as Any } ?? NSNull()
                        cardRow["chosenDetailLevelSource"] = detailChoice.map { $0.source as Any } ?? NSNull()
                        // Healthy cards intentionally have no status icon. Every
                        // exposed status icon is still measured like other leaves.
                        cardRow["statusIconPresent"] = cardLeaves.contains { $0.identifier == leafPrefix + "status" }
                        cardRow["fitNodes"] = fits.map(nodeJSON)
                        cardRow["leaves"] = leafReports
                        cardReports.append(cardRow)
                    }
                    for leaf in leaves where closestCard(leaf, in: nodes) == nil {
                        issues.append("Visible leaf \(leaf.id) is outside every identified card.")
                    }
                    let info = metadata(caseNode)
                    if !["systemSmall", "systemMedium", "systemLarge", "systemExtraLarge"].contains(info["family"] ?? "") ||
                        !["light", "dark"].contains(info["colorScheme"] ?? "") || info["widgetRenderingMode"] == nil {
                        issues.append("Private case is missing its actual family/appearance/rendering mode metadata.")
                    }
                    caseReports.append(["caseID": String((caseNode.identifier ?? "").dropFirst(casePrefix.count)),
                                        "node": nodeJSON(caseNode), "environment": info,
                                        "cards": cardReports, "visibleAXTree": branch.map(nodeJSON)])
                }
                reports.append(["pid": application.processIdentifier, "title": title,
                                "actualWindow": ["id": windowID, "axFrame": rect(bounds),
                                                 "cgFrame": cgFrame(cgWindow).map(rect) ?? [:],
                                                 "isOnscreen": true, "displayID": display,
                                                 "backingScale": scale, "scaleSource": "NSScreen.backingScaleFactor",
                                                 "tolerancePoints": tolerance, "tolerancePhysicalPixels": 1],
                                "cases": caseReports, "violations": issues,
                                "status": issues.isEmpty ? "passed" : "failed"])
            }
        }
        let status = reports.isEmpty ? "blocked" : reports.allSatisfy { $0["status"] as? String == "passed" } ? "passed" : "failed"
        return ["schemaVersion": 1, "scope": "private-widgetkit-qa-bounds", "kind": kind,
                "readOnly": true, "status": status,
                "observedAt": ISO8601DateFormatter().string(from: Date()),
                "measurement": "Actual onscreen CG window and visible AX card/leaf layout frames; not glyph ink bounds or screenshot pixels.",
                "windows": reports,
                "limitations": reports.isEmpty ? ["No onscreen private QA window matched the requested case/family/appearance and markers."] : []]
    }

    static func cgFrame(_ row: [String: Any]) -> CGRect? {
        guard let bounds = row[kCGWindowBounds as String] as? [String: NSNumber],
              let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"] else { return nil }
        let result = CGRect(x: x.doubleValue, y: y.doubleValue, width: w.doubleValue, height: h.doubleValue)
        return valid(result) ? result : nil
    }

    static func nodeJSON(_ node: Node) -> [String: Any] {
        var result: [String: Any] = ["nodeID": node.id, "parentNodeID": node.parentID.map { $0 as Any } ?? NSNull(),
                                     "depth": node.depth, "role": node.role]
        if let identifier = node.identifier { result["identifier"] = identifier }
        if let label = node.label { result["label"] = label }
        if let value = node.value { result["value"] = value }
        if let bounds = node.bounds { result["bounds"] = rect(bounds) }
        return result
    }

    static func write(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }

    static func selfTest() throws {
        var checkCount = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw Failure("Self-test: \(message)") }
            checkCount += 1
        }
        let safe = CGRect(x: 10, y: 8, width: 80, height: 64)
        try expect(inside(CGRect(x: 12, y: 10, width: 50, height: 20), safeRect: safe, tolerance: 0.5), "inside")
        try expect(inside(CGRect(x: 9.5, y: 8, width: 80.5, height: 64), safeRect: safe, tolerance: 0.5), "one physical pixel")
        try expect(!inside(CGRect(x: 9.49, y: 8, width: 80.51, height: 64), safeRect: safe, tolerance: 0.5), "more than one physical pixel")
        try expect(!inside(.zero, safeRect: safe, tolerance: 0.5), "missing/empty leaf cannot pass")
        try expect(!inside(safe, safeRect: .zero, tolerance: 0.5), "empty safe rectangle cannot pass")
        try expect(Insets.parse("safeInsets: 10.0,8.0; detailLevel: adaptive") == Insets(horizontal: 10, vertical: 8), "metadata")
        for value in ["safeInsets: nan,8", "safeInsets: -1,8", "safeInsets: 10", "detailLevel: full"] {
            try expect(Insets.parse(value) == nil, "invalid/missing insets")
        }
        let label = "QA caseID: test; kind: BeaverMeterWidgetQA; family: systemLarge; colorScheme: light; widgetRenderingMode: fullColor"
        let remote = Node(id: 0, parentID: nil, depth: 0, role: "AXGroup", identifier: casePrefix + "test",
                          label: label, value: nil, bounds: safe, hasChildren: true)
        try expect(metadata(remote)["kind"] == kind && metadata(remote)["family"] == "systemLarge", "remote description-only case")
        let merged = metadata(label: label, value: "family: systemSmall; colorScheme: dark")
        try expect(merged["kind"] == kind && merged["family"] == "systemSmall" && merged["colorScheme"] == "dark", "value authoritative, label-only keys preserved")
        try expect(Insets.parse(nil, label: "safeInsets: 10,8; detailLevel: adaptive") == Insets(horizontal: 10, vertical: 8), "description-only insets")
        try expect(Insets.parse("detailLevel: full", label: "safeInsets: 10,8") == Insets(horizontal: 10, vertical: 8), "partial value preserves label insets")
        try expect(Insets.parse("safeInsets: -1,8", label: "safeInsets: 10,8") == nil, "invalid authoritative value does not borrow label insets")
        let fit = Node(id: 0, parentID: nil, depth: 0, role: "AXGroup", identifier: fitPrefix + "0",
                       label: "detailLevel: full", value: nil, bounds: safe, hasChildren: true)
        try expect(metadata(fit)["detailLevel"] == "full", "description-only chosen fit")
        let logo = Node(id: 0, parentID: nil, depth: 0, role: "AXImage", identifier: leafPrefix + "logo",
                        label: "QA logo; detailLevel: withoutActivity", value: nil, bounds: safe, hasChildren: false)
        try expect(chosenDetail(fits: [fit], leaves: [logo]) == DetailChoice(level: "full", source: "fit-group"), "fit-group choice takes precedence")
        try expect(chosenDetail(fits: [], leaves: [logo]) == DetailChoice(level: "withoutActivity", source: "visible-logo"), "actual visible logo fallback")
        try expect(chosenDetail(fits: [], leaves: [logo, logo]) == nil, "duplicate visible logos cannot identify a variant")
        let absentLogo = Node(id: 0, parentID: nil, depth: 0, role: "AXImage", identifier: leafPrefix + "logo",
                              label: "QA logo; detailLevel: full", value: nil, bounds: nil, hasChildren: false)
        try expect(chosenDetail(fits: [], leaves: [absentLogo]) == nil, "logo without actual frame cannot identify a variant")
        let unknownLogo = Node(id: 0, parentID: nil, depth: 0, role: "AXImage", identifier: leafPrefix + "logo",
                               label: "QA logo; detailLevel: adaptive", value: nil, bounds: safe, hasChildren: false)
        try expect(chosenDetail(fits: [], leaves: [unknownLogo]) == nil && chosenDetail(fits: [], leaves: []) == nil, "missing or adaptive level cannot pass")
        try expect(chosenDetail(fits: [fit, fit], leaves: [logo]) == nil, "ambiguous fit wrappers cannot borrow logo metadata")
        let root = Node(id: 0, parentID: nil, depth: 0, role: "AXGroup", identifier: casePrefix + "test", label: nil, value: nil, bounds: safe, hasChildren: true)
        let card = Node(id: 1, parentID: 0, depth: 1, role: "AXGroup", identifier: cardPrefix + "group:test", label: nil, value: nil, bounds: safe, hasChildren: true)
        let leaf = Node(id: 2, parentID: 1, depth: 2, role: kAXStaticTextRole, identifier: nil, label: "Synthetic", value: nil, bounds: safe, hasChildren: false)
        try expect(closestCard(leaf, in: [root, card, leaf]) == 1 && descends(leaf, from: 0, in: [root, card, leaf]), "actual ancestry")
        let options = try Options(["--case", "antigravity-spacing-stress", "--family", "extra-large", "--appearance", "dark"])
        try expect(options.family == "systemExtraLarge" && options.appearance == "dark", "CLI filters")
        try write(["schemaVersion": 1, "scope": "private-widgetkit-qa-bounds-self-test", "status": "passed",
                   "readOnly": true, "accessibilityAccessed": false, "checks": checkCount])
    }
}
