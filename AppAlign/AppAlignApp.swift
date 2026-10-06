import AppKit
import SwiftUI

@main
struct AppAlignApp: App {
    @StateObject private var placementController = PlacementController()
    @StateObject private var layoutController = LayoutController()

    var body: some Scene {
        MenuBarExtra("AppAlign", systemImage: "rectangle.split.3x1") {
            MenuBarView()
                .environmentObject(placementController)
                .environmentObject(layoutController)
                .onAppear {
                    placementController.menuDidOpen()
                }
        }

        Settings {
            ContentView()
                .environmentObject(placementController)
                .environmentObject(layoutController)
        }
    }
}

private struct MenuBarView: View {
    @EnvironmentObject private var placementController: PlacementController
    @EnvironmentObject private var layoutController: LayoutController

    var body: some View {
        Group {
            if placementController.accessibilityGranted {
                Label("Accessibility: Granted", systemImage: "checkmark.shield")
            } else {
                Button("Grant Accessibility Access") {
                    placementController.requestAccessibilityAccess()
                }
            }

            Divider()

            Button("Capture Focused Window") {
                placementController.captureFocusedWindow()
            }
            .disabled(!placementController.accessibilityGranted)

            Button("Place Captured Window in Selected Zone") {
                layoutController.placeSelectedZone(using: placementController)
            }
            .disabled(!placementController.hasCapturedWindow || layoutController.selectedZoneID == nil)

            Button("Restore Captured Window") {
                placementController.restoreCapturedWindow()
            }
            .disabled(!placementController.canRestore)

            Divider()

            SettingsLink {
                Text("Settings…")
            }

            Button("Quit AppAlign") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
