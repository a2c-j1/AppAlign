import AppKit
import Carbon.HIToolbox
import Combine
import Foundation

@MainActor
protocol HotKeyRegistering: AnyObject {
    func conflictsWithSystemShortcut(_ shortcut: KeyboardShortcut) -> Bool
    func register(_ shortcut: KeyboardShortcut, id: UInt32, handler: @escaping @Sendable () -> Void) -> OSStatus
    func unregister(id: UInt32) -> OSStatus
    func shutdown()
}

private enum HotKeyDispatchTable {
    static let lock = NSLock()
    nonisolated(unsafe) static var handlers: [UInt32: @Sendable () -> Void] = [:]
    nonisolated(unsafe) static var queuedIDs = Set<UInt32>()

    static func set(_ handler: (@Sendable () -> Void)?, for id: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        handlers[id] = handler
    }

    static func dispatch(_ id: UInt32) {
        lock.lock()
        guard queuedIDs.insert(id).inserted else { lock.unlock(); return }
        let handler = handlers[id]
        lock.unlock()
        if let handler { handler() } else { completed(id) }
    }

    static func completed(_ id: UInt32) {
        lock.lock()
        queuedIDs.remove(id)
        lock.unlock()
    }
}

private let appAlignHotKeyHandler: EventHandlerUPP = { _, event, _ in
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    guard hotKeyID.signature == fourCharCode("APAL") else { return OSStatus(eventNotHandledErr) }
    HotKeyDispatchTable.dispatch(hotKeyID.id)
    return noErr
}

@MainActor
final class CarbonHotKeyRegistrar: HotKeyRegistering {
    private var eventHandler: EventHandlerRef?
    private var handles: [UInt32: EventHotKeyRef] = [:]

    func conflictsWithSystemShortcut(_ shortcut: KeyboardShortcut) -> Bool {
        var copied: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&copied) == noErr, let copied else { return false }
        let hotKeys = copied.takeRetainedValue() as NSArray
        return hotKeys.contains { value in
            guard let dictionary = value as? NSDictionary,
                  (dictionary[kHISymbolicHotKeyEnabled as String] as? NSNumber)?.boolValue == true,
                  let code = dictionary[kHISymbolicHotKeyCode as String] as? NSNumber,
                  let modifiers = dictionary[kHISymbolicHotKeyModifiers as String] as? NSNumber else { return false }
            return code.uint16Value == shortcut.keyCode && modifiers.uint32Value == shortcut.carbonModifiers
        }
    }

    func register(_ shortcut: KeyboardShortcut, id: UInt32, handler: @escaping @Sendable () -> Void) -> OSStatus {
        guard shortcut.isValid, installEventHandler() == noErr else { return eventHandler == nil ? OSStatus(paramErr) : eventHandlerStatus }
        let hotKeyID = EventHotKeyID(signature: fourCharCode("APAL"), id: id)
        var reference: EventHotKeyRef?
        HotKeyDispatchTable.set(handler, for: id)
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers, hotKeyID, GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else {
            HotKeyDispatchTable.set(nil, for: id)
            return status == noErr ? OSStatus(eventNotHandledErr) : status
        }
        handles[id] = reference
        return noErr
    }

    func unregister(id: UInt32) -> OSStatus {
        HotKeyDispatchTable.set(nil, for: id)
        guard let reference = handles[id] else { return noErr }
        let status = UnregisterEventHotKey(reference)
        if status == noErr { handles.removeValue(forKey: id) }
        return status
    }

    func shutdown() {
        for id in Array(handles.keys) { _ = unregister(id: id) }
        if handles.isEmpty, let eventHandler {
            _ = RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    private var eventHandlerStatus: OSStatus { OSStatus(eventNotHandledErr) }

    private func installEventHandler() -> OSStatus {
        guard eventHandler == nil else { return noErr }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        return InstallEventHandler(GetApplicationEventTarget(), appAlignHotKeyHandler, 1, &eventType, nil, &eventHandler)
    }
}

private func fourCharCode(_ string: String) -> OSType {
    string.utf8.reduce(0) { ($0 << 8) | OSType($1) }
}

@MainActor
final class GlobalHotkeys: ObservableObject {
    @Published private(set) var statusMessage = "Keyboard shortcuts are inactive."

    private struct Registration {
        let id: UInt32
        let action: KeyboardSnapAction
        let shortcut: KeyboardShortcut
        let lifecycleGeneration: UInt64
    }

    private let settingsController: LayoutController
    private let snapController: KeyboardSnapController
    private let registrar: any HotKeyRegistering
    private let environment: KeyboardEnvironment
    private var ownPID: pid_t { environment.ownPID }
    private var registrations: [UInt32: Registration] = [:]
    private var generation: UInt32 = 0
    private var lifecycleGeneration: UInt64 = 0
    private var runGeneration: UInt64 = 0
    private var started = false
    private var acceptsDispatch = false
    private var isReconciling = false
    private var reconcileAgain = false
    private var notificationObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var applicationTerminationObserver: NSObjectProtocol?
    private var permissionTimer: Timer?
    private var lastObservedPID: pid_t?
    private var lastObservedTrust: Bool?
    private var lastObservedEnabled: Bool?

    init(
        layoutController: LayoutController,
        snapController: KeyboardSnapController,
        registrar: any HotKeyRegistering = CarbonHotKeyRegistrar(),
        environment: KeyboardEnvironment = .live
    ) {
        settingsController = layoutController
        self.snapController = snapController
        self.registrar = registrar
        self.environment = environment
        snapController.didFinishAction = { [weak self] in self?.reconcile() }
    }

    func start() {
        guard !started else { return }
        started = true
        runGeneration &+= 1
        let run = runGeneration
        lifecycleGeneration &+= 1
        rememberEnvironment()
        notificationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.started, self.runGeneration == run else { return }
                self.applicationActivationChanged()
            }
        }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            Task { @MainActor in
                guard let self, self.started, self.runGeneration == run else { return }
                await self.snapController.discardProcess(pid)
            }
        }
        applicationTerminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.started, self.runGeneration == run else { return }
                self.shutdown()
            }
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.started, self.runGeneration == run else { return }
                if self.environmentDidChange() {
                    self.lifecycleGeneration &+= 1
                    self.snapController.invalidatePendingOperations()
                    if self.environment.frontmostPID() == self.ownPID || !self.environment.isAccessibilityTrusted() || !self.settingsController.keyboardSettings.isEnabled {
                        self.pause("Shortcuts are paused while AppAlign is frontmost, Accessibility is unavailable, or shortcuts are disabled.")
                    }
                }
                guard !self.isReconciling else { return }
                self.reconcile()
            }
        }
        reconcile()
    }

    func settingsDidChange() {
        lifecycleGeneration &+= 1
        snapController.invalidatePendingOperations()
        rememberEnvironment()
        if !settingsController.keyboardSettings.isEnabled {
            pause("Keyboard shortcuts are disabled.")
        }
        reconcile()
    }

    func shutdown() {
        started = false
        runGeneration &+= 1
        lifecycleGeneration &+= 1
        acceptsDispatch = false
        notificationObserver.map(NSWorkspace.shared.notificationCenter.removeObserver)
        notificationObserver = nil
        terminationObserver.map(NSWorkspace.shared.notificationCenter.removeObserver)
        terminationObserver = nil
        applicationTerminationObserver.map(NotificationCenter.default.removeObserver)
        applicationTerminationObserver = nil
        permissionTimer?.invalidate()
        permissionTimer = nil
        unregisterAll()
        registrar.shutdown()
    }

    private func reconcile() {
        guard started else { return }
        guard !isReconciling else { reconcileAgain = true; return }
        isReconciling = true
        let requestedGeneration = lifecycleGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reconcileNow(generation: requestedGeneration)
            self.isReconciling = false
            if self.reconcileAgain { self.reconcileAgain = false; self.reconcile() }
        }
    }

    private func reconcileNow(generation requestedGeneration: UInt64) async {
        guard started, lifecycleGeneration == requestedGeneration else { return }
        let settings = settingsController.keyboardSettings
        guard settings.isEnabled else { pause("Keyboard shortcuts are disabled."); return }
        guard environment.isAccessibilityTrusted() else { pause("Grant Accessibility access before enabling window placement shortcuts."); return }
        guard let pid = environment.frontmostPID(), pid != ownPID else {
            pause("Shortcuts pause while AppAlign or its Settings window is frontmost."); return
        }
        let probeBackend = snapController.backendForEligibility
        let token: RuntimeWindowSnapshot
        do {
            token = try await probeBackend.focusedWindow(applicationPID: pid, ownPID: ownPID)
        } catch {
            guard started, lifecycleGeneration == requestedGeneration else { return }
            unregisterAll(); statusMessage = "Shortcuts pause because the focused window is not eligible: \(error.localizedDescription)"; return
        }
        guard started, lifecycleGeneration == requestedGeneration else {
            await snapController.discardProbeIfUnowned(token.token)
            return
        }
        guard environment.isAccessibilityTrusted() else {
            await snapController.discardProbeIfUnowned(token.token)
            pause("Grant Accessibility access before enabling window placement shortcuts.")
            return
        }
        let appliedSnapshot = settingsController.appliedLayoutSnapshot(for: token.frame)
        guard environment.frontmostPID() == pid else {
            await snapController.discardProbeIfUnowned(token.token)
            pause("The foreground application changed while shortcuts were being checked.")
            return
        }

        var desired = settings.validShortcuts
        if settings.mode == .zoneOrder {
            desired = desired.filter { action, _ in
                switch action {
                case .direction(.north), .direction(.south): false
                default: true
                }
            }
        }
        desired = desired.filter { action, _ in
            if action == .restore { return snapController.isEligible(action, for: token, layout: appliedSnapshot) }
            return appliedSnapshot != nil && snapController.isEligible(action, for: token, layout: appliedSnapshot)
        }
        guard settingsController.keyboardSettings == settings,
              environment.frontmostPID() == pid else {
            await snapController.discardProbeIfUnowned(token.token)
            reconcileAgain = true
            return
        }
        guard !desired.isEmpty else {
            unregisterAll()
            if !registrations.isEmpty {
                statusMessage = "A registered shortcut could not be released; it may still consume its key. Restart AppAlign to retry release."
                await snapController.discardProbeIfUnowned(token.token)
                return
            }
            if appliedSnapshot == nil { statusMessage = "No applied layout is available for this window." } else { statusMessage = "No configured shortcut can act on this window in its current state." }
            await snapController.discardProbeIfUnowned(token.token)
            return
        }
        install(desired, settings: settings, pid: pid, lifecycleGeneration: requestedGeneration)
        await snapController.discardProbeIfUnowned(token.token)
    }

    private func install(
        _ desired: [KeyboardSnapAction: KeyboardShortcut],
        settings: KeyboardSettings,
        pid: pid_t,
        lifecycleGeneration requestedGeneration: UInt64
    ) {
        if acceptsDispatch, registrations.count == desired.count,
           registrations.values.allSatisfy({ desired[$0.action] == $0.shortcut && $0.lifecycleGeneration == requestedGeneration }) { return }

        acceptsDispatch = false
        unregisterAll()
        guard registrations.isEmpty else {
            statusMessage = "A shortcut could not be released; registration is paused to prevent duplicates."
            return
        }
        generation &+= 1
        for (action, shortcut) in desired.sorted(by: { $0.key.storageDescription < $1.key.storageDescription }) {
            guard started, lifecycleGeneration == requestedGeneration,
                  settingsController.keyboardSettings == settings else {
                unregisterAll()
                return
            }
            generation &+= 1
            let id = generation
            let registration = Registration(id: id, action: action, shortcut: shortcut, lifecycleGeneration: requestedGeneration)
            if registrar.conflictsWithSystemShortcut(shortcut) {
                unregisterAll()
                guard started, lifecycleGeneration == requestedGeneration else { return }
                statusMessage = "Could not register \(action.storageDescription): macOS already uses that key and modifier combination."
                return
            }
            let status = registrar.register(shortcut, id: id) { [weak self] in
                Task { @MainActor in
                    defer { HotKeyDispatchTable.completed(registration.id) }
                    guard let self, self.canDispatch(registration) else { return }
                    self.snapController.handle(action)
                }
            }
            guard status == noErr else {
                unregisterAll()
                guard started, lifecycleGeneration == requestedGeneration else { return }
                statusMessage = "Could not register \(action.storageDescription) (Carbon status \(status)). Check for another app using that shortcut."
                return
            }
            registrations[id] = registration
        }
        guard started, lifecycleGeneration == requestedGeneration,
              environment.isAccessibilityTrusted(), environment.frontmostPID() == pid,
              settingsController.keyboardSettings == settings else {
            unregisterAll()
            return
        }
        acceptsDispatch = true
        statusMessage = "Registered \(registrations.count) keyboard shortcuts. Registered keys may not reach their original app if Accessibility later fails."
    }

}

private extension GlobalHotkeys {
    func rememberEnvironment() {
        lastObservedPID = environment.frontmostPID()
        lastObservedTrust = environment.isAccessibilityTrusted()
        lastObservedEnabled = settingsController.keyboardSettings.isEnabled
    }

    func environmentDidChange() -> Bool {
        let frontmostPID = environment.frontmostPID()
        let isTrusted = environment.isAccessibilityTrusted()
        let isEnabled = settingsController.keyboardSettings.isEnabled
        let changed = frontmostPID != lastObservedPID || isTrusted != lastObservedTrust || isEnabled != lastObservedEnabled
        lastObservedPID = frontmostPID
        lastObservedTrust = isTrusted
        lastObservedEnabled = isEnabled
        return changed
    }

    func unregisterAll() {
        acceptsDispatch = false
        var retained: [UInt32: Registration] = [:]
        for (id, registration) in registrations {
            let status = registrar.unregister(id: id)
            if status != noErr { retained[id] = registration }
        }
        registrations = retained
    }

    func pause(_ reason: String) {
        unregisterAll()
        statusMessage = registrations.isEmpty ? reason : "\(reason) A registered shortcut could not be released and may still consume its key."
    }

    private func canDispatch(_ registration: Registration) -> Bool {
        guard started, acceptsDispatch, lifecycleGeneration == registration.lifecycleGeneration,
              registrations[registration.id]?.action == registration.action,
              settingsController.keyboardSettings.isEnabled,
              !snapController.isBusy,
              environment.isAccessibilityTrusted(),
              let pid = environment.frontmostPID(), pid != ownPID else { return false }
        return settingsController.keyboardSettings.validShortcuts[registration.action] == registration.shortcut
    }

    func applicationActivationChanged() {
        lifecycleGeneration &+= 1
        snapController.invalidatePendingOperations()
        rememberEnvironment()
        acceptsDispatch = false
        if environment.frontmostPID() == ownPID || !environment.isAccessibilityTrusted() {
            pause("Shortcuts pause while AppAlign is frontmost or Accessibility is unavailable.")
        }
        reconcile()
    }
}

private extension KeyboardSnapAction {
    var storageDescription: String {
        switch self {
        case .zone(let id):
            let suffix = id.rawValue == Int.max || id.rawValue == Int.max - 1 ? " (ID \(id.rawValue))" : ""
            return "Zone \(id.displayNumber)\(suffix)"
        case .next: return "next"
        case .previous: return "previous"
        case .direction(let direction): return direction.rawValue
        case .restore: return "restore"
        }
    }
}
