import CoreGraphics
import Foundation

enum MouseButtonEdge: Sendable, Equatable { case down, released }

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
    let buttonEdge: MouseButtonEdge?

    init(kind: DragInputKind, location: CGPoint = .zero, flags: UInt64 = 0, button: Int64 = 0,
         timestamp: UInt64 = 0, sequence: UInt64 = 0, epoch: UInt64 = 0, gesture: UInt64 = 0, buttonMask: UInt64 = 0, firstDraggedTimestamp: UInt64? = nil, buttonEdge: MouseButtonEdge? = nil) {
        self.kind = kind; self.location = location; self.flags = flags; self.button = button
        self.timestamp = timestamp; self.sequence = sequence; self.epoch = epoch
        self.gesture = gesture; self.buttonMask = buttonMask; self.firstDraggedTimestamp = firstDraggedTimestamp
        self.buttonEdge = buttonEdge
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
                          button: Int64 = 0, timestamp: UInt64 = 0, buttonMask: UInt64 = 0,
                          buttonEdge: MouseButtonEdge? = nil) {
        guard !overflowed else { return }
        nextSequence &+= 1
        if kind == .leftDown { gesture &+= 1; firstDraggedTimestamp = nil }
        if kind == .leftDragged, firstDraggedTimestamp == nil { firstDraggedTimestamp = timestamp }
        let event = DragInputEvent(kind: kind, location: location, flags: flags, button: button,
                                   timestamp: timestamp, sequence: nextSequence, epoch: epoch, gesture: gesture, buttonMask: buttonMask, firstDraggedTimestamp: firstDraggedTimestamp,
                                   buttonEdge: buttonEdge)
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

struct DragPointerPath: Sendable {
    private struct Sample: Sendable {
        let timestamp: UInt64
        let point: CGPoint
    }

    private var samples: [Sample] = []
    private static let retention: UInt64 = 300_000_000
    private static let capacity = 128

    mutating func append(_ event: DragInputEvent) {
        samples.append(Sample(timestamp: event.timestamp, point: event.location))
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
    }

    func recent(now: UInt64) -> [CGPoint] {
        guard let latest = samples.last else { return [] }
        let end = max(now, latest.timestamp)
        let cutoff = end > Self.retention ? end - Self.retention : 0
        let points = samples.filter { $0.timestamp >= cutoff }.map(\.point)
        return points.isEmpty ? [latest.point] : points
    }

    static func closestDelta(to frameDelta: CGPoint, down: CGPoint, points: [CGPoint]) -> CGPoint {
        guard let first = points.first else { return .zero }
        var closest = CGPoint(x: first.x - down.x, y: first.y - down.y)
        var bestDistance = hypot(frameDelta.x - closest.x, frameDelta.y - closest.y)
        for (start, end) in zip(points, points.dropFirst()) {
            let startDelta = CGPoint(x: start.x - down.x, y: start.y - down.y)
            let travel = CGPoint(x: end.x - start.x, y: end.y - start.y)
            let lengthSquared = travel.x * travel.x + travel.y * travel.y
            let fraction = lengthSquared > 0
                ? min(1, max(0, ((frameDelta.x - startDelta.x) * travel.x + (frameDelta.y - startDelta.y) * travel.y) / lengthSquared))
                : 0
            let candidate = CGPoint(x: startDelta.x + fraction * travel.x, y: startDelta.y + fraction * travel.y)
            let distance = hypot(frameDelta.x - candidate.x, frameDelta.y - candidate.y)
            if distance < bestDistance { closest = candidate; bestDistance = distance }
        }
        return closest
    }
}
