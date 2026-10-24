import AppKit
@preconcurrency import ApplicationServices
import Dispatch
import Foundation

extension AccessibilityWindowRuntime {
    func observedWindows(applicationPID pid: pid_t, processGeneration generation: UUID,
                         ownPID: pid_t, deadline: UInt64) async throws -> WindowObservationResult {
        guard processLaunchGenerations[pid] == generation, pid != ownPID,
              accessibilityTrustedProvider() else {
            throw accessibilityTrustedProvider() ? WindowManagementError.excludedWindow(reason: "ineligible process")
                : WindowManagementError.accessibilityPermissionRequired
        }
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
            return WindowObservationResult(candidates: [], isComplete: false)
        }
        let remaining = Float(deadline - DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        let windows = try applicationWindowsProvider(pid, min(0.2, remaining), deadline)
        var candidates: [WindowObservationCandidate] = []
        var isComplete = windows.count <= 64
        var hasUntrackedWindowsDueToCapacity = false
        for window in windows.prefix(64) {
            guard DispatchTime.now().uptimeNanoseconds < deadline else { isComplete = false; break }
            let runtimeToken: RuntimeWindowToken
            do {
                runtimeToken = try token(for: window)
            } catch let error as WindowManagementError {
                if case .invalidFocusedWindow = error { hasUntrackedWindowsDueToCapacity = true }
                continue
            } catch {
                continue
            }
            guard runtimeToken.processGeneration == generation else { continue }
            do {
                try focusedWindowValidator(window)
                let frame = try observationFrameProvider(window)
                guard Self.isFinite(frame), frame.width > 0, frame.height > 0 else {
                    candidates.append(WindowObservationCandidate(token: runtimeToken, readiness: .terminal))
                    continue
                }
                candidates.append(WindowObservationCandidate(token: runtimeToken, readiness: .ready(frame)))
            } catch let error as WindowManagementError {
                if case .accessibilityPermissionRequired = error { throw error }
                let readiness: WindowObservationReadiness = Self.isTemporaryObservationError(error) ? .temporarilyUnavailable : .terminal
                candidates.append(WindowObservationCandidate(token: runtimeToken, readiness: readiness))
            } catch {
                candidates.append(WindowObservationCandidate(token: runtimeToken, readiness: .terminal))
            }
        }
        return WindowObservationResult(candidates: candidates, isComplete: isComplete,
                                      hasUntrackedWindowsDueToCapacity: hasUntrackedWindowsDueToCapacity)
    }

    private static func isTemporaryObservationError(_ error: WindowManagementError) -> Bool {
        guard case let .readFailed(_, code) = error else { return false }
        return code == AXError.cannotComplete.rawValue || code == AXError.noValue.rawValue
    }
}
