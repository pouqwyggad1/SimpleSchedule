import SwiftUI

private struct GroupEditorDestination: Identifiable {
    let id = UUID()
    let group: TaskGroup?
}

struct GroupManagerView: View {
    let store: CalendarStore

    @Environment(\.dismiss) private var dismiss
    @State private var editorDestination: GroupEditorDestination?
    @State private var deletingGroup: TaskGroup?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Группы")
                    .font(.title2.bold())
                Spacer()
                Button("Создать", systemImage: "plus") {
                    editorDestination = GroupEditorDestination(group: nil)
                }
            }

            if store.groups.isEmpty {
                ContentUnavailableView {
                    Label("Пока нет групп", systemImage: "folder")
                } description: {
                    Text("Объединяйте дела по темам и выбирайте цвета меток.")
                } actions: {
                    Button("Создать группу") {
                        editorDestination = GroupEditorDestination(group: nil)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.groups) { group in
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(Color(hex: group.colorHex))
                                    .frame(width: 12, height: 12)
                                    .overlay(Circle().strokeBorder(.primary.opacity(0.18), lineWidth: 0.5))
                                    .accessibilityHidden(true)
                                Button {
                                    editorDestination = GroupEditorDestination(group: group)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(group.name)
                                            .lineLimit(2)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text("Дел в группе: \(store.tasks.filter { $0.groupID == group.id }.count)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Изменить название и цвет")
                                Button {
                                    editorDestination = GroupEditorDestination(group: group)
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .help("Изменить группу")
                                .accessibilityLabel("Изменить группу \(group.name)")
                                Button(role: .destructive) {
                                    deletingGroup = group
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .help("Удалить группу")
                                .accessibilityLabel("Удалить группу \(group.name)")
                            }
                            .padding(12)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }

            Text("При удалении группы все ее дела сохраняются в разделе «Без группы».")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Готово") { dismiss() }
                    .plannerSheetAction()
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500, height: 480)
        .environment(\.locale, Locale(identifier: "ru_RU"))
        .tint(.accentColor)
        .sheet(item: $editorDestination) { destination in
            GroupEditorView(store: store, group: destination.group)
        }
        .alert("Удалить группу?", isPresented: Binding(
            get: { deletingGroup != nil },
            set: { if !$0 { deletingGroup = nil } }
        ), presenting: deletingGroup) { group in
            Button("Отмена", role: .cancel) { deletingGroup = nil }
            Button("Удалить группу", role: .destructive) {
                store.deleteGroup(group)
                deletingGroup = nil
            }
        } message: { group in
            Text("Группа «\(group.name)» будет удалена. Все ее дела сохранятся с меткой «Без группы».")
        }
    }
}

struct GroupEditorView: View {
    let store: CalendarStore
    let group: TaskGroup?
    var onSave: ((TaskGroup) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var color: Color
    @State private var errorMessage: String?
    @FocusState private var nameIsFocused: Bool

    private let palette: [(name: String, hex: String)] = [
        ("Синий", "#3B82F6"),
        ("Зеленый", "#22A06B"),
        ("Оранжевый", "#E88713"),
        ("Красный", "#E5484D"),
        ("Фиолетовый", "#8B5CF6"),
        ("Бирюзовый", "#0D9488"),
        ("Розовый", "#DB4C9B"),
        ("Серый", "#7A7D85")
    ]

    init(store: CalendarStore, group: TaskGroup? = nil, onSave: ((TaskGroup) -> Void)? = nil) {
        self.store = store
        self.group = group
        self.onSave = onSave
        _name = State(initialValue: group?.name ?? "")
        _color = State(initialValue: group.map { Color(hex: $0.colorHex) } ?? Color(hex: "#3B82F6"))
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(group == nil ? "Новая группа" : "Редактирование группы")
                .font(.title2.bold())
            Form {
                TextField("Название", text: $name, prompt: Text("Например, Личное"))
                    .focused($nameIsFocused)
                    .accessibilityHint("Обязательное поле")
                ColorPicker("Цвет метки", selection: $color, supportsOpacity: false)
                HStack(spacing: 10) {
                    ForEach(palette, id: \.hex) { swatch in
                        let selected = color.hexString.uppercased() == swatch.hex
                        Button {
                            color = Color(hex: swatch.hex)
                        } label: {
                            Circle()
                                .fill(Color(hex: swatch.hex))
                                .frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(.primary.opacity(0.18), lineWidth: 0.5))
                                .padding(4)
                                .overlay(Circle().strokeBorder(selected ? Color.primary : Color.clear, lineWidth: 2))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(swatch.name)
                        .accessibilityLabel("Цвет: \(swatch.name)")
                        .accessibilityValue(selected ? "Выбран" : "Не выбран")
                        .accessibilityIdentifier("group.color.\(swatch.hex.dropFirst())")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Готовые цвета группы")
                HStack(spacing: 7) {
                    Circle().fill(color).frame(width: 9, height: 9)
                    Text(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Предпросмотр группы" : name)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .contentMargins(.all, 0, for: .scrollContent)
            .clipped()
            HStack {
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
        .frame(width: 450, height: 350)
        .environment(\.locale, Locale(identifier: "ru_RU"))
        .tint(.accentColor)
        .onAppear { nameIsFocused = true }
    }

    private func save() {
        guard canSave else {
            errorMessage = "Введите название группы."
            return
        }
        do {
            let result = try store.saveGroup(id: group?.id, name: name, colorHex: color.hexString)
            onSave?(result)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
