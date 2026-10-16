import Foundation

@main
struct ScheduleTests {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @MainActor
    private final class Suite {
        var count = 0
        func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            count += 1
            guard try condition() else { throw Failure(message: message) }
        }
        func rejects(_ message: String, _ body: () throws -> Void) throws {
            count += 1
            do { try body() } catch { return }
            throw Failure(message: message)
        }
        func folder() throws -> URL {
            let value = FileManager.default.temporaryDirectory.appendingPathComponent("Planner-schedule-test-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
            return value
        }
        func run() throws {
            try crudAndValidation()
            try sortingAndSummary()
            try earlierSchemas()
            try interleavedWidgetWrites()
            try invalidStoredLessons()
        }

        private func crudAndValidation() throws {
            let directory = try folder()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = CalendarStore(directory: directory)
            let day = CalendarMath().date(day: 29, month: 2, year: 2028)!
            try expect(store.lessons.isEmpty && store.isAvailable, "Первый запуск не содержит демонстрационного расписания")
            let lesson = try store.saveLesson(subject: "  Математика \n", date: day, startMinute: 510, endMinute: 600, homework: "  Задачи 1–5  ", room: " 305 ", teacher: " Иванова ")
            try expect(lesson.subject == "Математика" && lesson.homework == "Задачи 1–5" && lesson.room == "305" && lesson.teacher == "Иванова", "Название и дополнительные поля нормализованы")
            try expect(lesson.timeRange == "08:30–10:00" && lesson.civilDay == CivilDay(year: 2028, month: 2, day: 29), "Время и високосная дата занятия сохранены")
            let next = CalendarMath().shifting(day, by: 1, mode: .day)
            let edited = try store.saveLesson(id: lesson.id, subject: "Физика", date: next, startMinute: 620, endMinute: 710, homework: "Лабораторная", room: "402", teacher: "Петров")
            try expect(edited.id == lesson.id && store.lessons.count == 1, "Редактирование сохраняет идентификатор и не дублирует занятие")
            try expect(store.lessons(on: day).isEmpty && store.lessons(on: next) == [edited], "Перенос занятия обновляет обе даты")
            let reopened = CalendarStore(directory: directory)
            try expect(reopened.lessons == [edited] && reopened.isAvailable, "Все поля занятия сохранены после перезапуска")

            try rejects("Пустое название не сохраняется") { try store.saveLesson(subject: " \n ", date: day, startMinute: 100, endMinute: 200, homework: "", room: "", teacher: "") }
            for (start, end) in [(-1, 90), (0, 0), (600, 599), (600, 600), (1440, 1441), (1380, 1440)] {
                try rejects("Некорректное время не сохраняется: \(start)–\(end)") {
                    try store.saveLesson(subject: "Некорректное", date: day, startMinute: start, endMinute: end, homework: "", room: "", teacher: "")
                }
            }
            let outside = CalendarMath().shifting(CalendarMath().supportedDates.upperBound, by: 1, mode: .day)
            try rejects("Дата вне допустимого диапазона не сохраняется") { try store.saveLesson(subject: "Некорректная дата", date: outside, startMinute: 100, endMinute: 200, homework: "", room: "", teacher: "") }
            try rejects("Бесконечная дата не сохраняется") { try store.saveLesson(subject: "Некорректная дата", date: Date(timeIntervalSinceReferenceDate: .infinity), startMinute: 100, endMinute: 200, homework: "", room: "", teacher: "") }
            try rejects("Несуществующее занятие не редактируется") { try store.saveLesson(id: UUID(), subject: "Нет занятия", date: day, startMinute: 100, endMinute: 200, homework: "", room: "", teacher: "") }
            try expect(store.lessons == [edited], "Ошибка валидации не меняет расписание")

            let group = try store.saveGroup(name: "Задачи", colorHex: "#446688")
            _ = try store.saveTask(title: "Дело", date: next, groupID: group.id, note: "")
            store.deleteGroup(group)
            try expect(store.lessons == [edited] && store.tasks.first?.groupID == nil, "Удаление группы дел не влияет на занятия")
            store.deleteLesson(edited)
            try expect(store.lessons.isEmpty && store.tasks.count == 1, "Удаление занятия не затрагивает дела")
            try expect(CalendarStore(directory: directory).lessons.isEmpty, "Удаление занятия сохраняется после перезапуска")
        }

        private func sortingAndSummary() throws {
            let directory = try folder()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = CalendarStore(directory: directory)
            let date = CalendarMath().date(day: 31, month: 12, year: 2026)!
            let later = try store.saveLesson(subject: "Вторая", date: date, startMinute: 720, endMinute: 810, homework: "", room: "", teacher: "")
            let first = try store.saveLesson(subject: "Первая", date: date, startMinute: 510, endMinute: 600, homework: "", room: "", teacher: "")
            let overlapping = try store.saveLesson(subject: "Другая группа потока", date: date, startMinute: 510, endMinute: 570, homework: "", room: "", teacher: "")
            try expect(store.lessons(on: date).map(\.id) == [overlapping.id, first.id, later.id], "Занятия упорядочены по началу, затем окончанию")
            try expect(UniversityLesson.summary([later, first]) == "2 пары\nс 08:30 до 13:30", "Сводка использует минимум начала и максимум окончания независимо от порядка")
            try expect(UniversityLesson.summary([]) == nil, "У пустого дня нет ложной сводки")
            for (number, text) in [(0, "0 пар"), (1, "1 пара"), (2, "2 пары"), (4, "4 пары"), (5, "5 пар"), (11, "11 пар"), (12, "12 пар"), (14, "14 пар"), (21, "21 пара"), (22, "22 пары"), (25, "25 пар"), (101, "101 пара"), (111, "111 пар")] {
                try expect(UniversityLesson.lessonCountText(number) == text, "Русское склонение количества: \(number)")
            }
            try expect(UniversityLesson.time(0) == "00:00" && UniversityLesson.time(1439) == "23:59", "Время форматируется на границах суток")
            let yearDay = CalendarMath().date(day: 1, month: 1, year: 2027)!
            _ = try store.saveLesson(subject: "В новом году", date: yearDay, startMinute: 400, endMinute: 450, homework: "", room: "", teacher: "")
            try expect(store.lessons(on: date).count == 3 && store.lessons(on: yearDay).count == 1, "Расписание разделено по датам на границе года")
            let pinned = UniversityLesson(subject: "Високосный день", civilDay: CivilDay(year: 2028, month: 2, day: 29), startMinute: 510, endMinute: 600, homework: "", room: "", teacher: "")
            for name in ["Asia/Irkutsk", "America/Los_Angeles", "Pacific/Kiritimati"] {
                let zone = TimeZone(identifier: name)!
                let resolved = pinned.civilDay.date(in: zone)!
                try expect(CivilDay(date: resolved, timeZone: zone) == pinned.civilDay && pinned.timeRange == "08:30–10:00", "Календарная дата и настенное время не зависят от пояса")
            }
        }

        private func earlierSchemas() throws {
            let day = CalendarMath().date(day: 15, month: 10, year: 2026)!
            for version in [1, 2] {
                let directory = try folder()
                defer { try? FileManager.default.removeItem(at: directory) }
                let task = PlannerTask(title: "Ранее сохранённое дело", date: day, note: "Заметка")
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .millisecondsSince1970
                var taskObject = try JSONSerialization.jsonObject(with: encoder.encode(task)) as! [String: Any]
                if version == 1 { taskObject.removeValue(forKey: "day"); taskObject["date"] = day.timeIntervalSince1970 * 1000 }
                let original = try JSONSerialization.data(withJSONObject: ["schemaVersion": version, "tasks": [taskObject], "groups": []])
                let primary = directory.appendingPathComponent("planner.json")
                try original.write(to: primary, options: .atomic)
                let store = CalendarStore(directory: directory)
                try expect(store.isAvailable && store.tasks.count == 1 && store.lessons.isEmpty, "Формат \(version) открывается без выдуманных занятий")
                _ = try store.saveLesson(subject: "Новая пара", date: day, startMinute: 500, endMinute: 590, homework: "", room: "", teacher: "")
                let current = try JSONSerialization.jsonObject(with: Data(contentsOf: primary)) as! [String: Any]
                try expect(current["schemaVersion"] as? Int == 4, "Запись после формата \(version) использует формат 4")
                try expect(try Data(contentsOf: directory.appendingPathComponent("planner.backup.json")) == original, "Прежний формат \(version) сохранён в резервной копии")
                let reopened = CalendarStore(directory: directory)
                try expect(reopened.tasks.first?.id == task.id && reopened.tasks.first?.note == "Заметка" && reopened.lessons.count == 1, "Миграция формата \(version) сохраняет старые дела и новые занятия")
            }
        }

        private func interleavedWidgetWrites() throws {
            let directory = try folder()
            defer { try? FileManager.default.removeItem(at: directory) }
            let storage = SharedPlannerStorage(directory: directory, isShared: true)
            let app = CalendarStore(storage: storage)
            let widget = CalendarStore(storage: storage)
            let date = CalendarMath().date(day: 29, month: 2, year: 2028)!
            let task = try app.saveTask(title: "Задание", date: date, groupID: nil, note: "")
            let first = try app.saveLesson(subject: "Математика", date: date, startMinute: 510, endMinute: 600, homework: "", room: "", teacher: "")
            try widget.setTaskCompleted(id: task.id, isCompleted: true)
            try expect(widget.lessons == [first], "Intent виджета сохраняет ранее добавленное расписание")
            let second = try app.saveLesson(subject: "Физика", date: date, startMinute: 620, endMinute: 710, homework: "", room: "", teacher: "")
            try expect(app.tasks.first?.isCompleted == true, "Новая пара сохраняет выполнение дела из виджета")
            _ = try widget.saveTask(id: task.id, title: "Изменённое задание", date: date, groupID: nil, note: "Новая заметка")
            try expect(widget.lessons.count == 2, "Устаревшее редактирование дела не удаляет новую пару")
            let edited = try app.saveLesson(id: first.id, subject: "Алгебра", date: date, startMinute: 520, endMinute: 610, homework: "Практика", room: "101", teacher: "Преподаватель")
            try expect(app.tasks.first?.title == "Изменённое задание", "Редактирование пары сохраняет новый текст дела другого процесса")
            try widget.setTaskCompleted(id: task.id, isCompleted: false)
            try expect(widget.lessons.contains(edited) && widget.lessons.contains(second), "Повторный intent сохраняет изменённую и добавленную пары")
            app.deleteLesson(second)
            try widget.setTaskCompleted(id: task.id, isCompleted: true)
            try expect(widget.lessons == [edited], "Intent не воскрешает удалённую пару")
            app.reloadFromDisk()
            try expect(app.tasks.first?.isCompleted == true && app.lessons == [edited], "Два живых процесса сходятся к одному состоянию")
        }

        private func invalidStoredLessons() throws {
            let directory = try folder()
            defer { try? FileManager.default.removeItem(at: directory) }
            let primary = directory.appendingPathComponent("planner.json")
            let day = CivilDay(year: 2026, month: 10, day: 15)
            let invalid = UniversityLesson(subject: "Некорректная пара", civilDay: day, startMinute: 600, endMinute: 500, homework: "", room: "", teacher: "")
            struct Fixture: Encodable { let schemaVersion: Int; let tasks: [PlannerTask]; let groups: [TaskGroup]; let lessons: [UniversityLesson] }
            let encoder = JSONEncoder()
            let broken = try encoder.encode(Fixture(schemaVersion: 3, tasks: [], groups: [], lessons: [invalid]))
            try broken.write(to: primary, options: .atomic)
            let store = CalendarStore(directory: directory)
            try expect(!store.isAvailable && store.lessons.isEmpty && store.errorMessage != nil, "Некорректная сохранённая пара не публикуется")
            try rejects("Повреждённое расписание нельзя затереть пустой базой") { try store.saveTask(title: "Новое", date: Date(), groupID: nil, note: "") }
            try expect(try Data(contentsOf: primary) == broken, "Оригинал повреждённого расписания сохранён")
            let valid = UniversityLesson(subject: "Корректная пара", civilDay: day, startMinute: 500, endMinute: 600, homework: "", room: "", teacher: "")
            let duplicate = try encoder.encode(Fixture(schemaVersion: 3, tasks: [], groups: [], lessons: [valid, valid]))
            try duplicate.write(to: primary, options: .atomic)
            try expect(!CalendarStore(directory: directory).isAvailable, "Повторяющийся идентификатор занятия отклоняется")
            let future = Data("{\"schemaVersion\":5,\"future\":true}".utf8)
            try future.write(to: primary, options: .atomic)
            let unsupported = CalendarStore(directory: directory)
            try expect(!unsupported.isAvailable && unsupported.errorMessage?.contains("5") == true, "Будущий формат 5 не считается текущим расписанием")
            try expect(try Data(contentsOf: primary) == future, "Данные будущего формата не изменены")
        }
    }

    @MainActor
    static func main() {
        let suite = Suite()
        do {
            try suite.run()
            print("ScheduleTests: \(suite.count) проверок расписания, совместимости и сохранности общих данных пройдено.")
        } catch {
            fputs("ОШИБКА ScheduleTests: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
