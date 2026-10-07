import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var placementController: PlacementController
    @EnvironmentObject private var layoutController: LayoutController
    @EnvironmentObject private var dragDetectionController: DragDetectionController
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
                            layoutController.placeSelectedZone(using: placementController)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!layoutController.canEdit || !placementController.hasCapturedWindow || layoutController.selectedZoneID == nil)
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
                    HStack {
                        Text(dragDetectionController.statusMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !dragDetectionController.isRunning {
                            Button("Retry") { dragDetectionController.retry() }
                        }
                    }
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
                            placementController.restoreCapturedWindow()
                        }
                        .disabled(!placementController.canRestore)

                        Button("Forget Capture") {
                            placementController.clearCapture()
                        }
                        .disabled(!placementController.hasCapturedWindow)
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
