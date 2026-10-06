import CoreGraphics
import Foundation
import XCTest

final class DisplayGeometryTests: XCTestCase {
    func testPrimaryAndVisibleFramesUseTopLeftGlobalCoordinates() throws {
        let primary = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let visible = CGRect(x: 0, y: 24, width: 1_440, height: 851)
        XCTAssertEqual(
            try DisplayGeometry.globalFrame(from: visible, primaryFrame: primary),
            CGRect(x: 0, y: 25, width: 1_440, height: 851)
        )
    }

    func testDisplaysAboveBelowAndMainHeightChange() throws {
        let primary900 = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        XCTAssertEqual(
            try DisplayGeometry.globalFrame(from: CGRect(x: 0, y: 900, width: 1_000, height: 700), primaryFrame: primary900).minY,
            -700
        )
        XCTAssertEqual(
            try DisplayGeometry.globalFrame(from: CGRect(x: 0, y: -700, width: 1_000, height: 700), primaryFrame: primary900).minY,
            900
        )
        let primary1080 = CGRect(x: 0, y: 0, width: 1_440, height: 1_080)
        let moved = try DisplayGeometry.globalFrame(from: CGRect(x: 0, y: 900, width: 1_000, height: 700), primaryFrame: primary1080)
        XCTAssertEqual(moved.minY, -520)
        XCTAssertEqual(moved.minY - (-700), 180)
    }

    func testLogicalGeometryIgnoresBackingScaleFactor() throws {
        let primary = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let cocoa = CGRect(x: -1_200, y: 900, width: 2_000, height: 1_000)
        let expected = CGRect(x: -1_200, y: -1_000, width: 2_000, height: 1_000)
        let global = try DisplayGeometry.globalFrame(from: cocoa, primaryFrame: primary)
        XCTAssertEqual(global, expected)
        XCTAssertEqual(try DisplayGeometry.cocoaFrame(from: expected, primaryFrame: primary), cocoa)

        let scale1 = Display(runtimeID: RuntimeDisplayID(rawValue: 1), persistentID: nil, sessionID: UUID(), name: "one", frame: expected, workArea: expected, isPrimary: false, backingScaleFactor: 1)
        let scale2 = Display(runtimeID: RuntimeDisplayID(rawValue: 2), persistentID: nil, sessionID: UUID(), name: "two", frame: expected, workArea: expected, isPrimary: false, backingScaleFactor: 2)
        let template = try LayoutTemplates.definition(for: .columns, zoneCount: 2, area: scale1.workArea)
        let atScale1 = try LayoutEngine.zones(for: template, in: scale1.workArea)
        let atScale2 = try LayoutEngine.zones(for: template, in: scale2.workArea)
        XCTAssertEqual(atScale1.map(\.frame), [CGRect(x: -1_200, y: -1_000, width: 1_000, height: 1_000), CGRect(x: -200, y: -1_000, width: 1_000, height: 1_000)])
        XCTAssertEqual(atScale1, atScale2)
    }

    func testNonFiniteAndOverflowingFramesAreRejected() {
        let primary = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        XCTAssertThrowsError(try DisplayGeometry.globalFrame(from: CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 10), primaryFrame: primary))
        XCTAssertThrowsError(try DisplayGeometry.globalFrame(from: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10), primaryFrame: primary))
        XCTAssertThrowsError(try DisplayGeometry.globalFrame(from: .zero, primaryFrame: primary))
        let maximum = CGFloat.greatestFiniteMagnitude
        let tallPrimary = CGRect(x: 0, y: 0, width: 1, height: maximum)
        XCTAssertThrowsError(try DisplayGeometry.globalFrame(from: CGRect(x: 0, y: -maximum, width: 1, height: maximum), primaryFrame: tallPrimary)) { error in
            XCTAssertEqual(error as? DisplayGeometryError, .invalidFrame)
        }
        XCTAssertThrowsError(try DisplayGeometry.cocoaFrame(from: CGRect(x: 0, y: -maximum, width: 1, height: maximum), primaryFrame: tallPrimary)) { error in
            XCTAssertEqual(error as? DisplayGeometryError, .invalidFrame)
        }
    }

    func testDisplayIdentityFallbackIsSessionStableAndDuplicateUUIDIsNotPersistent() throws {
        var resolver = DisplayIdentityResolver()
        let uuid = UUID()
        let unique = resolver.resolveSnapshot([DisplayIdentityCandidate(runtimeID: 1, uuid: uuid)])
        let repeated = resolver.resolveSnapshot([DisplayIdentityCandidate(runtimeID: 1, uuid: uuid)])
        XCTAssertEqual(unique, repeated)
        XCTAssertEqual(unique.first?.persistentID, PersistentDisplayID(uuid: uuid))
        let duplicates = resolver.resolveSnapshot([
            DisplayIdentityCandidate(runtimeID: 1, uuid: uuid),
            DisplayIdentityCandidate(runtimeID: 2, uuid: uuid)
        ])
        XCTAssertEqual(duplicates.count, 2)
        XCTAssertTrue(duplicates.allSatisfy { $0.persistentID == nil })
        XCTAssertNotEqual(duplicates[0].sessionID, duplicates[1].sessionID)
        XCTAssertNotEqual(
            WorkAreaKey(display: .session(duplicates[0].sessionID), spaceScope: nil),
            WorkAreaKey(display: .session(duplicates[1].sessionID), spaceScope: nil)
        )
        XCTAssertNil(duplicates[0].persistentID.map { WorkAreaKey(display: .persistent($0), spaceScope: nil) })
        let missing = try XCTUnwrap(resolver.resolveSnapshot([DisplayIdentityCandidate(runtimeID: 3, uuid: nil)]).first)
        XCTAssertNil(missing.persistentID)
        XCTAssertEqual(missing.sessionID, resolver.resolveSnapshot([DisplayIdentityCandidate(runtimeID: 3, uuid: nil)]).first?.sessionID)
        let fallbackDisplay = Display(
            runtimeID: RuntimeDisplayID(rawValue: 3), persistentID: nil, sessionID: missing.sessionID,
            name: "Temporary", frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            workArea: CGRect(x: 0, y: 0, width: 100, height: 100), isPrimary: false, backingScaleFactor: 1
        )
        XCTAssertNil(fallbackDisplay.persistentWorkAreaKey)
        XCTAssertEqual(fallbackDisplay.selectionKey.display, DisplaySelectionID.session(missing.sessionID))
        _ = resolver.resolveSnapshot([])
        let reconnected = try XCTUnwrap(resolver.resolveSnapshot([DisplayIdentityCandidate(runtimeID: 3, uuid: nil)]).first)
        XCTAssertNotEqual(reconnected.sessionID, missing.sessionID)
    }
}

final class LayoutEngineTests: XCTestCase {
    private let area = CGRect(x: 0, y: 0, width: 1_001, height: 600)

    func testUnevenWidthsUseCumulativeBoundaries() throws {
        let zones = try LayoutEngine.gridZones(grid(
            rows: 1,
            columns: 3,
            rowPercentages: [10_000],
            columnPercentages: [2_500, 5_000, 2_500],
            map: [[0, 1, 2]]
        ), in: area)
        XCTAssertEqual(zones.map(\.frame.minX), [0, 250, 750])
        XCTAssertEqual(zones.map(\.frame.maxX), [250, 750, 1_001])
    }

    func testThirdsAssignRemainderAtCumulativeEdges() throws {
        let zones = try LayoutEngine.gridZones(grid(
            rows: 1,
            columns: 3,
            rowPercentages: [10_000],
            columnPercentages: [3_333, 3_333, 3_334],
            map: [[0, 1, 2]]
        ), in: area)
        XCTAssertEqual(zones.map(\.frame.minX), [0, 333, 667])
        XCTAssertEqual(zones.map(\.frame.maxX), [333, 667, 1_001])
    }

    func testFractionalAreaUsesExactFinalBoundary() throws {
        let fractionalArea = CGRect(x: 0, y: 0, width: 1_001.5, height: 600)
        let zones = try LayoutEngine.gridZones(grid(
            rows: 1,
            columns: 3,
            rowPercentages: [10_000],
            columnPercentages: [2_500, 5_000, 2_500],
            map: [[0, 1, 2]]
        ), in: fractionalArea)
        XCTAssertEqual(zones.map(\.frame.minX), [0, 250, 751])
        XCTAssertEqual(zones.map(\.frame.maxX), [250, 751, 1_001.5])
    }

    func testExteriorAndInteriorSpacing() throws {
        let zones = try LayoutEngine.gridZones(grid(
            rows: 1,
            columns: 3,
            rowPercentages: [10_000],
            columnPercentages: [2_500, 5_000, 2_500],
            map: [[0, 1, 2]]
        ), in: area, spacing: 10)
        XCTAssertEqual(zones.map(\.frame.minX), [10, 255, 755])
        XCTAssertEqual(zones.map(\.frame.maxX), [245, 745, 991])
    }

    func testMergedRectangularCellHasNoInternalGap() throws {
        let layout = grid(
            rows: 2,
            columns: 3,
            rowPercentages: [5_000, 5_000],
            columnPercentages: [2_500, 5_000, 2_500],
            map: [[0, 1, 2], [3, 1, 4]]
        )
        let zones = try LayoutEngine.gridZones(layout, in: CGRect(x: 0, y: 0, width: 1_000, height: 600))
        let merged = try XCTUnwrap(zones.first { $0.id.rawValue == 1 })
        XCTAssertEqual(merged.frame, CGRect(x: 250, y: 0, width: 500, height: 600))
        let spaced = try XCTUnwrap(try LayoutEngine.gridZones(layout, in: CGRect(x: 0, y: 0, width: 1_000, height: 600), spacing: 10).first { $0.id.rawValue == 1 })
        XCTAssertEqual(spaced.frame, CGRect(x: 255, y: 10, width: 490, height: 580))
    }

    func testLShapedAndDisconnectedCellsAreRejected() {
        XCTAssertThrowsError(try LayoutEngine.gridZones(grid(rows: 2, columns: 2, rowPercentages: [5_000, 5_000], columnPercentages: [5_000, 5_000], map: [[0, 0], [0, 1]]), in: area)) { error in
            XCTAssertEqual(error as? LayoutError, .nonRectangularZone(ZoneID(rawValue: 0)))
        }
        XCTAssertThrowsError(try LayoutEngine.gridZones(grid(rows: 1, columns: 3, columnPercentages: [3_333, 3_333, 3_334], map: [[0, 1, 0]]), in: area)) { error in
            XCTAssertEqual(error as? LayoutError, .nonRectangularZone(ZoneID(rawValue: 0)))
        }
        XCTAssertThrowsError(try LayoutEngine.gridZones(grid(rows: 3, columns: 3, rowPercentages: [3_333, 3_334, 3_333], columnPercentages: [3_333, 3_334, 3_333], map: [[0, 0, 0], [0, 1, 0], [0, 0, 0]]), in: area)) { error in
            XCTAssertEqual(error as? LayoutError, .nonRectangularZone(ZoneID(rawValue: 0)))
        }
    }

    func testInvalidPercentagesDimensionsAndMapsFailWithoutTrapping() {
        for percentages in [[9_999], [10_001], [0, 10_000], [-1, 10_001], [Int.max]] {
            XCTAssertThrowsError(try LayoutEngine.gridZones(grid(rows: 1, columns: percentages.count, columnPercentages: percentages, map: [Array(repeating: 0, count: percentages.count)]), in: area))
        }
        XCTAssertThrowsError(try LayoutEngine.gridZones(grid(rows: Int.max, columns: 2, rowPercentages: [], columnPercentages: [5_000, 5_000], map: []), in: area))
        XCTAssertThrowsError(try LayoutEngine.gridZones(grid(rows: 0, columns: 0, rowPercentages: [], columnPercentages: [], map: []), in: area)) { error in
            XCTAssertEqual(error as? LayoutError, .invalidDimensions)
        }
        XCTAssertThrowsError(try LayoutEngine.gridZones(grid(rows: 1, columns: 2, map: [[0]]), in: area))
        XCTAssertThrowsError(try LayoutEngine.gridZones(grid(rows: 1, columns: 1, map: [[Int.min]]), in: area))
        XCTAssertThrowsError(try LayoutTemplates.definition(for: .grid, zoneCount: 0, area: area))
        XCTAssertThrowsError(try LayoutTemplates.definition(for: .grid, zoneCount: 129, area: area))
    }

    func testExtremeZoneIdentifiersRemainSafeInGridAndCanvas() throws {
        let maxID = ZoneID(rawValue: Int.max)
        XCTAssertEqual(maxID.displayNumber, String(Int.max))
        let extremeGrid = grid(rows: 1, columns: 1, rowPercentages: [10_000], columnPercentages: [10_000], map: [[Int.max]])
        XCTAssertEqual(try LayoutEngine.gridZones(extremeGrid, in: area).first?.id.displayNumber, String(Int.max))
        let extremeCanvas = CanvasLayout(
            referenceSize: CGSize(width: 100, height: 100),
            zones: [CanvasZone(id: maxID, frame: CGRect(x: 0, y: 0, width: 50, height: 50))]
        )
        XCTAssertEqual(try LayoutEngine.canvasZones(extremeCanvas, in: area).first?.id.displayNumber, String(Int.max))
    }

    func testSpacingThatEliminatesAnyZoneRejectsWholeLayout() {
        XCTAssertThrowsError(try LayoutEngine.gridZones(
            grid(rows: 1, columns: 2, columnPercentages: [5_000, 5_000], map: [[0, 1]]),
            in: CGRect(x: 0, y: 0, width: 100, height: 100),
            spacing: 34
        ))
    }

    func testCanvasScalesEachEdgeAndAllowsOverlap() throws {
        let canvas = CanvasLayout(
            referenceSize: CGSize(width: 1_000, height: 500),
            zones: [
                CanvasZone(id: ZoneID(rawValue: 4), frame: CGRect(x: 100, y: 50, width: 300, height: 200)),
                CanvasZone(id: ZoneID(rawValue: 1), frame: CGRect(x: 200, y: 75, width: 300, height: 200))
            ]
        )
        let zones = try LayoutEngine.canvasZones(canvas, in: CGRect(x: -1_200, y: 30, width: 2_000, height: 1_000))
        XCTAssertEqual(zones.map(\.id.rawValue), [1, 4])
        XCTAssertEqual(zones.first { $0.id.rawValue == 4 }?.frame, CGRect(x: -1_000, y: 130, width: 600, height: 400))
        XCTAssertEqual(zones.first { $0.id.rawValue == 1 }?.frame, CGRect(x: -800, y: 180, width: 600, height: 400))
        XCTAssertThrowsError(try LayoutEngine.zones(for: .canvas(canvas), in: area, spacing: 2))
    }

    func testCanvasShrinksEachEdgeAgainstIndependentReferenceSize() throws {
        let canvas = CanvasLayout(
            referenceSize: CGSize(width: 1_000, height: 500),
            zones: [CanvasZone(id: ZoneID(rawValue: 0), frame: CGRect(x: 100, y: 50, width: 300, height: 200))]
        )
        let zones = try LayoutEngine.canvasZones(canvas, in: CGRect(x: 0, y: 0, width: 500, height: 250))
        XCTAssertEqual(zones.first?.frame, CGRect(x: 50, y: 25, width: 150, height: 100))
    }

    func testCanvasAllowsEmptyButRejectsInvalidBoundsDuplicatesAndNegativeIDs() throws {
        let empty = CanvasLayout(referenceSize: CGSize(width: 100, height: 100), zones: [])
        XCTAssertEqual(try LayoutEngine.canvasZones(empty, in: area), [])
        let invalid = CanvasLayout(referenceSize: CGSize(width: 100, height: 100), zones: [CanvasZone(id: ZoneID(rawValue: 0), frame: CGRect(x: 90, y: 0, width: 20, height: 10))])
        XCTAssertThrowsError(try LayoutEngine.canvasZones(invalid, in: area))
        let duplicate = CanvasLayout(referenceSize: CGSize(width: 100, height: 100), zones: [
            CanvasZone(id: ZoneID(rawValue: 1), frame: CGRect(x: 0, y: 0, width: 10, height: 10)),
            CanvasZone(id: ZoneID(rawValue: 1), frame: CGRect(x: 20, y: 0, width: 10, height: 10))
        ])
        XCTAssertThrowsError(try LayoutEngine.canvasZones(duplicate, in: area))
        let negative = CanvasLayout(referenceSize: CGSize(width: 100, height: 100), zones: [CanvasZone(id: ZoneID(rawValue: -1), frame: CGRect(x: 0, y: 0, width: 10, height: 10))])
        XCTAssertThrowsError(try LayoutEngine.canvasZones(negative, in: area))
        let nanReference = CanvasLayout(referenceSize: CGSize(width: CGFloat.nan, height: 100), zones: [])
        XCTAssertThrowsError(try LayoutEngine.canvasZones(nanReference, in: area))
        for invalidReference in [CGSize(width: 0, height: 100), CGSize(width: CGFloat.infinity, height: 100)] {
            let invalidCanvas = CanvasLayout(referenceSize: invalidReference, zones: [])
            XCTAssertThrowsError(try LayoutEngine.canvasZones(invalidCanvas, in: area)) { error in
                XCTAssertEqual(error as? LayoutError, .invalidCanvas)
            }
        }
        let outputRoundsToZero = CanvasLayout(referenceSize: CGSize(width: 100, height: 1), zones: [CanvasZone(id: ZoneID(rawValue: 0), frame: CGRect(x: 0, y: 0, width: 1, height: 1))])
        XCTAssertThrowsError(try LayoutEngine.canvasZones(outputRoundsToZero, in: CGRect(x: 0, y: 0, width: CGFloat.leastNonzeroMagnitude, height: 1)))
    }

    func testNonFiniteAndNegativeSpacingIsRejected() {
        let layout = grid(rows: 1, columns: 1, rowPercentages: [10_000], columnPercentages: [10_000], map: [[0]])
        for spacing: CGFloat in [.nan, .infinity, -1] {
            XCTAssertThrowsError(try LayoutEngine.gridZones(layout, in: area, spacing: spacing)) { error in
                XCTAssertEqual(error as? LayoutError, .invalidSpacing)
            }
        }
    }

    func testTemplatesCoverBoundariesAndPriorityLayoutIsStable() throws {
        for count in [1, 5, 11, 12, 128] {
            for template in LayoutTemplate.allCases {
                let definition = try LayoutTemplates.definition(for: template, zoneCount: count, area: area)
                let zones = try LayoutEngine.zones(for: definition, in: area)
                XCTAssertEqual(zones.count, count, "\(template) \(count)")
                XCTAssertEqual(zones.map(\.id.rawValue), Array(0 ..< count))
            }
        }
        guard case .grid(let priority) = try LayoutTemplates.definition(for: .priorityGrid, zoneCount: 5, area: area) else {
            return XCTFail("Expected a grid template")
        }
        XCTAssertEqual(priority.cellChildMap, [[0, 1, 2], [3, 1, 4]])
        guard case .grid(let twelve) = try LayoutTemplates.definition(for: .priorityGrid, zoneCount: 12, area: area) else {
            return XCTFail("Expected grid fallback")
        }
        XCTAssertEqual(twelve.rows, 3)
        XCTAssertEqual(twelve.columns, 4)
        guard case .grid(let eleven) = try LayoutTemplates.definition(for: .priorityGrid, zoneCount: 11, area: area) else {
            return XCTFail("Expected priority preset")
        }
        XCTAssertEqual(eleven.cellChildMap, [[0, 1, 2, 3], [4, 1, 5, 6], [7, 8, 9, 10]])
    }

    func testFocusPositionsRemainWithinSmallWorkArea() throws {
        let smallArea = CGRect(x: -100, y: 20, width: 120, height: 100)
        let definition = try LayoutTemplates.definition(for: .focus, zoneCount: 5, area: smallArea, spacing: 4)
        let zones = try LayoutEngine.zones(for: definition, in: smallArea, spacing: 4)
        XCTAssertEqual(zones.count, 5)
        XCTAssertTrue(zones.allSatisfy { smallArea.contains($0.frame) })
    }

    func testFocusUsesBoundedOffsetAndStepForLargeZoneCount() throws {
        let workArea = CGRect(x: 0, y: 0, width: 1_200, height: 900)
        let definition = try LayoutTemplates.definition(for: .focus, zoneCount: 128, area: workArea, spacing: 10)
        let zones = try LayoutEngine.zones(for: definition, in: workArea, spacing: 10)
        XCTAssertEqual(zones.first?.frame, CGRect(x: 110, y: 110, width: 472, height: 352))
        let last = try XCTUnwrap(zones.last)
        XCTAssertEqual(last.frame.minX, 110 + (608.0 / 127.0) * 127.0, accuracy: 0.000_001)
        XCTAssertEqual(last.frame.minY, 110 + (428.0 / 127.0) * 127.0, accuracy: 0.000_001)
        XCTAssertTrue(zones.allSatisfy { workArea.contains($0.frame) })
    }

    private func grid(
        rows: Int,
        columns: Int,
        rowPercentages: [Int]? = nil,
        columnPercentages: [Int]? = nil,
        map: [[Int]]
    ) -> GridLayout {
        GridLayout(
            rows: rows,
            columns: columns,
            rowPercentages: rowPercentages ?? Array(repeating: 10_000 / max(1, rows), count: max(1, rows)),
            columnPercentages: columnPercentages ?? Array(repeating: 10_000 / max(1, columns), count: max(1, columns)),
            cellChildMap: map
        )
    }
}
