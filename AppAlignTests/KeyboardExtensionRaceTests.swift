import Foundation
import XCTest

final class KeyboardExtensionRaceTests: XCTestCase {
    @MainActor
    func testScopedExtensionHistoryResetAfterPreflightBlocksSetterStart() async throws {
        let fixture = try await LifecycleFixture.make()
        defer { fixture.remove() }
        fixture.controller.flagsMonitorStatus(.ready)
        let snapshot = try XCTUnwrap(fixture.layout.appliedLayoutSnapshot(for: fixture.originalFrame))
        await fixture.backend.arm(.afterPreflight)
        fixture.controller.handle(.extend(.left))
        try await fixture.waitForBarrier()

        fixture.controller.resetNavigationHistory(for: snapshot.display.selectionKey)
        await fixture.backend.release()
        try await fixture.waitUntilIdle()

        let writes = await fixture.backend.writeCount()
        XCTAssertEqual(writes, 0, "The extension ticket must be invalidated between preflight and setter begin.")
        XCTAssertTrue(fixture.controller.hasRestoreTarget, "History reset must keep the original restore lease.")
        let session = try XCTUnwrap(fixture.controller.sessions.values.first)
        XCTAssertNil(session.extensionAnchor)
        XCTAssertNil(session.extensionEndpoint)
    }

    @MainActor
    func testSamePIDTargetSwitchResetsOnlyExtensionHistoryAndPreservesRestoreOwners() async throws {
        let fixture = try await LifecycleFixture.make()
        defer { fixture.remove() }
        fixture.controller.flagsMonitorStatus(.ready)
        let snapshot = try XCTUnwrap(fixture.layout.appliedLayoutSnapshot(for: fixture.originalFrame))
        let firstZone = try XCTUnwrap(snapshot.zones.first)
        fixture.controller.handle(.zone(firstZone.id))
        try await fixture.waitUntilIdle()
        fixture.controller.handle(.extend(.right))
        try await fixture.waitUntilIdle()

        let tokenA = await fixture.backend.currentToken()
        let frameA = await fixture.backend.currentFrame()
        let sessionA = try XCTUnwrap(fixture.controller.sessions[tokenA.id])
        let originalAnchorA = sessionA.extensionAnchor
        XCTAssertEqual(sessionA.originalFrame, fixture.originalFrame)
        XCTAssertNotNil(originalAnchorA)

        await fixture.backend.switchFocusedWindow()
        let originalFrameB = await fixture.backend.currentFrame()
        fixture.controller.handle(.extend(.left))
        try await fixture.waitUntilIdle()
        let tokenB = await fixture.backend.currentToken()
        let frameB = await fixture.backend.currentFrame()
        XCTAssertEqual(tokenB.pid, tokenA.pid)
        XCTAssertNotEqual(tokenB.id, tokenA.id)
        XCTAssertEqual(fixture.controller.sessions[tokenA.id]?.extensionAnchor, nil,
                       "Observing a different same-PID token must clear the old extension anchor.")
        XCTAssertEqual(fixture.controller.sessions[tokenA.id]?.originalFrame, fixture.originalFrame)
        XCTAssertEqual(fixture.controller.sessions[tokenB.id]?.originalFrame, originalFrameB)
        XCTAssertNotNil(fixture.controller.sessions[tokenB.id]?.extensionAnchor,
                        "The first extension action on the newly observed target must use fresh history and succeed.")

        await fixture.backend.focus(tokenA, frame: frameA)
        fixture.controller.handle(.extend(.right))
        try await fixture.waitUntilIdle()
        XCTAssertNotEqual(fixture.controller.sessions[tokenA.id]?.extensionAnchor, originalAnchorA,
                          "Returning to the old token must resolve from its current frame, not reuse its old anchor.")
        XCTAssertEqual(fixture.controller.sessions[tokenA.id]?.originalFrame, fixture.originalFrame)
        XCTAssertEqual(fixture.controller.sessions[tokenB.id]?.originalFrame, originalFrameB)
        XCTAssertTrue(fixture.controller.hasRestoreTarget)

        fixture.controller.handle(.restore)
        try await fixture.waitUntilIdle()
        let restoredA = await fixture.backend.currentFrame()
        XCTAssertEqual(restoredA, fixture.originalFrame, "A must retain its own original frame for Restore.")
        await fixture.backend.focus(tokenB, frame: frameB)
        fixture.controller.handle(.restore)
        try await fixture.waitUntilIdle()
        let restoredB = await fixture.backend.currentFrame()
        XCTAssertEqual(restoredB, originalFrameB, "B must retain its own original frame for Restore.")
        XCTAssertFalse(fixture.controller.hasRestoreTarget)
    }

    @MainActor
    func testEligibilityProbeObservingSamePIDTargetResetsExtensionHistory() async throws {
        let fixture = try await LifecycleFixture.make()
        defer { fixture.remove() }
        fixture.controller.flagsMonitorStatus(.ready)
        let snapshotA = try XCTUnwrap(fixture.layout.appliedLayoutSnapshot(for: fixture.originalFrame))
        let firstZone = try XCTUnwrap(snapshotA.zones.first)
        fixture.controller.handle(.zone(firstZone.id))
        try await fixture.waitUntilIdle()
        fixture.controller.handle(.extend(.right))
        try await fixture.waitUntilIdle()
        let tokenA = await fixture.backend.currentToken()
        let frameA = await fixture.backend.currentFrame()
        let originalFrameA = try XCTUnwrap(fixture.controller.sessions[tokenA.id]?.originalFrame)
        let oldAnchorA = fixture.controller.sessions[tokenA.id]?.extensionAnchor
        XCTAssertNotNil(oldAnchorA)

        await fixture.backend.switchFocusedWindow()
        let focusedB = try await fixture.backend.focusedWindow(applicationPID: tokenA.pid, ownPID: 100)
        XCTAssertNotEqual(focusedB.token.id, tokenA.id)
        XCTAssertFalse(fixture.controller.isEligible(.restore, for: focusedB, layout: nil))
        XCTAssertNil(fixture.controller.sessions[tokenA.id]?.extensionAnchor,
                     "A confirmed eligibility probe observes B even when no operation runs on B.")

        await fixture.backend.focus(tokenA, frame: frameA)
        fixture.controller.handle(.extend(.right))
        try await fixture.waitUntilIdle()
        XCTAssertNotEqual(fixture.controller.sessions[tokenA.id]?.extensionAnchor, oldAnchorA,
                          "Returning to A after observing B must start a fresh extension anchor.")
        XCTAssertEqual(fixture.controller.sessions[tokenA.id]?.originalFrame, originalFrameA)
        XCTAssertEqual(fixture.controller.sessions[focusedB.token.id]?.originalFrame, nil,
                       "An eligibility-only probe must not acquire Restore ownership for B.")
        XCTAssertTrue(fixture.controller.hasRestoreTarget)
    }

}
