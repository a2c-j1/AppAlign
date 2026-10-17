import AppKit
import Combine
import Foundation

protocol NewWindowMonitorRuntime: WindowHistoryLeaseOperating, Sendable {
    func processGenerationForMonitoring(_ pid: pid_t, launchDate: Date) async -> UUID
    func observeWindowCreation(applicationPID pid: pid_t, processGeneration generation: UUID,
                               epoch: UInt64, signal: @escaping @Sendable (pid_t, UUID, UInt64) -> Void) async -> Bool
    func stopWindowObservation(applicationPID pid: pid_t, processGeneration generation: UUID) async
    func observedWindows(applicationPID pid: pid_t, processGeneration generation: UUID,
                         ownPID: pid_t, deadline: UInt64) async throws -> WindowObservationResult
    func retainMonitorSeenLease(_ token: RuntimeWindowToken, lease: RuntimeMonitorSeenLeaseID) async -> Bool
    func releaseMonitorSeenLease(_ token: RuntimeWindowToken, lease: RuntimeMonitorSeenLeaseID) async
    func discardProcess(_ pid: pid_t, expectedGeneration generation: UUID) async -> [RuntimeWindowToken]
}

extension NewWindowMonitorRuntime {
    func retainMonitorSeenLease(_ token: RuntimeWindowToken, lease: RuntimeMonitorSeenLeaseID) async -> Bool { false }
    func releaseMonitorSeenLease(_ token: RuntimeWindowToken, lease: RuntimeMonitorSeenLeaseID) async {}
}

struct MonitoredApplication: Hashable, Sendable {
    let pid: pid_t
    let bundleID: String?
    let launchDate: Date?
    let isTerminated: Bool
}

@MainActor
protocol NewWindowProcessProviding {
    func runningApplications() -> [MonitoredApplication]
    func application(processID: pid_t) -> MonitoredApplication?
}

extension AccessibilityWindowRuntime: NewWindowMonitorRuntime {}

struct NewWindowSignal: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case launch, terminate, created }
    let kind: Kind
    let pid: pid_t
    let generation: UUID?
    let launchDate: Date?
    let bundleID: String?
    var duringBaseline: Bool
    var afterBaseline: Bool
    let epoch: UInt64
}

private final class NewWindowBaselineGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func complete() {
        lock.lock()
        active = false
        lock.unlock()
    }
}

final class NewWindowSignalInbox: @unchecked Sendable {
    private let ticketRegistry: AutoRestoreTicketRegistry
    private let lock = NSLock()
    private var signals: [NewWindowSignal] = []
    private var drainScheduled = false
    private var currentEpoch: UInt64 = 0
    private var overflowedEpoch: UInt64?

    init(ticketRegistry: AutoRestoreTicketRegistry = AutoRestoreTicketRegistry()) {
        self.ticketRegistry = ticketRegistry
    }

    func enqueue(_ signal: NewWindowSignal) -> (shouldDrain: Bool, overflowed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard signal.epoch >= currentEpoch else { return (false, false) }
        if signal.epoch > currentEpoch {
            currentEpoch = signal.epoch
            signals.removeAll(keepingCapacity: true)
            overflowedEpoch = nil
        }
        if let index = signals.firstIndex(where: {
            $0.kind == signal.kind && $0.pid == signal.pid && $0.generation == signal.generation && $0.epoch == signal.epoch
        }) {
            if signal.kind == .created {
                signals[index].duringBaseline = signals[index].duringBaseline || signal.duringBaseline
                signals[index].afterBaseline = signals[index].afterBaseline || signal.afterBaseline
            }
            return (false, false)
        }
        guard signals.count < 128 else {
            let firstOverflow = overflowedEpoch != signal.epoch
            overflowedEpoch = signal.epoch
            let schedule = !drainScheduled
            drainScheduled = true
            if firstOverflow { ticketRegistry.invalidateAll() }
            return (schedule, firstOverflow)
        }
        signals.append(signal)
        guard !drainScheduled else { return (false, false) }
        drainScheduled = true
        return (true, false)
    }

    func takeBatch() -> (signals: [NewWindowSignal], overflowed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let result = (overflowedEpoch == currentEpoch ? [] : signals, overflowedEpoch == currentEpoch)
        signals.removeAll(keepingCapacity: true)
        return result
    }

    func finishDrain() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if !signals.isEmpty || overflowedEpoch == currentEpoch { return true }
        drainScheduled = false
        return false
    }

    func advanceEpoch(_ epoch: UInt64) {
        lock.lock()
        currentEpoch = max(currentEpoch, epoch)
        signals.removeAll(keepingCapacity: true)
        overflowedEpoch = nil
        lock.unlock()
    }
}

@MainActor
final class NewWindowMonitor {
    private struct ProcessState {
        let generation: UUID
        let launchDate: Date?
        let bundleID: String
        var baseline = true
        var restoreInitialWindows = false
        var seen = Set<RuntimeWindowToken>()
        var seenLeases: [RuntimeWindowToken: RuntimeMonitorSeenLeaseID] = [:]
        var dirtyDuringBaseline = false
        var observerVerified = false
    }

    private struct ProcessOperation {
        let pid: pid_t
        let generation: UUID
        let epoch: UInt64
    }

    private let layout: LayoutController
    private let runtime: any NewWindowMonitorRuntime
    private let processProvider: any NewWindowProcessProviding
    private let ownPID: pid_t
    private let workspace: NSWorkspace
    private let ticketRegistry: AutoRestoreTicketRegistry
    private let inbox: NewWindowSignalInbox
    private var observers: [NSObjectProtocol] = []
    private var processes: [pid_t: ProcessState] = [:]
    private var epoch: UInt64 = 0
    private var enabled = false
    private var drainRunning = false
    private var drainTask: Task<Void, Never>?
    private var cleanupTasks: [UUID: Task<Void, Never>] = [:]
    private var needsReconcile = false
    private var monitoringStartedAt = Date()
    private(set) var diagnostics: [String] = []
    private(set) var completedReconcileCount = 0
    private var restoreWasEnabled = false
    var onNewWindow: (@MainActor (WindowObservationCandidate, String) -> Void)?
    var onStop: (@MainActor () -> Void)?
    var onStart: (@MainActor () -> Void)?
    var onEnvironmentChanged: (@MainActor () -> Void)?
    var onProcessTerminating: (@MainActor (pid_t, UUID) -> Void)?
    var onWindowClosed: (@MainActor (RuntimeWindowToken) -> Void)?
    var observedProcessCount: Int { processes.count }
    var observedWindowCount: Int { processes.values.reduce(0) { $0 + $1.seen.count } }

    init(layout: LayoutController, runtime: any NewWindowMonitorRuntime,
         processProvider: any NewWindowProcessProviding = WorkspaceNewWindowProcessProvider(),
         ticketRegistry: AutoRestoreTicketRegistry = AutoRestoreTicketRegistry(),
         ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
         workspace: NSWorkspace = .shared) {
        self.layout = layout
        self.runtime = runtime
        self.processProvider = processProvider
        self.ticketRegistry = ticketRegistry
        inbox = NewWindowSignalInbox(ticketRegistry: ticketRegistry)
        self.ownPID = ownPID
        self.workspace = workspace
    }
}

@MainActor
extension NewWindowMonitor {
    func update(settings: AppHistorySettings, accessibilityAllowed: Bool) {
        if restoreWasEnabled && !settings.restoreNewWindows { onEnvironmentChanged?() }
        restoreWasEnabled = settings.restoreNewWindows
        let shouldRun = settings.monitorNewWindows && accessibilityAllowed
            && layout.appZoneHistoryAvailable && layout.persistenceReady
        guard shouldRun != enabled else { return }
        if shouldRun { start() } else { stop() }
    }

    func start() {
        guard !enabled, layout.appZoneHistoryAvailable, layout.persistenceReady else { return }
        enabled = true
        epoch &+= 1
        inbox.advanceEpoch(epoch)
        monitoringStartedAt = Date()
        onStart?()
        let expectedEpoch = epoch
        installWorkspaceObservers(epoch: expectedEpoch)
        needsReconcile = true
        drainInbox()
    }

    func stop() {
        guard enabled else { return }
        enabled = false
        epoch &+= 1
        inbox.advanceEpoch(epoch)
        for observer in observers { workspace.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        onStop?()
        let prior = processes
        processes.removeAll()
        for (pid, state) in prior {
            let cleanupID = UUID()
            let runtime = self.runtime
            cleanupTasks[cleanupID] = Task { [weak self] in
                await runtime.stopWindowObservation(applicationPID: pid, processGeneration: state.generation)
                for (token, lease) in state.seenLeases {
                    await runtime.releaseMonitorSeenLease(token, lease: lease)
                }
                self?.cleanupTasks.removeValue(forKey: cleanupID)
            }
        }
    }

    func drainForShutdown() async {
        stop()
        await drainTask?.value
        while !cleanupTasks.isEmpty {
            let pending = Array(cleanupTasks)
            for (id, task) in pending {
                await task.value
                cleanupTasks.removeValue(forKey: id)
            }
        }
    }

    private func drainInbox() {
        guard enabled, !drainRunning else { return }
        drainRunning = true
        drainTask = Task { @MainActor [weak self] in await self?.drainLoop() }
    }

    func receive(_ signal: NewWindowSignal) {
        let result = inbox.enqueue(signal)
        if result.shouldDrain { drainInbox() }
    }

    private func drainLoop() async {
        while enabled {
            let batch = inbox.takeBatch()
            if batch.overflowed {
                recordDiagnostic("Window notification capacity was exceeded; monitoring restarted with a fresh baseline.")
                await restartAfterOverflow()
                continue
            }
            if needsReconcile {
                needsReconcile = false
                let currentEpoch = epoch
                for application in processProvider.runningApplications().prefix(64) {
                    guard enabled, epoch == currentEpoch else { break }
                    await beginMonitoring(application, epoch: currentEpoch, isNewLaunch: false)
                }
            }
            for signal in batch.signals where enabled && signal.epoch == epoch {
                switch signal.kind {
                case .launch:
                    guard signal.launchDate.map({ $0 >= monitoringStartedAt }) == true,
                          let application = processProvider.application(processID: signal.pid),
                          application.launchDate == signal.launchDate else { continue }
                    await beginMonitoring(application, epoch: signal.epoch, isNewLaunch: true)
                case .terminate:
                    await terminate(pid: signal.pid, launchDate: signal.launchDate, epoch: signal.epoch)
                case .created:
                    guard let generation = signal.generation else { continue }
                    if signal.duringBaseline {
                        await reconcileWindows(pid: signal.pid, generation: generation, epoch: signal.epoch,
                                               isBaseline: true)
                    }
                    if signal.afterBaseline {
                        await reconcileWindows(pid: signal.pid, generation: generation, epoch: signal.epoch)
                    }
                }
            }
            if !inbox.finishDrain() { break }
        }
        drainRunning = false
        drainTask = nil
    }

    private func restartAfterOverflow() async {
        guard enabled else { return }
        epoch &+= 1
        let nextEpoch = epoch
        onEnvironmentChanged?()
        for observer in observers { workspace.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        let prior = processes
        processes.removeAll()
        inbox.advanceEpoch(nextEpoch)
        var mayRestart = true
        for (pid, state) in prior {
            await runtime.stopWindowObservation(applicationPID: pid, processGeneration: state.generation)
            mayRestart = mayRestart && enabled && epoch == nextEpoch
            for (token, lease) in state.seenLeases {
                await runtime.releaseMonitorSeenLease(token, lease: lease)
                mayRestart = mayRestart && enabled && epoch == nextEpoch
            }
        }
        guard mayRestart, enabled, epoch == nextEpoch else { return }
        installWorkspaceObservers(epoch: nextEpoch)
        needsReconcile = true
    }

    private func installWorkspaceObservers(epoch expectedEpoch: UInt64) {
        let center = workspace.notificationCenter
        let signalInbox = inbox
        observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                            object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let value = WorkspaceNewWindowProcessProvider.valueForNotification(app)
            let result = signalInbox.enqueue(NewWindowSignal(kind: .launch, pid: value.pid, generation: nil,
                                                             launchDate: value.launchDate, bundleID: value.bundleID, duringBaseline: false,
                                                             afterBaseline: true, epoch: expectedEpoch))
            if result.shouldDrain { Task { @MainActor [weak self] in self?.drainInbox() } }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                            object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let value = WorkspaceNewWindowProcessProvider.valueForNotification(app)
            let result = signalInbox.enqueue(NewWindowSignal(kind: .terminate, pid: value.pid, generation: nil,
                                                             launchDate: value.launchDate, bundleID: value.bundleID, duringBaseline: false,
                                                             afterBaseline: true, epoch: expectedEpoch))
            if result.shouldDrain { Task { @MainActor [weak self] in self?.drainInbox() } }
        })
        let ticketRegistry = self.ticketRegistry
        observers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            ticketRegistry.invalidateAll()
            Task { @MainActor [weak self] in self?.onEnvironmentChanged?() }
        })
    }

    func spaceChanged() {
        ticketRegistry.invalidateAll()
        onEnvironmentChanged?()
    }

    private func beginMonitoring(pid: pid_t, epoch expectedEpoch: UInt64, expectedLaunchDate: Date? = nil) async {
        guard let expectedLaunchDate,
              let application = processProvider.application(processID: pid), application.launchDate == expectedLaunchDate else { return }
        await beginMonitoring(application, epoch: expectedEpoch, isNewLaunch: true)
    }

    private func beginMonitoring(_ application: MonitoredApplication, epoch expectedEpoch: UInt64,
                                 isNewLaunch: Bool) async {
        let pid = application.pid
        guard enabled, epoch == expectedEpoch, pid != ownPID, !application.isTerminated,
              let launchDate = application.launchDate,
              let bundleID = application.bundleID, !bundleID.isEmpty else { return }
        if var existing = processes[pid], existing.launchDate == application.launchDate {
            guard isNewLaunch else { return }
            existing.restoreInitialWindows = true
            let staleLeases = existing.seenLeases
            existing.seen.removeAll()
            existing.seenLeases.removeAll()
            processes[pid] = existing
            for (token, lease) in staleLeases {
                await runtime.releaseMonitorSeenLease(token, lease: lease)
            }
            await reconcileWindows(pid: pid, generation: existing.generation, epoch: expectedEpoch, isBaseline: true)
            return
        }
        if let previous = processes.removeValue(forKey: pid) {
            onProcessTerminating?(pid, previous.generation)
            await runtime.stopWindowObservation(applicationPID: pid, processGeneration: previous.generation)
            let removedTokens = await runtime.discardProcess(pid, expectedGeneration: previous.generation)
            for token in removedTokens { layout.appProcessTerminated(token) }
            for (token, lease) in previous.seenLeases {
                await runtime.releaseMonitorSeenLease(token, lease: lease)
            }
        }
        guard processes.count < 64 else {
            recordDiagnostic("The 64-process observation limit was reached; additional apps are not monitored.")
            return
        }
        let generation = await runtime.processGenerationForMonitoring(pid, launchDate: launchDate)
        guard enabled, epoch == expectedEpoch,
              processProvider.application(processID: pid)?.launchDate == application.launchDate else { return }
        processes[pid] = ProcessState(generation: generation, launchDate: application.launchDate,
                                      bundleID: bundleID, restoreInitialWindows: isNewLaunch)
        let signalInbox = inbox
        let baselineGate = NewWindowBaselineGate()
        let verified = await runtime.observeWindowCreation(applicationPID: pid, processGeneration: generation,
                                                            epoch: expectedEpoch) { [weak self] pid, generation, epoch in
            let result = signalInbox.enqueue(NewWindowSignal(kind: .created, pid: pid, generation: generation,
                                                             launchDate: nil, bundleID: nil,
                                                             duringBaseline: baselineGate.isActive,
                                                             afterBaseline: !baselineGate.isActive,
                                                             epoch: epoch))
            if result.shouldDrain {
                Task { @MainActor [weak self] in self?.drainInbox() }
            }
        }
        guard enabled, epoch == expectedEpoch, var state = processes[pid], state.generation == generation else {
            await runtime.stopWindowObservation(applicationPID: pid, processGeneration: generation)
            return
        }
        state.observerVerified = verified
        processes[pid] = state
        if !verified { recordDiagnostic("Window creation notifications are unavailable for a running app; later windows may not be detected.") }
        await reconcileWindows(pid: pid, generation: generation, epoch: expectedEpoch, isBaseline: true,
                               baselineGate: baselineGate)
    }

    private func reconcileWindows(pid: pid_t, generation: UUID, epoch expectedEpoch: UInt64,
                                  isBaseline: Bool = false,
                                  baselineGate: NewWindowBaselineGate? = nil) async {
        guard enabled, epoch == expectedEpoch, var state = processes[pid], state.generation == generation else { return }
        if state.baseline && !isBaseline { state.dirtyDuringBaseline = true; processes[pid] = state; return }
        let now = DispatchTime.now().uptimeNanoseconds
        let deadline = now + 5_000_000_000
        do {
            let result = try await runtime.observedWindows(applicationPID: pid, processGeneration: generation,
                                                           ownPID: ownPID, deadline: deadline)
            guard enabled, epoch == expectedEpoch, var current = processes[pid], current.generation == generation else { return }
            if !result.isComplete {
                recordDiagnostic("A partial window snapshot was retained without treating missing windows as closed.")
                if !current.baseline { processes[pid] = current; return }
            }
            let snapshotTokens = Set(result.candidates.map(\.token))
            if result.isComplete {
                let operation = ProcessOperation(pid: pid, generation: generation, epoch: expectedEpoch)
                guard let updated = await removeClosedTokens(current.seen.subtracting(snapshotTokens),
                                                             from: current, operation: operation) else { return }
                current = updated
            }
            let operation = ProcessOperation(pid: pid, generation: generation, epoch: expectedEpoch)
            guard let updated = await admitCandidates(result.candidates, to: current,
                                                      operation: operation, isBaseline: isBaseline) else { return }
            current = updated
            if isBaseline && result.isComplete {
                guard enabled, epoch == expectedEpoch,
                      var latest = processes[pid], latest.generation == generation else { return }
                latest.baseline = false
                latest.restoreInitialWindows = false
                baselineGate?.complete()
                let needsSecondPass = latest.dirtyDuringBaseline
                latest.dirtyDuringBaseline = false
                processes[pid] = latest
                completedReconcileCount += 1
                if needsSecondPass {
                    await reconcileWindows(pid: pid, generation: generation, epoch: expectedEpoch)
                }
            } else {
                guard enabled, epoch == expectedEpoch,
                      let latest = processes[pid], latest.generation == generation else { return }
                current = latest
                processes[pid] = current
                completedReconcileCount += 1
            }
        } catch {
            recordDiagnostic("A window list could not be read before its 5-second observation deadline.")
            if isBaseline, let current = processes[pid], current.generation == generation, !current.baseline {
                baselineGate?.complete()
            }
        }
    }

    private func removeClosedTokens(_ closedTokens: Set<RuntimeWindowToken>, from initial: ProcessState,
                                    operation: ProcessOperation) async -> ProcessState? {
        var current = initial
        for token in closedTokens {
            current.seen.remove(token)
            let lease = current.seenLeases.removeValue(forKey: token)
            processes[operation.pid] = current
            if let lease {
                await runtime.releaseMonitorSeenLease(token, lease: lease)
                guard enabled, epoch == operation.epoch,
                      let latest = processes[operation.pid], latest.generation == operation.generation else { return nil }
                current = latest
            }
            onWindowClosed?(token)
            layout.appWindowDestroyed(token)
        }
        return current
    }

    private func admitCandidates(_ candidates: [WindowObservationCandidate], to initial: ProcessState,
                                 operation: ProcessOperation, isBaseline: Bool) async -> ProcessState? {
        var current = initial
        for candidate in candidates {
            guard enabled, epoch == operation.epoch,
                  let latest = processes[operation.pid], latest.generation == operation.generation else { return nil }
            current = latest
            guard let updated = await admitCandidate(candidate, to: current,
                                                     operation: operation, isBaseline: isBaseline) else { return nil }
            current = updated
        }
        guard enabled, epoch == operation.epoch,
              let latest = processes[operation.pid], latest.generation == operation.generation else { return nil }
        return latest
    }

    private func admitCandidate(_ candidate: WindowObservationCandidate, to initial: ProcessState,
                                operation: ProcessOperation, isBaseline: Bool) async -> ProcessState? {
        var current = initial
        guard !current.seen.contains(candidate.token) else {
            current.seen.insert(candidate.token)
            processes[operation.pid] = current
            return current
        }
        guard observedTokenCount(excluding: operation.pid) + current.seen.count < 64 else {
            recordDiagnostic("The 64-window observation limit was reached; additional windows are not tracked.")
            return current
        }
        let lease = RuntimeMonitorSeenLeaseID()
        let retained = await runtime.retainMonitorSeenLease(candidate.token, lease: lease)
        guard enabled, epoch == operation.epoch,
              let latest = processes[operation.pid], latest.generation == operation.generation else {
            if retained { await runtime.releaseMonitorSeenLease(candidate.token, lease: lease) }
            return nil
        }
        current = latest
        guard retained else {
            recordDiagnostic("A window could not retain a monitor identity slot; the candidate was omitted.")
            return current
        }
        guard !current.seen.contains(candidate.token) else {
            await runtime.releaseMonitorSeenLease(candidate.token, lease: lease)
            return current
        }
        guard observedTokenCount(excluding: operation.pid) + current.seen.count < 64 else {
            await runtime.releaseMonitorSeenLease(candidate.token, lease: lease)
            recordDiagnostic("The 64-window observation limit was reached; additional windows are not tracked.")
            return current
        }
        current.seenLeases[candidate.token] = lease
        current.seen.insert(candidate.token)
        processes[operation.pid] = current
        if (!current.baseline && !isBaseline) || current.restoreInitialWindows {
            onNewWindow?(candidate, current.bundleID)
        }
        return current
    }

    private func observedTokenCount(excluding pid: pid_t) -> Int {
        processes.filter { $0.key != pid }.values.reduce(0) { $0 + $1.seen.count }
    }

    private func terminate(pid: pid_t, launchDate: Date?, epoch expectedEpoch: UInt64) async {
        guard enabled, epoch == expectedEpoch, let state = processes.removeValue(forKey: pid) else { return }
        guard let launchDate, state.launchDate == launchDate else {
            processes[pid] = state
            return
        }
        onProcessTerminating?(pid, state.generation)
        let tokens = await runtime.discardProcess(pid, expectedGeneration: state.generation)
        for token in tokens { layout.appProcessTerminated(token) }
        for (token, lease) in state.seenLeases {
            await runtime.releaseMonitorSeenLease(token, lease: lease)
        }
    }

    func cancelPendingAutoRestoreTickets() { ticketRegistry.invalidateAll() }

    private func recordDiagnostic(_ message: String) {
        guard !diagnostics.contains(message) else { return }
        if diagnostics.count == 8 { diagnostics.removeFirst() }
        diagnostics.append(message)
    }
}
