import SwiftUI

/// Model stems and three frequency-based drum detail exports.
struct StemSelectorView: View {
    @ObservedObject var prefs: AppPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(StemType.allCases, id: \.self) { stem in
                Toggle(stem.displayName, isOn: binding(for: stem))
                    .toggleStyle(.checkbox)
            }
            Text("Kick, Snare, and Cymbals are rough frequency-based splits of the Drums stem.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .borderedBox()
    }

    private func binding(for stem: StemType) -> Binding<Bool> {
        Binding(
            get: { prefs.selectedStems.contains(stem) },
            set: { isOn in
                if isOn {
                    prefs.selectedStems.insert(stem)
                } else {
                    prefs.selectedStems.remove(stem)
                }
            }
        )
    }
}
