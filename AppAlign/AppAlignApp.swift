import AppKit
import Combine
import CoreGraphics
import SwiftUI

@main
struct AppAlignApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate
    @StateObject private var placementController: PlacementController
    @StateObject private var layoutController: LayoutController
    @StateObject private var keyboardSnapController: KeyboardSnapController
    @StateObject private var globalHotkeys: GlobalHotkeys
    @StateObject private var layoutHotkeys: LayoutHotkeys
    @StateObject private var dragDetectionController: DragDetectionController
    @StateObject private var dragSnapController: DragSnapController

    @MainActor
    init() {
        let displayProvider = DisplayProvider()
        let validity = PlacementValidity()
        let spaceProvider = SpaceProvider.production()
        let layout = LayoutController(displayProvider: displayProvider, spaceProvider: spaceProvider,
                                      placementValidity: validity)
        let runtime = AccessibilityWindowRuntime()
        let autoTicketRegistry = AutoRestoreTicketRegistry()
        let autoRestore = AutoRestoreController(layout: layout, runtime: runtime,
                                                ticketRegistry: autoTicketRegistry)
        let newWindowMonitor = NewWindowMonitor(layout: layout, runtime: runtime,
                                                ticketRegistry: autoTicketRegistry)
        newWindowMonitor.onNewWindow = { candidate, bundleID in
            autoRestore.restoreNewWindow(candidate, bundleID: bundleID)
        }
        newWindowMonitor.onStart = { autoRestore.resume() }
        newWindowMonitor.onStop = { autoRestore.stop() }
        newWindowMonitor.onEnvironmentChanged = { autoRestore.cancelAll() }
        newWindowMonitor.onProcessTerminating = { pid, generation in
            autoRestore.cancel(processID: pid, generation: generation)
        }
        newWindowMonitor.onWindowClosed = { token in autoRestore.cancel(token: token) }
        layout.cancelAutomaticRestores = { autoRestore.cancelAll() }
        layout.appHistoryCoordinator.releaseRuntimeLease = { token, lease in
            Task { await runtime.releaseHistoryLease(token, lease: lease) }
        }
        let placement = PlacementController(displayProvider: displayProvider, validity: validity,
                                            refreshDisplayConfiguration: { layout.refreshDisplays() },
                                            manualRuntime: runtime)
        placement.cancelAutomaticRestores = { autoRestore.cancelAll() }
        layout.invalidateManualCapture = { [weak placement] in placement?.clearCapture() }
        placement.onSuccessfulPlacement = { _, context in
            layout.acceptSuccessfulAppPlacement(context.historyLease, zoneIDs: context.zoneIDs)
        }
        placement.onSuccessfulRestore = { token in layout.appRestoreSucceeded(token) }
        let keyboard = KeyboardSnapController(layoutController: layout, backend: runtime)
        let inbox = OrderedInteractionInbox()
        let input = InputMonitor(inbox: inbox)
        let drag = DragDetectionController(reader: runtime, monitor: input, displayProvider: displayProvider)
        let hotkeys = GlobalHotkeys(layoutController: layout, snapController: keyboard)
        let dragSnap = DragSnapController(layoutController: layout, runtime: runtime)
        let layoutHotkeys = LayoutHotkeys(layoutController: layout, inbox: inbox) { layoutID, point, flags in
            guard layout.applyQuickLayout(layoutID, at: point) != nil else { return }
            keyboard.resetNavigationHistory()
            dragSnap.reselectAfterQuickSwitch(point: point, flags: flags)
        }
        let gate = DragKeyboardGate(keyboard: keyboard, hotkeys: hotkeys, layoutHotkeys: layoutHotkeys)
        let displayConfiguration = DisplayConfigurationController(layout: layout, drag: dragSnap,
                                                                  detection: drag, keyboard: keyboard, gate: gate)
        drag.dragGateChanged = { gate.setDrag($0) }
        dragSnap.gateChanged = { gate.setCommit($0) }
        drag.onWillEnd = { dragSnap.prepareCommit($0) }
        drag.onAcceptedInput = { dragSnap.acceptedInput($0) }
        drag.onCommitCancelled = { dragSnap.cancel(reason: $0) }
        drag.onLifecycle = { dragSnap.lifecycle($0) }
        layout.invalidateDragCommit = {
            dragSnap.cancel(reason: "The applied layout changed.")
            drag.environmentChanged(reason: "The applied layout changed.")
        }
        drag.invalidateKeyboard = { [weak keyboard] in keyboard?.invalidatePendingOperations() }
        _layoutController = StateObject(wrappedValue: layout)
        _placementController = StateObject(wrappedValue: placement)
        _keyboardSnapController = StateObject(wrappedValue: keyboard)
        _globalHotkeys = StateObject(wrappedValue: hotkeys)
        _layoutHotkeys = StateObject(wrappedValue: layoutHotkeys)
        _dragDetectionController = StateObject(wrappedValue: drag)
        _dragSnapController = StateObject(wrappedValue: dragSnap)
        let delegate = appDelegate
        let lifecycleContext = HistoryLifecycleContext(
            layout: layout, placement: placement, autoRestore: autoRestore, monitor: newWindowMonitor,
            runtime: runtime, displayConfiguration: displayConfiguration, delegate: delegate,
            keyboard: keyboard, hotkeys: hotkeys, layoutHotkeys: layoutHotkeys,
            drag: drag, dragSnap: dragSnap
        )
        wireAppLifecycle(lifecycleContext)
        delegate.keyboardFlagsMonitor = input
        configureKeyboardFlagsObservation(layout: layout, input: input, keyboard: keyboard, delegate: delegate)
        startAfterPersistentLoad(lifecycleContext)
    }

    var body: some Scene {
        MenuBarExtra("AppAlign", systemImage: "rectangle.split.3x1") {
            MenuBarView()
                .environmentObject(placementController)
                .environmentObject(layoutController)
                .environmentObject(keyboardSnapController)
                .environmentObject(globalHotkeys)
                .environmentObject(layoutHotkeys)
                .environmentObject(dragDetectionController)
                .environmentObject(dragSnapController)
                .task {
                    appDelegate.layoutController = layoutController
                    appDelegate.globalHotkeys = globalHotkeys
                    appDelegate.layoutHotkeys = layoutHotkeys
                    appDelegate.keyboardSnapController = keyboardSnapController
                    appDelegate.dragDetectionController = dragDetectionController
                    appDelegate.dragSnapController = dragSnapController
                    if !layoutController.persistenceReady { await layoutController.loadPersistentState() }
                    if !appDelegate.isTerminating { globalHotkeys.settingsDidChange(); layoutHotkeys.settingsDidChange() }
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
                .environmentObject(layoutHotkeys)
                .environmentObject(dragDetectionController)
                .environmentObject(dragSnapController)
                .task {
                    appDelegate.layoutController = layoutController
                    appDelegate.globalHotkeys = globalHotkeys
                    appDelegate.layoutHotkeys = layoutHotkeys
                    appDelegate.keyboardSnapController = keyboardSnapController
                    appDelegate.dragDetectionController = dragDetectionController
                    appDelegate.dragSnapController = dragSnapController
                    if !layoutController.persistenceReady { await layoutController.loadPersistentState() }
                    if !appDelegate.isTerminating { globalHotkeys.settingsDidChange(); layoutHotkeys.settingsDidChange() }
                }
        }
    }
}

@MainActor
private struct HistoryLifecycleContext {
    let layout: LayoutController
    let placement: PlacementController
    let autoRestore: AutoRestoreController
    let monitor: NewWindowMonitor
    let runtime: AccessibilityWindowRuntime
    let displayConfiguration: DisplayConfigurationController
    let delegate: AppLifecycleDelegate
    let keyboard: KeyboardSnapController
    let hotkeys: GlobalHotkeys
    let layoutHotkeys: LayoutHotkeys
    let drag: DragDetectionController
    let dragSnap: DragSnapController
}

@MainActor
private func wireAppLifecycle(_ context: HistoryLifecycleContext) {
    let delegate = context.delegate
    delegate.layoutController = context.layout
    delegate.globalHotkeys = context.hotkeys
    delegate.layoutHotkeys = context.layoutHotkeys
    delegate.keyboardSnapController = context.keyboard
    delegate.dragDetectionController = context.drag
    delegate.dragSnapController = context.dragSnap
    delegate.displayConfigurationController = context.displayConfiguration
    delegate.placementController = context.placement
    delegate.newWindowMonitor = context.monitor
    delegate.autoRestoreController = context.autoRestore
    configureHistoryLifecycle(context)
}

@MainActor
private func startAfterPersistentLoad(_ context: HistoryLifecycleContext) {
    Task { @MainActor in
        await context.runtime.setHistoryWindowDestroyedHandler { token, _ in
            Task { @MainActor [weak layout = context.layout] in layout?.appWindowDestroyed(token) }
        }
        await context.layout.loadPersistentState()
        guard !context.delegate.isTerminating else { return }
        context.displayConfiguration.start()
        context.delegate.applyHistoryLifecycle?()
        context.hotkeys.start()
        context.layoutHotkeys.start()
    }
}

@MainActor
private func configureHistoryLifecycle(_ context: HistoryLifecycleContext) {
    let layout = context.layout
    let placement = context.placement
    let autoRestore = context.autoRestore
    let monitor = context.monitor
    let runtime = context.runtime
    let displayConfiguration = context.displayConfiguration
    let delegate = context.delegate
    let permissionMonitor = AccessibilityHistoryPermissionMonitor(
        permissionIsGranted: {
            placement.refreshAccessibility()
            return placement.accessibilityGranted
        },
        permissionWasRevoked: {
            placement.historyPermissionRetryRequired = true
            autoRestore.stop()
            monitor.stop()
            delegate.setHistoryPermissionPolling?(false)
            delegate.stopHistoryObservation?()
        }
    )
    displayConfiguration.historyPermissionPollingSuspendedChanged = { [weak delegate] suspended in
        guard let delegate else { return }
        delegate.historyPermissionPollingSuspended = suspended
        delegate.applyHistoryLifecycle?()
    }
    placement.retryHistoryPermission = {
        permissionMonitor.retrySucceeded()
        delegate.applyHistoryLifecycle?()
    }
    delegate.applyHistoryLifecycle = {
        delegate.historyLifecycleRevision &+= 1
        let revision = delegate.historyLifecycleRevision
        let allowed = placement.accessibilityGranted && !placement.historyPermissionRetryRequired &&
            !delegate.historyPermissionPollingSuspended
        permissionMonitor.update(enabled: layout.appHistorySettings.monitorNewWindows &&
            layout.appZoneHistoryAvailable && allowed && !delegate.isTerminating)
        monitor.update(settings: layout.appHistorySettings, accessibilityAllowed: allowed)
        Task { @MainActor in
            guard delegate.historyLifecycleRevision == revision, !delegate.isTerminating else { return }
            await runtime.applyHistoryDestroyState(enabled: allowed, revision: revision)
            guard delegate.historyLifecycleRevision == revision, !delegate.isTerminating else { return }
            let currentAllowed = placement.accessibilityGranted && !placement.historyPermissionRetryRequired &&
                !delegate.historyPermissionPollingSuspended
            monitor.update(settings: layout.appHistorySettings, accessibilityAllowed: currentAllowed)
        }
    }
    delegate.stopHistoryObservation = {
        delegate.historyLifecycleRevision &+= 1
        let revision = delegate.historyLifecycleRevision
        Task { @MainActor in
            guard delegate.historyLifecycleRevision == revision else { return }
            await runtime.applyHistoryDestroyState(enabled: false, revision: revision)
        }
    }
    delegate.resumeHistoryObservation = {
        delegate.applyHistoryLifecycle?()
    }
    delegate.appHistoryObservation = Publishers.CombineLatest(layout.$appHistorySettings, placement.$accessibilityGranted)
        .removeDuplicates { previous, current in previous.0 == current.0 && previous.1 == current.1 }
        .sink { _, _ in
            Task { @MainActor [weak delegate, weak monitor] in
                guard let delegate, !delegate.isTerminating, monitor != nil else { return }
                delegate.applyHistoryLifecycle?()
            }
        }
    delegate.setHistoryPermissionPolling = { enabled in
        permissionMonitor.update(enabled: enabled && layout.appHistorySettings.monitorNewWindows &&
            layout.appZoneHistoryAvailable && placement.accessibilityGranted &&
            !placement.historyPermissionRetryRequired && !delegate.isTerminating &&
            !delegate.historyPermissionPollingSuspended)
    }
}

@MainActor
private func configureKeyboardFlagsObservation(layout: LayoutController, input: InputMonitor,
                                               keyboard: KeyboardSnapController,
                                               delegate: AppLifecycleDelegate) {
    delegate.flagsObservation = layout.$keyboardSettings
        .map(\.isEnabled)
        .removeDuplicates()
        .sink { _ in
            Task { @MainActor [weak delegate] in
                guard let delegate, !delegate.isTerminating else { return }
                delegate.refreshKeyboardFlagsObservation?()
            }
        }
    delegate.refreshKeyboardFlagsObservation = {
        guard !delegate.isTerminating else { keyboard.setExtensionFlagsAvailable(false); return }
        guard layout.keyboardSettings.isEnabled else {
            input.setFlagsObserver(nil)
            keyboard.setExtensionFlagsAvailable(false)
            return
        }
        input.setFlagsObserver({ flags in
            keyboard.extensionModifierFlagsChanged(flags)
        }, onStatus: { keyboard.flagsMonitorStatus($0) })
    }
}

@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    private(set) var isTerminating = false
    weak var layoutController: LayoutController?
    weak var placementController: PlacementController?
    weak var globalHotkeys: GlobalHotkeys?
    weak var layoutHotkeys: LayoutHotkeys?
    weak var keyboardFlagsMonitor: InputMonitor?
    var flagsObservation: AnyCancellable?
    var refreshKeyboardFlagsObservation: (@MainActor () -> Void)?
    weak var keyboardSnapController: KeyboardSnapController?
    weak var dragDetectionController: DragDetectionController?
    weak var dragSnapController: DragSnapController?
    var displayConfigurationController: DisplayConfigurationController?
    var newWindowMonitor: NewWindowMonitor?
    var autoRestoreController: AutoRestoreController?
    var historyLifecycleRevision: UInt64 = 0
    var historyPermissionPollingSuspended = false
    var applyHistoryLifecycle: (@MainActor () -> Void)?
    var setHistoryPermissionPolling: (@MainActor (Bool) -> Void)?
    var stopHistoryObservation: (@MainActor () -> Void)?
    var resumeHistoryObservation: (@MainActor () -> Void)?
    var appHistoryObservation: AnyCancellable?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminating = true
        historyPermissionPollingSuspended = true
        setHistoryPermissionPolling?(false)
        newWindowMonitor?.stop()
        stopHistoryObservation?()
        flagsObservation?.cancel()
        flagsObservation = nil
        displayConfigurationController?.shutdown()
        globalHotkeys?.shutdown()
        layoutHotkeys?.shutdown()
        keyboardFlagsMonitor?.setFlagsObserver(nil)
        keyboardSnapController?.setExtensionFlagsAvailable(false)
        dragDetectionController?.shutdownForQuit()
        keyboardSnapController?.suspend()
        Task { @MainActor [weak self] in
            await self?.dragDetectionController?.prepareForShutdown()
            await self?.dragSnapController?.drainForShutdown()
            await self?.autoRestoreController?.drainForShutdown()
            await self?.newWindowMonitor?.drainForShutdown()
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
                historyPermissionPollingSuspended = false
                displayConfigurationController?.cancelQuit()
                applyHistoryLifecycle?()
                keyboardSnapController?.resume()
                globalHotkeys?.start()
                layoutHotkeys?.start()
                dragDetectionController?.resumeAfterCancelledQuit()
                refreshKeyboardFlagsObservation?()
                flagsObservation = layoutController.$keyboardSettings
                    .map(\.isEnabled)
                    .removeDuplicates()
                    .sink { [weak self] _ in
                        Task { @MainActor [weak self] in
                            guard let self, !self.isTerminating else { return }
                            self.refreshKeyboardFlagsObservation?()
                        }
                    }
            } else {
                await keyboardSnapController?.shutdown()
            }
            sender.reply(toApplicationShouldTerminate: retrySucceeded)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        newWindowMonitor?.stop()
        displayConfigurationController?.dispose()
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
                Task { await layoutController.placeSelectedZone(using: placementController) }
            }
            .disabled(!layoutController.canEdit || !placementController.hasCapturedWindow || layoutController.selectedZoneID == nil)

            Button("Restore Captured Window") {
                Task { await placementController.restoreCapturedWindow() }
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
