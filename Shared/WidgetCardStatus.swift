import Foundation

/// Widget-only policy; menu labels and snapshot status remain unchanged.
struct WidgetCardStatus: Equatable {
    let severity: UsageStatusPresentation.Severity
    let detail: String

    var icon: String {
        severity == .normal ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    init(_ primary: UsageStatusPresentation, supplemental: UsageStatusPresentation? = nil) {
        let statuses = [primary, supplemental].compactMap { $0 }
        severity = statuses.map(\.severity).max { Self.rank($0) < Self.rank($1) } ?? .normal
        detail = statuses.map(\.detail).joined(separator: "; ")
    }

    private static func rank(_ severity: UsageStatusPresentation.Severity) -> Int {
        switch severity {
        case .normal: 0
        case .warning: 1
        case .critical: 2
        }
    }
}
