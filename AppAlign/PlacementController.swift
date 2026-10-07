import AppKit
@preconcurrency import ApplicationServices
import Combine
import Foundation

@MainActor
final class PlacementController: ObservableObject {
    @Published private(set) var accessibilityGranted: Bool
    @Published private(set) var hasCapturedWindow = false
    @Published private(set) var canRestore = false
    @Published private(set) var statusMessage = "Open the menu while another app is active, then capture its focused window."
    @Published private(set) var requestedFrame: CGRect?
    @Published private(set) var actualFrame: CGRect?
    @Published private(set) var capturedDisplayFingerprint: String?

    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let displayProvider = DisplayProvider()
    private let repository = WindowRepository()
    private let mover = WindowMover()
    private var rememberedApplicationPID: pid_t?
    private var capturedWindow: AXWindow?
    private var originalFrame: CGRect?

    init() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    func menuDidOpen() {
        refreshAccessibility()
        displayProvider.refresh()
        rememberFrontmostApplication()
    }

    func refreshAccessibility() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    func requestAccessibilityAccess() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true as CFBoolean
        ] as CFDictionary

        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        statusMessage = accessibilityGranted
            ? "Accessibility access is available."
            : "Grant Accessibility access in System Settings, then reopen the AppAlign menu."
    }

    func captureFocusedWindow() {
        refreshAccessibility()
        let displaySnapshot = displayProvider.refresh()
        guard accessibilityGranted else {
            statusMessage = WindowManagementError.accessibilityPermissionRequired.localizedDescription
            return
        }

        rememberFrontmostApplication()
        guard let pid = rememberedApplicationPID else {
            statusMessage = WindowManagementError.noTargetApplication.localizedDescription
            return
        }

        do {
            let window = try repository.focusedWindow(applicationPID: pid)
            try WindowFilter(ownPID: ownPID).validate(window)
            let frame = try window.frame()

            capturedWindow = window
            originalFrame = frame
            hasCapturedWindow = true
            canRestore = true
            capturedDisplayFingerprint = displaySnapshot.fingerprint
            requestedFrame = nil
            actualFrame = frame
            statusMessage = "Captured the focused external window at \(Self.describe(frame))."
        } catch {
            clearCapture()
            statusMessage = error.localizedDescription
        }
    }

    func restoreCapturedWindow() {
        guard
            let window = capturedWindow,
            let originalFrame
        else {
            statusMessage = "There is no saved frame to restore."
            return
        }

        do {
            refreshAccessibility()
            guard accessibilityGranted else { throw WindowManagementError.accessibilityPermissionRequired }
            try WindowFilter(ownPID: ownPID).validate(window)
            try validateDisplayConfiguration(expectedFingerprint: capturedDisplayFingerprint)
            requestedFrame = originalFrame
            let result = try mover.move(window, to: originalFrame)
            actualFrame = result.actualFrame
            statusMessage = "Restored and verified the original frame."
        } catch {
            actualFrame = try? window.frame()
            statusMessage = error.localizedDescription
        }
    }

    func clearCapture() {
        capturedWindow = nil
        originalFrame = nil
        hasCapturedWindow = false
        canRestore = false
        requestedFrame = nil
        actualFrame = nil
        capturedDisplayFingerprint = nil
    }

    func placeCapturedWindow(in frame: CGRect, displayFingerprint: String) throws {
        guard let window = capturedWindow else {
            throw WindowManagementError.noCapturedWindow
        }
        do {
            refreshAccessibility()
            guard accessibilityGranted else { throw WindowManagementError.accessibilityPermissionRequired }
            try WindowFilter(ownPID: ownPID).validate(window)
            try validateDisplayConfiguration(expectedFingerprint: displayFingerprint)
            try validateDisplayConfiguration(expectedFingerprint: capturedDisplayFingerprint)
            requestedFrame = frame
            let result = try mover.move(window, to: frame)
            actualFrame = result.actualFrame
            statusMessage = "Placed and verified the captured window at \(Self.describe(result.actualFrame))."
        } catch {
            actualFrame = try? window.frame()
            statusMessage = error.localizedDescription
            throw error
        }
    }

    private func rememberFrontmostApplication() {
        guard
            let application = NSWorkspace.shared.frontmostApplication,
            application.processIdentifier != ownPID
        else {
            return
        }
        rememberedApplicationPID = application.processIdentifier
    }

    private func validateDisplayConfiguration(expectedFingerprint: String?) throws {
        let current = displayProvider.refresh().fingerprint
        guard let expectedFingerprint, expectedFingerprint == current else {
            canRestore = false
            throw WindowManagementError.displayConfigurationChanged
        }
    }

    static func describe(_ frame: CGRect) -> String {
        "x=\(frame.origin.x), y=\(frame.origin.y), w=\(frame.width), h=\(frame.height)"
    }
}
