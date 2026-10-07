/*
The geometric candidate score is adapted from FancyZonesLib/util.cpp,
ChooseNextZoneByPosition, PowerToys commit 1400fd8e999f381329e16e9df4084f7dc588c8a7:
https://github.com/microsoft/PowerToys/blob/1400fd8e999f381329e16e9df4084f7dc588c8a7/src/modules/fancyzones/FancyZonesLib/util.cpp

Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the MIT License:

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

import CoreGraphics
import Foundation

enum NavigationMode: String, CaseIterable, Sendable {
    case zoneOrder
    case position
}

enum NavigationDirection: String, CaseIterable, Sendable {
    case left
    case right
    case north = "up"
    case south = "down"

    var vector: CGVector {
        switch self {
        case .left: CGVector(dx: -1, dy: 0)
        case .right: CGVector(dx: 1, dy: 0)
        case .north: CGVector(dx: 0, dy: -1)
        case .south: CGVector(dx: 0, dy: 1)
        }
    }

    var isHorizontal: Bool { self == .left || self == .right }

    var opposite: NavigationDirection {
        switch self {
        case .left: .right
        case .right: .left
        case .north: .south
        case .south: .north
        }
    }
}

enum KeyboardSnapAction: Hashable, Sendable {
    case zone(ZoneID)
    case next
    case previous
    case direction(NavigationDirection)
    case restore
}

struct ZoneNavigationRequest {
    let mode: NavigationMode
    let currentID: ZoneID?
    let currentFrame: CGRect
    let zones: [Zone]
    let workArea: CGRect
    let cycle: Bool
}

enum ZoneNavigator {
    static func resolvedCurrentID(_ id: ZoneID?, frame: CGRect, zones: [Zone]) -> ZoneID? {
        resolveCurrentID(id, frame: frame, zones: zones)
    }

    static func orderedZones(_ zones: [Zone]) -> [Zone] {
        zones.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    static func adjacentZone(
        from currentID: ZoneID?,
        zones: [Zone],
        direction: NavigationDirection,
        cycle: Bool
    ) -> Zone? {
        let ordered = orderedZones(zones)
        guard !ordered.isEmpty else { return nil }
        guard let currentID, let index = ordered.firstIndex(where: { $0.id == currentID }) else {
            return direction == .right || direction == .south ? ordered.first : ordered.last
        }

        let offset = direction == .right || direction == .south ? 1 : -1
        let next = index + offset
        if ordered.indices.contains(next) { return ordered[next] }
        return cycle ? (offset > 0 ? ordered.first : ordered.last) : nil
    }

    static func zone(for action: KeyboardSnapAction, request: ZoneNavigationRequest) -> Zone? {
        let mode = request.mode
        let currentID = request.currentID
        let currentFrame = request.currentFrame
        let zones = request.zones
        let workArea = request.workArea
        let cycle = request.cycle
        switch action {
        case .zone(let id):
            return zones.first { $0.id == id }
        case .next, .previous:
            let direction: NavigationDirection = action == .next ? .right : .left
            switch mode {
            case .zoneOrder:
                let validCurrentID = resolveCurrentID(currentID, frame: currentFrame, zones: zones)
                return adjacentZone(from: validCurrentID, zones: zones, direction: direction, cycle: cycle)
            case .position:
                return directionalZone(from: currentFrame, zones: zones, direction: direction, workArea: workArea, cycle: cycle, excludingID: resolveCurrentID(currentID, frame: currentFrame, zones: zones))
            }
        case .direction(let direction):
            switch mode {
            case .zoneOrder:
                guard direction.isHorizontal else { return nil }
                let validCurrentID = resolveCurrentID(currentID, frame: currentFrame, zones: zones)
                return adjacentZone(from: validCurrentID, zones: zones, direction: direction, cycle: cycle)
            case .position:
                let validCurrentID = resolveCurrentID(currentID, frame: currentFrame, zones: zones)
                return directionalZone(
                    from: currentFrame,
                    zones: zones,
                    direction: direction,
                    workArea: workArea,
                    cycle: cycle,
                    excludingID: validCurrentID
                )
            }
        case .restore:
            return nil
        }
    }

    static func directionalZone(
        from frame: CGRect,
        zones: [Zone],
        direction: NavigationDirection,
        workArea: CGRect,
        cycle: Bool,
        excludingID: ZoneID? = nil
    ) -> Zone? {
        guard isFinite(frame), frame.width >= 0, frame.height >= 0,
              isFinite(workArea), workArea.width > 0, workArea.height > 0 else { return nil }
        let source = CGPoint(x: frame.midX, y: frame.midY)
        if let result = nearestZone(from: source, zones: zones, direction: direction, excludingID: excludingID) { return result }
        guard cycle else { return nil }

        let shift: CGFloat
        switch direction {
        case .left: shift = workArea.width
        case .right: shift = -workArea.width
        case .north: shift = workArea.height
        case .south: shift = -workArea.height
        }
        let wrappedSource: CGPoint
        if direction.isHorizontal {
            wrappedSource = CGPoint(x: source.x + shift, y: source.y)
        } else {
            wrappedSource = CGPoint(x: source.x, y: source.y + shift)
        }
        guard let wrapped = nearestZone(from: wrappedSource, zones: zones, direction: direction, excludingID: excludingID) else { return nil }
        let wrappedCenter = CGPoint(x: wrapped.frame.midX, y: wrapped.frame.midY)
        return wrappedCenter == source ? nil : wrapped
    }

    private static func nearestZone(
        from source: CGPoint,
        zones: [Zone],
        direction: NavigationDirection,
        excludingID: ZoneID?
    ) -> Zone? {
        let vector = direction.vector
        let candidates = zones.compactMap { zone -> (Zone, CGFloat)? in
            guard zone.id != excludingID, isFinite(zone.frame), zone.frame.width > 0, zone.frame.height > 0 else { return nil }
            let target = CGPoint(x: zone.frame.midX, y: zone.frame.midY)
            let deltaX = target.x - source.x
            let deltaY = target.y - source.y
            guard deltaX.isFinite, deltaY.isFinite else { return nil }
            let along = deltaX * vector.dx + deltaY * vector.dy
            let across = abs(deltaX * vector.dy - deltaY * vector.dx)
            guard along > 0, across / along <= 10 else { return nil }
            let ratio = across / along
            let score = along * (1 + 4 * ratio * ratio) / 4
            guard score.isFinite else { return nil }
            return (zone, score)
        }
        return candidates.min { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.id.rawValue < rhs.0.id.rawValue : lhs.1 < rhs.1
        }?.0
    }

    private static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
    }

    private static func resolveCurrentID(_ id: ZoneID?, frame: CGRect, zones: [Zone]) -> ZoneID? {
        if let id, let zone = zones.first(where: { $0.id == id }), framesMatch(zone.frame, frame) { return id }
        return orderedZones(zones).first(where: { framesMatch($0.frame, frame) })?.id
    }

    private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        isFinite(lhs) && isFinite(rhs)
            && abs(lhs.midX - rhs.midX) <= 2
            && abs(lhs.midY - rhs.midY) <= 2
            && abs(lhs.width - rhs.width) <= 2
            && abs(lhs.height - rhs.height) <= 2
    }
}
