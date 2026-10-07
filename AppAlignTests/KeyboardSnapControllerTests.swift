import XCTest

final class KeyboardSnapControllerTests: XCTestCase {
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
    private struct Fixture {
        let layout: LayoutController
        let backend: FakeKeyboardWindowBackend
        let controller: KeyboardSnapController
        let originalFrame = CGRect(x: 600, y: 400, width: 300, height: 200)
        let directory: URL

        static func make() async throws -> Fixture {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let uuid = UUID()
            let display = Display(
                runtimeID: RuntimeDisplayID(rawValue: 1),
                persistentID: PersistentDisplayID(uuid: uuid),
                sessionID: UUID(), name: "Test", frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                workArea: CGRect(x: 0, y: 0, width: 1_000, height: 800), isPrimary: true, backingScaleFactor: 1
            )
            let layout = LayoutController(
                displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [display], primaryFrame: display.frame)),
                storeCoordinator: PersistentStoreCoordinator(directory: directory)
            )
            await layout.loadPersistentState()
            let frame = CGRect(x: 600, y: 400, width: 300, height: 200)
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

    func move(_ token: RuntimeWindowToken, to frame: CGRect, preflight: @MainActor @Sendable () -> Bool) async throws -> CGRect {
        guard await preflight() else { throw WindowManagementError.displayConfigurationChanged }
        self.frame = frame
        writes += 1
        return frame
    }

    func restore(_ token: RuntimeWindowToken, to frame: CGRect, preflight: @MainActor @Sendable () -> Bool) async throws -> CGRect {
        guard await preflight() else { throw WindowManagementError.displayConfigurationChanged }
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
