import CoreGraphics

extension KeyboardSnapController {
    static func resolvedCurrentAddress(_ address: ZoneAddress?, frame: CGRect,
                                       displays: [KeyboardDisplayLayout]) -> ZoneAddress? {
        if let address,
           let display = displays.first(where: { $0.display.selectionKey == address.workArea }),
           let zone = display.zones.first(where: { $0.id == address.zoneID }),
           framesMatch(zone.frame, frame) { return address }
        let matches = displays.flatMap { display in
            display.zones.filter { framesMatch($0.frame, frame) }
                .map { ZoneAddress(workArea: display.display.selectionKey, zoneID: $0.id) }
        }
        return matches.sorted {
            let left = String(describing: $0.workArea.display)
            let right = String(describing: $1.workArea.display)
            return left == right ? $0.zoneID.rawValue < $1.zoneID.rawValue : left < right
        }.first
    }

    static func matches(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        [lhs.minX - rhs.minX, lhs.minY - rhs.minY, lhs.width - rhs.width, lhs.height - rhs.height]
            .allSatisfy { $0.isFinite && abs($0) <= 2 }
    }

    static func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool { matches(lhs, rhs) }

}
