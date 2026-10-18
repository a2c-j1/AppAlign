import AppKit
import CoreGraphics
import Foundation

struct DragCommitID: Hashable, Sendable {
    let rawValue: UUID
    init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

struct DragCommitOffer: Sendable {
    let id: DragCommitID
    let run: UInt64
    let session: UInt64
    let inputEpoch: UInt64
    let gesture: UInt64
    let token: RuntimeWindowToken
    let sourceLease: DragLeaseID
    let originalFrame: CGRect
    let targetFrame: CGRect
    let point: CGPoint
    let flags: UInt64
    let timestamp: UInt64
    let sequence: UInt64
    let displayFingerprint: String
    let layoutRevision: UInt64
    let workAreaKey: WorkAreaKey
    let zoneID: ZoneID
    var zoneIDs: Set<ZoneID> = []
    let layoutSnapshot: DragLayoutSnapshot
    let ticket: DragCommitTicket
}

struct DragCommitContext: Sendable {
    let run: UInt64
    let session: UInt64
    let event: DragInputEvent
    let token: RuntimeWindowToken
    let sourceLease: DragLeaseID
    let originalFrame: CGRect
    let displayFingerprint: String
}

protocol DragCommitOperating: WindowHistoryLeaseOperating {
    func handoffDragLease(token: RuntimeWindowToken, sourceLease: DragLeaseID, commitID: DragCommitID, ticket: DragCommitTicket) async -> Bool
    func commitDrag(_ offer: DragCommitOffer, preflight: @MainActor @Sendable () -> Bool) async throws -> CGRect
    func releaseDragLease(_ lease: DragLeaseID) async
    func releaseDragCommit(token: RuntimeWindowToken, commitID: DragCommitID) async
}

@MainActor
final class DragSnapController: ObservableObject {
    @Published private(set) var isCommitting = false
    @Published private(set) var statusMessage = ""
    var gateChanged: (@MainActor (Bool) -> Void)?

    private let layoutController: LayoutController
    private let validity: PlacementValidity
    private let runtime: any DragCommitOperating
    private let bundleIdentifierProvider: @MainActor (pid_t) -> String?
    private var activeOffer: DragCommitOffer?
    private var task: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var toggleActive = false
    private var heldToggleButton = false
    private var generation: UInt64 = 0
    private let overlay: any ZoneOverlayPresenting
    private var gestureActive = false
    private var rangeAnchor: [Zone]?
    private var rangeWorkArea: WorkAreaKey?
    private var rangeLayoutID: UUID?
    private var rangePlacementRevision: PlacementRevision?
    private var lastModifierFlags: UInt64?

    init(layoutController: LayoutController, runtime: any DragCommitOperating,
         overlay: any ZoneOverlayPresenting = ZoneOverlayManager(),
         bundleIdentifierProvider: @escaping @MainActor (pid_t) -> String? = {
             NSRunningApplication(processIdentifier: $0)?.bundleIdentifier
         }) {
        self.layoutController = layoutController
        validity = layoutController.placementValidity
        self.runtime = runtime
        self.overlay = overlay
        self.bundleIdentifierProvider = bundleIdentifierProvider
    }

    var settings: DragSettings { layoutController.dragSettings }

    func updateSettings(_ settings: DragSettings) {
        cancel(reason: "Drag settings changed.")
        layoutController.updateDragSettings(settings)
    }

    func acceptedInput(_ event: DragInputEvent) {
        if event.kind == .flagsChanged {
            if let lastModifierFlags,
               lastModifierFlags & settings.rangeModifier.eventFlag != 0,
               event.flags & settings.rangeModifier.eventFlag == 0 {
                clearRangeSelection()
            }
            lastModifierFlags = event.flags
        }
        if event.kind == .escape || event.kind == .leftDown {
            cancel(reason: "A new input cancelled the pending drag placement.")
            lastModifierFlags = event.flags
        }
        if event.kind == .buttonChanged, let edge = event.buttonEdge {
            let button = Int(event.button)
            let isDown = button > 0 && button < 64 && event.buttonMask & 1 != 0 &&
                event.buttonMask & (UInt64(1) << UInt64(button)) != 0
            if button != 0, settings.toggleButton == button {
                switch edge {
                case .down:
                    if isDown, !heldToggleButton { heldToggleButton = true; toggleActive.toggle() }
                case .released: heldToggleButton = false
                }
            }
        }
        if gestureActive { renderOverlay(point: event.location, flags: event.flags) }
    }
}

@MainActor
extension DragSnapController {
    func accept(_ offer: DragCommitOffer) -> Bool {
        guard activeOffer == nil, !isCommitting,
              offer.ticket.state == .pending else { return false }
        layoutController.cancelAutomaticRestores?()
        activeOffer = offer
        isCommitting = true
        gateChanged?(true)
        let generation = self.generation
        deadlineTask = Task { [runtime] in
            let now = DispatchTime.now().uptimeNanoseconds
            let remaining = offer.ticket.totalDeadline > now ? offer.ticket.totalDeadline - now : 0
            try? await Task.sleep(nanoseconds: remaining)
            guard !Task.isCancelled else { return }
            offer.ticket.invalidate()
            await runtime.releaseDragLease(offer.sourceLease)
            await runtime.releaseDragCommit(token: offer.token, commitID: offer.id)
        }
        task = Task { @MainActor [self, runtime] in
            await performCommit(offer, generation: generation, runtime: runtime)
        }
        return true
    }

    private func performCommit(_ offer: DragCommitOffer, generation: UInt64,
                               runtime: any DragCommitOperating) async {
            defer {
                offer.ticket.finish()
                if self.activeOffer?.id == offer.id {
                    self.deadlineTask?.cancel()
                    self.deadlineTask = nil
                    self.activeOffer = nil
                    self.isCommitting = false
                    self.gateChanged?(false)
                    self.task = nil
                }
            }
            let reservedHistoryLease = self.layoutController.reserveAppPlacement(
                token: offer.token,
                bundleID: self.bundleIdentifierProvider(offer.token.pid),
                display: offer.layoutSnapshot.display,
                layout: offer.layoutSnapshot.layout
            )
            let historyLease = await self.layoutController.acquireAppPlacement(reservedHistoryLease, using: runtime)
            guard self.generation == generation, self.activeOffer?.id == offer.id,
                  self.layoutController.appliedDragLayoutSnapshot(at: offer.point) == offer.layoutSnapshot,
                  offer.ticket.state == .pending else {
                self.layoutController.releaseAppPlacement(historyLease)
                if let historyLease {
                    await runtime.releaseHistoryLease(historyLease.token, lease: historyLease.runtimeLeaseID)
                }
                await runtime.releaseDragLease(offer.sourceLease)
                await runtime.releaseDragCommit(token: offer.token, commitID: offer.id)
                return
            }
            defer { self.layoutController.releaseAppPlacement(historyLease) }
            do {
                guard await runtime.handoffDragLease(token: offer.token, sourceLease: offer.sourceLease,
                                                     commitID: offer.id, ticket: offer.ticket) else {
                    await runtime.releaseDragLease(offer.sourceLease)
                    offer.ticket.invalidate()
                    await runtime.releaseDragCommit(token: offer.token, commitID: offer.id)
                    return
                }
                guard self.generation == generation, self.activeOffer?.id == offer.id,
                      offer.ticket.state == .pending else {
                    await runtime.releaseDragCommit(token: offer.token, commitID: offer.id)
                    return
                }
                let actualFrame = try await runtime.commitDrag(offer) { [weak self] in
                    guard let self, self.generation == generation,
                          self.activeOffer?.id == offer.id,
                          self.layoutController.appliedDragLayoutSnapshot(at: offer.point) == offer.layoutSnapshot,
                          offer.layoutSnapshot.placementRevision == offer.ticket.revision,
                          offer.ticket.state == .pending else { return false }
                    return true
                }
                guard Self.framesMatch(actualFrame, offer.targetFrame),
                      self.generation == generation, self.activeOffer?.id == offer.id,
                      self.layoutController.appliedDragLayoutSnapshot(at: offer.point) == offer.layoutSnapshot,
                      offer.layoutSnapshot.placementRevision == offer.ticket.revision,
                      offer.ticket.completeIfCurrent(now: DispatchTime.now().uptimeNanoseconds) else {
                    throw WindowManagementError.displayConfigurationChanged
                }
                self.layoutController.acceptSuccessfulAppPlacement(
                    historyLease, zoneIDs: offer.zoneIDs.map(\.rawValue).sorted()
                )
                if self.generation == generation, self.activeOffer?.id == offer.id {
                    self.statusMessage = "Window placed in zone."
                }
            } catch {
                if self.generation == generation, self.activeOffer?.id == offer.id {
                    self.statusMessage = error.localizedDescription
                }
            }
            await runtime.releaseDragLease(offer.sourceLease)
            await runtime.releaseDragCommit(token: offer.token, commitID: offer.id)

    }

    private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        DisplayGeometry.isFinite(lhs) && DisplayGeometry.isFinite(rhs) &&
            abs(lhs.minX - rhs.minX) <= 2 && abs(lhs.minY - rhs.minY) <= 2 &&
            abs(lhs.width - rhs.width) <= 2 && abs(lhs.height - rhs.height) <= 2
    }

    func prepareCommit(_ context: DragCommitContext) -> Bool {
        let generation = self.generation
        guard isActivated(flags: context.event.flags),
              let snapshot = layoutController.appliedDragLayoutSnapshot(at: context.event.location),
              self.generation == generation,
              let selection = selectionAt(point: context.event.location, flags: context.event.flags,
                                          snapshot: snapshot, updateRangeAnchor: false),
              let targetFrame = ZoneSelectionEngine.union(of: selection.map(\.frame)) else {
            overlay.hideAll()
            return false
        }
        let now = DispatchTime.now().uptimeNanoseconds
        guard let ticket = validity.reserve(startDeadline: now + 2_000_000_000,
                                            totalDeadline: now + 5_000_000_000) else {
            statusMessage = "A window placement is already pending or in progress."
            overlay.hideAll()
            return false
        }
        let offer = DragCommitOffer(id: DragCommitID(), run: context.run, session: context.session,
                                    inputEpoch: context.event.epoch, gesture: context.event.gesture,
                                    token: context.token, sourceLease: context.sourceLease,
                                    originalFrame: context.originalFrame, targetFrame: targetFrame,
                                    point: context.event.location, flags: context.event.flags,
                                    timestamp: context.event.timestamp, sequence: context.event.sequence,
                                    displayFingerprint: snapshot.fingerprint, layoutRevision: snapshot.revision,
                                    workAreaKey: snapshot.workAreaKey, zoneID: selection[0].id,
                                    zoneIDs: Set(selection.map(\.id)),
                                    layoutSnapshot: snapshot, ticket: ticket)
        guard accept(offer) else {
            ticket.invalidate()
            ticket.finish()
            overlay.hideAll()
            return false
        }
        return true
    }

    func lifecycle(_ event: DragLifecycleEvent) {
        switch event.kind {
        case .began, .updated:
            gestureActive = true
            renderOverlay(point: event.point, flags: event.flags)
        case .ended, .cancelled:
            gestureActive = false
            overlay.hideAll()
            clearRangeSelection()
            toggleActive = false
            heldToggleButton = false
        }
    }

    func reselectAfterQuickSwitch(point: CGPoint, flags: UInt64) {
        guard gestureActive else { return }
        generation &+= 1
        activeOffer?.ticket.invalidate()
        clearRangeSelection()
        overlay.hideAll()
        renderOverlay(point: point, flags: flags)
    }

    private func renderOverlay(point: CGPoint, flags: UInt64) {
        let generation = self.generation
        guard isActivated(flags: flags),
              let snapshot = layoutController.appliedDragLayoutSnapshot(at: point),
              self.generation == generation, gestureActive else {
            overlay.hideAll()
            return
        }
        guard let selection = selectionAt(point: point, flags: flags, snapshot: snapshot, updateRangeAnchor: true) else {
            overlay.show(snapshot, selected: [])
            return
        }
        overlay.show(snapshot, selected: Set(selection.map(\.id)))
    }

    private func selectionAt(point: CGPoint, flags: UInt64, snapshot: DragLayoutSnapshot,
                             updateRangeAnchor: Bool) -> [Zone]? {
        let layoutID = snapshot.layout.id
        if rangeWorkArea != snapshot.workAreaKey || rangeLayoutID != layoutID
            || rangePlacementRevision != snapshot.placementRevision {
            clearRangeSelection()
            rangeWorkArea = snapshot.workAreaKey
            rangeLayoutID = layoutID
            rangePlacementRevision = snapshot.placementRevision
        }
        let modifierDown = flags & settings.rangeModifier.eventFlag != 0
        let current = ZoneSelectionEngine.selectZones(point: point, zones: snapshot.zones,
                                                      workArea: snapshot.display.workArea,
                                                      radius: CGFloat(settings.selectionRadius),
                                                      strategy: settings.overlapStrategy)
        guard !current.isEmpty else {
            if updateRangeAnchor, !modifierDown { rangeAnchor = nil }
            return nil
        }
        guard modifierDown else {
            if updateRangeAnchor { rangeAnchor = nil }
            return current
        }
        if rangeAnchor == nil, updateRangeAnchor { rangeAnchor = current }
        guard let anchor = rangeAnchor else { return current }
        let ranged = ZoneSelectionEngine.range(anchor: anchor, current: current, zones: snapshot.zones)
        return ranged.isEmpty ? current : ranged
    }

    private func clearRangeSelection() {
        rangeAnchor = nil
        rangeWorkArea = nil
        rangeLayoutID = nil
        rangePlacementRevision = nil
    }

    func cancel(reason: String) {
        generation &+= 1
        gestureActive = false
        toggleActive = false
        heldToggleButton = false
        clearRangeSelection()
        if let offer = activeOffer { offer.ticket.invalidate() }
        if activeOffer == nil {
            isCommitting = false
            gateChanged?(false)
        }
        if !reason.isEmpty { statusMessage = reason }
        overlay.hideAll()
    }

    func drainForShutdown() async {
        cancel(reason: "AppAlign is quitting.")
        let pending = task
        await pending?.value
    }
}

@MainActor
final class DragKeyboardGate {
    private var dragActive = false
    private var commitActive = false
    private var configurationPending = false
    private let keyboard: KeyboardSnapController
    private let hotkeys: GlobalHotkeys
    private let layoutHotkeys: LayoutHotkeys?

    init(keyboard: KeyboardSnapController, hotkeys: GlobalHotkeys, layoutHotkeys: LayoutHotkeys? = nil) {
        self.keyboard = keyboard
        self.hotkeys = hotkeys
        self.layoutHotkeys = layoutHotkeys
    }

    func setDrag(_ active: Bool) { dragActive = active; update() }
    func setCommit(_ active: Bool) { commitActive = active; update() }
    func setConfigurationPending(_ pending: Bool) {
        configurationPending = pending
        layoutHotkeys?.setConfigurationPending(pending)
        update()
    }

    private func update() {
        let closed = dragActive || commitActive || configurationPending
        keyboard.setDragGateClosed(closed)
        hotkeys.setDragGateClosed(closed)
    }
}

@MainActor
extension DragSnapController {
    func isActivated(flags: UInt64) -> Bool {
        let shift = flags & CGEventFlags.maskShift.rawValue != 0
        return settings.requireShift ? (shift != toggleActive) : !(shift != toggleActive)
    }

}
