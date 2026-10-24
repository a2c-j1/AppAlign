import CoreGraphics
import Foundation

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
            guard let window = environment.downWindow(event.location, ownPID), window.windowID != nil else { return }
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
        guard var current = windowServerGesture, current.dragged,
              let id = current.window.windowID else { return false }
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
        guard current.moving, let id = current.window.windowID,
              let finalFrame = environment.windowFrame(id, current.window.pid) else {
            cancelWindowServer(reason: "The gesture did not become a window move.")
            return
        }
        let delta = CGPoint(x: finalFrame.minX - current.window.frame.minX,
                            y: finalFrame.minY - current.window.frame.minY)
        let path = current.path.recent(now: environment.now())
        let pointerDelta = DragPointerPath.closestDelta(to: delta, down: current.down.location, points: path)
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
                let hit = try await reader.window(at: point, ownPID: self.ownPID,
                                                 downTimestamp: current.down.timestamp)
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
