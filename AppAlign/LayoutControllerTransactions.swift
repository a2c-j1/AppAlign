import CoreGraphics
import Foundation

@MainActor
extension LayoutController {
    func editorCatalog(for displayID: DisplaySelectionID) -> EditorCatalogSnapshot {
        let display = displayProvider.snapshot.displays.first { $0.id == displayID }
        let appliedID: UUID
        if let uuid = display?.persistentID?.uuid {
            appliedID = assignments[uuid]?.layoutID ?? PersistentStoreCoordinator.defaultLayoutID
        } else if case .session(let sessionID) = displayID {
            appliedID = sessionLayouts[sessionID]?.id ?? PersistentStoreCoordinator.defaultLayoutID
        } else {
            appliedID = PersistentStoreCoordinator.defaultLayoutID
        }
        var catalog = savedLayouts
        catalog[PersistentStoreCoordinator.defaultLayoutID] = catalog[PersistentStoreCoordinator.defaultLayoutID] ?? PersistentStoreCoordinator.defaultLayout()
        return EditorCatalogSnapshot(layouts: catalog.values.sorted { $0.id.uuidString < $1.id.uuidString }, appliedLayoutID: appliedID)
    }

    func saveEditorLayout(_ proposed: PersistedLayout, identity: EditorOperationIdentity, copyOnWrite: Bool = true) async -> EditorOperationResult {
        guard registerEditorIdentity(identity) else { return .failure("This editor operation is stale.") }
        guard let storeCoordinator else { return .failure("Persistent storage is unavailable.") }
        do { try proposed.validate() } catch { return .failure(error.localizedDescription) }
        let quickRevision = quickLayoutMutationRevision
        let base = saveChain
        let operation = Task<EditorOperationResult, Never> { @MainActor [weak self] in
            await base?.value
            guard let self, self.isCurrent(identity), self.acceptsChanges,
                  self.quickLayoutMutationRevision == quickRevision else { return .failure("This editor operation was superseded.") }
            do {
                guard let display = self.displayProvider.snapshot.displays.first(where: { $0.id == identity.targetDisplay }) else {
                    return .failure("The selected display is no longer connected.")
                }
                var candidate = proposed
                let targetUUID = display.persistentID?.uuid
                if copyOnWrite && (candidate.id == PersistentStoreCoordinator.defaultLayoutID || self.isApplied(candidate.id) || self.isShared(candidate.id, excluding: targetUUID)) {
                    candidate = try self.reidentified(candidate, id: UUID())
                }
                try candidate.validate()
                var layouts = self.savedLayouts
                layouts[candidate.id] = candidate
                try await storeCoordinator.saveLayouts(Array(layouts.values))
                guard self.quickLayoutMutationRevision == quickRevision else { return .failure("This editor operation was superseded by a layout switch.") }
                self.savedLayouts = layouts
                self.markEditorPersistenceSucceeded()
                guard self.isCurrent(identity) else { return .failure("This editor operation was superseded after saving.") }
                self.errorMessage = nil
                return .success(candidate)
            } catch {
                self.persistenceErrorMessage = error.localizedDescription
                self.errorMessage = error.localizedDescription
                if let loaded = try? await storeCoordinator.load(), self.quickLayoutMutationRevision == quickRevision {
                    self.adoptPersistedStatePreservingQuickSwitches(loaded)
                }
                return .failure(error.localizedDescription)
            }
        }
        saveChain = Task { @MainActor in _ = await operation.value }
        return await operation.value
    }

    func applyEditorLayout(_ id: UUID, identity: EditorOperationIdentity) async -> EditorOperationResult {
        guard registerEditorIdentity(identity) else { return .failure("This editor operation is stale.") }
        guard let storeCoordinator else { return .failure("Persistent storage is unavailable.") }
        let quickRevision = quickLayoutMutationRevision
        let base = saveChain
        let operation = Task<EditorOperationResult, Never> { @MainActor [weak self] in
            await base?.value
            guard let self, self.isCurrent(identity), self.acceptsChanges,
                  self.quickLayoutMutationRevision == quickRevision else { return .failure("This editor operation was superseded.") }
            guard let display = self.displayProvider.snapshot.displays.first(where: { $0.id == identity.targetDisplay }),
                  let layout = self.savedLayouts[id] ?? (id == PersistentStoreCoordinator.defaultLayoutID ? PersistentStoreCoordinator.defaultLayout() : nil) else {
                return .failure("The display or saved layout is no longer available.")
            }
            var persistedAssignment = false
            do {
                if let uuid = display.persistentID?.uuid {
                    var nextAssignments = self.assignments
                    nextAssignments[uuid] = PersistedAssignment(displayUUID: uuid, spaceScope: .common, layoutID: id)
                    var layouts = self.savedLayouts
                    layouts[layout.id] = layout
                    try await storeCoordinator.saveLayoutAndAssignments(Array(layouts.values), Array(nextAssignments.values))
                    guard self.quickLayoutMutationRevision == quickRevision else { return .failure("This editor operation was superseded by a layout switch.") }
                    self.savedLayouts = layouts
                    self.assignments = nextAssignments
                    persistedAssignment = true
                } else if case .session(let sessionID) = identity.targetDisplay {
                    self.sessionLayouts[sessionID] = layout
                } else {
                    return .failure("This display cannot be assigned for this session.")
                }
                if self.selectedDisplayID == identity.targetDisplay { self.showLayoutForSelectedDisplay() }
                self.markEditorPersistenceSucceeded(acknowledgesQuickAssignment: persistedAssignment)
                guard self.isCurrent(identity) else { return .failure("This editor operation was superseded after saving.") }
                return .success(layout)
            } catch {
                self.persistenceErrorMessage = error.localizedDescription
                self.errorMessage = error.localizedDescription
                if let loaded = try? await storeCoordinator.load(), self.quickLayoutMutationRevision == quickRevision {
                    self.adoptPersistedStatePreservingQuickSwitches(loaded)
                }
                return .failure(error.localizedDescription)
            }
        }
        saveChain = Task { @MainActor in _ = await operation.value }
        return await operation.value
    }

    func renameEditorLayout(_ id: UUID, to name: String, identity: EditorOperationIdentity) async -> EditorOperationResult {
        guard registerEditorIdentity(identity) else { return .failure("This editor operation is stale.") }
        guard id != PersistentStoreCoordinator.defaultLayoutID else { return .failure("The default layout cannot be renamed.") }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure("Enter a layout name.") }
        guard let storeCoordinator else { return .failure("Persistent storage is unavailable.") }
        let quickRevision = quickLayoutMutationRevision
        let base = saveChain
        let operation = Task<EditorOperationResult, Never> { @MainActor [weak self] in
            await base?.value
            guard let self, self.isCurrent(identity), self.acceptsChanges,
                  self.quickLayoutMutationRevision == quickRevision else { return .failure("This editor operation was superseded.") }
            guard self.displayProvider.snapshot.displays.contains(where: { $0.id == identity.targetDisplay }),
                  let current = self.savedLayouts[id], let definition = try? current.definition() else {
                return .failure("The selected layout is no longer available.")
            }
            let renamed = PersistedLayout(id: current.id, definition: definition, spacing: current.spacing,
                                          template: LayoutTemplate(rawValue: current.template) ?? .grid,
                                          zoneCount: current.zoneCount, name: trimmed)
            do {
                try renamed.validate()
                var layouts = self.savedLayouts
                layouts[id] = renamed
                try await storeCoordinator.saveLayouts(Array(layouts.values))
                guard self.quickLayoutMutationRevision == quickRevision else { return .failure("This editor operation was superseded by a layout switch.") }
                self.savedLayouts = layouts
                self.markEditorPersistenceSucceeded()
                guard self.isCurrent(identity) else { return .failure("This editor operation was superseded after saving.") }
                return .success(renamed)
            } catch {
                self.persistenceErrorMessage = error.localizedDescription
                self.errorMessage = error.localizedDescription
                if let loaded = try? await storeCoordinator.load(), self.quickLayoutMutationRevision == quickRevision {
                    self.adoptPersistedStatePreservingQuickSwitches(loaded)
                }
                return .failure(error.localizedDescription)
            }
        }
        saveChain = Task { @MainActor in _ = await operation.value }
        return await operation.value
    }

    func duplicateEditorLayout(_ id: UUID, identity: EditorOperationIdentity) async -> EditorOperationResult {
        guard registerEditorIdentity(identity) else { return .failure("This editor operation is stale.") }
        guard let storeCoordinator else { return .failure("Persistent storage is unavailable.") }
        let quickRevision = quickLayoutMutationRevision
        let base = saveChain
        let operation = Task<EditorOperationResult, Never> { @MainActor [weak self] in
            await base?.value
            guard let self, self.isCurrent(identity), self.acceptsChanges,
                  self.quickLayoutMutationRevision == quickRevision else { return .failure("This editor operation was superseded.") }
            guard self.displayProvider.snapshot.displays.contains(where: { $0.id == identity.targetDisplay }),
                  let source = self.savedLayouts[id] ?? (id == PersistentStoreCoordinator.defaultLayoutID ? PersistentStoreCoordinator.defaultLayout() : nil) else {
                return .failure("The selected layout is no longer available.")
            }
            do {
                let duplicate = try self.reidentified(source, id: UUID(), name: "\(source.name ?? source.template) Copy")
                try duplicate.validate()
                var layouts = self.savedLayouts
                layouts[duplicate.id] = duplicate
                try await storeCoordinator.saveLayouts(Array(layouts.values))
                guard self.quickLayoutMutationRevision == quickRevision else { return .failure("This editor operation was superseded by a layout switch.") }
                self.savedLayouts = layouts
                self.markEditorPersistenceSucceeded()
                guard self.isCurrent(identity) else { return .failure("This editor operation was superseded after saving.") }
                return .success(duplicate)
            } catch {
                self.persistenceErrorMessage = error.localizedDescription
                self.errorMessage = error.localizedDescription
                if let loaded = try? await storeCoordinator.load(), self.quickLayoutMutationRevision == quickRevision {
                    self.adoptPersistedStatePreservingQuickSwitches(loaded)
                }
                return .failure(error.localizedDescription)
            }
        }
        saveChain = Task { @MainActor in _ = await operation.value }
        return await operation.value
    }

    func deleteEditorLayout(_ id: UUID, identity: EditorOperationIdentity) async -> EditorOperationResult {
        guard registerEditorIdentity(identity) else { return .failure("This editor operation is stale.") }
        guard id != PersistentStoreCoordinator.defaultLayoutID, let storeCoordinator else {
            return .failure("This layout cannot be deleted.")
        }
        let quickRevision = quickLayoutMutationRevision
        let base = saveChain
        let operation = Task<EditorOperationResult, Never> { @MainActor [weak self] in
            await base?.value
            guard let self, self.isCurrent(identity), self.acceptsChanges,
                  self.quickLayoutMutationRevision == quickRevision else { return .failure("This editor operation was superseded.") }
            guard self.savedLayouts[id] != nil else { return .failure("This layout is no longer available.") }
            let nextAssignments = self.assignments.filter { $0.value.layoutID != id }
            var nextLayouts = self.savedLayouts
            nextLayouts.removeValue(forKey: id)
            do {
                try await storeCoordinator.saveAssignmentsAndLayouts(Array(nextAssignments.values), Array(nextLayouts.values))
                guard self.quickLayoutMutationRevision == quickRevision else { return .failure("This editor operation was superseded by a layout switch.") }
                self.assignments = nextAssignments
                self.savedLayouts = nextLayouts
                for sessionID in Array(self.sessionLayouts.keys) where self.sessionLayouts[sessionID]?.id == id {
                    self.sessionLayouts.removeValue(forKey: sessionID)
                }
                if self.selectedDisplayID == identity.targetDisplay || self.currentLayout.id == id { self.showLayoutForSelectedDisplay() }
                self.markEditorPersistenceSucceeded(acknowledgesQuickAssignment: true)
                guard self.isCurrent(identity) else { return .failure("This editor operation was superseded after saving.") }
                return .success(nil)
            } catch {
                self.persistenceErrorMessage = error.localizedDescription
                self.errorMessage = error.localizedDescription
                if let loaded = try? await storeCoordinator.load(), self.quickLayoutMutationRevision == quickRevision {
                    self.adoptPersistedStatePreservingQuickSwitches(loaded)
                }
                return .failure(error.localizedDescription)
            }
        }
        saveChain = Task { @MainActor in _ = await operation.value }
        return await operation.value
    }
}

@MainActor
extension LayoutController {
    @discardableResult
    func quickSwitchLayout(at point: CGPoint) -> PersistedLayout? {
        guard acceptsChanges, persistenceReady, placementValidity.isAccepting,
              let snapshot = appliedDragLayoutSnapshot(at: point) else { return nil }
        let catalog = quickSwitchLayoutCatalog()
        guard let currentIndex = catalog.firstIndex(where: { $0.id == snapshot.layout.id }), catalog.count > 1 else { return nil }
        let next = catalog[(currentIndex + 1) % catalog.count]
        return applyQuickLayout(next.id, at: point)
    }

    @discardableResult
    func applyQuickLayout(_ id: UUID, at point: CGPoint) -> PersistedLayout? {
        guard acceptsChanges, persistenceReady, placementValidity.isAccepting,
              let snapshot = appliedDragLayoutSnapshot(at: point),
              let next = quickSwitchLayoutCatalog().first(where: { $0.id == id }),
              snapshot.layout.id != id else { return nil }

        // Invalidate outstanding tickets before changing the assignment.
        placementValidity.invalidateForLayoutChange()
        dragLayoutRevision &+= 1
        quickLayoutMutationRevision &+= 1
        quickLayoutOverrides[snapshot.display.id] = next
        isApplyingQuickLayout = true
        if let persistentID = snapshot.display.persistentID?.uuid {
            var updated = assignments
            updated[persistentID] = PersistedAssignment(displayUUID: persistentID, spaceScope: .common, layoutID: next.id)
            assignments = updated
        } else if case .session(let sessionID) = snapshot.display.id {
            sessionLayouts[sessionID] = next
        } else {
            isApplyingQuickLayout = false
            quickLayoutOverrides.removeValue(forKey: snapshot.display.id)
            return nil
        }
        if selectedDisplayID == snapshot.display.id { adoptQuickLayoutForSelectedDisplay(next, display: snapshot.display) }
        isApplyingQuickLayout = false
        if snapshot.display.persistentID != nil {
            let layoutSnapshot = Array(savedLayouts.values)
            let assignmentSnapshot = Array(assignments.values)
            let mutationRevision = quickLayoutMutationRevision
            let displayID = snapshot.display.id
            enqueueSave(isQuickAssignmentSave: true) { coordinator in
                try await coordinator.saveLayoutAndAssignments(layoutSnapshot, assignmentSnapshot)
                guard self.quickLayoutMutationRevision == mutationRevision,
                      self.quickLayoutOverrides[displayID]?.id == next.id else { return }
                self.quickLayoutOverrides.removeValue(forKey: displayID)
            }
        }
        return next
    }

    private func quickSwitchLayoutCatalog() -> [PersistedLayout] {
        var byID = savedLayouts
        byID[PersistentStoreCoordinator.defaultLayoutID] = savedLayouts[PersistentStoreCoordinator.defaultLayoutID]
            ?? PersistentStoreCoordinator.defaultLayout()
        return byID.values.sorted {
            let order = ($0.name ?? "Default").localizedStandardCompare($1.name ?? "Default")
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
    }

    private func adoptQuickLayoutForSelectedDisplay(_ layout: PersistedLayout, display: Display) {
        currentLayout = layout
        isApplyingStoredValues = true
        template = LayoutTemplate(rawValue: layout.template) ?? .grid
        zoneCount = layout.zoneCount
        spacing = layout.spacing
        isApplyingStoredValues = false
        do {
            zones = try LayoutEngine.zones(for: layout.definition(), in: display.workArea, spacing: layout.spacing)
            selectedZoneID = zones.first?.id
            errorMessage = nil
        } catch {
            zones = []
            selectedZoneID = nil
            errorMessage = error.localizedDescription
        }
    }

}

@MainActor
extension LayoutController {
    func registerEditorIdentity(_ identity: EditorOperationIdentity) -> Bool {
        guard acceptsChanges, persistenceReady, canEdit,
              displayProvider.snapshot.displays.contains(where: { $0.id == identity.targetDisplay }) else { return false }
        if let target = editorOperationTargets[identity.token], target != identity.targetDisplay { return false }
        guard identity.revision > (editorOperationRevisions[identity.token] ?? 0) else { return false }
        editorOperationTargets[identity.token] = identity.targetDisplay
        editorOperationRevisions[identity.token] = identity.revision
        return true
    }

    func isCurrent(_ identity: EditorOperationIdentity) -> Bool {
        editorOperationTargets[identity.token] == identity.targetDisplay && editorOperationRevisions[identity.token] == identity.revision
    }

    func markEditorPersistenceSucceeded(acknowledgesQuickAssignment: Bool = false) {
        if hasPendingQuickAssignmentSave, !acknowledgesQuickAssignment {
            return
        }
        // A later editor write is the new durable authority; retrying a closure
        // captured by an older legacy save could restore stale catalog/assignments.
        lastSaveSucceeded = true
        lastFailedOperation = nil
        lastFailedQuickMutationRevision = nil
        hasPendingQuickAssignmentSave = false
        canRetrySave = false
        persistenceErrorMessage = nil
    }

    func isShared(_ id: UUID, excluding displayUUID: UUID?) -> Bool {
        assignments.values.contains { assignment in assignment.layoutID == id && assignment.displayUUID != displayUUID }
    }

    func isApplied(_ id: UUID) -> Bool {
        assignments.values.contains(where: { $0.layoutID == id }) || sessionLayouts.values.contains(where: { $0.id == id })
    }

    func reidentified(_ layout: PersistedLayout, id: UUID, name: String? = nil) throws -> PersistedLayout {
        let oldDefinition = try layout.definition()
        let definition: LayoutDefinition
        switch oldDefinition {
        case .grid(let grid):
            definition = .grid(GridLayout(id: LayoutID(rawValue: id), rows: grid.rows, columns: grid.columns,
                                          rowPercentages: grid.rowPercentages, columnPercentages: grid.columnPercentages,
                                          cellChildMap: grid.cellChildMap))
        case .canvas(let canvas):
            definition = .canvas(CanvasLayout(id: LayoutID(rawValue: id), referenceSize: canvas.referenceSize, zones: canvas.zones))
        case .focus(let canvas):
            definition = .focus(CanvasLayout(id: LayoutID(rawValue: id), referenceSize: canvas.referenceSize, zones: canvas.zones))
        }
        return PersistedLayout(id: id, definition: definition, spacing: layout.spacing,
                               template: LayoutTemplate(rawValue: layout.template) ?? .grid,
                               zoneCount: layout.zoneCount, name: name ?? layout.name)
    }
    func userChangedDefinition() {
        guard canEdit, !isApplyingStoredValues, selectedDisplay != nil else { return }
        do {
            let definition = try LayoutTemplates.definition(
                for: template, zoneCount: zoneCount, area: selectedDisplay?.workArea ?? .zero, spacing: spacing
            )
            let id = writableLayoutID()
            currentLayout = PersistedLayout(id: id, definition: definition, spacing: spacing, template: template, zoneCount: zoneCount, name: currentLayout.name)
            if case .session(let sessionID)? = selectedDisplayID {
                sessionLayouts[sessionID] = currentLayout
            } else {
                savedLayouts[id] = currentLayout
                guard storeCoordinator != nil else { return }
                let layoutSnapshot = Array(savedLayouts.values)
                let displayUUID = selectedDisplay?.persistentID?.uuid
                if let displayUUID {
                    let assignment = PersistedAssignment(displayUUID: displayUUID, spaceScope: .common, layoutID: id)
                    assignments[displayUUID] = assignment
                    let assignmentSnapshot = Array(assignments.values)
                    enqueueSave(acknowledgesQuickAssignment: true) { coordinator in
                        try await coordinator.saveLayoutAndAssignments(layoutSnapshot, assignmentSnapshot)
                    }
                } else {
                    enqueueSave { coordinator in try await coordinator.saveLayouts(layoutSnapshot) }
                }
            }
            recalculate()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    func writableLayoutID() -> UUID {
        guard let selectedDisplay else { return currentLayout.id }
        if case .session(let sessionID) = selectedDisplay.id {
            return sessionLayouts[sessionID]?.id ?? UUID()
        }
        guard let id = selectedDisplay.persistentID?.uuid else { return currentLayout.id }
        let shared = assignments.values.contains { $0.layoutID == currentLayout.id && $0.displayUUID != id }
        if currentLayout.id == PersistentStoreCoordinator.defaultLayoutID || shared || assignments[id]?.layoutID != currentLayout.id {
            return UUID()
        }
        return currentLayout.id
    }
    func showLayoutForSelectedDisplay() {
        guard let selectedDisplay else { recalculate(); return }
        let stored: PersistedLayout?
        if let persistentID = selectedDisplay.persistentID,
           let layoutID = assignments[persistentID.uuid]?.layoutID {
            stored = savedLayouts[layoutID]
        } else if case .session(let sessionID) = selectedDisplay.id {
            stored = sessionLayouts[sessionID]
        } else {
            stored = nil
        }
        currentLayout = stored ?? PersistentStoreCoordinator.defaultLayout()
        isApplyingStoredValues = true
        template = LayoutTemplate(rawValue: currentLayout.template) ?? .grid
        zoneCount = currentLayout.zoneCount
        spacing = currentLayout.spacing
        isApplyingStoredValues = false
        recalculate()
    }

    func adoptPersistedStatePreservingQuickSwitches(_ state: LoadedPersistentState) {
        let keepSelectedQuickLayout = selectedDisplayID.map {
            quickLayoutOverrides[$0]?.id == currentLayout.id
        } ?? false
        isApplyingQuickLayout = true
        savedLayouts = state.layouts
        assignments = assignmentsWithQuickSwitchOverrides(state.assignments)
        for (displayID, layout) in Array(quickLayoutOverrides) {
            if case .session(let sessionID) = displayID { sessionLayouts[sessionID] = layout }
        }
        isApplyingQuickLayout = false
        if !keepSelectedQuickLayout { showLayoutForSelectedDisplay() }
    }

    func assignmentsWithQuickSwitchOverrides(_ source: [UUID: PersistedAssignment]) -> [UUID: PersistedAssignment] {
        var result = source
        for (displayID, layout) in quickLayoutOverrides {
            guard let display = displayProvider.snapshot.displays.first(where: { $0.id == displayID }),
                  let persistentID = display.persistentID?.uuid else { continue }
            result[persistentID] = PersistedAssignment(displayUUID: persistentID, spaceScope: .common, layoutID: layout.id)
        }
        return result
    }

    func clearPersistedQuickSwitchOverrides(_ persistedAssignments: [UUID: PersistedAssignment]) {
        for (displayID, layout) in Array(quickLayoutOverrides) {
            guard let display = displayProvider.snapshot.displays.first(where: { $0.id == displayID }),
                  let displayUUID = display.persistentID?.uuid,
                  persistedAssignments[displayUUID]?.layoutID == layout.id else { continue }
            quickLayoutOverrides.removeValue(forKey: displayID)
        }
    }

}

@MainActor
extension LayoutController {
    func retryFailedSave() async -> Bool {
        guard !isRetryingSave, let storeCoordinator else { return false }
        let wasAcceptingChanges = acceptsChanges
        acceptsChanges = false
        canEdit = false
        isRetryingSave = true
        defer {
            acceptsChanges = wasAcceptingChanges
            canEdit = wasAcceptingChanges && persistenceReady
            isRetryingSave = false
        }
        if let saveChain { await saveChain.value }
        guard let operation = lastFailedOperation else { return lastSaveSucceeded }
        let retryMutationRevision = quickLayoutMutationRevision
        let failedMutationRevision = lastFailedQuickMutationRevision
        do {
            if hasPendingQuickAssignmentSave {
                try await storeCoordinator.saveLayoutAndAssignments(Array(savedLayouts.values), Array(assignments.values))
            } else {
                try await operation(storeCoordinator)
            }
            if !hasPendingQuickAssignmentSave, failedMutationRevision != retryMutationRevision {
                try await storeCoordinator.saveLayoutAndAssignments(Array(savedLayouts.values), Array(assignments.values))
            }
            let state = try await storeCoordinator.load()
            guard quickLayoutMutationRevision == retryMutationRevision else { return false }
            adoptPersistedStatePreservingQuickSwitches(state)
            clearPersistedQuickSwitchOverrides(state.assignments)
            adoptSettings(state.settings)
            lastFailedOperation = nil
            lastFailedQuickMutationRevision = nil
            hasPendingQuickAssignmentSave = false
            lastSaveSucceeded = true
            persistenceErrorMessage = nil
            canRetrySave = false
            return true
        } catch {
            persistenceErrorMessage = error.localizedDescription
            errorMessage = error.localizedDescription
            lastSaveSucceeded = false
            canRetrySave = true
            return false
        }
    }

}
