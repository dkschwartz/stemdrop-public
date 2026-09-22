import SwiftUI

/// Three bordered rows of Vocal Cleanup options (re-separate, voice gate,
/// denoise), bound to the remembered preferences.
struct CleanupOptionsView: View {
    @ObservedObject var prefs: AppPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            reseparateRow
            gateRow
            denoiseRow
        }
    }

    private var reseparateRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Re-separate (run through Demucs again)", isOn: $prefs.cleanupReseparate)
                .toggleStyle(.checkbox)

            if prefs.cleanupReseparate {
                Picker("", selection: $prefs.cleanupReseparatePasses) {
                    Text("1 pass").tag(1)
                    Text("2 passes").tag(2)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 160)
            }

            Text("Removes music that bleeds through while the voice is singing.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .borderedBox()
    }

    private var gateRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Voice gate", isOn: $prefs.cleanupGate)
                .toggleStyle(.checkbox)

            if prefs.cleanupGate {
                HStack(spacing: 8) {
                    Text("Sensitivity")
                    Slider(value: $prefs.cleanupGateThreshold, in: 0.1...0.9)
                    Text("\(Int((prefs.cleanupGateThreshold * 100).rounded()))%")
                        .frame(width: 40, alignment: .trailing)
                }
            }

            Text("Silences the gaps between phrases where no voice is detected.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .borderedBox()
    }

    private var denoiseRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Denoise", isOn: $prefs.cleanupDenoise)
                .toggleStyle(.checkbox)

            if prefs.cleanupDenoise {
                HStack(spacing: 8) {
                    Text("Amount")
                    Slider(value: $prefs.cleanupDenoiseAmount, in: 0.1...1.0)
                    Text("\(Int((prefs.cleanupDenoiseAmount * 100).rounded()))%")
                        .frame(width: 40, alignment: .trailing)
                }
            }

            Text("Light spectral cleanup of the low-level bed under the voice.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .borderedBox()
    }
}
