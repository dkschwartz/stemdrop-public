import Foundation

protocol StemSeparator: Sendable {                               // D2: swap engine here later
    func separate(inputWAV: URL, stems: Set<StemType>, workDir: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> [StemType: URL]
}

protocol VocalCleaner: Sendable {
    func clean(inputWAV: URL, settings: CleanupSettings, workDir: URL,
               progress: @escaping @Sendable (Double) -> Void) async throws -> URL   // path to vocals.wav
}
