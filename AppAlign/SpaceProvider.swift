import AppKit
import Foundation

enum SpaceProviderMode: Equatable, Sendable {
    /// Public notifications only: preserve the existing display-wide behavior.
    case commonOnly
    /// A stable ID was returned by a backend validated for this OS and hardware.
    case validatedScoped
    /// Scoped mode was requested, but its current snapshot is unavailable.
    case degradedScoped
}

enum SpaceKind: Equatable, Sendable {
    case regular
    case fullscreen
}

struct RuntimeSpaceID: Equatable, Sendable {
    let provider: String
    let value: String
    let isPersistent: Bool

    init?(provider: String, value: String, isPersistent: Bool) {
        guard !provider.isEmpty, !value.isEmpty else { return nil }
        self.provider = provider
        self.value = value
        self.isPersistent = isPersistent
    }

    var persisted: PersistentSpaceID? {
        guard isPersistent else { return nil }
        return PersistentSpaceID(backend: provider, opaqueID: value)
    }
}

struct DisplaySpaceSnapshot: Equatable, Sendable {
    let displayUUID: UUID
    let mode: SpaceProviderMode
    let spaceID: RuntimeSpaceID?
    let kind: SpaceKind?
    let reason: String?

    init(displayUUID: UUID, mode: SpaceProviderMode, spaceID: RuntimeSpaceID?, kind: SpaceKind?, reason: String?) {
        if mode == .validatedScoped, spaceID?.persisted == nil || kind == nil {
            self.displayUUID = displayUUID
            self.mode = .degradedScoped
            self.spaceID = nil
            self.kind = nil
            self.reason = reason ?? "Space identifier is not persistent or incomplete."
        } else {
            self.displayUUID = displayUUID
            self.mode = mode
            self.spaceID = spaceID
            self.kind = kind
            self.reason = reason
        }
    }

    var persistedScope: PersistedSpaceScope {
        guard mode == .validatedScoped, let id = spaceID?.persisted else { return .common }
        return .space(id)
    }

    var recordsHistory: Bool { mode != .degradedScoped }
    var allowsAutomaticRestore: Bool { mode != .degradedScoped }
}

struct LayoutOverrideKey: Hashable, Sendable {
    let displayID: DisplaySelectionID
    let spaceScope: PersistedSpaceScope
}

/// Backends may only expose identifiers. They must not mutate Spaces or move windows.
protocol ReadOnlySpaceBackend: Sendable {
    var identifier: String { get }
    var canAdoptStableIdentifiers: Bool { get }
    var allowsScopedQueries: Bool { get }
    /// Synchronous private IPC/helper waits must run on a dedicated serial worker, never
    /// MainActor or a cooperative executor. Return only after query work and any child
    /// exit/reap complete; the controller retains its single running slot until then.
    /// Queries are host-gated; the helper independently checks the expected OS and build.
    func snapshot(for displayUUID: UUID) async throws -> ReadOnlySpaceValue?
    func snapshot(for displayUUID: UUID, deadline: UInt64) async throws -> ReadOnlySpaceValue?
}

extension ReadOnlySpaceBackend {
    var allowsScopedQueries: Bool { canAdoptStableIdentifiers }
    func snapshot(for displayUUID: UUID, deadline _: UInt64) async throws -> ReadOnlySpaceValue? {
        try await snapshot(for: displayUUID)
    }
}

struct ReadOnlySpaceValue: Equatable, Sendable {
    let id: String
    let kind: SpaceKind
}

struct SpaceProviderRefreshRequest: Sendable {
    let intentRevision: UInt64
    let displayUUIDs: [UUID]
    let scopedModeRequested: Bool
    let backend: (any ReadOnlySpaceBackend)?
}

struct SpaceProviderCandidate: Equatable, Sendable {
    let intentRevision: UInt64
    let displayUUIDs: [UUID]
    let scopedModeRequested: Bool
    let snapshots: [UUID: DisplaySpaceSnapshot]
}

/// Scoped reads are enabled only on the user-confirmed macOS 27 build 26A434 arm64 host.
/// The namespace remains stable across normal and explicit-preview launches.
struct SkyLightReadOnlyBackend: ReadOnlySpaceBackend {
    static let scopedNamespace = "skylight-preview-27-26A434"
    static let currentArchitecture: String = {
        #if arch(arm64)
        "arm64"
        #else
        "unsupported"
        #endif
    }()

    var identifier: String { hostAllowsScopedQueries ? Self.scopedNamespace : "skylight-read-only" }
    let isValidatedForCurrentSystem: Bool
    let previewEnabled: Bool
    private let hostAllowsScopedQueries: Bool
    private let runner: SpaceHelperProcessRunner

    static var previewRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--appalign-space-preview")
    }

    static func permitsScopedSpaceUse(host: SpaceHelperHostIdentity?, architecture: String) -> Bool {
        host == .supported && architecture == "arm64"
    }

    static var currentHostSupportsScopedSpaceUse: Bool {
        permitsScopedSpaceUse(host: SpaceHelperHostIdentity.current(), architecture: currentArchitecture)
    }

    init(runner: SpaceHelperProcessRunner = SpaceHelperProcessRunner(),
         previewRequested: Bool = SkyLightReadOnlyBackend.previewRequested,
         hostIdentity: SpaceHelperHostIdentity? = SpaceHelperHostIdentity.current(),
         architecture: String = SkyLightReadOnlyBackend.currentArchitecture) {
        self.runner = runner
        hostAllowsScopedQueries = Self.permitsScopedSpaceUse(host: hostIdentity, architecture: architecture)
        isValidatedForCurrentSystem = hostAllowsScopedQueries
        self.previewEnabled = previewRequested && hostAllowsScopedQueries
    }

    var canAdoptStableIdentifiers: Bool { isValidatedForCurrentSystem }
    var allowsScopedQueries: Bool { hostAllowsScopedQueries }

    func snapshot(for displayUUID: UUID) async throws -> ReadOnlySpaceValue? {
        try await snapshot(for: displayUUID, deadline: UInt64.max)
    }

    func snapshot(for displayUUID: UUID, deadline: UInt64) async throws -> ReadOnlySpaceValue? {
        // The helper's own OS/build checks remain an independent boundary.
        guard allowsScopedQueries else { return nil }
        return try await runner.snapshot(for: displayUUID, deadline: deadline)
    }
}

@MainActor
final class SpaceProvider {
    private(set) var mode: SpaceProviderMode = .commonOnly
    private(set) var snapshots: [UUID: DisplaySpaceSnapshot] = [:]
    private let backend: (any ReadOnlySpaceBackend)?
    private let notificationCenter: NotificationCenter
    private var scopedModeRequested = false
    private var intentRevision: UInt64 = 0
    private var observer: NSObjectProtocol?

    init(backend: (any ReadOnlySpaceBackend)? = SkyLightReadOnlyBackend(),
         notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.backend = backend
        self.notificationCenter = notificationCenter
    }

    static func production(backend: (any ReadOnlySpaceBackend)? = SkyLightReadOnlyBackend(),
                           notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) -> SpaceProvider {
        let provider = SpaceProvider(backend: backend, notificationCenter: notificationCenter)
        if backend?.allowsScopedQueries == true { provider.requestScopedMode() }
        return provider
    }

    func start(onChange: @escaping @Sendable () -> Void = {}) {
        guard observer == nil else { return }
        observer = notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: nil
        ) { _ in
            onChange()
        }
    }

    func stop() {
        guard let observer else { return }
        notificationCenter.removeObserver(observer)
        self.observer = nil
    }

    func requestScopedMode() {
        scopedModeRequested = true
        intentRevision &+= 1
    }

    func useCommonOnlyMode() {
        scopedModeRequested = false
        intentRevision &+= 1
    }

    func makeRefreshRequest(displays: [UUID]) -> SpaceProviderRefreshRequest {
        var seen: Set<UUID> = []
        let uniqueDisplays = displays.filter { seen.insert($0).inserted }
        return SpaceProviderRefreshRequest(intentRevision: intentRevision, displayUUIDs: uniqueDisplays,
                                           scopedModeRequested: scopedModeRequested, backend: backend)
    }

    nonisolated func readCandidate(for request: SpaceProviderRefreshRequest) async -> SpaceProviderCandidate {
        await readCandidate(for: request, deadline: UInt64.max)
    }

    nonisolated func readCandidate(for request: SpaceProviderRefreshRequest,
                                   deadline: UInt64) async -> SpaceProviderCandidate {
        var result: [UUID: DisplaySpaceSnapshot] = [:]
        if request.scopedModeRequested, let backend = request.backend, backend.allowsScopedQueries {
            let initialTime = DispatchTime.now().uptimeNanoseconds
            let available = deadline > initialTime ? deadline - initialTime : 0
            let reserve = min(100_000_000, available / 10)
            let usableDeadline = deadline > reserve ? deadline - reserve : deadline
            for (index, displayUUID) in request.displayUUIDs.enumerated() {
                let now = DispatchTime.now().uptimeNanoseconds
                let remaining = usableDeadline > now ? usableDeadline - now : 0
                let displayCount = UInt64(request.displayUUIDs.count - index)
                let displayBudget = min(250_000_000, remaining / displayCount)
                guard displayBudget > 0 else {
                    result[displayUUID] = DisplaySpaceSnapshot(
                        displayUUID: displayUUID, mode: .degradedScoped, spaceID: nil, kind: nil,
                        reason: "Space information deadline expired."
                    )
                    continue
                }
                let displayDeadline = now &+ displayBudget
                let found: ReadOnlySpaceValue?
                do { found = try await backend.snapshot(for: displayUUID, deadline: displayDeadline) } catch { found = nil }
                if let found,
                   let runtimeID = RuntimeSpaceID(provider: backend.identifier, value: found.id, isPersistent: true),
                   runtimeID.persisted != nil {
                    result[displayUUID] = DisplaySpaceSnapshot(displayUUID: displayUUID, mode: .validatedScoped,
                                                               spaceID: runtimeID, kind: found.kind, reason: nil)
                } else {
                    result[displayUUID] = DisplaySpaceSnapshot(displayUUID: displayUUID, mode: .degradedScoped,
                                                               spaceID: nil, kind: nil, reason: "Space information is unavailable.")
                }
            }
        } else if request.scopedModeRequested {
            result = Dictionary(uniqueKeysWithValues: request.displayUUIDs.map {
                ($0, DisplaySpaceSnapshot(displayUUID: $0, mode: .degradedScoped, spaceID: nil, kind: nil,
                                          reason: "No validated Space provider is available."))
            })
        } else {
            result = Dictionary(uniqueKeysWithValues: request.displayUUIDs.map {
                ($0, DisplaySpaceSnapshot(displayUUID: $0, mode: .commonOnly, spaceID: nil, kind: nil, reason: nil))
            })
        }
        return SpaceProviderCandidate(intentRevision: request.intentRevision, displayUUIDs: request.displayUUIDs,
                                      scopedModeRequested: request.scopedModeRequested, snapshots: result)
    }

    nonisolated func fallbackCandidate(for request: SpaceProviderRefreshRequest) -> SpaceProviderCandidate {
        let snapshotMode: SpaceProviderMode = request.scopedModeRequested ? .degradedScoped : .commonOnly
        let result = Dictionary(uniqueKeysWithValues: request.displayUUIDs.map { displayUUID in
            (displayUUID, DisplaySpaceSnapshot(displayUUID: displayUUID, mode: snapshotMode, spaceID: nil,
                                               kind: nil,
                                               reason: request.scopedModeRequested ? "Space information timed out." : nil))
        })
        return SpaceProviderCandidate(intentRevision: request.intentRevision, displayUUIDs: request.displayUUIDs,
                                      scopedModeRequested: request.scopedModeRequested, snapshots: result)
    }

    @discardableResult
    func publish(_ candidate: SpaceProviderCandidate, for request: SpaceProviderRefreshRequest) -> Bool {
        guard candidate.intentRevision == intentRevision,
              candidate.intentRevision == request.intentRevision,
              candidate.displayUUIDs == request.displayUUIDs,
              candidate.scopedModeRequested == request.scopedModeRequested,
              Set(candidate.snapshots.keys) == Set(request.displayUUIDs),
              candidate.snapshots.allSatisfy({ key, snapshot in
                  guard key == snapshot.displayUUID else { return false }
                  switch snapshot.mode {
                  case .commonOnly:
                      return !request.scopedModeRequested && snapshot.spaceID == nil && snapshot.kind == nil
                  case .validatedScoped:
                      return request.scopedModeRequested && snapshot.spaceID?.persisted != nil && snapshot.kind != nil
                  case .degradedScoped:
                      return request.scopedModeRequested && snapshot.spaceID == nil && snapshot.kind == nil
                  }
              })
        else { return false }
        snapshots = candidate.snapshots
        mode = !candidate.snapshots.isEmpty && candidate.snapshots.values.allSatisfy { $0.mode == .validatedScoped } && request.scopedModeRequested
            ? .validatedScoped
            : (request.scopedModeRequested ? .degradedScoped : .commonOnly)
        return true
    }

    func snapshot(for displayUUID: UUID) -> DisplaySpaceSnapshot {
        snapshots[displayUUID] ?? DisplaySpaceSnapshot(displayUUID: displayUUID, mode: mode,
                                                       spaceID: nil, kind: nil,
                                                       reason: mode == .degradedScoped ? "Space information is unavailable." : nil)
    }
}
