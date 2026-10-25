import CoreGraphics
import Foundation

struct DragLayoutSnapshot: Equatable, Sendable {
    let display: Display
    let displays: [Display]
    let primaryFrame: CGRect
    let workAreaKey: WorkAreaKey
    let layout: PersistedLayout
    let zones: [Zone]
    let zonesByDisplay: [DisplaySelectionID: [Zone]]
    let fingerprint: String
    let revision: UInt64
    let placementRevision: PlacementRevision
    let spaceSnapshot: DisplaySpaceSnapshot
}

@MainActor
extension LayoutController {
    func invalidateAppliedDragLayout() {
        cancelAutomaticRestores?()
        dragLayoutRevision &+= 1
        placementValidity.invalidateForLayoutChange()
        invalidateDragCommit?()
    }

    func appliedDragLayoutSnapshot(at point: CGPoint) -> DragLayoutSnapshot? {
        let snapshot = refreshDisplaysForDrag()
        let revision = placementValidity.revision
        guard placementValidity.isAccepting else { return nil }
        let candidates = snapshot.displays.filter {
            containsHalfOpen($0.frame, point) && containsHalfOpen($0.workArea, point)
                && $0.workArea.width > 0 && $0.workArea.height > 0
        }.sorted { lhs, rhs in
            let leftPrevious = lhs.id == lastDragCursorDisplayID
            let rightPrevious = rhs.id == lastDragCursorDisplayID
            if leftPrevious != rightPrevious { return leftPrevious }
            if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
            return stableDisplayKey(lhs.id) < stableDisplayKey(rhs.id)
        }
        guard let display = candidates.first else { return nil }
        lastDragCursorDisplayID = display.id
        guard let resolved = appliedLayoutSnapshot(for: display, in: snapshot, revision: revision) else { return nil }
        let zonesByDisplay: [DisplaySelectionID: [Zone]] = Dictionary(uniqueKeysWithValues: snapshot.displays.compactMap { candidate in
            guard let applied = appliedLayoutSnapshot(for: candidate, in: snapshot, revision: revision) else { return nil }
            return (candidate.id, applied.zones)
        })
        guard placementValidity.isAccepting, placementValidity.revision == revision,
              displayProvider.snapshot.fingerprint == snapshot.fingerprint else { return nil }
        return DragLayoutSnapshot(display: display, displays: snapshot.displays, primaryFrame: snapshot.primaryFrame,
                                  workAreaKey: display.selectionKey, layout: resolved.layout, zones: resolved.zones,
                                  zonesByDisplay: zonesByDisplay,
                                  fingerprint: snapshot.fingerprint, revision: dragLayoutRevision,
                                  placementRevision: revision, spaceSnapshot: resolved.spaceSnapshot)
    }

    func isCurrentDragLayout(revision: UInt64, fingerprint: String) -> Bool {
        _ = refreshDisplaysForDrag()
        return revision == dragLayoutRevision && fingerprint == displayProvider.snapshot.fingerprint
    }

    private func refreshDisplaysForDrag() -> DisplaySnapshot {
        let updated = refreshDisplays()
        lastDragDisplaySnapshot = updated
        return updated
    }

    private func containsHalfOpen(_ rect: CGRect, _ point: CGPoint) -> Bool {
        point.x >= rect.minX && point.x < rect.maxX && point.y >= rect.minY && point.y < rect.maxY
    }
}

private func stableDisplayKey(_ id: DisplaySelectionID) -> String {
    switch id {
    case .persistent(let value): "p:\(value.uuid.uuidString)"
    case .session(let value): "s:\(value.uuidString)"
    }
}
