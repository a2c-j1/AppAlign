import Combine
import CoreGraphics
import Foundation

@MainActor
final class LayoutEditorModel: ObservableObject {
    @Published private(set) var draft: PersistedLayout
    @Published private(set) var selectedZoneIDs = Set<Int>()
    @Published private(set) var errorMessage: String?
    @Published private(set) var isDirty = false
    @Published private(set) var gestureCancellationGeneration: UInt64 = 0

    private var baseline: PersistedLayout
    private var workArea: CGRect?
    private var undoStack: [EditorSnapshot] = []
    private var redoStack: [EditorSnapshot] = []
    private var gestureSnapshot: EditorSnapshot?

    init(layout: PersistedLayout, workArea: CGRect? = nil) {
        draft = layout
        baseline = layout
        self.workArea = workArea
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var isGestureInProgress: Bool { gestureSnapshot != nil }
    func selectZones(_ ids: Set<Int>) { selectedZoneIDs = ids }

    func setName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorMessage = "Enter a layout name."; return }
        update { makeLayout(definition: try draft.definition(), name: trimmed) }
    }

    func setSpacing(_ value: Double) {
        guard value.isFinite, value >= 0 else { errorMessage = LayoutError.invalidSpacing.localizedDescription; return }
        update { makeLayout(definition: try draft.definition(), spacing: draft.kind == .canvas ? 0 : value) }
    }

    func splitGrid(axis: GridAxis, track: Int) {
        guard let selectedID = selectedZoneIDs.first else { errorMessage = "Select a zone before splitting."; return }
        update {
            guard case .grid(let grid) = try draft.definition() else { throw LayoutError.invalidDimensions }
            let changed = try LayoutEditing.split(grid, zoneID: selectedID, axis: axis, track: track)
            return makeLayout(definition: .grid(changed), zoneCount: Set(changed.cellChildMap.flatMap { $0 }).count)
        }
    }

    func setGridPercentages(_ values: [Int], axis: GridAxis) {
        update {
            guard case .grid(let grid) = try draft.definition() else { throw LayoutError.invalidDimensions }
            let changed = try LayoutEditing.setPercentages(values, axis: axis, on: grid)
            return makeLayout(definition: .grid(changed))
        }
    }

    func mergeSelectedGridZones() {
        guard case .grid(let grid)? = try? draft.definition() else { errorMessage = LayoutError.invalidDimensions.localizedDescription; return }
        let cells = grid.cellChildMap.enumerated().flatMap { row, values in
            values.enumerated().compactMap { column, value in selectedZoneIDs.contains(value) ? (row, column, value) : nil }
        }
        guard let top = cells.map(\.0).min(), let left = cells.map(\.1).min(),
              let retainedID = cells.first(where: { $0.0 == top && $0.1 == left })?.2 else {
            errorMessage = LayoutError.invalidCellMap.localizedDescription
            return
        }
        update {
            let changed = try LayoutEditing.merge(grid, zoneIDs: selectedZoneIDs)
            return makeLayout(definition: .grid(changed), zoneCount: Set(changed.cellChildMap.flatMap { $0 }).count)
        } onSuccess: { self.selectedZoneIDs = [retainedID] }
    }

    func addCanvasZone(_ frame: CGRect) {
        update {
            guard let canvas = try draft.definition().canvasValue else { throw LayoutError.invalidDimensions }
            let changed = try LayoutEditing.addCanvasZone(canvas, frame: frame)
            return makeLayout(definition: canvasDefinition(changed), zoneCount: changed.zones.count)
        } onSuccess: {
            if let definition = try? self.draft.definition(), let id = definition.canvasValue?.zones.last?.id.rawValue {
                self.selectedZoneIDs = [id]
            }
        }
    }

    func moveOrResizeCanvasZone(id: ZoneID, frame: CGRect) {
        update {
            guard let canvas = try draft.definition().canvasValue else { throw LayoutError.invalidDimensions }
            let changed = try LayoutEditing.updateCanvasZone(canvas, id: id, frame: frame)
            return makeLayout(definition: canvasDefinition(changed), zoneCount: changed.zones.count)
        }
    }

    func deleteCanvasZone(id: ZoneID) {
        update {
            guard let canvas = try draft.definition().canvasValue else { throw LayoutError.invalidDimensions }
            let changed = try LayoutEditing.deleteCanvasZone(canvas, id: id)
            return makeLayout(definition: canvasDefinition(changed), zoneCount: changed.zones.count)
        } onSuccess: { self.selectedZoneIDs.remove(id.rawValue) }
    }

    func beginGesture() { if gestureSnapshot == nil { gestureSnapshot = snapshot } }

    func endGesture() {
        guard let start = gestureSnapshot else { return }
        gestureSnapshot = nil
        guard start.layout != draft else { return }
        appendUndo(start)
        isDirty = draft != baseline
    }

    func cancelGesture() {
        guard let start = gestureSnapshot else { return }
        gestureSnapshot = nil
        restore(start)
        gestureCancellationGeneration &+= 1
    }

    func undo() {
        guard gestureSnapshot == nil, let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot)
        restore(previous)
    }

    func redo() {
        guard gestureSnapshot == nil, let next = redoStack.popLast() else { return }
        undoStack.append(snapshot)
        restore(next)
    }

    func cancel() {
        gestureSnapshot = nil
        draft = baseline
        selectedZoneIDs.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        isDirty = false
        errorMessage = nil
    }

    func didSave(_ saved: PersistedLayout) {
        draft = saved
        baseline = saved
        gestureSnapshot = nil
        undoStack.removeAll()
        redoStack.removeAll()
        isDirty = false
        errorMessage = nil
    }

    func load(_ layout: PersistedLayout, workArea: CGRect? = nil) {
        draft = layout
        baseline = layout
        if let workArea { self.workArea = workArea }
        selectedZoneIDs.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        gestureSnapshot = nil
        isDirty = false
        errorMessage = nil
    }

    func updateWorkArea(_ newArea: CGRect) {
        workArea = newArea
        do { try validate(draft); errorMessage = nil } catch { errorMessage = error.localizedDescription }
    }

    func resetGrid(zoneCount: Int, in area: CGRect) {
        update {
            let template = LayoutTemplate(rawValue: draft.template) ?? .grid
            guard case .grid(let generated) = try LayoutTemplates.definition(for: template, zoneCount: zoneCount,
                                                                               area: area, spacing: draft.spacing) else {
                throw LayoutError.invalidDimensions
            }
            let previous: GridLayout
            if case .grid(let current) = try draft.definition() { previous = current } else { throw LayoutError.invalidDimensions }
            let grid = try LayoutEditing.replacingGridZones(in: previous, with: generated)
            return makeLayout(definition: .grid(grid), zoneCount: Set(grid.cellChildMap.flatMap { $0 }).count)
        } onSuccess: {
            let definition = try? self.draft.definition()
            let validIDs = Set(definition?.gridValue?.cellChildMap.flatMap { $0 } ?? [])
            self.selectedZoneIDs.formIntersection(validIDs)
        }
    }

    private var snapshot: EditorSnapshot { EditorSnapshot(layout: draft, selectedIDs: selectedZoneIDs) }

    private func update(_ change: () throws -> PersistedLayout, onSuccess: (() -> Void)? = nil) {
        let before = snapshot
        do {
            let changed = try change()
            guard changed != draft else { return }
            try validate(changed)
            if gestureSnapshot == nil { appendUndo(before) }
            draft = changed
            onSuccess?()
            isDirty = draft != baseline
            errorMessage = nil
        } catch {
            restore(before)
            errorMessage = error.localizedDescription
        }
    }

    private func appendUndo(_ value: EditorSnapshot) {
        undoStack.append(value)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func validate(_ layout: PersistedLayout) throws {
        try layout.validate()
        if let workArea { _ = try LayoutEngine.zones(for: layout.definition(), in: workArea, spacing: layout.spacing) }
    }

    private func restore(_ value: EditorSnapshot) {
        draft = value.layout
        selectedZoneIDs = value.selectedIDs
        isDirty = draft != baseline
    }

    private func makeLayout(definition: LayoutDefinition, name: String? = nil, spacing: Double? = nil, zoneCount: Int? = nil) -> PersistedLayout {
        PersistedLayout(id: draft.id, definition: definition, spacing: spacing ?? draft.spacing,
                        template: LayoutTemplate(rawValue: draft.template) ?? .grid,
                        zoneCount: zoneCount ?? draft.zoneCount, name: name ?? draft.name)
    }

    private func canvasDefinition(_ canvas: CanvasLayout) -> LayoutDefinition {
        draft.kind == .focus ? .focus(canvas) : .canvas(canvas)
    }
}

private struct EditorSnapshot {
    let layout: PersistedLayout
    let selectedIDs: Set<Int>
}

private extension LayoutDefinition {
    var canvasValue: CanvasLayout? {
        switch self {
        case .canvas(let canvas), .focus(let canvas): canvas
        case .grid: nil
        }
    }

    var gridValue: GridLayout? {
        if case .grid(let grid) = self { return grid }
        return nil
    }
}
