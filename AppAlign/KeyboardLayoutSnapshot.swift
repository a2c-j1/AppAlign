import CoreGraphics
import Foundation

struct KeyboardLayoutSnapshot: Equatable, Sendable {
    let display: Display
    let layout: PersistedLayout
    let zones: [Zone]
    let displayFingerprint: String
    let displayLayouts: [KeyboardDisplayLayout]
    let revision: PlacementRevision

    static func == (lhs: KeyboardLayoutSnapshot, rhs: KeyboardLayoutSnapshot) -> Bool {
        lhs.display == rhs.display && lhs.layout == rhs.layout && lhs.zones == rhs.zones
            && lhs.displayFingerprint == rhs.displayFingerprint && lhs.displayLayouts == rhs.displayLayouts
    }
}

@MainActor
extension LayoutController {
    var keyboardZoneChoices: [ZoneID] {
        let ids = refreshDisplays().displays.flatMap { display in layoutValues(for: display)?.zones.map(\.id) ?? [] }
        return Array(Set(ids)).sorted { $0.rawValue < $1.rawValue }
    }

    func appliedLayoutSnapshot(for windowFrame: CGRect) -> KeyboardLayoutSnapshot? {
        let displays = refreshDisplays().displays
        guard placementValidity.isAccepting, !displays.isEmpty, DisplayGeometry.isFinite(windowFrame) else { return nil }
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
        guard let display else { return nil }
        return snapshot(for: display, displays: displays)
    }

    func appliedLayoutSnapshot(for display: Display) -> KeyboardLayoutSnapshot? {
        let displays = refreshDisplays().displays
        guard placementValidity.isAccepting else { return nil }
        return snapshot(for: display, displays: displays)
    }

    func appliedLayoutSnapshot(for display: Display, in frozenSnapshot: DisplaySnapshot,
                               revision: PlacementRevision) -> KeyboardLayoutSnapshot? {
        guard placementValidity.isAccepting, placementValidity.revision == revision,
              displayProvider.snapshot.fingerprint == frozenSnapshot.fingerprint else { return nil }
        return snapshot(for: display, displays: frozenSnapshot.displays, revision: revision,
                        fingerprint: frozenSnapshot.fingerprint)
    }

    private func snapshot(for display: Display, displays: [Display]) -> KeyboardLayoutSnapshot? {
        snapshot(for: display, displays: displays, revision: placementValidity.revision,
                 fingerprint: displayProvider.snapshot.fingerprint)
    }

    private func snapshot(for display: Display, displays: [Display], revision: PlacementRevision,
                          fingerprint: String) -> KeyboardLayoutSnapshot? {
        guard let selected = layoutValues(for: display) else { return nil }
        let layouts = displays.compactMap { candidate -> KeyboardDisplayLayout? in
            guard let values = layoutValues(for: candidate) else { return nil }
            return KeyboardDisplayLayout(display: candidate, layout: values.layout, zones: values.zones)
        }
        return KeyboardLayoutSnapshot(display: display, layout: selected.layout, zones: selected.zones,
                                      displayFingerprint: fingerprint, displayLayouts: layouts, revision: revision)
    }

    private func layoutValues(for display: Display) -> (layout: PersistedLayout, zones: [Zone])? {
        guard display.workArea.width > 0, display.workArea.height > 0 else { return nil }
        let layout: PersistedLayout
        if let override = quickLayoutOverrides[display.id] {
            layout = override
        } else if let persistentID = display.persistentID,
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
        return (layout, zones)
    }

    func isCurrent(_ snapshot: KeyboardLayoutSnapshot, for windowFrame: CGRect) -> Bool {
        guard placementValidity.revision == snapshot.revision,
              let current = appliedLayoutSnapshot(for: windowFrame) else { return false }
        return placementValidity.revision == snapshot.revision && current == snapshot
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
