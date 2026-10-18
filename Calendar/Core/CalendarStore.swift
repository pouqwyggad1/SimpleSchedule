import Foundation
import Observation

/// Each mutation locks the common container, rereads the latest revision, and
/// publishes only after atomic persistence. Stale processes cannot lose updates.
@MainActor @Observable
final class CalendarStore {
    private(set) var tasks: [PlannerTask] = []
    private(set) var groups: [TaskGroup] = []
    private(set) var lessons: [UniversityLesson] = []
    private(set) var isAvailable = false
    var importFilter: ScheduleImportFilter?
    var errorMessage: String?

    @ObservationIgnored private let storage: SharedPlannerStorage?
    @ObservationIgnored var onCommit: (() -> Void)?

    private struct Document: Codable {
        var schemaVersion: Int
        var tasks: [PlannerTask]
        var groups: [TaskGroup]
        var lessons: [UniversityLesson]
        var deletedISTULessonKeys: [String]

        init(schemaVersion: Int = 4, tasks: [PlannerTask] = [], groups: [TaskGroup] = [], lessons: [UniversityLesson] = [], deletedISTULessonKeys: [String] = []) {
            self.schemaVersion = schemaVersion; self.tasks = tasks; self.groups = groups; self.lessons = lessons
            self.deletedISTULessonKeys = deletedISTULessonKeys
        }
        private enum CodingKeys: String, CodingKey { case schemaVersion, tasks, groups, lessons, deletedISTULessonKeys }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
            tasks = try values.decode([PlannerTask].self, forKey: .tasks)
            groups = try values.decode([TaskGroup].self, forKey: .groups)
            lessons = schemaVersion < 3 ? [] : try values.decode([UniversityLesson].self, forKey: .lessons)
            deletedISTULessonKeys = schemaVersion < 4 ? [] : try values.decode([String].self, forKey: .deletedISTULessonKeys)
        }
    }

    private struct Snapshot {
        let document: Document
        let bytes: Data?
        let warning: String?
    }

    init(directory: URL? = nil) {
        do {
            if let directory {
                storage = SharedPlannerStorage(directory: directory)
            } else {
                storage = try SharedPlannerStorage.resolve(for: .current())
            }
        } catch {
            storage = nil
            errorMessage = error.localizedDescription
            return
        }
        reloadFromDisk()
    }

    init(storage: SharedPlannerStorage) {
        self.storage = storage
        reloadFromDisk()
    }

    var cloudDirectory: URL? { storage?.directory.appendingPathComponent("Cloud", isDirectory: true) }

    func plannerSnapshot() throws -> NativePlannerSnapshot {
        guard let storage else { throw DataStoreError.storageUnavailable("Локальное хранилище недоступно.") }
        return try storage.withExclusiveAccess {
            let document = try readSnapshot(in: storage).document
            return NativePlannerSnapshot(tasks: document.tasks, groups: document.groups, lessons: document.lessons,
                deletedISTULessonKeys: document.deletedISTULessonKeys)
        }
    }

    /// Used only after a validated cloud projection or an explicit backup/account switch.
    func replacePlanner(with snapshot: NativePlannerSnapshot) throws {
        try commit { document in
            document.tasks = snapshot.tasks; document.groups = snapshot.groups; document.lessons = snapshot.lessons
            document.deletedISTULessonKeys = snapshot.deletedISTULessonKeys
        }
    }

    /// Failed refreshes retain the visible snapshot but mark it unavailable.
    /// A widget must check isAvailable before treating an empty array as valid.
    func reloadFromDisk() {
        guard let storage else { return }
        do {
            let snapshot = try storage.withExclusiveAccess { try readSnapshot(in: storage) }
            publish(snapshot)
        } catch {
            isAvailable = false
            errorMessage = error.localizedDescription
        }
    }

    func tasks(on date: Date) -> [PlannerTask] {
        let selectedDay = CivilDay(date: date)
        return tasks.filter { $0.civilDay == selectedDay }.sorted {
            if $0.isCompleted != $1.isCompleted { return !$0.isCompleted }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// nil selects the virtual «Без группы» page; its UI identifier is never stored.
    func tasks(in groupID: UUID?) -> [PlannerTask] {
        tasks.filter { $0.groupID == groupID }.sorted {
            if $0.isCompleted != $1.isCompleted { return !$0.isCompleted }
            let lhs = $0.civilDay
            let rhs = $1.civilDay
            if lhs.year != rhs.year { return lhs.year < rhs.year }
            if lhs.month != rhs.month { return lhs.month < rhs.month }
            if lhs.day != rhs.day { return lhs.day < rhs.day }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    func groups(on date: Date) -> [TaskGroup] {
        let identifiers = Set(tasks(on: date).compactMap(\.groupID))
        return groups.filter { identifiers.contains($0.id) }
    }

    func group(id: UUID?) -> TaskGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }

    func lessons(on date: Date) -> [UniversityLesson] {
        let day = CivilDay(date: date)
        return lessons.filter { $0.civilDay == day && !$0.sourceCancelled && (importFilter?.includes($0) ?? true) }.sorted {
            if $0.startMinute != $1.startMinute { return $0.startMinute < $1.startMinute }
            if $0.endMinute != $1.endMinute { return $0.endMinute < $1.endMinute }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    @discardableResult
    func saveLesson(id: UUID? = nil, subject: String, date: Date, startMinute: Int, endMinute: Int,
                    homework: String, room: String, teacher: String, kind: String = "", subgroup: String? = nil) throws -> UniversityLesson {
        let subject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty else { throw LessonValidationError.emptySubject }
        guard CalendarMath().isSupported(date) else { throw DataStoreError.invalidDate }
        var lesson = UniversityLesson(id: id ?? UUID(), subject: subject, civilDay: CivilDay(date: date),
            startMinute: startMinute, endMinute: endMinute,
            homework: homework.trimmingCharacters(in: .whitespacesAndNewlines),
            room: room.trimmingCharacters(in: .whitespacesAndNewlines),
            teacher: teacher.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind.trimmingCharacters(in: .whitespacesAndNewlines), subgroup: subgroup?.trimmingCharacters(in: .whitespacesAndNewlines))
        guard lesson.isValid else { throw LessonValidationError.invalidTime }
        return try commit { document in
            if let id {
                guard let index = document.lessons.firstIndex(where: { $0.id == id }) else { throw LessonValidationError.notFound }
                lesson.istuOrigin = document.lessons[index].istuOrigin
                lesson.sourceCancelled = document.lessons[index].sourceCancelled
                lesson.cloudID = document.lessons[index].cloudID
                document.lessons[index] = lesson
            } else { document.lessons.append(lesson) }
            return lesson
        }
    }

    func deleteLesson(_ lesson: UniversityLesson) {
        do {
            try commit { document in
                if let origin = document.lessons.first(where: { $0.id == lesson.id })?.istuOrigin,
                   !document.deletedISTULessonKeys.contains(origin.key) {
                    document.deletedISTULessonKeys.append(origin.key)
                }
                document.lessons.removeAll { $0.id == lesson.id }
            }
        }
        catch { errorMessage = error.localizedDescription }
    }

    /// Updates only published days of this source group. A three-way field merge
    /// preserves manual edits/homework; manual additions and other groups survive.
    func importISTUSchedule(_ page: ISTUSchedulePage, groupID: String, durationMinutes: Int) throws -> ISTUImportResult {
        guard (1...360).contains(durationMinutes), !page.coveredDays.isEmpty,
              page.coveredDays.allSatisfy(\.isValid), page.lessons.count <= 5000 else { throw DataStoreError.invalidContents("Неполное расписание для импорта.") }
        let days = Set(page.coveredDays.map { WidgetDeepLink.dayString($0) })
        var incoming: [UniversityLesson] = []
        for item in page.lessons {
            guard days.contains(WidgetDeepLink.dayString(item.day)) else { throw DataStoreError.invalidContents("Занятие вне загруженного периода.") }
            var lesson = UniversityLesson(subject: item.subject, civilDay: item.day,
                startMinute: item.startMinute, endMinute: item.startMinute + durationMinutes,
                homework: "", room: item.room, teacher: item.teacher, kind: item.kind, subgroup: item.subgroup)
            guard lesson.isValid else { throw LessonValidationError.invalidTime }
            lesson.istuOrigin = ISTULessonOrigin(groupID: groupID, sourceID: item.sourceID, original: ISTULessonFields(lesson))
            lesson.cloudID = "source:\(groupID):\(item.sourceID)"
            incoming.append(lesson)
        }
        guard Set(incoming.compactMap { $0.istuOrigin?.key }).count == incoming.count else {
            throw DataStoreError.invalidContents("Повторяющиеся занятия в ответе сайта.")
        }
        return try commit { document in
            var result = ISTUImportResult()
            let remoteKeys = Set(incoming.compactMap { $0.istuOrigin?.key })
            let deleted = Set(document.deletedISTULessonKeys)
            for index in document.lessons.indices {
                let existing = document.lessons[index]
                guard let origin = existing.istuOrigin, origin.groupID == groupID,
                      days.contains(WidgetDeepLink.dayString(origin.original.civilDay)), !remoteKeys.contains(origin.key) else { continue }
                if ISTULessonFields(existing) != origin.original || !existing.homework.isEmpty {
                    document.lessons[index].cloudID = existing.cloudID ?? "source:\(origin.groupID):\(origin.sourceID)"
                    document.lessons[index].istuOrigin = nil
                    document.lessons[index].sourceCancelled = false
                    result.preserved += 1; continue
                }
                if !existing.sourceCancelled { document.lessons[index].sourceCancelled = true; result.removed += 1 }
            }
            for remote in incoming {
                guard let origin = remote.istuOrigin, !deleted.contains(origin.key) else { continue }
                if let index = document.lessons.firstIndex(where: { $0.istuOrigin?.key == origin.key || $0.cloudID == remote.cloudID }) {
                    let previous = document.lessons[index].istuOrigin?.original
                    let current = document.lessons[index]
                    var merged = remote
                    merged.id = current.id
                    merged.homework = current.homework
                    if current.subject != previous?.subject { merged.subject = current.subject }
                    if current.civilDay != previous?.civilDay { merged.civilDay = current.civilDay }
                    if current.startMinute != previous?.startMinute { merged.startMinute = current.startMinute }
                    if current.endMinute != previous?.endMinute { merged.endMinute = current.endMinute }
                    if current.kind != previous?.kind { merged.kind = current.kind }
                    if current.room != previous?.room { merged.room = current.room }
                    if current.teacher != previous?.teacher { merged.teacher = current.teacher }
                    if current.subgroup != previous?.subgroup { merged.subgroup = current.subgroup }
                    guard merged.isValid else { throw LessonValidationError.invalidTime }
                    if merged != current { result.updated += 1 }
                    document.lessons[index] = merged
                } else {
                    document.lessons.append(remote); result.added += 1
                }
            }
            return result
        }
    }

    func recalculateImportedDuration(_ durationMinutes: Int) throws {
        guard (1...360).contains(durationMinutes) else { throw LessonValidationError.invalidTime }
        try commit { document in
            for index in document.lessons.indices {
                guard var origin = document.lessons[index].istuOrigin else { continue }
                let end = origin.original.startMinute + durationMinutes
                guard end <= 1440 else { throw LessonValidationError.invalidTime }
                if document.lessons[index].endMinute == origin.original.endMinute {
                    guard end > document.lessons[index].startMinute else { throw LessonValidationError.invalidTime }
                    document.lessons[index].endMinute = end
                }
                origin.original.endMinute = end
                document.lessons[index].istuOrigin = origin
            }
        }
    }

    @discardableResult
    func saveTask(id: UUID? = nil, title: String, date: Date, groupID: UUID?, note: String) throws -> PlannerTask {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw DataStoreError.emptyTitle }
        guard CalendarMath().isSupported(date) else { throw DataStoreError.invalidDate }
        guard groupID != TaskGroup.ungrouped.id else { throw DataStoreError.groupNotFound }
        return try commit { document in
            if let groupID, !document.groups.contains(where: { $0.id == groupID }) { throw DataStoreError.groupNotFound }
            if let id {
                guard let index = document.tasks.firstIndex(where: { $0.id == id }) else { throw DataStoreError.taskNotFound }
                // Keep completion from the current revision, not the editor's old snapshot.
                document.tasks[index].title = title
                document.tasks[index].date = CalendarMath().startOfDay(date)
                document.tasks[index].groupID = groupID
                document.tasks[index].note = note.trimmingCharacters(in: .whitespacesAndNewlines)
                return document.tasks[index]
            }
            let task = PlannerTask(title: title, date: CalendarMath().startOfDay(date), groupID: groupID, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
            document.tasks.append(task)
            return task
        }
    }

    func toggleTask(_ task: PlannerTask) {
        do {
            try commit { document in
                guard let index = document.tasks.firstIndex(where: { $0.id == task.id }) else { throw DataStoreError.taskNotFound }
                document.tasks[index].isCompleted.toggle()
            }
        } catch { errorMessage = error.localizedDescription }
    }

    /// An explicit state makes a repeated App Intent idempotent.
    func setTaskCompleted(id: UUID, isCompleted: Bool) throws {
        try commit { document in
            guard let index = document.tasks.firstIndex(where: { $0.id == id }) else { throw DataStoreError.taskNotFound }
            document.tasks[index].isCompleted = isCompleted
        }
    }

    func deleteTask(_ task: PlannerTask) {
        do { try commit { $0.tasks.removeAll { $0.id == task.id } } }
        catch { errorMessage = error.localizedDescription }
    }

    @discardableResult
    func saveGroup(id: UUID? = nil, name: String, colorHex: String) throws -> TaskGroup {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw DataStoreError.emptyGroupName }
        guard let normalizedColor = Self.normalizeColor(colorHex) else { throw DataStoreError.invalidColor }
        guard id != TaskGroup.ungrouped.id else { throw DataStoreError.groupNotFound }
        return try commit { document in
            let group = TaskGroup(id: id ?? UUID(), name: name, colorHex: normalizedColor)
            if let id {
                guard let index = document.groups.firstIndex(where: { $0.id == id }) else { throw DataStoreError.groupNotFound }
                document.groups[index] = group
            } else {
                document.groups.append(group)
            }
            return group
        }
    }

    func deleteGroup(_ group: TaskGroup) {
        guard !group.isUngrouped else { return }
        do {
            try commit { document in
                document.groups.removeAll { $0.id == group.id }
                for index in document.tasks.indices where document.tasks[index].groupID == group.id {
                    document.tasks[index].groupID = nil
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func commit<T>(_ mutation: (inout Document) throws -> T) throws -> T {
        guard let storage else { throw DataStoreError.storageUnavailable(errorMessage ?? "Общий контейнер недоступен.") }
        var latest: Snapshot?
        var changed = false
        do {
            let (result, snapshot) = try storage.withExclusiveAccess {
                let current = try readSnapshot(in: storage)
                latest = current
                var document = current.document
                let result = try mutation(&document)
                guard document.tasks != current.document.tasks || document.groups != current.document.groups || document.lessons != current.document.lessons || document.deletedISTULessonKeys != current.document.deletedISTULessonKeys else {
                    return (result, current)
                }
                document.schemaVersion = 4
                try validate(document)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .millisecondsSince1970
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                do {
                    let encoded = try encoder.encode(document)
                    try (current.bytes ?? encoded).write(to: storage.backupURL, options: .atomic)
                    try encoded.write(to: storage.dataURL, options: .atomic)
                    changed = true
                    return (result, Snapshot(document: document, bytes: encoded, warning: current.warning))
                } catch { throw DataStoreError.writeFailed(error.localizedDescription) }
            }
            publish(snapshot)
            if changed { onCommit?() }
            return result
        } catch {
            if let latest { publish(latest) } else { isAvailable = false }
            errorMessage = error.localizedDescription
            throw error
        }
    }

    private func publish(_ snapshot: Snapshot) {
        tasks = snapshot.document.tasks
        groups = snapshot.document.groups
        lessons = snapshot.document.lessons
        isAvailable = true
        errorMessage = snapshot.warning
    }

    /// Caller holds the interprocess lock, including throughout backup recovery.
    private func readSnapshot(in storage: SharedPlannerStorage) throws -> Snapshot {
        let manager = FileManager.default
        let primaryExists = manager.fileExists(atPath: storage.dataURL.path)
        if primaryExists {
            do {
                let bytes = try Data(contentsOf: storage.dataURL)
                return Snapshot(document: try decode(bytes), bytes: bytes, warning: nil)
            } catch DataStoreError.unsupportedSchema(let version) {
                throw DataStoreError.unsupportedSchema(version)
            } catch { }
        } else if !manager.fileExists(atPath: storage.backupURL.path) {
            return Snapshot(document: Document(), bytes: nil, warning: nil)
        }
        do {
            let bytes = try Data(contentsOf: storage.backupURL)
            let document = try decode(bytes)
            if primaryExists {
                let preserved = storage.directory.appendingPathComponent("planner.corrupt-\(UUID().uuidString).json")
                try manager.copyItem(at: storage.dataURL, to: preserved)
            }
            try bytes.write(to: storage.dataURL, options: .atomic)
            return Snapshot(document: document, bytes: bytes, warning: "Основной файл данных недоступен или повреждён. Восстановлена предыдущая сохранённая версия из резервной копии. Повреждённый файл, если он существовал, сохранён отдельно в хранилище приложения.")
        } catch {
            throw DataStoreError.readFailed("Не удалось открыть данные или резервную копию. Исходные файлы сохранены без изменений. Изменение дел недоступно до восстановления хранилища. \(error.localizedDescription)")
        }
    }

    private func decode(_ data: Data) throws -> Document {
        struct Header: Decodable { let schemaVersion: Int }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let header = try decoder.decode(Header.self, from: data)
        guard (1...4).contains(header.schemaVersion) else { throw DataStoreError.unsupportedSchema(header.schemaVersion) }
        decoder.userInfo[.plannerSchemaVersion] = header.schemaVersion
        let document = try decoder.decode(Document.self, from: data)
        try validate(document)
        return document
    }

    private func validate(_ document: Document) throws {
        let origins = document.lessons.compactMap(\.istuOrigin)
        guard Set(origins.map(\.key)).count == origins.count,
              origins.allSatisfy({ !$0.groupID.isEmpty && !$0.sourceID.isEmpty && $0.original.civilDay.isValid }),
              Set(document.deletedISTULessonKeys).count == document.deletedISTULessonKeys.count else {
            throw DataStoreError.invalidContents("Некорректные сведения об импорте.")
        }
        guard Set(document.lessons.map(\.id)).count == document.lessons.count,
              document.lessons.allSatisfy(\.isValid) else {
            throw DataStoreError.invalidContents("некорректное занятие или повторяющийся идентификатор занятия.")
        }
        guard Set(document.tasks.map(\.id)).count == document.tasks.count,
              Set(document.groups.map(\.id)).count == document.groups.count else {
            throw DataStoreError.invalidContents("повторяющиеся идентификаторы.")
        }
        let groupIDs = Set(document.groups.map(\.id))
        for group in document.groups {
            guard !group.isUngrouped, !group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  Self.normalizeColor(group.colorHex) != nil else { throw DataStoreError.invalidContents("некорректная группа.") }
        }
        for task in document.tasks {
            guard !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  task.civilDay.isValid, task.createdAt.timeIntervalSinceReferenceDate.isFinite else {
                throw DataStoreError.invalidContents("некорректное дело.")
            }
            if let id = task.groupID, !groupIDs.contains(id) { throw DataStoreError.invalidContents("дело ссылается на отсутствующую группу.") }
        }
    }

    private static func normalizeColor(_ value: String) -> String? {
        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard hex.count == 6, hex.unicodeScalars.allSatisfy({
            (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value)
        }) else { return nil }
        return "#" + hex.uppercased()
    }
}
