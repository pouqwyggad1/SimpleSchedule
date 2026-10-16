import Foundation

/// Exercises reversible navigation and all-date group queries without launching
/// the application or touching its real data, preferences, or login registration.
@main
struct GroupNavigationTests {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @MainActor
    private final class Suite {
        var assertions = 0

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            assertions += 1
            guard condition() else { throw Failure(message: message) }
        }

        func run() throws {
            try reversibleNavigation()
            try virtualGroupNavigation()
            try groupsAcrossDates()
            try ungroupedAcrossDates()
            try deterministicOrdering()
        }

        private func temporaryDirectory() throws -> URL {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("GoldenCalendar-group-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }

        private func reversibleNavigation() throws {
            let math = CalendarMath()
            let groupA = TaskGroup(name: "Первая", colorHex: "#FF0000")
            let groupB = TaskGroup(name: "Вторая", colorHex: "#0000FF")
            let dates = [
                math.date(day: 29, month: 2, year: 2024)!,
                math.date(day: 31, month: 12, year: 2026)!,
                math.date(day: 1, month: 1, year: 2027)!
            ]
            for mode in CalendarMode.allCases {
                for date in dates {
                    var navigation = PlannerNavigation(selectedDate: date, mode: mode)
                    try expect(navigation.selectedGroupID == nil, "Навигация начинается с календаря")
                    navigation.toggleGroup(groupA.id)
                    try expect(navigation.selectedGroupID == groupA.id, "Первое нажатие открывает страницу группы")
                    try expect(navigation.mode == mode && navigation.selectedDate == date, "Открытие группы сохраняет дату и режим \(mode.title)")
                    navigation.toggleGroup(groupA.id)
                    try expect(navigation.selectedGroupID == nil, "Второе нажатие закрывает выбранную группу")
                    try expect(navigation.mode == mode && navigation.selectedDate == date, "Возврат из группы восстанавливает исходный календарь")

                    navigation.toggleGroup(groupA.id)
                    navigation.toggleGroup(groupB.id)
                    try expect(navigation.selectedGroupID == groupB.id, "Другая группа заменяет только выбор группы")
                    try expect(navigation.mode == mode && navigation.selectedDate == date, "Смена группы сохраняет исходную навигацию")
                    navigation.clearGroupIfMissing(in: [groupA, groupB])
                    try expect(navigation.selectedGroupID == groupB.id, "Существующая активная группа сохраняется")
                    navigation.clearGroupIfMissing(in: [groupA])
                    try expect(navigation.selectedGroupID == nil, "Удаление активной группы возвращает календарь")
                    try expect(navigation.mode == mode && navigation.selectedDate == date, "Удаление активной группы сохраняет исходные режим и дату")
                    navigation.clearGroupIfMissing(in: [])
                    try expect(navigation.mode == mode && navigation.selectedDate == date, "Повторная очистка без группы не меняет навигацию")

                    for requestedMode in CalendarMode.allCases {
                        navigation.toggleGroup(groupA.id)
                        navigation.showCalendar(requestedMode)
                        try expect(navigation.selectedGroupID == nil, "Явный выбор календарного режима закрывает страницу группы")
                        try expect(navigation.mode == requestedMode && navigation.selectedDate == date, "Явный выбор режима сохраняет дату")
                    }
                }
            }
            var navigation = PlannerNavigation(selectedDate: dates[0], mode: .week)
            navigation.selectedDate = dates[1]
            navigation.toggleGroup(groupA.id)
            navigation.toggleGroup(groupA.id)
            try expect(navigation.selectedDate == dates[1] && navigation.mode == .week, "После изменения даты группа возвращает к новой выбранной дате")
        }

        private func groupsAcrossDates() throws {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let math = CalendarMath()
            let store = CalendarStore(directory: directory)
            let work = try store.saveGroup(name: "Работа", colorHex: "#33AA55")
            let personal = try store.saveGroup(name: "Личное", colorHex: "#3355AA")
            let oldDate = math.date(day: 29, month: 2, year: 2024)!
            let middleDate = math.date(day: 31, month: 12, year: 2026)!
            let laterDate = math.date(day: 1, month: 1, year: 2027)!
            let oldCompletedDate = math.date(day: 31, month: 12, year: 2025)!
            let later = try store.saveTask(title: "Позднее", date: laterDate, groupID: work.id, note: "")
            let middle = try store.saveTask(title: "На границе года", date: middleDate, groupID: work.id, note: "")
            let old = try store.saveTask(title: "Високосный день", date: oldDate, groupID: work.id, note: "")
            let completed = try store.saveTask(title: "Завершено ранее", date: oldCompletedDate, groupID: work.id, note: "")
            store.toggleTask(completed)
            _ = try store.saveTask(title: "В другой группе", date: oldDate, groupID: personal.id, note: "")
            _ = try store.saveTask(title: "Без группы", date: oldDate, groupID: nil, note: "")
            try expect(store.tasks(in: work.id).map(\.id) == [old.id, middle.id, later.id, completed.id], "Страница группы содержит все даты с выполненными в конце")
            try expect(store.tasks(on: middleDate).map(\.id) == [middle.id], "Общая страница группы не меняет фильтр выбранного дня")
            try expect(store.tasks(in: personal.id).count == 1, "Дела другой группы не попадают в выбранную")
            try expect(store.tasks(in: UUID()).isEmpty, "Несуществующая группа имеет пустую выборку")

            store.toggleTask(old)
            try expect(store.tasks(in: work.id).map(\.id) == [middle.id, later.id, old.id, completed.id], "Выполнение меняет первичный порядок, даты упорядочены внутри каждого статуса")
            store.toggleTask(old)
            try expect(store.tasks(in: work.id).first?.id == old.id, "Возврат в невыполненные возвращает дело на место по дате")
            let earlierDate = math.date(day: 1, month: 1, year: 2023)!
            try store.saveTask(id: later.id, title: later.title, date: earlierDate, groupID: work.id, note: "")
            try expect(store.tasks(in: work.id).first?.id == later.id, "Редактирование даты сразу меняет порядок страницы группы")
            try store.saveTask(id: middle.id, title: middle.title, date: middleDate, groupID: personal.id, note: "")
            try expect(store.tasks(in: work.id).map(\.id) == [later.id, old.id, completed.id], "Смена группы удаляет дело из прежней страницы")
            try expect(store.tasks(in: personal.id).contains { $0.id == middle.id }, "Смена группы добавляет дело в новую страницу")

            var navigation = PlannerNavigation(selectedDate: oldDate, mode: .day)
            navigation.toggleGroup(work.id)
            let total = store.tasks.count
            store.deleteGroup(work)
            navigation.clearGroupIfMissing(in: store.groups)
            try expect(store.tasks.count == total && store.tasks(in: work.id).isEmpty, "Удаление группы сохраняет дела и очищает страницу группы")
            try expect(store.tasks.filter { [later.id, old.id, completed.id].contains($0.id) }.allSatisfy { $0.groupID == nil }, "Дела удалённой группы остаются без группы")
            try expect(navigation.selectedGroupID == nil && navigation.mode == .day && navigation.selectedDate == oldDate, "Удаление выбранной группы возвращает к прежнему дню")
            let reopened = CalendarStore(directory: directory)
            try expect(reopened.tasks.count == total && reopened.tasks(in: work.id).isEmpty, "Удаление группы и дела сохраняются после перезапуска")
            try expect(reopened.tasks(in: personal.id).count == 2, "Выборка существующей группы сохраняется после перезапуска")
        }

        private func virtualGroupNavigation() throws {
            let math = CalendarMath()
            let date = math.date(day: 29, month: 2, year: 2024)!
            let real = TaskGroup(name: "Обычная", colorHex: "#336699")
            let virtual = TaskGroup.ungrouped
            try expect(virtual.id == TaskGroup.ungrouped.id, "Виртуальная группа имеет стабильный идентификатор")
            try expect(virtual.name == "Без группы" && virtual.isUngrouped, "Виртуальная группа распознается без пользовательского названия")
            try expect(virtual.taskGroupID == nil, "Для выборки и создания дела виртуальная группа преобразуется в nil")
            try expect(real.taskGroupID == real.id && !real.isUngrouped, "Обычная группа сохраняет настоящий идентификатор")
            let sameName = TaskGroup(name: "Без группы", colorHex: "#FF0000")
            try expect(!sameName.isUngrouped, "Совпадение названия не превращает пользовательскую группу в виртуальную")

            for mode in CalendarMode.allCases {
                var navigation = PlannerNavigation(selectedDate: date, mode: mode)
                navigation.toggleGroup(virtual.id)
                try expect(navigation.selectedGroupID == virtual.id, "Страница «Без группы» открывается из вида \(mode.title)")
                navigation.clearGroupIfMissing(in: [])
                try expect(navigation.selectedGroupID == virtual.id, "Виртуальная группа доступна при пустом списке пользовательских групп")
                navigation.clearGroupIfMissing(in: [real])
                try expect(navigation.selectedGroupID == virtual.id, "Изменение списка пользовательских групп не закрывает «Без группы»")
                try expect(navigation.selectedDate == date && navigation.mode == mode, "Открытие «Без группы» сохраняет дату и режим")
                navigation.toggleGroup(virtual.id)
                try expect(navigation.selectedGroupID == nil && navigation.mode == mode && navigation.selectedDate == date, "Повторный выбор «Без группы» возвращает прежний календарь")
                navigation.toggleGroup(real.id)
                navigation.toggleGroup(virtual.id)
                try expect(navigation.selectedGroupID == virtual.id, "Переход из обычной группы в «Без группы»")
                navigation.toggleGroup(real.id)
                try expect(navigation.selectedGroupID == real.id, "Переход из «Без группы» в обычную группу")
                navigation.toggleGroup(virtual.id)
                navigation.showCalendar(mode)
                try expect(navigation.selectedGroupID == nil && navigation.mode == mode && navigation.selectedDate == date, "Явный выбор режима закрывает «Без группы» и сохраняет дату")
            }
        }

        private func ungroupedAcrossDates() throws {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = CalendarStore(directory: directory)
            let math = CalendarMath()
            let oldDate = math.date(day: 29, month: 2, year: 2024)!
            let middleDate = math.date(day: 31, month: 12, year: 2026)!
            let laterDate = math.date(day: 1, month: 1, year: 2027)!
            try expect(store.groups.isEmpty && store.group(id: TaskGroup.ungrouped.id) == nil, "Виртуальная группа не сохраняется как пользовательская")
            try expect(store.tasks(in: nil).isEmpty, "Пустая выборка дел без группы доступна без пользовательских групп")
            let later = try store.saveTask(title: "Позднее без группы", date: laterDate, groupID: nil, note: "")
            let old = try store.saveTask(title: "Раннее без группы", date: oldDate, groupID: nil, note: "")
            let completed = try store.saveTask(title: "Завершенное без группы", date: middleDate, groupID: nil, note: "")
            store.toggleTask(completed)
            let work = try store.saveGroup(name: "Работа", colorHex: "#336699")
            let grouped = try store.saveTask(title: "В пользовательской группе", date: oldDate, groupID: work.id, note: "")
            try expect(store.tasks(in: nil).map(\.id) == [old.id, later.id, completed.id], "«Без группы» показывает все даты с выполненными в конце")
            try expect(store.tasks(in: nil).allSatisfy { $0.groupID == nil }, "Обычные группы исключены из виртуальной страницы")
            try expect(store.tasks(on: middleDate).map(\.id) == [completed.id], "Страница без группы не меняет выборку календарного дня")
            store.toggleTask(old)
            try expect(store.tasks(in: nil).map(\.id) == [later.id, old.id, completed.id], "Выполнение дела без группы меняет порядок по статусу")
            store.toggleTask(old)
            try store.saveTask(id: later.id, title: later.title, date: laterDate, groupID: work.id, note: "")
            try expect(store.tasks(in: nil).map(\.id) == [old.id, completed.id], "Назначение группы убирает дело со страницы «Без группы»")
            try store.saveTask(id: grouped.id, title: grouped.title, date: grouped.date, groupID: nil, note: "")
            try expect(store.tasks(in: nil).contains { $0.id == grouped.id }, "Снятие группы немедленно добавляет дело на виртуальную страницу")

            var navigation = PlannerNavigation(selectedDate: middleDate, mode: .week)
            navigation.toggleGroup(TaskGroup.ungrouped.id)
            store.deleteGroup(work)
            navigation.clearGroupIfMissing(in: store.groups)
            try expect(navigation.selectedGroupID == TaskGroup.ungrouped.id, "Удаление последней обычной группы не закрывает «Без группы»")
            try expect(store.tasks(in: nil).count == 4 && store.tasks.count == 4, "Все дела удаленной группы добавляются к делам без группы без потерь")
            try expect(store.groups.isEmpty, "Виртуальная группа не появляется в управлении группами")
            try expect(store.tasks.allSatisfy { $0.groupID == nil }, "Виртуальный UUID не записывается в дела")
            let reopened = CalendarStore(directory: directory)
            try expect(reopened.groups.isEmpty && reopened.tasks(in: nil).count == 4, "Дела без группы сохраняются после повторного открытия хранилища")
            try expect(reopened.tasks(in: nil).last?.id == completed.id, "Порядок выполненных без группы сохраняется после повторного открытия")
        }

        private func deterministicOrdering() throws {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let math = CalendarMath()
            let day = math.date(day: 1, month: 1, year: 2026)!
            let nextDay = math.shifting(day, by: 1, mode: .day)
            let group = TaskGroup(name: "Порядок", colorHex: "#112233")
            let identifiers = (1...5).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))! }
            let tiedFirst = PlannerTask(id: identifiers[0], title: "Первый при равенстве", date: day, groupID: group.id, createdAt: Date(timeIntervalSince1970: 100))
            let tiedSecond = PlannerTask(id: identifiers[1], title: "Второй при равенстве", date: day, groupID: group.id, createdAt: Date(timeIntervalSince1970: 100))
            let earlierCreated = PlannerTask(id: identifiers[2], title: "Раньше создано", date: day, groupID: group.id, createdAt: Date(timeIntervalSince1970: 50))
            let completed = PlannerTask(id: identifiers[3], title: "Выполнено", date: day, groupID: group.id, isCompleted: true, createdAt: Date(timeIntervalSince1970: 10))
            let laterDay = PlannerTask(id: identifiers[4], title: "Следующий день", date: nextDay, groupID: group.id, createdAt: Date(timeIntervalSince1970: 0))
            struct Fixture: Encodable { let schemaVersion: Int; let tasks: [PlannerTask]; let groups: [TaskGroup] }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let fixture = Fixture(schemaVersion: 2, tasks: [tiedSecond, laterDay, completed, tiedFirst, earlierCreated], groups: [group])
            try encoder.encode(fixture).write(to: directory.appendingPathComponent("planner.json"), options: .atomic)
            let store = CalendarStore(directory: directory)
            try expect(store.errorMessage == nil, "Корректная тестовая база открывается")
            let expectedGroupOrder = [identifiers[2], identifiers[0], identifiers[1], identifiers[4], identifiers[3]]
            try expect(store.tasks(in: group.id).map(\.id) == expectedGroupOrder, "Порядок группы: статус, дата, создание, идентификатор")
            try expect(store.tasks(on: day).map(\.id) == [identifiers[2], identifiers[0], identifiers[1], identifiers[3]], "Порядок дел одного дня остаётся прежним")
            try store.saveGroup(id: group.id, name: "Переименовано", colorHex: "#AA5500")
            let reopened = CalendarStore(directory: directory)
            try expect(reopened.tasks(in: group.id).map(\.id) == expectedGroupOrder, "Равные даты и времена дают стабильный порядок после записи и перезапуска")
        }
    }

    @MainActor
    static func main() {
        let suite = Suite()
        do {
            try suite.run()
            print("GroupNavigationTests: \(suite.assertions) проверок навигации и дел группы пройдено.")
        } catch {
            fputs("ОШИБКА GroupNavigationTests после \(suite.assertions) проверок: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
