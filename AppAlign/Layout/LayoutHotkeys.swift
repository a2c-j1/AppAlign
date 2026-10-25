import AppKit
import Carbon.HIToolbox
import Combine
import CoreGraphics
import Foundation

struct LayoutHotkeySampling: Sendable {
    var point: @Sendable () -> CGPoint?
    var flags: @Sendable () -> UInt64

    static let live = LayoutHotkeySampling(point: { CGEvent(source: nil)?.location },
                                          flags: { CGEventSource.flagsState(.combinedSessionState).rawValue })
}

/// Layout commands never use the window-placement eligibility probe or drag
/// gate. They do share configuration admission and the input acceptance inbox.
@MainActor
final class LayoutHotkeys: ObservableObject {
    @Published private(set) var statusMessage = "Layout shortcuts are disabled."
    private struct Registration: Sendable {
        let id: UInt32
        let layoutID: UUID
        let shortcut: KeyboardShortcut
        let generation: UInt64
    }

    private let layout: LayoutController
    private let inbox: OrderedInteractionInbox
    private let registrar: any HotKeyRegistering
    private let sampling: LayoutHotkeySampling
    private let action: @MainActor @Sendable (UUID, CGPoint, UInt64) -> Void
    private var registrations: [UInt32: Registration] = [:]
    private var started = false
    private var configurationPending = false
    private var generation: UInt64 = 0
    private var timer: Timer?
    private var observedSettings: LayoutHotkeySettings?
    private var observedKeyboard: KeyboardSettings?
    private var observedCatalog: Set<UUID> = []
    private var observedAdmission = false

    init(layoutController: LayoutController, inbox: OrderedInteractionInbox,
         registrar: any HotKeyRegistering = CarbonHotKeyRegistrar(),
         sampling: LayoutHotkeySampling = .live,
         action: @escaping @MainActor @Sendable (UUID, CGPoint, UInt64) -> Void) {
        layout = layoutController
        self.inbox = inbox
        self.registrar = registrar
        self.sampling = sampling
        self.action = action
    }

    func start() {
        guard !started else { return }
        started = true
        reconcile()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func settingsDidChange() {
        guard started else { return }
        reconcile()
    }

    func setConfigurationPending(_ pending: Bool) {
        guard configurationPending != pending else { return }
        configurationPending = pending
        if started { reconcile() }
    }

    func shutdown() {
        started = false
        generation &+= 1
        timer?.invalidate()
        timer = nil
        unregisterAll()
        registrar.shutdown()
    }

    private func poll() {
        guard started else { return }
        if observedSettings != layout.layoutHotkeySettings || observedKeyboard != layout.keyboardSettings
            || observedCatalog != Set(layout.savedLayouts.keys) || observedAdmission != layout.placementValidity.isAccepting {
            reconcile()
        }
    }

    private func reconcile() {
        generation &+= 1
        unregisterAll()
        observedSettings = layout.layoutHotkeySettings
        observedKeyboard = layout.keyboardSettings
        observedCatalog = Set(layout.savedLayouts.keys)
        observedAdmission = layout.placementValidity.isAccepting
        guard registrations.isEmpty else {
            statusMessage = "A layout shortcut could not be released; registration is paused to prevent duplicates."
            return
        }
        guard started, layout.layoutHotkeySettings.isEnabled else {
            statusMessage = "Layout shortcuts are disabled."
            return
        }
        guard !configurationPending, layout.placementValidity.isAccepting, layout.persistenceReady, layout.acceptsChanges else {
            statusMessage = "Layout shortcuts pause while the display or saved state is changing."
            return
        }
        let settings = layout.layoutHotkeySettings
        let placementShortcuts = layout.keyboardSettings.isEnabled ? Set(layout.keyboardSettings.shortcuts.values) : []
        let shortcutCounts = Dictionary(grouping: settings.bindings.values, by: { $0 }).mapValues(\.count)
        var seen = Set<KeyboardShortcut>()
        var failures: [String] = []
        for (layoutID, shortcut) in settings.bindings.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard shortcut.isValid, let stored = layout.savedLayouts[layoutID], (try? stored.definition()) != nil else {
                failures.append("A layout shortcut has an invalid key or missing layout.")
                continue
            }
            guard shortcutCounts[shortcut] == 1, !placementShortcuts.contains(shortcut), seen.insert(shortcut).inserted else {
                failures.append("A layout shortcut duplicates another configured shortcut.")
                continue
            }
            guard !registrar.conflictsWithSystemShortcut(shortcut) else {
                failures.append("macOS already uses a configured layout shortcut.")
                continue
            }
            let id = HotKeyIDAllocator.allocate()
            let registration = Registration(id: id, layoutID: layoutID, shortcut: shortcut, generation: generation)
            let inbox = self.inbox
            let sampling = self.sampling
            let status = registrar.register(shortcut, id: id) { [weak self] in
                defer { HotKeyDispatchTable.completed(id) }
                guard let point = sampling.point(), point.x.isFinite, point.y.isFinite else { return }
                let flags = sampling.flags()
                let accepted = inbox.enqueueControl { [weak self] in
                    guard let self, self.canDispatch(registration) else { return }
                    self.action(layoutID, point, flags)
                }
                if !accepted {
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self, self.started, self.generation == registration.generation else { return }
                            self.statusMessage = "The layout command queue is full; this switch was not accepted."
                        }
                    }
                }
            }
            if status == noErr { registrations[id] = registration } else {
                failures.append("A layout shortcut could not register (Carbon status \(status)).")
            }
        }
        statusMessage = failures.isEmpty ? "Registered \(registrations.count) layout shortcuts." : failures.joined(separator: " ")
    }

    private func canDispatch(_ registration: Registration) -> Bool {
        started && !configurationPending && generation == registration.generation
            && registrations[registration.id]?.layoutID == registration.layoutID
            && layout.placementValidity.isAccepting && layout.persistenceReady && layout.acceptsChanges
            && layout.layoutHotkeySettings.isEnabled
            && layout.layoutHotkeySettings.bindings[registration.layoutID] == registration.shortcut
            && layout.savedLayouts[registration.layoutID] != nil
            && !(layout.keyboardSettings.isEnabled && layout.keyboardSettings.shortcuts.values.contains(registration.shortcut))
    }

    private func unregisterAll() {
        var retained: [UInt32: Registration] = [:]
        for (id, registration) in registrations where registrar.unregister(id: id) != noErr { retained[id] = registration }
        registrations = retained
    }
}
