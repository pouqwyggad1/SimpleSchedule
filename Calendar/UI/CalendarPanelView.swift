import AppKit
import SwiftUI

private struct EditorDestination: Identifiable {
    enum Content { case task(Date, PlannerTask?, UUID?), lesson(Date, UniversityLesson?), groups, settings, jump, widgetDate(Date) }
    let id = UUID()
    let content: Content
}

/// One selection is shared by every calendar mode. No view owns a second date.
struct CalendarPanelView: View {
    @Bindable var store: CalendarStore
    @Bindable var settings: AppSettings
    @Bindable var login: LoginItemManager
    @Bindable var importer: ISTUImportController
    @Bindable var cloud: CloudController
    @State private var navigationState = PlannerNavigation()
    @State private var today = Date()
    @State private var destination: EditorDestination?
    @State private var pendingDeletion: PlannerTask?
    @State private var pendingLessonDeletion: UniversityLesson?
    @State private var isScheduleMode = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var math: CalendarMath { CalendarMath() }
    private var selectedDate: Date { navigationState.selectedDate }
    private var mode: CalendarMode { navigationState.mode }
    private var selectedGroup: TaskGroup? {
        if navigationState.selectedGroupID == TaskGroup.ungrouped.id { return .ungrouped }
        return store.group(id: navigationState.selectedGroupID)
    }
    private var selectedDateBinding: Binding<Date> {
        Binding(get: { navigationState.selectedDate }, set: {
            navigationState.selectedDate = $0
            navigationState.showCalendar(mode)
        })
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header(width: geometry.size.width)
                Divider().padding(.horizontal, 20)
                navigation
                pageContent(size: geometry.size)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                footer
            }
            .background {
                ZStack {
                    PanelMaterialView(theme: settings.theme)
                    Color(nsColor: .windowBackgroundColor)
                        .opacity(reduceTransparency ? 1 : settings.backgroundOpacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .environment(cloud)
        .environment(\.locale, Locale(identifier: "ru_RU"))
        .environment(\.calendar, math.calendar)
        .preferredColorScheme(settings.theme.preferredColorScheme)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: mode)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: navigationState.selectedGroupID)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isScheduleMode)
        .sheet(item: $destination) { route in
            switch route.content {
            case let .task(date, task, groupID):
                TaskEditorView(store: store, date: date, task: task, defaultGroupID: groupID)
            case let .lesson(date, lesson):
                LessonEditorView(store: store, date: date, lesson: lesson, durationMinutes: importer.settings.durationMinutes)
            case .groups:
                GroupManagerView(store: store)
            case .settings:
                SettingsView(settings: settings, login: login, importer: importer, cloud: cloud, store: store)
            case .jump:
                JumpToDateView(date: selectedDate) { selectedDateBinding.wrappedValue = $0 }
            case .widgetDate(let date):
                JumpToDateView(date: date) { selected in
                    do { try WidgetBridge.selectDate(selected) }
                    catch { store.errorMessage = error.localizedDescription }
                }
            }
        }
        .confirmationDialog("Удалить дело?", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        ), titleVisibility: .visible) {
            Button("Удалить дело", role: .destructive) {
                if let task = pendingDeletion { store.deleteTask(task) }
                pendingDeletion = nil
            }
            Button("Отмена", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(pendingDeletion?.title ?? "")
        }
        .confirmationDialog("Удалить занятие?", isPresented: Binding(
            get: { pendingLessonDeletion != nil },
            set: { if !$0 { pendingLessonDeletion = nil } }
        ), titleVisibility: .visible) {
            Button("Удалить занятие", role: .destructive) {
                if let lesson = pendingLessonDeletion { store.deleteLesson(lesson) }
                pendingLessonDeletion = nil
            }
            Button("Отмена", role: .cancel) { pendingLessonDeletion = nil }
        } message: { Text(pendingLessonDeletion?.subject ?? "") }
        .alert("Локальное хранилище", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("Понятно") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .calendarPanelWillShow)) { _ in refreshToday() }
        .onReceive(NotificationCenter.default.publisher(for: .calendarSystemDayChanged)) { _ in refreshToday() }
        .onReceive(NotificationCenter.default.publisher(for: .calendarNotificationDayRequested)) { notification in
            guard let day = notification.userInfo?["day"] as? CivilDay, let date = day.date(in: .current), math.isSupported(date) else { return }
            selectedDateBinding.wrappedValue = date
            navigationState.showCalendar(.day)
            isScheduleMode = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .calendarWidgetDateRequested)) { notification in
            guard let date = notification.userInfo?["date"] as? Date else { return }
            destination = EditorDestination(content: .widgetDate(date))
        }
        .onReceive(NotificationCenter.default.publisher(for: .calendarWidgetDayRequested)) { notification in
            guard let date = notification.userInfo?["date"] as? Date, math.isSupported(date) else { return }
            selectedDateBinding.wrappedValue = math.startOfDay(date)
            navigationState.showCalendar(.day)
            isScheduleMode = false
            destination = nil
        }
        .onChange(of: store.groups.map(\.id)) { _, _ in
            navigationState.clearGroupIfMissing(in: store.groups)
        }
    }

    private func header(width: CGFloat) -> some View {
        // Layout depends on the screen width, never on the chosen content mode.
        // Equal slots on either side keep the segmented control centered.
        let compactRefresh = width < 1_120
        let refreshWidth: CGFloat = compactRefresh ? 32 : 180
        return Group {
            if width >= 820 {
                ZStack {
                    HStack {
                        brand.frame(width: 200, alignment: .leading)
                        Spacer(minLength: 0)
                        headerActions
                    }
                    HStack(spacing: 12) {
                        refreshScheduleButton(compact: compactRefresh)
                            .frame(width: refreshWidth)
                            .opacity(isScheduleMode ? 1 : 0)
                            .allowsHitTesting(isScheduleMode)
                            .accessibilityHidden(!isScheduleMode)
                        modePicker.frame(width: 285)
                        Color.clear.frame(width: refreshWidth, height: 1)
                    }
                }
                .frame(height: 38)
            } else {
                VStack(spacing: 10) {
                    HStack { brand; Spacer(minLength: 8); headerActions }
                        .frame(height: 38)
                    HStack(spacing: 12) {
                        refreshScheduleButton(compact: true)
                            .frame(width: 32)
                            .opacity(isScheduleMode ? 1 : 0)
                            .allowsHitTesting(isScheduleMode)
                            .accessibilityHidden(!isScheduleMode)
                        modePicker.frame(maxWidth: 285)
                        Color.clear.frame(width: 32, height: 1)
                    }
                    .frame(height: 28)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar")
                .font(.title2.weight(.medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(isScheduleMode ? "Расписание" : "Календарь").font(.headline)
                Text(isScheduleMode ? "Занятия в университете" : "Время для важного")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var modePicker: some View {
        Picker("Вид календаря", selection: Binding(
            get: { mode }, set: { navigationState.showCalendar($0) }
        )) {
            ForEach(CalendarMode.allCases) { item in Text(item.title).tag(item) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("calendar.mode")
    }

    private var appMenu: some View {
        Menu {
            Button("Настройки…", systemImage: "gearshape") {
                login.refresh()
                destination = EditorDestination(content: .settings)
            }
            Divider()
            Button("Завершить приложение", systemImage: "power") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "gearshape").font(.title3)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Настройки и завершение приложения")
        .accessibilityLabel("Меню приложения")
    }

    private var headerActions: some View {
        HStack(spacing: 12) {
            Button { isScheduleMode.toggle() } label: {
                Image(systemName: "graduationcap")
                    .font(.title3)
                    .frame(width: 30, height: 28)
                    .foregroundStyle(isScheduleMode ? Color.accentColor : Color.primary)
                    .background(isScheduleMode ? Color.accentColor.opacity(0.15) : .clear,
                                in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .help(isScheduleMode ? "Вернуться к делам" : "Расписание университета")
            .accessibilityLabel("Режим расписания")
            .accessibilityValue(isScheduleMode ? "Включен" : "Выключен")
            .accessibilityAddTraits(isScheduleMode ? .isSelected : [])
            .accessibilityIdentifier("schedule.toggle")
            appMenu
        }
        .fixedSize()
    }

    private func refreshScheduleButton(compact: Bool) -> some View {
        Button {
            if importer.isLoading { importer.cancel() }
            else if importer.settings.groupID == nil { destination = EditorDestination(content: .settings) }
            else { Task { await importer.refresh(date: selectedDate, mode: mode) } }
        } label: {
            HStack(spacing: 6) {
                if importer.isLoading {
                    ProgressView().controlSize(.small).frame(width: 14, height: 14)
                } else {
                    Image(systemName: "arrow.clockwise").frame(width: 14, height: 14)
                }
                if !compact {
                    Text(importer.isLoading ? "Отмена обновления" : "Обновить расписание")
                        .lineLimit(1)
                        .frame(width: 145, alignment: .leading)
                }
            }
        }
        .help(importer.isLoading ? "\(importer.statusMessage ?? "Обновление расписания…") Нажмите, чтобы отменить." : "Загрузить с сайта ИРНИТУ недели показанного периода")
        .accessibilityLabel(importer.isLoading ? "Отменить обновление расписания" : "Обновить расписание")
        .accessibilityIdentifier("istu.refreshSchedule")
        .fixedSize()
        .popover(isPresented: Binding(
            get: { isScheduleMode && importer.errorMessage != nil && destination == nil },
            set: { if !$0 { importer.clearError() } }
        ), arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Не удалось обновить расписание").font(.headline)
                Text(importer.errorMessage ?? "").font(.callout).textSelection(.enabled)
                HStack {
                    Button("Настройки") {
                        importer.clearError()
                        destination = EditorDestination(content: .settings)
                    }
                    Spacer()
                    Button("Закрыть") { importer.clearError() }
                }
            }
            .padding(18)
            .frame(width: 340)
        }
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    navigationButtons
                    groupLegend
                        .opacity(isScheduleMode ? 0 : 1)
                        .allowsHitTesting(!isScheduleMode)
                        .accessibilityHidden(isScheduleMode)
                    dateControls.fixedSize()
                    addButton
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack { navigationButtons; Spacer(); addButton }
                    HStack(spacing: 12) {
                        groupLegend
                            .opacity(isScheduleMode ? 0 : 1)
                            .allowsHitTesting(!isScheduleMode)
                            .accessibilityHidden(isScheduleMode)
                        dateControls.fixedSize()
                    }
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(periodTitle)
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if !isScheduleMode && selectedGroup != nil {
                    Button("К календарю", systemImage: "arrow.uturn.backward") {
                        navigationState.showCalendar(mode)
                    }
                    .buttonStyle(.borderless)
                    .help("Вернуться к прежнему виду календаря")
                } else if mode == .month {
                    Text(isScheduleMode ? "Выберите день, чтобы увидеть занятия" : "Выберите день, чтобы увидеть дела")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).multilineTextAlignment(.trailing)
                }
            }
            .frame(height: 28)
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    private var navigationButtons: some View {
        HStack(spacing: 8) {
            Button { shift(-1) } label: { Image(systemName: "chevron.left").frame(width: 16, height: 18) }
                .help(backwardLabel).accessibilityLabel(backwardLabel)
            Button("Сегодня") { selectedDateBinding.wrappedValue = math.startOfDay(Date()); refreshToday() }
                .accessibilityIdentifier("calendar.today")
            Button { shift(1) } label: { Image(systemName: "chevron.right").frame(width: 16, height: 18) }
                .help(forwardLabel).accessibilityLabel(forwardLabel)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .fixedSize()
    }

    private var groupLegend: some View {
        GroupLegendView(groups: store.groups, selectedGroupID: navigationState.selectedGroupID) { group in
            navigationState.toggleGroup(group.id)
        }
        .layoutPriority(-1)
    }

    private var dateControls: some View {
        HStack(spacing: 8) {
            Button {
                destination = EditorDestination(content: .groups)
            } label: { Label("Группы", systemImage: "square.stack.3d.up") }
                .help("Управление группами")
                .accessibilityLabel("Управление группами")
                .accessibilityIdentifier("groups.manage")
                .opacity(isScheduleMode ? 0 : 1)
                .allowsHitTesting(!isScheduleMode)
                .accessibilityHidden(isScheduleMode)
            DatePicker("Дата", selection: selectedDateBinding, in: supportedDates, displayedComponents: .date)
                .datePickerStyle(.field)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("calendar.selectedDate")
            Button {
                destination = EditorDestination(content: .jump)
            } label: { Image(systemName: "calendar.badge.clock") }
                .help("Перейти к произвольной дате")
                .accessibilityLabel("Перейти к дате")
        }
    }

    private var addButton: some View {
        Button {
            if isScheduleMode { addLesson(on: selectedDate) } else { addTask(on: selectedDate) }
        } label: {
            Label(isScheduleMode ? "Занятие" : "Добавить", systemImage: "plus")
                .frame(width: 90)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut("n")
        .help(isScheduleMode ? "Добавить занятие на выбранную дату" : "Добавить дело на выбранную дату")
        .accessibilityIdentifier(isScheduleMode ? "lesson.add" : "task.add")
        .fixedSize()
    }

    @ViewBuilder private func calendarContent(size: CGSize) -> some View {
        switch mode {
        case .month:
            HStack(alignment: .top, spacing: size.width < 820 ? 10 : 16) {
                MonthGridView(store: store, selection: selectedDateBinding, today: today)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(.primary.opacity(0.09)).frame(width: 1)
                dayList(showFullDate: false)
                    .frame(width: monthSidebarWidth(size))
            }
        case .week:
            WeekColumnsView(store: store, selection: selectedDateBinding, today: today,
                onAdd: addTask, onEdit: editTask, onDelete: { pendingDeletion = $0 })
        case .day:
            dayList(showFullDate: true)
                .frame(maxWidth: 800)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private func pageContent(size: CGSize) -> some View {
        if isScheduleMode {
            scheduleContent(size: size)
        } else if let group = selectedGroup {
            GroupTaskPageView(store: store, group: group,
                onAdd: { addTask(on: selectedDate) }, onEdit: editTask,
                onDelete: { pendingDeletion = $0 })
        } else {
            calendarContent(size: size)
        }
    }

    @ViewBuilder private func scheduleContent(size: CGSize) -> some View {
        switch mode {
        case .month:
            HStack(alignment: .top, spacing: size.width < 820 ? 10 : 16) {
                ScheduleMonthGridView(store: store, selection: selectedDateBinding, today: today,
                    onAdd: addLesson, onEdit: editLesson, onDelete: { pendingLessonDeletion = $0 })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(.primary.opacity(0.09)).frame(width: 1)
                ScheduleDayListView(store: store, date: selectedDate, showFullDate: false,
                    onAdd: { addLesson(on: selectedDate) }, onEdit: editLesson,
                    onDelete: { pendingLessonDeletion = $0 })
                    .frame(width: monthSidebarWidth(size))
            }
        case .week:
            ScheduleWeekView(store: store, selection: selectedDateBinding, today: today,
                onAdd: addLesson, onEdit: editLesson, onDelete: { pendingLessonDeletion = $0 })
        case .day:
            ScheduleDayListView(store: store, date: selectedDate, showFullDate: true,
                onAdd: { addLesson(on: selectedDate) }, onEdit: editLesson,
                onDelete: { pendingLessonDeletion = $0 })
                .frame(maxWidth: 800).frame(maxWidth: .infinity)
        }
    }

    private func monthSidebarWidth(_ size: CGSize) -> CGFloat {
        min(330, max(190, size.width * 0.31))
    }

    private func dayList(showFullDate: Bool) -> some View {
        DayTaskListView(store: store, date: selectedDate, showFullDate: showFullDate,
            onAdd: { addTask(on: selectedDate) }, onEdit: editTask,
            onDelete: { pendingDeletion = $0 })
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if login.requiresApproval || login.errorMessage != nil {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.circle")
                    Text(login.requiresApproval ? "Автозапуск ожидает подтверждения macOS" : "Не удалось включить автозапуск")
                        .lineLimit(2)
                    Spacer()
                    Button("Настройки") { destination = EditorDestination(content: .settings) }
                        .buttonStyle(.borderless)
                }
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: isScheduleMode ? "graduationcap" : "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 16)
                if isScheduleMode {
                    Text("На выбранный день: \(UniversityLesson.lessonCountText(store.lessons(on: selectedDate).count))")
                } else {
                    let tasks = selectedGroup.map { store.tasks(in: $0.taskGroupID) } ?? store.tasks(on: selectedDate)
                    Text("Выполнено: \(tasks.filter(\.isCompleted).count) из \(tasks.count)")
                }
                Spacer()
                Text("Сегодня · \(today.formatted(.dateTime.day().month(.wide).locale(Locale(identifier: "ru_RU"))))")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 22)
        .padding(.vertical, 11)
        .background(.primary.opacity(0.035))
    }

    private var periodTitle: String {
        if !isScheduleMode, let group = selectedGroup { return group.name }
        switch mode {
        case .month: return initialCapital(formatted(selectedDate, "LLLL yyyy"))
        case .week:
            let dates = math.weekDays(containing: selectedDate)
            guard let first = dates.first, let last = dates.last else { return "Неделя" }
            return "\(formatted(first, "d MMM")) — \(formatted(last, "d MMM yyyy"))"
        case .day: return formatted(selectedDate, "d MMMM yyyy, EEEE")
        }
    }

    private var backwardLabel: String {
        switch mode { case .month: "Предыдущий месяц"; case .week: "Предыдущая неделя"; case .day: "Предыдущий день" }
    }
    private var forwardLabel: String {
        switch mode { case .month: "Следующий месяц"; case .week: "Следующая неделя"; case .day: "Следующий день" }
    }
    private var supportedDates: ClosedRange<Date> {
        math.supportedDates
    }

    private func shift(_ amount: Int) {
        let newDate = math.shifting(selectedDate, by: amount, mode: mode)
        if supportedDates.contains(newDate) { selectedDateBinding.wrappedValue = newDate }
    }
    private func addTask(on date: Date) {
        destination = EditorDestination(content: .task(date, nil, selectedGroup?.taskGroupID))
    }
    private func editTask(_ task: PlannerTask) { destination = EditorDestination(content: .task(task.date, task, nil)) }
    private func addLesson(on date: Date) { destination = EditorDestination(content: .lesson(date, nil)) }
    private func editLesson(_ lesson: UniversityLesson) { destination = EditorDestination(content: .lesson(lesson.date, lesson)) }
    private func refreshToday() { today = Date() }
}

struct MonthGridView: View {
    var store: CalendarStore
    @Binding var selection: Date
    let today: Date
    @Environment(\.colorScheme) private var colorScheme
    private var math: CalendarMath { CalendarMath() }
    private let weekdays = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]
    private var weekendColor: Color { colorScheme == .dark ? Color(hex: "#FF8A80") : Color(hex: "#B42318") }

    var body: some View {
        let days = math.monthDays(containing: selection)
        let weeks = days.count / 7
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(0..<7, id: \.self) { index in
                    Text(weekdays[index]).font(.caption.weight(.semibold))
                        .foregroundStyle(index >= 5 ? weekendColor : Color.secondary)
                        .frame(maxWidth: .infinity)
                }
            }.padding(.bottom, 5)
            ForEach(0..<weeks, id: \.self) { week in
                HStack(spacing: 6) {
                    ForEach(0..<7, id: \.self) { weekday in
                        let date = days[week * 7 + weekday]
                        dayCell(date, weekend: weekday >= 5)
                    }
                }.frame(maxHeight: .infinity)
            }
        }
    }

    private func dayCell(_ date: Date, weekend: Bool) -> some View {
        let selected = math.isSameDay(date, selection)
        let isToday = math.isSameDay(date, today)
        let inMonth = math.isSameMonth(date, selection)
        let groups = store.groups(on: date)
        let hasUngrouped = store.tasks(on: date).contains { $0.groupID == nil }
        return Button { if math.isSupported(date) { selection = date } } label: {
            MonthDayCellLayout(day: math.dayNumber(date), selected: selected, isToday: isToday,
                               foreground: weekend && inMonth ? weekendColor : .primary) { _ in
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 3) {
                        ForEach(groups.prefix(3)) { group in
                            Circle().fill(Color(hex: group.colorHex)).frame(width: 6, height: 6)
                                .help(group.name)
                        }
                        if groups.count > 3 {
                            Text("+\(groups.count - 3)").font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        if hasUngrouped {
                            Circle().strokeBorder(.secondary, lineWidth: 1).frame(width: 6, height: 6)
                                .help("Без группы")
                        }
                    }
                    HStack(spacing: 2) {
                        if let first = groups.first {
                            Circle().fill(Color(hex: first.colorHex)).frame(width: 6, height: 6)
                        }
                        let remaining = max(0, groups.count - 1) + (hasUngrouped ? 1 : 0)
                        if remaining > 0 {
                            Text("+\(remaining)").font(.system(size: 9, weight: .semibold))
                        }
                    }
                }.frame(height: 10)
            }
            .background(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.025),
                in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5)
            }
            .opacity(inMonth ? 1 : 0.42)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!math.isSupported(date))
        .accessibilityLabel("\(formatted(date, "d MMMM yyyy"))\(isToday ? ", сегодня" : ""), дел: \(store.tasks(on: date).count). Группы: \(groups.map(\.name).joined(separator: ", "))\(hasUngrouped ? ", Без группы" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(formatted(date, "d MMMM yyyy, EEEE"))
    }
}

/// Both month grids reserve the same date and detail slots, including empty days.
/// Extra lesson text can never change a row's height or move the date number.
struct MonthDayCellLayout<Details: View>: View {
    let day: Int
    let selected: Bool
    let isToday: Bool
    let foreground: Color
    @ViewBuilder var details: (Bool) -> Details

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 64
            VStack(spacing: compact ? 2 : 6) {
                Text("\(day)")
                    .font(.system(size: compact ? 11 : 13,
                                  weight: selected || isToday ? .bold : .medium, design: .rounded))
                    .foregroundStyle(foreground)
                    .frame(width: compact ? 19 : 29, height: compact ? 19 : 29)
                    .background(isToday ? Color.accentColor.opacity(0.2) : .clear, in: Circle())
                    .overlay(Circle().strokeBorder(isToday ? Color.accentColor : .clear, lineWidth: 2))
                ZStack(alignment: .top) {
                    Color.clear
                    details(compact)
                }
                .frame(maxWidth: .infinity)
                .frame(height: compact ? 20 : 28)
            }
            .padding(.horizontal, 2)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WeekColumnsView: View {
    var store: CalendarStore
    @Binding var selection: Date
    let today: Date
    var onAdd: (Date) -> Void
    var onEdit: (PlannerTask) -> Void
    var onDelete: (PlannerTask) -> Void
    @Environment(\.colorScheme) private var colorScheme
    private var math: CalendarMath { CalendarMath() }
    private var weekendColor: Color { colorScheme == .dark ? Color(hex: "#FF8A80") : Color(hex: "#B42318") }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            ForEach(Array(math.weekDays(containing: selection).enumerated()), id: \.element) { index, date in
                column(date, weekend: index >= 5)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func column(_ date: Date, weekend: Bool) -> some View {
        let selected = math.isSameDay(date, selection)
        let isToday = math.isSameDay(date, today)
        let tasks = store.tasks(on: date)
        return VStack(spacing: 0) {
            Button { if math.isSupported(date) { selection = date } } label: {
                VStack(spacing: 5) {
                    Text(initialCapital(formatted(date, "EEEEEE")))
                        .font(.caption.weight(.semibold))
                    Text("\(math.calendar.component(.day, from: date))")
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                    Text(formatted(date, "MMM"))
                        .font(.caption2)
                }
                .foregroundStyle(weekend ? weekendColor : Color.primary)
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
            .accessibilityLabel("\(formatted(date, "EEEE, d MMMM yyyy"))\(isToday ? ", сегодня" : "")")
            .accessibilityAddTraits(selected ? .isSelected : [])
            Divider()
            ScrollView {
                LazyVStack(spacing: 8) {
                    if tasks.isEmpty {
                        Text("Нет дел").font(.caption).foregroundStyle(.secondary)
                            .padding(.vertical, 20)
                    }
                    ForEach(tasks) { task in
                        TaskRowView(task: task, group: store.group(id: task.groupID),
                            onToggle: { store.toggleTask(task) },
                            onEdit: { onEdit(task) }, onDelete: { onDelete(task) }, compact: true)
                    }
                }.padding(7)
            }
            .scrollBounceBehavior(.basedOnSize)
            Button { onAdd(date) } label: {
                Image(systemName: "plus").frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.plain).foregroundStyle(.tint)
            .disabled(!math.isSupported(date))
            .help("Добавить дело на \(formatted(date, "d MMMM"))")
            .accessibilityLabel("Добавить дело на \(formatted(date, "d MMMM"))")
            .background(.primary.opacity(0.035))
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(
                selected ? Color.accentColor.opacity(0.45) : .primary.opacity(0.07), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

struct DayTaskListView: View {
    var store: CalendarStore
    var date: Date
    var showFullDate: Bool
    var onAdd: () -> Void
    var onEdit: (PlannerTask) -> Void
    var onDelete: (PlannerTask) -> Void

    var body: some View {
        let tasks = store.tasks(on: date)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(initialCapital(formatted(date, showFullDate ? "EEEE" : "d MMMM")))
                        .font(showFullDate ? .title3.weight(.semibold) : .headline)
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .accessibilityAddTraits(.isHeader)
                    Text(showFullDate ? formatted(date, "d MMMM yyyy") : "Дела на выбранный день")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text("\(tasks.count)").font(.caption.weight(.semibold))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(.primary.opacity(0.06), in: Capsule())
            }
            if tasks.isEmpty {
                Spacer(minLength: 0)
                EmptyDayView(onAdd: onAdd).frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(tasks) { task in
                            TaskRowView(task: task, group: store.group(id: task.groupID),
                                onToggle: { store.toggleTask(task) },
                                onEdit: { onEdit(task) }, onDelete: { onDelete(task) })
                        }
                    }.padding(.bottom, 6)
                }.scrollBounceBehavior(.basedOnSize)
                Button(action: onAdd) { Label("Добавить дело", systemImage: "plus") }
                    .buttonStyle(.borderless)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The material blurs the actual desktop behind the window. Opacity is applied
/// only to a separate color wash in CalendarPanelView, never to text or controls.
private struct PanelMaterialView: NSViewRepresentable {
    let theme: AppTheme
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        switch theme {
        case .system: view.appearance = nil
        case .light: view.appearance = NSAppearance(named: .aqua)
        case .dark: view.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

private struct JumpToDateView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var day: Int
    @State private var month: Int
    @State private var yearText: String
    var onSelect: (Date) -> Void
    private var math: CalendarMath { CalendarMath() }

    init(date: Date, onSelect: @escaping (Date) -> Void) {
        let components = CalendarMath().calendar.dateComponents([.day, .month, .year], from: date)
        _day = State(initialValue: components.day ?? 1)
        _month = State(initialValue: components.month ?? 1)
        _yearText = State(initialValue: String(components.year ?? 2026))
        self.onSelect = onSelect
    }

    private var validDate: Date? {
        guard let year = Int(yearText), (1...9999).contains(year) else { return nil }
        return math.date(day: day, month: month, year: year)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Перейти к дате").font(.title2.weight(.semibold))
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading) {
                    Text("День").font(.caption).foregroundStyle(.secondary)
                    Picker("День", selection: $day) { ForEach(1...31, id: \.self) { Text("\($0)").tag($0) } }
                        .labelsHidden().frame(width: 65)
                }
                VStack(alignment: .leading) {
                    Text("Месяц").font(.caption).foregroundStyle(.secondary)
                    Picker("Месяц", selection: $month) {
                        ForEach(1...12, id: \.self) { m in
                            Text(monthName(m)).tag(m)
                        }
                    }.labelsHidden().frame(width: 150)
                }
                VStack(alignment: .leading) {
                    Text("Год").font(.caption).foregroundStyle(.secondary)
                    TextField("Год", text: $yearText).textFieldStyle(.roundedBorder)
                        .frame(width: 85)
                        .accessibilityLabel("Год от 1 до 9999")
                }
            }
            Text(validDate.map { initialCapital(formatted($0, "EEEE, d MMMM yyyy")) }
                ?? "Укажите существующую дату и год от 1 до 9999.")
                .font(.callout).foregroundStyle(validDate == nil ? Color.red : Color.secondary)
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.plannerSheetAction().keyboardShortcut(.cancelAction)
                Button("Перейти") {
                    if let validDate { onSelect(validDate); dismiss() }
                }.plannerSheetAction().buttonStyle(.borderedProminent).disabled(validDate == nil)
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 410)
            .environment(\.locale, Locale(identifier: "ru_RU"))
    }

    private func monthName(_ month: Int) -> String {
        initialCapital(formatted(math.date(day: 1, month: month, year: 2024)!, "LLLL"))
    }
}

private func formatted(_ date: Date, _ template: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ru_RU")
    formatter.calendar = CalendarMath().calendar
    formatter.timeZone = .autoupdatingCurrent
    formatter.dateFormat = template
    return formatter.string(from: date)
}

private func initialCapital(_ value: String) -> String {
    guard let first = value.first else { return value }
    return String(first).uppercased(with: Locale(identifier: "ru_RU")) + value.dropFirst()
}
