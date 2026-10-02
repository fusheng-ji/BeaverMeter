import SwiftUI

struct TokenHistorySection<Totals: DailyTokenTotals>: View {
    let provider: String
    let data: UsageValue<TokenHistory<Totals>>
    let tint: Color
    let referenceDate: Date
    let metrics: (Totals) -> [(String, Int)]
    var expandedOverride: Bool? = nil
    @AppStorage("codexHistoryExpanded") private var codexExpanded = false
    @AppStorage("claudeHistoryExpanded") private var claudeExpanded = false
    @State private var selectedDayID: Date?
    @Environment(\.timeZone) private var timeZone
    @Environment(\.locale) private var locale

    private var expanded: Binding<Bool> {
        Binding(get: { expandedOverride ?? (provider == "Codex" ? codexExpanded : claudeExpanded) },
                set: { if provider == "Codex" { codexExpanded = $0 } else { claudeExpanded = $0 } })
    }

    private var history: TokenHistory<Totals>? {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        return data.value?.coversToday(at: referenceDate, calendar: calendar) == true ? data.value : nil
    }

    var body: some View {
        DisclosureGroup(isExpanded: expanded) {
            if let history {
                VStack(alignment: .leading, spacing: 5) {
                    compactHistory(history)
                    if data.status != .ready {
                        StatusPill(value: data, referenceDate: referenceDate)
                    }
                    SectionMessage(message: data.message, status: data.status)
                }.padding(.top, 4)
            } else {
                EmptyState(message: data.value == nil ? data.message ?? "No seven-day history yet." : "History needs a refresh for today's dates and time zone.")
            }
        } label: {
            HStack {
                Text("Last 7 days").font(.caption.weight(.semibold))
                    .accessibilityLabel("\(provider) token consumption in the last seven days")
                Spacer()
                Text(history.map { "\(UsageFormatting.tokens($0.totals.totalTokens)) tokens" } ?? "—")
                    .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(tint)
                if data.isStale {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            .help(summaryHelp)
        }
    }

    private var sourceDescription: String {
        provider == "Codex" ? "Combined configured logs from all Codex profiles and the optional SSH source"
            : "Local Claude Code transcripts"
    }

    private var summaryHelp: String {
        var lines = [sourceDescription]
        if let history {
            lines.append("\(history.totals.totalTokens.formatted(.number.locale(locale))) tokens")
            lines.append(metrics(history.totals).map {
                "\($0.0): \($0.1.formatted(.number.locale(locale)))"
            }.joined(separator: " · "))
        }
        lines.append("Updated \(UsageFormatting.relativeAge(data.measuredAt, relativeTo: referenceDate))")
        return lines.joined(separator: "\n")
    }

    private func weekday(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: locale, timeZone: timeZone).weekday(.abbreviated))
    }

    private func compactHistory(_ history: TokenHistory<Totals>) -> some View {
        let selected = history.days.first { $0.id == selectedDayID } ?? history.days.last!
        let items = metrics(selected.totals)
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(selected.id == history.days.last?.id ? "Today · \(weekday(selected.date))" : weekday(selected.date))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text("\(UsageFormatting.tokens(selected.totals.totalTokens)) tokens")
                        .fontWeight(.semibold).monospacedDigit()
                }.font(.caption2)
                ForEach([0, 2], id: \.self) { start in
                    Text(items.dropFirst(start).prefix(2).map {
                        "\($0.0) \(UsageFormatting.tokens($0.1))"
                    }.joined(separator: " · "))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.9)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            activityBars(history, selectedID: selected.id)
        }
    }

    private func activityBars(_ history: TokenHistory<Totals>, selectedID: Date) -> some View {
        let maximum = history.days.map { $0.totals.totalTokens }.max() ?? 0
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(history.days) { day in
                let isToday = day.id == history.days.last?.id
                let fraction = maximum > 0 ? Double(day.totals.totalTokens) / Double(maximum) : 0
                Button { selectedDayID = day.id } label: {
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(contributionColor(day.totals.totalTokens, maximum: maximum))
                            .frame(width: 15, height: max(2, 32 * fraction))
                            .frame(height: 32, alignment: .bottom)
                        Text(weekday(day.date))
                            .font(.system(size: 9, weight: isToday ? .semibold : .regular))
                            .foregroundStyle(isToday ? .primary : .secondary)
                    }
                    .frame(width: 22)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 3)
                        .fill(day.id == selectedID ? tint.opacity(0.12) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in if hovering { selectedDayID = day.id } }
                .help("\(weekday(day.date))\(isToday ? " · Today" : "") · \(day.totals.totalTokens.formatted(.number.locale(locale))) tokens\n"
                    + metrics(day.totals).map { "\($0.0): \($0.1.formatted(.number.locale(locale)))" }.joined(separator: " · "))
                .accessibilityLabel("\(provider), \(weekday(day.date))\(isToday ? ", today" : ""), \(day.totals.totalTokens) tokens")
                .accessibilityAddTraits(day.id == selectedID ? .isSelected : [])
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func contributionColor(_ tokens: Int, maximum: Int) -> Color {
        guard tokens > 0, maximum > 0 else { return Color.secondary.opacity(0.10) }
        let fraction = Double(tokens) / Double(maximum)
        let opacity: Double = fraction <= 0.25 ? 0.25 : fraction <= 0.5 ? 0.45 : fraction <= 0.75 ? 0.7 : 1
        return tint.opacity(opacity)
    }
}

struct ResetCardSection: View {
    let data: UsageValue<ResetCardInventory>
    let provider: String
    let referenceDate: Date
    var expandedOverride: Bool? = nil
    @AppStorage private var isExpanded: Bool
    @Environment(\.timeZone) private var timeZone
    @Environment(\.locale) private var locale

    init(data: UsageValue<ResetCardInventory>, provider: String, referenceDate: Date,
         expandedOverride: Bool? = nil, storageID: String = "default") {
        self.data = data
        self.provider = provider
        self.referenceDate = referenceDate
        self.expandedOverride = expandedOverride
        _isExpanded = AppStorage(wrappedValue: false, "\(provider)ResetCardsExpanded.\(storageID)")
    }

    private var expanded: Binding<Bool> {
        Binding(get: { expandedOverride ?? isExpanded }, set: { isExpanded = $0 })
    }

    var body: some View {
        DisclosureGroup(isExpanded: expanded) {
            VStack(alignment: .leading, spacing: 6) {
                if let inventory = data.value {
                    let batches = inventory.availableBatches(at: referenceDate)
                    ForEach(batches) { batch in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("\(batch.count) reset\(batch.count == 1 ? "" : "s")")
                                Spacer(minLength: 6)
                                Text(batch.expiresAt.map { "Expires \(expiryDate($0))" } ?? "Expiry unknown")
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                            if batch.paused {
                                Text("Temporarily paused").foregroundStyle(.orange)
                            } else if let start = batch.startsAt, start > referenceDate {
                                Text("Available from \(expiryDate(start))").foregroundStyle(.secondary)
                            } else if batch.requiresLimit {
                                Text("Usable when an eligible limit is reached").foregroundStyle(.secondary)
                            }
                        }.font(.caption2).accessibilityElement(children: .combine)
                    }
                    let known = batches.reduce(0) { $0 + min(max(0, inventory.count(at: referenceDate) - $0), $1.count) }
                    if inventory.count(at: referenceDate) > known {
                        Text("\(inventory.count(at: referenceDate) - known) reset(s) · expiry unknown")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if inventory.count(at: referenceDate) == 0 {
                        Text(provider == "Claude" ? "No limit resets available." : "No banked resets available.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                SectionMessage(message: data.message, status: data.status)
            }.padding(.top, 5)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(provider == "Claude" ? "Limit resets" : "Banked resets").font(.caption.weight(.semibold))
                        .accessibilityLabel("\(provider) reset cards")
                    Spacer()
                    Text(data.value.map { "\($0.count(at: referenceDate)) available" } ?? "—")
                        .font(.caption.weight(.semibold)).monospacedDigit()
                    if data.isStale { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                }
                if let expiry = data.value?.availableBatches(at: referenceDate).first(where: { $0.expiresAt != nil })?.expiresAt {
                    Text("Next expiry \(expiryDate(expiry)) · \(expiryCountdown(expiry))")
                        .font(.caption2).foregroundStyle(expiry.timeIntervalSince(referenceDate) < 86_400 ? .orange : .secondary)
                }
            }
        }
    }

    private func expiryDate(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, timeZone: timeZone))
    }

    private func expiryCountdown(_ date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(referenceDate)))
        if seconds >= 86_400 { return "\(seconds / 86_400)d \(seconds % 86_400 / 3_600)h left" }
        return "\(seconds / 3_600)h \(seconds % 3_600 / 60)m left"
    }
}

struct CodexAccountsSection: View {
    @ObservedObject var store: UsageStore
    let referenceDate: Date
    var expandedOverride: Bool? = nil
    var cardsExpandedOverride: Bool? = nil
    @AppStorage("codexAccountsExpanded") private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expandedOverride ?? isExpanded }, set: { isExpanded = $0 })) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(store.snapshot.codexAccounts.value ?? []) { account in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(workspaceTitle(account))
                                    .font(.caption.weight(.semibold)).textSelection(.enabled)
                                if let email = account.accountName {
                                    Text(email).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                Text(account.planName.map { "Plan: \($0)" } ?? "Plan: Unknown")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 6)
                            StatusPill(value: account.quota, referenceDate: referenceDate)
                        }
                        if let quota = account.quota.value {
                            ForEach(quota.windows ?? [quota], id: \.label) { window in
                                QuotaWindowRow(window: window, tint: .teal, referenceDate: referenceDate)
                            }
                        }
                        SectionMessage(message: account.quota.message, status: account.quota.status)
                        if let id = account.loginProfileID, account.quota.status != .ready {
                            Button("Sign in…") { store.signInCodexWorkspace(id: id, label: account.workspaceName ?? "Workspace") }
                                .font(.caption).disabled(store.isSigningInCodex)
                        }
                        ResetCardSection(data: account.resetCards, provider: "Codex", referenceDate: referenceDate,
                                         expandedOverride: cardsExpandedOverride, storageID: account.id)
                    }
                    if account.id != store.snapshot.codexAccounts.value?.last?.id { Divider() }
                }
                if store.snapshot.codexAccounts.value == nil {
                    EmptyState(message: store.snapshot.codexAccounts.message ?? "Accounts have not been read yet.")
                } else {
                    SectionMessage(message: store.snapshot.codexAccounts.message, status: store.snapshot.codexAccounts.status)
                }
                HStack {
                    Button("Add workspace…") { store.addCodexWorkspace() }.disabled(store.isSigningInCodex)
                    Button("Open configuration…") { store.openAccountConfiguration() }
                }.font(.caption)
                if let message = store.codexLoginMessage {
                    HStack(alignment: .top, spacing: 6) {
                        if store.isSigningInCodex { ProgressView().controlSize(.mini) }
                        Text(message).font(.caption2).foregroundStyle(.secondary)
                    }
                    if store.canRetryCodexLogin {
                        Button("Retry sign-in…") { store.retryCodexWorkspaceSignIn() }.font(.caption)
                    }
                }
                Text("Each workspace has its own plan and limits. Token history combines configured logs.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(.top, 6)
        } label: {
            HStack {
                Text("Codex workspaces").font(.caption.weight(.semibold))
                Spacer()
                if let accounts = store.snapshot.codexAccounts.value {
                    Text("\(accounts.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func workspaceTitle(_ account: CodexAccountUsage) -> String {
        let title = account.workspaceName ?? account.displayName
        let duplicates = store.snapshot.codexAccounts.value?.filter {
            ($0.workspaceName ?? $0.displayName) == title && $0.accountName == account.accountName
        }.count ?? 0
        return duplicates > 1 ? "\(title) · \(account.id.prefix(8))" : title
    }
}
