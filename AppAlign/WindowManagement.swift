import Combine
import AppKit
@preconcurrency import ApplicationServices
import Foundation
import Dispatch

func configureAXMessagingTimeout(_ element: AXUIElement, timeout: Float) -> AXError {
    AXUIElementSetMessagingTimeout(element, timeout)
}

struct AXWindow {
    let applicationElement: AXUIElement
    let element: AXUIElement
    let pid: pid_t
    let messagingTimeout: Float

    init(applicationElement: AXUIElement, element: AXUIElement, pid: pid_t, messagingTimeout: Float = 0.5) {
        self.applicationElement = applicationElement
        self.element = element
        self.pid = pid
        self.messagingTimeout = max(0.01, messagingTimeout)
    }

    func configureMessagingTimeout(_ timeout: Float) throws {
        let result = AXUIElementSetMessagingTimeout(applicationElement, timeout)
        guard result == .success else {
            throw WindowManagementError.writeFailed(attribute: "messaging timeout", code: result.rawValue)
        }
    }

    private func setElementTimeout() throws {
        let result = AXUIElementSetMessagingTimeout(element, messagingTimeout)
        guard result == .success else {
            throw WindowManagementError.readFailed(attribute: "messaging timeout", code: result.rawValue)
        }
    }

    func frame() throws -> CGRect {
        try setElementTimeout()
        let position = try pointAttribute(kAXPositionAttribute as CFString)
        let size = try sizeAttribute(kAXSizeAttribute as CFString)
        return CGRect(origin: position, size: size)
    }

    func stableFrame() throws -> CGRect {
        try setElementTimeout()
        let firstPosition = try pointAttribute(kAXPositionAttribute as CFString)
        let size = try sizeAttribute(kAXSizeAttribute as CFString)
        let finalPosition = try pointAttribute(kAXPositionAttribute as CFString)
        guard abs(firstPosition.x - finalPosition.x) <= 2, abs(firstPosition.y - finalPosition.y) <= 2 else {
            throw WindowManagementError.displayConfigurationChanged
        }
        return CGRect(origin: finalPosition, size: size)
    }

    func stringAttribute(_ attribute: CFString) throws -> String? {
        try setElementTimeout()
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)

        if result == .noValue || result == .attributeUnsupported {
            return nil
        }
        guard result == .success else {
            throw WindowManagementError.readFailed(
                attribute: attribute as String,
                code: result.rawValue
            )
        }
        return value as? String
    }

    func boolAttribute(_ attribute: CFString) throws -> Bool? {
        try setElementTimeout()
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)

        if result == .noValue || result == .attributeUnsupported {
            return nil
        }
        guard result == .success else {
            throw WindowManagementError.readFailed(
                attribute: attribute as String,
                code: result.rawValue
            )
        }
        return value as? Bool
    }

    func isAttributeSettable(_ attribute: CFString) throws -> Bool {
        try setElementTimeout()
        var settable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(element, attribute, &settable)
        guard result == .success else {
            throw WindowManagementError.readFailed(
                attribute: attribute as String,
                code: result.rawValue
            )
        }
        return settable.boolValue
    }

    func setPosition(_ point: CGPoint) throws {
        try setElementTimeout()
        var mutablePoint = point
        guard let value = AXValueCreate(.cgPoint, &mutablePoint) else {
            throw WindowManagementError.invalidAttribute(attribute: kAXPositionAttribute as String)
        }
        let result = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        guard result == .success else {
            throw WindowManagementError.writeFailed(
                attribute: kAXPositionAttribute as String,
                code: result.rawValue
            )
        }
    }

    func setSize(_ size: CGSize) throws {
        try setElementTimeout()
        var mutableSize = size
        guard let value = AXValueCreate(.cgSize, &mutableSize) else {
            throw WindowManagementError.invalidAttribute(attribute: kAXSizeAttribute as String)
        }
        let result = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        guard result == .success else {
            throw WindowManagementError.writeFailed(
                attribute: kAXSizeAttribute as String,
                code: result.rawValue
            )
        }
    }

    private func pointAttribute(_ attribute: CFString) throws -> CGPoint {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else {
            throw WindowManagementError.readFailed(
                attribute: attribute as String,
                code: result.rawValue
            )
        }
        guard
            let value,
            CFGetTypeID(value) == AXValueGetTypeID()
        else {
            throw WindowManagementError.invalidAttribute(attribute: attribute as String)
        }

        var point = CGPoint.zero
        // CoreFoundation type ID was checked immediately above.
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else {
            throw WindowManagementError.invalidAttribute(attribute: attribute as String)
        }
        return point
    }

    private func sizeAttribute(_ attribute: CFString) throws -> CGSize {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else {
            throw WindowManagementError.readFailed(
                attribute: attribute as String,
                code: result.rawValue
            )
        }
        guard
            let value,
            CFGetTypeID(value) == AXValueGetTypeID()
        else {
            throw WindowManagementError.invalidAttribute(attribute: attribute as String)
        }

        var size = CGSize.zero
        // CoreFoundation type ID was checked immediately above.
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else {
            throw WindowManagementError.invalidAttribute(attribute: attribute as String)
        }
        return size
    }
}

struct WindowRepository {
    let messagingTimeout: Float

    init(messagingTimeout: Float = 0.5) {
        self.messagingTimeout = messagingTimeout
    }

    func focusedWindow(applicationPID: pid_t) throws -> AXWindow {
        let applicationElement = AXUIElementCreateApplication(applicationPID)
        let timeoutResult = AXUIElementSetMessagingTimeout(applicationElement, messagingTimeout)
        guard timeoutResult == .success else {
            throw WindowManagementError.readFailed(
                attribute: "messaging timeout",
                code: timeoutResult.rawValue
            )
        }

        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            &value
        )
        guard result == .success else {
            throw WindowManagementError.noFocusedWindow(code: result.rawValue)
        }
        guard
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            throw WindowManagementError.invalidFocusedWindow
        }

        // CoreFoundation type ID was checked immediately above.
        // swiftlint:disable:next force_cast
        let element = value as! AXUIElement
        let windowTimeout = AXUIElementSetMessagingTimeout(element, messagingTimeout)
        guard windowTimeout == .success else {
            throw WindowManagementError.readFailed(attribute: "messaging timeout", code: windowTimeout.rawValue)
        }
        var pid = applicationPID
        let pidResult = AXUIElementGetPid(element, &pid)
        guard pidResult == .success else {
            throw WindowManagementError.readFailed(
                attribute: "window pid",
                code: pidResult.rawValue
            )
        }

        return AXWindow(
            applicationElement: applicationElement,
            element: element,
            pid: pid
        )
    }
}

private struct AXHitResult {
    let pid: pid_t
    let applicationElement: AXUIElement
    let windowElement: AXUIElement
    let hitRole: String?
    let ancestorRoles: [String]
}

actor AccessibilityWindowRuntime: KeyboardWindowOperating {
    nonisolated let executor = AccessibilitySerialExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private struct Record {
        let window: AXWindow
        var ownership = RuntimeWindowOwnership()
        var revisionTracker = AXRevisionTracker()
        var observerRegistration: AXObserverRegistration?
    }

    private var records: [UUID: Record] = [:]
    private var writeInProgress = false
    private var lastWriteEndNanoseconds: UInt64 = 0
    private let repository = WindowRepository(messagingTimeout: 0.5)
    private let mover = WindowMover(messagingTimeout: 0.5, retryLimit: 1)
}

extension AccessibilityWindowRuntime {
    func discardProcess(_ pid: pid_t) async {
        let removedRecords = records.values.filter { $0.window.pid == pid }
        records = records.filter { $0.value.window.pid != pid }
        for registration in removedRecords.compactMap(\.observerRegistration) {
            registration.invalidate()
        }
    }

    func focusedWindow(applicationPID: pid_t, ownPID: pid_t) async throws -> RuntimeWindowSnapshot {
        guard applicationPID != ownPID else {
            throw WindowManagementError.excludedWindow(reason: "AppAlign cannot move its own windows")
        }
        let focused = try repository.focusedWindow(applicationPID: applicationPID)
        try WindowFilter(ownPID: ownPID).validate(focused)
        let frame = try focused.frame()
        guard Self.isFinite(frame), frame.width > 0, frame.height > 0 else {
            throw WindowManagementError.invalidFocusedWindow
        }

        if let match = records.first(where: { $0.value.window.pid == focused.pid && CFEqual($0.value.window.element, focused.element) }) {
            return RuntimeWindowSnapshot(token: RuntimeWindowToken(id: match.key, pid: focused.pid), frame: frame)
        }
        if records.count >= 128,
           let oldest = records.keys.first(where: { !Self.isOwned(records[$0]) }) {
            records.removeValue(forKey: oldest)
        }
        guard records.count < 128 else { throw WindowManagementError.invalidFocusedWindow }
        let id = UUID()
        records[id] = Record(window: focused)
        return RuntimeWindowSnapshot(token: RuntimeWindowToken(id: id, pid: focused.pid), frame: frame)
    }

    func retain(_ token: RuntimeWindowToken) async {
        guard var record = records[token.id], record.window.pid == token.pid else { return }
        record.ownership.retainKeyboard()
        records[token.id] = record
    }

    func move(
        _ token: RuntimeWindowToken,
        to frame: CGRect,
        preflight: @MainActor @Sendable () -> Bool
    ) async throws -> CGRect {
        try await withCurrentFocusedWindow(token, preflight: preflight) { window in try mover.move(window, to: frame).actualFrame }
    }

    func restore(
        _ token: RuntimeWindowToken,
        to frame: CGRect,
        preflight: @MainActor @Sendable () -> Bool
    ) async throws -> CGRect {
        try await withCurrentFocusedWindow(token, preflight: preflight) { window in try mover.move(window, to: frame).actualFrame }
    }

    func discard(_ token: RuntimeWindowToken) async {
        guard var record = records[token.id], record.window.pid == token.pid else { return }
        record.ownership.discardKeyboard()
        if !record.ownership.isOwned { records.removeValue(forKey: token.id) } else { records[token.id] = record }
    }

    func shutdown() async {
        let registrations = records.values.compactMap(\.observerRegistration)
        records.removeAll()
        for registration in registrations {
            registration.invalidate()
        }
    }

    func isWriteInProgress() async -> Bool { writeInProgress }

    func window(at point: CGPoint, ownPID: pid_t, downTimestamp: UInt64) async throws -> DragWindowSnapshot {
        guard downTimestamp > lastWriteEndNanoseconds else { throw WindowManagementError.displayConfigurationChanged }
        guard AXIsProcessTrusted() else { throw WindowManagementError.accessibilityPermissionRequired }
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        let hit = try hitTest(point, ownPID: ownPID, deadline: deadline)
        let windowTimeout = try Self.remainingTimeout(before: deadline) / 8
        let window = AXWindow(applicationElement: hit.applicationElement, element: hit.windowElement, pid: hit.pid,
                              messagingTimeout: max(0.01, windowTimeout))
        try WindowFilter(ownPID: ownPID).validate(window)
        let frame = try window.stableFrame()
        let capturedAt = DispatchTime.now().uptimeNanoseconds
        guard Self.isFinite(frame), frame.width > 0, frame.height > 0 else { throw WindowManagementError.invalidFocusedWindow }
        let titleBarCandidate = TitleBarHitClassifier.isCandidate(frame: frame, point: point,
                                                                   hitRole: hit.hitRole, ancestorRoles: hit.ancestorRoles)
        let token = try token(for: window)
        let lease = DragLeaseID(rawValue: UUID())
        guard var record = records[token.id] else { throw WindowManagementError.noCapturedWindow }
        record.ownership.retainDrag(lease)
        let tracker = record.revisionTracker
        let hadObserverRegistration = record.observerRegistration != nil
        if record.observerRegistration == nil {
            record.observerRegistration = AXObserverRegistration(pid: hit.pid, element: window.element,
                                                                 tracker: tracker, deadline: deadline)
        }
        if DispatchTime.now().uptimeNanoseconds >= deadline {
            if !hadObserverRegistration {
                record.observerRegistration?.invalidate()
                record.observerRegistration = nil
            }
            record.ownership.releaseDrag(lease)
            records[token.id] = record
            if !Self.isOwned(record) { records.removeValue(forKey: token.id) }
            throw WindowManagementError.operationFailed
        }
        let notificationsVerified = record.observerRegistration?.notificationsVerified ?? false
        records[token.id] = record
        let revision = tracker.snapshot(since: downTimestamp)
        guard !revision.destroyed else {
            record.observerRegistration?.invalidate()
            records.removeValue(forKey: token.id)
            throw WindowManagementError.noCapturedWindow
        }
        let hitRegion = TitleBarHitClassifier.hitRegion(frame: frame, point: point, isCandidate: titleBarCandidate)
        return DragWindowSnapshot(
            token: token,
            lease: lease,
            frame: frame,
            hitRole: hit.hitRole,
            ancestorRoles: hit.ancestorRoles,
            hitInTitleBar: titleBarCandidate,
            capturedAt: capturedAt,
            hitRegion: hitRegion,
            revision: revision.revision,
            lastChangedAt: revision.lastChangedAt,
            changeWasResize: revision.changeWasResize,
            notificationsVerified: notificationsVerified,
            revisionChanges: revision.changes
        )
    }

    private func hitTest(_ point: CGPoint, ownPID: pid_t, deadline: UInt64) throws -> AXHitResult {
        let system = AXUIElementCreateSystemWide()
        try Self.configure(system, before: deadline)
        var hitValue: AXUIElement?
        let hitResult = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hitValue)
        guard hitResult == .success, let hit = hitValue else {
            throw WindowManagementError.readFailed(attribute: "hit-test", code: hitResult.rawValue)
        }
        try Self.configure(hit, before: deadline)
        var pid = pid_t.zero
        guard AXUIElementGetPid(hit, &pid) == .success, pid != ownPID else {
            throw WindowManagementError.excludedWindow(reason: "the pointer is not over an external application")
        }
        let applicationElement = AXUIElementCreateApplication(pid)
        try Self.configure(applicationElement, before: deadline)
        var current: AXUIElement? = hit
        var roles: [String] = []
        var visited: [AXUIElement] = []
        let associatedTimeout = try Self.remainingTimeout(before: deadline)
        var windowElement: AXUIElement? = try Self.associatedWindow(for: hit, timeout: associatedTimeout)
        for _ in 0 ..< 24 {
            guard let element = current else { break }
            guard !visited.contains(where: { CFEqual($0, element) }) else { break }
            visited.append(element)
            let roleTimeout = try Self.remainingTimeout(before: deadline)
            let role = try Self.stringAttribute(kAXRoleAttribute as CFString, from: element, timeout: roleTimeout)
            if let role {
                roles.append(role)
                if role == "AXWindow" { windowElement = windowElement ?? element; break }
            }
            var parentValue: CFTypeRef?
            try Self.configure(element, before: deadline)
            let parentResult = AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentValue)
            if parentResult == .noValue || parentResult == .attributeUnsupported { break }
            guard parentResult == .success, let parentValue, CFGetTypeID(parentValue) == AXUIElementGetTypeID() else {
                throw WindowManagementError.readFailed(attribute: kAXParentAttribute as String, code: parentResult.rawValue)
            }
            // The type id is checked directly above.
            // swiftlint:disable:next force_cast
            current = parentValue as! AXUIElement
        }
        guard let windowElement else { throw WindowManagementError.invalidFocusedWindow }
        let hitRoleTimeout = try Self.remainingTimeout(before: deadline)
        let hitRole = try Self.stringAttribute(kAXRoleAttribute as CFString, from: hit, timeout: hitRoleTimeout)
        return AXHitResult(pid: pid, applicationElement: applicationElement, windowElement: windowElement,
                           hitRole: hitRole, ancestorRoles: roles)
    }

    func releaseDragLease(_ lease: DragLeaseID) async {
        guard let id = records.first(where: { $0.value.ownership.dragLeases.contains(lease) })?.key,
              var record = records[id] else { return }
        record.ownership.releaseDrag(lease)
        if record.ownership.dragLeases.isEmpty, let registration = record.observerRegistration {
            record.observerRegistration = nil
            records[id] = record
            registration.invalidate()
            guard let refreshed = records[id] else { return }
            if !Self.isOwned(refreshed) { records.removeValue(forKey: id) }
        } else if !Self.isOwned(record) { records.removeValue(forKey: id) } else { records[id] = record }
    }

    func frame(for token: RuntimeWindowToken, lease: DragLeaseID) async throws -> CGRect {
        guard AXIsProcessTrusted(), let record = records[token.id], record.window.pid == token.pid,
              record.ownership.dragLeases.contains(lease) else {
            throw WindowManagementError.noCapturedWindow
        }
        if record.revisionTracker.snapshot(since: 0).destroyed {
            record.observerRegistration?.invalidate()
            records.removeValue(forKey: token.id)
            throw WindowManagementError.noCapturedWindow
        }
        do {
            let frame = try record.window.stableFrame()
            guard Self.isFinite(frame), frame.width > 0, frame.height > 0 else {
                throw WindowManagementError.invalidFocusedWindow
            }
            return frame
        } catch {
            record.observerRegistration?.invalidate()
            records.removeValue(forKey: token.id)
            throw error
        }
    }

    private func withCurrentFocusedWindow<T>(
        _ token: RuntimeWindowToken,
        preflight: @MainActor @Sendable () -> Bool,
        operation: (AXWindow) throws -> T
    ) async throws -> T {
        guard let record = records[token.id], record.window.pid == token.pid else { throw WindowManagementError.noCapturedWindow }
        if record.revisionTracker.snapshot(since: 0).destroyed {
            record.observerRegistration?.invalidate()
            records.removeValue(forKey: token.id)
            throw WindowManagementError.noCapturedWindow
        }
        do {
            let focusedBeforePreflight = try repository.focusedWindow(applicationPID: token.pid)
            guard CFEqual(record.window.element, focusedBeforePreflight.element) else {
                throw WindowManagementError.noFocusedWindow(code: -1)
            }
            try WindowFilter(ownPID: ProcessInfo.processInfo.processIdentifier).validate(focusedBeforePreflight)
            guard await preflight() else { throw WindowManagementError.displayConfigurationChanged }
            let focused = try repository.focusedWindow(applicationPID: token.pid)
            guard CFEqual(record.window.element, focused.element) else {
                throw WindowManagementError.noFocusedWindow(code: -1)
            }
            try WindowFilter(ownPID: ProcessInfo.processInfo.processIdentifier).validate(focused)
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == token.pid,
                  AXIsProcessTrusted() else {
                throw WindowManagementError.displayConfigurationChanged
            }
            writeInProgress = true
            defer { writeInProgress = false }
            defer {
                let timestamp = DispatchTime.now().uptimeNanoseconds
                record.revisionTracker.recordWrite(at: timestamp)
                lastWriteEndNanoseconds = timestamp
            }
            return try operation(focused)
        } catch {
            if error is WindowManagementError { throw error }
            records.removeValue(forKey: token.id)
            throw error
        }
    }

    private static func isFinite(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite
    }

    private func token(for window: AXWindow) throws -> RuntimeWindowToken {
        if let match = records.first(where: { $0.value.window.pid == window.pid && CFEqual($0.value.window.element, window.element) }) {
            return RuntimeWindowToken(id: match.key, pid: window.pid)
        }
        if records.count >= 128,
           let oldest = records.keys.first(where: { !Self.isOwned(records[$0]) }) {
            records.removeValue(forKey: oldest)
        }
        guard records.count < 128 else { throw WindowManagementError.invalidFocusedWindow }
        let id = UUID()
        records[id] = Record(window: window)
        return RuntimeWindowToken(id: id, pid: window.pid)
    }

    private static func isOwned(_ record: Record?) -> Bool {
        record?.ownership.isOwned ?? false
    }

    private static func stringAttribute(_ attribute: CFString, from element: AXUIElement, timeout: Float = 0.5) throws -> String? {
        let timeout = AXUIElementSetMessagingTimeout(element, timeout)
        guard timeout == .success else { throw WindowManagementError.readFailed(attribute: "messaging timeout", code: timeout.rawValue) }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        if result == .noValue || result == .attributeUnsupported { return nil }
        guard result == .success else { throw WindowManagementError.readFailed(attribute: attribute as String, code: result.rawValue) }
        return value as? String
    }

    private static func associatedWindow(for element: AXUIElement, timeout: Float) throws -> AXUIElement? {
        let timeoutResult = AXUIElementSetMessagingTimeout(element, timeout)
        guard timeoutResult == .success else {
            throw WindowManagementError.readFailed(attribute: "messaging timeout", code: timeoutResult.rawValue)
        }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &value)
        if result == .noValue || result == .attributeUnsupported { return nil }
        guard result == .success else {
            throw WindowManagementError.readFailed(attribute: kAXWindowAttribute as String, code: result.rawValue)
        }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw WindowManagementError.invalidAttribute(attribute: kAXWindowAttribute as String)
        }
        // The type id is checked directly above.
        // swiftlint:disable:next force_cast
        return value as! AXUIElement
    }

    private static func remainingTimeout(before deadline: UInt64) throws -> Float {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { throw WindowManagementError.operationFailed }
        return Float(deadline - now) / 1_000_000_000
    }

    private static func configure(_ element: AXUIElement, before deadline: UInt64) throws {
        let timeout = AXUIElementSetMessagingTimeout(element, min(0.5, try remainingTimeout(before: deadline)))
        guard timeout == .success else {
            throw WindowManagementError.readFailed(attribute: "messaging timeout", code: timeout.rawValue)
        }
    }
}

extension AccessibilityWindowRuntime: DragWindowReading {}
