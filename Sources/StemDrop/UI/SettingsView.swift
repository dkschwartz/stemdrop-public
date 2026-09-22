import SwiftUI
import AppKit

/// Settings scene (Cmd-,). Groups mirror the product brief plus the AUDIO /
/// TAGS blocks from SPEC.md §7 and §12.
struct SettingsView: View {
    @ObservedObject var prefs: AppPreferences
    @ObservedObject var modelManager: ModelManager

    init(appState: AppState) {
        self.prefs = appState.prefs
        self.modelManager = appState.modelManager
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                generalGroup
                audioGroup
                tagsGroup
                modelGroup
            }
            .padding(20)
            .frame(width: 460, alignment: .top)
        }
    }

    // MARK: - GENERAL

    private var generalGroup: some View {
        group("GENERAL") {
            Text("Default stems")
                .font(.caption)
                .foregroundStyle(.secondary)
            StemSelectorView(prefs: prefs)

            Divider()

            Text("Output")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("", selection: $prefs.outputMode) {
                Text("Folder: \(abbreviatedPath(prefs.outputRootPath))").tag(OutputMode.root)
                Text("Same folder as the song").tag(OutputMode.sameFolder)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if prefs.outputMode == .root {
                HStack(spacing: 8) {
                    Text(prefs.outputRootPath)
                        .font(.caption)
                        .truncationMode(.middle)
                        .lineLimit(1)
                    Spacer()
                    Button("Change…") { chooseFolder() }
                        .buttonStyle(.bordered)
                }
            }

            Divider()

            Text("Format")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Picker("", selection: $prefs.outputFormat) {
                    Text("WAV").tag(OutputFormat.wav)
                    Text("AIFF").tag(OutputFormat.aiff)
                    Text("MP3").tag(OutputFormat.mp3)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 110)

                if prefs.outputFormat != .mp3 {
                    Picker("", selection: $prefs.wavBitDepth) {
                        Text("16-bit").tag(WAVBitDepth.int16)
                        Text("24-bit").tag(WAVBitDepth.int24)
                        Text("32-bit float").tag(WAVBitDepth.float32)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 130)
                }
                Spacer()
            }
            if prefs.outputFormat == .wav {
                Text("Finder can't display Album for WAV files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text("After processing")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Reveal output in Finder", isOn: $prefs.revealInFinder)
            Toggle("Play start/finish sounds", isOn: $prefs.playSound)
            Toggle("Delete temporary files immediately", isOn: $prefs.deleteTempImmediately)
        }
    }

    // MARK: - AUDIO

    private var audioGroup: some View {
        group("AUDIO") {
            Toggle("Keep original length (pad or trim to match the source)", isOn: $prefs.preserveOriginalLength)
            Toggle("Normalize output", isOn: $prefs.normalizeOutput)
            Toggle("Trim trailing silence", isOn: $prefs.trimTrailingSilence)
            Text("Defaults leave the audio untouched.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - TAGS

    private var tagsGroup: some View {
        group("TAGS") {
            HStack(spacing: 8) {
                Text("Album tag")
                TextField("", text: $prefs.albumTag)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }
            Text("Artist and title are copied from the source file.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - MODEL

    private var modelGroup: some View {
        group("MODEL") {
            Text(modelStateText)
        }
    }

    private var modelStateText: String {
        switch modelManager.state {
        case .unknown:
            return "Not installed"
        case .installed:
            return "Installed"
        case .downloading:
            return "Downloading…"
        case .failed(let message):
            return message.isEmpty ? "Download failed" : message
        }
    }

    // MARK: - Helpers

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .borderedBox()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: prefs.outputRootPath, isDirectory: true)

        if panel.runModal() == .OK, let url = panel.url {
            prefs.outputRootPath = url.path
        }
    }
}
