import CoreGraphics
import Foundation

struct RuntimeDisplayID: Hashable, Sendable {
    let rawValue: UInt32
}

struct PersistentDisplayID: Hashable, Sendable {
    let uuid: UUID
}

enum DisplaySelectionID: Hashable, Sendable {
    case persistent(PersistentDisplayID)
    case session(UUID)
}

struct WorkAreaKey: Hashable, Sendable {
    let display: DisplaySelectionID
    let spaceScope: UUID?
}

struct ResolvedDisplayIdentity: Equatable, Sendable {
    let persistentID: PersistentDisplayID?
    let sessionID: UUID
}

struct DisplayIdentityCandidate: Sendable {
    let runtimeID: UInt32
    let uuid: UUID?
}

struct DisplayIdentityResolver {
    private var sessionIDs: [UInt32: UUID] = [:]

    mutating func resolve(runtimeID: UInt32, uuid: UUID?, isUnique: Bool = true) -> ResolvedDisplayIdentity {
        let persistentID = uuid.flatMap { isUnique ? PersistentDisplayID(uuid: $0) : nil }
        let sessionID: UUID
        if let existing = sessionIDs[runtimeID] {
            sessionID = existing
        } else {
            let created = UUID()
            sessionIDs[runtimeID] = created
            sessionID = created
        }
        return ResolvedDisplayIdentity(persistentID: persistentID, sessionID: sessionID)
    }

    mutating func resolveSnapshot(_ candidates: [DisplayIdentityCandidate]) -> [ResolvedDisplayIdentity] {
        let runtimeIDs = Set(candidates.map(\.runtimeID))
        sessionIDs = sessionIDs.filter { runtimeIDs.contains($0.key) }
        let counts = Dictionary(grouping: candidates.compactMap(\.uuid), by: { $0 }).mapValues { $0.count }
        return candidates.map { candidate in
            resolve(runtimeID: candidate.runtimeID, uuid: candidate.uuid, isUnique: candidate.uuid.map { counts[$0] == 1 } ?? false)
        }
    }
}

struct Display: Identifiable, Equatable, Sendable {
    let runtimeID: RuntimeDisplayID
    let persistentID: PersistentDisplayID?
    let sessionID: UUID
    let name: String
    let frame: CGRect
    let workArea: CGRect
    let isPrimary: Bool
    let backingScaleFactor: CGFloat

    var id: DisplaySelectionID {
        if let persistentID { return .persistent(persistentID) }
        return .session(sessionID)
    }
    var selectionKey: WorkAreaKey { WorkAreaKey(display: id, spaceScope: nil) }
    var persistentWorkAreaKey: WorkAreaKey? {
        guard let persistentID else { return nil }
        return WorkAreaKey(display: .persistent(persistentID), spaceScope: nil)
    }
}

struct DisplaySnapshot: Equatable, Sendable {
    let displays: [Display]
    let primaryFrame: CGRect

    var fingerprint: String {
        displays.map {
            "\($0.runtimeID.rawValue):\($0.frame.origin.x),\($0.frame.origin.y),\($0.frame.width),\($0.frame.height):\($0.workArea.origin.x),\($0.workArea.origin.y),\($0.workArea.width),\($0.workArea.height):\($0.backingScaleFactor)"
        }.joined(separator: "|")
    }
}
