import Foundation

struct ISTUOption: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

struct ISTUParsedLesson: Codable, Equatable, Sendable {
    let sourceID: String
    let day: CivilDay
    let startMinute: Int
    let subject: String
    /// Keep the site's literal description, including previously unknown kinds.
    let kind: String
    let teacher: String
    let subgroup: String?
    let room: String
}

struct ISTUSchedulePage: Codable, Equatable, Sendable {
    let lessons: [ISTUParsedLesson]
    let coveredDays: [CivilDay]
    let groupName: String?
    /// Discovered from every source alternative, independently of the visible week.
    let subgroups: [String]

    init(lessons: [ISTUParsedLesson], coveredDays: [CivilDay], groupName: String?, subgroups: [String] = []) {
        self.lessons = lessons; self.coveredDays = coveredDays; self.groupName = groupName
        self.subgroups = ISTUSubgroupOptions.values(from: subgroups)
    }
}

enum ISTUSubgroupOptions {
    static func values(from labels: [String]) -> [String] {
        var values: [String: String] = [:]
        for label in labels {
            let separated = label.replacingOccurrences(of: #"(?<=[0-9])\s*(?:или|и)\s*(?=[0-9])|[,;/&]"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            for part in separated.components(separatedBy: .newlines) {
                let value = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                values[value.lowercased()] = value
            }
        }
        return values.values.sorted { $0.compare($1, options: [.numeric, .caseInsensitive]) == .orderedAscending }
    }
}

enum ISTUParserError: LocalizedError {
    case noPublishedSchedule
    case invalidHTML
    case invalidLayout(String)
    case invalidDate(String)
    case ambiguousYear(String)
    case invalidTime(String)

    var errorDescription: String? {
        switch self {
        case .noPublishedSchedule: "На сайте ИРНИТУ нет опубликованного расписания для выбранного периода. Сохранённые занятия не изменены."
        case .invalidHTML: "Страница ИРНИТУ не распознана как безопасный HTML. Сохранённые занятия не изменены."
        case .invalidLayout(let reason): "Структура страницы расписания ИРНИТУ изменилась. \(reason)"
        case .invalidDate(let value): "На странице ИРНИТУ указана некорректная дата: \(value)."
        case .ambiguousYear(let value): "Не удалось однозначно определить год даты \(value) в запрошенной неделе."
        case .invalidTime(let value): "На странице ИРНИТУ указано некорректное время: \(value)."
        }
    }
}
