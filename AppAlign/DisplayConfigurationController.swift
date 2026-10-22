import AppKit
import CoreGraphics
import Foundation

private struct ConfigurationRefreshRequest: Sendable {
    let id: UInt64
    let epoch: UInt64
    let revision: UInt64
    let displaySnapshot: DisplaySnapshot
    let spaceRequest: SpaceProviderRefreshRequest
    let deadline: UInt64
}

@MainActor
final class DisplayConfigurationController {
    struct Effects {
        let cancelDrag: @MainActor (String) -> Void
        let environmentChanged: @MainActor (String) -> Void
        let invalidateKeyboard: @MainActor () -> Void
        let invalidateManualCapture: @MainActor () -> Void
        let setConfigurationPending: @MainActor (Bool) -> Void
    }

    private struct ObserverRegistration {
        let center: NotificationCenter
        let token: NSObjectProtocol
    }
    private let layout: LayoutController
    private let validity: PlacementValidity
    private let effects: Effects
    private let appKitNotificationCenter: NotificationCenter
    private let workspaceNotificationCenter: NotificationCenter
    private let registerCoreGraphics: (UnsafeMutableRawPointer) -> CGError
    private let removeCoreGraphics: (UnsafeMutableRawPointer) -> CGError
    private let sampleDisplayConfiguration: @MainActor () -> DisplaySnapshot
    private let refreshDeadlineNanoseconds: UInt64
    private var observers: [ObserverRegistration] = []
    private var pollingTimer: Timer?
    private var sleeping = false
    private var pendingRevision: UInt64?
    private var callbackEpoch: UInt64 = 0
    private var lastHandledConfigurationRevision: UInt64 = 0
    private var handledSleepTransition: UInt64 = 0
    private var nextRefreshID: UInt64 = 0
    private var latestRefreshID: UInt64?
    private var runningRefresh: ConfigurationRefreshRequest?
    private var runningRefreshExpired = false
    private var pendingRefresh: ConfigurationRefreshRequest?
    private var refreshDeadlineTask: Task<Void, Never>?
    // A single userdata object stays strongly owned for the whole delegate lifetime.
    // During the Cancel Quit prompt it is deactivated, so callbacks become no-ops;
    // Cancel Quit reactivates it with a new epoch instead of allocating stale userdata.
    private let callbackContext: DisplayCallbackContext
    private var registeredWithCoreGraphics = false
    private(set) var monitoringDiagnostics: [String] = []
    var historyPermissionPollingSuspendedChanged: (@MainActor (Bool) -> Void)?
    var callbackContextIdentityForTesting: ObjectIdentifier { ObjectIdentifier(callbackContext) }
    var callbackEpochForTesting: UInt64 { callbackEpoch }

    init(layout: LayoutController, drag: DragSnapController, detection: DragDetectionController,
         keyboard: KeyboardSnapController, gate: DragKeyboardGate,
         refreshDeadlineNanoseconds: UInt64 = 1_000_000_000) {
        self.layout = layout
        validity = layout.placementValidity
        effects = Effects(cancelDrag: { drag.cancel(reason: $0) },
                          environmentChanged: { detection.environmentChanged(reason: $0) },
                          invalidateKeyboard: { keyboard.invalidatePendingOperations() },
                          invalidateManualCapture: { layout.invalidateManualCapture() },
                          setConfigurationPending: { gate.setConfigurationPending($0) })
        appKitNotificationCenter = .default
        workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
        registerCoreGraphics = { CGDisplayRegisterReconfigurationCallback(issue9DisplayReconfigured, $0) }
        removeCoreGraphics = { CGDisplayRemoveReconfigurationCallback(issue9DisplayReconfigured, $0) }
        sampleDisplayConfiguration = { layout.displayProvider.sample() }
        self.refreshDeadlineNanoseconds = refreshDeadlineNanoseconds
        callbackContext = DisplayCallbackContext(validity: layout.placementValidity, owner: nil)
        callbackContext.setOwner(self)
        layout.refreshConfiguration = { [weak self, weak layout] force in
            guard let layout else { return DisplaySnapshot(displays: [], primaryFrame: .zero) }
            return self?.refreshIfChanged(force: force) ?? layout.displayProvider.snapshot
        }
    }

    init(layout: LayoutController, effects: Effects,
         appKitNotificationCenter: NotificationCenter, workspaceNotificationCenter: NotificationCenter,
         registerCoreGraphics: @escaping (UnsafeMutableRawPointer) -> CGError,
         removeCoreGraphics: @escaping (UnsafeMutableRawPointer) -> CGError,
         sample: @escaping @MainActor () -> DisplaySnapshot,
         refreshDeadlineNanoseconds: UInt64 = 1_000_000_000) {
        self.layout = layout
        validity = layout.placementValidity
        self.effects = effects
        self.appKitNotificationCenter = appKitNotificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.registerCoreGraphics = registerCoreGraphics
        self.removeCoreGraphics = removeCoreGraphics
        sampleDisplayConfiguration = sample
        self.refreshDeadlineNanoseconds = refreshDeadlineNanoseconds
        callbackContext = DisplayCallbackContext(validity: layout.placementValidity, owner: nil)
        callbackContext.setOwner(self)
        layout.refreshConfiguration = { [weak self, weak layout] force in
            guard let layout else { return DisplaySnapshot(displays: [], primaryFrame: .zero) }
            return self?.refreshIfChanged(force: force) ?? layout.displayProvider.snapshot
        }
    }

    func start() {
        guard observers.isEmpty else { return }
        callbackEpoch &+= 1
        callbackContext.activate(epoch: callbackEpoch)
        lastHandledConfigurationRevision = validity.revision.configuration
        handledSleepTransition = callbackContext.state.sleepTransition
        let epoch = callbackEpoch
        let workspace = workspaceNotificationCenter
        let appKitCenter = appKitNotificationCenter
        observers.append(ObserverRegistration(center: appKitCenter, token: appKitCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil
        ) { [callbackContext] _ in
            guard let signal = callbackContext.signal(event: .displayChange, expectedEpoch: epoch) else { return }
            Task { @MainActor in callbackContext.deliver(event: .displayChange, revision: signal.revision, epoch: signal.epoch) }
        }))
        observers.append(ObserverRegistration(center: workspace, token: workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
        ) { [callbackContext] _ in
            guard let signal = callbackContext.signal(event: .sleep, expectedEpoch: epoch) else { return }
            Task { @MainActor in callbackContext.deliver(event: .sleep, revision: signal.revision, epoch: signal.epoch) }
        }))
        observers.append(ObserverRegistration(center: workspace, token: workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [callbackContext] _ in
            guard let signal = callbackContext.signal(event: .wake, expectedEpoch: epoch) else { return }
            Task { @MainActor in callbackContext.deliver(event: .wake, revision: signal.revision, epoch: signal.epoch) }
        }))
        layout.spaceProvider.start { [callbackContext] in
            guard let signal = callbackContext.signal(event: .spaceChange, expectedEpoch: epoch) else { return }
            Task { @MainActor in callbackContext.deliver(event: .spaceChange, revision: signal.revision, epoch: signal.epoch) }
        }
        if !registeredWithCoreGraphics {
            if registerCoreGraphics(Unmanaged.passUnretained(callbackContext).toOpaque()) != .success {
                recordMonitoringDiagnostic("CoreGraphics display reconfiguration callback registration failed.")
            } else {
                registeredWithCoreGraphics = true
            }
        }
        let revision = beginInvalidation()
        enqueueRefresh(sampleDisplayConfiguration(), revision: revision)
        startPolling()
    }

    func shutdown() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        callbackEpoch &+= 1
        invalidateRefreshRequests()
        callbackContext.deactivate()
        for observer in observers { observer.center.removeObserver(observer.token) }
        observers.removeAll()
        layout.spaceProvider.stop()
        _ = beginInvalidation()
    }

    func dispose() {
        shutdown()
        // The context remains alive until CoreGraphics has removed its registration.
        if registeredWithCoreGraphics {
            if removeCoreGraphics(Unmanaged.passUnretained(callbackContext).toOpaque()) == .success {
                registeredWithCoreGraphics = false
            } else {
                recordMonitoringDiagnostic("CoreGraphics display reconfiguration callback removal failed; callback context remains retained.")
            }
        }
    }

    func cancelQuit() {
        sleeping = false
        historyPermissionPollingSuspendedChanged?(false)
        start()
    }

    private func beginInvalidation(revision: UInt64? = nil) -> UInt64 {
        let revision = revision ?? validity.invalidateForConfigurationChange()
        invalidateRefreshRequests()
        layout.cancelAutomaticRestores?()
        effects.invalidateManualCapture()
        pendingRevision = revision
        effects.setConfigurationPending(true)
        effects.invalidateKeyboard()
        effects.cancelDrag("The display configuration changed.")
        effects.environmentChanged("The display configuration changed.")
        return revision
    }
}

@MainActor
extension DisplayConfigurationController {
    private func refreshAfterSignal(revision: UInt64? = nil) {
        guard callbackContext.isActive, !sleeping, !callbackContext.isSleeping,
              !callbackContext.isAwaitingCompletion else { return }
        let revision = revision ?? pendingRevision ?? beginInvalidation()
        _ = beginInvalidation(revision: revision)
        enqueueRefresh(sampleDisplayConfiguration(), revision: revision)
    }

    private func refreshIfChanged(force: Bool = false) -> DisplaySnapshot {
        guard callbackContext.isActive, !sleeping, !callbackContext.isSleeping else { return layout.displayProvider.snapshot }
        let sampled = sampleDisplayConfiguration()
        guard !callbackContext.isAwaitingCompletion else { return layout.displayProvider.snapshot }
        if !force, sampled == layout.displayProvider.snapshot {
            if let revision = pendingRevision, !hasOutstandingRefresh(matching: sampled) {
                enqueueRefresh(sampled, revision: revision)
            }
            return layout.displayProvider.snapshot
        }
        if !force, hasOutstandingRefresh(matching: sampled) { return layout.displayProvider.snapshot }
        let revision = beginInvalidation()
        enqueueRefresh(sampled, revision: revision)
        return layout.displayProvider.snapshot
    }

    private func enqueueRefresh(_ sampled: DisplaySnapshot, revision: UInt64) {
        guard callbackContext.isActive else { return }
        nextRefreshID &+= 1
        let id = nextRefreshID
        let now = DispatchTime.now().uptimeNanoseconds
        let deadline = now &+ refreshDeadlineNanoseconds
        let displays = sampled.displays.compactMap { $0.persistentID?.uuid }
        let request = ConfigurationRefreshRequest(id: id, epoch: callbackEpoch, revision: revision,
                                                  displaySnapshot: sampled,
                                                  spaceRequest: layout.spaceProvider.makeRefreshRequest(displays: displays),
                                                  deadline: deadline)
        latestRefreshID = id
        refreshDeadlineTask?.cancel()
        refreshDeadlineTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: self?.remaining(until: deadline) ?? 0) } catch { return }
            self?.expireRefresh(id: id)
        }
        if runningRefresh == nil {
            startRefresh(request)
        } else {
            pendingRefresh = request
        }
    }

    private func startRefresh(_ request: ConfigurationRefreshRequest) {
        guard runningRefresh == nil else {
            pendingRefresh = request
            return
        }
        guard isEligible(request), DispatchTime.now().uptimeNanoseconds < request.deadline else {
            expireRefresh(id: request.id, request: request)
            return
        }
        runningRefresh = request
        runningRefreshExpired = false
        let spaceProvider = layout.spaceProvider
        Task { @MainActor [weak self, spaceProvider] in
            let candidate = await spaceProvider.readCandidate(for: request.spaceRequest, deadline: request.deadline)
            self?.finishRefresh(request, candidate: candidate)
        }
    }

    private func finishRefresh(_ request: ConfigurationRefreshRequest, candidate: SpaceProviderCandidate) {
        guard runningRefresh?.id == request.id else { return }
        let wasExpired = runningRefreshExpired
        runningRefresh = nil
        runningRefreshExpired = false

        if !wasExpired, DispatchTime.now().uptimeNanoseconds < request.deadline,
           latestRefreshID == request.id, isEligible(request) {
            _ = publish(request, candidate: candidate)
        } else if !wasExpired, latestRefreshID == request.id,
                  DispatchTime.now().uptimeNanoseconds >= request.deadline {
            expireRefresh(id: request.id, request: request)
        }
        startPendingRefreshIfPossible()
    }

    private func startPendingRefreshIfPossible() {
        guard runningRefresh == nil, let request = pendingRefresh else { return }
        pendingRefresh = nil
        guard latestRefreshID == request.id, isEligible(request) else { return }
        if DispatchTime.now().uptimeNanoseconds >= request.deadline {
            expireRefresh(id: request.id, request: request)
        } else {
            startRefresh(request)
        }
    }

    private func expireRefresh(id: UInt64, request suppliedRequest: ConfigurationRefreshRequest? = nil) {
        guard latestRefreshID == id,
              let request = suppliedRequest ?? (runningRefresh?.id == id ? runningRefresh : pendingRefresh?.id == id ? pendingRefresh : nil)
        else { return }
        if runningRefresh?.id == id { runningRefreshExpired = true }
        if pendingRefresh?.id == id { pendingRefresh = nil }
        refreshDeadlineTask?.cancel()
        refreshDeadlineTask = nil
        guard isEligible(request) else { latestRefreshID = nil; return }
        _ = publish(request, candidate: layout.spaceProvider.fallbackCandidate(for: request.spaceRequest),
                    deadlineFallback: true)
    }

    private func publish(_ request: ConfigurationRefreshRequest, candidate: SpaceProviderCandidate,
                         deadlineFallback: Bool = false) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        guard isEligible(request), deadlineFallback ? now >= request.deadline : now < request.deadline,
              sampleDisplayConfiguration() == request.displaySnapshot,
              layout.spaceProvider.publish(candidate, for: request.spaceRequest) else { return false }
        layout.displayProvider.publish(request.displaySnapshot)
        layout.displaysDidPublish(request.displaySnapshot)
        guard isEligible(request), validity.publishConfiguration(revision: request.revision) else { return false }
        refreshDeadlineTask?.cancel()
        refreshDeadlineTask = nil
        latestRefreshID = nil
        pendingRevision = nil
        effects.setConfigurationPending(false)
        return true
    }

    private func isEligible(_ request: ConfigurationRefreshRequest) -> Bool {
        callbackContext.isActive && latestRefreshID == request.id && request.epoch == callbackEpoch && pendingRevision == request.revision &&
            validity.revision.configuration == request.revision && !sleeping && !callbackContext.isSleeping &&
            !callbackContext.isAwaitingCompletion
    }

    private func hasOutstandingRefresh(matching sampled: DisplaySnapshot) -> Bool {
        let outstanding = pendingRefresh ?? runningRefresh
        return outstanding?.id == latestRefreshID && outstanding?.revision == pendingRevision &&
            outstanding?.displaySnapshot == sampled
    }

    private func invalidateRefreshRequests() {
        latestRefreshID = nil
        pendingRefresh = nil
        refreshDeadlineTask?.cancel()
        refreshDeadlineTask = nil
        if runningRefresh != nil { runningRefreshExpired = true }
    }

    private func remaining(until deadline: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        return deadline > now ? deadline - now : 0
    }

    private func startPolling() {
        guard pollingTimer == nil, !sleeping, !callbackContext.isSleeping else { return }
        let epoch = callbackEpoch
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.callbackEpoch == epoch else { return }
                _ = self.refreshIfChanged()
            }
        }
    }

    private func recordMonitoringDiagnostic(_ message: String) {
        guard !monitoringDiagnostics.contains(message) else { return }
        if monitoringDiagnostics.count >= 4 { monitoringDiagnostics.removeFirst() }
        monitoringDiagnostics.append(message)
        NSLog("[AppAlign] %@", message)
    }

    fileprivate func receiveSignal(event: DisplayCallbackContext.Event, revision _: UInt64, epoch: UInt64) {
        guard callbackEpoch == epoch else { return }
        let state = callbackContext.state
        guard state.epoch == epoch else { return }
        let currentRevision = state.configurationRevision
        if lastHandledConfigurationRevision != currentRevision {
            lastHandledConfigurationRevision = currentRevision
            _ = beginInvalidation(revision: currentRevision)
        }

        if handledSleepTransition != state.sleepTransition {
            handledSleepTransition = state.sleepTransition
            sleeping = state.sleeping
            if sleeping {
                historyPermissionPollingSuspendedChanged?(true)
                pollingTimer?.invalidate()
                pollingTimer = nil
                return
            }
            historyPermissionPollingSuspendedChanged?(false)
            refreshAfterSignal(revision: currentRevision)
            startPolling()
            return
        }

        guard !state.sleeping else { return }
        switch event {
        case .begin: break
        case .displayChange, .spaceChange: refreshAfterSignal(revision: currentRevision)
        case .sleep: break
        case .wake: refreshAfterSignal(revision: currentRevision)
        case .complete: refreshAfterSignal(revision: currentRevision)
        }
    }

    func beginConfigurationForTesting() {
        guard let signal = callbackContext.signal(event: .begin) else { return }
        receiveSignal(event: .begin, revision: signal.revision, epoch: signal.epoch)
    }

    func completeConfigurationForTesting() {
        guard let signal = callbackContext.signal(event: .complete) else { return }
        receiveSignal(event: .complete, revision: signal.revision, epoch: signal.epoch)
    }

    func pollForTesting() { _ = refreshIfChanged() }

    func deliverStaleCallbackForTesting(revision: UInt64, epoch: UInt64) {
        callbackContext.deliver(event: .complete, revision: revision, epoch: epoch)
    }

    func signalStaleObserverForTesting(expectedEpoch: UInt64) -> Bool {
        callbackContext.signal(event: .displayChange, expectedEpoch: expectedEpoch) != nil
    }
}

private final class DisplayCallbackContext: @unchecked Sendable {
    enum Event: Sendable, Equatable { case begin, complete, displayChange, spaceChange, sleep, wake }
    struct State {
        let epoch: UInt64
        let configurationRevision: UInt64
        let awaitingCompletion: Bool
        let sleeping: Bool
        let sleepTransition: UInt64
    }
    private let lock = NSLock()
    private var active = true
    private var awaitingCompletion = false
    private var sleeping = false
    private var sleepTransition: UInt64 = 0
    let validity: PlacementValidity
    weak var owner: DisplayConfigurationController?
    private var epoch: UInt64 = 0

    init(validity: PlacementValidity, owner: DisplayConfigurationController?) {
        self.validity = validity
        self.owner = owner
    }

    func setOwner(_ owner: DisplayConfigurationController) { lock.withLock { self.owner = owner } }
    func activate(epoch: UInt64) {
        lock.withLock {
            self.epoch = epoch
            awaitingCompletion = false
            sleeping = false
            sleepTransition &+= 1
            active = true
        }
    }
    var state: State {
        lock.withLock {
            State(epoch: epoch, configurationRevision: validity.revision.configuration,
                  awaitingCompletion: awaitingCompletion, sleeping: sleeping,
                  sleepTransition: sleepTransition)
        }
    }
    var isAwaitingCompletion: Bool { lock.withLock { awaitingCompletion } }
    var isSleeping: Bool { lock.withLock { sleeping } }
    var isActive: Bool { lock.withLock { active } }

    func signal(event: Event, expectedEpoch: UInt64? = nil) -> (revision: UInt64, epoch: UInt64)? {
        lock.withLock {
            guard active, expectedEpoch == nil || epoch == expectedEpoch else { return nil }
            if event == .begin { awaitingCompletion = true }
            if event == .complete { awaitingCompletion = false }
            if event == .sleep, !sleeping { sleeping = true; sleepTransition &+= 1 }
            if event == .wake, sleeping { sleeping = false; sleepTransition &+= 1 }
            return (validity.invalidateForConfigurationChange(), epoch)
        }
    }

    func deactivate() { lock.withLock { active = false; awaitingCompletion = false } }

    @MainActor
    func deliver(event: Event, revision: UInt64, epoch: UInt64) {
        let state = lock.withLock { (active, self.epoch) }
        guard state.0, state.1 == epoch else { return }
        owner?.receiveSignal(event: event, revision: revision, epoch: epoch)
    }
}

func issue9DisplayReconfigured(_ display: CGDirectDisplayID,
                               _ flags: CGDisplayChangeSummaryFlags,
                               _ userInfo: UnsafeMutableRawPointer?) {
    guard let userInfo else { return }
    let context = Unmanaged<DisplayCallbackContext>.fromOpaque(userInfo).takeUnretainedValue()
    let isBeginning = flags.contains(.beginConfigurationFlag)
    let event: DisplayCallbackContext.Event = isBeginning ? .begin : .complete
    guard let signal = context.signal(event: event) else { return }
    Task { @MainActor in context.deliver(event: event, revision: signal.revision, epoch: signal.epoch) }
}
