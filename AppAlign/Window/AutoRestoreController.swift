import AppKit
import Foundation

private struct AutoRestoreTarget {
    let display: Display
    let snapshot: KeyboardLayoutSnapshot
    let frame: CGRect
}

protocol AutoRestoreClock: Sendable {
    func now() -> UInt64
    func sleep(nanoseconds: UInt64) async throws
}

struct SystemAutoRestoreClock: AutoRestoreClock {
    func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    func sleep(nanoseconds: UInt64) async throws { try await Task.sleep(nanoseconds: nanoseconds) }
}

final class AutoRestoreTicketRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var tickets: [UUID: PlacementCommitTicket] = [:]

    func register(_ ticket: PlacementCommitTicket, id: UUID) {
        lock.lock()
        tickets[id] = ticket
        lock.unlock()
    }

    func remove(id: UUID) {
        lock.lock()
        tickets.removeValue(forKey: id)
        lock.unlock()
    }

    func invalidateAll() {
        lock.lock()
        let active = Array(tickets.values)
        lock.unlock()
        for ticket in active { ticket.invalidate() }
    }
}

@MainActor
final class AutoRestoreController {
    private final class Episode {
        let id = UUID()
        let token: RuntimeWindowToken
        let bundleID: String
        let startedAt: UInt64
        let deadline: UInt64
        let configurationRevision: UInt64
        var ticket: PlacementCommitTicket?
        var task: Task<Void, Never>?

        init(token: RuntimeWindowToken, bundleID: String, startedAt: UInt64, deadline: UInt64,
             configurationRevision: UInt64) {
            self.token = token
            self.bundleID = bundleID
            self.startedAt = startedAt
            self.deadline = deadline
            self.configurationRevision = configurationRevision
        }
    }

    private let layout: LayoutController
    private let runtime: any AutomaticWindowOperating
    private let ticketRegistry: AutoRestoreTicketRegistry
    private let clock: any AutoRestoreClock
    private let cursorLocationProvider: @MainActor () -> CGPoint?
    private var episodes: [RuntimeWindowToken: Episode] = [:]
    private var inFlightEpisodes: [UUID: Episode] = [:]
    private var active = true
    var activeEpisodeCount: Int { episodes.count }
    var inFlightEpisodeCount: Int { inFlightEpisodes.count }

    init(layout: LayoutController, runtime: any AutomaticWindowOperating,
         ticketRegistry: AutoRestoreTicketRegistry = AutoRestoreTicketRegistry(),
         clock: any AutoRestoreClock = SystemAutoRestoreClock(),
         cursorLocationProvider: @escaping @MainActor () -> CGPoint? = { CGEvent(source: nil)?.location }) {
        self.layout = layout
        self.runtime = runtime
        self.ticketRegistry = ticketRegistry
        self.clock = clock
        self.cursorLocationProvider = cursorLocationProvider
    }

    func restoreNewWindow(_ initial: WindowObservationCandidate, bundleID: String) {
        if case .terminal = initial.readiness { return }
        guard active, layout.appHistorySettings.monitorNewWindows, layout.appHistorySettings.restoreNewWindows,
              layout.appZoneHistoryAvailable, !bundleID.isEmpty,
              episodes[initial.token] == nil, inFlightEpisodes.count < 8 else { return }
        let startedAt = clock.now()
        let episode = Episode(token: initial.token, bundleID: bundleID, startedAt: startedAt,
                              deadline: startedAt + 5_000_000_000,
                              configurationRevision: layout.placementValidity.revision.configuration)
        episodes[initial.token] = episode
        inFlightEpisodes[episode.id] = episode
        episode.task = Task { @MainActor [weak self, weak episode] in
            guard let self, let episode else { return }
            await self.run(episode, initial: initial)
        }
    }

    func cancelAll() {
        active = false
        for episode in episodes.values { cancel(episode) }
        episodes.removeAll()
        active = true
    }

    func cancel(token: RuntimeWindowToken) {
        guard let episode = episodes.removeValue(forKey: token) else { return }
        cancel(episode)
    }

    func cancel(processID: pid_t, generation: UUID) {
        for token in episodes.keys where token.pid == processID && token.processGeneration == generation {
            cancel(token: token)
        }
    }

    func stop() {
        active = false
        for episode in episodes.values { cancel(episode) }
        episodes.removeAll()
    }

    func drainForShutdown() async {
        stop()
        while !inFlightEpisodes.isEmpty {
            let tasks = inFlightEpisodes.values.compactMap(\.task)
            guard !tasks.isEmpty else { return }
            for task in tasks { await task.value }
        }
    }

    func resume() { active = true }

    private func cancel(_ episode: Episode) {
        episode.task?.cancel()
        episode.ticket?.invalidate()
    }

    private func isCurrent(_ episode: Episode) -> Bool {
        active && !Task.isCancelled && episodes[episode.token] === episode
            && episode.configurationRevision == layout.placementValidity.revision.configuration
            && clock.now() < episode.deadline
            && layout.appHistorySettings.monitorNewWindows && layout.appHistorySettings.restoreNewWindows
            && layout.appZoneHistoryAvailable
    }

    private func run(_ episode: Episode, initial: WindowObservationCandidate) async {
        defer { finish(episode) }
        let cumulativeDelays: [UInt64] = [0, 100_000_000, 300_000_000, 700_000_000, 1_500_000_000]
        var latest = initial
        for attempt in cumulativeDelays.indices {
            guard isCurrent(episode) else { break }
            let targetTime = episode.startedAt + cumulativeDelays[attempt]
            let now = clock.now()
            let delay = targetTime > now ? targetTime - now : 0
            if delay > 0 {
                do { try await clock.sleep(nanoseconds: delay) } catch { break }
                guard isCurrent(episode) else { break }
            }
            if case .temporarilyUnavailable = latest.readiness {
                let now = clock.now()
                guard now < episode.deadline else { break }
                do {
                    let result = try await runtime.observedWindows(applicationPID: episode.token.pid,
                                                                   processGeneration: episode.token.processGeneration,
                                                                   ownPID: ProcessInfo.processInfo.processIdentifier,
                                                                   deadline: min(episode.deadline, now + 200_000_000))
                    guard isCurrent(episode) else { break }
                    guard let refreshed = result.candidates.first(where: { $0.token == episode.token }) else {
                        if result.isComplete { break }
                        continue
                    }
                    latest = refreshed
                } catch {
                    if let managementError = error as? WindowManagementError,
                       case .accessibilityPermissionRequired = managementError { break }
                    continue
                }
            }
            if case .terminal = latest.readiness { break }
            guard case .ready(let windowFrame) = latest.readiness else { continue }
            if await attemptPlacement(episode, windowFrame: windowFrame) { return }
            break
        }
    }

    private func attemptPlacement(_ episode: Episode, windowFrame: CGRect) async -> Bool {
        guard isCurrent(episode), let target = restoreTarget(bundleID: episode.bundleID, windowFrame: windowFrame) else { return false }
        guard target.snapshot.revision == layout.placementValidity.revision,
              target.snapshot.spaceSnapshot.persistedScope == layout.spaceSnapshot(for: target.display).persistedScope else { return false }
        let lease = layout.reserveAppPlacement(token: episode.token, bundleID: episode.bundleID,
                                               display: target.display, layout: target.snapshot.layout)
        let retainDeadline = min(episode.deadline, clock.now() + 200_000_000)
        guard let acquired = await layout.acquireAppPlacement(lease, using: runtime,
                                                              retainDeadline: retainDeadline), isCurrent(episode),
              target.snapshot.revision == layout.placementValidity.revision,
              target.snapshot.spaceSnapshot.persistedScope == layout.spaceSnapshot(for: target.display).persistedScope else {
            layout.releaseAppPlacement(lease)
            return false
        }
        let now = clock.now()
        guard now < episode.deadline, isCurrent(episode),
              target.snapshot.revision == layout.placementValidity.revision,
              target.snapshot.spaceSnapshot.persistedScope == layout.spaceSnapshot(for: target.display).persistedScope,
              let ticket = layout.placementValidity.reserve(startDeadline: min(episode.deadline, now + 200_000_000),
                                                            totalDeadline: episode.deadline) else {
            layout.releaseAppPlacement(acquired)
            return false
        }
        episode.ticket = ticket
        ticketRegistry.register(ticket, id: episode.id)
        defer {
            // The reservation remains occupied until the backend await has returned,
            // even if cancellation removed the episode from the registry meanwhile.
            ticket.finish()
            ticketRegistry.remove(id: episode.id)
            if episode.ticket === ticket { episode.ticket = nil }
        }
        let revision = ticket.revision
        let displayFingerprint = layout.displayProvider.snapshot.fingerprint
        do {
            let actualFrame = try await runtime.moveHistoryWindow(episode.token, lease: acquired.runtimeLeaseID,
                                                                  to: target.frame, ticket: ticket) { [weak self, weak episode] in
                guard let self, let episode, self.isCurrent(episode), ticket.state == .pending,
                      self.layout.placementValidity.revision == revision,
                      self.layout.displayProvider.snapshot.fingerprint == displayFingerprint else { return false }
                return true
            }
            guard isCurrent(episode), Self.framesMatch(actualFrame, target.frame),
                  ticket.completeIfCurrent(now: clock.now()) else {
                layout.releaseAppPlacement(acquired)
                ticket.invalidate()
                return false
            }
            layout.acceptSuccessfulAppRestore(acquired)
            return true
        } catch {
            layout.releaseAppPlacement(acquired)
            ticket.invalidate()
            return false
        }
    }

    private static func framesMatch(_ actual: CGRect, _ expected: CGRect) -> Bool {
        guard DisplayGeometry.isFinite(actual), DisplayGeometry.isFinite(expected) else { return false }
        return abs(actual.minX - expected.minX) <= 2 && abs(actual.minY - expected.minY) <= 2
            && abs(actual.width - expected.width) <= 2 && abs(actual.height - expected.height) <= 2
    }

    private func restoreTarget(bundleID: String, windowFrame: CGRect) -> AutoRestoreTarget? {
        let current = layout.refreshDisplays()
        guard !current.displays.isEmpty else { return nil }
        let cursor = cursorLocationProvider()
        for display in Self.displayPreferenceOrder(displays: current.displays, windowFrame: windowFrame, cursor: cursor) {
            guard let displayUUID = display.persistentID?.uuid,
                  let snapshot = layout.appliedLayoutSnapshot(for: display) else { continue }
            let key = AppZoneHistoryKey(bundleID: bundleID, displayUUID: displayUUID,
                                        spaceScope: snapshot.spaceSnapshot.persistedScope, layoutID: snapshot.layout.id)
            guard snapshot.spaceSnapshot.allowsAutomaticRestore else { continue }
            guard let record = layout.appZoneHistory[key], !record.zoneIDs.isEmpty,
                  let zones = Optional(snapshot.zones.filter { record.zoneIDs.contains($0.id.rawValue) }),
                  Set(zones.map { $0.id.rawValue }) == Set(record.zoneIDs) else { continue }
            let frame = zones.dropFirst().reduce(zones[0].frame) { $0.union($1.frame) }
            guard DisplayGeometry.isFinite(frame), frame.width > 0, frame.height > 0 else { continue }
            return AutoRestoreTarget(display: display, snapshot: snapshot, frame: frame)
        }
        return nil
    }

    static func displayPreferenceOrder(displays: [Display], windowFrame: CGRect, cursor: CGPoint?) -> [Display] {
        let rankedByWindow = displays.sorted { lhs, rhs in
            let left = windowFrame.intersection(lhs.frame).areaForHistory
            let right = windowFrame.intersection(rhs.frame).areaForHistory
            if left != right { return left > right }
            return lhs.frame.contains(windowFrame.centerForHistory) && !rhs.frame.contains(windowFrame.centerForHistory)
        }
        let byWindow = rankedByWindow.first.flatMap { display in
            let overlap = windowFrame.intersection(display.frame).areaForHistory
            return overlap > 0 || display.frame.contains(windowFrame.centerForHistory) ? display : nil
        }
        let byCursor = cursor.flatMap { location in displays.first(where: { $0.frame.contains(location) }) }
        let primary = displays.first(where: \.isPrimary)
        var ordered: [Display] = []
        for display in [byWindow, byCursor, primary].compactMap({ $0 }) + displays.sorted(by: { stableHistoryKey($0) < stableHistoryKey($1) })
            where !ordered.contains(where: { $0.id == display.id }) {
            ordered.append(display)
        }
        return ordered
    }

    private func finish(_ episode: Episode) {
        inFlightEpisodes.removeValue(forKey: episode.id)
        if episodes[episode.token] === episode { episodes.removeValue(forKey: episode.token) }
        ticketRegistry.remove(id: episode.id)
    }
}

private extension CGRect {
    var areaForHistory: CGFloat { isNull || isInfinite ? 0 : max(0, width) * max(0, height) }
    var centerForHistory: CGPoint { CGPoint(x: midX, y: midY) }
}

private func stableHistoryKey(_ display: Display) -> String {
    display.persistentID?.uuid.uuidString ?? "~\(display.sessionID.uuidString)"
}
