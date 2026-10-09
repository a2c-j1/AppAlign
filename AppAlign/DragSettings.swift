import Foundation

struct DragSettings: Equatable, Sendable {
    var requireShift = true
    var toggleButton: Int?
    var selectionRadius = 20.0

    static let knownButtons: Set<Int> = [1, 2, 3, 4]
    static let managedKeys: Set<String> = ["drag.requireShift", "drag.toggleButton", "drag.selectionRadius"]

    static func decode(from values: [String: PersistedSetting]) -> DragSettings {
        var result = DragSettings()
        if case .bool(let value) = values["drag.requireShift"] { result.requireShift = value }
        if case .integer(let value) = values["drag.toggleButton"], knownButtons.contains(value) {
            result.toggleButton = value
        }
        if case .number(let value) = values["drag.selectionRadius"], value.isFinite, (0 ... 80).contains(value) {
            result.selectionRadius = value
        }
        return result
    }

    func applying(to values: [String: PersistedSetting]) -> [String: PersistedSetting] {
        var result = values
        result["drag.requireShift"] = .bool(requireShift)
        if let toggleButton, Self.knownButtons.contains(toggleButton) {
            result["drag.toggleButton"] = .integer(toggleButton)
        } else {
            result.removeValue(forKey: "drag.toggleButton")
        }
        result["drag.selectionRadius"] = .number(selectionRadius)
        return result
    }
}

struct ZoneSelectionEngine {
    static func select(point: CGPoint, zones: [Zone], workArea: CGRect, radius: CGFloat) -> Zone? {
        guard point.x.isFinite, point.y.isFinite, DisplayGeometry.isFinite(workArea),
              workArea.width > 0, workArea.height > 0, radius.isFinite, radius >= 0,
              point.x >= workArea.minX, point.x < workArea.maxX,
              point.y >= workArea.minY, point.y < workArea.maxY else { return nil }
        let valid = zones.filter { DisplayGeometry.isFinite($0.frame) && $0.frame.width > 0 && $0.frame.height > 0 }
        guard let bounds = valid.map(\.frame).reduce(nil as CGRect?, { accumulated, frame in
            accumulated.map { $0.union(frame) } ?? frame
        }),
              point.x >= bounds.minX, point.x <= bounds.maxX,
              point.y >= bounds.minY, point.y <= bounds.maxY else { return nil }
        let strict = valid.filter { containsHalfOpen($0.frame, point) }
        if strict.isEmpty, radius == 0 { return nil }
        let expanded = strict.isEmpty ? valid.filter { expandedContains($0.frame, point, radius: radius) } : []
        if strict.isEmpty, expanded.count == 1 { return nil }
        let candidates = strict.isEmpty ? expanded : strict
        return candidates.enumerated().min { leftEntry, rightEntry in
            let lhs = leftEntry.element
            let rhs = rightEntry.element
            let left = centerDistanceSquared(point, lhs.frame)
            let right = centerDistanceSquared(point, rhs.frame)
            if left != right { return left < right }
            return leftEntry.offset < rightEntry.offset
        }?.element
    }

    private static func containsHalfOpen(_ rect: CGRect, _ point: CGPoint) -> Bool {
        point.x >= rect.minX && point.x < rect.maxX && point.y >= rect.minY && point.y < rect.maxY
    }

    private static func expandedContains(_ rect: CGRect, _ point: CGPoint, radius: CGFloat) -> Bool {
        point.x >= rect.minX - radius && point.x <= rect.maxX + radius &&
            point.y >= rect.minY - radius && point.y <= rect.maxY + radius
    }

    private static func centerDistanceSquared(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let deltaX = point.x - rect.midX
        let deltaY = point.y - rect.midY
        return deltaX * deltaX + deltaY * deltaY
    }
}
