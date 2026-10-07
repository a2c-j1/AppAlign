import AppKit
import SwiftUI

@main
struct AppAlignApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate
    @StateObject private var placementController: PlacementController
    @StateObject private var layoutController: LayoutController
    @StateObject private var keyboardSnapController: KeyboardSnapController
    @StateObject private var globalHotkeys: GlobalHotkeys
    @StateObject private var dragDetectionController: DragDetectionController

    @MainActor
    init() {
        let layout = LayoutController()
        let placement = PlacementController()
        let runtime = AccessibilityWindowRuntime()
        let keyboard = KeyboardSnapController(layoutController: layout, backend: runtime)
        let drag = DragDetectionController(reader: runtime)
        let hotkeys = GlobalHotkeys(layoutController: layout, snapController: keyboard)
        drag.dragGateChanged = { [weak keyboard, weak hotkeys] closed in
            keyboard?.setDragGateClosed(closed)
            hotkeys?.setDragGateClosed(closed)
        }
        drag.invalidateKeyboard = { [weak keyboard] in keyboard?.invalidatePendingOperations() }
        _layoutController = StateObject(wrappedValue: layout)
        _placementController = StateObject(wrappedValue: placement)
        _keyboardSnapController = StateObject(wrappedValue: keyboard)
        _globalHotkeys = StateObject(wrappedValue: hotkeys)
        _dragDetectionController = StateObject(wrappedValue: drag)
        let delegate = appDelegate
        delegate.layoutController = layout
        delegate.globalHotkeys = hotkeys
        delegate.keyboardSnapController = keyboard
        delegate.dragDetectionController = drag
        Task { @MainActor in
            await layout.loadPersistentState()
            guard !delegate.isTerminating else { return }
            hotkeys.start()
        }
    }

    var body: some Scene {
        MenuBarExtra("AppAlign", systemImage: "rectangle.split.3x1") {
            MenuBarView()
                .environmentObject(placementController)
                .environmentObject(layoutController)
                .environmentObject(keyboardSnapController)
                .environmentObject(globalHotkeys)
                .environmentObject(dragDetectionController)
                .task {
                    appDelegate.layoutController = layoutController
                    appDelegate.globalHotkeys = globalHotkeys
                    appDelegate.keyboardSnapController = keyboardSnapController
                    appDelegate.dragDetectionController = dragDetectionController
                    if !layoutController.persistenceReady { await layoutController.loadPersistentState() }
                    if !appDelegate.isTerminating { globalHotkeys.settingsDidChange() }
                }
                .onAppear {
                    placementController.menuDidOpen()
                }
        }

        Settings {
            ContentView()
                .environmentObject(placementController)
                .environmentObject(layoutController)
                .environmentObject(keyboardSnapController)
                .environmentObject(globalHotkeys)
                .environmentObject(dragDetectionController)
                .task {
                    appDelegate.layoutController = layoutController
                    appDelegate.globalHotkeys = globalHotkeys
                    appDelegate.keyboardSnapController = keyboardSnapController
                    appDelegate.dragDetectionController = dragDetectionController
                    if !layoutController.persistenceReady { await layoutController.loadPersistentState() }
                    if !appDelegate.isTerminating { globalHotkeys.settingsDidChange() }
                }
        }
    }
}

@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    private(set) var isTerminating = false
    weak var layoutController: LayoutController?
    weak var globalHotkeys: GlobalHotkeys?
    weak var keyboardSnapController: KeyboardSnapController?
    weak var dragDetectionController: DragDetectionController?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminating = true
        globalHotkeys?.shutdown()
        dragDetectionController?.shutdownForQuit()
        keyboardSnapController?.suspend()
        Task { @MainActor [weak self] in
            await self?.dragDetectionController?.prepareForShutdown()
            guard let self, let layoutController = self.layoutController else {
                await self?.keyboardSnapController?.shutdown()
                sender.reply(toApplicationShouldTerminate: true)
                return
            }
            let ready = await layoutController.prepareForTermination()
            guard !ready else {
                await keyboardSnapController?.shutdown()
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
                retrySucceeded = await layoutController.flush()
            } else {
                retrySucceeded = false
            }
            if !retrySucceeded {
                isTerminating = false
                keyboardSnapController?.resume()
                globalHotkeys?.start()
                dragDetectionController?.resumeAfterCancelledQuit()
            } else {
                await keyboardSnapController?.shutdown()
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
