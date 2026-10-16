import Foundation

@main
struct WidgetLinkTests {
    static func main() {
        var count = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            count += 1
            guard condition() else { fputs("WidgetLinkTests: \(message)\n", stderr); exit(1) }
        }
        let days = [CivilDay(year: 1, month: 1, day: 1), CivilDay(year: 2028, month: 2, day: 29),
                    CivilDay(year: 2026, month: 12, day: 31), CivilDay(year: 9999, month: 12, day: 31)]
        for day in days {
            for link in [WidgetDeepLink.chooseDate(day), .openDay(day)] {
                expect(WidgetDeepLink(url: link.url) == link, "Локальная ссылка сохраняет назначение и дату")
                expect(link.url.scheme == "goldencalendar", "Ссылка использует только собственную схему")
                expect(WidgetDeepLink.parseDay(WidgetDeepLink.dayString(day)) == day, "Компоненты даты сохраняются независимо от часового пояса")
            }
        }
        let invalid = ["2027-02-29", "2026-13-01", "0000-01-01", "10000-01-01", "2026-04-31",
                       "2026-1-01", "2026-01-1", "2026-01-01/", "2026-01-01 12:00", "abcd-ef-gh"]
        for value in invalid { expect(WidgetDeepLink.parseDay(value) == nil, "Несуществующая или неоднозначная дата отвергается: \(value)") }
        let rejectedLinks = ["https://day?day=2026-10-15", "goldencalendar://other?day=2026-10-15",
            "goldencalendar://day/path?day=2026-10-15", "goldencalendar://day?day=2027-02-29",
            "goldencalendar://person@day?day=2026-10-15", "goldencalendar://day:80?day=2026-10-15",
            "goldencalendar://widget-date", "goldencalendar://day?date=2026-10-15"]
        for value in rejectedLinks { expect(WidgetDeepLink(url: URL(string: value)!) == nil, "Посторонняя ссылка не меняет интерфейс") }
        print("WidgetLinkTests: \(count) проверок локальных переходов виджета пройдено.")
    }
}
