import AppKit

@MainActor
struct WorkspaceNewWindowProcessProvider: NewWindowProcessProviding {
    func runningApplications() -> [MonitoredApplication] {
        NSWorkspace.shared.runningApplications.map(Self.valueForNotification)
    }

    func application(processID: pid_t) -> MonitoredApplication? {
        NSRunningApplication(processIdentifier: processID).map(Self.valueForNotification)
    }

    nonisolated static func valueForNotification(_ app: NSRunningApplication) -> MonitoredApplication {
        MonitoredApplication(pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                             launchDate: app.launchDate, isTerminated: app.isTerminated)
    }
}
