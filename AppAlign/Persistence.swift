import CoreGraphics
import Darwin
import Foundation

enum PersistedLayoutKind: String, Codable, Sendable {
    case grid
    case canvas
    case focus
}

struct PersistedZone: Codable, Equatable, Sendable {
    let id: Int
    let originX: Double
    let originY: Double
    let width: Double
    let height: Double
}

struct PersistedLayout: Codable, Equatable, Sendable {
    let id: UUID
    let kind: PersistedLayoutKind
    let rows: Int?
    let columns: Int?
    let rowPercentages: [Int]?
    let columnPercentages: [Int]?
    let cellChildMap: [[Int]]?
    let referenceWidth: Double?
    let referenceHeight: Double?
    let zones: [PersistedZone]?
    let spacing: Double
    let template: String
    let zoneCount: Int
    let name: String?

    init(id: UUID, definition: LayoutDefinition, spacing: Double, template: LayoutTemplate, zoneCount: Int, name: String? = nil) {
        self.id = id
        self.spacing = spacing
        self.template = template.rawValue
        self.zoneCount = zoneCount
        self.name = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        switch definition {
        case .grid(let grid):
            kind = .grid
            rows = grid.rows
            columns = grid.columns
            rowPercentages = grid.rowPercentages
            columnPercentages = grid.columnPercentages
            cellChildMap = grid.cellChildMap
            referenceWidth = nil
            referenceHeight = nil
            zones = nil
        case .canvas(let canvas):
            kind = .canvas
            rows = nil
            columns = nil
            rowPercentages = nil
            columnPercentages = nil
            cellChildMap = nil
            referenceWidth = Double(canvas.referenceSize.width)
            referenceHeight = Double(canvas.referenceSize.height)
            zones = Self.persistedZones(canvas.zones)
        case .focus(let canvas):
            kind = .focus
            rows = nil
            columns = nil
            rowPercentages = nil
            columnPercentages = nil
            cellChildMap = nil
            referenceWidth = Double(canvas.referenceSize.width)
            referenceHeight = Double(canvas.referenceSize.height)
            zones = Self.persistedZones(canvas.zones)
        }
    }

    private static func persistedZones(_ zones: [CanvasZone]) -> [PersistedZone] {
        zones.map { zone in
            PersistedZone(
                id: zone.id.rawValue,
                originX: Double(zone.frame.minX),
                originY: Double(zone.frame.minY),
                width: Double(zone.frame.width),
                height: Double(zone.frame.height)
            )
        }
    }

    func definition() throws -> LayoutDefinition {
        switch kind {
        case .grid:
            guard let rows, let columns, let rowPercentages, let columnPercentages, let cellChildMap,
                  referenceWidth == nil, referenceHeight == nil, zones == nil else { throw PersistenceError.invalidData("grid fields") }
            return .grid(GridLayout(
                id: LayoutID(rawValue: id), rows: rows, columns: columns,
                rowPercentages: rowPercentages, columnPercentages: columnPercentages,
                cellChildMap: cellChildMap
            ))
        case .canvas, .focus:
            guard let referenceWidth, let referenceHeight, let zones,
                  rows == nil, columns == nil, rowPercentages == nil, columnPercentages == nil, cellChildMap == nil else {
                throw PersistenceError.invalidData("canvas fields")
            }
            let canvas = CanvasLayout(
                id: LayoutID(rawValue: id),
                referenceSize: CGSize(width: referenceWidth, height: referenceHeight),
                zones: zones.map {
                    CanvasZone(id: ZoneID(rawValue: $0.id), frame: CGRect(x: $0.originX, y: $0.originY, width: $0.width, height: $0.height))
                }
            )
            return kind == .focus ? .focus(canvas) : .canvas(canvas)
        }
    }

    func validate() throws {
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed == name else { throw PersistenceError.invalidData("layout name") }
        }
        guard spacing.isFinite, spacing >= 0, (1 ... LayoutEngine.maximumDimension).contains(zoneCount),
              LayoutTemplate(rawValue: template) != nil else { throw PersistenceError.invalidData("layout metadata") }
        let decodedDefinition = try definition()
        let definitionID: UUID
        switch decodedDefinition {
        case .grid(let grid): definitionID = grid.id.rawValue
        case .canvas(let canvas), .focus(let canvas): definitionID = canvas.id.rawValue
        }
        guard definitionID == id else { throw PersistenceError.invalidData("layout ID mismatch") }
        if kind == .canvas, spacing != 0 { throw PersistenceError.invalidData("canvas spacing") }
        let definition = try definition()
        switch definition {
        case .grid(let grid):
            try LayoutEngine.validateGridStructure(grid)
        case .canvas(let canvas):
            _ = try LayoutEngine.canvasZones(canvas, in: CGRect(x: 0, y: 0, width: 10_000, height: 10_000))
        case .focus(let canvas):
            _ = try LayoutEngine.canvasZones(canvas, in: CGRect(x: 0, y: 0, width: 10_000, height: 10_000))
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

enum PersistedSetting: Codable, Equatable, Sendable {
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case string(String)

    private enum CodingKeys: String, CodingKey { case type, bool, integer, number, string }
    private enum ValueType: String, Codable { case bool, integer, number, string }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ValueType.self, forKey: .type) {
        case .bool: self = .bool(try container.decode(Bool.self, forKey: .bool))
        case .integer: self = .integer(try container.decode(Int.self, forKey: .integer))
        case .number: self = .number(try container.decode(Double.self, forKey: .number))
        case .string: self = .string(try container.decode(String.self, forKey: .string))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bool(let value): try container.encode(ValueType.bool, forKey: .type); try container.encode(value, forKey: .bool)
        case .integer(let value): try container.encode(ValueType.integer, forKey: .type); try container.encode(value, forKey: .integer)
        case .number(let value): try container.encode(ValueType.number, forKey: .type); try container.encode(value, forKey: .number)
        case .string(let value): try container.encode(ValueType.string, forKey: .type); try container.encode(value, forKey: .string)
        }
    }
}

struct VersionedStore<Value: Codable & Sendable>: Codable, Sendable {
    let schemaVersion: Int
    var value: Value
}

struct LayoutStore: Codable, Sendable {
    var layouts: [PersistedLayout]
}

struct AssignmentStore: Codable, Sendable {
    var assignments: [PersistedAssignment]
}

/// A stable, privacy-preserving key for a window's last successful zone assignment.
/// Process identifiers, accessibility handles, titles, and transient display IDs are
/// deliberately absent so a record survives launches without identifying a window.
struct AppZoneHistoryKey: Codable, Hashable, Sendable {
    let bundleID: String
    let displayUUID: UUID
    let spaceScope: PersistedSpaceScope
    let layoutID: UUID
}

struct AppZoneHistoryRecord: Codable, Equatable, Sendable {
    let key: AppZoneHistoryKey
    let zoneIDs: [Int]
    let revision: UInt64

    init(key: AppZoneHistoryKey, zoneIDs: [Int], revision: UInt64) {
        self.key = key
        self.zoneIDs = Self.normalized(zoneIDs)
        self.revision = revision
    }

    static func normalized(_ zoneIDs: [Int]) -> [Int] {
        var seen = Set<Int>()
        return zoneIDs.filter { seen.insert($0).inserted }.sorted()
    }
}

struct AppZoneHistoryStore: Codable, Sendable {
    var records: [AppZoneHistoryRecord]
}

struct SettingsStore: Codable, Sendable {
    var values: [String: PersistedSetting]
}

enum PersistenceError: LocalizedError {
    case invalidData(String)
    case unknownSchema(Int)
    case backupFailed(URL)
    case storeUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidData(let detail): "Saved data is invalid: \(detail)."
        case .unknownSchema(let version): "Saved data uses unsupported schema version \(version)."
        case .backupFailed(let url): "Could not safely back up damaged data at \(url.path)."
        case .storeUnavailable(let name): "The \(name) store is unavailable."
        }
    }
}

enum AppZoneHistoryWriterProcessLock {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var claimedPaths = Set<String>()

    static func claim(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return claimedPaths.insert(path).inserted
    }

    static func release(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        claimedPaths.remove(path)
    }
}

protocol AtomicFileAccess: Sendable {
    func read(_ url: URL) throws -> Data?
    func writeAtomically(_ data: Data, to url: URL) throws
}

struct LocalAtomicFileAccess: AtomicFileAccess {
    func read(_ url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

struct StoreURLs: Sendable {
    let layouts: URL
    let assignments: URL
    let settings: URL
    let appZoneHistory: URL

    init(directory: URL) {
        layouts = directory.appendingPathComponent("layouts.json")
        assignments = directory.appendingPathComponent("assignments.json")
        settings = directory.appendingPathComponent("settings.json")
        appZoneHistory = directory.appendingPathComponent("app-zone-history.json")
    }
}

struct LoadedPersistentState: Sendable {
    var layouts: [UUID: PersistedLayout]
    var assignments: PersistedAssignments
    var assignmentsAvailable: Bool
    var settings: [String: PersistedSetting]
    var appZoneHistory: [AppZoneHistoryKey: AppZoneHistoryRecord]
    var appZoneHistoryAvailable: Bool
    var maxAppZoneHistoryRevision: UInt64
    var layoutStoreNeedsRepair: Bool
}

actor PersistentStoreCoordinator {
    static let defaultLayoutID = UUID(uuid: (0xA1, 0x10, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04))
    let urls: StoreURLs
    let fileAccess: any AtomicFileAccess
    let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    var protectedStores = Set<String>()
    var appZoneHistoryWriterFD: Int32?
    var appZoneHistoryWriterPath: String?
    var appZoneHistoryWriterUnavailable = false
    var appZoneHistoryLoadAttempted = false
    var appZoneHistoryAvailable = false
    var appZoneHistoryNeedsPrune = false
    private var legacyAssignmentBytes: Data?
    private var legacyHistoryBytes: Data?

    init(directory: URL, fileAccess: any AtomicFileAccess = LocalAtomicFileAccess()) {
        urls = StoreURLs(directory: directory)
        self.fileAccess = fileAccess
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    deinit {
        if let appZoneHistoryWriterFD {
            _ = Darwin.lockf(appZoneHistoryWriterFD, F_ULOCK, 0)
            _ = Darwin.close(appZoneHistoryWriterFD)
        }
        if let appZoneHistoryWriterPath { AppZoneHistoryWriterProcessLock.release(appZoneHistoryWriterPath) }
    }

    static func applicationSupportDirectory(fileManager: FileManager = .default) throws -> URL {
        try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("jp.a2c.AppAlign", isDirectory: true)
    }

    func load() throws -> LoadedPersistentState {
        appZoneHistoryLoadAttempted = true
        let layoutFile = try loadStore(LayoutStore.self, at: urls.layouts, name: "layouts", default: LayoutStore(layouts: [Self.defaultLayout()]), validate: Self.validateLayouts)
        let assignmentFile: LoadedStore<AssignmentStore>?
        do {
            assignmentFile = try loadStore(AssignmentStore.self, at: urls.assignments, name: "assignments",
                                           default: AssignmentStore(assignments: []), validate: Self.validateAssignments)
            legacyAssignmentBytes = assignmentFile?.schemaVersion == 1 ? assignmentFile?.sourceBytes : nil
        } catch {
            assignmentFile = nil
        }
        let settingsFile = try loadStore(SettingsStore.self, at: urls.settings, name: "settings", default: SettingsStore(values: [:]), validate: Self.validateSettings)
        let layouts = Dictionary(uniqueKeysWithValues: layoutFile.value.layouts.map { ($0.id, $0) })
        let historyFile: LoadedStore<AppZoneHistoryStore>?
        if (try? ensureAppZoneHistoryWriter()) != nil {
            historyFile = try? loadStore(AppZoneHistoryStore.self, at: urls.appZoneHistory, name: "app-zone-history",
                                         default: AppZoneHistoryStore(records: []), validate: Self.validateAppZoneHistory)
            legacyHistoryBytes = historyFile?.schemaVersion == 1 ? historyFile?.sourceBytes : nil
            appZoneHistoryAvailable = historyFile != nil
        } else {
            historyFile = nil
            appZoneHistoryAvailable = false
        }
        let catalogTrusted = !layoutFile.wasRecovered
        if !catalogTrusted {
            protectedStores.insert("assignments")
            protectedStores.insert("app-zone-history")
            appZoneHistoryAvailable = false
            appZoneHistoryNeedsPrune = false
        }
        let history: [AppZoneHistoryKey: AppZoneHistoryRecord] = Dictionary(
            (catalogTrusted ? (historyFile?.value.records ?? []) : []).compactMap { record in
                guard Self.isValid(record, layouts: layouts) else { return nil }
                return (record.key, record)
            }, uniquingKeysWith: { existing, incoming in
                existing.revision >= incoming.revision ? existing : incoming
            })
        let maxHistoryRevision = historyFile?.value.records.map(\.revision).max() ?? 0
        if catalogTrusted, let historyFile, history.count != historyFile.value.records.count { appZoneHistoryNeedsPrune = true }
        var assignments = PersistedAssignments()
        let decodedAssignments = assignmentFile?.value.assignments ?? []
        if catalogTrusted, decodedAssignments.allSatisfy({ layouts[$0.layoutID] != nil }) {
            for assignment in decodedAssignments { assignments[assignment.key] = assignment }
        } else {
            protectedStores.insert("assignments")
        }
        return LoadedPersistentState(layouts: layouts, assignments: assignments,
                                     assignmentsAvailable: catalogTrusted && assignmentFile != nil && !protectedStores.contains("assignments"),
                                     settings: settingsFile.value.values,
                                     appZoneHistory: history, appZoneHistoryAvailable: appZoneHistoryAvailable,
                                     maxAppZoneHistoryRevision: maxHistoryRevision,
                                     layoutStoreNeedsRepair: layoutFile.wasRecovered)
    }

    func saveLayouts(_ layouts: [PersistedLayout]) throws {
        try ensureWritable("layouts")
        let ordered = layouts.sorted { $0.id.uuidString < $1.id.uuidString }
        try Self.validateLayouts(LayoutStore(layouts: ordered))
        try save(LayoutStore(layouts: ordered), to: urls.layouts)
        // Layout persistence remains authoritative if history cleanup fails. Loads
        // and future upserts validate against the saved catalog and cannot revive it.
        if appZoneHistoryAvailable {
            appZoneHistoryNeedsPrune = true
            do {
                try pruneAppZoneHistory(validLayouts: Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) }))
            } catch {
                // The history-specific pending flag is retried by flush without turning
                // a successfully saved layout catalog into a failed layout transaction.
            }
        }
    }

    func saveAssignments(_ assignments: [PersistedAssignment]) throws {
        try ensureWritable("assignments")
        try ensureWritable("layouts")
        try Self.validateAssignments(AssignmentStore(assignments: assignments))
        let ordered = assignments.sorted {
            if $0.displayUUID != $1.displayUUID { return $0.displayUUID.uuidString < $1.displayUUID.uuidString }
            return String(describing: $0.spaceScope) < String(describing: $1.spaceScope)
        }
        try backupLegacyStoreIfNeeded(name: "assignments", url: urls.assignments)
        try save(AssignmentStore(assignments: ordered), to: urls.assignments)
        legacyAssignmentBytes = nil
    }

    func saveSettings(_ settings: [String: PersistedSetting]) throws {
        try ensureWritable("settings")
        try Self.validateSettings(SettingsStore(values: settings))
        try save(SettingsStore(values: settings), to: urls.settings)
    }

    func saveLayoutAndAssignments(_ layouts: [PersistedLayout], _ assignments: [PersistedAssignment]) throws {
        try preflight(layouts, assignments)
        try saveLayouts(layouts)
        try saveAssignments(assignments)
    }

    func saveAssignmentsAndLayouts(_ assignments: [PersistedAssignment], _ layouts: [PersistedLayout]) throws {
        try preflight(layouts, assignments)
        try saveAssignments(assignments)
        try saveLayouts(layouts)
    }

    func flush() throws {
        guard appZoneHistoryNeedsPrune else { return }
        let loaded = try loadStore(LayoutStore.self, at: urls.layouts, name: "layouts",
                                   default: LayoutStore(layouts: [Self.defaultLayout()]), validate: Self.validateLayouts)
        let layouts = Dictionary(uniqueKeysWithValues: loaded.value.layouts.map { ($0.id, $0) })
        try pruneAppZoneHistory(validLayouts: layouts)
    }

    func loadStore<Value: Codable & Sendable>(
        _ type: Value.Type,
        at url: URL,
        name: String,
        default defaultValue: Value,
        validate: (Value) throws -> Void
    ) throws -> LoadedStore<Value> {
        try ensureWritable(name)
        let bytes: Data
        do {
            guard let readBytes = try fileAccess.read(url) else {
                return LoadedStore(value: defaultValue, wasRecovered: false, sourceBytes: Data(), schemaVersion: name == "assignments" || name == "app-zone-history" ? 2 : 1)
            }
            bytes = readBytes
        } catch {
            protectedStores.insert(name)
            throw PersistenceError.storeUnavailable(name)
        }
        do {
            let header = try decoder.decode(StoreHeader.self, from: bytes)
            let supportsMigration = name == "assignments" || name == "app-zone-history"
            guard header.schemaVersion == 1 || (supportsMigration && header.schemaVersion == 2) else {
                throw PersistenceError.unknownSchema(header.schemaVersion)
            }
            if supportsMigration { try validateSpaceStoreShape(bytes, name: name, schemaVersion: header.schemaVersion) }
            let file = try decoder.decode(VersionedStore<Value>.self, from: bytes)
            try validate(file.value)
            if header.schemaVersion == 1 { try validateLegacyCommonScope(file.value, name: name) }
            return LoadedStore(value: file.value, wasRecovered: false, sourceBytes: bytes, schemaVersion: header.schemaVersion)
        } catch {
            if name == "assignments" || name == "app-zone-history" {
                protectedStores.insert(name)
                throw PersistenceError.storeUnavailable(name)
            }
            do {
                try recover(bytes: bytes, original: url, defaultValue: defaultValue)
                return LoadedStore(value: defaultValue, wasRecovered: true, sourceBytes: bytes, schemaVersion: 1)
            } catch {
                protectedStores.insert(name)
                throw PersistenceError.storeUnavailable(name)
            }
        }
    }

    private func recover<Value: Codable & Sendable>(bytes: Data, original: URL, defaultValue: Value) throws {
        try backup(bytes: bytes, original: original)
        try save(defaultValue, to: original)
    }

    private func backup(bytes: Data, original: URL) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let suffix = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString
        let backup = original.deletingLastPathComponent().appendingPathComponent("\(original.lastPathComponent).\(suffix).backup")
        do {
            try fileAccess.writeAtomically(bytes, to: backup)
            guard try fileAccess.read(backup) == bytes else { throw PersistenceError.backupFailed(backup) }
        } catch {
            throw PersistenceError.backupFailed(backup)
        }
    }

    func ensureWritable(_ name: String) throws {
        guard !protectedStores.contains(name) else { throw PersistenceError.storeUnavailable(name) }
    }

    private func preflight(_ layouts: [PersistedLayout], _ assignments: [PersistedAssignment]) throws {
        try ensureWritable("layouts")
        try ensureWritable("assignments")
        try Self.validateLayouts(LayoutStore(layouts: layouts))
        try Self.validateAssignments(AssignmentStore(assignments: assignments))
        let layoutIDs = Set(layouts.map(\.id))
        guard assignments.allSatisfy({ layoutIDs.contains($0.layoutID) }) else {
            throw PersistenceError.invalidData("assignment references missing layout")
        }
    }

    func save<Value: Codable & Sendable>(_ value: Value, to url: URL) throws {
        let version = url == urls.assignments || url == urls.appZoneHistory ? 2 : 1
        try fileAccess.writeAtomically(encoder.encode(VersionedStore(schemaVersion: version, value: value)), to: url)
    }

    func backupLegacyStoreIfNeeded(name: String, url: URL) throws {
        let bytes = name == "assignments" ? legacyAssignmentBytes : legacyHistoryBytes
        guard let bytes else { return }
        try backup(bytes: bytes, original: url)
    }

    func markLegacyStoreMigrated(_ name: String) {
        if name == "assignments" { legacyAssignmentBytes = nil } else if name == "app-zone-history" { legacyHistoryBytes = nil }
    }

    static func validateLayouts(_ store: LayoutStore) throws {
        guard Set(store.layouts.map(\.id)).count == store.layouts.count else { throw PersistenceError.invalidData("duplicate layout IDs") }
        for layout in store.layouts { try layout.validate() }
    }

    static func validateAssignments(_ store: AssignmentStore) throws {
        guard Set(store.assignments.map(\.key)).count == store.assignments.count else {
            throw PersistenceError.invalidData("duplicate assignments")
        }
    }

    private static func validateSettings(_ store: SettingsStore) throws {
        guard store.values.values.allSatisfy({ if case .number(let value) = $0 { return value.isFinite }; return true }) else {
            throw PersistenceError.invalidData("non-finite setting")
        }
    }

    static func defaultLayout() -> PersistedLayout {
        let grid = GridLayout(
            id: LayoutID(rawValue: defaultLayoutID), rows: 2, columns: 2,
            rowPercentages: [5_000, 5_000], columnPercentages: [5_000, 5_000],
            cellChildMap: [[0, 1], [2, 3]]
        )
        return PersistedLayout(id: defaultLayoutID, definition: .grid(grid), spacing: 10, template: .grid, zoneCount: 4)
    }
}

private struct StoreHeader: Decodable {
    let schemaVersion: Int
}

struct LoadedStore<Value: Sendable> {
    let value: Value
    let wasRecovered: Bool
    let sourceBytes: Data
    let schemaVersion: Int
}
