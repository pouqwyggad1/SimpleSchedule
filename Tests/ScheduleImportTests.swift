import Foundation

/// Real local transactions against temporary stores. No network, app, or user data.
@main
struct ScheduleImportTests {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @MainActor private final class Suite {
        var count = 0
        let monday = CivilDay(year: 2026, month: 10, day: 12)
        let tuesday = CivilDay(year: 2026, month: 10, day: 13)
        let nextWeek = CivilDay(year: 2026, month: 10, day: 19)

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
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Calendar-ImportTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }

        func row(_ id: String, day: CivilDay? = nil, start: Int = 510,
                 subject: String = "Математика", kind: String = "Лекция",
                 teacher: String = "Иванова", subgroup: String? = nil, room: String = "305") -> ISTUParsedLesson {
            ISTUParsedLesson(sourceID: id, day: day ?? monday, startMinute: start,
                subject: subject, kind: kind, teacher: teacher, subgroup: subgroup, room: room)
        }

        func page(_ lessons: [ISTUParsedLesson], days: [CivilDay]? = nil) -> ISTUSchedulePage {
            ISTUSchedulePage(lessons: lessons, coveredDays: days ?? [monday], groupName: "Тестовая группа сайта")
        }

        func source(_ id: String, in store: CalendarStore, group: String = "A") throws -> UniversityLesson {
            guard let lesson = store.lessons.first(where: { $0.istuOrigin?.sourceID == id && $0.istuOrigin?.groupID == group }) else {
                throw Failure(message: "Не найдено импортированное занятие \(group)/\(id)")
            }
            return lesson
        }

        func save(_ lesson: UniversityLesson, in store: CalendarStore) throws {
            try store.saveLesson(id: lesson.id, subject: lesson.subject, date: lesson.date,
                startMinute: lesson.startMinute, endMinute: lesson.endMinute, homework: lesson.homework,
                room: lesson.room, teacher: lesson.teacher, kind: lesson.kind, subgroup: lesson.subgroup)
        }

        func json(_ directory: URL) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("planner.json"))) as! [String: Any]
        }

        func run() throws {
            try idempotenceAndCoverage()
            try correctedPublishedWeek()
            try capturedUserWeekCorrection()
            try partialPublishedDaysPreserveUnknown()
            try threeWayFields()
            try deletionsAndWidgetWrites()
            try subgroupAndGroupFilters()
            try durationsAndAtomicFailures()
            try schemaThreeMigration()
        }

        private func idempotenceAndCoverage() throws {
            let directory = try folder()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = CalendarStore(directory: directory)
            let manual = try store.saveLesson(subject: "Своя пара", date: monday.date(in: .current)!,
                startMinute: 900, endMinute: 950, homework: "Личное ДЗ", room: "101", teacher: "Мой руководитель")
            let original = page([row("keep"), row("remove", start: 620), row("notes", start: 730)])
            let first = try store.importISTUSchedule(original, groupID: "A", durationMinutes: 90)
            try expect(first.added == 3 && store.lessons.count == 4, "Первый импорт добавляет занятия и сохраняет ручные")
            let identities = Set(store.lessons.map(\.id))
            let bytes = try Data(contentsOf: directory.appendingPathComponent("planner.json"))
            let again = try store.importISTUSchedule(original, groupID: "A", durationMinutes: 90)
            try expect(again.added == 0 && again.updated == 0 && again.removed == 0, "Повторный импорт не создает изменений")
            try expect(Set(store.lessons.map(\.id)) == identities, "Повторный импорт сохраняет идентификаторы")
            try expect(try Data(contentsOf: directory.appendingPathComponent("planner.json")) == bytes, "Идемпотентный импорт не переписывает основной файл")
            var withNotes = try source("notes", in: store)
            withNotes.homework = "Не терять подготовленное задание"
            try save(withNotes, in: store)
            _ = try store.importISTUSchedule(page([row("outside", day: nextWeek)], days: [nextWeek]), groupID: "A", durationMinutes: 90)
            _ = try store.importISTUSchedule(page([row("other-source")]), groupID: "B", durationMinutes: 90)
            let changed = try store.importISTUSchedule(page([row("keep", teacher: "Новый руководитель")]), groupID: "A", durationMinutes: 90)
            try expect(changed.removed == 1 && changed.preserved == 1, "Отсутствующее неизмененное занятие удаляется, занятие с ДЗ сохраняется")
            try expect(!store.lessons.contains { $0.istuOrigin?.sourceID == "remove" && !$0.sourceCancelled }, "Удаляется только пропавший источник покрытого дня")
            try expect(store.lessons.contains(manual), "Ручная пара не затрагивается импортом")
            try expect(try source("outside", in: store).civilDay == nextWeek, "Неохваченная неделя того же источника сохраняется")
            try expect(try source("other-source", in: store, group: "B").subject == "Математика", "Другая исходная группа сохраняется")
            try expect(store.lessons.first(where: { $0.id == withNotes.id })?.homework == withNotes.homework, "ДЗ сохраняется, даже когда пара исчезла на сайте")
            try expect(try source("keep", in: store).teacher == "Новый руководитель", "Неизмененное локально поле обновляется с сайта")
        }

        private func threeWayFields() throws {
            let directory = try folder()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = CalendarStore(directory: directory)
            let fields = ["subject", "date", "start", "end", "kind", "room", "teacher", "subgroup", "homework"]
            _ = try store.importISTUSchedule(page(fields.map { row($0) }), groupID: "A", durationMinutes: 90)
            var editedByField: [String: UniversityLesson] = [:]
            for field in fields {
                var lesson = try source(field, in: store)
                switch field {
                case "subject": lesson.subject = "Мое название"
                case "date": lesson.civilDay = tuesday
                case "start": lesson.startMinute = 520
                case "end": lesson.endMinute = 610
                case "kind": lesson.kind = "Мой вид"
                case "room": lesson.room = "Мой кабинет"
                case "teacher": lesson.teacher = "Мой руководитель"
                case "subgroup": lesson.subgroup = "Моя подгруппа"
                default: lesson.homework = "Самостоятельно добавленное ДЗ"
                }
                try save(lesson, in: store)
                editedByField[field] = lesson
            }
            let remote = page(fields.map { row($0, subject: "Новое название сайта", kind: "Практика", teacher: "Новый руководитель сайта", subgroup: "2", room: "402") })
            _ = try store.importISTUSchedule(remote, groupID: "A", durationMinutes: 90)
            for field in fields {
                let actual = try source(field, in: store)
                let edited = editedByField[field]!
                try expect(actual.id == edited.id, "Слияние сохраняет ID для ручного поля \(field)")
                let preserved: Bool
                switch field {
                case "subject": preserved = actual.subject == edited.subject
                case "date": preserved = actual.civilDay == edited.civilDay
                case "start": preserved = actual.startMinute == edited.startMinute
                case "end": preserved = actual.endMinute == edited.endMinute
                case "kind": preserved = actual.kind == edited.kind
                case "room": preserved = actual.room == edited.room
                case "teacher": preserved = actual.teacher == edited.teacher
                case "subgroup": preserved = actual.subgroup == edited.subgroup
                default: preserved = actual.homework == edited.homework
                }
                try expect(preserved, "Ручное поле \(field) сохраняется трехсторонним слиянием")
                try expect(actual.teacher == (field == "teacher" ? edited.teacher : "Новый руководитель сайта"), "Неизмененный руководитель обновляется отдельно от поля \(field)")
                try expect(actual.room == (field == "room" ? edited.room : "402"), "Неизмененный кабинет обновляется отдельно от поля \(field)")
                try expect(actual.istuOrigin?.original.teacher == "Новый руководитель сайта", "Снимок источника обновляется независимо от локальной правки \(field)")
            }
            let before = store.lessons
            let repeated = try store.importISTUSchedule(remote, groupID: "A", durationMinutes: 90)
            try expect(repeated.updated == 0 && store.lessons == before, "После слияния повторный импорт остается идемпотентным")
            try expect(CalendarStore(directory: directory).lessons == before, "Ручные поля и происхождение переживают повторное открытие")
        }

        /// A parser correction is a regular source refresh: former wrong-parity
        /// rows disappear inside the covered week and surviving cards keep edits.
        private func correctedPublishedWeek() throws {
            let directory = try folder()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = CalendarStore(directory: directory)
            let wednesday = CivilDay(year: 2026, month: 10, day: 14)
            let covered = [tuesday, wednesday]
            let old = page([
                row("wrong-tuesday", day: tuesday, start: 705, subject: "История России", room: "В-013"),
                row("wrong-wednesday-1", day: wednesday, start: 495, subject: "Экономика"),
                row("wrong-wednesday-2", day: wednesday, start: 600, subject: "Разработка"),
                row("wrong-wednesday-3", day: wednesday, start: 705, subject: "Лабораторная"),
                row("surviving-card", day: tuesday, start: 825, subject: "Разработка", teacher: "Старый руководитель")
            ], days: covered)
            _ = try store.importISTUSchedule(old, groupID: "A", durationMinutes: 90)
            var surviving = try source("surviving-card", in: store)
            surviving.homework = "Решить домашнее задание"
            surviving.room = "Мой кабинет"
            try save(surviving, in: store)
            let manual = try store.saveLesson(subject: "Моя среда", date: wednesday.date(in: .current)!,
                startMinute: 900, endMinute: 990, homework: "Мое ДЗ", room: "", teacher: "")
            _ = try store.importISTUSchedule(page([row("outside", day: nextWeek)], days: [nextWeek]), groupID: "A", durationMinutes: 90)

            let corrected = page([
                row("correct-tuesday", day: tuesday, start: 705, subject: "История России", room: "Б-100"),
                row("surviving-card", day: tuesday, start: 825, subject: "Разработка", teacher: "Новый руководитель", room: "З-210")
            ], days: covered)
            let result = try store.importISTUSchedule(corrected, groupID: "A", durationMinutes: 90)
            try expect(result.removed == 4 && result.added == 1 && result.updated == 1, "Исправленный источник заменяет ошибочные ветки недели без дублей")
            try expect(store.lessons(on: tuesday.date(in: .current)!).count == 2, "После исправления во вторник две пары")
            try expect(store.lessons(on: wednesday.date(in: .current)!) == [manual], "Ошибочные пары среды удаляются, собственная пара сохраняется")
            try expect(try source("correct-tuesday", in: store).room == "Б-100", "Корректная аудитория заменяет неактивную ветку")
            let current = try source("surviving-card", in: store)
            try expect(current.id == surviving.id && current.homework == surviving.homework && current.room == surviving.room, "Исправление парсера сохраняет UUID, домашнее задание и ручной кабинет существующей пары")
            try expect(current.teacher == "Новый руководитель" && current.istuOrigin?.original.room == "З-210", "Неизмененные поля и исходный снимок обновляются исправленным источником")
            try expect(try source("outside", in: store).civilDay == nextWeek, "Исправление недели не изменяет другие недели")
            let bytes = try Data(contentsOf: directory.appendingPathComponent("planner.json"))
            let repeated = try store.importISTUSchedule(corrected, groupID: "A", durationMinutes: 90)
            try expect(repeated.added == 0 && repeated.updated == 0 && repeated.removed == 0, "Повторное исправленное расписание не дублируется")
            try expect(try Data(contentsOf: directory.appendingPathComponent("planner.json")) == bytes, "Повторное исправление не переписывает базу")
        }

        private func capturedUserWeekCorrection() throws {
            let directory = try folder()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = CalendarStore(directory: directory)
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            let captured = try Data(contentsOf: root.appendingPathComponent("Fixtures/ISTU/group-478229-2026-10-12.html"))
            // Recreate the previous bug's branch choice without retaining an old
            // parser implementation: only the source's visibility marker changes.
            let wrongBranch = String(decoding: captured, as: UTF8.self)
                .replacingOccurrences(of: "sch-list-week sch-list-week-even", with: "sch-list-week sch-list-week-odd")
            let reference = monday.date(in: .current)!
            let group = "478229"
            let obsolete = try ISTUParser.schedule(html: Data(wrongBranch.utf8), referenceDate: reference, groupID: group)
            let corrected = try ISTUParser.schedule(html: captured, referenceDate: reference, groupID: group)
            store.importFilter = ScheduleImportFilter(groupID: group, subgroup: "1")
            _ = try store.importISTUSchedule(obsolete, groupID: group, durationMinutes: 90)
            let wednesday = CivilDay(year: 2026, month: 10, day: 14).date(in: .current)!
            let tuesdayDate = tuesday.date(in: .current)!
            try expect(store.lessons(on: tuesdayDate).count == 1 && store.lessons(on: wednesday).count == 3, "Старая ветка захваченной страницы воспроизводит ошибку: вторник 1, среда 3")
            let identities = Dictionary(uniqueKeysWithValues: store.lessons.map { ($0.istuOrigin!.key, $0.id) })
            let result = try store.importISTUSchedule(corrected, groupID: group, durationMinutes: 90)
            try expect(result.removed > 0 && result.added > 0, "Исправленный парсер очищает ранее импортированную неверную ветку той же недели")
            try expect(store.lessons.filter { !$0.sourceCancelled }.count == corrected.lessons.count && Set(store.lessons.filter { !$0.sourceCancelled }.map { $0.istuOrigin!.sourceID }) == Set(corrected.lessons.map(\.sourceID)), "После исправления база точно соответствует активным карточкам захваченной страницы без дублей")
            let tuesdayLessons = store.lessons(on: tuesdayDate)
            try expect(tuesdayLessons.count == 2 && store.lessons(on: wednesday).isEmpty, "Захваченная группа ИСИб-23-1 после импорта: вторник две пары, среда без пар")
            try expect(tuesdayLessons.map(\.startMinute) == [705, 825] && tuesdayLessons.map(\.endMinute) == [795, 915], "Время пар 11:45–13:15 и 13:45–15:15 сохраняется с длительностью 90 минут")
            try expect(tuesdayLessons.map(\.room) == ["Б-100", "3-210"], "Аудитории совпадают с активными карточками сайта")
            for lesson in store.lessons where identities[lesson.istuOrigin!.key] != nil {
                try expect(lesson.id == identities[lesson.istuOrigin!.key], "Пережившая исправление карточка захваченной страницы сохраняет UUID")
            }
            let reloaded = CalendarStore(directory: directory)
            reloaded.importFilter = store.importFilter
            try expect(reloaded.lessons(on: tuesdayDate) == tuesdayLessons && reloaded.lessons(on: wednesday).isEmpty, "Исправленное расписание сохраняется после повторного открытия")
        }

        private func partialPublishedDaysPreserveUnknown() throws {
            let directory = try folder()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = CalendarStore(directory: directory)
            let wednesday = CivilDay(year: 2026, month: 10, day: 14)
            let thursday = CivilDay(year: 2026, month: 10, day: 15)
            let sunday = CivilDay(year: 2026, month: 10, day: 18)
            let original = page([row("old-monday"), row("explicit-empty", day: wednesday), row("unknown-thursday", day: thursday), row("unknown-sunday", day: sunday)], days: [monday, wednesday, thursday, sunday])
            _ = try store.importISTUSchedule(original, groupID: "42", durationMinutes: 90)
            let unknown = store.lessons.filter { $0.istuOrigin?.sourceID.hasPrefix("unknown-") == true }
            let html = """
            <html><body><h1>Группа ТЕСТ-1</h1>
            <div class="info-block-item"><div class="info-block-item-label">Начало действия:</div><div class="info-block-item-value">12.10.2026</div></div>
            <div class="info-block-item"><div class="info-block-item-label">Окончание действия:</div><div class="info-block-item-value">18.10.2026</div></div>
            <div class="sch-list-week sch-list-week-even">
            <div class="sch-list-day" data-params="{'date':'12.10.2026'}"><h2 class="sch-list-day-header" id="date-12.10.2026">Понедельник</h2>
            <div class="sch-list-item" data-params="{'time':'8:15'}"><div class="sch-list-item-classes"><div class="sch-list-item-week week-all">
            <div class="schcls-item schcls-card" id="new-monday"><div class="schcls-item-name">Новая пара</div><div class="schcls-item-group"><a href="/raspisanie/grup/42/">ТЕСТ-1</a></div></div>
            </div></div></div></div>
            <div class="sch-list-day" data-params="{'date':'13.10.2026'}"><h2 class="sch-list-day-header" id="date-13.10.2026">Вторник</h2></div>
            <div class="sch-list-day" data-params="{'date':'14.10.2026'}"><h2 class="sch-list-day-header" id="date-14.10.2026">Среда</h2></div>
            </div></body></html>
            """
            let partial = try ISTUParser.schedule(html: Data(html.utf8), referenceDate: monday.date(in: .current)!, groupID: "42")
            try expect(partial.coveredDays == [monday, tuesday, wednesday], "Метаданные полной недели не расширяют подтвержденные DOM-даты понедельника–среды")
            let result = try store.importISTUSchedule(partial, groupID: "42", durationMinutes: 90)
            try expect(result.removed == 2 && result.added == 1, "Частичный импорт заменяет понедельник и очищает явно пустую среду")
            try expect(store.lessons(on: wednesday.date(in: .current)!).isEmpty, "Явно опубликованный пустой день очищает прежние автоматические пары")
            try expect(unknown.allSatisfy { store.lessons.contains($0) }, "Отсутствующие DOM-даты четверга и воскресенья сохраняются вместе с UUID и исходными полями")
            try expect(CalendarStore(directory: directory).lessons == store.lessons, "База с сохраненными неизвестными днями переживает открытие")
        }

        private func deletionsAndWidgetWrites() throws {
            let directory = try folder()
            defer { try? FileManager.default.removeItem(at: directory) }
            let storage = SharedPlannerStorage(directory: directory, isShared: true)
            let app = CalendarStore(storage: storage)
            let widget = CalendarStore(storage: storage)
            let task = try app.saveTask(title: "Дело для виджета", date: monday.date(in: .current)!, groupID: nil, note: "")
            let original = page([row("deleted"), row("kept", start: 620)])
            _ = try app.importISTUSchedule(original, groupID: "A", durationMinutes: 90)
            let deleted = try source("deleted", in: app)
            app.deleteLesson(deleted)
            var kept = try source("kept", in: app)
            kept.homework = "Моя заметка"
            try save(kept, in: app)
            let lessonsBefore = app.lessons
            let tombstonesBefore = try json(directory)["deletedISTULessonKeys"] as? [String]
            try expect(tombstonesBefore == [deleted.istuOrigin!.key], "Удаление импортированной пары сохраняет надгробие источника")
            try widget.setTaskCompleted(id: task.id, isCompleted: true)
            try expect(widget.lessons == lessonsBefore, "Устаревший процесс виджета сохраняет все поля и метаданные расписания")
            try expect(try json(directory)["deletedISTULessonKeys"] as? [String] == tombstonesBefore, "Запись задачи виджетом сохраняет надгробия")
            let reimport = try app.importISTUSchedule(original, groupID: "A", durationMinutes: 90)
            try expect(reimport.added == 0 && app.lessons.count == 1, "Повторный импорт не воскрешает удаленную пару")
            try expect(app.tasks.first?.isCompleted == true, "Импорт не теряет изменение выполнения из виджета")
            try expect(try source("kept", in: app).homework == "Моя заметка", "Импорт после записи виджета сохраняет ручное ДЗ")
            let newlyAdded = try app.importISTUSchedule(page([row("deleted"), row("kept", start: 620), row("new-remote", start: 730)]), groupID: "A", durationMinutes: 90)
            try expect(newlyAdded.added == 1 && app.lessons.count == 2, "Новый sourceID разрешен рядом с удаленным источником")
            let reopened = CalendarStore(storage: storage)
            _ = try reopened.importISTUSchedule(original, groupID: "A", durationMinutes: 90)
            try expect(!reopened.lessons.contains { $0.istuOrigin?.sourceID == "deleted" }, "Надгробие действует после перезапуска")
            try expect(try source("kept", in: reopened).istuOrigin?.original.subject == "Математика", "Снимок источника сохраняется после действий разных процессов")
        }

        private func subgroupAndGroupFilters() throws {
            let directory = try folder()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = CalendarStore(directory: directory)
            let date = monday.date(in: .current)!
            let manual = try store.saveLesson(subject: "Ручная общая", date: date, startMinute: 900, endMinute: 950, homework: "", room: "", teacher: "")
            _ = try store.importISTUSchedule(page([row("common"), row("one", subgroup: "1"), row("two", subgroup: "2"), row("both", subgroup: "1/2")]), groupID: "A", durationMinutes: 90)
            _ = try store.importISTUSchedule(page([row("other", subgroup: "1")]), groupID: "B", durationMinutes: 90)
            store.importFilter = ScheduleImportFilter(groupID: "A", subgroup: "1")
            let first = store.lessons(on: date)
            try expect(Set(first.compactMap { $0.istuOrigin?.sourceID }) == ["common", "one", "both"], "Первая подгруппа видит общие, свои и совместные 1/2")
            try expect(first.contains(manual), "Выбор источника сохраняет видимость ручных занятий")
            store.importFilter = ScheduleImportFilter(groupID: "A", subgroup: " 2 ")
            try expect(Set(store.lessons(on: date).compactMap { $0.istuOrigin?.sourceID }) == ["common", "two", "both"], "Вторая подгруппа нормализует пробелы и включает 1/2")
            store.importFilter = ScheduleImportFilter(groupID: "A", subgroup: nil)
            try expect(store.lessons(on: date).count == 5, "Все подгруппы выбранного источника и ручные пары видны вместе")
            store.importFilter = ScheduleImportFilter(groupID: "B", subgroup: "1")
            try expect(Set(store.lessons(on: date).compactMap { $0.istuOrigin?.sourceID }) == ["other"], "Смена группы скрывает импорт предыдущей группы")
            try expect(store.lessons(on: date).contains(manual) && store.lessons.count == 6, "Смена фильтра не удаляет старый импорт и не скрывает ручные общие пары")

            _ = try store.importISTUSchedule(page([row("common"), row("one", subgroup: "1"), row("two", subgroup: "2"), row("both", subgroup: "1/2"), row("ten", subgroup: "10"), row("eleven", subgroup: "11")]), groupID: "A", durationMinutes: 90)
            let allImported = store.lessons
            let bytes = try Data(contentsOf: directory.appendingPathComponent("planner.json"))
            for selected in ["1", "2", "10", "11", "1"] {
                store.importFilter = ScheduleImportFilter(groupID: "A", subgroup: selected)
                let visible = Set(store.lessons(on: date).compactMap { $0.istuOrigin?.sourceID })
                let expected: Set<String> = switch selected {
                case "1": ["common", "one", "both"]
                case "2": ["common", "two", "both"]
                case "10": ["common", "ten"]
                default: ["common", "eleven"]
                }
                try expect(visible == expected, "Подгруппа \(selected) видит только свои и общие пары; 1 не совпадает с 10/11")
                try expect(store.lessons == allImported, "Переключение подгруппы \(selected) сохраняет скрытые пары в памяти")
            }
            try expect(try Data(contentsOf: directory.appendingPathComponent("planner.json")) == bytes, "Выбор подгрупп не переписывает сохраненный импорт")
            try expect(CalendarStore(directory: directory).lessons == allImported, "После перезапуска сохраняются данные всех подгрупп")
        }

        private func durationsAndAtomicFailures() throws {
            let directory = try folder()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = CalendarStore(directory: directory)
            _ = try store.importISTUSchedule(page([row("manual-end"), row("automatic", start: 620)]), groupID: "A", durationMinutes: 90)
            var manualEnd = try source("manual-end", in: store)
            manualEnd.endMinute = 605
            try save(manualEnd, in: store)
            let manual = try store.saveLesson(subject: "Ручная пара", date: monday.date(in: .current)!, startMinute: 800, endMinute: 830, homework: "", room: "", teacher: "")
            try store.recalculateImportedDuration(100)
            try expect(try source("manual-end", in: store).endMinute == 605, "Изменение длительности не затирает вручную измененное окончание")
            try expect(try source("automatic", in: store).endMinute == 720, "Неизмененное окончание пересчитывается по новой длительности")
            try expect(store.lessons.contains(manual), "Длительность импорта не изменяет ручные пары")
            try expect(try source("manual-end", in: store).istuOrigin?.original.endMinute == 610, "Исходный снимок длительности обновляется отдельно от ручного окончания")
            _ = try store.importISTUSchedule(page([row("late", day: tuesday, start: 1400)], days: [tuesday]), groupID: "A", durationMinutes: 30)
            let primary = directory.appendingPathComponent("planner.json")
            let backup = directory.appendingPathComponent("planner.backup.json")
            let before = store.lessons
            let beforeBytes = try Data(contentsOf: primary)
            let beforeBackup = try Data(contentsOf: backup)
            let invalidPages = [
                page([row("outside", day: tuesday)]),
                page([row("duplicate"), row("duplicate")]),
                page([row("midnight", start: 1400)]),
                page([row("invalid-day", day: CivilDay(year: 2026, month: 2, day: 30))]),
                page([], days: [])
            ]
            for invalid in invalidPages {
                try rejects("Неполный или некорректный импорт отклоняется целиком") {
                    _ = try store.importISTUSchedule(invalid, groupID: "A", durationMinutes: 90)
                }
                try expect(store.lessons == before, "Ошибка импорта не публикует частичное расписание")
                try expect(try Data(contentsOf: primary) == beforeBytes, "Ошибка импорта сохраняет основной файл побайтно")
                try expect(try Data(contentsOf: backup) == beforeBackup, "Ошибка импорта не изменяет резервную копию")
            }
            try rejects("Переход пересчитанного окончания через полночь отклоняется") { try store.recalculateImportedDuration(90) }
            try expect(store.lessons == before, "Ошибка в середине пересчета откатывает все занятия")
            try expect(try Data(contentsOf: primary) == beforeBytes, "Ошибка в середине пересчета сохраняет основной файл побайтно")
            try expect(try Data(contentsOf: backup) == beforeBackup, "Неудачный пересчет не создает новую резервную версию")
        }

        private func schemaThreeMigration() throws {
            let directory = try folder()
            defer { try? FileManager.default.removeItem(at: directory) }
            let id = UUID()
            let oldLesson: [String: Any] = [
                "id": id.uuidString, "subject": "Занятие формата 3",
                "civilDay": ["year": monday.year, "month": monday.month, "day": monday.day],
                "startMinute": 510, "endMinute": 600, "homework": "Старое ДЗ", "room": "305", "teacher": "Иванова"
            ]
            let original = try JSONSerialization.data(withJSONObject: ["schemaVersion": 3, "tasks": [], "groups": [], "lessons": [oldLesson]])
            let primary = directory.appendingPathComponent("planner.json")
            try original.write(to: primary, options: .atomic)
            let store = CalendarStore(directory: directory)
            try expect(store.isAvailable && store.lessons.count == 1, "Формат 3 читается без сведений импорта")
            let lesson = store.lessons[0]
            try expect(lesson.id == id && lesson.kind.isEmpty && lesson.subgroup == nil && lesson.istuOrigin == nil, "Новые поля получают безопасные значения по умолчанию")
            try expect(try Data(contentsOf: primary) == original, "Чтение старого формата не переписывает файл")
            _ = try store.saveTask(title: "Первая запись формата 4", date: monday.date(in: .current)!, groupID: nil, note: "")
            try expect(try json(directory)["schemaVersion"] as? Int == 4, "Следующая мутация сохраняет формат 4")
            try expect(try json(directory)["deletedISTULessonKeys"] as? [String] == [], "Миграция начинает с пустого списка удаленных источников")
            try expect(try Data(contentsOf: directory.appendingPathComponent("planner.backup.json")) == original, "Исходный формат 3 сохранен побайтно в резервной копии")
            let reopened = CalendarStore(directory: directory)
            try expect(reopened.lessons == [lesson] && reopened.tasks.count == 1, "Формат 4 повторно открывается со старыми парами и новыми делами")
        }
    }

    @MainActor static func main() {
        let suite = Suite()
        do {
            try suite.run()
            print("ScheduleImportTests: \(suite.count) проверок слияния, фильтров, удаления, миграции и атомарности пройдено.")
        } catch {
            fputs("ОШИБКА ScheduleImportTests после \(suite.count) проверок: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
