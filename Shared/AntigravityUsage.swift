import Foundation

enum AntigravityQuotaGroupID: String, Codable, CaseIterable, Hashable, Sendable {
    case gemini
    case claudeGPT = "claude-gpt"

    var title: String {
        switch self {
        case .gemini: "Gemini"
        case .claudeGPT: "Claude/GPT"
        }
    }

    var moduleID: String { "antigravity-group:\(rawValue)" }
}

struct AntigravityQuotaGroup: Codable, Hashable, Identifiable, Sendable {
    let id: AntigravityQuotaGroupID
    let windows: [CompactQuota]
}

/// Independent allowance pools, never added together or inferred from local tokens.
struct AntigravityQuotaSnapshot: Codable, Hashable, Sendable {
    let groups: [AntigravityQuotaGroup]
    let planName: String?
    /// One-way account discriminator; the upstream email is not persisted.
    let accountID: String?

    init(groups: [AntigravityQuotaGroup], planName: String? = nil, accountID: String? = nil) {
        self.groups = groups
        self.planName = planName
        self.accountID = accountID
    }
}

/// Antigravity reports cache and reasoning counters as separate additive categories.
struct AntigravityTokenTotals: DailyTokenTotals {
    static let providerName = "Antigravity"

    let totalTokens: Int
    let inputTokens: Int?
    let cacheReadTokens: Int?
    let cacheCreationTokens: Int?
    let outputTokens: Int?
    let reasoningTokens: Int?
    let requestCount: Int?
}
