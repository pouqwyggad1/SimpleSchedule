import Foundation
import Observation
import UserNotifications

@MainActor @Observable
final class NativeNotificationCoordinator: NSObject {
    private(set) var authorization = UNAuthorizationStatus.notDetermined
    private(set) var errorMessage: String?
    @ObservationIgnored private weak var store: CalendarStore?
    @ObservationIgnored private weak var cloud: CloudController?
    @ObservationIgnored private let center: UNUserNotificationCenter
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var previousLessons: [UniversityLesson] = []
    @ObservationIgnored private var accountContext = ""
    @ObservationIgnored private var initialized = false
    static let openDay = Notification.Name("SimpleSchedule.NotificationOpenDay")

    init(store: CalendarStore, cloud: CloudController, center: UNUserNotificationCenter = .current(), defaults: UserDefaults = .standard) {
        self.store = store; self.cloud = cloud; self.center = center; self.defaults = defaults
        super.init(); center.delegate = self
        refresh()
    }
    func requestAuthorization() async {
        do { _ = try await center.requestAuthorization(options: [.alert, .badge, .sound]); refresh() }
        catch { errorMessage = error.localizedDescription }
    }
    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let settings = await center.notificationSettings(); authorization = settings.authorizationStatus
            do { try await reconcile() } catch is CancellationError { } catch { errorMessage = error.localizedDescription }
        }
    }
    func sendTest() async {
        guard authorization == .authorized || authorization == .provisional else { errorMessage = "Разрешите уведомления в настройках macOS."; return }
        let content = UNMutableNotificationContent(); content.title = "SimpleSchedule"
        content.body = "Уведомления на этом Mac работают."; content.sound = .default
        do { try await center.add(UNNotificationRequest(identifier: "SimpleSchedule.test", content: content, trigger: nil)); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
    private func reconcile() async throws {
        guard let store, let cloud else { return }
        let context = cloud.user?.id ?? "guest"
        if context != accountContext { initialized = false; previousLessons = []; accountContext = context }
        let preferences = cloud.preferences
        let pending = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix("SimpleSchedule.") }
        let delivered = await center.deliveredNotifications()
        var receipts = Set(defaults.stringArray(forKey: "notifications.delivered.v1." + context) ?? [])
        receipts.formUnion(delivered.map { $0.request.identifier })
        let now = Date.now
        let authorized = authorization == .authorized || authorization == .provisional
        if initialized && authorized {
            for lesson in NotificationPlan.sourceChanges(old: previousLessons, new: store.lessons, preferences: preferences, now: now) {
                var data = lesson.istuOrigin.map { CloudMapping.lessonFields($0.original) } ?? CloudMapping.lessonFields(ISTULessonFields(lesson))
                data["sourceCancelled"] = .bool(lesson.sourceCancelled)
                let fingerprint = String(decoding: try JSONEncoder.sorted.encode(CloudValue.object(data)), as: UTF8.self)
                let identifier = "SimpleSchedule.change.\(lesson.id.uuidString).\(CloudMapping.uuid(fingerprint))"
                guard !receipts.contains(identifier) else { continue }
                let content = UNMutableNotificationContent()
                content.title = "\(lesson.sourceCancelled ? "Занятие отменено" : "Расписание изменилось"): \(lesson.subject)"
                content.body = "\(CloudMapping.date(lesson.civilDay)) · \(lesson.timeRange). \(NotificationPlan.details(lesson))"
                content.sound = .default; content.userInfo = ["date": CloudMapping.date(lesson.civilDay)]
                try Task.checkCancellation()
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
                receipts.insert(identifier)
                defaults.set(Array(receipts), forKey: "notifications.delivered.v1." + context)
            }
        }
        let reminders = authorized ? NotificationPlan.reminders(store.lessons, preferences: preferences, now: now, delivered: receipts) : []
        let ids = Set(reminders.map(\.id))
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { !ids.contains($0.identifier) }.map(\.identifier))
        for reminder in reminders {
            try Task.checkCancellation()
            let content = UNMutableNotificationContent(); content.title = reminder.title; content.body = reminder.body
            content.sound = .default; content.userInfo = ["date": CloudMapping.date(reminder.day)]
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = NotificationPlan.timeZone
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.fire)
            components.timeZone = calendar.timeZone
            let existing = pending.first { $0.identifier == reminder.id }
            if existing?.content.title == content.title, existing?.content.body == content.body,
               (existing?.trigger as? UNCalendarNotificationTrigger)?.dateComponents == components { continue }
            try await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
        }
        previousLessons = store.lessons; initialized = true
        if receipts.count > 3000 { receipts = Set(receipts.sorted().suffix(2000)) }
        defaults.set(Array(receipts), forKey: "notifications.delivered.v1." + context)
    }

}
extension NativeNotificationCoordinator: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound, .list] }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let date = response.notification.request.content.userInfo["date"] as? String
        await MainActor.run { if let date, let day = CloudMapping.day(date) { NotificationCenter.default.post(name: Self.openDay, object: nil, userInfo: ["day": day]) } }
    }
}
private extension JSONEncoder {
    static var sorted: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys; return encoder }
}
