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
    @Published var zones: [Zone] = []
    @Published var selectedZoneID: ZoneID?
    @Published var errorMessage: String?
    @Published var persistenceErrorMessage: String?
    @Published var canRetrySave = false
    @Published private(set) var persistenceReady = false
    @Published var canEdit = false
    @Published var keyboardSettings = KeyboardSettings()
    @Published var layoutHotkeySettings = LayoutHotkeySettings()
    @Published var keyboardSettingsErrorMessage: String?

    let storeCoordinator: PersistentStoreCoordinator?
    var savedLayouts: [UUID: PersistedLayout] = [:] {
        didSet {
            if oldValue != savedLayouts, !isApplyingQuickLayout {
                for (displayID, override) in Array(quickLayoutOverrides) {
                    if savedLayouts[override.id] == nil || oldValue[override.id] != savedLayouts[override.id] {
                        quickLayoutOverrides.removeValue(forKey: displayID)
                    }
                }
                invalidateAppliedDragLayout()
            }
        }
    }
    var assignments: [UUID: PersistedAssignment] = [:] {
        didSet {
            if oldValue != assignments, !isApplyingQuickLayout {
                quickLayoutOverrides.removeAll()
                invalidateAppliedDragLayout()
            }
        }
    }
    var sessionLayouts: [UUID: PersistedLayout] = [:] {
        didSet {
            if oldValue != sessionLayouts, !isApplyingQuickLayout {
                quickLayoutOverrides.removeAll()
                invalidateAppliedDragLayout()
            }
        }
    }
    var settings: [String: PersistedSetting] = [:]
    var currentLayout: PersistedLayout
    var isApplyingStoredValues = false
    private var requestedLoadRevision: UInt64 = 0
    private var requestedSaveRevision: UInt64 = 0
    var saveChain: Task<Void, Never>?
    private var loadInProgress = false
    var acceptsChanges = true
    private var zonesDisplayFingerprint: String?
    var lastSaveSucceeded = true
    var lastFailedOperation: (@MainActor (PersistentStoreCoordinator) async throws -> Void)?
    var lastFailedQuickMutationRevision: UInt64?
    var hasPendingQuickAssignmentSave = false
    var isRetryingSave = false
    var editorOperationTargets: [UUID: DisplaySelectionID] = [:]
    var editorOperationRevisions: [UUID: UInt64] = [:]
    var keyboardSettingsRevision: UInt64 = 0
    var keyboardSettingsRetrySnapshot: [String: PersistedSetting]?
    var layoutHotkeySettingsRevision: UInt64 = 0
    var layoutHotkeySettingsRetrySnapshot: [String: PersistedSetting]?
    var dragLayoutRevision: UInt64 = 0
    let placementValidity: PlacementValidity
    var dragSettings = DragSettings()
    var dragSettingsRetrySnapshot: [String: PersistedSetting]?
    var dragSettingsRevision: UInt64 = 0
    var invalidateDragCommit: (@MainActor () -> Void)?
    var lastDragDisplaySnapshot: DisplaySnapshot?
    var lastDragCursorDisplayID: DisplaySelectionID?
    var refreshConfiguration: (@MainActor () -> DisplaySnapshot)?
    var isApplyingQuickLayout = false
    var quickLayoutMutationRevision: UInt64 = 0
    var quickLayoutOverrides: [DisplaySelectionID: PersistedLayout] = [:]

    init(displayProvider: DisplayProvider = DisplayProvider(), storeCoordinator: PersistentStoreCoordinator? = nil,
         placementValidity: PlacementValidity = PlacementValidity()) {
        self.displayProvider = displayProvider
        self.placementValidity = placementValidity
        if let storeCoordinator {
            self.storeCoordinator = storeCoordinator
        } else if let directory = Self.applicationStoreDirectory() {
            self.storeCoordinator = PersistentStoreCoordinator(directory: directory)
        } else {
            self.storeCoordinator = nil
        }
        currentLayout = PersistentStoreCoordinator.defaultLayout()
        lastDragDisplaySnapshot = displayProvider.snapshot
        selectedDisplayID = displayProvider.snapshot.displays.first(where: \.isPrimary)?.id
        recalculate()
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
            adoptPersistedStatePreservingQuickSwitches(state)
            adoptSettings(state.settings)
            persistenceReady = true
            canEdit = acceptsChanges
            persistenceErrorMessage = nil
            canRetrySave = false
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

    func displaysDidPublish(_ result: DisplaySnapshot) {
        let previous = selectedDisplayID
        if !result.displays.contains(where: { $0.id == selectedDisplayID }) {
            selectedDisplayID = result.displays.first(where: \.isPrimary)?.id
        }
        if selectedDisplayID != previous { showLayoutForSelectedDisplay() } else { recalculate() }
    }
    func recalculate() {
        invalidateAppliedDragLayout()
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
        enqueueSave(acknowledgesQuickAssignment: true) { coordinator in
            try await coordinator.saveAssignmentsAndLayouts(remainingAssignments, layoutSnapshot)
        }
    }
    func flush() async -> Bool {
        if let saveChain { await saveChain.value }
        guard persistenceReady else { return true }
        do {
            if !lastSaveSucceeded, !(await retryFailedSave()) { return false }
            if keyboardSettingsRetrySnapshot != nil, !(await retryKeyboardSettingsSave()) { return false }
            if dragSettingsRetrySnapshot != nil, !(await retryDragSettingsSave()) { return false }
            if layoutHotkeySettingsRetrySnapshot != nil, !(await retryLayoutHotkeySettingsSave()) { return false }
            try await storeCoordinator?.flush()
            return persistenceReady && lastSaveSucceeded
        } catch {
            errorMessage = error.localizedDescription
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
    func enqueueSave(isQuickAssignmentSave: Bool = false, acknowledgesQuickAssignment: Bool = false,
                     _ operation: @escaping @MainActor (PersistentStoreCoordinator) async throws -> Void) {
        guard acceptsChanges, let storeCoordinator else { return }
        requestedSaveRevision &+= 1
        let revision = requestedSaveRevision
        let quickMutationRevision = quickLayoutMutationRevision
        let previous = saveChain
        saveChain = Task { @MainActor [weak self] in
            await previous?.value
            do {
                try await operation(storeCoordinator)
                if let self, revision == self.requestedSaveRevision,
                   !self.hasPendingQuickAssignmentSave || isQuickAssignmentSave || acknowledgesQuickAssignment {
                    self.lastSaveSucceeded = true
                    self.lastFailedOperation = nil
                    self.lastFailedQuickMutationRevision = nil
                    self.hasPendingQuickAssignmentSave = false
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
                    self.lastFailedQuickMutationRevision = quickMutationRevision
                    self.hasPendingQuickAssignmentSave = isQuickAssignmentSave
                }
                if let recovered = try? await storeCoordinator.load(),
                   quickMutationRevision == self.quickLayoutMutationRevision,
                   revision == self.requestedSaveRevision {
                    self.adoptPersistedStatePreservingQuickSwitches(recovered)
                    self.adoptSettings(recovered.settings)
                }
            }
        }
    }
}
