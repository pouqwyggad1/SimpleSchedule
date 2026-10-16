import Foundation

/// Standalone tests: no test framework, package resolution, network, app launch, or system settings.
/// Compile this file together with Calendar/Core/*.swift (see README).
@main
struct CoreTests {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @MainActor
    private final class Suite {
        var assertions = 0

        func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            assertions += 1
            guard try condition() else { throw Failure(message: message) }
        }

        func rejects(_ message: String, _ body: () throws -> Void) throws {
            assertions += 1
            do { try body() }
            catch { return }
            throw Failure(message: message)
        }

        func run() throws {
            try calendarBoundaries()
            try daylightSaving()
            try civilDatesAndMigration()
            try persistenceAndCRUD()
            try recoveryAndUnknownVersions()
            try failedWriteIsNotPublished()
        }

        private func temporaryDirectory(_ label: String) throws -> URL {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("GoldenCalendar-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }

        private func calendarBoundaries() throws {
            let math = CalendarMath(timeZone: TimeZone(identifier: "Asia/Irkutsk")!)
            try expect(math.calendar.firstWeekday == 2, "Неделя должна начинаться с понедельника")
            try expect(math.date(day: 29, month: 2, year: 2024) != nil, "Високосный 2024 год")
            try expect(math.date(day: 29, month: 2, year: 2000) != nil, "Високосный 2000 год")
            try expect(math.date(day: 29, month: 2, year: 1900) == nil, "1900 не високосный")
            try expect(math.date(day: 29, month: 2, year: 2025) == nil, "Не принимать 29 февраля обычного года")
            try expect(math.date(day: 31, month: 4, year: 2026) == nil, "Не принимать 31 апреля")
            try expect(math.date(day: 0, month: 1, year: 2026) == nil, "Не принимать нулевой день")
            try expect(math.date(day: 1, month: 13, year: 2026) == nil, "Не принимать тринадцатый месяц")
            try expect(math.date(day: 1, month: 1, year: 0) == nil, "Не принимать нулевой год")

            let firstSupported = math.supportedDates.lowerBound
            let lastSupported = math.supportedDates.upperBound
            try expect(math.isSupported(firstSupported) && math.isSupported(lastSupported), "Минимальная и максимальная даты доступны")
            try expect(math.yearNumber(firstSupported) == 1 && math.yearNumber(lastSupported) == 9999, "Общий диапазон охватывает годы от 1 до 9999")
            let beforeSupported = math.shifting(firstSupported, by: -1, mode: .day)
            let afterSupported = math.shifting(lastSupported, by: 1, mode: .day)
            try expect(!math.isSupported(beforeSupported), "Предыдущий день до года 1 недоступен")
            try expect(!math.isSupported(afterSupported), "Следующий день после года 9999 недоступен")
            try expect(math.isSupported(lastSupported.addingTimeInterval(12 * 60 * 60)), "Время внутри последнего допустимого дня принимается")
            try expect(!math.isSupported(Date(timeIntervalSinceReferenceDate: .infinity)), "Бесконечная дата недоступна")
            try expect(!math.isSupported(Date(timeIntervalSinceReferenceDate: .nan)), "Неопределённая дата недоступна")

            let january = math.date(day: 1, month: 1, year: 2027)!
            let week = math.weekDays(containing: january)
            try expect(week.count == 7, "Неделя содержит ровно семь дат")
            try expect(math.isSameDay(week[0], math.date(day: 28, month: 12, year: 2026)!), "Начало недели на границе года")
            try expect(math.isSameDay(week[6], math.date(day: 3, month: 1, year: 2027)!), "Конец недели на границе года")
            try expect(!math.isWeekend(week[4]) && math.isWeekend(week[5]) && math.isWeekend(week[6]), "Суббота и воскресенье определяются отдельно от будней")

            for (year, month, expectedCount) in [(2021, 2, 28), (2024, 2, 35), (2025, 3, 42), (2027, 1, 35)] {
                let selected = math.date(day: 15, month: month, year: year)!
                let grid = math.monthDays(containing: selected)
                try expect(grid.count == expectedCount, "Полные недели в сетке \(month).\(year)")
                try expect(math.calendar.component(.weekday, from: grid.first!) == 2, "Первый столбец — понедельник")
                try expect(math.calendar.component(.weekday, from: grid.last!) == 1, "Последний столбец — воскресенье")
                let monthDates = grid.filter { math.isSameMonth($0, selected) }
                try expect(monthDates.count == math.calendar.range(of: .day, in: .month, for: selected)!.count, "Все дни выбранного месяца присутствуют один раз")
                try expect(Set(grid).count == grid.count, "В сетке нет повторяющихся дат")
            }

            let endOfYear = math.date(day: 31, month: 12, year: 2026)!
            try expect(math.isSameDay(math.shifting(endOfYear, by: 1, mode: .day), january), "Стрелка дня переходит в новый год")
            try expect(math.isSameDay(math.shifting(january, by: -1, mode: .day), endOfYear), "Стрелка дня переходит в предыдущий год")
            let january31 = math.date(day: 31, month: 1, year: 2027)!
            try expect(math.isSameDay(math.shifting(january31, by: 1, mode: .month), math.date(day: 28, month: 2, year: 2027)!), "Месячный переход учитывает длину февраля")
            try expect(math.isSameDay(math.shifting(january, by: 1, mode: .week), math.date(day: 8, month: 1, year: 2027)!), "Стрелка недели добавляет семь календарных дней")
            let distant = math.date(day: 29, month: 2, year: 2040)!
            for mode in CalendarMode.allCases {
                // Modes are a projection of one selected date, not separate navigation state.
                switch mode {
                case .month: try expect(math.monthDays(containing: distant).contains(distant), "Произвольная дата в месяце")
                case .week: try expect(math.weekDays(containing: distant).contains(distant), "Произвольная дата в неделе")
                case .day: try expect(math.isSameDay(distant, math.startOfDay(distant)), "Произвольная дата в дне")
                }
            }
        }

        private func daylightSaving() throws {
            let math = CalendarMath(timeZone: TimeZone(identifier: "America/Los_Angeles")!)
            let sunday = math.date(day: 10, month: 3, year: 2024)!
            let monday = math.shifting(sunday, by: 1, mode: .day)
            try expect(math.dayNumber(monday) == 11, "Переход летнего времени не сдвигает календарный день")
            try expect(monday.timeIntervalSince(sunday) == 23 * 60 * 60, "Весенний день может содержать 23 часа")
            let week = math.weekDays(containing: sunday)
            try expect(week.count == 7 && math.dayNumber(week.first!) == 4 && math.dayNumber(week.last!) == 10, "Семь столбцов в неделю смены времени")
            let fall = math.date(day: 3, month: 11, year: 2024)!
            try expect(math.shifting(fall, by: 1, mode: .day).timeIntervalSince(fall) == 25 * 60 * 60, "Осенний день может содержать 25 часов")
        }

        private func civilDatesAndMigration() throws {
            let originalDate = CalendarMath().date(day: 15, month: 10, year: 2026)!
            let task = PlannerTask(title: "Одна дата в любом поясе", date: originalDate)
            let expectedDay = CivilDay(year: 2026, month: 10, day: 15)
            try expect(task.civilDay == expectedDay, "Дело хранит календарные компоненты даты")
            let zones = ["Asia/Irkutsk", "America/Los_Angeles", "Europe/London", "Pacific/Kiritimati", "Pacific/Pago_Pago"]
            for name in zones {
                let zone = TimeZone(identifier: name)!
                guard let resolved = task.date(in: zone) else { throw Failure(message: "Дата не представима в поясе \(name)") }
                try expect(CivilDay(date: resolved, timeZone: zone) == expectedDay, "Календарная дата сохраняется в поясе \(name)")
                try expect(CalendarMath(timeZone: zone).calendar.component(.hour, from: resolved) == 0, "Дата нормализована к началу дня в поясе \(name)")
            }
            let firstInstant = task.date(in: TimeZone(identifier: zones[0])!)!
            let secondInstant = task.date(in: TimeZone(identifier: zones[1])!)!
            try expect(firstInstant != secondInstant, "Разные пояса меняют момент времени, сохраняя календарный день")
            try expect(!CivilDay(year: 1900, month: 2, day: 29).isValid, "Каноническая дата проверяет високосность")
            try expect(CivilDay(year: 2000, month: 2, day: 29).isValid, "Каноническая дата допускает 29 февраля 2000")
            try expect(!CivilDay(year: 2026, month: 4, day: 31).isValid, "Каноническая дата отклоняет 31 апреля")

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let encoded = try encoder.encode(task)
            let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            let encodedDay = object["day"] as! [String: Int]
            try expect(encodedDay == ["year": 2026, "month": 10, "day": 15], "Новый формат записывает календарную дату")
            try expect(object["date"] == nil, "Дата дела не записывается как абсолютный момент")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let decoded = try decoder.decode(PlannerTask.self, from: encoded)
            try expect(decoded.civilDay == expectedDay, "Календарная дата сохраняется при кодировании и чтении")

            let directory = try temporaryDirectory("schema-migration")
            defer { try? FileManager.default.removeItem(at: directory) }
            let primary = directory.appendingPathComponent("planner.json")
            let taskID = UUID()
            let legacyTask: [String: Any] = [
                "id": taskID.uuidString,
                "title": "Данные первой версии",
                "date": originalDate.timeIntervalSince1970 * 1000,
                "note": "Заметка сохранена",
                "isCompleted": true,
                "createdAt": Date().timeIntervalSince1970 * 1000
            ]
            let legacy: [String: Any] = ["schemaVersion": 1, "tasks": [legacyTask], "groups": []]
            let legacyBytes = try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys])
            try legacyBytes.write(to: primary, options: .atomic)
            let migrated = CalendarStore(directory: directory)
            try expect(migrated.errorMessage == nil && migrated.tasks.count == 1, "Первая версия формата читается без потери данных")
            try expect(migrated.tasks[0].civilDay == expectedDay && migrated.tasks[0].isCompleted, "Миграция сохраняет дату и статус старого дела")
            try expect(try Data(contentsOf: primary) == legacyBytes, "Чтение первой версии не перезаписывает исходный файл")
            try migrated.saveTask(id: taskID, title: "Обновлено", date: migrated.tasks[0].date, groupID: nil, note: migrated.tasks[0].note)
            let currentDocument = try JSONSerialization.jsonObject(with: Data(contentsOf: primary)) as! [String: Any]
            try expect(currentDocument["schemaVersion"] as? Int == 4, "Следующая запись переводит документ в формат 4")
            try expect(try Data(contentsOf: directory.appendingPathComponent("planner.backup.json")) == legacyBytes, "Миграция сохраняет прежний документ в резервной копии")
            let reopened = CalendarStore(directory: directory)
            try expect(reopened.errorMessage == nil && reopened.tasks[0].civilDay == expectedDay, "Новый формат повторно открывается")
            try expect(reopened.tasks[0].title == "Обновлено" && reopened.tasks[0].note == "Заметка сохранена", "Миграция сохраняет остальные поля дела")

            let invalidDirectory = try temporaryDirectory("invalid-civil-day")
            defer { try? FileManager.default.removeItem(at: invalidDirectory) }
            let invalidPrimary = invalidDirectory.appendingPathComponent("planner.json")
            var invalidTask = object
            invalidTask["day"] = ["year": 2026, "month": 2, "day": 30]
            let invalidBytes = try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "tasks": [invalidTask], "groups": []])
            try invalidBytes.write(to: invalidPrimary, options: .atomic)
            let invalid = CalendarStore(directory: invalidDirectory)
            try expect(invalid.errorMessage != nil && invalid.tasks.isEmpty, "Некорректные компоненты календарной даты не публикуются")
            try rejects("Повреждённую календарную дату нельзя затереть новой записью") {
                try invalid.saveTask(title: "Новое дело", date: originalDate, groupID: nil, note: "")
            }
            try expect(try Data(contentsOf: invalidPrimary) == invalidBytes, "Файл с некорректной календарной датой сохранён без изменений")

            let missingComponents = try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "tasks": [legacyTask], "groups": []])
            try missingComponents.write(to: invalidPrimary, options: .atomic)
            let missing = CalendarStore(directory: invalidDirectory)
            try expect(missing.errorMessage != nil && missing.tasks.isEmpty, "Формат 2 требует канонические компоненты даты")
            try expect(try Data(contentsOf: invalidPrimary) == missingComponents, "Документ без обязательных компонентов не перезаписан")

            var invalidLegacyTask = legacyTask
            let afterMaximum = CalendarMath().shifting(CalendarMath().supportedDates.upperBound, by: 1, mode: .day)
            invalidLegacyTask["date"] = afterMaximum.timeIntervalSince1970 * 1000
            let invalidLegacyBytes = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "tasks": [invalidLegacyTask], "groups": []])
            try invalidLegacyBytes.write(to: invalidPrimary, options: .atomic)
            let invalidLegacy = CalendarStore(directory: invalidDirectory)
            try expect(invalidLegacy.errorMessage != nil && invalidLegacy.tasks.isEmpty, "Миграция отклоняет старую дату за пределами диапазона")
            try expect(try Data(contentsOf: invalidPrimary) == invalidLegacyBytes, "Некорректный документ первой версии сохранён")
        }

        private func persistenceAndCRUD() throws {
            let directory = try temporaryDirectory("crud")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = CalendarStore(directory: directory)
            try expect(store.errorMessage == nil && store.tasks.isEmpty && store.groups.isEmpty, "Первый запуск с пустым хранилищем")
            let work = try store.saveGroup(name: "  Работа  ", colorHex: "#a1b2c3")
            let home = try store.saveGroup(name: "Дом", colorHex: "DD4400")
            try expect(work.name == "Работа" && work.colorHex == "#A1B2C3", "Нормализация названия и цвета группы")

            let date = CalendarMath().date(day: 15, month: 10, year: 2026)!
            var created: [PlannerTask] = []
            for mode in CalendarMode.allCases {
                let task = try store.saveTask(title: "Дело: \(mode.title)", date: date, groupID: work.id, note: "  Заметка  ")
                created.append(task)
            }
            let ungrouped = try store.saveTask(title: "Без группы", date: date, groupID: nil, note: "")
            try expect(store.tasks(on: date).count == 4, "Создание дел для каждого из трёх видов и без группы")
            try expect(store.groups(on: date).map(\.id) == [work.id], "Одна метка для каждой представленной группы")
            try expect(store.group(id: work.id)?.colorHex == "#A1B2C3", "Метки берут актуальный цвет группы")

            store.toggleTask(created[0])
            try expect(store.tasks(on: date).last?.id == created[0].id, "Завершённые дела после незавершённых")
            store.toggleTask(created[0])
            try expect(store.tasks(on: date).first?.id == created[0].id, "Возврат дела в незавершённые сохраняет порядок")
            store.toggleTask(created[0])
            let tomorrow = CalendarMath().shifting(date, by: 1, mode: .day)
            let edited = try store.saveTask(id: created[0].id, title: "Изменено", date: tomorrow, groupID: home.id, note: "Новая заметка")
            try expect(edited.isCompleted && edited.title == "Изменено" && edited.note == "Новая заметка", "Редактирование сохраняет статус и меняет поля")
            try expect(store.tasks(on: date).count == 3 && store.tasks(on: tomorrow).count == 1, "Изменение даты сразу меняет списки")
            let renamed = try store.saveGroup(id: work.id, name: "Проект", colorHex: "0011FF")
            try expect(renamed.name == "Проект" && store.groups(on: date).first?.colorHex == "#0011FF", "Переименование и цвет группы обновляют метки")

            try rejects("Пустое название дела нельзя сохранить") { try store.saveTask(title: " \n\t ", date: date, groupID: nil, note: "") }
            try rejects("Пустое название группы нельзя сохранить") { try store.saveGroup(name: " \n ", colorHex: "#FFFFFF") }
            try rejects("Некорректный цвет нельзя сохранить") { try store.saveGroup(name: "Ошибка", colorHex: "#GG0033") }
            try rejects("Несуществующую группу нельзя назначить") { try store.saveTask(title: "Ошибка", date: date, groupID: UUID(), note: "") }
            try rejects("Не редактировать несуществующее дело") { try store.saveTask(id: UUID(), title: "Ошибка", date: date, groupID: nil, note: "") }
            let bounds = CalendarMath().supportedDates
            let firstDayTask = try store.saveTask(title: "Начало диапазона", date: bounds.lowerBound, groupID: nil, note: "")
            let lastDayTask = try store.saveTask(title: "Конец диапазона", date: bounds.upperBound.addingTimeInterval(12 * 60 * 60), groupID: nil, note: "")
            try expect(CalendarMath().isSameDay(lastDayTask.date, bounds.upperBound), "Хранилище нормализует время последнего допустимого дня")
            store.deleteTask(firstDayTask)
            store.deleteTask(lastDayTask)
            try rejects("Не сохранять дату до года 1") {
                try store.saveTask(title: "До диапазона", date: CalendarMath().shifting(bounds.lowerBound, by: -1, mode: .day), groupID: nil, note: "")
            }
            try rejects("Не сохранять дату после года 9999") {
                try store.saveTask(title: "После диапазона", date: CalendarMath().shifting(bounds.upperBound, by: 1, mode: .day), groupID: nil, note: "")
            }
            try expect(store.tasks.count == 4 && store.groups.count == 2, "Ошибка валидации не меняет хранилище")

            store.deleteGroup(renamed)
            try expect(store.tasks.count == 4, "Удаление группы сохраняет все дела")
            try expect(store.tasks.filter { $0.groupID == nil }.count == 3, "Дела удалённой группы становятся «Без группы»")
            try expect(store.groups.count == 1 && store.groups(on: date).isEmpty, "Метка удалённой группы исчезает")
            store.deleteTask(ungrouped)
            try expect(store.tasks.count == 3, "Удаление отдельного дела")

            let reopened = CalendarStore(directory: directory)
            try expect(reopened.errorMessage == nil, "Повторное открытие корректного хранилища")
            try expect(reopened.tasks.count == 3 && reopened.groups == [home], "Дела и группы сохранены после перезапуска")
            try expect(reopened.tasks(on: tomorrow).first?.title == "Изменено", "Дата и название сохраняются после перезапуска")
            try expect(reopened.tasks(on: tomorrow).first?.isCompleted == true, "Статус сохраняется после перезапуска")
            try expect(reopened.tasks(on: tomorrow).first?.groupID == home.id, "Группа сохраняется после перезапуска")
            try expect(reopened.tasks(on: date).allSatisfy { $0.groupID == nil }, "Удалённая группа не возвращается после перезапуска")
            try expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("planner.backup.json").path), "Есть резервная копия")
        }

        private func recoveryAndUnknownVersions() throws {
            let directory = try temporaryDirectory("recovery")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = CalendarStore(directory: directory)
            let group = try store.saveGroup(name: "Группа", colorHex: "#FF5500")
            _ = try store.saveTask(title: "Первая версия", date: Date(), groupID: group.id, note: "")
            _ = try store.saveTask(title: "Последняя версия", date: Date(), groupID: nil, note: "")
            let primary = directory.appendingPathComponent("planner.json")
            let corrupt = Data("это не JSON".utf8)
            try corrupt.write(to: primary, options: .atomic)
            let recovered = CalendarStore(directory: directory)
            try expect(recovered.errorMessage != nil, "Восстановление показывает предупреждение")
            try expect(recovered.tasks.count == 1 && recovered.tasks[0].title == "Первая версия", "Загружена предыдущая корректная версия")
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            let preserved = files.first { $0.lastPathComponent.hasPrefix("planner.corrupt-") }
            try expect(preserved != nil, "Повреждённый оригинал сохранён отдельно")
            if let preserved { try expect(try Data(contentsOf: preserved) == corrupt, "Содержимое повреждённого оригинала не изменено") }
            let cleanReopen = CalendarStore(directory: directory)
            try expect(cleanReopen.errorMessage == nil && cleanReopen.tasks.count == 1, "Восстановленный основной файл читается при следующем запуске")

            var invalidDateDocument = try JSONSerialization.jsonObject(with: Data(contentsOf: primary)) as! [String: Any]
            var invalidDateTasks = invalidDateDocument["tasks"] as! [[String: Any]]
            let outsideRange = CalendarMath().shifting(CalendarMath().supportedDates.upperBound, by: 1, mode: .day)
            invalidDateTasks[0]["day"] = ["year": CalendarMath().yearNumber(outsideRange), "month": 1, "day": 1]
            invalidDateDocument["tasks"] = invalidDateTasks
            try JSONSerialization.data(withJSONObject: invalidDateDocument).write(to: primary, options: .atomic)
            let invalidDateRecovery = CalendarStore(directory: directory)
            try expect(invalidDateRecovery.errorMessage != nil, "Дата вне диапазона в файле отклоняется при чтении")
            try expect(invalidDateRecovery.tasks.count == 1 && CalendarMath().isSupported(invalidDateRecovery.tasks[0].date), "При неверной дате восстанавливается корректная резервная копия")

            let future = Data("{\"schemaVersion\":5,\"futureSchema\":true}".utf8)
            try future.write(to: primary, options: .atomic)
            let unsupported = CalendarStore(directory: directory)
            try expect(unsupported.errorMessage?.contains("5") == true, "Будущая версия формата явно обозначена")
            try rejects("Не перезаписывать данные будущей версии") { try unsupported.saveGroup(name: "Новая", colorHex: "FFFFFF") }
            try expect(try Data(contentsOf: primary) == future, "Файл будущей версии сохранён побайтно")

            let brokenDirectory = try temporaryDirectory("broken")
            defer { try? FileManager.default.removeItem(at: brokenDirectory) }
            let brokenPrimary = brokenDirectory.appendingPathComponent("planner.json")
            try corrupt.write(to: brokenPrimary, options: .atomic)
            let broken = CalendarStore(directory: brokenDirectory)
            try expect(broken.errorMessage != nil, "Повреждение без резервной копии не скрыто")
            try rejects("При повреждении нельзя перезаписать пустым документом") { try broken.saveTask(title: "Новое", date: Date(), groupID: nil, note: "") }
            try expect(try Data(contentsOf: brokenPrimary) == corrupt, "Повреждённый файл без резервной копии не изменён")

            let missingDirectory = try temporaryDirectory("missing-primary")
            defer { try? FileManager.default.removeItem(at: missingDirectory) }
            let first = CalendarStore(directory: missingDirectory)
            _ = try first.saveGroup(name: "Первая запись", colorHex: "00FF00")
            try FileManager.default.removeItem(at: missingDirectory.appendingPathComponent("planner.json"))
            let fromBackup = CalendarStore(directory: missingDirectory)
            try expect(fromBackup.groups.count == 1 && fromBackup.errorMessage != nil, "При отсутствии основного файла восстанавливается резервная копия")
        }

        private func failedWriteIsNotPublished() throws {
            let directory = try temporaryDirectory("write-failure")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = CalendarStore(directory: directory)
            _ = try store.saveTask(title: "Сохранено", date: Date(), groupID: nil, note: "")
            let before = store.tasks
            // Replace only the disposable test directory with a regular file to force
            // deterministic failure even when the test runner owns all its files.
            try FileManager.default.removeItem(at: directory)
            try Data("тест".utf8).write(to: directory)
            try rejects("Ошибка записи должна возвращаться форме") { try store.saveTask(title: "Не сохранено", date: Date(), groupID: nil, note: "") }
            try expect(store.tasks == before, "Ошибка записи не публикует несохранённые дела")
            try expect(store.errorMessage != nil, "Ошибка записи явно показана")
            store.toggleTask(before[0])
            try expect(store.tasks == before, "Ошибка записи не публикует несохранённый статус")
            store.deleteTask(before[0])
            try expect(store.tasks == before, "Ошибка записи не удаляет дело из интерфейса")
        }
    }

    @MainActor
    static func main() {
        let suite = Suite()
        do {
            try suite.run()
            print("ПРОЙДЕНО: \(suite.assertions) проверок календарной арифметики, локального хранения, CRUD, восстановления и отказов записи.")
        } catch {
            fputs("ОШИБКА после \(suite.assertions) проверок: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
