import Foundation

/// Input callbacks and Carbon commands share this acceptance point. Physical
/// timestamps from different producers do not define the ordering contract.
final class OrderedInteractionInbox: @unchecked Sendable {
    private enum Entry {
        case input(DragInputEvent, UUID, UInt64, @MainActor @Sendable (DragInputEvent) -> Void)
        case control(@MainActor @Sendable () -> Void)
    }

    private let lock = NSLock()
    private let capacity: Int
    private var entries: [Entry] = []
    private var scheduled = false

    init(capacity: Int = 256) { self.capacity = max(1, capacity) }

    @discardableResult
    func enqueueControl(_ action: @escaping @MainActor @Sendable () -> Void) -> Bool {
        lock.lock()
        guard entries.count < capacity else { lock.unlock(); return false }
        entries.append(.control(action))
        scheduleIfNeeded()
        lock.unlock()
        return true
    }

    func enqueueInput(_ event: DragInputEvent, source: UUID, generation: UInt64,
                      deliver: @escaping @MainActor @Sendable (DragInputEvent) -> Void) {
        lock.lock()
        let incoming = Entry.input(event, source, generation, deliver)
        if let last = entries.last, Self.canCoalesce(last, event: event, source: source, generation: generation) {
            entries[entries.count - 1] = incoming
        } else if entries.count < capacity {
            entries.append(incoming)
        } else {
            // A backlog must not lose mouseUp and later commit an old selection.
            entries.removeAll(keepingCapacity: true)
            let overflow = DragInputEvent(kind: .overflow, location: event.location, flags: event.flags,
                                          timestamp: event.timestamp, sequence: event.sequence,
                                          epoch: event.epoch, gesture: event.gesture, buttonMask: event.buttonMask)
            entries.append(.input(overflow, source, generation, deliver))
        }
        scheduleIfNeeded()
        lock.unlock()
    }

    var pendingCount: Int { lock.withLock { entries.count } }

    private static func canCoalesce(_ last: Entry, event: DragInputEvent, source: UUID, generation: UInt64) -> Bool {
        guard event.kind == .leftDragged || event.kind == .mouseMoved,
              case let .input(previous, previousSource, previousGeneration, _) = last else { return false }
        return previousSource == source && previousGeneration == generation && previous.kind == event.kind
            && previous.gesture == event.gesture && previous.epoch == event.epoch
    }

    /// Called only while lock is held; dispatch does not execute synchronously.
    private func scheduleIfNeeded() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in self?.drain() }
    }

    private func drain() {
        let batch: [Entry] = lock.withLock {
            let result = entries
            entries.removeAll(keepingCapacity: true)
            scheduled = false
            return result
        }
        MainActor.assumeIsolated {
            for entry in batch {
                switch entry {
                case let .input(event, _, _, deliver): deliver(event)
                case .control(let action): action()
                }
            }
        }
    }
}
