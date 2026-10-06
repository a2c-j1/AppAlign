import Combine
import CoreGraphics
import Foundation

@MainActor
final class LayoutController: ObservableObject {
    let displayProvider: DisplayProvider
    @Published var template: LayoutTemplate = .grid { didSet { recalculate() } }
    @Published var zoneCount = 4 { didSet { recalculate() } }
    @Published var spacing: Double = 10 { didSet { recalculate() } }
    @Published private(set) var selectedDisplayID: DisplaySelectionID?
    @Published private(set) var zones: [Zone] = []
    @Published var selectedZoneID: ZoneID?
    @Published private(set) var errorMessage: String?
    private var zonesDisplayFingerprint: String?

    init(displayProvider: DisplayProvider = DisplayProvider()) {
        self.displayProvider = displayProvider
        selectedDisplayID = displayProvider.snapshot.displays.first(where: \.isPrimary)?.id
        recalculate()
    }

    var selectedDisplay: Display? {
        displayProvider.snapshot.displays.first { $0.id == selectedDisplayID }
    }

    func selectDisplay(_ id: DisplaySelectionID) {
        selectedDisplayID = id
        recalculate()
    }

    @discardableResult
    func refreshDisplays() -> DisplaySnapshot {
        let result = displayProvider.refresh()
        if !result.displays.contains(where: { $0.id == selectedDisplayID }) {
            selectedDisplayID = result.displays.first(where: \.isPrimary)?.id
        }
        recalculate()
        return result
    }

    func recalculate() {
        guard let display = selectedDisplay else {
            zones = []
            selectedZoneID = nil
            zonesDisplayFingerprint = nil
            errorMessage = "No display is available."
            return
        }
        do {
            zonesDisplayFingerprint = displayProvider.snapshot.fingerprint
            let definition = try LayoutTemplates.definition(for: template, zoneCount: zoneCount, area: display.workArea, spacing: spacing)
            zones = try LayoutEngine.zones(
                for: definition,
                in: display.workArea,
                spacing: spacing
            )
            if !zones.contains(where: { $0.id == selectedZoneID }) {
                selectedZoneID = zones.first?.id
            }
            errorMessage = nil
        } catch {
            zones = []
            selectedZoneID = nil
            errorMessage = error.localizedDescription
        }
    }

    func placeSelectedZone(using placementController: PlacementController) {
        guard let zone = zones.first(where: { $0.id == selectedZoneID }) else { return }
        let zonesFingerprint = zonesDisplayFingerprint
        _ = refreshDisplays()
        guard selectedDisplay != nil else { return }
        guard zonesFingerprint == displayProvider.snapshot.fingerprint else {
            errorMessage = WindowManagementError.displayConfigurationChanged.localizedDescription
            return
        }
        do {
            try placementController.placeCapturedWindow(
                in: zone.frame,
                displayFingerprint: zonesFingerprint ?? ""
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
