import Foundation

struct ClaudeOAuthUsageResponse: Decodable {
    struct Window: Decodable {
        let utilization: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    let fiveHour: Window?
    let sevenDay: Window?
    let sevenDayOpus: Window?
    let sevenDaySonnet: Window?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
    }
}

private struct ClaudeCredentialsFile: Decodable {
    struct OAuth: Decodable {
        let accessToken: String?
        let expiresAt: Double?
    }

    let claudeAiOauth: OAuth?
}

enum ClaudeQuotaError: LocalizedError, Equatable {
    case notLoggedIn
    case expired
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: "Claude Code is not signed in."
        case .expired: "The Claude Code sign-in has expired; run `claude` to refresh it."
        case .rateLimited: "Anthropic is rate limiting usage requests; the next refresh will retry."
        }
    }
}

/// Reads the quota windows that Claude Code's `/usage` shows. BeaverMeter only
/// borrows Claude Code's access token and never refreshes it, because a refresh
/// would rotate the refresh token Claude Code itself depends on.
enum ClaudeQuotaCollector {
    private static let keychainService = "Claude Code-credentials"

    static func collect(
        previous: UsageValue<CompactQuota>,
        now: Date,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> UsageValue<CompactQuota> {
        do {
            let response = try await fetchResponse(now: now, environment: environment)
            guard let quota = tightestQuota(in: response, now: now) else {
                throw URLError(.cannotParseResponse)
            }
            return UsageValue(
                status: .ready,
                source: .accountAPI,
                measuredAt: now,
                lastAttemptAt: now,
                message: nil,
                value: quota
            )
        } catch {
            let status: UsageDataStatus = [.notLoggedIn, .expired].contains(error as? ClaudeQuotaError)
                ? .unauthenticated : .error
            return CollectorSupport.stale(
                previous: previous,
                attemptedAt: now,
                status: status,
                message: "Claude quota refresh failed: \(error.localizedDescription)"
            )
        }
    }

    /// The window with the least allowance left, like the Codex quota.
    static func tightestQuota(in response: ClaudeOAuthUsageResponse, now: Date) -> CompactQuota? {
        [
            makeQuota(response.fiveHour, label: "Claude 5h", seconds: 18_000),
            makeQuota(response.sevenDay, label: "Claude Week", seconds: 604_800),
            makeQuota(response.sevenDayOpus, label: "Claude Opus Week", seconds: 604_800),
            makeQuota(response.sevenDaySonnet, label: "Claude Sonnet Week", seconds: 604_800),
        ]
        .compactMap { $0 }
        .min { ($0.remainingPercent ?? 101) < ($1.remainingPercent ?? 101) }
    }

    static func accessToken(fromCredentials data: Data, now: Date) throws -> String {
        guard let oauth = try? JSONDecoder().decode(ClaudeCredentialsFile.self, from: data).claudeAiOauth,
              let token = CodexUsageSupport.nonempty(oauth.accessToken)
        else {
            throw ClaudeQuotaError.notLoggedIn
        }
        if let expiresAt = oauth.expiresAt, Date(timeIntervalSince1970: expiresAt / 1_000) <= now {
            throw ClaudeQuotaError.expired
        }
        return token
    }

    private static func makeQuota(
        _ window: ClaudeOAuthUsageResponse.Window?,
        label: String,
        seconds: Int
    ) -> CompactQuota? {
        guard let used = window?.utilization else { return nil }
        let remaining = min(max(100 - used, 0), 100)
        return CompactQuota(
            label: label,
            used: nil,
            limit: nil,
            remaining: nil,
            remainingPercent: remaining,
            resetAt: CollectorSupport.parseISODate(window?.resetsAt),
            windowSeconds: seconds,
            detail: "\(Int(remaining.rounded()))% left"
        )
    }

    private static func fetchResponse(
        now: Date,
        environment: [String: String]
    ) async throws -> ClaudeOAuthUsageResponse {
        if let fixture = environment["CLAUDE_USAGE_FIXTURE"] {
            return try JSONDecoder().decode(
                ClaudeOAuthUsageResponse.self,
                from: Data(contentsOf: URL(fileURLWithPath: fixture))
            )
        }

        let token = try accessToken(fromCredentials: credentialsData(environment: environment), now: now)
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 12
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")

        let (data, urlResponse) = try await URLSession.shared.data(for: request)
        guard let http = urlResponse as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        switch http.statusCode {
        case 200: return try JSONDecoder().decode(ClaudeOAuthUsageResponse.self, from: data)
        case 401, 403: throw ClaudeQuotaError.expired
        case 429: throw ClaudeQuotaError.rateLimited
        default: throw URLError(.badServerResponse)
        }
    }

    /// Claude Code keeps credentials in a file on Linux-style setups and in the
    /// login Keychain on macOS. The Keychain item is read through `security`,
    /// which Claude Code itself uses to write it.
    private static func credentialsData(environment: [String: String]) throws -> Data {
        let configRoot = CodexUsageSupport.nonempty(environment["CLAUDE_CONFIG_DIR"])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        if let data = try? Data(contentsOf: configRoot.appendingPathComponent(".credentials.json")) {
            return data
        }
        guard environment["CLAUDE_KEYCHAIN_ACCESS"] != "0" else {
            throw ClaudeQuotaError.notLoggedIn
        }
        let result = try SubprocessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/security"),
            arguments: ["find-generic-password", "-s", keychainService, "-w"],
            timeout: 10
        )
        guard result.status == 0, !result.timedOut else {
            throw ClaudeQuotaError.notLoggedIn
        }
        return result.standardOutput
    }
}
