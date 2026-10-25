import CoreFoundation
import Darwin
import Foundation

enum SpaceHelperProcessError: Error, Equatable {
    case unsupportedHost
    case deadlineExpired
    case helperUnavailable
    case cancelled
    case launchFailed
    case timedOut
    case outputTooLarge
    case invalidResponse
}

struct SpaceHelperHostIdentity: Equatable, Sendable {
    let major: Int
    let build: String

    static let supported = SpaceHelperHostIdentity(major: 27, build: "26A434")

    static func current() -> SpaceHelperHostIdentity? {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard let build = String(bytes: bytes, encoding: .utf8) else { return nil }
        return SpaceHelperHostIdentity(major: ProcessInfo.processInfo.operatingSystemVersion.majorVersion, build: build)
    }
}

struct SpaceHelperResponseDecoder {
    static let maximumOutputBytes = 2_048

    private static let keys: Set<String> = [
        "osMajor", "build", "displayUUID", "rawSpaceID", "kind", "error", "adoption",
        "rawSpaceType", "spaceUUIDCandidate"
    ]
    private static let helperErrors: Set<String> = [
        "skylight_unavailable", "main_connection_symbol_missing", "current_space_symbol_missing",
        "main_connection_failed", "zero_space_id", "space_type_symbol_missing",
        "managed_display_spaces_symbol_missing", "space_copy_name_symbol_missing",
        "managed_display_spaces_unavailable", "invalid_display_metadata", "display_uuid_not_found",
        "ambiguous_display_uuid", "invalid_spaces_metadata", "invalid_space_id", "duplicate_space_id",
        "current_space_not_found", "ambiguous_current_space_id", "invalid_space_uuid",
        "space_changed_during_probe", "unsupported_space_type", "too_many_displays", "too_many_spaces",
        "duplicate_space_uuid", "managed_space_set_changed"
    ]

    static func decode(_ data: Data, exitCode: Int32, host: SpaceHelperHostIdentity,
                       displayUUID: UUID) throws -> ReadOnlySpaceValue? {
        guard data.count <= maximumOutputBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let record = object as? [String: Any], Set(record.keys) == keys,
              integer(record["osMajor"]) == host.major,
              record["build"] as? String == host.build,
              record["displayUUID"] as? String == displayUUID.uuidString.uppercased(),
              boolean(record["adoption"]) == false
        else { throw SpaceHelperProcessError.invalidResponse }

        guard let kind = record["kind"] as? String,
              ["user", "system", "fullscreen", "unknown"].contains(kind)
        else { throw SpaceHelperProcessError.invalidResponse }

        let fields = try ResponseFields(record: record)
        if fields.error != nil {
            guard exitCode != 0 else { throw SpaceHelperProcessError.invalidResponse }
            return nil
        }
        guard exitCode == 0, fields.rawSpaceID != nil, let rawSpaceType = fields.rawSpaceType else {
            throw SpaceHelperProcessError.invalidResponse
        }
        guard rawSpaceType == 0, fields.kind == "user" else { return nil }
        guard let candidate = fields.candidate else { throw SpaceHelperProcessError.invalidResponse }
        return ReadOnlySpaceValue(id: candidate, kind: .regular)
    }

    private struct ResponseFields {
        let error: String?
        let rawSpaceID: UInt64?
        let rawSpaceType: Int32?
        let kind: String
        let candidate: String?

        init(record: [String: Any]) throws {
            guard let kind = record["kind"] as? String,
                  ["user", "system", "fullscreen", "unknown"].contains(kind)
            else { throw SpaceHelperProcessError.invalidResponse }
            self.kind = kind

            if record["error"] is NSNull {
                error = nil
            } else if let value = record["error"] as? String, helperErrors.contains(value) {
                error = value
            } else {
                throw SpaceHelperProcessError.invalidResponse
            }

            if record["rawSpaceID"] is NSNull {
                rawSpaceID = nil
            } else if let value = record["rawSpaceID"] as? String,
                      let parsed = UInt64(value), parsed > 0, String(parsed) == value {
                rawSpaceID = parsed
            } else {
                throw SpaceHelperProcessError.invalidResponse
            }

            if record["rawSpaceType"] is NSNull {
                rawSpaceType = nil
            } else {
                guard let parsed = integer(record["rawSpaceType"]), let checked = Int32(exactly: parsed) else {
                    throw SpaceHelperProcessError.invalidResponse
                }
                rawSpaceType = checked
            }

            if record["spaceUUIDCandidate"] is NSNull {
                candidate = nil
            } else if let value = record["spaceUUIDCandidate"] as? String,
                      canonicalUUID(value) == value {
                candidate = value
            } else {
                throw SpaceHelperProcessError.invalidResponse
            }

            let expectedKind: String
            if let rawSpaceType {
                switch rawSpaceType {
                case 0: expectedKind = "user"
                case 2: expectedKind = "system"
                case 4: expectedKind = "fullscreen"
                default: expectedKind = "unknown"
                }
            } else {
                expectedKind = "unknown"
            }
            guard kind == expectedKind else { throw SpaceHelperProcessError.invalidResponse }
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let cfNumber = unsafeDowncast(number as CFTypeRef, to: CFNumber.self)
        guard !CFNumberIsFloatType(cfNumber),
              let result = Int(number.stringValue),
              number.stringValue == String(result)
        else { return nil }
        return result
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func canonicalUUID(_ value: String) -> String? {
        guard value.utf8.count == 36, let uuid = UUID(uuidString: value) else { return nil }
        return uuid.uuidString.uppercased()
    }
}

final class SpaceHelperProcessRunner: @unchecked Sendable {
    private let queue: DispatchQueue
    private let executableURL: @Sendable () -> URL?
    private let hostIdentity: @Sendable () -> SpaceHelperHostIdentity?
    private let argumentPrefix: [String]
    private let childStarted: @Sendable (pid_t) -> Void

    init() {
        queue = DispatchQueue(label: "AppAlign.SpaceHelperProcess", qos: .utility)
        executableURL = { Bundle.main.url(forAuxiliaryExecutable: "AppAlignSpaceHelper") }
        hostIdentity = SpaceHelperHostIdentity.current
        argumentPrefix = []
        childStarted = { _ in }
    }

    /// Dependency injection is reserved for process-lifecycle tests; production uses the bundle helper above.
    init(testExecutableURL: URL?, testHostIdentity: SpaceHelperHostIdentity? = .supported,
         testArgumentPrefix: [String] = [], childStarted: @escaping @Sendable (pid_t) -> Void = { _ in }) {
        queue = DispatchQueue(label: "AppAlign.SpaceHelperProcess.Tests", qos: .utility)
        executableURL = { testExecutableURL }
        hostIdentity = { testHostIdentity }
        argumentPrefix = testArgumentPrefix
        self.childStarted = childStarted
    }

    func snapshot(for displayUUID: UUID, deadline: UInt64) async throws -> ReadOnlySpaceValue? {
        try Task.checkCancellation()
        let cancellation = SpaceHelperCancellation()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    do {
                        let value = try run(displayUUID: displayUUID, deadline: deadline, cancellation: cancellation)
                        continuation.resume(returning: value)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()
        return result
    }

    private func run(displayUUID: UUID, deadline: UInt64,
                     cancellation: SpaceHelperCancellation) throws -> ReadOnlySpaceValue? {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let runnerDeadline = min(deadline, startedAt &+ 250_000_000)
        guard startedAt < runnerDeadline else { throw SpaceHelperProcessError.deadlineExpired }
        guard !cancellation.isCancelled else { throw SpaceHelperProcessError.cancelled }
        guard let host = hostIdentity(), host == .supported else { throw SpaceHelperProcessError.unsupportedHost }
        guard let executableURL = executableURL() else { throw SpaceHelperProcessError.helperUnavailable }
        guard DispatchTime.now().uptimeNanoseconds < runnerDeadline else { throw SpaceHelperProcessError.deadlineExpired }
        guard !cancellation.isCancelled else { throw SpaceHelperProcessError.cancelled }

        let pipe = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = argumentPrefix + [
            "--expected-os-major", String(host.major),
            "--expected-build", host.build,
            "--display-uuid", displayUUID.uuidString.uppercased()
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.closeFile()
            pipe.fileHandleForWriting.closeFile()
            throw SpaceHelperProcessError.launchFailed
        }

        let pid = process.processIdentifier
        childStarted(pid)
        pipe.fileHandleForWriting.closeFile()
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let currentFlags = fcntl(descriptor, F_GETFL)
        guard currentFlags >= 0, fcntl(descriptor, F_SETFL, currentFlags | O_NONBLOCK) >= 0 else {
            terminateAndReap(process, pipe: pipe)
            throw SpaceHelperProcessError.launchFailed
        }

        do {
            let payload = try capture(process: process, descriptor: descriptor, deadline: runnerDeadline,
                                      cancellation: cancellation)
            process.waitUntilExit()
            pipe.fileHandleForReading.closeFile()
            guard !cancellation.isCancelled else { throw SpaceHelperProcessError.cancelled }
            return try SpaceHelperResponseDecoder.decode(payload, exitCode: process.terminationStatus,
                                                         host: host, displayUUID: displayUUID)
        } catch {
            terminateAndReap(process, pipe: pipe)
            throw error
        }
    }

    private func capture(process: Process, descriptor: Int32, deadline: UInt64,
                         cancellation: SpaceHelperCancellation) throws -> Data {
        var output = Data()
        var reachedEOF = false
        while !reachedEOF || process.isRunning {
            if cancellation.isCancelled { throw SpaceHelperProcessError.cancelled }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw SpaceHelperProcessError.timedOut }
            let remaining = deadline - now
            let timeoutMilliseconds = Int32(min(UInt64(25), max(UInt64(1), remaining / 1_000_000)))
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
            let pollResult = reachedEOF ? poll(nil, 0, timeoutMilliseconds) : poll(&pollDescriptor, 1, timeoutMilliseconds)
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw SpaceHelperProcessError.launchFailed
            }
            guard pollResult > 0 else { continue }
            if reachedEOF { continue }

            while true {
                var bytes = [UInt8](repeating: 0, count: min(512, SpaceHelperResponseDecoder.maximumOutputBytes + 1 - output.count))
                let count = bytes.withUnsafeMutableBytes { buffer in
                    read(descriptor, buffer.baseAddress, buffer.count)
                }
                if count > 0 {
                    output.append(contentsOf: bytes.prefix(count))
                    if output.count > SpaceHelperResponseDecoder.maximumOutputBytes {
                        throw SpaceHelperProcessError.outputTooLarge
                    }
                } else if count == 0 {
                    reachedEOF = true
                    break
                } else if errno == EINTR {
                    continue
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    break
                } else {
                    throw SpaceHelperProcessError.launchFailed
                }
            }
        }
        return output
    }

    private func terminateAndReap(_ process: Process, pipe: Pipe) {
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        pipe.fileHandleForReading.closeFile()
        pipe.fileHandleForWriting.closeFile()
    }
}

private final class SpaceHelperCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}
