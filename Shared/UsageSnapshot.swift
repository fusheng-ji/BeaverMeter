import Foundation

struct UsageSnapshot: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 7
    enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedAt, codexTokens, cursorCosts, cursorQuota, codexQuota
        case claudeTokens, claudeQuota, deepseekUsage, codexAccounts, codexHistory, claudeHistory, claudeResetCards
    }

    let schemaVersion: Int
    let generatedAt: Date
    let codexTokens: UsageValue<CodexTokenTotals>
    let cursorCosts: UsageValue<CursorCostTotals>
    let cursorQuota: UsageValue<CompactQuota>
    let codexQuota: UsageValue<CompactQuota>
    let claudeTokens: UsageValue<ClaudeTokenTotals>
    let claudeQuota: UsageValue<CompactQuota>
    let deepseekUsage: UsageValue<DeepSeekUsageTotals>
    var codexAccounts: UsageValue<[CodexAccountUsage]> = .unavailable("No Codex accounts collected yet.")
    var codexHistory: UsageValue<TokenHistory<CodexTokenTotals>> = .unavailable("No seven-day Codex history yet.")
    var claudeHistory: UsageValue<TokenHistory<ClaudeTokenTotals>> = .unavailable("No seven-day Claude history yet.")
    var claudeResetCards: UsageValue<ResetCardInventory> = .unavailable("Claude reset cards have not been read yet.")

    static let unavailable = UsageSnapshot(
        schemaVersion: Self.currentSchemaVersion,
        generatedAt: .now,
        codexTokens: .unavailable("Run Codex once so local session logs are available."),
        cursorCosts: .unavailable("Open Cursor and sign in to view model-call costs."),
        cursorQuota: .unavailable("Open Cursor and sign in to view Monthly usage."),
        codexQuota: .unavailable("Sign in to Codex to view the current quota window."),
        claudeTokens: .unavailable("Run Claude Code once so local session logs are available."),
        claudeQuota: .unavailable("Sign in to Claude Code to view the current quota window."),
        deepseekUsage: .unavailable("Connect DeepSeek in your browser to view account usage and balance.")
    )
}
