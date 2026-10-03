import AppKit
import SwiftUI

@main
struct AppAlignApp: App {
    @StateObject private var placementController = PlacementController()

    var body: some Scene {
        MenuBarExtra("AppAlign", systemImage: "rectangle.split.3x1") {
            MenuBarView()
                .environmentObject(placementController)
                .onAppear {
                    placementController.menuDidOpen()
                }
        }

        Settings {
            ContentView()
                .environmentObject(placementController)
        }
    }
}

private struct MenuBarView: View {
    @EnvironmentObject private var placementController: PlacementController

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

            Button("Move Captured Window +32 pt") {
                placementController.moveCapturedWindow()
            }
            .disabled(!placementController.hasCapturedWindow)

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
