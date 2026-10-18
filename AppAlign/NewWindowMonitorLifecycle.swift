import Foundation

extension NewWindowMonitor {
    func spaceChanged() {
        ticketRegistry.invalidateAll()
        onEnvironmentChanged?()
    }

    func cancelPendingAutoRestoreTickets() { ticketRegistry.invalidateAll() }

    func waitForCurrentDrain() async { await drainTask?.value }

    func recordDiagnostic(_ message: String) {
        guard !diagnostics.contains(message) else { return }
        if diagnostics.count == 8 { diagnostics.removeFirst() }
        diagnostics.append(message)
    }
}
