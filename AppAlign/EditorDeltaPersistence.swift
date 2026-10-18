import Foundation

extension PersistentStoreCoordinator {
    /// Merge the editor's fixed target into the latest stores after an await.
    func mergeEditorDelta(layout: PersistedLayout, assignment: PersistedAssignment?) throws {
        try ensureWritable("layouts")
        let loadedLayouts = try loadStore(LayoutStore.self, at: urls.layouts, name: "layouts",
                                          default: LayoutStore(layouts: [Self.defaultLayout()]),
                                          validate: Self.validateLayouts)
        var layouts = Dictionary(uniqueKeysWithValues: loadedLayouts.value.layouts.map { ($0.id, $0) })
        layouts[layout.id] = layout
        let orderedLayouts = layouts.values.sorted { $0.id.uuidString < $1.id.uuidString }
        try Self.validateLayouts(LayoutStore(layouts: orderedLayouts))
        guard let assignment else {
            try saveLayouts(orderedLayouts)
            return
        }

        try ensureWritable("assignments")
        guard layouts[assignment.layoutID] != nil else {
            throw PersistenceError.invalidData("assignment references a missing layout")
        }
        let loadedAssignments = try loadStore(AssignmentStore.self, at: urls.assignments, name: "assignments",
                                              default: AssignmentStore(assignments: []),
                                              validate: Self.validateAssignments)
        var assignments = PersistedAssignments(loadedAssignments.value.assignments)
        assignments[assignment.key] = assignment
        try Self.validateAssignments(AssignmentStore(assignments: assignments.values))
        try saveLayouts(orderedLayouts)
        try saveAssignments(assignments.values)
    }
}
