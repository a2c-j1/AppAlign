import CoreGraphics
import Foundation

struct ZoneID: Hashable, Identifiable, Sendable {
    let rawValue: Int
    var id: Int { rawValue }

    var displayNumber: String {
        let number = rawValue.addingReportingOverflow(1)
        return String(number.overflow ? rawValue : number.partialValue)
    }
}

struct LayoutID: Hashable, Identifiable, Sendable {
    let rawValue: UUID
    var id: UUID { rawValue }

    init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

struct GridLayout: Equatable, Sendable {
    let id: LayoutID
    let rows: Int
    let columns: Int
    let rowPercentages: [Int]
    let columnPercentages: [Int]
    let cellChildMap: [[Int]]

    init(
        id: LayoutID = LayoutID(),
        rows: Int,
        columns: Int,
        rowPercentages: [Int],
        columnPercentages: [Int],
        cellChildMap: [[Int]]
    ) {
        self.id = id
        self.rows = rows
        self.columns = columns
        self.rowPercentages = rowPercentages
        self.columnPercentages = columnPercentages
        self.cellChildMap = cellChildMap
    }
}

struct CanvasZone: Equatable, Sendable {
    let id: ZoneID
    let frame: CGRect
}

struct CanvasLayout: Equatable, Sendable {
    let id: LayoutID
    let referenceSize: CGSize
    let zones: [CanvasZone]

    init(id: LayoutID = LayoutID(), referenceSize: CGSize, zones: [CanvasZone]) {
        self.id = id
        self.referenceSize = referenceSize
        self.zones = zones
    }
}

enum LayoutDefinition: Equatable, Sendable {
    case grid(GridLayout)
    case canvas(CanvasLayout)
    case focus(CanvasLayout)
}

struct Zone: Identifiable, Equatable, Sendable {
    let id: ZoneID
    let frame: CGRect
}

enum LayoutError: LocalizedError, Equatable {
    case invalidDimensions
    case invalidPercentages
    case invalidCellMap
    case nonRectangularZone(ZoneID)
    case invalidSpacing
    case spacingLeavesNoArea
    case invalidArea
    case invalidCanvas
    case invalidZoneCount
    case arithmeticOverflow

    var errorDescription: String? {
        switch self {
        case .invalidDimensions: "Grid dimensions are invalid or exceed the supported maximum."
        case .invalidPercentages: "Grid percentages must be positive integers that total 10000."
        case .invalidCellMap: "The grid cell map does not match its declared dimensions."
        case .nonRectangularZone: "Each zone in the grid must occupy one complete rectangle."
        case .invalidSpacing: "Spacing must be a finite, nonnegative value supported by this layout."
        case .spacingLeavesNoArea: "Spacing leaves at least one zone with no usable area."
        case .invalidArea: "The display work area must have finite positive dimensions."
        case .invalidCanvas: "The canvas layout contains an invalid size, zone, or identifier."
        case .invalidZoneCount: "Choose between 1 and 128 zones."
        case .arithmeticOverflow: "The layout dimensions exceed the supported coordinate range."
        }
    }
}

enum LayoutTemplate: String, CaseIterable, Identifiable, Sendable {
    case columns
    case rows
    case grid
    case priorityGrid
    case focus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .columns: "Columns"
        case .rows: "Rows"
        case .grid: "Grid"
        case .priorityGrid: "Priority Grid"
        case .focus: "Focus"
        }
    }
}
