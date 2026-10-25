import SwiftUI

/// Recorded activity stays inside its selected module, with its own source status.
struct WidgetActivitySummary: View {
    enum Layout { case inline, footer }

    let item: WidgetActivityItem
    var showsHistory = false
    var showsDetails = false
    var layout = Layout.inline

    init(item: WidgetActivityItem, showsHistory: Bool = false, showsDetails: Bool = false,
         layout: Layout = .inline) {
        self.item = item
        self.showsHistory = showsHistory
        self.showsDetails = showsDetails
        self.layout = layout
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            currentActivity
            if showsHistory, let days = item.history {
                WidgetActivityHistory(days: days, label: item.historyLabel ?? "Last 7 days",
                                      timeZoneIdentifier: item.historyTimeZoneIdentifier,
                                      status: item.historyStatus)
            } else if showsDetails, item.provider == .deepseek, let detail = item.detail {
                Text(detail)
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .modifier(WidgetSecondaryText())
                    .lineLimit(1)
                    .help(detail)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.provider.displayName) activity")
    }

    private var currentActivity: some View {
        Group {
            if layout == .footer { footerActivity }
            else { inlineActivity }
        }
        .lineLimit(1)
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityText)
        .help(item.accessibilityText)
    }

    private var footerActivity: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                footerReading(item.value)
                footerReading(item.compactValue)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let fetchedAt = item.fetchedAtLabel {
                Text(fetchedAt)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .modifier(WidgetSecondaryText())
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func footerReading(_ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .modifier(WidgetPrimaryText())
            Text(item.provider == .cursor ? "charged today" : item.caption)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .modifier(WidgetSecondaryText())
            activityStatus
        }
        .fixedSize()
    }

    private var inlineActivity: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                if let note = item.aggregationNote {
                    Text(note)
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .modifier(WidgetSecondaryText())
                }
                Text(item.value)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .modifier(WidgetPrimaryText())
                Text(item.provider == .cursor ? "charged today" : item.caption)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .modifier(WidgetSecondaryText())
                if let fetchedAt = item.fetchedAtLabel {
                    Text(fetchedAt)
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .modifier(WidgetSecondaryText())
                }
                activityStatus
            }
            .fixedSize(horizontal: true, vertical: true)
            HStack(spacing: 3) {
                Text(compactActivity)
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .modifier(WidgetSecondaryText())
                activityStatus
            }
            .fixedSize(horizontal: true, vertical: true)
            if let fetchedAt = item.fetchedAtLabel {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        Text("\(item.compactValue) \(item.caption)")
                            .font(.system(size: 8, weight: .medium, design: .rounded))
                            .modifier(WidgetSecondaryText())
                        activityStatus
                    }
                    Text(fetchedAt)
                        .font(.system(size: 7, weight: .medium, design: .rounded))
                        .modifier(WidgetSecondaryText())
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .lineLimit(1)
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityText)
        .help(item.accessibilityText)
    }

    @ViewBuilder
    private var activityStatus: some View {
        if item.status.severity != .normal { WidgetStatusIcon(status: item.status, size: 7) }
    }

    private var compactActivity: String {
        let caption: String
        switch item.caption {
        case "tokens today": caption = "tok today"
        case "actual charge today": caption = "charged today"
        case "tokens this month": caption = "tok / month"
        case "calls this month": caption = "calls / month"
        default: caption = item.caption
        }
        return (["\(item.compactValue) \(caption)", item.fetchedAtLabel, item.aggregationNote].compactMap { $0 }).joined(separator: " · ")
    }
}

/// Missing days keep their slot empty; a measured zero retains a thin baseline.
struct WidgetActivityHistory: View {
    let days: [WidgetActivityDay]
    let label: String
    let timeZoneIdentifier: String?
    let status: WidgetCardStatus?
    private var legibility = WidgetLegibility()
    private let chartHeight: CGFloat = 23

    init(days: [WidgetActivityDay], label: String, timeZoneIdentifier: String?, status: WidgetCardStatus?) {
        self.days = days
        self.label = label
        self.timeZoneIdentifier = timeZoneIdentifier
        self.status = status
    }

    private var maximum: Double { Double(max(0, days.compactMap(\.value).max() ?? 0)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(days) { day in
                    Group {
                        if let value = day.value, value >= 0 {
                            RoundedRectangle(cornerRadius: 1, style: .continuous)
                                .fill(legibility.primary.opacity(value == 0 ? 0.4 : 0.75))
                                .frame(height: barHeight(value))
                        } else {
                            Color.clear.frame(height: chartHeight)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: chartHeight, alignment: .bottom)
                    .help(dayDescription(day))
                }
            }
            .frame(height: chartHeight)
            HStack(spacing: 3) {
                Text(label)
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .modifier(WidgetSecondaryText())
                    .lineLimit(1)
                if let status, status.severity != .normal {
                    WidgetStatusIcon(status: status, size: 6)
                }
            }
            .frame(height: 10, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([context] + days.map(dayDescription) + [status?.detail].compactMap { $0 }).joined(separator: "; "))
        .help(([context] + days.map(dayDescription) + [status?.detail].compactMap { $0 }).joined(separator: "\n"))
    }

    private var context: String { label + (timeZoneIdentifier.map { " (\($0))" } ?? "") }

    private func barHeight(_ value: Int) -> CGFloat {
        guard value > 0, maximum > 0 else { return 1 }
        return max(1, min(chartHeight, CGFloat(Double(value) / maximum) * chartHeight))
    }

    private func dayDescription(_ day: WidgetActivityDay) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? TimeZone(secondsFromGMT: 0)!
        formatter.dateFormat = "EEE, MMM d"
        let value = day.value.flatMap { $0 >= 0 ? $0 : nil }
        return "\(formatter.string(from: day.date)): \(value.map { "\($0.formatted(.number.locale(UsageFormatting.locale))) tokens" } ?? "unknown")"
    }
}
