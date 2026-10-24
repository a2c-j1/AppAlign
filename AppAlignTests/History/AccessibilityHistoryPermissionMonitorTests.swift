import XCTest

final class HistoryPermissionMonitorTests: XCTestCase {
    @MainActor
    func testSingleOneSecondPollSuspendsAfterRevocationUntilExplicitRetry() {
        var permissionGranted = true
        var revocations = 0
        let monitor = AccessibilityHistoryPermissionMonitor(
            permissionIsGranted: { permissionGranted },
            permissionWasRevoked: { revocations += 1 }
        )

        monitor.update(enabled: true)
        monitor.update(enabled: true)
        XCTAssertTrue(monitor.isRunning)
        XCTAssertEqual(monitor.timerInstallCount, 1, "Repeated lifecycle updates keep one permission timer.")
        monitor.pollNow()
        XCTAssertEqual(revocations, 0)

        permissionGranted = false
        monitor.pollNow()
        monitor.pollNow()
        XCTAssertEqual(revocations, 1, "Permission loss synchronously suspends history only once.")

        permissionGranted = true
        monitor.pollNow()
        XCTAssertEqual(revocations, 1, "Permission returning does not restart monitoring before an explicit retry.")
        monitor.retrySucceeded()
        monitor.pollNow()
        XCTAssertEqual(revocations, 1)

        monitor.update(enabled: false)
        XCTAssertFalse(monitor.isRunning)
        monitor.update(enabled: true)
        XCTAssertEqual(monitor.timerInstallCount, 2)
        monitor.update(enabled: false)
    }
}
