import CodexBarCore
import Foundation

/// Official profile statistics, scoped to the OAuth token's own verified default workspace.
/// Daily buckets retain the service's date strings because the service declares no time zone.
enum CodexWorkspaceTokenAPICollector {
    static let cacheLifetime: TimeInterval = 3 * 60 * 60
    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/profiles/me")!

    enum Failure: Error {
        case unauthenticated
        case workspaceMismatch
        case invalidResponse
        case statisticsUnavailable
        case noStatistics
        case http(Int)
    }

    private struct Profile: Decodable {
        struct Stats: Decodable {
            struct Bucket: Decodable {
                let startDate: String
                let tokens: Int
                enum CodingKeys: String, CodingKey { case startDate = "start_date", tokens }
            }
            let dailyUsageBuckets: [Bucket]?
            let lifetimeTokens: Int?
            enum CodingKeys: String, CodingKey {
                case dailyUsageBuckets = "daily_usage_buckets", lifetimeTokens = "lifetime_tokens"
            }
        }
        struct Metadata: Decodable {
            let statsAsOf: String?
            let generatedAt: String?
            let hasStatisticsError: Bool
            enum CodingKeys: String, CodingKey {
                case statsAsOf = "stats_as_of", generatedAt = "generated_at", statsError = "stats_error"
            }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                statsAsOf = try container.decodeIfPresent(String.self, forKey: .statsAsOf)
                generatedAt = try container.decodeIfPresent(String.self, forKey: .generatedAt)
                // Never retain or display an arbitrary server error body.
                if container.contains(.statsError) { hasStatisticsError = try !container.decodeNil(forKey: .statsError) }
                else { hasStatisticsError = false }
            }
        }
        let stats: Stats?
        let metadata: Metadata?
        let returnedAccountIDs: [String]
        enum CodingKeys: String, CodingKey {
            case stats, metadata, accountID = "account_id", accountIDCamel = "accountId"
        }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            stats = try container.decodeIfPresent(Stats.self, forKey: .stats)
            metadata = try container.decodeIfPresent(Metadata.self, forKey: .metadata)
            returnedAccountIDs = try [container.decodeIfPresent(String.self, forKey: .accountID),
                                     container.decodeIfPresent(String.self, forKey: .accountIDCamel)].compactMap { $0 }
        }
    }

    static func collect(
        credentials: CodexOAuthCredentials, workspaceAccountID: String,
        previous: UsageValue<CodexAccountTokenActivity>?, now: Date, environment: [String: String]
    ) async -> UsageValue<CodexAccountTokenActivity> {
        let scope: String
        do { scope = try verifiedWorkspaceID(credentials: credentials, workspaceAccountID: workspaceAccountID) }
        catch { return failed(error, previous: nil, workspaceAccountID: workspaceAccountID, now: now) }
        do {
            let data: Data
            if let fixture = environment["CODEX_WORKSPACE_TOKENS_FIXTURE"] {
                var isDirectory: ObjCBool = false
                let fixtureURL = URL(fileURLWithPath: fixture)
                let scopedFixture = FileManager.default.fileExists(atPath: fixture, isDirectory: &isDirectory) && isDirectory.boolValue
                    ? fixtureURL.appendingPathComponent(CodexUsageSupport.hash(scope) + ".json") : fixtureURL
                data = try Data(contentsOf: scopedFixture)
            } else if environment.keys.contains(where: { $0.hasSuffix("_FIXTURE") }) {
                // Every fixture run must remain isolated from additional live account requests.
                return empty(.unavailable, now: now, message: "No workspace token statistics fixture provided.")
            } else {
                let request = try request(credentials: credentials, workspaceAccountID: scope)
                let session = URLSession(configuration: configuration(), delegate: RejectRedirects(), delegateQueue: nil)
                defer { session.invalidateAndCancel() }
                let (body, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, http.url == endpoint else { throw Failure.invalidResponse }
                guard http.statusCode == 200 else { throw Failure.http(http.statusCode) }
                data = body
            }
            let activity = try decodeResponse(data, workspaceAccountID: scope)
            return UsageValue(status: .ready, source: .accountAPI, measuredAt: now,
                              lastAttemptAt: now, message: reportDescription(activity, queriedAt: now), value: activity)
        } catch {
            return failed(error, previous: previous, workspaceAccountID: scope, now: now)
        }
    }

    static func verifiedWorkspaceID(credentials: CodexOAuthCredentials, workspaceAccountID: String) throws -> String {
        guard !credentials.isAPIKey, CodexUsageSupport.nonempty(credentials.accessToken) != nil,
              let selected = normalized(workspaceAccountID), let credentialScope = normalized(credentials.accountId),
              let payload = UsageFetcher.parseJWT(credentials.accessToken),
              let claims = payload["https://api.openai.com/auth"] as? [String: Any],
              let tokenScope = normalized(claims["chatgpt_account_id"] as? String) else { throw Failure.unauthenticated }
        guard selected == credentialScope, selected == tokenScope else { throw Failure.workspaceMismatch }
        if let directClaim = payload["chatgpt_account_id"] {
            guard let directScope = normalized(directClaim as? String), directScope == selected else { throw Failure.workspaceMismatch }
        }
        if let idToken = credentials.idToken {
            guard let idPayload = UsageFetcher.parseJWT(idToken),
                  let idClaims = idPayload["https://api.openai.com/auth"] as? [String: Any],
                  normalized(idClaims["chatgpt_account_id"] as? String) == selected else { throw Failure.workspaceMismatch }
            if let directClaim = idPayload["chatgpt_account_id"] {
                guard normalized(directClaim as? String) == selected else { throw Failure.workspaceMismatch }
            }
        }
        return selected
    }

    static func request(credentials: CodexOAuthCredentials, workspaceAccountID: String) throws -> URLRequest {
        let scope = try verifiedWorkspaceID(credentials: credentials, workspaceAccountID: workspaceAccountID)
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(scope, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 12
        return configuration
    }

    static func decodeResponse(_ data: Data, workspaceAccountID: String) throws -> CodexAccountTokenActivity {
        guard let scope = normalized(workspaceAccountID) else { throw Failure.workspaceMismatch }
        let profile: Profile
        do { profile = try JSONDecoder().decode(Profile.self, from: data) }
        catch { throw Failure.invalidResponse }
        guard profile.returnedAccountIDs.allSatisfy({ normalized($0) == scope }) else { throw Failure.workspaceMismatch }
        guard profile.metadata?.hasStatisticsError != true else { throw Failure.statisticsUnavailable }
        guard let stats = profile.stats else { throw Failure.noStatistics }
        let days = try stats.dailyUsageBuckets.map { buckets in
            try validatedDays(buckets.map { CodexAccountTokenDay(date: $0.startDate, tokens: $0.tokens) })
        }
        guard stats.lifetimeTokens.map({ $0 >= 0 }) ?? true else { throw Failure.invalidResponse }
        if let asOf = profile.metadata?.statsAsOf, !validStatisticsDate(asOf) { throw Failure.invalidResponse }
        var activity = CodexAccountTokenActivity(workspaceAccountIDHash: CodexUsageSupport.hash(scope), dailyUsage: days,
            lifetimeTokens: stats.lifetimeTokens, statsAsOf: profile.metadata?.statsAsOf)
        if let generatedAt = profile.metadata?.generatedAt {
            guard let date = serviceTimestamp(generatedAt) else { throw Failure.invalidResponse }
            // Response generation is independent of the service's statistical date label.
            activity.serviceGeneratedAt = date
        }
        return activity
    }

    /// Kept internal so response/status/cache behavior can be tested without any network request.
    static func failed(_ error: Error, previous: UsageValue<CodexAccountTokenActivity>?,
                       workspaceAccountID: String, now: Date) -> UsageValue<CodexAccountTokenActivity> {
        let failure = error as? Failure
        if case .unauthenticated? = failure {
            return empty(.unauthenticated, now: now, message: "Sign in to this Codex workspace to read official token statistics.")
        }
        if case .workspaceMismatch? = failure {
            return empty(.unauthenticated, now: now, message: "The token statistics request could not be verified for this workspace.")
        }
        if case .http(let status)? = failure, status == 401 || status == 403 {
            return empty(.unauthenticated, now: now, message: "Sign in to this Codex workspace to read official token statistics.")
        }
        let transient: Bool
        switch failure {
        case .statisticsUnavailable?: transient = true
        case .http(let status)?: transient = status == 429 || (500...599).contains(status)
        default: transient = error is URLError
        }
        if transient, let scope = normalized(workspaceAccountID), let previous,
           [.ready, .stale].contains(previous.status), [.accountAPI, .cache].contains(previous.source),
           let measuredAt = previous.measuredAt, measuredAt <= now, now.timeIntervalSince(measuredAt) <= cacheLifetime,
           let value = previous.value, value.workspaceAccountIDHash == CodexUsageSupport.hash(scope),
           (try? validatedDays(value.dailyUsage ?? [])) != nil,
           value.lifetimeTokens.map({ $0 >= 0 }) ?? true,
           value.statsAsOf.map(validStatisticsDate) ?? true,
           value.serviceGeneratedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true {
            return UsageValue(status: .stale, source: .cache, measuredAt: measuredAt, lastAttemptAt: now,
                message: "Official workspace token statistics could not be refreshed; retaining the recent reading. "
                    + reportDescription(value, queriedAt: measuredAt), value: value)
        }
        if case .noStatistics? = failure {
            return empty(.unavailable, now: now, message: "Official token statistics are not available for this workspace.")
        }
        return empty(.error, now: now, message: "Official workspace token statistics could not be refreshed.")
    }

    private static func validatedDays(_ days: [CodexAccountTokenDay]) throws -> [CodexAccountTokenDay] {
        var byDate: [String: Int] = [:]
        for day in days {
            guard validDate(day.date), day.tokens >= 0 else { throw Failure.invalidResponse }
            if let previous = byDate[day.date], previous != day.tokens { throw Failure.invalidResponse }
            byDate[day.date] = day.tokens
        }
        return byDate.sorted { $0.key < $1.key }.map { CodexAccountTokenDay(date: $0.key, tokens: $0.value) }
    }

    private static func validDate(_ value: String) -> Bool {
        CodexAccountTokenDay.parseCalendarDate(value) != nil
    }

    private static func validStatisticsDate(_ value: String) -> Bool {
        validDate(value) || serviceTimestamp(value) != nil
    }

    private static func serviceTimestamp(_ value: String) -> Date? {
        guard value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](?:\.[0-9]+)?(?:Z|[+-](?:0[0-9]|1[0-4]):[0-5][0-9])$"#,
                          options: .regularExpression) != nil, validDate(String(value.prefix(10))) else { return nil }
        let format = Date.ISO8601FormatStyle(timeZoneSeparator: .colon, includingFractionalSeconds: value.contains("."))
        return try? format.parse(value)
    }

    private static func reportDescription(_ activity: CodexAccountTokenActivity, queriedAt: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let report = activity.statsAsOf.map { "Account report date \($0)" } ?? "Account report date unavailable"
        var result = "\(report); queried at \(formatter.string(from: queriedAt))."
        if let generatedAt = activity.serviceGeneratedAt {
            result += " Service generated response \(formatter.string(from: generatedAt))."
        }
        return result + " Bucket dates use the service's unspecified time zone."
    }

    private static func normalized(_ value: String?) -> String? { CodexUsageSupport.nonempty(value)?.lowercased() }

    private static func empty(_ status: UsageDataStatus, now: Date, message: String) -> UsageValue<CodexAccountTokenActivity> {
        UsageValue(status: status, source: .none, measuredAt: nil, lastAttemptAt: now, message: message, value: nil)
    }

    private final class RejectRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
