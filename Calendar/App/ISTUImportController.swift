import Foundation
import Observation

@MainActor @Observable
final class ISTUImportController {
    let settings: ScheduleImportSettings
    private(set) var isLoading = false
    private(set) var statusMessage: String?
    private(set) var errorMessage: String?
    @ObservationIgnored private weak var store: CalendarStore?
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var appliedDuration: Int
    @ObservationIgnored private let fetch: @MainActor (String) async throws -> Data
    @ObservationIgnored private var applyingCloudPreferences = false
    @ObservationIgnored var onSettingsChanged: (() -> Void)?

    var institutes: [ISTUOption] { settings.cachedInstitutes }
    var groups: [ISTUOption] { settings.cachedGroups[settings.instituteID ?? ""] ?? [] }
    var availableSubgroups: [String] {
        guard let groupID = settings.groupID else { return [] }
        let sourceLabels = store?.lessons.filter { $0.istuOrigin?.groupID == groupID }
            .compactMap { $0.istuOrigin?.original.subgroup } ?? []
        return ISTUSubgroupOptions.values(from: (settings.cachedSubgroups[groupID] ?? []) + sourceLabels)
    }

    init(settings: ScheduleImportSettings = ScheduleImportSettings(),
         fetch: @escaping @MainActor (String) async throws -> Data = { try await ISTUFetchClient.fetch(path: $0) }) {
        self.settings = settings; self.fetch = fetch; appliedDuration = settings.durationMinutes
        settings.onChange = { [weak self] in self?.applySettings() }
    }

    /// Attaching and reading cached choices never starts a network operation.
    func attach(store: CalendarStore) {
        self.store = store
        reconcileSubgroupSelection()
        applySettings()
    }
    func clearError() { errorMessage = nil }
    func cancel() { activeTask?.cancel() }

    private func reconcileSubgroupSelection() {
        let options = availableSubgroups
        if let selected = settings.subgroup, !options.isEmpty, !options.contains(selected) {
            settings.subgroup = nil
        }
    }

    private func applySettings() {
        guard !applyingCloudPreferences else { return }
        store?.importFilter = ScheduleImportFilter(groupID: settings.groupID, subgroup: settings.subgroup)
        if appliedDuration != settings.durationMinutes {
            do {
                try store?.recalculateImportedDuration(settings.durationMinutes)
                appliedDuration = settings.durationMinutes
            } catch {
                settings.durationMinutes = appliedDuration
                errorMessage = error.localizedDescription
            }
        }
        onSettingsChanged?()
    }

    func applyCloudPreferences(_ preferences: PlannerPreferences) {
        // Imported end times arrive with the cloud snapshot, so do not recalculate it.
        applyingCloudPreferences = true
        defer { applyingCloudPreferences = false }
        appliedDuration = preferences.durationMinutes
        settings.instituteID = preferences.instituteId; settings.groupID = preferences.groupId
        settings.subgroup = preferences.subgroup; settings.durationMinutes = preferences.durationMinutes
        store?.importFilter = ScheduleImportFilter(groupID: preferences.groupId, subgroup: preferences.subgroup)
    }

    func loadInstitutes() async {
        await run {
            self.statusMessage = "Загрузка институтов…"
            let data = try await self.fetch("/raspisanie")
            try Task.checkCancellation()
            let options = try ISTUParser.institutes(html: data)
            self.settings.cacheInstitutes(options)
            self.statusMessage = "Список институтов загружен: \(options.count)."
        }
    }

    func selectInstitute(_ id: String?) async {
        guard !isLoading else { return }
        if settings.instituteID != id { settings.instituteID = id; settings.groupID = nil }
        guard let id else { return }
        guard Self.validID(id), institutes.contains(where: { $0.id == id }) else {
            errorMessage = "Выберите институт из загруженного списка."; return
        }
        await run {
            self.statusMessage = "Загрузка групп…"
            let data = try await self.fetch("/raspisanie/podrazdelenie/\(id)")
            try Task.checkCancellation()
            let options = try ISTUParser.groups(html: data)
            self.settings.cacheGroups(options, instituteID: id)
            self.statusMessage = "Список групп загружен: \(options.count)."
        }
    }

    func selectGroup(_ id: String?) {
        guard !isLoading else { return }
        guard id == nil || groups.contains(where: { $0.id == id }) else { errorMessage = "Выберите группу из списка."; return }
        settings.groupID = id
        statusMessage = nil
    }

    func refresh(date: Date, mode: CalendarMode) async {
        guard let groupID = settings.groupID, Self.validID(groupID) else {
            errorMessage = "Сначала выберите институт и группу в настройках."; return
        }
        guard let store, store.isAvailable else { errorMessage = "Локальное хранилище недоступно."; return }
        let duration = settings.durationMinutes
        let instituteID = settings.instituteID
        await run {
            let math = CalendarMath()
            let dates = mode == .month ? math.monthDays(containing: date) : math.weekDays(containing: date)
            let mondays = dates.enumerated().filter { $0.offset % 7 == 0 }.map(\.element)
            guard !mondays.isEmpty, mondays.count <= 6 else { throw ISTUImportError.invalidPeriod }
            var allLessons: [ISTUParsedLesson] = []
            var coveredDays: [CivilDay] = []
            var discoveredSubgroups: [String] = []
            var firstPageError: (any Error)?
            var sawUnpublishedPeriod = false
            for (index, monday) in mondays.enumerated() {
                try Task.checkCancellation()
                guard self.settings.groupID == groupID, self.settings.instituteID == instituteID,
                      self.settings.durationMinutes == duration else { throw ISTUImportError.changedSettings }
                self.statusMessage = "Загрузка расписания: \(index + 1) из \(mondays.count)…"
                let day = CivilDay(date: monday)
                guard day.isValid else { throw ISTUImportError.invalidPeriod }
                let path = String(format: "/raspisanie/grup/%@/%02d.%02d.%04d/", groupID, day.day, day.month, day.year)
                do {
                    let data = try await self.fetch(path)
                    try Task.checkCancellation()
                    let page = try ISTUParser.schedule(html: data, referenceDate: monday, groupID: groupID)
                    let expected = Set(math.weekDays(containing: monday).map { WidgetDeepLink.dayString(CivilDay(date: $0)) })
                    let actual = Set(page.coveredDays.map { WidgetDeepLink.dayString($0) })
                    guard !actual.isEmpty, actual.isSubset(of: expected) else { throw ISTUImportError.wrongWeek }
                    allLessons.append(contentsOf: page.lessons); coveredDays.append(contentsOf: page.coveredDays)
                    discoveredSubgroups.append(contentsOf: page.subgroups)
                } catch is CancellationError {
                    throw CancellationError()
                } catch ISTUParserError.noPublishedSchedule {
                    sawUnpublishedPeriod = true
                } catch {
                    try Task.checkCancellation()
                    if firstPageError == nil { firstPageError = error }
                    // A missing week does not invalidate other confirmed dates.
                    // Unreturned days remain outside coverage and keep their old data.
                }
            }
            try Task.checkCancellation()
            guard self.settings.groupID == groupID, self.settings.instituteID == instituteID,
                  self.settings.durationMinutes == duration else { throw ISTUImportError.changedSettings }
            if coveredDays.isEmpty, sawUnpublishedPeriod, firstPageError == nil {
                self.statusMessage = nil
                self.errorMessage = nil
                return
            }
            guard !coveredDays.isEmpty else { throw firstPageError ?? ISTUImportError.invalidPeriod }
            let page = ISTUSchedulePage(lessons: allLessons, coveredDays: coveredDays, groupName: nil, subgroups: discoveredSubgroups)
            _ = try store.importISTUSchedule(page, groupID: groupID, durationMinutes: duration)
            self.settings.cacheSubgroups(discoveredSubgroups, groupID: groupID)
            self.reconcileSubgroupSelection()
            self.settings.recordRefresh(Date())
            self.errorMessage = nil
            self.statusMessage = nil
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) async {
        guard !isLoading else { return }
        isLoading = true; errorMessage = nil
        let task = Task { @MainActor [weak self] in
            do { try await action() }
            catch is CancellationError { self?.statusMessage = "Загрузка отменена. Сохраненное расписание не изменено." }
            catch { self?.statusMessage = nil; self?.errorMessage = error.localizedDescription }
        }
        activeTask = task
        await task.value
        activeTask = nil; isLoading = false
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 12 && value.utf8.allSatisfy { (48...57).contains($0) }
    }
}

enum ISTUImportError: LocalizedError {
    case invalidPeriod, wrongWeek, changedSettings
    var errorDescription: String? {
        switch self {
        case .invalidPeriod: "Не удалось определить период обновления расписания."
        case .wrongWeek: "Сайт вернул другой или неполный период. Сохраненное расписание не изменено."
        case .changedSettings: "Настройки изменились во время загрузки. Повторите обновление."
        }
    }
}
