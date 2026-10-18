import CoreFoundation
import Darwin
import Foundation

// Private ABI candidate source (not an Apple ABI contract):
// yabai commit dd845723416f5fe92af49fad5ebab00369e07edd,
// src/misc/extern.h:42 and src/display.c:179-187.
// The pinned declaration is uint64_t SLSManagedDisplayGetCurrentSpace(int, CFStringRef).
// Only this query and SLSMainConnectionID are looked up after both OS guards pass.

private struct ProbeOutput: Encodable {
    let osMajor: Int?
    let build: String?
    let displayUUID: String?
    let rawSpaceID: String?
    let kind: String
    let error: String?
    let adoption: Bool

    enum CodingKeys: String, CodingKey {
        case osMajor
        case build
        case displayUUID
        case rawSpaceID
        case kind
        case error
        case adoption
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let osMajor { try container.encode(osMajor, forKey: .osMajor) } else { try container.encodeNil(forKey: .osMajor) }
        if let build { try container.encode(build, forKey: .build) } else { try container.encodeNil(forKey: .build) }
        if let displayUUID { try container.encode(displayUUID, forKey: .displayUUID) } else { try container.encodeNil(forKey: .displayUUID) }
        if let rawSpaceID { try container.encode(rawSpaceID, forKey: .rawSpaceID) } else { try container.encodeNil(forKey: .rawSpaceID) }
        try container.encode(kind, forKey: .kind)
        if let error { try container.encode(error, forKey: .error) } else { try container.encodeNil(forKey: .error) }
        try container.encode(adoption, forKey: .adoption)
    }
}

private typealias MainConnectionFunction = @convention(c) () -> Int32
private typealias CurrentSpaceFunction = @convention(c) (Int32, CFString) -> UInt64

private func emit(_ output: ProbeOutput, exitCode: Int32) -> Never {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    if let data = try? encoder.encode(output), let line = String(data: data, encoding: .utf8) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    } else {
        FileHandle.standardOutput.write(Data("{\"adoption\":false,\"error\":\"json_encode_failed\",\"kind\":\"unknown\"}\n".utf8))
    }
    exit(exitCode)
}

private func currentBuild() -> String? {
    var requiredSize = 0
    guard sysctlbyname("kern.osversion", nil, &requiredSize, nil, 0) == 0, requiredSize > 1 else {
        return nil
    }
    var buffer = [CChar](repeating: 0, count: requiredSize)
    guard sysctlbyname("kern.osversion", &buffer, &requiredSize, nil, 0) == 0 else {
        return nil
    }
    let terminated = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: terminated, as: UTF8.self)
}

private func uuidString(_ value: String) -> String? {
    guard value.utf8.count == 36, let uuid = UUID(uuidString: value) else { return nil }
    return uuid.uuidString.uppercased()
}

private func run() -> Never {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--help"] {
        print("Usage: space-probe --expected-os-major 27 --expected-build BUILD --display-uuid UUID")
        print("Read-only isolated Space ID probe; adoption is always false.")
        exit(0)
    }

    guard arguments.count == 6,
          arguments[0] == "--expected-os-major",
          arguments[2] == "--expected-build",
          arguments[4] == "--display-uuid"
    else {
        emit(ProbeOutput(osMajor: nil, build: currentBuild(), displayUUID: nil, rawSpaceID: nil,
                         kind: "unknown", error: "invalid_arguments", adoption: false), exitCode: 2)
    }

    guard let expectedOSMajor = Int(arguments[1]) else {
        emit(ProbeOutput(osMajor: nil, build: currentBuild(), displayUUID: nil, rawSpaceID: nil,
                         kind: "unknown", error: "invalid_expected_os_major", adoption: false), exitCode: 2)
    }
    let expectedBuild = arguments[3]
    let suppliedUUID = arguments[5]
    let version = ProcessInfo.processInfo.operatingSystemVersion
    let build = currentBuild()
    let canonicalUUID = uuidString(suppliedUUID)

    // This probe was scoped specifically to the verified macOS 27 host. The input
    // cannot broaden that allowlist or spoof the running OS.
    guard expectedOSMajor == 27, version.majorVersion == expectedOSMajor else {
        emit(ProbeOutput(osMajor: version.majorVersion, build: build, displayUUID: canonicalUUID, rawSpaceID: nil,
                         kind: "unknown", error: "unsupported_os_major", adoption: false), exitCode: 2)
    }
    guard let build, build == expectedBuild else {
        emit(ProbeOutput(osMajor: version.majorVersion, build: build, displayUUID: canonicalUUID, rawSpaceID: nil,
                         kind: "unknown", error: "build_mismatch_or_unavailable", adoption: false), exitCode: 2)
    }
    guard let canonicalUUID else {
        emit(ProbeOutput(osMajor: version.majorVersion, build: build, displayUUID: nil, rawSpaceID: nil,
                         kind: "unknown", error: "invalid_display_uuid", adoption: false), exitCode: 2)
    }

    guard let framework = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
        RTLD_LAZY | RTLD_LOCAL
    ) else {
        emit(ProbeOutput(osMajor: version.majorVersion, build: build, displayUUID: canonicalUUID, rawSpaceID: nil,
                         kind: "unknown", error: "skylight_unavailable", adoption: false), exitCode: 3)
    }
    // The two signatures below are copied from the pinned yabai declaration and its
    // call site, not from Apple documentation. unsafeBitCast is limited to these
    // two dlsym results; the probe must never use any mutating Space/window symbol.
    guard let connectionSymbol = dlsym(framework, "SLSMainConnectionID") else {
        emit(ProbeOutput(osMajor: version.majorVersion, build: build, displayUUID: canonicalUUID, rawSpaceID: nil,
                         kind: "unknown", error: "main_connection_symbol_missing", adoption: false), exitCode: 3)
    }
    guard let currentSpaceSymbol = dlsym(framework, "SLSManagedDisplayGetCurrentSpace") else {
        emit(ProbeOutput(osMajor: version.majorVersion, build: build, displayUUID: canonicalUUID, rawSpaceID: nil,
                         kind: "unknown", error: "current_space_symbol_missing", adoption: false), exitCode: 3)
    }

    let mainConnection = unsafeBitCast(connectionSymbol, to: MainConnectionFunction.self)
    let currentSpace = unsafeBitCast(currentSpaceSymbol, to: CurrentSpaceFunction.self)
    let connection = mainConnection()
    guard connection > 0 else {
        emit(ProbeOutput(osMajor: version.majorVersion, build: build, displayUUID: canonicalUUID, rawSpaceID: nil,
                         kind: "unknown", error: "main_connection_failed", adoption: false), exitCode: 3)
    }

    let rawSpaceID = {
        let cfUUID = CFUUIDCreateFromString(kCFAllocatorDefault, canonicalUUID as CFString)!
        let cfUUIDString = CFUUIDCreateString(kCFAllocatorDefault, cfUUID)!
        // Swift ARC owns the +1 CFCreate results and releases them at scope exit,
        // matching the pinned C call site's explicit post-call CFRelease.
        return currentSpace(connection, cfUUIDString)
    }()
    dlclose(framework)
    guard rawSpaceID != 0 else {
        emit(ProbeOutput(osMajor: version.majorVersion, build: build, displayUUID: canonicalUUID, rawSpaceID: nil,
                         kind: "unknown", error: "zero_space_id", adoption: false), exitCode: 3)
    }

    emit(ProbeOutput(osMajor: version.majorVersion, build: build, displayUUID: canonicalUUID,
                     rawSpaceID: String(rawSpaceID), kind: "unknown",
                     error: nil, adoption: false), exitCode: 0)
}

run()
