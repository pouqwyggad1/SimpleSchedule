import Foundation

/// A separate signed sandboxed host. Persistence checks always supply an isolated
/// temporary directory; no default storage resolver or login item code is used.
@main
struct FetchCheck {
    @MainActor
    static func main() async {
        let arguments = CommandLine.arguments.dropFirst()
        if arguments.first == "--policy-tests" {
            let valid = ["/raspisanie", "/raspisanie/podrazdelenie/123", "/raspisanie/grup/478240", "/raspisanie/grup/478240/02.11.2026/", "/raspisanie/grup/1/29.02.2024/", "/raspisanie/grup/1/01.01.0001/"]
            let invalid = ["https://www.istu.edu/raspisanie", "/raspisanie/", "/raspisanie?x=1", "/raspisanie#x", "/raspisanie/grup/-1", "/raspisanie/grup/1/29.02.2025/", "/raspisanie/grup/1/31.04.2026/", "/raspisanie/grup/1/01.01.0000/", "/raspisanie/grup/1/2.11.2026/", "/raspisanie/grup/1/02.11.2026", "/raspisanie/grup/1/02.11.2026/?q=1", "/raspisanie/../private", "/raspisanie\n", "/raspisanie/%67rup/1", "/raspisanie/grup/١", "/raspisanie//grup/1"]
            guard valid.allSatisfy({ (try? ISTUFetchPolicy.url(for: $0)) != nil }),
                  invalid.allSatisfy({ (try? ISTUFetchPolicy.url(for: $0)) == nil }) else {
                print("FAIL: политика адресов")
                exit(1)
            }
            print("PASS: \(valid.count + invalid.count) проверок точных адресов и григорианских дат; сетевых запросов не было.")
            return
        }
        if arguments.first == "--chain" || arguments.first == "--chain-user" {
            do {
                let userWeek = arguments.first == "--chain-user"
                let groupID = userWeek ? "478229" : "478240"
                let first = userWeek ? CivilDay(year: 2026, month: 10, day: 12) : CivilDay(year: 2026, month: 11, day: 2)
                let requestedDate = first.date(in: .current)!
                let requestedWeek = CalendarMath().weekDays(containing: requestedDate).map { CivilDay(date: $0) }
                let institutesHTML = try await ISTUFetchClient.fetch(path: "/raspisanie")
                let institutes = try ISTUParser.institutes(html: institutesHTML)
                guard institutes.contains(where: { $0.id == "683" }) else { throw CheckError.unexpectedInstitutes }
                print("PASS: XPC → HTML \(institutesHTML.count) байт → институты \(institutes.count).")
                let groupsHTML = try await ISTUFetchClient.fetch(path: "/raspisanie/podrazdelenie/683")
                let groups = try ISTUParser.groups(html: groupsHTML)
                guard groups.contains(where: { $0.id == groupID }) else { throw CheckError.unexpectedGroups(groupID) }
                print("PASS: XPC → HTML \(groupsHTML.count) байт → группы \(groups.count).")
                let routeDate = String(format: "%02d.%02d.%04d", first.day, first.month, first.year)
                let scheduleHTML = try await ISTUFetchClient.fetch(path: "/raspisanie/grup/\(groupID)/\(routeDate)/")
                let schedule = try ISTUParser.schedule(html: scheduleHTML, referenceDate: requestedDate, groupID: groupID)
                guard !schedule.coveredDays.isEmpty,
                      schedule.coveredDays.allSatisfy({ requestedWeek.contains($0) }) else { throw CheckError.unexpectedWeek(routeDate) }
                print("PASS: XPC → HTML \(scheduleHTML.count) байт → неделя от \(routeDate), группа \(groupID), \(schedule.coveredDays.count) подтверждённых дней, \(schedule.lessons.count) занятий; отсутствующие дни не считаются пустыми.")
                if userWeek { try verifyUserWeek(schedule) }
                try verifyTemporaryPersistence(schedule, groupID: groupID)
                print("PASS: три последовательных запроса в одном sandboxed host; пользовательская база не открывалась и не изменялась.")
                // Gives the caller a short observation window after every connection
                // is invalidated, without keeping the service alive ourselves.
                try await Task.sleep(for: .seconds(2))
                return
            } catch {
                print("FAIL: \(error.localizedDescription)")
                exit(1)
            }
        }
        let verifyIsolation = arguments.first == "--verify-isolation"
        let path = verifyIsolation ? (arguments.dropFirst().first ?? "/raspisanie") : (arguments.first ?? "/raspisanie")
        do {
            if verifyIsolation {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.urlCache = nil
                configuration.httpCookieStorage = nil
                configuration.urlCredentialStorage = nil
                configuration.timeoutIntervalForRequest = 3
                configuration.timeoutIntervalForResource = 3
                let probe = URLSession(configuration: configuration, delegate: ProbeRedirectRefuser(), delegateQueue: nil)
                let url = try ISTUFetchPolicy.url(for: path)
                var denied = false
                do { _ = try await probe.data(from: url) }
                catch { denied = true; print("PASS: прямой запрос sandboxed родителя отклонён (\((error as NSError).domain), \((error as NSError).code)).") }
                probe.invalidateAndCancel()
                guard denied else { throw NSError(domain: "FetchCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Прямой запрос родителя неожиданно разрешён."]) }
            }
            let data = try await ISTUFetchClient.fetch(path: path)
            print("PASS: \(data.count) байт HTML через embedded XPC; основной процесс без сетевого разрешения.")
        } catch {
            print("FAIL: \(error.localizedDescription)")
            exit(1)
        }
    }

    private static func verifyUserWeek(_ page: ISTUSchedulePage) throws {
        let tuesday = page.lessons.filter { $0.day == CivilDay(year: 2026, month: 10, day: 13) }
        guard tuesday.count == 2, tuesday.map(\.startMinute) == [705, 825],
              tuesday[0].subject == "История России", tuesday[0].room == "Б-100",
              tuesday[1].subject == "Технологии разработки программ-роботов", tuesday[1].room == "3-210",
              !page.lessons.contains(where: { $0.day == CivilDay(year: 2026, month: 10, day: 14) }),
              page.subgroups == ["1"] else {
            throw CheckError.userSchedule("Живая страница ИСИб-23-1 не совпадает с контрольными парами 13/14 октября или номерами подгрупп.")
        }
        print("PASS: живая ИСИб-23-1: 13 октября ровно две пары (11:45 История России, Б-100; 13:45 Технологии разработки программ-роботов, 3-210), 14 октября пар нет; номера подгрупп сайта: 1.")
    }

    @MainActor private static func verifyTemporaryPersistence(_ page: ISTUSchedulePage, groupID: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Calendar-FetchCheck-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CalendarStore(directory: directory)
        guard store.isAvailable, !page.lessons.isEmpty else { throw CheckError.persistence("Не удалось открыть временное хранилище или живое расписание пусто.") }
        let result = try store.importISTUSchedule(page, groupID: groupID, durationMinutes: 90)
        guard result.added == page.lessons.count, store.lessons.count == page.lessons.count else { throw CheckError.persistence("Первый импорт создал неожиданное число занятий.") }
        let reloaded = CalendarStore(directory: directory)
        guard reloaded.isAvailable, reloaded.lessons == store.lessons else { throw CheckError.persistence("Перечитывание локального файла изменило занятия.") }
        let bySource = Dictionary(uniqueKeysWithValues: reloaded.lessons.compactMap { lesson in lesson.istuOrigin.map { ($0.sourceID, lesson) } })
        for parsed in page.lessons {
            guard let lesson = bySource[parsed.sourceID],
                  lesson.istuOrigin?.groupID == groupID, lesson.civilDay == parsed.day,
                  lesson.startMinute == parsed.startMinute, lesson.endMinute == parsed.startMinute + 90,
                  lesson.subject == parsed.subject, lesson.kind == parsed.kind,
                  lesson.teacher == parsed.teacher, lesson.room == parsed.room, lesson.subgroup == parsed.subgroup,
                  lesson.homework.isEmpty else { throw CheckError.persistence("Поля импортированного занятия или расчёт окончания отличаются от HTML.") }
        }
        print("PASS: live HTML → локальный JSON → повторное открытие: \(page.lessons.count) занятий; даты, названия, виды, преподаватели, аудитории, подгруппы и конец = начало + 90 минут совпадают.")
        guard let edited = reloaded.lessons.first else { throw CheckError.persistence("Не найдено занятие для проверки ручного ДЗ.") }
        try reloaded.saveLesson(id: edited.id, subject: edited.subject, date: edited.date,
                                startMinute: edited.startMinute, endMinute: edited.endMinute,
                                homework: "Диагностическое ручное ДЗ", room: edited.room,
                                teacher: edited.teacher, kind: edited.kind, subgroup: edited.subgroup)
        let manual = try reloaded.saveLesson(subject: "Диагностическое ручное занятие", date: edited.date,
                                             startMinute: 600, endMinute: 690, homework: "Личное ДЗ", room: "", teacher: "")
        let before = reloaded.lessons
        let bytesBefore = try Data(contentsOf: directory.appendingPathComponent("planner.json"))
        let repeated = try reloaded.importISTUSchedule(page, groupID: groupID, durationMinutes: 90)
        let final = CalendarStore(directory: directory)
        guard repeated.added == 0, repeated.updated == 0, repeated.removed == 0,
              final.isAvailable, final.lessons == before,
              final.lessons.count == page.lessons.count + 1,
              final.lessons.first(where: { $0.id == edited.id })?.homework == "Диагностическое ручное ДЗ",
              final.lessons.contains(manual),
              try Data(contentsOf: directory.appendingPathComponent("planner.json")) == bytesBefore else {
            throw CheckError.persistence("Повторный импорт создал дубли, изменил ручное занятие/ДЗ или перезаписал файл без изменений.")
        }
        print("PASS: повторный импорт без дублей и записи неизменённого JSON; ручное ДЗ и отдельное ручное занятие сохранены после повторного открытия. Временная база удаляется.")
    }
}

private enum CheckError: LocalizedError {
    case unexpectedInstitutes, unexpectedGroups(String), unexpectedWeek(String)
    case persistence(String), userSchedule(String)
    var errorDescription: String? {
        switch self {
        case .unexpectedInstitutes: "В актуальном списке не найден проверочный институт 683."
        case let .unexpectedGroups(groupID): "В актуальном списке не найдена проверочная группа \(groupID)."
        case let .unexpectedWeek(date): "Датированный запрос не вернул подтверждённые дни запрошенной недели от \(date)."
        case let .persistence(reason): "Проверка временного хранилища: \(reason)"
        case let .userSchedule(reason): reason
        }
    }
}

private final class ProbeRedirectRefuser: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
