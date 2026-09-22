import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Dashed drop target. Accepts one or many audio files and forwards them to
/// `AppState.handleDrop`. Also offers a "Choose Songs…" button so the app
/// can be started without dragging, and shows a status line so a drop is
/// visibly acknowledged.
struct DropZoneView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var prefs: AppPreferences
    var mode: JobKind = .split

    @State private var isTargeted = false
    @State private var statusNote: String?
    @State private var statusIsError = false

    /// Split mode needs at least one stem selected; cleanup mode has no
    /// such requirement — any vocal stem can be dropped.
    private var hasStems: Bool { mode == .split ? !prefs.selectedStems.isEmpty : true }

    private var staged: [URL] { mode == .split ? appState.staged : appState.stagedCleanup }

    var body: some View {
        VStack(spacing: 8) {
            dropZone
            if !staged.isEmpty {
                stagedList
            }
            SplitButton(appState: appState, prefs: prefs, mode: mode)
            if let result = appState.lastResult {
                resultLine(result)
            } else if let statusNote, statusIsError {
                errorLine(statusNote)
            }
        }
    }

    /// Plain text under the button: "SUCCESS! Exported to <path>".
    private func resultLine(_ result: AppState.BatchResult) -> some View {
        let ok = result.failed == 0 && result.succeeded > 0
        return VStack(spacing: 4) {
            if result.folders.isEmpty {
                Text(result.succeeded == 0 ? "FAILED — see the job list below." : "FINISHED WITH ERRORS")
            } else {
                ForEach(result.folders, id: \.self) { folder in
                    Text("\(ok ? "SUCCESS!" : "FINISHED WITH ERRORS.") Exported to \(abbreviatedPath(folder.path))")
                        .truncationMode(.middle)
                        .lineLimit(2)
                        .help(folder.path)
                }
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(ok ? Color.green : Color.red)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .borderedBox()
    }

    private func errorLine(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Color.red)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .borderedBox()
    }

    /// Songs waiting for SPLIT/CLEAN, each with a remove button.
    private var stagedList: some View {
        VStack(spacing: 4) {
            ForEach(staged, id: \.self) { url in
                HStack {
                    Text(url.lastPathComponent)
                        .truncationMode(.middle)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        if mode == .split {
                            appState.removeStaged(url)
                        } else {
                            appState.removeStagedCleanup(url)
                        }
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(appState.isSplitting)
                    .help("Remove")
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .borderedBox()
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            VStack(spacing: 6) {
                if hasStems, !staged.isEmpty {
                    // Show the staged song title(s) in the box. The box stays a
                    // live drop target, so another drop still lands here.
                    ForEach(staged, id: \.self) { url in
                        Text(url.deletingPathExtension().lastPathComponent)
                            .font(.system(size: 18, weight: .semibold))
                            .truncationMode(.middle)
                            .lineLimit(1)
                            .padding(.horizontal, 16)
                    }
                    Text(mode == .split ? "Drop another song to add it" : "Drop another vocal stem to add it")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if hasStems {
                    Text(mode == .split ? "DROP SONG HERE" : "DROP VOCAL STEM HERE")
                        .font(.system(size: 18, weight: .semibold))
                        .tracking(1)
                    Text(mode == .split
                         ? "MP3 • WAV • M4A • FLAC • AIFF"
                         : "An already-split vocal track — WAV • AIFF • MP3 • M4A • FLAC")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Select at least one stem")
                        .font(.system(size: 16, weight: .semibold))
                }
            }

            Button(mode == .split ? "Choose Songs…" : "Choose Vocal Stem…") { chooseSongs() }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!hasStems)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.6),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [6, 4])
                )
        )
        .opacity(hasStems ? 1.0 : 0.4)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .dropDestination(for: URL.self) { urls, _ in
            accept(urls)
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }

    /// Returns whether the drop was accepted; always gives visible feedback.
    private func accept(_ urls: [URL]) -> Bool {
        guard hasStems else {
            statusNote = "Select at least one stem first."
            statusIsError = true
            return false
        }
        let audioURLs = urls.filter { !$0.hasDirectoryPath }
        guard !audioURLs.isEmpty else {
            statusNote = "That drop didn't contain an audio file."
            statusIsError = true
            return false
        }

        statusIsError = false
        statusNote = nil
        appState.lastResult = nil
        if mode == .split {
            appState.handleDrop(urls: audioURLs)
        } else {
            appState.handleCleanupDrop(urls: audioURLs)
        }
        return true
    }

    private func chooseSongs() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio]

        if panel.runModal() == .OK, !panel.urls.isEmpty {
            _ = accept(panel.urls)
        }
    }
}

/// Big SPLIT button. Idle until clicked; flashes while a batch is running.
/// The flash is clock-driven (TimelineView), not a repeatForever animation,
/// so it cannot keep going after the batch ends.
struct SplitButton: View {
    @ObservedObject var appState: AppState
    @ObservedObject var prefs: AppPreferences
    var mode: JobKind = .split

    private var canSplit: Bool {
        switch mode {
        case .split:
            return !appState.staged.isEmpty && !prefs.selectedStems.isEmpty && !appState.isSplitting
        case .cleanup:
            return !appState.stagedCleanup.isEmpty && !appState.isSplitting
        }
    }

    var body: some View {
        let splitting = appState.isSplitting
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let flashOn = splitting && (Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0)
            Button {
                if mode == .split {
                    appState.split()
                } else {
                    appState.cleanVocals()
                }
            } label: {
                // Background + border live INSIDE the label so the whole
                // green box is the hit area, not just the word.
                Text(splitting ? (mode == .split ? "SPLITTING…" : "CLEANING…") : (mode == .split ? "SPLIT" : "CLEAN"))
                    .font(.system(size: 20, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(splitting ? Color.black : (canSplit ? Color.white : Color.secondary))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(splitting
                                  ? Color.green.opacity(flashOn ? 1.0 : 0.35)
                                  : (canSplit ? Color.green.opacity(0.85) : Color.secondary.opacity(0.15)))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(splitting || canSplit ? Color.green : Color.secondary.opacity(0.5), lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.4), value: flashOn)
            .disabled(!canSplit)
        }
    }
}
