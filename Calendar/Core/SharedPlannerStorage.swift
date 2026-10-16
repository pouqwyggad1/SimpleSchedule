import Darwin
import Foundation

enum PlannerStorageRole: Sendable {
    case application
    case widget

    static func current(in bundle: Bundle = .main) -> PlannerStorageRole {
        bundle.object(forInfoDictionaryKey: "PlannerStorageRole") as? String == "widget" ? .widget : .application
    }
}

struct WidgetSharedState: Codable, Equatable, Sendable {
    /// nil follows the actual current day instead of freezing the day of the last refresh.
    var selectedDay: CivilDay? = nil
    var intentError: String? = nil

    func effectiveDay(now: Date = Date(), timeZone: TimeZone = .current) -> CivilDay {
        selectedDay ?? CivilDay(date: now, timeZone: timeZone)
    }
}

/// Both the app and its extension use this same lock file. Atomic JSON replacement
/// alone is insufficient: every read-modify-write transaction must hold this lock.
struct SharedPlannerStorage: Sendable {
    let directory: URL
    let isShared: Bool
    private let legacyDirectory: URL?

    var dataURL: URL { directory.appendingPathComponent("planner.json") }
    var backupURL: URL { directory.appendingPathComponent("planner.backup.json") }
    private var lockURL: URL { directory.appendingPathComponent("planner.lock") }
    private var widgetStateURL: URL { directory.appendingPathComponent("widget-state.json") }
    private var migrationMarkerURL: URL { directory.appendingPathComponent("private-migration-completed-v1") }
    private var migrationPendingURL: URL { directory.appendingPathComponent("private-migration-pending-v1.json") }

    /// Explicit URLs are used only by isolated tests and the app's own container resolver.
    init(directory: URL, legacyDirectory: URL? = nil, isShared: Bool = false) {
        self.directory = directory
        self.legacyDirectory = legacyDirectory
        self.isShared = isShared
    }

    static func resolve(for role: PlannerStorageRole, bundle: Bundle = .main) throws -> SharedPlannerStorage {
        let rawIdentifier = bundle.object(forInfoDictionaryKey: "PlannerAppGroupIdentifier") as? String ?? ""
        let identifier = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let legacy = privateDirectory(bundle: bundle)
        guard !identifier.isEmpty else {
            guard role == .application else {
                throw DataStoreError.storageUnavailable("Общий контейнер виджета не настроен. Откройте приложение, собранное с поддержкой App Groups.")
            }
            return SharedPlannerStorage(directory: legacy)
        }
        guard !identifier.contains("$("),
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            throw DataStoreError.storageUnavailable("Общий контейнер App Group недоступен. Проверьте подпись и разрешение группы у приложения и виджета.")
        }
        let shared = SharedPlannerStorage(
            directory: container.appendingPathComponent("Library/Application Support/Planner", isDirectory: true),
            legacyDirectory: role == .application ? legacy : nil,
            isShared: true
        )
        try shared.withExclusiveAccess { }
        return shared
    }

    private static func privateDirectory(bundle: Bundle) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent(bundle.bundleIdentifier ?? "ru.local.GoldenCalendar", isDirectory: true)
    }

    func withExclusiveAccess<T>(_ operation: () throws -> T) throws -> T {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw DataStoreError.storageUnavailable(error.localizedDescription)
        }
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw DataStoreError.storageUnavailable("Не удалось открыть блокировку хранилища.") }
        defer { Darwin.close(descriptor) }
        let lockFunction: (Int32, Int32) -> Int32 = flock
        let deadline = Date().addingTimeInterval(3)
        while lockFunction(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else {
                throw DataStoreError.storageUnavailable("Не удалось заблокировать хранилище.")
            }
            guard Date() < deadline else {
                throw DataStoreError.storageUnavailable("Хранилище занято другим процессом. Повторите действие.")
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        defer { _ = lockFunction(descriptor, LOCK_UN) }
        if legacyDirectory != nil {
            try migratePrivateDataIfNeeded()
        } else if FileManager.default.fileExists(atPath: migrationPendingURL.path),
                  !FileManager.default.fileExists(atPath: migrationMarkerURL.path) {
            throw DataStoreError.storageUnavailable("Перенос данных ещё не завершён. Откройте основное приложение.")
        }
        return try operation()
    }

    func readWidgetState() throws -> WidgetSharedState {
        try withExclusiveAccess { try readWidgetStateLocked() }
    }

    func updateWidgetState(_ body: (inout WidgetSharedState) -> Void) throws {
        try withExclusiveAccess {
            var state = try readWidgetStateLocked()
            body(&state)
            guard state.selectedDay?.isValid != false else { throw DataStoreError.invalidDate }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            do { try encoder.encode(state).write(to: widgetStateURL, options: .atomic) }
            catch { throw DataStoreError.writeFailed(error.localizedDescription) }
        }
    }

    private func readWidgetStateLocked() throws -> WidgetSharedState {
        guard FileManager.default.fileExists(atPath: widgetStateURL.path) else { return WidgetSharedState() }
        do {
            let state = try JSONDecoder().decode(WidgetSharedState.self, from: Data(contentsOf: widgetStateURL))
            guard state.selectedDay?.isValid != false else { throw DataStoreError.invalidDate }
            return state
        } catch { throw DataStoreError.readFailed("Состояние виджета повреждено. \(error.localizedDescription)") }
    }

    private struct Migration: Codable {
        let primary: Data?
        let backup: Data?
    }

    /// A journal contains both source files before either destination is written.
    /// Only the application may import its private data. An extension seeing an
    /// unfinished journal reports unavailable storage instead of an empty database.
    private func migratePrivateDataIfNeeded() throws {
        guard let legacyDirectory else { return }
        let manager = FileManager.default
        if manager.fileExists(atPath: migrationMarkerURL.path) {
            if manager.fileExists(atPath: migrationPendingURL.path) { try manager.removeItem(at: migrationPendingURL) }
            return
        }
        let migration: Migration
        if manager.fileExists(atPath: migrationPendingURL.path) {
            migration = try JSONDecoder().decode(Migration.self, from: Data(contentsOf: migrationPendingURL))
        } else {
            guard !manager.fileExists(atPath: dataURL.path), !manager.fileExists(atPath: backupURL.path) else {
                try Data("shared-store-already-exists".utf8).write(to: migrationMarkerURL, options: .atomic)
                return
            }
            let primary = legacyDirectory.appendingPathComponent("planner.json")
            let backup = legacyDirectory.appendingPathComponent("planner.backup.json")
            migration = Migration(
                primary: manager.fileExists(atPath: primary.path) ? try Data(contentsOf: primary) : nil,
                backup: manager.fileExists(atPath: backup.path) ? try Data(contentsOf: backup) : nil
            )
            if migration.primary == nil && migration.backup == nil {
                try Data("no-private-data".utf8).write(to: migrationMarkerURL, options: .atomic)
                return
            }
            try JSONEncoder().encode(migration).write(to: migrationPendingURL, options: .atomic)
        }
        if let backup = migration.backup { try backup.write(to: backupURL, options: .atomic) }
        if let primary = migration.primary { try primary.write(to: dataURL, options: .atomic) }
        try Data("completed".utf8).write(to: migrationMarkerURL, options: .atomic)
        try manager.removeItem(at: migrationPendingURL)
    }
}
