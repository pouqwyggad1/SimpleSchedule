import Foundation

/// Shared, deterministic notification rules. No notification permission or networking here.
enum NotificationPlan {
    static let timeZone = TimeZone(identifier: "Asia/Irkutsk")!
    struct Reminder: Equatable, Sendable {
        let id: String
        let day: CivilDay
        let fire: Date
        let title: String
        let body: String
    }
    static func start(_ lesson: UniversityLesson) -> Date? {
        lesson.civilDay.date(in: timeZone)?.addingTimeInterval(Double(lesson.startMinute * 60))
    }
    static func details(_ lesson: UniversityLesson) -> String {
        "Аудитория: \(lesson.room.isEmpty ? "не указана" : lesson.room). Преподаватель: \(lesson.teacher.isEmpty ? "не указан" : lesson.teacher). Вид занятия: \(lesson.kind.isEmpty ? "не указан" : lesson.kind)."
    }
    static func reminders(_ lessons: [UniversityLesson], preferences: PlannerPreferences, now: Date, delivered: Set<String>) -> [Reminder] {
        guard preferences.beforeLessonEnabled else { return [] }
        return lessons.compactMap { lesson -> Reminder? in
            guard preferences.allows(lesson), let start = start(lesson), start > now else { return nil }
            let fire = start.addingTimeInterval(-Double(preferences.leadMinutes * 60))
            let id = "SimpleSchedule.before.\(lesson.id.uuidString).\(CloudMapping.date(lesson.civilDay)).\(lesson.startMinute)"
            guard fire > now, !delivered.contains(id) else { return nil }
            return Reminder(id: id, day: lesson.civilDay, fire: fire,
                title: "Через \(preferences.leadMinutes) мин — \(lesson.subject)", body: details(lesson))
        }.sorted { $0.fire == $1.fire ? $0.id < $1.id : $0.fire < $1.fire }.prefix(60).map { $0 }
    }
    /// Source baselines distinguish a university update from personal homework/field edits.
    static func sourceChanges(old: [UniversityLesson], new: [UniversityLesson], preferences: PlannerPreferences, now: Date) -> [UniversityLesson] {
        guard preferences.scheduleChangesEnabled, !old.isEmpty else { return [] }
        let previous = Dictionary(old.filter { $0.istuOrigin != nil }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return new.compactMap { current in
            guard let origin = current.istuOrigin else {
                // A cancelled class with personal edits is retained as a manual class.
                guard let previous = previous[current.id], previous.istuOrigin != nil else { return nil }
                var cancelled = current; cancelled.sourceCancelled = true
                guard preferences.allows(cancelled, includeCancelled: true), start(cancelled).map({ $0 > now }) == true else { return nil }
                return cancelled
            }
            guard previous[current.id]?.istuOrigin?.original != origin.original || previous[current.id]?.sourceCancelled != current.sourceCancelled,
                  preferences.allows(current, includeCancelled: true), start(current).map({ $0 > now }) == true else { return nil }
            return current
        }
    }
}
