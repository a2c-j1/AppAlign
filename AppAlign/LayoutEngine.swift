import CoreGraphics
import Foundation

enum LayoutEngine {
    static let percentageTotal = 10_000
    static let maximumDimension = 128
    static let maximumCells = 16_384

    static func zones(for layout: LayoutDefinition, in area: CGRect, spacing: CGFloat = 0) throws -> [Zone] {
        guard DisplayGeometry.isFinite(area), area.width > 0, area.height > 0 else { throw LayoutError.invalidArea }
        switch layout {
        case .grid(let grid):
            return try gridZones(grid, in: area, spacing: spacing)
        case .canvas(let canvas):
            guard spacing.isFinite, spacing == 0 else { throw LayoutError.invalidSpacing }
            return try canvasZones(canvas, in: area)
        case .focus(let canvas):
            guard spacing.isFinite, spacing >= 0 else { throw LayoutError.invalidSpacing }
            let availableArea = area.insetBy(dx: spacing, dy: spacing)
            guard DisplayGeometry.isFinite(availableArea), availableArea.width > 0, availableArea.height > 0 else {
                throw LayoutError.spacingLeavesNoArea
            }
            return try canvasZones(canvas, in: availableArea)
        }
    }

    static func gridZones(_ grid: GridLayout, in area: CGRect, spacing: CGFloat = 0) throws -> [Zone] {
        let dimensions = grid.rows.multipliedReportingOverflow(by: grid.columns)
        guard grid.rows > 0, grid.rows <= maximumDimension,
              grid.columns > 0, grid.columns <= maximumDimension,
              !dimensions.overflow, dimensions.partialValue <= maximumCells else {
            throw LayoutError.invalidDimensions
        }
        guard grid.rowPercentages.count == grid.rows, grid.columnPercentages.count == grid.columns,
              validPercentages(grid.rowPercentages), validPercentages(grid.columnPercentages) else {
            throw LayoutError.invalidPercentages
        }
        let boundsByID = try validatedMapBounds(grid.cellChildMap, rows: grid.rows, columns: grid.columns)
        guard spacing.isFinite, spacing >= 0 else { throw LayoutError.invalidSpacing }
        guard DisplayGeometry.isFinite(area), area.width > 0, area.height > 0 else { throw LayoutError.invalidArea }

        let xEdges = try edges(start: area.minX, length: area.width, percentages: grid.columnPercentages)
        let yEdges = try edges(start: area.minY, length: area.height, percentages: grid.rowPercentages)
        var zones: [Zone] = []
        for child in boundsByID.keys.sorted() {
            guard let cellBounds = boundsByID[child] else { continue }
            let leftInset = cellBounds.minColumn == 0 ? spacing : spacing / 2
            let rightInset = cellBounds.maxColumn == grid.columns - 1 ? spacing : spacing / 2
            let topInset = cellBounds.minRow == 0 ? spacing : spacing / 2
            let bottomInset = cellBounds.maxRow == grid.rows - 1 ? spacing : spacing / 2
            let zoneOriginX = xEdges[cellBounds.minColumn] + leftInset
            let right = xEdges[cellBounds.maxColumn + 1] - rightInset
            let zoneOriginY = yEdges[cellBounds.minRow] + topInset
            let bottom = yEdges[cellBounds.maxRow + 1] - bottomInset
            guard zoneOriginX.isFinite, zoneOriginY.isFinite, right.isFinite, bottom.isFinite,
                  right > zoneOriginX, bottom > zoneOriginY else { throw LayoutError.spacingLeavesNoArea }
            zones.append(Zone(id: ZoneID(rawValue: child), frame: CGRect(x: zoneOriginX, y: zoneOriginY, width: right - zoneOriginX, height: bottom - zoneOriginY)))
        }
        return zones
    }

    static func canvasZones(_ canvas: CanvasLayout, in area: CGRect) throws -> [Zone] {
        guard DisplayGeometry.isFinite(area), area.width > 0, area.height > 0,
              canvas.referenceSize.width.isFinite, canvas.referenceSize.height.isFinite,
              canvas.referenceSize.width > 0, canvas.referenceSize.height > 0 else { throw LayoutError.invalidCanvas }
        var seen = Set<ZoneID>()
        for zone in canvas.zones {
            guard zone.id.rawValue >= 0, seen.insert(zone.id).inserted, DisplayGeometry.isFinite(zone.frame),
                  zone.frame.width > 0, zone.frame.height > 0,
                  zone.frame.minX >= 0, zone.frame.minY >= 0,
                  zone.frame.maxX <= canvas.referenceSize.width,
                  zone.frame.maxY <= canvas.referenceSize.height else { throw LayoutError.invalidCanvas }
        }
        let result = canvas.zones.map { zone in
            let left = area.minX + zone.frame.minX / canvas.referenceSize.width * area.width
            let right = area.minX + zone.frame.maxX / canvas.referenceSize.width * area.width
            let top = area.minY + zone.frame.minY / canvas.referenceSize.height * area.height
            let bottom = area.minY + zone.frame.maxY / canvas.referenceSize.height * area.height
            return Zone(
                id: zone.id,
                frame: CGRect(x: left, y: top, width: right - left, height: bottom - top)
            )
        }
        guard result.allSatisfy({ DisplayGeometry.isFinite($0.frame) && $0.frame.width > 0 && $0.frame.height > 0 }) else {
            throw LayoutError.arithmeticOverflow
        }
        return result.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    private static func validPercentages(_ percentages: [Int]) -> Bool {
        guard !percentages.isEmpty, percentages.allSatisfy({ (1 ... percentageTotal).contains($0) }) else { return false }
        var sum = 0
        for value in percentages {
            let next = sum.addingReportingOverflow(value)
            guard !next.overflow else { return false }
            sum = next.partialValue
        }
        return sum == percentageTotal
    }

    private static func edges(start: CGFloat, length: CGFloat, percentages: [Int]) throws -> [CGFloat] {
        var result = [CGFloat]()
        result.reserveCapacity(percentages.count + 1)
        result.append(start)
        var cumulative = 0
        for percentage in percentages.dropLast() {
            let next = cumulative.addingReportingOverflow(percentage)
            guard !next.overflow else { throw LayoutError.invalidPercentages }
            cumulative = next.partialValue
            let fraction = CGFloat(cumulative) / CGFloat(percentageTotal)
            let edge = start + floor(length * fraction)
            guard edge.isFinite else { throw LayoutError.arithmeticOverflow }
            result.append(edge)
        }
        result.append(start + length)
        guard result.allSatisfy(\.isFinite) else { throw LayoutError.arithmeticOverflow }
        return result
    }

    private struct CellBounds {
        let minRow: Int
        let maxRow: Int
        let minColumn: Int
        let maxColumn: Int
    }

    private static func validatedMapBounds(_ map: [[Int]], rows: Int, columns: Int) throws -> [Int: CellBounds] {
        guard map.count == rows, map.allSatisfy({ $0.count == columns }) else { throw LayoutError.invalidCellMap }
        var bounds: [Int: CellBounds] = [:]
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                let value = map[row][column]
                guard value >= 0 else { throw LayoutError.invalidCellMap }
                if let current = bounds[value] {
                    bounds[value] = CellBounds(
                        minRow: min(current.minRow, row), maxRow: max(current.maxRow, row),
                        minColumn: min(current.minColumn, column), maxColumn: max(current.maxColumn, column)
                    )
                } else {
                    bounds[value] = CellBounds(minRow: row, maxRow: row, minColumn: column, maxColumn: column)
                }
            }
        }
        for (value, rect) in bounds {
            for row in rect.minRow ... rect.maxRow {
                for column in rect.minColumn ... rect.maxColumn where map[row][column] != value {
                    throw LayoutError.nonRectangularZone(ZoneID(rawValue: value))
                }
            }
        }
        return bounds
    }
}
