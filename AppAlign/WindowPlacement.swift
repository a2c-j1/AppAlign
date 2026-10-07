import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation

enum WindowManagementError: LocalizedError {
    case accessibilityPermissionRequired
    case noTargetApplication
    case noFocusedWindow(code: Int32)
    case invalidFocusedWindow
    case noCapturedWindow
    case readFailed(attribute: String, code: Int32)
    case invalidAttribute(attribute: String)
    case excludedWindow(reason: String)
    case attributeNotSettable(attribute: String)
    case writeFailed(attribute: String, code: Int32)
    case invalidRequestedFrame
    case frameMismatch(requested: CGRect, actual: CGRect)
    case displayConfigurationChanged
    case operationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired:
            return "Accessibility access is required before AppAlign can inspect or move another app's window."
        case .noTargetApplication:
            return "No external foreground application is available to capture."
        case .noFocusedWindow(let code):
            return "The target app did not expose a focused window (AX error \(code))."
        case .invalidFocusedWindow:
            return "The focused accessibility object is not a valid window."
        case .noCapturedWindow:
            return "Capture an eligible window before placing it."
        case .readFailed(let attribute, let code):
            return "Could not read \(attribute) (AX error \(code))."
        case .invalidAttribute(let attribute):
            return "The target returned an invalid value for \(attribute)."
        case .excludedWindow(let reason):
            return "This window is not eligible for placement: \(reason)."
        case .attributeNotSettable(let attribute):
            return "The target does not allow AppAlign to change \(attribute)."
        case .writeFailed(let attribute, let code):
            return "Could not update \(attribute) (AX error \(code))."
        case .invalidRequestedFrame:
            return "The requested window frame is invalid."
        case .frameMismatch(let requested, let actual):
            return "The app constrained the requested frame. Requested \(Self.describe(requested)); actual \(Self.describe(actual))."
        case .displayConfigurationChanged:
            return "The display configuration changed. Capture the window again before placing or restoring it."
        case .operationFailed:
            return "The window operation failed."
        }
    }

    var isRetryable: Bool {
        switch self {
        case .readFailed, .writeFailed:
            return true
        default:
            return false
        }
    }

    private static func describe(_ frame: CGRect) -> String {
        "x=\(frame.origin.x), y=\(frame.origin.y), w=\(frame.width), h=\(frame.height)"
    }
}

struct WindowFilter {
    let ownPID: pid_t

    func validate(_ window: AXWindow) throws {
        guard window.pid != ownPID else {
            throw WindowManagementError.excludedWindow(reason: "AppAlign does not move its own windows")
        }

        guard try window.stringAttribute(kAXRoleAttribute as CFString) == "AXWindow" else {
            throw WindowManagementError.excludedWindow(reason: "the focused element is not a standard window")
        }

        if let subrole = try window.stringAttribute(kAXSubroleAttribute as CFString),
           subrole == "AXDialog" || subrole == "AXSystemDialog" {
            throw WindowManagementError.excludedWindow(reason: "dialogs and sheets are excluded")
        }

        if try window.boolAttribute(kAXMinimizedAttribute as CFString) == true {
            throw WindowManagementError.excludedWindow(reason: "the window is minimized")
        }

        if try window.boolAttribute("AXFullScreen" as CFString) == true {
            throw WindowManagementError.excludedWindow(reason: "full-screen windows are excluded")
        }

        guard try window.isAttributeSettable(kAXPositionAttribute as CFString) else {
            throw WindowManagementError.attributeNotSettable(attribute: kAXPositionAttribute as String)
        }

        guard try window.isAttributeSettable(kAXSizeAttribute as CFString) else {
            throw WindowManagementError.attributeNotSettable(attribute: kAXSizeAttribute as String)
        }
    }
}
struct PlacementResult {
    let requestedFrame: CGRect
    let actualFrame: CGRect
}

struct WindowMover {
    let messagingTimeout: Float
    let retryLimit: Int
    let frameTolerance: CGFloat

    init(
        messagingTimeout: Float = 0.5,
        retryLimit: Int = 1,
        frameTolerance: CGFloat = 2
    ) {
        self.messagingTimeout = messagingTimeout
        self.retryLimit = max(0, retryLimit)
        self.frameTolerance = max(0, frameTolerance)
    }

    func move(_ window: AXWindow, to requestedFrame: CGRect) throws -> PlacementResult {
        guard
            requestedFrame.width.isFinite,
            requestedFrame.height.isFinite,
            requestedFrame.origin.x.isFinite,
            requestedFrame.origin.y.isFinite,
            requestedFrame.width > 0,
            requestedFrame.height > 0
        else {
            throw WindowManagementError.invalidRequestedFrame
        }

        try window.configureMessagingTimeout(messagingTimeout)

        var lastError: WindowManagementError = .operationFailed

        for attempt in 0 ... retryLimit {
            do {
                // Some apps clamp size based on their current position. Re-applying
                // position after size keeps the requested origin explicit while the
                // final readback remains the source of truth.
                try window.setPosition(requestedFrame.origin)
                try window.setSize(requestedFrame.size)
                try window.setPosition(requestedFrame.origin)

                let actualFrame = try window.frame()
                guard framesMatch(requestedFrame, actualFrame) else {
                    throw WindowManagementError.frameMismatch(
                        requested: requestedFrame,
                        actual: actualFrame
                    )
                }

                return PlacementResult(
                    requestedFrame: requestedFrame,
                    actualFrame: actualFrame
                )
            } catch let error as WindowManagementError {
                lastError = error
                if attempt >= retryLimit || !error.isRetryable {
                    throw error
                }
            }
        }

        throw lastError
    }

    private func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= frameTolerance
            && abs(lhs.origin.y - rhs.origin.y) <= frameTolerance
            && abs(lhs.width - rhs.width) <= frameTolerance
            && abs(lhs.height - rhs.height) <= frameTolerance
    }
}
