import CoreFoundation
import Darwin
import Foundation

// Private ABI candidate source (not an Apple ABI contract):
// yabai commit dd845723416f5fe92af49fad5ebab00369e07edd,
// src/misc/extern.h:42,56,57,60; src/display.c:197-213,225-249;
// src/space.c:88-100; src/view.c:995,1039; src/space_manager.c:1166-1195.
// Additional signatures and call-site links are documented in issue-12-validation.md.
// Only these read-only functions and SLSMainConnectionID are looked up after both OS guards pass.

private struct ProbeOutput: Encodable {
    let osMajor: Int?
    let build: String?
    let displayUUID: String?
    let rawSpaceID: String?
    let kind: String
    let error: String?
    let adoption: Bool
    let rawSpaceType: Int?
    let spaceUUIDCandidate: String?

    init(osMajor: Int?, build: String?, displayUUID: String?, rawSpaceID: String?, kind: String,
         error: String?, adoption: Bool, rawSpaceType: Int? = nil, spaceUUIDCandidate: String? = nil) {
        self.osMajor = osMajor
        self.build = build
        self.displayUUID = displayUUID
        self.rawSpaceID = rawSpaceID
        self.kind = kind
        self.error = error
        self.adoption = adoption
        self.rawSpaceType = rawSpaceType
        self.spaceUUIDCandidate = spaceUUIDCandidate
    }

    enum CodingKeys: String, CodingKey {
        case osMajor
        case build
        case displayUUID
        case rawSpaceID
        case kind
        case error
        case adoption
        case rawSpaceType
        case spaceUUIDCandidate
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
        if let rawSpaceType { try container.encode(rawSpaceType, forKey: .rawSpaceType) } else { try container.encodeNil(forKey: .rawSpaceType) }
        if let spaceUUIDCandidate { try container.encode(spaceUUIDCandidate, forKey: .spaceUUIDCandidate) } else { try container.encodeNil(forKey: .spaceUUIDCandidate) }
    }
}

private typealias MainConnectionFunction = @convention(c) () -> Int32
private typealias CurrentSpaceFunction = @convention(c) (Int32, CFString) -> UInt64
private typealias SpaceTypeFunction = @convention(c) (Int32, UInt64) -> Int32
private typealias ManagedDisplaySpacesFunction = @convention(c) (Int32) -> Unmanaged<CFArray>?
private typealias SpaceCopyNameFunction = @convention(c) (Int32, UInt64) -> Unmanaged<CFString>?

private func emit(_ output: ProbeOutput, exitCode: Int32) -> Never {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    if let data = try? encoder.encode(output), let line = String(data: data, encoding: .utf8) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    } else {
        FileHandle.standardOutput.write(Data("{\"adoption\":false,\"build\":null,\"displayUUID\":null,\"error\":\"json_encode_failed\",\"kind\":\"unknown\",\"osMajor\":null,\"rawSpaceID\":null,\"rawSpaceType\":null,\"spaceUUIDCandidate\":null}\n".utf8))
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
    // Signatures below are copied from the pinned yabai declarations and call sites,
    // not from Apple documentation. unsafeBitCast is limited to these dlsym results;
    // the probe must never use any mutating Space/window symbol.
    guard let connectionSymbol = dlsym(framework, "SLSMainConnectionID") else {
        emit(ProbeOutput(osMajor: version.majorVersion, build: build, displayUUID: canonicalUUID, rawSpaceID: nil,
                         kind: "unknown", error: "main_connection_symbol_missing", adoption: false), exitCode: 3)
    }
    guard let currentSpaceSymbol = dlsym(framework, "SLSManagedDisplayGetCurrentSpace") else {
        emit(ProbeOutput(osMajor: version.majorVersion, build: build, displayUUID: canonicalUUID, rawSpaceID: nil,
                         kind: "unknown", error: "current_space_symbol_missing", adoption: false), exitCode: 3)
    }
    guard let spaceTypeSymbol = dlsym(framework, "SLSSpaceGetType") else {
        emit(ProbeOutput(osMajor: version.majorVersion, build: build, displayUUID: canonicalUUID, rawSpaceID: nil,
                         kind: "unknown", error: "space_type_symbol_missing", adoption: false), exitCode: 3)
    }
    guard let managedSpacesSymbol = dlsym(framework, "SLSCopyManagedDisplaySpaces") else {
        emit(ProbeOutput(osMajor: version.majorVersion, build: build, displayUUID: canonicalUUID, rawSpaceID: nil,
                         kind: "unknown", error: "managed_display_spaces_symbol_missing", adoption: false), exitCode: 3)
    }
    guard let spaceNameSymbol = dlsym(framework, "SLSSpaceCopyName") else {
        emit(ProbeOutput(osMajor: version.majorVersion, build: build, displayUUID: canonicalUUID, rawSpaceID: nil,
                         kind: "unknown", error: "space_copy_name_symbol_missing", adoption: false), exitCode: 3)
    }

    let mainConnection = unsafeBitCast(connectionSymbol, to: MainConnectionFunction.self)
    let currentSpace = unsafeBitCast(currentSpaceSymbol, to: CurrentSpaceFunction.self)
    let spaceType = unsafeBitCast(spaceTypeSymbol, to: SpaceTypeFunction.self)
    let managedDisplaySpaces = unsafeBitCast(managedSpacesSymbol, to: ManagedDisplaySpacesFunction.self)
    let spaceCopyName = unsafeBitCast(spaceNameSymbol, to: SpaceCopyNameFunction.self)
    let connection = mainConnection()
    guard connection > 0 else {
        emit(ProbeOutput(osMajor: version.majorVersion, build: build, displayUUID: canonicalUUID, rawSpaceID: nil,
                         kind: "unknown", error: "main_connection_failed", adoption: false), exitCode: 3)
    }

    let rawSpaceID = currentSpace(connection, canonicalUUID as CFString)
    guard rawSpaceID != 0 else {
        dlclose(framework)
        emit(ProbeOutput(osMajor: version.majorVersion, build: build, displayUUID: canonicalUUID, rawSpaceID: nil,
                         kind: "unknown", error: "zero_space_id", adoption: false), exitCode: 3)
    }

    do {
        let displayMetadata = managedDisplaySpaces(connection)
        guard let displayMetadata else { throw SpaceProbeFailure.managedDisplaySpacesUnavailable }
        // The +1 Copy result is consumed exactly once; all array/dictionary children
        // are borrowed and remain owned by this array.
        let metadata = displayMetadata.takeRetainedValue()
        _ = try decodeManagedDisplaySpaces(metadata, displayUUID: canonicalUUID, currentSpaceID: rawSpaceID)
    } catch let failure as SpaceProbeFailure {
        dlclose(framework)
        emit(ProbeOutput(osMajor: version.majorVersion, build: build, displayUUID: canonicalUUID,
                         rawSpaceID: String(rawSpaceID), kind: "unknown", error: failure.rawValue, adoption: false), exitCode: 3)
    } catch {
        dlclose(framework)
        emit(ProbeOutput(osMajor: version.majorVersion, build: build, displayUUID: canonicalUUID,
                         rawSpaceID: String(rawSpaceID), kind: "unknown", error: "invalid_display_metadata", adoption: false), exitCode: 3)
    }

    let rawSpaceType = spaceType(connection, rawSpaceID)
    let kind = kindForSpaceType(rawSpaceType)
    guard let kind else {
        dlclose(framework)
        emit(ProbeOutput(osMajor: version.majorVersion, build: build, displayUUID: canonicalUUID,
                         rawSpaceID: String(rawSpaceID), kind: "unknown", error: "unsupported_space_type",
                         adoption: false, rawSpaceType: Int(rawSpaceType)), exitCode: 3)
    }
    let nameResult = spaceCopyName(connection, rawSpaceID)
    guard let nameResult else {
        dlclose(framework)
        emit(ProbeOutput(osMajor: version.majorVersion, build: build, displayUUID: canonicalUUID,
                         rawSpaceID: String(rawSpaceID), kind: kind, error: "invalid_space_uuid",
                         adoption: false, rawSpaceType: Int(rawSpaceType)), exitCode: 3)
    }
    // SLSSpaceCopyName is a Copy result. Consume/release it in this scope and expose
    // only UUID-shaped strings; arbitrary user Space names are never emitted.
    let candidate: String? = {
        let copiedName = nameResult.takeRetainedValue()
        return spaceUUIDCandidate(from: copiedName)
    }()
    guard let candidate else {
        dlclose(framework)
        emit(ProbeOutput(osMajor: version.majorVersion, build: build, displayUUID: canonicalUUID,
                         rawSpaceID: String(rawSpaceID), kind: kind, error: "invalid_space_uuid",
                         adoption: false, rawSpaceType: Int(rawSpaceType)), exitCode: 3)
    }
    let secondSpaceID = currentSpace(connection, canonicalUUID as CFString)
    do {
        _ = try verifyCurrentSpaceIDs(before: rawSpaceID, after: secondSpaceID)
    } catch let failure as SpaceProbeFailure {
        dlclose(framework)
        emit(ProbeOutput(osMajor: version.majorVersion, build: build, displayUUID: canonicalUUID,
                         rawSpaceID: String(rawSpaceID), kind: kind, error: failure.rawValue,
                         adoption: false, rawSpaceType: Int(rawSpaceType), spaceUUIDCandidate: candidate), exitCode: 3)
    } catch {
        dlclose(framework)
        emit(ProbeOutput(osMajor: version.majorVersion, build: build, displayUUID: canonicalUUID,
                         rawSpaceID: String(rawSpaceID), kind: kind, error: "space_changed_during_probe",
                         adoption: false, rawSpaceType: Int(rawSpaceType), spaceUUIDCandidate: candidate), exitCode: 3)
    }
    dlclose(framework)

    emit(ProbeOutput(osMajor: version.majorVersion, build: build, displayUUID: canonicalUUID,
                     rawSpaceID: String(rawSpaceID), kind: kind,
                     error: nil, adoption: false, rawSpaceType: Int(rawSpaceType),
                     spaceUUIDCandidate: candidate), exitCode: 0)
}

@main
private struct SpaceProbeMain {
    static func main() {
        run()
    }
}
