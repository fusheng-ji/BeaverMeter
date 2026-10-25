import Foundation

/// One authenticated response supplies quota windows and limit-reset grants.
/// The collector's snapshot lock serializes this state across App and launch agent.
enum ClaudeUsageCollector {
    struct Reading: Codable, Sendable {
        let quota: UsageValue<CompactQuota>
        let resetCards: UsageValue<ResetCardInventory>
    }

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private struct State: Codable {
        var identity: String
        var successfulAt: Date?
        var retryAt: Date?
        var rateLimitCount = 0
        var reading: Reading

        mutating func invalidate(with reading: Reading) {
            recordFailure(reading)
            retryAt = nil
            rateLimitCount = 0
        }

        mutating func recordSuccess(_ reading: Reading, at now: Date) {
            self.reading = reading
            successfulAt = now
            retryAt = nil
            rateLimitCount = 0
        }

        mutating func recordFailure(_ reading: Reading) {
            self.reading = reading
            successfulAt = nil
        }

        mutating func scheduleRetry(_ supplied: Date?, at now: Date) -> Date {
            rateLimitCount = min(max(rateLimitCount, 0), 3) + 1
            let minutes = [5, 10, 20, 30][rateLimitCount - 1]
            let deadline = supplied ?? now.addingTimeInterval(Double(minutes * 60))
            retryAt = deadline
            return deadline
        }

        func save(to url: URL) {
            try? AtomicFileWriter.writeJSON(self, to: url)
        }

        static func load(from url: URL) -> State? {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? Data(contentsOf: url)).flatMap { try? decoder.decode(State.self, from: $0) }
        }
    }

    static func collect(
        previousQuota: UsageValue<CompactQuota>, previousCards: UsageValue<ResetCardInventory>,
        now: Date, stateDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        forceRefresh: Bool = false,
        cancellation: SubprocessCancellation? = nil,
        credentialReader: ClaudeQuotaCollector.CredentialReader = ClaudeQuotaCollector.credentialsData,
        transport: Transport = liveTransport
    ) async -> Reading {
        var previous = Reading(quota: previousQuota, resetCards: previousCards)
        // Fixtures never touch credentials, networking or persistent live state.
        if environment["CLAUDE_USAGE_FIXTURE"] != nil || environment["CLAUDE_RESET_CARDS_FIXTURE"] != nil {
            func fixture(_ key: String) -> Result<Data, Error> {
                Result {
                    guard let path = environment[key] ?? environment["CLAUDE_USAGE_FIXTURE"] else {
                        throw URLError(.resourceUnavailable)
                    }
                    return try Data(contentsOf: URL(fileURLWithPath: path))
                }
            }
            return parse(quotaData: fixture("CLAUDE_USAGE_FIXTURE"),
                         cardsData: fixture("CLAUDE_RESET_CARDS_FIXTURE"), previous: previous, now: now)
        }

        let stateURL = stateDirectory.appendingPathComponent("beaver-meter-claude-usage-v1.json")
        var state: State?
        do {
            // A cancelled browser/repair operation still records an outcome,
            // but must not begin a new credential authorization dialog.
            if cancellation?.isCancelled == true {
                previous = emptyReading("Claude verification was cancelled; awaiting refresh.")
                throw URLError(.cancelled)
            }
            let credentials = try credentialReader(environment)
            let originalToken = try? ClaudeQuotaCollector.accessToken(fromCredentials: credentials, now: .distantPast)
            let token: String
            var planName = ClaudeQuotaCollector.planName(fromCredentials: credentials)
            var didRenew = false
            do {
                token = try ClaudeQuotaCollector.accessToken(fromCredentials: credentials, now: now)
            } catch {
                guard error as? ClaudeQuotaError == .expired
                        || (error as? ClaudeQuotaError == .notLoggedIn
                            && ClaudeQuotaCollector.hasRefreshToken(inCredentials: credentials)) else { throw error }
                // Expiry is already known, even if renewal later hits a
                // temporary Keychain error. Invalidate every old success before
                // launching the CLI; a failed renewal must not revive it.
                invalidateCache(previous: &previous, state: &state, at: stateURL,
                                message: "Claude sign-in needs renewal; awaiting verification.")
                let renewed = try ClaudeCredentialRenewal.renewedCredential(
                    now: now, stateDirectory: stateDirectory, environment: environment,
                    rejectedToken: originalToken, cancellation: cancellation, credentialReader: credentialReader
                )
                token = renewed.token
                planName = renewed.planName
                didRenew = true
                // A repaired credential must be verified by the server. Neither
                // a prior success nor rate-limit state may certify a new token.
                previous = emptyReading("Claude sign-in renewed; awaiting verification.")
            }
            // Hash only; neither the state nor snapshot contains the bearer token.
            let root = try ClaudeCredentialResolver.profileIdentity(environment: environment)
            let identity = CodexUsageSupport.hash(root + "\n" + token)
            let stored = State.load(from: stateURL)
            if let stored, stored.identity == identity, !didRenew {
                state = stored
                previous = stored.reading
                if !forceRefresh, let retryAt = stored.retryAt, retryAt > now {
                    return failure(previous: previous, now: now, error: ClaudeQuotaError.rateLimited(retryAt: retryAt))
                }
                if !forceRefresh, let success = stored.successfulAt, now >= success,
                   now.timeIntervalSince(success) < 300, !hasResetWindow(stored.reading.quota.value, now: now) {
                    // A 200 response can contain a parser failure for one part,
                    // retaining its older measurement. successfulAt alone must
                    // never extend that component's measured-time cache limit.
                    return Reading(quota: ClaudeQuotaVisibility.quota(
                        quota(stored.reading.quota, withPlanName: planName), relativeTo: now),
                                   resetCards: ClaudeQuotaVisibility.resetCards(stored.reading.resetCards, relativeTo: now))
                }
            } else {
                if stored != nil {
                    previous = emptyReading("Claude sign-in changed; awaiting refresh.")
                }
                state = State(identity: identity, reading: previous)
            }
            let data: Data
            do {
                data = try await request(token: token, now: now, environment: environment,
                                         cancellation: cancellation, transport: transport)
            } catch ClaudeQuotaError.expired {
                // A rejected credential is invalid even when its renewal is
                // then cancelled; it must not regain its cached percentages.
                invalidateCache(previous: &previous, state: &state, at: stateURL,
                                message: "Claude sign-in could not be verified.")
                let renewed = try ClaudeCredentialRenewal.renewedCredential(
                    now: now, stateDirectory: stateDirectory, environment: environment,
                    rejectedToken: token, cancellation: cancellation, credentialReader: credentialReader
                )
                // Once the server rejects a credential its old quota/cards are
                // no longer an acceptable fallback, even if verification fails.
                previous = emptyReading("Claude sign-in renewed; awaiting verification.")
                state?.identity = CodexUsageSupport.hash(root + "\n" + renewed.token)
                planName = renewed.planName
                data = try await request(token: renewed.token, now: now, environment: environment,
                                         cancellation: cancellation, transport: transport)
            }
            let reading = parse(quotaData: .success(data), cardsData: .success(data), previous: previous,
                                now: now, planName: planName)
            state?.recordSuccess(reading, at: now)
            state?.save(to: stateURL)
            return reading
        } catch {
            if isAuthenticationFailure(error) {
                // Remove every route back to the old account values, including
                // successfulAt/retryAt from an earlier collection process.
                try? FileManager.default.removeItem(at: stateURL)
                return failure(previous: previous, now: now, error: error)
            }
            var reported = error
            if case ClaudeQuotaError.rateLimited(let supplied) = error, var saved = state {
                reported = ClaudeQuotaError.rateLimited(retryAt: saved.scheduleRetry(supplied, at: now))
                state = saved
            }
            let reading = failure(previous: previous, now: now, error: reported)
            state?.recordFailure(reading)
            state?.save(to: stateURL)
            return reading
        }
    }

    static func parse(quotaData: Result<Data, Error>, cardsData: Result<Data, Error>,
                      previous: Reading, now: Date, planName: String? = nil) -> Reading {
        let quota: UsageValue<CompactQuota>
        do {
            let response = try JSONDecoder().decode(ClaudeOAuthUsageResponse.self, from: quotaData.get())
            guard let value = ClaudeQuotaCollector.quota(from: response) else { throw URLError(.cannotParseResponse) }
            quota = ClaudeQuotaVisibility.quota(
                self.quota(UsageValue(status: .ready, source: .accountAPI, measuredAt: now, lastAttemptAt: now,
                                      message: nil, value: value), withPlanName: planName),
                relativeTo: now
            )
        } catch {
            quota = failedValue(previous: ClaudeQuotaVisibility.quota(previous.quota, relativeTo: now), now: now, error: error,
                                message: "Claude quota refresh failed: \(error.localizedDescription)")
        }
        let cards: UsageValue<ResetCardInventory>
        do {
            if let value = try ClaudeResetCardCollector.inventory(from: cardsData.get(), now: now) {
                cards = UsageValue(status: .ready, source: .accountAPI, measuredAt: now, lastAttemptAt: now, message: nil, value: value)
            } else {
                cards = CollectorSupport.stale(previous: ClaudeQuotaVisibility.resetCards(previous.resetCards, relativeTo: now), attemptedAt: now, status: .unavailable,
                                               message: "Claude did not provide reset-card information for this sign-in.")
            }
        } catch {
            cards = failedValue(previous: ClaudeQuotaVisibility.resetCards(previous.resetCards, relativeTo: now), now: now, error: error,
                                message: "Claude limit resets could not be refreshed: \(error.localizedDescription)")
        }
        return Reading(quota: quota, resetCards: cards)
    }

    private static func quota(_ data: UsageValue<CompactQuota>, withPlanName planName: String?) -> UsageValue<CompactQuota> {
        guard data.status == .ready, let planName, var value = data.value else { return data }
        value.planName = planName
        value.windows = value.windows?.map {
            var window = $0
            window.planName = planName
            return window
        }
        return UsageValue(status: data.status, source: data.source, measuredAt: data.measuredAt,
                          lastAttemptAt: data.lastAttemptAt, message: data.message, value: value)
    }

    private static func failure(previous: Reading, now: Date, error: Error) -> Reading {
        parse(quotaData: .failure(error), cardsData: .failure(error), previous: previous, now: now)
    }

    private static func status(_ error: Error) -> UsageDataStatus {
        isAuthenticationFailure(error) ? .unauthenticated : .error
    }

    private static func isAuthenticationFailure(_ error: Error) -> Bool {
        if [.notLoggedIn, .expired].contains(error as? ClaudeQuotaError) { return true }
        if case ClaudeCredentialResolver.ResolutionError.unsupportedOAuthEndpoint = error { return true }
        return false
    }

    private static func emptyReading(_ message: String) -> Reading {
        Reading(quota: .unavailable(message), resetCards: .unavailable(message))
    }

    private static func invalidateCache(previous: inout Reading, state: inout State?, at url: URL,
                                        message: String) {
        previous = emptyReading(message)
        try? FileManager.default.removeItem(at: url)
        state?.invalidate(with: previous)
    }

    private static func failedValue<Value: Codable & Hashable & Sendable>(previous: UsageValue<Value>, now: Date, error: Error,
                                            message: String) -> UsageValue<Value> {
        if isAuthenticationFailure(error) {
            return UsageValue(status: .unauthenticated, source: .none, measuredAt: nil,
                              lastAttemptAt: now, message: message, value: nil)
        }
        return CollectorSupport.stale(previous: previous, attemptedAt: now, status: status(error), message: message)
    }

    private static func hasResetWindow(_ quota: CompactQuota?, now: Date) -> Bool {
        guard let quota else { return false }
        return quota.resetAt.map { $0 <= now } == true
            || quota.windows?.contains(where: { hasResetWindow($0, now: now) }) == true
    }

    static func retryDate(_ value: String?, now: Date) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 {
            let date = now.addingTimeInterval(seconds)
            return date <= .distantFuture ? date : nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).flatMap { $0 > now ? $0 : nil }
    }

    private static func request(token: String, now: Date, environment: [String: String],
                                cancellation: SubprocessCancellation?, transport: Transport) async throws -> Data {
        if cancellation?.isCancelled == true { throw URLError(.cancelled) }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")!)
        request.timeoutInterval = 12
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(ClaudeQuotaCollector.userAgent(environment: environment, cancellation: cancellation), forHTTPHeaderField: "User-Agent")
        if cancellation?.isCancelled == true { throw URLError(.cancelled) }
        let (data, response) = try await transport(request)
        switch response.statusCode {
        case 200: return data
        case 401, 403: throw ClaudeQuotaError.expired
        case 429: throw ClaudeQuotaError.rateLimited(retryAt: retryDate(response.value(forHTTPHeaderField: "Retry-After"), now: now))
        default: throw URLError(.badServerResponse)
        }
    }

    static func liveTransport(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}
