import Foundation

enum UsageDataStatus: String, Codable, Hashable, Sendable {
    case ready
    case stale
    case unavailable
    case unauthenticated
    case error
}

enum UsageDataSource: String, Codable, Hashable, Sendable {
    case codexBarLocal
    case cursorDashboard
    case accountAPI
    case deepSeekPlatform
    case cache
    case preview
    case none
}

struct UsageValue<Value: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    let status: UsageDataStatus
    let source: UsageDataSource
    let measuredAt: Date?
    let lastAttemptAt: Date
    let message: String?
    let value: Value?

    var isStale: Bool { status == .stale || source == .cache }

    func age(at date: Date = .now) -> TimeInterval? {
        measuredAt.map { max(0, date.timeIntervalSince($0)) }
    }

    static func unavailable(_ message: String) -> Self {
        Self(
            status: .unavailable,
            source: .none,
            measuredAt: nil,
            lastAttemptAt: .now,
            message: message,
            value: nil
        )
    }
}

/// Daily token totals shown with the "hide values from a previous day" policy.
protocol DailyTokenTotals: Codable, Hashable, Sendable {
    static var providerName: String { get }
    var totalTokens: Int { get }
}

struct CodexTokenTotals: DailyTokenTotals {
    static let providerName = "Codex"

    let totalTokens: Int
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let sessionCount: Int
}

/// Claude's `input_tokens` excludes cache traffic, so the total adds both cache
/// counters to match Codex's "input including cached + output" semantics.
struct ClaudeTokenTotals: DailyTokenTotals {
    static let providerName = "Claude"

    let totalTokens: Int
    let inputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let outputTokens: Int
    /// Estimated at API list prices; subscription plans are not billed per token.
    let costUSD: Double?
}

struct CursorCostEvent: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let occurredAt: Date
    let model: String
    let costUSD: Double?
    let tokenCount: Int?
    let kind: String?
}

struct CursorCostTotals: Codable, Hashable, Sendable {
    let todayCostUSD: Double?
    let recentEvents: [CursorCostEvent]

    var latestEvent: CursorCostEvent? { recentEvents.first }
}

struct CompactQuota: Codable, Hashable, Sendable {
    let label: String
    let used: Double?
    let limit: Double?
    let remaining: Double?
    let remainingPercent: Double?
    let resetAt: Date?
    let windowSeconds: Int?
    let detail: String
    /// Every window from the same response, display order; nil for single-window services.
    var windows: [CompactQuota]? = nil
}

struct DeepSeekMoney: Codable, Hashable, Identifiable, Sendable {
    var id: String { currency }
    let currency: String
    let amount: Double
}

struct DeepSeekUsageTotals: Codable, Hashable, Sendable {
    let monthTokens: Int?
    let monthRequests: Int?
    let monthCosts: [DeepSeekMoney]
    let balances: [DeepSeekMoney]
    let grantedBalances: [DeepSeekMoney]
    let totalCosts: [DeepSeekMoney]
}
