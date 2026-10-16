import SwiftUI

struct ScheduleMonthGridView: View {
    let store: CalendarStore
    @Binding var selection: Date
    let today: Date
    var onAdd: (Date) -> Void
    var onEdit: (UniversityLesson) -> Void
    var onDelete: (UniversityLesson) -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var math: CalendarMath { CalendarMath() }
    private let weekdays = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]
    private var weekendColor: Color { scheduleWeekendColor(colorScheme) }

    var body: some View {
        let days = math.monthDays(containing: selection)
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(0..<7, id: \.self) { index in
                    Text(weekdays[index])
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(index >= 5 ? weekendColor : Color.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 5)
            ForEach(0..<(days.count / 7), id: \.self) { week in
                HStack(spacing: 6) {
                    ForEach(0..<7, id: \.self) { weekday in
                        dayCell(days[week * 7 + weekday], weekend: weekday >= 5)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .accessibilityIdentifier("schedule.month")
    }

    private func dayCell(_ date: Date, weekend: Bool) -> some View {
        let lessons = store.lessons(on: date)
        let selected = math.isSameDay(date, selection)
        let isToday = math.isSameDay(date, today)
        let inMonth = math.isSameMonth(date, selection)
        let summary = UniversityLesson.summary(lessons)
        return Button {
            if math.isSupported(date) { selection = date }
        } label: {
            MonthDayCellLayout(day: math.dayNumber(date), selected: selected, isToday: isToday,
                               foreground: weekend && inMonth ? weekendColor : .primary) { compact in
                if let summary {
                    Text(summary)
                        .font(.system(size: compact ? 8 : 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                }
            }
            .background(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5)
            }
            .opacity(inMonth ? 1 : 0.42)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!math.isSupported(date))
        .help("\(math.fullDate(date)). \(summary?.replacingOccurrences(of: "\n", with: ", ") ?? "Нет пар")")
        .accessibilityLabel("\(math.fullDate(date))\(isToday ? ", сегодня" : ""). \(summary?.replacingOccurrences(of: "\n", with: ", ") ?? "Нет пар")")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button("Добавить пару", systemImage: "plus") { onAdd(date) }
            if !lessons.isEmpty {
                Divider()
                ForEach(lessons) { lesson in
                    Menu("\(lesson.timeRange) · \(lesson.subject)") {
                        Button("Редактировать", systemImage: "pencil") { onEdit(lesson) }
                        Button("Удалить пару…", systemImage: "trash", role: .destructive) { onDelete(lesson) }
                    }
                }
            }
        }
    }
}

struct ScheduleWeekView: View {
    let store: CalendarStore
    @Binding var selection: Date
    let today: Date
    var onAdd: (Date) -> Void
    var onEdit: (UniversityLesson) -> Void
    var onDelete: (UniversityLesson) -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var math: CalendarMath { CalendarMath() }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            ForEach(Array(math.weekDays(containing: selection).enumerated()), id: \.element) { index, date in
                column(date, weekend: index >= 5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("schedule.week")
    }

    private func column(_ date: Date, weekend: Bool) -> some View {
        let selected = math.isSameDay(date, selection)
        let isToday = math.isSameDay(date, today)
        let lessons = store.lessons(on: date)
        return VStack(spacing: 0) {
            Button {
                if math.isSupported(date) { selection = date }
            } label: {
                VStack(spacing: 5) {
                    Text(scheduleCapitalized(math.shortWeekdayTitle(date)))
                        .font(.caption.weight(.semibold))
                    Text("\(math.dayNumber(date))")
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                    Text(math.formatted(date, template: "MMM"))
                        .font(.caption2)
                }
                .foregroundStyle(weekend ? scheduleWeekendColor(colorScheme) : Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(selected ? Color.accentColor.opacity(0.13) : .clear)
                .overlay(alignment: .bottom) {
                    if isToday { Capsule().fill(Color.accentColor).frame(width: 25, height: 3) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!math.isSupported(date))
            .accessibilityLabel("\(math.fullDate(date))\(isToday ? ", сегодня" : ""). \(UniversityLesson.lessonCountText(lessons.count))")
            .accessibilityAddTraits(selected ? .isSelected : [])
            Divider()
            ScrollView {
                LazyVStack(spacing: 8) {
                    if lessons.isEmpty {
                        Text("Нет пар")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 20)
                    }
                    ForEach(lessons) { lesson in
                        ScheduleLessonCard(lesson: lesson, compact: true,
                            onEdit: { onEdit(lesson) }, onDelete: { onDelete(lesson) })
                    }
                }
                .padding(7)
            }
            .scrollBounceBehavior(.basedOnSize)
            Button { onAdd(date) } label: {
                Image(systemName: "plus")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .disabled(!math.isSupported(date))
            .help("Добавить пару на \(math.formatted(date, template: "d MMMM"))")
            .accessibilityLabel("Добавить пару на \(math.formatted(date, template: "d MMMM"))")
            .background(.primary.opacity(0.035))
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? Color.accentColor.opacity(0.45) : .primary.opacity(0.07), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

struct ScheduleDayListView: View {
    let store: CalendarStore
    let date: Date
    let showFullDate: Bool
    var onAdd: () -> Void
    var onEdit: (UniversityLesson) -> Void
    var onDelete: (UniversityLesson) -> Void

    private var math: CalendarMath { CalendarMath() }

    var body: some View {
        let lessons = store.lessons(on: date)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(scheduleCapitalized(showFullDate ? math.weekdayTitle(date) : math.formatted(date, template: "d MMMM")))
                        .font(showFullDate ? .title3.weight(.semibold) : .headline)
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .accessibilityAddTraits(.isHeader)
                    Text(showFullDate ? math.formatted(date, template: "d MMMM yyyy") : "Расписание на выбранный день")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(UniversityLesson.lessonCountText(lessons.count))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.primary.opacity(0.06), in: Capsule())
            }
            if lessons.isEmpty {
                ContentUnavailableView {
                    Label("На этот день пар нет", systemImage: "graduationcap")
                } description: {
                    Text("Добавьте занятие в расписание.")
                } actions: {
                    Button("Добавить пару", systemImage: "plus", action: onAdd)
                        .buttonStyle(.bordered)
                        .disabled(!math.isSupported(date))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(lessons) { lesson in
                            ScheduleLessonCard(lesson: lesson,
                                onEdit: { onEdit(lesson) }, onDelete: { onDelete(lesson) })
                        }
                    }
                    .padding(.bottom, 6)
                }
                .scrollBounceBehavior(.basedOnSize)
                Button("Добавить пару", systemImage: "plus", action: onAdd)
                    .buttonStyle(.borderless)
                    .disabled(!math.isSupported(date))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("schedule.day")
    }
}

private struct ScheduleLessonCard: View {
    let lesson: UniversityLesson
    var compact = false
    var onEdit: () -> Void
    var onDelete: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var lessonBorder: Color {
        let value = lesson.kind.lowercased()
        if value.contains("лаборатор") {
            return Color(hex: colorScheme == .dark ? "#F5B34D" : "#BE780E")
        }
        if value.contains("практ") {
            return Color(hex: colorScheme == .dark ? "#52C878" : "#16824A")
        }
        return Color(hex: colorScheme == .dark ? "#6DA7EB" : "#2878C8")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 4) {
                Text(lesson.timeRange)
                    .font(.system(size: compact ? 10 : 12, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(.tint)
                Spacer(minLength: 0)
                Menu {
                    Button("Редактировать", systemImage: "pencil", action: onEdit)
                    Button("Удалить пару…", systemImage: "trash", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 14, height: 16)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Действия с парой \(lesson.subject)")
            }
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(lesson.subject)
                        .font(compact ? .callout.weight(.semibold) : .body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(compact ? 4 : nil)
                        .fixedSize(horizontal: false, vertical: true)
                    if !lesson.kind.isEmpty {
                        detail("Вид: \(lesson.kind)", symbol: "bookmark")
                    }
                    if let subgroup = lesson.subgroup, !subgroup.isEmpty {
                        detail("Подгруппа: \(subgroup)", symbol: "person.2")
                    }
                    if !lesson.room.isEmpty {
                        detail("Кабинет: \(lesson.room)", symbol: "door.left.hand.open")
                    }
                    if !lesson.teacher.isEmpty {
                        detail("Руководитель: \(lesson.teacher)", symbol: "person")
                    }
                    if !lesson.homework.isEmpty {
                        detail("ДЗ: \(lesson.homework)", symbol: "text.book.closed", lineLimit: compact ? 4 : nil)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Редактировать пару: \(lesson.subject)")
            .accessibilityLabel("\(lesson.subject), \(lesson.timeRange). Вид: \(lesson.kind.isEmpty ? "не указан" : lesson.kind). Подгруппа: \(lesson.subgroup ?? "все"). Кабинет: \(lesson.room.isEmpty ? "не указан" : lesson.room). Руководитель: \(lesson.teacher.isEmpty ? "не указан" : lesson.teacher). Домашнее задание: \(lesson.homework.isEmpty ? "не указано" : lesson.homework)")
        }
        .padding(compact ? 8 : 12)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(lessonBorder, lineWidth: 0.8)
                .allowsHitTesting(false)
        }
        .contextMenu {
            Button("Редактировать", systemImage: "pencil", action: onEdit)
            Button("Удалить пару…", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }

    private func detail(_ title: String, symbol: String, lineLimit: Int? = nil) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(lineLimit ?? (compact ? 2 : nil))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LessonEditorView: View {
    let store: CalendarStore
    let lesson: UniversityLesson?
    let durationMinutes: Int

    @Environment(\.dismiss) private var dismiss
    @State private var subject: String
    @State private var date: Date
    @State private var startTime: Date
    @State private var endTime: Date
    @State private var homework: String
    @State private var room: String
    @State private var teacher: String
    @State private var kind: String
    @State private var subgroup: String
    @State private var automaticEndExceedsDay = false
    @State private var errorMessage: String?
    @FocusState private var subjectIsFocused: Bool

    // DatePicker is used solely to edit wall-clock minutes, independent of the
    // lesson's date and the Mac's time zone or daylight-saving transition.
    private var clock: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "ru_RU")
        return calendar
    }
    private var startMinute: Int { minute(of: startTime) }
    private var endMinute: Int { minute(of: endTime) }
    private var timeIsValid: Bool { !automaticEndExceedsDay && startMinute < endMinute }
    private var endTimeBinding: Binding<Date> {
        Binding(get: { endTime }, set: { endTime = $0; automaticEndExceedsDay = false })
    }
    private var canSave: Bool {
        !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            CalendarMath().isSupported(date) && timeIsValid
    }

    init(store: CalendarStore, date: Date, lesson: UniversityLesson? = nil, durationMinutes: Int = 90) {
        self.store = store
        self.lesson = lesson
        self.durationMinutes = min(360, max(1, durationMinutes))
        _subject = State(initialValue: lesson?.subject ?? "")
        _date = State(initialValue: lesson?.date ?? date)
        _startTime = State(initialValue: Date(timeIntervalSinceReferenceDate: Double((lesson?.startMinute ?? 540) * 60)))
        _endTime = State(initialValue: Date(timeIntervalSinceReferenceDate: Double((lesson?.endMinute ?? (540 + min(360, max(1, durationMinutes)))) * 60)))
        _homework = State(initialValue: lesson?.homework ?? "")
        _room = State(initialValue: lesson?.room ?? "")
        _teacher = State(initialValue: lesson?.teacher ?? "")
        _kind = State(initialValue: lesson?.kind ?? "")
        _subgroup = State(initialValue: lesson?.subgroup ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(lesson == nil ? "Новая пара" : "Редактирование пары")
                .font(.title2.bold())
            Form {
                Section {
                    TextField("Предмет", text: $subject, prompt: Text("Название предмета"))
                        .focused($subjectIsFocused)
                        .accessibilityHint("Обязательное поле")
                        .accessibilityIdentifier("schedule.subject")
                    DatePicker("Дата", selection: $date, in: CalendarMath().supportedDates, displayedComponents: .date)
                        .datePickerStyle(.field)
                }
                Section("Время пары") {
                    DatePicker("Начало", selection: $startTime, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.field)
                        .environment(\.calendar, clock)
                        .environment(\.timeZone, clock.timeZone)
                        .accessibilityIdentifier("schedule.startTime")
                    DatePicker("Окончание", selection: endTimeBinding, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.field)
                        .environment(\.calendar, clock)
                        .environment(\.timeZone, clock.timeZone)
                        .accessibilityIdentifier("schedule.endTime")
                    if !timeIsValid {
                        Text(automaticEndExceedsDay ? "По заданной длительности окончание выходит за пределы дня. Укажите время окончания вручную." : "Окончание должно быть позже начала в пределах одного дня.")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Section("Дополнительно — необязательно") {
                    TextField("Вид занятия", text: $kind, prompt: Text("Лекция, практика, лабораторная…"))
                    TextField("Подгруппа", text: $subgroup, prompt: Text("Пусто — все подгруппы"))
                    TextField("Кабинет", text: $room, prompt: Text("Номер или название"))
                    TextField("Руководитель", text: $teacher, prompt: Text("Имя руководителя"))
                }
                Section("Домашнее задание — необязательно") {
                    TextEditor(text: $homework)
                        .font(.body)
                        .frame(minHeight: 65, idealHeight: 85)
                        .accessibilityLabel("Домашнее задание")
                        .accessibilityIdentifier("schedule.homework")
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
                Text("Предмет, дата и время обязательны")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Button("Отмена") { dismiss() }
                    .plannerSheetAction()
                    .keyboardShortcut(.cancelAction)
                Button("Сохранить", action: save)
                    .plannerSheetAction()
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 520, height: 550)
        .environment(\.locale, Locale(identifier: "ru_RU"))
        .tint(.accentColor)
        .onAppear { subjectIsFocused = true }
        .onChange(of: startTime) { _, value in
            let end = minute(of: value) + durationMinutes
            guard end < 1440 else { automaticEndExceedsDay = true; return }
            endTime = Date(timeIntervalSinceReferenceDate: Double(end * 60))
            automaticEndExceedsDay = false
        }
    }

    private func minute(of date: Date) -> Int {
        let components = clock.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private func save() {
        guard canSave else {
            errorMessage = !timeIsValid ? "Укажите окончание позже начала в пределах одного дня." : "Введите предмет и выберите корректную дату."
            return
        }
        do {
            try store.saveLesson(id: lesson?.id, subject: subject, date: date,
                startMinute: startMinute, endMinute: endMinute,
                homework: homework, room: room, teacher: teacher,
                kind: kind, subgroup: subgroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : subgroup)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private func scheduleWeekendColor(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? Color(red: 1, green: 0.54, blue: 0.5) : Color(red: 0.71, green: 0.14, blue: 0.1)
}

private func scheduleCapitalized(_ text: String) -> String {
    guard let first = text.first else { return text }
    return first.uppercased() + text.dropFirst()
}
