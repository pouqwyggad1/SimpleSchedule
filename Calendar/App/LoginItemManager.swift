import Foundation
import Observation
import ServiceManagement

/// Only this application's login item is managed. No helper executable is used.
@MainActor
@Observable
final class LoginItemManager {
    private(set) var isEnabled = false
    private(set) var requiresApproval = false
    private(set) var statusText = "Проверка состояния…"
    private(set) var isUpdating = false
    var errorMessage: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let firstAttemptKey = "loginItem.initialRegistrationAttempted.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        refresh()
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        requiresApproval = status == .requiresApproval
        switch status {
        case .enabled:
            statusText = "Приложение будет открываться при входе в систему."
        case .requiresApproval:
            statusText = "macOS ожидает подтверждения в разделе «Объекты входа»."
        case .notRegistered:
            statusText = "Запуск при входе выключен."
        case .notFound:
            statusText = "macOS не нашла приложение. Переместите его в «Программы» и повторите включение."
        @unknown default:
            statusText = "Не удалось определить состояние запуска при входе."
        }
    }

    /// Called by the real application delegate, never by a model, preview or test initializer.
    func attemptFirstLaunchRegistration() {
        guard !defaults.bool(forKey: firstAttemptKey),
              ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else { return }
        // Record the request before contacting macOS; a failed request is not silently retried.
        defaults.set(true, forKey: firstAttemptKey)
        refresh()
        guard !isEnabled, !requiresApproval else { return }
        setEnabled(true)
    }

    func setEnabled(_ enabled: Bool) {
        guard !isUpdating else { return }
        errorMessage = nil
        refresh()
        if enabled && requiresApproval {
            openSystemSettings()
            return
        }
        guard enabled != isEnabled || (!enabled && requiresApproval) else { return }
        isUpdating = true
        defer {
            isUpdating = false
            refresh()
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = "Не удалось изменить запуск при входе: \(error.localizedDescription)"
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
