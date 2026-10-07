import AppKit
import ApplicationServices
import Combine
import Foundation

struct RuntimeWindowToken: Hashable, Sendable {
    let id: UUID
    let pid: pid_t
}

struct RuntimeWindowSnapshot: Sendable {
    let token: RuntimeWindowToken
    let frame: CGRect
}

struct DragLeaseID: Hashable, Sendable {
    let rawValue: UUID
}

struct DragWindowSnapshot: Sendable {
    let token: RuntimeWindowToken
    let lease: DragLeaseID
    let frame: CGRect
    let hitRole: String?
    let ancestorRoles: [String]
    let hitInTitleBar: Bool
    let capturedAt: UInt64
    let hitRegion: CGRect
    let revision: UInt64
    let lastChangedAt: UInt64
    let changeWasResize: Bool
    let notificationsVerified: Bool
    let revisionChanges: [WindowRevisionChange]
}

protocol DragWindowReading: Sendable {
    func window(at point: CGPoint, ownPID: pid_t, downTimestamp: UInt64) async throws -> DragWindowSnapshot
    func releaseDragLease(_ lease: DragLeaseID) async
    func isWriteInProgress() async -> Bool
    func frame(for token: RuntimeWindowToken, lease: DragLeaseID) async throws -> CGRect
}

protocol KeyboardWindowOperating: Sendable {
    func focusedWindow(applicationPID: pid_t, ownPID: pid_t) async throws -> RuntimeWindowSnapshot
    func retain(_ token: RuntimeWindowToken) async
    func move(_ token: RuntimeWindowToken, to frame: CGRect, preflight: @MainActor @Sendable () -> Bool) async throws -> CGRect
    func restore(_ token: RuntimeWindowToken, to frame: CGRect, preflight: @MainActor @Sendable () -> Bool) async throws -> CGRect
    func discard(_ token: RuntimeWindowToken) async
    func shutdown() async
    func discardProcess(_ pid: pid_t) async
}

extension KeyboardWindowOperating {
    func discardProcess(_ pid: pid_t) async {}
}

private enum KeyboardSnapError: LocalizedError {
    case readbackMismatch

    var errorDescription: String? { "The window manager did not confirm the requested frame." }
}

@MainActor
struct KeyboardEnvironment {
    let frontmostPID: @MainActor () -> pid_t?
    let isAccessibilityTrusted: @MainActor () -> Bool
    let ownPID: pid_t

    static var live: KeyboardEnvironment {
        KeyboardEnvironment(
            frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            isAccessibilityTrusted: { AXIsProcessTrusted() },
            ownPID: ProcessInfo.processInfo.processIdentifier
        )
    }
}

@MainActor
final class KeyboardSnapController: ObservableObject {
    private struct PlacementSession {
        let token: RuntimeWindowToken
        let originalFrame: CGRect
        var activeZoneID: ZoneID?
    }

    @Published private(set) var statusMessage = "Keyboard placement is disabled."
    @Published private(set) var isBusy = false
    @Published private(set) var hasRestoreTarget = false
    var didFinishAction: (@MainActor () -> Void)?

    private let layoutController: LayoutController
    private let backend: any KeyboardWindowOperating
    var backendForEligibility: any KeyboardWindowOperating { backend }
    private let environment: KeyboardEnvironment
    private var ownPID: pid_t { environment.ownPID }
    private var sessions: [UUID: PlacementSession] = [:]
    private let maximumSessions = 64
    private var lifecycleGeneration: UInt64 = 0
    private var isRunning = true
    private(set) var dragGateClosed = false

    init(
        layoutController: LayoutController,
        backend: any KeyboardWindowOperating = AccessibilityWindowRuntime(),
        environment: KeyboardEnvironment = .live
    ) {
        self.layoutController = layoutController
        self.backend = backend
        self.environment = environment
    }

    func handle(_ action: KeyboardSnapAction) {
        guard isRunning, !isBusy, !dragGateClosed else { return }
        isBusy = true
        let generation = lifecycleGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isBusy = false
                self.didFinishAction?()
            }
            await self.perform(action, generation: generation)
        }
    }

    func shutdown() async {
        lifecycleGeneration &+= 1
        isRunning = false
        sessions.removeAll()
        hasRestoreTarget = false
        await backend.shutdown()
    }

    func suspend() {
        lifecycleGeneration &+= 1
        isRunning = false
    }

    func resume() {
        lifecycleGeneration &+= 1
        isRunning = true
    }

    func invalidatePendingOperations() {
        lifecycleGeneration &+= 1
    }

    func setDragGateClosed(_ closed: Bool) {
        guard dragGateClosed != closed else { return }
        dragGateClosed = closed
        if closed { invalidatePendingOperations() }
    }

    func isEligible(_ action: KeyboardSnapAction, for focused: RuntimeWindowSnapshot, layout snapshot: KeyboardLayoutSnapshot?) -> Bool {
        if action == .restore { return sessions[focused.token.id] != nil }
        guard let snapshot else { return false }
        let session = sessions[focused.token.id]
        let currentID = ZoneNavigator.resolvedCurrentID(session?.activeZoneID, frame: focused.frame, zones: snapshot.zones)
        let request = ZoneNavigationRequest(
            mode: layoutController.keyboardSettings.mode,
            currentID: currentID,
            currentFrame: focused.frame,
            zones: snapshot.zones,
            workArea: snapshot.display.workArea,
            cycle: layoutController.keyboardSettings.cyclesAtEdges
        )
        guard let target = ZoneNavigator.zone(for: action, request: request) else { return false }
        guard target.id != currentID else { return false }
        return Self.centerDistance(target.frame, focused.frame) > 2
            || abs(target.frame.width - focused.frame.width) > 2
            || abs(target.frame.height - focused.frame.height) > 2
    }

    var frontmostPID: pid_t? { environment.frontmostPID() }
    var accessibilityIsTrusted: Bool { environment.isAccessibilityTrusted() }
    var processID: pid_t { environment.ownPID }

    private func perform(_ action: KeyboardSnapAction, generation: UInt64) async {
        guard isRunning, !dragGateClosed, lifecycleGeneration == generation else { return }
        guard layoutController.keyboardSettings.isEnabled else {
            statusMessage = "Keyboard placement is disabled."
            return
        }
        guard accessibilityIsTrusted else {
            statusMessage = WindowManagementError.accessibilityPermissionRequired.localizedDescription
            return
        }
        guard let pid = frontmostPID, pid != ownPID else {
            statusMessage = "Keep an eligible external window in front before using a keyboard shortcut."
            return
        }
        do {
            let focused = try await backend.focusedWindow(applicationPID: pid, ownPID: ownPID)
            guard isRunning, lifecycleGeneration == generation,
                  frontmostPID == pid, accessibilityIsTrusted,
                  layoutController.keyboardSettings.isEnabled else {
                await discardProbeIfUnowned(focused.token)
                statusMessage = "The front window changed. Try the shortcut again."
                return
            }
            if action == .restore {
                await restore(focused, generation: generation)
            } else {
                await place(action, focused: focused, generation: generation)
            }
        } catch {
            guard isRunning, lifecycleGeneration == generation else { return }
            statusMessage = error.localizedDescription
        }
    }

    private func place(_ action: KeyboardSnapAction, focused: RuntimeWindowSnapshot, generation: UInt64) async {
        guard let snapshot = layoutController.appliedLayoutSnapshot(for: focused.frame) else {
            statusMessage = "No applied layout is available for the window's display."
            return
        }
        var session = sessions[focused.token.id] ?? PlacementSession(
            token: focused.token,
            originalFrame: focused.frame,
            activeZoneID: nil
        )
        session.activeZoneID = ZoneNavigator.resolvedCurrentID(session.activeZoneID, frame: focused.frame, zones: snapshot.zones)
        let request = ZoneNavigationRequest(
            mode: layoutController.keyboardSettings.mode,
            currentID: session.activeZoneID,
            currentFrame: focused.frame,
            zones: snapshot.zones,
            workArea: snapshot.display.workArea,
            cycle: layoutController.keyboardSettings.cyclesAtEdges
        )
        guard let zone = ZoneNavigator.zone(for: action, request: request) else {
            statusMessage = action == .direction(.north) || action == .direction(.south)
                ? "Up and Down are unavailable in zone-order mode."
                : "There is no eligible zone in that direction."
            return
        }
        if zone.id == session.activeZoneID {
            statusMessage = "The window is already in zone \(zone.id.displayNumber)."
            return
        }
        guard layoutController.isCurrent(snapshot, for: focused.frame),
              frontmostPID == focused.token.pid else {
            statusMessage = "The window or applied layout changed. Try the shortcut again."
            return
        }

        if sessions[focused.token.id] == nil {
            guard sessions.count < maximumSessions else {
                statusMessage = "Restore sessions are full. Restore an earlier window before placing another."
                return
            }
            await backend.retain(focused.token)
            guard isRunning, lifecycleGeneration == generation else {
                await backend.discard(focused.token)
                return
            }
        }

        // Preserve the original frame before either position or size can partially succeed.
        sessions[focused.token.id] = session
        hasRestoreTarget = true
        do {
            let savedSettings = layoutController.keyboardSettings
            let preflight: @MainActor @Sendable () -> Bool = { [weak self] in
                guard let self, self.isRunning, !self.dragGateClosed, self.lifecycleGeneration == generation,
                      self.layoutController.keyboardSettings.isEnabled,
                      self.frontmostPID == focused.token.pid,
                      self.accessibilityIsTrusted,
                      self.layoutController.keyboardSettings == savedSettings else { return false }
                return self.layoutController.isCurrent(snapshot, for: focused.frame)
            }
            let actualFrame = try await backend.move(focused.token, to: zone.frame, preflight: preflight)
            guard Self.matches(actualFrame, zone.frame) else { throw KeyboardSnapError.readbackMismatch }
            guard isRunning, lifecycleGeneration == generation else {
                await discardProbeIfUnowned(focused.token)
                return
            }
            session.activeZoneID = zone.id
            sessions[focused.token.id] = session
            statusMessage = "Placed window in zone \(zone.id.displayNumber)."
        } catch {
            guard isRunning, lifecycleGeneration == generation else { return }
            statusMessage = "Placement failed; the original frame is saved for Restore. \(error.localizedDescription)"
        }
    }

    private func restore(_ focused: RuntimeWindowSnapshot, generation: UInt64) async {
        guard let session = sessions[focused.token.id] else {
            statusMessage = "There is no saved original frame for this focused window."
            return
        }
        guard frontmostPID == focused.token.pid else {
            statusMessage = "The front window changed. Try Restore again."
            return
        }
        do {
            let preflight: @MainActor @Sendable () -> Bool = { [weak self] in
                guard let self, self.isRunning, !self.dragGateClosed, self.lifecycleGeneration == generation,
                      self.layoutController.keyboardSettings.isEnabled else { return false }
                return self.frontmostPID == focused.token.pid && self.accessibilityIsTrusted
            }
            let actualFrame = try await backend.restore(session.token, to: session.originalFrame, preflight: preflight)
            guard Self.matches(actualFrame, session.originalFrame) else { throw KeyboardSnapError.readbackMismatch }
            guard isRunning, lifecycleGeneration == generation else { return }
            sessions.removeValue(forKey: focused.token.id)
            hasRestoreTarget = !sessions.isEmpty
            statusMessage = "Restored and verified the original window frame."
            await backend.discard(session.token)
        } catch {
            guard isRunning, lifecycleGeneration == generation else { return }
            sessions[focused.token.id] = session
            hasRestoreTarget = true
            statusMessage = "Restore failed; the original frame is still saved. \(error.localizedDescription)"
        }
    }

    private static func centerDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        hypot(lhs.midX - rhs.midX, lhs.midY - rhs.midY)
    }

    private static func matches(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        [lhs.minX - rhs.minX, lhs.minY - rhs.minY, lhs.width - rhs.width, lhs.height - rhs.height]
            .allSatisfy { $0.isFinite && abs($0) <= 2 }
    }

    func discardProcess(_ pid: pid_t) async {
        lifecycleGeneration &+= 1
        let removed = sessions.values.filter { $0.token.pid == pid }.map(\.token)
        sessions = sessions.filter { $0.value.token.pid != pid }
        hasRestoreTarget = !sessions.isEmpty
        for token in removed { await backend.discard(token) }
        await backend.discardProcess(pid)
    }

    func discardProbeIfUnowned(_ token: RuntimeWindowToken) async {
        guard !isBusy, sessions[token.id] == nil else { return }
        await backend.discard(token)
    }
}
