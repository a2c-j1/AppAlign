import Foundation
import XCTest

final class KeyboardExtensionAwaitTests: XCTestCase {
    @MainActor
    func testExtensionChordReleaseDuringFocusedWindowCaptureCancelsAttempt() async throws {
        let fixture = try await LifecycleFixture.make()
        defer { fixture.remove() }
        configureDistinctExtensionChords(fixture.layout)
        fixture.controller.flagsMonitorStatus(.ready)
        fixture.controller.extensionModifierFlagsChanged(customRightChordFlags)
        let snapshot = try XCTUnwrap(fixture.layout.appliedLayoutSnapshot(for: fixture.originalFrame))
        let anchor = try XCTUnwrap(snapshot.zones.first(where: { zone in
            ZoneNavigator.directionalZone(from: zone.frame, zones: snapshot.zones, direction: .left,
                                          workArea: snapshot.display.workArea, cycle: false,
                                          excludingID: zone.id) != nil
        }))
        fixture.controller.handle(.zone(anchor.id))
        try await fixture.waitUntilIdle()
        let original = try XCTUnwrap(fixture.controller.sessions.values.first?.originalFrame)
        let placed = await fixture.backend.currentFrame()

        await fixture.backend.arm(.capture)
        fixture.controller.handle(.extend(.left))
        try await fixture.waitForBarrier()
        // The previous flags sample held the other custom chord. This unchanged sample
        // omits the newly pending left chord and must still cancel the pending extension.
        fixture.controller.extensionModifierFlagsChanged(customRightChordFlags)
        await fixture.backend.release()
        try await fixture.waitUntilIdle()

        let writes = await fixture.backend.writeCount()
        XCTAssertEqual(writes, 1, "A release during focused-window capture must block the later extension setter.")
        let frameAfterCancelledCapture = await fixture.backend.currentFrame()
        XCTAssertEqual(frameAfterCancelledCapture, placed)
        XCTAssertTrue(fixture.controller.hasRestoreTarget)
        let session = try XCTUnwrap(fixture.controller.sessions.values.first)
        XCTAssertEqual(session.originalFrame, original)
        XCTAssertNil(session.extensionAnchor)

        fixture.controller.handle(.restore)
        try await fixture.waitUntilIdle()
        let restored = await fixture.backend.currentFrame()
        XCTAssertEqual(restored, original,
                       "Cancelling a pending extension must preserve its original Restore frame.")
    }

    @MainActor
    func testHeldExtensionChordDuringFocusedWindowCaptureAllowsExtension() async throws {
        let fixture = try await LifecycleFixture.make()
        defer { fixture.remove() }
        configureDistinctExtensionChords(fixture.layout)
        fixture.controller.flagsMonitorStatus(.ready)
        let snapshot = try XCTUnwrap(fixture.layout.appliedLayoutSnapshot(for: fixture.originalFrame))
        let anchor = try XCTUnwrap(snapshot.zones.first(where: { zone in
            ZoneNavigator.directionalZone(from: zone.frame, zones: snapshot.zones, direction: .left,
                                          workArea: snapshot.display.workArea, cycle: false,
                                          excludingID: zone.id) != nil
        }))
        fixture.controller.handle(.zone(anchor.id))
        try await fixture.waitUntilIdle()
        await fixture.backend.arm(.capture)
        fixture.controller.handle(.extend(.left))
        try await fixture.waitForBarrier()
        fixture.controller.flagsMonitorStatus(.ready)
        fixture.controller.extensionModifierFlagsChanged(customLeftChordFlags)
        await fixture.backend.release()
        try await fixture.waitUntilIdle()

        let writes = await fixture.backend.writeCount()
        XCTAssertEqual(writes, 2, "Holding the pending extension's own chord must allow its setter.")
        XCTAssertTrue(fixture.controller.hasRestoreTarget)
        XCTAssertNotNil(fixture.controller.sessions.values.first?.extensionAnchor)
    }

    @MainActor
    func testExtensionChordReleaseDuringRetainWaitBlocksWriteAndKeepsOtherRestoreOwner() async throws {
        let fixture = try await LifecycleFixture.make()
        defer { fixture.remove() }
        configureDistinctExtensionChords(fixture.layout)
        fixture.controller.flagsMonitorStatus(.ready)
        let snapshot = try XCTUnwrap(fixture.layout.appliedLayoutSnapshot(for: fixture.originalFrame))
        let anchor = try XCTUnwrap(snapshot.zones.first(where: { zone in
            ZoneNavigator.directionalZone(from: zone.frame, zones: snapshot.zones, direction: .left,
                                          workArea: snapshot.display.workArea, cycle: false,
                                          excludingID: zone.id) != nil
        }))
        fixture.controller.handle(.zone(anchor.id))
        try await fixture.waitUntilIdle()
        let tokenA = await fixture.backend.currentToken()
        let originalA = try XCTUnwrap(fixture.controller.sessions[tokenA.id]?.originalFrame)
        let frameA = await fixture.backend.currentFrame()

        await fixture.backend.switchFocusedWindow()
        let tokenB = await fixture.backend.currentToken()
        await fixture.backend.arm(.retain)
        fixture.controller.handle(.extend(.left))
        try await fixture.waitForBarrier()
        fixture.controller.flagsMonitorStatus(.ready)
        fixture.controller.extensionModifierFlagsChanged(customRightChordFlags)
        await fixture.backend.release()
        try await fixture.waitUntilIdle()

        let writes = await fixture.backend.writeCount()
        XCTAssertEqual(writes, 1, "A release during retain must prevent the extension setter from starting.")
        XCTAssertNil(fixture.controller.sessions[tokenB.id])
        XCTAssertEqual(fixture.controller.sessions[tokenA.id]?.originalFrame, originalA)
        XCTAssertTrue(fixture.controller.hasRestoreTarget)
        await fixture.backend.focus(tokenA, frame: frameA)
        fixture.controller.handle(.restore)
        try await fixture.waitUntilIdle()
        let restored = await fixture.backend.currentFrame()
        XCTAssertEqual(restored, originalA,
                       "The unrelated preexisting Restore owner must survive pending extension cancellation.")
    }

    @MainActor
    func testHeldExtensionChordDuringRetainWaitAllowsExtensionAndRestore() async throws {
        let fixture = try await LifecycleFixture.make()
        defer { fixture.remove() }
        configureDistinctExtensionChords(fixture.layout)
        fixture.controller.flagsMonitorStatus(.ready)
        let snapshot = try XCTUnwrap(fixture.layout.appliedLayoutSnapshot(for: fixture.originalFrame))
        let anchor = try XCTUnwrap(snapshot.zones.first(where: { zone in
            ZoneNavigator.directionalZone(from: zone.frame, zones: snapshot.zones, direction: .left,
                                          workArea: snapshot.display.workArea, cycle: false,
                                          excludingID: zone.id) != nil
        }))
        fixture.controller.handle(.zone(anchor.id))
        try await fixture.waitUntilIdle()
        let tokenA = await fixture.backend.currentToken()
        let frameA = await fixture.backend.currentFrame()

        await fixture.backend.switchFocusedWindow()
        let tokenB = await fixture.backend.currentToken()
        let originalB = await fixture.backend.currentFrame()
        await fixture.backend.arm(.retain)
        fixture.controller.handle(.extend(.left))
        try await fixture.waitForBarrier()
        fixture.controller.flagsMonitorStatus(.ready)
        fixture.controller.extensionModifierFlagsChanged(customLeftChordFlags)
        await fixture.backend.release()
        try await fixture.waitUntilIdle()

        let writes = await fixture.backend.writeCount()
        XCTAssertEqual(writes, 2, "Holding the pending chord during retain must allow the extension setter.")
        let sessionB = try XCTUnwrap(fixture.controller.sessions[tokenB.id])
        XCTAssertEqual(sessionB.originalFrame, originalB)
        XCTAssertNotNil(sessionB.extensionAnchor)
        XCTAssertTrue(fixture.controller.hasRestoreTarget)

        fixture.controller.handle(.restore)
        try await fixture.waitUntilIdle()
        let restoredB = await fixture.backend.currentFrame()
        XCTAssertEqual(restoredB, originalB, "The retained target must preserve its original Restore frame.")
        await fixture.backend.focus(tokenA, frame: frameA)
        fixture.controller.handle(.restore)
        try await fixture.waitUntilIdle()
        let restoredA = await fixture.backend.currentFrame()
        XCTAssertEqual(restoredA, fixture.originalFrame)
        XCTAssertFalse(fixture.controller.hasRestoreTarget)
    }

    private var customLeftChordFlags: UInt64 {
        CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue
    }

    private var customRightChordFlags: UInt64 {
        CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue
    }

    @MainActor
    private func configureDistinctExtensionChords(_ layout: LayoutController) {
        var settings = layout.keyboardSettings
        settings.shortcuts[.extend(.left)] = KeyboardShortcut(keyCode: 123,
                                                               modifiers: KeyboardShortcut.control | KeyboardShortcut.shift)
        settings.shortcuts[.extend(.right)] = KeyboardShortcut(keyCode: 124,
                                                                modifiers: KeyboardShortcut.option | KeyboardShortcut.command)
        layout.updateKeyboardSettings(settings)
    }

}
