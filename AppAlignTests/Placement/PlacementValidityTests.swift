import XCTest

final class PlacementValidityTests: XCTestCase {
    func testPendingAndInflightLimitsReleaseOnlyWhenFinished() throws {
        let validity = PlacementValidity()
        let now = DispatchTime.now().uptimeNanoseconds
        let first = try XCTUnwrap(validity.reserve(startDeadline: now + 10_000_000_000,
                                                  totalDeadline: now + 20_000_000_000))
        XCTAssertNil(validity.reserve(startDeadline: now + 10_000_000_000,
                                      totalDeadline: now + 20_000_000_000))
        XCTAssertTrue(first.beginWrite(now: now))
        let second = try XCTUnwrap(validity.reserve(startDeadline: now + 10_000_000_000,
                                                   totalDeadline: now + 20_000_000_000))
        XCTAssertNil(validity.reserve(startDeadline: now + 10_000_000_000,
                                      totalDeadline: now + 20_000_000_000))
        XCTAssertTrue(first.completeIfCurrent(now: now))
        XCTAssertNil(validity.reserve(startDeadline: now + 10_000_000_000,
                                      totalDeadline: now + 20_000_000_000),
                      "A completed entry retains its slot until finish.")
        XCTAssertFalse(second.beginWrite(now: now),
                       "A pending ticket cannot start while an earlier completed ticket is not finished.")
        first.finish()
        XCTAssertTrue(second.beginWrite(now: now))
        second.finish()
        XCTAssertNotNil(validity.reserve(startDeadline: now + 10_000_000_000,
                                         totalDeadline: now + 20_000_000_000))
    }

    func testConfigurationABANotificationsInvalidateOldTicketAndRejectEarlierPublish() throws {
        let validity = PlacementValidity()
        let now = DispatchTime.now().uptimeNanoseconds
        let old = try XCTUnwrap(validity.reserve(startDeadline: now + 10_000_000_000,
                                                 totalDeadline: now + 20_000_000_000))
        let revisionB = validity.invalidateForConfigurationChange()
        XCTAssertEqual(old.state, .invalidated)
        let revisionA = validity.invalidateForConfigurationChange()
        XCTAssertGreaterThan(revisionA, revisionB)
        XCTAssertFalse(validity.publishConfiguration(revision: revisionB))
        XCTAssertTrue(validity.publishConfiguration(revision: revisionA))
        old.finish()
        let fresh = try XCTUnwrap(validity.reserve(startDeadline: now + 10_000_000_000,
                                                  totalDeadline: now + 20_000_000_000))
        XCTAssertTrue(fresh.beginWrite(now: now))
        XCTAssertEqual(fresh.state, .writing)
    }

    func testBeginKeepsAdmissionClosedUntilMatchingCompletionEvenWhenSampleIsUnchanged() throws {
        let validity = PlacementValidity()
        let now = DispatchTime.now().uptimeNanoseconds
        let beginRevision = validity.invalidateForConfigurationChange()
        // A 500 ms poll can observe the same snapshot while AppKit's display
        // transaction is still in progress; observation alone cannot reopen.
        XCTAssertNil(validity.reserve(startDeadline: now + 10_000_000_000,
                                      totalDeadline: now + 20_000_000_000))
        XCTAssertFalse(validity.publishConfiguration(revision: beginRevision - 1))

        let completionRevision = validity.invalidateForConfigurationChange()
        XCTAssertGreaterThan(completionRevision, beginRevision)
        XCTAssertFalse(validity.publishConfiguration(revision: beginRevision))
        XCTAssertTrue(validity.publishConfiguration(revision: completionRevision))
        XCTAssertNotNil(validity.reserve(startDeadline: now + 10_000_000_000,
                                         totalDeadline: now + 20_000_000_000))
    }

    func testInvalidationDuringWriteBlocksFurtherWritesAndFinishDoesNotRevive() throws {
        let validity = PlacementValidity()
        let now = DispatchTime.now().uptimeNanoseconds
        let ticket = try XCTUnwrap(validity.reserve(startDeadline: now + 10_000_000_000,
                                                   totalDeadline: now + 20_000_000_000))
        XCTAssertTrue(ticket.beginWrite(now: now))
        validity.invalidateForLayoutChange()
        XCTAssertFalse(ticket.mayContinueWrite(now: now))
        XCTAssertEqual(ticket.state, .invalidated)
        XCTAssertFalse(ticket.completeIfCurrent(now: now))
        ticket.finish()
        XCTAssertEqual(ticket.state, .invalidated)
    }

    func testExpiredInflightKeepsItsSlotUntilTaskFinishes() throws {
        let validity = PlacementValidity()
        let now = DispatchTime.now().uptimeNanoseconds
        let inflight = try XCTUnwrap(validity.reserve(startDeadline: now + 10_000_000_000,
                                                     totalDeadline: now + 100_000_000))
        XCTAssertTrue(inflight.beginWrite(now: now))
        let pending = try XCTUnwrap(validity.reserve(startDeadline: now + 10_000_000_000,
                                                     totalDeadline: now + 20_000_000_000))
        XCTAssertFalse(inflight.mayContinueWrite(now: now + 200_000_000))
        XCTAssertNil(validity.reserve(startDeadline: now + 10_000_000_000,
                                      totalDeadline: now + 20_000_000_000))
        inflight.finish()
        XCTAssertNil(validity.reserve(startDeadline: now + 10_000_000_000,
                                      totalDeadline: now + 20_000_000_000))
        pending.finish()
        XCTAssertNotNil(validity.reserve(startDeadline: now + 10_000_000_000,
                                         totalDeadline: now + 20_000_000_000))
    }
}
