import CoreFoundation
import Foundation

@main
private struct SpaceProbeFixtureTests {
    static func main() throws {
        let target = "D16814E6-E4F8-4D8F-0857-D6964E3302DB"
        let other = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let valid = display(target, spaces: [space(NSNumber(value: 41)), space(NSNumber(value: 42))])
        let snapshot = try decodeManagedDisplaySpaces(array([valid]), displayUUID: target, currentSpaceID: 41)
        check(snapshot == ManagedDisplaySpaceSnapshot(matchingDisplayCount: 1, matchingCurrentSpaceCount: 1),
              "target display/current ID decodes")
        try check(decodeManagedDisplaySpaces(array([display(target, spaces: [space(NSNumber(value: UInt64.max))])]),
                                             displayUUID: target, currentSpaceID: UInt64.max).matchingCurrentSpaceCount == 1,
                  "UInt64 maximum is decoded without Double conversion")
        try check(decodeManagedDisplaySpaces(array([display(other, spaces: [space(NSNumber(value: 41))]), valid]),
                                             displayUUID: target, currentSpaceID: 41).matchingDisplayCount == 1,
                  "another display with same current ID is not selected")
        expectFailure(.displayUUIDNotFound) {
            try decodeManagedDisplaySpaces(array([display(other, spaces: [space(NSNumber(value: 41))])]),
                                           displayUUID: target, currentSpaceID: 41)
        }
        expectFailure(.managedDisplaySpacesUnavailable) {
            try decodeManagedDisplaySpaces("not-an-array" as CFTypeRef, displayUUID: target, currentSpaceID: 41)
        }
        expectFailure(.invalidDisplayMetadata) {
            try decodeManagedDisplaySpaces(array([NSDictionary(dictionary: ["Spaces": [space(NSNumber(value: 41))]])]),
                                           displayUUID: target, currentSpaceID: 41)
        }
        expectFailure(.invalidDisplayMetadata) {
            try decodeManagedDisplaySpaces(array([NSDictionary(dictionary: ["Display Identifier": NSNumber(value: 7),
                                                                            "Spaces": [space(NSNumber(value: 41))]])]),
                                           displayUUID: target, currentSpaceID: 41)
        }
        expectFailure(.ambiguousDisplayUUID) {
            try decodeManagedDisplaySpaces(array([valid, valid]), displayUUID: target, currentSpaceID: 41)
        }
        expectFailure(.invalidSpacesMetadata) {
            try decodeManagedDisplaySpaces(array([NSDictionary(dictionary: ["Display Identifier": target,
                                                                            "Spaces": "not-an-array"])]),
                                           displayUUID: target, currentSpaceID: 41)
        }
        expectFailure(.currentSpaceNotFound) {
            try decodeManagedDisplaySpaces(array([display(target, spaces: [space(NSNumber(value: 42))])]),
                                           displayUUID: target, currentSpaceID: 41)
        }
        expectFailure(.duplicateSpaceID) {
            try decodeManagedDisplaySpaces(array([display(target, spaces: [space(NSNumber(value: 41)),
                                                                            space(NSNumber(value: 41))])]),
                                           displayUUID: target, currentSpaceID: 41)
        }

        for invalidID: Any in [NSNumber(value: true), NSNumber(value: 4.5), NSNumber(value: -1), NSNumber(value: 0),
                               NSDecimalNumber(string: "18446744073709551616"), "41"] {
            expectFailure(.invalidSpaceID) {
                try decodeManagedDisplaySpaces(array([display(target, spaces: [space(invalidID)])]),
                                               displayUUID: target, currentSpaceID: 41)
            }
        }
        expectFailure(.invalidSpaceID) {
            try decodeManagedDisplaySpaces(array([display(target, spaces: [NSDictionary()])]),
                                           displayUUID: target, currentSpaceID: 41)
        }

        check(kindForSpaceType(0) == "user", "type 0 maps to user")
        check(kindForSpaceType(2) == "system", "type 2 maps to system")
        check(kindForSpaceType(4) == "fullscreen", "type 4 maps to fullscreen")
        check(kindForSpaceType(1) == nil, "unrecognized type remains unknown")
        check(spaceUUIDCandidate(from: target as CFString) == target, "UUID-shaped name becomes candidate")
        check(spaceUUIDCandidate(from: "Personal Space" as CFString) == nil, "user Space name is suppressed")
        check(spaceUUIDCandidate(from: NSNumber(value: 3)) == nil, "non-string name is suppressed")

        try check(verifyCurrentSpaceIDs(before: 41, after: 41) == 41, "stable before/after ID accepted")
        expectFailure(.spaceChangedDuringProbe) { try verifyCurrentSpaceIDs(before: 41, after: 42) }
        expectFailure(.zeroSpaceID) { try verifyCurrentSpaceIDs(before: 41, after: 0) }
        print("Space probe pure fixtures passed.")
    }

    private static func array(_ values: [Any]) -> CFTypeRef {
        values as NSArray as CFArray
    }

    private static func display(_ uuid: String, spaces: [Any]) -> NSDictionary {
        NSDictionary(dictionary: ["Display Identifier": uuid, "Spaces": spaces])
    }

    private static func space(_ id: Any) -> NSDictionary {
        NSDictionary(dictionary: ["id64": id])
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        guard try condition() else { fatalError("Fixture failed: \(message)") }
    }

    private static func expectFailure(_ expected: SpaceProbeFailure, _ operation: () throws -> Any) {
        do {
            _ = try operation()
            fatalError("Expected failure: \(expected.rawValue)")
        } catch let actual as SpaceProbeFailure {
            check(actual == expected, "expected \(expected.rawValue), received \(actual.rawValue)")
        } catch {
            fatalError("Unexpected error: \(error)")
        }
    }
}
