import AppKit
import SwiftUI

@main
struct AppAlignApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate
    @StateObject private var placementController = PlacementController()
    @StateObject private var layoutController = LayoutController()

    var body: some Scene {
        MenuBarExtra("AppAlign", systemImage: "rectangle.split.3x1") {
            MenuBarView()
                .environmentObject(placementController)
                .environmentObject(layoutController)
                .task {
                    appDelegate.layoutController = layoutController
                    if !layoutController.persistenceReady { await layoutController.loadPersistentState() }
                }
                .onAppear {
                    placementController.menuDidOpen()
                }
        }

        Settings {
            ContentView()
                .environmentObject(placementController)
                .environmentObject(layoutController)
                .task {
                    appDelegate.layoutController = layoutController
                    if !layoutController.persistenceReady { await layoutController.loadPersistentState() }
                }
        }
    }
}

@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    weak var layoutController: LayoutController?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor [weak self] in
            guard let self, let layoutController = self.layoutController else {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }
            let ready = await layoutController.prepareForTermination()
            guard !ready else {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }
            let alert = NSAlert()
            alert.messageText = "AppAlign could not save your changes."
            alert.informativeText = layoutController.persistenceErrorMessage ?? "The save did not complete. Retry before quitting."
            alert.addButton(withTitle: "Retry Save")
            alert.addButton(withTitle: "Cancel Quit")
            let response = alert.runModal()
            let retrySucceeded: Bool
            if response == .alertFirstButtonReturn {
                retrySucceeded = await layoutController.retryFailedSave()
            } else {
                retrySucceeded = false
            }
            sender.reply(toApplicationShouldTerminate: retrySucceeded)
        }
        return .terminateLater
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
            .disabled(!layoutController.canEdit || !placementController.hasCapturedWindow || layoutController.selectedZoneID == nil)

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
