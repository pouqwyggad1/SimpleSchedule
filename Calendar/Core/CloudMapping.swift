import CryptoKit
import Foundation

/// Lossless wire IDs for the existing PWA, mapped to stable UUIDs for native views/widget.
enum CloudMapping {
    static func uuid(_ id: String) -> UUID {
        if let value = UUID(uuidString: id) { return value }
        let bytes = Array(SHA256.hash(data: Data(("SimpleSchedule.PWA:" + id).utf8)).prefix(16))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    static func date(_ day: CivilDay) -> String { String(format: "%04d-%02d-%02d", day.year, day.month, day.day) }
    static func day(_ text: String) -> CivilDay? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard text.count == 10, parts.count == 3 else { return nil }
        let result = CivilDay(year: parts[0], month: parts[1], day: parts[2]); return result.isValid && date(result) == text ? result : nil
    }
    static func lessonFields(_ fields: ISTULessonFields) -> CloudFields {
        ["date": .text(date(fields.civilDay)), "startMinute": .number(Int64(fields.startMinute)), "endMinute": .number(Int64(fields.endMinute)),
         "subject": .text(fields.subject), "kind": .text(fields.kind), "teacher": .text(fields.teacher), "room": .text(fields.room), "subgroup": .optional(fields.subgroup)]
    }
    static func entities(_ snapshot: NativePlannerSnapshot, preferences: PlannerPreferences, known: [CloudEntity] = []) throws -> [CloudEntity] {
        guard Set(known.map { uuid($0.id) }).count == known.count else { throw CloudError.message("В облаке есть несовместимые идентификаторы. Локальная копия сохранена.") }
        let ids = Dictionary(uniqueKeysWithValues: known.map { (uuid($0.id), $0.id) })
        func id(_ value: UUID) -> String { ids[value] ?? value.uuidString.lowercased() }
        var values = snapshot.groups.map { CloudEntity(id: id($0.id), kind: "group", data: ["name": .text($0.name), "color": .text($0.colorHex)], version: 0, deleted: false) }
        values += snapshot.tasks.map { CloudEntity(id: id($0.id), kind: "task", data: ["title": .text($0.title), "date": .text(date($0.civilDay)), "groupId": $0.groupID.map { .text(id($0)) } ?? .null,
            "note": .text($0.note), "completed": .bool($0.isCompleted)], version: 0, deleted: false) }
        values += snapshot.lessons.map { lesson in
            var fields = lessonFields(ISTULessonFields(lesson)); fields["homework"] = .text(lesson.homework)
            var key = lesson.cloudID ?? id(lesson.id)
            if let origin = lesson.istuOrigin {
                key = lesson.cloudID ?? ids[lesson.id] ?? "source:\(origin.groupID):\(origin.sourceID)"
                fields["sourceId"] = .text(origin.sourceID); fields["sourceGroupId"] = .text(origin.groupID)
                var baseline = lessonFields(origin.original); baseline["sourceId"] = .text(origin.sourceID); baseline["sourceGroupId"] = .text(origin.groupID)
                fields["sourceBaseline"] = .object(baseline); fields["sourceCancelled"] = .bool(lesson.sourceCancelled)
            }
            return CloudEntity(id: key, kind: "lesson", data: fields, version: 0, deleted: false)
        }
        for key in snapshot.deletedISTULessonKeys {
            let parts = key.split(separator: "|", maxSplits: 2).map(String.init)
            guard parts.count == 3, let civil = day(parts[1]) else { throw CloudError.message("Неподходящая отметка удалённого занятия.") }
            let existing = known.first { $0.kind == "lesson" && $0.data["sourceGroupId"]?.string == parts[0] && $0.data["sourceId"]?.string == parts[2] }
            let sourceID = existing?.id ?? "source:\(parts[0]):\(parts[2])"
            guard !values.contains(where: { $0.id == sourceID }) else { continue }
            var fields = existing?.data ?? lessonFields(ISTULessonFields(UniversityLesson(subject: "Удалённое занятие", civilDay: civil, startMinute: 0, endMinute: 1, homework: "", room: "", teacher: "")))
            fields["sourceId"] = .text(parts[2]); fields["sourceGroupId"] = .text(parts[0])
            // New hidden IDs need a create/delete sequence on the existing server.
            // Its transient creation must neither schedule reminders nor announce a fake source change.
            if existing == nil { fields["sourceCancelled"] = .bool(true); fields.removeValue(forKey: "sourceBaseline") }
            else if fields["sourceBaseline"] == nil { fields["sourceBaseline"] = .object(fields) }
            values.append(CloudEntity(id: sourceID, kind: "lesson", data: fields, version: existing?.version ?? 0, deleted: true))
        }
        values.append(CloudEntity(id: "preferences", kind: "preferences", data: preferences.fields, version: 0, deleted: false))
        guard Set(values.map(\.id)).count == values.count else { throw CloudError.message("Повторяющиеся идентификаторы записей для облака.") }
        for record in values {
            for (field, limit) in [("title",500),("subject",500),("note",20000),("homework",20000),("teacher",500),("room",200),("kind",100),("name",120),("subgroup",50)] {
                if let text = record.data[field]?.string, text.utf16.count > limit { throw CloudError.message("Поле «\(field)» слишком длинное для синхронизации (максимум \(limit)). Локальные данные сохранены.") }
            }
        }
        try validate(values)
        return values
    }
    static func validate(_ entities: [CloudEntity]) throws {
        guard entities.count <= 100000, Set(entities.map(\.id)).count == entities.count,
              Set(entities.map { uuid($0.id) }).count == entities.count,
              entities.allSatisfy({ !$0.id.isEmpty && $0.id.utf16.count <= 200 && $0.version >= 0 && ["task", "group", "lesson", "preferences"].contains($0.kind) && ($0.kind != "preferences" || $0.id == "preferences") }) else { throw CloudError.message("Неподходящие идентификаторы облачных записей.") }
        for record in entities where !record.deleted {
            for (field, limit) in [("title",500),("subject",500),("note",20000),("homework",20000),("teacher",500),("room",200),("kind",100),("name",120),("subgroup",50),("sourceId",200),("sourceGroupId",12)] {
                if let text = record.data[field]?.string, text.utf16.count > limit { throw CloudError.message("Слишком длинное поле в облачной записи: \(field).") }
            }
            if record.kind == "preferences" { _ = try PlannerPreferences(fields: record.data) }
        }
    }
    static func snapshot(_ entities: [CloudEntity], preserving local: NativePlannerSnapshot? = nil) throws -> NativePlannerSnapshot {
        try validate(entities)
        let active = entities.filter { !$0.deleted }
        let groups = try active.filter { $0.kind == "group" }.map { record -> TaskGroup in
            guard let name = record.data["name"]?.string, let color = record.data["color"]?.string, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, color.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else { throw CloudError.message("Некорректная группа в облаке.") }
            return TaskGroup(id: uuid(record.id), name: name, colorHex: color)
        }
        let groupIDs = Set(groups.map(\.id))
        let tasks = try active.filter { $0.kind == "task" }.map { record -> PlannerTask in
            guard let title = record.data["title"]?.string, let day = day(record.data["date"]?.string ?? ""),
                  let completed = record.data["completed"]?.flag, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudError.message("Некорректное дело в облаке.") }
            let group = record.data["groupId"]?.string.map(uuid)
            return PlannerTask(id: uuid(record.id), title: title, civilDay: day, groupID: group.flatMap { groupIDs.contains($0) ? $0 : nil },
                note: record.data["note"]?.string ?? "", isCompleted: completed,
                createdAt: local?.tasks.first(where: { $0.id == uuid(record.id) })?.createdAt ?? Date(timeIntervalSince1970: Double(record.version)))
        }
        func lesson(_ fields: CloudFields, id: UUID) throws -> UniversityLesson {
            guard let subject = fields["subject"]?.string, let civil = day(fields["date"]?.string ?? ""),
                  let start = fields["startMinute"]?.int, let end = fields["endMinute"]?.int else { throw CloudError.message("Некорректная пара в облаке.") }
            let value = UniversityLesson(id: id, subject: subject, civilDay: civil, startMinute: start, endMinute: end, homework: fields["homework"]?.string ?? "",
                room: fields["room"]?.string ?? "", teacher: fields["teacher"]?.string ?? "", kind: fields["kind"]?.string ?? "", subgroup: fields["subgroup"]?.string)
            guard value.isValid else { throw CloudError.message("Некорректное время занятия в облаке.") }; return value
        }
        let lessons = try active.filter { $0.kind == "lesson" }.map { record in
            let existing = local?.lessons.first { value in
                value.cloudID == record.id || value.id == uuid(record.id) || value.istuOrigin.map { "source:\($0.groupID):\($0.sourceID)" == record.id } == true
            }
            var value = try lesson(record.data, id: existing?.id ?? uuid(record.id))
            value.cloudID = record.id
            if let source = record.data["sourceId"]?.string, let group = record.data["sourceGroupId"]?.string {
                let baseline = record.data["sourceBaseline"]?.fields ?? record.data
                value.istuOrigin = ISTULessonOrigin(groupID: group, sourceID: source, original: ISTULessonFields(try lesson(baseline, id: value.id)))
                value.sourceCancelled = record.data["sourceCancelled"]?.flag ?? false
            }
            return value
        }
        let deleted = entities.filter { $0.deleted && $0.kind == "lesson" }.compactMap { record -> String? in
            guard let source = record.data["sourceId"]?.string, let group = record.data["sourceGroupId"]?.string,
                  let day = day(record.data["sourceBaseline"]?.fields?["date"]?.string ?? record.data["date"]?.string ?? "") else { return nil }
            return "\(group)|\(date(day))|\(source)"
        }
        return NativePlannerSnapshot(tasks: tasks, groups: groups, lessons: lessons, deletedISTULessonKeys: Array(Set(deleted)).sorted())
    }
}
