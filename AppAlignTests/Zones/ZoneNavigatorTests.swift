import XCTest

final class ZoneNavigatorTests: XCTestCase {
    func testFourDirectionsChooseNearestCardinalZoneAndStableScoreTie() {
        let zones = [
            zone(4, 100, 100), zone(3, 0, 100), zone(2, 100, 0), zone(1, 0, 0),
            zone(10, 200, 100), zone(11, 100, 200)
        ]
        let source = CGRect(x: 100, y: 100, width: 0, height: 0)
        XCTAssertEqual(ZoneNavigator.directionalZone(from: source, zones: zones, direction: .left, workArea: area, cycle: false)?.id.rawValue, 3)
        XCTAssertEqual(ZoneNavigator.directionalZone(from: source, zones: zones, direction: .right, workArea: area, cycle: false)?.id.rawValue, 10)
        XCTAssertEqual(ZoneNavigator.directionalZone(from: source, zones: zones, direction: .north, workArea: area, cycle: false)?.id.rawValue, 2)
        XCTAssertEqual(ZoneNavigator.directionalZone(from: source, zones: zones, direction: .south, workArea: area, cycle: false)?.id.rawValue, 11)

        let tied = [zone(8, 200, 0), zone(2, 200, 200)]
        XCTAssertEqual(ZoneNavigator.directionalZone(from: source, zones: tied, direction: .right, workArea: area, cycle: false)?.id.rawValue, 2)
        XCTAssertEqual(ZoneNavigator.directionalZone(from: source, zones: tied.reversed().map(\.self), direction: .right, workArea: area, cycle: false)?.id.rawValue, 2)
    }

    func testAngleScoreHasFixedExpectedOrdering() {
        let source = CGRect(x: 0, y: 0, width: 0, height: 0)
        let zones = [zone(1, 200, 0), zone(2, 100, 100)]
        XCTAssertEqual(ZoneNavigator.directionalZone(from: source, zones: zones, direction: .right, workArea: area, cycle: false)?.id.rawValue, 1)
    }

    func testZoneOrderUsesOnlyExistingIDsAndHandlesSparseMaximumIDs() {
        let zones = [zone(Int.max, 30, 0), zone(11, 20, 0), zone(8, 10, 0)]
        XCTAssertEqual(ZoneNavigator.orderedZones(zones).map(\.id.rawValue), [8, 11, Int.max])
        XCTAssertEqual(ZoneNavigator.adjacentZone(from: ZoneID(rawValue: 8), zones: zones, direction: .right, cycle: false)?.id.rawValue, 11)
        XCTAssertNil(ZoneNavigator.adjacentZone(from: ZoneID(rawValue: Int.max), zones: zones, direction: .right, cycle: false))
        XCTAssertEqual(ZoneNavigator.adjacentZone(from: ZoneID(rawValue: Int.max), zones: zones, direction: .right, cycle: true)?.id.rawValue, 8)
        XCTAssertNil(ZoneNavigator.adjacentZone(from: ZoneID(rawValue: 8), zones: zones, direction: .left, cycle: false))
        XCTAssertEqual(ZoneNavigator.adjacentZone(from: ZoneID(rawValue: 8), zones: zones, direction: .left, cycle: true)?.id.rawValue, Int.max)
        XCTAssertEqual(ZoneNavigator.adjacentZone(from: ZoneID(rawValue: 11), zones: zones, direction: .right, cycle: false)?.id.rawValue, Int.max)
        XCTAssertEqual(ZoneNavigator.adjacentZone(from: ZoneID(rawValue: 11), zones: zones, direction: .right, cycle: true)?.id.rawValue, Int.max)
        XCTAssertEqual(ZoneNavigator.adjacentZone(from: nil, zones: zones, direction: .left, cycle: false)?.id.rawValue, Int.max)
    }

    func testExplicitIDsAndUnplacedOriginRemainUnambiguous() {
        let zones = [zone(Int.max - 1, 100, 0), zone(Int.max, 200, 0)]
        XCTAssertEqual(navigate(.zone(ZoneID(rawValue: Int.max)), request(.zoneOrder, nil, .zero, zones, false))?.id.rawValue, Int.max)
        XCTAssertEqual(ZoneNavigator.directionalZone(from: CGRect(x: 0, y: 0, width: 0, height: 0), zones: zones, direction: .right, workArea: area, cycle: false)?.id.rawValue, Int.max - 1)
        XCTAssertEqual(navigate(.direction(.right), request(.zoneOrder, ZoneID(rawValue: Int.max - 1), CGRect(x: 50, y: -50, width: 100, height: 100), zones, false))?.id.rawValue, Int.max)
        let movedManually = navigate(
            .direction(.right),
            request(.zoneOrder, ZoneID(rawValue: Int.max - 1), CGRect(x: -100, y: -50, width: 100, height: 100), zones, false)
        )
        XCTAssertEqual(movedManually?.id.rawValue, Int.max - 1, "A manual move invalidates a stale current-zone ID.")
    }

    func testModeCycleOverlapSameCenterAndNonfiniteHandling() {
        let zones = [zone(1, 0, 0), zone(2, 100, 0)]
        let center = CGRect(x: 50, y: -50, width: 100, height: 100)
        XCTAssertNil(navigate(.direction(.right), request(.zoneOrder, ZoneID(rawValue: 2), center, zones, false)))
        XCTAssertEqual(navigate(.direction(.right), request(.position, ZoneID(rawValue: 2), center, zones, true))?.id.rawValue, 1)
        XCTAssertNil(ZoneNavigator.directionalZone(from: center, zones: [zone(3, 100, 0)], direction: .right, workArea: area, cycle: true))
        XCTAssertNil(ZoneNavigator.directionalZone(from: CGRect(x: CGFloat.infinity, y: 0, width: 1, height: 1), zones: zones, direction: .right, workArea: area, cycle: false))
    }

    private func navigate(_ action: KeyboardSnapAction, _ request: ZoneNavigationRequest) -> Zone? {
        ZoneNavigator.zone(for: action, request: request)
    }

    private func request(
        _ mode: NavigationMode,
        _ currentID: ZoneID?,
        _ frame: CGRect,
        _ zones: [Zone],
        _ cycle: Bool
    ) -> ZoneNavigationRequest {
        .init(mode: mode, currentID: currentID, currentFrame: frame, zones: zones, workArea: area, cycle: cycle)
    }

    private var area: CGRect { CGRect(x: 0, y: 0, width: 1_000, height: 800) }

    private func zone(_ id: Int, _ centerX: CGFloat, _ centerY: CGFloat) -> Zone {
        Zone(id: ZoneID(rawValue: id), frame: CGRect(x: centerX - 50, y: centerY - 50, width: 100, height: 100))
    }
}
