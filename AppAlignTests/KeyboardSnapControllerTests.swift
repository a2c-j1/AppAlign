import XCTest
import ApplicationServices

final class KeyboardSnapControllerTests: XCTestCase {
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

    @MainActor
    func testFirstModifierSampleIsReleaseResetsExtensionAnchorBeforeReextension() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        fixture.layout.template = .columns
        _ = await fixture.layout.flush()
        var settings = fixture.layout.keyboardSettings
        settings.isEnabled = true
        fixture.layout.updateKeyboardSettings(settings)
        fixture.controller.flagsMonitorStatus(.ready)

        let snapshot = try XCTUnwrap(fixture.layout.appliedLayoutSnapshot(for: fixture.originalFrame))
        let anchor = try XCTUnwrap(snapshot.zones.first)
        fixture.controller.handle(.zone(anchor.id))
        let positioned = await fixture.waitUntilIdle()
        XCTAssertTrue(positioned)
        let adjacent = try XCTUnwrap(ZoneNavigator.directionalZone(from: anchor.frame, zones: snapshot.zones,
                                                                     direction: .right, workArea: snapshot.display.workArea,
                                                                     cycle: false, excludingID: anchor.id))
        fixture.controller.handle(.extend(.right))
        let extended = await fixture.waitUntilIdle()
        XCTAssertTrue(extended)
        let extendedFrame = await fixture.backend.currentFrame()
        XCTAssertEqual(extendedFrame, ZoneSelectionEngine.union(of: [anchor.frame, adjacent.frame]))
        let token = try XCTUnwrap(fixture.controller.sessions.keys.first)
        let savedAnchor = fixture.controller.sessions[token]?.extensionAnchor
        XCTAssertEqual(savedAnchor?.zoneID, anchor.id)

        let requiredFlags = CGEventFlags.maskShift.rawValue
        fixture.controller.flagsMonitorStatus(.ready)
        fixture.controller.extensionModifierFlagsChanged(0)
        XCTAssertNil(fixture.controller.sessions[token]?.extensionAnchor,
                     "A first observed release after readiness must clear history from a held modifier chord.")

        fixture.controller.extensionModifierFlagsChanged(requiredFlags)
        fixture.controller.handle(.extend(.right))
        let reextended = await fixture.waitUntilIdle()
        XCTAssertTrue(reextended)
        let finalFrame = await fixture.backend.currentFrame()
        let fartherZone = try XCTUnwrap(ZoneNavigator.directionalZone(from: adjacent.frame, zones: snapshot.zones,
                                                                       direction: .right, workArea: snapshot.display.workArea,
                                                                       cycle: false, excludingID: adjacent.id))
        let staleAnchorContinuation = ZoneSelectionEngine.union(of: [anchor.frame, adjacent.frame, fartherZone.frame])
        XCTAssertNotEqual(finalFrame, staleAnchorContinuation,
                          "Reextension after the first release sample must not reuse the old anchor.")
    }

    @MainActor
    func testFirstModifierSampleHeldPreservesExtensionAnchorUntilRelease() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        var settings = fixture.layout.keyboardSettings
        settings.isEnabled = true
        fixture.layout.updateKeyboardSettings(settings)
        fixture.controller.flagsMonitorStatus(.ready)
        let snapshot = try XCTUnwrap(fixture.layout.appliedLayoutSnapshot(for: fixture.originalFrame))
        let anchor = try XCTUnwrap(snapshot.zones.first)
        fixture.controller.handle(.zone(anchor.id))
        let positioned = await fixture.waitUntilIdle()
        XCTAssertTrue(positioned)
        fixture.controller.handle(.extend(.right))
        let extended = await fixture.waitUntilIdle()
        XCTAssertTrue(extended)
        let token = try XCTUnwrap(fixture.controller.sessions.keys.first)
        let savedAnchor = fixture.controller.sessions[token]?.extensionAnchor

        fixture.controller.flagsMonitorStatus(.ready)
        let heldChord = CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue
            | CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue
        fixture.controller.extensionModifierFlagsChanged(heldChord)
        XCTAssertEqual(fixture.controller.sessions[token]?.extensionAnchor, savedAnchor,
                       "A first sample with the configured modifier held must preserve the active extension.")
    }

    @MainActor
    func testFirstSampleTracksThePreviouslyUsedCustomChordWhenAnotherChordIsHeld() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        var settings = fixture.layout.keyboardSettings
        settings.isEnabled = true
        settings.shortcuts[.extend(.left)] = KeyboardShortcut(keyCode: 123,
                                                               modifiers: KeyboardShortcut.control | KeyboardShortcut.shift)
        settings.shortcuts[.extend(.right)] = KeyboardShortcut(keyCode: 124,
                                                                modifiers: KeyboardShortcut.option | KeyboardShortcut.command)
        fixture.layout.updateKeyboardSettings(settings)
        fixture.controller.flagsMonitorStatus(.ready)
        let snapshot = try XCTUnwrap(fixture.layout.appliedLayoutSnapshot(for: fixture.originalFrame))
        let anchor = try XCTUnwrap(snapshot.zones.first(where: { zone in
            ZoneNavigator.directionalZone(from: zone.frame, zones: snapshot.zones, direction: .left,
                                          workArea: snapshot.display.workArea, cycle: false,
                                          excludingID: zone.id) != nil
        }))
        fixture.controller.handle(.zone(anchor.id))
        let positioned = await fixture.waitUntilIdle()
        XCTAssertTrue(positioned)
        fixture.controller.handle(.extend(.left))
        let extended = await fixture.waitUntilIdle()
        XCTAssertTrue(extended)
        let leftExtendedFrame = await fixture.backend.currentFrame()
        let token = try XCTUnwrap(fixture.controller.sessions.keys.first)
        let oldLeftAnchor = try XCTUnwrap(fixture.controller.sessions[token]?.extensionAnchor)

        fixture.controller.flagsMonitorStatus(.ready)
        let otherChord = CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue
        fixture.controller.extensionModifierFlagsChanged(otherChord)
        XCTAssertNil(fixture.controller.sessions[token]?.extensionAnchor,
                     "A different held chord must not keep the previously used custom chord's history alive.")

        let postReleaseFrame = await fixture.backend.currentFrame()
        let expectedFreshTarget = try XCTUnwrap(ZoneNavigator.directionalZone(from: postReleaseFrame, zones: snapshot.zones,
                                                                                direction: .right, workArea: snapshot.display.workArea,
                                                                                cycle: false, excludingID: nil))
        fixture.controller.handle(.extend(.right))
        let reextended = await fixture.waitUntilIdle()
        XCTAssertTrue(reextended)
        let newRightAnchor = try XCTUnwrap(fixture.controller.sessions[token]?.extensionAnchor)
        let frameAfterFreshRight = await fixture.backend.currentFrame()
        XCTAssertEqual(frameAfterFreshRight, expectedFreshTarget.frame,
                       "A reextension must use the current window frame as its fresh source.")
        XCTAssertNotEqual(frameAfterFreshRight, leftExtendedFrame,
                          "The new target frame must replace the previous extension result, proving the old anchor was not continued.")
        XCTAssertNotNil(oldLeftAnchor)
        XCTAssertEqual(fixture.controller.sessions[token]?.originalFrame, fixture.originalFrame)

        let rightChordWithUnrelatedModifiers = otherChord | CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue
        fixture.controller.flagsMonitorStatus(.ready)
        fixture.controller.extensionModifierFlagsChanged(rightChordWithUnrelatedModifiers)
        XCTAssertEqual(fixture.controller.sessions[token]?.extensionAnchor, newRightAnchor,
                       "A first sample holding the current custom chord must preserve its anchor.")
        fixture.controller.extensionModifierFlagsChanged(otherChord)
        XCTAssertEqual(fixture.controller.sessions[token]?.extensionAnchor, newRightAnchor,
                        "Releasing unrelated modifiers must preserve the currently owned custom chord.")
        fixture.controller.extensionModifierFlagsChanged(CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue)
        XCTAssertNil(fixture.controller.sessions[token]?.extensionAnchor,
                     "Releasing the currently owned chord must reset extension history.")
    }

}
