import Foundation

/// Group pages are an overlay on calendar navigation. Opening or closing a group
/// never replaces the date or mode to which the user returns.
struct PlannerNavigation: Equatable {
    var selectedDate: Date
    private(set) var mode: CalendarMode
    private(set) var selectedGroupID: UUID?

    init(selectedDate: Date = Date(), mode: CalendarMode = .month) {
        self.selectedDate = selectedDate
        self.mode = mode
        self.selectedGroupID = nil
    }

    mutating func toggleGroup(_ id: UUID) {
        selectedGroupID = selectedGroupID == id ? nil : id
    }

    mutating func showCalendar(_ mode: CalendarMode) {
        self.mode = mode
        selectedGroupID = nil
    }

    mutating func clearGroupIfMissing(in groups: [TaskGroup]) {
        guard let selectedGroupID,
              selectedGroupID != TaskGroup.ungrouped.id,
              !groups.contains(where: { $0.id == selectedGroupID }) else { return }
        self.selectedGroupID = nil
    }
}
