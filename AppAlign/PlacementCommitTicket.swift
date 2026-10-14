import Foundation

struct PlacementRevision: Equatable, Sendable {
    let configuration: UInt64
    let layout: UInt64
}

/// Serializes layout invalidation with the last point at which either AX path
/// may begin or continue writing. The lock is never held across AX/AppKit work.
final class PlacementValidity: @unchecked Sendable {
    enum State: Equatable { case pending, writing, invalidated, completed, finished }

    private struct Entry {
        var state: State
        let revision: PlacementRevision
        var didBeginWriting: Bool
    }

    private let lock = NSLock()
    private var configurationRevision: UInt64 = 0
    private var layoutRevision: UInt64 = 0
    private var accepting = true
    private var entries: [UUID: Entry] = [:]

    var revision: PlacementRevision {
        lock.withLock { PlacementRevision(configuration: configurationRevision, layout: layoutRevision) }
    }
    var isAccepting: Bool { lock.withLock { accepting } }

    func reserve(startDeadline: UInt64, totalDeadline: UInt64) -> PlacementCommitTicket? {
        lock.withLock {
            let pendingCount = entries.values.filter { !$0.didBeginWriting }.count
            guard accepting,
                  pendingCount < 1,
                  entries.count < 2 else { return nil }
            let id = UUID()
            let revision = PlacementRevision(configuration: configurationRevision, layout: layoutRevision)
            entries[id] = Entry(state: .pending, revision: revision, didBeginWriting: false)
            return PlacementCommitTicket(id: id, validity: self, revision: revision,
                                         startDeadline: startDeadline, totalDeadline: totalDeadline)
        }
    }

    fileprivate func registerFixtureTicket(_ id: UUID, revision: PlacementRevision) {
        lock.withLock { entries[id] = Entry(state: .pending, revision: revision, didBeginWriting: false) }
    }

    func invalidateForConfigurationChange() -> UInt64 {
        lock.withLock {
            configurationRevision &+= 1
            accepting = false
            invalidateEntries()
            return configurationRevision
        }
    }

    func publishConfiguration(revision: UInt64) -> Bool {
        lock.withLock {
            guard revision == configurationRevision else { return false }
            accepting = true
            return true
        }
    }

    func invalidateForLayoutChange() {
        lock.withLock {
            layoutRevision &+= 1
            invalidateEntries()
        }
    }

    func invalidateAll() {
        lock.withLock { invalidateEntries() }
    }

    private func invalidateEntries() {
        for id in entries.keys {
            guard var entry = entries[id], entry.state == .pending || entry.state == .writing else { continue }
            entry.state = .invalidated
            entries[id] = entry
        }
    }

    fileprivate func state(of id: UUID, revision: PlacementRevision) -> State {
        lock.withLock {
            guard let entry = entries[id], entry.revision == revision,
                  revision.configuration == configurationRevision,
                  revision.layout == layoutRevision else { return .invalidated }
            return entry.state
        }
    }

    fileprivate func invalidate(_ id: UUID) {
        lock.withLock {
            guard var entry = entries[id], entry.state == .pending || entry.state == .writing else { return }
            entry.state = .invalidated
            entries[id] = entry
        }
    }

    fileprivate func beginWrite(_ id: UUID, revision: PlacementRevision, now: UInt64,
                                startDeadline: UInt64, totalDeadline: UInt64) -> Bool {
        lock.withLock {
            guard accepting, now < startDeadline, now < totalDeadline,
                  revision.configuration == configurationRevision,
                  revision.layout == layoutRevision,
                  var entry = entries[id], entry.state == .pending,
                  entry.revision == revision else {
                if var entry = entries[id], entry.state == .pending {
                    entry.state = .invalidated
                    entries[id] = entry
                }
                return false
            }
            // A second reserved ticket may wait in the single pending slot,
            // but a transient busy result must leave it pending for retry.
            guard !entries.contains(where: { $0.key != id && $0.value.didBeginWriting }) else { return false }
            entry.state = .writing
            entry.didBeginWriting = true
            entries[id] = entry
            return true
        }
    }

    fileprivate func mayContinueWrite(_ id: UUID, revision: PlacementRevision, now: UInt64,
                                      totalDeadline: UInt64) -> Bool {
        lock.withLock {
            guard now < totalDeadline, accepting,
                  revision.configuration == configurationRevision,
                  revision.layout == layoutRevision,
                  let entry = entries[id] else { return false }
            return entry.state == .writing && entry.revision == revision
        }
    }

    fileprivate func completeIfCurrent(
        _ id: UUID,
        revision: PlacementRevision,
        now: UInt64,
        totalDeadline: UInt64
    ) -> Bool {
        lock.withLock {
            guard now < totalDeadline, accepting,
                  revision.configuration == configurationRevision,
                  revision.layout == layoutRevision,
                  var entry = entries[id], entry.state == .writing,
                  entry.revision == revision else { return false }
            entry.state = .completed
            entries[id] = entry
            return true
        }
    }

    fileprivate func finish(_ id: UUID) {
        _ = lock.withLock {
            // Keep invalidation terminal; always release the bounded slot.
            entries.removeValue(forKey: id)
        }
    }
}

final class PlacementCommitTicket: @unchecked Sendable {
    let startDeadline: UInt64
    let totalDeadline: UInt64
    let revision: PlacementRevision
    private let id: UUID
    private let validity: PlacementValidity

    fileprivate init(id: UUID, validity: PlacementValidity, revision: PlacementRevision,
                     startDeadline: UInt64, totalDeadline: UInt64) {
        self.id = id
        self.validity = validity
        self.revision = revision
        self.startDeadline = startDeadline
        self.totalDeadline = totalDeadline
    }

    convenience init(startDeadline: UInt64, totalDeadline: UInt64) {
        let validity = PlacementValidity()
        // Compatibility initializer for isolated unit fixtures. Production
        // controllers reserve from LayoutController's shared validity.
        self.init(id: UUID(), validity: validity, revision: validity.revision,
                  startDeadline: startDeadline, totalDeadline: totalDeadline)
        validity.registerFixtureTicket(id, revision: revision)
    }

    var state: PlacementValidity.State { validity.state(of: id, revision: revision) }
    func invalidate() { validity.invalidate(id) }
    func beginWrite(now: UInt64) -> Bool {
        validity.beginWrite(id, revision: revision, now: now,
                            startDeadline: startDeadline, totalDeadline: totalDeadline)
    }
    func mayContinueWrite(now: UInt64) -> Bool {
        validity.mayContinueWrite(id, revision: revision, now: now, totalDeadline: totalDeadline)
    }
    func completeIfCurrent(now: UInt64) -> Bool {
        validity.completeIfCurrent(id, revision: revision, now: now, totalDeadline: totalDeadline)
    }
    func finish() { validity.finish(id) }
}

typealias DragCommitTicket = PlacementCommitTicket
