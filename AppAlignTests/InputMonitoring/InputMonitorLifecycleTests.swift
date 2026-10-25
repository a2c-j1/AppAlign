import CoreGraphics
import Foundation
import XCTest

@MainActor
final class InputMonitorLifecycleTests: XCTestCase {
    func testStopDuringDelayedTapCreationThenRetryRejectsLateResource() async throws {
        let factoryState = FakeInputResourceFactoryState(delayFirstCreation: true)
        let factory = InputTapResourceFactory { core, generation in factoryState.make(core: core, generation: generation) }
        let core = InputMonitorCore(resourceFactory: factory)
        let results = InputMonitorTestResults()
        let ready = expectation(description: "retry tap becomes ready")

        core.start(onEvent: { results.event($0) }, onStatus: {
            results.status($0)
            if $0 == .ready { ready.fulfill() }
        })
        try await spin { factoryState.firstCreationIsBlocked }

        core.stop()
        core.start(onEvent: { results.event($0) }, onStatus: {
            results.status($0)
            if $0 == .ready { ready.fulfill() }
        })
        await fulfillment(of: [ready], timeout: 2)

        factoryState.releaseFirstCreation()
        try await spin { factoryState.invalidationCount(generation: 1) == 1 }
        XCTAssertEqual(results.statuses, [.ready])
        XCTAssertEqual(factoryState.enableCount(generation: 1), 0)
        XCTAssertEqual(factoryState.invalidationCount(generation: 1), 1)

        core.stop()
        try await spin { factoryState.invalidationCount(generation: 3) == 1 }
        XCTAssertEqual(factoryState.invalidationCount(generation: 3), 1)
    }

    func testOldTapCallbackIsIgnoredAfterStopAndRetry() async throws {
        let factoryState = FakeInputResourceFactoryState(delayFirstCreation: false)
        let factory = InputTapResourceFactory { core, generation in factoryState.make(core: core, generation: generation) }
        let core = InputMonitorCore(resourceFactory: factory)
        let results = InputMonitorTestResults()
        let firstReady = expectation(description: "first tap ready")
        core.start(onEvent: { results.event($0) }, onStatus: {
            results.status($0)
            if $0 == .ready { firstReady.fulfill() }
        })
        await fulfillment(of: [firstReady], timeout: 2)
        try await spin { factoryState.runStarted(generation: 1) }
        guard let oldResource = factoryState.resource(generation: 1) else {
            XCTFail("The first resource was not created")
            return
        }

        core.stop()
        let secondReady = expectation(description: "retry tap ready")
        core.start(onEvent: { results.event($0) }, onStatus: {
            results.status($0)
            if $0 == .ready { secondReady.fulfill() }
        })
        await fulfillment(of: [secondReady], timeout: 2)
        try await spin { factoryState.runStarted(generation: 3) }

        oldResource.emit(.leftDown)
        XCTAssertTrue(results.events.isEmpty)
        guard let newResource = factoryState.resource(generation: 3) else {
            XCTFail("The retry resource was not created")
            return
        }
        newResource.emit(.leftDown)
        try await spin { results.events.count == 1 }
        XCTAssertEqual(results.events.map(\.kind), [.leftDown])

        core.stop()
        try await spin { factoryState.invalidationCount(generation: 1) == 1 && factoryState.invalidationCount(generation: 3) == 1 }
        XCTAssertEqual(factoryState.invalidationCount(generation: 1), 1)
        XCTAssertEqual(factoryState.invalidationCount(generation: 3), 1)
    }

    func testFactoryAndEnableFailuresCleanUpAndCanRetry() async throws {
        for failure in [FakeInputResourceFactoryState.FirstFailure.factory, .enable] {
            let factoryState = FakeInputResourceFactoryState(delayFirstCreation: false, firstFailure: failure)
            let factory = InputTapResourceFactory { core, generation in factoryState.make(core: core, generation: generation) }
            let core = InputMonitorCore(resourceFactory: factory)
            let results = InputMonitorTestResults()
            let ready = expectation(description: "retry after \\(failure) failure becomes ready")
            var didRetry = false
            core.start(onEvent: { results.event($0) }, onStatus: { status in
                results.status(status)
                if case .failed = status, !didRetry {
                    didRetry = true
                    core.stop()
                    core.start(onEvent: { results.event($0) }, onStatus: { retryStatus in
                        results.status(retryStatus)
                        if retryStatus == .ready { ready.fulfill() }
                    })
                }
            })
            await fulfillment(of: [ready], timeout: 2)
            try await spin { factoryState.invalidationCount(generation: 1) == (failure == .enable ? 1 : 0) }
            XCTAssertEqual(results.statuses.filter { if case .failed = $0 { return true }; return false }.count, 1)
            XCTAssertEqual(results.statuses.filter { $0 == .ready }.count, 1)
            if failure == .enable { XCTAssertEqual(factoryState.invalidationCount(generation: 1), 1) }
            XCTAssertTrue(factoryState.runStarted(generation: 3))
            core.stop()
            try await spin { factoryState.invalidationCount(generation: 3) == 1 }
        }
    }
}

private final class FakeInputResourceFactoryState: @unchecked Sendable {
    enum FirstFailure: Equatable { case factory, enable }

    private let lock = NSLock()
    private let releaseFirst = DispatchSemaphore(value: 0)
    private let delayFirstCreation: Bool
    private let firstFailure: FirstFailure?
    private var resources: [UInt64: FakeInputTapResource] = [:]
    private var firstBlocked = false

    init(delayFirstCreation: Bool, firstFailure: FirstFailure? = nil) {
        self.delayFirstCreation = delayFirstCreation
        self.firstFailure = firstFailure
    }

    var firstCreationIsBlocked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return firstBlocked
    }

    func make(core: InputMonitorCore, generation: UInt64) -> (any InputTapResource)? {
        if delayFirstCreation, generation == 1 {
            lock.lock()
            firstBlocked = true
            lock.unlock()
            releaseFirst.wait()
        }
        if generation == 1, firstFailure == .factory { return nil }
        let resource = FakeInputTapResource(core: core, generation: generation, factoryState: self,
                                            enableSucceeds: !(generation == 1 && firstFailure == .enable))
        lock.lock()
        resources[generation] = resource
        lock.unlock()
        return resource
    }

    func releaseFirstCreation() { releaseFirst.signal() }
    func resource(generation: UInt64) -> FakeInputTapResource? {
        lock.lock()
        defer { lock.unlock() }
        return resources[generation]
    }
    func runStarted(generation: UInt64) -> Bool { resource(generation: generation)?.hasRunStarted ?? false }
    func enableCount(generation: UInt64) -> Int { resource(generation: generation)?.enableCount ?? 0 }
    func invalidationCount(generation: UInt64) -> Int { resource(generation: generation)?.invalidationCount ?? 0 }
}

private final class FakeInputTapResource: InputTapResource, @unchecked Sendable {
    private let core: InputMonitorCore
    private let generation: UInt64
    private weak var factoryState: FakeInputResourceFactoryState?
    private let stopped = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var enabled = false
    private var runStartedValue = false
    private var invalidated = false
    private var invalidations = 0
    private let enableSucceeds: Bool

    init(core: InputMonitorCore, generation: UInt64, factoryState: FakeInputResourceFactoryState,
         enableSucceeds: Bool) {
        self.core = core
        self.generation = generation
        self.factoryState = factoryState
        self.enableSucceeds = enableSucceeds
    }

    var enableCount: Int { lock.lock(); defer { lock.unlock() }; return enabled ? 1 : 0 }
    var hasRunStarted: Bool { lock.lock(); defer { lock.unlock() }; return runStartedValue }
    var invalidationCount: Int { lock.lock(); defer { lock.unlock() }; return invalidations }

    func enable() -> Bool {
        lock.lock()
        enabled = true
        lock.unlock()
        return enableSucceeds
    }

    func run() {
        lock.lock()
        runStartedValue = true
        lock.unlock()
        stopped.wait()
        invalidate()
    }

    func stop() { stopped.signal() }

    func invalidate() {
        lock.lock()
        guard !invalidated else { lock.unlock(); return }
        invalidated = true
        invalidations += 1
        lock.unlock()
    }

    func emit(_ kind: DragInputKind) {
        let eventType: CGEventType = kind == .leftDown ? .leftMouseDown : .mouseMoved
        core.accept(InputMonitorPayload(kind: kind, location: CGPoint(x: 2, y: 3), flags: 0,
                                        button: 0, timestamp: 123, generation: generation,
                                        eventType: eventType))
    }
}

private final class InputMonitorTestResults: @unchecked Sendable {
    private let lock = NSLock()
    private var eventStorage: [DragInputEvent] = []
    private var statusStorage: [DragMonitorStatus] = []

    var events: [DragInputEvent] { lock.lock(); defer { lock.unlock() }; return eventStorage }
    var statuses: [DragMonitorStatus] { lock.lock(); defer { lock.unlock() }; return statusStorage }

    func event(_ value: DragInputEvent) { lock.lock(); eventStorage.append(value); lock.unlock() }
    func status(_ value: DragMonitorStatus) { lock.lock(); statusStorage.append(value); lock.unlock() }
}
