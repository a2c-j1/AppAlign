import AppKit
@preconcurrency import ApplicationServices
import Combine
import CoreGraphics
import Foundation

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
    var onWillResolveWindow: (@MainActor () -> Void)?
    var onAcceptedInput: (@MainActor (DragInputEvent) -> Void)?
    var onCommitCancelled: (@MainActor (String) -> Void)?

    struct WindowServerGesture {
        let session: UInt64
        let inputID: UInt64
        let down: DragInputEvent
        let window: DownWindowBaseline
        let fingerprint: String
        var latest: DragInputEvent
        var path = DragPointerPath()
        var frame: CGRect
        var dragged = false
        var moving = false
    }

    let reader: any DragWindowReading
    let environment: DragEnvironment
    let ownPID: pid_t
    var windowServerGesture: WindowServerGesture?
    var windowServerResolutionInFlight = false
    var sessionGeneration: UInt64 = 0
    var runGeneration: UInt64 = 0
    private let monitor: any DragInputMonitoring
    private let installsObservers: Bool
    private var inputEpoch: UInt64?
    private var lastSequence: UInt64 = 0
    private var quitPaused = false
    private var timeoutRetries = 0
    private var starting = false
    private var permissionTimer: Timer?
    private var observationTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var cleanupQueue: [DragLeaseID] = []
    private var cleanupInFlight = false
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

    init(reader: any DragWindowReading, monitor: (any DragInputMonitoring)? = nil,
         environment: DragEnvironment? = nil, displayProvider: DisplayProvider? = nil,
         ownPID: pid_t = ProcessInfo.processInfo.processIdentifier, installsObservers: Bool = true) {
        self.reader = reader
        self.monitor = monitor ?? InputMonitor()
        self.environment = environment ?? .live(displayProvider: displayProvider)
        self.ownPID = ownPID
        self.installsObservers = installsObservers
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        timeoutRetries = 0
        if !enabled { stopMonitoring(reason: "Window dragging detection was stopped."); return }
        guard !quitPaused else { return }
        guard environment.accessibilityGranted() else {
            statusMessage = "Accessibility lets AppAlign observe drags and inspect windows. Grant access, then choose Retry."
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
        if isEnabled { startMonitoring() }
    }
    func prepareForShutdown() async {
        shutdownForQuit()
        if !resourcesDrained { await withCheckedContinuation { shutdownWaiters.append($0) } }
    }

    private func startMonitoring() {
        guard isEnabled, !quitPaused, !isRunning, !starting else { return }
        guard environment.accessibilityGranted() else {
            statusMessage = "Accessibility is required. Choose Retry after granting access."
            return
        }
        guard environment.buttonsReleased() else {
            statusMessage = "Release mouse buttons, then choose Retry to begin a fresh gesture."
            return
        }
        runGeneration &+= 1
        let run = runGeneration
        inputEpoch = nil
        lastSequence = 0
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
            starting = false
            isRunning = true
            statusMessage = "Listening for window drags. Input is observed without suppression or injection."
            if installsObservers { installObservers(run: runGeneration) }
        case let .failed(reason):
            stopMonitoring(reason: "Drag monitoring could not start: \(reason). Choose Retry.")
        case let .interrupted(reason):
            stopMonitoring(reason: "Drag monitoring stopped: \(reason). Choose Retry.")
            if reason == "timeout", timeoutRetries == 0 {
                timeoutRetries += 1
                startMonitoring()
            }
        }
    }

    private func stopMonitoring(reason: String) {
        runGeneration &+= 1
        starting = false
        isRunning = false
        monitor.stop()
        permissionTimer?.invalidate(); permissionTimer = nil
        observationTimer?.invalidate(); observationTimer = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        inputEpoch = nil
        lastSequence = 0
        cancel(reason: reason)
        statusMessage = reason
    }

    private func installObservers(run: UInt64) {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let specs: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.didTerminateApplicationNotification),
            (.default, NSApplication.didChangeScreenParametersNotification),
            (.default, NSApplication.didBecomeActiveNotification)
        ]
        for (center, name) in specs {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                Task { @MainActor in
                    guard let self, self.runGeneration == run, self.isRunning else { return }
                    if name == NSWorkspace.didTerminateApplicationNotification,
                       pid != self.windowServerGesture?.window.pid { return }
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
        observationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.runGeneration == run, self.isRunning,
                      self.windowServerGesture != nil else { return }
                self.observeWindowServerFrame()
            }
        }
    }

    func checkHealth() {
        guard environment.accessibilityGranted() else {
            stopMonitoring(reason: "Accessibility permission was revoked. Choose Retry.")
            invalidateKeyboard?()
            return
        }
        if let current = windowServerGesture,
           current.fingerprint != environment.displayFingerprint() {
            environmentChanged(reason: "The display fingerprint changed.")
        }
    }

    func environmentChanged(reason: String) {
        sessionGeneration &+= 1
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
        receiveWindowServer(event)
    }

    func cancel(reason: String) {
        let hadGesture = windowServerGesture != nil
        cancelWindowServer(reason: reason)
        if !hadGesture { onCommitCancelled?(reason) }
    }

    private var resourcesDrained: Bool { !windowServerResolutionInFlight && cleanupQueue.isEmpty && !cleanupInFlight }

    func completeShutdownIfDrained() {
        guard resourcesDrained else { return }
        let waiting = shutdownWaiters
        shutdownWaiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }

    func queueRelease(_ lease: DragLeaseID) {
        guard !cleanupQueue.contains(lease) else { return }
        cleanupQueue.append(lease)
        pumpCleanup()
    }

    private func pumpCleanup() {
        guard !cleanupInFlight, let lease = cleanupQueue.first else { return }
        cleanupInFlight = true
        Task { @MainActor [self, reader] in
            await reader.releaseDragLease(lease)
            cleanupQueue.removeAll { $0 == lease }
            cleanupInFlight = false
            completeShutdownIfDrained()
            pumpCleanup()
        }
    }

    func publish(_ events: [DragLifecycleEvent]) {
        lifecycleEvents.append(contentsOf: events)
        if lifecycleEvents.count > 256 { lifecycleEvents.removeFirst(lifecycleEvents.count - 256) }
        for event in events {
            if event.kind == .began || event.kind == .updated,
               windowServerGesture?.session != event.session { continue }
            onLifecycle?(event)
        }
        if let reason = events.last?.reason { statusMessage = reason }
    }
}

@MainActor
extension DragDetectionController {
    func receiveWindowServer(_ event: DragInputEvent) {
        if event.kind == .escape {
            onAcceptedInput?(event)
            cancel(reason: "Escape cancelled the gesture.")
            return
        }
        if event.kind == .leftDown {
            cancel(reason: "A new mouse-down replaced the prior gesture.")
            sessionGeneration &+= 1
            onAcceptedInput?(event)
            guard let window = environment.downWindow(event.location, ownPID) else { return }
            var next = WindowServerGesture(session: sessionGeneration, inputID: event.gesture, down: event,
                                           window: window, fingerprint: environment.displayFingerprint(),
                                           latest: event, frame: window.frame)
            next.path.append(event)
            windowServerGesture = next
            dragGateChanged?(true)
            return
        }
        guard var current = windowServerGesture, current.inputID == event.gesture else { return }
        current.latest = event
        if event.kind == .leftDragged || event.kind == .leftUp { current.path.append(event) }
        if event.kind == .leftDragged { current.dragged = true }
        windowServerGesture = current
        onAcceptedInput?(event)
        guard windowServerGesture?.session == current.session else { return }
        switch event.kind {
        case .leftDragged:
            observeWindowServerFrame()
        case .flagsChanged, .buttonChanged:
            if current.moving { publishWindowServer(.updated, frame: current.frame) }
        case .leftUp:
            observeWindowServerFrame()
            finishWindowServer()
        default: break
        }
    }

    @discardableResult
    func observeWindowServerFrame() -> Bool {
        guard var current = windowServerGesture, current.dragged else { return false }
        let id = current.window.windowID
        guard let frame = environment.windowFrame(id, current.window.pid) else {
            cancelWindowServer(reason: "The dragged window disappeared.")
            return false
        }
        let original = current.window.frame
        guard abs(frame.width - original.width) <= 2, abs(frame.height - original.height) <= 2 else {
            cancelWindowServer(reason: "The dragged window changed size.")
            return false
        }
        let frameDelta = CGPoint(x: frame.minX - original.minX, y: frame.minY - original.minY)
        let path = current.path.recent(now: environment.now())
        let pointerDelta = DragPointerPath.closestDelta(to: frameDelta, down: current.down.location, points: path)
        let followsPointer = hypot(frameDelta.x - pointerDelta.x, frameDelta.y - pointerDelta.y) <= 12
        current.frame = frame
        windowServerGesture = current
        guard followsPointer, hypot(frameDelta.x, frameDelta.y) >= 3 else { return false }
        if !current.moving {
            windowServerGesture?.moving = true
            publishWindowServer(.began, frame: original)
        }
        publishWindowServer(.updated, frame: frame)
        return true
    }

    func finishWindowServer() {
        guard let current = windowServerGesture else { return }
        let id = current.window.windowID
        guard current.moving,
              let finalFrame = environment.windowFrame(id, current.window.pid) else {
            cancelWindowServer(reason: "The gesture did not become a window move.")
            return
        }
        let delta = CGPoint(x: finalFrame.minX - current.window.frame.minX,
                            y: finalFrame.minY - current.window.frame.minY)
        let pointerDelta = CGPoint(x: current.latest.location.x - current.down.location.x,
                                   y: current.latest.location.y - current.down.location.y)
        guard hypot(delta.x - pointerDelta.x, delta.y - pointerDelta.y) <= 12,
              abs(finalFrame.width - current.window.frame.width) <= 2,
              abs(finalFrame.height - current.window.frame.height) <= 2,
              !windowServerResolutionInFlight else {
            cancelWindowServer(reason: "The window did not follow the completed drag.")
            return
        }
        windowServerGesture = nil
        onWillResolveWindow?()
        windowServerResolutionInFlight = true
        let run = runGeneration
        let point = CGPoint(x: finalFrame.minX + current.down.location.x - current.window.frame.minX,
                            y: finalFrame.minY + current.down.location.y - current.window.frame.minY)
        guard environment.downWindow(point, ownPID)?.windowID == id else {
            windowServerResolutionInFlight = false
            dragGateChanged?(false)
            publishWindowServer(.cancelled, context: current,
                                 reason: "The dragged window is no longer under the pointer.")
            return
        }
        Task { @MainActor [weak self, reader] in
            guard let self else { return }
            defer {
                self.windowServerResolutionInFlight = false
                if self.sessionGeneration == current.session, self.windowServerGesture == nil {
                    self.dragGateChanged?(false)
                }
                self.completeShutdownIfDrained()
            }
            do {
                let hit = try await reader.window(at: point, ownPID: self.ownPID)
                guard self.runGeneration == run, self.sessionGeneration == current.session,
                      self.isRunning else {
                    self.queueRelease(hit.lease)
                    return
                }
                guard hit.token.pid == current.window.pid,
                      self.environment.downWindow(point, self.ownPID)?.windowID == id,
                      let liveFrame = self.environment.windowFrame(id, current.window.pid),
                      abs(liveFrame.minX - hit.frame.minX) <= 4,
                      abs(liveFrame.minY - hit.frame.minY) <= 4,
                      abs(liveFrame.width - hit.frame.width) <= 2,
                      abs(liveFrame.height - hit.frame.height) <= 2,
                      abs(liveFrame.minX - finalFrame.minX) <= 4,
                      abs(liveFrame.minY - finalFrame.minY) <= 4 else {
                    self.queueRelease(hit.lease)
                    self.publishWindowServer(.cancelled, context: current,
                                             reason: "The released window could not be identified.")
                    return
                }
                let commit = DragCommitContext(run: run, session: current.session, event: current.latest,
                                               token: hit.token, sourceLease: hit.lease,
                                               originalFrame: current.window.frame,
                                               displayFingerprint: current.fingerprint)
                if self.onWillEnd?(commit) != true { self.queueRelease(hit.lease) }
                self.publishWindowServer(.ended, context: current)
            } catch {
                guard self.runGeneration == run, self.sessionGeneration == current.session else { return }
                self.publishWindowServer(.cancelled, context: current,
                                         reason: "The released window could not be inspected: \(error.localizedDescription)")
            }
        }
    }

    func cancelWindowServer(reason: String) {
        guard let current = windowServerGesture else { return }
        windowServerGesture = nil
        dragGateChanged?(false)
        onCommitCancelled?(reason)
        publishWindowServer(.cancelled, context: current, reason: reason)
    }

    private func publishWindowServer(_ kind: DragLifecycleKind, frame: CGRect? = nil, context: WindowServerGesture? = nil,
                                     reason: String? = nil) {
        guard let current = context ?? windowServerGesture else { return }
        let event = DragLifecycleEvent(kind: kind, session: current.session, frame: frame, reason: reason,
                                       point: current.latest.location, flags: current.latest.flags,
                                       buttonMask: current.latest.buttonMask, displayFingerprint: current.fingerprint)
        publish([event])
    }
}
