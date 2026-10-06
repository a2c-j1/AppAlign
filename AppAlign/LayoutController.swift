import Combine
import CoreGraphics
import Foundation

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
private extension LayoutController {
    private func userChangedDefinition() {
        guard canEdit, !isApplyingStoredValues, selectedDisplay != nil else { return }
        do {
            let definition = try LayoutTemplates.definition(
                for: template, zoneCount: zoneCount, area: selectedDisplay?.workArea ?? .zero, spacing: spacing
            )
            let id = writableLayoutID()
            currentLayout = PersistedLayout(id: id, definition: definition, spacing: spacing, template: template, zoneCount: zoneCount)
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
