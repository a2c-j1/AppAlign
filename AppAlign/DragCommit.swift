import AppKit
import CoreGraphics
import Foundation

struct DragCommitID: Hashable, Sendable {
    let rawValue: UUID
    init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// Cancellation and the first AX write share one lock, so a cancelled pending
/// placement cannot pass a stale MainActor preflight and then start writing.
final class DragCommitTicket: @unchecked Sendable {
    enum State: Equatable { case pending, writing, invalidated, finished }

    private let lock = NSLock()
    private var current: State = .pending
    let startDeadline: UInt64
    let totalDeadline: UInt64

    init(startDeadline: UInt64, totalDeadline: UInt64) {
        self.startDeadline = startDeadline
        self.totalDeadline = totalDeadline
    }

    var state: State { lock.withLock { current } }

    func invalidate() {
        lock.withLock {
            if current == .pending || current == .writing { current = .invalidated }
        }
    }

    func beginWrite(now: UInt64) -> Bool {
        lock.withLock {
            guard current == .pending, now < startDeadline, now < totalDeadline else {
                if current == .pending { current = .invalidated }
                return false
            }
            current = .writing
            return true
        }
    }

    func mayContinueWrite(now: UInt64) -> Bool {
        lock.withLock { current == .writing && now < totalDeadline }
    }

    func finish() { lock.withLock { current = .finished } }
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

protocol DragCommitOperating: Sendable {
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
    private let runtime: any DragCommitOperating
    private var activeOffer: DragCommitOffer?
    private var task: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var toggleActive = false
    private var heldToggleButton = false
    private var generation: UInt64 = 0
    private let overlay: any ZoneOverlayPresenting
    private var gestureActive = false

    init(layoutController: LayoutController, runtime: any DragCommitOperating,
         overlay: any ZoneOverlayPresenting = ZoneOverlayManager()) {
        self.layoutController = layoutController
        self.runtime = runtime
        self.overlay = overlay
    }

    var settings: DragSettings { layoutController.dragSettings }

    func updateSettings(_ settings: DragSettings) {
        cancel(reason: "Drag settings changed.")
        layoutController.updateDragSettings(settings)
    }

    func acceptedInput(_ event: DragInputEvent) {
        if event.kind == .escape || event.kind == .leftDown {
            cancel(reason: "A new input cancelled the pending drag placement.")
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

    func isActivated(flags: UInt64) -> Bool {
        let shift = flags & CGEventFlags.maskShift.rawValue != 0
        return settings.requireShift ? (shift != toggleActive) : !(shift != toggleActive)
    }

    func accept(_ offer: DragCommitOffer) -> Bool {
        guard activeOffer == nil, !isCommitting,
              offer.ticket.state == .pending else { return false }
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
            defer {
                offer.ticket.finish()
                self.deadlineTask?.cancel()
                self.deadlineTask = nil
                self.activeOffer = nil
                self.isCommitting = false
                self.gateChanged?(false)
                self.task = nil
            }
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
                _ = try await runtime.commitDrag(offer) { [weak self] in
                    guard let self, self.generation == generation,
                          self.activeOffer?.id == offer.id,
                          self.layoutController.appliedDragLayoutSnapshot(at: offer.point) == offer.layoutSnapshot,
                          offer.ticket.state == .pending else { return false }
                    return true
                }
                self.statusMessage = "Window placed in zone."
            } catch {
                self.statusMessage = error.localizedDescription
            }
            await runtime.releaseDragLease(offer.sourceLease)
            await runtime.releaseDragCommit(token: offer.token, commitID: offer.id)
        }
        return true
    }

    func prepareCommit(_ context: DragCommitContext) -> Bool {
        let generation = self.generation
        guard isActivated(flags: context.event.flags),
              let snapshot = layoutController.appliedDragLayoutSnapshot(at: context.event.location),
              self.generation == generation,
              let zone = ZoneSelectionEngine.select(point: context.event.location, zones: snapshot.zones,
                                                   workArea: snapshot.display.workArea,
                                                   radius: CGFloat(settings.selectionRadius)) else {
            overlay.hideAll()
            return false
        }
        let now = DispatchTime.now().uptimeNanoseconds
        let ticket = DragCommitTicket(startDeadline: now + 2_000_000_000,
                                      totalDeadline: now + 5_000_000_000)
        let offer = DragCommitOffer(id: DragCommitID(), run: context.run, session: context.session,
                                    inputEpoch: context.event.epoch, gesture: context.event.gesture,
                                    token: context.token, sourceLease: context.sourceLease,
                                    originalFrame: context.originalFrame, targetFrame: zone.frame,
                                    point: context.event.location, flags: context.event.flags,
                                    timestamp: context.event.timestamp, sequence: context.event.sequence,
                                    displayFingerprint: snapshot.fingerprint, layoutRevision: snapshot.revision,
                                    workAreaKey: snapshot.workAreaKey, zoneID: zone.id,
                                    layoutSnapshot: snapshot, ticket: ticket)
        return accept(offer)
    }

    func lifecycle(_ event: DragLifecycleEvent) {
        switch event.kind {
        case .began, .updated:
            gestureActive = true
            renderOverlay(point: event.point, flags: event.flags)
        case .ended, .cancelled:
            gestureActive = false
            overlay.hideAll()
            toggleActive = false
            heldToggleButton = false
        }
    }

    private func renderOverlay(point: CGPoint, flags: UInt64) {
        let generation = self.generation
        guard isActivated(flags: flags),
              let snapshot = layoutController.appliedDragLayoutSnapshot(at: point),
              self.generation == generation, gestureActive else {
            overlay.hideAll()
            return
        }
        let zone = ZoneSelectionEngine.select(point: point, zones: snapshot.zones,
                                             workArea: snapshot.display.workArea,
                                             radius: CGFloat(settings.selectionRadius))
        overlay.show(snapshot, selected: zone?.id)
    }

    func cancel(reason: String) {
        generation &+= 1
        gestureActive = false
        toggleActive = false
        heldToggleButton = false
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
    private let keyboard: KeyboardSnapController
    private let hotkeys: GlobalHotkeys

    init(keyboard: KeyboardSnapController, hotkeys: GlobalHotkeys) {
        self.keyboard = keyboard
        self.hotkeys = hotkeys
    }

    func setDrag(_ active: Bool) { dragActive = active; update() }
    func setCommit(_ active: Bool) { commitActive = active; update() }

    private func update() {
        let closed = dragActive || commitActive
        keyboard.setDragGateClosed(closed)
        hotkeys.setDragGateClosed(closed)
    }
}
