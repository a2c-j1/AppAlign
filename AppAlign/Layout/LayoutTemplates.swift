import CoreGraphics
import Foundation

enum LayoutTemplates {
    static func definition(for template: LayoutTemplate, zoneCount: Int, area: CGRect, spacing: CGFloat = 0) throws -> LayoutDefinition {
        guard (1 ... LayoutEngine.maximumDimension).contains(zoneCount) else { throw LayoutError.invalidZoneCount }
        guard spacing.isFinite, spacing >= 0 else { throw LayoutError.invalidSpacing }
        switch template {
        case .columns:
            return .grid(grid(rows: 1, columns: zoneCount, map: [Array(0 ..< zoneCount)]))
        case .rows:
            return .grid(grid(rows: zoneCount, columns: 1, map: (0 ..< zoneCount).map { [$0] }))
        case .grid:
            let rows = max(1, Int(floor(sqrt(Double(zoneCount)))))
            let columns = (zoneCount + rows - 1) / rows
            let map = (0 ..< rows).map { row in
                (0 ..< columns).map { column in min(row * columns + column, zoneCount - 1) }
            }
            return .grid(grid(rows: rows, columns: columns, map: map))
        case .priorityGrid:
            return .grid(priorityGrid(zoneCount: zoneCount))
        case .focus:
            return .focus(try focusCanvas(zoneCount: zoneCount, area: area, spacing: spacing))
        }
    }

    private static func grid(
        rows: Int,
        columns: Int,
        rowPercentages: [Int]? = nil,
        columnPercentages: [Int]? = nil,
        map: [[Int]]
    ) -> GridLayout {
        GridLayout(
            rows: rows,
            columns: columns,
            rowPercentages: rowPercentages ?? equalPercentages(rows),
            columnPercentages: columnPercentages ?? equalPercentages(columns),
            cellChildMap: map
        )
    }

    private static func equalPercentages(_ count: Int) -> [Int] {
        guard count > 0 else { return [] }
        return (0 ..< count).map { index in
            let start = index * LayoutEngine.percentageTotal / count
            let end = (index + 1) * LayoutEngine.percentageTotal / count
            return end - start
        }
    }

    private static func priorityGrid(zoneCount: Int) -> GridLayout {
        // Adapted preset table from Microsoft PowerToys FancyZones LayoutConfigurator.cpp
        // at commit 1400fd8e999f381329e16e9df4084f7dc588c8a7; table data only.
        // AppAlign-specific validation and geometry are implemented independently.
        // See THIRD_PARTY_NOTICES.md for the source link and complete MIT notice.
        let presets: [GridLayout?] = [
            nil,
            grid(rows: 1, columns: 1, rowPercentages: [10_000], columnPercentages: [10_000], map: [[0]]),
            grid(rows: 1, columns: 2, rowPercentages: [10_000], columnPercentages: [6_667, 3_333], map: [[0, 1]]),
            grid(rows: 1, columns: 3, rowPercentages: [10_000], columnPercentages: [2_500, 5_000, 2_500], map: [[0, 1, 2]]),
            grid(rows: 2, columns: 3, rowPercentages: [5_000, 5_000], columnPercentages: [2_500, 5_000, 2_500], map: [[0, 1, 2], [0, 1, 3]]),
            grid(rows: 2, columns: 3, rowPercentages: [5_000, 5_000], columnPercentages: [2_500, 5_000, 2_500], map: [[0, 1, 2], [3, 1, 4]]),
            grid(rows: 3, columns: 3, rowPercentages: [3_333, 3_334, 3_333], columnPercentages: [2_500, 5_000, 2_500], map: [[0, 1, 2], [0, 1, 3], [4, 1, 5]]),
            grid(rows: 3, columns: 3, rowPercentages: [3_333, 3_334, 3_333], columnPercentages: [2_500, 5_000, 2_500], map: [[0, 1, 2], [3, 1, 4], [5, 1, 6]]),
            grid(rows: 3, columns: 4, rowPercentages: [3_333, 3_334, 3_333], columnPercentages: [2_500, 2_500, 2_500, 2_500], map: [[0, 1, 2, 3], [4, 1, 2, 5], [6, 1, 2, 7]]),
            grid(rows: 3, columns: 4, rowPercentages: [3_333, 3_334, 3_333], columnPercentages: [2_500, 2_500, 2_500, 2_500], map: [[0, 1, 2, 3], [4, 1, 2, 5], [6, 1, 7, 8]]),
            grid(rows: 3, columns: 4, rowPercentages: [3_333, 3_334, 3_333], columnPercentages: [2_500, 2_500, 2_500, 2_500], map: [[0, 1, 2, 3], [4, 1, 5, 6], [7, 1, 8, 9]]),
            grid(rows: 3, columns: 4, rowPercentages: [3_333, 3_334, 3_333], columnPercentages: [2_500, 2_500, 2_500, 2_500], map: [[0, 1, 2, 3], [4, 1, 5, 6], [7, 8, 9, 10]])
        ]
        if zoneCount <= 11, let preset = presets[zoneCount] { return preset }
        let rows = max(1, Int(floor(sqrt(Double(zoneCount)))))
        let columns = (zoneCount + rows - 1) / rows
        let map = (0 ..< rows).map { row in
            (0 ..< columns).map { column in min(row * columns + column, zoneCount - 1) }
        }
        return grid(rows: rows, columns: columns, map: map)
    }

    private static func focusCanvas(zoneCount: Int, area: CGRect, spacing: CGFloat) throws -> CanvasLayout {
        let availableWidth = area.width - spacing * 2
        let availableHeight = area.height - spacing * 2
        guard availableWidth.isFinite, availableHeight.isFinite, availableWidth > 0, availableHeight > 0 else {
            throw LayoutError.spacingLeavesNoArea
        }
        let width = floor(availableWidth * 0.4)
        let height = floor(availableHeight * 0.4)
        guard width > 0, height > 0 else { throw LayoutError.invalidArea }
        let remainingX = availableWidth - width
        let remainingY = availableHeight - height
        let offsetX = min(100, remainingX / 2)
        let offsetY = min(100, remainingY / 2)
        let stepX = zoneCount <= 1 ? 0 : min(50, (remainingX - offsetX) / CGFloat(zoneCount - 1))
        let stepY = zoneCount <= 1 ? 0 : min(50, (remainingY - offsetY) / CGFloat(zoneCount - 1))
        let zones = (0 ..< zoneCount).map { index -> CanvasZone in
            let zoneOriginX = offsetX + CGFloat(index) * stepX
            let zoneOriginY = offsetY + CGFloat(index) * stepY
            return CanvasZone(id: ZoneID(rawValue: index), frame: CGRect(x: zoneOriginX, y: zoneOriginY, width: width, height: height))
        }
        return CanvasLayout(referenceSize: CGSize(width: availableWidth, height: availableHeight), zones: zones)
    }
}
