#if NATIVE_DIRECT_UPDATES
import AppKit

/// Stable and beta use the same app defaults. Persist only civil dates and the
/// month of the latest visible invitation, independent of the app language.
@MainActor final class SupportReminder {
    static let shared = SupportReminder()
    private struct History: Codable {
        var days: [Int] = []
        var lastMonth = 0
    }
    private let defaults: UserDefaults
    private let key = "authorSupport.usage.v1"
    private var activityMonitor: Any?
    private var observedDay: DateInterval?
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func beginRecordingUse() {
        guard activityMonitor == nil else { return }
        activityMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            if NSApp.isActive, event.window != nil { self?.recordForegroundUse() }
            return event
        }
    }
    func recordForegroundUse() {
        let now = Date()
        guard observedDay?.contains(now) != true else { return }
        observedDay = Calendar.current.dateInterval(of: .day, for: now)
        recordUse(at: now)
    }

    private var history: History {
        guard let data = defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode(History.self, from: data) else { return History() }
        return saved
    }
    private func save(_ history: History) {
        if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: key) }
    }
    private func civilDay(_ date: Date, timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
    }
    func recordUse(at date: Date = Date(), timeZone: TimeZone = .current) {
        var state = history
        guard state.days.count < 7 else { return }
        let today = civilDay(date, timeZone: timeZone)
        guard !state.days.contains(today) else { return }
        state.days.append(today)
        save(state)
    }
    func eligible(active: Bool, at date: Date = Date(), timeZone: TimeZone = .current) -> Bool {
        let state = history
        return !active && state.days.count == 7 && civilDay(date, timeZone: timeZone) / 100 > state.lastMonth
    }
    /// Call only once the invitation actually enters the visible Home viewport.
    func claimVisible(active: Bool, at date: Date = Date(), timeZone: TimeZone = .current) -> Bool {
        guard eligible(active: active, at: date, timeZone: timeZone) else { return false }
        var state = history
        state.lastMonth = civilDay(date, timeZone: timeZone) / 100
        save(state)
        return true
    }
}
#endif
