import CoreGraphics
import Foundation

struct DragLayoutSnapshot: Equatable, Sendable {
    let display: Display
    let displays: [Display]
    let primaryFrame: CGRect
    let workAreaKey: WorkAreaKey
    let layout: PersistedLayout
    let zones: [Zone]
    let fingerprint: String
    let revision: UInt64
}

@MainActor
extension LayoutController {
    func invalidateAppliedDragLayout() {
        dragLayoutRevision &+= 1
        invalidateDragCommit?()
    }

    func appliedDragLayoutSnapshot(at point: CGPoint) -> DragLayoutSnapshot? {
        let snapshot = refreshDisplaysForDrag()
        guard let display = snapshot.displays.first(where: { $0.frame.contains(point) }),
              display.workArea.width > 0, display.workArea.height > 0 else { return nil }
        guard let resolved = appliedLayoutSnapshot(for: display) else { return nil }
        return DragLayoutSnapshot(display: display, displays: snapshot.displays, primaryFrame: snapshot.primaryFrame,
                                  workAreaKey: display.selectionKey, layout: resolved.layout, zones: resolved.zones,
                                  fingerprint: snapshot.fingerprint, revision: dragLayoutRevision)
    }

    func isCurrentDragLayout(revision: UInt64, fingerprint: String) -> Bool {
        _ = refreshDisplaysForDrag()
        return revision == dragLayoutRevision && fingerprint == displayProvider.snapshot.fingerprint
    }

    private func refreshDisplaysForDrag() -> DisplaySnapshot {
        let updated = displayProvider.refresh()
        if let previous = lastDragDisplaySnapshot, previous != updated {
            invalidateAppliedDragLayout()
        }
        lastDragDisplaySnapshot = updated
        return updated
    }
}
