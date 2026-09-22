import SwiftUI

/// Six stem checkboxes in the product mock's order (Vocals, Drums, Bass,
/// Guitar, Piano, Other), bound to the remembered selection.
struct StemSelectorView: View {
    @ObservedObject var prefs: AppPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(StemType.allCases, id: \.self) { stem in
                Toggle(stem.displayName, isOn: binding(for: stem))
                    .toggleStyle(.checkbox)
            }
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
