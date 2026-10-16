import AppIntents
import Foundation

struct CompletePlannerTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Изменить выполнение дела"
    static let description = IntentDescription("Отмечает дело выполненным или возвращает в невыполненные на этом Mac.")
    static let openAppWhenRun = false
    static let isDiscoverable = false

    @Parameter(title: "Идентификатор дела") var taskID: String
    @Parameter(title: "Выполнено") var completed: Bool

    init() {}
    init(taskID: String, completed: Bool) { self.taskID = taskID; self.completed = completed }

    @MainActor func perform() async throws -> some IntentResult {
        do { try WidgetBridge.setCompleted(taskID: taskID, isCompleted: completed) }
        catch { WidgetBridge.recordFailure(error) }
        return .result()
    }
}

struct ShiftPlannerWidgetDayIntent: AppIntent {
    static let title: LocalizedStringResource = "Перелистнуть день виджета"
    static let openAppWhenRun = false
    static let isDiscoverable = false

    @Parameter(title: "Количество дней") var amount: Int

    init() {}
    init(amount: Int) { self.amount = amount }

    @MainActor func perform() async throws -> some IntentResult {
        do { try WidgetBridge.shiftDay(by: amount) }
        catch { WidgetBridge.recordFailure(error) }
        return .result()
    }
}

struct PlannerWidgetTodayIntent: AppIntent {
    static let title: LocalizedStringResource = "Сегодня в виджете"
    static let openAppWhenRun = false
    static let isDiscoverable = false

    @MainActor func perform() async throws -> some IntentResult {
        do { try WidgetBridge.showToday() }
        catch { WidgetBridge.recordFailure(error) }
        return .result()
    }
}
