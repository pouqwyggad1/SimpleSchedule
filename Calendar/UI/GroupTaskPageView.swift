import SwiftUI

/// All dates of one group, with the same editable task rows as the calendar.
struct GroupTaskPageView: View {
    let store: CalendarStore
    let group: TaskGroup
    var onAdd: () -> Void
    var onEdit: (PlannerTask) -> Void
    var onDelete: (PlannerTask) -> Void

    var body: some View {
        let tasks = store.tasks(in: group.taskGroupID)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Circle().fill(Color(hex: group.colorHex)).frame(width: 9, height: 9)
                    .accessibilityHidden(true)
                Text(group.isUngrouped ? "Дела без группы · Все даты" : "Все дела группы · Все даты")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text("Невыполненных: \(tasks.filter { !$0.isCompleted }.count)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if tasks.isEmpty {
                ContentUnavailableView {
                    Label(group.isUngrouped ? "Пока нет дел без группы" : "В этой группе пока нет дел", systemImage: "folder")
                } description: {
                    Text(group.isUngrouped ? "Добавьте дело, оставив значение «Без группы»." : "Добавьте дело — выбранная группа уже будет указана в форме.")
                } actions: {
                    Button("Добавить дело", systemImage: "plus", action: onAdd)
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(tasks) { task in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(CalendarMath().fullDate(task.date))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                                TaskRowView(task: task, group: group.isUngrouped ? nil : group,
                                    onToggle: { store.toggleTask(task) },
                                    onEdit: { onEdit(task) }, onDelete: { onDelete(task) })
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(maxWidth: 880, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("groups.taskPage")
    }
}
