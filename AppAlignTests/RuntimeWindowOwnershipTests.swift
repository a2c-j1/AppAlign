import XCTest

final class RuntimeWindowOwnershipTests: XCTestCase {
    func testKeyboardDiscardKeepsRecordWhileDragLeaseIsActive() {
        var ownership = RuntimeWindowOwnership()
        let lease = DragLeaseID(rawValue: UUID())
        ownership.retainKeyboard()
        ownership.retainDrag(lease)
        ownership.discardKeyboard()
        XCTAssertTrue(ownership.isOwned)
        XCTAssertTrue(ownership.dragLeases.contains(lease))
    }

    func testDragReleaseKeepsKeyboardOriginalFrameRecordAndIsIdempotent() {
        var ownership = RuntimeWindowOwnership()
        let lease = DragLeaseID(rawValue: UUID())
        ownership.retainKeyboard()
        ownership.retainDrag(lease)
        ownership.releaseDrag(lease)
        ownership.releaseDrag(lease)
        XCTAssertTrue(ownership.isOwned)
        XCTAssertTrue(ownership.keyboardRetained)
        XCTAssertTrue(ownership.dragLeases.isEmpty)
    }

    func testUnownedRecordCanBeEvictedOnlyAfterBothOwnersRelease() {
        var ownership = RuntimeWindowOwnership()
        let lease = DragLeaseID(rawValue: UUID())
        ownership.retainKeyboard()
        ownership.retainDrag(lease)
        XCTAssertTrue(ownership.isOwned)
        ownership.discardKeyboard()
        XCTAssertTrue(ownership.isOwned)
        ownership.releaseDrag(lease)
        XCTAssertFalse(ownership.isOwned)
    }

    func testReleasingUnknownLeaseDoesNotAffectAnotherGesture() {
        var ownership = RuntimeWindowOwnership()
        let liveLease = DragLeaseID(rawValue: UUID())
        ownership.retainDrag(liveLease)
        ownership.releaseDrag(DragLeaseID(rawValue: UUID()))
        XCTAssertTrue(ownership.dragLeases.contains(liveLease))
        XCTAssertTrue(ownership.isOwned)
    }

    func testCommitHandoffKeepsOwnershipContinuousAndReleasesAreIdempotent() {
        var ownership = RuntimeWindowOwnership()
        let drag = DragLeaseID(rawValue: UUID())
        let commit = DragCommitID()
        ownership.retainKeyboard()
        ownership.retainDrag(drag)
        XCTAssertTrue(ownership.handoffDrag(drag, to: commit))
        XCTAssertTrue(ownership.isOwned)
        XCTAssertTrue(ownership.keyboardRetained)
        XCTAssertFalse(ownership.dragLeases.contains(drag))
        XCTAssertTrue(ownership.dragCommits.contains(commit))
        ownership.releaseDrag(drag)
        ownership.releaseDragCommit(commit)
        ownership.releaseDragCommit(commit)
        XCTAssertTrue(ownership.isOwned, "Keyboard Restore ownership must outlive drag cleanup.")
        XCTAssertTrue(ownership.keyboardRetained)
        ownership.discardKeyboard()
        XCTAssertFalse(ownership.isOwned)
    }

    func testTextTabContentAndResizeHitFixturesAreRejectedWithoutTitleBarEvidence() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertFalse(TitleBarHitClassifier.isCandidate(frame: frame, point: CGPoint(x: 40, y: 12), hitRole: "AXTextField", ancestorRoles: ["AXTextField", "AXWebArea", "AXWindow"]))
        XCTAssertFalse(TitleBarHitClassifier.isCandidate(frame: frame, point: CGPoint(x: 80, y: 12), hitRole: "AXTab", ancestorRoles: ["AXTab", "AXTabGroup", "AXWindow"]))
        XCTAssertFalse(TitleBarHitClassifier.isCandidate(frame: frame, point: CGPoint(x: 80, y: 140), hitRole: "AXImage", ancestorRoles: ["AXImage", "AXWebArea", "AXWindow"]))
        XCTAssertFalse(TitleBarHitClassifier.isCandidate(frame: frame, point: CGPoint(x: 799, y: 300), hitRole: "AXSplitter", ancestorRoles: ["AXSplitter", "AXWindow"]))
        XCTAssertFalse(TitleBarHitClassifier.isCandidate(frame: frame, point: CGPoint(x: 80, y: 12), hitRole: "AXGroup", ancestorRoles: ["AXGroup", "AXTabGroup", "AXWindow"]))
        XCTAssertFalse(TitleBarHitClassifier.isCandidate(frame: frame, point: CGPoint(x: 3, y: 12), hitRole: "AXWindow", ancestorRoles: ["AXWindow"]))
        XCTAssertFalse(TitleBarHitClassifier.isCandidate(frame: frame, point: CGPoint(x: 80, y: 12), hitRole: "AXButton", ancestorRoles: ["AXTitleBar", "AXWindow"]))
        XCTAssertTrue(TitleBarHitClassifier.isCandidate(frame: frame, point: CGPoint(x: 80, y: 12), hitRole: "AXGroup", ancestorRoles: ["AXTitleBar", "AXWindow"]))
    }

    func testHitRegionIsSmallAndClippedToWindowTitleBand() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let region = TitleBarHitClassifier.hitRegion(frame: frame, point: CGPoint(x: 20, y: 8), isCandidate: true)
        XCTAssertEqual(region, CGRect(x: 14, y: 2, width: 12, height: 12))
        XCTAssertTrue(TitleBarHitClassifier.hitRegion(frame: frame, point: CGPoint(x: 20, y: 8), isCandidate: false).isNull)
    }

    func testAXRevisionRemembersResizeAfterLaterMoveAndDestroyedIsSticky() {
        let tracker = AXRevisionTracker()
        tracker.record(kAXResizedNotification as String)
        let revisionAfterResize = tracker.snapshot(since: 0)
        XCTAssertEqual(revisionAfterResize.revision, 1)
        XCTAssertTrue(revisionAfterResize.changeWasResize)
        XCTAssertEqual(revisionAfterResize.changes.map(\.kind), [.resized])

        tracker.record(kAXMovedNotification as String)
        let revisionAfterMove = tracker.snapshot(since: 0)
        XCTAssertEqual(revisionAfterMove.revision, 2)
        XCTAssertTrue(revisionAfterMove.changeWasResize)
        XCTAssertEqual(revisionAfterMove.changes.map(\.kind), [.resized, .moved])
        XCTAssertFalse(tracker.snapshot(since: UInt64.max).changeWasResize)

        tracker.record(kAXUIElementDestroyedNotification as String)
        tracker.record(kAXMovedNotification as String)
        XCTAssertTrue(tracker.snapshot(since: 0).destroyed)
    }

    func testMonitorGenerationRejectsLateTapAndOldDrainAfterStopAndRetry() {
        var generation = InputMonitorGeneration()
        let first = generation.start()
        XCTAssertTrue(generation.accepts(first))
        generation.stop()
        XCTAssertFalse(generation.accepts(first))
        let second = generation.start()
        XCTAssertGreaterThan(second, first)
        XCTAssertFalse(generation.accepts(first))
        XCTAssertTrue(generation.accepts(second))
        generation.stop()
        XCTAssertFalse(generation.accepts(second))
    }
}
