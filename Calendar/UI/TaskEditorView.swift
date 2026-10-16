import SwiftUI

struct TaskEditorView: View {
    let store: CalendarStore
    let task: PlannerTask?

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var date: Date
    @State private var groupID: UUID?
    @State private var note: String
    @State private var errorMessage: String?
    @State private var showsNewGroup = false
    @FocusState private var titleIsFocused: Bool

    init(store: CalendarStore, date: Date, task: PlannerTask? = nil, defaultGroupID: UUID? = nil) {
        self.store = store
        self.task = task
        _title = State(initialValue: task?.title ?? "")
        _date = State(initialValue: task?.date ?? date)
        _groupID = State(initialValue: task == nil ? defaultGroupID : task?.groupID)
        _note = State(initialValue: task?.note ?? "")
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(task == nil ? "Новое дело" : "Редактирование дела")
                .font(.title2.bold())

            Form {
                Section {
                    TextField("Название", text: $title, prompt: Text("Что нужно сделать?"))
                        .focused($titleIsFocused)
                        .accessibilityHint("Обязательное поле")
                    DatePicker("Дата", selection: $date, in: CalendarMath().supportedDates, displayedComponents: .date)
                        .datePickerStyle(.field)
                }

                Section {
                    Picker("Группа", selection: $groupID) {
                        Text("Без группы").tag(Optional<UUID>.none)
                        ForEach(store.groups) { group in
                            Text(group.name).tag(Optional(group.id))
                        }
                    }
                    if let group = store.group(id: groupID) {
                        GroupBadgeView(group: group)
                    }
                    Button("Создать группу…", systemImage: "folder.badge.plus") {
                        showsNewGroup = true
                    }
                }

                Section("Заметка — необязательно") {
                    TextEditor(text: $note)
                        .font(.body)
                        .frame(minHeight: 70, idealHeight: 90)
                        .accessibilityLabel("Заметка")
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Ошибка: \(errorMessage)")
                }
            }
            .formStyle(.grouped)
            .contentMargins(.all, 0, for: .scrollContent)
            .clipped()

            HStack {
                Text("Название и дата обязательны")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Отмена") { dismiss() }
                    .plannerSheetAction()
                    .keyboardShortcut(.cancelAction)
                Button("Сохранить", action: save)
                    .plannerSheetAction()
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 500, height: 530)
        .environment(\.locale, Locale(identifier: "ru_RU"))
        .tint(.accentColor)
        .onAppear { titleIsFocused = true }
        .sheet(isPresented: $showsNewGroup) {
            GroupEditorView(store: store) { group in
                groupID = group.id
            }
        }
    }

    private func save() {
        guard canSave else {
            errorMessage = "Введите название дела."
            titleIsFocused = true
            return
        }
        do {
            try store.saveTask(id: task?.id, title: title, date: date, groupID: groupID, note: note)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
