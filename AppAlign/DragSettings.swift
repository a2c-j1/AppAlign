import CoreGraphics
import Foundation

struct DragSettings: Equatable, Sendable {
    var requireShift = true
    var toggleButton: Int?
    var selectionRadius = 20.0
    var rangeModifier: RangeSelectionModifier = .option
    var overlapStrategy: ZoneOverlapStrategy = .smallest

    static let knownButtons: Set<Int> = [1, 2, 3, 4]
    static let managedKeys: Set<String> = ["drag.requireShift", "drag.toggleButton", "drag.selectionRadius", "drag.rangeModifier", "drag.overlapStrategy"]

    static func decode(from values: [String: PersistedSetting]) -> DragSettings {
        var result = DragSettings()
        if case .bool(let value) = values["drag.requireShift"] { result.requireShift = value }
        if case .integer(let value) = values["drag.toggleButton"], knownButtons.contains(value) {
            result.toggleButton = value
        }
        if case .number(let value) = values["drag.selectionRadius"], value.isFinite, (0 ... 80).contains(value) {
            result.selectionRadius = value
        }
        if case .string(let value) = values["drag.rangeModifier"], let modifier = RangeSelectionModifier(rawValue: value) {
            result.rangeModifier = modifier
        }
        if case .string(let value) = values["drag.overlapStrategy"], let strategy = ZoneOverlapStrategy(rawValue: value) {
            result.overlapStrategy = strategy
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
        result["drag.rangeModifier"] = .string(rangeModifier.rawValue)
        result["drag.overlapStrategy"] = .string(overlapStrategy.rawValue)
        return result
    }
}

enum RangeSelectionModifier: String, CaseIterable, Sendable {
    case shift
    case control
    case option
    case command

    var eventFlag: UInt64 {
        switch self {
        case .shift: CGEventFlags.maskShift.rawValue
        case .control: CGEventFlags.maskControl.rawValue
        case .option: CGEventFlags.maskAlternate.rawValue
        case .command: CGEventFlags.maskCommand.rawValue
        }
    }
}

enum ZoneOverlapStrategy: String, CaseIterable, Sendable {
    case smallest
    case largest
    case positional
    case closestCenter
}

struct ZoneSelectionEngine {
    static func selectZones(point: CGPoint, zones: [Zone], workArea: CGRect, radius: CGFloat,
                            strategy: ZoneOverlapStrategy = .smallest) -> [Zone] {
        guard point.x.isFinite, point.y.isFinite, DisplayGeometry.isFinite(workArea),
              workArea.width > 0, workArea.height > 0, radius.isFinite, radius >= 0,
              point.x >= workArea.minX, point.x < workArea.maxX,
              point.y >= workArea.minY, point.y < workArea.maxY else { return [] }
        let valid = zones.filter { DisplayGeometry.isFinite($0.frame) && $0.frame.width > 0 && $0.frame.height > 0 }
        guard let bounds = valid.map(\.frame).reduce(nil as CGRect?, { accumulated, frame in
            accumulated.map { $0.union(frame) } ?? frame
        }),
              point.x >= bounds.minX, point.x <= bounds.maxX,
              point.y >= bounds.minY, point.y <= bounds.maxY else { return [] }
        let strict = valid.filter { containsHalfOpen($0.frame, point) }
        let candidates: [Zone]
        if strict.isEmpty {
            guard radius > 0 else { return [] }
            let expanded = valid.filter { expandedContains($0.frame, point, radius: radius) }
            guard expanded.count > 1 else { return [] }
            candidates = expanded
        } else {
            candidates = strict
        }
        guard candidates.count > 1 else { return candidates }
        let overlaps = candidates.indices.contains { leftIndex in
            candidates.indices.contains { rightIndex in
                guard rightIndex > leftIndex else { return false }
                let intersection = candidates[leftIndex].frame.intersection(candidates[rightIndex].frame)
                return !intersection.isNull && intersection.width > radius && intersection.height > radius
            }
        }
        guard overlaps else { return candidates }
        switch strategy {
        case .smallest:
            return [candidates.dropFirst().reduce(candidates[0]) { best, zone in
                zone.frame.width * zone.frame.height < best.frame.width * best.frame.height ? zone : best
            }]
        case .largest:
            return [candidates.dropFirst().reduce(candidates[0]) { best, zone in
                zone.frame.width * zone.frame.height > best.frame.width * best.frame.height ? zone : best
            }]
        case .closestCenter:
            return [closestCandidate(point: point, candidates: candidates)]
        case .positional:
            let expansion = radius / 2
            let intersection = candidates.dropFirst().reduce(expanded(candidates[0].frame, by: expansion)) { result, zone in
                result.intersection(expanded(zone.frame, by: expansion))
            }
            guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return candidates }
            let horizontal = intersection.width >= intersection.height
            let rawDimension = horizontal ? intersection.width : intersection.height
            let dimension = max(CGFloat(1), rawDimension)
            let band = dimension / CGFloat(candidates.count)
            let coordinate = horizontal ? point.x - intersection.minX : point.y - intersection.minY
            let index = coordinate >= dimension ? candidates.count - 1 : min(candidates.count - 1, max(0, Int(floor(coordinate / band))))
            return [candidates[index]]
        }
    }

    static func range(anchor: [Zone], current: [Zone], zones: [Zone]) -> [Zone] {
        guard let anchorBounds = union(of: anchor.map(\.frame)),
              let currentBounds = union(of: current.map(\.frame)) else { return [] }
        let selectionBounds = anchorBounds.union(currentBounds)
        return zones.filter { zone in
            DisplayGeometry.isFinite(zone.frame) && zone.frame.width > 0 && zone.frame.height > 0 &&
                zone.frame.minX >= selectionBounds.minX && zone.frame.maxX <= selectionBounds.maxX &&
                zone.frame.minY >= selectionBounds.minY && zone.frame.maxY <= selectionBounds.maxY
        }
    }

    static func union(of frames: [CGRect]) -> CGRect? {
        frames.reduce(nil as CGRect?) { accumulated, frame in
            guard DisplayGeometry.isFinite(frame), frame.width > 0, frame.height > 0 else { return accumulated }
            return accumulated.map { $0.union(frame) } ?? frame
        }
    }

    private static func closestCandidate(point: CGPoint, candidates: [Zone]) -> Zone {
        // The prioritized center-distance comparison is adapted from FancyZonesLib/util.cpp.
        var best = candidates[0]
        for zone in candidates.dropFirst() {
            let centerDeltaX = best.frame.midX - zone.frame.midX
            let centerDeltaY = best.frame.midY - zone.frame.midY
            if centerDeltaX * centerDeltaX + centerDeltaY * centerDeltaY > 75 {
                if centerDistanceSquared(point, zone.frame) < centerDistanceSquared(point, best.frame) { best = zone }
            } else {
                let bestArea = best.frame.width * best.frame.height
                let area = zone.frame.width * zone.frame.height
                if area < bestArea { best = zone }
            }
        }
        return best
    }

    private static func expanded(_ frame: CGRect, by amount: CGFloat) -> CGRect {
        frame.insetBy(dx: -amount, dy: -amount)
    }

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
