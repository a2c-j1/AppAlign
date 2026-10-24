import XCTest

extension KeyboardSnapControllerTests {
    @MainActor
    func testManualHistoryLeaseWaitRejectsQuickLayoutAndSameTokenRecapture() async throws {
        for change in [ManualHistoryWaitChange.quickLayout, .recapture] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("AppAlignManualHistoryWait-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let displayID = PersistentDisplayID(uuid: UUID())
            let display = Display(runtimeID: RuntimeDisplayID(rawValue: 1), persistentID: displayID,
                                  sessionID: UUID(), name: "Manual", frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                                  workArea: CGRect(x: 0, y: 0, width: 1_000, height: 800), isPrimary: true,
                                  backingScaleFactor: 1)
            let snapshot = DisplaySnapshot(displays: [display], primaryFrame: display.frame)
            let firstLayout = PersistentStoreCoordinator.defaultLayout()
            let alternativeID = UUID()
            let alternativeLayout = PersistedLayout(
                id: alternativeID,
                definition: .grid(GridLayout(id: LayoutID(rawValue: alternativeID), rows: 1, columns: 1,
                                             rowPercentages: [10_000], columnPercentages: [10_000],
                                             cellChildMap: [[44]])),
                spacing: 0, template: .columns, zoneCount: 1, name: "Alternative"
            )
            let seedStore = PersistentStoreCoordinator(directory: directory)
            try await seedStore.saveLayoutAndAssignments(
                [firstLayout, alternativeLayout],
                [PersistedAssignment(displayUUID: displayID.uuid, spaceScope: .common, layoutID: firstLayout.id)]
            )
            let token = RuntimeWindowToken(id: UUID(), pid: 200)
            let originalFrame = CGRect(x: 100, y: 120, width: 500, height: 350)
            let capture = ManualWindowCapture(token: token, lease: ManualWindowLeaseID(), originalFrame: originalFrame)
            let nextCapture = ManualWindowCapture(token: token, lease: ManualWindowLeaseID(),
                                                  originalFrame: CGRect(x: 300, y: 220, width: 400, height: 300))
            let expectedFrame = change == .quickLayout ? originalFrame : nextCapture.originalFrame
            let runtime = ManualWindowTestRuntime(capture: capture, initialFrame: originalFrame,
                                                  nextCaptures: [nextCapture])
            let layout = LayoutController(
                displayProvider: DisplayProvider(snapshot: snapshot),
                storeCoordinator: PersistentStoreCoordinator(directory: directory),
                bundleIdentifierProvider: { _ in "com.example.Manual" }
            )
            await layout.loadPersistentState()
            layout.appHistoryCoordinator.releaseRuntimeLease = { leaseToken, leaseID in
                Task { await runtime.releaseHistoryLease(leaseToken, lease: leaseID) }
            }
            let placement = PlacementController(
                displayProvider: DisplayProvider(snapshot: snapshot),
                dependencies: PlacementControllerDependencies(isAccessibilityTrusted: { true }),
                manualRuntime: runtime,
                initialManualCapture: capture,
                initialManualDisplayFingerprint: snapshot.fingerprint
            )
            await runtime.blockNextHistoryRetain()
            let placementTask = Task { await layout.placeSelectedZone(using: placement) }
            await runtime.waitForHistoryRetain()

            switch change {
            case .quickLayout:
                XCTAssertNotNil(layout.applyQuickLayout(alternativeLayout.id, at: CGPoint(x: 10, y: 10)))
            case .recapture:
                await placement.startManualCapture(applicationPID: token.pid, displaySnapshot: snapshot).value
                XCTAssertEqual(placement.capturedRuntimeToken, token, "The replacement capture intentionally reuses the same runtime token.")
            }
            await runtime.releaseHistoryRetain()
            await placementTask.value
            for _ in 0 ..< 100 {
                if await runtime.historyLeaseCountValue() == 0 { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let ticketStates = await runtime.getTicketStates()
            XCTAssertTrue(ticketStates.isEmpty, "A quick layout or replacement capture during history retain must not reach the setter.")
            let historyLeaseCount = await runtime.historyLeaseCountValue()
            let actualFrame = await runtime.currentFrameValue()
            XCTAssertEqual(historyLeaseCount, 0)
            XCTAssertEqual(placement.actualFrame, change == .quickLayout ? nil : expectedFrame)
            XCTAssertEqual(placement.canRestore, true, "Manual Restore remains available after the stale placement request is rejected.")
            XCTAssertEqual(actualFrame, expectedFrame)
            XCTAssertTrue(layout.appZoneHistory.isEmpty)
        }
    }
}
