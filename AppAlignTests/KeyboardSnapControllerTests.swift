import XCTest
import ApplicationServices

final class KeyboardSnapControllerTests: XCTestCase {
    @MainActor
    func testManualPlacementAndRestoreRejectInvalidationAfterReadback() throws {
        let frame = CGRect(x: 100, y: 100, width: 300, height: 200)
        let display = Display(runtimeID: RuntimeDisplayID(rawValue: 1), persistentID: nil, sessionID: UUID(),
                              name: "Test", frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                              workArea: CGRect(x: 0, y: 0, width: 1_000, height: 780), isPrimary: true,
                              backingScaleFactor: 1)
        let snapshot = DisplaySnapshot(displays: [display], primaryFrame: display.frame)
        let window = AXWindow(applicationElement: AXUIElementCreateApplication(200),
                              element: AXUIElementCreateSystemWide(), pid: 200)

        let placed = CGRect(x: 10, y: 10, width: 480, height: 380)

        // A control with the same controller dependencies proves that the
        // result boundary still accepts a current ticket for both operations.
        do {
            let validity = PlacementValidity()
            var backendFrame = frame
            let dependencies = PlacementControllerDependencies(
                isAccessibilityTrusted: { true },
                validateWindow: { _ in },
                readFrame: { _ in backendFrame },
                movePlacement: { _, requested, ticket in
                    XCTAssertEqual(ticket.state, .writing)
                    backendFrame = requested
                    return PlacementResult(requestedFrame: requested, actualFrame: requested)
                }
            )
            let controller = PlacementController(
                displayProvider: DisplayProvider(snapshot: snapshot),
                validity: validity,
                refreshDisplayConfiguration: { snapshot },
                dependencies: dependencies,
                initialCapture: CapturedWindow(window: window, originalFrame: frame,
                                               displayFingerprint: snapshot.fingerprint)
            )
            try controller.placeCapturedWindow(in: placed, displayFingerprint: snapshot.fingerprint)
            XCTAssertEqual(controller.actualFrame, placed)
            XCTAssertTrue(controller.statusMessage.contains("Placed and verified"))
            XCTAssertTrue(controller.canRestore)
            controller.restoreCapturedWindow()
            XCTAssertEqual(controller.actualFrame, frame)
            XCTAssertTrue(controller.statusMessage.contains("Restored and verified"))
            XCTAssertTrue(controller.canRestore)
        }

        for restoring in [false, true] {
            let validity = PlacementValidity()
            var backendFrame = frame
            let dependencies = PlacementControllerDependencies(
                isAccessibilityTrusted: { true },
                validateWindow: { _ in },
                readFrame: { _ in backendFrame },
                movePlacement: { _, requested, _ in
                    backendFrame = requested
                    // Simulate the configuration callback arriving after AX
                    // readback but before the controller accepts success.
                    _ = validity.invalidateForConfigurationChange()
                    return PlacementResult(requestedFrame: requested, actualFrame: requested)
                }
            )
            let controller = PlacementController(
                displayProvider: DisplayProvider(snapshot: snapshot),
                validity: validity,
                refreshDisplayConfiguration: { snapshot },
                dependencies: dependencies,
                initialCapture: CapturedWindow(window: window, originalFrame: frame,
                                               displayFingerprint: snapshot.fingerprint)
            )
            if restoring {
                controller.restoreCapturedWindow()
            } else {
                XCTAssertThrowsError(try controller.placeCapturedWindow(in: placed,
                                                                         displayFingerprint: snapshot.fingerprint))
            }
            XCTAssertFalse(controller.statusMessage.contains("verified"))
            XCTAssertEqual(controller.actualFrame, restoring ? frame : placed)
            XCTAssertTrue(controller.hasCapturedWindow)
            XCTAssertTrue(controller.canRestore, "A rejected completion must preserve the original Restore target.")
        }
    }

    @MainActor
    func testFirstMovePreservesOriginalAndRestoreSuccessConsumesSession() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        var settings = fixture.layout.keyboardSettings
        settings.isEnabled = true
        fixture.layout.updateKeyboardSettings(settings)

        fixture.controller.handle(.zone(ZoneID(rawValue: 0)))
        let firstIdle = await fixture.waitUntilIdle()
        XCTAssertTrue(firstIdle)
        let firstWriteCount = await fixture.backend.writeCount()
        XCTAssertEqual(firstWriteCount, 1)
        XCTAssertTrue(fixture.controller.hasRestoreTarget)
        fixture.controller.handle(.zone(ZoneID(rawValue: 1)))
        let secondIdle = await fixture.waitUntilIdle()
        XCTAssertTrue(secondIdle)
        let secondWriteCount = await fixture.backend.writeCount()
        XCTAssertEqual(secondWriteCount, 2)
        let placedFrame = await fixture.backend.currentFrame()
        XCTAssertEqual(placedFrame, fixture.layout.appliedLayoutSnapshot(for: fixture.originalFrame)?.zones.first(where: { $0.id.rawValue == 1 })?.frame)

        fixture.controller.handle(.restore)
        let restoreIdle = await fixture.waitUntilIdle()
        XCTAssertTrue(restoreIdle)
        let totalWriteCount = await fixture.backend.writeCount()
        XCTAssertEqual(totalWriteCount, 3)
        XCTAssertFalse(fixture.controller.hasRestoreTarget)
        let restoredFrame = await fixture.backend.currentFrame()
        XCTAssertEqual(restoredFrame, fixture.originalFrame)
    }

    @MainActor
    func testFailedRestoreKeepsTheOriginalFrameForRetry() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        var settings = fixture.layout.keyboardSettings
        settings.isEnabled = true
        fixture.layout.updateKeyboardSettings(settings)

        fixture.controller.handle(.zone(ZoneID(rawValue: 0)))
        let placementIdle = await fixture.waitUntilIdle()
        XCTAssertTrue(placementIdle)
        await fixture.backend.failNextRestore()
        fixture.controller.handle(.restore)
        let failedRestoreIdle = await fixture.waitUntilIdle()
        XCTAssertTrue(failedRestoreIdle)
        XCTAssertTrue(fixture.controller.hasRestoreTarget)
        XCTAssertTrue(fixture.controller.statusMessage.contains("still saved"))

        fixture.controller.handle(.restore)
        let restoreIdle = await fixture.waitUntilIdle()
        XCTAssertTrue(restoreIdle)
        XCTAssertFalse(fixture.controller.hasRestoreTarget)
        let restoredFrame = await fixture.backend.currentFrame()
        XCTAssertEqual(restoredFrame, fixture.originalFrame)
    }

    @MainActor
    func testUnchangedDisplayConfigurationRestoresExactFrameOutsideWorkArea() async throws {
        let original = CGRect(x: -40, y: -20, width: 300, height: 200)
        let fixture = try await Fixture.make(originalFrame: original,
                                             workArea: CGRect(x: 0, y: 30, width: 1_000, height: 750))
        defer { fixture.remove() }
        var settings = fixture.layout.keyboardSettings
        settings.isEnabled = true
        fixture.layout.updateKeyboardSettings(settings)

        fixture.controller.handle(.zone(ZoneID(rawValue: 0)))
        let placementIdle = await fixture.waitUntilIdle()
        XCTAssertTrue(placementIdle)
        fixture.controller.handle(.restore)
        let restoreIdle = await fixture.waitUntilIdle()
        XCTAssertTrue(restoreIdle)
        let restoredFrame = await fixture.backend.currentFrame()
        XCTAssertEqual(restoredFrame, original)
        XCTAssertFalse(fixture.controller.hasRestoreTarget)
    }

    @MainActor
    func testConfigurationChangeTranslatesRestoreAnchorAndDisconnectKeepsIt() async throws {
        let original = CGRect(x: 600, y: 400, width: 300, height: 200)
        let id = PersistentDisplayID(uuid: UUID())
        let first = makeDisplay(id: id, frame: CGRect(x: 0, y: 0, width: 1_000, height: 800))
        let translated = makeDisplay(id: id, frame: CGRect(x: 1_000, y: 0, width: 1_000, height: 800))
        let fixture = try await Fixture.make(originalFrame: original,
                                             snapshots: Array(repeating: snapshot(first), count: 5) + [snapshot(translated)])
        defer { fixture.remove() }
        var settings = fixture.layout.keyboardSettings
        settings.isEnabled = true
        fixture.layout.updateKeyboardSettings(settings)
        fixture.controller.handle(.zone(ZoneID(rawValue: 0)))
        let placementIdle = await fixture.waitUntilIdle()
        XCTAssertTrue(placementIdle)
        fixture.controller.handle(.restore)
        let restoreIdle = await fixture.waitUntilIdle()
        XCTAssertTrue(restoreIdle)
        let frameAfterMove = await fixture.backend.currentFrame()
        XCTAssertEqual(frameAfterMove, CGRect(x: 1_600, y: 400, width: 300, height: 200))
        XCTAssertFalse(fixture.controller.hasRestoreTarget)

        let disconnectedFixture = try await Fixture.make(originalFrame: original,
                                                         snapshots: Array(repeating: snapshot(first), count: 5)
                                                            + [DisplaySnapshot(displays: [], primaryFrame: .zero)])
        defer { disconnectedFixture.remove() }
        var disconnectedSettings = disconnectedFixture.layout.keyboardSettings
        disconnectedSettings.isEnabled = true
        disconnectedFixture.layout.updateKeyboardSettings(disconnectedSettings)
        disconnectedFixture.controller.handle(.zone(ZoneID(rawValue: 0)))
        let disconnectedPlacementIdle = await disconnectedFixture.waitUntilIdle()
        XCTAssertTrue(disconnectedPlacementIdle)
        disconnectedFixture.controller.handle(.restore)
        let disconnectedRestoreIdle = await disconnectedFixture.waitUntilIdle()
        XCTAssertTrue(disconnectedRestoreIdle)
        XCTAssertTrue(disconnectedFixture.controller.hasRestoreTarget)
        let writes = await disconnectedFixture.backend.writeCount()
        XCTAssertEqual(writes, 1)
    }

    @MainActor
    private struct Fixture {
        let layout: LayoutController
        let backend: FakeKeyboardWindowBackend
        let controller: KeyboardSnapController
        let originalFrame = CGRect(x: 600, y: 400, width: 300, height: 200)
        let directory: URL

        static func make(originalFrame: CGRect = CGRect(x: 600, y: 400, width: 300, height: 200),
                         workArea: CGRect = CGRect(x: 0, y: 0, width: 1_000, height: 800),
                         snapshots: [DisplaySnapshot]? = nil) async throws -> Fixture {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let uuid = UUID()
            let display = Display(
                runtimeID: RuntimeDisplayID(rawValue: 1),
                persistentID: PersistentDisplayID(uuid: uuid),
                sessionID: UUID(), name: "Test", frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                workArea: workArea, isPrimary: true, backingScaleFactor: 1
            )
            let provider = snapshots.map { DisplayProvider(snapshots: $0) }
                ?? DisplayProvider(snapshot: DisplaySnapshot(displays: [display], primaryFrame: display.frame))
            let layout = LayoutController(
                displayProvider: provider,
                storeCoordinator: PersistentStoreCoordinator(directory: directory)
            )
            await layout.loadPersistentState()
            let frame = originalFrame
            let backend = FakeKeyboardWindowBackend(frame: frame)
            let environment = KeyboardEnvironment(frontmostPID: { 200 }, isAccessibilityTrusted: { true }, ownPID: 100)
            let controller = KeyboardSnapController(layoutController: layout, backend: backend, environment: environment)
            return Fixture(layout: layout, backend: backend, controller: controller, directory: directory)
        }

        func waitUntilIdle() async -> Bool {
            for _ in 0 ..< 100 where controller.isBusy {
                try? await Task.sleep(for: .milliseconds(10))
            }
            if controller.isBusy { return false }
            return await layout.flush()
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    private func snapshot(_ display: Display) -> DisplaySnapshot {
        DisplaySnapshot(displays: [display], primaryFrame: display.frame)
    }

    private func makeDisplay(id: PersistentDisplayID, frame: CGRect) -> Display {
        Display(runtimeID: RuntimeDisplayID(rawValue: 1), persistentID: id, sessionID: UUID(), name: "Test",
                frame: frame, workArea: frame, isPrimary: true, backingScaleFactor: 1)
    }
}

@MainActor
extension KeyboardSnapControllerTests {
    @MainActor
    func testKeyboardExtensionExpandsShrinksAndUsesConfiguredModifierRelease() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        var settings = fixture.layout.keyboardSettings
        settings.isEnabled = true
        fixture.layout.updateKeyboardSettings(settings)
        fixture.controller.flagsMonitorStatus(.ready)

        let snapshot = try XCTUnwrap(fixture.layout.appliedLayoutSnapshot(for: fixture.originalFrame))
        let firstZone = try XCTUnwrap(snapshot.zones.first)
        fixture.controller.handle(.zone(firstZone.id))
        let firstIdle = await fixture.waitUntilIdle()
        XCTAssertTrue(firstIdle)
        let placed = await fixture.backend.currentFrame()
        XCTAssertEqual(placed, firstZone.frame)

        let adjacent = try XCTUnwrap(ZoneNavigator.directionalZone(from: firstZone.frame, zones: snapshot.zones,
                                                                     direction: .right, workArea: snapshot.display.workArea,
                                                                     cycle: false, excludingID: firstZone.id))
        fixture.controller.handle(.extend(.right))
        let expandedIdle = await fixture.waitUntilIdle()
        XCTAssertTrue(expandedIdle)
        let expanded = await fixture.backend.currentFrame()
        XCTAssertEqual(expanded, ZoneSelectionEngine.union(of: [firstZone.frame, adjacent.frame]))

        fixture.controller.handle(.direction(.left))
        let normalMoveIdle = await fixture.waitUntilIdle()
        XCTAssertTrue(normalMoveIdle)
        let movedToEndpoint = await fixture.backend.currentFrame()
        XCTAssertEqual(movedToEndpoint, firstZone.frame)
        fixture.controller.handle(.extend(.right))
        let reextendedIdle = await fixture.waitUntilIdle()
        XCTAssertTrue(reextendedIdle)
        let reextended = await fixture.backend.currentFrame()
        XCTAssertEqual(reextended, ZoneSelectionEngine.union(of: [firstZone.frame, adjacent.frame]))

        fixture.controller.handle(.extend(.left))
        let shrunkIdle = await fixture.waitUntilIdle()
        XCTAssertTrue(shrunkIdle)
        let shrunk = await fixture.backend.currentFrame()
        XCTAssertEqual(shrunk, firstZone.frame)

        let requiredFlags = CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue
            | CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue
        fixture.controller.extensionModifierFlagsChanged(requiredFlags)
        fixture.controller.extensionModifierFlagsChanged(requiredFlags & ~CGEventFlags.maskShift.rawValue)
        fixture.controller.handle(.extend(.right))
        let reanchoredIdle = await fixture.waitUntilIdle()
        XCTAssertTrue(reanchoredIdle)
        let reanchored = await fixture.backend.currentFrame()
        XCTAssertEqual(reanchored, ZoneSelectionEngine.union(of: [firstZone.frame, adjacent.frame]))
        let writes = await fixture.backend.writeCount()
        XCTAssertEqual(writes, 6)
    }

    @MainActor
    func testKeyboardExtensionUnavailableUntilModifierMonitorReady() async throws {
        let fixture = try await Fixture.make(originalFrame: CGRect(x: 100, y: 100, width: 300, height: 200))
        defer { fixture.remove() }
        var settings = fixture.layout.keyboardSettings
        settings.isEnabled = true
        fixture.layout.updateKeyboardSettings(settings)
        fixture.controller.handle(.extend(.right))
        let unavailableIdle = await fixture.waitUntilIdle()
        XCTAssertTrue(unavailableIdle)
        var writes = await fixture.backend.writeCount()
        XCTAssertEqual(writes, 0)
        XCTAssertTrue(fixture.controller.statusMessage.contains("modifier monitoring is not ready"))

        fixture.controller.flagsMonitorStatus(.ready)
        fixture.controller.handle(.extend(.right))
        let readyIdle = await fixture.waitUntilIdle()
        XCTAssertTrue(readyIdle)
        writes = await fixture.backend.writeCount()
        XCTAssertEqual(writes, 1)
    }

}

private actor FakeKeyboardWindowBackend: KeyboardWindowOperating {
    private let token = RuntimeWindowToken(id: UUID(), pid: 200)
    private var frame: CGRect
    private var writes = 0
    private var failRestore = false

    init(frame: CGRect) { self.frame = frame }

    func focusedWindow(applicationPID: pid_t, ownPID: pid_t) async throws -> RuntimeWindowSnapshot {
        RuntimeWindowSnapshot(token: token, frame: frame)
    }

    func retain(_ token: RuntimeWindowToken) async {}

    func move(_ token: RuntimeWindowToken, to frame: CGRect, ticket: PlacementCommitTicket, preflight: @MainActor @Sendable () -> Bool) async throws -> CGRect {
        guard await preflight(), ticket.beginWrite(now: DispatchTime.now().uptimeNanoseconds) else { throw WindowManagementError.displayConfigurationChanged }
        self.frame = frame
        writes += 1
        return frame
    }

    func restore(_ token: RuntimeWindowToken, to frame: CGRect, ticket: PlacementCommitTicket, preflight: @MainActor @Sendable () -> Bool) async throws -> CGRect {
        guard await preflight(), ticket.beginWrite(now: DispatchTime.now().uptimeNanoseconds) else { throw WindowManagementError.displayConfigurationChanged }
        if failRestore {
            failRestore = false
            throw WindowManagementError.noCapturedWindow
        }
        self.frame = frame
        writes += 1
        return frame
    }

    func discard(_ token: RuntimeWindowToken) async {}
    func shutdown() async {}
    func currentFrame() -> CGRect { frame }
    func writeCount() -> Int { writes }
    func failNextRestore() { failRestore = true }
}
