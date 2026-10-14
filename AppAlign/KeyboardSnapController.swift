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
    func move(_ token: RuntimeWindowToken, to frame: CGRect, ticket: PlacementCommitTicket,
              preflight: @MainActor @Sendable () -> Bool) async throws -> CGRect
    func restore(_ token: RuntimeWindowToken, to frame: CGRect, ticket: PlacementCommitTicket,
                 preflight: @MainActor @Sendable () -> Bool) async throws -> CGRect
    func discard(_ token: RuntimeWindowToken) async
    func shutdown() async
    func discardProcess(_ pid: pid_t) async
}

extension KeyboardWindowOperating {
    func discardProcess(_ pid: pid_t) async {}
}

enum KeyboardSnapError: LocalizedError {
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

struct KeyboardPlacementSession {
    let token: RuntimeWindowToken
    let originalFrame: CGRect
    let restoreAnchor: KeyboardRestoreAnchor
    var activeAddress: ZoneAddress?
    var extensionAnchor: ZoneAddress?
    var extensionEndpoint: ZoneAddress?
    var extensionLayoutID: UUID?
    var extensionWorkArea: WorkAreaKey?
    var extensionPlacementRevision: PlacementRevision?
    var extensionLastFrame: CGRect?
    var extendedAddresses: [ZoneAddress] = []
}

struct KeyboardRestoreAnchor {
    let displayID: DisplaySelectionID
    let displayFrame: CGRect
    let configurationFingerprint: String
}

struct KeyboardNavigationTarget {
    let session: KeyboardPlacementSession
    let address: ZoneAddress
    let zone: Zone
}

@MainActor
final class KeyboardSnapController: ObservableObject {
    @Published var statusMessage = "Keyboard placement is disabled."
    @Published private(set) var isBusy = false
    @Published var hasRestoreTarget = false
    var didFinishAction: (@MainActor () -> Void)?

    let layoutController: LayoutController
    let validity: PlacementValidity
    let backend: any KeyboardWindowOperating
    var backendForEligibility: any KeyboardWindowOperating { backend }
    let environment: KeyboardEnvironment
    var ownPID: pid_t { environment.ownPID }
    var sessions: [UUID: KeyboardPlacementSession] = [:]
    private var activeTicket: PlacementCommitTicket?
    private var activeTicketToken: RuntimeWindowToken?
    let maximumSessions = 64
    var lifecycleGeneration: UInt64 = 0
    var extensionHistoryGeneration: UInt64 = 0
    var extensionFlagsAvailable = false
    var previousModifierFlags: UInt64?
    var isRunning = true
    private(set) var dragGateClosed = false

    init(
        layoutController: LayoutController,
        backend: any KeyboardWindowOperating = AccessibilityWindowRuntime(),
        environment: KeyboardEnvironment = .live
    ) {
        self.layoutController = layoutController
        validity = layoutController.placementValidity
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
        invalidatePendingOperations()
        setExtensionFlagsAvailable(false)
        isRunning = false
        sessions.removeAll()
        hasRestoreTarget = false
        await backend.shutdown()
    }

    func suspend() {
        invalidatePendingOperations()
        setExtensionFlagsAvailable(false)
        isRunning = false
    }

    func resume() {
        lifecycleGeneration &+= 1
        isRunning = true
    }

    func invalidatePendingOperations() {
        lifecycleGeneration &+= 1
        activeTicket?.invalidate()
    }

    func setDragGateClosed(_ closed: Bool) {
        guard dragGateClosed != closed else { return }
        dragGateClosed = closed
        if closed { invalidatePendingOperations() }
    }

    var frontmostPID: pid_t? { environment.frontmostPID() }
    var accessibilityIsTrusted: Bool { environment.isAccessibilityTrusted() }
    var processID: pid_t { environment.ownPID }

    private func perform(_ action: KeyboardSnapAction, generation: UInt64) async {
        guard isRunning, !dragGateClosed, lifecycleGeneration == generation else { return }
        if case .extend = action, !extensionFlagsAvailable {
            statusMessage = "Keyboard extension is unavailable because modifier monitoring is not ready."
            return
        }
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
            } else if case .extend = action {
                await extend(action, focused: focused, generation: generation)
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
        let existing = sessions[focused.token.id]
        let sourceDisplay = snapshot.display
        var session = existing ?? KeyboardPlacementSession(
            token: focused.token,
            originalFrame: focused.frame,
            restoreAnchor: KeyboardRestoreAnchor(displayID: sourceDisplay.id, displayFrame: sourceDisplay.frame,
                                          configurationFingerprint: layoutController.displayProvider.snapshot.fingerprint),
            activeAddress: nil,
            extensionAnchor: nil,
            extensionEndpoint: nil,
            extensionLayoutID: nil,
            extensionWorkArea: nil
        )
        guard let target = navigationTarget(action, focused: focused, snapshot: snapshot, session: session) else { return }
        session = target.session
        resetExtensionHistory(&session)
        let targetAddress = target.address
        let zone = target.zone
        if targetAddress == session.activeAddress {
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
            let now = DispatchTime.now().uptimeNanoseconds
            guard let ticket = validity.reserve(startDeadline: now + 2_000_000_000,
                                                totalDeadline: now + 5_000_000_000) else {
                statusMessage = "A window placement is already pending or in progress."
                return
            }
            installActiveTicket(ticket, token: focused.token)
            defer { finishActiveTicket(ticket) }
            let savedSettings = layoutController.keyboardSettings
            let preflight: @MainActor @Sendable () -> Bool = { [weak self] in
                guard let self, self.isRunning, !self.dragGateClosed, self.lifecycleGeneration == generation,
                      self.layoutController.keyboardSettings.isEnabled,
                      self.frontmostPID == focused.token.pid,
                      self.accessibilityIsTrusted,
                      self.layoutController.keyboardSettings == savedSettings else { return false }
                return self.layoutController.isCurrent(snapshot, for: focused.frame)
            }
            let actualFrame = try await backend.move(focused.token, to: zone.frame, ticket: ticket, preflight: preflight)
            guard Self.matches(actualFrame, zone.frame) else { throw KeyboardSnapError.readbackMismatch }
            guard preflight(), ticket.completeIfCurrent(now: DispatchTime.now().uptimeNanoseconds) else {
                throw WindowManagementError.displayConfigurationChanged
            }
            session.activeAddress = targetAddress
            resetExtensionHistory(&session)
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
        guard let targetFrame = restoreFrame(for: session) else {
            statusMessage = "Restore failed; the original frame is still saved. \(WindowManagementError.displayConfigurationChanged.localizedDescription)"
            return
        }
        do {
            let now = DispatchTime.now().uptimeNanoseconds
            guard let ticket = validity.reserve(startDeadline: now + 2_000_000_000,
                                                totalDeadline: now + 5_000_000_000) else {
                statusMessage = "A window placement is already pending or in progress."
                return
            }
            installActiveTicket(ticket, token: focused.token)
            defer { finishActiveTicket(ticket) }
            let preflight: @MainActor @Sendable () -> Bool = { [weak self] in
                guard let self, self.isRunning, !self.dragGateClosed, self.lifecycleGeneration == generation,
                      self.layoutController.keyboardSettings.isEnabled else { return false }
                return self.frontmostPID == focused.token.pid && self.accessibilityIsTrusted
            }
            let actualFrame = try await backend.restore(session.token, to: targetFrame,
                                                        ticket: ticket, preflight: preflight)
            guard Self.matches(actualFrame, targetFrame) else { throw KeyboardSnapError.readbackMismatch }
            guard preflight(), ticket.completeIfCurrent(now: DispatchTime.now().uptimeNanoseconds) else {
                throw WindowManagementError.displayConfigurationChanged
            }
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

}

extension KeyboardSnapController {
    private func navigationTarget(
        _ action: KeyboardSnapAction,
        focused: RuntimeWindowSnapshot,
        snapshot: KeyboardLayoutSnapshot,
        session: KeyboardPlacementSession
    ) -> KeyboardNavigationTarget? {
        var session = session
        let extendedUnionIsCurrent = session.extensionPlacementRevision == snapshot.revision
            && session.extensionLayoutID == snapshot.layout.id
            && session.extensionWorkArea == snapshot.display.selectionKey
            && session.extensionLastFrame.map { Self.framesMatch($0, focused.frame) } == true
        session.activeAddress = extendedUnionIsCurrent ? session.extensionEndpoint
            : Self.resolvedCurrentAddress(session.activeAddress, frame: focused.frame, displays: snapshot.displayLayouts)
        let request = MultiDisplayNavigationRequest(
            mode: layoutController.keyboardSettings.mode,
            currentAddress: session.activeAddress,
            currentDisplay: snapshot.display.id,
            currentFrame: focused.frame,
            displays: snapshot.displayLayouts,
            cycle: layoutController.keyboardSettings.cyclesAtEdges
        )
        guard let (address, zone) = MultiDisplayNavigator.zone(for: action, request: request) else {
            let message = action == .direction(.north) || action == .direction(.south)
                ? "Up and Down are unavailable in zone-order mode."
                : "There is no eligible zone in that direction."
            statusMessage = message
            return nil
        }
        guard address != session.activeAddress else {
            statusMessage = "The window is already in zone \(zone.id.displayNumber)."
            return nil
        }
        return KeyboardNavigationTarget(session: session, address: address, zone: zone)
    }

    func installActiveTicket(_ ticket: PlacementCommitTicket, token: RuntimeWindowToken) {
        activeTicket = ticket
        activeTicketToken = token
    }

    func finishActiveTicket(_ ticket: PlacementCommitTicket) {
        ticket.finish()
        if activeTicket === ticket {
            activeTicket = nil
            activeTicketToken = nil
        }
    }

    private func invalidateActiveTicket(for pid: pid_t) {
        guard activeTicketToken?.pid == pid else { return }
        activeTicket?.invalidate()
    }

    private func restoreFrame(for session: KeyboardPlacementSession) -> CGRect? {
        let snapshot = layoutController.refreshDisplays()
        let original = session.originalFrame
        guard DisplayGeometry.isFinite(original), original.width > 0, original.height > 0 else { return nil }
        if snapshot.fingerprint == session.restoreAnchor.configurationFingerprint { return original }
        guard let display = snapshot.displays.first(where: { $0.id == session.restoreAnchor.displayID }) else { return nil }
        let deltaX = display.frame.minX - session.restoreAnchor.displayFrame.minX
        let deltaY = display.frame.minY - session.restoreAnchor.displayFrame.minY
        let frame = original.offsetBy(dx: deltaX, dy: deltaY)
        guard DisplayGeometry.isFinite(frame), frame.width > 0, frame.height > 0,
              display.workArea.contains(frame) else { return nil }
        return frame
    }

    static func resolvedCurrentAddress(_ address: ZoneAddress?, frame: CGRect,
                                       displays: [KeyboardDisplayLayout]) -> ZoneAddress? {
        if let address,
           let display = displays.first(where: { $0.display.selectionKey == address.workArea }),
           let zone = display.zones.first(where: { $0.id == address.zoneID }),
           framesMatch(zone.frame, frame) { return address }
        let matches = displays.flatMap { display in
            display.zones.filter { framesMatch($0.frame, frame) }
                .map { ZoneAddress(workArea: display.display.selectionKey, zoneID: $0.id) }
        }
        return matches.sorted {
            let left = String(describing: $0.workArea.display)
            let right = String(describing: $1.workArea.display)
            return left == right ? $0.zoneID.rawValue < $1.zoneID.rawValue : left < right
        }.first
    }

    static func matches(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        [lhs.minX - rhs.minX, lhs.minY - rhs.minY, lhs.width - rhs.width, lhs.height - rhs.height]
            .allSatisfy { $0.isFinite && abs($0) <= 2 }
    }

    static func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool { matches(lhs, rhs) }

}

@MainActor
extension KeyboardSnapController {
    func discardProcess(_ pid: pid_t) async {
        lifecycleGeneration &+= 1
        invalidateActiveTicket(for: pid)
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

    func isEligible(_ action: KeyboardSnapAction, for focused: RuntimeWindowSnapshot, layout snapshot: KeyboardLayoutSnapshot?) -> Bool {
        if action == .restore {
            guard let session = sessions[focused.token.id] else { return false }
            return restoreFrame(for: session) != nil
        }
        guard let snapshot else { return false }
        if case .extend = action, !extensionFlagsAvailable { return false }
        let session = sessions[focused.token.id]
        let currentAddress = Self.resolvedCurrentAddress(session?.activeAddress, frame: focused.frame,
                                                         displays: snapshot.displayLayouts)
        let request = MultiDisplayNavigationRequest(
            mode: layoutController.keyboardSettings.mode,
            currentAddress: currentAddress,
            currentDisplay: snapshot.display.id,
            currentFrame: focused.frame,
            displays: snapshot.displayLayouts,
            cycle: layoutController.keyboardSettings.cyclesAtEdges
        )
        if case .extend = action {
            return extensionTarget(action, snapshot: snapshot, session: sessions[focused.token.id],
                                   frame: focused.frame) != nil
        }
        guard let (address, target) = MultiDisplayNavigator.zone(for: action, request: request) else { return false }
        guard address != currentAddress else { return false }
        return !Self.framesMatch(target.frame, focused.frame)
    }
}
