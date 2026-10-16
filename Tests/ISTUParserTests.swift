import Foundation

@main
struct ISTUParserTests {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func main() {
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
        func invalidLayout(_ message: String, _ body: () throws -> Void) throws {
            count += 1
            do { try body() }
            catch ISTUParserError.invalidLayout { return }
            catch { throw Failure(message: "\(message): получено другое состояние \(error.localizedDescription)") }
            throw Failure(message: message)
        }
        func bytes(_ value: String) -> Data { Data(value.utf8) }
        func fixture(_ name: String) throws -> Data {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            return try Data(contentsOf: root.appendingPathComponent("Fixtures/ISTU/\(name)"))
        }
        func card(_ id: String, subject: String = "Математика", kind: String = "неизвестный новый вид", subgroup: String? = nil) -> String {
            """
            <div class="schcls-item schcls-card" id="\(id)"><div class="schcls-item-info">
            <div class="schcls-item-name">\(subject)</div><div class="schcls-item-distype">\(kind)</div>
            <div class="schcls-item-prepod">Иванов&nbsp;И.&nbsp;И.</div>
            <div class="schcls-item-group"><a href="/raspisanie/grup/42/">ТЕСТ-1</a>\(subgroup.map { " подгруппа \($0)" } ?? "")</div>
            </div><div class="schcls-item-aud">Б-101 &amp; Б-102</div></div>
            """
        }
        func slot(_ cards: String, time: String = "8:15", parity: String = "week-all") -> String {
            """
            <div class="sch-list-item" data-params="{'time':'\(time)'}"><div class="sch-list-item-time-inner">\(time)</div>
            <div class="sch-list-item-classes"><div class="sch-list-item-week \(parity)">\(cards)</div></div></div>
            """
        }
        func day(_ date: String, content: String) -> String { "<div class=\"sch-list-day\" data-params=\"{'date':'\(date)'}\"><h2 class=\"sch-list-day-header\" id=\"date-\(date)\">День</h2>\(content)</div>" }
        func page(_ content: String, start: String? = nil, end: String? = nil, parity: String? = nil, rendered: String = "even") -> String {
            func field(_ label: String, _ value: String) -> String { "<div class=\"info-block-item\"><div class=\"info-block-item-label\">\(label):</div><div class=\"info-block-item-value\">\(value)</div></div>" }
            return "<html><body><h1>Группа ТЕСТ-1</h1>" + (start.map { field("Начало действия", $0) } ?? "") + (end.map { field("Окончание действия", $0) } ?? "") + (parity.map { field("Показана неделя", $0) } ?? "") + "<div class=\"sch-list-week sch-list-week-\(rendered)\">\(content)</div></body></html>"
        }
        do {
            let institutes = try ISTUParser.institutes(html: fixture("institutes.html"))
            try expect(institutes.count == 12, "Реальная главная страница содержит 12 подразделений")
            try expect(institutes.contains { $0.id == "683" && $0.name == "Институт информационных технологий и анализа данных" }, "Название и id подразделения извлечены из официальной ссылки")
            let groups = try ISTUParser.groups(html: fixture("groups-683.html"))
            try expect(groups.count == 39, "Реальная страница подразделения содержит все группы")
            try expect(groups.contains(ISTUOption(id: "478240", name: "ИСТб-26-1")), "Маршрут grup и русское название группы сохранены")
            let october = CalendarMath().date(day: 12, month: 10, year: 2026)!
            let octoberPage = try ISTUParser.schedule(html: fixture("group-478240-2026-10-12.html"), referenceDate: october, groupID: "478240")
            try expect(octoberPage.coveredDays.count == 5 && octoberPage.coveredDays.first == CivilDay(year: 2026, month: 10, day: 12) && octoberPage.coveredDays.last == CivilDay(year: 2026, month: 10, day: 16), "Покрыты только пять опубликованных дней; отсутствующие выходные не объявляются пустыми")
            try expect(octoberPage.groupName == "ИСТб-26-1", "Название группы извлечено из информационного блока")
            try expect(octoberPage.lessons.count == 20, "Реальная октябрьская неделя импортирует 20 активных карточек всех подгрупп")
            try expect(octoberPage.lessons.contains { $0.subgroup == "1" } && octoberPage.lessons.contains { $0.subgroup == "2" } && octoberPage.lessons.contains { $0.subgroup == nil }, "Подгруппы 1/2 и общие занятия сохранены раздельно")
            try expect(octoberPage.lessons.contains { $0.sourceID.contains("sh13419575") }, "Активная CSS-альтернатива импортирована вопреки ошибочной текстовой подписи")
            try expect(!octoberPage.lessons.contains { $0.sourceID.contains("sh13414651") }, "Серая CSS-альтернатива исключена, хотя текст недели указывает обратное")
            let november = CalendarMath().date(day: 2, month: 11, year: 2026)!
            let novemberPage = try ISTUParser.schedule(html: fixture("group-478240-2026-11-02.html"), referenceDate: november, groupID: "478240")
            try expect(novemberPage.coveredDays.count == 5 && novemberPage.coveredDays.first == CivilDay(year: 2026, month: 11, day: 2), "Датированный route возвращает пять опубликованных дней запрошенной ноябрьской недели")
            try expect(novemberPage.lessons.contains { $0.day.day == 4 && $0.startMinute == 930 && $0.subject == "Программирование на языке высокого уровня" } && !novemberPage.lessons.contains { $0.day.day == 4 && $0.startMinute == 930 && $0.subject == "Введение в веб-технологии" }, "Ноябрьская неделя выбирает активную CSS-альтернативу")
            try expect(Set(octoberPage.lessons.map(\.sourceID)).isDisjoint(with: Set(novemberPage.lessons.map(\.sourceID))), "Повторяющиеся officialIDs разных дат получают разные sourceIDs")
            try expect(octoberPage.subgroups == ["1", "2"], "Номера всех подгрупп получены из сайта и отсортированы")

            let userWeek = try ISTUParser.schedule(html: fixture("group-478229-2026-10-12.html"), referenceDate: october, groupID: "478229")
            let tuesday = userWeek.lessons.filter { $0.day == CivilDay(year: 2026, month: 10, day: 13) }
            try expect(userWeek.groupName == "ИСИб-23-1" && userWeek.lessons.count == 19, "Реальная группа пользователя распознана, импортированы активные карточки недели")
            try expect(tuesday.count == 2 && tuesday.map(\.startMinute) == [705, 825], "Регрессия: 13 октября ровно две пары в 11:45 и 13:45")
            try expect(tuesday[0].subject == "История России" && tuesday[0].room == "Б-100" && tuesday[0].teacher == "Наумов И.В." && tuesday[0].kind == "практика", "Регрессия: История России берёт активную аудиторию Б-100, а не серую В-013")
            try expect(tuesday[1].subject == "Технологии разработки программ-роботов" && tuesday[1].room == "3-210" && tuesday[1].kind == "лекция", "Регрессия: вторая пара вторника сохранена")
            try expect(!userWeek.lessons.contains { $0.day == CivilDay(year: 2026, month: 10, day: 14) }, "Регрессия: 14 октября нет пар, три серые альтернативы исключены")
            try expect(userWeek.subgroups == ["1"], "Для ИСИб-23-1 сайт указывает только подгруппу 1; номер 2 не выдумывается")
            try expect(userWeek.coveredDays.count == 6 && !userWeek.coveredDays.contains(CivilDay(year: 2026, month: 10, day: 18)), "Непоказанное воскресенье группы пользователя не считается подтвержденно пустым")
            let followingWeek = try ISTUParser.schedule(html: fixture("group-478229-2026-10-19.html"), referenceDate: CalendarMath().date(day: 19, month: 10, year: 2026)!, groupID: "478229")
            try expect(followingWeek.lessons.filter { $0.day.day == 20 }.count == 1 && followingWeek.lessons.filter { $0.day.day == 21 }.count == 3, "Соседняя неделя переключается по CSS: вторник одна пара, среда три")
            let unpublishedHTML = try fixture("group-478229-2026-12-21-unpublished.html")
            let unpublishedDate = CalendarMath().date(day: 21, month: 12, year: 2026)!
            count += 1
            do {
                _ = try ISTUParser.schedule(html: unpublishedHTML, referenceDate: unpublishedDate, groupID: "478229")
                throw Failure(message: "Официальное отсутствие публикации не должно создавать покрытие пустой недели")
            } catch ISTUParserError.noPublishedSchedule { }
            let unpublishedText = String(data: unpublishedHTML, encoding: .utf8)!
            try invalidLayout("Другой текст вместо официального ответа не считается отсутствием публикации") {
                _ = try ISTUParser.schedule(html: bytes(unpublishedText.replacingOccurrences(of: "Не обнаружено занятий с заданными характеристиками", with: "Ошибка сервера")), referenceDate: unpublishedDate, groupID: "478229")
            }
            try invalidLayout("Точный текст без идентифицированной группы не скрывает поврежденную разметку") {
                _ = try ISTUParser.schedule(html: bytes(unpublishedText.replacingOccurrences(of: "Группа ИСИб-23-1", with: "Ошибка")), referenceDate: unpublishedDate, groupID: "478229")
            }
            try invalidLayout("Точный текст вне main не меняет ошибку разметки на отсутствие публикации") {
                let detached = unpublishedText.replacingOccurrences(of: "<p>Не обнаружено занятий с заданными характеристиками</p>", with: "").replacingOccurrences(of: "</body>", with: "<p>Не обнаружено занятий с заданными характеристиками</p></body>")
                _ = try ISTUParser.schedule(html: bytes(detached), referenceDate: unpublishedDate, groupID: "478229")
            }
            try invalidLayout("Неизвестное содержимое рядом с официальным сообщением не игнорируется") {
                _ = try ISTUParser.schedule(html: bytes(unpublishedText.replacingOccurrences(of: "</main>", with: "<div>Ошибка сервера</div></main>")), referenceDate: unpublishedDate, groupID: "478229")
            }
            try invalidLayout("Без сведений об институте и курсе отсутствие недельного блока остается ошибкой") {
                _ = try ISTUParser.schedule(html: bytes(unpublishedText.replacingOccurrences(of: "Учебное подразделение:", with: "Неизвестное поле:")), referenceDate: unpublishedDate, groupID: "478229")
            }
            try invalidLayout("Оборванный main с известным текстом не считается целым официальным ответом") {
                _ = try ISTUParser.schedule(html: bytes(unpublishedText.replacingOccurrences(of: "</main>", with: "")), referenceDate: unpublishedDate, groupID: "478229")
            }

            let synthetic = page(day("12.10.2026", content: slot(card("a", subject: "Алгебра &amp; геометрия") + card("b", subgroup: "1") + card("c", subgroup: "2"))))
            let parsed = try ISTUParser.schedule(html: bytes(synthetic), referenceDate: october, groupID: "42")
            try expect(parsed.lessons.count == 3 && parsed.lessons.allSatisfy { $0.startMinute == 495 }, "Один временной блок сохраняет несколько отдельных занятий")
            try expect(parsed.lessons.contains { $0.subject == "Алгебра & геометрия" && $0.room == "Б-101 & Б-102" }, "HTML-сущности декодируются DOM-парсером")
            try expect(parsed.lessons.allSatisfy { $0.teacher == "Иванов И. И." && $0.kind == "неизвестный новый вид" }, "Неразрывные пробелы нормализованы, неизвестный вид занятия не потерян")
            try expect(parsed.lessons.filter { $0.subgroup == nil }.count == 1, "Общая пара остается общей без подгруппы")
            try expect(parsed.subgroups == ["1", "2"], "Список подгрупп независим от текущего пользовательского выбора")
            let withInactive = page(day("12.10.2026", content: slot(card("active", subgroup: "1"), parity: "week-even") + slot(card("inactive", subgroup: "2"), parity: "week-odd")), parity: "нечетная")
            let inactive = try ISTUParser.schedule(html: bytes(withInactive), referenceDate: october, groupID: "42")
            try expect(inactive.lessons.count == 1 && inactive.lessons.first?.subgroup == "1" && inactive.subgroups == ["1", "2"], "Неактивная альтернатива пополняет список номеров, но не добавляет серую пару")
            let cardInactive = synthetic.replacingOccurrences(of: "schcls-item schcls-card\" id=\"b", with: "schcls-item schcls-card card-unactive\" id=\"b")
            let cardInactivePage = try ISTUParser.schedule(html: bytes(cardInactive), referenceDate: october, groupID: "42")
            try expect(cardInactivePage.lessons.count == 2 && cardInactivePage.subgroups == ["1", "2"], "Индивидуальная неактивная карточка исключена тем же правилом, что и CSS сайта")
            let combined = try ISTUParser.schedule(html: bytes(page(day("12.10.2026", content: slot(card("shared", subgroup: "2 / 1"))))), referenceDate: october, groupID: "42")
            try expect(combined.subgroups == ["1", "2"] && Set(combined.lessons.compactMap(\.subgroup)) == ["1", "2"], "Одна карточка нескольких подгрупп сохраняет обе подгруппы")
            let conjunction = try ISTUParser.schedule(html: bytes(page(day("12.10.2026", content: slot(card("conjunction", subgroup: "1 и 2"))))), referenceDate: october, groupID: "42")
            try expect(conjunction.subgroups == ["1", "2"] && conjunction.lessons.count == 2, "Перечень подгрупп с союзом сохраняет оба номера")
            let compactConjunction = try ISTUParser.schedule(html: bytes(page(day("12.10.2026", content: slot(card("compact-conjunction", subgroup: "1И2"))))), referenceDate: october, groupID: "42")
            try expect(compactConjunction.subgroups == ["1", "2"] && compactConjunction.lessons.count == 2, "Слитное перечисление 1И2 сохраняет обе подгруппы")
            let foreignSubgroup = card("target", subgroup: "3").replacingOccurrences(of: "<a href=\"/raspisanie/grup/42/\">", with: "<a href=\"/raspisanie/grup/99/\">ДРУГАЯ</a> подгруппа 8, <a href=\"/raspisanie/grup/42/\">")
            let foreignSubgroupPage = try ISTUParser.schedule(html: bytes(page(day("12.10.2026", content: slot(foreignSubgroup)))), referenceDate: october, groupID: "42")
            try expect(foreignSubgroupPage.subgroups == ["3"] && foreignSubgroupPage.lessons.first?.subgroup == "3", "Номер подгруппы привязан к своей ссылке группы, чужие номера исключены")
            let changedTime = try ISTUParser.schedule(html: bytes(synthetic.replacingOccurrences(of: "8:15", with: "9:00")), referenceDate: october, groupID: "42")
            try expect(Set(changedTime.lessons.map(\.sourceID)) == Set(parsed.lessons.map(\.sourceID)) && changedTime.lessons.allSatisfy { $0.startMinute == 540 }, "Изменение времени сохраняет устойчивые sourceIDs")
            let optional = synthetic.replacingOccurrences(of: "<div class=\"schcls-item-prepod\">Иванов&nbsp;И.&nbsp;И.</div>", with: "<div class=\"schcls-item-prepod\"></div>")
            try expect(try ISTUParser.schedule(html: bytes(optional), referenceDate: october, groupID: "42").lessons.allSatisfy { $0.teacher.isEmpty }, "Пустое ФИО в официальной карточке допустимо")

            let newYear = CalendarMath().date(day: 28, month: 12, year: 2026)!
            let boundary = page(day("31.12", content: slot(card("dec"))) + day("01.01", content: slot(card("jan"))))
            let cross = try ISTUParser.schedule(html: bytes(boundary), referenceDate: newYear, groupID: "42")
            try expect(cross.coveredDays == [CivilDay(year: 2026, month: 12, day: 31), CivilDay(year: 2027, month: 1, day: 1)], "Год восстанавливается однозначно внутри запрошенной недели на границе года")
            for (dayNumber, month, year) in [(1, 9, 2026), (1, 1, 2027), (1, 9, 2027)] {
                let dateString = "\(dayNumber).\(month).\(year)"
                let reference = CalendarMath().date(day: dayNumber, month: month, year: year)!
                for rendered in ["odd", "even"] {
                    let chosen = try ISTUParser.schedule(html: bytes(page(day(dateString, content: slot(card("odd"), parity: "week-odd") + slot(card("even"), parity: "week-even")), parity: rendered == "odd" ? "четная" : "нечетная", rendered: rendered)), referenceDate: reference, groupID: "42")
                    try expect(chosen.lessons.count == 1 && chosen.lessons.first?.sourceID.contains(":\(rendered):") == true, "Граница учебного/календарного года \(dateString): выбор следует DOM, а не вычисленной четности")
                }
            }
            try rejects("Год вне запрошенной недели нельзя угадывать") { _ = try ISTUParser.schedule(html: bytes(page(day("01.06", content: ""))), referenceDate: newYear, groupID: "42") }
            let empty = try ISTUParser.schedule(html: bytes(page("", start: "12.10.2026", end: "18.10.2026", parity: "нечетная")), referenceDate: october, groupID: "42")
            try expect(empty.lessons.isEmpty && empty.coveredDays.count == 7, "Явно пустая официальная неделя отличается от поврежденной страницы")
            let emptyDay = try ISTUParser.schedule(html: bytes(page(day("12.10.2026", content: ""))), referenceDate: october, groupID: "42")
            try expect(emptyDay.lessons.isEmpty && emptyDay.coveredDays.count == 1, "Явная дата пустого дня сохраняется как покрытая")
            let partial = try ISTUParser.schedule(html: bytes(page(day("12.10.2026", content: slot(card("partial-mon"))) + day("13.10.2026", content: slot(card("partial-tue"))) + day("14.10.2026", content: ""), start: "12.10.2026", end: "18.10.2026")), referenceDate: october, groupID: "42")
            try expect(partial.lessons.count == 2 && partial.coveredDays == [CivilDay(year: 2026, month: 10, day: 12), CivilDay(year: 2026, month: 10, day: 13), CivilDay(year: 2026, month: 10, day: 14)], "Частично опубликованная неделя пн–ср импортируется без ошибки, несмотря на полный диапазон в шапке")
            try expect(!partial.coveredDays.contains(CivilDay(year: 2026, month: 10, day: 15)) && !partial.coveredDays.contains(CivilDay(year: 2026, month: 10, day: 18)), "Неподтвержденный остаток недели не считается пустым и не дает права удалять его данные")
            try expect(partial.coveredDays.contains(CivilDay(year: 2026, month: 10, day: 14)) && !partial.lessons.contains { $0.day.day == 14 }, "Явно опубликованный пустой день остается покрытым при частичном импорте")
            let partialRange = try ISTUParser.schedule(html: bytes(page(day("12.10.2026", content: slot(card("range-mon"))), start: "12.10.2026", end: "14.10.2026")), referenceDate: october, groupID: "42")
            try expect(partialRange.coveredDays == [CivilDay(year: 2026, month: 10, day: 12)] && partialRange.lessons.count == 1, "Частичный диапазон в шапке тоже не подтверждает отсутствующие даты")
            let partialEmptyRange = try ISTUParser.schedule(html: bytes(page("занятий нет", start: "12.10.2026", end: "14.10.2026")), referenceDate: october, groupID: "42")
            try expect(partialEmptyRange.lessons.isEmpty && partialEmptyRange.coveredDays.count == 3, "Явно пустой диапазон пн–ср подтверждается целиком без расширения до воскресенья")
            try rejects("Случайная пустая HTML-страница не очищает данные") { _ = try ISTUParser.schedule(html: bytes("<html><body>Ошибка сервера</body></html>"), referenceDate: october, groupID: "42") }
            try rejects("Неделя без дат и диапазона не считается пустой") { _ = try ISTUParser.schedule(html: bytes(page("")), referenceDate: october, groupID: "42") }
            try rejects("HTML ошибки в блоке недели не считается пустой неделей") { _ = try ISTUParser.schedule(html: bytes(page("Ошибка сервера", start: "12.10.2026", end: "18.10.2026")), referenceDate: october, groupID: "42") }
            try rejects("Ошибка сервера в блоке дня не считается опубликованным пустым днем") { _ = try ISTUParser.schedule(html: bytes(page(day("12.10.2026", content: "Ошибка сервера"), start: "12.10.2026", end: "18.10.2026")), referenceDate: october, groupID: "42") }
            try rejects("Чужая полная неделя с согласованными датами не подменяет запрошенную") { _ = try ISTUParser.schedule(html: bytes(page(day("19.10.2026", content: slot(card("wrong-week"))), start: "19.10.2026", end: "25.10.2026")), referenceDate: october, groupID: "42") }
            try rejects("Чужой явно пустой диапазон не очищает запрошенную неделю") { _ = try ISTUParser.schedule(html: bytes(page("", start: "19.10.2026", end: "25.10.2026")), referenceDate: october, groupID: "42") }
            try rejects("Без метаданных явно датированное занятие чужой недели тоже отклоняется") { _ = try ISTUParser.schedule(html: bytes(page(day("19.10.2026", content: slot(card("wrong-week-no-range"))))), referenceDate: october, groupID: "42") }
            try rejects("Несуществующая дата не переносится в следующий месяц") { _ = try ISTUParser.schedule(html: bytes(page(day("29.02.2027", content: ""))), referenceDate: october, groupID: "42") }
            try rejects("Повторяющиеся даты отклоняются") { _ = try ISTUParser.schedule(html: bytes(page(day("12.10.2026", content: "") + day("12.10.2026", content: ""))), referenceDate: october, groupID: "42") }
            try rejects("Дата вне заявленного диапазона отклоняется") { _ = try ISTUParser.schedule(html: bytes(page(day("19.10.2026", content: ""), start: "12.10.2026", end: "18.10.2026")), referenceDate: october, groupID: "42") }
            try rejects("Некорректное время не импортируется") { _ = try ISTUParser.schedule(html: bytes(page(day("12.10.2026", content: slot(card("bad-time"), time: "25:99")))), referenceDate: october, groupID: "42") }
            try rejects("Пустой предмет не исчезает молча из импорта") { _ = try ISTUParser.schedule(html: bytes(page(day("12.10.2026", content: slot(card("bad-name", subject: " "))))), referenceDate: october, groupID: "42") }
            try rejects("Один officialID разных временных карточек не разделяется наугад") { _ = try ISTUParser.schedule(html: bytes(page(day("12.10.2026", content: slot(card("same"), time: "8:15") + slot(card("same"), time: "10:00")))), referenceDate: october, groupID: "42") }
            try rejects("Карточка другой группы не очищает выбранную группу") { _ = try ISTUParser.schedule(html: bytes(synthetic), referenceDate: october, groupID: "99") }
            try expect(try ISTUParser.schedule(html: bytes(page(day("12.10.2026", content: slot(card("p"))), parity: "четная")), referenceDate: october, groupID: "42").lessons.count == 1, "Текстовая подпись недели не подменяет официальный CSS-селектор")
            try rejects("Без активного класса недели нельзя угадывать по противоречивой текстовой подписи") { _ = try ISTUParser.schedule(html: bytes(withInactive.replacingOccurrences(of: "sch-list-week-even", with: "")), referenceDate: october, groupID: "42") }
            try rejects("Два активных класса недели не выбираются наугад") { _ = try ISTUParser.schedule(html: bytes(withInactive.replacingOccurrences(of: "sch-list-week-even", with: "sch-list-week-even sch-list-week-odd")), referenceDate: october, groupID: "42") }
            try rejects("Противоречивые классы одной альтернативы отклоняются") { _ = try ISTUParser.schedule(html: bytes(withInactive.replacingOccurrences(of: "sch-list-item-week week-even", with: "sch-list-item-week week-even week-odd")), referenceDate: october, groupID: "42") }
            try rejects("Нераспознанная подгруппа не превращается в общую пару") { _ = try ISTUParser.schedule(html: bytes(page(day("12.10.2026", content: slot(card("unknown-subgroup", subgroup: "неизвестно"))))), referenceDate: october, groupID: "42") }
            try rejects("Нераспознанный суффикс не теряется после первой цифры подгруппы") { _ = try ISTUParser.schedule(html: bytes(page(day("12.10.2026", content: slot(card("unknown-subgroup-suffix", subgroup: "1 неизвестно"))))), referenceDate: october, groupID: "42") }
            try rejects("Неизвестная разметка карточек не считается отсутствием занятий") { _ = try ISTUParser.schedule(html: bytes(synthetic.replacingOccurrences(of: "schcls-item schcls-card", with: "changed-layout")), referenceDate: october, groupID: "42") }
            try rejects("Внутренние XML-сущности запрещены") { _ = try ISTUParser.schedule(html: bytes("<!DOCTYPE html [<!ENTITY payload SYSTEM 'file:///etc/passwd'>]>" + synthetic), referenceDate: october, groupID: "42") }
            let inert = synthetic.replacingOccurrences(of: "<body>", with: "<body><script>throw new Error('must not execute')</script><iframe src='https://example.invalid'></iframe>")
            try expect(try ISTUParser.schedule(html: bytes(inert), referenceDate: october, groupID: "42") == parsed, "Scripts и внешние resource-элементы не выполняются и не участвуют в расписании")
            print("ISTUParserTests: \(count) проверок реальных HTML-фрагментов, четности, подгрупп, дат и безопасного отказа пройдено.")
        } catch {
            fputs("ОШИБКА ISTUParserTests после \(count) проверок: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
