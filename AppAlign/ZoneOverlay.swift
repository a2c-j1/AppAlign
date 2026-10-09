import AppKit
import CoreGraphics

@MainActor
protocol ZoneOverlayPresenting: AnyObject {
    func show(_ snapshot: DragLayoutSnapshot, selected: ZoneID?)
    func hideAll()
}

@MainActor
protocol ZoneOverlayPanelPresenting: AnyObject {
    func show(display: Display, snapshot: DragLayoutSnapshot, selected: ZoneID?)
    func hide()
}

@MainActor
final class ZoneOverlayManager: ZoneOverlayPresenting {
    private let makePanel: @MainActor () -> any ZoneOverlayPanelPresenting
    private var panels: [DisplaySelectionID: any ZoneOverlayPanelPresenting] = [:]

    init(makePanel: @escaping @MainActor () -> any ZoneOverlayPanelPresenting = { AppKitZoneOverlayPanel() }) {
        self.makePanel = makePanel
    }

    func show(_ snapshot: DragLayoutSnapshot, selected: ZoneID?) {
        let liveIDs = Set(snapshot.displays.map(\.id))
        let removedIDs = panels.keys.filter { !liveIDs.contains($0) }
        for id in removedIDs { panels[id]?.hide(); panels.removeValue(forKey: id) }
        for display in snapshot.displays {
            guard display.id == snapshot.display.id else {
                panels[display.id]?.hide()
                continue
            }
            let panel = panels[display.id] ?? makePanel()
            panels[display.id] = panel
            panel.show(display: display, snapshot: snapshot, selected: selected)
        }
    }

    func hideAll() { panels.values.forEach { $0.hide() } }
}

@MainActor
private final class AppKitZoneOverlayPanel: ZoneOverlayPanelPresenting {
    private let panel: NSPanel
    private var view: ZoneOverlayView?

    init() {
        panel = ZoneOverlayWindow(contentRect: .zero,
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    func show(display: Display, snapshot: DragLayoutSnapshot, selected: ZoneID?) {
        guard let cocoaFrame = try? DisplayGeometry.cocoaFrame(from: display.frame, primaryFrame: snapshot.primaryFrame) else { return }
        panel.setFrame(cocoaFrame, display: true)
        let content = view ?? ZoneOverlayView(frame: NSRect(origin: .zero, size: cocoaFrame.size))
        content.frame = NSRect(origin: .zero, size: cocoaFrame.size)
        content.update(display: display, zones: snapshot.zones, selected: selected)
        view = content
        panel.contentView = content
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

@MainActor
private final class ZoneOverlayWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class ZoneOverlayView: NSView {
    private var display: Display?
    private var zones: [Zone] = []
    private var selected: ZoneID?

    override var isOpaque: Bool { false }

    func update(display: Display, zones: [Zone], selected: ZoneID?) {
        self.display = display
        self.zones = zones
        self.selected = selected
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let display else { return }
        for zone in zones {
            let frame = NSRect(x: zone.frame.minX - display.frame.minX,
                               y: display.frame.maxY - zone.frame.maxY,
                               width: zone.frame.width, height: zone.frame.height)
            let active = zone.id == selected
            let lineWidth: CGFloat = active ? 4 : 2
            let path = NSBezierPath(roundedRect: frame.insetBy(dx: lineWidth / 2, dy: lineWidth / 2), xRadius: 9, yRadius: 9)
            (active ? NSColor.systemBlue : NSColor.black).withAlphaComponent(active ? 0.92 : 0.7).setStroke()
            path.lineWidth = lineWidth
            path.stroke()
            let label = zone.id.displayNumber as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 24, weight: .bold),
                .foregroundColor: NSColor.white
            ]
            let size = label.size(withAttributes: attributes)
            let badge = NSRect(x: frame.midX - size.width / 2 - 10, y: frame.midY - size.height / 2 - 6,
                               width: size.width + 20, height: size.height + 12)
            NSColor.black.withAlphaComponent(0.72).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 10, yRadius: 10).fill()
            label.draw(at: NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2), withAttributes: attributes)
        }
    }
}
