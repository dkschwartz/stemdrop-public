import SwiftUI
import AppKit

/// Shared 1-pt border used on every visual element (Daniel's hard UI rule).
struct BorderedBox: ViewModifier {
    var cornerRadius: CGFloat = 6

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(.secondary.opacity(0.5), lineWidth: 1)
        )
    }
}

extension View {
    func borderedBox(cornerRadius: CGFloat = 6) -> some View {
        modifier(BorderedBox(cornerRadius: cornerRadius))
    }
}

/// `~/…`-abbreviated display path for the output-folder row.
func abbreviatedPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == home { return "~" }
    if path.hasPrefix(home + "/") {
        return "~" + path.dropFirst(home.count)
    }
    return path
}

struct MainView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var prefs: AppPreferences

    init(appState: AppState) {
        self.appState = appState
        self.prefs = appState.prefs
    }

    var body: some View {
        VStack(spacing: 12) {
            tabPicker

            switch appState.activeTab {
            case .split:
                splitTab
            case .cleanup:
                cleanupTab
            }
        }
        .padding(16)
        .frame(width: 480)
        // The window is content-sized (StemDropApp), so it only grows when
        // the content's minimum does: the cleanup tab is the taller of the two.
        .frame(minHeight: appState.activeTab == .cleanup ? 700 : 480, alignment: .top)
    }

    private var tabPicker: some View {
        Picker("", selection: $appState.activeTab) {
            Text("Split").tag(MainTab.split)
            Text("Vocal Cleanup").tag(MainTab.cleanup)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(8)
        .borderedBox()
    }

    private var splitTab: some View {
        VStack(spacing: 12) {
            StemSelectorView(prefs: prefs)

            DropZoneView(appState: appState, prefs: prefs, mode: .split)

            ExportOptionsView(prefs: prefs)

            if !appState.jobs.isEmpty {
                JobQueueView(jobs: appState.jobs)
            }
        }
    }

    private var cleanupTab: some View {
        VStack(spacing: 12) {
            CleanupOptionsView(prefs: prefs)

            DropZoneView(appState: appState, prefs: prefs, mode: .cleanup)

            ExportOptionsView(
                prefs: prefs,
                caption: "The cleaned vocal is saved as \"[song name] - Vocals CLEAN\" next to the original stem (or in the folder above)."
            )

            if !appState.jobs.isEmpty {
                JobQueueView(jobs: appState.jobs)
            }
        }
    }
}

/// Format dropdown (WAV / AIFF / MP3), bit depth, and the output-folder
/// picker, shown under the stem checkboxes (SPEC.md §13).
struct ExportOptionsView: View {
    @ObservedObject var prefs: AppPreferences
    var caption: String = "Stems are saved to a new folder named \"[song name] STEM SPLIT\" inside this folder."

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            formatRow
            outputRow
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var formatRow: some View {
        HStack(spacing: 12) {
            Text("Format:")
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
        .padding(10)
        .borderedBox()
    }

    private var outputRow: some View {
        HStack(spacing: 8) {
            Text("Output folder:")

            if prefs.outputMode == .sameFolder {
                Text("Same folder as the song")
                    .truncationMode(.middle)
                    .lineLimit(1)
            } else {
                Text(abbreviatedPath(prefs.outputRootPath))
                    .truncationMode(.middle)
                    .lineLimit(1)
                    .help(prefs.outputRootPath)
            }

            Spacer()

            Button("Change…") { chooseFolder() }
                .buttonStyle(.bordered)
                .disabled(prefs.outputMode == .sameFolder)
        }
        .padding(10)
        .borderedBox()
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
