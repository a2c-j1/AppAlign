import Foundation
import XCTest

final class KeyboardLifecycleTests: XCTestCase {
    @MainActor
    func testDisableThenImmediateEnableCancelsOldWriteButAllowsNewAction() async throws {
        let fixture = try await LifecycleFixture.make()
        defer { fixture.remove() }
        await fixture.backend.arm(.beforeWrite)
        fixture.controller.handle(.zone(ZoneID(rawValue: 0)))
        try await fixture.waitForBarrier()
        var settings = fixture.layout.keyboardSettings
        settings.isEnabled = false
        fixture.layout.updateKeyboardSettings(settings)
        fixture.controller.invalidatePendingOperations()
        settings.isEnabled = true
        fixture.layout.updateKeyboardSettings(settings)
        fixture.controller.invalidatePendingOperations()
        await fixture.backend.release()
        try await fixture.waitUntilIdle()
        let oldWrites = await fixture.backend.writeCount()
        XCTAssertEqual(oldWrites, 0)
        fixture.controller.handle(.zone(ZoneID(rawValue: 1)))
        try await fixture.waitUntilIdle()
        let newWrites = await fixture.backend.writeCount()
        XCTAssertEqual(newWrites, 1)
        fixture.controller.handle(.restore)
        try await fixture.waitUntilIdle()
        let restored = await fixture.backend.currentFrame()
        XCTAssertEqual(restored, fixture.originalFrame)
        _ = await fixture.layout.flush()
    }

    @MainActor
    func testProcessTerminationDuringCaptureInvalidatesPendingOperation() async throws {
        let fixture = try await LifecycleFixture.make()
        defer { fixture.remove() }
        await fixture.backend.arm(.capture)
        fixture.controller.handle(.zone(ZoneID(rawValue: 0)))
        try await fixture.waitForBarrier()
        await fixture.controller.discardProcess(200)
        await fixture.backend.release()
        try await fixture.waitUntilIdle()
        let writes = await fixture.backend.writeCount()
        XCTAssertEqual(writes, 0)
        XCTAssertFalse(fixture.controller.hasRestoreTarget)
        _ = await fixture.layout.flush()
    }

    @MainActor
    func testDisableAndShutdownDuringCaptureDoNotWriteOrReviveSessions() async throws {
        for shuttingDown in [false, true] {
            let fixture = try await LifecycleFixture.make()
            defer { fixture.remove() }
            await fixture.backend.arm(.capture)
            fixture.controller.handle(.zone(ZoneID(rawValue: 0)))
            try await fixture.waitForBarrier()
            if shuttingDown {
                await fixture.controller.shutdown()
            } else {
                var settings = fixture.layout.keyboardSettings
                settings.isEnabled = false
                fixture.layout.updateKeyboardSettings(settings)
            }
            await fixture.backend.release()
            try await fixture.waitUntilIdle()
            let writes = await fixture.backend.writeCount()
            XCTAssertEqual(writes, 0)
            XCTAssertFalse(fixture.controller.hasRestoreTarget)
            _ = await fixture.layout.flush()
        }
    }

    @MainActor
    func testDisableAndShutdownBeforeWritePreventAdditionalWrites() async throws {
        for shuttingDown in [false, true] {
            let fixture = try await LifecycleFixture.make()
            defer { fixture.remove() }
            await fixture.backend.arm(.beforeWrite)
            fixture.controller.handle(.zone(ZoneID(rawValue: 0)))
            try await fixture.waitForBarrier()
            if shuttingDown {
                await fixture.controller.shutdown()
            } else {
                var settings = fixture.layout.keyboardSettings
                settings.isEnabled = false
                fixture.layout.updateKeyboardSettings(settings)
            }
            await fixture.backend.release()
            try await fixture.waitUntilIdle()
            let writes = await fixture.backend.writeCount()
            XCTAssertEqual(writes, 0)
            XCTAssertEqual(fixture.controller.hasRestoreTarget, !shuttingDown)
            _ = await fixture.layout.flush()
        }
    }

    @MainActor
    func testOwnAppForegroundAndPermissionLossDuringWriteWaitPreventWrite() async throws {
        for losesPermission in [false, true] {
            let fixture = try await LifecycleFixture.make()
            defer { fixture.remove() }
            await fixture.backend.arm(.beforeWrite)
            fixture.controller.handle(.zone(ZoneID(rawValue: 0)))
            try await fixture.waitForBarrier()
            if losesPermission { fixture.context.trusted = false } else { fixture.context.pid = 100 }
            await fixture.backend.release()
            try await fixture.waitUntilIdle()
            let writes = await fixture.backend.writeCount()
            XCTAssertEqual(writes, 0)
            _ = await fixture.layout.flush()
        }
    }

    @MainActor
    func testSamePIDWindowSwitchAfterPreflightWaitDoesNotWriteOldWindow() async throws {
        let fixture = try await LifecycleFixture.make()
        defer { fixture.remove() }
        await fixture.backend.arm(.beforeWrite)
        fixture.controller.handle(.zone(ZoneID(rawValue: 0)))
        try await fixture.waitForBarrier()
        await fixture.backend.switchFocusedWindow()
        await fixture.backend.release()
        try await fixture.waitUntilIdle()
        let writes = await fixture.backend.writeCount()
        XCTAssertEqual(writes, 0)
        XCTAssertTrue(fixture.controller.statusMessage.contains("failed"))
        _ = await fixture.layout.flush()
    }

    @MainActor
    func testLayoutChangeWhileWriteWaitsRejectsStaleSnapshot() async throws {
        let fixture = try await LifecycleFixture.make()
        defer { fixture.remove() }
        await fixture.backend.arm(.beforeWrite)
        fixture.controller.handle(.zone(ZoneID(rawValue: 0)))
        try await fixture.waitForBarrier()
        fixture.layout.template = .columns
        let saved = await fixture.layout.flush()
        XCTAssertTrue(saved)
        await fixture.backend.release()
        try await fixture.waitUntilIdle()
        let writes = await fixture.backend.writeCount()
        XCTAssertEqual(writes, 0)
    }

    @MainActor
    func testSuspendDuringMoveResultThenResumeRetainsOriginalRestoreToken() async throws {
        let fixture = try await LifecycleFixture.make()
        defer { fixture.remove() }
        await fixture.backend.arm(.afterWrite)
        fixture.controller.handle(.zone(ZoneID(rawValue: 0)))
        try await fixture.waitForBarrier()
        fixture.controller.suspend()
        await fixture.backend.release()
        try await fixture.waitUntilIdle()
        XCTAssertTrue(fixture.controller.hasRestoreTarget)
        fixture.controller.resume()
        fixture.controller.handle(.restore)
        try await fixture.waitUntilIdle()
        let restored = await fixture.backend.currentFrame()
        XCTAssertEqual(restored, fixture.originalFrame)
        let writes = await fixture.backend.writeCount()
        XCTAssertEqual(writes, 2)
        XCTAssertFalse(fixture.controller.hasRestoreTarget)
        _ = await fixture.layout.flush()
    }

    @MainActor
    func testShutdownWhileMoveResultWaitsCannotReviveSession() async throws {
        let fixture = try await LifecycleFixture.make()
        defer { fixture.remove() }
        await fixture.backend.arm(.afterWrite)
        fixture.controller.handle(.zone(ZoneID(rawValue: 0)))
        try await fixture.waitForBarrier()
        await fixture.controller.shutdown()
        await fixture.backend.release()
        try await fixture.waitUntilIdle()
        XCTAssertFalse(fixture.controller.hasRestoreTarget)
        fixture.controller.handle(.restore)
        let writes = await fixture.backend.writeCount()
        XCTAssertEqual(writes, 1, "Shutdown must reject the queued result and later actions.")
        _ = await fixture.layout.flush()
    }

    @MainActor
    func testObsoleteProbeCannotDiscardTokenOwnedByRestoreSession() async throws {
        let fixture = try await LifecycleFixture.make()
        defer { fixture.remove() }
        fixture.controller.handle(.zone(ZoneID(rawValue: 0)))
        try await fixture.waitUntilIdle()
        let probe = try await fixture.backend.focusedWindow(applicationPID: 200, ownPID: 100)
        fixture.controller.suspend()
        await fixture.controller.discardProbeIfUnowned(probe.token)
        fixture.controller.resume()
        fixture.controller.handle(.restore)
        try await fixture.waitUntilIdle()
        let restored = await fixture.backend.currentFrame()
        XCTAssertEqual(restored, fixture.originalFrame)
        XCTAssertFalse(fixture.controller.hasRestoreTarget)
        _ = await fixture.layout.flush()
    }

    @MainActor
    func testSessionCapacityRejectsNewWindowWithoutLosingEarlierRestore() async throws {
        let fixture = try await LifecycleFixture.make()
        defer { fixture.remove() }
        let earliest = await fixture.backend.currentToken()
        for index in 0 ..< 65 {
            if index > 0 { await fixture.backend.switchFocusedWindow() }
            fixture.controller.handle(.zone(ZoneID(rawValue: 0)))
            try await fixture.waitUntilIdle()
        }
        XCTAssertTrue(fixture.controller.statusMessage.contains("full"))
        let writesBeforeRestore = await fixture.backend.writeCount()
        XCTAssertEqual(writesBeforeRestore, 64)
        let placed = try XCTUnwrap(fixture.layout.appliedLayoutSnapshot(for: fixture.originalFrame)?.zones.first?.frame)
        await fixture.backend.focus(earliest, frame: placed)
        fixture.controller.handle(.restore)
        try await fixture.waitUntilIdle()
        let restored = await fixture.backend.currentFrame()
        XCTAssertEqual(restored, fixture.originalFrame)
        _ = await fixture.layout.flush()
    }

    @MainActor
    func testPartialReadbackFailureKeepsOriginalAndDoesNotAdvanceNumberOrder() async throws {
        let fixture = try await LifecycleFixture.make()
        defer { fixture.remove() }
        var settings = fixture.layout.keyboardSettings
        settings.mode = .zoneOrder
        fixture.layout.updateKeyboardSettings(settings)
        _ = await fixture.layout.flush()
        await fixture.backend.mismatchNextWrite()
        fixture.controller.handle(.zone(ZoneID(rawValue: 2)))
        try await fixture.waitUntilIdle()
        XCTAssertTrue(fixture.controller.statusMessage.contains("failed"))
        XCTAssertTrue(fixture.controller.hasRestoreTarget)
        fixture.controller.handle(.next)
        try await fixture.waitUntilIdle()
        let nextFrame = await fixture.backend.currentFrame()
        XCTAssertEqual(nextFrame, fixture.layout.appliedLayoutSnapshot(for: fixture.originalFrame)?.zones.first?.frame)
        fixture.controller.handle(.restore)
        try await fixture.waitUntilIdle()
        let restored = await fixture.backend.currentFrame()
        XCTAssertEqual(restored, fixture.originalFrame)
        _ = await fixture.layout.flush()
    }
}

extension KeyboardLifecycleTests {
    @MainActor
    func testDragGateCancelsPendingKeyboardWriteAndPreservesRestoreFrame() async throws {
        let fixture = try await LifecycleFixture.make()
        defer { fixture.remove() }
        await fixture.backend.arm(.beforeWrite)
        fixture.controller.handle(.zone(ZoneID(rawValue: 0)))
        try await fixture.waitForBarrier()
        fixture.controller.setDragGateClosed(true)
        await fixture.backend.release()
        try await fixture.waitUntilIdle()
        let cancelledWrites = await fixture.backend.writeCount()
        XCTAssertEqual(cancelledWrites, 0)

        fixture.controller.setDragGateClosed(false)
        fixture.controller.handle(.zone(ZoneID(rawValue: 0)))
        try await fixture.waitUntilIdle()
        fixture.controller.handle(.restore)
        try await fixture.waitUntilIdle()
        let restored = await fixture.backend.currentFrame()
        XCTAssertEqual(restored, fixture.originalFrame)
        let writes = await fixture.backend.writeCount()
        XCTAssertEqual(writes, 2)
        _ = await fixture.layout.flush()
    }

    @MainActor
    func testDragGateReleaseDuringQuitSuspendCannotRestoreUntilResume() async throws {
        let fixture = try await LifecycleFixture.make()
        defer { fixture.remove() }
        fixture.controller.handle(.zone(ZoneID(rawValue: 0)))
        try await fixture.waitUntilIdle()
        let placedWrites = await fixture.backend.writeCount()
        XCTAssertEqual(placedWrites, 1)

        fixture.controller.suspend()
        fixture.controller.setDragGateClosed(false)
        fixture.controller.handle(.restore)
        let writesWhileSuspended = await fixture.backend.writeCount()
        XCTAssertEqual(writesWhileSuspended, 1)
        XCTAssertTrue(fixture.controller.hasRestoreTarget)

        fixture.controller.resume()
        fixture.controller.handle(.restore)
        try await fixture.waitUntilIdle()
        let restored = await fixture.backend.currentFrame()
        XCTAssertEqual(restored, fixture.originalFrame)
        let writesAfterResume = await fixture.backend.writeCount()
        XCTAssertEqual(writesAfterResume, 2)
        _ = await fixture.layout.flush()
    }
}

private enum LifecycleTestError: Error { case timeout }

@MainActor
private final class LifecycleContext {
    var pid: pid_t? = 200
    var trusted = true
}

@MainActor
private struct LifecycleFixture {
    let layout: LayoutController
    let backend: LifecycleWindowBackend
    let controller: KeyboardSnapController
    let context: LifecycleContext
    let directory: URL
    let originalFrame = CGRect(x: 600, y: 400, width: 300, height: 200)

    static func make() async throws -> LifecycleFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Issue6-lifecycle-\(UUID().uuidString)")
        let area = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let display = Display(runtimeID: RuntimeDisplayID(rawValue: 1), persistentID: PersistentDisplayID(uuid: UUID()),
                              sessionID: UUID(), name: "Test", frame: area, workArea: area, isPrimary: true, backingScaleFactor: 1)
        let layout = LayoutController(displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [display], primaryFrame: area)),
                                      storeCoordinator: PersistentStoreCoordinator(directory: directory))
        await layout.loadPersistentState()
        var settings = layout.keyboardSettings
        settings.isEnabled = true
        layout.updateKeyboardSettings(settings)
        let ready = await layout.flush()
        XCTAssertTrue(ready)
        let context = LifecycleContext()
        let backend = LifecycleWindowBackend()
        let environment = KeyboardEnvironment(frontmostPID: { context.pid }, isAccessibilityTrusted: { context.trusted }, ownPID: 100)
        let controller = KeyboardSnapController(layoutController: layout, backend: backend, environment: environment)
        return LifecycleFixture(layout: layout, backend: backend, controller: controller, context: context, directory: directory)
    }

    func waitForBarrier() async throws {
        for _ in 0 ..< 200 {
            if await backend.isBlocked() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw LifecycleTestError.timeout
    }

    func waitUntilIdle() async throws {
        for _ in 0 ..< 200 {
            if !controller.isBusy { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw LifecycleTestError.timeout
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// This fake enforces the backend contract: the live focused token is checked after the preflight await.
private actor LifecycleWindowBackend: KeyboardWindowOperating {
    enum Stage { case capture, beforeWrite, afterWrite }
    private var token = RuntimeWindowToken(id: UUID(), pid: 200)
    private var frame = CGRect(x: 600, y: 400, width: 300, height: 200)
    private var validTokens = Set<UUID>()
    private var writes = 0
    private var armed: Stage?
    private var continuation: CheckedContinuation<Void, Never>?
    private var mismatch = false

    func arm(_ stage: Stage) { armed = stage }
    func isBlocked() -> Bool { continuation != nil }
    func release() { continuation?.resume(); continuation = nil }
    func writeCount() -> Int { writes }
    func currentFrame() -> CGRect { frame }
    func currentToken() -> RuntimeWindowToken { token }
    func mismatchNextWrite() { mismatch = true }
    func switchFocusedWindow() {
        token = RuntimeWindowToken(id: UUID(), pid: 200)
        frame = CGRect(x: 600, y: 400, width: 300, height: 200)
    }
    func focus(_ selected: RuntimeWindowToken, frame: CGRect) { token = selected; self.frame = frame }

    func focusedWindow(applicationPID: pid_t, ownPID: pid_t) async throws -> RuntimeWindowSnapshot {
        let captured = token
        validTokens.insert(captured.id)
        await pause(.capture)
        return RuntimeWindowSnapshot(token: captured, frame: frame)
    }

    func retain(_ token: RuntimeWindowToken) async { validTokens.insert(token.id) }
    func discard(_ token: RuntimeWindowToken) async { validTokens.remove(token.id) }
    func shutdown() async { validTokens.removeAll() }

    func move(_ token: RuntimeWindowToken, to requested: CGRect, preflight: @MainActor @Sendable () -> Bool) async throws -> CGRect {
        await pause(.beforeWrite)
        guard await preflight(), token == self.token, validTokens.contains(token.id) else {
            throw WindowManagementError.invalidFocusedWindow
        }
        frame = mismatch ? requested.offsetBy(dx: 20, dy: 0) : requested
        mismatch = false
        writes += 1
        await pause(.afterWrite)
        return frame
    }

    func restore(_ token: RuntimeWindowToken, to frame: CGRect, preflight: @MainActor @Sendable () -> Bool) async throws -> CGRect {
        try await move(token, to: frame, preflight: preflight)
    }

    private func pause(_ stage: Stage) async {
        guard armed == stage else { return }
        armed = nil
        await withCheckedContinuation { continuation = $0 }
    }
}
