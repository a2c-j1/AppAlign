import AppKit
@preconcurrency import ApplicationServices
import Foundation
import Dispatch

actor AccessibilityWindowRuntime: KeyboardWindowOperating {
    nonisolated let executor = AccessibilitySerialExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    struct Record {
        var window: AXWindow
        var ownership = RuntimeWindowOwnership()
        var revisionTracker = AXRevisionTracker()
        var observerRegistration: AXObserverRegistration?
        var historyObserverVerified = false
    }
    struct ProcessObservation {
        let generation: UUID
        let epoch: UInt64
        let registration: AXWindowCreationRegistration
    }

    var records: [UUID: Record] = [:]
    var processLaunchGenerations: [pid_t: UUID] = [:]
    var processLaunchDates: [pid_t: Date] = [:]
    var processObservations: [pid_t: ProcessObservation] = [:]
    var historyDestroyHandler: (@Sendable (RuntimeWindowToken, UInt64) -> Void)?
    var historyDestroyEpoch: UInt64 = 0
    var historyDestroyNotificationsEnabled = true
    var historyDestroyLifecycleRevision: UInt64 = 0
    var historyDestroySinks = Set<RuntimeWindowToken>()
    var writeInProgress = false
    var lastWriteEndNanoseconds: UInt64 = 0
    let repository = WindowRepository(messagingTimeout: 0.5)
    let mover: any WindowPlacementOperating
    let historyMover: any WindowPlacementOperating
    let settableAttributeProvider: @Sendable (AXWindow, CFString) throws -> Bool
    let historyObserverProvider: (@Sendable (pid_t, AXUIElement, AXRevisionTracker, UInt64) -> Bool)?
    let focusedWindowProvider: @Sendable (pid_t) throws -> AXWindow
    let focusedWindowValidator: @Sendable (AXWindow) throws -> Void
    let frontmostPIDProvider: @Sendable () -> pid_t?
    let accessibilityTrustedProvider: @Sendable () -> Bool
    let applicationWindowsProvider: @Sendable (pid_t, Float, UInt64) throws -> [AXWindow]
    let observationFrameProvider: @Sendable (AXWindow) throws -> CGRect

    init(focusedWindowProvider: (@Sendable (pid_t) throws -> AXWindow)? = nil,
         focusedWindowValidator: (@Sendable (AXWindow) throws -> Void)? = nil,
         frontmostPIDProvider: (@Sendable () -> pid_t?)? = nil,
         accessibilityTrustedProvider: (@Sendable () -> Bool)? = nil,
         mover: any WindowPlacementOperating = WindowMover(messagingTimeout: 0.5, retryLimit: 1),
         historyMover: (any WindowPlacementOperating)? = nil,
         settableAttributeProvider: (@Sendable (AXWindow, CFString) throws -> Bool)? = nil,
         historyObserverProvider: (@Sendable (pid_t, AXUIElement, AXRevisionTracker, UInt64) -> Bool)? = nil,
         applicationWindowsProvider: (@Sendable (pid_t, Float, UInt64) throws -> [AXWindow])? = nil,
         observationFrameProvider: (@Sendable (AXWindow) throws -> CGRect)? = nil) {
        self.mover = mover
        self.historyMover = historyMover ?? WindowMover(messagingTimeout: 0.2, retryLimit: 0)
        self.settableAttributeProvider = settableAttributeProvider ?? { window, attribute in
            try window.isAttributeSettable(attribute)
        }
        self.historyObserverProvider = historyObserverProvider
        self.applicationWindowsProvider = applicationWindowsProvider ?? { pid, timeout, deadline in
            try WindowRepository(messagingTimeout: timeout).applicationWindows(applicationPID: pid,
                                                                                timeout: timeout,
                                                                                deadline: deadline)
        }
        self.observationFrameProvider = observationFrameProvider ?? { try $0.stableFrame() }
        self.focusedWindowProvider = focusedWindowProvider ?? { pid in
            try WindowRepository(messagingTimeout: 0.5).focusedWindow(applicationPID: pid)
        }
        self.focusedWindowValidator = focusedWindowValidator ?? { window in
            try WindowFilter(ownPID: ProcessInfo.processInfo.processIdentifier).validate(window)
        }
        self.frontmostPIDProvider = frontmostPIDProvider ?? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        self.accessibilityTrustedProvider = accessibilityTrustedProvider ?? { AXIsProcessTrusted() }
    }
}
