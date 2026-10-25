import CoreGraphics
import Foundation

enum GridAxis: Equatable, Sendable { case rows, columns }

enum LayoutEditing {
    static func replacingGridZones(in previous: GridLayout, with generated: GridLayout) throws -> GridLayout {
        let oldIDs = orderedUnique(previous.cellChildMap.flatMap { $0 })
        let newIDs = orderedUnique(generated.cellChildMap.flatMap { $0 })
        guard !newIDs.isEmpty, newIDs.count <= LayoutEngine.maximumDimension else { throw LayoutError.invalidZoneCount }
        var assignedIDs = Array(oldIDs.prefix(newIDs.count))
        if assignedIDs.count < newIDs.count {
            var next = (oldIDs.max() ?? -1).addingReportingOverflow(1)
            guard !next.overflow, next.partialValue >= 0 else { throw LayoutError.arithmeticOverflow }
            while assignedIDs.count < newIDs.count {
                assignedIDs.append(next.partialValue)
                if assignedIDs.count < newIDs.count {
                    next = next.partialValue.addingReportingOverflow(1)
                    guard !next.overflow else { throw LayoutError.arithmeticOverflow }
                }
            }
        }
        let replacements = Dictionary(uniqueKeysWithValues: zip(newIDs, assignedIDs))
        let map = generated.cellChildMap.map { row in row.map { replacements[$0] ?? $0 } }
        let result = GridLayout(id: previous.id, rows: generated.rows, columns: generated.columns,
                                rowPercentages: generated.rowPercentages, columnPercentages: generated.columnPercentages,
                                cellChildMap: map)
        try LayoutEngine.validateGridStructure(result)
        return result
    }

    static func split(_ grid: GridLayout, zoneID: Int, axis: GridAxis, track: Int) throws -> GridLayout {
        let originalZones = Set(grid.cellChildMap.flatMap { $0 })
        guard originalZones.contains(zoneID) else { throw LayoutError.invalidCellMap }
        let percentages = axis == .columns ? grid.columnPercentages : grid.rowPercentages
        guard percentages.indices.contains(track), percentages[track] >= 2 else { throw LayoutError.invalidPercentages }
        let selectedTracks = axis == .columns
            ? grid.cellChildMap.flatMap { values in values.indices.filter { values[$0] == zoneID } }
            : grid.cellChildMap.indices.filter { grid.cellChildMap[$0].contains(zoneID) }
        guard let low = selectedTracks.min(), let high = selectedTracks.max(), (low ... high).contains(track) else {
            throw LayoutError.invalidCellMap
        }
        guard originalZones.count < LayoutEngine.maximumDimension else { throw LayoutError.invalidZoneCount }
        let nextID = (grid.cellChildMap.flatMap { $0 }.max() ?? -1).addingReportingOverflow(1)
        guard !nextID.overflow, nextID.partialValue >= 0 else { throw LayoutError.arithmeticOverflow }
        var adjusted = percentages
        let first = percentages[track] / 2
        adjusted[track] = first
        adjusted.insert(percentages[track] - first, at: track + 1)
        var map = grid.cellChildMap
        if axis == .columns {
            for row in map.indices {
                map[row].insert(map[row][track], at: track + 1)
            }
            for row in map.indices {
                for column in map[row].indices where column > track && map[row][column] == zoneID {
                    map[row][column] = nextID.partialValue
                }
            }
            let result = GridLayout(id: grid.id, rows: grid.rows, columns: grid.columns + 1,
                                   rowPercentages: grid.rowPercentages, columnPercentages: adjusted, cellChildMap: map)
            try LayoutEngine.validateGridStructure(result)
            return result
        }
        map.insert(map[track], at: track + 1)
        for row in map.indices where row > track {
            for column in map[row].indices where map[row][column] == zoneID { map[row][column] = nextID.partialValue }
        }
        guard Set(map.flatMap { $0 }).count <= LayoutEngine.maximumDimension else { throw LayoutError.invalidZoneCount }
        let result = GridLayout(id: grid.id, rows: grid.rows + 1, columns: grid.columns,
                               rowPercentages: adjusted, columnPercentages: grid.columnPercentages, cellChildMap: map)
        try LayoutEngine.validateGridStructure(result)
        return result
    }

    static func setPercentages(_ values: [Int], axis: GridAxis, on grid: GridLayout) throws -> GridLayout {
        var total = 0
        for value in values {
            let addition = total.addingReportingOverflow(value)
            guard !addition.overflow else { throw LayoutError.invalidPercentages }
            total = addition.partialValue
        }
        guard values.count == (axis == .columns ? grid.columns : grid.rows), values.allSatisfy({ $0 > 0 }),
              total == LayoutEngine.percentageTotal else { throw LayoutError.invalidPercentages }
        let result = GridLayout(id: grid.id, rows: grid.rows, columns: grid.columns,
                                rowPercentages: axis == .rows ? values : grid.rowPercentages,
                                columnPercentages: axis == .columns ? values : grid.columnPercentages,
                                cellChildMap: grid.cellChildMap)
        try LayoutEngine.validateGridStructure(result)
        return result
    }

    static func merge(_ grid: GridLayout, zoneIDs: Set<Int>) throws -> GridLayout {
        guard zoneIDs.count > 1 else { throw LayoutError.invalidCellMap }
        let cells = grid.cellChildMap.enumerated().flatMap { row, values in
            values.enumerated().compactMap { column, value in zoneIDs.contains(value) ? (row, column) : nil }
        }
        guard zoneIDs.isSubset(of: Set(grid.cellChildMap.flatMap { $0 })),
              let top = cells.map(\.0).min(), let bottom = cells.map(\.0).max(),
              let left = cells.map(\.1).min(), let right = cells.map(\.1).max(),
              cells.count == (bottom - top + 1) * (right - left + 1) else { throw LayoutError.invalidCellMap }
        let retained = grid.cellChildMap[top][left]
        var map = grid.cellChildMap
        for row in top ... bottom {
            for column in left ... right { map[row][column] = retained }
        }
        let result = GridLayout(id: grid.id, rows: grid.rows, columns: grid.columns,
                                rowPercentages: grid.rowPercentages, columnPercentages: grid.columnPercentages, cellChildMap: map)
        try LayoutEngine.validateGridStructure(result)
        return result
    }

    static func addCanvasZone(_ canvas: CanvasLayout, frame: CGRect) throws -> CanvasLayout {
        guard canvas.zones.count < LayoutEngine.maximumDimension, frame.isFinitePositive,
              CGRect(origin: .zero, size: canvas.referenceSize).contains(frame) else { throw LayoutError.invalidCanvas }
        let rawIDs = canvas.zones.map { $0.id.rawValue }
        let nextID = (rawIDs.max() ?? -1).addingReportingOverflow(1)
        guard !nextID.overflow, nextID.partialValue >= 0 else { throw LayoutError.arithmeticOverflow }
        return CanvasLayout(id: canvas.id, referenceSize: canvas.referenceSize,
                            zones: canvas.zones + [CanvasZone(id: ZoneID(rawValue: nextID.partialValue), frame: frame)])
    }

    static func updateCanvasZone(_ canvas: CanvasLayout, id: ZoneID, frame: CGRect) throws -> CanvasLayout {
        guard frame.isFinitePositive, CGRect(origin: .zero, size: canvas.referenceSize).contains(frame),
              canvas.zones.contains(where: { $0.id == id }) else { throw LayoutError.invalidCanvas }
        return CanvasLayout(id: canvas.id, referenceSize: canvas.referenceSize,
                            zones: canvas.zones.map { $0.id == id ? CanvasZone(id: id, frame: frame) : $0 })
    }

    static func deleteCanvasZone(_ canvas: CanvasLayout, id: ZoneID) throws -> CanvasLayout {
        let zones = canvas.zones.filter { $0.id != id }
        guard zones.count < canvas.zones.count, !zones.isEmpty else { throw LayoutError.invalidCanvas }
        return CanvasLayout(id: canvas.id, referenceSize: canvas.referenceSize, zones: zones)
    }

    private static func orderedUnique(_ values: [Int]) -> [Int] {
        var seen = Set<Int>()
        return values.filter { seen.insert($0).inserted }
    }
}

private extension CGRect {
    var isFinitePositive: Bool {
        minX.isFinite && minY.isFinite && width.isFinite && height.isFinite && width > 0 && height > 0
    }
}
