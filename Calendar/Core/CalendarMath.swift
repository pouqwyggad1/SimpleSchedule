import Foundation

/// All calendar calculations use the same civil calendar and the user's current time zone.
/// Calendar arithmetic, rather than fixed 24-hour intervals, also handles daylight saving time.
struct CalendarMath {
    var calendar: Calendar

    init(timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ru_RU")
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        self.calendar = calendar
    }

    /// The shared range for every date selector and calendar navigation action.
    var supportedDates: ClosedRange<Date> {
        date(day: 1, month: 1, year: 1)! ... date(day: 31, month: 12, year: 9999)!
    }

    /// Include the entire last civil day, including a DatePicker value with a time
    /// component. Reject extreme values before attempting to normalize them.
    func isSupported(_ date: Date) -> Bool {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return false }
        let bounds = supportedDates
        guard let exclusiveEnd = calendar.date(byAdding: .day, value: 1, to: bounds.upperBound) else { return false }
        return date >= bounds.lowerBound && date < exclusiveEnd
    }

    func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    func isSameDay(_ lhs: Date, _ rhs: Date) -> Bool {
        calendar.isDate(lhs, inSameDayAs: rhs)
    }

    func isSameMonth(_ lhs: Date, _ rhs: Date) -> Bool {
        calendar.isDate(lhs, equalTo: rhs, toGranularity: .month)
    }

    func weekDays(containing date: Date) -> [Date] {
        let day = startOfDay(date)
        let weekday = calendar.component(.weekday, from: day)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        guard let monday = calendar.date(byAdding: .day, value: -offset, to: day) else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: monday) }
    }

    func monthDays(containing date: Date) -> [Date] {
        guard let month = calendar.dateInterval(of: .month, for: date),
              let last = calendar.date(byAdding: .day, value: -1, to: month.end),
              let firstVisibleDay = weekDays(containing: month.start).first,
              let lastVisibleDay = weekDays(containing: last).last,
              let numberOfDays = calendar.dateComponents([.day], from: firstVisibleDay, to: lastVisibleDay).day
        else { return [] }
        return (0...numberOfDays).compactMap {
            calendar.date(byAdding: .day, value: $0, to: firstVisibleDay)
        }
    }

    func shifting(_ date: Date, by amount: Int, mode: CalendarMode) -> Date {
        let component: Calendar.Component = switch mode {
        case .month: .month
        case .week: .weekOfYear
        case .day: .day
        }
        return calendar.date(byAdding: component, value: amount, to: startOfDay(date)) ?? date
    }

    /// DateComponents normally rolls impossible dates into another month. Check the result
    /// explicitly so the date chooser can reject 31 February instead of silently changing it.
    func date(day: Int, month: Int, year: Int) -> Date? {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        let components = DateComponents(timeZone: calendar.timeZone, year: year, month: month, day: day, hour: 12)
        guard let result = calendar.date(from: components) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day], from: result)
        guard actual.year == year, actual.month == month, actual.day == day else { return nil }
        return startOfDay(result)
    }

    func dayNumber(_ date: Date) -> Int { calendar.component(.day, from: date) }
    func monthNumber(_ date: Date) -> Int { calendar.component(.month, from: date) }
    func yearNumber(_ date: Date) -> Int { calendar.component(.year, from: date) }
    func isWeekend(_ date: Date) -> Bool { calendar.isDateInWeekend(date) }
    func fullDate(_ date: Date) -> String { formatted(date, template: "EEEE, d MMMM yyyy") }
    func monthTitle(_ date: Date) -> String { formatted(date, template: "LLLL yyyy") }
    func weekdayTitle(_ date: Date) -> String { formatted(date, template: "EEEE") }
    func shortWeekdayTitle(_ date: Date) -> String { formatted(date, template: "EEE") }

    func formatted(_ date: Date, template: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}
