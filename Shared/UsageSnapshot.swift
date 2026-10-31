import Foundation

struct UsageSnapshot: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 8
    enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedAt, codexTokens, cursorCosts, cursorQuota, codexQuota
        case claudeTokens, claudeQuota, deepseekUsage, codexAccounts, codexHistory, claudeHistory, claudeResetCards
        case antigravityQuota, antigravityTokens
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
    var antigravityQuota: UsageValue<AntigravityQuotaSnapshot> = .unavailable("Open Antigravity or install its official agy CLI to read quota.")
    var antigravityTokens: UsageValue<AntigravityTokenTotals> = .unavailable("No local Antigravity token logs are available yet.")

    /// ISO-8601 snapshots have second precision. A login verification can replace
    /// an earlier reading in the same second and must still reach the menu.
    func supersedes(_ previous: UsageSnapshot) -> Bool {
        generatedAt >= previous.generatedAt && self != previous
    }

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

// Decoding belongs to the shared model, including isolated synthetic QA builds.
extension UsageSnapshot {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try c.decode(Int.self, forKey: .schemaVersion),
            generatedAt: try c.decode(Date.self, forKey: .generatedAt),
            codexTokens: try c.decode(UsageValue<CodexTokenTotals>.self, forKey: .codexTokens),
            cursorCosts: try c.decode(UsageValue<CursorCostTotals>.self, forKey: .cursorCosts),
            cursorQuota: try c.decode(UsageValue<CompactQuota>.self, forKey: .cursorQuota),
            codexQuota: try c.decode(UsageValue<CompactQuota>.self, forKey: .codexQuota),
            claudeTokens: try c.decodeIfPresent(UsageValue<ClaudeTokenTotals>.self, forKey: .claudeTokens)
                ?? Self.unavailable.claudeTokens,
            claudeQuota: try c.decodeIfPresent(UsageValue<CompactQuota>.self, forKey: .claudeQuota)
                ?? Self.unavailable.claudeQuota,
            deepseekUsage: try c.decode(UsageValue<DeepSeekUsageTotals>.self, forKey: .deepseekUsage),
            codexAccounts: try c.decodeIfPresent(UsageValue<[CodexAccountUsage]>.self, forKey: .codexAccounts)
                ?? Self.unavailable.codexAccounts,
            codexHistory: try c.decodeIfPresent(UsageValue<TokenHistory<CodexTokenTotals>>.self, forKey: .codexHistory)
                ?? Self.unavailable.codexHistory,
            claudeHistory: try c.decodeIfPresent(UsageValue<TokenHistory<ClaudeTokenTotals>>.self, forKey: .claudeHistory)
                ?? Self.unavailable.claudeHistory,
            claudeResetCards: try c.decodeIfPresent(UsageValue<ResetCardInventory>.self, forKey: .claudeResetCards)
                ?? Self.unavailable.claudeResetCards,
            antigravityQuota: try c.decodeIfPresent(UsageValue<AntigravityQuotaSnapshot>.self, forKey: .antigravityQuota)
                ?? Self.unavailable.antigravityQuota,
            antigravityTokens: try c.decodeIfPresent(UsageValue<AntigravityTokenTotals>.self, forKey: .antigravityTokens)
                ?? Self.unavailable.antigravityTokens
        )
    }
}
