import CoreFoundation
import Foundation

enum SpaceProbeFailure: String, Error {
    case managedDisplaySpacesUnavailable = "managed_display_spaces_unavailable"
    case invalidDisplayMetadata = "invalid_display_metadata"
    case displayUUIDNotFound = "display_uuid_not_found"
    case ambiguousDisplayUUID = "ambiguous_display_uuid"
    case invalidSpacesMetadata = "invalid_spaces_metadata"
    case invalidSpaceID = "invalid_space_id"
    case duplicateSpaceID = "duplicate_space_id"
    case currentSpaceNotFound = "current_space_not_found"
    case ambiguousCurrentSpaceID = "ambiguous_current_space_id"
    case invalidSpaceUUID = "invalid_space_uuid"
    case spaceChangedDuringProbe = "space_changed_during_probe"
    case zeroSpaceID = "zero_space_id"
    case unsupportedSpaceType = "unsupported_space_type"
}

func verifyCurrentSpaceIDs(before: UInt64, after: UInt64) throws -> UInt64 {
    guard before > 0, after > 0 else { throw SpaceProbeFailure.zeroSpaceID }
    guard before == after else { throw SpaceProbeFailure.spaceChangedDuringProbe }
    return before
}

struct ManagedDisplaySpaceSnapshot: Equatable {
    let matchingDisplayCount: Int
    let matchingCurrentSpaceCount: Int
}

func kindForSpaceType(_ rawType: Int32) -> String? {
    switch rawType {
    case 0: "user"
    case 2: "system"
    case 4: "fullscreen"
    default: nil
    }
}

func spaceUUIDCandidate(from value: CFTypeRef?) -> String? {
    guard let value, CFGetTypeID(value) == CFStringGetTypeID(),
          let text = value as? String,
          text.utf8.count == 36,
          let uuid = UUID(uuidString: text)
    else { return nil }
    return uuid.uuidString.uppercased()
}

func decodeManagedDisplaySpaces(
    _ value: CFTypeRef?,
    displayUUID: String,
    currentSpaceID: UInt64
) throws -> ManagedDisplaySpaceSnapshot {
    guard let value, CFGetTypeID(value) == CFArrayGetTypeID() else {
        throw SpaceProbeFailure.managedDisplaySpacesUnavailable
    }
    let displays = unsafeDowncast(value, to: CFArray.self)
    var matchingDisplays = 0
    var matchingCurrentSpaces = 0

    for displayIndex in 0..<CFArrayGetCount(displays) {
        guard let displayPointer = CFArrayGetValueAtIndex(displays, displayIndex) else {
            throw SpaceProbeFailure.invalidDisplayMetadata
        }
        let displayValue = Unmanaged<AnyObject>.fromOpaque(displayPointer).takeUnretainedValue()
        guard CFGetTypeID(displayValue) == CFDictionaryGetTypeID() else {
            throw SpaceProbeFailure.invalidDisplayMetadata
        }
        let display = unsafeDowncast(displayValue, to: CFDictionary.self)
        guard let identifierValue = dictionaryValue(display, key: "Display Identifier"),
              CFGetTypeID(identifierValue) == CFStringGetTypeID(),
              let identifier = identifierValue as? String
        else { throw SpaceProbeFailure.invalidDisplayMetadata }

        guard identifier.uppercased() == displayUUID else { continue }
        matchingDisplays += 1
        guard let spacesValue = dictionaryValue(display, key: "Spaces"),
              CFGetTypeID(spacesValue) == CFArrayGetTypeID()
        else { throw SpaceProbeFailure.invalidSpacesMetadata }
        let spaces = unsafeDowncast(spacesValue, to: CFArray.self)
        var foundIDs = Set<UInt64>()
        for spaceIndex in 0..<CFArrayGetCount(spaces) {
            guard let spacePointer = CFArrayGetValueAtIndex(spaces, spaceIndex) else {
                throw SpaceProbeFailure.invalidSpacesMetadata
            }
            let spaceValue = Unmanaged<AnyObject>.fromOpaque(spacePointer).takeUnretainedValue()
            guard CFGetTypeID(spaceValue) == CFDictionaryGetTypeID() else {
                throw SpaceProbeFailure.invalidSpacesMetadata
            }
            let space = unsafeDowncast(spaceValue, to: CFDictionary.self)
            guard let idValue = dictionaryValue(space, key: "id64"),
                  CFGetTypeID(idValue) == CFNumberGetTypeID(),
                  CFGetTypeID(idValue) != CFBooleanGetTypeID()
            else { throw SpaceProbeFailure.invalidSpaceID }
            let number = unsafeDowncast(idValue, to: CFNumber.self)
            guard !CFNumberIsFloatType(number) else { throw SpaceProbeFailure.invalidSpaceID }
            let numberObject = unsafeDowncast(idValue, to: NSNumber.self)
            guard let spaceID = UInt64(numberObject.stringValue), spaceID > 0 else {
                throw SpaceProbeFailure.invalidSpaceID
            }
            guard foundIDs.insert(spaceID).inserted else { throw SpaceProbeFailure.duplicateSpaceID }
            if spaceID == currentSpaceID { matchingCurrentSpaces += 1 }
        }
    }

    guard matchingDisplays > 0 else { throw SpaceProbeFailure.displayUUIDNotFound }
    guard matchingDisplays == 1 else { throw SpaceProbeFailure.ambiguousDisplayUUID }
    guard matchingCurrentSpaces > 0 else { throw SpaceProbeFailure.currentSpaceNotFound }
    guard matchingCurrentSpaces == 1 else { throw SpaceProbeFailure.ambiguousCurrentSpaceID }
    return ManagedDisplaySpaceSnapshot(matchingDisplayCount: matchingDisplays,
                                        matchingCurrentSpaceCount: matchingCurrentSpaces)
}

private func dictionaryValue(_ dictionary: CFDictionary, key: String) -> CFTypeRef? {
    let cfKey = key as CFString
    guard let pointer = CFDictionaryGetValue(dictionary, Unmanaged.passUnretained(cfKey).toOpaque()) else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
}
