import SwiftUI
import UniformTypeIdentifiers

/// Additional functionality uses the existing grouped Form; no new app shell or styling.
struct CloudAccountSection: View {
    @Bindable var cloud: CloudController
    var body: some View {
        Section("Аккаунт и синхронизация") {
            if let user = cloud.user {
                LabeledContent("Почта", value: user.email)
                Text(cloud.authenticated ? "Синхронизация включена. Изменения отправляются автоматически." : "Офлайн-копия аккаунта. Войдите снова для синхронизации.")
                    .font(.caption).foregroundStyle(.secondary)
                if cloud.pendingMerge {
                    Text("Локальная копия сохранена отдельно. Выберите, объединить её с аккаунтом или открыть облако. Записи в облаке с совпадающими идентификаторами сохранятся.")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    Button("Объединить локальные данные с аккаунтом") { Task { await cloud.openAccount(mergeGuest: true) } }
                    Button("Открыть облачные данные") { Task { await cloud.openAccount(mergeGuest: false) } }
                } else {
                    LabeledContent("Ожидают отправки", value: cloud.pendingCount.formatted())
                    if let last = cloud.lastSync { LabeledContent("Последняя синхронизация") { Text(last, format: .dateTime.day().month().hour().minute()) } }
                    HStack {
                        Button(cloud.isSynchronizing ? "Синхронизация…" : "Синхронизировать") { Task { await cloud.synchronize() } }.disabled(!cloud.authenticated || cloud.isSynchronizing)
                        Button("Объединить локальную копию") { Task { await cloud.mergeLocalCopy() } }
                    }
                }
                Button("Выйти из аккаунта") { Task { await cloud.signOut() } }.disabled(cloud.isSynchronizing)
            }
            if cloud.user == nil || !cloud.authenticated {
                TextField("Ваша почта", text: $cloud.email).textContentType(.emailAddress)
                if cloud.codeSent { TextField("Шестизначный код", text: $cloud.code).textContentType(.oneTimeCode) }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = max(0, Int(ceil(cloud.retryAt.timeIntervalSince(context.date))))
                    HStack {
                        Button(seconds > 0 ? "Повторить через \(seconds) с" : "Получить код") { Task { await cloud.requestCode() } }
                            .disabled(seconds > 0)
                        if cloud.codeSent { Button("Войти") { Task { await cloud.verifyCode() } } }
                        else { Button("У меня уже есть код") { cloud.showCodeEntry() } }
                    }
                }
                Text("Используйте одну почту на Mac и iPhone. Пароль не требуется; шестизначный код приходит письмом. Сессия хранится в Связке ключей.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if cloud.isBusy { ProgressView().controlSize(.small) }
            if let error = cloud.errorMessage { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            ForEach(cloud.conflicts) { conflict in
                VStack(alignment: .leading, spacing: 8) {
                    Text("Конфликт: \(conflict.operation.data?["title"]?.string ?? conflict.operation.data?["subject"]?.string ?? conflict.server.data["name"]?.string ?? "Запись")").font(.headline)
                    Text("Эти поля изменены на двух устройствах: \(conflict.fields.joined(separator: ", ")). Обе версии сохранены до выбора.").font(.caption)
                    HStack {
                        Button("Использовать облачную") { cloud.resolve(conflict, keepLocal: false) }
                        Button(conflict.server.deleted ? "Сохранить отдельной копией" : "Сохранить мою") { cloud.resolve(conflict, keepLocal: true) }
                        if !conflict.server.deleted && conflict.server.kind != "preferences" { Button("Создать копию") { cloud.resolve(conflict, keepLocal: true, copy: true) } }
                    }
                }
            }
        }.disabled(cloud.isBusy)
    }
}
struct NativeNotificationSection: View {
    @Bindable var cloud: CloudController
    @Bindable var notifications: NativeNotificationCoordinator
    let lessons: [UniversityLesson]
    private var subjects: [String] { Array(Set(lessons.map(\.subject))).sorted() }
    var body: some View {
        Section("Уведомления") {
            HStack {
                Button("Разрешить уведомления на этом Mac") { Task { await notifications.requestAuthorization() } }
                Button("Проверить") { Task { await notifications.sendTest() } }
            }
            Text(notifications.authorization == .authorized ? "macOS разрешает уведомления." : "Разрешение для этого Mac настраивается отдельно от iPhone.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Включить уведомления", isOn: $cloud.preferences.notificationsEnabled)
            Toggle("Перед началом занятия", isOn: $cloud.preferences.beforeLessonEnabled)
            Toggle("При изменении расписания", isOn: $cloud.preferences.scheduleChangesEnabled)
            Stepper("Напоминать за \(cloud.preferences.leadMinutes) мин", value: $cloud.preferences.leadMinutes, in: 1...1440)
            ForEach(subjects, id: \.self) { subject in
                Toggle(subject, isOn: Binding(get: { !cloud.preferences.mutedSubjects.contains(PlannerPreferences.subjectKey(subject)) }, set: { checked in
                    if checked != !cloud.preferences.mutedSubjects.contains(PlannerPreferences.subjectKey(subject)) { cloud.toggleSubject(subject) }
                }))
            }
            ForEach(cloud.preferences.mutedDates, id: \.self) { date in
                Button("Включить уведомления на \(date)") { if let day = CloudMapping.day(date) { cloud.toggleMutedDate(day) } }
            }
            Text("Время занятий — Иркутск. Отключить отдельный день можно в его контекстном меню. При скрытой панели приложение продолжает работать; после полного завершения новые изменения из облака появятся при следующем запуске.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = notifications.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
}
struct CloudBackupSection: View {
    @Bindable var cloud: CloudController
    @State private var message: String?
    var body: some View {
        Section("Резервная копия") {
            HStack {
                Button("Экспорт данных") { export() }
                Button("Импорт данных") { importFile() }
            }
            Text("JSON совместим с PWA. Импорт объединяет записи; совпадающие идентификаторы заменяются данными файла. Сначала сохраните текущую копию. Коды входа и сессия не экспортируются.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func export() {
        do {
            let data = try cloud.exportBackup(); let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "SimpleSchedule-Backup.json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic); message = "Резервная копия сохранена."
        } catch { message = error.localizedDescription }
    }
    private func importFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert(); alert.messageText = "Импортировать данные?"; alert.informativeText = "Записи с совпадающими идентификаторами изменятся. Текущие файлы сохраняются в резервной копии приложения."
        alert.addButton(withTitle: "Импортировать"); alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try cloud.importBackup(Data(contentsOf: url)); message = "Данные импортированы." }
        catch { message = error.localizedDescription }
    }
}
