import CoreGraphics
import Foundation

struct ZoneAddress: Hashable, Sendable {
    let workArea: WorkAreaKey
    let zoneID: ZoneID
}

struct KeyboardDisplayLayout: Equatable, Sendable {
    let display: Display
    let layout: PersistedLayout
    let zones: [Zone]
}

struct MultiDisplayNavigationRequest {
    let mode: NavigationMode
    let currentAddress: ZoneAddress?
    let currentDisplay: DisplaySelectionID
    let currentFrame: CGRect
    let displays: [KeyboardDisplayLayout]
    let cycle: Bool
}

enum MultiDisplayNavigator {
    static func zone(for action: KeyboardSnapAction, request: MultiDisplayNavigationRequest) -> (ZoneAddress, Zone)? {
        guard let current = request.displays.first(where: { $0.display.id == request.currentDisplay }) else { return nil }
        if case .zone(let id) = action {
            guard let zone = current.zones.first(where: { $0.id == id }) else { return nil }
            return (ZoneAddress(workArea: current.display.selectionKey, zoneID: id), zone)
        }
        guard case .restore = action else {
            switch request.mode {
            case .zoneOrder: return zoneOrderTarget(action, request: request, current: current)
            case .position: return positionTarget(action, request: request, current: current)
            }
        }
        return nil
    }

    private static func zoneOrderTarget(_ action: KeyboardSnapAction, request: MultiDisplayNavigationRequest,
                                        current: KeyboardDisplayLayout) -> (ZoneAddress, Zone)? {
        let direction: NavigationDirection
        switch action {
        case .next: direction = .right
        case .previous: direction = .left
        case .direction(let value):
            guard value.isHorizontal else { return nil }
            direction = value
        default: return nil
        }
        let localID = request.currentAddress.flatMap { $0.workArea == current.display.selectionKey ? $0.zoneID : nil }
        if let local = ZoneNavigator.adjacentZone(from: localID, zones: current.zones,
                                                  direction: direction, cycle: false) {
            return (ZoneAddress(workArea: current.display.selectionKey, zoneID: local.id), local)
        }
        let displays = request.displays.sorted(by: displayOrder)
        guard let currentIndex = displays.firstIndex(where: { $0.display.id == current.display.id }) else { return nil }
        let step = direction == .right ? 1 : -1
        var index = currentIndex + step
        while displays.indices.contains(index) {
            let candidate = displays[index]
            let zones = ZoneNavigator.orderedZones(candidate.zones)
            if let zone = step > 0 ? zones.first : zones.last {
                return (ZoneAddress(workArea: candidate.display.selectionKey, zoneID: zone.id), zone)
            }
            index += step
        }
        guard request.cycle else { return nil }
        index = step > 0 ? 0 : displays.count - 1
        while displays.indices.contains(index) {
            let candidate = displays[index]
            let zones = ZoneNavigator.orderedZones(candidate.zones)
            if let zone = step > 0 ? zones.first : zones.last {
                return (ZoneAddress(workArea: candidate.display.selectionKey, zoneID: zone.id), zone)
            }
            index += step
        }
        return nil
    }

    private static func positionTarget(_ action: KeyboardSnapAction, request: MultiDisplayNavigationRequest,
                                       current: KeyboardDisplayLayout) -> (ZoneAddress, Zone)? {
        let direction: NavigationDirection
        switch action {
        case .next: direction = .right
        case .previous: direction = .left
        case .direction(let value): direction = value
        default: return nil
        }
        let currentID = request.currentAddress.flatMap { $0.workArea == current.display.selectionKey ? $0.zoneID : nil }
        if let local = ZoneNavigator.directionalZone(from: request.currentFrame, zones: current.zones,
                                                     direction: direction, workArea: current.display.workArea,
                                                     cycle: false, excludingID: currentID) {
            return (ZoneAddress(workArea: current.display.selectionKey, zoneID: local.id), local)
        }
        let displays = request.displays.sorted(by: displayOrder)
        let candidates = candidateZones(in: displays.filter { $0.display.id != current.display.id }, excluding: request.currentAddress)
        if let target = bestCandidate(from: request.currentFrame, candidates: candidates, direction: direction) {
            return target
        }
        guard request.cycle else { return nil }
        let allCandidates = candidateZones(in: displays, excluding: request.currentAddress)
        return wrappedCandidate(request, displays: displays, candidates: allCandidates, direction: direction)
    }

    private static func candidateZones(in displays: [KeyboardDisplayLayout], excluding address: ZoneAddress?) -> [(ZoneAddress, Zone)] {
        displays.flatMap { display in
            display.zones.filter { ZoneAddress(workArea: display.display.selectionKey, zoneID: $0.id) != address }
                .map { (ZoneAddress(workArea: display.display.selectionKey, zoneID: $0.id), $0) }
        }
    }

    private static func wrappedCandidate(_ request: MultiDisplayNavigationRequest,
                                         displays: [KeyboardDisplayLayout], candidates: [(ZoneAddress, Zone)],
                                         direction: NavigationDirection) -> (ZoneAddress, Zone)? {
        let workAreas = displays.map { $0.display.workArea }
        guard let union = workAreas.dropFirst().reduce(workAreas.first, { $0?.union($1) }),
              union.width > 0, union.height > 0 else { return nil }
        let offset: CGFloat
        switch direction {
        case .left: offset = union.width
        case .right: offset = -union.width
        case .north: offset = union.height
        case .south: offset = -union.height
        }
        let point = direction.isHorizontal
            ? CGPoint(x: request.currentFrame.midX + offset, y: request.currentFrame.midY)
            : CGPoint(x: request.currentFrame.midX, y: request.currentFrame.midY + offset)
        let frame = CGRect(x: point.x, y: point.y, width: 0, height: 0)
        return bestCandidate(from: frame, candidates: candidates, direction: direction)
    }

    private static func bestCandidate(from frame: CGRect, candidates: [(ZoneAddress, Zone)],
                                      direction: NavigationDirection) -> (ZoneAddress, Zone)? {
        let source = CGPoint(x: frame.midX, y: frame.midY)
        return candidates.compactMap { address, zone -> ((ZoneAddress, Zone), CGFloat)? in
            guard zone.frame.width > 0, zone.frame.height > 0,
                  zone.frame.minX.isFinite, zone.frame.minY.isFinite else { return nil }
            guard let score = ZoneNavigator.directionalScore(
                from: source, to: CGPoint(x: zone.frame.midX, y: zone.frame.midY), direction: direction
            ) else { return nil }
            return ((address, zone), score)
        }.min { lhs, rhs in
            lhs.1 == rhs.1 ? addressOrder(lhs.0.0, rhs.0.0) : lhs.1 < rhs.1
        }?.0
    }

    private static func displayOrder(_ lhs: KeyboardDisplayLayout, _ rhs: KeyboardDisplayLayout) -> Bool {
        if lhs.display.frame.minY != rhs.display.frame.minY { return lhs.display.frame.minY < rhs.display.frame.minY }
        if lhs.display.frame.minX != rhs.display.frame.minX { return lhs.display.frame.minX < rhs.display.frame.minX }
        return displayKey(lhs.display.id) < displayKey(rhs.display.id)
    }

    private static func addressOrder(_ lhs: ZoneAddress, _ rhs: ZoneAddress) -> Bool {
        if displayKey(lhs.workArea.display) != displayKey(rhs.workArea.display) {
            return displayKey(lhs.workArea.display) < displayKey(rhs.workArea.display)
        }
        return lhs.zoneID.rawValue < rhs.zoneID.rawValue
    }

    private static func displayKey(_ id: DisplaySelectionID) -> String {
        switch id {
        case .persistent(let value): "p:\(value.uuid.uuidString)"
        case .session(let value): "s:\(value.uuidString)"
        }
    }
}
