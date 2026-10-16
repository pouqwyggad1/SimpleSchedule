import Foundation
import WidgetKit

extension Notification.Name {
    static let calendarWidgetDateRequested = Notification.Name("CalendarWidgetDateRequested")
    static let calendarWidgetDayRequested = Notification.Name("CalendarWidgetDayRequested")
    static let plannerSharedDataChanged = Notification.Name("ru.local.GoldenGateCalendar.sharedDataChanged")
}

/// These are local application URLs, never network requests.
enum WidgetDeepLink: Equatable {
    case chooseDate(CivilDay)
    case openDay(CivilDay)

    init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "goldencalendar", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.path.isEmpty,
              let value = parts.queryItems?.first(where: { $0.name == "day" })?.value,
              let day = Self.parseDay(value) else { return nil }
        switch parts.host {
        case "widget-date": self = .chooseDate(day)
        case "day": self = .openDay(day)
        default: return nil
        }
    }

    var day: CivilDay {
        switch self { case .chooseDate(let day), .openDay(let day): day }
    }

    var url: URL {
        var parts = URLComponents()
        parts.scheme = "goldencalendar"
        switch self { case .chooseDate: parts.host = "widget-date"; case .openDay: parts.host = "day" }
        parts.queryItems = [URLQueryItem(name: "day", value: Self.dayString(day))]
        return parts.url!
    }

    static func dayString(_ day: CivilDay) -> String {
        String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
    }

    static func parseDay(_ value: String) -> CivilDay? {
        let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              value.utf8.allSatisfy({ (48...57).contains($0) || $0 == 45 }),
              let year = Int(pieces[0]), let month = Int(pieces[1]), let number = Int(pieces[2]) else { return nil }
        let day = CivilDay(year: year, month: month, day: number)
        return day.isValid ? day : nil
    }
}

struct PlannerWidgetSnapshot: Sendable {
    var selectedDate: Date
    var tasks: [PlannerTask]
    var groups: [TaskGroup]
    var followsToday: Bool
    var errorMessage: String?

    func group(for task: PlannerTask) -> TaskGroup? {
        groups.first { $0.id == task.groupID }
    }
}

/// Every widget action reads and commits inside the app's own shared container.
/// No extension writes to the application's private/legacy container.
@MainActor
enum WidgetBridge {
    static let kind = "ru.local.GoldenGateCalendar.DayWidget"

    static func snapshot(now: Date = Date()) -> PlannerWidgetSnapshot {
        do {
            let storage = try SharedPlannerStorage.resolve(for: .widget)
            let state = try storage.readWidgetState()
            let day = state.effectiveDay(now: now)
            guard let date = day.date(in: .current) else { throw DataStoreError.invalidDate }
            let store = CalendarStore(storage: storage)
            guard store.isAvailable else {
                throw DataStoreError.storageUnavailable(store.errorMessage ?? "Не удалось открыть данные виджета.")
            }
            return PlannerWidgetSnapshot(selectedDate: date,
                tasks: store.tasks(on: date), groups: store.groups,
                followsToday: state.selectedDay == nil,
                errorMessage: state.intentError ?? store.errorMessage)
        } catch {
            return PlannerWidgetSnapshot(selectedDate: CalendarMath().startOfDay(now),
                tasks: [], groups: [], followsToday: true,
                errorMessage: error.localizedDescription)
        }
    }

    static func selectDate(_ date: Date) throws {
        guard CalendarMath().isSupported(date) else { throw DataStoreError.invalidDate }
        let storage = try SharedPlannerStorage.resolve(for: .widget)
        try storage.updateWidgetState {
            $0.selectedDay = CivilDay(date: date)
            $0.intentError = nil
        }
        notifyDataChanged()
    }

    static func shiftDay(by amount: Int, now: Date = Date()) throws {
        guard amount == -1 || amount == 1 else { throw DataStoreError.invalidDate }
        let storage = try SharedPlannerStorage.resolve(for: .widget)
        var invalidDate = false
        try storage.updateWidgetState { state in
            guard let current = state.effectiveDay(now: now).date(in: .current) else {
                invalidDate = true; return
            }
            let shifted = CalendarMath().shifting(current, by: amount, mode: .day)
            guard CalendarMath().isSupported(shifted) else { invalidDate = true; return }
            state.selectedDay = CivilDay(date: shifted)
            state.intentError = nil
        }
        if invalidDate { throw DataStoreError.invalidDate }
        notifyDataChanged()
    }

    static func showToday() throws {
        let storage = try SharedPlannerStorage.resolve(for: .widget)
        try storage.updateWidgetState { $0.selectedDay = nil; $0.intentError = nil }
        notifyDataChanged()
    }

    static func setCompleted(taskID: String, isCompleted: Bool) throws {
        guard let id = UUID(uuidString: taskID) else { throw DataStoreError.taskNotFound }
        let storage = try SharedPlannerStorage.resolve(for: .widget)
        let store = CalendarStore(storage: storage)
        try store.setTaskCompleted(id: id, isCompleted: isCompleted)
        try storage.updateWidgetState { $0.intentError = nil }
        notifyDataChanged()
    }

    /// AppIntent cannot show an alert. Persist the failure for its next timeline.
    static func recordFailure(_ error: Error) {
        if let storage = try? SharedPlannerStorage.resolve(for: .widget) {
            try? storage.updateWidgetState { $0.intentError = error.localizedDescription }
        }
        notifyDataChanged()
    }

    static func notifyDataChanged() {
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
        DistributedNotificationCenter.default().postNotificationName(
            .plannerSharedDataChanged, object: nil, userInfo: nil, deliverImmediately: true)
    }
}
