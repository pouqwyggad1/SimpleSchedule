import Foundation

struct PlannerPreferences: Codable, Equatable, Sendable {
    var instituteId: String? = nil
    var groupId: String? = nil
    var subgroup: String? = nil
    var durationMinutes = 90
    var refreshMode = "manual"
    var refreshIntervalHours = 1
    var notificationsEnabled = false
    var beforeLessonEnabled = true
    var scheduleChangesEnabled = true
    var leadMinutes = 5
    var mutedSubjects: [String] = []
    var mutedDates: [String] = []

    var fields: CloudFields {
        ["instituteId": .optional(instituteId), "groupId": .optional(groupId), "subgroup": .optional(subgroup),
         "durationMinutes": .number(Int64(durationMinutes)), "refreshMode": .text(refreshMode),
         "refreshIntervalHours": .number(Int64(refreshIntervalHours)), "notificationsEnabled": .bool(notificationsEnabled),
         "beforeLessonEnabled": .bool(beforeLessonEnabled), "scheduleChangesEnabled": .bool(scheduleChangesEnabled),
         "leadMinutes": .number(Int64(leadMinutes)), "mutedSubjects": .array(mutedSubjects.map(CloudValue.text)),
         "mutedDates": .array(mutedDates.map(CloudValue.text))]
    }
    init() {}
    init(fields: CloudFields) throws {
        let data = try JSONEncoder().encode(CloudValue.object(PlannerPreferences().fields.merging(fields) { _, incoming in incoming }))
        self = try JSONDecoder().decode(Self.self, from: data)
        guard (1...360).contains(durationMinutes), ["manual", "auto"].contains(refreshMode),
              [1, 3, 6].contains(refreshIntervalHours), (1...1440).contains(leadMinutes),
              mutedSubjects.count <= 1000, mutedDates.count <= 1000,
              mutedDates.allSatisfy({ CloudMapping.day($0) != nil }) else { throw CloudError.message("Неподходящие настройки в облаке.") }
    }
    static func subjectKey(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    func allows(_ lesson: UniversityLesson, includeCancelled: Bool = false) -> Bool {
        var visible = lesson
        if includeCancelled { visible.sourceCancelled = false }
        return notificationsEnabled && (includeCancelled || !lesson.sourceCancelled) && ScheduleImportFilter(groupID: groupId, subgroup: subgroup).includes(visible) &&
        !mutedSubjects.contains(Self.subjectKey(lesson.subject)) && !mutedDates.contains(CloudMapping.date(lesson.civilDay))
    }
}
