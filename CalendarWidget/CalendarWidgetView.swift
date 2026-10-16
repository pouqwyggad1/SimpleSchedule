import SwiftUI
import WidgetKit

struct CalendarWidgetView: View {
    let snapshot: PlannerWidgetSnapshot
    @Environment(\.colorScheme) private var colorScheme
    private var math: CalendarMath { CalendarMath() }
    private var day: CivilDay { CivilDay(date: snapshot.selectedDate) }

    var body: some View {
        GeometryReader { geometry in
            let rowHeight: CGFloat = 22
            let capacity = max(1, min(5, Int((geometry.size.height - 62) / rowHeight)))
            let visible = Array(snapshot.tasks.prefix(capacity))
            VStack(spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    dateColumn
                        .frame(width: max(82, min(108, geometry.size.width * 0.31)), alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        if let error = snapshot.errorMessage {
                            Text(error)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else if visible.isEmpty {
                            Text("На этот день дел нет")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        } else {
                            ForEach(visible) { task in taskRow(task).frame(height: rowHeight - 4) }
                            if snapshot.tasks.count > capacity {
                                Link("Еще дел: \(snapshot.tasks.count - capacity)", destination: WidgetDeepLink.openDay(day).url)
                                    .buttonStyle(.plain)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                navigation
            }
        }
        .padding(14)
        .tint(.accentColor)
        .widgetURL(WidgetDeepLink.openDay(day).url)
        .accessibilityIdentifier("widget.day")
    }

    private var dateColumn: some View {
        Link(destination: WidgetDeepLink.openDay(day).url) {
            VStack(alignment: .leading, spacing: 1) {
                Text(math.weekdayTitle(snapshot.selectedDate).uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(colorScheme == .dark ? Color(red: 1, green: 0.36, blue: 0.38) : Color(red: 0.75, green: 0.06, blue: 0.1))
                    .lineLimit(1).minimumScaleFactor(0.75)
                Text("\(math.dayNumber(snapshot.selectedDate))")
                    .font(.system(size: 40, weight: .regular, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                Text(math.formatted(snapshot.selectedDate, template: "LLLL"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Text(String(math.yearNumber(snapshot.selectedDate)))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(math.fullDate(snapshot.selectedDate))
    }

    private func taskRow(_ task: PlannerTask) -> some View {
        let group = snapshot.group(for: task)
        let color = group.map { Color(widgetHex: $0.colorHex) } ?? Color.secondary
        return HStack(spacing: 6) {
            Button(intent: CompletePlannerTaskIntent(taskID: task.id.uuidString, completed: !task.isCompleted)) {
                ZStack {
                    Circle().strokeBorder(color, lineWidth: 1.5)
                    if task.isCompleted {
                        Circle().fill(color).padding(2)
                        Image(systemName: "checkmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(checkmarkColor(hex: group?.colorHex))
                    }
                }
                .frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 0.5))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(task.isCompleted ? "Вернуть в невыполненные" : "Выполнить"): \(task.title). Группа: \(group?.name ?? "Без группы")")
            Link(destination: WidgetDeepLink.openDay(day).url) {
                Text(task.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(task.isCompleted ? .secondary : .primary)
                    .strikethrough(task.isCompleted)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
    }

    private func checkmarkColor(hex: String?) -> Color {
        guard let hex, let rgb = UInt64(hex.replacingOccurrences(of: "#", with: ""), radix: 16) else { return .primary }
        let brightness = (Double((rgb >> 16) & 255) * 0.299 + Double((rgb >> 8) & 255) * 0.587 + Double(rgb & 255) * 0.114) / 255
        return brightness > 0.65 ? .black : .white
    }

    private var navigation: some View {
        HStack(spacing: 5) {
            Button(intent: ShiftPlannerWidgetDayIntent(amount: -1)) {
                Image(systemName: "chevron.left").frame(width: 20, height: 24)
            }
            .accessibilityLabel("Предыдущий день")
            .disabled(!math.isSupported(math.shifting(snapshot.selectedDate, by: -1, mode: .day)))
            Button(intent: PlannerWidgetTodayIntent()) {
                Text("Сегодня").font(.system(size: 11, weight: .medium)).frame(height: 24)
            }
            .accessibilityLabel("Показывать сегодняшний день")
            Button(intent: ShiftPlannerWidgetDayIntent(amount: 1)) {
                Image(systemName: "chevron.right").frame(width: 20, height: 24)
            }
            .accessibilityLabel("Следующий день")
            .disabled(!math.isSupported(math.shifting(snapshot.selectedDate, by: 1, mode: .day)))
            Spacer(minLength: 4)
            Link(destination: WidgetDeepLink.chooseDate(day).url) {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                    Text(math.formatted(snapshot.selectedDate, template: "dd.MM.yyyy"))
                        .monospacedDigit()
                }
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1).minimumScaleFactor(0.8)
                .padding(.horizontal, 7)
                .frame(height: 24)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            .accessibilityLabel("Выбрать точную дату для виджета")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

private extension Color {
    init(widgetHex value: String) {
        let text = value.hasPrefix("#") ? String(value.dropFirst()) : value
        let rgb = UInt64(text, radix: 16) ?? 0x8E8E93
        self.init(.sRGB, red: Double((rgb >> 16) & 255) / 255,
            green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: 1)
    }
}
