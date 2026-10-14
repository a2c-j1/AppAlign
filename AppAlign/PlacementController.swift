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
    private let displayProvider: DisplayProvider
    private let repository = WindowRepository()
    private let dependencies: PlacementControllerDependencies
    private let validity: PlacementValidity
    private let refreshDisplayConfiguration: @MainActor () -> DisplaySnapshot
    private var rememberedApplicationPID: pid_t?
    private var capturedWindow: AXWindow?
    private var originalFrame: CGRect?

    init(displayProvider: DisplayProvider = DisplayProvider(),
         validity: PlacementValidity = PlacementValidity(),
         refreshDisplayConfiguration: (@MainActor () -> DisplaySnapshot)? = nil,
         dependencies: PlacementControllerDependencies = .live,
         initialCapture: CapturedWindow? = nil) {
        self.displayProvider = displayProvider
        self.validity = validity
        self.dependencies = dependencies
        self.refreshDisplayConfiguration = refreshDisplayConfiguration ?? {
            let sample = displayProvider.sample()
            displayProvider.publish(sample)
            return sample
        }
        capturedWindow = initialCapture?.window
        originalFrame = initialCapture?.originalFrame
        capturedDisplayFingerprint = initialCapture?.displayFingerprint
        hasCapturedWindow = initialCapture != nil
        canRestore = initialCapture != nil
        accessibilityGranted = dependencies.isAccessibilityTrusted()
    }

    func menuDidOpen() {
        refreshAccessibility()
        _ = refreshDisplayConfiguration()
        rememberFrontmostApplication()
    }

    func refreshAccessibility() {
        accessibilityGranted = dependencies.isAccessibilityTrusted()
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
        let displaySnapshot = refreshDisplayConfiguration()
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
            try dependencies.validateWindow(window)
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
            try dependencies.validateWindow(window)
            try validateDisplayConfiguration(expectedFingerprint: capturedDisplayFingerprint)
            let ticket = try makeTicket()
            defer { ticket.finish() }
            guard ticket.beginWrite(now: DispatchTime.now().uptimeNanoseconds) else {
                throw WindowManagementError.displayConfigurationChanged
            }
            requestedFrame = originalFrame
            let result = try dependencies.movePlacement(window, originalFrame, ticket)
            guard ticket.completeIfCurrent(now: DispatchTime.now().uptimeNanoseconds) else {
                throw WindowManagementError.displayConfigurationChanged
            }
            actualFrame = result.actualFrame
            statusMessage = "Restored and verified the original frame."
        } catch {
            actualFrame = try? dependencies.readFrame(window)
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
            try dependencies.validateWindow(window)
            try validateDisplayConfiguration(expectedFingerprint: displayFingerprint)
            try validateDisplayConfiguration(expectedFingerprint: capturedDisplayFingerprint)
            let ticket = try makeTicket()
            defer { ticket.finish() }
            guard ticket.beginWrite(now: DispatchTime.now().uptimeNanoseconds) else {
                throw WindowManagementError.displayConfigurationChanged
            }
            requestedFrame = frame
            let result = try dependencies.movePlacement(window, frame, ticket)
            guard ticket.completeIfCurrent(now: DispatchTime.now().uptimeNanoseconds) else {
                throw WindowManagementError.displayConfigurationChanged
            }
            actualFrame = result.actualFrame
            statusMessage = "Placed and verified the captured window at \(Self.describe(result.actualFrame))."
        } catch {
            actualFrame = try? dependencies.readFrame(window)
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
        let current = refreshDisplayConfiguration().fingerprint
        guard let expectedFingerprint, expectedFingerprint == current else {
            canRestore = false
            throw WindowManagementError.displayConfigurationChanged
        }
    }

    private func makeTicket() throws -> PlacementCommitTicket {
        let now = DispatchTime.now().uptimeNanoseconds
        guard let ticket = validity.reserve(startDeadline: now + 2_000_000_000,
                                            totalDeadline: now + 5_000_000_000) else {
            throw WindowManagementError.operationFailed
        }
        return ticket
    }

    static func describe(_ frame: CGRect) -> String {
        "x=\(frame.origin.x), y=\(frame.origin.y), w=\(frame.width), h=\(frame.height)"
    }
}

struct CapturedWindow {
    let window: AXWindow
    let originalFrame: CGRect
    let displayFingerprint: String
}

@MainActor
struct PlacementControllerDependencies {
    let isAccessibilityTrusted: () -> Bool
    let validateWindow: (AXWindow) throws -> Void
    let readFrame: (AXWindow) throws -> CGRect
    let movePlacement: (AXWindow, CGRect, PlacementCommitTicket) throws -> PlacementResult

    static var live: PlacementControllerDependencies {
        PlacementControllerDependencies(
            isAccessibilityTrusted: { AXIsProcessTrusted() },
            validateWindow: { try WindowFilter(ownPID: ProcessInfo.processInfo.processIdentifier).validate($0) },
            readFrame: { try $0.frame() },
            movePlacement: { try WindowMover().movePlacement($0, to: $1, ticket: $2) }
        )
    }
}
