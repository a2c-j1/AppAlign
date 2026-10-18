import AppKit
import Foundation

@MainActor
final class AccessibilityHistoryPermissionMonitor {
    private let permissionIsGranted: @MainActor () -> Bool
    private let permissionWasRevoked: @MainActor () -> Void
    private var timer: Timer?
    private var suspendedUntilRetry = false
    private(set) var timerInstallCount = 0
    var isRunning: Bool { timer != nil }

    init(permissionIsGranted: @escaping @MainActor () -> Bool,
         permissionWasRevoked: @escaping @MainActor () -> Void) {
        self.permissionIsGranted = permissionIsGranted
        self.permissionWasRevoked = permissionWasRevoked
    }

    func update(enabled: Bool) {
        guard enabled else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        timerInstallCount += 1
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollNow() }
        }
    }

    func pollNow() {
        guard timer != nil, !permissionIsGranted(), !suspendedUntilRetry else { return }
        suspendedUntilRetry = true
        permissionWasRevoked()
    }

    func retrySucceeded() { suspendedUntilRetry = false }
}
