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

    /// The newer flat list that also carries model-scoped weekly limits such as Fable.
    struct Limit: Decodable {
        struct Scope: Decodable {
            struct Model: Decodable {
                let displayName: String?

                enum CodingKeys: String, CodingKey {
                    case displayName = "display_name"
                }
            }

            let model: Model?
        }

        let kind: String?
        let percent: Double?
        let resetsAt: String?
        let scope: Scope?

        enum CodingKeys: String, CodingKey {
            case kind, percent, scope
            case resetsAt = "resets_at"
        }

        var window: Window { Window(utilization: percent, resetsAt: resetsAt) }
    }

    let fiveHour: Window?
    let sevenDay: Window?
    let sevenDayOpus: Window?
    let sevenDaySonnet: Window?
    let limits: [Limit]?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case limits
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
        case .expired: "Claude Code could not renew its sign-in; run `claude` and `/login`."
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
        stateDirectory: URL = UsageSnapshot.snapshotURL.deletingLastPathComponent(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> UsageValue<CompactQuota> {
        do {
            let response = try await fetchResponse(now: now, stateDirectory: stateDirectory, environment: environment)
            guard let quota = quota(from: response) else {
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

    /// The five-hour window (the tightest one when there is none), carrying every
    /// window in display order: five hours, the all-models week, then
    /// model-scoped weeks (for example Fable).
    static func quota(from response: ClaudeOAuthUsageResponse) -> CompactQuota? {
        let limits = response.limits ?? []
        func limit(_ kind: String) -> ClaudeOAuthUsageResponse.Window? {
            limits.first { $0.kind == kind }?.window
        }
        var windows = [
            makeQuota(response.fiveHour ?? limit("session"), label: "Claude 5h", seconds: 18_000),
            makeQuota(response.sevenDay ?? limit("weekly_all"), label: "Claude Week", seconds: 604_800),
        ].compactMap { $0 }
        // `is_active` is not a filter: enforced scoped limits have been observed reporting false.
        let scoped = limits.filter { $0.kind == "weekly_scoped" }.compactMap { limit -> (String, ClaudeOAuthUsageResponse.Window)? in
            guard let name = CodexUsageSupport.nonempty(limit.scope?.model?.displayName),
                  name.caseInsensitiveCompare("All models") != .orderedSame
            else { return nil }
            return (name, limit.window)
        }
        for (name, window) in scoped + [("Opus", response.sevenDayOpus), ("Sonnet", response.sevenDaySonnet)]
            .compactMap({ name, window in window.map { (name, $0) } }) {
            let label = "Claude \(name) Week"
            guard !windows.contains(where: { $0.label == label }),
                  let quota = makeQuota(window, label: label, seconds: 604_800)
            else { continue }
            windows.append(quota)
        }
        guard var headline = windows.first(where: { $0.windowSeconds == 18_000 })
                ?? windows.min(by: { ($0.remainingPercent ?? 101) < ($1.remainingPercent ?? 101) })
        else { return nil }
        headline.windows = windows.count > 1 ? windows : nil
        return headline
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
        stateDirectory: URL,
        environment: [String: String]
    ) async throws -> ClaudeOAuthUsageResponse {
        if let fixture = environment["CLAUDE_USAGE_FIXTURE"] {
            return try JSONDecoder().decode(
                ClaudeOAuthUsageResponse.self,
                from: Data(contentsOf: URL(fileURLWithPath: fixture))
            )
        }

        let token: String
        do {
            token = try accessToken(fromCredentials: credentialsData(environment: environment), now: now)
        } catch ClaudeQuotaError.expired {
            token = try renewedToken(now: now, stateDirectory: stateDirectory, environment: environment)
        }
        do {
            return try await usage(token: token)
        } catch ClaudeQuotaError.expired {
            // The token looked valid but was revoked or rotated; one renewal, one retry.
            return try await usage(
                token: renewedToken(now: now, stateDirectory: stateDirectory, environment: environment)
            )
        }
    }

    /// Asks Claude Code to renew its sign-in and reads the renewed token.
    private static func renewedToken(
        now: Date,
        stateDirectory: URL,
        environment: [String: String]
    ) throws -> String {
        guard ClaudeSignInRenewer.isAllowed(environment: environment),
              let cli = ClaudeSignInRenewer.cliURL(environment: environment),
              ClaudeSignInRenewer.reserveAttempt(
                  stateURL: stateDirectory.appendingPathComponent("beaver-meter-claude-refresh-v1.json"), now: now
              )
        else { throw ClaudeQuotaError.expired }
        let isRenewed = {
            (try? accessToken(fromCredentials: credentialsData(environment: environment), now: Date())) != nil
        }
        guard ClaudeSignInRenewer.renew(
            cli: cli,
            workingDirectory: stateDirectory.appendingPathComponent("claude-sign-in", isDirectory: true),
            isRenewed: isRenewed
        ) else { throw ClaudeQuotaError.expired }
        return try accessToken(fromCredentials: credentialsData(environment: environment), now: Date())
    }

    private static func usage(token: String) async throws -> ClaudeOAuthUsageResponse {
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
