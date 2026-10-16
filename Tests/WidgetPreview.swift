import AppKit
import SwiftUI

/// Renders the real widget view with disposable fixtures, without registering a
/// widget, launching the calendar, or reading the user's planner/preferences.
@main
struct WidgetPreview {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let date = CalendarMath().date(day: 15, month: 10, year: 2026)!
        let study = TaskGroup(name: "Учеба", colorHex: "#388AFF")
        let personal = TaskGroup(name: "Личное", colorHex: "#F0A830")
        let pale = TaskGroup(name: "Белая метка", colorHex: "#FFFFFF")
        let tasks = [
            PlannerTask(title: "Подготовить доклад", date: date, groupID: study.id, note: "Эта заметка не должна отображаться"),
            PlannerTask(title: "Очень длинное название дела, которое должно аккуратно обрезаться", date: date, groupID: personal.id),
            PlannerTask(title: "Дело без группы", date: date),
            PlannerTask(title: "Выполненное дело", date: date, groupID: pale.id, isCompleted: true),
            PlannerTask(title: "Еще одно дело", date: date)
        ]
        let variants: [(String, CGFloat, CGFloat, ColorScheme, [PlannerTask])] = [
            ("widget-medium-dark", 344, 170, .dark, tasks),
            ("widget-medium-light", 344, 170, .light, tasks),
            ("widget-medium-compact", 320, 154, .dark, [tasks[0], tasks[3]]),
            ("widget-medium-empty", 344, 170, .dark, [])
        ]
        for (name, width, height, scheme, rows) in variants {
            let snapshot = PlannerWidgetSnapshot(selectedDate: date, tasks: rows,
                groups: [study, personal, pale], followsToday: true, errorMessage: nil)
            let view = CalendarWidgetView(snapshot: snapshot)
                .frame(width: width, height: height)
                .background(scheme == .dark ? Color(white: 0.09) : Color(white: 0.96))
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .environment(\.colorScheme, scheme)
                .environment(\.locale, Locale(identifier: "ru_RU"))
                .environment(\.calendar, CalendarMath().calendar)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try data.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
        }
        print("Четыре предпросмотра реального SwiftUI-вида записаны; это не проверка запуска WidgetKit.")
    }
}
