import XCTest
import AVFoundation
@testable import StemDrop

final class AudioExporterLengthTests: XCTestCase {
    private var tempDir: URL!
    private let sampleRate = 44_100.0
    private let channelCount: AVAudioChannelCount = 2

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioExporterLengthTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    /// Writes a float32, non-interleaved WAV with `frameCount` frames whose
    /// samples are a simple per-frame ramp (never zero), so padding/trimming
    /// is easy to tell apart from real signal.
    private func makeStemWAV(name: String, frameCount: Int) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        ) else {
            throw XCTSkip("Could not create format")
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true
        ]

        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            throw XCTSkip("Could not create buffer")
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        if let channelData = buffer.floatChannelData {
            for channel in 0..<Int(channelCount) {
                for frame in 0..<frameCount {
                    // Small, never-zero, channel-distinguishable values well
                    // under the int16 quantization step so identity checks
                    // are exact.
                    channelData[channel][frame] = Float(0.1 + Double(frame % 100) / 1000.0 + Double(channel) * 0.01)
                }
            }
        }

        try file.write(from: buffer)
        return url
    }

    private func readAllFloatFrames(_ url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let channelCount = Int(format.channelCount)
        var channels: [[Float]] = Array(repeating: [], count: channelCount)

        let chunk: AVAudioFrameCount = 32_768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw XCTSkip("Could not create read buffer")
        }
        while true {
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: chunk)
            if buffer.frameLength == 0 { break }
            guard let floatData = buffer.floatChannelData else { break }
            for channel in 0..<channelCount {
                channels[channel].append(contentsOf: UnsafeBufferPointer(start: floatData[channel], count: Int(buffer.frameLength)))
            }
            // A short read (fewer frames than requested) means EOF —
            // AVAudioFile.read(into:frameCount:) throws rather than
            // returning frameLength 0 if called again past the end.
            if buffer.frameLength < chunk { break }
        }
        return channels
    }

    func testShorterThanTargetIsPaddedWithZeroTail() throws {
        let originalFrames = 1_000
        let targetFrames = 1_500
        let stemURL = try makeStemWAV(name: "short.wav", frameCount: originalFrames)
        let destURL = tempDir.appendingPathComponent("padded.wav")

        var settings = ExportSettings(format: .wav, bitDepth: .float32)
        settings.targetFrameCount = AVAudioFramePosition(targetFrames)

        try AudioExporter().write(stemWAV: stemURL, to: destURL, settings: settings)

        let outFile = try AVAudioFile(forReading: destURL)
        XCTAssertEqual(outFile.length, AVAudioFramePosition(targetFrames))

        let outChannels = try readAllFloatFrames(destURL)
        let sourceChannels = try readAllFloatFrames(stemURL)

        for channel in 0..<outChannels.count {
            XCTAssertEqual(Array(outChannels[channel][0..<originalFrames]), sourceChannels[channel])
            for frame in originalFrames..<targetFrames {
                XCTAssertEqual(outChannels[channel][frame], 0, "expected digital silence in the padded tail")
            }
        }
    }

    func testLongerThanTargetIsTruncated() throws {
        let originalFrames = 2_000
        let targetFrames = 1_200
        let stemURL = try makeStemWAV(name: "long.wav", frameCount: originalFrames)
        let destURL = tempDir.appendingPathComponent("truncated.wav")

        var settings = ExportSettings(format: .wav, bitDepth: .float32)
        settings.targetFrameCount = AVAudioFramePosition(targetFrames)

        try AudioExporter().write(stemWAV: stemURL, to: destURL, settings: settings)

        let outFile = try AVAudioFile(forReading: destURL)
        XCTAssertEqual(outFile.length, AVAudioFramePosition(targetFrames))

        let outChannels = try readAllFloatFrames(destURL)
        let sourceChannels = try readAllFloatFrames(stemURL)

        for channel in 0..<outChannels.count {
            XCTAssertEqual(outChannels[channel], Array(sourceChannels[channel][0..<targetFrames]))
        }
    }

    func testDefaultsProduceBitIdenticalSampleData() throws {
        let frameCount = 1_000
        let stemURL = try makeStemWAV(name: "identity.wav", frameCount: frameCount)
        let destURL = tempDir.appendingPathComponent("identity-out.wav")

        // Defaults: no trim, no normalize, no target frame count.
        let settings = ExportSettings(format: .wav, bitDepth: .float32)
        XCTAssertNil(settings.targetFrameCount)
        XCTAssertFalse(settings.normalize)
        XCTAssertFalse(settings.trimTrailingSilence)

        try AudioExporter().write(stemWAV: stemURL, to: destURL, settings: settings)

        let outChannels = try readAllFloatFrames(destURL)
        let sourceChannels = try readAllFloatFrames(stemURL)
        XCTAssertEqual(outChannels, sourceChannels)
    }
}
