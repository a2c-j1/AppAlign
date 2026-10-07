import CoreGraphics
import Foundation

struct KeyboardLayoutSnapshot: Equatable, Sendable {
    let display: Display
    let layout: PersistedLayout
    let zones: [Zone]
    let displayFingerprint: String
}

@MainActor
extension LayoutController {
    var keyboardZoneChoices: [ZoneID] {
        let ids = displayProvider.refresh().displays.flatMap { display in
            appliedLayoutSnapshot(for: display.frame)?.zones.map(\.id) ?? []
        }
        return Array(Set(ids)).sorted { $0.rawValue < $1.rawValue }
    }

    func appliedLayoutSnapshot(for windowFrame: CGRect) -> KeyboardLayoutSnapshot? {
        let displays = displayProvider.refresh().displays
        guard !displays.isEmpty, DisplayGeometry.isFinite(windowFrame) else { return nil }
        let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        let display = displays.sorted { lhs, rhs in
            let leftArea = windowFrame.intersection(lhs.frame).area
            let rightArea = windowFrame.intersection(rhs.frame).area
            if leftArea != rightArea { return leftArea > rightArea }
            let leftContains = lhs.frame.contains(center)
            let rightContains = rhs.frame.contains(center)
            if leftContains != rightContains { return leftContains }
            return stableDisplayKey(lhs.id) < stableDisplayKey(rhs.id)
        }.first
        guard let display, display.workArea.width > 0, display.workArea.height > 0 else { return nil }

        let layout: PersistedLayout
        if let persistentID = display.persistentID,
           let layoutID = assignments[persistentID.uuid]?.layoutID,
           let assigned = savedLayouts[layoutID] {
            layout = assigned
        } else if case .session(let sessionID) = display.id, let sessionLayout = sessionLayouts[sessionID] {
            layout = sessionLayout
        } else {
            layout = savedLayouts[PersistentStoreCoordinator.defaultLayoutID] ?? PersistentStoreCoordinator.defaultLayout()
        }
        guard let definition = try? layout.definition(),
              let zones = try? LayoutEngine.zones(for: definition, in: display.workArea, spacing: layout.spacing) else { return nil }
        return KeyboardLayoutSnapshot(
            display: display,
            layout: layout,
            zones: zones,
            displayFingerprint: displayProvider.snapshot.fingerprint
        )
    }

    func isCurrent(_ snapshot: KeyboardLayoutSnapshot, for windowFrame: CGRect) -> Bool {
        appliedLayoutSnapshot(for: windowFrame) == snapshot
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isInfinite ? 0 : max(0, width) * max(0, height) }
}

private func stableDisplayKey(_ id: DisplaySelectionID) -> String {
    switch id {
    case .persistent(let value): "p:\(value.uuid.uuidString)"
    case .session(let value): "s:\(value.uuidString)"
    }
}
