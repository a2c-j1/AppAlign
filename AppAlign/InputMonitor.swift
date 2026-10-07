import CoreGraphics
import Foundation

struct InputMonitorGeneration: Sendable {
    private(set) var value: UInt64 = 0
    private(set) var active = false

    mutating func start() -> UInt64 {
        value &+= 1
        active = true
        return value
    }

    mutating func stop() {
        value &+= 1
        active = false
    }

    func accepts(_ generation: UInt64) -> Bool { active && value == generation }
}

private final class InputTapContext {
    let monitor: InputMonitorCore
    let generation: UInt64

    init(monitor: InputMonitorCore, generation: UInt64) {
        self.monitor = monitor
        self.generation = generation
    }
}

struct InputMonitorPayload: Sendable {
    let kind: DragInputKind
    let location: CGPoint
    let flags: UInt64
    let button: Int64
    let timestamp: UInt64
    let generation: UInt64
    let eventType: CGEventType
}

protocol InputTapResource: AnyObject, Sendable {
    func enable() -> Bool
    func run()
    func stop()
    func invalidate()
}

struct InputTapResourceFactory: Sendable {
    let make: @Sendable (InputMonitorCore, UInt64) -> (any InputTapResource)?

    static let live = InputTapResourceFactory { core, generation in
        CGEventTapResource(core: core, generation: generation)
    }
}

private final class CGEventTapResource: InputTapResource, @unchecked Sendable {
    private let tap: CFMachPort
    private let source: CFRunLoopSource
    private let runLoop: CFRunLoop
    private let context: InputTapContext
    private let lock = NSLock()
    private var invalidated = false
    private var stopped = false

    init?(core: InputMonitorCore, generation: UInt64) {
        var mask = CGEventMask(0)
        let subscribedTypes: [CGEventType] = [
            .leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved,
            .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .flagsChanged, .keyDown
        ]
        for type in subscribedTypes where type.rawValue < 64 {
            mask |= CGEventMask(1) << type.rawValue
        }
        context = InputTapContext(monitor: core, generation: generation)
        let userInfo = Unmanaged.passUnretained(context).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: mask,
                                          callback: inputTapCallback, userInfo: userInfo) else { return nil }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, source, .commonModes)
    }

    func enable() -> Bool {
        CGEvent.tapEnable(tap: tap, enable: true)
        return CGEvent.tapIsEnabled(tap: tap)
    }

    func run() {
        lock.lock()
        let shouldRun = !stopped
        lock.unlock()
        guard shouldRun else {
            invalidate()
            return
        }
        withExtendedLifetime(context) {
            CFRunLoopRun()
            invalidate()
        }
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        lock.unlock()
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            CFRunLoopStop(self.runLoop)
        }
        CFRunLoopWakeUp(runLoop)
    }

    func invalidate() {
        lock.lock()
        guard !invalidated else { lock.unlock(); return }
        invalidated = true
        lock.unlock()
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        CFMachPortInvalidate(tap)
    }
}

@MainActor
final class InputMonitor: DragInputMonitoring {
    private let core = InputMonitorCore()

    func start(
        onEvent: @escaping @MainActor @Sendable (DragInputEvent) -> Void,
        onStatus: @escaping @MainActor @Sendable (DragMonitorStatus) -> Void
    ) {
        core.start(onEvent: onEvent, onStatus: onStatus)
    }

    func stop() {
        core.stop()
    }

    deinit { core.stop() }
}

final class InputMonitorCore: @unchecked Sendable {
    private let resourceFactory: InputTapResourceFactory
    private let lock = NSLock()
    private var lifecycle = InputMonitorGeneration()
    private var stopping = true
    private var resource: (any InputTapResource)?
    private var thread: Thread?
    private var mailbox = DragMailbox(capacity: 256)
    private var drainScheduled = false
    private var buttonMask: UInt64 = 0
    private var onEvent: (@MainActor @Sendable (DragInputEvent) -> Void)?
    private var onStatus: (@MainActor @Sendable (DragMonitorStatus) -> Void)?
    private var interruptionReason: String?

    init(resourceFactory: InputTapResourceFactory = .live) {
        self.resourceFactory = resourceFactory
    }

    func start(
        onEvent: @escaping @MainActor @Sendable (DragInputEvent) -> Void,
        onStatus: @escaping @MainActor @Sendable (DragMonitorStatus) -> Void
    ) {
        lock.lock()
        guard stopping else { lock.unlock(); return }
        let requestedGeneration = lifecycle.start()
        stopping = false
        mailbox = DragMailbox(capacity: 256)
        interruptionReason = nil
        drainScheduled = false
        buttonMask = 0
        self.onEvent = onEvent
        self.onStatus = onStatus
        let worker = Thread { [weak self] in self?.runTap(generation: requestedGeneration) }
        worker.name = "AppAlign.InputMonitor"
        thread = worker
        lock.unlock()
        worker.start()
    }

    func stop() {
        lock.lock()
        lifecycle.stop()
        stopping = true
        let currentResource = resource
        resource = nil
        thread = nil
        onEvent = nil
        onStatus = nil
        mailbox = DragMailbox(capacity: 256)
        interruptionReason = nil
        drainScheduled = false
        buttonMask = 0
        lock.unlock()
        currentResource?.stop()
    }

    private func runTap(generation requestedGeneration: UInt64) {
        lock.lock()
        let mayStart = !stopping && lifecycle.accepts(requestedGeneration)
        lock.unlock()
        guard mayStart else { return }
        guard let newResource = resourceFactory.make(self, requestedGeneration) else {
            deliverStatus(.failed("macOS could not create the listen-only event tap. Check Input Monitoring permission and choose Retry."), generation: requestedGeneration)
            return
        }
        lock.lock()
        guard !stopping && lifecycle.accepts(requestedGeneration) else {
            lock.unlock()
            newResource.stop()
            newResource.invalidate()
            return
        }
        resource = newResource
        lock.unlock()

        guard newResource.enable() else {
            lock.lock()
            if lifecycle.accepts(requestedGeneration) {
                resource = nil
                thread = nil
            }
            lock.unlock()
            newResource.stop()
            newResource.invalidate()
            deliverStatus(.failed("macOS did not enable the listen-only event tap. Check Input Monitoring permission and choose Retry."), generation: requestedGeneration)
            return
        }

        lock.lock()
        let remainsCurrent = !stopping && lifecycle.accepts(requestedGeneration) && resource === newResource
        lock.unlock()
        guard remainsCurrent else {
            newResource.stop()
            newResource.invalidate()
            return
        }

        deliverStatus(.ready, generation: requestedGeneration)
        newResource.run()
        lock.lock()
        if lifecycle.accepts(requestedGeneration), resource === newResource {
            resource = nil
            thread = nil
        }
        lock.unlock()
    }

    fileprivate func receive(type: CGEventType, event: CGEvent, generation requestedGeneration: UInt64) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let reason = type == .tapDisabledByTimeout ? "timeout" : "user-input-disabled"
            interrupt(reason: reason, generation: requestedGeneration)
            return
        }
        let kind: DragInputKind
        switch type {
        case .leftMouseDown: kind = .leftDown
        case .leftMouseDragged: kind = .leftDragged
        case .leftMouseUp: kind = .leftUp
        case .mouseMoved: kind = .mouseMoved
        case .rightMouseDown, .otherMouseDown, .rightMouseUp, .otherMouseUp: kind = .buttonChanged
        case .flagsChanged: kind = .flagsChanged
        case .keyDown where event.getIntegerValueField(.keyboardEventKeycode) == 53: kind = .escape
        case .tapDisabledByTimeout, .tapDisabledByUserInput: return
        default: return
        }

        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        enqueue(InputMonitorPayload(kind: kind, location: event.location, flags: event.flags.rawValue,
                                     button: button, timestamp: event.timestamp,
                                     generation: requestedGeneration, eventType: type))
    }

    private func enqueue(_ payload: InputMonitorPayload) {
        lock.lock()
        guard !stopping, interruptionReason == nil, lifecycle.accepts(payload.generation) else { lock.unlock(); return }
        let bit = payload.button >= 0 && payload.button < 64 ? UInt64(1) << UInt64(payload.button) : 0
        switch payload.eventType {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: buttonMask |= bit
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: buttonMask &= ~bit
        default: break
        }
        if payload.kind == .mouseMoved, buttonMask != 0 {
            lock.unlock()
            return
        }
        mailbox.enqueue(
            kind: payload.kind,
            location: payload.location,
            flags: payload.flags,
            button: payload.button,
            timestamp: payload.timestamp,
            buttonMask: buttonMask
        )
        let shouldScheduleDrain = !drainScheduled
        drainScheduled = true
        let requestedGeneration = lifecycle.value
        lock.unlock()
        if shouldScheduleDrain {
            DispatchQueue.main.async { [weak self] in self?.drainMailbox(generation: requestedGeneration) }
        }
    }

    func accept(_ payload: InputMonitorPayload) {
        enqueue(payload)
    }

}

private extension InputMonitorCore {
    func drainMailbox(generation requestedGeneration: UInt64) {
        lock.lock()
        guard !stopping, lifecycle.accepts(requestedGeneration) else { lock.unlock(); return }
        let events = mailbox.drain()
        let overflowed = mailbox.overflowed
        let interruption = interruptionReason
        interruptionReason = nil
        drainScheduled = false
        let eventHandler = onEvent
        let statusHandler = onStatus
        lock.unlock()

        if overflowed || interruption != nil {
            if let statusHandler {
                MainActor.assumeIsolated {
                    let reason = interruption ?? "Input event queue overflowed. The gesture was cancelled and monitoring stopped; choose Retry to start a fresh gesture."
                    statusHandler(.interrupted(reason))
                }
            }
            stopFromDrain(generation: requestedGeneration)
            return
        }
        guard let eventHandler else { return }
        for event in events {
            MainActor.assumeIsolated { eventHandler(event) }
        }

        lock.lock()
        let needsAnotherDrain = !stopping && lifecycle.accepts(requestedGeneration) && !mailbox.events.isEmpty && !drainScheduled
        if needsAnotherDrain { drainScheduled = true }
        lock.unlock()
        if needsAnotherDrain {
            DispatchQueue.main.async { [weak self] in self?.drainMailbox(generation: requestedGeneration) }
        }
    }

    func stopFromDrain(generation requestedGeneration: UInt64) {
        lock.lock()
        guard lifecycle.accepts(requestedGeneration) else { lock.unlock(); return }
        let currentResource = resource
        stopping = true
        lifecycle.stop()
        resource = nil
        thread = nil
        onEvent = nil
        onStatus = nil
        mailbox = DragMailbox(capacity: 256)
        interruptionReason = nil
        drainScheduled = false
        buttonMask = 0
        lock.unlock()
        currentResource?.stop()
    }

    func deliverStatus(_ status: DragMonitorStatus, generation requestedGeneration: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let accepted = !self.stopping && self.lifecycle.accepts(requestedGeneration)
            let handler = self.onStatus
            self.lock.unlock()
            guard accepted, let handler else { return }
            MainActor.assumeIsolated { handler(status) }
        }
    }

    func interrupt(reason: String, generation requestedGeneration: UInt64) {
        lock.lock()
        guard !stopping, lifecycle.accepts(requestedGeneration), interruptionReason == nil else { lock.unlock(); return }
        mailbox = DragMailbox(capacity: 256)
        interruptionReason = reason
        let shouldScheduleDrain = !drainScheduled
        drainScheduled = true
        lock.unlock()
        if shouldScheduleDrain {
            DispatchQueue.main.async { [weak self] in self?.drainMailbox(generation: requestedGeneration) }
        }
    }
}

private let inputTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let context = Unmanaged<InputTapContext>.fromOpaque(userInfo).takeUnretainedValue()
    context.monitor.receive(type: type, event: event, generation: context.generation)
    return Unmanaged.passUnretained(event)
}
