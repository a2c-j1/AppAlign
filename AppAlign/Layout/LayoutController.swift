import AppKit
import Combine
import CoreGraphics
import Foundation

struct EditorOperationIdentity: Equatable, Sendable {
    let token: UUID
    let targetDisplay: DisplaySelectionID
    let revision: UInt64
    let targetScope: PersistedSpaceScope
    let configurationRevision: UInt64

    init(token: UUID, targetDisplay: DisplaySelectionID, revision: UInt64, targetScope: PersistedSpaceScope = .common,
         configurationRevision: UInt64 = 0) {
        self.token = token
        self.targetDisplay = targetDisplay
        self.revision = revision
        self.targetScope = targetScope
        self.configurationRevision = configurationRevision
    }
}

struct EditorCatalogSnapshot: Sendable {
    let layouts: [PersistedLayout]
    let appliedLayoutID: UUID
}

@MainActor
final class AppHistoryCoordinator {
    struct Lease: Equatable {
        let id: UUID
        let key: AppZoneHistoryKey
        let token: RuntimeWindowToken
        let expectedLayout: PersistedLayout
        let runtimeLeaseID: RuntimeHistoryLeaseID
    }

    private struct Assignment {
        let token: RuntimeWindowToken
        let sequence: UInt64
        let runtimeLeaseID: RuntimeHistoryLeaseID
    }

    private var owners: [AppZoneHistoryKey: RuntimeWindowToken] = [:]
    private var assignments: [AppZoneHistoryKey: [Assignment]] = [:]
    private var currentKeys: [RuntimeWindowToken: AppZoneHistoryKey] = [:]
    private var pendingLeases: [UUID: Lease] = [:]
    private var nextSequence: UInt64 = 0
    var releaseRuntimeLease: (@MainActor (RuntimeWindowToken, RuntimeHistoryLeaseID) -> Void)?
    var assignedTokenCount: Int { currentKeys.count }
    func isAssigned(token: RuntimeWindowToken) -> Bool { currentKeys[token] != nil }

    func reservePlacement(token: RuntimeWindowToken, bundleID: String, displayUUID: UUID,
                          expectedLayout: PersistedLayout,
                          spaceScope: PersistedSpaceScope = .common) -> Lease? {
        guard !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !bundleID.contains("\n") else { return nil }
        let key = AppZoneHistoryKey(bundleID: bundleID, displayUUID: displayUUID,
                                    spaceScope: spaceScope, layoutID: expectedLayout.id)
        let pendingNewTokens = Set(pendingLeases.values.map(\.token)).subtracting(currentKeys.keys)
        guard pendingLeases.count < 64,
              currentKeys[token] != nil || currentKeys.count + pendingNewTokens.count < 64 else {
            return nil
        }
        let lease = Lease(id: UUID(), key: key, token: token, expectedLayout: expectedLayout,
                          runtimeLeaseID: RuntimeHistoryLeaseID())
        pendingLeases[lease.id] = lease
        return lease
    }

    func release(_ lease: Lease) -> Bool {
        pendingLeases.removeValue(forKey: lease.id) != nil
    }

    func isPending(_ lease: Lease) -> Bool { pendingLeases[lease.id] == lease }

    func acceptSuccessfulPlacement(_ lease: Lease) -> Bool? {
        guard pendingLeases.removeValue(forKey: lease.id) == lease else { return nil }
        let alreadyAssigned = assignments[lease.key]?.contains(where: { $0.token == lease.token }) == true
        guard alreadyAssigned || nextSequence < UInt64.max else { return nil }
        if alreadyAssigned {
            releaseRuntimeLease?(lease.token, lease.runtimeLeaseID)
            return owners[lease.key] == lease.token
        }
        if currentKeys[lease.token] != lease.key { removeAssignments(for: lease.token) }
        var entries = assignments[lease.key] ?? []
        if !entries.contains(where: { $0.token == lease.token }) {
            guard currentKeys.count < 64 || currentKeys[lease.token] == lease.key else { return nil }
            nextSequence += 1
            entries.append(Assignment(token: lease.token, sequence: nextSequence,
                                      runtimeLeaseID: lease.runtimeLeaseID))
            assignments[lease.key] = entries
            currentKeys[lease.token] = lease.key
        }
        if owners[lease.key] == nil { owners[lease.key] = lease.token }
        return owners[lease.key] == lease.token
    }

    func windowDestroyed(_ token: RuntimeWindowToken) {
        removeAssignments(where: { $0.token == token })
    }

    func processTerminated(_ token: RuntimeWindowToken) {
        removeAssignments(where: { $0.token.pid == token.pid && $0.token.processGeneration == token.processGeneration })
    }

    func restoreSucceeded(_ token: RuntimeWindowToken) {
        removeAssignments(for: token)
    }

    private func removeAssignments(for token: RuntimeWindowToken) {
        removeAssignments(where: { $0.token == token })
        currentKeys.removeValue(forKey: token)
    }

    private func removeAssignments(where shouldRemove: (Assignment) -> Bool) {
        for key in Array(assignments.keys) {
            let removed = (assignments[key] ?? []).filter(shouldRemove)
            for assignment in removed {
                releaseRuntimeLease?(assignment.token, assignment.runtimeLeaseID)
            }
            let remaining = (assignments[key] ?? []).filter { !shouldRemove($0) }
            if remaining.isEmpty {
                assignments.removeValue(forKey: key)
                owners.removeValue(forKey: key)
            } else {
                assignments[key] = remaining
                if owners[key].map({ token in remaining.contains(where: { $0.token == token }) }) != true {
                    owners[key] = remaining.min(by: { $0.sequence < $1.sequence })?.token
                }
            }
        }
        for token in Array(currentKeys.keys) where shouldRemove(Assignment(token: token, sequence: 0,
                                                                           runtimeLeaseID: RuntimeHistoryLeaseID(rawValue: UUID()))) {
            currentKeys.removeValue(forKey: token)
        }
        for (id, lease) in Array(pendingLeases) where shouldRemove(Assignment(token: lease.token, sequence: 0,
                                                                               runtimeLeaseID: lease.runtimeLeaseID)) {
            pendingLeases.removeValue(forKey: id)
            releaseRuntimeLease?(lease.token, lease.runtimeLeaseID)
        }
    }
}

enum EditorOperationResult: Sendable {
    case success(PersistedLayout?)
    case failure(String)
}

@MainActor
final class LayoutController: ObservableObject {
    let displayProvider: DisplayProvider
    let spaceProvider: SpaceProvider
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
    @Published var appHistorySettings = AppHistorySettings()
    @Published var keyboardSettingsErrorMessage: String?
    @Published var appZoneHistory: [AppZoneHistoryKey: AppZoneHistoryRecord] = [:]
    @Published private(set) var appZoneHistoryAvailable = false
    @Published var appZoneHistoryErrorMessage: String?
    var cancelAutomaticRestores: (@MainActor () -> Void)?
    var invalidateManualCapture: @MainActor () -> Void = {}

    let storeCoordinator: PersistentStoreCoordinator?
    let appHistoryCoordinator = AppHistoryCoordinator()
    var savedLayouts: [UUID: PersistedLayout] = [:] {
        didSet {
            if oldValue != savedLayouts, !isApplyingQuickLayout {
                for (overrideKey, override) in Array(quickLayoutOverrides) {
                    if savedLayouts[override.id] == nil || oldValue[override.id] != savedLayouts[override.id] {
                        quickLayoutOverrides.removeValue(forKey: overrideKey)
                    }
                }
                invalidateAppliedDragLayout()
            }
        }
    }
    var assignments = PersistedAssignments() {
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
    var appZoneHistoryRetryRecords: [AppZoneHistoryKey: AppZoneHistoryRecord] = [:]
    var appZoneHistoryRetryLayouts: [AppZoneHistoryKey: PersistedLayout] = [:]
    var nextAppZoneHistoryRevision: UInt64 = 0
    var isRetryingSave = false
    var editorOperationTargets: [UUID: DisplaySelectionID] = [:]
    var editorOperationRevisions: [UUID: UInt64] = [:]
    var editorOperationScopes: [UUID: PersistedSpaceScope] = [:]
    var keyboardSettingsRevision: UInt64 = 0
    var keyboardSettingsRetrySnapshot: [String: PersistedSetting]?
    var layoutHotkeySettingsRevision: UInt64 = 0
    var layoutHotkeySettingsRetrySnapshot: [String: PersistedSetting]?
    var appHistorySettingsRevision: UInt64 = 0
    var appHistorySettingsRetrySnapshot: [String: PersistedSetting]?
    var dragLayoutRevision: UInt64 = 0
    let placementValidity: PlacementValidity
    let bundleIdentifierProvider: @MainActor (pid_t) -> String?
    var dragSettings = DragSettings()
    var dragSettingsRetrySnapshot: [String: PersistedSetting]?
    var dragSettingsRevision: UInt64 = 0
    var invalidateDragCommit: (@MainActor () -> Void)?
    var lastDragDisplaySnapshot: DisplaySnapshot?
    var lastDragCursorDisplayID: DisplaySelectionID?
    var refreshConfiguration: (@MainActor (Bool) -> DisplaySnapshot)?
    var isApplyingQuickLayout = false
    var quickLayoutMutationRevision: UInt64 = 0
    var quickLayoutOverrides: [LayoutOverrideKey: PersistedLayout] = [:]
    var degradedLayoutOverrides: [LayoutOverrideKey: PersistedLayout] = [:]
    var lastPublishedSelectedSpaceScope: PersistedSpaceScope?
    var lastPublishedSelectedSpaceMode: SpaceProviderMode?

    init(displayProvider: DisplayProvider = DisplayProvider(), spaceProvider: SpaceProvider = SpaceProvider(), storeCoordinator: PersistentStoreCoordinator? = nil,
         placementValidity: PlacementValidity = PlacementValidity(),
         bundleIdentifierProvider: @escaping @MainActor (pid_t) -> String? = {
             NSRunningApplication(processIdentifier: $0)?.bundleIdentifier
         }) {
        self.displayProvider = displayProvider
        self.spaceProvider = spaceProvider
        self.placementValidity = placementValidity
        self.bundleIdentifierProvider = bundleIdentifierProvider
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
}

@MainActor
extension LayoutController {
    func spaceSnapshot(for display: Display) -> DisplaySpaceSnapshot {
        guard let uuid = display.persistentID?.uuid else {
            let sessionOnly = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
            return DisplaySpaceSnapshot(displayUUID: sessionOnly, mode: .commonOnly, spaceID: nil, kind: nil, reason: nil)
        }
        return spaceProvider.snapshot(for: uuid)
    }

    func assignmentKey(for display: Display, scope: PersistedSpaceScope? = nil) -> PersistedAssignmentKey? {
        guard let uuid = display.persistentID?.uuid else { return nil }
        return PersistedAssignmentKey(displayUUID: uuid, spaceScope: scope ?? spaceSnapshot(for: display).persistedScope)
    }

    func overrideKey(for display: Display, scope: PersistedSpaceScope? = nil) -> LayoutOverrideKey {
        LayoutOverrideKey(displayID: display.id, spaceScope: scope ?? spaceSnapshot(for: display).persistedScope)
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
            appZoneHistory = state.appZoneHistory
            appZoneHistoryAvailable = state.appZoneHistoryAvailable
            nextAppZoneHistoryRevision = state.maxAppZoneHistoryRevision
            if !state.appZoneHistoryAvailable {
                appZoneHistoryErrorMessage = "App window history storage is unavailable. Layouts can still be used."
            }
            adoptSettings(state.settings)
            persistenceReady = true
            canEdit = acceptsChanges
            persistenceErrorMessage = state.assignmentsAvailable ? nil
                : "Saved display assignments are protected because their data format is unsupported or incomplete. Basic layouts remain available."
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
        degradedLayoutOverrides = degradedLayoutOverrides.filter { key, _ in
            guard let display = result.displays.first(where: { $0.id == key.displayID }) else { return false }
            return spaceSnapshot(for: display).mode == .degradedScoped
        }
        let currentScope = selectedDisplay.map { spaceSnapshot(for: $0).persistedScope }
        let currentMode = selectedDisplay.map { spaceSnapshot(for: $0).mode }
        let spaceChanged = currentScope != lastPublishedSelectedSpaceScope || currentMode != lastPublishedSelectedSpaceMode
        lastPublishedSelectedSpaceScope = currentScope
        lastPublishedSelectedSpaceMode = currentMode
        if selectedDisplayID != previous || spaceChanged { showLayoutForSelectedDisplay() } else { recalculate() }
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
            _ = assignments.removeValue(forKey: assignment.key)
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
            if appHistorySettingsRetrySnapshot != nil, !(await retryAppHistorySettingsSave()) { return false }
            if !(await retryAppZoneHistorySaves()) { return false }
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

    func placeSelectedZone(using placementController: PlacementController) async {
        guard canEdit else { return }
        cancelAutomaticRestores?()
        guard let zone = zones.first(where: { $0.id == selectedZoneID }) else { return }
        let zonesFingerprint = zonesDisplayFingerprint
        _ = refreshDisplays()
        guard selectedDisplay != nil else { return }
        guard zonesFingerprint == displayProvider.snapshot.fingerprint else {
            errorMessage = WindowManagementError.displayConfigurationChanged.localizedDescription
            return
        }
        do {
            guard let display = selectedDisplay else { return }
            let token = placementController.capturedRuntimeToken
            let manualCaptureIdentity = placementController.manualCaptureIdentity
            let placementRevision = placementValidity.revision
            let quickLayoutRevision = quickLayoutMutationRevision
            let targetLayout = currentLayout
            let targetZoneID = zone.id
            let targetDisplayID = display.id
            let bundleID = token.flatMap { bundleIdentifierProvider($0.pid) }
            let reservedHistoryLease = token.flatMap {
                reserveAppPlacement(token: $0, bundleID: bundleID, display: display, layout: targetLayout)
            }
            let historyLease: AppHistoryCoordinator.Lease?
            if let historyRuntime = placementController.historyRuntime {
                historyLease = await acquireAppPlacement(reservedHistoryLease, using: historyRuntime)
            } else {
                releaseAppPlacement(reservedHistoryLease)
                historyLease = nil
            }
            guard token == placementController.capturedRuntimeToken,
                  manualCaptureIdentity == placementController.manualCaptureIdentity,
                  placementRevision == placementValidity.revision,
                  quickLayoutRevision == quickLayoutMutationRevision,
                  currentLayout == targetLayout, selectedZoneID == targetZoneID,
                  selectedDisplay?.id == targetDisplayID, canEdit, acceptsChanges else {
                releaseAppPlacement(historyLease)
                return
            }
            defer { releaseAppPlacement(historyLease) }
            let context = PlacementHistoryContext(display: display, layout: targetLayout,
                                                  zoneIDs: [targetZoneID.rawValue], historyLease: historyLease,
                                                  expectedToken: token)
            try await placementController.placeCapturedWindowAsync(in: zone.frame,
                                                                   displayFingerprint: zonesFingerprint ?? "",
                                                                   historyContext: context)
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
