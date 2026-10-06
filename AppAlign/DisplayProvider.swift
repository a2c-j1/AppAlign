import AppKit
import Combine
import CoreGraphics
import Foundation

private struct ScreenInput {
    let index: Int
    let screen: NSScreen
    let runtimeID: UInt32
    let uuid: UUID?
}

@MainActor
final class DisplayProvider: ObservableObject {
    @Published private(set) var snapshot: DisplaySnapshot
    private var identityResolver = DisplayIdentityResolver()
    private let injectedSnapshots: [DisplaySnapshot]?
    private var injectedSnapshotIndex = 0

    init(snapshot: DisplaySnapshot? = nil, snapshots: [DisplaySnapshot]? = nil) {
        let normalizedSnapshots = snapshots?.isEmpty == false ? snapshots : snapshot.map { [$0] }
        injectedSnapshots = normalizedSnapshots
        self.snapshot = normalizedSnapshots?.first ?? DisplaySnapshot(displays: [], primaryFrame: .zero)
        injectedSnapshotIndex = min(1, (normalizedSnapshots?.count ?? 1) - 1)
        if injectedSnapshots == nil { refresh() }
    }

    @discardableResult
    func refresh() -> DisplaySnapshot {
        if let injectedSnapshots {
            snapshot = injectedSnapshots[injectedSnapshotIndex]
            injectedSnapshotIndex = min(injectedSnapshotIndex + 1, injectedSnapshots.count - 1)
            return snapshot
        }
        let screens = NSScreen.screens
        guard let primary = screens.first else {
            snapshot = DisplaySnapshot(displays: [], primaryFrame: .zero)
            return snapshot
        }
        let primaryFrame = primary.frame
        let numberedScreens: [ScreenInput] = screens.enumerated().compactMap { index, screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let rawID = number.uint32Value
            return ScreenInput(index: index, screen: screen, runtimeID: rawID, uuid: persistentID(for: rawID)?.uuid)
        }
        let resolved = identityResolver.resolveSnapshot(numberedScreens.map {
            DisplayIdentityCandidate(runtimeID: $0.runtimeID, uuid: $0.uuid)
        })
        let displays = numberedScreens.enumerated().compactMap { offset, input -> Display? in
            let index = input.index
            let screen = input.screen
            let rawID = input.runtimeID
            guard
                let frame = try? DisplayGeometry.globalFrame(from: screen.frame, primaryFrame: primaryFrame),
                let workArea = try? DisplayGeometry.globalFrame(from: screen.visibleFrame, primaryFrame: primaryFrame)
            else { return nil }
            let identity = resolved[offset]
            return Display(
                runtimeID: RuntimeDisplayID(rawValue: rawID),
                persistentID: identity.persistentID,
                sessionID: identity.sessionID,
                name: screen.localizedName,
                frame: frame,
                workArea: workArea,
                isPrimary: index == 0,
                backingScaleFactor: screen.backingScaleFactor
            )
        }
        snapshot = DisplaySnapshot(
            displays: displays,
            primaryFrame: (try? DisplayGeometry.globalFrame(from: primaryFrame, primaryFrame: primaryFrame)) ?? .zero
        )
        return snapshot
    }

    private func persistentID(for runtimeID: UInt32) -> PersistentDisplayID? {
        guard let cgUUID = CGDisplayCreateUUIDFromDisplayID(runtimeID)?.takeRetainedValue() else { return nil }
        let uuidString = CFUUIDCreateString(nil, cgUUID) as String
        guard let uuid = UUID(uuidString: uuidString)
        else {
            return nil
        }
        return PersistentDisplayID(uuid: uuid)
    }

}
