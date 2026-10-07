import AppKit
@preconcurrency import ApplicationServices
import Combine
import CoreGraphics
import Foundation

@MainActor
struct DragEnvironment {
    var inputGranted: @MainActor () -> Bool
    var accessibilityGranted: @MainActor () -> Bool
    var requestInput: @MainActor () -> Void
    var requestAccessibility: @MainActor () -> Void
    var buttonsReleased: @MainActor () -> Bool
    var displayFingerprint: @MainActor () -> String
    var now: @MainActor () -> UInt64

    static func live() -> DragEnvironment {
        let displays = DisplayProvider()
        return DragEnvironment(inputGranted: { CGPreflightListenEventAccess() }, accessibilityGranted: { AXIsProcessTrusted() },
                               requestInput: { CGRequestListenEventAccess() }, requestAccessibility: {
                                   let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true as CFBoolean] as CFDictionary
                                   _ = AXIsProcessTrustedWithOptions(options)
                               }, buttonsReleased: { NSEvent.pressedMouseButtons == 0 }, displayFingerprint: { displays.refresh().fingerprint },
                               now: { DispatchTime.now().uptimeNanoseconds })
    }
}

@MainActor
final class DragDetectionController: ObservableObject {
    @Published private(set) var statusMessage = "Window dragging detection is off."
    @Published private(set) var isEnabled = false
    @Published private(set) var isRunning = false
    @Published private(set) var lifecycleEvents: [DragLifecycleEvent] = []
    var dragGateChanged: (@MainActor (Bool) -> Void)?
    var invalidateKeyboard: (@MainActor () -> Void)?
    var onLifecycle: (@MainActor (DragLifecycleEvent) -> Void)?
    var onWillEnd: (@MainActor (DragCommitContext) -> Bool)?
    var onAcceptedInput: (@MainActor (DragInputEvent) -> Void)?
    var onCommitCancelled: (@MainActor (String) -> Void)?

    private struct Gesture {
        let session: UInt64
        let inputID: UInt64
        let down: DragInputEvent
        let fingerprint: String
        var firstMotion: UInt64?
        var latest: DragInputEvent
        var hit: DragWindowSnapshot?
        var frame: CGRect?
        var originalFrame: CGRect?
        var baseline: DragWindowSnapshot?
        var validationRetries = 0
    }
    private let reader: any DragWindowReading
    private let monitor: any DragInputMonitoring
    private let environment: DragEnvironment
    private let ownPID: pid_t
    private let installsObservers: Bool
    private var machine = DragStateMachine()
    private var gesture: Gesture?
    private var sessionGeneration: UInt64 = 0
    private var runGeneration: UInt64 = 0
    private var inputEpoch: UInt64?
    private var lastSequence: UInt64 = 0
    private var environmentGeneration: UInt64 = 0
    private var quitPaused = false
    private var timeoutRetries = 0
    private var starting = false
    private var captureInFlight = false
    private struct PrewarmCache {
        let hit: DragWindowSnapshot
        let point: CGPoint
        let epoch: UInt64
        let environment: UInt64
        let fingerprint: String
    }
    private var prewarmCache: PrewarmCache?
    private var pendingHover: DragInputEvent?
    private var lastHover: DragInputEvent?
    private static let prewarmInterval: UInt64 = 100_000_000
    private static let cacheFreshness: UInt64 = 100_000_000
    private var lastPrewarmRequest: UInt64 = 0
    private var cleanupQueue: [DragLeaseID] = []
    private var cleanupInFlight = false
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var frameRequestID: UInt64 = 0
    private var frameInFlightID: UInt64?
    private var pendingFrameEvent: DragInputEvent?
    private var permissionTimer: Timer?
    private var observationTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(reader: any DragWindowReading, monitor: (any DragInputMonitoring)? = nil,
         environment: DragEnvironment? = nil, ownPID: pid_t = ProcessInfo.processInfo.processIdentifier, installsObservers: Bool = true) {
        self.reader = reader; self.monitor = monitor ?? InputMonitor()
        self.environment = environment ?? .live(); self.ownPID = ownPID; self.installsObservers = installsObservers
    }

    var cleanupRequestCount: Int { cleanupQueue.count }
    var prewarmCacheCount: Int { prewarmCache == nil ? 0 : 1 }
    var pendingHoverCount: Int { pendingHover == nil ? 0 : 1 }
    var captureRequestCount: Int { captureInFlight ? 1 : 0 }
    var frameRequestCount: Int { frameInFlightID == nil ? 0 : 1 }
    var pendingFrameCount: Int { pendingFrameEvent == nil ? 0 : 1 }
    var state: DragStateMachine.State { machine.state }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        timeoutRetries = 0
        if !enabled { stopMonitoring(reason: "Window dragging detection was stopped."); return }
        guard !quitPaused else { return }
        // Permission prompts occur only in this explicit user operation.
        if !environment.inputGranted() {
            statusMessage = "Input Monitoring lets AppAlign observe mouse gestures without changing input. Grant access, then choose Retry."
            environment.requestInput()
            return
        }
        if !environment.accessibilityGranted() {
            statusMessage = "Accessibility lets AppAlign identify and inspect the window under the pointer. Grant access, then choose Retry."
            environment.requestAccessibility()
            return
        }
        startMonitoring()
    }

    func retry() { setEnabled(true) }

    func shutdownForQuit() {
        quitPaused = true
        stopMonitoring(reason: "Window dragging detection is paused while AppAlign is quitting.")
    }

    func resumeAfterCancelledQuit() {
        quitPaused = false
        guard isEnabled else { return }
        startMonitoring()
    }

    func prepareForShutdown() async {
        shutdownForQuit()
        if !resourcesDrained {
            await withCheckedContinuation { shutdownWaiters.append($0) }
        }
        // The app owner alone shuts down the shared runtime, after drag leases drain.
    }
    private func startMonitoring() {
        guard isEnabled, !quitPaused, !isRunning, !starting else { return }
        guard environment.inputGranted(), environment.accessibilityGranted() else {
            statusMessage = "Input Monitoring and Accessibility are required. Choose Retry after granting access."
            return
        }
        guard environment.buttonsReleased() else {
            statusMessage = "Release mouse buttons, then choose Retry to begin a fresh gesture."
            return
        }
        runGeneration &+= 1
        let run = runGeneration
        inputEpoch = nil; lastSequence = 0
        starting = true
        statusMessage = "Starting input monitoring…"
        monitor.start(onEvent: { [weak self] event in
            guard let self, self.runGeneration == run, self.isRunning else { return }
            self.receive(event)
        }, onStatus: { [weak self] status in
            guard let self, self.runGeneration == run, !self.quitPaused, self.isEnabled else { return }
            self.monitorStatus(status)
        })
    }
    private func monitorStatus(_ status: DragMonitorStatus) {
        switch status {
        case .ready:
            starting = false; isRunning = true
            statusMessage = "Listening for title-bar drags. Input is observed without suppression or injection."
            if installsObservers { installObservers(run: runGeneration) }
        case let .failed(reason):
            stopMonitoring(reason: "Input Monitoring could not start: \(reason). Choose Retry.")
        case let .interrupted(reason):
            stopMonitoring(reason: "Input Monitoring stopped: \(reason). Choose Retry.")
            if reason == "timeout", timeoutRetries == 0 {
                timeoutRetries += 1
                startMonitoring()
            }
        }
    }
    private func stopMonitoring(reason: String) {
        runGeneration &+= 1
        starting = false; isRunning = false
        monitor.stop()
        permissionTimer?.invalidate(); permissionTimer = nil
        observationTimer?.invalidate(); observationTimer = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        inputEpoch = nil; lastSequence = 0
        cancel(reason: reason)
        discardPrewarm()
        pendingHover = nil
        lastHover = nil
        statusMessage = reason
    }

}

@MainActor
extension DragDetectionController {
    private func installObservers(run: UInt64) {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let specs: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.activeSpaceDidChangeNotification),
            (workspace, NSWorkspace.didTerminateApplicationNotification),
            (.default, NSApplication.didChangeScreenParametersNotification),
            (.default, NSApplication.didBecomeActiveNotification)
        ]
        for (center, name) in specs {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                Task { @MainActor in
                    guard let self, self.runGeneration == run, self.isRunning else { return }
                    if name == NSWorkspace.didTerminateApplicationNotification {
                        guard pid == self.gesture?.hit?.token.pid else { return }
                    }
                    self.environmentChanged(reason: "The target, Space, display, or foreground environment changed.")
                }
            }
            observers.append((center, observer))
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.runGeneration == run, self.isRunning else { return }
                self.checkHealth()
            }
        }
        // A single AX request observes movement/disappearance even if the pointer
        // stops. This timer never queues a second AX request behind a blocked one.
        observationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.runGeneration == run, self.isRunning else { return }
                if let gesture = self.gesture, gesture.hit != nil { self.requestFrame(gesture.latest) } else if self.gesture == nil, let hover = self.lastHover, self.environment.buttonsReleased() {
                    self.pendingHover = DragInputEvent(kind: .mouseMoved, location: hover.location, flags: hover.flags,
                                                      timestamp: self.environment.now(), sequence: hover.sequence, epoch: hover.epoch, gesture: hover.gesture)
                    self.pumpCapture()
                }
            }
        }
    }

    func checkHealth() {
        guard environment.inputGranted(), environment.accessibilityGranted() else {
            stopMonitoring(reason: "Input Monitoring or Accessibility permission was revoked. Choose Retry.")
            invalidateKeyboard?()
            return
        }
        if let cached = prewarmCache, environment.now() > cached.hit.capturedAt,
           environment.now() - cached.hit.capturedAt > Self.cacheFreshness { discardPrewarm() }
        if let gesture, gesture.fingerprint != environment.displayFingerprint() {
            environmentChanged(reason: "The display fingerprint changed.")
        }
    }

    func environmentChanged(reason: String) {
        environmentGeneration &+= 1
        discardPrewarm()
        pendingHover = nil
        cancel(reason: reason)
        invalidateKeyboard?()
    }

    func receive(_ event: DragInputEvent) {
        guard isRunning else { return }
        if event.kind == .overflow {
            stopMonitoring(reason: "Input queue overflow cancelled the gesture and stopped monitoring. Choose Retry.")
            return
        }
        if let inputEpoch, inputEpoch != event.epoch {
            stopMonitoring(reason: "An input epoch changed unexpectedly. Choose Retry.")
            return
        }
        inputEpoch = event.epoch
        guard event.sequence > lastSequence else { return }
        lastSequence = event.sequence
        if event.kind == .tapDisabled { monitorStatus(.interrupted("The event tap was disabled")); return }
        if event.kind == .escape { onAcceptedInput?(event); cancel(reason: "Escape cancelled the gesture."); return }
        if event.kind == .mouseMoved {
            guard gesture == nil, event.buttonMask == 0 else { return }
            lastHover = event
            pendingHover = event
            pumpCapture()
            return
        }
        if event.kind == .leftDown { begin(event); return }
        guard var current = gesture, event.gesture == current.inputID else { return }
        current.latest = event
        gesture = current
        onAcceptedInput?(event)
        guard let live = gesture, live.session == current.session, live.inputID == current.inputID else { return }
        switch event.kind {
        case .leftUp:
            lastHover = event
            finish()
        case .leftDragged:
            if current.firstMotion == nil { gesture?.firstMotion = event.firstDraggedTimestamp ?? event.timestamp }
            if current.hit != nil { requestFrame(event) }
        case .flagsChanged, .buttonChanged:
            append(machine.modifierUpdate(session: current.session, frame: current.frame))
        default: break
        }
    }
    private func begin(_ event: DragInputEvent) {
        cancel(reason: "A new mouse-down replaced the prior gesture.")
        sessionGeneration &+= 1
        var current = Gesture(session: sessionGeneration, inputID: event.gesture, down: event,
                              fingerprint: environment.displayFingerprint(), latest: event)
        pendingHover = nil
        if let cached = prewarmCache {
            if cached.hit.notificationsVerified, cached.hit.capturedAt < event.timestamp,
               event.timestamp - cached.hit.capturedAt <= Self.cacheFreshness,
               cached.hit.hitRegion.contains(event.location), cached.epoch == event.epoch,
               cached.environment == environmentGeneration, cached.fingerprint == current.fingerprint {
                current.baseline = cached.hit
                prewarmCache = nil
            } else { discardPrewarm() }
        }
        gesture = current
        onAcceptedInput?(event)
        guard gesture?.session == current.session, gesture?.inputID == current.inputID else { return }
        dragGateChanged?(true)
        pumpCapture()
    }
    private func canRetryValidation(_ value: Gesture) -> Bool {
        value.baseline != nil && value.validationRetries == 0 && value.latest.location != value.down.location
    }

    private func shouldRetrySnapshot(_ snapshot: DragWindowSnapshot, for value: Gesture) -> Bool {
        canRetryValidation(value) && (value.baseline?.token != snapshot.token || !snapshot.hitInTitleBar)
    }

    private func pumpCapture() {
        guard !captureInFlight, cleanupQueue.count < 2 else { return }
        guard let current = gesture else { pumpPrewarm(); return }
        guard current.hit == nil else { return }
        captureInFlight = true
        let session = current.session
        Task { @MainActor [weak self, reader] in
            guard let self else { return }
            defer {
                self.captureInFlight = false
                self.completeShutdownIfDrained()
                // Coalesced next-down request: only the latest surviving gesture.
                if let next = self.gesture, next.hit == nil, next.session != session || next.validationRetries == 1 { self.pumpCapture() }
            }
            guard self.gesture?.session == session else { return }
            do {
                let point = current.validationRetries == 0 ? current.down.location : current.latest.location
                let hit = try await reader.window(at: point, ownPID: self.ownPID, downTimestamp: current.down.timestamp)
                guard var live = self.gesture, live.session == session, self.isRunning else {
                    self.queueRelease(hit.lease)
                    return
                }
                if let baseline = live.baseline {
                    if self.shouldRetrySnapshot(hit, for: live) {
                        self.queueRelease(hit.lease)
                        live.validationRetries = 1
                        self.gesture = live
                        return
                    }
                    guard self.validateCache(baseline, against: hit, down: live.down) else {
                        self.queueRelease(hit.lease)
                        guard self.gesture?.session == session else { return }
                        self.cancel(reason: "The prewarm target, size, or revision changed.")
                        return
                    }
                } else if let motion = live.firstMotion, hit.capturedAt >= motion {
                    self.queueRelease(hit.lease)
                    guard self.gesture?.session == session else { return }
                    self.cancel(reason: "The initial frame was unavailable before window movement.")
                    return
                }
                guard hit.hitInTitleBar else {
                    self.queueRelease(hit.lease)
                    self.cancel(reason: "The pointer did not hit a verified title-bar candidate.")
                    return
                }
                let originalFrame = live.baseline?.frame ?? hit.frame
                let oldBaselineLease = live.baseline?.lease
                live.baseline = nil
                live.hit = hit; live.frame = hit.frame; live.originalFrame = originalFrame
                self.gesture = live
                if let oldBaselineLease { self.queueRelease(oldBaselineLease) }
                self.append(self.machine.down(session: session, point: current.down.location, frame: originalFrame,
                                              titleBarHit: true, epoch: self.environmentGeneration))
                if live.firstMotion != nil { self.requestFrame(live.latest) }
            } catch {
                guard var live = self.gesture, live.session == session else { return }
                if self.canRetryValidation(live) {
                    live.validationRetries = 1
                    self.gesture = live
                    return
                }
                self.cancel(reason: "The window under the pointer could not be inspected: \(error.localizedDescription)")
            }
        }
    }

}

@MainActor
extension DragDetectionController {
    private func requestFrame(_ event: DragInputEvent) {
        guard let current = gesture, let hit = current.hit else { return }
        pendingFrameEvent = event
        guard frameInFlightID == nil else { return }
        frameRequestID &+= 1
        let request = frameRequestID
        frameInFlightID = request
        pendingFrameEvent = nil
        let session = current.session
        let point = event.location
        Task { @MainActor [weak self, reader] in
            guard let self else { return }
            defer {
                if self.frameInFlightID == request {
                    self.frameInFlightID = nil
                    self.completeShutdownIfDrained()
                    if let pending = self.pendingFrameEvent, let active = self.gesture, active.inputID == pending.gesture {
                        self.pendingFrameEvent = nil
                        self.requestFrame(pending)
                    } else {
                        self.pendingFrameEvent = nil
                    }
                }
            }
            guard self.gesture?.session == session else { return }
            do {
                let frame = try await reader.frame(for: hit.token, lease: hit.lease)
                guard self.gesture?.session == session, self.isRunning else { return }
                self.gesture?.frame = frame
                let events = self.machine.observe(session: session, point: point, frame: frame, epoch: self.environmentGeneration)
                if events.contains(where: { $0.kind == .cancelled }) {
                    let decorated = self.decorate(events, using: self.gesture)
                    self.detachGesture()
                    self.publish(decorated)
                } else { self.append(events) }
            } catch {
                guard self.gesture?.session == session else { return }
                self.cancel(reason: "The dragged window became unavailable: \(error.localizedDescription)")
            }
        }
    }

    private func finish() {
        let events = machine.finish()
        let terminal = decorate(events, using: gesture)
        var transferredLease: DragLeaseID?
        if events.last?.kind == .ended, let current = gesture,
           let hit = current.hit, let original = current.originalFrame {
            let context = DragCommitContext(run: runGeneration, session: current.session,
                                            event: current.latest, token: hit.token,
                                            sourceLease: hit.lease, originalFrame: original,
                                            displayFingerprint: current.fingerprint)
            if onWillEnd?(context) == true { transferredLease = hit.lease }
        }
        detachGesture(transferring: transferredLease)
        publish(terminal)
    }

    private func cancel(reason: String) {
        var emitted = machine.cancel(reason: reason)
        if emitted.isEmpty, let current = gesture {
            emitted = [DragLifecycleEvent(kind: .cancelled, session: current.session, frame: nil, reason: reason)]
        }
        let terminal = decorate(emitted, using: gesture)
        onCommitCancelled?(reason)
        detachGesture()
        publish(terminal)
    }

    private func detachGesture(transferring: DragLeaseID? = nil) {
        let oldLease = gesture?.hit?.lease
        let baselineLease = gesture?.baseline?.lease
        gesture = nil
        sessionGeneration &+= 1
        pendingFrameEvent = nil
        // The old AX task retains its in-flight slot until it returns. A new
        // gesture cannot enqueue unbounded reads behind that task.
        dragGateChanged?(false)
        if let oldLease, oldLease != transferring { queueRelease(oldLease) }
        if let baselineLease { queueRelease(baselineLease) }
    }

}

@MainActor
extension DragDetectionController {
    private func discardPrewarm() {
        let old = prewarmCache?.hit.lease
        prewarmCache = nil
        if let old { queueRelease(old) }
    }

    private func validateCache(_ cached: DragWindowSnapshot, against live: DragWindowSnapshot, down: DragInputEvent) -> Bool {
        guard cached.token == live.token, live.notificationsVerified, live.hitInTitleBar,
              abs(cached.frame.width - live.frame.width) <= 2, abs(cached.frame.height - live.frame.height) <= 2 else { return false }
        guard live.revision >= cached.revision else { return false }
        let changes = live.revisionChanges.filter { $0.revision > cached.revision }
        guard UInt64(changes.count) == live.revision - cached.revision else { return false }
        if changes.contains(where: { $0.kind != .moved || $0.timestamp <= down.timestamp }) { return false }
        return true
    }

    private func pumpPrewarm() {
        guard !captureInFlight, cleanupQueue.count < 2, let hover = pendingHover, hover.buttonMask == 0, isRunning,
              environment.inputGranted(), environment.accessibilityGranted() else { return }
        guard hover.timestamp >= lastPrewarmRequest, hover.timestamp - lastPrewarmRequest >= Self.prewarmInterval else { return }
        pendingHover = nil
        lastPrewarmRequest = hover.timestamp
        captureInFlight = true
        let run = runGeneration
        let environmentEpoch = environmentGeneration
        let fingerprint = environment.displayFingerprint()
        Task { @MainActor [weak self, reader] in
            guard let self else { return }
            defer {
                self.captureInFlight = false
                self.completeShutdownIfDrained()
                if self.gesture?.hit == nil, self.gesture != nil { self.pumpCapture() } else if self.gesture == nil { self.pumpPrewarm() }
            }
            do {
                let hit = try await reader.window(at: hover.location, ownPID: self.ownPID, downTimestamp: hover.timestamp)
                guard self.isRunning, self.runGeneration == run, self.environmentGeneration == environmentEpoch,
                      self.gesture == nil, self.environment.displayFingerprint() == fingerprint,
                      hit.notificationsVerified, hit.hitInTitleBar else {
                    self.queueRelease(hit.lease)
                    return
                }
                self.discardPrewarm()
                self.prewarmCache = PrewarmCache(hit: hit, point: hover.location, epoch: hover.epoch, environment: environmentEpoch, fingerprint: fingerprint)
            } catch {
                // Hover is best effort and does not prompt or alter input.
            }
        }
    }

    private var resourcesDrained: Bool { !captureInFlight && frameInFlightID == nil && cleanupQueue.isEmpty }

    private func completeShutdownIfDrained() {
        guard resourcesDrained else { return }
        let waiting = shutdownWaiters
        shutdownWaiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }

    private func queueRelease(_ lease: DragLeaseID) {
        guard !cleanupQueue.contains(lease) else { return }
        // Capture backpressure at two cleanup entries reserves room for the
        // single in-flight capture plus the frozen baseline. Maximum: four.
        cleanupQueue.append(lease)
        pumpCleanup()
    }

    private func pumpCleanup() {
        guard !cleanupInFlight, let oldLease = cleanupQueue.first else { return }
        cleanupInFlight = true
        Task { @MainActor [self, reader] in
            await reader.releaseDragLease(oldLease)
            cleanupQueue.removeAll { $0 == oldLease }
            cleanupInFlight = false
            completeShutdownIfDrained()
            pumpCleanup()
            if isRunning { pumpCapture() }
        }
    }

    private func append(_ events: [DragLifecycleEvent]) {
        publish(decorate(events, using: gesture))
    }

    private func decorate(_ events: [DragLifecycleEvent], using context: Gesture?) -> [DragLifecycleEvent] {
        events.map { value in
            var result = value
            result.token = context?.hit?.token
            result.point = context?.latest.location ?? .zero
            result.flags = context?.latest.flags ?? 0
            result.buttonMask = context?.latest.buttonMask ?? 0
            result.displayFingerprint = context?.fingerprint ?? ""
            return result
        }
    }

    private func publish(_ decorated: [DragLifecycleEvent]) {
        lifecycleEvents.append(contentsOf: decorated)
        if lifecycleEvents.count > 256 { lifecycleEvents.removeFirst(lifecycleEvents.count - 256) }
        for event in decorated {
            if event.kind == .began || event.kind == .updated,
               gesture?.session != event.session { continue }
            onLifecycle?(event)
        }
        if let reason = decorated.last?.reason { statusMessage = reason }
    }
}
