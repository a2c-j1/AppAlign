import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var placementController: PlacementController
    @EnvironmentObject private var layoutController: LayoutController
    @EnvironmentObject private var dragDetectionController: DragDetectionController
    @EnvironmentObject private var dragSnapController: DragSnapController
    @State private var isLayoutEditorPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("AppAlign")
                    .font(.largeTitle.weight(.semibold))
                Text("Accessibility and window-placement proof of concept")
                    .foregroundStyle(.secondary)
            }

            GroupBox("Display layout") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Picker("Display", selection: Binding(
                            get: { layoutController.selectedDisplayID },
                            set: { if let id = $0 { layoutController.selectDisplay(id) } }
                        )) {
                            ForEach(layoutController.displayProvider.snapshot.displays) { display in
                                Text(display.name + (display.isPrimary ? " (Primary)" : ""))
                                    .tag(Optional(display.id))
                            }
                        }
                        .disabled(!layoutController.canEdit || layoutController.displayProvider.snapshot.displays.isEmpty)

                        Button("Edit Layout…") { isLayoutEditorPresented = true }
                            .disabled(!layoutController.canEdit || layoutController.selectedDisplayID == nil)

                        Button("Refresh Displays") {
                            layoutController.refreshDisplays()
                        }
                        .disabled(!layoutController.canEdit)
                    }

                    HStack {
                        Picker("Template", selection: $layoutController.template) {
                            ForEach(LayoutTemplate.allCases) { template in
                                Text(template.title).tag(template)
                            }
                        }
                        Stepper("Zones: \(layoutController.zoneCount)", value: $layoutController.zoneCount, in: 1 ... 128)
                    }
                    .disabled(!layoutController.canEdit)

                    HStack {
                        Text("Spacing: \(layoutController.spacing.formatted(.number.precision(.fractionLength(0)))) pt")
                            .frame(width: 130, alignment: .leading)
                        Slider(value: $layoutController.spacing, in: 0 ... 80, step: 2)
                    }
                    .disabled(!layoutController.canEdit)

                    LayoutPreview(
                        display: layoutController.selectedDisplay,
                        zones: layoutController.zones,
                        selectedZoneID: layoutController.selectedZoneID,
                        select: { layoutController.selectedZoneID = $0 }
                    )
                    .disabled(!layoutController.canEdit)

                    HStack {
                        Button("Place Captured Window in Selected Zone") {
                            Task { await layoutController.placeSelectedZone(using: placementController) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!layoutController.canEdit || !placementController.hasCapturedWindow || placementController.isBusy || layoutController.selectedZoneID == nil)
                        if let error = layoutController.persistenceErrorMessage ?? layoutController.errorMessage {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                        if layoutController.canRetrySave {
                            Button("Retry Save") {
                                Task { await layoutController.retryFailedSave() }
                            }
                            .disabled(!layoutController.canEdit)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            GroupBox("Accessibility") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label(
                            placementController.accessibilityGranted ? "Access granted" : "Access required",
                            systemImage: placementController.accessibilityGranted ? "checkmark.shield" : "hand.raised"
                        )
                        Spacer()

                        if placementController.accessibilityGranted {
                            Button("Refresh") {
                                placementController.refreshAccessibility()
                            }
                        } else {
                            Button("Request Access") {
                                placementController.requestAccessibilityAccess()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }

                    Text("AppAlign only requests Accessibility access when window placement is used. The app is intentionally not sandboxed because macOS Accessibility APIs must control windows owned by other applications.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            KeyboardSettingsView()

            GroupBox("Pointer window dragging") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Detect title-bar window drags", isOn: Binding(
                        get: { dragDetectionController.isEnabled },
                        set: { dragDetectionController.setEnabled($0) }
                    ))
                    Toggle("Require Shift", isOn: Binding(
                        get: { dragSnapController.settings.requireShift },
                        set: { value in var updated = dragSnapController.settings; updated.requireShift = value; dragSnapController.updateSettings(updated) }
                    ))
                    Picker("Range selection modifier", selection: Binding(
                        get: { dragSnapController.settings.rangeModifier },
                        set: { value in var updated = dragSnapController.settings; updated.rangeModifier = value; dragSnapController.updateSettings(updated) }
                    )) {
                        Text("Shift").tag(RangeSelectionModifier.shift)
                        Text("Control").tag(RangeSelectionModifier.control)
                        Text("Option").tag(RangeSelectionModifier.option)
                        Text("Command").tag(RangeSelectionModifier.command)
                    }
                    .disabled(!layoutController.canEdit)
                    Picker("Overlap selection", selection: Binding(
                        get: { dragSnapController.settings.overlapStrategy },
                        set: { value in var updated = dragSnapController.settings; updated.overlapStrategy = value; dragSnapController.updateSettings(updated) }
                    )) {
                        Text("Smallest").tag(ZoneOverlapStrategy.smallest)
                        Text("Largest").tag(ZoneOverlapStrategy.largest)
                        Text("Positional").tag(ZoneOverlapStrategy.positional)
                        Text("Closest center").tag(ZoneOverlapStrategy.closestCenter)
                    }
                    .disabled(!layoutController.canEdit)
                    Picker("Toggle with button", selection: Binding<Int?>(
                        get: { dragSnapController.settings.toggleButton },
                        set: { value in var updated = dragSnapController.settings; updated.toggleButton = value; dragSnapController.updateSettings(updated) }
                    )) {
                        Text("Disabled").tag(Optional<Int>.none)
                        Text("Right").tag(Optional(1))
                        Text("Middle").tag(Optional(2))
                        Text("Button 4").tag(Optional(3))
                        Text("Button 5").tag(Optional(4))
                    }
                    .disabled(!layoutController.canEdit)
                    HStack {
                        Text("Selection radius: \(Int(dragSnapController.settings.selectionRadius)) pt")
                        Slider(value: Binding(
                            get: { dragSnapController.settings.selectionRadius },
                            set: { value in var updated = dragSnapController.settings; updated.selectionRadius = value; dragSnapController.updateSettings(updated) }
                        ), in: 0 ... 80, step: 2)
                    }
                    .disabled(!layoutController.canEdit)
                    HStack {
                        Text(dragDetectionController.statusMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !dragDetectionController.isRunning {
                            Button("Retry") { dragDetectionController.retry() }
                        }
                    }
                    Text(dragSnapController.statusMessage).font(.caption).foregroundStyle(.secondary)
                    Text("Input Monitoring observes pointer events. Accessibility identifies the window under the pointer. Both permissions are requested only when this feature is enabled. AppAlign never changes or injects input.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            GroupBox("Focused-window placement") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(
                        "Keep another app active, open the AppAlign menu-bar item, and choose “Capture Focused Window”. " +
                            "AppAlign excludes its own windows, dialogs, minimized/full-screen windows, and windows whose " +
                            "position or size is not writable."
                    )
                        .font(.callout)

                    HStack {
                        Button("Restore") {
                            Task { await placementController.restoreCapturedWindow() }
                        }
                        .disabled(!placementController.canRestore || placementController.isBusy)

                        Button("Forget Capture") {
                            placementController.clearCapture()
                        }
                        .disabled(!placementController.hasCapturedWindow || placementController.isBusy)
                    }

                    Text(placementController.statusMessage)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    if let requestedFrame = placementController.requestedFrame {
                        Text("Requested: \(PlacementController.describe(requestedFrame))")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    if let actualFrame = placementController.actualFrame {
                        Text("Actual: \(PlacementController.describe(actualFrame))")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            newWindowHistorySection

                Spacer(minLength: 12)
            }
            .padding(28)
            .frame(minWidth: 760, alignment: .topLeading)
        }
        .frame(minWidth: 760, minHeight: 600)
        .task {
            if !layoutController.persistenceReady { await layoutController.loadPersistentState() }
        }
        .sheet(isPresented: $isLayoutEditorPresented) {
            if let displayID = layoutController.selectedDisplayID {
                LayoutEditorView(controller: layoutController, initialDisplayID: displayID)
            }
        }
    }
}

private extension ContentView {
    var newWindowHistorySection: some View {
        GroupBox("New-window history") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Monitor newly opened windows", isOn: Binding(
                    get: { layoutController.appHistorySettings.monitorNewWindows },
                    set: { value in
                        var updated = layoutController.appHistorySettings
                        updated.monitorNewWindows = value
                        layoutController.updateAppHistorySettings(updated)
                    }
                ))
                .disabled(!layoutController.canEdit || !layoutController.appZoneHistoryAvailable)
                Toggle("Restore matching windows automatically", isOn: Binding(
                    get: { layoutController.appHistorySettings.restoreNewWindows },
                    set: { value in
                        var updated = layoutController.appHistorySettings
                        updated.restoreNewWindows = value
                        layoutController.updateAppHistorySettings(updated)
                    }
                ))
                .disabled(!layoutController.canEdit || !layoutController.appZoneHistoryAvailable ||
                          !layoutController.appHistorySettings.monitorNewWindows)
                Text(layoutController.appZoneHistoryErrorMessage ??
                     "History is learned after a successful placement. New-window monitoring and automatic restoration start off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if placementController.historyPermissionRetryRequired {
                    Button("Retry window monitoring") {
                        placementController.retryAppHistoryPermission()
                    }
                    .disabled(!layoutController.canEdit)
                }
                if layoutController.appZoneHistoryErrorMessage != nil || layoutController.appHistorySettingsRetrySnapshot != nil {
                    Button("Retry History Save") {
                        Task {
                            _ = await layoutController.retryAppZoneHistorySaves()
                            _ = await layoutController.retryAppHistorySettingsSave()
                        }
                    }
                    .disabled(!layoutController.canEdit)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}
