import Foundation

extension PersistentStoreCoordinator {
    func validateSpaceStoreShape(_ bytes: Data, name: String, schemaVersion: Int) throws {
        guard let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(root.keys) == ["schemaVersion", "value"],
              let value = root["value"] as? [String: Any] else { throw PersistenceError.invalidData("store envelope fields") }
        if name == "assignments" {
            guard Set(value.keys) == ["assignments"], let records = value["assignments"] as? [[String: Any]] else {
                throw PersistenceError.invalidData("assignment store fields")
            }
            for record in records {
                guard Set(record.keys) == ["displayUUID", "spaceScope", "layoutID"],
                      let scope = record["spaceScope"] else { throw PersistenceError.invalidData("assignment fields") }
                try validateScopeShape(scope, schemaVersion: schemaVersion)
            }
        } else {
            guard Set(value.keys) == ["records"], let records = value["records"] as? [[String: Any]] else {
                throw PersistenceError.invalidData("history store fields")
            }
            for record in records {
                guard Set(record.keys) == ["key", "zoneIDs", "revision"],
                      let key = record["key"] as? [String: Any],
                      Set(key.keys) == ["bundleID", "displayUUID", "spaceScope", "layoutID"],
                      let scope = key["spaceScope"] else { throw PersistenceError.invalidData("history record fields") }
                try validateScopeShape(scope, schemaVersion: schemaVersion)
            }
        }
    }

    private func validateScopeShape(_ scope: Any, schemaVersion: Int) throws {
        if schemaVersion == 1 {
            guard let legacy = scope as? String, legacy == "common" else {
                throw PersistenceError.invalidData("legacy scope")
            }
        } else {
            guard let tagged = scope as? [String: Any], Set(tagged.keys).contains("kind"),
                  let kind = tagged["kind"] as? String else { throw PersistenceError.invalidData("scope fields") }
            if kind == "common" {
                guard Set(tagged.keys) == ["kind"] else { throw PersistenceError.invalidData("common scope fields") }
            } else if kind == "space" {
                guard Set(tagged.keys) == ["kind", "space"],
                      let space = tagged["space"] as? [String: Any],
                      Set(space.keys) == ["backend", "opaqueID"],
                      let backend = space["backend"] as? String, !backend.isEmpty,
                      backend.trimmingCharacters(in: .whitespacesAndNewlines) == backend,
                      let opaqueID = space["opaqueID"] as? String, !opaqueID.isEmpty,
                      opaqueID.trimmingCharacters(in: .whitespacesAndNewlines) == opaqueID else {
                    throw PersistenceError.invalidData("persistent Space scope fields")
                }
            } else {
                throw PersistenceError.invalidData("unknown scope kind")
            }
        }
    }

    func validateLegacyCommonScope<Value>(_ value: Value, name: String) throws {
        if name == "assignments", let store = value as? AssignmentStore,
           store.assignments.contains(where: { $0.spaceScope != .common }) {
            throw PersistenceError.invalidData("legacy assignments must be common")
        }
        if name == "app-zone-history", let store = value as? AppZoneHistoryStore,
           store.records.contains(where: { $0.key.spaceScope != .common }) {
            throw PersistenceError.invalidData("legacy history must be common")
        }
    }
}
