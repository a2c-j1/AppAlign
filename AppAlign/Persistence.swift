import CoreGraphics
import Foundation

enum PersistedSpaceScope: String, Codable, Sendable {
    case common
}

struct PersistedAssignment: Codable, Equatable, Sendable {
    let displayUUID: UUID
    let spaceScope: PersistedSpaceScope
    let layoutID: UUID
}

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

    init(directory: URL) {
        layouts = directory.appendingPathComponent("layouts.json")
        assignments = directory.appendingPathComponent("assignments.json")
        settings = directory.appendingPathComponent("settings.json")
    }
}

struct LoadedPersistentState: Sendable {
    var layouts: [UUID: PersistedLayout]
    var assignments: [UUID: PersistedAssignment]
    var settings: [String: PersistedSetting]
    var layoutStoreNeedsRepair: Bool
}

actor PersistentStoreCoordinator {
    static let defaultLayoutID = UUID(uuid: (0xA1, 0x10, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04))
    private let urls: StoreURLs
    private let fileAccess: any AtomicFileAccess
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private var protectedStores = Set<String>()

    init(directory: URL, fileAccess: any AtomicFileAccess = LocalAtomicFileAccess()) {
        urls = StoreURLs(directory: directory)
        self.fileAccess = fileAccess
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    static func applicationSupportDirectory(fileManager: FileManager = .default) throws -> URL {
        try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("jp.a2c.AppAlign", isDirectory: true)
    }

    func load() throws -> LoadedPersistentState {
        let layoutFile = try loadStore(LayoutStore.self, at: urls.layouts, name: "layouts", default: LayoutStore(layouts: [Self.defaultLayout()]), validate: Self.validateLayouts)
        let assignmentFile = try loadStore(AssignmentStore.self, at: urls.assignments, name: "assignments", default: AssignmentStore(assignments: []), validate: Self.validateAssignments)
        let settingsFile = try loadStore(SettingsStore.self, at: urls.settings, name: "settings", default: SettingsStore(values: [:]), validate: Self.validateSettings)
        let layouts = Dictionary(uniqueKeysWithValues: layoutFile.value.layouts.map { ($0.id, $0) })
        var assignments: [UUID: PersistedAssignment] = [:]
        var repaired = false
        for assignment in assignmentFile.value.assignments {
            guard layouts[assignment.layoutID] != nil else { repaired = true; continue }
            assignments[assignment.displayUUID] = assignment
        }
        if repaired {
            do {
                try backup(bytes: assignmentFile.sourceBytes, original: urls.assignments)
                try saveAssignments(Array(assignments.values))
            } catch {
                protectedStores.insert("assignments")
                throw PersistenceError.storeUnavailable("assignments")
            }
        }
        return LoadedPersistentState(layouts: layouts, assignments: assignments, settings: settingsFile.value.values, layoutStoreNeedsRepair: layoutFile.wasRecovered)
    }

    func saveLayouts(_ layouts: [PersistedLayout]) throws {
        try ensureWritable("layouts")
        let ordered = layouts.sorted { $0.id.uuidString < $1.id.uuidString }
        try Self.validateLayouts(LayoutStore(layouts: ordered))
        try save(LayoutStore(layouts: ordered), to: urls.layouts)
    }

    func saveAssignments(_ assignments: [PersistedAssignment]) throws {
        try ensureWritable("assignments")
        try ensureWritable("layouts")
        try Self.validateAssignments(AssignmentStore(assignments: assignments))
        let ordered = assignments.sorted { $0.displayUUID.uuidString < $1.displayUUID.uuidString }
        try save(AssignmentStore(assignments: ordered), to: urls.assignments)
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

    func flush() throws {}

    private func loadStore<Value: Codable & Sendable>(
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
                return LoadedStore(value: defaultValue, wasRecovered: false, sourceBytes: Data())
            }
            bytes = readBytes
        } catch {
            protectedStores.insert(name)
            throw PersistenceError.storeUnavailable(name)
        }
        do {
            let header = try decoder.decode(StoreHeader.self, from: bytes)
            guard header.schemaVersion == 1 else { throw PersistenceError.unknownSchema(header.schemaVersion) }
            let file = try decoder.decode(VersionedStore<Value>.self, from: bytes)
            try validate(file.value)
            return LoadedStore(value: file.value, wasRecovered: false, sourceBytes: bytes)
        } catch {
            do {
                try recover(bytes: bytes, original: url, defaultValue: defaultValue)
                return LoadedStore(value: defaultValue, wasRecovered: true, sourceBytes: bytes)
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

    private func ensureWritable(_ name: String) throws {
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

    private func save<Value: Codable & Sendable>(_ value: Value, to url: URL) throws {
        try fileAccess.writeAtomically(encoder.encode(VersionedStore(schemaVersion: 1, value: value)), to: url)
    }

    private static func validateLayouts(_ store: LayoutStore) throws {
        guard Set(store.layouts.map(\.id)).count == store.layouts.count else { throw PersistenceError.invalidData("duplicate layout IDs") }
        for layout in store.layouts { try layout.validate() }
    }

    private static func validateAssignments(_ store: AssignmentStore) throws {
        guard Set(store.assignments.map(\.displayUUID)).count == store.assignments.count,
              store.assignments.allSatisfy({ $0.spaceScope == .common }) else { throw PersistenceError.invalidData("assignments") }
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

private struct LoadedStore<Value: Sendable> {
    let value: Value
    let wasRecovered: Bool
    let sourceBytes: Data
}
