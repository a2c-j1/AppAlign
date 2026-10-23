import AppKit
import Carbon.HIToolbox
import XCTest

final class GlobalHotkeysTests: XCTestCase {
    @MainActor
    func testShutdownWhileFocusedWindowProbeIsPendingCannotRegisterLate() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        await fixture.backend.blockNextFocus()
        fixture.hotkeys.start()
        let awaitedCondition11 = await fixture.backend.waitForFocusProbe()
        XCTAssertTrue(awaitedCondition11)
        fixture.hotkeys.shutdown()
        await fixture.backend.releaseBlockedFocus()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fixture.registrar.totalRegistrations, 0)
        XCTAssertEqual(fixture.registrar.activeIDs.count, 0)
    }

    @MainActor
    func testOldCallbackAfterDisableDoesNotMoveAndReenableRegistersAgain() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        fixture.hotkeys.start()
        let awaitedCondition24 = await fixture.waitForActiveRegistrations()
        XCTAssertTrue(awaitedCondition24)
        let oldCallback = try XCTUnwrap(fixture.registrar.callbacks.values.first)

        fixture.updateEnabled(false)
        oldCallback()
        try await Task.sleep(for: .milliseconds(50))
        let awaitedValue30 = await fixture.backend.writeCount()
        XCTAssertEqual(awaitedValue30, 0)

        let before = fixture.registrar.totalRegistrations
        fixture.updateEnabled(true)
        let awaitedCondition34 = await fixture.waitForActiveRegistrations()
        XCTAssertTrue(awaitedCondition34)
        XCTAssertGreaterThan(fixture.registrar.totalRegistrations, before)
        let currentCallback = try XCTUnwrap(fixture.currentCallback())
        currentCallback()
        let awaitedCondition38 = await fixture.waitForWindowAction()
        XCTAssertTrue(awaitedCondition38)
        let awaitedValue39 = await fixture.backend.writeCount()
        XCTAssertEqual(awaitedValue39, 1)
    }

    @MainActor
    func testDisableThenReenableInvalidatesAnAlreadyPendingWrite() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        fixture.hotkeys.start()
        let active = await fixture.waitForActiveRegistrations()
        XCTAssertTrue(active)
        await fixture.backend.blockNextPreflight()
        try XCTUnwrap(fixture.currentCallback())()
        let reachedPreflight = await fixture.backend.waitForPreflight()
        XCTAssertTrue(reachedPreflight)

        fixture.updateEnabled(false)
        fixture.updateEnabled(true)
        await fixture.backend.releaseBlockedPreflight()
        let idle = await fixture.waitForIdle()
        XCTAssertTrue(idle)
        let canceledWrites = await fixture.backend.writeCount()
        XCTAssertEqual(canceledWrites, 0)

        let reenabled = await fixture.waitForActiveRegistrations()
        XCTAssertTrue(reenabled)
        try XCTUnwrap(fixture.currentCallback())()
        let completed = await fixture.waitForWindowAction()
        XCTAssertTrue(completed)
        let freshWrites = await fixture.backend.writeCount()
        XCTAssertEqual(freshWrites, 1)
    }

    @MainActor
    func testDragGateUnregistersIgnoresOldCallbacksAndReconcilesOnlyWhenEligible() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        fixture.hotkeys.start()
        let initiallyRegistered = await fixture.waitForActiveRegistrations()
        XCTAssertTrue(initiallyRegistered)
        let oldCallback = try XCTUnwrap(fixture.currentCallback())

        fixture.hotkeys.setDragGateClosed(true)
        let unregistered = await fixture.waitForNoActiveRegistrations()
        XCTAssertTrue(unregistered)
        oldCallback()
        try await Task.sleep(for: .milliseconds(50))
        let staleCallbackWrites = await fixture.backend.writeCount()
        XCTAssertEqual(staleCallbackWrites, 0)

        fixture.environment.isTrusted = false
        fixture.hotkeys.setDragGateClosed(false)
        XCTAssertTrue(fixture.registrar.activeIDs.isEmpty)
        fixture.environment.isTrusted = true
        fixture.hotkeys.settingsDidChange()
        let reRegistered = await fixture.waitForActiveRegistrations()
        XCTAssertTrue(reRegistered)
        try XCTUnwrap(fixture.currentCallback())()
        let reRegisteredAction = await fixture.waitForWindowAction()
        XCTAssertTrue(reRegisteredAction)
        let freshCallbackWrites = await fixture.backend.writeCount()
        XCTAssertEqual(freshCallbackWrites, 1)
        let registrationsBeforeShutdown = fixture.registrar.totalRegistrations

        fixture.hotkeys.shutdown()
        fixture.hotkeys.setDragGateClosed(false)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(fixture.registrar.activeIDs.isEmpty)
        XCTAssertEqual(fixture.registrar.totalRegistrations, registrationsBeforeShutdown)
    }

    @MainActor
    func testSystemConflictAndCarbonRegistrationFailureAreReported() async throws {
        let systemConflict = try await Fixture.make(systemConflict: true)
        defer { systemConflict.remove() }
        systemConflict.hotkeys.start()
        let awaitedCondition47 = await systemConflict.waitForStatus("macOS already uses")
        XCTAssertTrue(awaitedCondition47)
        XCTAssertEqual(systemConflict.registrar.totalRegistrations, 0)

        let registrationFailure = try await Fixture.make(registrationStatus: OSStatus(eventNotHandledErr))
        defer { registrationFailure.remove() }
        registrationFailure.hotkeys.start()
        let awaitedCondition53 = await registrationFailure.waitForStatus("Carbon status")
        XCTAssertTrue(awaitedCondition53)
        XCTAssertEqual(registrationFailure.registrar.activeIDs.count, 0)
    }

    @MainActor
    func testPermissionRevocationAndUnregisterFailureStopDispatchAndRetryRelease() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        fixture.hotkeys.start()
        let awaitedCondition62 = await fixture.waitForActiveRegistrations()
        XCTAssertTrue(awaitedCondition62)
        let oldCallback = try XCTUnwrap(fixture.registrar.callbacks.values.first)
        fixture.registrar.unregisterStatus = OSStatus(eventNotHandledErr)
        fixture.environment.isTrusted = false
        fixture.hotkeys.settingsDidChange()
        let warningVisible = await fixture.waitForStatus("may still consume")
        XCTAssertTrue(warningVisible)
        XCTAssertTrue(fixture.hotkeys.statusMessage.contains("may still consume"))
        oldCallback()
        try await Task.sleep(for: .milliseconds(50))
        let awaitedValue70 = await fixture.backend.writeCount()
        XCTAssertEqual(awaitedValue70, 0)
        XCTAssertGreaterThan(fixture.registrar.activeIDs.count, 0)

        fixture.registrar.unregisterStatus = noErr
        fixture.hotkeys.settingsDidChange()
        let awaitedCondition75 = await fixture.waitForNoActiveRegistrations()
        XCTAssertTrue(awaitedCondition75)
    }

    @MainActor
    private struct Fixture {
        let layout: LayoutController
        let snapController: KeyboardSnapController
        let hotkeys: GlobalHotkeys
        let backend: HotkeyFakeWindowBackend
        let registrar: FakeHotKeyRegistrar
        let environment: FakeKeyboardEnvironment
        let directory: URL

        static func make(systemConflict: Bool = false, registrationStatus: OSStatus = noErr) async throws -> Fixture {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let display = Display(
                runtimeID: RuntimeDisplayID(rawValue: 1), persistentID: PersistentDisplayID(uuid: UUID()),
                sessionID: UUID(), name: "Test", frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                workArea: CGRect(x: 0, y: 0, width: 1_000, height: 800), isPrimary: true, backingScaleFactor: 1
            )
            let layout = LayoutController(
                displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [display], primaryFrame: display.frame)),
                storeCoordinator: PersistentStoreCoordinator(directory: directory)
            )
            await layout.loadPersistentState()
            var settings = layout.keyboardSettings
            settings.isEnabled = true
            layout.updateKeyboardSettings(settings)
            _ = await layout.flush()

            let backend = HotkeyFakeWindowBackend(frame: CGRect(x: 600, y: 400, width: 300, height: 200))
            let environment = FakeKeyboardEnvironment()
            let keyboardEnvironment = KeyboardEnvironment(
                frontmostPID: { environment.frontmostPID },
                isAccessibilityTrusted: { environment.isTrusted },
                focusedWindowIdentity: { _ in await environment.readFocusedWindowIdentity() }, ownPID: 100
            )
            let snapController = KeyboardSnapController(layoutController: layout, backend: backend, environment: keyboardEnvironment)
            let registrar = FakeHotKeyRegistrar(systemConflict: systemConflict, registrationStatus: registrationStatus)
            let hotkeys = GlobalHotkeys(layoutController: layout, snapController: snapController, registrar: registrar, environment: keyboardEnvironment)
            return Fixture(layout: layout, snapController: snapController, hotkeys: hotkeys, backend: backend, registrar: registrar, environment: environment, directory: directory)
        }

        func updateEnabled(_ value: Bool) {
            var settings = layout.keyboardSettings
            settings.isEnabled = value
            layout.updateKeyboardSettings(settings)
            hotkeys.settingsDidChange()
        }

        func waitForActiveRegistrations() async -> Bool {
            for _ in 0 ..< 200 {
                if !registrar.activeIDs.isEmpty, hotkeys.statusMessage.hasPrefix("Registered ") { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }

        func currentCallback() -> (@Sendable () -> Void)? {
            guard let id = registrar.activeIDs.sorted().first else { return nil }
            return registrar.callbacks[id]
        }

        func waitForNoActiveRegistrations() async -> Bool {
            for _ in 0 ..< 200 {
                if registrar.activeIDs.isEmpty { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }

        func waitForStatus(_ text: String) async -> Bool {
            for _ in 0 ..< 200 {
                if hotkeys.statusMessage.contains(text) { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }

        func waitForWindowAction() async -> Bool {
            for _ in 0 ..< 200 {
                if await backend.writeCount() > 0, !snapController.isBusy { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }

        func waitForIdle() async -> Bool {
            for _ in 0 ..< 200 {
                if !snapController.isBusy { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }

        func remove() {
            hotkeys.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

@MainActor
extension GlobalHotkeysTests {
    func testEnvironmentPollingSkipsUnchangedFocusedWindowProbe() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        fixture.hotkeys.start()
        let registered = await fixture.waitForActiveRegistrations()
        XCTAssertTrue(registered)

        let initialProbeCount = await fixture.backend.focusProbeCount()
        let unchangedEnvironmentDetected = await fixture.hotkeys.pollEnvironmentForTesting()
        XCTAssertFalse(unchangedEnvironmentDetected)
        try await Task.sleep(for: .milliseconds(50))
        let unchangedProbeCount = await fixture.backend.focusProbeCount()
        XCTAssertEqual(unchangedProbeCount, initialProbeCount)

        fixture.environment.frontmostPID = 201
        let changedEnvironmentDetected = await fixture.hotkeys.pollEnvironmentForTesting()
        XCTAssertTrue(changedEnvironmentDetected)
        let changedEnvironmentWasProbed = await fixture.backend.waitForFocusProbeCount(greaterThan: initialProbeCount)
        XCTAssertTrue(changedEnvironmentWasProbed)
    }

    func testFocusedWindowChangesWithinSameProcessReconcileInBothDirections() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        fixture.hotkeys.start()
        let initiallyRegistered = await fixture.waitForActiveRegistrations()
        XCTAssertTrue(initiallyRegistered)
        let initialFocusIdentityDetected = await fixture.hotkeys.pollEnvironmentForTesting()
        XCTAssertFalse(initialFocusIdentityDetected)

        await fixture.backend.setFocusedWindowEligible(false)
        fixture.environment.focusedWindowIdentity = 2
        let focusedWindowChangeDetected = await fixture.hotkeys.pollEnvironmentForTesting()
        XCTAssertTrue(focusedWindowChangeDetected)
        let ineligibleWindowReleasedHotkeys = await fixture.waitForNoActiveRegistrations()
        XCTAssertTrue(ineligibleWindowReleasedHotkeys)
        XCTAssertTrue(fixture.registrar.activeIDs.isEmpty)

        await fixture.backend.setFocusedWindowEligible(true)
        fixture.environment.focusedWindowIdentity = 3
        let focusedWindowRestoreDetected = await fixture.hotkeys.pollEnvironmentForTesting()
        XCTAssertTrue(focusedWindowRestoreDetected)
        let eligibleWindowRegistered = await fixture.waitForActiveRegistrations()
        XCTAssertTrue(eligibleWindowRegistered)
    }

    func testAccessibilityPermissionRevocationAndRestoreWithinSameProcess() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        fixture.hotkeys.start()
        let initiallyRegistered = await fixture.waitForActiveRegistrations()
        XCTAssertTrue(initiallyRegistered)

        fixture.environment.isTrusted = false
        let revokedPermissionDetected = await fixture.hotkeys.pollEnvironmentForTesting()
        XCTAssertTrue(revokedPermissionDetected)
        let revokedPermissionReleasedHotkeys = await fixture.waitForNoActiveRegistrations()
        XCTAssertTrue(revokedPermissionReleasedHotkeys)

        fixture.environment.isTrusted = true
        let restoredPermissionDetected = await fixture.hotkeys.pollEnvironmentForTesting()
        XCTAssertTrue(restoredPermissionDetected)
        let restoredPermissionRegisteredHotkeys = await fixture.waitForActiveRegistrations()
        XCTAssertTrue(restoredPermissionRegisteredHotkeys)
    }

    func testDelayedFocusedWindowIdentityIsDiscardedAfterProcessChanges() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        fixture.hotkeys.start()
        let initiallyRegistered = await fixture.waitForActiveRegistrations()
        XCTAssertTrue(initiallyRegistered)
        _ = await fixture.hotkeys.pollEnvironmentForTesting()
        let initialProbeCount = await fixture.backend.focusProbeCount()

        fixture.environment.blockNextFocusIdentityRead()
        let stalePoll = Task { await fixture.hotkeys.pollEnvironmentForTesting() }
        let identityReadStarted = await fixture.environment.waitForFocusIdentityRead()
        XCTAssertTrue(identityReadStarted)

        fixture.environment.frontmostPID = 201
        let processChangeDetected = await fixture.hotkeys.pollEnvironmentForTesting()
        XCTAssertTrue(processChangeDetected)
        let newProcessWasProbed = await fixture.backend.waitForFocusProbeCount(greaterThan: initialProbeCount)
        XCTAssertTrue(newProcessWasProbed)

        let probesAfterProcessChange = await fixture.backend.focusProbeCount()
        fixture.environment.releaseBlockedFocusIdentityRead()
        _ = await stalePoll.value
        try await Task.sleep(for: .milliseconds(50))
        let probesAfterStaleResponse = await fixture.backend.focusProbeCount()
        XCTAssertEqual(probesAfterStaleResponse, probesAfterProcessChange)
    }
}

@MainActor
private final class FakeKeyboardEnvironment {
    var frontmostPID: pid_t? = 200
    var isTrusted = true
    var focusedWindowIdentity: Int? = 1
    private var blocksNextFocusIdentityRead = false
    private var focusIdentityReadStarted = false
    private var focusIdentityReadContinuation: CheckedContinuation<Int?, Never>?

    func blockNextFocusIdentityRead() { blocksNextFocusIdentityRead = true }

    func readFocusedWindowIdentity() async -> Int? {
        guard blocksNextFocusIdentityRead else { return focusedWindowIdentity }
        blocksNextFocusIdentityRead = false
        focusIdentityReadStarted = true
        return await withCheckedContinuation { focusIdentityReadContinuation = $0 }
    }

    func waitForFocusIdentityRead() async -> Bool {
        for _ in 0 ..< 100 {
            if focusIdentityReadStarted { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func releaseBlockedFocusIdentityRead() {
        focusIdentityReadContinuation?.resume(returning: focusedWindowIdentity)
        focusIdentityReadContinuation = nil
    }
}

@MainActor
private final class FakeHotKeyRegistrar: HotKeyRegistering {
    private(set) var totalRegistrations = 0
    private(set) var activeIDs = Set<UInt32>()
    private(set) var callbacks: [UInt32: @Sendable () -> Void] = [:]
    var systemConflict: Bool
    var registrationStatus: OSStatus
    var unregisterStatus = noErr

    init(systemConflict: Bool, registrationStatus: OSStatus) {
        self.systemConflict = systemConflict
        self.registrationStatus = registrationStatus
    }

    func conflictsWithSystemShortcut(_ shortcut: KeyboardShortcut) -> Bool { systemConflict }

    func register(_ shortcut: KeyboardShortcut, id: UInt32, handler: @escaping @Sendable () -> Void) -> OSStatus {
        guard registrationStatus == noErr else { return registrationStatus }
        totalRegistrations += 1
        activeIDs.insert(id)
        callbacks[id] = handler
        return noErr
    }

    func unregister(id: UInt32) -> OSStatus {
        guard unregisterStatus == noErr else { return unregisterStatus }
        activeIDs.remove(id)
        return noErr
    }

    func shutdown() {}
}

private actor HotkeyFakeWindowBackend: KeyboardWindowOperating {
    private let token = RuntimeWindowToken(id: UUID(), pid: 200)
    private var frame: CGRect
    private var writes = 0
    private var focusProbes = 0
    private var focusedWindowEligible = true
    private var blockFocus = false
    private var focusStarted = false
    private var focusContinuation: CheckedContinuation<RuntimeWindowSnapshot, Never>?
    private var blockPreflight = false
    private var preflightStarted = false
    private var preflightContinuation: CheckedContinuation<Void, Never>?

    init(frame: CGRect) { self.frame = frame }

    func blockNextFocus() { blockFocus = true }

    func blockNextPreflight() { blockPreflight = true }

    func setFocusedWindowEligible(_ eligible: Bool) { focusedWindowEligible = eligible }

    func focusedWindow(applicationPID: pid_t, ownPID: pid_t) async throws -> RuntimeWindowSnapshot {
        focusProbes += 1
        guard focusedWindowEligible else { throw WindowManagementError.invalidFocusedWindow }
        if blockFocus {
            blockFocus = false
            focusStarted = true
            return await withCheckedContinuation { focusContinuation = $0 }
        }
        return RuntimeWindowSnapshot(token: token, frame: frame)
    }

    func focusProbeCount() -> Int { focusProbes }

    func waitForFocusProbeCount(greaterThan count: Int) async -> Bool {
        for _ in 0 ..< 100 {
            if focusProbes > count { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func waitForFocusProbe() async -> Bool {
        for _ in 0 ..< 100 {
            if focusStarted { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func releaseBlockedFocus() {
        focusContinuation?.resume(returning: RuntimeWindowSnapshot(token: token, frame: frame))
        focusContinuation = nil
    }

    func waitForPreflight() async -> Bool {
        for _ in 0 ..< 100 {
            if preflightStarted { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func releaseBlockedPreflight() {
        preflightContinuation?.resume()
        preflightContinuation = nil
    }

    func retain(_ token: RuntimeWindowToken) async {}

    func move(_ token: RuntimeWindowToken, to frame: CGRect, ticket: PlacementCommitTicket, preflight: @MainActor @Sendable () -> Bool) async throws -> CGRect {
        if blockPreflight {
            blockPreflight = false
            preflightStarted = true
            await withCheckedContinuation { preflightContinuation = $0 }
        }
        guard await preflight(), ticket.beginWrite(now: DispatchTime.now().uptimeNanoseconds) else { throw WindowManagementError.displayConfigurationChanged }
        self.frame = frame
        writes += 1
        return frame
    }

    func restore(_ token: RuntimeWindowToken, to frame: CGRect, ticket: PlacementCommitTicket, preflight: @MainActor @Sendable () -> Bool) async throws -> CGRect {
        if blockPreflight {
            blockPreflight = false
            preflightStarted = true
            await withCheckedContinuation { preflightContinuation = $0 }
        }
        guard await preflight(), ticket.beginWrite(now: DispatchTime.now().uptimeNanoseconds) else { throw WindowManagementError.displayConfigurationChanged }
        self.frame = frame
        writes += 1
        return frame
    }

    func discard(_ token: RuntimeWindowToken) async {}
    func shutdown() async { releaseBlockedFocus() }
    func writeCount() -> Int { writes }
}
