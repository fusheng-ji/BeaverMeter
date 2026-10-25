import Combine
import SwiftUI

@MainActor
final class UsageMenuNavigation: ObservableObject {
    @Published private(set) var codexWorkspacesRequestID: UUID?

    func open(_ target: AppNavigation.Target) {
        if target == .codexWorkspaces { codexWorkspacesRequestID = UUID() }
    }

    func endPresentation() { codexWorkspacesRequestID = nil }
}

struct UsageMenuView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var appearance: AppearanceStore
    @ObservedObject var updates = UpdateStore()
    @ObservedObject var navigation = UsageMenuNavigation()
    var refreshingOverride: Bool?
    var automaticRefresh = true
    var scrollsContent = true
    var updatedDescriptionOverride: String?
    var viewHeight: CGFloat = 700
    var referenceDate: Date?
    var refreshErrorOverride: String?
    var servicesExpanded = false
    var historyExpanded: Bool?
    var accountsExpanded: Bool?
    var resetCardsExpanded: Bool?
    var appearanceExpanded: Bool?
    @Environment(\.isRenderingUsagePreview) private var isRenderingPreview
    @AppStorage("codexAccountsExpanded") private var persistedAccountsExpanded = false
    @State private var appliedNavigationRequestID: UUID?
    private var presentationDate: Date { referenceDate ?? .now }
    private var showsRefreshing: Bool { refreshingOverride ?? store.isRefreshing }
    private let timer = Timer.publish(every: 300, on: .main, in: .common).autoconnect()

    private func disclosureOverride(_ value: Bool?) -> Bool? {
        value ?? (isRenderingPreview ? false : nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            quotaFooter
            if let error = refreshErrorOverride ?? store.refreshError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
            Divider()
            actions
        }
        .frame(width: 410)
        .frame(height: scrollsContent ? fittedHeight : nil)
        .fixedSize(horizontal: false, vertical: !scrollsContent)
        .environment(\.locale, UsageFormatting.locale)
        .onAppear {
            if automaticRefresh { store.refreshIfNeeded() }
        }
        .onReceive(timer) { _ in
            if automaticRefresh { store.refreshIfNeeded(force: true) }
        }
    }

    private var fittedHeight: CGFloat {
        Self.fittedHeight(
            for: displayedProviders, maxHeight: viewHeight, servicesExpanded: servicesExpanded,
            claudeWindowCount: store.snapshot.claudeQuota.value?.windows?.count ?? 0,
            expandedMonitoringHeight: (historyExpanded == true ? 120 : 0)
                + (accountsAreExpanded ? CGFloat(store.snapshot.codexAccounts.value?.count ?? 0) * 280 : 0)
                + (resetCardsExpanded == true ? 120 : 0)
                + (appearanceExpanded == true ? 95 : 0)
        )
    }

    private var accountsAreExpanded: Bool {
        if navigation.codexWorkspacesRequestID != nil { return persistedAccountsExpanded }
        return disclosureOverride(accountsExpanded) ?? persistedAccountsExpanded
    }

    private var displayedProviders: [MeterProvider] {
        let visible = store.visibleProviders
        // A direct section link can show its destination without changing service preferences.
        return navigation.codexWorkspacesRequestID != nil && !visible.contains(.codex)
            ? [.codex] + visible : visible
    }

    /// Fewer services shrink the popover instead of leaving an empty scroll area;
    /// larger content keeps the requested height and scrolls.
    static func fittedHeight(
        for providers: [MeterProvider], maxHeight: CGFloat, servicesExpanded: Bool = false,
        claudeWindowCount: Int = 0, expandedMonitoringHeight: CGFloat = 0
    ) -> CGFloat {
        let sections = providers.reduce(CGFloat(0)) { total, provider in
            switch provider {
            case .codex: total + 195
            case .claude: total + 270 + 24 * CGFloat(claudeWindowCount)
            case .cursor: total + 340
            case .deepseek: total + 270
            }
        }
        return min(maxHeight, 265 + sections + (servicesExpanded ? 60 : 0) + expandedMonitoringHeight)
    }

    @ViewBuilder
    private var content: some View {
        if scrollsContent {
            ScrollViewReader { proxy in
                ScrollView { sections }
                    .task(id: navigation.codexWorkspacesRequestID) {
                        await navigateToWorkspaces(navigation.codexWorkspacesRequestID, proxy: proxy)
                    }
            }
        } else {
            sections
                .task(id: navigation.codexWorkspacesRequestID) {
                    await navigateToWorkspaces(navigation.codexWorkspacesRequestID, proxy: nil)
                }
        }
    }

    @MainActor
    private func navigateToWorkspaces(_ requestID: UUID?, proxy: ScrollViewProxy?) async {
        guard let requestID, requestID != appliedNavigationRequestID else { return }
        appliedNavigationRequestID = requestID
        // Allow the disclosure and scroll content size to update before positioning.
        await Task.yield()
        guard !Task.isCancelled else { return }
        proxy?.scrollTo(CodexAccountsSection.navigationAnchor, anchor: .top)
        try? await Task.sleep(for: .milliseconds(80))
        guard !Task.isCancelled, navigation.codexWorkspacesRequestID == requestID else { return }
        proxy?.scrollTo(CodexAccountsSection.navigationAnchor, anchor: .top)
    }

    private var sections: some View {
        VStack(spacing: 14) {
            ForEach(Array(displayedProviders.enumerated()), id: \.element) { index, provider in
                if index > 0 { Divider() }
                section(for: provider)
            }
            Divider()
            ServiceSettingsSection(store: store, initiallyExpanded: servicesExpanded)
            Divider()
            AppearanceSettingsSection(appearance: appearance, expandedOverride: appearanceExpanded)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func section(for provider: MeterProvider) -> some View {
        switch provider {
        case .codex: codexSection
        case .claude: claudeSection
        case .cursor: cursorSection
        case .deepseek: deepseekSection
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            BrandLogoView(variant: appearance.variant, size: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("BeaverMeter")
                    .font(.headline)
                Text(
                    showsRefreshing
                        ? "Refreshing…"
                        : "Updated \(updatedDescriptionOverride ?? UsageFormatting.relativeAge(store.snapshot.generatedAt, relativeTo: presentationDate))"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let update = updates.available {
                Button("Update \(update.version)") { updates.installUpdate() }
                    .buttonStyle(UpdateButtonStyle())
                    .controlSize(.small)
                    .disabled(updates.isChecking)
                    .help("Install BeaverMeter \(update.version) and restart")
                    .accessibilityLabel("Update to BeaverMeter \(update.version)")
            }
            if showsRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .help("Refresh now")
                    .accessibilityLabel("Refresh usage now")
            }
        }
        .padding(14)
    }

    private var dailyCodexTokens: UsageValue<CodexTokenTotals> {
        CodexDailyTokenPresentation(store.snapshot.codexTokens, relativeTo: presentationDate).data
    }

    private var codexSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            UsageSectionHeader(title: "Codex today", provider: .codex, tint: .teal,
                               value: dailyCodexTokens, referenceDate: presentationDate)
            if let tokens = dailyCodexTokens.value {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(UsageFormatting.tokens(tokens.totalTokens))
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .accessibilityLabel("\(tokens.totalTokens.formatted()) tokens today")
                    Text("tokens")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(tokens.sessionCount) session\(tokens.sessionCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    TokenMetric(label: "Input", value: tokens.inputTokens)
                    TokenMetric(label: "Cached", value: tokens.cachedInputTokens)
                    TokenMetric(label: "Output", value: tokens.outputTokens)
                    TokenMetric(label: "Reasoning", value: tokens.reasoningTokens)
                }
                SectionMessage(message: dailyCodexTokens.message, status: dailyCodexTokens.status)
            } else {
                EmptyState(message: dailyCodexTokens.message ?? "No Codex token data yet.")
            }
            TokenHistorySection(provider: "Codex", data: store.snapshot.codexHistory, tint: .teal,
                                referenceDate: presentationDate,
                                metrics: { [("Input", $0.inputTokens), ("Cached", $0.cachedInputTokens),
                                            ("Output", $0.outputTokens), ("Reasoning", $0.reasoningTokens)] },
                                expandedOverride: disclosureOverride(historyExpanded))
            CodexAccountsSection(store: store, referenceDate: presentationDate,
                                 expandedOverride: navigation.codexWorkspacesRequestID == nil ? disclosureOverride(accountsExpanded) : nil,
                                 cardsExpandedOverride: disclosureOverride(resetCardsExpanded),
                                 expansionRequestID: navigation.codexWorkspacesRequestID)
                .id(CodexAccountsSection.navigationAnchor)
        }
    }

    private var dailyClaudeTokens: UsageValue<ClaudeTokenTotals> {
        ClaudeDailyTokenPresentation(store.snapshot.claudeTokens, relativeTo: presentationDate).data
    }

    private var claudeQuota: UsageValue<CompactQuota> {
        ClaudeQuotaVisibility.quota(store.snapshot.claudeQuota, relativeTo: presentationDate)
    }

    private var claudeResetCards: UsageValue<ResetCardInventory> {
        ClaudeQuotaVisibility.resetCards(store.snapshot.claudeResetCards, relativeTo: presentationDate)
    }

    private var claudeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            UsageSectionHeader(title: "Claude today", provider: .claude, tint: .orange,
                               value: dailyClaudeTokens, referenceDate: presentationDate)
            if let tokens = dailyClaudeTokens.value {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(UsageFormatting.tokens(tokens.totalTokens))
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .accessibilityLabel("\(tokens.totalTokens.formatted()) tokens today")
                    Text("tokens")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    // Unpriced models (newer than CodexBarCore's table) leave the estimate out.
                    if let cost = tokens.costUSD {
                        Text("≈ \(UsageFormatting.usd(cost, minimumDigits: 2, maximumDigits: 2)) at API rates")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                HStack(spacing: 10) {
                    TokenMetric(label: "Input", value: tokens.inputTokens)
                    TokenMetric(label: "Cache write", value: tokens.cacheCreationTokens)
                    TokenMetric(label: "Cache read", value: tokens.cacheReadTokens)
                    TokenMetric(label: "Output", value: tokens.outputTokens)
                }
                SectionMessage(message: dailyClaudeTokens.message, status: dailyClaudeTokens.status)
            } else {
                EmptyState(message: dailyClaudeTokens.message ?? "No Claude token data yet.")
            }
            claudeAuthentication
            if let windows = claudeQuota.value?.windows, windows.count > 1 {
                VStack(spacing: 5) {
                    ForEach(windows, id: \.label) { window in
                        QuotaWindowRow(window: window, tint: .orange, referenceDate: presentationDate)
                    }
                }
                .padding(.top, 2)
            }
            ResetCardSection(data: claudeResetCards, provider: "Claude", referenceDate: presentationDate,
                             expandedOverride: disclosureOverride(resetCardsExpanded))
            TokenHistorySection(provider: "Claude", data: store.snapshot.claudeHistory, tint: .orange,
                                referenceDate: presentationDate,
                                metrics: { [("Input", $0.inputTokens), ("Cache write", $0.cacheCreationTokens),
                                            ("Cache read", $0.cacheReadTokens), ("Output", $0.outputTokens)] },
                                expandedOverride: disclosureOverride(historyExpanded))
        }
    }

    private var claudeAuthentication: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Online quota")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                StatusPill(value: claudeQuota, referenceDate: presentationDate)
            }
            if claudeQuota.status != .ready {
                SectionMessage(message: claudeQuota.message, status: claudeQuota.status)
            }
            if store.claudeAuthenticationState.isBusy {
                HStack(alignment: .top, spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(store.claudeAuthenticationState.message ?? "Verifying Claude login…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Cancel") { store.cancelClaudeAuthentication() }
                        .controlSize(.small)
                        .disabled(store.claudeAuthenticationState == .cancelling)
                }
            } else {
                HStack(spacing: 8) {
                    if claudeQuota.message?.contains("macOS Keychain session") == true {
                        Button("Repair Keychain session…") { store.repairClaudeKeychainSession() }
                            .controlSize(.small)
                            .help("Review a one-time lock and unlock of the login Keychain to restore access to the saved Claude login")
                    } else if claudeQuota.status == .unauthenticated {
                        Button("Sign in to Claude…") { store.signInClaude() }
                            .controlSize(.small)
                    } else if claudeQuota.message?.contains("permission to read") == true
                        || claudeQuota.message?.contains("credential access was cancelled") == true {
                        Button("Allow Claude access…") { store.authorizeClaudeAccess() }
                            .controlSize(.small)
                            .help("Ask macOS for access to your existing Claude Keychain login, then verify quota without signing in again")
                    }
                    Button("Verify login") { store.verifyClaudeLogin() }
                        .controlSize(.small)
                        .help("Read the current Claude login and verify quota online")
                }
                .disabled(!store.canAuthenticateClaude || isRenderingPreview)
                if let message = store.claudeAuthenticationState.message, message != claudeQuota.message {
                    SectionMessage(message: message, status: .error)
                }
            }
        }
        .padding(.top, 2)
    }

    private var cursorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            UsageSectionHeader(title: "Cursor today", provider: .cursor, tint: .indigo,
                               value: store.snapshot.cursorCosts, referenceDate: presentationDate)
            if let costs = store.snapshot.cursorCosts.value {
                HStack(alignment: .firstTextBaseline) {
                    Text(UsageFormatting.usd(costs.todayCostUSD, minimumDigits: 2, maximumDigits: 4))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("actual charge")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Text("Recent model calls")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if costs.recentEvents.isEmpty {
                    Text("No Cursor model calls today.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(costs.recentEvents) { event in
                            CursorEventRow(event: event)
                            if event.id != costs.recentEvents.last?.id { Divider() }
                        }
                    }
                }
                SectionMessage(message: store.snapshot.cursorCosts.message, status: store.snapshot.cursorCosts.status)
            } else {
                EmptyState(message: store.snapshot.cursorCosts.message ?? "No Cursor cost data yet.")
            }
        }
    }

    private var deepseekSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            UsageSectionHeader(title: "DeepSeek this month", provider: .deepseek, tint: .blue,
                               value: store.snapshot.deepseekUsage, referenceDate: presentationDate)

            if let usage = store.snapshot.deepseekUsage.value {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(UsageFormatting.money(UsageFormatting.firstValidMoney(usage.balances)))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                    Text("balance")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }

                HStack(spacing: 12) {
                    DeepSeekMetric(label: "Month cost", value: UsageFormatting.moneyList(usage.monthCosts))
                    DeepSeekMetric(label: "Tokens", value: UsageFormatting.tokens(usage.monthTokens))
                    DeepSeekMetric(label: "Requests", value: usage.monthRequests?.formatted() ?? "—")
                }

                let additionalBalances = Array(usage.balances.dropFirst())
                if !additionalBalances.isEmpty {
                    DeepSeekDetailLine(
                        label: "Other balances",
                        value: UsageFormatting.moneyList(additionalBalances)
                    )
                }
                if !usage.grantedBalances.isEmpty {
                    DeepSeekDetailLine(
                        label: "Granted balance",
                        value: UsageFormatting.moneyList(usage.grantedBalances)
                    )
                }
                if !usage.totalCosts.isEmpty {
                    DeepSeekDetailLine(
                        label: "Total cost",
                        value: UsageFormatting.moneyList(usage.totalCosts)
                    )
                }

            } else {
                EmptyState(message: store.snapshot.deepseekUsage.message ?? "No DeepSeek usage yet.")
            }

            HStack {
                if store.snapshot.deepseekUsage.value != nil {
                    SectionMessage(message: store.snapshot.deepseekUsage.message, status: store.snapshot.deepseekUsage.status)
                }
                Spacer()
                if store.deepSeekConnectionState == .loadingUsage {
                    Button("Loading…") {}
                        .controlSize(.small)
                        .disabled(true)
                } else if store.isConnectingDeepSeek {
                    Button("Check now") { store.checkDeepSeekBrowserSession() }
                        .controlSize(.small)
                } else if store.snapshot.deepseekUsage.status == .unauthenticated
                    || store.snapshot.deepseekUsage.value == nil {
                    Button("Connect in browser…") { store.connectDeepSeekInBrowser() }
                        .controlSize(.small)
                } else {
                    Button("Reconnect in browser…") { store.connectDeepSeekInBrowser() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }

            if let message = store.deepSeekConnectionMessage {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if store.isConnectingDeepSeek {
                        ProgressView().controlSize(.mini)
                    } else if case .failed = store.deepSeekConnectionState {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Text(message)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// DeepSeek has a balance rather than a quota window, so it has no footer entry.
    private var quotaProviders: [MeterProvider] {
        store.visibleProviders.filter { $0 != .deepseek }
    }

    @ViewBuilder
    private var quotaFooter: some View {
        if !quotaProviders.isEmpty {
            Divider()
            HStack(spacing: 12) {
                ForEach(Array(quotaProviders.enumerated()), id: \.element) { index, provider in
                    if index > 0 { Divider().frame(height: 28) }
                    quotaLabel(for: provider)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private func quotaLabel(for provider: MeterProvider) -> some View {
        switch provider {
        case .codex:
            QuotaLabel(provider: .codex, value: store.snapshot.codexQuota, referenceDate: presentationDate)
        case .claude:
            QuotaLabel(provider: .claude, value: claudeQuota, referenceDate: presentationDate)
        case .cursor:
            QuotaLabel(provider: .cursor, value: store.snapshot.cursorQuota, referenceDate: presentationDate)
        case .deepseek:
            EmptyView()
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if updates.observesChanges || updates.available != nil {
                HStack {
                    Button(updates.isChecking ? "Checking for Updates…" : "Check for Updates…") {
                        updates.checkIfNeeded(force: true)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .disabled(updates.isChecking)
                    if updates.isChecking { ProgressView().controlSize(.mini) }
                }
                if let message = updates.message {
                    Text(message).font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
            Label("Credentials stay local · snapshots contain no credentials", systemImage: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.caption)
            }
        }
        .padding(12)
    }
}

private struct UpdateButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Color.blue.opacity(configuration.isPressed ? 0.8 : 1),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

#Preview("Menu popover") {
    UsageMenuView(
        store: UsageStore(snapshot: .preview, providerSettings: .default, observesSnapshotChanges: false),
        appearance: AppearanceStore(settings: .default, observesChanges: false,
                                    referenceDate: UsageSnapshot.previewDate, timeZone: TimeZone(secondsFromGMT: 0)!),
        automaticRefresh: false,
        scrollsContent: false,
        updatedDescriptionOverride: "from demo data",
        referenceDate: UsageSnapshot.previewDate
    )
}
