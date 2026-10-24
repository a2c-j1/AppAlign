import Foundation

@MainActor
extension LayoutController {
    var selectedDisplay: Display? {
        displayProvider.snapshot.displays.first { $0.id == selectedDisplayID }
    }

    @discardableResult
    func refreshDisplays(force: Bool = false) -> DisplaySnapshot {
        if let refreshConfiguration { return refreshConfiguration(force) }
        let result = displayProvider.sample()
        if result != displayProvider.snapshot {
            displayProvider.publish(result)
            displaysDidPublish(result)
        }
        return result
    }
}
