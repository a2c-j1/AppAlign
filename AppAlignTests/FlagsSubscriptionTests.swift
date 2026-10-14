import CoreGraphics
import Foundation
import XCTest

@MainActor
final class FlagsSubscriptionTests: XCTestCase {
    func testEnablingDragCannotReplayInputQueuedByExistingFlagsSubscriber() async throws {
        let state = SubscriptionTapState()
        let inbox = OrderedInteractionInbox()
        let monitor = InputMonitor(inbox: inbox, resourceFactory: .init { core, generation in state.make(core, generation: generation) })
        let ready = expectation(description: "flags subscription ready")
        monitor.setFlagsObserver({ _ in }, onStatus: { if $0 == .ready { ready.fulfill() } })
        defer { monitor.stop(); monitor.setFlagsObserver(nil) }
        await fulfillment(of: [ready], timeout: 2)
        let core = try XCTUnwrap(state.core)
        var sequences: [UInt64] = []
        core.accept(state.payload(.leftDown, type: .leftMouseDown))
        monitor.start(onEvent: { sequences.append($0.sequence) }, onStatus: { _ in })
        core.accept(state.payload(.leftDown, type: .leftMouseDown))
        let done = expectation(description: "subscription barrier")
        XCTAssertTrue(inbox.enqueueControl { done.fulfill() })
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(sequences, [2])
        XCTAssertEqual(state.creationCount, 1)
    }

    func testStoppingDragKeepsFlagsTapUntilItsLastSubscriberLeaves() async throws {
        let state = SubscriptionTapState()
        let inbox = OrderedInteractionInbox()
        let monitor = InputMonitor(inbox: inbox, resourceFactory: .init { core, generation in state.make(core, generation: generation) })
        let ready = expectation(description: "shared subscription ready")
        var flags: [UInt64] = []
        monitor.setFlagsObserver({ flags.append($0) }, onStatus: { if $0 == .ready { ready.fulfill() } })
        defer { monitor.stop(); monitor.setFlagsObserver(nil) }
        await fulfillment(of: [ready], timeout: 2)
        monitor.start(onEvent: { _ in XCTFail("Stopped drag subscription must not receive queued input") }, onStatus: { _ in })
        monitor.stop()
        XCTAssertEqual(state.stopCount, 0)
        let core = try XCTUnwrap(state.core)
        core.accept(state.payload(.flagsChanged, type: .flagsChanged))
        let done = expectation(description: "flags delivered")
        XCTAssertTrue(inbox.enqueueControl { done.fulfill() })
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(flags, [CGEventFlags.maskShift.rawValue])
        monitor.setFlagsObserver(nil)
        XCTAssertEqual(state.stopCount, 1)
        core.accept(state.payload(.flagsChanged, type: .flagsChanged))
        let stopped = expectation(description: "stopped callback rejected")
        XCTAssertTrue(inbox.enqueueControl { stopped.fulfill() })
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(flags.count, 1)
    }
}

private final class SubscriptionTapState: @unchecked Sendable {
    private let lock = NSLock()
    private weak var storedCore: InputMonitorCore?
    private var generation: UInt64 = 0
    private var creations = 0
    private var stops = 0
    var core: InputMonitorCore? { lock.withLock { storedCore } }
    var creationCount: Int { lock.withLock { creations } }
    var stopCount: Int { lock.withLock { stops } }

    func make(_ core: InputMonitorCore, generation: UInt64) -> any InputTapResource {
        lock.withLock { storedCore = core; self.generation = generation; creations += 1 }
        return SubscriptionTapResource { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.stops += 1 }
        }
    }

    func payload(_ kind: DragInputKind, type: CGEventType) -> InputMonitorPayload {
        InputMonitorPayload(kind: kind, location: .zero, flags: CGEventFlags.maskShift.rawValue, button: 0,
                            timestamp: 1, generation: lock.withLock { generation }, eventType: type)
    }
}

private final class SubscriptionTapResource: InputTapResource, @unchecked Sendable {
    private let stopped = DispatchSemaphore(value: 0)
    private let onStop: @Sendable () -> Void
    init(onStop: @escaping @Sendable () -> Void) { self.onStop = onStop }
    func enable() -> Bool { true }
    func run() { stopped.wait() }
    func stop() { onStop(); stopped.signal() }
    func invalidate() {}
}
