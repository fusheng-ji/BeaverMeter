import SwiftUI
import WidgetKit

struct QuotaWidgetContent: View {
    let snapshot: UsageSnapshot
    let family: WidgetFamily
    var providers: [MeterProvider] = MeterProvider.allCases
    var referenceDate: Date = .now

    var body: some View {
        layout
            .padding(outerPadding)
    }

    @ViewBuilder
    private var layout: some View {
        if providers.isEmpty {
            Text("No services are switched on. Choose Services in the BeaverMeter menu.")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.62))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch family {
            case .systemSmall:
                // Strips only when three or four services must share the tile.
                let roomy = providers.count <= 2
                VStack(spacing: roomy ? 6 : 4) {
                    ForEach(providers, id: \.self) { provider in
                        item(provider,
                             quota: providers.count == 1 ? .hero : roomy ? .compact : .strip,
                             deepSeek: providers.count == 1 ? .tall : roomy ? .regular : .strip)
                    }
                }
            case .systemMedium where providers.count == 1:
                grid([providers], spacing: 7, quota: .hero, deepSeek: .regular)
            case .systemMedium:
                grid(ProviderGridLayout.rows(providers), spacing: 7, quota: .compact, deepSeek: .regular)
            case .systemLarge where providers.count <= 2:
                // A square tile reads better as full-width rows than as two tall columns.
                grid(providers.map { [$0] }, spacing: 12, quota: .hero, deepSeek: .tall)
            case .systemExtraLarge where providers.count <= 2:
                grid([providers], spacing: 12, quota: .hero, deepSeek: .tall)
            default:
                grid(ProviderGridLayout.rows(providers), spacing: 12, quota: .regular, deepSeek: .tall)
            }
        }
    }

    private func grid(
        _ rows: [[MeterProvider]], spacing: CGFloat, quota: QuotaPanelDensity, deepSeek: DeepSeekPanelDensity
    ) -> some View {
        VStack(spacing: spacing) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: spacing) {
                    ForEach(row, id: \.self) { provider in
                        item(provider, quota: quota, deepSeek: deepSeek)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func item(_ provider: MeterProvider, quota: QuotaPanelDensity, deepSeek: DeepSeekPanelDensity) -> some View {
        switch provider {
        case .codex: panel(.codex, density: quota)
        case .claude: panel(.claude, density: quota)
        case .cursor: panel(.cursor, density: quota)
        case .deepseek: deepSeekPanel(density: deepSeek)
        }
    }

    private var outerPadding: CGFloat {
        switch family {
        case .systemSmall: 8
        case .systemMedium: 10
        default: 14
        }
    }

    private func panel(_ provider: QuotaProviderKind, density: QuotaPanelDensity) -> some View {
        let data: UsageValue<CompactQuota>
        let dailyTokens: DailyTokenSummary?
        switch provider {
        case .codex:
            data = snapshot.codexQuota
            dailyTokens = CodexDailyTokenPresentation(snapshot.codexTokens, relativeTo: referenceDate).summary
        case .claude:
            data = snapshot.claudeQuota
            dailyTokens = ClaudeDailyTokenPresentation(snapshot.claudeTokens, relativeTo: referenceDate).summary
        case .cursor:
            data = snapshot.cursorQuota
            dailyTokens = nil
        }
        return QuotaProviderPanel(
            provider: provider,
            data: data,
            density: density,
            dailyTokens: dailyTokens,
            referenceDate: referenceDate
        )
    }

    private func deepSeekPanel(density: DeepSeekPanelDensity) -> some View {
        DeepSeekUsagePanel(
            data: snapshot.deepseekUsage,
            density: density,
            referenceDate: referenceDate
        )
    }
}

struct QuotaWidgetBackground: View {
    var body: some View {
        Color(red: 0.065, green: 0.07, blue: 0.085)
    }
}
