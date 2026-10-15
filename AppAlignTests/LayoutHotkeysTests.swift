import Carbon.HIToolbox
import CoreGraphics
import Foundation
import XCTest

@MainActor
final class LayoutHotkeysTests: XCTestCase {
    func testCarbonRouteAndInputCoreShareAcceptedSwitchReleaseOrder() async throws {
        let fixture = try await LayoutHotkeyFixture()
        defer { fixture.cleanup() }
        let inbox = OrderedInteractionInbox()
        let core = InputMonitorCore(resourceFactory: .init { _, _ in OrderedTestTapResource() }, inbox: inbox)
        let ready = expectation(description: "input ready")
        var order: [String] = []
        core.start(onEvent: { order.append(String(describing: $0.kind)) }, onStatus: { if $0 == .ready { ready.fulfill() } })
        defer { core.stop() }
        await fulfillment(of: [ready], timeout: 2)
        let registrar = LayoutTestRegistrar()
        let route = LayoutHotkeys(layoutController: fixture.layout, inbox: inbox, registrar: registrar,
                                  sampling: .init(point: { CGPoint(x: 12, y: 34) }, flags: { 17 })) { _, point, flags in
            XCTAssertEqual(point, CGPoint(x: 12, y: 34))
            XCTAssertEqual(flags, 17)
            order.append("switch")
        }
        route.start()
        defer { route.shutdown() }
        let id = try XCTUnwrap(registrar.ids.first)
        core.accept(fixture.payload(.leftDown, type: .leftMouseDown))
        registrar.fire(id)
        core.accept(fixture.payload(.leftUp, type: .leftMouseUp))
        let done = expectation(description: "accepted batch complete")
        XCTAssertTrue(inbox.enqueueControl { done.fulfill() })
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(order, ["leftDown", "switch", "leftUp"])
    }

    func testPendingConfigurationAndShutdownRejectOldQueuedCallback() async throws {
        let fixture = try await LayoutHotkeyFixture()
        defer { fixture.cleanup() }
        let inbox = OrderedInteractionInbox()
        let registrar = LayoutTestRegistrar()
        var calls = 0
        let route = LayoutHotkeys(layoutController: fixture.layout, inbox: inbox, registrar: registrar,
                                  sampling: .init(point: { .zero }, flags: { 0 })) { _, _, _ in calls += 1 }
        route.start()
        let old = try XCTUnwrap(registrar.ids.first)
        registrar.fire(old)
        route.setConfigurationPending(true)
        XCTAssertTrue(registrar.ids.isEmpty)
        let blocked = expectation(description: "blocked callback drained")
        XCTAssertTrue(inbox.enqueueControl { blocked.fulfill() })
        await fulfillment(of: [blocked], timeout: 2)
        XCTAssertEqual(calls, 0)
        route.setConfigurationPending(false)
        let current = try XCTUnwrap(registrar.ids.first)
        XCTAssertNotEqual(current, old)
        registrar.fire(current)
        let control = expectation(description: "success control")
        XCTAssertTrue(inbox.enqueueControl { control.fulfill() })
        await fulfillment(of: [control], timeout: 2)
        XCTAssertEqual(calls, 1)
        registrar.fire(current)
        route.shutdown()
        let quit = expectation(description: "shutdown callback drained")
        XCTAssertTrue(inbox.enqueueControl { quit.fulfill() })
        await fulfillment(of: [quit], timeout: 2)
        XCTAssertEqual(calls, 1)
    }

    func testDuplicateChordsAndPlacementConflictAreNotRegistered() async throws {
        let fixture = try await LayoutHotkeyFixture()
        defer { fixture.cleanup() }
        let otherID = UUID()
        let stored = try XCTUnwrap(fixture.layout.savedLayouts[fixture.layoutID])
        fixture.layout.savedLayouts[otherID] = try fixture.layout.reidentified(stored, id: otherID)
        fixture.layout.layoutHotkeySettings.bindings[otherID] = fixture.shortcut
        let registrar = LayoutTestRegistrar()
        let route = LayoutHotkeys(layoutController: fixture.layout, inbox: OrderedInteractionInbox(), registrar: registrar) { _, _, _ in }
        route.start()
        defer { route.shutdown() }
        XCTAssertTrue(registrar.ids.isEmpty)
        fixture.layout.layoutHotkeySettings.bindings.removeValue(forKey: otherID)
        fixture.layout.keyboardSettings.isEnabled = true
        fixture.layout.keyboardSettings.shortcuts = [.next: fixture.shortcut]
        route.settingsDidChange()
        XCTAssertTrue(registrar.ids.isEmpty)
        fixture.layout.keyboardSettings.isEnabled = false
        route.settingsDidChange()
        XCTAssertEqual(registrar.ids.count, 1)
    }

    func testFailedReleaseDoesNotCreateDuplicateAndStaleHandlerCannotAct() async throws {
        let fixture = try await LayoutHotkeyFixture()
        defer { fixture.cleanup() }
        let registrar = LayoutTestRegistrar()
        let inbox = OrderedInteractionInbox()
        var calls = 0
        let route = LayoutHotkeys(layoutController: fixture.layout, inbox: inbox, registrar: registrar,
                                  sampling: .init(point: { .zero }, flags: { 0 })) { _, _, _ in calls += 1 }
        route.start()
        let old = try XCTUnwrap(registrar.ids.first)
        registrar.failRelease = true
        route.settingsDidChange()
        XCTAssertEqual(registrar.ids, [old])
        XCTAssertEqual(registrar.registerCount, 1)
        registrar.fire(old)
        let done = expectation(description: "stale callback complete")
        XCTAssertTrue(inbox.enqueueControl { done.fulfill() })
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(calls, 0)
        registrar.failRelease = false
        route.settingsDidChange()
        XCTAssertEqual(registrar.ids.count, 1)
        XCTAssertNotEqual(registrar.ids.first, old)
        route.shutdown()
    }
}

@MainActor
private final class LayoutHotkeyFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppAlign-issue10-route-" + UUID().uuidString)
    let layout: LayoutController
    let layoutID = PersistentStoreCoordinator.defaultLayoutID
    let shortcut = KeyboardShortcut(keyCode: 18, modifiers: KeyboardShortcut.command)

    init() async throws {
        layout = LayoutController(displayProvider: DisplayProvider(snapshot: DisplaySnapshot(displays: [], primaryFrame: .zero)),
                                  storeCoordinator: PersistentStoreCoordinator(directory: directory))
        await layout.loadPersistentState()
        XCTAssertTrue(layout.persistenceReady)
        layout.layoutHotkeySettings.isEnabled = true
        layout.layoutHotkeySettings.bindings = [layoutID: shortcut]
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }

    func payload(_ kind: DragInputKind, type: CGEventType) -> InputMonitorPayload {
        InputMonitorPayload(kind: kind, location: CGPoint(x: 12, y: 34), flags: 0, button: 0,
                            timestamp: 100, generation: 1, eventType: type)
    }
}

@MainActor
private final class LayoutTestRegistrar: HotKeyRegistering {
    private var handlers: [UInt32: @Sendable () -> Void] = [:]
    var failRelease = false
    private(set) var registerCount = 0
    var ids: [UInt32] { handlers.keys.sorted() }
    func conflictsWithSystemShortcut(_ shortcut: KeyboardShortcut) -> Bool { false }
    func register(_ shortcut: KeyboardShortcut, id: UInt32, handler: @escaping @Sendable () -> Void) -> OSStatus {
        registerCount += 1
        handlers[id] = handler
        return noErr
    }
    func unregister(id: UInt32) -> OSStatus {
        if failRelease { return OSStatus(paramErr) }
        handlers.removeValue(forKey: id)
        return noErr
    }
    func shutdown() { if !failRelease { handlers.removeAll() } }
    func fire(_ id: UInt32) { handlers[id]?() }
}

private final class OrderedTestTapResource: InputTapResource, @unchecked Sendable {
    private let stopped = DispatchSemaphore(value: 0)
    func enable() -> Bool { true }
    func run() { stopped.wait() }
    func stop() { stopped.signal() }
    func invalidate() {}
}
