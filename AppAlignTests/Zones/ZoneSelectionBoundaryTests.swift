import CoreGraphics
import Foundation
import XCTest

final class ZoneSelectionBoundaryTests: XCTestCase {
    func testAllOverlapModesRespectFourHalfOpenWorkAreaEdges() {
        let area = CGRect(x: -20, y: -10, width: 100, height: 80)
        let zone = Zone(id: ZoneID(rawValue: 27), frame: area)
        for strategy in ZoneOverlapStrategy.allCases {
            for point in [CGPoint(x: area.minX, y: area.minY), CGPoint(x: area.minX, y: area.midY),
                          CGPoint(x: area.midX, y: area.minY)] {
                XCTAssertEqual(ZoneSelectionEngine.selectZones(point: point, zones: [zone], workArea: area,
                                                              radius: 20, strategy: strategy).map(\.id), [zone.id])
            }
            for point in [CGPoint(x: area.maxX, y: area.midY), CGPoint(x: area.midX, y: area.maxY),
                          CGPoint(x: area.maxX, y: area.maxY)] {
                XCTAssertTrue(ZoneSelectionEngine.selectZones(point: point, zones: [zone], workArea: area,
                                                             radius: 20, strategy: strategy).isEmpty)
            }
        }
    }

    func testClosestCenterThresholdBelowEqualAndAboveSeventyFive() {
        let area = CGRect(x: -100, y: -100, width: 200, height: 200)
        let large = Zone(id: ZoneID(rawValue: 9), frame: CGRect(x: -50, y: -50, width: 100, height: 100))
        let distanceY = CGFloat(50).squareRoot()
        for (delta, expected) in [(CGFloat(-0.001), 2), (CGFloat(0), 2), (CGFloat(0.001), 9)] {
            let small = Zone(id: ZoneID(rawValue: 2), frame: CGRect(x: -1, y: distanceY + delta - 8, width: 12, height: 16))
            let distanceSquared = small.frame.midX * small.frame.midX + small.frame.midY * small.frame.midY
            if delta == 0 { XCTAssertEqual(distanceSquared, 75) }
            XCTAssertEqual(ZoneSelectionEngine.selectZones(point: .zero, zones: [large, small], workArea: area,
                                                          radius: 0, strategy: .closestCenter).map(\.id),
                           [ZoneID(rawValue: expected)])
        }
    }

    func testNontransitiveClosestCenterFoldFollowsFixedLayoutOrder() {
        let area = CGRect(x: -100, y: -100, width: 200, height: 200)
        let first = Zone(id: ZoneID(rawValue: 90), frame: CGRect(x: -50, y: -50, width: 100, height: 100))
        let second = Zone(id: ZoneID(rawValue: 3), frame: CGRect(x: -2, y: CGFloat(50).squareRoot() - 8, width: 14, height: 16))
        let third = Zone(id: ZoneID(rawValue: 25), frame: CGRect(x: -19, y: -10, width: 20, height: 20))
        // first/second use area, second/third use cursor distance, third/first
        // use cursor distance. This cyclic preference must never enter a sort.
        for _ in 0 ..< 10 {
            XCTAssertEqual(ZoneSelectionEngine.selectZones(point: CGPoint(x: -1, y: 0), zones: [first, second, third],
                                                          workArea: area, radius: 0, strategy: .closestCenter).map(\.id), [third.id])
            XCTAssertEqual(ZoneSelectionEngine.selectZones(point: CGPoint(x: -1, y: 0), zones: [first, third, second],
                                                          workArea: area, radius: 0, strategy: .closestCenter).map(\.id), [second.id])
        }
    }
}
