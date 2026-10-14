import AppKit
@preconcurrency import ApplicationServices
import Foundation

extension AccessibilityWindowRuntime {
    func discardProcess(_ pid: pid_t) async {
        let removedRecords = records.values.filter { $0.window.pid == pid }
        records = records.filter { $0.value.window.pid != pid }
        for registration in removedRecords.compactMap(\.observerRegistration) { registration.invalidate() }
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
        if let match = records.first(where: {
            $0.value.window.pid == focused.pid && CFEqual($0.value.window.element, focused.element)
        }) {
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

    func move(_ token: RuntimeWindowToken, to frame: CGRect, ticket: PlacementCommitTicket,
              preflight: @MainActor @Sendable () -> Bool) async throws -> CGRect {
        let actualFrame = try await withCurrentFocusedWindow(token, ticket: ticket, preflight: preflight) { window in
            try mover.movePlacement(window, to: frame, ticket: ticket).actualFrame
        }
        try ensureKeyboardOwnership(token)
        return actualFrame
    }

    func restore(_ token: RuntimeWindowToken, to frame: CGRect, ticket: PlacementCommitTicket,
                 preflight: @MainActor @Sendable () -> Bool) async throws -> CGRect {
        let actualFrame = try await withCurrentFocusedWindow(token, ticket: ticket, preflight: preflight) { window in
            try mover.movePlacement(window, to: frame, ticket: ticket).actualFrame
        }
        try ensureKeyboardOwnership(token)
        return actualFrame
    }

    func discard(_ token: RuntimeWindowToken) async {
        guard var record = records[token.id], record.window.pid == token.pid else { return }
        record.ownership.discardKeyboard()
        if !record.ownership.isOwned { records.removeValue(forKey: token.id) } else { records[token.id] = record }
    }

    func shutdown() async {
        let registrations = records.values.compactMap(\.observerRegistration)
        records.removeAll()
        for registration in registrations { registration.invalidate() }
    }

    func isWriteInProgress() async -> Bool { writeInProgress }

    static func remainingTimeout(before deadline: UInt64) throws -> Float {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { throw WindowManagementError.operationFailed }
        return Float(deadline - now) / 1_000_000_000
    }

    func releaseOwnership(id: UUID, update: (inout RuntimeWindowOwnership) -> Void) {
        guard var record = records[id] else { return }
        update(&record.ownership)
        if record.ownership.dragLeases.isEmpty, record.ownership.dragCommits.isEmpty,
           let registration = record.observerRegistration {
            record.observerRegistration = nil
            records[id] = record
            registration.invalidate()
            if let latest = records[id], !Self.isOwned(latest) { records.removeValue(forKey: id) }
        } else if !Self.isOwned(record) { records.removeValue(forKey: id) } else { records[id] = record }
    }

    static func dragWindow(_ window: AXWindow, before deadline: UInt64) throws -> AXWindow {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { throw WindowManagementError.operationFailed }
        let remaining = Float(deadline - now) / 1_000_000_000
        guard remaining > 0.01 else { throw WindowManagementError.operationFailed }
        return AXWindow(applicationElement: window.applicationElement, element: window.element,
                        pid: window.pid, messagingTimeout: min(0.5, remaining), operationDeadline: deadline)
    }

    func withCurrentFocusedWindow<T>(
        _ token: RuntimeWindowToken,
        ticket: PlacementCommitTicket,
        preflight: @MainActor @Sendable () -> Bool,
        operation: (AXWindow) throws -> T
    ) async throws -> T {
        guard let initialRecord = records[token.id], initialRecord.window.pid == token.pid,
              initialRecord.ownership.keyboardRetained else { throw WindowManagementError.noCapturedWindow }
        if initialRecord.revisionTracker.snapshot(since: 0).destroyed {
            initialRecord.observerRegistration?.invalidate()
            records.removeValue(forKey: token.id)
            throw WindowManagementError.noCapturedWindow
        }
        do {
            let focusedBeforePreflight = try focusedWindowProvider(token.pid)
            guard CFEqual(initialRecord.window.element, focusedBeforePreflight.element) else {
                throw WindowManagementError.noFocusedWindow(code: -1)
            }
            try focusedWindowValidator(focusedBeforePreflight)
            guard await preflight() else { throw WindowManagementError.displayConfigurationChanged }
            let focused = try focusedWindowProvider(token.pid)
            guard CFEqual(initialRecord.window.element, focused.element) else {
                throw WindowManagementError.noFocusedWindow(code: -1)
            }
            try focusedWindowValidator(focused)
            guard frontmostPIDProvider() == token.pid,
                  accessibilityTrustedProvider() else {
                throw WindowManagementError.displayConfigurationChanged
            }
            // `preflight` suspends this actor. Discard, shutdown, or record replacement
            // may have run while it was suspended, so reacquire ownership immediately
            // before the atomic ticket boundary and AX setters.
            guard let record = records[token.id], record.window.pid == token.pid,
                  CFEqual(record.window.element, focused.element),
                  record.ownership.keyboardRetained,
                  !record.revisionTracker.snapshot(since: 0).destroyed else {
                throw WindowManagementError.noCapturedWindow
            }
            guard ticket.beginWrite(now: DispatchTime.now().uptimeNanoseconds) else {
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

    private func ensureKeyboardOwnership(_ token: RuntimeWindowToken) throws {
        guard let record = records[token.id], record.window.pid == token.pid,
              record.ownership.keyboardRetained,
              !record.revisionTracker.snapshot(since: 0).destroyed else {
            throw WindowManagementError.noCapturedWindow
        }
    }

    static func isFinite(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite
    }

    func token(for window: AXWindow) throws -> RuntimeWindowToken {
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

    static func isOwned(_ record: Record?) -> Bool {
        record?.ownership.isOwned ?? false
    }
}
