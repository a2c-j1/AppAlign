import AppKit
import SwiftUI

struct EditableLayoutPreview: View {
    let display: Display
    let zones: [Zone]
    @ObservedObject var model: LayoutEditorModel
    let definition: LayoutDefinition?
    @State private var dragStart: CGRect?
    @State private var dragZoneID: ZoneID?
    @State private var isResizing = false
    @State private var ratioStartValues: [Int]?
    @State private var pointerGestureActive = false
    @State private var ignorePointerGestureUntilEnd = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor))
                RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.4))
                ForEach(zones) { zone in
                    let rect = localFrame(zone.frame, area: display.workArea, size: proxy.size)
                    zoneView(zone, frame: rect, proxy: proxy)
                        .zIndex(Double(zone.id.rawValue))
                }
                if case .grid(let grid) = definition {
                    boundaryHandles(grid: grid, size: proxy.size)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onChange(of: model.gestureCancellationGeneration) { _, _ in
                ignorePointerGestureUntilEnd = pointerGestureActive
                dragStart = nil
                dragZoneID = nil
                ratioStartValues = nil
                isResizing = false
            }
            .onTapGesture { point in
                if isCanvasLayout, let zone = zones.reversed().first(where: { $0.frame.contains(workPoint(point, size: proxy.size)) }) {
                    model.selectZones([zone.id.rawValue])
                }
            }
        }
        .aspectRatio(display.workArea.width / display.workArea.height, contentMode: .fit)
        .frame(maxHeight: 330)
    }

    private var previewArea: CGRect {
        if case .focus = definition { return display.workArea.insetBy(dx: model.draft.spacing, dy: model.draft.spacing) }
        return display.workArea
    }

    @ViewBuilder
    private func zoneView(_ zone: Zone, frame: CGRect, proxy: GeometryProxy) -> some View {
        let selected = model.selectedZoneIDs.contains(zone.id.rawValue)
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 5)
                .fill(selected ? Color.accentColor.opacity(0.38) : Color.accentColor.opacity(0.18))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? Color.accentColor : Color.accentColor.opacity(0.8), lineWidth: 2))
                .overlay(Text("Zone \(zone.id.displayNumber)").font(.caption.weight(.semibold)).foregroundStyle(.primary))
                .contentShape(Rectangle())
                .onTapGesture {
                    if NSEvent.modifierFlags.contains(.shift) {
                        var ids = model.selectedZoneIDs
                        if !ids.insert(zone.id.rawValue).inserted { ids.remove(zone.id.rawValue) }
                        model.selectZones(ids)
                    } else { model.selectZones([zone.id.rawValue]) }
                }
            if canvas != nil, selected {
                Circle().fill(Color.accentColor).frame(width: 14, height: 14).overlay(Circle().stroke(.white, lineWidth: 1))
                    .offset(x: -4, y: -4)
                    .gesture(canvasDrag(zone: zone, size: proxy.size, resizing: true))
            }
        }
        .frame(width: frame.width, height: frame.height)
        .frame(width: max(frame.width, 20), height: max(frame.height, 20))
        .position(x: frame.midX, y: frame.midY)
        .gesture(canvasDrag(zone: zone, size: proxy.size, resizing: false))
    }

    private var canvas: CanvasLayout? {
        switch definition {
        case .canvas(let value), .focus(let value): value
        case .grid, .none: nil
        }
    }

    private var isCanvasLayout: Bool {
        if case .canvas = definition { return true }
        return false
    }

    private func canvasDrag(zone: Zone, size: CGSize, resizing: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard !ignorePointerGestureUntilEnd, canvas != nil else { return }
                pointerGestureActive = true
                if dragZoneID != zone.id {
                    model.beginGesture()
                    dragZoneID = zone.id
                    dragStart = canvas?.zones.first(where: { $0.id == zone.id })?.frame
                    isResizing = resizing
                }
                guard let start = dragStart, let canvas else { return }
                let effectiveSize = CGSize(width: size.width * previewArea.width / display.workArea.width,
                                           height: size.height * previewArea.height / display.workArea.height)
                let deltaX = value.translation.width * canvas.referenceSize.width / effectiveSize.width
                let deltaY = value.translation.height * canvas.referenceSize.height / effectiveSize.height
                let frame: CGRect
                if isResizing {
                    frame = CGRect(x: start.minX, y: start.minY,
                                   width: min(canvas.referenceSize.width - start.minX, max(1, start.width + deltaX)),
                                   height: min(canvas.referenceSize.height - start.minY, max(1, start.height + deltaY)))
                } else {
                    frame = CGRect(x: min(canvas.referenceSize.width - start.width, max(0, start.minX + deltaX)),
                                   y: min(canvas.referenceSize.height - start.height, max(0, start.minY + deltaY)),
                                   width: start.width, height: start.height)
                }
                model.moveOrResizeCanvasZone(id: zone.id, frame: frame)
            }
            .onEnded { _ in
                model.endGesture()
                dragStart = nil
                dragZoneID = nil
                isResizing = false
                pointerGestureActive = false
                ignorePointerGestureUntilEnd = false
            }
    }

    @ViewBuilder
    private func boundaryHandles(grid: GridLayout, size: CGSize) -> some View {
        ForEach(Array(grid.columnPercentages.dropLast().indices), id: \.self) { index in
            let columnPosition = CGFloat(grid.columnPercentages.prefix(index + 1).reduce(0, +)) / CGFloat(LayoutEngine.percentageTotal) * size.width
            Rectangle().fill(.clear).frame(width: 12, height: size.height).contentShape(Rectangle())
                .overlay(Rectangle().fill(Color.accentColor.opacity(0.45)).frame(width: 1))
                .position(x: columnPosition, y: size.height / 2)
                .gesture(ratioDrag(grid.columnPercentages, index: index, size: size, horizontal: true))
        }
        ForEach(Array(grid.rowPercentages.dropLast().indices), id: \.self) { index in
            let rowPosition = CGFloat(grid.rowPercentages.prefix(index + 1).reduce(0, +)) / CGFloat(LayoutEngine.percentageTotal) * size.height
            Rectangle().fill(.clear).frame(width: size.width, height: 12).contentShape(Rectangle())
                .overlay(Rectangle().fill(Color.accentColor.opacity(0.45)).frame(height: 1))
                .position(x: size.width / 2, y: rowPosition)
                .gesture(ratioDrag(grid.rowPercentages, index: index, size: size, horizontal: false))
        }
    }

    private func ratioDrag(_ values: [Int], index: Int, size: CGSize, horizontal: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                guard !ignorePointerGestureUntilEnd else { return }
                pointerGestureActive = true
                if ratioStartValues == nil {
                    model.beginGesture()
                    ratioStartValues = values
                }
                guard let base = ratioStartValues else { return }
                let pairTotal = base[index] + base[index + 1]
                let length = horizontal ? size.width : size.height
                let delta = Int(((horizontal ? gesture.translation.width : gesture.translation.height) / length * CGFloat(LayoutEngine.percentageTotal)).rounded())
                let first = min(pairTotal - 1, max(1, base[index] + delta))
                var next = base
                next[index] = first
                next[index + 1] = pairTotal - first
                model.setGridPercentages(next, axis: horizontal ? .columns : .rows)
            }
            .onEnded { _ in
                model.endGesture()
                ratioStartValues = nil
                pointerGestureActive = false
                ignorePointerGestureUntilEnd = false
            }
    }

    private func localFrame(_ frame: CGRect, area: CGRect, size: CGSize) -> CGRect {
        CGRect(x: (frame.minX - area.minX) / area.width * size.width,
               y: (frame.minY - area.minY) / area.height * size.height,
               width: frame.width / area.width * size.width,
               height: frame.height / area.height * size.height)
    }

    private func workPoint(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: display.workArea.minX + point.x / size.width * display.workArea.width,
                y: display.workArea.minY + point.y / size.height * display.workArea.height)
    }
}
