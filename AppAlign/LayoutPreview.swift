import SwiftUI

struct LayoutPreview: View {
    let display: Display?
    let zones: [Zone]
    let selectedZoneID: ZoneID?
    let select: (ZoneID) -> Void

    var body: some View {
        Group {
            if let display {
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .windowBackgroundColor))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.5)))
                        ForEach(zones) { zone in
                            let frame = localFrame(zone.frame, area: display.workArea, size: proxy.size)
                            Button {
                                select(zone.id)
                            } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(zone.id == selectedZoneID ? Color.accentColor.opacity(0.38) : Color.accentColor.opacity(0.14))
                                    RoundedRectangle(cornerRadius: 5)
                                        .stroke(zone.id == selectedZoneID ? Color.accentColor : Color.accentColor.opacity(0.65), lineWidth: 2)
                                    Text("Zone \(zone.id.displayNumber)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.primary)
                                }
                            }
                            .buttonStyle(.plain)
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                        }
                    }
                }
                .aspectRatio(display.workArea.width / display.workArea.height, contentMode: .fit)
                .frame(maxHeight: 360)
            } else {
                ContentUnavailableView("No display", systemImage: "display")
            }
        }
        .accessibilityLabel("Layout preview")
    }

    private func localFrame(_ frame: CGRect, area: CGRect, size: CGSize) -> CGRect {
        let scaleX = size.width / area.width
        let scaleY = size.height / area.height
        return CGRect(
            x: (frame.minX - area.minX) * scaleX,
            y: (frame.minY - area.minY) * scaleY,
            width: frame.width * scaleX,
            height: frame.height * scaleY
        )
    }
}
