import AppKit
import SwiftUI

extension View {
    /// Native buttons share a fixed footprint in every editor footer.
    func plannerSheetAction() -> some View {
        self
            .controlSize(.regular)
            .buttonSizing(.flexible)
            .frame(width: 100, height: 28)
    }
}

extension Color {
    init(hex: String) {
        let value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else {
            self = .blue
            return
        }
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xff) / 255,
            green: Double((rgb >> 8) & 0xff) / 255,
            blue: Double(rgb & 0xff) / 255,
            opacity: 1
        )
    }

    var hexString: String {
        let rgb = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.systemBlue
        return String(
            format: "#%02X%02X%02X",
            Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()),
            Int((rgb.blueComponent * 255).rounded())
        )
    }
}

struct GroupBadgeView: View {
    let group: TaskGroup?

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(group.map { Color(hex: $0.colorHex) } ?? .secondary)
                .frame(width: 7, height: 7)
                .overlay(Circle().strokeBorder(.primary.opacity(0.18), lineWidth: 0.5))
                .accessibilityHidden(true)
            Text(group?.name ?? "Без группы")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help(group?.name ?? "Без группы")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Группа: \(group?.name ?? "Без группы")")
    }
}

struct TaskRowView: View {
    let task: PlannerTask
    let group: TaskGroup?
    var onToggle: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void
    var compact: Bool = false

    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        toggleButton
                        Spacer(minLength: 0)
                        actionsMenu
                    }
                    contentButton
                }
            } else {
                HStack(alignment: .top, spacing: 9) {
                    toggleButton
                    contentButton
                    actionsMenu
                }
            }
        }
        .padding(compact ? 8 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(task.isCompleted ? 0.35 : 0.65), in: RoundedRectangle(cornerRadius: 10))
        .contextMenu {
            Button("Редактировать", systemImage: "pencil", action: onEdit)
            Button(task.isCompleted ? "Вернуть в невыполненные" : "Отметить выполненным", action: onToggle)
            Divider()
            Button("Удалить…", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }

    private var toggleButton: some View {
        Button(action: onToggle) {
            Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: compact ? 16 : 18))
                .foregroundStyle(task.isCompleted ? Color.accentColor : Color.secondary)
                .frame(width: compact ? 18 : 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(task.isCompleted ? "Вернуть в невыполненные" : "Отметить выполненным")
        .accessibilityLabel(task.isCompleted ? "Вернуть в невыполненные: \(task.title)" : "Выполнить: \(task.title)")
    }

    private var contentButton: some View {
        Button(action: onEdit) {
            VStack(alignment: .leading, spacing: 5) {
                Text(task.title)
                    .font(compact ? .callout : .body)
                    .foregroundStyle(task.isCompleted ? .secondary : .primary)
                    .strikethrough(task.isCompleted)
                    .lineLimit(compact ? 5 : 6)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                GroupBadgeView(group: group)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !task.note.isEmpty && !compact {
                    Label("Есть заметка", systemImage: "note.text")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("Редактировать дело: \(task.title)")
        .accessibilityLabel("\(task.title), \(task.isCompleted ? "выполнено" : "не выполнено"), \(group?.name ?? "Без группы")")
        .accessibilityHint("Открывает редактирование дела")
    }

    private var actionsMenu: some View {
        Menu {
            Button("Редактировать", systemImage: "pencil", action: onEdit)
            Button(task.isCompleted ? "Вернуть в невыполненные" : "Отметить выполненным", action: onToggle)
            Divider()
            Button("Удалить…", systemImage: "trash", role: .destructive, action: onDelete)
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 15, height: 20)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Действия с делом")
        .accessibilityLabel("Действия с делом \(task.title)")
    }
}

struct EmptyDayView: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("На этот день дел нет")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Добавить дело", systemImage: "plus", action: onAdd)
                .buttonStyle(.bordered)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
