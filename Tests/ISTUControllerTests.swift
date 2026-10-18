import Foundation

private final class ControllerMemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }; return values[key]
    }
    override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    override func integer(forKey key: String) -> Int { (object(forKey: key) as? NSNumber)?.intValue ?? 0 }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func set(_ value: Any?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }; values[key] = value
    }
}

@main
struct ISTUControllerTests {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @MainActor private final class SuspendedFetch {
        var pending: CheckedContinuation<Data, any Error>?
        var paths: [String] = []
        func fetch(_ path: String) async throws -> Data {
            paths.append(path)
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        func complete(_ data: Data) {
            let continuation = pending; pending = nil; continuation?.resume(returning: data)
        }
    }

    @MainActor private final class Suite {
        var count = 0
        let math = CalendarMath()
        let groupID = "478240"

        func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            count += 1
            guard try condition() else { throw Failure(message: message) }
        }
        func folder() throws -> URL {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Calendar-ControllerTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
        func fixture(_ name: String) throws -> Data {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            return try Data(contentsOf: root.appendingPathComponent("Fixtures/ISTU/\(name)"))
        }
        func settings() throws -> ScheduleImportSettings {
            let settings = ScheduleImportSettings(defaults: ControllerMemoryDefaults())
            settings.cacheInstitutes(try ISTUParser.institutes(html: fixture("institutes.html")))
            settings.cacheGroups(try ISTUParser.groups(html: fixture("groups-683.html")), instituteID: "683")
            settings.instituteID = "683"; settings.groupID = groupID
            return settings
        }
        func path(_ monday: Date) -> String {
            let day = CivilDay(date: monday)
            return String(format: "/raspisanie/grup/%@/%02d.%02d.%04d/", groupID, day.day, day.month, day.year)
        }

        /// Reuse the captured site's actual DOM/cards, moving only dates to
        /// exercise controller routing. The rendered active branch is retained;
        /// the site's descriptive parity label is not its visibility authority.
        func projectedWeek(_ monday: Date) throws -> Data {
            var text = String(decoding: try fixture("group-478240-2026-10-12.html"), as: UTF8.self)
            let anchor = math.date(day: 12, month: 10, year: 2026)!
            func stamp(_ date: Date) -> String {
                let day = CivilDay(date: date)
                return String(format: "%02d.%02d.%04d", day.day, day.month, day.year)
            }
            for offset in 0..<7 {
                text = text.replacingOccurrences(of: stamp(math.shifting(anchor, by: offset, mode: .day)), with: "__TEST_DAY_\(offset)__")
            }
            for offset in 0..<7 {
                text = text.replacingOccurrences(of: "__TEST_DAY_\(offset)__", with: stamp(math.shifting(monday, by: offset, mode: .day)))
            }
            return Data(text.utf8)
        }

        /// A small complete dated week with subgroup metadata in both visible and
        /// greyed-out alternatives. Its group numbers come only from this HTML.
        func subgroupWeek(_ monday: Date, inactiveSubgroup: String, includedDayOffsets: [Int] = Array(0..<7)) -> Data {
            func stamp(_ date: Date) -> String {
                let day = CivilDay(date: date)
                return String(format: "%02d.%02d.%04d", day.day, day.month, day.year)
            }
            func card(_ id: String, _ subject: String, subgroup: String? = nil) -> String {
                """
                <div class="schcls-item schcls-card" id="\(id)">
                <div class="schcls-item-name">\(subject)</div><div class="schcls-item-distype">практика</div>
                <div class="schcls-item-group"><a href="/raspisanie/grup/\(groupID)/">ТЕСТ-1</a>\(subgroup.map { " подгруппа \($0)" } ?? "")</div>
                </div>
                """
            }
            let cards = """
            <div class="sch-list-item" data-params="{'time':'8:15'}"><div class="sch-list-item-classes">
            <div class="sch-list-item-week week-all">\(card("common", "Общая"))</div>
            <div class="sch-list-item-week week-even">\(card("one", "Только первая", subgroup: "1"))\(card("two", "Только вторая", subgroup: "2"))</div>
            <div class="sch-list-item-week week-odd">\(card("inactive", "Неактивная неделя", subgroup: inactiveSubgroup))</div>
            </div></div>
            """
            let days = includedDayOffsets.map { offset in
                let date = stamp(math.shifting(monday, by: offset, mode: .day))
                return "<div class=\"sch-list-day\" data-params=\"{'date':'\(date)'}\"><h2 class=\"sch-list-day-header\" id=\"date-\(date)\">День</h2>\(offset == 0 ? cards : "")</div>"
            }.joined()
            return Data("""
            <html><body><h1>Группа ТЕСТ-1</h1>
            <div class="info-block-item"><div class="info-block-item-label">Начало действия:</div><div class="info-block-item-value">\(stamp(monday))</div></div>
            <div class="info-block-item"><div class="info-block-item-label">Окончание действия:</div><div class="info-block-item-value">\(stamp(math.shifting(monday, by: 6, mode: .day)))</div></div>
            <div class="sch-list-week sch-list-week-even">\(days)</div></body></html>
            """.utf8)
        }

        func run() async throws {
            try await explicitRequestsOnly()
            try await reconcileLegacySubgroupPreference()
            try await subgroupDiscoveryAndSwitching()
            try await dateAndMonthRequests()
            try await partialWeekPreservesUnknownDays()
            try await partialMonthPublishesValidWeeks()
            try await unpublishedPeriodDoesNotChangeData()
            try await unpublishedWeeksAfterValidPrefix()
            try await unpublishedDoesNotHideRealErrors()
            try await failureDoesNotCommit()
            try await cancellationAndSettingsChange()
            try await cancellationAfterBufferedWeek()
            try durationRollbackAndFilter()
        }

        private func explicitRequestsOnly() async throws {
            let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
            let store = CalendarStore(directory: directory)
            let defaults = ControllerMemoryDefaults()
            let settings = ScheduleImportSettings(defaults: defaults)
            var requests: [String] = []
            let controller = ISTUImportController(settings: settings) { path in
                requests.append(path)
                return try self.fixture(path == "/raspisanie" ? "institutes.html" : "groups-683.html")
            }
            controller.attach(store: store)
            _ = controller.institutes; _ = controller.groups; _ = controller.availableSubgroups
            _ = ScheduleImportSettings(defaults: defaults)
            try expect(requests.isEmpty, "Инициализация, attach и чтение настроек не запускают загрузку")
            await controller.loadInstitutes()
            try expect(requests == ["/raspisanie"] && controller.institutes.count == 12, "Явная загрузка институтов делает один запрос")
            await controller.selectInstitute("683")
            try expect(requests == ["/raspisanie", "/raspisanie/podrazdelenie/683"], "Группы запрашиваются только после явного выбора института")
            try expect(controller.groups.contains { $0.id == groupID }, "После загрузки доступна реальная группа из сохраненного fixture")
            controller.selectGroup(groupID)
            settings.subgroup = " 1 "; settings.durationMinutes = 95
            _ = controller.groups; _ = controller.institutes
            try expect(requests.count == 2, "Выбор группы, подгруппы, длительности и чтение кэша не обращаются к сети")
            let reloaded = ScheduleImportSettings(defaults: defaults)
            try expect(reloaded.groupID == groupID && reloaded.subgroup == "1" && reloaded.durationMinutes == 95, "Выбор и длительность сохраняются через in-memory preferences")
            try expect(reloaded.cachedInstitutes.count == 12 && reloaded.cachedGroups["683"]?.count == 39, "Русские списки институтов и групп сохраняются для офлайн-чтения")
            await controller.selectInstitute(nil)
            try expect(requests.count == 2 && settings.groupID == nil, "Снятие института не загружает страницу и снимает группу")
        }

        private func dateAndMonthRequests() async throws {
            for mode in [CalendarMode.day, .week] {
                let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
                let store = CalendarStore(directory: directory)
                let settings = try settings()
                let selected = math.date(day: 15, month: 10, year: 2026)!
                let monday = math.weekDays(containing: selected).first!
                var requests: [String] = []
                let controller = ISTUImportController(settings: settings) { path in requests.append(path); return try self.projectedWeek(monday) }
                controller.attach(store: store)
                await controller.refresh(date: selected, mode: mode)
                try expect(requests == [path(monday)], "Вид \(mode.title) делает один датированный запрос своей недели")
                try expect(controller.errorMessage == nil && !store.lessons.isEmpty && settings.lastRefresh != nil, "Одна неделя сохраняется после полного успешного ответа")
            }
            for (year, month, weekCount) in [(2021, 2, 4), (2026, 10, 5), (2021, 5, 6)] {
                let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
                let store = CalendarStore(directory: directory)
                let settings = try settings()
                let selected = math.date(day: 15, month: month, year: year)!
                let days = math.monthDays(containing: selected)
                let mondays = days.enumerated().filter { $0.offset % 7 == 0 }.map(\.element)
                let responses = try Dictionary(uniqueKeysWithValues: mondays.map { (path($0), try projectedWeek($0)) })
                var requests: [String] = []
                let controller = ISTUImportController(settings: settings) { path in
                    requests.append(path)
                    guard let response = responses[path] else { throw Failure(message: "Непредусмотренный путь \(path)") }
                    return response
                }
                controller.attach(store: store)
                await controller.refresh(date: selected, mode: .month)
                try expect(requests == mondays.map(path) && requests.count == weekCount, "Месяц \(month).\(year) запрашивает каждую из \(weekCount) недель ровно один раз")
                try expect(Set(requests).count == requests.count && controller.errorMessage == nil, "Месячный импорт не дублирует недельные запросы")
                try expect(settings.lastRefresh != nil && !store.lessons.isEmpty, "Месячный импорт сохраняется только после всех ответов")
            }
        }

        private func reconcileLegacySubgroupPreference() async throws {
            let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
            let store = CalendarStore(directory: directory)
            let settings = try settings()
            settings.cacheSubgroups(["1", "2"], groupID: groupID)
            settings.subgroup = "-6"
            let monday = math.date(day: 12, month: 10, year: 2026)!
            let day = CivilDay(date: monday)
            let rows: [ISTUParsedLesson] = [("common", nil), ("one", "1"), ("two", "2")].map { id, subgroup in
                ISTUParsedLesson(sourceID: id, day: day, startMinute: 600, subject: id, kind: "Лекция", teacher: "", subgroup: subgroup, room: "")
            }
            _ = try store.importISTUSchedule(ISTUSchedulePage(lessons: rows, coveredDays: [day], groupName: nil), groupID: groupID, durationMinutes: 90)
            let before = store.lessons
            let bytes = try Data(contentsOf: directory.appendingPathComponent("planner.json"))
            var requests: [String] = []
            var commits = 0
            store.onCommit = { commits += 1 }
            let controller = ISTUImportController(settings: settings) { path in
                requests.append(path)
                throw Failure(message: "Сеть запрещена при согласовании настройки")
            }
            controller.attach(store: store)
            try expect(controller.availableSubgroups == ["1", "2"] && settings.subgroup == nil, "Старое пользовательское значение -6 сбрасывается, когда сайт уже подтвердил только подгруппы 1 и 2")
            try expect(store.lessons(on: monday).count == 3 && store.lessons == before, "После сброса недействительной подгруппы видны общие пары и обе подгруппы, данные сохраняются")
            try expect(requests.isEmpty && commits == 0 && (try Data(contentsOf: directory.appendingPathComponent("planner.json"))) == bytes, "Согласование старой настройки не вызывает сеть и не записывает базу")
            settings.subgroup = "1"
            controller.attach(store: store)
            try expect(settings.subgroup == "1" && Set(store.lessons(on: monday).map(\.subject)) == ["common", "one"], "Подтвержденная сайтом подгруппа 1 сохраняется при повторном подключении хранилища")
            try expect(requests.isEmpty && commits == 0, "Действительный выбор тоже согласуется без сети и записи данных")

            let freshDirectory = try folder(); defer { try? FileManager.default.removeItem(at: freshDirectory) }
            let freshStore = CalendarStore(directory: freshDirectory)
            let freshSettings = try self.settings()
            freshSettings.subgroup = "-6"
            var freshRequests: [String] = []
            let freshController = ISTUImportController(settings: freshSettings) { path in
                freshRequests.append(path)
                return self.subgroupWeek(monday, inactiveSubgroup: "7")
            }
            freshController.attach(store: freshStore)
            try expect(freshSettings.subgroup == "-6" && freshController.availableSubgroups.isEmpty && freshRequests.isEmpty, "До получения номеров сайта неизвестное сохраненное значение не сбрасывается предположением")
            await freshController.refresh(date: monday, mode: .week)
            try expect(freshController.errorMessage == nil && freshSettings.subgroup == nil && freshController.availableSubgroups == ["1", "2", "7"], "После первого явного обновления новые метаданные заменяют недействительное сохраненное значение выбором всех подгрупп")
            try expect(freshRequests == [path(monday)] && freshStore.lessons(on: monday).count == 3, "Исправление настройки не делает дополнительного запроса и показывает весь сохраненный импорт")
        }

        private func subgroupDiscoveryAndSwitching() async throws {
            let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
            let store = CalendarStore(directory: directory)
            let defaults = ControllerMemoryDefaults()
            let settings = ScheduleImportSettings(defaults: defaults)
            let otherGroup = "478241"
            settings.cacheInstitutes([ISTUOption(id: "683", name: "Тестовый институт")])
            settings.cacheGroups([ISTUOption(id: groupID, name: "ТЕСТ-1"), ISTUOption(id: otherGroup, name: "ТЕСТ-2")], instituteID: "683")
            settings.instituteID = "683"; settings.groupID = groupID; settings.subgroup = "1"
            let monday = math.date(day: 12, month: 10, year: 2026)!
            let nextMonday = math.shifting(monday, by: 1, mode: .week)
            var requests: [String] = []
            let responses = [path(monday): subgroupWeek(monday, inactiveSubgroup: "7"), path(nextMonday): subgroupWeek(nextMonday, inactiveSubgroup: "12")]
            let controller = ISTUImportController(settings: settings) { path in
                requests.append(path)
                guard let data = responses[path] else { throw Failure(message: "Непредусмотренный путь \(path)") }
                return data
            }
            controller.attach(store: store)
            try expect(controller.availableSubgroups.isEmpty && requests.isEmpty, "До первого явного импорта нет выдуманных номеров подгрупп и запросов")
            await controller.refresh(date: monday, mode: .week)
            try expect(controller.errorMessage == nil && requests == [path(monday)], "Одна неделя с подгруппами импортируется одним явным запросом")
            try expect(controller.availableSubgroups == ["1", "2", "7"], "Номера берутся из всех альтернатив сайта, включая неактивную подгруппу 7")
            try expect(store.lessons.count == 3 && Set(store.lessons.compactMap(\.subgroup)) == ["1", "2"], "При выбранной подгруппе 1 импортируются также активные пары подгруппы 2, а неактивная ветка недели не импортируется")
            try expect(Set(store.lessons(on: monday).map(\.subject)) == ["Общая", "Только первая"], "Первая подгруппа сразу показывает общие и свои занятия")
            let imported = store.lessons
            let bytes = try Data(contentsOf: directory.appendingPathComponent("planner.json"))
            settings.subgroup = "2"
            try expect(Set(store.lessons(on: monday).map(\.subject)) == ["Общая", "Только вторая"], "Выбор подгруппы 2 сразу переключает локальное расписание")
            settings.subgroup = "1"
            try expect(Set(store.lessons(on: monday).map(\.subject)) == ["Общая", "Только первая"], "Обратный выбор первой подгруппы не требует импорта")
            settings.subgroup = "7"
            try expect(store.lessons(on: monday).map(\.subject) == ["Общая"], "Неактивная для недели подгруппа видит только общие пары")
            try expect(requests.count == 1 && store.lessons == imported, "Смена подгрупп не делает сетевых запросов и не удаляет скрытые данные")
            try expect(try Data(contentsOf: directory.appendingPathComponent("planner.json")) == bytes, "Фильтр подгруппы не переписывает локальную базу")
            await controller.refresh(date: nextMonday, mode: .week)
            try expect(controller.errorMessage == nil && requests.count == 2 && controller.availableSubgroups == ["1", "2", "7", "12"], "Обнаруженные номера объединяются по неделям без жесткого диапазона 1–4")
            let reloaded = ScheduleImportSettings(defaults: defaults)
            try expect(reloaded.cachedSubgroups[groupID] == ["1", "2", "7", "12"], "Номера подгрупп из сайта сохраняются после повторного открытия настроек")
            settings.cacheSubgroups(["3"], groupID: otherGroup)
            controller.selectGroup(otherGroup)
            try expect(controller.availableSubgroups == ["3"] && requests.count == 2, "Выбор другой группы использует только ее кэш без загрузки")
            controller.selectGroup(groupID)
            try expect(controller.availableSubgroups == ["1", "2", "7", "12"] && requests.count == 2, "Возврат группы восстанавливает ее номера без сети")
            settings.cacheSubgroups(["2/10", " 12 ", "1", ""], groupID: groupID)
            try expect(controller.availableSubgroups == ["1", "2", "7", "10", "12"], "Совместные номера нормализуются в отдельные значения с числовой сортировкой")
        }

        private func partialWeekPreservesUnknownDays() async throws {
            let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
            let store = CalendarStore(directory: directory)
            let settings = try settings()
            let monday = math.date(day: 12, month: 10, year: 2026)!
            let dates = [2, 3, 6].map { math.shifting(monday, by: $0, mode: .day) }
            let old = zip(["explicit-empty", "unknown-thursday", "unknown-sunday"], dates).map { id, date in
                ISTUParsedLesson(sourceID: id, day: CivilDay(date: date), startMinute: 600, subject: id, kind: "Лекция", teacher: "", subgroup: nil, room: "")
            }
            _ = try store.importISTUSchedule(ISTUSchedulePage(lessons: old, coveredDays: dates.map { CivilDay(date: $0) }, groupName: nil), groupID: groupID, durationMinutes: 90)
            let manual = try store.saveLesson(subject: "Моя среда", date: dates[0], startMinute: 800, endMinute: 890, homework: "Не терять", room: "", teacher: "")
            let retainedIDs = Set(store.lessons.filter { $0.istuOrigin?.sourceID.hasPrefix("unknown-") == true }.map(\.id))
            var requests: [String] = []
            let controller = ISTUImportController(settings: settings) { path in
                requests.append(path)
                return self.subgroupWeek(monday, inactiveSubgroup: "7", includedDayOffsets: [0, 1, 2])
            }
            controller.attach(store: store)
            await controller.refresh(date: monday, mode: .week)
            try expect(requests == [path(monday)] && controller.errorMessage == nil && settings.lastRefresh != nil, "Частичная подтвержденная неделя принимается одним запросом")
            try expect(store.lessons(on: dates[0]) == [manual], "Явно показанная пустая среда удаляет прежний импорт, сохраняя ручную пару")
            try expect(Set(store.lessons.filter { $0.istuOrigin?.sourceID.hasPrefix("unknown-") == true }.map(\.id)) == retainedIDs, "Отсутствующие в HTML четверг и воскресенье сохраняют прежние данные и UUID")
            try expect(store.lessons(on: monday).count == 3 && controller.availableSubgroups == ["1", "2", "7"], "Опубликованные пары и номера подгрупп частичной недели сохраняются")
            try expect(controller.statusMessage == nil, "Успешный частичный импорт не оставляет строку итоговой статистики")
        }

        private func partialMonthPublishesValidWeeks() async throws {
            let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
            let store = CalendarStore(directory: directory)
            let settings = try settings()
            settings.cacheSubgroups(["20"], groupID: groupID)
            let selected = math.date(day: 15, month: 10, year: 2026)!
            let mondays = math.monthDays(containing: selected).enumerated().filter { $0.offset % 7 == 0 }.map(\.element)
            let unknownThursday = math.shifting(mondays[0], by: 3, mode: .day)
            let emptyWednesday = math.shifting(mondays[2], by: 2, mode: .day)
            let oldDates = [unknownThursday, mondays[1], emptyWednesday, mondays[3]]
            let old = zip(["unknown-thursday", "failed-week", "explicit-empty", "invalid-week"], oldDates).map { id, date in
                ISTUParsedLesson(sourceID: id, day: CivilDay(date: date), startMinute: 600, subject: id, kind: "Лекция", teacher: "", subgroup: nil, room: "")
            }
            _ = try store.importISTUSchedule(ISTUSchedulePage(lessons: old, coveredDays: oldDates.map { CivilDay(date: $0) }, groupName: nil), groupID: groupID, durationMinutes: 90)
            let preserved = store.lessons.filter { $0.istuOrigin?.sourceID != "explicit-empty" }
            var commits = 0
            store.onCommit = { commits += 1 }
            var requests: [String] = []
            let controller = ISTUImportController(settings: settings) { path in
                requests.append(path)
                switch path {
                case self.path(mondays[0]): return self.subgroupWeek(mondays[0], inactiveSubgroup: "7", includedDayOffsets: [0, 1, 2])
                case self.path(mondays[1]): throw Failure(message: "Контролируемый отказ второй недели")
                case self.path(mondays[2]): return self.subgroupWeek(mondays[2], inactiveSubgroup: "12", includedDayOffsets: [0, 1, 2])
                case self.path(mondays[3]): return Data("<html><body>Расписание временно недоступно</body></html>".utf8)
                default: return try self.fixture("group-478240-2026-11-02.html")
                }
            }
            controller.attach(store: store)
            await controller.refresh(date: selected, mode: .month)
            try expect(requests == mondays.map(path), "Месячное обновление пытается получить все недели после сетевого отказа, неверной структуры и чужой недели")
            try expect(controller.errorMessage == nil && controller.statusMessage == nil && settings.lastRefresh != nil, "Частично доступный месяц публикует корректные данные без сообщения об ошибке")
            try expect(commits == 1, "Все подтвержденные дни месяца сохраняются одной локальной транзакцией")
            try expect(preserved.allSatisfy { store.lessons.contains($0) }, "Неизвестные дни, недоступная и неверная недели сохраняют прежние пары побезопасно")
            try expect(!store.lessons.contains { $0.istuOrigin?.sourceID == "explicit-empty" && !$0.sourceCancelled }, "Подтвержденная пустая среда корректной третьей недели очищает только свою старую пару")
            try expect(store.lessons(on: mondays[0]).count == 3 && store.lessons(on: mondays[2]).count == 3, "Корректная третья неделя загружается и сохраняется после отказа второй")
            try expect(controller.availableSubgroups == ["1", "2", "7", "12", "20"], "Кэш объединяет подгруппы только подтвержденных страниц с прежним кэшем")
            try expect(CalendarStore(directory: directory).lessons == store.lessons, "Частично доступный месяц переживает повторное открытие базы")
        }

        private func failureDoesNotCommit() async throws {
            for wrongWeek in [true, false] {
                let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
                let store = CalendarStore(directory: directory)
                let settings = try settings()
                settings.recordRefresh(Date(timeIntervalSince1970: 100))
                settings.cacheSubgroups(["7"], groupID: groupID)
                let cachedSubgroups = settings.cachedSubgroups
                let selected = math.date(day: 15, month: 10, year: 2026)!
                let manual = try store.saveLesson(subject: "Сохраненная вручную", date: selected, startMinute: 500, endMinute: 590, homework: "Не терять", room: "", teacher: "")
                let primary = directory.appendingPathComponent("planner.json")
                let bytes = try Data(contentsOf: primary)
                var requests: [String] = []
                let mondays = math.monthDays(containing: selected).enumerated().filter { $0.offset % 7 == 0 }.map(\.element)
                let controller = ISTUImportController(settings: settings) { path in
                    requests.append(path)
                    if wrongWeek { return try self.fixture("group-478240-2026-11-02.html") }
                    throw Failure(message: "Контролируемый отказ каждой страницы")
                }
                controller.attach(store: store)
                await controller.refresh(date: selected, mode: wrongWeek ? .day : .month)
                try expect(controller.errorMessage != nil && !controller.isLoading, "Полное отсутствие подтвержденных данных показывается как ошибка")
                try expect(requests.count == (wrongWeek ? 1 : mondays.count), "При полном отказе все запрошенные недели проверяются")
                try expect(store.lessons == [manual], "Отсутствие подтвержденных дней не изменяет локальную базу")
                try expect(try Data(contentsOf: primary) == bytes, "Ошибка запроса сохраняет базу побайтно")
                try expect(settings.lastRefresh == Date(timeIntervalSince1970: 100), "Неудача не изменяет время успешного обновления")
                try expect(settings.cachedSubgroups == cachedSubgroups, "Неудачный месячный импорт сохраняет прежний кэш и не публикует номера подгрупп из частичного ответа")
            }
        }

        private func unpublishedPeriodDoesNotChangeData() async throws {
            for mode in [CalendarMode.week, .month] {
                let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
                let store = CalendarStore(directory: directory)
                let settings = try settings()
                settings.groupID = "478229"
                settings.cacheSubgroups(["1"], groupID: "478229")
                settings.recordRefresh(Date(timeIntervalSince1970: 100))
                let selected = math.date(day: 24, month: 12, year: 2026)!
                let old = ISTUParsedLesson(sourceID: "old-unpublished", day: CivilDay(date: selected), startMinute: 600, subject: "Ранее сохраненная пара", kind: "Лекция", teacher: "", subgroup: "1", room: "101")
                _ = try store.importISTUSchedule(ISTUSchedulePage(lessons: [old], coveredDays: [old.day], groupName: nil), groupID: "478229", durationMinutes: 90)
                _ = try store.saveLesson(subject: "Своя пара", date: selected, startMinute: 800, endMinute: 890, homework: "Сохранить", room: "", teacher: "")
                let before = store.lessons
                let primary = directory.appendingPathComponent("planner.json")
                let bytes = try Data(contentsOf: primary)
                let cache = settings.cachedSubgroups
                var commits = 0
                store.onCommit = { commits += 1 }
                var requests: [String] = []
                let unpublished = try fixture("group-478229-2026-12-21-unpublished.html")
                let controller = ISTUImportController(settings: settings) { path in
                    requests.append(path)
                    return unpublished
                }
                controller.attach(store: store)
                await controller.refresh(date: selected, mode: mode)
                let expectedWeeks = mode == .week ? 1 : math.monthDays(containing: selected).count / 7
                try expect(requests.count == expectedWeeks && requests.allSatisfy { $0.contains("/478229/") }, "Неопубликованный \(mode.title.lowercased()) проверяет все запрошенные недели своей группы")
                try expect(controller.errorMessage == nil && controller.statusMessage == nil && !controller.isLoading, "Штатное сообщение сайта об отсутствии опубликованного периода завершается без ошибки и статистики")
                try expect(store.lessons == before && commits == 0, "Неопубликованный период не означает пустые дни и не удаляет старые или ручные пары")
                try expect(try Data(contentsOf: primary) == bytes, "Неопубликованный период не переписывает локальную базу")
                try expect(settings.cachedSubgroups == cache && settings.lastRefresh == Date(timeIntervalSince1970: 100), "Без подтвержденных дней кэш и дата последнего обновления сохраняются")
            }
        }

        private func unpublishedWeeksAfterValidPrefix() async throws {
            let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
            let store = CalendarStore(directory: directory)
            let settings = try settings()
            settings.recordRefresh(Date(timeIntervalSince1970: 100))
            let selected = math.date(day: 15, month: 10, year: 2026)!
            let mondays = math.monthDays(containing: selected).enumerated().filter { $0.offset % 7 == 0 }.map(\.element)
            let unknown = ISTUParsedLesson(sourceID: "unpublished-week-old", day: CivilDay(date: mondays[1]), startMinute: 600, subject: "Сохраненная неопубликованная неделя", kind: "Лекция", teacher: "", subgroup: nil, room: "")
            _ = try store.importISTUSchedule(ISTUSchedulePage(lessons: [unknown], coveredDays: [unknown.day], groupName: nil), groupID: groupID, durationMinutes: 90)
            let preserved = store.lessons[0]
            let unpublished = try fixture("group-478229-2026-12-21-unpublished.html")
            var requests: [String] = []
            var commits = 0
            store.onCommit = { commits += 1 }
            let controller = ISTUImportController(settings: settings) { path in
                requests.append(path)
                if path == self.path(mondays[0]) { return self.subgroupWeek(mondays[0], inactiveSubgroup: "7", includedDayOffsets: [0, 1, 2]) }
                return unpublished
            }
            controller.attach(store: store)
            await controller.refresh(date: selected, mode: .month)
            try expect(requests == mondays.map(path), "После опубликованной части обновление проверяет все оставшиеся неопубликованные недели")
            try expect(controller.errorMessage == nil && controller.statusMessage == nil && commits == 1, "Опубликованная часть перед неопубликованным остатком сохраняется одной транзакцией без ошибки")
            try expect(store.lessons.contains(preserved) && store.lessons(on: mondays[0]).count == 3, "Импортируются только подтвержденные дни, сохраненная неопубликованная неделя не очищается")
            try expect(controller.availableSubgroups == ["1", "2", "7"] && settings.lastRefresh != Date(timeIntervalSince1970: 100), "Успех опубликованной части обновляет кэш подгрупп и дату обновления")
            try expect(CalendarStore(directory: directory).lessons == store.lessons, "Опубликованная часть с неизвестным остатком сохраняется после открытия базы")
        }

        private func unpublishedDoesNotHideRealErrors() async throws {
            let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
            let store = CalendarStore(directory: directory)
            let settings = try settings()
            settings.recordRefresh(Date(timeIntervalSince1970: 100))
            settings.cacheSubgroups(["20"], groupID: groupID)
            let selected = math.date(day: 15, month: 10, year: 2026)!
            _ = try store.saveLesson(subject: "Своя пара", date: selected, startMinute: 600, endMinute: 690, homework: "Не терять", room: "", teacher: "")
            let before = store.lessons
            let primary = directory.appendingPathComponent("planner.json")
            let bytes = try Data(contentsOf: primary)
            let cache = settings.cachedSubgroups
            let mondays = math.monthDays(containing: selected).enumerated().filter { $0.offset % 7 == 0 }.map(\.element)
            let unpublished = try fixture("group-478229-2026-12-21-unpublished.html")
            var requests: [String] = []
            let controller = ISTUImportController(settings: settings) { path in
                requests.append(path)
                if path == self.path(mondays[1]) { throw Failure(message: "Контролируемая настоящая ошибка сети") }
                return unpublished
            }
            controller.attach(store: store)
            await controller.refresh(date: selected, mode: .month)
            try expect(requests == mondays.map(path), "Неопубликованные недели и одна ошибка не прерывают проверку оставшегося периода")
            try expect(controller.errorMessage?.contains("настоящая ошибка сети") == true && !controller.isLoading, "Без подтвержденных дней штатное отсутствие публикации не скрывает настоящую ошибку")
            try expect(store.lessons == before && (try Data(contentsOf: primary)) == bytes, "Сочетание неопубликованных недель и ошибки сохраняет базу побайтно")
            try expect(settings.cachedSubgroups == cache && settings.lastRefresh == Date(timeIntervalSince1970: 100), "Настоящая ошибка без подтвержденных данных не публикует кэш или время обновления")
        }

        private func cancellationAndSettingsChange() async throws {
            for cancel in [true, false] {
                let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
                let store = CalendarStore(directory: directory)
                let settings = try settings()
                let selected = math.date(day: 15, month: 10, year: 2026)!
                _ = try store.saveTask(title: "Неизменяемое дело", date: selected, groupID: nil, note: "")
                let primary = directory.appendingPathComponent("planner.json")
                let bytes = try Data(contentsOf: primary)
                let suspended = SuspendedFetch()
                let controller = ISTUImportController(settings: settings, fetch: suspended.fetch)
                controller.attach(store: store)
                let operation = Task { await controller.refresh(date: selected, mode: .day) }
                for _ in 0..<1000 where suspended.pending == nil { await Task.yield() }
                guard suspended.pending != nil else {
                    operation.cancel(); throw Failure(message: "Контроллер не начал ожидаемый явный запрос")
                }
                if cancel { controller.cancel() } else { settings.groupID = "478241" }
                suspended.complete(try fixture("group-478240-2026-10-12.html"))
                await operation.value
                try expect(suspended.paths.count == 1 && !controller.isLoading, "При отмене или смене настроек завершается один начатый запрос")
                try expect(store.lessons.isEmpty && settings.lastRefresh == nil, "Отмена или смена настроек не публикует импорт и дату обновления")
                try expect(try Data(contentsOf: primary) == bytes, "Отмена или смена настроек сохраняет исходные байты")
                try expect(cancel ? controller.statusMessage?.contains("отменена") == true : controller.errorMessage != nil, "Причина отказа показана пользователю")
            }
        }

        private func cancellationAfterBufferedWeek() async throws {
            for cancel in [true, false] {
                let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
                let store = CalendarStore(directory: directory)
                let settings = try settings()
                settings.cacheSubgroups(["20"], groupID: groupID)
                settings.recordRefresh(Date(timeIntervalSince1970: 100))
                let selected = math.date(day: 15, month: 10, year: 2026)!
                _ = try store.saveLesson(subject: "Неизменяемая ручная пара", date: selected, startMinute: 600, endMinute: 690, homework: "Не терять", room: "", teacher: "")
                let primary = directory.appendingPathComponent("planner.json")
                let bytes = try Data(contentsOf: primary)
                let before = store.lessons
                let cached = settings.cachedSubgroups
                let mondays = math.monthDays(containing: selected).enumerated().filter { $0.offset % 7 == 0 }.map(\.element)
                let suspended = SuspendedFetch()
                var requests: [String] = []
                let controller = ISTUImportController(settings: settings) { path in
                    requests.append(path)
                    if requests.count == 2 { return try await suspended.fetch(path) }
                    guard let monday = mondays.first(where: { self.path($0) == path }) else { throw Failure(message: "Непредусмотренный путь") }
                    return self.subgroupWeek(monday, inactiveSubgroup: "7", includedDayOffsets: [0, 1, 2])
                }
                controller.attach(store: store)
                let operation = Task { await controller.refresh(date: selected, mode: .month) }
                for _ in 0..<1000 where suspended.pending == nil { await Task.yield() }
                guard suspended.pending != nil else { operation.cancel(); throw Failure(message: "Не достигнута вторая страница после подтвержденной первой") }
                try expect(store.lessons == before && settings.cachedSubgroups == cached, "Первая подтвержденная неделя остается в буфере до завершения обновления")
                if cancel { controller.cancel() } else { settings.durationMinutes = 95 }
                suspended.complete(subgroupWeek(mondays[1], inactiveSubgroup: "12", includedDayOffsets: [0, 1, 2]))
                await operation.value
                try expect(store.lessons == before && !controller.isLoading, "Поздняя отмена или смена настроек откатывает даже ранее подтвержденную неделю")
                try expect(try Data(contentsOf: primary) == bytes, "Поздняя отмена или смена настроек сохраняет основной файл побайтно")
                try expect(settings.cachedSubgroups == cached && settings.lastRefresh == Date(timeIntervalSince1970: 100), "Поздний отказ не публикует кэш подгрупп и время обновления")
                try expect(cancel ? controller.statusMessage?.contains("отменена") == true : controller.errorMessage != nil, "Поздняя отмена не проглатывается как допустимый частичный ответ")
            }
        }

        private func durationRollbackAndFilter() throws {
            let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
            let store = CalendarStore(directory: directory)
            let settings = try settings()
            var requests = 0
            let controller = ISTUImportController(settings: settings) { _ in requests += 1; throw Failure(message: "Загрузка здесь запрещена тестом") }
            controller.attach(store: store)
            let date = math.date(day: 15, month: 10, year: 2026)!
            let day = CivilDay(date: date)
            let late = ISTUParsedLesson(sourceID: "late", day: day, startMinute: 1420, subject: "Поздняя", kind: "Практика", teacher: "", subgroup: nil, room: "")
            _ = try store.importISTUSchedule(ISTUSchedulePage(lessons: [late], coveredDays: [day], groupName: nil), groupID: groupID, durationMinutes: 10)
            let manual = try store.saveLesson(subject: "Ручная", date: date, startMinute: 500, endMinute: 550, homework: "", room: "", teacher: "")
            let bytes = try Data(contentsOf: directory.appendingPathComponent("planner.json"))
            settings.durationMinutes = 100
            try expect(settings.durationMinutes == 90 && controller.errorMessage != nil, "Ошибка пересчета откатывает настройку длительности")
            try expect(try Data(contentsOf: directory.appendingPathComponent("planner.json")) == bytes, "Ошибка пересчета не меняет сохраненное расписание")
            settings.groupID = "478241"; settings.subgroup = "2"
            try expect(store.importFilter == ScheduleImportFilter(groupID: "478241", subgroup: "2"), "Изменение настроек обновляет локальный фильтр")
            try expect(store.lessons(on: date) == [manual] && store.lessons.count == 2, "Другая группа скрывает импорт, сохраняя ручные занятия и исходные данные")
            try expect(requests == 0, "Пересчет длительности и смена фильтра не вызывают загрузок")
        }
    }

    @MainActor static func main() async {
        let suite = Suite()
        do {
            try await suite.run()
            print("ISTUControllerTests: \(suite.count) проверок явных запросов, периодов, отмены и атомарности пройдено; сеть/XPC не использовались.")
        } catch {
            fputs("ОШИБКА ISTUControllerTests после \(suite.count) проверок: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
