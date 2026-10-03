import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var placementController: PlacementController

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("AppAlign")
                    .font(.largeTitle.weight(.semibold))
                Text("Accessibility and window-placement proof of concept")
                    .foregroundStyle(.secondary)
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

            GroupBox("Focused-window placement") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(
                        "Keep another app active, open the AppAlign menu-bar item, and choose “Capture Focused Window”. " +
                            "AppAlign excludes its own windows, dialogs, minimized/full-screen windows, and windows whose " +
                            "position or size is not writable."
                    )
                        .font(.callout)

                    HStack {
                        Button("Move +32 pt") {
                            placementController.moveCapturedWindow()
                        }
                        .disabled(!placementController.hasCapturedWindow)

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

            Spacer()
        }
        .padding(28)
        .frame(minWidth: 620, minHeight: 430)
    }
}
