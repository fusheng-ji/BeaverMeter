import CodexBarCore
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
        let refreshToken: String?
        let expiresAt: Double?
    }

    let claudeAiOauth: OAuth?
}

enum ClaudeQuotaError: LocalizedError, Equatable {
    case notLoggedIn
    case expired
    case rateLimited(retryAt: Date?)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: "Claude Code is not signed in. Choose Sign in to Claude."
        case .expired: "Claude sign-in expired and could not be renewed. Sign in again."
        case .rateLimited(let retryAt):
            "Rate limited by Anthropic." + (retryAt.map { " Retry after \($0.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: UsageFormatting.locale)))." } ?? "")
        }
    }
}

/// Failure to complete delegated renewal does not prove the stored refresh
/// grant was revoked. Keep these retryable conditions separate from a login
/// rejected by the usage endpoint, so the menu does not ask for another login.
enum ClaudeRenewalError: LocalizedError, Equatable {
    case disabled
    case cliUnavailable
    case retryLater
    case notCompleted

    var errorDescription: String? {
        switch self {
        case .disabled:
            "Automatic Claude renewal is disabled. Current quota cannot be verified until the saved credential is renewed."
        case .cliUnavailable:
            "Claude Code is unavailable for automatic renewal. BeaverMeter will retry when the CLI is available."
        case .retryLater:
            "Claude automatic renewal is waiting before retrying. BeaverMeter will try again automatically."
        case .notCompleted:
            "Claude automatic renewal has not completed. BeaverMeter will retry without starting a new login."
        }
    }
}

/// Reads the quota windows that Claude Code's `/usage` shows. BeaverMeter only
/// reads Claude Code's access token and delegates renewal to the installed CLI
/// so Claude Code remains responsible for refresh-token rotation.
enum ClaudeQuotaCollector {
    typealias CredentialReader = @Sendable ([String: String]) throws -> Data
    static func collect(
        previous: UsageValue<CompactQuota>,
        now: Date,
        stateDirectory: URL = UsageSnapshot.snapshotURL.deletingLastPathComponent(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> UsageValue<CompactQuota> {
        await ClaudeUsageCollector.collect(
            previousQuota: previous, previousCards: .unavailable("Reset cards have not been read."),
            now: now, stateDirectory: stateDirectory, environment: environment
        ).quota
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

    /// Uses only the document already read for this request; unknown metadata
    /// does not imply a free plan or require another credential/profile lookup.
    static func planName(fromCredentials data: Data) -> String? {
        guard let credentials = try? ClaudeOAuthCredentials.parse(data: data) else { return nil }
        return ClaudePlan.oauthLoginMethod(subscriptionType: credentials.subscriptionType,
                                          rateLimitTier: credentials.rateLimitTier)
    }

    /// An absent access token can still be repairable by Claude Code. Never
    /// start the CLI for a signed-out (both tokens empty) credential store.
    static func hasRefreshToken(inCredentials data: Data) -> Bool {
        guard let oauth = try? JSONDecoder().decode(ClaudeCredentialsFile.self, from: data).claudeAiOauth else {
            return false
        }
        return CodexUsageSupport.nonempty(oauth.refreshToken) != nil
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

    /// Asks Claude Code to renew its sign-in and reads the renewed token.
    static func renewedToken(
        now: Date,
        stateDirectory: URL,
        environment: [String: String],
        rejectedToken: String? = nil,
        cancellation: SubprocessCancellation? = nil,
        credentialReader: CredentialReader = credentialsData
    ) throws -> String {
        try ClaudeCredentialRenewal.renewedToken(
            now: now, stateDirectory: stateDirectory, environment: environment,
            rejectedToken: rejectedToken, cancellation: cancellation, credentialReader: credentialReader
        )
    }

    static func userAgent(environment: [String: String], cancellation: SubprocessCancellation? = nil) -> String {
        ClaudeCredentialRenewal.userAgent(environment: environment, cancellation: cancellation)
    }

    /// Claude Code keeps credentials in a file on Linux-style setups and in the
    /// login Keychain on macOS. Scheduled reads use the native, noninteractive
    /// Keychain reader and preserve access failures separately from sign-out.
    static func credentialsData(environment: [String: String]) throws -> Data {
        try ClaudeCredentialResolver.credentialsData(environment: environment)
    }
}
