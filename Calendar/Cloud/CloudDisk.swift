import Foundation

struct CloudDisk {
    let directory: URL
    func read<T: Decodable>(_ name: String, as type: T.Type) throws -> T? {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }
    func save<T: Encodable>(_ value: T, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(name)
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func accountFile(_ id: String) throws -> String {
        guard let uuid = UUID(uuidString: id) else { throw CloudError.message("Некорректный идентификатор аккаунта.") }
        return "account-\(uuid.uuidString.lowercased()).json"
    }
}
struct CloudGuestBackup: Codable {
    var snapshot: NativePlannerSnapshot
    var preferences: PlannerPreferences
}
struct PlannerCloudBackup: Codable {
    var format = "SimpleSchedule.PWA"
    var version = 1
    var exportedAt: String
    var records: [CloudEntity]
    var pendingOperations: [CloudOperation]?
    var conflicts: [CloudConflict]? = nil
}
