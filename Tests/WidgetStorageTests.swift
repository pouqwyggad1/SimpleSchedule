import Foundation

/// Uses only disposable test directories and this test executable's child processes.
/// Never resolves a real App Group, starts the app, or registers a login item.
@main
struct WidgetStorageTests {
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
            do { try body() } catch { return }
            throw Failure(message: message)
        }

        func directory(_ label: String) throws -> URL {
            let value = FileManager.default.temporaryDirectory.appendingPathComponent("Planner-widget-\(label)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
            return value
        }

        func run() throws {
            try twoLiveStores()
            try migrationAndRecovery()
            try migrationJournal()
            try widgetState()
            try resolverWithoutGroup()
            try simultaneousProcesses()
        }

        private func twoLiveStores() throws {
            let folder = try directory("live")
            defer { try? FileManager.default.removeItem(at: folder) }
            let shared = SharedPlannerStorage(directory: folder, isShared: true)
            let app = CalendarStore(storage: shared)
            let widget = CalendarStore(storage: shared)
            var commits = 0
            app.onCommit = { commits += 1 }
            let group = try app.saveGroup(name: "Общая", colorHex: "#2244AA")
            let first = try widget.saveTask(title: "Из виджета", date: Date(), groupID: group.id, note: "")
            try expect(widget.groups.contains { $0.id == group.id }, "Устаревший процесс перечитывает новые группы до сохранения дела")
            let second = try app.saveTask(title: "Из приложения", date: Date(), groupID: group.id, note: "Прежняя заметка")
            try expect(app.tasks.count == 2, "Запись приложения сохраняет дело другого процесса")
            try widget.setTaskCompleted(id: second.id, isCompleted: true)
            let changed = try app.saveTask(id: second.id, title: "Изменено приложением", date: second.date, groupID: group.id, note: "Новая заметка")
            try expect(changed.isCompleted, "Позднее редактирование приложения сохраняет выполнение из виджета")
            widget.reloadFromDisk()
            try expect(widget.tasks.first { $0.id == second.id }?.note == "Новая заметка", "reload получает свежую заметку другого процесса")
            try expect(widget.tasks.first { $0.id == second.id }?.isCompleted == true, "reload получает свежее выполнение")

            let before = try Data(contentsOf: shared.dataURL)
            let beforeBackup = try Data(contentsOf: shared.backupURL)
            let beforeCommits = commits
            try app.setTaskCompleted(id: second.id, isCompleted: true)
            try app.setTaskCompleted(id: second.id, isCompleted: true)
            try expect(try Data(contentsOf: shared.dataURL) == before, "Повторный intent не переписывает основной файл")
            try expect(try Data(contentsOf: shared.backupURL) == beforeBackup, "Повторный intent не вытесняет резервную копию")
            try expect(commits == beforeCommits, "Повторный intent не публикует ложное изменение")
            try app.setTaskCompleted(id: second.id, isCompleted: false)
            try expect(commits == beforeCommits + 1, "Фактическое изменение вызывает onCommit ровно один раз")
            let later = try widget.saveTask(title: "Создано позднее", date: Date(), groupID: group.id, note: "")
            app.deleteGroup(group)
            try expect(app.tasks.count == 3 && app.tasks.allSatisfy { $0.groupID == nil }, "Удаление группы учитывает новые дела другого процесса")
            try rejects("Нельзя вернуть удалённую группу из устаревшей формы") {
                try widget.saveTask(id: later.id, title: later.title, date: later.date, groupID: group.id, note: "")
            }
            try expect(widget.groups.isEmpty && widget.tasks.allSatisfy { $0.groupID == nil }, "Неудачная устаревшая форма получает актуальную базу")
            app.deleteTask(first)
            try rejects("Intent удалённого дела не воскрешает его") { try widget.setTaskCompleted(id: first.id, isCompleted: true) }
            app.reloadFromDisk()
            try expect(app.tasks.count == 2 && !app.tasks.contains { $0.id == first.id }, "Удалённое дело остаётся удалённым")
            try expect(app.isAvailable && widget.isAvailable, "Ошибка логики не делает исправную базу недоступной")
        }

        private func migrationAndRecovery() throws {
            let legacy = try directory("legacy")
            let sharedFolder = try directory("shared")
            defer {
                try? FileManager.default.removeItem(at: legacy)
                try? FileManager.default.removeItem(at: sharedFolder)
            }
            let source = CalendarStore(directory: legacy)
            let group = try source.saveGroup(name: "Из прежней версии", colorHex: "#11AA33")
            _ = try source.saveTask(title: "Сохранено ранее", date: Date(), groupID: group.id, note: "")
            _ = try source.saveTask(title: "Последняя версия", date: Date(), groupID: nil, note: "")
            let original = try Data(contentsOf: legacy.appendingPathComponent("planner.json"))
            let originalBackup = try Data(contentsOf: legacy.appendingPathComponent("planner.backup.json"))
            let appStorage = SharedPlannerStorage(directory: sharedFolder, legacyDirectory: legacy, isShared: true)
            let app = CalendarStore(storage: appStorage)
            try expect(app.isAvailable && app.tasks.count == 2, "Приложение переносит свою базу в общий контейнер")
            try expect(try Data(contentsOf: appStorage.dataURL) == original, "Перенос сохраняет основной файл побайтно")
            try expect(try Data(contentsOf: appStorage.backupURL) == originalBackup, "Перенос сохраняет резервную копию побайтно")
            try expect(try Data(contentsOf: legacy.appendingPathComponent("planner.json")) == original, "Прежний основной файл не удалён и не изменён")
            try expect(try Data(contentsOf: legacy.appendingPathComponent("planner.backup.json")) == originalBackup, "Прежняя резервная копия не изменена")
            _ = try app.saveTask(title: "Только в общем контейнере", date: Date(), groupID: nil, note: "")
            let reopened = CalendarStore(storage: appStorage)
            try expect(reopened.tasks.count == 3, "Повторный запуск не заменяет общие изменения старым оригиналом")
            let widget = CalendarStore(storage: SharedPlannerStorage(directory: sharedFolder, isShared: true))
            try expect(widget.tasks.count == 3 && widget.isAvailable, "Виджет читает именно общую базу")

            let broken = Data("повреждённый общий файл".utf8)
            try appStorage.withExclusiveAccess { try broken.write(to: appStorage.dataURL, options: .atomic) }
            app.reloadFromDisk()
            try expect(app.isAvailable && app.errorMessage != nil && app.tasks.count == 2, "Общая база восстанавливается из предыдущей копии с предупреждением")
            let preserved = try FileManager.default.contentsOfDirectory(at: sharedFolder, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("planner.corrupt-") }
            try expect(preserved.count == 1, "Повреждённый общий оригинал сохранён отдельно")

            let noBackup = try directory("broken-without-backup")
            defer { try? FileManager.default.removeItem(at: noBackup) }
            let corruptURL = noBackup.appendingPathComponent("planner.json")
            try broken.write(to: corruptURL, options: .atomic)
            let unavailable = CalendarStore(storage: SharedPlannerStorage(directory: noBackup, isShared: true))
            try expect(!unavailable.isAvailable && unavailable.errorMessage != nil, "Повреждение без копии обозначается как недоступная база, не пустая исправная")
            try rejects("Intent не перезаписывает повреждённую базу") { try unavailable.setTaskCompleted(id: UUID(), isCompleted: true) }
            try expect(try Data(contentsOf: corruptURL) == broken, "Повреждённая база не заменена пустым документом")
        }

        private func migrationJournal() throws {
            let legacy = try directory("journal-source")
            let folder = try directory("journal-destination")
            defer {
                try? FileManager.default.removeItem(at: legacy)
                try? FileManager.default.removeItem(at: folder)
            }
            let source = CalendarStore(directory: legacy)
            _ = try source.saveTask(title: "Прерванный перенос", date: Date(), groupID: nil, note: "")
            let primary = try Data(contentsOf: legacy.appendingPathComponent("planner.json"))
            let backup = try Data(contentsOf: legacy.appendingPathComponent("planner.backup.json"))
            let journal = try JSONSerialization.data(withJSONObject: ["primary": primary.base64EncodedString(), "backup": backup.base64EncodedString()])
            let pending = folder.appendingPathComponent("private-migration-pending-v1.json")
            try journal.write(to: pending, options: .atomic)
            let widgetStorage = SharedPlannerStorage(directory: folder, isShared: true)
            let waiting = CalendarStore(storage: widgetStorage)
            try expect(!waiting.isAvailable && waiting.tasks.isEmpty, "Виджет не подменяет незавершённый перенос пустой базой")
            try expect(!FileManager.default.fileExists(atPath: widgetStorage.dataURL.path), "Виджет не выполняет перенос вместо приложения")
            let appStorage = SharedPlannerStorage(directory: folder, legacyDirectory: legacy, isShared: true)
            let resumed = CalendarStore(storage: appStorage)
            try expect(resumed.isAvailable && resumed.tasks.count == 1, "Приложение завершает перенос из журнала")
            try expect(!FileManager.default.fileExists(atPath: pending.path), "Журнал убирается после завершения переноса")
            waiting.reloadFromDisk()
            try expect(waiting.isAvailable && waiting.tasks.count == 1, "Виджет получает базу после завершения переноса")

            try Data("оставшийся журнал после завершения".utf8).write(to: pending, options: .atomic)
            let afterMarker = CalendarStore(storage: widgetStorage)
            try expect(afterMarker.isAvailable && afterMarker.tasks.count == 1, "Завершённый маркер устраняет окно сбоя перед удалением журнала")
            _ = CalendarStore(storage: appStorage)
            try expect(!FileManager.default.fileExists(atPath: pending.path), "Приложение убирает оставшийся журнал при следующем чтении")
            try expect(try Data(contentsOf: legacy.appendingPathComponent("planner.json")) == primary, "Возобновление переноса не трогает исходную базу")
        }

        private func widgetState() throws {
            let folder = try directory("state")
            defer { try? FileManager.default.removeItem(at: folder) }
            let first = SharedPlannerStorage(directory: folder, isShared: true)
            let second = SharedPlannerStorage(directory: folder, isShared: true)
            var state = try first.readWidgetState()
            try expect(state.selectedDay == nil && state.intentError == nil, "Новое состояние автоматически следует сегодняшнему дню")
            let zone = TimeZone(identifier: "Asia/Irkutsk")!
            let math = CalendarMath(timeZone: zone)
            for (year, month, day) in [(2028, 2, 28), (2028, 2, 29), (2028, 3, 1), (2026, 12, 31), (2027, 1, 1)] {
                let now = math.date(day: day, month: month, year: year)!
                try expect(state.effectiveDay(now: now, timeZone: zone) == CivilDay(year: year, month: month, day: day), "Автодата учитывает високосный день и границу года")
            }
            let chosen = CivilDay(year: 2028, month: 2, day: 29)
            try first.updateWidgetState { $0.selectedDay = chosen }
            try second.updateWidgetState { $0.intentError = "Тестовая ошибка intent" }
            state = try first.readWidgetState()
            try expect(state.selectedDay == chosen && state.intentError == "Тестовая ошибка intent", "Две живые стороны обновляют разные поля без потери изменений")
            try expect(state.effectiveDay(now: Date(), timeZone: zone) == chosen, "Выбранная дата не перескакивает на сегодня")
            try first.updateWidgetState { $0.selectedDay = nil }
            try expect(try second.readWidgetState().intentError == "Тестовая ошибка intent", "Смена даты не теряет ошибку другого процесса")
            try second.updateWidgetState { $0.intentError = nil }
            try expect(try first.readWidgetState() == WidgetSharedState(), "Можно вернуться к сегодняшнему дню и очистить ошибку")
            try rejects("Состояние не принимает несуществующую дату") { try first.updateWidgetState { $0.selectedDay = CivilDay(year: 2027, month: 2, day: 29) } }
            try expect(try second.readWidgetState().selectedDay == nil, "Неверная дата не опубликована")
            let corrupt = Data("не JSON состояния".utf8)
            let stateURL = folder.appendingPathComponent("widget-state.json")
            try corrupt.write(to: stateURL, options: .atomic)
            try rejects("Повреждение состояния не скрывается пустым состоянием") { _ = try first.readWidgetState() }
            try rejects("Обновление не затирает повреждённое состояние") { try first.updateWidgetState { $0.intentError = nil } }
            try expect(try Data(contentsOf: stateURL) == corrupt, "Повреждённый файл состояния сохранён")
        }

        private func resolverWithoutGroup() throws {
            let folder = try directory("fixture.bundle")
            defer { try? FileManager.default.removeItem(at: folder) }
            let contents = folder.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": "ru.local.storage-test.\(UUID().uuidString)", "CFBundlePackageType": "BNDL", "PlannerAppGroupIdentifier": "", "PlannerStorageRole": "widget"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
            guard let bundle = Bundle(path: folder.path) else { throw Failure(message: "Не удалось создать тестовый Bundle") }
            try expect(PlannerStorageRole.current(in: bundle) == .widget, "Роль виджета читается из собственного Info.plist")
            try rejects("Widget без App Group не получает приватный fallback") { _ = try SharedPlannerStorage.resolve(for: .widget, bundle: bundle) }
            let app = try SharedPlannerStorage.resolve(for: .application, bundle: bundle)
            try expect(!app.isShared, "CLI приложение без App Group сохраняет прежний приватный путь")
            try expect(!FileManager.default.fileExists(atPath: app.dataURL.path), "Проверка resolver не создаёт базу в пользовательском контейнере")
        }

        private func simultaneousProcesses() throws {
            let folder = try directory("processes")
            defer { try? FileManager.default.removeItem(at: folder) }
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            let processes = ["первый", "второй"].map { prefix in
                let process = Process()
                process.executableURL = executable
                process.arguments = ["--writer", folder.path, prefix, "24"]
                return process
            }
            for process in processes { try process.run() }
            for process in processes { process.waitUntilExit() }
            try expect(processes.allSatisfy { $0.terminationStatus == 0 }, "Два независимых процесса завершили запись")
            let store = CalendarStore(storage: SharedPlannerStorage(directory: folder, isShared: true))
            try expect(store.isAvailable && store.tasks.count == 48, "Межпроцессная блокировка сохраняет все конкурентные записи")
            try expect(Set(store.tasks.map(\.title)).count == 48, "Конкурентные записи не дублируют и не теряют дела")
            try expect(store.tasks.filter { $0.title.hasPrefix("первый") }.count == 24 && store.tasks.filter { $0.title.hasPrefix("второй") }.count == 24, "Сохранены все изменения каждой стороны")
        }
    }

    @MainActor
    static func main() {
        do {
            if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--writer" {
                let storage = SharedPlannerStorage(directory: URL(fileURLWithPath: CommandLine.arguments[2]), isShared: true)
                let store = CalendarStore(storage: storage)
                for index in 0..<(Int(CommandLine.arguments[4]) ?? 0) {
                    _ = try store.saveTask(title: "\(CommandLine.arguments[3])-\(index)", date: Date(), groupID: nil, note: "")
                }
                return
            }
            let suite = Suite()
            try suite.run()
            print("WidgetStorageTests: \(suite.assertions) проверок общего хранилища, миграции, intent и межпроцессной записи пройдено.")
        } catch {
            fputs("ОШИБКА WidgetStorageTests: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
