import CoreGraphics
import Foundation
import XCTest

@MainActor
final class OrderedInteractionTests: XCTestCase {
    func testControlSeparatesMotionCoalescingAndFinalRelease() async {
        let inbox = OrderedInteractionInbox()
        let source = UUID()
        var order: [UInt64] = []
        let done = expectation(description: "ordered batch")
        let deliver: @MainActor @Sendable (DragInputEvent) -> Void = { order.append($0.sequence) }
        inbox.enqueueInput(DragInputEvent(kind: .leftDragged, sequence: 1, gesture: 1), source: source, generation: 1, deliver: deliver)
        inbox.enqueueInput(DragInputEvent(kind: .leftDragged, sequence: 2, gesture: 1), source: source, generation: 1, deliver: deliver)
        XCTAssertTrue(inbox.enqueueControl { order.append(100) })
        inbox.enqueueInput(DragInputEvent(kind: .leftDragged, sequence: 3, gesture: 1), source: source, generation: 1, deliver: deliver)
        inbox.enqueueInput(DragInputEvent(kind: .leftUp, sequence: 4, gesture: 1), source: source, generation: 1, deliver: deliver)
        XCTAssertTrue(inbox.enqueueControl { done.fulfill() })
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(order, [2, 100, 3, 4])
        XCTAssertEqual(inbox.pendingCount, 0)
    }

    func testInputOverflowCancelsBatchInsteadOfDroppingRelease() async {
        let inbox = OrderedInteractionInbox(capacity: 2)
        let source = UUID()
        var delivered: [DragInputKind] = []
        let done = expectation(description: "overflow delivered")
        let deliver: @MainActor @Sendable (DragInputEvent) -> Void = { delivered.append($0.kind); done.fulfill() }
        inbox.enqueueInput(DragInputEvent(kind: .leftDown, sequence: 1), source: source, generation: 1, deliver: deliver)
        XCTAssertTrue(inbox.enqueueControl { XCTFail("Overflow must discard the old switch") })
        inbox.enqueueInput(DragInputEvent(kind: .leftUp, sequence: 2), source: source, generation: 1, deliver: deliver)
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(delivered, [.overflow])
    }

    func testNewGenerationOrGestureCannotCoalesceEarlierMotion() async {
        let inbox = OrderedInteractionInbox()
        let source = UUID()
        var delivered: [UInt64] = []
        let done = expectation(description: "generation boundaries")
        let deliver: @MainActor @Sendable (DragInputEvent) -> Void = { delivered.append($0.sequence) }
        inbox.enqueueInput(DragInputEvent(kind: .leftDragged, sequence: 1, gesture: 1), source: source, generation: 1, deliver: deliver)
        inbox.enqueueInput(DragInputEvent(kind: .leftDragged, sequence: 2, gesture: 1), source: source, generation: 2, deliver: deliver)
        inbox.enqueueInput(DragInputEvent(kind: .leftDragged, sequence: 3, gesture: 2), source: source, generation: 2, deliver: deliver)
        XCTAssertTrue(inbox.enqueueControl { done.fulfill() })
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(delivered, [1, 2, 3])
    }
}
