import CoreGraphics
import Foundation

struct KeyboardExtensionAttempt {
    let id: UUID
    let lifecycleGeneration: UInt64
    let historyGeneration: UInt64
    let modifierMask: UInt64
}

@MainActor
extension KeyboardSnapController {
    func handle(_ action: KeyboardSnapAction) {
        guard isRunning, !isBusy, !dragGateClosed else { return }
        setBusy(true)
        let generation = lifecycleGeneration
        let attempt: KeyboardExtensionAttempt?
        if case .extend = action {
            let modifierMask = layoutController.keyboardSettings.shortcuts[action].map {
                Self.eventFlags(for: $0.modifiers)
            } ?? 0
            let captured = KeyboardExtensionAttempt(id: UUID(), lifecycleGeneration: generation,
                                                    historyGeneration: extensionHistoryGeneration,
                                                    modifierMask: modifierMask)
            pendingExtensionAttempt = captured
            attempt = captured
        } else {
            attempt = nil
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if let attempt, self.pendingExtensionAttempt?.id == attempt.id {
                    self.pendingExtensionAttempt = nil
                }
                self.setBusy(false)
                self.didFinishAction?()
            }
            await self.perform(action, generation: generation, extensionAttempt: attempt)
        }
    }

    func flagsMonitorStatus(_ status: DragMonitorStatus) {
        switch status {
        case .ready:
            extensionFlagsAvailable = true
            previousModifierFlags = nil
        case .failed(let reason), .interrupted(let reason):
            extensionFlagsAvailable = false
            previousModifierFlags = nil
            resetNavigationHistory()
            statusMessage = "Keyboard extension history is cleared because modifier monitoring is unavailable: \(reason)"
        }
    }

    func setExtensionFlagsAvailable(_ available: Bool) {
        guard extensionFlagsAvailable != available else { return }
        extensionFlagsAvailable = available
        previousModifierFlags = nil
        if !available { resetNavigationHistory() }
    }

    func extensionModifierFlagsChanged(_ flags: UInt64) {
        guard extensionFlagsAvailable else { return }
        let requiredFlags = configuredExtensionModifierMasks
        let activeOwnerMask = pendingExtensionAttempt?.modifierMask ?? lastExtensionModifierMask
        guard let previousModifierFlags else {
            self.previousModifierFlags = flags
            // If an extension owns the history, only its chord can release it. Without an
            // owner (for example, before the first extension), any active extension chord
            // keeps history until the next observed transition.
            let trackedChordIsReleased = activeOwnerMask.map { flags & $0 != $0 }
                ?? (!requiredFlags.isEmpty && !requiredFlags.contains { flags & $0 == $0 })
            if trackedChordIsReleased {
                resetNavigationHistory()
            }
            return
        }
        self.previousModifierFlags = flags
        let releasedOwnedChord = activeOwnerMask.map { flags & $0 != $0 }
            ?? requiredFlags.contains { previousModifierFlags & $0 == $0 && flags & $0 != $0 }
        if releasedOwnedChord {
            resetNavigationHistory()
        }
    }

    func extend(_ action: KeyboardSnapAction, focused: RuntimeWindowSnapshot,
                attempt: KeyboardExtensionAttempt) async {
        guard let snapshot = layoutController.appliedLayoutSnapshot(for: focused.frame),
              let direction = extensionDirection(action) else { return }
        guard attempt.lifecycleGeneration == lifecycleGeneration,
              attempt.historyGeneration == extensionHistoryGeneration else { return }
        let existing = sessions[focused.token.id]
        var currentSession = existing
        let existingExtensionIsCurrent = existing.map {
            $0.extensionPlacementRevision == snapshot.revision && $0.extensionLayoutID == snapshot.layout.id
                && $0.extensionWorkArea == snapshot.display.selectionKey
                && $0.extensionLastFrame.map { Self.framesMatch($0, focused.frame) } == true
        } ?? false
        if var stale = currentSession, !existingExtensionIsCurrent {
            resetExtensionHistory(&stale)
            stale.activeAddress = Self.resolvedCurrentAddress(stale.activeAddress, frame: focused.frame,
                                                               displays: snapshot.displayLayouts)
            currentSession = stale
        }
        let base = existingExtensionIsCurrent ? existing?.extensionEndpoint
            : Self.resolvedCurrentAddress(existing?.activeAddress, frame: focused.frame, displays: snapshot.displayLayouts)
        var session = currentSession ?? KeyboardPlacementSession(
            token: focused.token, originalFrame: focused.frame,
            restoreAnchor: KeyboardRestoreAnchor(displayID: snapshot.display.id, displayFrame: snapshot.display.frame,
                                                  configurationFingerprint: snapshot.displayFingerprint),
            activeAddress: base, extensionAnchor: nil, extensionEndpoint: nil,
            extensionLayoutID: nil, extensionWorkArea: nil
        )
        if session.extensionWorkArea != snapshot.display.selectionKey || session.extensionLayoutID != snapshot.layout.id {
            resetExtensionHistory(&session)
        }
        let endpoint = extensionTarget(action, snapshot: snapshot, session: session, frame: focused.frame)
        guard let endpoint, endpoint.0.workArea == snapshot.display.selectionKey else {
            statusMessage = "Keyboard extension stays within the current display layout."
            return
        }
        if session.extensionAnchor == nil && base != nil {
            session.extensionAnchor = base
            session.extensionEndpoint = base
            session.extensionWorkArea = snapshot.display.selectionKey
            session.extensionLayoutID = snapshot.layout.id
            session.extendedAddresses = base.map { [$0] } ?? []
        }
        let currentEndpoint = session.extensionEndpoint ?? base
        guard let currentZone = currentEndpoint.flatMap({ address in
            snapshot.zones.first { $0.id == address.zoneID }
        }) else {
            session.extensionAnchor = endpoint.0
            session.extensionEndpoint = endpoint.0
            let target = KeyboardNavigationTarget(session: session, address: endpoint.0, zone: endpoint.1)
            await placeExtended([endpoint.1], endpoint: target, snapshot: snapshot, focused: focused,
                                attempt: attempt)
            return
        }
        guard let nextZone = ZoneNavigator.directionalZone(from: currentZone.frame, zones: snapshot.zones,
                                                            direction: direction, workArea: snapshot.display.workArea,
                                                            cycle: false, excludingID: currentZone.id),
              let anchorAddress = session.extensionAnchor ?? currentEndpoint,
              let anchorZone = snapshot.zones.first(where: { $0.id == anchorAddress.zoneID }) else {
            statusMessage = "There is no eligible zone in that direction."
            return
        }
        let selection = ZoneSelectionEngine.range(anchor: [anchorZone], current: [nextZone], zones: snapshot.zones)
        guard !selection.isEmpty else { return }
        let target = KeyboardNavigationTarget(session: session,
                                              address: ZoneAddress(workArea: snapshot.display.selectionKey, zoneID: nextZone.id),
                                              zone: nextZone)
        await placeExtended(selection, endpoint: target, snapshot: snapshot, focused: focused,
                            attempt: attempt)
    }

    func resetNavigationHistory(for workArea: WorkAreaKey? = nil) {
        activeExtensionTicket?.invalidate()
        extensionHistoryGeneration &+= 1
        lastExtensionModifierMask = nil
        for tokenID in Array(sessions.keys) {
            guard var session = sessions[tokenID], workArea == nil || session.extensionWorkArea == workArea else { continue }
            resetExtensionHistory(&session)
            sessions[tokenID] = session
        }
    }

    private func placeExtended(_ selection: [Zone], endpoint: KeyboardNavigationTarget,
                               snapshot: KeyboardLayoutSnapshot, focused: RuntimeWindowSnapshot,
                               attempt: KeyboardExtensionAttempt) async {
        guard let targetFrame = ZoneSelectionEngine.union(of: selection.map(\.frame)),
              layoutController.isCurrent(snapshot, for: focused.frame), frontmostPID == focused.token.pid else { return }
        var session = endpoint.session
        session.extensionAnchor = session.extensionAnchor ?? endpoint.address
        session.extensionEndpoint = endpoint.address
        session.extensionLayoutID = snapshot.layout.id
        session.extensionWorkArea = snapshot.display.selectionKey
        session.extensionPlacementRevision = snapshot.revision
        if sessions[focused.token.id] == nil {
            guard sessions.count < maximumSessions else { statusMessage = "Restore sessions are full."; return }
            await backend.retain(focused.token)
            guard isRunning, lifecycleGeneration == attempt.lifecycleGeneration,
                  extensionHistoryGeneration == attempt.historyGeneration else { await backend.discard(focused.token); return }
        }
        sessions[focused.token.id] = session
        hasRestoreTarget = true
        do {
            let now = DispatchTime.now().uptimeNanoseconds
            guard let ticket = validity.reserve(startDeadline: now + 2_000_000_000,
                                                totalDeadline: now + 5_000_000_000) else {
                statusMessage = "A window placement is already pending or in progress."
                return
            }
            installActiveExtensionTicket(ticket, token: focused.token)
            lastExtensionModifierMask = attempt.modifierMask
            defer { finishActiveTicket(ticket) }
            let savedSettings = layoutController.keyboardSettings
            let preflight: @MainActor @Sendable () -> Bool = { [weak self] in
                guard let self, self.isRunning, !self.dragGateClosed,
                      self.lifecycleGeneration == attempt.lifecycleGeneration,
                      self.extensionFlagsAvailable, self.extensionHistoryGeneration == attempt.historyGeneration,
                      self.layoutController.keyboardSettings.isEnabled,
                      self.frontmostPID == focused.token.pid, self.accessibilityIsTrusted,
                      self.layoutController.keyboardSettings == savedSettings else { return false }
                return self.layoutController.isCurrent(snapshot, for: focused.frame)
            }
            let actualFrame = try await backend.move(focused.token, to: targetFrame, ticket: ticket, preflight: preflight)
            guard Self.matches(actualFrame, targetFrame) else { throw KeyboardSnapError.readbackMismatch }
            guard preflight(), ticket.completeIfCurrent(now: DispatchTime.now().uptimeNanoseconds) else {
                throw WindowManagementError.displayConfigurationChanged
            }
            session.activeAddress = endpoint.address
            session.extensionEndpoint = endpoint.address
            session.extensionLayoutID = snapshot.layout.id
            session.extensionWorkArea = snapshot.display.selectionKey
            session.extensionPlacementRevision = snapshot.revision
            session.extensionLastFrame = actualFrame
            session.extendedAddresses = selection.map { ZoneAddress(workArea: snapshot.display.selectionKey, zoneID: $0.id) }
            if session.extensionAnchor == nil { session.extensionAnchor = endpoint.address }
            sessions[focused.token.id] = session
            statusMessage = "Extended window across \(selection.count) zones."
        } catch {
            guard isRunning, lifecycleGeneration == attempt.lifecycleGeneration,
                  extensionHistoryGeneration == attempt.historyGeneration else { return }
            statusMessage = "Extension failed; the original frame is saved for Restore. \(error.localizedDescription)"
        }
    }

    func resetExtensionHistory(_ session: inout KeyboardPlacementSession) {
        session.extensionAnchor = nil
        session.extensionEndpoint = nil
        session.extensionLayoutID = nil
        session.extensionWorkArea = nil
        session.extensionPlacementRevision = nil
        session.extensionLastFrame = nil
        session.extendedAddresses = []
    }

    private func extensionDirection(_ action: KeyboardSnapAction) -> NavigationDirection? {
        guard case .extend(let direction) = action else { return nil }
        return direction
    }

    func extensionTarget(_ action: KeyboardSnapAction, snapshot: KeyboardLayoutSnapshot,
                         session: KeyboardPlacementSession?, frame: CGRect) -> (ZoneAddress, Zone)? {
        guard let direction = extensionDirection(action) else { return nil }
        let extensionStateIsCurrent = session.map {
            $0.extensionPlacementRevision == snapshot.revision && $0.extensionLayoutID == snapshot.layout.id
                && $0.extensionWorkArea == snapshot.display.selectionKey
                && $0.extensionLastFrame.map { Self.framesMatch($0, frame) } == true
        } ?? false
        let address = (extensionStateIsCurrent ? session?.extensionEndpoint : nil)
            ?? Self.resolvedCurrentAddress(session?.activeAddress, frame: frame, displays: snapshot.displayLayouts)
        let currentZone = address.flatMap { candidate in
            candidate.workArea == snapshot.display.selectionKey ? snapshot.zones.first { $0.id == candidate.zoneID } : nil
        }
        let sourceFrame = currentZone?.frame ?? frame
        guard let target = ZoneNavigator.directionalZone(from: sourceFrame, zones: snapshot.zones,
                                                          direction: direction, workArea: snapshot.display.workArea,
                                                          cycle: false, excludingID: currentZone?.id) else { return nil }
        return (ZoneAddress(workArea: snapshot.display.selectionKey, zoneID: target.id), target)
    }

    static func eventFlags(for modifiers: UInt32) -> UInt64 {
        var flags: UInt64 = 0
        if modifiers & KeyboardShortcut.shift != 0 { flags |= CGEventFlags.maskShift.rawValue }
        if modifiers & KeyboardShortcut.control != 0 { flags |= CGEventFlags.maskControl.rawValue }
        if modifiers & KeyboardShortcut.option != 0 { flags |= CGEventFlags.maskAlternate.rawValue }
        if modifiers & KeyboardShortcut.command != 0 { flags |= CGEventFlags.maskCommand.rawValue }
        return flags
    }

    private var configuredExtensionModifierMasks: Set<UInt64> {
        Set(layoutController.keyboardSettings.shortcuts.compactMap { action, shortcut -> UInt64? in
            guard case .extend = action else { return nil }
            let mask = Self.eventFlags(for: shortcut.modifiers)
            return mask == 0 ? nil : mask
        })
    }
}
