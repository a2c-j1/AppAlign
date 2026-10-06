import Combine
import CoreGraphics
import Foundation

struct EditorOperationIdentity: Equatable, Sendable {
    let token: UUID
    let targetDisplay: DisplaySelectionID
    let revision: UInt64
}

struct EditorCatalogSnapshot: Sendable {
    let layouts: [PersistedLayout]
    let appliedLayoutID: UUID
}

enum EditorOperationResult: Sendable {
    case success(PersistedLayout?)
    case failure(String)
}

@MainActor
final class LayoutController: ObservableObject {
    let displayProvider: DisplayProvider
    @Published var template: LayoutTemplate = .grid { didSet { userChangedDefinition() } }
    @Published var zoneCount = 4 { didSet { userChangedDefinition() } }
    @Published var spacing: Double = 10 { didSet { userChangedDefinition() } }
    @Published private(set) var selectedDisplayID: DisplaySelectionID?
    @Published private(set) var zones: [Zone] = []
    @Published var selectedZoneID: ZoneID?
    @Published private(set) var errorMessage: String?
    @Published private(set) var persistenceErrorMessage: String?
    @Published private(set) var canRetrySave = false
    @Published private(set) var persistenceReady = false
    @Published private(set) var canEdit = false

    private let storeCoordinator: PersistentStoreCoordinator?
    private var savedLayouts: [UUID: PersistedLayout] = [:]
    private var assignments: [UUID: PersistedAssignment] = [:]
    private var sessionLayouts: [UUID: PersistedLayout] = [:]
    private var settings: [String: PersistedSetting] = [:]
    private var currentLayout: PersistedLayout
    private var isApplyingStoredValues = false
    private var requestedLoadRevision: UInt64 = 0
    private var requestedSaveRevision: UInt64 = 0
    private var saveChain: Task<Void, Never>?
    private var loadInProgress = false
    private var acceptsChanges = true
    private var zonesDisplayFingerprint: String?
    private var lastSaveSucceeded = true
    private var lastFailedOperation: (@MainActor (PersistentStoreCoordinator) async throws -> Void)?
    private var isRetryingSave = false
    private var editorOperationTargets: [UUID: DisplaySelectionID] = [:]
    private var editorOperationRevisions: [UUID: UInt64] = [:]

    init(displayProvider: DisplayProvider = DisplayProvider(), storeCoordinator: PersistentStoreCoordinator? = nil) {
        self.displayProvider = displayProvider
        if let storeCoordinator {
            self.storeCoordinator = storeCoordinator
        } else if let directory = Self.applicationStoreDirectory() {
            self.storeCoordinator = PersistentStoreCoordinator(directory: directory)
        } else {
            self.storeCoordinator = nil
        }
        currentLayout = PersistentStoreCoordinator.defaultLayout()
        selectedDisplayID = displayProvider.snapshot.displays.first(where: \.isPrimary)?.id
        recalculate()
    }

    var selectedDisplay: Display? {
        displayProvider.snapshot.displays.first { $0.id == selectedDisplayID }
    }

    func loadPersistentState() async {
        guard !persistenceReady, !loadInProgress else { return }
        guard let storeCoordinator else {
            errorMessage = "AppAlign could not access its Application Support directory."
            return
        }
        requestedLoadRevision &+= 1
        loadInProgress = true
        let revision = requestedLoadRevision
        do {
            let state = try await storeCoordinator.load()
            guard revision == requestedLoadRevision else { return }
            savedLayouts = state.layouts
            assignments = state.assignments
            settings = state.settings
            persistenceReady = true
            canEdit = acceptsChanges
            persistenceErrorMessage = nil
            canRetrySave = false
            showLayoutForSelectedDisplay()
            if state.layoutStoreNeedsRepair { errorMessage = "Damaged layout data was backed up and reset." }
        } catch {
            guard revision == requestedLoadRevision else { return }
            persistenceErrorMessage = error.localizedDescription
            errorMessage = error.localizedDescription
            persistenceReady = false
        }
        loadInProgress = false
    }

    func selectDisplay(_ id: DisplaySelectionID) {
        guard canEdit, id != selectedDisplayID else { return }
        selectedDisplayID = id
        showLayoutForSelectedDisplay()
    }

    @discardableResult
    func refreshDisplays() -> DisplaySnapshot {
        let previous = selectedDisplayID
        let result = displayProvider.refresh()
        if !result.displays.contains(where: { $0.id == selectedDisplayID }) {
            selectedDisplayID = result.displays.first(where: \.isPrimary)?.id
        }
        if selectedDisplayID != previous { showLayoutForSelectedDisplay() } else { recalculate() }
        return result
    }

    func recalculate() {
        guard let display = selectedDisplay else {
            zones = []
            selectedZoneID = nil
            errorMessage = "No display is available."
            return
        }
        do {
            let definition = try currentLayout.definition()
            zonesDisplayFingerprint = displayProvider.snapshot.fingerprint
            zones = try LayoutEngine.zones(for: definition, in: display.workArea, spacing: currentLayout.spacing)
            if !zones.contains(where: { $0.id == selectedZoneID }) { selectedZoneID = zones.first?.id }
            if persistenceReady { errorMessage = nil }
        } catch {
            zones = []
            selectedZoneID = nil
            errorMessage = error.localizedDescription
        }
    }

    func deleteLayout(_ id: UUID) {
        guard acceptsChanges, id != PersistentStoreCoordinator.defaultLayoutID else { return }
        guard savedLayouts[id] != nil else { return }
        for assignment in assignments.values.filter({ $0.layoutID == id }) {
            assignments.removeValue(forKey: assignment.displayUUID)
        }
        let remainingAssignments = Array(assignments.values)
        var remainingLayouts = savedLayouts
        remainingLayouts.removeValue(forKey: id)
        savedLayouts = remainingLayouts
        if currentLayout.id == id { showLayoutForSelectedDisplay() }
        let layoutSnapshot = Array(remainingLayouts.values)
        enqueueSave { coordinator in
            try await coordinator.saveAssignmentsAndLayouts(remainingAssignments, layoutSnapshot)
        }
    }

    func flush() async -> Bool {
        if let saveChain { await saveChain.value }
        guard persistenceReady else { return true }
        do {
            if !lastSaveSucceeded, !(await retryFailedSave()) { return false }
            try await storeCoordinator?.flush()
            return persistenceReady && lastSaveSucceeded
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

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
        do {
            try await operation(storeCoordinator)
            let state = try await storeCoordinator.load()
            savedLayouts = state.layouts
            assignments = state.assignments
            settings = state.settings
            lastFailedOperation = nil
            lastSaveSucceeded = true
            persistenceErrorMessage = nil
            canRetrySave = false
            showLayoutForSelectedDisplay()
            return true
        } catch {
            persistenceErrorMessage = error.localizedDescription
            errorMessage = error.localizedDescription
            lastSaveSucceeded = false
            canRetrySave = true
            return false
        }
    }

    func prepareForTermination() async -> Bool {
        acceptsChanges = false
        canEdit = false
        let success = await flush()
        if !success {
            acceptsChanges = true
            canEdit = persistenceReady
        }
        return success
    }

    func placeSelectedZone(using placementController: PlacementController) {
        guard canEdit else { return }
        guard let zone = zones.first(where: { $0.id == selectedZoneID }) else { return }
        let zonesFingerprint = zonesDisplayFingerprint
        _ = refreshDisplays()
        guard selectedDisplay != nil else { return }
        guard zonesFingerprint == displayProvider.snapshot.fingerprint else {
            errorMessage = WindowManagementError.displayConfigurationChanged.localizedDescription
            return
        }
        do {
            try placementController.placeCapturedWindow(in: zone.frame, displayFingerprint: zonesFingerprint ?? "")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

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
        let base = saveChain
        let operation = Task<EditorOperationResult, Never> { @MainActor [weak self] in
            await base?.value
            guard let self, self.isCurrent(identity), self.acceptsChanges else { return .failure("This editor operation was superseded.") }
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
                self.savedLayouts = layouts
                self.markEditorPersistenceSucceeded()
                guard self.isCurrent(identity) else { return .failure("This editor operation was superseded after saving.") }
                self.errorMessage = nil
                return .success(candidate)
            } catch {
                self.persistenceErrorMessage = error.localizedDescription
                self.errorMessage = error.localizedDescription
                if let loaded = try? await storeCoordinator.load() { self.savedLayouts = loaded.layouts }
                return .failure(error.localizedDescription)
            }
        }
        saveChain = Task { @MainActor in _ = await operation.value }
        return await operation.value
    }

    func applyEditorLayout(_ id: UUID, identity: EditorOperationIdentity) async -> EditorOperationResult {
        guard registerEditorIdentity(identity) else { return .failure("This editor operation is stale.") }
        guard let storeCoordinator else { return .failure("Persistent storage is unavailable.") }
        let base = saveChain
        let operation = Task<EditorOperationResult, Never> { @MainActor [weak self] in
            await base?.value
            guard let self, self.isCurrent(identity), self.acceptsChanges else { return .failure("This editor operation was superseded.") }
            guard let display = self.displayProvider.snapshot.displays.first(where: { $0.id == identity.targetDisplay }),
                  let layout = self.savedLayouts[id] ?? (id == PersistentStoreCoordinator.defaultLayoutID ? PersistentStoreCoordinator.defaultLayout() : nil) else {
                return .failure("The display or saved layout is no longer available.")
            }
            do {
                if let uuid = display.persistentID?.uuid {
                    var nextAssignments = self.assignments
                    nextAssignments[uuid] = PersistedAssignment(displayUUID: uuid, spaceScope: .common, layoutID: id)
                    var layouts = self.savedLayouts
                    layouts[layout.id] = layout
                    try await storeCoordinator.saveLayoutAndAssignments(Array(layouts.values), Array(nextAssignments.values))
                    self.savedLayouts = layouts
                    self.assignments = nextAssignments
                } else if case .session(let sessionID) = identity.targetDisplay {
                    self.sessionLayouts[sessionID] = layout
                } else {
                    return .failure("This display cannot be assigned for this session.")
                }
                if self.selectedDisplayID == identity.targetDisplay { self.showLayoutForSelectedDisplay() }
                self.markEditorPersistenceSucceeded()
                guard self.isCurrent(identity) else { return .failure("This editor operation was superseded after saving.") }
                return .success(layout)
            } catch {
                self.persistenceErrorMessage = error.localizedDescription
                self.errorMessage = error.localizedDescription
                if let loaded = try? await storeCoordinator.load() {
                    self.savedLayouts = loaded.layouts
                    self.assignments = loaded.assignments
                    if self.selectedDisplayID == identity.targetDisplay { self.showLayoutForSelectedDisplay() }
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
        let base = saveChain
        let operation = Task<EditorOperationResult, Never> { @MainActor [weak self] in
            await base?.value
            guard let self, self.isCurrent(identity), self.acceptsChanges else { return .failure("This editor operation was superseded.") }
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
                self.savedLayouts = layouts
                self.markEditorPersistenceSucceeded()
                guard self.isCurrent(identity) else { return .failure("This editor operation was superseded after saving.") }
                return .success(renamed)
            } catch {
                self.persistenceErrorMessage = error.localizedDescription
                self.errorMessage = error.localizedDescription
                if let loaded = try? await storeCoordinator.load() { self.savedLayouts = loaded.layouts }
                return .failure(error.localizedDescription)
            }
        }
        saveChain = Task { @MainActor in _ = await operation.value }
        return await operation.value
    }

    func duplicateEditorLayout(_ id: UUID, identity: EditorOperationIdentity) async -> EditorOperationResult {
        guard registerEditorIdentity(identity) else { return .failure("This editor operation is stale.") }
        guard let storeCoordinator else { return .failure("Persistent storage is unavailable.") }
        let base = saveChain
        let operation = Task<EditorOperationResult, Never> { @MainActor [weak self] in
            await base?.value
            guard let self, self.isCurrent(identity), self.acceptsChanges else { return .failure("This editor operation was superseded.") }
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
                self.savedLayouts = layouts
                self.markEditorPersistenceSucceeded()
                guard self.isCurrent(identity) else { return .failure("This editor operation was superseded after saving.") }
                return .success(duplicate)
            } catch {
                self.persistenceErrorMessage = error.localizedDescription
                self.errorMessage = error.localizedDescription
                if let loaded = try? await storeCoordinator.load() { self.savedLayouts = loaded.layouts }
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
        let base = saveChain
        let operation = Task<EditorOperationResult, Never> { @MainActor [weak self] in
            await base?.value
            guard let self, self.isCurrent(identity), self.acceptsChanges else { return .failure("This editor operation was superseded.") }
            guard self.savedLayouts[id] != nil else { return .failure("This layout is no longer available.") }
            let nextAssignments = self.assignments.filter { $0.value.layoutID != id }
            var nextLayouts = self.savedLayouts
            nextLayouts.removeValue(forKey: id)
            do {
                try await storeCoordinator.saveAssignmentsAndLayouts(Array(nextAssignments.values), Array(nextLayouts.values))
                self.assignments = nextAssignments
                self.savedLayouts = nextLayouts
                for sessionID in Array(self.sessionLayouts.keys) where self.sessionLayouts[sessionID]?.id == id {
                    self.sessionLayouts.removeValue(forKey: sessionID)
                }
                if self.selectedDisplayID == identity.targetDisplay || self.currentLayout.id == id { self.showLayoutForSelectedDisplay() }
                self.markEditorPersistenceSucceeded()
                guard self.isCurrent(identity) else { return .failure("This editor operation was superseded after saving.") }
                return .success(nil)
            } catch {
                self.persistenceErrorMessage = error.localizedDescription
                self.errorMessage = error.localizedDescription
                if let loaded = try? await storeCoordinator.load() {
                    self.savedLayouts = loaded.layouts
                    self.assignments = loaded.assignments
                    if self.selectedDisplayID == identity.targetDisplay || self.currentLayout.id == id { self.showLayoutForSelectedDisplay() }
                }
                return .failure(error.localizedDescription)
            }
        }
        saveChain = Task { @MainActor in _ = await operation.value }
        return await operation.value
    }

}

@MainActor
private extension LayoutController {
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

    func markEditorPersistenceSucceeded() {
        // A later editor write is the new durable authority; retrying a closure
        // captured by an older legacy save could restore stale catalog/assignments.
        lastSaveSucceeded = true
        lastFailedOperation = nil
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

    private func userChangedDefinition() {
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
                    enqueueSave { coordinator in
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

    private func writableLayoutID() -> UUID {
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

    private func showLayoutForSelectedDisplay() {
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

    private func enqueueSave(_ operation: @escaping @MainActor (PersistentStoreCoordinator) async throws -> Void) {
        guard acceptsChanges, let storeCoordinator else { return }
        requestedSaveRevision &+= 1
        let revision = requestedSaveRevision
        let previous = saveChain
        saveChain = Task { @MainActor [weak self] in
            await previous?.value
            do {
                try await operation(storeCoordinator)
                if let self, revision == self.requestedSaveRevision {
                    self.lastSaveSucceeded = true
                    self.lastFailedOperation = nil
                    self.persistenceErrorMessage = nil
                    self.canRetrySave = false
                }
            } catch {
                guard let self else { return }
                self.lastSaveSucceeded = false
                self.lastFailedOperation = operation
                if revision == self.requestedSaveRevision {
                    self.persistenceErrorMessage = error.localizedDescription
                    self.errorMessage = error.localizedDescription
                    self.canRetrySave = true
                }
                if let recovered = try? await storeCoordinator.load(), revision == self.requestedSaveRevision {
                    self.savedLayouts = recovered.layouts
                    self.assignments = recovered.assignments
                    self.settings = recovered.settings
                    self.showLayoutForSelectedDisplay()
                }
            }
        }
    }

    private static func applicationStoreDirectory() -> URL? {
        #if DEBUG
            if let path = ProcessInfo.processInfo.environment["APPALIGN_STORAGE_DIRECTORY"], !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        #endif
        return try? PersistentStoreCoordinator.applicationSupportDirectory()
    }
}
