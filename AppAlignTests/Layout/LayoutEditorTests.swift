import XCTest

final class LayoutEditorTests: XCTestCase {
    func testSelectedGridZoneSplitPreservesOtherMergedZonesAndRatios() throws {
        let grid = GridLayout(
            rows: 2, columns: 3,
            rowPercentages: [5_000, 5_000], columnPercentages: [2_500, 5_000, 2_500],
            cellChildMap: [[0, 1, 2], [3, 1, 4]]
        )
        let split = try LayoutEditing.split(grid, zoneID: 0, axis: .columns, track: 0)
        XCTAssertEqual(split.columnPercentages, [1_250, 1_250, 5_000, 2_500])
        XCTAssertEqual(split.cellChildMap, [[0, 5, 1, 2], [3, 3, 1, 4]])
        XCTAssertEqual(Set(split.cellChildMap.flatMap { $0 }), [0, 1, 2, 3, 4, 5])
        _ = try LayoutEngine.gridZones(split, in: CGRect(x: 0, y: 0, width: 1_000, height: 600))
    }

    func testRowSplitChangesOnlySelectedZone() throws {
        let grid = GridLayout(
            rows: 2, columns: 2,
            rowPercentages: [5_000, 5_000], columnPercentages: [5_000, 5_000],
            cellChildMap: [[0, 1], [2, 3]]
        )
        let split = try LayoutEditing.split(grid, zoneID: 2, axis: .rows, track: 1)
        XCTAssertEqual(split.cellChildMap, [[0, 1], [2, 3], [4, 3]])
        XCTAssertEqual(split.rowPercentages, [5_000, 2_500, 2_500])
        _ = try LayoutEngine.gridZones(split, in: CGRect(x: 0, y: 0, width: 800, height: 600))
    }

    func testSplitMergedZonesUsesRectangularCutAndLeavesOtherZoneIDsUntouched() throws {
        let horizontal = GridLayout(rows: 2, columns: 3, rowPercentages: [5_000, 5_000],
                                    columnPercentages: [3_000, 4_000, 3_000], cellChildMap: [[7, 7, 7], [8, 8, 9]])
        let horizontalSplit = try LayoutEditing.split(horizontal, zoneID: 7, axis: .columns, track: 1)
        XCTAssertEqual(horizontalSplit.cellChildMap, [[7, 7, 10, 10], [8, 8, 8, 9]])
        _ = try LayoutEngine.gridZones(horizontalSplit, in: CGRect(x: 0, y: 0, width: 900, height: 600))

        let vertical = GridLayout(rows: 3, columns: 2, rowPercentages: [3_000, 4_000, 3_000],
                                  columnPercentages: [5_000, 5_000], cellChildMap: [[7, 8], [7, 9], [7, 10]])
        let verticalSplit = try LayoutEditing.split(vertical, zoneID: 7, axis: .rows, track: 1)
        XCTAssertEqual(verticalSplit.cellChildMap, [[7, 8], [7, 9], [11, 9], [11, 10]])
        _ = try LayoutEngine.gridZones(verticalSplit, in: CGRect(x: 0, y: 0, width: 900, height: 600))
    }

    func testRectangleMergePreservesTopLeftZoneIDAndRejectsLShape() throws {
        let grid = GridLayout(rows: 2, columns: 2, rowPercentages: [5_000, 5_000],
                              columnPercentages: [5_000, 5_000], cellChildMap: [[7, 8], [9, 10]])
        let merged = try LayoutEditing.merge(grid, zoneIDs: [7, 8, 9, 10])
        XCTAssertEqual(merged.cellChildMap, [[7, 7], [7, 7]])
        XCTAssertThrowsError(try LayoutEditing.merge(grid, zoneIDs: [7, 8, 9]))
        XCTAssertThrowsError(try LayoutEditing.merge(grid, zoneIDs: [7, 99]))
    }

    func testCanvasOverlapMoveResizeAndStableIDs() throws {
        let canvas = CanvasLayout(referenceSize: CGSize(width: 1_000, height: 800), zones: [
            CanvasZone(id: ZoneID(rawValue: 20), frame: CGRect(x: 0, y: 0, width: 600, height: 500)),
            CanvasZone(id: ZoneID(rawValue: 50), frame: CGRect(x: 300, y: 200, width: 600, height: 500))
        ])
        let changed = try LayoutEditing.updateCanvasZone(canvas, id: ZoneID(rawValue: 50),
                                                          frame: CGRect(x: 100, y: 100, width: 700, height: 600))
        XCTAssertEqual(changed.zones.map(\.id.rawValue), [20, 50])
        XCTAssertEqual(changed.zones[1].frame, CGRect(x: 100, y: 100, width: 700, height: 600))
        _ = try LayoutEngine.canvasZones(changed, in: CGRect(x: 0, y: 0, width: 1_000, height: 800))
    }

    func testSparseZoneIDsAndOverflowAreHandled() throws {
        let sparse = GridLayout(rows: 1, columns: 1, rowPercentages: [10_000], columnPercentages: [10_000],
                                cellChildMap: [[1_000]])
        let split = try LayoutEditing.split(sparse, zoneID: 1_000, axis: .columns, track: 0)
        XCTAssertEqual(split.cellChildMap, [[1_000, 1_001]])
        let overflowing = GridLayout(rows: 1, columns: 1, rowPercentages: [10_000], columnPercentages: [10_000],
                                     cellChildMap: [[Int.max]])
        XCTAssertThrowsError(try LayoutEditing.split(overflowing, zoneID: Int.max, axis: .columns, track: 0))
    }

    func testGridSplitHonorsZoneLimitAt127And128Zones() throws {
        let map127 = [Array(0 ..< 127)]
        let grid127 = GridLayout(rows: 1, columns: 127, rowPercentages: [10_000],
                                 columnPercentages: Array(repeating: 1, count: 126) + [9_874],
                                 cellChildMap: map127)
        let split127 = try LayoutEditing.split(grid127, zoneID: 126, axis: .columns, track: 126)
        XCTAssertEqual(Set(split127.cellChildMap.flatMap { $0 }).count, 128)
        XCTAssertEqual(split127.columns, 128)

        let map128 = [Array(0 ..< 64), Array(64 ..< 128)]
        let grid128 = GridLayout(rows: 2, columns: 64, rowPercentages: [5_000, 5_000],
                                 columnPercentages: Array(repeating: 1, count: 63) + [9_937], cellChildMap: map128)
        XCTAssertThrowsError(try LayoutEditing.split(grid128, zoneID: 0, axis: .rows, track: 0))
    }

    func testGridPercentagesPersistAndLegacyMissingNameDecodes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppAlignEditor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let grid = GridLayout(id: LayoutID(rawValue: id), rows: 1, columns: 3,
                              rowPercentages: [10_000], columnPercentages: [2_500, 5_000, 2_500],
                              cellChildMap: [[4, 8, 12]])
        let layout = PersistedLayout(id: id, definition: .grid(grid), spacing: 10, template: .priorityGrid,
                                     zoneCount: 3, name: "Wide center")
        let coordinator = PersistentStoreCoordinator(directory: directory)
        let tinyTracksID = UUID()
        let tinyTracksGrid = GridLayout(id: LayoutID(rawValue: tinyTracksID), rows: 1, columns: 127,
                                        rowPercentages: [10_000], columnPercentages: Array(repeating: 1, count: 126) + [9_874],
                                        cellChildMap: [Array(0 ..< 127)])
        let tinyTracks = PersistedLayout(id: tinyTracksID, definition: .grid(tinyTracksGrid), spacing: 0,
                                         template: .columns, zoneCount: 127)
        try await coordinator.saveLayouts([layout, tinyTracks])
        let reopened = try await PersistentStoreCoordinator(directory: directory).load()
        XCTAssertEqual(reopened.layouts[id], layout)
        XCTAssertEqual(reopened.layouts[tinyTracksID], tinyTracks)
        XCTAssertFalse(reopened.layoutStoreNeedsRepair)
        XCTAssertFalse(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.contains(where: { $0.lastPathComponent.contains("backup") }))
        XCTAssertEqual(try reopened.layouts[id]?.definition(), .grid(grid))

        let legacy = Data("""
        {"id":"\(UUID().uuidString)","kind":"grid","rows":1,"columns":1,
         "rowPercentages":[10000],"columnPercentages":[10000],"cellChildMap":[[2]],
         "spacing":0,"template":"grid","zoneCount":1}
        """.utf8)
        XCTAssertNil(try JSONDecoder().decode(PersistedLayout.self, from: legacy).name)
    }

    @MainActor
    func testEditorModelUndoRedoGestureAndCancelPreserveBaseline() throws {
        let original = PersistentStoreCoordinator.defaultLayout()
        let model = LayoutEditorModel(layout: original, workArea: CGRect(x: 0, y: 0, width: 1_000, height: 700))
        model.setName(" Desk ")
        XCTAssertEqual(model.draft.name, "Desk")
        model.undo()
        XCTAssertNil(model.draft.name)
        model.redo()
        XCTAssertEqual(model.draft.name, "Desk")

        model.beginGesture()
        model.setGridPercentages([4_500, 5_500], axis: .columns)
        model.setGridPercentages([4_000, 6_000], axis: .columns)
        model.endGesture()
        model.undo()
        guard case .grid(let restored) = try model.draft.definition() else { return XCTFail("Expected grid") }
        XCTAssertEqual(restored.columnPercentages, [5_000, 5_000])
        model.redo()
        guard case .grid(let redone) = try model.draft.definition() else { return XCTFail("Expected grid") }
        XCTAssertEqual(redone.columnPercentages, [4_000, 6_000])

        model.cancel()
        XCTAssertEqual(model.draft, original)
        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(model.canUndo)
    }

    @MainActor
    func testCancelGestureRestoresDraftSelectionAndSignalsPreviewWithoutAddingHistory() throws {
        let original = PersistentStoreCoordinator.defaultLayout()
        let model = LayoutEditorModel(layout: original, workArea: CGRect(x: 0, y: 0, width: 1_000, height: 700))
        model.selectZones([1])
        let initialGeneration = model.gestureCancellationGeneration
        model.beginGesture()
        model.setGridPercentages([4_500, 5_500], axis: .columns)
        XCTAssertNotEqual(model.draft, original)
        model.cancelGesture()
        XCTAssertEqual(model.draft, original)
        XCTAssertEqual(model.selectedZoneIDs, [1])
        XCTAssertEqual(model.gestureCancellationGeneration, initialGeneration + 1)
        XCTAssertFalse(model.isGestureInProgress)
        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(model.canUndo)
        XCTAssertFalse(model.canRedo)
    }

    @MainActor
    func testRejectedGridEditRestoresDraftSelectionAndHistory() throws {
        let map = [Array(0 ..< 64), Array(64 ..< 128)]
        let grid = GridLayout(rows: 2, columns: 64, rowPercentages: [5_000, 5_000],
                              columnPercentages: Array(repeating: 1, count: 63) + [9_937], cellChildMap: map)
        let layout = PersistedLayout(id: grid.id.rawValue, definition: .grid(grid), spacing: 0,
                                     template: .grid, zoneCount: 128)
        let model = LayoutEditorModel(layout: layout, workArea: CGRect(x: 0, y: 0, width: 1_000, height: 700))
        model.selectZones([0])
        model.splitGrid(axis: .rows, track: 0)
        XCTAssertEqual(model.draft, layout)
        XCTAssertEqual(model.selectedZoneIDs, [0])
        XCTAssertFalse(model.canUndo)
        XCTAssertTrue(model.errorMessage != nil)

        let smallGrid = GridLayout(rows: 1, columns: 2, rowPercentages: [10_000],
                                   columnPercentages: [5_000, 5_000], cellChildMap: [[2, 8]])
        let smallLayout = PersistedLayout(id: smallGrid.id.rawValue, definition: .grid(smallGrid), spacing: 0,
                                          template: .columns, zoneCount: 2)
        let smallArea = CGRect(x: 0, y: 0, width: 100, height: 100)
        let spacingModel = LayoutEditorModel(layout: smallLayout, workArea: smallArea)
        spacingModel.setSpacing(51)
        XCTAssertEqual(spacingModel.draft, smallLayout)
        XCTAssertFalse(spacingModel.canUndo)
        spacingModel.setGridPercentages([10_001], axis: .columns)
        XCTAssertEqual(spacingModel.draft, smallLayout)
        XCTAssertFalse(spacingModel.canUndo)
    }

    @MainActor
    func testGridReplacementPreservesExistingZoneIDsAndRejectsIDOverflow() throws {
        let id = UUID()
        let oldGrid = GridLayout(id: LayoutID(rawValue: id), rows: 1, columns: 3, rowPercentages: [10_000],
                                 columnPercentages: [3_000, 4_000, 3_000], cellChildMap: [[7, 15, 1_000]])
        let layout = PersistedLayout(id: id, definition: .grid(oldGrid), spacing: 0, template: .columns, zoneCount: 3)
        let model = LayoutEditorModel(layout: layout, workArea: CGRect(x: 0, y: 0, width: 1_000, height: 700))
        model.resetGrid(zoneCount: 2, in: CGRect(x: 0, y: 0, width: 1_000, height: 700))
        guard case .grid(let replaced) = try model.draft.definition() else { return XCTFail("Expected grid") }
        XCTAssertEqual(Set(replaced.cellChildMap.flatMap { $0 }), [7, 15])
        XCTAssertTrue(model.canUndo)

        let maximumGrid = GridLayout(rows: 1, columns: 1, rowPercentages: [10_000], columnPercentages: [10_000],
                                     cellChildMap: [[Int.max]])
        let maximumLayout = PersistedLayout(id: maximumGrid.id.rawValue, definition: .grid(maximumGrid), spacing: 0,
                                            template: .columns, zoneCount: 1)
        let overflowModel = LayoutEditorModel(layout: maximumLayout, workArea: CGRect(x: 0, y: 0, width: 1_000, height: 700))
        overflowModel.resetGrid(zoneCount: 2, in: CGRect(x: 0, y: 0, width: 1_000, height: 700))
        XCTAssertEqual(overflowModel.draft, maximumLayout)
        XCTAssertFalse(overflowModel.canUndo)
        XCTAssertNotNil(overflowModel.errorMessage)
    }
}
