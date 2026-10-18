import Foundation

private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
    override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func integer(forKey key: String) -> Int { object(forKey: key) as? Int ?? 0 }
    override func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
    override func removeObject(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}
private final class MockServer: @unchecked Sendable {
    static let shared = MockServer()
    let lock = NSLock()
    var requests: [URLRequest] = []
    var records: [CloudEntity] = []
    var revision: Int64 = 0
    var status = 200
    var email = "native-test@example.invalid"
    let userID = "f913fd86-4b55-4c50-8c56-c63d43a512ab"
    func response(_ request: URLRequest) throws -> (Int, [String: String], Data) {
        try lock.withLock {
            requests.append(request)
            if status == 0 { throw URLError(.notConnectedToInternet) }
            if status != 200 { return (status, ["Retry-After": "73"], Data("{\"error\":\"Подождите\"}".utf8)) }
            let path = request.url!.path
            let encoder = JSONEncoder()
            if path == "/api/auth/verify-code" { return (200, ["Set-Cookie": "ss_session=mock-session; Path=/api; Secure; HttpOnly; SameSite=Strict"], try encoder.encode(CloudValue.object(["user": .object(["id": .text(userID), "email": .text(email)])]))) }
            if path == "/api/auth/session" { return (200, [:], try encoder.encode(CloudValue.object(["configured": .bool(true), "user": .object(["id": .text(userID), "email": .text(email)])]))) }
            if path == "/api/auth/request-code" { return (200, [:], Data("{\"sent\":true,\"retryAfterSeconds\":60}".utf8)) }
            if path == "/api/auth/sign-out" { return (200, [:], Data("{}".utf8)) }
            if path == "/api/sync" {
                var body = request.httpBody ?? Data()
                if body.isEmpty, let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable { let read = stream.read(&buffer, maxLength: buffer.count); if read <= 0 { break }; body.append(contentsOf: buffer.prefix(read)) }
                }
                let object = try JSONDecoder().decode(CloudValue.self, from: body).fields!
                let operations = try JSONDecoder().decode([CloudOperation].self, from: encoder.encode(object["operations"]!))
                var results: [CloudOperationResult] = []
                for op in operations {
                    revision += 1
                    let record = CloudEntity(id: op.entityId, kind: op.kind, data: op.data ?? records.first(where: { $0.id == op.entityId })?.data ?? [:], version: revision, deleted: op.data == nil)
                    records.removeAll { $0.id == record.id }; records.append(record)
                    results.append(CloudOperationResult(operationId: op.operationId, status: "applied", record: record, conflictingFields: []))
                }
                return (200, [:], try encoder.encode(CloudReply(records: records, results: results, revision: revision)))
            }
            throw URLError(.unsupportedURL)
        }
    }
}
private final class MockProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, body) = try MockServer.shared.response(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
@main struct CloudAPITests {
    struct Failure: Error { let message: String }
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            count += 1; if try !value() { throw Failure(message: message) }
        }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockProtocol.self]
        let api = CloudAPI(configuration: config)
        let reply: CloudSessionReply = try await api.request("/api/auth/verify-code", body: ["email": .text("native-test@example.invalid"), "code": .text("123456")])
        try check(reply.user?.id == MockServer.shared.userID, "Decode same account contract as PWA")
        let cookie = await api.currentCookie(); try check(cookie == "ss_session=mock-session", "Secure session obtained from response cookie")
        _ = try await api.sync(userID: MockServer.shared.userID, operations: [])
        let syncRequest = MockServer.shared.lock.withLock { MockServer.shared.requests.last! }
        try check(syncRequest.value(forHTTPHeaderField: "Origin") == CloudAPI.origin, "Fixed trusted origin")
        try check(syncRequest.value(forHTTPHeaderField: "X-SimpleSchedule-Account") == MockServer.shared.userID, "Account guard present")
        try check(syncRequest.value(forHTTPHeaderField: "Cookie") == cookie && syncRequest.httpMethod == "POST", "Authenticated JSON sync request")
        do { let _: CloudValue = try await api.request("/api/arbitrary"); throw Failure(message: "Unexpected route accepted") } catch is CloudError { count += 1 }
        MockServer.shared.lock.withLock { MockServer.shared.status = 429 }
        do { let _: CloudValue = try await api.request("/api/auth/request-code", body: ["email": .text("x@example.invalid")]); throw Failure(message: "429 accepted") }
        catch CloudError.response(let status, let message, let delay) { try check(status == 429 && delay == 73 && message == "Подождите", "Rate-limit response preserves explicit retry interval") }
        MockServer.shared.lock.withLock { MockServer.shared.status = 200; MockServer.shared.requests = [] }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SimpleSchedule-CloudAPI-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CalendarStore(directory: dir); let defaults = MemoryDefaults()
        let settings = ScheduleImportSettings(defaults: defaults)
        let importer = ISTUImportController(settings: settings, fetch: { _ in throw URLError(.notConnectedToInternet) })
        importer.attach(store: store)
        var savedCredential: String?
        let controller = CloudController(defaults: defaults, api: api, credentials: CloudCredentialAccess(read: { savedCredential }, save: { savedCredential = $0 }))
        controller.attach(store: store, importer: importer, startMonitoring: false)
        store.onCommit = { controller.localDataChanged() }
        let today = CalendarMath().date(day: 20, month: 10, year: 2026)!
        let guest = try store.saveTask(title: "Локальное дело", date: today, groupID: nil, note: "Не потерять")
        controller.email = "native-test@example.invalid"; await controller.requestCode()
        try check(controller.codeSent && controller.retryAt > .now, "Code UI and persisted cooldown initialized")
        let requestCount = MockServer.shared.lock.withLock { MockServer.shared.requests.count }
        await controller.requestCode()
        try check(MockServer.shared.lock.withLock { MockServer.shared.requests.count } == requestCount, "Cooldown prevents duplicate email request")
        controller.email = "other@example.invalid"; try check(controller.retryAt <= .now, "Cooldown scoped to email")
        controller.email = "native-test@example.invalid"; controller.code = "123456"; await controller.verifyCode()
        try check(controller.pendingMerge && controller.authenticated && savedCredential == cookie, "Explicit merge required after credentials saved")
        try check(store.tasks.map(\.id) == [guest.id], "Sign-in alone never replaces guest data")
        await controller.openAccount(mergeGuest: true)
        try check(!controller.pendingMerge && controller.pendingCount == 0 && controller.errorMessage == nil, "Merge sync completes durably")
        try check(MockServer.shared.lock.withLock { MockServer.shared.records.contains { $0.data["title"] == .text("Локальное дело") } }, "Guest record uploaded to same backend format")
        store.toggleTask(store.tasks[0]); await controller.synchronize()
        try check(MockServer.shared.lock.withLock { MockServer.shared.records.first { $0.kind == "task" }?.data["completed"] == .bool(true) }, "Completion propagates through controller and queue")
        MockServer.shared.lock.withLock {
            let index = MockServer.shared.records.firstIndex { $0.kind == "task" }!
            MockServer.shared.records[index].data["note"] = .text("Правка с телефона")
            MockServer.shared.revision += 1; MockServer.shared.records[index].version = MockServer.shared.revision
        }
        await controller.synchronize()
        try check(store.tasks.first?.note == "Правка с телефона", "Phone edit projects into native planner")
        controller.preferences.notificationsEnabled = true; controller.preferences.leadMinutes = 12
        await controller.synchronize()
        try check(MockServer.shared.lock.withLock { MockServer.shared.records.first { $0.kind == "preferences" }?.data["leadMinutes"] == .number(12) }, "Notification settings synchronize")
        MockServer.shared.lock.withLock { MockServer.shared.status = 0 }
        _ = try store.saveTask(title: "Офлайн", date: today, groupID: nil, note: "Очередь")
        await controller.synchronize()
        try check(controller.pendingCount > 0 && store.tasks.contains { $0.title == "Офлайн" }, "Network failure preserves native edits and durable queue")
        let accountDisk = CloudDisk(directory: store.cloudDirectory!)
        let persisted = try accountDisk.read(CloudDisk.accountFile(MockServer.shared.userID), as: CloudAccountState.self)!
        try check(persisted.outbox.contains { $0.data?["title"] == .text("Офлайн") }, "Offline edit is on disk before any successful network response")
        MockServer.shared.lock.withLock { MockServer.shared.status = 200 }
        await controller.synchronize()
        try check(controller.pendingCount == 0, "Connection recovery drains queue")
        let backup = try controller.exportBackup()
        try check(!String(decoding: backup, as: UTF8.self).contains("mock-session"), "Backups never include session")
        let before = try store.plannerSnapshot()
        do { try controller.importBackup(Data("{}".utf8)); throw Failure(message: "Invalid backup accepted") } catch is DecodingError { count += 1 }
        try check(try store.plannerSnapshot() == before, "Invalid backup leaves planner untouched")
        await controller.signOut()
        try check(controller.user == nil && savedCredential == nil && store.tasks.first?.note == "Не потерять", "Logout revokes credentials and restores separate guest copy")
        try controller.importBackup(backup)
        try check(store.tasks.contains { $0.note == "Правка с телефона" } && store.tasks.contains { $0.title == "Офлайн" }, "PWA-format backup restores all account data into guest space")
        let record = try JSONDecoder().decode(PlannerCloudBackup.self, from: backup).records.first { $0.kind == "task" }!
        var localVersion = record.data; localVersion["title"] = .text("Сохранённая версия конфликта")
        let conflict = CloudConflict(operation: CloudOperation(entityId: record.id, kind: record.kind, baseVersion: record.version, base: record.data, data: localVersion), server: record, fields: ["title"])
        let recovery = PlannerCloudBackup(exportedAt: "2026-10-19T00:00:00Z", records: [record], pendingOperations: [], conflicts: [conflict])
        try controller.importBackup(JSONEncoder().encode(recovery))
        try check(controller.conflicts.count == 1, "Saved PWA conflict is available after backup import")
        controller.resolve(controller.conflicts[0], keepLocal: true)
        try check(controller.conflicts.isEmpty && store.tasks.contains { $0.title == "Сохранённая версия конфликта" }, "Guest can recover local conflict version without signing in")
        controller.stop()
        let corruptDefaults = MemoryDefaults()
        corruptDefaults.set(try JSONEncoder().encode(CloudUser(id: MockServer.shared.userID, email: "native-test@example.invalid")), forKey: "cloud.activeUser")
        let archive = accountDisk.directory.appendingPathComponent(try CloudDisk.accountFile(MockServer.shared.userID))
        try Data("broken-json".utf8).write(to: archive, options: .atomic)
        let blocked = CloudController(defaults: corruptDefaults, api: api, credentials: CloudCredentialAccess(read: { "ss_session=mock-session" }, save: { _ in }))
        let beforeRequests = MockServer.shared.lock.withLock { MockServer.shared.requests.count }
        blocked.attach(store: store, importer: importer)
        await Task.yield(); await blocked.synchronize()
        try check(blocked.errorMessage != nil && MockServer.shared.lock.withLock { MockServer.shared.requests.count } == beforeRequests, "Corrupt queue fails closed without uploading duplicate identities")
        blocked.stop()
        print("CloudAPITests: \(count) проверок HTTPS-контракта, входа, очереди и изоляции аккаунта пройдено. Реальная сеть, почта и Keychain не использовались.")
    }
}
