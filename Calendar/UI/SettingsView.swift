import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var login: LoginItemManager
    @Bindable var importer: ISTUImportController

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var transparency: Binding<Double> {
        Binding(
            get: { 1 - settings.backgroundOpacity },
            set: { settings.backgroundOpacity = 1 - $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Настройки")
                .font(.title2.bold())
            Form {
                importSection
                Section("Оформление") {
                    Picker("Тема", selection: $settings.theme) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Прозрачность фона")
                            Spacer()
                            Text("\(Int(((1 - settings.backgroundOpacity) * 100).rounded())) %")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: transparency, in: 0...0.95) {
                            Text("Прозрачность фона")
                        } minimumValueLabel: {
                            Text("0 %").font(.caption2)
                        } maximumValueLabel: {
                            Text("95 %").font(.caption2)
                        }
                        .labelsHidden()
                        .accessibilityLabel("Прозрачность фона")
                        .accessibilityValue("\(Int(((1 - settings.backgroundOpacity) * 100).rounded())) процентов")
                        .accessibilityIdentifier("settings.backgroundTransparency")
                        .disabled(reduceTransparency)
                        TransparencyPreview(opacity: settings.backgroundOpacity, reduceTransparency: reduceTransparency)
                        if reduceTransparency {
                            Text("В macOS включено уменьшение прозрачности. Панель использует непрозрачный фон.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    LabeledContent("Акцентный цвет", value: "Системный")
                    Text("Элементы управления используют системный акцент. Цвета групп задаются отдельно.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("Запуск") {
                    Toggle("Запускать при входе в систему", isOn: Binding(
                        get: { login.isEnabled },
                        set: { login.setEnabled($0) }
                    ))
                    .disabled(login.isUpdating)
                    Text(login.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if login.requiresApproval {
                        HStack {
                            Button("Открыть системные настройки") { login.openSystemSettings() }
                            Button("Отменить запрос") { login.setEnabled(false) }
                                .disabled(login.isUpdating)
                        }
                    }
                    if let errorMessage = login.errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section {
                    Label("Данные хранятся на этом Mac. Дела и сохраненное расписание доступны без интернета; сайт ИРНИТУ нужен только для загрузки списков и импорта по вашему действию.", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .contentMargins(.all, 0, for: .scrollContent)
            .clipped()
            HStack {
                Spacer()
                Button("Готово") { dismiss() }
                    .plannerSheetAction()
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 540)
        .environment(\.locale, Locale(identifier: "ru_RU"))
        .preferredColorScheme(settings.theme.preferredColorScheme)
        .tint(.accentColor)
        .onAppear { login.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            login.refresh()
        }
    }

    private var instituteSelection: Binding<String?> {
        Binding(get: { importer.settings.instituteID }, set: { id in
            Task { await importer.selectInstitute(id) }
        })
    }

    private var groupSelection: Binding<String?> {
        Binding(get: { importer.settings.groupID }, set: { importer.selectGroup($0) })
    }

    private var duration: Binding<Int> {
        Binding(get: { importer.settings.durationMinutes }, set: {
            importer.settings.durationMinutes = min(360, max(1, $0))
        })
    }

    private var subgroupOptions: [String] {
        importer.availableSubgroups
    }

    @ViewBuilder private var importSection: some View {
        @Bindable var importSettings = importer.settings
        Section("Расписание ИРНИТУ") {
            HStack {
                Button(importer.institutes.isEmpty ? "Загрузить институты" : "Обновить институты") {
                    Task { await importer.loadInstitutes() }
                }
                .disabled(importer.isLoading)
                .accessibilityIdentifier("istu.loadInstitutes")
                if importer.isLoading {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Загрузка расписания ИРНИТУ")
                    Button("Отмена") { importer.cancel() }
                        .accessibilityIdentifier("istu.cancelLoading")
                }
            }
            Picker("Институт", selection: instituteSelection) {
                Text("Выберите институт").tag(Optional<String>.none)
                ForEach(importer.institutes) { option in
                    Text(option.name).tag(Optional(option.id))
                }
                if let selected = importSettings.instituteID,
                   !importer.institutes.contains(where: { $0.id == selected }) {
                    Text("Сохраненный институт").tag(Optional(selected))
                }
            }
            .disabled(importer.institutes.isEmpty || importer.isLoading)
            .accessibilityIdentifier("istu.institute")
            Picker("Группа", selection: groupSelection) {
                Text("Выберите группу").tag(Optional<String>.none)
                ForEach(importer.groups) { option in
                    Text(option.name).tag(Optional(option.id))
                }
                if let selected = importSettings.groupID,
                   !importer.groups.contains(where: { $0.id == selected }) {
                    Text("Сохраненная группа").tag(Optional(selected))
                }
            }
            .disabled(importSettings.instituteID == nil || importer.groups.isEmpty || importer.isLoading)
            .accessibilityIdentifier("istu.group")
            Button(importer.groups.isEmpty ? "Загрузить группы" : "Обновить группы") {
                Task { await importer.selectInstitute(importSettings.instituteID) }
            }
            .disabled(importSettings.instituteID == nil || importer.isLoading)
            .accessibilityIdentifier("istu.loadGroups")
            Picker("Подгруппа", selection: $importSettings.subgroup) {
                Text("Все подгруппы").tag(Optional<String>.none)
                ForEach(subgroupOptions, id: \.self) { value in
                    Text(value).tag(Optional(value))
                }
                if let selected = importSettings.subgroup, !subgroupOptions.contains(selected) {
                    Text("Обновите расписание").tag(Optional(selected))
                }
            }
            .disabled(importSettings.groupID == nil)
            .accessibilityIdentifier("istu.subgroup")
            Text(subgroupOptions.isEmpty
                 ? "Номера подгрупп появятся после обновления расписания. Все занятия загружаются сразу."
                 : "Номера получены с сайта. Выбор показывает общие занятия и занятия вашей подгруппы; переключение работает без повторной загрузки.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("Длительность пары") {
                HStack(spacing: 6) {
                    TextField("Длительность в минутах", value: duration, format: .number.grouping(.never))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .accessibilityLabel("Длительность пары в минутах")
                        .accessibilityIdentifier("istu.duration")
                    Text("мин").foregroundStyle(.secondary)
                    Stepper("Длительность пары", value: duration, in: 1...360, step: 5)
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityLabel("Изменить длительность пары")
                }
            }
            Text("От 1 до 360 минут. Для новой пары окончание рассчитывается от начала; его можно изменить вручную.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Сохраненные списки доступны офлайн. Загрузка списка и импорт недели выполняются только по вашему действию. Выбор института загружает его группы; остальные настройки сохраняются автоматически.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let status = importer.statusMessage {
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = importer.errorMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Скрыть ошибку") { importer.clearError() }
                        .buttonStyle(.borderless)
                }
            }
        }
    }
}

private struct TransparencyPreview: View {
    let opacity: Double
    let reduceTransparency: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: [.indigo, .mint, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack {
                Image(systemName: "calendar")
                    .font(.title3)
                    .accessibilityHidden(true)
                Text("Так будет выглядеть фон")
                    .font(.callout)
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
            .padding(13)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(nsColor: .windowBackgroundColor).opacity(reduceTransparency ? 1 : opacity))
                    }
            }
            .padding(10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Предпросмотр прозрачности фона")
    }
}
