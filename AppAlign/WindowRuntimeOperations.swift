import AppKit
@preconcurrency import ApplicationServices
import Foundation

protocol ManualWindowOperating: WindowHistoryLeaseOperating {
    func captureManualWindow(applicationPID: pid_t, ownPID: pid_t) async throws -> ManualWindowCapture
    func moveManualWindow(_ token: RuntimeWindowToken, lease: ManualWindowLeaseID, to frame: CGRect,
                          ticket: PlacementCommitTicket,
                          preflight: @MainActor @Sendable () async -> Bool) async throws -> CGRect
    func readManualWindowFrame(_ token: RuntimeWindowToken, lease: ManualWindowLeaseID) async throws -> CGRect
    func releaseManualLease(_ token: RuntimeWindowToken, lease: ManualWindowLeaseID) async
}

protocol AutomaticWindowOperating: NewWindowMonitorRuntime {
    func moveHistoryWindow(_ token: RuntimeWindowToken, lease: RuntimeHistoryLeaseID, to frame: CGRect,
                           ticket: PlacementCommitTicket,
                           preflight: @MainActor @Sendable () async -> Bool) async throws -> CGRect
}

extension AccessibilityWindowRuntime: ManualWindowOperating, WindowHistoryLeaseOperating, AutomaticWindowOperating {}

extension AccessibilityWindowRuntime {
    static func operationWindow(_ window: AXWindow, deadline: UInt64, timeoutLimit: Float = 0.5) throws -> AXWindow {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { throw WindowManagementError.operationFailed }
        let remaining = Float(deadline - now) / 1_000_000_000
        guard remaining > 0.01 else { throw WindowManagementError.operationFailed }
        return AXWindow(applicationElement: window.applicationElement, element: window.element,
                        pid: window.pid, messagingTimeout: min(timeoutLimit, remaining), operationDeadline: deadline)
    }

    func moveHistoryWindow(_ token: RuntimeWindowToken, lease: RuntimeHistoryLeaseID, to frame: CGRect,
                           ticket: PlacementCommitTicket,
                           preflight: @MainActor @Sendable () async -> Bool) async throws -> CGRect {
        guard processLaunchGenerations[token.pid] == token.processGeneration,
              let initial = records[token.id], initial.window.pid == token.pid,
              initial.ownership.historyLeases.contains(lease),
              !initial.revisionTracker.snapshot(since: 0).destroyed,
              accessibilityTrustedProvider() else { throw WindowManagementError.noCapturedWindow }
        try focusedWindowValidator(initial.window)
        guard await preflight() else { throw WindowManagementError.displayConfigurationChanged }
        guard processLaunchGenerations[token.pid] == token.processGeneration,
              let current = records[token.id], current.window.pid == token.pid,
              current.ownership.historyLeases.contains(lease),
              !current.revisionTracker.snapshot(since: 0).destroyed,
              accessibilityTrustedProvider() else { throw WindowManagementError.noCapturedWindow }
        let operationDeadline = min(ticket.totalDeadline, DispatchTime.now().uptimeNanoseconds + 200_000_000)
        let operationWindow = try Self.operationWindow(current.window, deadline: operationDeadline, timeoutLimit: 0.2)
        try focusedWindowValidator(operationWindow)
        guard try settableAttributeProvider(operationWindow, kAXPositionAttribute as CFString),
              try settableAttributeProvider(operationWindow, kAXSizeAttribute as CFString) else {
            throw WindowManagementError.excludedWindow(reason: "the window cannot be moved or resized")
        }
        guard ticket.beginWrite(now: DispatchTime.now().uptimeNanoseconds) else {
            throw WindowManagementError.displayConfigurationChanged
        }
        writeInProgress = true
        defer {
            writeInProgress = false
            let timestamp = DispatchTime.now().uptimeNanoseconds
            current.revisionTracker.recordWrite(at: timestamp)
            lastWriteEndNanoseconds = timestamp
        }
        return try historyMover.movePlacement(operationWindow, to: frame, ticket: ticket).actualFrame
    }

    func readManualWindowFrame(_ token: RuntimeWindowToken, lease: ManualWindowLeaseID) async throws -> CGRect {
        guard processLaunchGenerations[token.pid] == token.processGeneration,
              let record = records[token.id], record.window.pid == token.pid,
              record.ownership.manualLeases.contains(lease),
              !record.revisionTracker.snapshot(since: 0).destroyed,
              accessibilityTrustedProvider() else { throw WindowManagementError.noCapturedWindow }
        try focusedWindowValidator(record.window)
        return try record.window.frame()
    }

    func retainHistoryLease(_ token: RuntimeWindowToken, lease: RuntimeHistoryLeaseID) async -> Bool {
        await retainHistoryLease(token, lease: lease, observerDeadline: nil)
    }

    func retainHistoryLease(_ token: RuntimeWindowToken, lease: RuntimeHistoryLeaseID,
                            deadline: UInt64) async -> Bool {
        guard DispatchTime.now().uptimeNanoseconds < deadline else { return false }
        return await retainHistoryLease(token, lease: lease, observerDeadline: deadline)
    }

    private func retainHistoryLease(_ token: RuntimeWindowToken, lease: RuntimeHistoryLeaseID,
                                    observerDeadline: UInt64?) async -> Bool {
        guard processLaunchGenerations[token.pid] == token.processGeneration,
              var record = records[token.id], record.window.pid == token.pid,
              !record.revisionTracker.snapshot(since: 0).destroyed else { return false }
        if record.ownership.historyLeases.contains(lease) {
            records[token.id] = record
            installHistoryDestroySink(token, tracker: record.revisionTracker)
            return true
        }
        let retainedHistoryTokens = Set(records.compactMap { id, candidate in
            candidate.ownership.historyLeases.isEmpty ? nil : id
        })
        let alreadyTracked = !record.ownership.historyLeases.isEmpty
        guard record.ownership.historyLeases.count < 2,
              alreadyTracked || retainedHistoryTokens.count < 64 else { return false }
        if record.observerRegistration == nil, !record.historyObserverVerified,
           let historyObserverProvider {
            guard let deadline = Self.historyObserverDeadline(limit: observerDeadline) else { return false }
            guard historyObserverProvider(token.pid, record.window.element, record.revisionTracker, deadline) else { return false }
            record.historyObserverVerified = true
        }
        if record.observerRegistration == nil, !record.historyObserverVerified {
            guard let deadline = Self.historyObserverDeadline(limit: observerDeadline) else { return false }
            guard let registration = AXObserverRegistration(pid: token.pid, element: record.window.element,
                                                               tracker: record.revisionTracker, deadline: deadline,
                                                               mode: .destroyOnly),
                  registration.notificationsVerified else {
                return false
            }
            record.observerRegistration = registration
        } else if !record.historyObserverVerified, record.observerRegistration?.notificationsVerified != true {
            return false
        }
        record.ownership.retainHistory(lease)
        records[token.id] = record
        installHistoryDestroySink(token, tracker: record.revisionTracker)
        return true
    }

    private static func historyObserverDeadline(limit: UInt64?) -> UInt64? {
        let now = DispatchTime.now().uptimeNanoseconds
        let ordinaryDeadline = now + 1_000_000_000
        guard let limit else { return ordinaryDeadline }
        guard now < limit else { return nil }
        return min(ordinaryDeadline, limit)
    }

    func retainMonitorSeenLease(_ token: RuntimeWindowToken, lease: RuntimeMonitorSeenLeaseID) async -> Bool {
        guard processLaunchGenerations[token.pid] == token.processGeneration,
              var record = records[token.id], record.window.pid == token.pid,
              !record.revisionTracker.snapshot(since: 0).destroyed else { return false }
        if record.ownership.monitorSeenLeases.contains(lease) { return true }
        let retainedMonitorTokens = Set(records.compactMap { id, candidate in
            candidate.ownership.monitorSeenLeases.isEmpty ? nil : id
        })
        guard record.ownership.monitorSeenLeases.count < 2,
              !record.ownership.monitorSeenLeases.isEmpty || retainedMonitorTokens.count < 64 else { return false }
        record.ownership.retainMonitorSeen(lease)
        records[token.id] = record
        return true
    }

    func releaseMonitorSeenLease(_ token: RuntimeWindowToken, lease: RuntimeMonitorSeenLeaseID) async {
        guard processLaunchGenerations[token.pid] == token.processGeneration,
              let record = records[token.id], record.window.pid == token.pid else { return }
        releaseOwnership(id: token.id) { $0.releaseMonitorSeen(lease) }
    }

    func monitorSeenLeaseCount(for token: RuntimeWindowToken) -> Int {
        guard processLaunchGenerations[token.pid] == token.processGeneration,
              let record = records[token.id] else { return 0 }
        return record.ownership.monitorSeenLeases.count
    }

    var retainedMonitorSeenTokenCount: Int {
        records.values.reduce(0) { $0 + ($1.ownership.monitorSeenLeases.isEmpty ? 0 : 1) }
    }

    func retainManualLease(_ token: RuntimeWindowToken, lease: ManualWindowLeaseID) -> Bool {
        guard processLaunchGenerations[token.pid] == token.processGeneration,
              var record = records[token.id], record.window.pid == token.pid,
              !record.revisionTracker.snapshot(since: 0).destroyed else { return false }
        record.ownership.retainManual(lease)
        records[token.id] = record
        return true
    }

    func releaseHistoryLease(_ token: RuntimeWindowToken, lease: RuntimeHistoryLeaseID) async {
        guard processLaunchGenerations[token.pid] == token.processGeneration,
              let record = records[token.id], record.window.pid == token.pid else { return }
        let tracker = record.revisionTracker
        releaseOwnership(id: token.id) { $0.releaseHistory(lease) }
        if records[token.id]?.ownership.historyLeases.isEmpty != false {
            tracker.setDestroyedHandler(nil)
            historyDestroySinks.remove(token)
        }
    }

    func setHistoryWindowDestroyedHandler(_ handler: @escaping @Sendable (RuntimeWindowToken, UInt64) -> Void) {
        historyDestroyHandler = handler
        resumeHistoryDestroyNotifications()
    }

    func applyHistoryDestroyState(enabled: Bool, revision: UInt64) {
        guard revision >= historyDestroyLifecycleRevision else { return }
        historyDestroyLifecycleRevision = revision
        if enabled {
            resumeHistoryDestroyNotifications()
        } else {
            invalidateHistoryDestroyNotifications()
        }
    }

    func invalidateHistoryDestroyNotifications() {
        guard historyDestroyNotificationsEnabled else { return }
        historyDestroyNotificationsEnabled = false
        historyDestroyEpoch &+= 1
        for token in historyDestroySinks {
            records[token.id]?.revisionTracker.setDestroyedHandler(nil)
        }
        historyDestroySinks.removeAll()
    }

    func resumeHistoryDestroyNotifications() {
        guard !historyDestroyNotificationsEnabled else {
            installAllHistoryDestroySinks()
            return
        }
        historyDestroyNotificationsEnabled = true
        historyDestroyEpoch &+= 1
        installAllHistoryDestroySinks()
    }

    func notifyWindowDestroyedForTesting(_ token: RuntimeWindowToken) {
        records[token.id]?.revisionTracker.record(kAXUIElementDestroyedNotification as String)
    }

    private func installAllHistoryDestroySinks() {
        for (id, record) in records where !record.ownership.historyLeases.isEmpty {
            installHistoryDestroySink(RuntimeWindowToken(id: id, pid: record.window.pid,
                                                         processGeneration: processLaunchGenerations[record.window.pid] ?? UUID()),
                                      tracker: record.revisionTracker)
        }
    }

    private func installHistoryDestroySink(_ token: RuntimeWindowToken, tracker: AXRevisionTracker) {
        guard historyDestroyNotificationsEnabled, historyDestroyHandler != nil,
              processLaunchGenerations[token.pid] == token.processGeneration,
              historyDestroySinks.insert(token).inserted else { return }
        let epoch = historyDestroyEpoch
        tracker.setDestroyedHandler { [weak self] in
            Task { await self?.deliverHistoryDestroyed(token, epoch: epoch) }
        }
    }

    private func deliverHistoryDestroyed(_ token: RuntimeWindowToken, epoch: UInt64) {
        guard historyDestroyNotificationsEnabled, epoch == historyDestroyEpoch,
              historyDestroySinks.contains(token), processLaunchGenerations[token.pid] == token.processGeneration,
              let record = records[token.id], record.window.pid == token.pid,
              !record.ownership.historyLeases.isEmpty else { return }
        historyDestroyHandler?(token, epoch)
    }

    func captureManualWindow(applicationPID: pid_t, ownPID: pid_t) async throws -> ManualWindowCapture {
        guard applicationPID != ownPID, accessibilityTrustedProvider() else {
            throw accessibilityTrustedProvider() ? WindowManagementError.excludedWindow(reason: "AppAlign cannot capture its own windows")
                : WindowManagementError.accessibilityPermissionRequired
        }
        let window = try repository.focusedWindow(applicationPID: applicationPID)
        try focusedWindowValidator(window)
        let frame = try window.frame()
        guard Self.isFinite(frame), frame.width > 0, frame.height > 0 else { throw WindowManagementError.invalidFocusedWindow }
        let token = try token(for: window)
        let lease = ManualWindowLeaseID()
        guard retainManualLease(token, lease: lease) else { throw WindowManagementError.noCapturedWindow }
        return ManualWindowCapture(token: token, lease: lease, originalFrame: frame)
    }

    func moveManualWindow(_ token: RuntimeWindowToken, lease: ManualWindowLeaseID, to frame: CGRect,
                          ticket: PlacementCommitTicket,
                          preflight: @MainActor @Sendable () async -> Bool) async throws -> CGRect {
        guard processLaunchGenerations[token.pid] == token.processGeneration,
              let before = records[token.id], before.window.pid == token.pid,
              before.ownership.manualLeases.contains(lease),
              !before.revisionTracker.snapshot(since: 0).destroyed,
              accessibilityTrustedProvider() else { throw WindowManagementError.noCapturedWindow }
        guard await preflight() else { throw WindowManagementError.displayConfigurationChanged }
        guard processLaunchGenerations[token.pid] == token.processGeneration,
              let latest = records[token.id], latest.window.pid == token.pid,
              latest.ownership.manualLeases.contains(lease),
              !latest.revisionTracker.snapshot(since: 0).destroyed,
              accessibilityTrustedProvider() else {
            throw WindowManagementError.displayConfigurationChanged
        }
        let operationDeadline = min(ticket.totalDeadline, DispatchTime.now().uptimeNanoseconds + 500_000_000)
        let operationWindow = try Self.operationWindow(latest.window, deadline: operationDeadline)
        try focusedWindowValidator(operationWindow)
        guard ticket.beginWrite(now: DispatchTime.now().uptimeNanoseconds) else {
            throw WindowManagementError.displayConfigurationChanged
        }
        writeInProgress = true
        defer {
            writeInProgress = false
            let timestamp = DispatchTime.now().uptimeNanoseconds
            latest.revisionTracker.recordWrite(at: timestamp)
            lastWriteEndNanoseconds = timestamp
        }
        return try mover.movePlacement(operationWindow, to: frame, ticket: ticket).actualFrame
    }

    func releaseManualLease(_ token: RuntimeWindowToken, lease: ManualWindowLeaseID) async {
        guard let record = records[token.id], record.window.pid == token.pid else { return }
        releaseOwnership(id: token.id) { $0.releaseManual(lease) }
    }

    func processGenerationForMonitoring(_ pid: pid_t, launchDate: Date) async -> UUID {
        if let previousLaunchDate = processLaunchDates[pid], previousLaunchDate != launchDate,
           let previousGeneration = processLaunchGenerations[pid] {
            _ = discardProcess(pid, expectedGeneration: previousGeneration)
        }
        processLaunchDates[pid] = launchDate
        return processGeneration(for: pid)
    }

    func observeWindowCreation(applicationPID pid: pid_t, processGeneration generation: UUID,
                               epoch: UInt64, signal: @escaping @Sendable (pid_t, UUID, UInt64) -> Void) async -> Bool {
        guard processLaunchGenerations[pid] == generation, accessibilityTrustedProvider(),
              processObservations[pid] != nil || processObservations.count < 64 else { return false }
        let registration = AXWindowCreationRegistration(pid: pid) { signal(pid, generation, epoch) }
        guard let registration, registration.isVerified,
              processLaunchGenerations[pid] == generation else {
            registration?.invalidate()
            return false
        }
        processObservations[pid]?.registration.invalidate()
        processObservations[pid] = ProcessObservation(generation: generation, epoch: epoch,
                                                      registration: registration)
        return true
    }

    func stopWindowObservation(applicationPID pid: pid_t, processGeneration generation: UUID) async {
        guard let observation = processObservations[pid], observation.generation == generation else { return }
        processObservations.removeValue(forKey: pid)
        observation.registration.invalidate()
    }

    func discardProcess(_ pid: pid_t) async {
        guard let generation = processLaunchGenerations[pid] else { return }
        _ = discardProcess(pid, expectedGeneration: generation)
    }

    @discardableResult
    func discardProcess(_ pid: pid_t, expectedGeneration generation: UUID) -> [RuntimeWindowToken] {
        guard processLaunchGenerations[pid] == generation else { return [] }
        if let observation = processObservations[pid], observation.generation == generation {
            processObservations.removeValue(forKey: pid)
            observation.registration.invalidate()
        }
        let removed = records.filter { $0.value.window.pid == pid }
        let removedRecords = removed.map(\.value)
        let removedTokens = removed.map { RuntimeWindowToken(id: $0.key, pid: pid, processGeneration: generation) }
        for token in removedTokens {
            removed[token.id]?.revisionTracker.setDestroyedHandler(nil)
            historyDestroySinks.remove(token)
        }
        records = records.filter { $0.value.window.pid != pid }
        for registration in removedRecords.compactMap(\.observerRegistration) { registration.invalidate() }
        processLaunchGenerations.removeValue(forKey: pid)
        processLaunchDates.removeValue(forKey: pid)
        return removedTokens
    }

    func focusedWindow(applicationPID: pid_t, ownPID: pid_t) async throws -> RuntimeWindowSnapshot {
        guard applicationPID != ownPID else {
            throw WindowManagementError.excludedWindow(reason: "AppAlign cannot move its own windows")
        }
        let focused = try repository.focusedWindow(applicationPID: applicationPID)
        try WindowFilter(ownPID: ownPID).validate(focused)
        let frame = try focused.frame()
        guard Self.isFinite(frame), frame.width > 0, frame.height > 0 else {
            throw WindowManagementError.invalidFocusedWindow
        }
        if let match = records.first(where: {
            $0.value.window.pid == focused.pid && CFEqual($0.value.window.element, focused.element)
        }) {
            return RuntimeWindowSnapshot(token: RuntimeWindowToken(id: match.key, pid: focused.pid,
                                                                    processGeneration: processGeneration(for: focused.pid)), frame: frame)
        }
        if records.count >= 128,
           let oldest = records.keys.first(where: { !Self.isOwned(records[$0]) }) {
            records.removeValue(forKey: oldest)
        }
        guard records.count < 128 else { throw WindowManagementError.invalidFocusedWindow }
        let id = UUID()
        records[id] = Record(window: focused)
        return RuntimeWindowSnapshot(token: RuntimeWindowToken(id: id, pid: focused.pid,
                                                                processGeneration: processGeneration(for: focused.pid)), frame: frame)
    }

    func retain(_ token: RuntimeWindowToken) async {
        guard var record = records[token.id], record.window.pid == token.pid else { return }
        record.ownership.retainKeyboard()
        records[token.id] = record
    }

    func move(_ token: RuntimeWindowToken, to frame: CGRect, ticket: PlacementCommitTicket,
              preflight: @MainActor @Sendable () -> Bool) async throws -> CGRect {
        let actualFrame = try await withCurrentFocusedWindow(token, ticket: ticket, preflight: preflight) { window in
            try mover.movePlacement(window, to: frame, ticket: ticket).actualFrame
        }
        try ensureKeyboardOwnership(token)
        return actualFrame
    }

    func restore(_ token: RuntimeWindowToken, to frame: CGRect, ticket: PlacementCommitTicket,
                 preflight: @MainActor @Sendable () -> Bool) async throws -> CGRect {
        let actualFrame = try await withCurrentFocusedWindow(token, ticket: ticket, preflight: preflight) { window in
            try mover.movePlacement(window, to: frame, ticket: ticket).actualFrame
        }
        try ensureKeyboardOwnership(token)
        return actualFrame
    }

    func discard(_ token: RuntimeWindowToken) async {
        guard var record = records[token.id], record.window.pid == token.pid else { return }
        record.ownership.discardKeyboard()
        if !record.ownership.isOwned { removeRecord(token.id, record: record) } else { records[token.id] = record }
    }

    func shutdown() async {
        let registrations = records.values.compactMap(\.observerRegistration)
        let processRegistrations = processObservations.values.map(\.registration)
        records.removeAll()
        processObservations.removeAll()
        for registration in registrations { registration.invalidate() }
        for registration in processRegistrations { registration.invalidate() }
    }

    func isWriteInProgress() async -> Bool { writeInProgress }

    static func remainingTimeout(before deadline: UInt64) throws -> Float {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { throw WindowManagementError.operationFailed }
        return Float(deadline - now) / 1_000_000_000
    }

    func releaseOwnership(id: UUID, update: (inout RuntimeWindowOwnership) -> Void) {
        guard var record = records[id] else { return }
        update(&record.ownership)
        if !record.ownership.isOwned { removeRecord(id, record: record) } else { records[id] = record }
    }

    private func removeRecord(_ id: UUID, record: Record) {
        records.removeValue(forKey: id)
        let token = RuntimeWindowToken(id: id, pid: record.window.pid,
                                       processGeneration: processLaunchGenerations[record.window.pid] ?? UUID())
        record.revisionTracker.setDestroyedHandler(nil)
        historyDestroySinks.remove(token)
        record.observerRegistration?.invalidate()
    }

    static func dragWindow(_ window: AXWindow, before deadline: UInt64) throws -> AXWindow {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { throw WindowManagementError.operationFailed }
        let remaining = Float(deadline - now) / 1_000_000_000
        guard remaining > 0.01 else { throw WindowManagementError.operationFailed }
        return AXWindow(applicationElement: window.applicationElement, element: window.element,
                        pid: window.pid, messagingTimeout: min(0.5, remaining), operationDeadline: deadline)
    }

    func withCurrentFocusedWindow<T>(
        _ token: RuntimeWindowToken,
        ticket: PlacementCommitTicket,
        preflight: @MainActor @Sendable () -> Bool,
        operation: (AXWindow) throws -> T
    ) async throws -> T {
        guard processLaunchGenerations[token.pid] == token.processGeneration,
              let initialRecord = records[token.id], initialRecord.window.pid == token.pid,
              initialRecord.ownership.keyboardRetained else { throw WindowManagementError.noCapturedWindow }
        if initialRecord.revisionTracker.snapshot(since: 0).destroyed {
            initialRecord.observerRegistration?.invalidate()
            records.removeValue(forKey: token.id)
            throw WindowManagementError.noCapturedWindow
        }
        do {
            let focusedBeforePreflight = try focusedWindowProvider(token.pid)
            guard CFEqual(initialRecord.window.element, focusedBeforePreflight.element) else {
                throw WindowManagementError.noFocusedWindow(code: -1)
            }
            try focusedWindowValidator(focusedBeforePreflight)
            guard await preflight() else { throw WindowManagementError.displayConfigurationChanged }
            let focused = try focusedWindowProvider(token.pid)
            guard CFEqual(initialRecord.window.element, focused.element) else {
                throw WindowManagementError.noFocusedWindow(code: -1)
            }
            try focusedWindowValidator(focused)
            guard frontmostPIDProvider() == token.pid,
                  accessibilityTrustedProvider() else {
                throw WindowManagementError.displayConfigurationChanged
            }
            // `preflight` suspends this actor. Discard, shutdown, or record replacement
            // may have run while it was suspended, so reacquire ownership immediately
            // before the atomic ticket boundary and AX setters.
            guard processLaunchGenerations[token.pid] == token.processGeneration,
                  let record = records[token.id], record.window.pid == token.pid,
                  CFEqual(record.window.element, focused.element),
                  record.ownership.keyboardRetained,
                  !record.revisionTracker.snapshot(since: 0).destroyed else {
                throw WindowManagementError.noCapturedWindow
            }
            guard ticket.beginWrite(now: DispatchTime.now().uptimeNanoseconds) else {
                throw WindowManagementError.displayConfigurationChanged
            }
            writeInProgress = true
            defer { writeInProgress = false }
            defer {
                let timestamp = DispatchTime.now().uptimeNanoseconds
                record.revisionTracker.recordWrite(at: timestamp)
                lastWriteEndNanoseconds = timestamp
            }
            return try operation(focused)
        } catch {
            if error is WindowManagementError { throw error }
            records.removeValue(forKey: token.id)
            throw error
        }
    }

    private func ensureKeyboardOwnership(_ token: RuntimeWindowToken) throws {
        guard processLaunchGenerations[token.pid] == token.processGeneration,
              let record = records[token.id], record.window.pid == token.pid,
              record.ownership.keyboardRetained,
              !record.revisionTracker.snapshot(since: 0).destroyed else {
            throw WindowManagementError.noCapturedWindow
        }
    }

    static func isFinite(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite
    }

    func token(for window: AXWindow) throws -> RuntimeWindowToken {
        if let match = records.first(where: { $0.value.window.pid == window.pid && CFEqual($0.value.window.element, window.element) }) {
            if match.value.window.operationDeadline != nil {
                var normalized = match.value
                normalized.window = AXWindow(applicationElement: window.applicationElement, element: window.element,
                                             pid: window.pid, messagingTimeout: window.messagingTimeout)
                records[match.key] = normalized
            }
            return RuntimeWindowToken(id: match.key, pid: window.pid,
                                      processGeneration: processGeneration(for: window.pid))
        }
        if records.count >= 128,
           let oldest = records.keys.first(where: { !Self.isOwned(records[$0]) }) {
            records.removeValue(forKey: oldest)
        }
        guard records.count < 128 else { throw WindowManagementError.invalidFocusedWindow }
        let id = UUID()
        let durableWindow = AXWindow(applicationElement: window.applicationElement, element: window.element,
                                     pid: window.pid, messagingTimeout: window.messagingTimeout)
        records[id] = Record(window: durableWindow)
        return RuntimeWindowToken(id: id, pid: window.pid, processGeneration: processGeneration(for: window.pid))
    }

    func historyLeaseCount(for token: RuntimeWindowToken) -> Int {
        guard processLaunchGenerations[token.pid] == token.processGeneration,
              let record = records[token.id] else { return 0 }
        return record.ownership.historyLeases.count
    }

    var historyDestroySinkCount: Int { historyDestroySinks.count }

    func storedOperationDeadline(for token: RuntimeWindowToken) -> UInt64? {
        records[token.id]?.window.operationDeadline
    }

    private func processGeneration(for pid: pid_t) -> UUID {
        if let generation = processLaunchGenerations[pid] { return generation }
        let generation = UUID()
        processLaunchGenerations[pid] = generation
        return generation
    }

    static func isOwned(_ record: Record?) -> Bool {
        record?.ownership.isOwned ?? false
    }
}
