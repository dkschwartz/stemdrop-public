import XCTest
import AVFoundation
@testable import StemDrop

final class AudioConverterTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioConverterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    private func makeSourceSineWAV() throws -> URL {
        let sourceURL = tempDir.appendingPathComponent("source.wav")

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: 1,
            interleaved: true
        ) else {
            throw XCTSkip("Could not create source format")
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let file = try AVAudioFile(forWriting: sourceURL, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)

        let durationSeconds: Double = 2
        let frameCount = AVAudioFrameCount(durationSeconds * 48_000)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw XCTSkip("Could not create buffer")
        }
        buffer.frameLength = frameCount

        let frequency = 440.0
        let amplitude: Int16 = 10_000
        if let channelData = buffer.int16ChannelData {
            for frame in 0..<Int(frameCount) {
                let sampleValue = sin(2.0 * .pi * frequency * Double(frame) / 48_000.0)
                channelData[0][frame] = Int16(Double(amplitude) * sampleValue)
            }
        }

        try file.write(from: buffer)
        return sourceURL
    }

    func testConvertToEngineWAVFormat() async throws {
        let sourceURL = try makeSourceSineWAV()
        let converter = AudioConverter()

        let outputURL = try await converter.toEngineWAV(sourceURL, into: tempDir)

        let convertedFile = try AVAudioFile(forReading: outputURL)
        let convertedFormat = convertedFile.processingFormat

        XCTAssertEqual(convertedFormat.sampleRate, 44_100)
        XCTAssertEqual(convertedFormat.channelCount, 2)
        XCTAssertEqual(convertedFormat.commonFormat, .pcmFormatFloat32)
        XCTAssertFalse(convertedFormat.isInterleaved)

        // 2 s @ 48 kHz -> 2 s @ 44.1 kHz ≈ 88200 frames
        XCTAssertEqual(convertedFile.length, 88_200, accuracy: 200)

        // Export that converted stem as int24 and confirm it opens with 24-bit settings.
        let exportedURL = tempDir.appendingPathComponent("exported-int24.wav")
        let exporter = AudioExporter()
        try exporter.write(
            stemWAV: outputURL,
            to: exportedURL,
            settings: ExportSettings(format: .wav, bitDepth: .int24)
        )

        let asset = AVURLAsset(url: exportedURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            XCTFail("Exported file has no audio track")
            return
        }
        let formatDescriptions = try await track.load(.formatDescriptions)
        guard let formatDescription = formatDescriptions.first,
              let streamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            XCTFail("Could not read exported format description")
            return
        }

        XCTAssertEqual(streamBasicDescription.pointee.mBitsPerChannel, 24)
    }
}
