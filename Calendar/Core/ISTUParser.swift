import Foundation

/// Parses inert HTML using Apple's libxml-backed DOM. It never loads resources,
/// evaluates scripts, follows links, or applies a lesson duration.
enum ISTUParser {
    private static let utc = TimeZone(secondsFromGMT: 0)!

    static func institutes(html: Data) throws -> [ISTUOption] {
        try options(html: html, container: "list-sublist", pathComponent: "podrazdelenie")
    }

    static func groups(html: Data) throws -> [ISTUOption] {
        try options(html: html, container: "schd-grp-list", pathComponent: "grup")
    }

    static func schedule(html: Data, referenceDate: Date, groupID: String) throws -> ISTUSchedulePage {
        guard numeric(groupID) else { throw ISTUParserError.invalidLayout("Некорректный идентификатор группы.") }
        let document = try document(html)
        let weeks = try nodes(document, className: "sch-list-week")
        if weeks.isEmpty, try isUnpublishedSchedule(document, originalHTML: html) {
            throw ISTUParserError.noPublishedSchedule
        }
        guard weeks.count == 1 else { throw ISTUParserError.invalidLayout("Не найден единственный блок недели.") }
        let week = weeks[0]
        let metadata = try info(document)
        let name = try groupName(document)
        let activeParity = try renderedParity(week)
        let range = try coverage(metadata: metadata, reference: referenceDate)
        let requestedDays = CalendarMath().weekDays(containing: referenceDate).map { CivilDay(date: $0) }
        guard range?.allSatisfy({ requestedDays.contains($0) }) != false else {
            throw ISTUParserError.invalidLayout("Заявленный диапазон находится вне запрошенной недели.")
        }
        let days = try nodes(week, className: "sch-list-day")
        guard !days.isEmpty || range != nil else { throw ISTUParserError.invalidLayout("Нет дат или подтверждённого пустого недельного диапазона.") }
        if days.isEmpty, !clean(week.stringValue ?? "").isEmpty {
            guard clean(week.stringValue ?? "").lowercased().contains("занятий нет") else {
                throw ISTUParserError.invalidLayout("Вместо дат получен неизвестный текст.")
            }
        }
        // A declared week is a bound, not proof that every day was published.
        // Missing trailing days must not erase previously saved lessons. Only an
        // explicitly empty whole-week block confirms its complete stated range.
        var covered = days.isEmpty ? (range ?? []) : []
        var seenDays: [CivilDay] = []
        var results: [String: ISTUParsedLesson] = [:]
        var availableSubgroups: Set<String> = []
        for dayNode in days {
            let day = try parseDay(dayNode, reference: referenceDate)
            guard !seenDays.contains(day), range?.contains(day) != false, requestedDays.contains(day) else {
                throw ISTUParserError.invalidLayout("Повторяющаяся дата или дата вне запрошенного диапазона.")
            }
            seenDays.append(day)
            covered.append(day)
            let slots = try nodes(dayNode, className: "sch-list-item")
            let cards = try nodes(dayNode, className: "schcls-item")
            if slots.isEmpty && cards.isEmpty {
                let headers = try nodes(dayNode, className: "sch-list-day-header")
                let content = clean(dayNode.stringValue ?? "")
                let headerText = headers.map { clean($0.stringValue ?? "") }.joined(separator: " ")
                let remaining = clean(content.hasPrefix(headerText) ? String(content.dropFirst(headerText.count)) : content).lowercased()
                guard ["", "свободно", "занятий нет"].contains(remaining) else {
                    throw ISTUParserError.invalidLayout("Не распознано содержимое пустого дня.")
                }
            }
            var visitedCards = 0
            for slot in slots {
                let start = try startMinute(slot)
                let classContainers = try nodes(slot, className: "sch-list-item-classes")
                guard classContainers.count == 1 else { throw ISTUParserError.invalidLayout("Не найден блок занятий времени.") }
                let slotCards = try nodes(classContainers[0], className: "schcls-item")
                visitedCards += slotCards.count
                if slotCards.isEmpty, !clean(classContainers[0].stringValue ?? "").isEmpty {
                    throw ISTUParserError.invalidLayout("Неизвестная разметка карточек занятий.")
                }
                for card in slotCards {
                    if classNames(card).contains("schcls-empty") {
                        guard try !isActive(card, parity: activeParity) || ["", "свободно", "занятий нет"].contains(clean(card.stringValue ?? "").lowercased()) else {
                            throw ISTUParserError.invalidLayout("Не распознан текст свободной пары.")
                        }
                        continue
                    }
                    // Both weekly alternatives contain real subgroup metadata.
                    // Cache their numbers, but never import the greyed-out lessons.
                    let subgroups = try targetSubgroups(card, groupID: groupID)
                    availableSubgroups.formUnion(subgroups.compactMap { $0 })
                    guard try isActive(card, parity: activeParity) else { continue }
                    let subject = try requiredText(card, className: "schcls-item-name")
                    let kind = try optionalText(card, className: "schcls-item-distype")
                    let teacher = try optionalText(card, className: "schcls-item-prepod")
                    let room = try optionalText(card, className: "schcls-item-aud")
                    let rawID = attribute(card, "id") ?? attribute(card, "title") ?? ""
                    guard !rawID.isEmpty, rawID.count < 128 else { throw ISTUParserError.invalidLayout("У карточки нет идентификатора источника.") }
                    for subgroup in subgroups {
                        let sourceID = "istu:\(groupID):\(day.year)-\(day.month)-\(day.day):\(rawID):\(subgroup ?? "all")"
                        let lesson = ISTUParsedLesson(sourceID: sourceID, day: day, startMinute: start, subject: subject, kind: kind, teacher: teacher, subgroup: subgroup, room: room)
                        if let previous = results[sourceID], previous != lesson {
                            throw ISTUParserError.invalidLayout("Один идентификатор содержит разные занятия.")
                        }
                        results[sourceID] = lesson
                    }
                }
            }
            guard visitedCards == cards.count else { throw ISTUParserError.invalidLayout("Карточка занятия находится вне блока времени.") }
        }
        guard !covered.isEmpty else { throw ISTUParserError.invalidLayout("Не подтверждён ни один день расписания.") }
        covered.sort(by: dayLess)
        let lessons = results.values.sorted {
            if $0.day != $1.day { return dayLess($0.day, $1.day) }
            if $0.startMinute != $1.startMinute { return $0.startMinute < $1.startMinute }
            return $0.sourceID < $1.sourceID
        }
        return ISTUSchedulePage(lessons: lessons, coveredDays: covered, groupName: name,
                                subgroups: availableSubgroups.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    private static func document(_ html: Data) throws -> XMLDocument {
        guard html.count > 0, html.count <= 2_000_000, let text = String(data: html, encoding: .utf8),
              !text.localizedCaseInsensitiveContains("<!ENTITY") else { throw ISTUParserError.invalidHTML }
        do {
            // HTML tidy otherwise treats an absent/HTML5-only charset as Latin-1.
            // A Unicode BOM conveys the already validated UTF-8 text unambiguously.
            // Foundation's HTML4 tidy drops <main> together with its attributes.
            // Preserve its boundary as a marked div for the narrow unpublished
            // response check; all resource/script nodes are still removed below.
            let normalized = text.replacingOccurrences(of: "(?i)<main\\b", with: "<div data-istu-main=\"true\"", options: .regularExpression)
                .replacingOccurrences(of: "(?i)</main\\s*>", with: "</div>", options: .regularExpression)
            guard let unicode = normalized.data(using: .utf16) else { throw ISTUParserError.invalidHTML }
            let document = try XMLDocument(data: unicode, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
            guard try document.nodes(forXPath: "/*").count == 1 else { throw ISTUParserError.invalidHTML }
            for node in descendants(document, where: { ["script", "style", "iframe", "object", "embed", "link"].contains($0.name ?? "") }) { node.detach() }
            return document
        } catch { throw ISTUParserError.invalidHTML }
    }

    /// The official future-period response has no dates or weekly block. It is
    /// not an empty covered week: it must leave every existing lesson untouched.
    /// Accept only the exact message inside the complete, identified group main.
    private static func isUnpublishedSchedule(_ document: XMLDocument, originalHTML: Data) throws -> Bool {
        guard let original = String(data: originalHTML, encoding: .utf8),
              original.range(of: "(?is)<main\\b[^>]*>.*?</main\\s*>", options: .regularExpression) != nil else { return false }
        let mains = descendants(document, where: { $0.name == "div" && attribute($0, "data-istu-main") == "true" && classNames($0).contains("page-content") })
        guard mains.count == 1 else { return false }
        let main = mains[0]
        let infos = try nodes(main, className: "schedule-info")
        let paragraphs = descendants(main, where: { $0.name == "p" })
        guard infos.count == 1, paragraphs.count == 1,
              clean(paragraphs[0].stringValue ?? "") == "Не обнаружено занятий с заданными характеристиками",
              let name = try groupName(infos[0]), !name.isEmpty, name.count <= 128,
              try nodes(main, className: "sch-list-day").isEmpty,
              try nodes(main, className: "schcls-item").isEmpty else { return false }
        let metadata = try info(infos[0])
        guard let institute = metadata["учебное подразделение"], !institute.isEmpty,
              let courseText = metadata["курс"], let course = Int(courseText), (1...10).contains(course) else { return false }
        return (main.children ?? []).allSatisfy { child in
            child === infos[0] || child === paragraphs[0] ||
            (child.kind == .text && clean(child.stringValue ?? "").isEmpty) || child.kind == .comment
        }
    }

    private static func options(html: Data, container: String, pathComponent: String) throws -> [ISTUOption] {
        let document = try document(html)
        let containers = try nodes(document, className: container)
        guard containers.count == 1 else { throw ISTUParserError.invalidLayout("Не найден список подразделений или групп.") }
        var result: [ISTUOption] = []
        for anchor in descendants(containers[0], where: { $0.name == "a" && attribute($0, "href") != nil }) {
            guard let href = attribute(anchor, "href"), let id = linkedID(href, component: pathComponent) else { continue }
            let name = clean(anchor.stringValue ?? "")
            guard !name.isEmpty else { throw ISTUParserError.invalidLayout("Пустое название в списке.") }
            if let previous = result.first(where: { $0.id == id }) {
                guard previous.name == name else { throw ISTUParserError.invalidLayout("Повторный идентификатор с другим названием.") }
            } else { result.append(ISTUOption(id: id, name: name)) }
        }
        guard !result.isEmpty else { throw ISTUParserError.invalidLayout("Список пуст или его ссылки не распознаны.") }
        return result
    }

    private static func linkedID(_ href: String, component: String) -> String? {
        guard let url = URLComponents(string: href),
              url.scheme == nil || url.scheme?.lowercased() == "https",
              url.host == nil || url.host?.lowercased() == "www.istu.edu",
              url.query == nil, url.fragment == nil else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[0] == "raspisanie", parts[1] == component, numeric(parts[2]) else { return nil }
        return parts[2]
    }

    private static func info(_ document: XMLNode) throws -> [String: String] {
        var values: [String: String] = [:]
        for node in try nodes(document, className: "info-block-item") {
            let labels = try nodes(node, className: "info-block-item-label")
            let fields = try nodes(node, className: "info-block-item-value")
            guard labels.count == 1, fields.count == 1 else { continue }
            let label = clean(labels[0].stringValue ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            let value = clean(fields[0].stringValue ?? "")
            if let old = values[label], old != value { throw ISTUParserError.invalidLayout("Противоречивые сведения о неделе.") }
            values[label] = value
        }
        return values
    }

    private static func groupName(_ document: XMLNode) throws -> String? {
        let candidates = try descendants(document, where: { $0.name == "h1" }) + nodes(document, className: "info-block-header")
        for node in candidates {
            let text = clean(node.stringValue ?? "")
            if text.lowercased().hasPrefix("группа ") { return clean(String(text.dropFirst(7))) }
        }
        return nil
    }

    private static func coverage(metadata: [String: String], reference: Date) throws -> [CivilDay]? {
        let start = metadata["начало действия"]
        let end = metadata["окончание действия"]
        guard start != nil || end != nil else { return nil }
        guard let start, let end else { throw ISTUParserError.invalidLayout("Указана только одна граница расписания.") }
        let first = try parseDate(start, reference: reference)
        let last = try parseDate(end, reference: reference)
        let math = CalendarMath(timeZone: utc)
        guard let firstDate = first.date(in: utc), let lastDate = last.date(in: utc),
              let count = math.calendar.dateComponents([.day], from: firstDate, to: lastDate).day,
              (0...6).contains(count) else { throw ISTUParserError.invalidLayout("Неподдерживаемый диапазон недели.") }
        return (0...count).map { CivilDay(date: math.shifting(firstDate, by: $0, mode: .day), timeZone: utc) }
    }

    private static func parseDay(_ node: XMLNode, reference: Date) throws -> CivilDay {
        var candidates: [String] = []
        if let params = attribute(node, "data-params"), let value = capture(params, pattern: "['\"]date['\"]\\s*:\\s*['\"]([^'\"]+)['\"]") { candidates.append(value) }
        for header in try nodes(node, className: "sch-list-day-header") {
            if let id = attribute(header, "id"), id.hasPrefix("date-") { candidates.append(String(id.dropFirst(5))) }
        }
        if candidates.isEmpty, let header = try nodes(node, className: "sch-list-day-header").first {
            candidates.append(clean(header.stringValue ?? ""))
        }
        guard !candidates.isEmpty else { throw ISTUParserError.invalidLayout("У дня нет распознаваемой даты.") }
        let parsed = try candidates.map { try parseDate($0, reference: reference) }
        guard parsed.allSatisfy({ $0 == parsed[0] }) else { throw ISTUParserError.invalidLayout("Дата дня и заголовок не совпадают.") }
        return parsed[0]
    }

    /// A missing year is accepted only within the requested seven-day week. A
    /// nearest-year heuristic could silently overwrite a different year's lessons.
    private static func parseDate(_ raw: String, reference: Date) throws -> CivilDay {
        let value = clean(raw)
        let pattern = "^(\\d{1,2})[.](\\d{1,2})(?:[.](\\d{4}))?$"
        var components = captures(value, pattern: pattern)
        if components == nil {
            let months = ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря"]
            if let parts = captures(value.lowercased(), pattern: "(?:^|,\\s*)(\\d{1,2})\\s+([а-яё]+)(?:\\s+(\\d{4}))?$") {
                guard let month = months.firstIndex(of: parts[1]) else { throw ISTUParserError.invalidDate(value) }
                components = [parts[0], String(month + 1), parts[2]]
            }
        }
        guard let parts = components, let day = Int(parts[0]), let month = Int(parts[1]) else { throw ISTUParserError.invalidDate(value) }
        if let year = Int(parts[2]) {
            let result = CivilDay(year: year, month: month, day: day)
            guard result.isValid else { throw ISTUParserError.invalidDate(value) }
            return result
        }
        let matches = CalendarMath().weekDays(containing: reference).map { CivilDay(date: $0) }.filter { $0.day == day && $0.month == month }
        guard matches.count == 1 else { throw ISTUParserError.ambiguousYear(value) }
        return matches[0]
    }

    /// Follow the same selector as the official ScheduleClass.css. The site's
    /// visible "Показана неделя" text can contradict this class (12 October
    /// 2026 is labelled odd, but sch-list-week-even makes week-odd cards grey).
    /// Recomputing September/ISO parity would import those inactive alternatives.
    private static func renderedParity(_ week: XMLNode) throws -> Bool {
        let classes = classNames(week)
        let even = classes.contains("sch-list-week-even")
        let odd = classes.contains("sch-list-week-odd")
        guard even != odd else {
            throw ISTUParserError.invalidLayout("Не указан единственный активный вариант недели.")
        }
        return even
    }

    private static func isActive(_ card: XMLNode, parity: Bool) throws -> Bool {
        guard !classNames(card).contains("card-unactive") else { return false }
        var node = card.parent
        while let ancestor = node {
            let classes = classNames(ancestor)
            if classes.contains("sch-list-item-week") {
                guard classes.intersection(["week-all", "week-even", "week-odd"]).count == 1 else {
                    throw ISTUParserError.invalidLayout("Противоречивые варианты недель одной карточки.")
                }
                if classes.contains("week-all") { return true }
                if classes.contains("week-even") { return parity }
                if classes.contains("week-odd") { return !parity }
                throw ISTUParserError.invalidLayout("Не распознано чередование недель.")
            }
            if classes.contains("sch-list-item") { break }
            node = ancestor.parent
        }
        return true
    }

    private static func startMinute(_ slot: XMLNode) throws -> Int {
        var values: [String] = []
        if let params = attribute(slot, "data-params"), let value = capture(params, pattern: "['\"]time['\"]\\s*:\\s*['\"]([^'\"]+)['\"]") { values.append(value) }
        values += try nodes(slot, className: "sch-list-item-time-inner").map { clean($0.stringValue ?? "") }
        guard !values.isEmpty else { throw ISTUParserError.invalidTime("не указано") }
        let minutes = try values.map { value -> Int in
            guard let parts = captures(value, pattern: "^(\\d{1,2}):(\\d{2})(?:\\s*[–—-]\\s*\\d{1,2}:\\d{2})?$"),
                  let hour = Int(parts[0]), let minute = Int(parts[1]), (0...23).contains(hour), (0...59).contains(minute) else { throw ISTUParserError.invalidTime(value) }
            return hour * 60 + minute
        }
        guard minutes.allSatisfy({ $0 == minutes[0] }) else { throw ISTUParserError.invalidTime(values.joined(separator: ", ")) }
        return minutes[0]
    }

    private static func targetSubgroups(_ card: XMLNode, groupID: String) throws -> [String?] {
        let fields = try nodes(card, className: "schcls-item-group")
        guard fields.count == 1 else { throw ISTUParserError.invalidLayout("У карточки нет блока группы.") }
        var found: [String?] = []
        for anchor in descendants(fields[0], where: { $0.name == "a" && attribute($0, "href") != nil }) {
            guard let href = attribute(anchor, "href"), linkedID(href, component: "grup") == groupID else { continue }
            var trailing = ""
            var sibling = anchor.nextSibling
            while let node = sibling, node.name != "a" {
                trailing += " " + (node.stringValue ?? "")
                sibling = node.nextSibling
            }
            let suffix = clean(trailing)
            let rawSubgroups = capture(suffix, pattern: "(?i)подгрупп[аы]\\s*[:№]?\\s*([0-9]+(?:\\s*(?:[,/;&]|или|и)\\s*[0-9]+)*)\\s*[,;]?\\s*$")
            if let rawSubgroups {
                for subgroup in ISTUSubgroupOptions.values(from: [rawSubgroups.lowercased()]) {
                    if !found.contains(where: { $0 == subgroup }) { found.append(subgroup) }
                }
            } else {
                guard !suffix.lowercased().contains("подгрупп") else {
                    throw ISTUParserError.invalidLayout("Не распознан номер подгруппы.")
                }
                if !found.contains(where: { $0 == nil }) { found.append(nil) }
            }
        }
        guard !found.isEmpty else { throw ISTUParserError.invalidLayout("Карточка относится к другой или неизвестной группе.") }
        return found
    }

    private static func nodes(_ node: XMLNode, className: String) throws -> [XMLNode] {
        descendants(node, where: { classNames($0).contains(className) })
    }
    private static func descendants(_ node: XMLNode, where predicate: (XMLNode) -> Bool) -> [XMLNode] {
        // Bound traversal to real children. Some Foundation HTML-tidy versions make
        // descendant-axis XPath on a subtree include its following HTML siblings.
        var result: [XMLNode] = []
        var pending = Array((node.children ?? []).reversed())
        while let child = pending.popLast() {
            if predicate(child) { result.append(child) }
            pending.append(contentsOf: (child.children ?? []).reversed())
        }
        return result
    }
    private static func attribute(_ node: XMLNode, _ name: String) -> String? { (node as? XMLElement)?.attribute(forName: name)?.stringValue }
    private static func classNames(_ node: XMLNode) -> Set<String> { Set((attribute(node, "class") ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init)) }
    private static func clean(_ value: String) -> String { value.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ") }
    private static func requiredText(_ node: XMLNode, className: String) throws -> String {
        let value = try optionalText(node, className: className)
        guard !value.isEmpty else { throw ISTUParserError.invalidLayout("Отсутствует название предмета.") }
        return value
    }
    private static func optionalText(_ node: XMLNode, className: String) throws -> String {
        let fields = try nodes(node, className: className)
        guard fields.count <= 1 else { throw ISTUParserError.invalidLayout("Повторяющееся поле карточки.") }
        return clean(fields.first?.stringValue ?? "")
    }
    private static func numeric(_ value: String) -> Bool { !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) } }
    private static func dayLess(_ lhs: CivilDay, _ rhs: CivilDay) -> Bool { (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day) }
    private static func capture(_ text: String, pattern: String) -> String? { captures(text, pattern: pattern)?.first }
    private static func captures(_ text: String, pattern: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern), let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in Range(match.range(at: index), in: text).map { String(text[$0]) } ?? "" }
    }
}
