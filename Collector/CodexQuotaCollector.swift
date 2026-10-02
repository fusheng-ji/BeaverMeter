import CodexBarCore
import Foundation

private struct CodexUsageResponse: Decodable {
    struct RateLimit: Decodable {
        let primaryWindow: Window?
        let secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct Window: Decodable {
        let usedPercent: Double?
        let resetAt: Double?
        let resetAfterSeconds: Double?
        let limitWindowSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case resetAfterSeconds = "reset_after_seconds"
            case limitWindowSeconds = "limit_window_seconds"
        }
    }

    struct Credits: Decodable {
        let unlimited: Bool?
        let hasCredits: Bool?
        let balance: String?

        enum CodingKeys: String, CodingKey {
            case unlimited
            case hasCredits = "has_credits"
            case balance
        }
    }

    let rateLimit: RateLimit?
    let credits: Credits?
    let accountID: String?
    let planType: String?

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
        case credits
        case accountID = "account_id"
        case accountIDCamel = "accountId"
        case planType = "plan_type"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rateLimit = try container.decodeIfPresent(RateLimit.self, forKey: .rateLimit)
        credits = try container.decodeIfPresent(Credits.self, forKey: .credits)
        accountID = try container.decodeIfPresent(String.self, forKey: .accountID)
            ?? container.decodeIfPresent(String.self, forKey: .accountIDCamel)
        planType = try container.decodeIfPresent(String.self, forKey: .planType)
    }
}

private enum CodexQuotaError: LocalizedError {
    case notLoggedIn
    case workspaceMismatch

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: "Codex is not signed in to this workspace."
        case .workspaceMismatch: "The response could not be verified for this workspace. Sign in to it in a separate Codex profile."
        }
    }
}

enum CodexQuotaCollector {
    static func collect(
        previous: UsageValue<CompactQuota>,
        now: Date,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        includeAllWindows: Bool = false,
        credentials: CodexOAuthCredentials? = nil,
        workspaceAccountID: String? = nil
    ) async -> UsageValue<CompactQuota> {
        do {
            let response = try await fetchResponse(environment: environment, credentials: credentials,
                                                   workspaceAccountID: workspaceAccountID)
            let windows = [
                response.rateLimit?.primaryWindow,
                response.rateLimit?.secondaryWindow
            ].compactMap { $0 }.compactMap { window in
                makeQuota(window: window, now: now)
            }

            var quota: CompactQuota
            if let tightest = windows.min(by: {
                ($0.remainingPercent ?? 101) < ($1.remainingPercent ?? 101)
            }) {
                var headline = tightest
                if includeAllWindows { headline.windows = windows }
                quota = headline
            } else if response.credits?.unlimited == true {
                quota = CompactQuota(
                    label: "Codex credits",
                    used: nil,
                    limit: nil,
                    remaining: nil,
                    remainingPercent: nil,
                    resetAt: nil,
                    windowSeconds: nil,
                    detail: "Unlimited"
                )
            } else if response.credits?.hasCredits == true {
                quota = CompactQuota(
                    label: "Codex credits",
                    used: nil,
                    limit: nil,
                    remaining: nil,
                    remainingPercent: nil,
                    resetAt: nil,
                    windowSeconds: nil,
                    detail: "Balance \(response.credits?.balance ?? "available")"
                )
            } else {
                throw URLError(.cannotParseResponse)
            }

            quota.planName = planName(response.planType)
            return UsageValue(
                status: .ready,
                source: .accountAPI,
                measuredAt: now,
                lastAttemptAt: now,
                message: nil,
                value: quota
            )
        } catch {
            let status: UsageDataStatus = error is CodexQuotaError || error is CodexOAuthCredentialsError
                ? .unauthenticated : .error
            return CollectorSupport.stale(
                previous: previous,
                attemptedAt: now,
                status: status,
                message: "Codex quota refresh failed: \(error.localizedDescription)"
            )
        }
    }

    static func planName(_ value: String?) -> String? {
        guard let value = CodexUsageSupport.nonempty(value) else { return nil }
        return value.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func fetchResponse(environment: [String: String], credentials: CodexOAuthCredentials?,
                                      workspaceAccountID: String?) async throws -> CodexUsageResponse {
        if let fixture = environment["CODEX_USAGE_FIXTURE"] {
            return try decodeResponse(Data(contentsOf: URL(fileURLWithPath: fixture)),
                                      credentials: credentials, workspaceAccountID: workspaceAccountID)
        }

        let auth = try credentials ?? CodexOAuthCredentialsStore.loadOAuthTokens(env: environment)
        guard !auth.accessToken.isEmpty, !auth.isAPIKey else {
            throw CodexQuotaError.notLoggedIn
        }

        let request = usageRequest(credentials: auth, workspaceAccountID: workspaceAccountID)

        let (data, urlResponse) = try await URLSession.shared.data(for: request)
        guard let http = urlResponse as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw CodexQuotaError.notLoggedIn
        }
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try decodeResponse(data, credentials: auth, workspaceAccountID: workspaceAccountID)
    }

    static func usageRequest(credentials auth: CodexOAuthCredentials, workspaceAccountID: String?) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.timeoutInterval = 12
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        if let accountID = workspaceAccountID ?? auth.accountId, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        return request
    }

    private static func decodeResponse(_ data: Data, credentials: CodexOAuthCredentials?,
                                        workspaceAccountID: String?) throws -> CodexUsageResponse {
        let response = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        let expected = workspaceAccountID ?? credentials?.accountId
        if let returned = response.accountID, let expected,
           returned.lowercased() != expected.lowercased() { throw CodexQuotaError.workspaceMismatch }
        // Some endpoints silently ignore a non-default workspace header. Never
        // publish the default workspace's usage as another workspace's reading.
        if let workspaceAccountID,
           workspaceAccountID.lowercased() != credentials?.accountId?.lowercased(),
           response.accountID == nil { throw CodexQuotaError.workspaceMismatch }
        return response
    }

    private static func makeQuota(
        window: CodexUsageResponse.Window,
        now: Date
    ) -> CompactQuota? {
        guard let seconds = window.limitWindowSeconds,
              seconds > 0,
              let used = window.usedPercent else {
            return nil
        }
        let remaining = min(max(100 - used, 0), 100)
        let reset = window.resetAt.map { Date(timeIntervalSince1970: $0) }
            ?? window.resetAfterSeconds.map { now.addingTimeInterval($0) }
        let label: String
        if seconds == 604_800 {
            label = "Codex Week"
        } else if seconds % 86_400 == 0 {
            label = "Codex \(seconds / 86_400)d"
        } else if seconds % 3_600 == 0 {
            label = "Codex \(seconds / 3_600)h"
        } else {
            label = "Codex quota"
        }
        return CompactQuota(
            label: label,
            used: nil,
            limit: nil,
            remaining: nil,
            remainingPercent: remaining,
            resetAt: reset,
            windowSeconds: seconds,
            detail: "\(Int(remaining.rounded()))% left"
        )
    }
}
