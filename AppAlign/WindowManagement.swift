import Combine
import AppKit
@preconcurrency import ApplicationServices
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

struct AXWindow {
    let applicationElement: AXUIElement
    let element: AXUIElement
    let pid: pid_t

    func frame() throws -> CGRect {
        let position = try pointAttribute(kAXPositionAttribute as CFString)
        let size = try sizeAttribute(kAXSizeAttribute as CFString)
        return CGRect(origin: position, size: size)
    }

    func stringAttribute(_ attribute: CFString) throws -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)

        if result == .noValue || result == .attributeUnsupported {
            return nil
        }
        guard result == .success else {
            throw WindowManagementError.readFailed(
                attribute: attribute as String,
                code: result.rawValue
            )
        }
        return value as? String
    }

    func boolAttribute(_ attribute: CFString) throws -> Bool? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)

        if result == .noValue || result == .attributeUnsupported {
            return nil
        }
        guard result == .success else {
            throw WindowManagementError.readFailed(
                attribute: attribute as String,
                code: result.rawValue
            )
        }
        return value as? Bool
    }

    func isAttributeSettable(_ attribute: CFString) throws -> Bool {
        var settable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(element, attribute, &settable)
        guard result == .success else {
            throw WindowManagementError.readFailed(
                attribute: attribute as String,
                code: result.rawValue
            )
        }
        return settable.boolValue
    }

    func setPosition(_ point: CGPoint) throws {
        var mutablePoint = point
        guard let value = AXValueCreate(.cgPoint, &mutablePoint) else {
            throw WindowManagementError.invalidAttribute(attribute: kAXPositionAttribute as String)
        }
        let result = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        guard result == .success else {
            throw WindowManagementError.writeFailed(
                attribute: kAXPositionAttribute as String,
                code: result.rawValue
            )
        }
    }

    func setSize(_ size: CGSize) throws {
        var mutableSize = size
        guard let value = AXValueCreate(.cgSize, &mutableSize) else {
            throw WindowManagementError.invalidAttribute(attribute: kAXSizeAttribute as String)
        }
        let result = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        guard result == .success else {
            throw WindowManagementError.writeFailed(
                attribute: kAXSizeAttribute as String,
                code: result.rawValue
            )
        }
    }

    private func pointAttribute(_ attribute: CFString) throws -> CGPoint {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else {
            throw WindowManagementError.readFailed(
                attribute: attribute as String,
                code: result.rawValue
            )
        }
        guard
            let value,
            CFGetTypeID(value) == AXValueGetTypeID()
        else {
            throw WindowManagementError.invalidAttribute(attribute: attribute as String)
        }

        var point = CGPoint.zero
        // CoreFoundation type ID was checked immediately above.
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else {
            throw WindowManagementError.invalidAttribute(attribute: attribute as String)
        }
        return point
    }

    private func sizeAttribute(_ attribute: CFString) throws -> CGSize {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else {
            throw WindowManagementError.readFailed(
                attribute: attribute as String,
                code: result.rawValue
            )
        }
        guard
            let value,
            CFGetTypeID(value) == AXValueGetTypeID()
        else {
            throw WindowManagementError.invalidAttribute(attribute: attribute as String)
        }

        var size = CGSize.zero
        // CoreFoundation type ID was checked immediately above.
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else {
            throw WindowManagementError.invalidAttribute(attribute: attribute as String)
        }
        return size
    }
}

struct WindowRepository {
    let messagingTimeout: Float

    init(messagingTimeout: Float = 0.5) {
        self.messagingTimeout = messagingTimeout
    }

    func focusedWindow(applicationPID: pid_t) throws -> AXWindow {
        let applicationElement = AXUIElementCreateApplication(applicationPID)
        let timeoutResult = AXUIElementSetMessagingTimeout(applicationElement, messagingTimeout)
        guard timeoutResult == .success else {
            throw WindowManagementError.readFailed(
                attribute: "messaging timeout",
                code: timeoutResult.rawValue
            )
        }

        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            &value
        )
        guard result == .success else {
            throw WindowManagementError.noFocusedWindow(code: result.rawValue)
        }
        guard
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            throw WindowManagementError.invalidFocusedWindow
        }

        // CoreFoundation type ID was checked immediately above.
        // swiftlint:disable:next force_cast
        let element = value as! AXUIElement
        var pid = applicationPID
        let pidResult = AXUIElementGetPid(element, &pid)
        guard pidResult == .success else {
            throw WindowManagementError.readFailed(
                attribute: "window pid",
                code: pidResult.rawValue
            )
        }

        return AXWindow(
            applicationElement: applicationElement,
            element: element,
            pid: pid
        )
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

        let timeoutResult = AXUIElementSetMessagingTimeout(window.applicationElement, messagingTimeout)
        guard timeoutResult == .success else {
            throw WindowManagementError.writeFailed(
                attribute: "messaging timeout",
                code: timeoutResult.rawValue
            )
        }

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

/// Owns AXUIElement instances on one actor so no accessibility handle crosses the UI boundary.
actor AccessibilityWindowRuntime: KeyboardWindowOperating {
    private struct Record {
        let window: AXWindow
    }

    private var records: [UUID: Record] = [:]
    private var retainedIDs = Set<UUID>()
    private let repository = WindowRepository(messagingTimeout: 0.5)
    private let mover = WindowMover(messagingTimeout: 0.5, retryLimit: 1)

    func focusedWindow(applicationPID: pid_t, ownPID: pid_t) async throws -> RuntimeWindowSnapshot {
        guard applicationPID != ownPID else {
            throw WindowManagementError.excludedWindow(reason: "AppAlign cannot move its own windows")
        }
        let focused = try repository.focusedWindow(applicationPID: applicationPID)
        try WindowFilter(ownPID: ownPID).validate(focused)
        let frame = try focused.frame()
        guard Self.isFinite(frame), frame.width > 0, frame.height > 0 else {
            throw WindowManagementError.invalidFocusedWindow
        }

        if let match = records.first(where: { $0.value.window.pid == focused.pid && CFEqual($0.value.window.element, focused.element) }) {
            return RuntimeWindowSnapshot(token: RuntimeWindowToken(id: match.key, pid: focused.pid), frame: frame)
        }
        if records.count >= 128,
           let oldest = records.keys.first(where: { !retainedIDs.contains($0) }) {
            records.removeValue(forKey: oldest)
        }
        guard records.count < 128 else { throw WindowManagementError.invalidFocusedWindow }
        let id = UUID()
        records[id] = Record(window: focused)
        return RuntimeWindowSnapshot(token: RuntimeWindowToken(id: id, pid: focused.pid), frame: frame)
    }

    func retain(_ token: RuntimeWindowToken) async {
        guard records[token.id]?.window.pid == token.pid else { return }
        retainedIDs.insert(token.id)
    }

    func move(
        _ token: RuntimeWindowToken,
        to frame: CGRect,
        preflight: @MainActor @Sendable () -> Bool
    ) async throws -> CGRect {
        try await withCurrentFocusedWindow(token, preflight: preflight) { window in try mover.move(window, to: frame).actualFrame }
    }

    func restore(
        _ token: RuntimeWindowToken,
        to frame: CGRect,
        preflight: @MainActor @Sendable () -> Bool
    ) async throws -> CGRect {
        try await withCurrentFocusedWindow(token, preflight: preflight) { window in try mover.move(window, to: frame).actualFrame }
    }

    func discard(_ token: RuntimeWindowToken) async {
        records.removeValue(forKey: token.id)
        retainedIDs.remove(token.id)
    }

    func shutdown() async {
        records.removeAll()
        retainedIDs.removeAll()
    }

    private func withCurrentFocusedWindow<T>(
        _ token: RuntimeWindowToken,
        preflight: @MainActor @Sendable () -> Bool,
        operation: (AXWindow) throws -> T
    ) async throws -> T {
        guard let record = records[token.id], record.window.pid == token.pid else { throw WindowManagementError.noCapturedWindow }
        do {
            let focusedBeforePreflight = try repository.focusedWindow(applicationPID: token.pid)
            guard CFEqual(record.window.element, focusedBeforePreflight.element) else {
                throw WindowManagementError.noFocusedWindow(code: -1)
            }
            try WindowFilter(ownPID: ProcessInfo.processInfo.processIdentifier).validate(focusedBeforePreflight)
            guard await preflight() else { throw WindowManagementError.displayConfigurationChanged }
            let focused = try repository.focusedWindow(applicationPID: token.pid)
            guard CFEqual(record.window.element, focused.element) else {
                throw WindowManagementError.noFocusedWindow(code: -1)
            }
            try WindowFilter(ownPID: ProcessInfo.processInfo.processIdentifier).validate(focused)
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == token.pid,
                  AXIsProcessTrusted() else {
                throw WindowManagementError.displayConfigurationChanged
            }
            return try operation(focused)
        } catch {
            if error is WindowManagementError { throw error }
            records.removeValue(forKey: token.id)
            throw error
        }
    }

    private static func isFinite(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite
    }
}
