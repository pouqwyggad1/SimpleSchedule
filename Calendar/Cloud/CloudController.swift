import Foundation
import Observation

@MainActor @Observable
final class CloudController {
    private(set) var user: CloudUser?
    private(set) var authenticated = false
    private(set) var isBusy = false
    private(set) var codeSent = false
    private(set) var pendingMerge = false
    private(set) var pendingCount = 0
    private(set) var conflicts: [CloudConflict] = []
    private(set) var lastSync: Date?
    private(set) var errorMessage: String?
    var email = "" { didSet { restoreCooldown() } }
    var code = ""
    private(set) var retryAt = Date.distantPast
    var preferences = PlannerPreferences() {
        didSet { guard !applying else { return }; preferenceChanged() }
    }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let credentials: CloudCredentialAccess
    @ObservationIgnored private let api: CloudAPI
    @ObservationIgnored private var state = CloudAccountState()
    @ObservationIgnored private var disk: CloudDisk?
    @ObservationIgnored private weak var store: CalendarStore?
    @ObservationIgnored private weak var importer: ISTUImportController?
    @ObservationIgnored private var applying = false
    private(set) var isSynchronizing = false
    @ObservationIgnored private var storageReady = true
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var lastLocalAttempt = Date.distantPast
    @ObservationIgnored var notifications: NativeNotificationCoordinator?

    init(defaults: UserDefaults = .standard, api: CloudAPI = CloudAPI(), credentials: CloudCredentialAccess = .keychain) { self.defaults = defaults; self.api = api; self.credentials = credentials }
    func attach(store: CalendarStore, importer: ISTUImportController, startMonitoring: Bool = true) {
        self.store = store; self.importer = importer
        guard let directory = store.cloudDirectory else { return }
        disk = CloudDisk(directory: directory)
        email = user?.email ?? defaults.string(forKey: "cloud.authRetryEmail") ?? ""
        do {
            if let bytes = defaults.data(forKey: "cloud.activeUser") {
                user = try JSONDecoder().decode(CloudUser.self, from: bytes)
                if let user {
                    state = try disk?.read(CloudDisk.accountFile(user.id), as: CloudAccountState.self) ?? CloudAccountState()
                    try CloudMapping.validate(state.records)
                    try CloudMapping.validate(state.optimistic)
                    if let record = state.optimistic.first(where: { $0.id == "preferences" && !$0.deleted }) {
                        applying = true; preferences = try PlannerPreferences(fields: record.data); importer.applyCloudPreferences(preferences); applying = false
                    }
                    // Preserve unsent app/widget edits before ever replacing the active planner.
                    try capture()
                }
            } else {
                state = try disk?.read("guest-cloud.json", as: CloudAccountState.self) ?? CloudAccountState()
                try CloudMapping.validate(state.records)
                if let saved = defaults.data(forKey: "cloud.guestPreferences") {
                    applying = true; preferences = try JSONDecoder().decode(PlannerPreferences.self, from: saved); applying = false
                }
                try capture()
            }
            if let user { email = user.email }
            readImportPreferences()
        } catch { applying = false; storageReady = false; errorMessage = "Не удалось открыть облачную очередь. Данные не отправляются и сохранены на диске. " + error.localizedDescription }
        importer.onSettingsChanged = { [weak self] in self?.readImportPreferences() }
        guard startMonitoring, storageReady else { return }
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshSessionIfNeeded()
                await self.synchronize()
                await self.runLocalRefreshIfDue()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }
    func stop() { timer?.cancel(); debounce?.cancel() }
    func clearError() { errorMessage = nil }
    private func readImportPreferences() {
        guard let settings = importer?.settings, !applying else { return }
        var next = preferences; next.instituteId = settings.instituteID; next.groupId = settings.groupID
        next.subgroup = settings.subgroup; next.durationMinutes = settings.durationMinutes
        if next != preferences { preferences = next }
    }
    private func preferenceChanged() {
        do {
            if user == nil { defaults.set(try JSONEncoder().encode(preferences), forKey: "cloud.guestPreferences") }
            try capture(); requestSync()
            notifications?.refresh()
        } catch { errorMessage = error.localizedDescription }
    }
    func localDataChanged() {
        guard !applying else { return }
        do { try capture(); requestSync(); notifications?.refresh() }
        catch { errorMessage = error.localizedDescription }
    }
    private func requestSync() {
        debounce?.cancel()
        debounce = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            await self?.synchronize()
        }
    }
    private func persist() throws {
        guard let disk else { return }
        try disk.save(state, name: try user.map { try CloudDisk.accountFile($0.id) } ?? "guest-cloud.json")
        pendingCount = state.outbox.count; conflicts = state.conflicts
    }
    private func capture() throws {
        guard storageReady else { throw CloudError.message("Облачная очередь недоступна. Локальные файлы сохранены.") }
        guard !pendingMerge, !applying, let store, store.isAvailable else { return }
        if user == nil {
            let current = try CloudMapping.entities(store.plannerSnapshot(), preferences: preferences, known: state.records)
            let ids = Set(current.map(\.id))
            state.records = current + state.records.filter { !ids.contains($0.id) }.map { record in var copy = record; copy.deleted = true; return copy }
            try persist(); return
        }
        let current = try CloudMapping.entities(store.plannerSnapshot(), preferences: preferences, known: state.optimistic)
        state.capture(current, comparingTo: state.projectionBase)
        // Persist before any request. The planner remains the fallback if disk is full.
        try persist()
    }
    private func project() throws {
        guard let store else { return }
        let old = try store.plannerSnapshot()
        let snapshot = try CloudMapping.snapshot(state.optimistic, preserving: old)
        let nextPreferences = try state.optimistic.first(where: { $0.id == "preferences" && !$0.deleted }).map { try PlannerPreferences(fields: $0.data) }
        if state.projectionBase == nil {
            state.projectionBase = try CloudMapping.entities(old, preferences: preferences, known: state.optimistic)
            try persist()
        }
        applying = true
        defer { applying = false }
        try store.replacePlanner(with: snapshot)
        if let nextPreferences {
            preferences = nextPreferences
            importer?.applyCloudPreferences(nextPreferences)
        }
        state.projectionBase = nil; try persist()
        notifications?.refresh()
    }
    private func refreshSessionIfNeeded() async {
        guard user != nil, !authenticated, !isBusy else { return }
        do {
            if await api.currentCookie() == nil { await api.setCookie(try credentials.read()) }
            guard await api.currentCookie() != nil else { return }
            let result: CloudSessionReply = try await api.request("/api/auth/session")
            guard result.user?.id == user?.id else { errorMessage = "Сессия истекла. Войдите снова; локальная копия аккаунта сохранена."; return }
            authenticated = true
        } catch { errorMessage = error.localizedDescription }
    }
    private func restoreCooldown() {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        retryAt = defaults.string(forKey: "cloud.authRetryEmail") == address ? (defaults.object(forKey: "cloud.authRetryAt") as? Date ?? .distantPast) : .distantPast
    }
    func requestCode() async {
        guard storageReady, !isBusy, retryAt <= .now else { return }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard address.count <= 254, address.contains("@"), !address.contains(where: \.isWhitespace) else { errorMessage = "Введите корректную почту."; return }
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        do {
            let result: CloudValue = try await api.request("/api/auth/request-code", body: ["email": .text(address)])
            email = address; codeSent = true
            retryAt = Date.now.addingTimeInterval(Double(result.fields?["retryAfterSeconds"]?.int ?? 60))
            defaults.set(retryAt, forKey: "cloud.authRetryAt"); defaults.set(address, forKey: "cloud.authRetryEmail")
        } catch CloudError.response(let status, let message, let delay) {
            if status == 429 { retryAt = Date.now.addingTimeInterval(Double(delay ?? 60)); defaults.set(retryAt, forKey: "cloud.authRetryAt"); defaults.set(address, forKey: "cloud.authRetryEmail") }
            errorMessage = message
        } catch { errorMessage = error.localizedDescription }
    }
    func verifyCode() async {
        guard storageReady, !isBusy else { return }
        if let user, email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != user.email.lowercased() {
            errorMessage = "Для другого аккаунта сначала выполните выход."; return
        }
        guard code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else { errorMessage = "Введите шестизначный код."; return }
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        do {
            let result: CloudSessionReply = try await api.request("/api/auth/verify-code", body: ["email": .text(email.trimmingCharacters(in: .whitespacesAndNewlines)), "code": .text(code)])
            guard let next = result.user, let cookie = await api.currentCookie(), let disk, let store else { throw CloudError.message("Сервер не подтвердил вход.") }
            try credentials.save(cookie)
            if user?.id == next.id {
                user = next; authenticated = true; defaults.set(try JSONEncoder().encode(next), forKey: "cloud.activeUser")
                code = ""; codeSent = false; await synchronize(); return
            }
            guard user == nil else { throw CloudError.message("Сначала выйдите из текущего аккаунта, чтобы переключиться на другой.") }
            // A durable guest copy precedes either explicit choice in the settings form.
            try disk.save(CloudGuestBackup(snapshot: store.plannerSnapshot(), preferences: preferences), name: "guest.json")
            state = try disk.read(CloudDisk.accountFile(next.id), as: CloudAccountState.self) ?? CloudAccountState()
            user = next; authenticated = true; pendingMerge = true; code = ""; codeSent = false
        } catch { errorMessage = error.localizedDescription }
    }
    func openAccount(mergeGuest: Bool) async {
        guard pendingMerge, let user, let store else { return }
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        do {
            let reply = try await api.sync(userID: user.id, operations: [])
            try disk?.save(CloudGuestBackup(snapshot: store.plannerSnapshot(), preferences: preferences), name: "guest.json")
            try state.receive(reply)
            if mergeGuest {
                let guest = try CloudMapping.entities(store.plannerSnapshot(), preferences: preferences)
                var combined = Dictionary(uniqueKeysWithValues: state.optimistic.map { ($0.id, $0) })
                for record in guest where record.kind != "preferences" && combined[record.id] == nil { combined[record.id] = record }
                if combined["preferences"] == nil { combined["preferences"] = guest.first { $0.id == "preferences" } }
                state.capture(Array(combined.values))
            }
            try persist()
            defaults.set(try JSONEncoder().encode(user), forKey: "cloud.activeUser")
            pendingMerge = false; try project()
            await synchronize()
        } catch { errorMessage = error.localizedDescription }
    }
    func synchronize() async {
        guard storageReady, authenticated, !pendingMerge, !isSynchronizing, let user else { return }
        isSynchronizing = true
        defer { isSynchronizing = false }
        do {
            store?.reloadFromDisk(); try capture()
            for _ in 0..<50 {
                let operations = state.batch()
                let reply = try await api.sync(userID: user.id, operations: operations)
                guard self.user?.id == user.id else { return }
                try state.receive(reply); try persist(); try project()
                if state.outbox.isEmpty || operations.isEmpty { break }
            }
            lastSync = .now; errorMessage = nil
        } catch CloudError.response(let status, let message, _) {
            if status == 401 { authenticated = false }
            errorMessage = message
        } catch { errorMessage = error.localizedDescription }
    }
    func resolve(_ conflict: CloudConflict, keepLocal: Bool, copy: Bool = false) {
        do {
            if user == nil { try capture() }
            state.resolve(conflict, keepLocal: keepLocal, copy: copy)
            if user == nil { state.records = state.optimistic; state.outbox = [] }
            try persist(); try project(); requestSync()
        }
        catch { errorMessage = error.localizedDescription }
    }
    func signOut() async {
        guard !isBusy, !isSynchronizing, let disk, let store else { return }
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        do {
            if !pendingMerge { try capture() }
            else { try disk.save(CloudGuestBackup(snapshot: store.plannerSnapshot(), preferences: preferences), name: "guest.json") }
            // Restore only after a safe archive and successful server logout.
            let guest = try disk.read("guest.json", as: CloudGuestBackup.self)
            let _: CloudValue = try await api.request("/api/auth/sign-out", body: [:])
            try credentials.save(nil); await api.setCookie(nil)
            applying = true; defer { applying = false }
            if let guest { try store.replacePlanner(with: guest.snapshot); preferences = guest.preferences; importer?.applyCloudPreferences(guest.preferences) }
            user = nil; authenticated = false; pendingMerge = false; state = try disk.read("guest-cloud.json", as: CloudAccountState.self) ?? CloudAccountState()
            defaults.removeObject(forKey: "cloud.activeUser"); pendingCount = 0; conflicts = []; lastSync = nil
            conflicts = state.conflicts; notifications?.refresh()
        } catch { errorMessage = error.localizedDescription }
    }
    func toggleMutedDate(_ day: CivilDay) {
        let value = CloudMapping.date(day)
        if preferences.mutedDates.contains(value) { preferences.mutedDates.removeAll { $0 == value } }
        else { preferences.mutedDates.append(value) }
    }
    func toggleSubject(_ subject: String) {
        let key = PlannerPreferences.subjectKey(subject)
        if preferences.mutedSubjects.contains(key) { preferences.mutedSubjects.removeAll { $0 == key } }
        else { preferences.mutedSubjects.append(key) }
    }
    func showCodeEntry() { codeSent = true }
    func exportBackup() throws -> Data {
        guard store != nil, !pendingMerge else { throw CloudError.message("Сначала откройте локальное пространство или выберите способ входа.") }
        try capture()
        let records = state.optimistic
        let backup = PlannerCloudBackup(exportedAt: Date.now.ISO8601Format(), records: records, pendingOperations: user == nil ? nil : state.outbox, conflicts: state.conflicts)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(backup)
    }
    func importBackup(_ data: Data) throws {
        guard data.count <= 20 * 1024 * 1024, let store else { throw CloudError.message("Файл слишком большой или хранилище недоступно.") }
        let backup = try JSONDecoder().decode(PlannerCloudBackup.self, from: data)
        guard backup.format == "SimpleSchedule.PWA", backup.version == 1, backup.records.count <= 20000,
              Set(backup.records.map(\.id)).count == backup.records.count,
              backup.records.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 200 && ["task","group","lesson","preferences"].contains($0.kind) }) else { throw CloudError.message("Неподдерживаемый формат резервной копии.") }
        var combined = Dictionary(uniqueKeysWithValues: try CloudMapping.entities(store.plannerSnapshot(), preferences: preferences, known: state.optimistic).map { ($0.id, $0) })
        for record in backup.records {
            if (combined[record.id]?.deleted == true || state.optimistic.contains(where: { $0.id == record.id && $0.deleted })) && !record.deleted { throw CloudError.message("Запись уже удалена. Для её восстановления создайте отдельную копию.") }
            combined[record.id] = record
        }
        let records = Array(combined.values)
        let snapshot = try CloudMapping.snapshot(records, preserving: store.plannerSnapshot())
        let next = try combined["preferences"].map { try PlannerPreferences(fields: $0.data) } ?? preferences
        // Validate recoverable conflict versions before changing any planner files.
        for conflict in backup.conflicts ?? [] {
            _ = try CloudMapping.snapshot([conflict.server])
            if let data = conflict.operation.data { _ = try CloudMapping.snapshot([CloudEntity(id: conflict.operation.entityId, kind: conflict.operation.kind, data: data, version: 0, deleted: false)]) }
        }
        applying = true
        do { try store.replacePlanner(with: snapshot); preferences = next; importer?.applyCloudPreferences(next) }
        catch { applying = false; throw error }
        applying = false
        let existing = Set(state.conflicts.map(\.id)); state.conflicts += (backup.conflicts ?? []).filter { !existing.contains($0.id) }
        // Include imported tombstones so refresh cannot resurrect an explicitly hidden source.
        if user == nil { state.records = records }
        else { state.capture(records) }
        try persist(); preferenceChanged()
    }
    func mergeLocalCopy() async {
        guard !isBusy, let disk, let backup = try? disk.read("guest.json", as: CloudGuestBackup.self) else { errorMessage = "Сохранённой гостевой копии нет."; return }
        do {
            var combined = Dictionary(uniqueKeysWithValues: state.optimistic.map { ($0.id, $0) })
            for record in try CloudMapping.entities(backup.snapshot, preferences: backup.preferences) where record.kind != "preferences" && combined[record.id] == nil { combined[record.id] = record }
            state.capture(Array(combined.values)); try persist(); try project(); await synchronize()
        } catch { errorMessage = error.localizedDescription }
    }
    private func runLocalRefreshIfDue() async {
        guard user == nil, preferences.refreshMode == "auto", let importer, !importer.isLoading,
              preferences.groupId != nil else { return }
        if let last = importer.settings.lastRefresh, last.addingTimeInterval(Double(preferences.refreshIntervalHours * 3600)) > .now { return }
        guard lastLocalAttempt.addingTimeInterval(15 * 60) <= .now else { return }
        lastLocalAttempt = .now
        await importer.refresh(date: .now, mode: .month)
    }
}
