import Foundation
import SwiftUI

/// In-memory defaults exercise the actual persistence calls without touching user preferences.
private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    override func object(forKey defaultName: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return values[defaultName]
    }

    override func double(forKey defaultName: String) -> Double {
        (object(forKey: defaultName) as? NSNumber)?.doubleValue ?? 0
    }

    override func string(forKey defaultName: String) -> String? {
        object(forKey: defaultName) as? String
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        lock.lock()
        defer { lock.unlock() }
        values[defaultName] = value
    }
}

@main
struct SettingsTests {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @MainActor
    static func main() throws {
        var assertions = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            assertions += 1
            guard condition() else { throw Failure(message: message) }
        }

        let defaults = MemoryDefaults()
        let initial = AppSettings(defaults: defaults)
        try expect(initial.theme == .system, "По умолчанию используется системная тема")
        try expect(initial.backgroundOpacity == 0.3, "Непрозрачность фона по умолчанию")
        try expect(initial.theme.preferredColorScheme == nil, "Системная тема не принудительно задает ColorScheme")

        initial.theme = .dark
        initial.backgroundOpacity = 0.72
        let reopened = AppSettings(defaults: defaults)
        try expect(reopened.theme == .dark, "Темная тема сохраняется и повторно читается")
        try expect(reopened.theme.preferredColorScheme == .dark, "Темная тема задает темное оформление")
        try expect(reopened.backgroundOpacity == 0.72, "Непрозрачность сохраняется и повторно читается")
        reopened.theme = .light
        try expect(AppSettings(defaults: defaults).theme == .light, "Светлая тема сохраняется")
        try expect(reopened.theme.preferredColorScheme == .light, "Светлая тема задает светлое оформление")
        reopened.theme = .system
        try expect(AppSettings(defaults: defaults).theme == .system, "Возврат к системной теме сохраняется")

        reopened.backgroundOpacity = -1
        try expect(reopened.backgroundOpacity == 0.05, "Непрозрачность ограничена снизу")
        try expect(AppSettings(defaults: defaults).backgroundOpacity == 0.05, "Нижнее ограничение сохраняется")
        reopened.backgroundOpacity = 100
        try expect(reopened.backgroundOpacity == 1, "Непрозрачность ограничена сверху")
        try expect(AppSettings(defaults: defaults).backgroundOpacity == 1, "Верхнее ограничение сохраняется")

        for value in [Double.nan, .infinity, -.infinity] {
            reopened.backgroundOpacity = value
            try expect(reopened.backgroundOpacity == 0.3, "Неконечная непрозрачность заменяется безопасным значением")
            try expect(AppSettings(defaults: defaults).backgroundOpacity == 0.3, "Безопасное значение сохраняется")
        }

        defaults.set("unknown-future-theme", forKey: "appearance.theme")
        try expect(AppSettings(defaults: defaults).theme == .system, "Неизвестная тема использует системное оформление")
        defaults.set(Double.infinity, forKey: "appearance.backgroundOpacity")
        try expect(AppSettings(defaults: defaults).backgroundOpacity == 0.3, "Неконечное сохраненное значение исправляется при чтении")
        defaults.set(-10.0, forKey: "appearance.backgroundOpacity")
        try expect(AppSettings(defaults: defaults).backgroundOpacity == 0.05, "Сохраненное значение ограничивается при чтении")
        print("SettingsTests: \(assertions) проверок пройдено. UserDefaults не записывались на диск.")
    }
}
