import AppKit
@preconcurrency import ApplicationServices
import Foundation

extension AccessibilityWindowRuntime {
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
