import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("AppAlign")
                    .font(.largeTitle.weight(.semibold))
                Text("Arrange windows into spaces that fit your work.")
                    .foregroundStyle(.secondary)
            }

            ContentUnavailableView {
                Label("Your first layout starts here", systemImage: "rectangle.split.3x1")
            } description: {
                Text("Display detection and the zone editor are the first milestone.")
            }
            .frame(minHeight: 220)

            HStack {
                Label("Accessibility access will be requested when placement is enabled.", systemImage: "hand.raised")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Get Started") {}
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
            }
        }
        .padding(28)
        .frame(minWidth: 560, minHeight: 390)
    }
}
