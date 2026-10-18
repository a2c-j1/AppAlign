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
    func snapshot(for displayUUID: UUID) -> (id: String, kind: SpaceKind)?
}

/// An intentionally closed gate until the private ABI and IDs have been verified on
/// the supported macOS 26 + M1 + Dell setup. This implementation never resolves or
/// calls a SkyLight symbol on unverified systems.
struct SkyLightReadOnlyBackend: ReadOnlySpaceBackend {
    let identifier = "skylight-read-only"
    let isValidatedForCurrentSystem = false
    var canAdoptStableIdentifiers: Bool { isValidatedForCurrentSystem }

    func snapshot(for displayUUID: UUID) -> (id: String, kind: SpaceKind)? {
        guard isValidatedForCurrentSystem else { return nil }
        return nil
    }
}

@MainActor
final class SpaceProvider {
    private(set) var mode: SpaceProviderMode = .commonOnly
    private(set) var snapshots: [UUID: DisplaySpaceSnapshot] = [:]
    private let backend: (any ReadOnlySpaceBackend)?
    private let notificationCenter: NotificationCenter
    private var scopedModeRequested = false
    private var observer: NSObjectProtocol?

    init(backend: (any ReadOnlySpaceBackend)? = SkyLightReadOnlyBackend(),
         notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.backend = backend
        self.notificationCenter = notificationCenter
    }

    static func production(backend: (any ReadOnlySpaceBackend)? = SkyLightReadOnlyBackend(),
                           notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) -> SpaceProvider {
        let provider = SpaceProvider(backend: backend, notificationCenter: notificationCenter)
        if backend?.canAdoptStableIdentifiers == true { provider.requestScopedMode() }
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
        mode = .degradedScoped
        snapshots = snapshots.mapValues {
            DisplaySpaceSnapshot(displayUUID: $0.displayUUID, mode: .degradedScoped, spaceID: nil, kind: nil,
                                 reason: "Space information is being refreshed.")
        }
    }

    func useCommonOnlyMode() {
        scopedModeRequested = false
        mode = .commonOnly
        snapshots = snapshots.mapValues {
            DisplaySpaceSnapshot(displayUUID: $0.displayUUID, mode: .commonOnly, spaceID: nil, kind: nil, reason: nil)
        }
    }

    @discardableResult
    func refresh(displays: [UUID]) -> [UUID: DisplaySpaceSnapshot] {
        var result: [UUID: DisplaySpaceSnapshot] = [:]
        if scopedModeRequested, let backend, backend.canAdoptStableIdentifiers {
            for displayUUID in displays {
                if let found = backend.snapshot(for: displayUUID),
                   let runtimeID = RuntimeSpaceID(provider: backend.identifier, value: found.id, isPersistent: true),
                   runtimeID.persisted != nil {
                    result[displayUUID] = DisplaySpaceSnapshot(displayUUID: displayUUID, mode: .validatedScoped,
                                                               spaceID: runtimeID, kind: found.kind, reason: nil)
                } else {
                    result[displayUUID] = DisplaySpaceSnapshot(displayUUID: displayUUID, mode: .degradedScoped,
                                                               spaceID: nil, kind: nil, reason: "Space information is unavailable.")
                }
            }
            mode = result.values.allSatisfy { $0.mode == .validatedScoped } ? .validatedScoped : .degradedScoped
        } else if scopedModeRequested {
            mode = .degradedScoped
            result = Dictionary(uniqueKeysWithValues: displays.map {
                ($0, DisplaySpaceSnapshot(displayUUID: $0, mode: .degradedScoped, spaceID: nil, kind: nil,
                                          reason: "No validated Space provider is available."))
            })
        } else {
            mode = .commonOnly
            result = Dictionary(uniqueKeysWithValues: displays.map {
                ($0, DisplaySpaceSnapshot(displayUUID: $0, mode: .commonOnly, spaceID: nil, kind: nil, reason: nil))
            })
        }
        snapshots = result
        return result
    }

    func snapshot(for displayUUID: UUID) -> DisplaySpaceSnapshot {
        snapshots[displayUUID] ?? DisplaySpaceSnapshot(displayUUID: displayUUID, mode: mode,
                                                       spaceID: nil, kind: nil,
                                                       reason: mode == .degradedScoped ? "Space information is unavailable." : nil)
    }
}
