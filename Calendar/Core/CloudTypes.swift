import Foundation

/// JSON values remain Sendable; no untyped dictionaries cross actor boundaries.
enum CloudValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Int64), text(String), array([CloudValue]), object([String: CloudValue])
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let flag = try? value.decode(Bool.self) { self = .bool(flag) }
        else if let number = try? value.decode(Int64.self) { self = .number(number) }
        else if let text = try? value.decode(String.self) { self = .text(text) }
        else if let array = try? value.decode([CloudValue].self) { self = .array(array) }
        else { self = .object(try value.decode([String: CloudValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let flag): try value.encode(flag)
        case .number(let number): try value.encode(number)
        case .text(let text): try value.encode(text)
        case .array(let array): try value.encode(array)
        case .object(let object): try value.encode(object)
        }
    }
    var string: String? { if case .text(let value) = self { value } else { nil } }
    var int: Int? { if case .number(let value) = self { Int(exactly: value) } else { nil } }
    var flag: Bool? { if case .bool(let value) = self { value } else { nil } }
    var fields: [String: CloudValue]? { if case .object(let value) = self { value } else { nil } }
    static func optional(_ value: String?) -> Self { value.map(Self.text) ?? .null }
}
typealias CloudFields = [String: CloudValue]
struct CloudEntity: Codable, Equatable, Sendable {
    var id: String
    var kind: String
    var data: CloudFields
    var version: Int64
    var deleted: Bool
}
struct CloudOperation: Codable, Equatable, Sendable {
    var operationId = UUID().uuidString.lowercased()
    var entityId: String
    var kind: String
    var baseVersion: Int64
    var base: CloudFields?
    var data: CloudFields?
    private enum CodingKeys: String, CodingKey { case operationId, entityId, kind, baseVersion, base, data }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(operationId, forKey: .operationId); try values.encode(entityId, forKey: .entityId)
        try values.encode(kind, forKey: .kind); try values.encode(baseVersion, forKey: .baseVersion)
        try values.encode(base, forKey: .base); try values.encode(data, forKey: .data)
    }
}
struct CloudOperationResult: Codable, Sendable {
    let operationId: String
    let status: String
    let record: CloudEntity
    let conflictingFields: [String]
}
struct CloudReply: Codable, Sendable {
    let records: [CloudEntity]
    var results: [CloudOperationResult]?
    let revision: Int64
}
struct CloudConflict: Codable, Identifiable, Equatable, Sendable {
    var id: String { operation.operationId }
    var operation: CloudOperation
    var server: CloudEntity
    var fields: [String]
    private enum CodingKeys: String, CodingKey { case id, entityId, kind, localData, baseData, serverRecord, conflictingFields, createdAt }
    init(operation: CloudOperation, server: CloudEntity, fields: [String]) { self.operation = operation; self.server = server; self.fields = fields }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        server = try values.decode(CloudEntity.self, forKey: .serverRecord)
        let entityID = try values.decode(String.self, forKey: .entityId)
        let kind = try values.decode(String.self, forKey: .kind)
        guard server.id == entityID, server.kind == kind else { throw CloudError.message("Некорректный конфликт в резервной копии.") }
        operation = CloudOperation(operationId: try values.decode(String.self, forKey: .id), entityId: entityID, kind: kind, baseVersion: server.version,
            base: try values.decodeIfPresent(CloudFields.self, forKey: .baseData), data: try values.decodeIfPresent(CloudFields.self, forKey: .localData))
        fields = try values.decode([String].self, forKey: .conflictingFields)
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(operation.entityId, forKey: .entityId); try values.encode(operation.kind, forKey: .kind)
        try values.encode(operation.data, forKey: .localData); try values.encode(operation.base, forKey: .baseData)
        try values.encode(server, forKey: .serverRecord); try values.encode(fields, forKey: .conflictingFields)
        try values.encode(0, forKey: .createdAt)
    }
}
struct CloudUser: Codable, Equatable, Sendable { var id: String; var email: String }
struct CloudSessionReply: Decodable, Sendable { var configured: Bool?; var user: CloudUser? }
struct CloudAccountState: Codable, Sendable {
    var records: [CloudEntity] = []
    var outbox: [CloudOperation] = []
    var conflicts: [CloudConflict] = []
    var revision: Int64 = 0
    var projectionBase: [CloudEntity]? = nil
    var optimistic: [CloudEntity] {
        var values = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for operation in conflicts.map(\.operation) + outbox {
            let old = values[operation.entityId]
            var data = old?.data ?? operation.data ?? [:]
            if let proposed = operation.data {
                for field in Set((operation.base ?? [:]).keys).union(proposed.keys) where operation.base?[field] != proposed[field] {
                    data[field] = proposed[field]
                }
            }
            values[operation.entityId] = CloudEntity(id: operation.entityId, kind: operation.kind, data: data,
                version: old?.version ?? 0, deleted: operation.data == nil)
        }
        return values.values.sorted { $0.id < $1.id }
    }
    mutating func capture(_ incoming: [CloudEntity], comparingTo expected: [CloudEntity]? = nil) {
        let current = Dictionary(incoming.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let old = Dictionary((expected ?? optimistic).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for record in incoming {
            let previous = old[record.id]
            if record.deleted {
                if previous?.deleted == true { continue }
                if previous == nil {
                    // The server requires creation before a new tombstone. Keep both operations durable.
                    outbox.append(CloudOperation(entityId: record.id, kind: record.kind, baseVersion: 0, base: nil, data: record.data))
                }
                outbox.append(CloudOperation(entityId: record.id, kind: record.kind, baseVersion: previous?.version ?? 0, base: previous?.data ?? record.data, data: nil))
            } else {
                if let previous, !previous.deleted && previous.data == record.data { continue }
                outbox.append(CloudOperation(entityId: record.id, kind: record.kind, baseVersion: previous?.version ?? 0, base: previous?.data, data: record.data))
            }
        }
        for previous in old.values where !previous.deleted && current[previous.id] == nil {
            outbox.append(CloudOperation(entityId: previous.id, kind: previous.kind, baseVersion: previous.version, base: previous.data, data: nil))
        }
    }

    func batch() -> [CloudOperation] {
        var seen = Set(conflicts.map { $0.operation.entityId })
        // Stable order keeps each entity's edits serial. New groups precede referencing tasks.
        return outbox.filter { seen.insert($0.entityId).inserted }.sorted {
            func priority(_ op: CloudOperation) -> Int { op.kind == "group" ? 0 : op.kind == "preferences" ? 1 : 2 }
            return priority($0) < priority($1)
        }.prefix(100).map { $0 }
    }
    mutating func receive(_ reply: CloudReply) throws {
        guard Set(reply.records.map(\.id)).count == reply.records.count,
              reply.records.allSatisfy({ ["task", "group", "lesson", "preferences"].contains($0.kind) && $0.version >= 0 }) else {
            throw CloudError.message("Сервер вернул неподходящий снимок. Локальная копия сохранена.")
        }
        guard (reply.results ?? []).allSatisfy({ ["applied", "conflict"].contains($0.status) }), reply.revision >= 0 else { throw CloudError.message("Неизвестный результат синхронизации.") }
        _ = try CloudMapping.snapshot(reply.records)
        for result in reply.results ?? [] {
            guard let operation = outbox.first(where: { $0.operationId == result.operationId }) else { continue }
            guard result.status == "applied" || result.status == "conflict" else { throw CloudError.message("Неизвестный результат синхронизации.") }
            if result.status == "conflict" { conflicts.append(CloudConflict(operation: operation, server: result.record, fields: result.conflictingFields)) }
            outbox.removeAll { $0.operationId == result.operationId }
            if result.status == "applied", let next = outbox.firstIndex(where: { $0.entityId == result.record.id }), outbox[next].base == result.record.data {
                outbox[next].baseVersion = result.record.version
            }
        }
        records = reply.records; revision = reply.revision
    }
    mutating func resolve(_ conflict: CloudConflict, keepLocal: Bool, copy: Bool = false) {
        let desired = optimistic.first { $0.id == conflict.operation.entityId }
        let current = records.first { $0.id == conflict.operation.entityId } ?? conflict.server
        conflicts.removeAll { $0.operation.entityId == conflict.operation.entityId }
        outbox.removeAll { $0.entityId == conflict.operation.entityId }
        if keepLocal {
            let data = desired?.deleted == true ? nil : desired?.data ?? conflict.operation.data
            if copy || (current.deleted && data != nil) {
                guard var data, current.kind != "preferences" else { return }
                if current.kind == "lesson" { for key in ["sourceId", "sourceGroupId", "sourceBaseline", "sourceCancelled"] { data.removeValue(forKey: key) } }
                outbox.append(CloudOperation(entityId: UUID().uuidString.lowercased(), kind: current.kind, baseVersion: 0, base: nil, data: data))
            } else {
                outbox.append(CloudOperation(entityId: current.id, kind: current.kind, baseVersion: current.version, base: current.data, data: data))
            }
        }
    }
}
enum CloudError: LocalizedError, Sendable {
    case message(String)
    case response(Int, String, Int?)
    var errorDescription: String? { switch self { case .message(let text), .response(_, let text, _): text } }
}
