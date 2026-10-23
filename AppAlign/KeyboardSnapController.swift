import AppKit
import ApplicationServices
import Combine
import Foundation

struct RuntimeWindowToken: Hashable, Sendable {
    let id: UUID
    let pid: pid_t
    let processGeneration: UUID

    init(id: UUID, pid: pid_t, processGeneration: UUID = UUID()) {
        self.id = id
        self.pid = pid
        self.processGeneration = processGeneration
    }
}

struct RuntimeWindowSnapshot: Sendable {
    let token: RuntimeWindowToken
    let frame: CGRect
}

enum WindowObservationReadiness: Sendable {
    case ready(CGRect)
    case temporarilyUnavailable
    case terminal
}

struct WindowObservationCandidate: Sendable {
    let token: RuntimeWindowToken
    let readiness: WindowObservationReadiness
}

struct WindowObservationResult: Sendable {
    let candidates: [WindowObservationCandidate]
    let isComplete: Bool
    /// True when the AX list was complete, but at least one identity could not be
    /// represented because the runtime record table was at capacity.
    let hasUntrackedWindowsDueToCapacity: Bool

    init(candidates: [WindowObservationCandidate], isComplete: Bool,
         hasUntrackedWindowsDueToCapacity: Bool = false) {
        self.candidates = candidates
        self.isComplete = isComplete
        self.hasUntrackedWindowsDueToCapacity = hasUntrackedWindowsDueToCapacity
    }
}

struct ManualWindowLeaseID: Hashable, Sendable {
    let rawValue: UUID
    init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

struct RuntimeHistoryLeaseID: Hashable, Sendable {
    let rawValue: UUID
    init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

struct ManualWindowCapture: Sendable {
    let token: RuntimeWindowToken
    let lease: ManualWindowLeaseID
    let originalFrame: CGRect
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

protocol KeyboardWindowOperating: WindowHistoryLeaseOperating {
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
    let focusedWindowIdentity: @MainActor (pid_t) async -> Int?
    let ownPID: pid_t
    let bundleIdentifier: @MainActor (pid_t) -> String?
    init(frontmostPID: @escaping @MainActor () -> pid_t?, isAccessibilityTrusted: @escaping @MainActor () -> Bool,
         focusedWindowIdentity: @escaping @MainActor (pid_t) async -> Int? = FocusedWindowIdentity.read,
         ownPID: pid_t,
         bundleIdentifier: @escaping @MainActor (pid_t) -> String? = { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }) {
        self.frontmostPID = frontmostPID
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.focusedWindowIdentity = focusedWindowIdentity
        self.ownPID = ownPID
        self.bundleIdentifier = bundleIdentifier
    }

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

private struct KeyboardPlacementPreparation {
    let snapshot: KeyboardLayoutSnapshot
    let target: KeyboardNavigationTarget
    let historyLease: AppHistoryCoordinator.Lease?
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
    var activeExtensionTicket: PlacementCommitTicket?
    var lastObservedWindowToken: RuntimeWindowToken?
    let maximumSessions = 64
    var lifecycleGeneration: UInt64 = 0
    var extensionHistoryGeneration: UInt64 = 0
    var extensionFlagsAvailable = false
    var previousModifierFlags: UInt64?
    var lastExtensionModifierMask: UInt64?
    var pendingExtensionAttempt: KeyboardExtensionAttempt?
    var isRunning = true
    private(set) var dragGateClosed = false

    func setBusy(_ busy: Bool) {
        isBusy = busy
    }

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

    func shutdown() async {
        invalidatePendingOperations()
        setExtensionFlagsAvailable(false)
        isRunning = false
        lastObservedWindowToken = nil
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

    func perform(_ action: KeyboardSnapAction, generation: UInt64,
                 extensionAttempt: KeyboardExtensionAttempt? = nil) async {
        layoutController.cancelAutomaticRestores?()
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
                  extensionAttempt.map({ $0.historyGeneration == extensionHistoryGeneration }) ?? true,
                  frontmostPID == pid, accessibilityIsTrusted,
                  layoutController.keyboardSettings.isEnabled else {
                await discardProbeIfUnowned(focused.token)
                statusMessage = "The front window changed. Try the shortcut again."
                return
            }
            observeFocusedWindow(focused.token)
            if action == .restore {
                await restore(focused, generation: generation)
            } else if case .extend = action {
                guard let extensionAttempt else { return }
                let observedAttempt: KeyboardExtensionAttempt
                if extensionHistoryGeneration == extensionAttempt.historyGeneration {
                    observedAttempt = extensionAttempt
                } else {
                    observedAttempt = KeyboardExtensionAttempt(id: extensionAttempt.id,
                                                               lifecycleGeneration: extensionAttempt.lifecycleGeneration,
                                                               historyGeneration: extensionHistoryGeneration,
                                                               modifierMask: extensionAttempt.modifierMask)
                    if pendingExtensionAttempt?.id == extensionAttempt.id {
                        pendingExtensionAttempt = observedAttempt
                    }
                }
                await extend(action, focused: focused, attempt: observedAttempt)
            } else {
                await place(action, focused: focused, generation: generation)
            }
        } catch {
            guard isRunning, lifecycleGeneration == generation else { return }
            statusMessage = error.localizedDescription
        }
    }
}

@MainActor
extension KeyboardSnapController {
    private func place(_ action: KeyboardSnapAction, focused: RuntimeWindowSnapshot, generation: UInt64) async {
        guard let preparation = await preparePlacement(action, focused: focused, generation: generation) else { return }
        let snapshot = preparation.snapshot
        let target = preparation.target
        let historyLease = preparation.historyLease
        var session = target.session
        let targetAddress = target.address
        let zone = target.zone
        defer { layoutController.releaseAppPlacement(historyLease) }
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
            layoutController.acceptSuccessfulAppPlacement(historyLease, zoneIDs: [targetAddress.zoneID.rawValue])
            session.activeAddress = targetAddress
            resetExtensionHistory(&session)
            sessions[focused.token.id] = session
            statusMessage = "Placed window in zone \(zone.id.displayNumber)."
        } catch {
            guard isRunning, lifecycleGeneration == generation else { return }
            statusMessage = "Placement failed; the original frame is saved for Restore. \(error.localizedDescription)"
        }
    }

    private func preparePlacement(_ action: KeyboardSnapAction, focused: RuntimeWindowSnapshot,
                                  generation: UInt64) async -> KeyboardPlacementPreparation? {
        guard let snapshot = layoutController.appliedLayoutSnapshot(for: focused.frame) else {
            statusMessage = "No applied layout is available for the window's display."
            return nil
        }
        let existing = sessions[focused.token.id]
        let sourceDisplay = snapshot.display
        let session = existing ?? KeyboardPlacementSession(
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
        guard let target = navigationTarget(action, focused: focused, snapshot: snapshot, session: session) else { return nil }
        var resolvedTarget = target
        var updatedSession = resolvedTarget.session
        resetExtensionHistory(&updatedSession)
        resolvedTarget = KeyboardNavigationTarget(session: updatedSession, address: resolvedTarget.address,
                                                  zone: resolvedTarget.zone)
        if resolvedTarget.address == updatedSession.activeAddress {
            statusMessage = "The window is already in zone \(resolvedTarget.zone.id.displayNumber)."
            return nil
        }
        guard let targetDisplayLayout = snapshot.displayLayouts.first(where: {
            $0.display.selectionKey == resolvedTarget.address.workArea
        }) else {
            statusMessage = "The target display layout is no longer available."
            return nil
        }
        let bundleID = environment.bundleIdentifier(focused.token.pid)
        let reservedHistoryLease = layoutController.reserveAppPlacement(token: focused.token, bundleID: bundleID,
                                                                         display: targetDisplayLayout.display,
                                                                         layout: targetDisplayLayout.layout)
        let historyLease = await layoutController.acquireAppPlacement(reservedHistoryLease, using: backend)
        guard isRunning, lifecycleGeneration == generation,
              layoutController.isCurrent(snapshot, for: focused.frame), frontmostPID == focused.token.pid else {
            layoutController.releaseAppPlacement(historyLease)
            return nil
        }
        return KeyboardPlacementPreparation(snapshot: snapshot, target: resolvedTarget, historyLease: historyLease)
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
            layoutController.appRestoreSucceeded(focused.token)
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

    func installActiveExtensionTicket(_ ticket: PlacementCommitTicket, token: RuntimeWindowToken) {
        installActiveTicket(ticket, token: token)
        activeExtensionTicket = ticket
    }

    func finishActiveTicket(_ ticket: PlacementCommitTicket) {
        ticket.finish()
        if activeTicket === ticket {
            activeTicket = nil
            activeTicketToken = nil
        }
        if activeExtensionTicket === ticket { activeExtensionTicket = nil }
    }

    func observeFocusedWindow(_ token: RuntimeWindowToken) {
        if let lastObservedWindowToken, lastObservedWindowToken != token {
            resetNavigationHistory()
        }
        lastObservedWindowToken = token
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

}

@MainActor
extension KeyboardSnapController {
    func discardProcess(_ pid: pid_t) async {
        lifecycleGeneration &+= 1
        invalidateActiveTicket(for: pid)
        if lastObservedWindowToken?.pid == pid { lastObservedWindowToken = nil }
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
        observeFocusedWindow(focused.token)
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
