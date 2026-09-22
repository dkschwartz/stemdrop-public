import Foundation

/// Runs `stemdrop_engine.encode_mp3` (lameenc, 320 kbps CBR) as a
/// one-shot `Process`, using the same JSON-lines protocol as
/// `PythonEngineRunner` (SPEC.md §13). Synchronous because
/// `AudioExporting.write` is synchronous — encoding a single stem is
/// fast enough not to need progress reporting.
struct MP3Encoder: Sendable {
    private let pythonPath: URL

    init(pythonPath: URL? = nil) {
        self.pythonPath = pythonPath ?? EnginePaths.pythonExecutable()
    }

    func encode(wav: URL, to mp3: URL, bitrateKbps: Int = 320) throws {
        let process = Process()
        process.executableURL = pythonPath
        process.arguments = [
            "-m", "stemdrop_engine.encode_mp3",
            "--input", wav.path,
            "--output", mp3.path,
            "--bitrate", String(bitrateKbps)
        ]

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw StemDropError.separationFailed
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if let stderrText = String(data: stderrData, encoding: .utf8) {
            for line in stderrText.split(separator: "\n", omittingEmptySubsequences: true) {
                Log.engine(String(line))
            }
        }

        var sawDone = false
        var errorMessage: String?
        if let stdoutText = String(data: stdoutData, encoding: .utf8) {
            for line in stdoutText.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let event = JSONLinesParser.parse(String(line)) else { continue }
                switch event {
                case .done:
                    sawDone = true
                case .error(let message):
                    errorMessage = message
                default:
                    break
                }
            }
        }

        if let errorMessage {
            Log.engine("mp3 encoder reported error: \(errorMessage)")
            throw StemDropError.separationFailed
        }
        if process.terminationStatus != 0 || !sawDone {
            throw StemDropError.separationFailed
        }
    }
}
