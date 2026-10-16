import SwiftUI
import WidgetKit

struct CalendarWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: PlannerWidgetSnapshot
}

/// WidgetKit's callback is delivered exactly once from the main actor, where the
/// shared observable store is isolated. The callback itself has no shared state.
private struct WidgetCallback<Value>: @unchecked Sendable {
    let complete: (Value) -> Void
}

struct CalendarWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> CalendarWidgetEntry {
        CalendarWidgetEntry(date: Date(), snapshot: PlannerWidgetSnapshot(
            selectedDate: Date(), tasks: [], groups: [], followsToday: true, errorMessage: nil))
    }

    func getSnapshot(in context: Context, completion: @escaping (CalendarWidgetEntry) -> Void) {
        let callback = WidgetCallback(complete: completion)
        Task { @MainActor in
            callback.complete(CalendarWidgetEntry(date: Date(), snapshot: WidgetBridge.snapshot()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CalendarWidgetEntry>) -> Void) {
        let callback = WidgetCallback(complete: completion)
        Task { @MainActor in
            let now = Date()
            let snapshot = WidgetBridge.snapshot(now: now)
            let math = CalendarMath()
            let tomorrow = math.calendar.date(byAdding: .day, value: 1, to: math.startOfDay(now))
                ?? now.addingTimeInterval(3600)
            // The future entry changes the date at midnight even before another
            // provider call. Manual date selection remains fixed until «Сегодня».
            var entries = [CalendarWidgetEntry(date: now, snapshot: snapshot)]
            if snapshot.followsToday {
                entries.append(CalendarWidgetEntry(date: tomorrow, snapshot: WidgetBridge.snapshot(now: tomorrow)))
            }
            callback.complete(Timeline(entries: entries, policy: .after(min(tomorrow, now.addingTimeInterval(900)))))
        }
    }
}

@main
struct CalendarDesktopWidget: Widget {
    let kind = "ru.local.GoldenGateCalendar.DayWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CalendarWidgetProvider()) { entry in
            CalendarWidgetView(snapshot: entry.snapshot)
                .containerBackground(.background, for: .widget)
                .environment(\.locale, Locale(identifier: "ru_RU"))
                .environment(\.calendar, CalendarMath().calendar)
        }
        .configurationDisplayName("Календарь и дела")
        .description("Дела выбранного дня с цветами групп. Отмечайте выполнение и перелистывайте дни.")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}
