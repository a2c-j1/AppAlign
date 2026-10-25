import AppKit
@preconcurrency import ApplicationServices
import Combine
import Foundation

struct ManualCaptureIdentity: Equatable {
    let token: RuntimeWindowToken
    let lease: ManualWindowLeaseID
    let generation: UInt64
}

@MainActor
final class PlacementController: ObservableObject {
    @Published private(set) var accessibilityGranted: Bool
    @Published private(set) var hasCapturedWindow = false
    @Published private(set) var canRestore = false
    @Published private(set) var isBusy = false
    @Published private(set) var statusMessage = "Open the menu while another app is active, then capture its focused window."
    @Published private(set) var requestedFrame: CGRect?
    @Published private(set) var actualFrame: CGRect?
    @Published private(set) var capturedDisplayFingerprint: String?
    @Published var historyPermissionRetryRequired = false

    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let displayProvider: DisplayProvider
    private let dependencies: PlacementControllerDependencies
    private let validity: PlacementValidity
    private let refreshDisplayConfiguration: @MainActor () -> DisplaySnapshot
    private let manualRuntime: any ManualWindowOperating
    var historyRuntime: (any WindowHistoryLeaseOperating)? { manualRuntime }
    private var rememberedApplicationPID: pid_t?
    private var manualCapture: ManualWindowCapture?
    private var captureGeneration: UInt64 = 0
    private var manualOperationGeneration: UInt64 = 0
    private var manualTicket: PlacementCommitTicket?
    private var originalFrame: CGRect?
    var capturedRuntimeToken: RuntimeWindowToken? { manualCapture?.token }
    var manualCaptureIdentity: ManualCaptureIdentity? {
        guard let manualCapture else { return nil }
        return ManualCaptureIdentity(token: manualCapture.token, lease: manualCapture.lease,
                                     generation: captureGeneration)
    }
    var onSuccessfulPlacement: (@MainActor (RuntimeWindowToken, PlacementHistoryContext) -> Void)?
    var onSuccessfulRestore: (@MainActor (RuntimeWindowToken) -> Void)?
    var cancelAutomaticRestores: (@MainActor () -> Void)?
    var retryHistoryPermission: (@MainActor () -> Void)?

    init(displayProvider: DisplayProvider = DisplayProvider(),
         validity: PlacementValidity = PlacementValidity(),
         refreshDisplayConfiguration: (@MainActor () -> DisplaySnapshot)? = nil,
         dependencies: PlacementControllerDependencies = .live,
         manualRuntime: any ManualWindowOperating = AccessibilityWindowRuntime(),
         initialManualCapture: ManualWindowCapture? = nil,
         initialManualDisplayFingerprint: String? = nil) {
        self.displayProvider = displayProvider
        self.validity = validity
        self.dependencies = dependencies
        self.manualRuntime = manualRuntime
        manualCapture = initialManualCapture
        self.refreshDisplayConfiguration = refreshDisplayConfiguration ?? {
            let sample = displayProvider.sample()
            displayProvider.publish(sample)
            return sample
        }
        originalFrame = initialManualCapture?.originalFrame
        capturedDisplayFingerprint = initialManualDisplayFingerprint
        hasCapturedWindow = initialManualCapture != nil
        canRestore = initialManualCapture != nil
        accessibilityGranted = dependencies.isAccessibilityTrusted()
    }
}

@MainActor
extension PlacementController {
    func menuDidOpen() {
        refreshAccessibility()
        _ = refreshDisplayConfiguration()
        rememberFrontmostApplication()
    }

    func refreshAccessibility() {
        let isGranted = dependencies.isAccessibilityTrusted()
        if accessibilityGranted != isGranted { accessibilityGranted = isGranted }
    }

    func retryAppHistoryPermission() {
        refreshAccessibility()
        guard accessibilityGranted else {
            statusMessage = WindowManagementError.accessibilityPermissionRequired.localizedDescription
            return
        }
        historyPermissionRetryRequired = false
        retryHistoryPermission?()
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
        cancelAutomaticRestores?()
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

        _ = startManualCapture(applicationPID: pid, displaySnapshot: displaySnapshot)
    }

    @discardableResult
    func startManualCapture(applicationPID pid: pid_t, displaySnapshot: DisplaySnapshot) -> Task<Void, Never> {
        manualTicket?.invalidate()
        manualOperationGeneration &+= 1
        isBusy = false
        captureGeneration &+= 1
        let generation = captureGeneration
        statusMessage = "Capturing the focused window…"
        let manualRuntime = self.manualRuntime
        return Task { @MainActor [weak self, manualRuntime] in
                guard let self else { return }
                do {
                    let capture = try await manualRuntime.captureManualWindow(applicationPID: pid, ownPID: self.ownPID)
                    guard self.captureGeneration == generation else {
                        await manualRuntime.releaseManualLease(capture.token, lease: capture.lease)
                        return
                    }
                    if let old = self.manualCapture {
                        await manualRuntime.releaseManualLease(old.token, lease: old.lease)
                        guard self.captureGeneration == generation else {
                            await manualRuntime.releaseManualLease(capture.token, lease: capture.lease)
                            return
                        }
                    }
                    self.manualCapture = capture
                    self.originalFrame = capture.originalFrame
                    self.hasCapturedWindow = true
                    self.canRestore = true
                    self.capturedDisplayFingerprint = displaySnapshot.fingerprint
                    self.requestedFrame = nil
                    self.actualFrame = capture.originalFrame
                    self.statusMessage = "Captured the focused external window at \(Self.describe(capture.originalFrame))."
                } catch {
                    guard self.captureGeneration == generation else { return }
                    self.clearCapture()
                    self.statusMessage = error.localizedDescription
                }
        }
    }

    func restoreCapturedWindow() async {
        cancelAutomaticRestores?()
        guard manualCapture != nil else {
            statusMessage = "There is no saved frame to restore."
            return
        }
        await restoreManualCapture()
    }

    func clearCapture() {
        captureGeneration &+= 1
        manualOperationGeneration &+= 1
        manualTicket?.invalidate()
        manualTicket = nil
        isBusy = false
        if let manualCapture {
            Task { await manualRuntime.releaseManualLease(manualCapture.token, lease: manualCapture.lease) }
        }
        manualCapture = nil
        originalFrame = nil
        hasCapturedWindow = false
        canRestore = false
        requestedFrame = nil
        actualFrame = nil
        capturedDisplayFingerprint = nil
    }

    func placeCapturedWindowAsync(in frame: CGRect, displayFingerprint: String,
                                  historyContext: PlacementHistoryContext?) async throws {
        guard let capture = manualCapture else { throw WindowManagementError.noCapturedWindow }
        guard !isBusy else { throw WindowManagementError.operationFailed }
        guard historyContext?.expectedToken == nil || historyContext?.expectedToken == capture.token else {
            throw WindowManagementError.noCapturedWindow
        }
        let generation = captureGeneration
        let configurationRevision = validity.revision.configuration
        manualOperationGeneration &+= 1
        let operation = manualOperationGeneration
        isBusy = true
        defer {
            if manualOperationGeneration == operation {
                manualTicket = nil
                isBusy = false
            }
        }
        do {
            refreshAccessibility()
            guard accessibilityGranted else { throw WindowManagementError.accessibilityPermissionRequired }
            try validateDisplayConfiguration(expectedFingerprint: displayFingerprint)
            try validateDisplayConfiguration(expectedFingerprint: capturedDisplayFingerprint)
            let ticket = try makeTicket()
            manualTicket = ticket
            defer { ticket.finish() }
            requestedFrame = frame
            let preflight: @MainActor @Sendable () async -> Bool = { [weak self] in
                guard let self, self.captureGeneration == generation,
                      self.manualOperationGeneration == operation,
                      self.manualCapture?.token == capture.token,
                      self.manualCapture?.lease == capture.lease,
                      self.dependencies.isAccessibilityTrusted() else { return false }
                return self.displayConfigurationIsCurrent(displayFingerprint) &&
                    self.displayConfigurationIsCurrent(self.capturedDisplayFingerprint)
            }
            let actualFrame = try await manualRuntime.moveManualWindow(capture.token, lease: capture.lease,
                                                                      to: frame, ticket: ticket, preflight: preflight)
            guard Self.framesMatch(actualFrame, frame),
                  manualOperationGeneration == operation,
                  await preflight(),
                  ticket.completeIfCurrent(now: DispatchTime.now().uptimeNanoseconds) else {
                throw WindowManagementError.displayConfigurationChanged
            }
            if let historyContext { onSuccessfulPlacement?(capture.token, historyContext) }
            self.actualFrame = actualFrame
            statusMessage = "Placed and verified the captured window at \(Self.describe(actualFrame))."
        } catch {
            let observedFrame = try? await manualRuntime.readManualWindowFrame(capture.token, lease: capture.lease)
            guard captureGeneration == generation, manualOperationGeneration == operation,
                  manualCapture?.token == capture.token, manualCapture?.lease == capture.lease,
                  validity.revision.configuration == configurationRevision else { throw error }
            actualFrame = observedFrame
            statusMessage = error.localizedDescription
            throw error
        }
    }

    private func restoreManualCapture() async {
        guard let capture = manualCapture, let originalFrame else {
            statusMessage = "There is no saved frame to restore."
            return
        }
        guard !isBusy else {
            statusMessage = "A manual window operation is already in progress."
            return
        }
        isBusy = true
        let generation = captureGeneration
        let configurationRevision = validity.revision.configuration
        manualOperationGeneration &+= 1
        let operation = manualOperationGeneration
        defer {
            if manualOperationGeneration == operation {
                manualTicket = nil
                isBusy = false
            }
        }
        do {
            refreshAccessibility()
            guard accessibilityGranted else { throw WindowManagementError.accessibilityPermissionRequired }
            try validateDisplayConfiguration(expectedFingerprint: capturedDisplayFingerprint)
            let ticket = try makeTicket()
            manualTicket = ticket
            defer { ticket.finish() }
            let preflight: @MainActor @Sendable () async -> Bool = { [weak self] in
                guard let self, self.captureGeneration == generation,
                      self.manualOperationGeneration == operation,
                      self.manualCapture?.token == capture.token,
                      self.manualCapture?.lease == capture.lease,
                      self.dependencies.isAccessibilityTrusted() else { return false }
                return self.displayConfigurationIsCurrent(self.capturedDisplayFingerprint)
            }
            let actualFrame = try await manualRuntime.moveManualWindow(capture.token, lease: capture.lease,
                                                                      to: originalFrame, ticket: ticket, preflight: preflight)
            guard Self.framesMatch(actualFrame, originalFrame),
                  manualOperationGeneration == operation, await preflight(),
                  ticket.completeIfCurrent(now: DispatchTime.now().uptimeNanoseconds) else {
                throw WindowManagementError.displayConfigurationChanged
            }
            self.actualFrame = actualFrame
            onSuccessfulRestore?(capture.token)
            statusMessage = "Restored and verified the original frame."
        } catch {
            let observedFrame = try? await manualRuntime.readManualWindowFrame(capture.token, lease: capture.lease)
            guard captureGeneration == generation, manualOperationGeneration == operation,
                  manualCapture?.token == capture.token, manualCapture?.lease == capture.lease,
                  validity.revision.configuration == configurationRevision else { return }
            actualFrame = observedFrame
            statusMessage = error.localizedDescription
        }
    }

    private func displayConfigurationIsCurrent(_ expected: String?) -> Bool {
        guard let expected else { return false }
        return refreshDisplayConfiguration().fingerprint == expected
    }

    private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        DisplayGeometry.isFinite(lhs) && DisplayGeometry.isFinite(rhs) &&
            abs(lhs.minX - rhs.minX) <= 2 && abs(lhs.minY - rhs.minY) <= 2 &&
            abs(lhs.width - rhs.width) <= 2 && abs(lhs.height - rhs.height) <= 2
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

struct PlacementHistoryContext {
    let display: Display
    let layout: PersistedLayout
    let zoneIDs: [Int]
    let historyLease: AppHistoryCoordinator.Lease?
    let expectedToken: RuntimeWindowToken?
}

@MainActor
struct PlacementControllerDependencies {
    let isAccessibilityTrusted: () -> Bool

    static var live: PlacementControllerDependencies {
        PlacementControllerDependencies(
            isAccessibilityTrusted: { AXIsProcessTrusted() }
        )
    }
}
