import SwiftUI

struct AntigravityUsageSection: View {
    let snapshot: UsageSnapshot
    let referenceDate: Date

    private var today: DailyTokenPresentation<AntigravityTokenTotals> {
        DailyTokenPresentation(snapshot.antigravityTokens, relativeTo: referenceDate)
    }

    private var quota: UsageValue<AntigravityQuotaSnapshot> {
        AntigravityQuotaVisibility.quota(snapshot.antigravityQuota, relativeTo: referenceDate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            UsageSectionHeader(title: "Antigravity today", provider: .antigravity, tint: .green,
                               value: today.data, referenceDate: referenceDate)
            if let tokens = today.data.value {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(today.value)
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("tokens").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if let count = tokens.requestCount {
                        Text("\(count.formatted()) requests").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(today.accessibilityText)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
                          alignment: .leading, spacing: 8) {
                    metric("Input", tokens.inputTokens)
                    metric("Cache read", tokens.cacheReadTokens)
                    metric("Cache write", tokens.cacheCreationTokens)
                    metric("Output", tokens.outputTokens)
                    metric("Reasoning", tokens.reasoningTokens)
                }
                SectionMessage(message: today.data.message, status: today.data.status)
            } else {
                EmptyState(message: today.data.message ?? "No local Antigravity token data yet.")
            }
            Text("From this Mac's Antigravity logs; separate from account quota.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.vertical, 2)
            HStack {
                Text("Online quota").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if let plan = quota.value?.planName {
                    Text(plan).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                StatusPill(value: quota, referenceDate: referenceDate)
            }
            ForEach(AntigravityQuotaGroupID.allCases, id: \.self) { id in
                group(id)
            }
            SectionMessage(message: quota.message, status: quota.status)
        }
    }

    private func metric(_ label: String, _ value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(UsageFormatting.tokens(value)).font(.caption.weight(.semibold)).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value.map { "\($0.formatted()) tokens" } ?? "unavailable")")
    }

    private func group(_ id: AntigravityQuotaGroupID) -> some View {
        let data = AntigravityQuotaVisibility.group(id, in: snapshot.antigravityQuota, relativeTo: referenceDate)
        return VStack(alignment: .leading, spacing: 5) {
            Text(id.title).font(.caption.weight(.semibold))
            if let primary = data.value {
                ForEach(primary.windows ?? [primary], id: \.label) { window in
                    QuotaWindowRow(window: window, tint: .green, referenceDate: referenceDate)
                }
            } else {
                Text(data.message ?? "Quota unavailable")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 3)
    }
}
