import Foundation

@main struct CloudCoreTests {
    struct Failure: Error { let message: String }
    static func main() throws {
        var count = 0
        func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            count += 1; if try !value() { throw Failure(message: message) }
        }
        func rejects(_ message: String, _ body: () throws -> Void) throws {
            count += 1; do { try body() } catch { return }; throw Failure(message: message)
        }
        let day = CivilDay(year: 2026, month: 10, day: 20)
        let task = CloudEntity(id: "task-one", kind: "task", data: ["title": .text("Дело"), "date": .text("2026-10-20"), "note": .text("Заметка"), "groupId": .null, "completed": .bool(false)], version: 3, deleted: false)
        var state = CloudAccountState(records: [task])
        var edited = task; edited.data["completed"] = .bool(true)
        state.capture([edited]); let first = state.batch()[0]
        try check(state.outbox.count == 1 && first.base == task.data && first.baseVersion == 3, "Capture includes exact merge baseline")
        state.capture([edited]); try check(state.outbox.count == 1, "No duplicate operation on unchanged capture")
        let encoded = try JSONEncoder().encode(state)
        state = try JSONDecoder().decode(CloudAccountState.self, from: encoded)
        try check(state.batch()[0].operationId == first.operationId, "Restart preserves idempotency key")
        var later = edited; later.data["title"] = .text("После запроса")
        state.capture([later]); try check(state.outbox.count == 2 && state.batch().count == 1, "Concurrent local edit is serialized behind in-flight head")
        var server = edited; server.version = 4
        try state.receive(CloudReply(records: [server], results: [CloudOperationResult(operationId: first.operationId, status: "applied", record: server, conflictingFields: [])], revision: 4))
        try check(state.outbox.count == 1 && state.batch()[0].baseVersion == 4, "Unsent successor rebases only after exact applied baseline")
        try check(state.optimistic[0].data["title"] == .text("После запроса"), "Awaited response preserves newer local edit")
        server.data["note"] = .text("Из iPhone"); server.version = 5
        try state.receive(CloudReply(records: [server], revision: 5))
        try check(state.optimistic[0].data["note"] == .text("Из iPhone"), "Optimistic patch preserves unrelated cloud fields")
        let conflictOp = state.batch()[0]
        server.data["title"] = .text("В облаке")
        try state.receive(CloudReply(records: [server], results: [CloudOperationResult(operationId: conflictOp.operationId, status: "conflict", record: server, conflictingFields: ["title"])], revision: 5))
        try check(state.conflicts.count == 1 && state.batch().isEmpty, "Conflicting entity stops sending until explicit choice")
        state.resolve(state.conflicts[0], keepLocal: false)
        try check(state.conflicts.isEmpty && state.optimistic[0].data["title"] == .text("В облаке"), "Cloud choice restores cloud value")
        state.capture([later]); let deleting = state.batch()[0]
        server.deleted = true; server.version = 6
        try state.receive(CloudReply(records: [server], results: [CloudOperationResult(operationId: deleting.operationId, status: "conflict", record: server, conflictingFields: ["__deleted"])], revision: 6))
        state.resolve(state.conflicts[0], keepLocal: true)
        try check(state.batch()[0].entityId != task.id && state.batch()[0].baseVersion == 0, "Remote deletion can only preserve local edit as separate copy")
        var many: [CloudEntity] = []
        for n in 0..<105 { var item = task; item.id = "task-\(n)"; many.append(item) }
        var bulk = CloudAccountState(); bulk.capture(many)
        try check(bulk.batch().count == 100, "Server batch cap respected")
        let group = CloudEntity(id: "group-first", kind: "group", data: ["name": .text("Учеба"), "color": .text("#3388FF")], version: 0, deleted: false)
        bulk.capture(many + [group]); try check(bulk.batch().first?.kind == "group", "Groups precede referencing tasks")
        try rejects("Duplicate IDs rejected before dictionary materialization") { _ = try CloudMapping.snapshot([task, task]) }
        var bad = task; bad.id = "preferences"
        try rejects("Same identity cannot represent two kinds") { _ = try CloudMapping.snapshot([task, bad, bad]) }
        try check(CloudMapping.day("2026-02-30") == nil && CloudMapping.day("2026-1-020") == nil, "Civil dates are strict and independent of local timezone")
        try check(CloudMapping.date(day) == "2026-10-20", "Canonical PWA date")
        let snapshot = try CloudMapping.snapshot([task, group])
        try check(snapshot.tasks[0].id == CloudMapping.uuid(task.id), "Stable PWA string ID maps to UUID")
        let roundtrip = try CloudMapping.entities(snapshot, preferences: PlannerPreferences(), known: [task, group])
        try check(roundtrip.first { $0.id == task.id }?.data == task.data, "String IDs and task fields survive roundtrip")
        try check(CloudMapping.uuid("a") == CloudMapping.uuid("a") && CloudMapping.uuid("a") != CloudMapping.uuid("b"), "Mapping is deterministic")
        var lesson = UniversityLesson(subject: "Теория", civilDay: day, startMinute: 705, endMinute: 795, homework: "Личное ДЗ", room: "Б-100", teacher: "Иванов", kind: "Лекция", subgroup: "1")
        lesson.istuOrigin = ISTULessonOrigin(groupID: "478229", sourceID: "istu:478229:2026-10-20:42:1", original: ISTULessonFields(lesson))
        let origin = lesson.istuOrigin!
        let sourceSnapshot = NativePlannerSnapshot(tasks: [], groups: [], lessons: [lesson], deletedISTULessonKeys: [])
        let source = try CloudMapping.entities(sourceSnapshot, preferences: PlannerPreferences()).first { $0.kind == "lesson" }!
        try check(source.id == "source:478229:istu:478229:2026-10-20:42:1", "Canonical source ID exactly matches PWA")
        let preserved = try CloudMapping.snapshot([source], preserving: sourceSnapshot)
        try check(preserved.lessons[0].id == lesson.id, "First cloud projection preserves an open native lesson identity")
        let back = try CloudMapping.snapshot([source])
        try check(back.lessons[0].istuOrigin == origin && back.lessons[0].homework == lesson.homework, "Source baseline and personal homework survive")
        var cancelled = source; cancelled.data["sourceCancelled"] = .bool(true)
        try check(try CloudMapping.snapshot([cancelled]).lessons[0].sourceCancelled, "Source cancellation retained without destructive deletion")
        var untilMidnight = lesson; untilMidnight.endMinute = 1440
        try check(untilMidnight.isValid && untilMidnight.timeRange.hasSuffix("24:00"), "PWA midnight end supported")
        var prefs = PlannerPreferences(); prefs.notificationsEnabled = true; prefs.subgroup = "1"; prefs.groupId = "478229"
        try check(try PlannerPreferences(fields: prefs.fields) == prefs, "All preferences match PWA contract")
        try rejects("Malformed duration rejected") { _ = try PlannerPreferences(fields: ["durationMinutes": .number(0)]) }
        let now = NotificationPlan.start(lesson)!.addingTimeInterval(-600)
        let reminders = NotificationPlan.reminders([lesson], preferences: prefs, now: now, delivered: [])
        try check(reminders.count == 1 && reminders[0].fire == NotificationPlan.start(lesson)!.addingTimeInterval(-300), "Reminder runs five minutes before Irkutsk wall time")
        try check(reminders[0].body.contains("Б-100") && reminders[0].body.contains("Иванов") && !reminders[0].body.contains("Личное ДЗ"), "Payload has room, teacher and kind without homework")
        try check(NotificationPlan.reminders([lesson], preferences: prefs, now: now, delivered: [reminders[0].id]).isEmpty, "Delivered reminder not sent twice")
        var other = lesson; other.subgroup = "2"
        try check(NotificationPlan.reminders([other], preferences: prefs, now: now, delivered: []).isEmpty, "Other subgroup never notifies")
        other.subgroup = nil
        try check(NotificationPlan.reminders([other], preferences: prefs, now: now, delivered: []).count == 1, "Common lesson notifies selected subgroup")
        prefs.mutedSubjects = [PlannerPreferences.subjectKey("  ТЕОРИЯ  ")]
        try check(NotificationPlan.reminders([lesson], preferences: prefs, now: now, delivered: []).isEmpty, "Subject mute normalizes case and whitespace")
        prefs.mutedSubjects = []; prefs.mutedDates = ["2026-10-20"]
        try check(NotificationPlan.reminders([lesson], preferences: prefs, now: now, delivered: []).isEmpty, "Day mute applies")
        prefs.mutedDates = []; prefs.beforeLessonEnabled = false
        try check(NotificationPlan.reminders([lesson], preferences: prefs, now: now, delivered: []).isEmpty, "Before-lesson toggle applies")
        prefs.beforeLessonEnabled = true; prefs.notificationsEnabled = false
        try check(NotificationPlan.reminders([lesson], preferences: prefs, now: now, delivered: []).isEmpty, "Master toggle applies")
        prefs.notificationsEnabled = true
        var revised = lesson; revised.room = "Б-101"
        try check(NotificationPlan.sourceChanges(old: [lesson], new: [revised], preferences: prefs, now: now).isEmpty, "Personal edit does not masquerade as source update")
        revised.istuOrigin = ISTULessonOrigin(groupID: origin.groupID, sourceID: origin.sourceID, original: ISTULessonFields(revised))
        try check(NotificationPlan.sourceChanges(old: [lesson], new: [revised], preferences: prefs, now: now).count == 1, "Actual source change detected")
        try check(NotificationPlan.sourceChanges(old: [], new: [lesson], preferences: prefs, now: now).isEmpty, "First import remains silent")
        revised = lesson; revised.sourceCancelled = true
        try check(NotificationPlan.sourceChanges(old: [lesson], new: [revised], preferences: prefs, now: now).count == 1, "Cancellation alert remains eligible")
        prefs.scheduleChangesEnabled = false
        try check(NotificationPlan.sourceChanges(old: [lesson], new: [revised], preferences: prefs, now: now).isEmpty, "Change toggle independent from reminders")
        var gone = sourceSnapshot; gone.lessons = []; gone.deletedISTULessonKeys = [origin.key]
        let hidden = try CloudMapping.entities(gone, preferences: prefs)
        let tombstone = hidden.first { $0.kind == "lesson" }!
        try check(tombstone.deleted && tombstone.id == source.id, "Local hidden source exports a canonical tombstone")
        var hiddenState = CloudAccountState(); hiddenState.capture(hidden)
        let creation = hiddenState.batch().first { $0.kind == "lesson" }!
        try check(creation.data?["sourceCancelled"] == .bool(true) && creation.data?["sourceBaseline"] == nil, "Transient tombstone creation never emits fake source-change or lesson alerts")
        try check(creation.data != nil && hiddenState.outbox.contains { $0.entityId == source.id && $0.data == nil }, "New tombstone creates before deleting, as server requires")
        var created = tombstone; created.deleted = false; created.version = 10
        try hiddenState.receive(CloudReply(records: [created], results: [CloudOperationResult(operationId: creation.operationId, status: "applied", record: created, conflictingFields: [])], revision: 10))
        let deletion = hiddenState.batch().first { $0.kind == "lesson" }!
        try check(deletion.data == nil && deletion.baseVersion == 10, "Queued deletion rebases to acknowledged creation version")
        let deleteJSON = try JSONDecoder().decode(CloudValue.self, from: JSONEncoder().encode(deletion)).fields!
        try check(deleteJSON["data"] == .null, "PWA backup operation encodes explicit null, not a missing field")
        let aConflict = CloudConflict(operation: CloudOperation(entityId: task.id, kind: "task", baseVersion: task.version, base: task.data, data: edited.data), server: task, fields: ["completed"])
        let conflictJSON = try JSONEncoder().encode(aConflict)
        try check(try JSONDecoder().decode(CloudConflict.self, from: conflictJSON).operation.data == edited.data, "PWA conflict backup has recoverable local version")
        var conflicted = CloudAccountState(records: [task], conflicts: [aConflict]); conflicted.capture([later])
        try check(conflicted.optimistic.first?.data["title"] == later.data["title"], "Later edit overlays saved conflict instead of being overwritten by it")
        try check(conflicted.batch().isEmpty, "Further edits to conflicted entity wait for resolution")
        let beforeProjection = [task]; var projected = CloudAccountState(records: [server], projectionBase: beforeProjection)
        projected.capture([task], comparingTo: beforeProjection)
        try check(projected.outbox.isEmpty, "Interrupted projection does not upload old local snapshot over cloud data")
        let disk = CloudDisk(directory: FileManager.default.temporaryDirectory.appendingPathComponent("SimpleSchedule-CloudCore-\(UUID())"))
        defer { try? FileManager.default.removeItem(at: disk.directory) }
        try disk.save(state, name: "state.json")
        try check(try disk.read("state.json", as: CloudAccountState.self)?.outbox == state.outbox, "Atomic queue survives actual disk roundtrip")
        try rejects("Account cannot escape cloud directory") { _ = try CloudDisk.accountFile("../../planner") }
        print("CloudCoreTests: \(count) проверок синхронизации, формата и уведомлений пройдено.")
    }
}
