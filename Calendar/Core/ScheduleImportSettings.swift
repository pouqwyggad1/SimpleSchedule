import Foundation
import Observation

@MainActor @Observable
final class ScheduleImportSettings {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onChange: (() -> Void)?
    private var storedInstituteID: String?
    private var storedGroupID: String?
    private var storedSubgroup: String?
    private var storedDuration: Int
    private(set) var cachedInstitutes: [ISTUOption]
    private(set) var cachedGroups: [String: [ISTUOption]]
    private(set) var cachedSubgroups: [String: [String]]
    private(set) var lastRefresh: Date?

    var instituteID: String? {
        get { storedInstituteID }
        set { guard storedInstituteID != newValue else { return }; storedInstituteID = newValue; defaults.set(newValue, forKey: "istu.instituteID"); onChange?() }
    }
    var groupID: String? {
        get { storedGroupID }
        set { guard storedGroupID != newValue else { return }; storedGroupID = newValue; defaults.set(newValue, forKey: "istu.groupID"); onChange?() }
    }
    var subgroup: String? {
        get { storedSubgroup }
        set {
            let text = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = text?.isEmpty == true ? nil : text
            guard storedSubgroup != value else { return }
            storedSubgroup = value; defaults.set(value, forKey: "istu.subgroup"); onChange?()
        }
    }
    var durationMinutes: Int {
        get { storedDuration }
        set {
            let value = min(360, max(1, newValue))
            guard storedDuration != value else { return }
            storedDuration = value; defaults.set(value, forKey: "istu.duration"); onChange?()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storedInstituteID = defaults.string(forKey: "istu.instituteID")
        storedGroupID = defaults.string(forKey: "istu.groupID")
        let subgroup = defaults.string(forKey: "istu.subgroup")?.trimmingCharacters(in: .whitespacesAndNewlines)
        storedSubgroup = subgroup?.isEmpty == true ? nil : subgroup
        let duration = defaults.object(forKey: "istu.duration") == nil ? 90 : defaults.integer(forKey: "istu.duration")
        storedDuration = min(360, max(1, duration))
        cachedInstitutes = defaults.data(forKey: "istu.institutes").flatMap { try? JSONDecoder().decode([ISTUOption].self, from: $0) } ?? []
        cachedGroups = defaults.data(forKey: "istu.groups").flatMap { try? JSONDecoder().decode([String: [ISTUOption]].self, from: $0) } ?? [:]
        cachedSubgroups = defaults.data(forKey: "istu.subgroups").flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
        lastRefresh = defaults.object(forKey: "istu.lastRefresh") as? Date
    }

    func cacheInstitutes(_ values: [ISTUOption]) {
        cachedInstitutes = values
        defaults.set(try? JSONEncoder().encode(values), forKey: "istu.institutes")
    }
    func cacheGroups(_ values: [ISTUOption], instituteID: String) {
        cachedGroups[instituteID] = values
        defaults.set(try? JSONEncoder().encode(cachedGroups), forKey: "istu.groups")
    }
    func cacheSubgroups(_ values: [String], groupID: String) {
        cachedSubgroups[groupID] = ISTUSubgroupOptions.values(from: (cachedSubgroups[groupID] ?? []) + values)
        defaults.set(try? JSONEncoder().encode(cachedSubgroups), forKey: "istu.subgroups")
    }
    func recordRefresh(_ date: Date) { lastRefresh = date; defaults.set(date, forKey: "istu.lastRefresh") }
}
