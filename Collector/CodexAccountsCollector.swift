import CodexBarCore
import Foundation

struct CodexWorkspaceProfile: Codable, Sendable, Hashable {
    let home: String
    var workspaceAccountID: String? = nil
    var workspaceLabel: String? = nil
    var loginProfileID: UUID? = nil
}

struct CodexAccountConfiguration: Sendable {
    let homes: [String]
    let message: String?
    var workspaces: [CodexWorkspaceProfile] = []

    var profiles: [CodexWorkspaceProfile] {
        homes.flatMap { home in
            let selected = workspaces.filter { $0.home == home }
            return selected.isEmpty ? [CodexWorkspaceProfile(home: home)] : selected
        }
    }

    private struct WorkspaceSettings: Decodable {
        var codexWorkspaces: [CodexWorkspaceProfile]?
    }

    static func load(directory: URL, environment: [String: String]) -> Self {
        let ambient = CodexUsageSupport.homeURL(environment["CODEX_HOME"]).path
        do {
            let configURL = directory.appendingPathComponent("beaver-meter-accounts.json")
            // Decode the upstream model before normalization: CodexBar's store
            // normalizes the version, which would hide an unsupported input version.
            let data = FileManager.default.fileExists(atPath: configURL.path) ? try Data(contentsOf: configURL) : nil
            let config = try data.map { try JSONDecoder().decode(CodexBarConfig.self, from: $0) }
            guard config == nil || config?.version == CodexBarConfig.currentVersion else {
                throw CocoaError(.coderReadCorrupt)
            }
            let paths = config?.providers.first { $0.id == .codex }?.codexProfileHomePaths ?? []
            guard paths.allSatisfy({ $0.hasPrefix("/") || $0.hasPrefix("~/") }) else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            var workspaces = try data.flatMap { try JSONDecoder().decode(WorkspaceSettings.self, from: $0).codexWorkspaces } ?? []
            guard workspaces.allSatisfy({ $0.home.hasPrefix("/") || $0.home.hasPrefix("~/") }) else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            workspaces = workspaces.map {
                CodexWorkspaceProfile(home: normalizedHome($0.home),
                    workspaceAccountID: CodexOpenAIWorkspaceResolver.normalizeWorkspaceAccountID($0.workspaceAccountID),
                    workspaceLabel: CodexOpenAIWorkspaceIdentity.normalizeWorkspaceLabel($0.workspaceLabel))
            }
            let loginStore = CodexWorkspaceStore(directory: directory)
            let owned = try loginStore.load().map {
                CodexWorkspaceProfile(home: normalizedHome(loginStore.home(for: $0.id).path),
                    workspaceAccountID: $0.workspaceAccountID, workspaceLabel: $0.label, loginProfileID: $0.id)
            }
            // Own profile metadata takes precedence over a manually added copy.
            let ownedHomes = Set(owned.map(\.home))
            workspaces = workspaces.filter { !ownedHomes.contains($0.home) } + owned
            var seenProfiles: Set<CodexWorkspaceProfile> = []
            workspaces = workspaces.filter { profile in
                seenProfiles.insert(CodexWorkspaceProfile(home: profile.home, workspaceAccountID: profile.workspaceAccountID)).inserted
            }
            var seenHomes: Set<String> = []
            let homes = ([ambient] + paths + workspaces.map(\.home)).map(normalizedHome)
                .filter { seenHomes.insert($0).inserted }
            // The ambient default must stay first for the existing widget/menu summary.
            let ambientHome = normalizedHome(ambient)
            if workspaces.contains(where: { $0.home == ambientHome }) {
                let currentID = try? CodexOAuthCredentialsStore.loadOAuthTokens(
                    env: CodexHomeScope.scopedEnvironment(base: environment, codexHome: ambientHome)).accountId
                if let index = workspaces.firstIndex(where: { $0.home == ambientHome && $0.workspaceAccountID == currentID }) {
                    workspaces.insert(workspaces.remove(at: index), at: 0)
                } else {
                    workspaces.insert(CodexWorkspaceProfile(home: ambientHome), at: 0)
                }
            }
            return Self(homes: homes, message: nil, workspaces: workspaces)
        } catch {
            return Self(homes: [ambient], message: "Could not read Codex account configuration. Check beaver-meter-accounts.json.")
        }
    }

    private static func normalizedHome(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
    }
}

enum CodexAccountsCollector {
    static func defaultQuota(
        accounts: UsageValue<[CodexAccountUsage]>, previous: UsageValue<CompactQuota>,
        now: Date, environment: [String: String]
    ) async -> UsageValue<CompactQuota> {
        if let primary = accounts.value?.first,
           primary.quota.value != nil || environment["CODEX_USAGE_FIXTURE"] == nil {
            var quota = primary.quota.value
            quota?.windows = nil
            return UsageValue(status: primary.quota.status, source: primary.quota.source,
                              measuredAt: primary.quota.measuredAt, lastAttemptAt: primary.quota.lastAttemptAt,
                              message: primary.quota.message, value: quota)
        }
        // Existing provider-wide fixtures don't require a synthetic login file.
        return await CodexQuotaCollector.collect(previous: previous, now: now, environment: environment)
    }

    static func collect(
        configuration: CodexAccountConfiguration,
        previous: UsageValue<[CodexAccountUsage]>,
        now: Date,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> UsageValue<[CodexAccountUsage]> {
        // Batches bound concurrency even when many profile homes are configured.
        var accounts: [CodexAccountUsage] = []
        let profiles = configuration.profiles
        for start in stride(from: 0, to: profiles.count, by: 3) {
            let batchProfiles = Array(profiles[start..<min(start + 3, profiles.count)])
            let batch = await withTaskGroup(of: (Int, CodexAccountUsage).self) { group in
                for (index, profile) in batchProfiles.enumerated() {
                    group.addTask {
                        (index, await collectWorkspace(profile: profile, previous: previous.value ?? [],
                                                     now: now, environment: environment))
                    }
                }
                var values: [(Int, CodexAccountUsage)] = []
                for await item in group { values.append(item) }
                return values.sorted { $0.0 < $1.0 }.map(\.1)
            }
            accounts += batch
        }
        var seen: Set<String> = []
        accounts = accounts.filter { seen.insert($0.id).inserted }
        return UsageValue(status: configuration.message == nil ? .ready : .error, source: .accountAPI,
                          measuredAt: now, lastAttemptAt: now, message: configuration.message, value: accounts)
    }

    static func collectAccount(
        home: String, previous: [CodexAccountUsage], now: Date, environment: [String: String]
    ) async -> CodexAccountUsage {
        await collectWorkspace(profile: CodexWorkspaceProfile(home: home), previous: previous, now: now, environment: environment)
    }

    static func collectWorkspace(
        profile: CodexWorkspaceProfile, previous: [CodexAccountUsage], now: Date, environment: [String: String]
    ) async -> CodexAccountUsage {
        let home = profile.home
        let scoped = CodexHomeScope.scopedEnvironment(base: environment, codexHome: home)
        let homeID = CodexUsageSupport.hash(home)
        do {
            let credentials = try CodexOAuthCredentialsStore.loadOAuthTokens(env: scoped)
            let identity = try DefaultCodexSystemAccountObserver(workspaceCache: CodexOpenAIWorkspaceIdentityCache(
                fileURL: URL(fileURLWithPath: home).appendingPathComponent("beaver-meter-workspace-labels.json")))
                .loadSystemAccount(environment: scoped)
            guard let accountID = CodexOpenAIWorkspaceResolver.normalizeWorkspaceAccountID(credentials.accountId) else {
                throw CodexOAuthCredentialsError.missingTokens
            }
            let workspaceID = profile.workspaceAccountID ?? accountID
            let id = CodexUsageSupport.hash([homeID, accountID, identity?.email ?? "",
                                            workspaceID].joined(separator: "\u{0}"))
            let cached = previous.first { $0.id == id }
            let workspaceName = profile.workspaceLabel
                ?? (workspaceID == accountID ? identity?.workspaceLabel ?? tokenWorkspaceName(credentials) : nil)
                ?? "Workspace \(CodexUsageSupport.hash(workspaceID).prefix(8))"
            let name = [identity?.email ?? URL(fileURLWithPath: home).lastPathComponent,
                        workspaceName].joined(separator: " · ")
            async let quota = CodexQuotaCollector.collect(
                previous: cached?.quota ?? .unavailable("Quota has not been read."), now: now,
                environment: scoped, includeAllWindows: true, credentials: credentials, workspaceAccountID: workspaceID
            )
            // A workspace override needs a verified usage identity before its
            // reset-card endpoint may be treated as workspace-scoped.
            let readCards: Bool
            if workspaceID == accountID { readCards = true }
            else { readCards = await quota.status == .ready }
            async let cards = !readCards
                ? CollectorSupport.stale(previous: cached?.resetCards ?? .unavailable("Reset cards have not been read."),
                    attemptedAt: now, status: .unauthenticated, message: "Sign in to this workspace to read its reset cards.")
                : await collectResetCards(
                credentials: credentials, previous: cached?.resetCards ?? .unavailable("Reset cards have not been read."),
                now: now, environment: scoped, workspaceAccountID: workspaceID
            )
            let resolvedQuota = await quota
            let resolvedCards = await cards
            return CodexAccountUsage(id: id, homeID: homeID, displayName: name, quota: resolvedQuota, resetCards: resolvedCards,
                workspaceName: workspaceName, accountName: identity?.email,
                planName: resolvedQuota.value?.planName ?? (workspaceID == accountID ? tokenPlan(credentials) : nil),
                loginProfileID: profile.loginProfileID)
        } catch {
            // An unreadable login has no trusted identity: never borrow the last account's values.
            let unavailable: UsageValue<CompactQuota> = UsageValue(
                status: .unauthenticated, source: .none, measuredAt: nil, lastAttemptAt: now,
                message: "Sign in to Codex in this profile directory to read its account usage.", value: nil
            )
            return CodexAccountUsage(
                id: CodexUsageSupport.hash([homeID, profile.workspaceAccountID ?? ""].joined(separator: "\u{0}")),
                homeID: homeID, displayName: profile.workspaceLabel ?? URL(fileURLWithPath: home).lastPathComponent,
                quota: unavailable,
                resetCards: UsageValue(status: .unauthenticated, source: .none, measuredAt: nil,
                                       lastAttemptAt: now, message: unavailable.message, value: nil),
                workspaceName: profile.workspaceLabel, loginProfileID: profile.loginProfileID
            )
        }
    }

    private static func tokenPlan(_ credentials: CodexOAuthCredentials) -> String? {
        guard let token = credentials.idToken,
              let payload = UsageFetcher.parseJWT(token),
              let auth = payload["https://api.openai.com/auth"] as? [String: Any] else { return nil }
        return CodexQuotaCollector.planName(auth["chatgpt_plan_type"] as? String)
    }

    private static func tokenWorkspaceName(_ credentials: CodexOAuthCredentials) -> String? {
        guard let idToken = credentials.idToken,
              let payload = UsageFetcher.parseJWT(idToken),
              let auth = payload["https://api.openai.com/auth"] as? [String: Any],
              let accessPayload = UsageFetcher.parseJWT(credentials.accessToken),
              let accessAuth = accessPayload["https://api.openai.com/auth"] as? [String: Any],
              let organizationID = accessAuth["poid"] as? String,
              let organizations = auth["organizations"] as? [[String: Any]],
              let organization = organizations.first(where: { ($0["id"] as? String) == organizationID }) else { return nil }
        return CodexUsageSupport.nonempty(organization["title"] as? String)
    }

    static func inventory(from snapshot: CodexRateLimitResetCreditsSnapshot, now: Date) -> ResetCardInventory {
        ResetCardInventory(
            availableCount: snapshot.availableCount, observedAt: now,
            batches: snapshot.availableCredits(at: now).map {
                ResetCardBatch(id: $0.id, count: 1, startsAt: nil, expiresAt: $0.expiresAt)
            }
        )
    }

    private static func collectResetCards(
        credentials: CodexOAuthCredentials, previous: UsageValue<ResetCardInventory>,
        now: Date, environment: [String: String], workspaceAccountID: String
    ) async -> UsageValue<ResetCardInventory> {
        do {
            let inventory: ResetCardInventory
            if let fixture = environment["CODEX_RESET_CARDS_FIXTURE"] {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                inventory = try decoder.decode(ResetCardInventory.self, from: Data(contentsOf: URL(fileURLWithPath: fixture)))
            } else if environment["CODEX_USAGE_FIXTURE"] != nil {
                // Provider fixtures must never fall through to live account endpoints.
                return .unavailable("No reset-card fixture provided.")
            } else {
                inventory = Self.inventory(from: try await CodexOAuthUsageFetcher.fetchRateLimitResetCredits(
                    accessToken: credentials.accessToken, accountId: workspaceAccountID,
                    env: environment, timeout: 12
                ), now: now)
            }
            guard inventory.availableCount >= 0, inventory.batches.allSatisfy({ $0.count >= 0 }) else {
                throw URLError(.cannotParseResponse)
            }
            return UsageValue(status: .ready, source: .accountAPI, measuredAt: now,
                              lastAttemptAt: now, message: nil, value: inventory)
        } catch {
            let status: UsageDataStatus
            if case CodexOAuthFetchError.unauthorized = error { status = .unauthenticated } else { status = .error }
            return CollectorSupport.stale(previous: previous, attemptedAt: now, status: status,
                                          message: "Codex reset cards could not be refreshed.")
        }
    }
}
