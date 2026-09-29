import SwiftUI

struct UsageSectionHeader<Value: Codable & Hashable & Sendable>: View {
    let title: String
    let systemImage: String
    let tint: Color
    let value: UsageValue<Value>
    let referenceDate: Date

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            StatusPill(value: value, referenceDate: referenceDate)
        }
    }
}

struct TokenMetric: View {
    let label: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(UsageFormatting.tokens(value)).font(.caption.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value.formatted()) tokens")
    }
}

struct CursorEventRow: View {
    let event: CursorCostEvent
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        HStack(spacing: 10) {
            Text(event.occurredAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened,
                                                           locale: locale, timeZone: timeZone)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.model).font(.callout).lineLimit(1)
                if let tokenCount = event.tokenCount {
                    Text("\(UsageFormatting.tokens(tokenCount)) tokens" + (event.kind.map { " · \($0)" } ?? ""))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Text(UsageFormatting.usd(event.costUSD, minimumDigits: 2, maximumDigits: 4))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

struct DeepSeekMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct DeepSeekDetailLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .font(.caption)
    }
}

struct StatusPill<Value: Codable & Hashable & Sendable>: View {
    let value: UsageValue<Value>
    var referenceDate: Date = .now

    private var presentation: UsageStatusPresentation { UsageStatusPresentation(value, relativeTo: referenceDate) }
    private var tint: Color {
        switch presentation.severity {
        case .normal: .secondary
        case .warning: .orange
        case .critical: .red
        }
    }

    var body: some View {
        Label(presentation.label, systemImage: presentation.icon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .help(presentation.detail)
            .accessibilityLabel(presentation.detail)
    }
}

struct SectionMessage: View {
    let message: String?
    let status: UsageDataStatus

    var body: some View {
        if let message, status != .ready || !message.isEmpty {
            Label(message, systemImage: status == .ready ? "info.circle" : "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(status == .ready ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct EmptyState: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "questionmark.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8)
    }
}

struct QuotaLabel: View {
    let systemImage: String
    let tint: Color
    let value: UsageValue<CompactQuota>
    var referenceDate: Date = .now

    private var presentation: UsageStatusPresentation { UsageStatusPresentation(value, relativeTo: referenceDate) }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: presentation.severity == .normal ? systemImage : presentation.icon)
                .foregroundStyle(presentation.severity == .normal ? tint : presentation.severity == .critical ? .red : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(value.value?.label ?? "Quota").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Text(value.value?.detail ?? UsageFormatting.status(value.status))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help([value.value.flatMap { UsageFormatting.reset($0.resetAt) }, presentation.detail].compactMap { $0 }.joined(separator: " · "))
        .accessibilityElement(children: .combine)
    }
}

/// Auto shows a service once it has data on this Mac; On and Off override that.
struct ServiceSettingsSection: View {
    @ObservedObject var store: UsageStore
    @State private var isExpanded: Bool

    init(store: UsageStore, initiallyExpanded: Bool = false) {
        self.store = store
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 6) {
                ForEach(MeterProvider.allCases, id: \.self) { provider in
                    HStack {
                        Text(provider.displayName)
                            .font(.callout)
                        if store.providerSettings[provider] == .auto, !store.snapshot.isDetected(provider) {
                            Text("not detected")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VisibilityControl(selection: Binding(
                            get: { store.providerSettings[provider] },
                            set: { store.setVisibility($0, for: provider) }
                        ))
                        .accessibilityLabel("\(provider.displayName) visibility")
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Label("Services", systemImage: "slider.horizontal.3")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

/// SwiftUI-drawn segmented control, so screenshots render it like the App does.
private struct VisibilityControl: View {
    @Binding var selection: ProviderVisibility

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ProviderVisibility.allCases, id: \.self) { option in
                Button { selection = option } label: {
                    Text(title(option))
                        .font(.caption.weight(selection == option ? .semibold : .regular))
                        .frame(width: 42, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(selection == option ? Color.accentColor.opacity(0.85) : .clear)
                        )
                        .foregroundStyle(selection == option ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func title(_ option: ProviderVisibility) -> String {
        switch option {
        case .auto: "Auto"
        case .shown: "On"
        case .hidden: "Off"
        }
    }
}

/// One quota window, for services whose response has several (Claude).
struct QuotaWindowRow: View {
    let window: CompactQuota
    let tint: Color
    var referenceDate: Date = .now

    private var percent: Double? { UsageFormatting.clampedPercent(window.remainingPercent) }
    private var barTint: Color {
        guard let percent else { return tint }
        return percent < 20 ? .red : percent < 50 ? .orange : tint
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(window.windowTitle)
                .font(.caption.weight(.semibold))
                .frame(width: 92, alignment: .leading)
                .lineLimit(1)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(barTint).frame(width: proxy.size.width * (percent ?? 0) / 100)
                }
            }
            .frame(height: 5)
            .accessibilityHidden(true)
            Text("\(window.percentLeftText) left")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .frame(width: 58, alignment: .trailing)
            Text(UsageFormatting.resetCountdown(window.resetAt, relativeTo: referenceDate))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 104, alignment: .trailing)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}
