import Foundation

struct PersistentSpaceID: Codable, Hashable, Sendable {
    let backend: String
    let opaqueID: String

    init?(backend: String, opaqueID: String) {
        guard !backend.isEmpty, !opaqueID.isEmpty,
              backend.trimmingCharacters(in: .whitespacesAndNewlines) == backend,
              opaqueID.trimmingCharacters(in: .whitespacesAndNewlines) == opaqueID else { return nil }
        self.backend = backend
        self.opaqueID = opaqueID
    }

    private enum CodingKeys: String, CodingKey { case backend, opaqueID }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let value = Self(backend: try container.decode(String.self, forKey: .backend),
                               opaqueID: try container.decode(String.self, forKey: .opaqueID)) else {
            throw DecodingError.dataCorruptedError(forKey: .opaqueID, in: container,
                                                   debugDescription: "Invalid persistent Space identifier")
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(backend, forKey: .backend)
        try container.encode(opaqueID, forKey: .opaqueID)
    }
}

enum PersistedSpaceScope: Codable, Hashable, Sendable {
    case common
    case space(PersistentSpaceID)

    private enum CodingKeys: String, CodingKey { case kind, space }
    private enum Kind: String, Codable { case common, space }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let legacy = try? single.decode(String.self), legacy == "common" {
            self = .common
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .common: self = .common
        case .space: self = .space(try container.decode(PersistentSpaceID.self, forKey: .space))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .common: try container.encode(Kind.common, forKey: .kind)
        case .space(let id):
            try container.encode(Kind.space, forKey: .kind)
            try container.encode(id, forKey: .space)
        }
    }
}

struct PersistedAssignmentKey: Hashable, Sendable {
    let displayUUID: UUID
    let spaceScope: PersistedSpaceScope
}

struct PersistedAssignments: Equatable, Sendable {
    private var storage: [PersistedAssignmentKey: PersistedAssignment] = [:]

    subscript(_ key: PersistedAssignmentKey) -> PersistedAssignment? {
        get { storage[key] }
        set { storage[key] = newValue }
    }

    /// Compatibility accessor for legacy common-scope call sites and tests.
    subscript(_ displayUUID: UUID) -> PersistedAssignment? {
        get { storage[PersistedAssignmentKey(displayUUID: displayUUID, spaceScope: .common)] }
        set { storage[PersistedAssignmentKey(displayUUID: displayUUID, spaceScope: .common)] = newValue }
    }

    var values: [PersistedAssignment] { Array(storage.values) }
    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }
    var keys: Dictionary<PersistedAssignmentKey, PersistedAssignment>.Keys { storage.keys }
    var allValues: [PersistedAssignment] { Array(storage.values) }

    init() {}

    init<S: Sequence>(_ assignments: S) where S.Element == PersistedAssignment {
        for assignment in assignments { storage[assignment.key] = assignment }
    }

    mutating func removeValue(forKey key: PersistedAssignmentKey) -> PersistedAssignment? { storage.removeValue(forKey: key) }
    mutating func removeValue(forKey displayUUID: UUID) -> PersistedAssignment? {
        storage.removeValue(forKey: PersistedAssignmentKey(displayUUID: displayUUID, spaceScope: .common))
    }
    func filter(_ isIncluded: ((key: PersistedAssignmentKey, value: PersistedAssignment)) throws -> Bool) rethrows
        -> PersistedAssignments {
        PersistedAssignments(try storage.filter(isIncluded).map(\.value))
    }
}

extension PersistedAssignment {
    var key: PersistedAssignmentKey { PersistedAssignmentKey(displayUUID: displayUUID, spaceScope: spaceScope) }
}

struct PersistedAssignment: Codable, Equatable, Sendable {
    let displayUUID: UUID
    let spaceScope: PersistedSpaceScope
    let layoutID: UUID
}
