import AppKit
import SwiftUI

struct LayoutEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var controller: LayoutController
    @StateObject private var model: LayoutEditorModel
    @State private var targetDisplayID: DisplaySelectionID
    @State private var selectedLayoutID: UUID
    @State private var catalog: [PersistedLayout]
    @State private var revision: UInt64 = 0
    @State private var nameText: String
    @State private var gridAxis: GridAxis = .columns
    @State private var splitTrack = 0
    @State private var ratioText = "2500, 5000, 2500"
    @State private var isBusy = false
    @State private var isDeleteConfirmationPresented = false
    @State private var statusMessage: String?
    @State private var isNewDraft = false
    @State private var requestedZoneCount = 3
    @State private var isResetGridConfirmationPresented = false
    @State private var isDraftChangeConfirmationPresented = false
    @State private var pendingSelection: PendingEditorSelection?

    init(controller: LayoutController, initialDisplayID: DisplaySelectionID) {
        self.controller = controller
        let snapshot = controller.editorCatalog(for: initialDisplayID)
        let initial = snapshot.layouts.first(where: { $0.id == snapshot.appliedLayoutID })
            ?? snapshot.layouts.first(where: { $0.id == PersistentStoreCoordinator.defaultLayoutID })
            ?? PersistentStoreCoordinator.defaultLayout()
        _model = StateObject(wrappedValue: LayoutEditorModel(layout: initial,
                                                             workArea: controller.displayProvider.snapshot.displays.first(where: { $0.id == initialDisplayID })?.workArea))
        _targetDisplayID = State(initialValue: initialDisplayID)
        _selectedLayoutID = State(initialValue: initial.id)
        _catalog = State(initialValue: snapshot.layouts)
        _nameText = State(initialValue: initial.name ?? "")
    }

    private var identity: EditorOperationIdentity {
        EditorOperationIdentity(token: editorToken, targetDisplay: targetDisplayID, revision: revision)
    }

    @State private var editorToken = UUID()

    private var selectedDisplay: Display? {
        controller.displayProvider.snapshot.displays.first { $0.id == targetDisplayID }
    }

    private var hasUnsavedDraft: Bool { model.isDirty || isNewDraft }

    private var editorZones: [Zone] {
        guard let display = selectedDisplay, let definition = try? model.draft.definition() else { return [] }
        return (try? LayoutEngine.zones(for: definition, in: display.workArea, spacing: model.draft.spacing)) ?? []
    }

    private var grid: GridLayout? {
        guard case .grid(let value)? = try? model.draft.definition() else { return nil }
        return value
    }

    private var canvas: CanvasLayout? {
        guard let definition = try? model.draft.definition() else { return nil }
        switch definition {
        case .canvas(let value), .focus(let value): return value
        case .grid: return nil
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
                .background(.quaternary.opacity(0.35))
                .disabled(isBusy || model.isGestureInProgress)
            Divider()
            editorContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 640)
        .onAppear(perform: synchronizeFields)
        .onChange(of: selectedDisplay?.workArea) { _, area in
            model.cancelGesture()
            if let area { model.updateWorkArea(area) }
        }
        .onChange(of: model.draft) { _, _ in synchronizeFields() }
        .onChange(of: gridAxis) { _, _ in synchronizeRatioField() }
        .interactiveDismissDisabled(hasUnsavedDraft || isBusy || model.isGestureInProgress)
        .confirmationDialog("This editor has an unsaved draft.", isPresented: $isDraftChangeConfirmationPresented) {
            Button("Save and Continue") { Task { await saveAndContinuePending() } }
            Button("Discard and Continue", role: .destructive) { continuePending(discard: true) }
            Button("Keep Editing", role: .cancel) { pendingSelection = nil }
        }
        .confirmationDialog("Delete this custom layout? Any display using it will return to the default layout.", isPresented: $isDeleteConfirmationPresented) {
            Button("Delete Layout", role: .destructive) { Task { await deleteSelectedLayout() } }
        }
    }

}

extension LayoutEditorView {
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Layouts").font(.headline).padding(.horizontal, 12).padding(.top, 16)
            Picker("Display", selection: Binding(
                get: { targetDisplayID },
                set: { newDisplay in requestDisplayChange(newDisplay) }
            )) {
                ForEach(controller.displayProvider.snapshot.displays) { display in
                    Text(display.name + (display.isPrimary ? " (Primary)" : "")).tag(display.id)
                }
            }
            .labelsHidden()
            .padding(.horizontal, 10)
            .disabled(isBusy)

            List {
                Section("Saved") {
                    ForEach(catalog, id: \.id) { layout in
                        Button {
                            choose(layout)
                        } label: {
                            HStack {
                                Image(systemName: symbol(for: layout))
                                Text(layout.name ?? layout.template)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if layout.id == controller.editorCatalog(for: targetDisplayID).appliedLayoutID {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(layout.id == selectedLayoutID ? Color.accentColor.opacity(0.15) : nil)
                    }
                }
                Section("Templates") {
                    ForEach(LayoutTemplate.allCases) { template in
                        Button {
                            chooseTemplate(template)
                        } label: {
                            Label(template.title, systemImage: "square.grid.2x2")
                        }
                        .buttonStyle(.plain)
                    }
                    Button { makeBlankCanvas() } label: { Label("Canvas", systemImage: "rectangle.dashed") }
                        .buttonStyle(.plain)
                }
            }
            .listStyle(.sidebar)
            .disabled(isBusy)

            HStack {
                Button { Task { await duplicateSelectedLayout() } } label: { Image(systemName: "plus.square.on.square") }
                    .disabled(isBusy)
                    .help("Duplicate selected layout")
                Button(role: .destructive) { requestDelete() } label: { Image(systemName: "trash") }
                    .disabled(isBusy || selectedLayoutID == PersistentStoreCoordinator.defaultLayoutID || !catalog.contains(where: { $0.id == selectedLayoutID }))
                    .help("Delete selected custom layout")
            }
            .padding(12)
        }
    }

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Layout Editor").font(.title2.weight(.semibold))
                if hasUnsavedDraft { Text("Unsaved").font(.caption).foregroundStyle(.orange) }
                Spacer()
                Button("Undo") { model.undo() }.disabled(!model.canUndo || isBusy)
                Button("Redo") { model.redo() }.disabled(!model.canRedo || isBusy)
            }

            HStack {
                TextField("Layout name", text: $nameText)
                    .textFieldStyle(.roundedBorder)
                Button("Rename") { Task { await renameSelectedLayout() } }
                    .disabled(nameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)
            }

            if let display = selectedDisplay {
                EditableLayoutPreview(display: display, zones: editorZones, model: model, definition: (try? model.draft.definition()))
                    .frame(maxHeight: 330)
                    .accessibilityLabel("Editable layout preview")
            } else {
                ContentUnavailableView("Display disconnected", systemImage: "display.slash")
                    .frame(height: 260)
            }

            if let grid {
                gridControls(grid)
            } else if canvas != nil {
                canvasControls
            }

            if let error = model.errorMessage ?? statusMessage ?? controller.persistenceErrorMessage {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
            }

            HStack {
                Button("Cancel") {
                    model.cancel()
                    dismiss()
                }
                Spacer()
                Button("Save") { Task { await saveDraft() } }
                    .disabled(isBusy || model.isGestureInProgress || !hasUnsavedDraft || selectedDisplay == nil)
                Button("Apply") { Task { await applyDraft() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy || model.isGestureInProgress || selectedDisplay == nil)
            }
        }
        .padding(22)
        .disabled(isBusy)
        .onExitCommand { model.cancelGesture() }
    }

    private func gridControls(_ grid: GridLayout) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Axis", selection: $gridAxis) {
                    Text("Columns").tag(GridAxis.columns)
                    Text("Rows").tag(GridAxis.rows)
                }
                .pickerStyle(.segmented)
                Stepper("Cut track: \(splitTrack + 1)", value: $splitTrack,
                        in: 0 ... max(0, (gridAxis == .columns ? grid.columns : grid.rows) - 1))
                Button("Split Selected Zone") { model.splitGrid(axis: gridAxis, track: splitTrack) }
                    .disabled(model.selectedZoneIDs.count != 1 || isBusy)
                Button("Merge Selected") { model.mergeSelectedGridZones() }
                    .disabled(model.selectedZoneIDs.count < 2 || isBusy)
            }
            HStack {
                Text("Track ratios (sum 10000)")
                TextField("2500, 5000, 2500", text: $ratioText)
                    .textFieldStyle(.roundedBorder)
                Button("Set") { applyRatios() }
            }
            spacingControls
            HStack {
                Stepper("Zones: \(requestedZoneCount)", value: $requestedZoneCount, in: 1 ... LayoutEngine.maximumDimension)
                Button("Reset to Template") { isResetGridConfirmationPresented = true }
                    .confirmationDialog("Replace the grid with this template and zone count? This is one undoable edit.", isPresented: $isResetGridConfirmationPresented) {
                        Button("Reset Grid", role: .destructive) {
                            if let area = selectedDisplay?.workArea { model.resetGrid(zoneCount: requestedZoneCount, in: area) }
                        }
                    }
            }
            zoneSelectionList(Array(Set(grid.cellChildMap.flatMap { $0 })).sorted())
        }
    }

    private var canvasControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Add Rectangle") { addCanvasRectangle() }
                Button("Delete Selected") {
                    if let id = model.selectedZoneIDs.first { model.deleteCanvasZone(id: ZoneID(rawValue: id)) }
                }
                .disabled(model.selectedZoneIDs.count != 1 || (canvas?.zones.count ?? 0) <= 1)
                Text("Overlapping zones are allowed. Drag a rectangle to move it; drag its handle to resize.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.draft.kind == .focus { spacingControls }
            if let canvas { zoneSelectionList(canvas.zones.map { $0.id.rawValue }.sorted()) }
        }
    }

    private var spacingControls: some View {
        HStack {
            Text("Spacing")
            Slider(value: Binding(
                get: { min(80, max(0, model.draft.spacing)) },
                set: { model.setSpacing($0) }
            ), in: 0 ... 80, step: 2, onEditingChanged: { editing in
                if editing { model.beginGesture() } else { model.endGesture() }
            })
            Text("\(model.draft.spacing.formatted(.number.precision(.fractionLength(0)))) pt")
                .monospacedDigit().frame(width: 60, alignment: .trailing)
        }
    }

    private func zoneSelectionList(_ ids: [Int]) -> some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(ids, id: \.self) { id in
                    Toggle("Zone \(ZoneID(rawValue: id).displayNumber)", isOn: Binding(
                        get: { model.selectedZoneIDs.contains(id) },
                        set: { selected in
                            var ids = model.selectedZoneIDs
                            if selected { ids.insert(id) } else { ids.remove(id) }
                            model.selectZones(ids)
                        }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
        }
        .frame(height: 24)
    }

    private func requestDisplayChange(_ newDisplay: DisplaySelectionID) {
        guard newDisplay != targetDisplayID else { return }
        requestSelection(.display(newDisplay))
    }

    private func requestSelection(_ selection: PendingEditorSelection) {
        if hasUnsavedDraft {
            pendingSelection = selection
            isDraftChangeConfirmationPresented = true
        } else {
            pendingSelection = selection
            continuePending(discard: false)
        }
    }

    private func saveAndContinuePending() async {
        await saveDraft()
        if !hasUnsavedDraft && statusMessage == nil { continuePending(discard: false) }
    }

    private func continuePending(discard: Bool) {
        guard let selection = pendingSelection else { return }
        if discard { model.cancel() }
        pendingSelection = nil
        switch selection {
        case .display(let next):
            targetDisplayID = next
            editorToken = UUID()
            revision = 0
            catalog = controller.editorCatalog(for: next).layouts
            let snapshot = controller.editorCatalog(for: next)
            let layout = snapshot.layouts.first(where: { $0.id == snapshot.appliedLayoutID }) ?? PersistentStoreCoordinator.defaultLayout()
            model.load(layout, workArea: controller.displayProvider.snapshot.displays.first(where: { $0.id == next })?.workArea)
            selectedLayoutID = layout.id
            isNewDraft = false
            synchronizeFields()
        case .layout(let layout): loadDraft(layout, isNew: false)
        case .template(let template): installTemplate(template)
        case .canvas: installBlankCanvas()
        case .delete(let id): selectedLayoutID = id; isDeleteConfirmationPresented = true
        case .duplicate(let id): selectedLayoutID = id; Task { await duplicateSelectedLayout() }
        }
    }

    private func choose(_ layout: PersistedLayout) {
        guard layout.id != selectedLayoutID else { return }
        requestSelection(.layout(layout))
    }

    private func chooseTemplate(_ template: LayoutTemplate) {
        requestSelection(.template(template))
    }

    private func installTemplate(_ template: LayoutTemplate) {
        guard let display = selectedDisplay,
              let definition = try? LayoutTemplates.definition(for: template, zoneCount: 3, area: display.workArea, spacing: 10) else { return }
        let draft = PersistedLayout(id: definition.layoutID, definition: definition, spacing: 10,
                                    template: template, zoneCount: 3, name: template.title)
        loadDraft(draft, isNew: true)
    }

    private func makeBlankCanvas() {
        requestSelection(.canvas)
    }

    private func installBlankCanvas() {
        let size = selectedDisplay?.workArea.size ?? CGSize(width: 1_000, height: 700)
        let canvas = CanvasLayout(referenceSize: size, zones: [CanvasZone(id: ZoneID(rawValue: 0), frame: CGRect(x: 0, y: 0, width: size.width * 0.65, height: size.height * 0.7))])
        let draft = PersistedLayout(id: canvas.id.rawValue, definition: .canvas(canvas), spacing: 0, template: .grid, zoneCount: 1, name: "Canvas")
        loadDraft(draft, isNew: true)
    }

    private func loadDraft(_ layout: PersistedLayout, isNew: Bool) {
        model.load(layout, workArea: selectedDisplay?.workArea)
        selectedLayoutID = layout.id
        isNewDraft = isNew
        synchronizeFields()
    }

    private func requestDelete() {
        if hasUnsavedDraft {
            pendingSelection = .delete(selectedLayoutID)
            isDraftChangeConfirmationPresented = true
        } else {
            isDeleteConfirmationPresented = true
        }
    }

    private func renameSelectedLayout() async {
        let trimmed = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { statusMessage = "Enter a layout name."; return }
        guard !isBusy else { return }
        if isNewDraft || model.isDirty {
            model.setName(trimmed)
            return
        }
        guard catalog.contains(where: { $0.id == selectedLayoutID }) else {
            statusMessage = "The selected layout is unavailable."
            return
        }
        isBusy = true
        revision &+= 1
        let result = await controller.renameEditorLayout(selectedLayoutID, to: trimmed, identity: identity)
        if case .success(let saved?) = result {
            model.didSave(saved)
            catalog = controller.editorCatalog(for: targetDisplayID).layouts
            synchronizeFields()
        } else if case .failure(let message) = result { statusMessage = message }
        isBusy = false
    }

    private func applyRatios() {
        let parts = ratioText.split(separator: ",", omittingEmptySubsequences: false)
        let values = parts.compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        var sum = 0
        var hasOverflow = false
        for value in values {
            let next = sum.addingReportingOverflow(value)
            sum = next.partialValue
            hasOverflow = hasOverflow || next.overflow
        }
        guard values.count == parts.count, values.allSatisfy({ $0 > 0 }), !hasOverflow,
              sum == LayoutEngine.percentageTotal else {
            statusMessage = "Enter positive ratios that sum to 10000."
            return
        }
        model.setGridPercentages(values, axis: gridAxis)
        statusMessage = model.errorMessage
    }

    private func addCanvasRectangle() {
        guard let canvas else { return }
        let frame = CGRect(x: canvas.referenceSize.width * 0.15, y: canvas.referenceSize.height * 0.15,
                           width: canvas.referenceSize.width * 0.55, height: canvas.referenceSize.height * 0.55)
        model.addCanvasZone(frame)
    }

    private func synchronizeFields() {
        nameText = model.draft.name ?? ""
        requestedZoneCount = model.draft.zoneCount
        synchronizeRatioField()
    }

    private func synchronizeRatioField() {
        guard let grid else { return }
        let values = gridAxis == .columns ? grid.columnPercentages : grid.rowPercentages
        ratioText = values.map(String.init).joined(separator: ", ")
    }

    private func saveDraft() async {
        guard !isBusy else { return }
        isBusy = true
        statusMessage = nil
        let submittedDraft = model.draft
        let submittedTarget = targetDisplayID
        let submittedToken = editorToken
        revision &+= 1
        let result = await controller.saveEditorLayout(model.draft, identity: identity)
        switch result {
        case .success(let saved):
            if let saved {
                guard model.draft == submittedDraft, targetDisplayID == submittedTarget, editorToken == submittedToken else { break }
                model.didSave(saved)
                isNewDraft = false
                selectedLayoutID = saved.id
                catalog = controller.editorCatalog(for: targetDisplayID).layouts
                synchronizeFields()
            }
        case .failure(let message): statusMessage = message
        }
        isBusy = false
    }

    private func applyDraft() async {
        guard !isBusy else { return }
        if hasUnsavedDraft {
            await saveDraft()
            guard !hasUnsavedDraft else { return }
        }
        isBusy = true
        revision &+= 1
        let result = await controller.applyEditorLayout(model.draft.id, identity: identity)
        if case .failure(let message) = result { statusMessage = message }
        if case .success(let saved) = result, let saved { model.didSave(saved) }
        catalog = controller.editorCatalog(for: targetDisplayID).layouts
        isBusy = false
    }

    private func duplicateSelectedLayout() async {
        guard !isBusy else { return }
        guard !hasUnsavedDraft else { requestSelection(.duplicate(selectedLayoutID)); return }
        isBusy = true
        let sourceTarget = targetDisplayID
        let sourceToken = editorToken
        revision &+= 1
        let result = await controller.duplicateEditorLayout(selectedLayoutID, identity: identity)
        if case .success(let layout?) = result, targetDisplayID == sourceTarget, editorToken == sourceToken {
            catalog = controller.editorCatalog(for: targetDisplayID).layouts
            loadDraft(layout, isNew: false)
            selectedLayoutID = layout.id
            synchronizeFields()
        } else if case .failure(let message) = result { statusMessage = message }
        isBusy = false
    }

    private func deleteSelectedLayout() async {
        guard !isBusy else { return }
        isBusy = true
        let id = selectedLayoutID
        let sourceTarget = targetDisplayID
        let sourceToken = editorToken
        revision &+= 1
        let result = await controller.deleteEditorLayout(id, identity: identity)
        if case .success = result, targetDisplayID == sourceTarget, editorToken == sourceToken {
            catalog = controller.editorCatalog(for: targetDisplayID).layouts
            let fallback = catalog.first(where: { $0.id == controller.editorCatalog(for: targetDisplayID).appliedLayoutID })
                ?? PersistentStoreCoordinator.defaultLayout()
            loadDraft(fallback, isNew: false)
            selectedLayoutID = fallback.id
            synchronizeFields()
        } else if case .failure(let message) = result { statusMessage = message }
        isBusy = false
    }

    private func symbol(for layout: PersistedLayout) -> String {
        switch layout.kind {
        case .grid: "square.grid.2x2"
        case .canvas: "rectangle.dashed"
        case .focus: "viewfinder"
        }
    }
}

private extension LayoutDefinition {
    var layoutID: UUID {
        switch self {
        case .grid(let value): value.id.rawValue
        case .canvas(let value), .focus(let value): value.id.rawValue
        }
    }
}

private enum PendingEditorSelection {
    case display(DisplaySelectionID)
    case layout(PersistedLayout)
    case template(LayoutTemplate)
    case canvas
    case delete(UUID)
    case duplicate(UUID)
}
