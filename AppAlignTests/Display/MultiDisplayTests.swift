import XCTest

final class MultiDisplayTests: XCTestCase {
    func testZoneOrderMovesToNextDisplayAndKeepsDuplicateZoneAddressesDistinct() throws {
        let left = display(originX: -1_000, uuid: UUID())
        let right = display(originX: 0, uuid: UUID())
        let leftZones = [zone(0, originX: -1_000), zone(1, originX: -500)]
        let rightZones = [zone(0, originX: 0), zone(1, originX: 500)]
        let current = ZoneAddress(workArea: left.selectionKey, zoneID: ZoneID(rawValue: 1))
        let request = MultiDisplayNavigationRequest(mode: .zoneOrder, currentAddress: current,
                                                    currentDisplay: left.id,
                                                    currentFrame: leftZones[1].frame,
                                                    displays: [layout(left, leftZones), layout(right, rightZones)],
                                                    cycle: false)
        let target = try XCTUnwrap(MultiDisplayNavigator.zone(for: .next, request: request))
        XCTAssertEqual(target.0.workArea, right.selectionKey)
        XCTAssertEqual(target.0.zoneID, ZoneID(rawValue: 0))

        let direct = try XCTUnwrap(MultiDisplayNavigator.zone(for: .zone(ZoneID(rawValue: 0)),
                                                              request: MultiDisplayNavigationRequest(
                                                                mode: .zoneOrder, currentAddress: current,
                                                                currentDisplay: left.id, currentFrame: leftZones[1].frame,
                                                                displays: [layout(left, leftZones), layout(right, rightZones)],
                                                                cycle: false)))
        XCTAssertEqual(direct.0.workArea, left.selectionKey)
        XCTAssertNotEqual(direct.0, ZoneAddress(workArea: right.selectionKey, zoneID: ZoneID(rawValue: 0)))
    }

    func testZoneOrderStopsAtGlobalEndUnlessCycleEnabledAndSkipsEmptyDisplays() throws {
        let first = display(originX: 0, uuid: UUID())
        let empty = display(originX: 1_000, uuid: UUID())
        let last = display(originX: 2_000, uuid: UUID())
        let firstZone = zone(0, originX: 0)
        let lastZone = zone(3, originX: 2_000)
        let displays = [layout(first, [firstZone]), layout(empty, []), layout(last, [lastZone])]
        let current = ZoneAddress(workArea: last.selectionKey, zoneID: lastZone.id)
        let request = MultiDisplayNavigationRequest(mode: .zoneOrder, currentAddress: current,
                                                    currentDisplay: last.id, currentFrame: lastZone.frame,
                                                    displays: displays, cycle: false)
        XCTAssertNil(MultiDisplayNavigator.zone(for: .next, request: request))
        let cyclic = MultiDisplayNavigationRequest(mode: .zoneOrder, currentAddress: current,
                                                   currentDisplay: last.id, currentFrame: lastZone.frame,
                                                   displays: displays, cycle: true)
        XCTAssertEqual(try XCTUnwrap(MultiDisplayNavigator.zone(for: .next, request: cyclic)).0,
                       ZoneAddress(workArea: first.selectionKey, zoneID: firstZone.id))
    }

    func testPositionModeEvaluatesOtherDisplayUsingGlobalCoordinatesAndFourDirections() throws {
        let left = display(originX: -1_000, uuid: UUID())
        let right = display(originX: 0, uuid: UUID())
        let source = zone(4, originX: -800, originY: 100)
        let east = zone(4, originX: 100, originY: 100)
        let north = zone(5, originX: -800, originY: -300)
        let displays = [layout(left, [source, north]), layout(right, [east])]
        let current = ZoneAddress(workArea: left.selectionKey, zoneID: source.id)
        let request = MultiDisplayNavigationRequest(mode: .position, currentAddress: current,
                                                    currentDisplay: left.id, currentFrame: source.frame,
                                                    displays: displays, cycle: false)
        let rightTarget = try XCTUnwrap(MultiDisplayNavigator.zone(for: .direction(.right), request: request))
        XCTAssertEqual(rightTarget.0.workArea, right.selectionKey)
        XCTAssertEqual(rightTarget.0.zoneID, east.id)
        let northTarget = try XCTUnwrap(MultiDisplayNavigator.zone(for: .direction(.north), request: request))
        XCTAssertEqual(northTarget.0.workArea, left.selectionKey)
        XCTAssertEqual(northTarget.0.zoneID, north.id)
        XCTAssertNil(MultiDisplayNavigator.zone(for: .direction(.south), request: request))

        let leftTarget = zone(6, originX: -1_200, originY: 100)
        let southTarget = zone(7, originX: -800, originY: 900)
        let expanded = [layout(left, [source, north, leftTarget, southTarget]), layout(right, [east])]
        let leftRequest = MultiDisplayNavigationRequest(mode: .position, currentAddress: current,
                                                        currentDisplay: left.id, currentFrame: source.frame,
                                                        displays: expanded, cycle: false)
        XCTAssertEqual(try XCTUnwrap(MultiDisplayNavigator.zone(for: .direction(.left), request: leftRequest)).0.zoneID,
                       leftTarget.id)
        XCTAssertEqual(try XCTUnwrap(MultiDisplayNavigator.zone(for: .direction(.south), request: leftRequest)).0.zoneID,
                       southTarget.id)
    }

    func testPositionCycleWrapsAllFourDirectionsUsingWorkAreaUnion() throws {
        let screen = display(originX: 0, uuid: UUID())
        let sourceFrame = CGRect(x: 450, y: 350, width: 100, height: 100)
        let targets: [(NavigationDirection, Zone)] = [
            (.left, zone(1, originX: 850, originY: 350)),
            (.right, zone(2, originX: 50, originY: 350)),
            (.north, zone(3, originX: 450, originY: 650)),
            (.south, zone(4, originX: 450, originY: 50))
        ]
        for (direction, targetZone) in targets {
            let request = MultiDisplayNavigationRequest(mode: .position, currentAddress: nil,
                                                        currentDisplay: screen.id, currentFrame: sourceFrame,
                                                        displays: [layout(screen, [targetZone])], cycle: true)
            let target = try XCTUnwrap(MultiDisplayNavigator.zone(for: .direction(direction), request: request),
                                       "Expected \(direction) to wrap to its opposite edge")
            XCTAssertEqual(target.1.id, targetZone.id)
        }
    }

    private func layout(_ display: Display, _ zones: [Zone]) -> KeyboardDisplayLayout {
        KeyboardDisplayLayout(display: display, layout: PersistentStoreCoordinator.defaultLayout(), zones: zones)
    }

    private func display(originX: CGFloat, uuid: UUID) -> Display {
        let frame = CGRect(x: originX, y: 0, width: 1_000, height: 800)
        return Display(runtimeID: RuntimeDisplayID(rawValue: UInt32(abs(Int(originX)) + 1)),
                       persistentID: PersistentDisplayID(uuid: uuid), sessionID: UUID(), name: "test",
                       frame: frame, workArea: frame, isPrimary: originX == 0, backingScaleFactor: 1)
    }

    private func zone(_ id: Int, originX: CGFloat, originY: CGFloat = 100) -> Zone {
        Zone(id: ZoneID(rawValue: id), frame: CGRect(x: originX, y: originY, width: 300, height: 200))
    }
}
