import Darwin
import Foundation
import XCTest

final class SpaceHelperBackendTests: XCTestCase {

    func testResponseDecoderReturnsOnlyCanonicalRegularSpaceUUID() throws {
        let displayID = UUID()
        let spaceUUID = "5EA7DC96-5689-1D28-6AF8-DB244D30E11E"
        let payload = try encoded(record(displayUUID: displayID, candidate: spaceUUID))

        let result = try SpaceHelperResponseDecoder.decode(payload, exitCode: 0, host: .supported,
                                                           displayUUID: displayID)

        XCTAssertEqual(result, ReadOnlySpaceValue(id: spaceUUID, kind: .regular))

        var fullscreen = record(displayUUID: displayID, candidate: spaceUUID)
        fullscreen["rawSpaceType"] = 4
        fullscreen["kind"] = "fullscreen"
        XCTAssertNil(try SpaceHelperResponseDecoder.decode(encoded(fullscreen), exitCode: 0, host: .supported,
                                                           displayUUID: displayID))

        var unavailableUUID = record(displayUUID: displayID, candidate: NSNull())
        unavailableUUID["error"] = "invalid_space_uuid"
        XCTAssertNil(try SpaceHelperResponseDecoder.decode(encoded(unavailableUUID), exitCode: 3, host: .supported,
                                                           displayUUID: displayID))

        let noncanonicalUUID = record(displayUUID: displayID, candidate: spaceUUID.lowercased())
        XCTAssertThrowsError(try SpaceHelperResponseDecoder.decode(encoded(noncanonicalUUID), exitCode: 0,
                                                                   host: .supported, displayUUID: displayID))
    }

    func testRunnerDecodesOnlyTheUUIDCandidateFromAValidHelperResponse() async throws {
        let displayID = UUID()
        let spaceUUID = "06497333-89E6-B6A1-90A2-D67FCC9F9348"
        let payload = String(data: try encoded(record(displayUUID: displayID, candidate: spaceUUID)), encoding: .utf8)!
        let runner = SpaceHelperProcessRunner(testExecutableURL: URL(fileURLWithPath: "/bin/sh"),
                                              testArgumentPrefix: ["-c", "printf '%s' '\(payload)'"])

        let result = try await runner.snapshot(for: displayID, deadline: deadline(after: 1_000_000_000))

        XCTAssertEqual(result, ReadOnlySpaceValue(id: spaceUUID, kind: .regular))
    }

    func testResponseDecoderRejectsSchemaIdentityAndExitStatusMismatches() throws {
        let displayID = UUID()
        let valid = record(displayUUID: displayID, candidate: UUID().uuidString)
        var extraField = valid
        extraField["spaces"] = []
        XCTAssertThrowsError(try SpaceHelperResponseDecoder.decode(encoded(extraField), exitCode: 0,
                                                                   host: .supported, displayUUID: displayID))

        var identityMismatch = valid
        identityMismatch["build"] = "wrong-build"
        XCTAssertThrowsError(try SpaceHelperResponseDecoder.decode(encoded(identityMismatch), exitCode: 0,
                                                                   host: .supported, displayUUID: displayID))

        var adoptionEnabled = valid
        adoptionEnabled["adoption"] = true
        XCTAssertThrowsError(try SpaceHelperResponseDecoder.decode(encoded(adoptionEnabled), exitCode: 0,
                                                                   host: .supported, displayUUID: displayID))

        XCTAssertThrowsError(try SpaceHelperResponseDecoder.decode(encoded(valid), exitCode: 3,
                                                                   host: .supported, displayUUID: displayID))

        var falseSuccess = valid
        falseSuccess["error"] = "invalid_space_uuid"
        XCTAssertThrowsError(try SpaceHelperResponseDecoder.decode(encoded(falseSuccess), exitCode: 0,
                                                                   host: .supported, displayUUID: displayID))

        var floatingType = valid
        floatingType["rawSpaceType"] = 0.0
        floatingType.removeValue(forKey: "rawSpaceType")
        let jsonWithoutType = String(data: try encoded(floatingType), encoding: .utf8)!
        let floatJSON = String(jsonWithoutType.dropLast()) + ",\"rawSpaceType\":0.0}"
        let floatPayload = Data(floatJSON.utf8)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: floatPayload))
        XCTAssertThrowsError(try SpaceHelperResponseDecoder.decode(floatPayload, exitCode: 0,
                                                                   host: .supported, displayUUID: displayID))

        var malformedErrorRecord = valid
        malformedErrorRecord["error"] = "invalid_space_uuid"
        malformedErrorRecord["kind"] = 42
        XCTAssertThrowsError(try SpaceHelperResponseDecoder.decode(encoded(malformedErrorRecord), exitCode: 3,
                                                                   host: .supported, displayUUID: displayID))

        var outOfRangeType = valid
        outOfRangeType["rawSpaceType"] = Int64(Int32.max) + 1
        outOfRangeType["kind"] = "unknown"
        XCTAssertThrowsError(try SpaceHelperResponseDecoder.decode(encoded(outOfRangeType), exitCode: 0,
                                                                   host: .supported, displayUUID: displayID))
    }

    func testRunnerTimesOutAndReapsChildThatClosedStdoutEarly() async throws {
        let recorder = ProcessIDRecorder()
        let pidFile = temporaryPIDFile()
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = "printf '%s' \"$$\" > '\(pidFile.path)'; exec 1>&-; exec /bin/sleep 20"
        let childDeadline = deadline(after: 5_000_000_000)
        let runner = SpaceHelperProcessRunner(testExecutableURL: URL(fileURLWithPath: "/bin/sh"),
                                              testArgumentPrefix: ["-c", script],
                                              childStarted: { recorder.set($0) })

        let startedAt = DispatchTime.now().uptimeNanoseconds
        let task = Task {
            try await runner.snapshot(for: UUID(), deadline: childDeadline)
        }
        let pid = try await waitForPID(recorder, cancelling: task)
        do {
            _ = try await task.value
            XCTFail("A child still running after stdout EOF must hit the same deadline.")
        } catch let error as SpaceHelperProcessError {
            XCTAssertEqual(error, .timedOut)
        }
        task.cancel()
        _ = await task.result
        XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - startedAt, 1_000_000_000,
                          "Runner callers must receive a finite deadline even when they pass UInt64-scale budgets.")
        XCTAssertTrue(isReaped(pid), "The runner must reap its direct child before returning timeout.")
    }

    func testRunnerKillsDirectChildWhenStdoutExceedsBound() async throws {
        let recorder = ProcessIDRecorder()
        let pidFile = temporaryPIDFile()
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = "printf '%s' \"$$\" > '\(pidFile.path)'; exec /usr/bin/yes x"
        let childDeadline = deadline(after: 1_000_000_000)
        let runner = SpaceHelperProcessRunner(testExecutableURL: URL(fileURLWithPath: "/bin/sh"),
                                              testArgumentPrefix: ["-c", script],
                                              childStarted: { recorder.set($0) })

        let task = Task {
            try await runner.snapshot(for: UUID(), deadline: childDeadline)
        }
        let pid = try await waitForPID(recorder, cancelling: task)
        do {
            _ = try await task.value
            XCTFail("An oversized response must be rejected.")
        } catch let error as SpaceHelperProcessError {
            XCTAssertEqual(error, .outputTooLarge)
        }
        task.cancel()
        _ = await task.result
        XCTAssertTrue(isReaped(pid))
    }

    func testCancellationWaitsForDirectChildTerminationAndReaping() async throws {
        let recorder = ProcessIDRecorder()
        let pidFile = temporaryPIDFile()
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = "printf '%s' \"$$\" > '\(pidFile.path)'; exec /bin/sleep 20"
        let childDeadline = deadline(after: 1_000_000_000)
        let runner = SpaceHelperProcessRunner(testExecutableURL: URL(fileURLWithPath: "/bin/sh"),
                                              testArgumentPrefix: ["-c", script],
                                              childStarted: { recorder.set($0) })
        let task = Task {
            try await runner.snapshot(for: UUID(), deadline: childDeadline)
        }
        let pid = try await waitForPID(recorder, cancelling: task)

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must not return a helper result.")
        } catch is CancellationError {
            // Expected after the runner has stopped and reaped its child.
        } catch let error as SpaceHelperProcessError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertTrue(isReaped(pid), "Cancellation must wait until the direct child is reaped.")
    }

    @MainActor
    func testDeadlineBudgetAndMixedDisplayResults() async throws {
        let first = UUID()
        let second = UUID()
        let backend = BudgetRecordingBackend(successfulDisplay: second, delayedDisplay: first)
        let provider = SpaceProvider(backend: backend)
        provider.requestScopedMode()
        let request = provider.makeRefreshRequest(displays: [first, second])
        let overallDeadline = deadline(after: 400_000_000)
        let candidate = await provider.readCandidate(for: request, deadline: overallDeadline)

        XCTAssertEqual(candidate.snapshots[first]?.mode, .degradedScoped)
        XCTAssertEqual(candidate.snapshots[second]?.mode, .validatedScoped)
        XCTAssertTrue(provider.publish(candidate, for: request))
        XCTAssertEqual(provider.mode, .degradedScoped)
        let budgets = await backend.receivedDeadlines
        let startedAt = await backend.receivedAt
        XCTAssertEqual(budgets.count, 2)
        XCTAssertEqual(startedAt.count, 2)
        XCTAssertTrue(budgets.allSatisfy { $0 <= overallDeadline })
        XCTAssertTrue(budgets.allSatisfy { $0 > 0 })
        XCTAssertTrue(zip(budgets, startedAt).allSatisfy { pair in
            pair.0 >= pair.1 && pair.0 - pair.1 <= 250_000_000
        })
    }

    private func record(displayUUID: UUID, candidate: Any) -> [String: Any] {
        [
            "osMajor": 27,
            "build": "26A434",
            "displayUUID": displayUUID.uuidString.uppercased(),
            "rawSpaceID": "41",
            "kind": "user",
            "error": NSNull(),
            "adoption": false,
            "rawSpaceType": 0,
            "spaceUUIDCandidate": candidate
        ]
    }

    private func encoded(_ record: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    }

    private func deadline(after nanoseconds: UInt64) -> UInt64 {
        DispatchTime.now().uptimeNanoseconds &+ nanoseconds
    }

    private func temporaryPIDFile() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("appalign-helper-\(UUID().uuidString).pid")
    }

    private func waitForPID(_ recorder: ProcessIDRecorder,
                            cancelling task: Task<ReadOnlySpaceValue?, Error>) async throws -> pid_t {
        let deadline = DispatchTime.now().uptimeNanoseconds &+ 2_000_000_000
        do {
            while DispatchTime.now().uptimeNanoseconds < deadline {
                if let pid = recorder.pid { return pid }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw SpaceHelperProcessError.timedOut
        } catch {
            task.cancel()
            _ = await task.result
            throw error
        }
    }

    private func isReaped(_ pid: pid_t) -> Bool {
        let result = kill(pid, 0)
        return result == -1 && errno == ESRCH
    }
}

@MainActor
extension SpaceHelperBackendTests {
    func testUnsupportedBackendHostAndMissingHelperDoNotLaunchAChild() async throws {
        let recorder = ProcessIDRecorder()
        let helperURL = URL(fileURLWithPath: "/bin/sh")
        let runner = SpaceHelperProcessRunner(testExecutableURL: helperURL,
                                              testArgumentPrefix: ["-c", "exec /bin/sleep 20"],
                                              childStarted: { recorder.set($0) })
        let backend = SkyLightReadOnlyBackend(runner: runner, previewRequested: false,
                                              hostIdentity: SpaceHelperHostIdentity(major: 26, build: "26A434"),
                                              architecture: "arm64")
        let provider = SpaceProvider.production(backend: backend, notificationCenter: NotificationCenter())
        let request = provider.makeRefreshRequest(displays: [UUID()])
        let candidate = await provider.readCandidate(for: request, deadline: deadline(after: 1_000_000_000))
        XCTAssertTrue(provider.publish(candidate, for: request))
        XCTAssertEqual(provider.mode, .commonOnly,
                       "The production factory remains on common layout when the host is unsupported.")
        let gatedValue = try await backend.snapshot(for: UUID(), deadline: deadline(after: 1_000_000_000))
        XCTAssertNil(gatedValue)
        XCTAssertNil(recorder.pid, "An unsupported host must prevent helper launch.")

        let unsupportedArchitecture = SkyLightReadOnlyBackend(runner: runner, previewRequested: true,
                                                              hostIdentity: .supported, architecture: "x86_64")
        let architectureValue = try await unsupportedArchitecture.snapshot(
            for: UUID(), deadline: deadline(after: 1_000_000_000)
        )
        XCTAssertNil(architectureValue)
        XCTAssertNil(recorder.pid, "An unsupported architecture must prevent helper launch, even with opt-in.")

        let unavailableHost = SkyLightReadOnlyBackend(runner: runner, previewRequested: true,
                                                      hostIdentity: nil, architecture: "arm64")
        let unavailableHostValue = try await unavailableHost.snapshot(
            for: UUID(), deadline: deadline(after: 1_000_000_000)
        )
        XCTAssertNil(unavailableHostValue)
        XCTAssertNil(recorder.pid, "An unavailable host identity must prevent helper launch.")

        let mismatch = SpaceHelperProcessRunner(testExecutableURL: helperURL,
                                                testHostIdentity: SpaceHelperHostIdentity(major: 26, build: "26A434"),
                                                testArgumentPrefix: ["-c", "exec /bin/sleep 20"],
                                                childStarted: { recorder.set($0) })
        do {
            _ = try await mismatch.snapshot(for: UUID(), deadline: deadline(after: 1_000_000_000))
            XCTFail("Unsupported host identity must fail before launch.")
        } catch let error as SpaceHelperProcessError {
            XCTAssertEqual(error, .unsupportedHost)
        }
        XCTAssertNil(recorder.pid)

        let missing = SpaceHelperProcessRunner(testExecutableURL: nil, childStarted: { recorder.set($0) })
        do {
            _ = try await missing.snapshot(for: UUID(), deadline: deadline(after: 1_000_000_000))
            XCTFail("A missing bundled helper must fail before launch.")
        } catch let error as SpaceHelperProcessError {
            XCTAssertEqual(error, .helperUnavailable)
        }
        XCTAssertNil(recorder.pid)

        let expired = SpaceHelperProcessRunner(testExecutableURL: helperURL,
                                               testArgumentPrefix: ["-c", "exec /bin/sleep 20"],
                                               childStarted: { recorder.set($0) })
        do {
            _ = try await expired.snapshot(for: UUID(), deadline: 0)
            XCTFail("An expired deadline must prevent process creation.")
        } catch let error as SpaceHelperProcessError {
            XCTAssertEqual(error, .deadlineExpired)
        }
        XCTAssertNil(recorder.pid)
    }
}

private final class ProcessIDRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: pid_t?

    var pid: pid_t? { lock.withLock { value } }
    func set(_ pid: pid_t) { lock.withLock { value = pid } }
}

private actor BudgetRecordingBackend: ReadOnlySpaceBackend {
    nonisolated let identifier = "budget-test"
    nonisolated let canAdoptStableIdentifiers = true
    private let successfulDisplay: UUID
    private let delayedDisplay: UUID
    private(set) var receivedDeadlines: [UInt64] = []
    private(set) var receivedAt: [UInt64] = []

    init(successfulDisplay: UUID, delayedDisplay: UUID) {
        self.successfulDisplay = successfulDisplay
        self.delayedDisplay = delayedDisplay
    }

    func snapshot(for displayUUID: UUID) async throws -> ReadOnlySpaceValue? {
        displayUUID == successfulDisplay ? ReadOnlySpaceValue(id: "space-A", kind: .regular) : nil
    }

    func snapshot(for displayUUID: UUID, deadline: UInt64) async throws -> ReadOnlySpaceValue? {
        receivedAt.append(DispatchTime.now().uptimeNanoseconds)
        receivedDeadlines.append(deadline)
        if displayUUID == delayedDisplay {
            let now = DispatchTime.now().uptimeNanoseconds
            if deadline > now { try await Task.sleep(nanoseconds: deadline - now) }
            return nil
        }
        return try await snapshot(for: displayUUID)
    }
}

final class SpacePreviewPolicyTests: XCTestCase {
    func testScopedUseRequiresObservedHostAndArchitecture() {
        XCTAssertTrue(SkyLightReadOnlyBackend.permitsScopedSpaceUse(host: .supported, architecture: "arm64"))
        XCTAssertFalse(SkyLightReadOnlyBackend.permitsScopedSpaceUse(host: nil, architecture: "arm64"))
        XCTAssertFalse(SkyLightReadOnlyBackend.permitsScopedSpaceUse(host: .supported, architecture: "x86_64"))
        XCTAssertFalse(SkyLightReadOnlyBackend.permitsScopedSpaceUse(
            host: SpaceHelperHostIdentity(major: 26, build: "26A434"), architecture: "arm64"
        ))
        XCTAssertFalse(SkyLightReadOnlyBackend.permitsScopedSpaceUse(
            host: SpaceHelperHostIdentity(major: 27, build: "other"), architecture: "arm64"
        ))

        let normal = SkyLightReadOnlyBackend(previewRequested: false, hostIdentity: .supported, architecture: "arm64")
        let explicitPreview = SkyLightReadOnlyBackend(previewRequested: true, hostIdentity: .supported, architecture: "arm64")
        XCTAssertTrue(normal.canAdoptStableIdentifiers)
        XCTAssertTrue(normal.allowsScopedQueries)
        XCTAssertEqual(normal.identifier, "skylight-preview-27-26A434")
        XCTAssertEqual(explicitPreview.identifier, normal.identifier,
                       "Opt-in arguments must not select a different persistence namespace.")
        XCTAssertFalse(SkyLightReadOnlyBackend(previewRequested: true, hostIdentity: nil,
                                               architecture: "arm64").allowsScopedQueries)
    }
}
