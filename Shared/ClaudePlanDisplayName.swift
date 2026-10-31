import Foundation

/// Current names for Claude subscription metadata and older stored display labels.
/// Naming does not establish which quota windows an account is entitled to use.
enum ClaudePlanDisplayName {
    static func fromMetadata(subscriptionType: String?, rateLimitTier: String?) -> String? {
        let subscription = recognizedPlan(subscriptionType)
        let tier = recognizedPlan(rateLimitTier)
        if subscription == .ultra { return Plan.ultra.label }
        if subscription == .max {
            // The legacy subscription type is just "max" for both old tiers.
            return (tier == .ultra ? Plan.ultra : Plan.max).label
        }
        return (subscription ?? tier)?.label
    }

    /// Unknown nonempty display labels remain display labels rather than being
    /// interpreted as a new subscription or a free account.
    static func normalizeLabel(_ label: String?) -> String? {
        guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return nil }
        return recognizedPlan(label)?.label ?? label
    }

    private enum Plan {
        case pro, max, ultra, team, enterprise

        var label: String {
            switch self {
            case .pro: "Claude Pro"
            case .max: "Claude Max"
            case .ultra: "Claude Ultra"
            case .team: "Claude Team"
            case .enterprise: "Claude Enterprise"
            }
        }
    }

    private static func recognizedPlan(_ text: String?) -> Plan? {
        var words = (text ?? "").lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if words.first == "default" { words.removeFirst() }
        if words.first == "claude" { words.removeFirst() }
        switch words {
        case ["pro"]: return .pro
        case ["max"], ["max", "5x"]: return .max
        case ["ultra"], ["max", "20x"]: return .ultra
        case ["team"]: return .team
        case ["enterprise"]: return .enterprise
        default: return nil
        }
    }
}
