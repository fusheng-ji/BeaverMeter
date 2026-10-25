import AppKit
import Combine
import Foundation

/// Appearance follows the system calendar independently of usage collection.
@MainActor
final class AppearanceStore: ObservableObject {
    @Published private(set) var settings: AppearanceSettings
    @Published private(set) var variant: BrandVariant
    @Published private(set) var errorMessage: String?

    private let observesChanges: Bool
    private let referenceDate: Date?
    private let timeZone: TimeZone?
    private let settingsURL: URL
    private var subscriptions: Set<AnyCancellable> = []
    private var midnightTask: Task<Void, Never>?

    init(
        settings: AppearanceSettings = .load(),
        observesChanges: Bool = true,
        referenceDate: Date? = nil,
        timeZone: TimeZone? = nil,
        settingsURL: URL = AppearanceSettings.settingsURL
    ) {
        let initialDate = referenceDate ?? .now
        let initialTimeZone = timeZone ?? .current
        self.settings = settings
        self.observesChanges = observesChanges
        self.referenceDate = observesChanges ? referenceDate : initialDate
        self.timeZone = observesChanges ? timeZone : initialTimeZone
        self.settingsURL = settingsURL
        variant = settings.resolvedVariant(at: initialDate, timeZone: initialTimeZone)

        if observesChanges {
            observeCalendarChanges()
            scheduleNextMidnight()
        }
    }

    deinit {
        midnightTask?.cancel()
        // AnyCancellable cancels its notification subscription on deallocation.
    }

    func select(_ selection: AppearanceSelection) {
        guard selection != settings.selection else { return }
        let updated = AppearanceSettings(selection: selection)
        if observesChanges {
            do {
                try updated.save(to: settingsURL)
            } catch {
                // Keep the saved selection visible if persistence fails.
                errorMessage = "Could not save appearance: \(error.localizedDescription)"
                return
            }
        }
        settings = updated
        variant = updated.resolvedVariant(at: referenceDate ?? .now, timeZone: timeZone ?? .current)
        errorMessage = nil
    }

    private func observeCalendarChanges() {
        for notification in [Notification.Name.NSCalendarDayChanged, NSApplication.didBecomeActiveNotification,
                             .NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            observe(notification, in: .default)
        }
        observe(NSWorkspace.didWakeNotification, in: NSWorkspace.shared.notificationCenter)
    }

    private func observe(_ notification: Notification.Name, in center: NotificationCenter) {
        center.publisher(for: notification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.calendarDidChange()
                }
            }
            .store(in: &subscriptions)
    }

    private func calendarDidChange() {
        let updated = settings.resolvedVariant(at: referenceDate ?? .now, timeZone: timeZone ?? .current)
        if updated != variant { variant = updated }
        scheduleNextMidnight()
    }

    private func scheduleNextMidnight() {
        midnightTask?.cancel()
        let now = referenceDate ?? .now
        guard let next = HolidayLogoResolver.futureMidnights(after: now, timeZone: timeZone ?? .current, count: 1).first
        else { return }
        let delay = max(0.1, next.timeIntervalSince(now))
        midnightTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.calendarDidChange()
        }
    }
}
