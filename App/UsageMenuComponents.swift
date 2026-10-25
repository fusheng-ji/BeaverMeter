import SwiftUI

private struct UsagePreviewRenderingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isRenderingUsagePreview: Bool {
        get { self[UsagePreviewRenderingKey.self] }
        set { self[UsagePreviewRenderingKey.self] = newValue }
    }
}

struct UsageSectionHeader<Value: Codable & Hashable & Sendable>: View {
    let title: String
    let provider: MeterProvider
    let tint: Color
    let value: UsageValue<Value>
    let referenceDate: Date

    var body: some View {
        HStack {
            Label {
                Text(title)
            } icon: {
                ProviderLogoView(provider: provider).accessibilityHidden(true)
            }
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
    let provider: MeterProvider
    let value: UsageValue<CompactQuota>
    var referenceDate: Date = .now

    private var presentation: UsageStatusPresentation { UsageStatusPresentation(value, relativeTo: referenceDate) }

    private var detail: String {
        guard let quota = value.value else { return UsageFormatting.status(value.status) }
        guard provider == .cursor else { return quota.detail }
        guard let remaining = quota.remaining, remaining.isFinite else { return "—" }
        return "\(UsageFormatting.usdCode(remaining)) left"
    }

    var body: some View {
        HStack(spacing: 7) {
            ProviderLogoView(provider: provider, size: 16).accessibilityHidden(true)
            if presentation.severity != .normal {
                Image(systemName: presentation.icon)
                    .foregroundStyle(presentation.severity == .critical ? .red : .orange)
                    .font(.caption2)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(value.value?.label ?? "Quota").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Text(detail)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help([provider == .cursor ? value.value?.detail : nil,
               value.value.flatMap { UsageFormatting.reset($0.resetAt) }, presentation.detail]
            .compactMap { $0 }.joined(separator: " · "))
        .accessibilityElement(children: .combine)
    }
}

/// Existing automatic detection stays intact until a service is toggled.
struct ServiceSettingsSection: View {
    @ObservedObject var store: UsageStore
    @State private var isExpanded: Bool
    @Environment(\.isRenderingUsagePreview) private var isRenderingPreview

    init(store: UsageStore, initiallyExpanded: Bool = false) {
        self.store = store
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 10) {
                ForEach(MeterProvider.allCases, id: \.self) { provider in
                    if isRenderingPreview {
                        // ImageRenderer cannot draw the AppKit-backed checkbox.
                        HStack(spacing: 5) {
                            Image(systemName: store.providerSettings.collects(provider) ? "checkmark.square.fill" : "square")
                            ProviderLogoView(provider: provider, size: 14).accessibilityHidden(true)
                            Text(provider.displayName)
                        }.font(.callout)
                    } else {
                        Toggle(isOn: Binding(
                            get: { store.providerSettings.collects(provider) },
                            set: { store.setVisibility($0 ? .shown : .hidden, for: provider) }
                        )) {
                            HStack(spacing: 5) {
                                ProviderLogoView(provider: provider, size: 14).accessibilityHidden(true)
                                Text(provider.displayName)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .font(.callout)
                        .help("Enable or disable \(provider.displayName) monitoring")
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Label("Services", systemImage: "slider.horizontal.3")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

struct AppearanceSettingsSection: View {
    @ObservedObject var appearance: AppearanceStore
    var expandedOverride: Bool?
    @State private var isExpanded = false
    @Environment(\.isRenderingUsagePreview) private var isRenderingPreview

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expandedOverride ?? isExpanded }, set: { isExpanded = $0 })) {
            VStack(alignment: .leading, spacing: 8) {
                if isRenderingPreview {
                    // ImageRenderer cannot render the AppKit-backed menu picker.
                    HStack {
                        Text("Logo")
                        Spacer()
                        Text(appearance.settings.selection.displayName).foregroundStyle(.secondary)
                    }.font(.callout)
                } else {
                    Picker("Logo", selection: Binding(
                        get: { appearance.settings.selection },
                        set: { appearance.select($0) }
                    )) {
                        ForEach(AppearanceSelection.allCases, id: \.self) { selection in
                            Text(selection.displayName).tag(selection)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel("Logo appearance")
                }
                Text("Automatic uses this Mac’s date and time zone. Outfits appear in the popover; the menu bar keeps its Classic Beaver outline.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = appearance.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Label("Appearance", systemImage: "paintpalette")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(appearance.variant.displayName)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
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
