import Foundation

extension CodingUserInfoKey {
    static let plannerSchemaVersion = CodingUserInfoKey(rawValue: "planner.schemaVersion")!
}

enum CalendarMode: String, CaseIterable, Identifiable, Sendable {
    case month
    case week
    case day

    var id: String { rawValue }

    var title: String {
        switch self {
        case .month: "Месяц"
        case .week: "Неделя"
        case .day: "День"
        }
    }
}

/// A task belongs to a civil date, not to an instant on a timeline. Keeping these
/// components makes an all-day task stay on 15 October when the Mac changes zone.
struct CivilDay: Codable, Equatable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(date: Date, timeZone: TimeZone = .current) {
        let components = CalendarMath(timeZone: timeZone).calendar.dateComponents([.year, .month, .day, .era], from: date)
        year = components.era == 1 ? components.year ?? 0 : 0
        month = components.month ?? 0
        day = components.day ?? 0
    }

    var isValid: Bool {
        // Validation is independent of the current zone, including historical zones
        // that have skipped an entire civil day when crossing the date line.
        date(in: TimeZone(secondsFromGMT: 0)!) != nil
    }

    func date(in timeZone: TimeZone) -> Date? {
        CalendarMath(timeZone: timeZone).date(day: day, month: month, year: year)
    }
}

struct PlannerTask: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    private(set) var civilDay: CivilDay
    var groupID: UUID?
    var note: String
    var isCompleted: Bool
    var createdAt: Date

    var date: Date {
        get {
            // A historical civil day may not exist in a particular time zone. The
            // canonical components remain intact; filtering uses civilDay directly.
            civilDay.date(in: .current)
                ?? civilDay.date(in: TimeZone(secondsFromGMT: 0)!)
                ?? Date(timeIntervalSinceReferenceDate: .nan)
        }
        set { civilDay = CivilDay(date: newValue) }
    }

    func date(in timeZone: TimeZone) -> Date? { civilDay.date(in: timeZone) }

    init(
        id: UUID = UUID(), title: String, date: Date, groupID: UUID? = nil,
        note: String = "", isCompleted: Bool = false, createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.civilDay = CivilDay(date: date)
        self.groupID = groupID
        self.note = note
        self.isCompleted = isCompleted
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, day, date, groupID, note, isCompleted, createdAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        if let day = try values.decodeIfPresent(CivilDay.self, forKey: .day) {
            civilDay = day
        } else {
            guard (decoder.userInfo[.plannerSchemaVersion] as? Int ?? 1) < 2 else {
                throw DecodingError.keyNotFound(CodingKeys.day, DecodingError.Context(codingPath: values.codingPath, debugDescription: "В формате 2 отсутствуют компоненты даты дела."))
            }
            // Version 1 stored a local-midnight timestamp. Its original zone was not
            // recorded, so migrate it once using the zone in effect during this load.
            let legacyDate = try values.decode(Date.self, forKey: .date)
            guard CalendarMath().isSupported(legacyDate) else {
                throw DecodingError.dataCorruptedError(forKey: .date, in: values, debugDescription: "Дата дела вне допустимого диапазона.")
            }
            civilDay = CivilDay(date: legacyDate)
        }
        guard civilDay.isValid else {
            throw DecodingError.dataCorruptedError(forKey: .day, in: values, debugDescription: "Некорректная календарная дата дела.")
        }
        groupID = try values.decodeIfPresent(UUID.self, forKey: .groupID)
        note = try values.decode(String.self, forKey: .note)
        isCompleted = try values.decode(Bool.self, forKey: .isCompleted)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(title, forKey: .title)
        try values.encode(civilDay, forKey: .day)
        try values.encodeIfPresent(groupID, forKey: .groupID)
        try values.encode(note, forKey: .note)
        try values.encode(isCompleted, forKey: .isCompleted)
        try values.encode(createdAt, forKey: .createdAt)
    }
}

struct TaskGroup: Codable, Identifiable, Equatable, Sendable {
    /// Navigation-only item. Its reserved ID is never written as a task's group.
    static let ungrouped = TaskGroup(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
        name: "Без группы", colorHex: "#7A7D85"
    )

    var id: UUID
    var name: String
    var colorHex: String

    var isUngrouped: Bool { id == Self.ungrouped.id }
    var taskGroupID: UUID? { isUngrouped ? nil : id }

    init(id: UUID = UUID(), name: String, colorHex: String) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
    }
}

enum DataStoreError: LocalizedError {
    case emptyTitle
    case emptyGroupName
    case invalidColor
    case invalidDate
    case taskNotFound
    case groupNotFound
    case unsupportedSchema(Int)
    case invalidContents(String)
    case storageUnavailable(String)
    case readFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyTitle: "Введите название дела."
        case .emptyGroupName: "Введите название группы."
        case .invalidColor: "Выберите корректный цвет группы."
        case .invalidDate: "Выберите корректную дату."
        case .taskNotFound: "Дело больше не существует. Обновите список."
        case .groupNotFound: "Группа больше не существует. Выберите другую группу."
        case .unsupportedSchema(let version):
            "Данные сохранены в неподдерживаемой версии формата (\(version)). Файлы сохранены без изменений."
        case .invalidContents(let reason): "Файл данных повреждён: \(reason)"
        case .storageUnavailable(let reason): "Локальное хранилище недоступно. \(reason)"
        case .readFailed(let reason): "Не удалось прочитать локальные данные. \(reason)"
        case .writeFailed(let reason): "Не удалось сохранить изменения. \(reason)"
        }
    }
}
