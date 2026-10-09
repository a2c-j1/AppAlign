@preconcurrency import ApplicationServices
import CoreGraphics
import Dispatch
import Foundation

struct RuntimeWindowOwnership: Sendable {
    private(set) var keyboardRetained = false
    private(set) var dragLeases = Set<DragLeaseID>()
    private(set) var dragCommits = Set<DragCommitID>()

    var isOwned: Bool { keyboardRetained || !dragLeases.isEmpty || !dragCommits.isEmpty }

    mutating func retainKeyboard() { keyboardRetained = true }
    mutating func discardKeyboard() { keyboardRetained = false }
    mutating func retainDrag(_ lease: DragLeaseID) { dragLeases.insert(lease) }
    mutating func releaseDrag(_ lease: DragLeaseID) { dragLeases.remove(lease) }
    mutating func retainDragCommit(_ commit: DragCommitID) { dragCommits.insert(commit) }
    mutating func releaseDragCommit(_ commit: DragCommitID) { dragCommits.remove(commit) }
    mutating func handoffDrag(_ lease: DragLeaseID, to commit: DragCommitID) -> Bool {
        guard dragLeases.contains(lease) else { return false }
        dragCommits.insert(commit)
        dragLeases.remove(lease)
        return true
    }
}

enum TitleBarHitClassifier {
    private static let excludedRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXComboBox", "AXLink", "AXMenuButton", "AXPopUpButton",
        "AXRadioButton", "AXScrollArea", "AXScrollBar", "AXSlider", "AXSplitGroup", "AXSplitter",
        "AXTab", "AXTabGroup", "AXTable", "AXTextArea", "AXTextField", "AXWebArea"
    ]
    private static let positiveFallbackRoles: Set<String> = ["AXGroup", "AXToolbar", "AXWindow"]

    static func isCandidate(frame: CGRect, point: CGPoint, hitRole: String?, ancestorRoles: [String]) -> Bool {
        guard DisplayGeometry.isFinite(frame), frame.width > 12, frame.height > 12,
              point.x > frame.minX + 6, point.x < frame.maxX - 6,
              point.y > frame.minY + 6, point.y < frame.maxY - 6,
              point.y <= frame.minY + min(40, frame.height * 0.12),
              hitRole.map({ !excludedRoles.contains($0) }) ?? true,
              !ancestorRoles.contains(where: excludedRoles.contains) else { return false }
        if ancestorRoles.contains("AXTitleBar") { return true }
        guard let hitRole else { return false }
        return positiveFallbackRoles.contains(hitRole)
    }

    static func hitRegion(frame: CGRect, point: CGPoint, isCandidate: Bool) -> CGRect {
        guard isCandidate else { return .null }
        let topBand = CGRect(x: frame.minX, y: frame.minY, width: frame.width,
                             height: min(40, frame.height * 0.12))
        let aroundPoint = CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)
        return aroundPoint.intersection(frame).intersection(topBand)
    }
}

final class AccessibilitySerialExecutor: SerialExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "AppAlign.AccessibilityWindowRuntime")

    func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        queue.async { unownedJob.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}

struct AXRevisionSnapshot: Sendable {
    let revision: UInt64
    let lastChangedAt: UInt64
    let changeWasResize: Bool
    let destroyed: Bool
    let changes: [WindowRevisionChange]
}

enum WindowRevisionChangeKind: Sendable, Equatable {
    case moved
    case resized
    case destroyed
    case write
}

struct WindowRevisionChange: Sendable, Equatable {
    let revision: UInt64
    let timestamp: UInt64
    let kind: WindowRevisionChangeKind
}

final class AXRevisionTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    private var changedAt: UInt64 = 0
    private var lastResizeAt: UInt64 = 0
    private var isDestroyed = false
    private var changes: [WindowRevisionChange] = []

    func record(_ notification: String) {
        let kind: WindowRevisionChangeKind
        if notification == (kAXMovedNotification as String) || notification == (kAXWindowMovedNotification as String) {
            kind = .moved
        } else if notification == (kAXResizedNotification as String) || notification == (kAXWindowResizedNotification as String) {
            kind = .resized
        } else if notification == (kAXUIElementDestroyedNotification as String) {
            kind = .destroyed
        } else { return }
        record(kind, at: DispatchTime.now().uptimeNanoseconds)
    }

    func recordWrite(at timestamp: UInt64) {
        record(.write, at: timestamp)
    }

    private func record(_ kind: WindowRevisionChangeKind, at timestamp: UInt64) {
        lock.lock()
        value &+= 1
        changedAt = timestamp
        if kind == .resized { lastResizeAt = timestamp }
        isDestroyed = isDestroyed || kind == .destroyed
        changes.append(WindowRevisionChange(revision: value, timestamp: timestamp, kind: kind))
        if changes.count > 16 { changes.removeFirst(changes.count - 16) }
        lock.unlock()
    }

    func snapshot(since timestamp: UInt64) -> AXRevisionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return AXRevisionSnapshot(revision: value, lastChangedAt: changedAt,
                                  changeWasResize: lastResizeAt >= timestamp && lastResizeAt != 0,
                                  destroyed: isDestroyed, changes: changes)
    }
}

final class AXRevisionCallbackContext: @unchecked Sendable {
    let tracker: AXRevisionTracker
    private let lock = NSLock()
    private var active = true

    init(tracker: AXRevisionTracker) { self.tracker = tracker }

    func receive(_ notification: String) {
        lock.lock()
        if active { tracker.record(notification) }
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        active = false
        lock.unlock()
    }
}

final class AXObserverRegistration: @unchecked Sendable {
    let observer: AXObserver
    let source: CFRunLoopSource
    let element: AXUIElement
    let tracker: AXRevisionTracker
    let notificationsVerified: Bool
    private let registeredNotifications: [String]
    private let context: AXRevisionCallbackContext
    private let callbackContext: UnsafeMutableRawPointer
    private var invalidated = false

    init?(pid: pid_t, element: AXUIElement, tracker: AXRevisionTracker, deadline: UInt64) {
        var observer: AXObserver?
        guard AXObserverCreate(pid, axRevisionCallback, &observer) == .success,
              let observer else { return nil }
        self.observer = observer
        source = AXObserverGetRunLoopSource(observer)
        self.element = element
        self.tracker = tracker
        context = AXRevisionCallbackContext(tracker: tracker)
        callbackContext = Unmanaged.passRetained(context).toOpaque()

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        let moveNotification = Self.add(ObserverNotificationRequest(
            notification: kAXMovedNotification as String,
            fallback: kAXWindowMovedNotification as String,
            observer: observer, element: element, context: callbackContext, deadline: deadline
        ))
        let resizeNotification = Self.add(ObserverNotificationRequest(
            notification: kAXResizedNotification as String,
            fallback: kAXWindowResizedNotification as String,
            observer: observer, element: element, context: callbackContext, deadline: deadline
        ))
        let destroyNotification = Self.add(ObserverNotificationRequest(
            notification: kAXUIElementDestroyedNotification as String,
            fallback: nil, observer: observer, element: element, context: callbackContext, deadline: deadline
        ))
        registeredNotifications = [moveNotification, resizeNotification, destroyNotification].compactMap { $0 }
        notificationsVerified = moveNotification != nil && resizeNotification != nil && destroyNotification != nil
        if !notificationsVerified {
            for notification in registeredNotifications {
                _ = configureAXMessagingTimeout(element, timeout: 0.05)
                AXObserverRemoveNotification(observer, element, notification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    private static func add(_ request: ObserverNotificationRequest) -> String? {
        guard let timeout = remainingTimeout(request.deadline) else { return nil }
        guard configureAXMessagingTimeout(request.element, timeout: timeout) == .success else { return nil }
        var result = AXObserverAddNotification(request.observer, request.element,
                                               request.notification as CFString, request.context)
        if result == .success { return request.notification }
        guard result == .notificationUnsupported, let fallback = request.fallback,
              let fallbackTimeout = remainingTimeout(request.deadline),
              configureAXMessagingTimeout(request.element, timeout: fallbackTimeout) == .success else { return nil }
        result = AXObserverAddNotification(request.observer, request.element, fallback as CFString, request.context)
        return result == .success ? fallback : nil
    }

    private static func remainingTimeout(_ deadline: UInt64) -> Float? {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { return nil }
        return min(0.5, Float(deadline - now) / 1_000_000_000)
    }

    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        context.invalidate()
        for notification in registeredNotifications {
            _ = configureAXMessagingTimeout(element, timeout: 0.1)
            AXObserverRemoveNotification(observer, element, notification as CFString)
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        let releasingContext = context
        DispatchQueue.main.async {
            Unmanaged.passUnretained(releasingContext).release()
        }
    }
}

private struct ObserverNotificationRequest {
    let notification: String
    let fallback: String?
    let observer: AXObserver
    let element: AXUIElement
    let context: UnsafeMutableRawPointer
    let deadline: UInt64
}

private let axRevisionCallback: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon else { return }
    Unmanaged<AXRevisionCallbackContext>.fromOpaque(refcon).takeUnretainedValue().receive(notification as String)
}
