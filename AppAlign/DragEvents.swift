import CoreGraphics
import Foundation

enum DragInputKind: Sendable, Equatable {
    case mouseMoved, leftDown, leftDragged, leftUp, flagsChanged, buttonChanged, escape, tapDisabled, overflow
}

struct DragInputEvent: Sendable, Equatable {
    let kind: DragInputKind
    let location: CGPoint
    let flags: UInt64
    let button: Int64
    let timestamp: UInt64
    let sequence: UInt64
    let epoch: UInt64
    let gesture: UInt64
    let buttonMask: UInt64
    let firstDraggedTimestamp: UInt64?

    init(kind: DragInputKind, location: CGPoint = .zero, flags: UInt64 = 0, button: Int64 = 0,
         timestamp: UInt64 = 0, sequence: UInt64 = 0, epoch: UInt64 = 0, gesture: UInt64 = 0, buttonMask: UInt64 = 0, firstDraggedTimestamp: UInt64? = nil) {
        self.kind = kind; self.location = location; self.flags = flags; self.button = button
        self.timestamp = timestamp; self.sequence = sequence; self.epoch = epoch
        self.gesture = gesture; self.buttonMask = buttonMask; self.firstDraggedTimestamp = firstDraggedTimestamp
    }
}

enum DragMonitorStatus: Sendable, Equatable {
    case ready
    case failed(String)
    case interrupted(String)
}

@MainActor
protocol DragInputMonitoring: AnyObject {
    func start(onEvent: @escaping @MainActor @Sendable (DragInputEvent) -> Void,
               onStatus: @escaping @MainActor @Sendable (DragMonitorStatus) -> Void)
    func stop()
}

struct DragMailbox: Sendable {
    private(set) var events: [DragInputEvent] = []
    private(set) var epoch: UInt64 = 0
    private(set) var overflowed = false
    private var nextSequence: UInt64 = 0
    private var gesture: UInt64 = 0
    private var firstDraggedTimestamp: UInt64?
    private let capacity: Int

    init(capacity: Int = 256) { self.capacity = max(1, capacity) }

    mutating func enqueue(kind: DragInputKind, location: CGPoint = .zero, flags: UInt64 = 0,
                          button: Int64 = 0, timestamp: UInt64 = 0, buttonMask: UInt64 = 0) {
        guard !overflowed else { return }
        nextSequence &+= 1
        if kind == .leftDown { gesture &+= 1; firstDraggedTimestamp = nil }
        if kind == .leftDragged, firstDraggedTimestamp == nil { firstDraggedTimestamp = timestamp }
        let event = DragInputEvent(kind: kind, location: location, flags: flags, button: button,
                                   timestamp: timestamp, sequence: nextSequence, epoch: epoch, gesture: gesture, buttonMask: buttonMask, firstDraggedTimestamp: firstDraggedTimestamp)
        if kind == .leftDragged || kind == .mouseMoved, events.last?.kind == kind, events.last?.gesture == gesture {
            events[events.count - 1] = event
        } else if events.count < capacity {
            events.append(event)
        } else {
            overflowed = true
            epoch &+= 1
            events.append(DragInputEvent(kind: .overflow, location: location, timestamp: timestamp,
                                         sequence: nextSequence, epoch: epoch, gesture: gesture, buttonMask: buttonMask))
        }
    }

    mutating func drain() -> [DragInputEvent] {
        defer { events.removeAll(keepingCapacity: true) }
        return events
    }
}

enum DragLifecycleKind: String, Sendable, Equatable { case began, updated, ended, cancelled }

struct DragLifecycleEvent: Sendable, Equatable {
    let kind: DragLifecycleKind
    let session: UInt64
    let frame: CGRect?
    let reason: String?
    var token: RuntimeWindowToken?
    var point: CGPoint = .zero
    var flags: UInt64 = 0
    var buttonMask: UInt64 = 0
    var displayFingerprint: String = ""
}

struct DragStateMachine: Sendable {
    enum State: Sendable, Equatable {
        case idle
        case candidate(session: UInt64, down: CGPoint, original: CGRect, epoch: UInt64)
        case moving(session: UInt64, down: CGPoint, original: CGRect, epoch: UInt64)
        case committing, cancelled
    }
    private(set) var state: State = .idle
    private var confirmingSamples = 0

    mutating func down(session: UInt64, point: CGPoint, frame: CGRect, titleBarHit: Bool, epoch: UInt64) -> [DragLifecycleEvent] {
        let previous = cancel(reason: "A new mouse-down replaced the prior gesture.")
        guard titleBarHit else { return previous }
        confirmingSamples = 0
        state = .candidate(session: session, down: point, original: frame, epoch: epoch)
        return previous
    }

    mutating func observe(session: UInt64, point: CGPoint, frame: CGRect, epoch: UInt64) -> [DragLifecycleEvent] {
        let original: CGRect
        let down: CGPoint
        let moving: Bool
        switch state {
        case let .candidate(active, start, initial, generation) where active == session && generation == epoch:
            original = initial; down = start; moving = false
        case let .moving(active, start, initial, generation) where active == session && generation == epoch:
            original = initial; down = start; moving = true
        default: return []
        }
        guard DisplayGeometry.isFinite(frame), frame.width > 0, frame.height > 0 else { return cancel(reason: "The window frame is invalid.") }
        guard abs(frame.width - original.width) <= 2, abs(frame.height - original.height) <= 2 else {
            return cancel(reason: "The gesture resized the window.")
        }
        let pointerDelta = CGPoint(x: point.x - down.x, y: point.y - down.y)
        let frameDelta = CGPoint(x: frame.minX - original.minX, y: frame.minY - original.minY)
        guard hypot(frameDelta.x - pointerDelta.x, frameDelta.y - pointerDelta.y) <= 8 else {
            confirmingSamples = 0
            return moving ? cancel(reason: "The window no longer follows the pointer.") : []
        }
        guard hypot(frameDelta.x, frameDelta.y) >= 3, hypot(pointerDelta.x, pointerDelta.y) >= 3 else { return [] }
        if !moving {
            confirmingSamples += 1
            guard confirmingSamples >= 2 else { return [] }
            state = .moving(session: session, down: down, original: original, epoch: epoch)
            return [DragLifecycleEvent(kind: .began, session: session, frame: original, reason: nil),
                    DragLifecycleEvent(kind: .updated, session: session, frame: frame, reason: nil)]
        }
        return [DragLifecycleEvent(kind: .updated, session: session, frame: frame, reason: nil)]
    }

    mutating func modifierUpdate(session: UInt64, frame: CGRect?) -> [DragLifecycleEvent] {
        guard case let .moving(active, _, _, _) = state, active == session else { return [] }
        return [DragLifecycleEvent(kind: .updated, session: session, frame: frame, reason: nil)]
    }

    mutating func finish(reason: String? = nil) -> [DragLifecycleEvent] {
        let session: UInt64
        let moved: Bool
        switch state {
        case let .candidate(active, _, _, _): session = active; moved = false
        case let .moving(active, _, _, _): session = active; moved = true
        default: return []
        }
        state = moved && reason == nil ? .committing : .cancelled
        defer { state = .idle; confirmingSamples = 0 }
        return [DragLifecycleEvent(kind: moved && reason == nil ? .ended : .cancelled, session: session, frame: nil,
                                   reason: reason ?? (moved ? nil : "The gesture did not become a window move."))]
    }

    mutating func cancel(reason: String) -> [DragLifecycleEvent] { finish(reason: reason) }
}
