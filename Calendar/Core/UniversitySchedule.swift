import Foundation

/// University lessons are independent of task groups and completion state.
/// Wall-clock minutes and a civil date preserve the timetable on time-zone changes.
struct UniversityLesson: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var subject: String
    var civilDay: CivilDay
    var startMinute: Int
    var endMinute: Int
    var homework: String
    var room: String
    var teacher: String
    var kind: String = ""
    var subgroup: String? = nil
    var istuOrigin: ISTULessonOrigin? = nil
    var sourceCancelled: Bool = false
    var cloudID: String? = nil

    init(id: UUID = UUID(), subject: String, civilDay: CivilDay, startMinute: Int, endMinute: Int,
         homework: String, room: String, teacher: String, kind: String = "", subgroup: String? = nil,
         istuOrigin: ISTULessonOrigin? = nil) {
        self.id = id; self.subject = subject; self.civilDay = civilDay
        self.startMinute = startMinute; self.endMinute = endMinute; self.homework = homework
        self.room = room; self.teacher = teacher; self.kind = kind; self.subgroup = subgroup; self.istuOrigin = istuOrigin
    }

    private enum CodingKeys: String, CodingKey {
        case id, subject, civilDay, startMinute, endMinute, homework, room, teacher, kind, subgroup, istuOrigin, sourceCancelled, cloudID
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        subject = try values.decode(String.self, forKey: .subject)
        civilDay = try values.decode(CivilDay.self, forKey: .civilDay)
        startMinute = try values.decode(Int.self, forKey: .startMinute)
        endMinute = try values.decode(Int.self, forKey: .endMinute)
        homework = try values.decode(String.self, forKey: .homework)
        room = try values.decode(String.self, forKey: .room)
        teacher = try values.decode(String.self, forKey: .teacher)
        kind = try values.decodeIfPresent(String.self, forKey: .kind) ?? ""
        subgroup = try values.decodeIfPresent(String.self, forKey: .subgroup)
        istuOrigin = try values.decodeIfPresent(ISTULessonOrigin.self, forKey: .istuOrigin)
        sourceCancelled = try values.decodeIfPresent(Bool.self, forKey: .sourceCancelled) ?? false
        cloudID = try values.decodeIfPresent(String.self, forKey: .cloudID)
    }

    var date: Date {
        civilDay.date(in: .current) ?? civilDay.date(in: TimeZone(secondsFromGMT: 0)!)!
    }
    var isValid: Bool {
        !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && civilDay.isValid &&
        (0..<1440).contains(startMinute) && (1...1440).contains(endMinute) && startMinute < endMinute
    }
    var timeRange: String { "\(Self.time(startMinute))–\(Self.time(endMinute))" }
    static func time(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }
    static func lessonCountText(_ count: Int) -> String {
        let tens = count % 100
        let word: String
        if (11...14).contains(tens) { word = "пар" }
        else {
            word = switch count % 10 {
            case 1: "пара"
            case 2...4: "пары"
            default: "пар"
            }
        }
        return "\(count) \(word)"
    }
    static func summary(_ lessons: [UniversityLesson]) -> String? {
        guard let start = lessons.map(\.startMinute).min(), let end = lessons.map(\.endMinute).max() else { return nil }
        return "\(lessonCountText(lessons.count))\nс \(time(start)) до \(time(end))"
    }
}

struct ISTULessonFields: Codable, Equatable, Sendable {
    var subject: String
    var civilDay: CivilDay
    var startMinute: Int
    var endMinute: Int
    var kind: String
    var room: String
    var teacher: String
    var subgroup: String?

    init(_ lesson: UniversityLesson) {
        subject = lesson.subject; civilDay = lesson.civilDay; startMinute = lesson.startMinute
        endMinute = lesson.endMinute; kind = lesson.kind; room = lesson.room
        teacher = lesson.teacher; subgroup = lesson.subgroup
    }
}

struct ISTULessonOrigin: Codable, Equatable, Sendable {
    var groupID: String
    var sourceID: String
    var original: ISTULessonFields

    var key: String { "\(groupID)|\(WidgetDeepLink.dayString(original.civilDay))|\(sourceID)" }
}

struct ScheduleImportFilter: Equatable, Sendable {
    var groupID: String?
    var subgroup: String?

    func includes(_ lesson: UniversityLesson) -> Bool {
        guard !lesson.sourceCancelled else { return false }
        if let origin = lesson.istuOrigin, origin.groupID != groupID { return false }
        guard let selected = subgroup?.trimmingCharacters(in: .whitespacesAndNewlines), !selected.isEmpty,
              let lessonSubgroup = lesson.subgroup?.trimmingCharacters(in: .whitespacesAndNewlines), !lessonSubgroup.isEmpty else { return true }
        if selected.localizedCaseInsensitiveCompare(lessonSubgroup) == .orderedSame { return true }
        let parts = lessonSubgroup.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return parts.contains { $0.localizedCaseInsensitiveCompare(selected) == .orderedSame }
    }
}

struct ISTUImportResult: Equatable, Sendable {
    var added = 0
    var updated = 0
    var removed = 0
    var preserved = 0
}

enum LessonValidationError: LocalizedError {
    case emptySubject, invalidTime, notFound
    var errorDescription: String? {
        switch self {
        case .emptySubject: "Введите название предмета."
        case .invalidTime: "Время окончания должно быть позже начала в пределах одного дня."
        case .notFound: "Занятие больше не существует."
        }
    }
}
