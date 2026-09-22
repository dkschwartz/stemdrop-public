import Foundation
import AVFoundation

protocol AudioConverting: Sendable {
    func toEngineWAV(_ src: URL, into dir: URL) async throws -> URL
}

struct AudioConverter: AudioConverting {
    static let engineSampleRate: Double = 44_100
    static let engineChannelCount: AVAudioChannelCount = 2

    func toEngineWAV(_ src: URL, into dir: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try Self.convert(src, into: dir)
        }.value
    }

    private static func convert(_ src: URL, into dir: URL) throws -> URL {
        let sourceFile: AVAudioFile
        do {
            sourceFile = try AVAudioFile(forReading: src)
        } catch {
            throw StemDropError.unreadableAudio
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: engineSampleRate,
            channels: engineChannelCount,
            interleaved: false
        ) else {
            throw StemDropError.unreadableAudio
        }

        guard let converter = AVAudioConverter(from: sourceFile.processingFormat, to: outputFormat) else {
            throw StemDropError.unreadableAudio
        }

        let destinationURL = dir.appendingPathComponent("input.wav")

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: engineSampleRate,
            AVNumberOfChannelsKey: engineChannelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true
        ]

        let destinationFile: AVAudioFile
        do {
            destinationFile = try AVAudioFile(
                forWriting: destinationURL,
                settings: outputSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw StemDropError.outputNotWritable
        }

        let sourceFrameCapacity: AVAudioFrameCount = 32_768
        let ratio = outputFormat.sampleRate / sourceFile.processingFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount((Double(sourceFrameCapacity) * ratio).rounded(.up)) + 1024

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFile.processingFormat, frameCapacity: sourceFrameCapacity),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
            throw StemDropError.unreadableAudio
        }

        var reachedEndOfFile = false

        while true {
            outputBuffer.frameLength = 0

            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                if reachedEndOfFile {
                    outStatus.pointee = .endOfStream
                    return nil
                }

                do {
                    inputBuffer.frameLength = 0
                    try sourceFile.read(into: inputBuffer, frameCount: sourceFrameCapacity)
                } catch {
                    outStatus.pointee = .endOfStream
                    return nil
                }

                if inputBuffer.frameLength == 0 {
                    reachedEndOfFile = true
                    outStatus.pointee = .endOfStream
                    return nil
                }

                outStatus.pointee = .haveData
                return inputBuffer
            }

            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError, withInputFrom: inputBlock)

            if status == .error {
                throw StemDropError.unreadableAudio
            }

            if outputBuffer.frameLength > 0 {
                try destinationFile.write(from: outputBuffer)
            }

            if status == .endOfStream {
                break
            }

            if reachedEndOfFile && outputBuffer.frameLength == 0 {
                break
            }
        }

        return destinationURL
    }
}
