import Foundation
import AVFoundation

protocol AudioExporting: Sendable {
    func write(stemWAV: URL, to dst: URL, settings: ExportSettings) throws
}

struct AudioExporter: AudioExporting {
    func write(stemWAV: URL, to dst: URL, settings: ExportSettings) throws {
        var effectiveSourceURL = stemWAV
        var temporaryURL: URL?
        defer {
            if let temporaryURL {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }

        // Trim/normalize/pad need the whole signal in hand before any
        // bit-depth quantization happens, so — only when one of them is
        // requested — do a full pass up front and write a float32
        // intermediate, then let the existing streaming path below handle
        // the final bit-depth conversion untouched. With all three off
        // (the default) this block never runs, so output stays
        // bit-identical to the un-processed stem.
        if settings.trimTrailingSilence || settings.normalize || settings.targetFrameCount != nil {
            let processed = try preprocess(stemWAV, settings: settings)
            effectiveSourceURL = processed
            temporaryURL = processed
        }

        switch settings.format {
        case .wav, .aiff:
            try writePCM(
                source: effectiveSourceURL,
                dst: dst,
                bitDepth: settings.bitDepth,
                bigEndian: settings.format == .aiff
            )
            if let metadata = settings.metadata {
                try TagWriter.write(metadata, to: dst, format: settings.format)
            }
        case .mp3:
            try writeMP3(source: effectiveSourceURL, dst: dst, settings: settings)
        }
    }

    /// Streams `source` through an `AVAudioConverter` into a PCM file at
    /// `dst` (WAV or AIFF depending on `bigEndian`), at the requested bit
    /// depth. Used both for the final WAV/AIFF export and to produce a
    /// standard interleaved float32 WAV temp file for the MP3 encoder.
    private func writePCM(source: URL, dst: URL, bitDepth: WAVBitDepth, bigEndian: Bool) throws {
        let sourceFile: AVAudioFile
        do {
            sourceFile = try AVAudioFile(forReading: source)
        } catch {
            throw StemDropError.unreadableAudio
        }

        let sourceFormat = sourceFile.processingFormat
        let channelCount = sourceFormat.channelCount
        let sampleRate = sourceFormat.sampleRate

        let outputSettings: [String: Any]
        let commonFormat: AVAudioCommonFormat
        let isFloat: Bool
        let depth: Int

        switch bitDepth {
        case .int16:
            commonFormat = .pcmFormatInt16
            isFloat = false
            depth = 16
        case .int24:
            commonFormat = .pcmFormatInt32
            isFloat = false
            depth = 24
        case .float32:
            commonFormat = .pcmFormatFloat32
            isFloat = true
            depth = 32
        }

        outputSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: depth,
            AVLinearPCMIsFloatKey: isFloat,
            AVLinearPCMIsBigEndianKey: bigEndian,
            AVLinearPCMIsNonInterleaved: false
        ]

        let destinationFile: AVAudioFile
        do {
            destinationFile = try AVAudioFile(
                forWriting: dst,
                settings: outputSettings,
                commonFormat: bitDepth == .int24 ? .pcmFormatInt32 : commonFormat,
                interleaved: true
            )
        } catch {
            throw StemDropError.outputNotWritable
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: destinationFile.processingFormat) else {
            throw StemDropError.outputNotWritable
        }

        let frameCapacity: AVAudioFrameCount = 32_768
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCapacity),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: destinationFile.processingFormat, frameCapacity: frameCapacity) else {
            throw StemDropError.outputNotWritable
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
                    try sourceFile.read(into: inputBuffer, frameCount: frameCapacity)
                } catch {
                    outStatus.pointee = .endOfStream
                    return nil
                }

                if inputBuffer.frameLength == 0 {
                    reachedEndOfFile = true
                    outStatus.pointee = .endOfStream
                    return nil
                }

                clampIfNeeded(inputBuffer, isFloat: isFloat)
                outStatus.pointee = .haveData
                return inputBuffer
            }

            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError, withInputFrom: inputBlock)

            if status == .error {
                throw StemDropError.outputNotWritable
            }

            if outputBuffer.frameLength > 0 {
                do {
                    try destinationFile.write(from: outputBuffer)
                } catch {
                    throw StemDropError.outputNotWritable
                }
            }

            if status == .endOfStream {
                break
            }

            if reachedEndOfFile && outputBuffer.frameLength == 0 {
                break
            }
        }
    }

    /// Renders `source` to a standard interleaved float32 WAV temp file,
    /// hands it to the Python engine's `lameenc`-based encoder (SPEC.md
    /// §13), then tags the result if metadata was requested.
    private func writeMP3(source: URL, dst: URL, settings: ExportSettings) throws {
        let tempWAV = FileManager.default.temporaryDirectory
            .appendingPathComponent("stemdrop-mp3-src-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tempWAV) }

        try writePCM(source: source, dst: tempWAV, bitDepth: .float32, bigEndian: false)
        try MP3Encoder().encode(wav: tempWAV, to: dst, bitrateKbps: 320)

        if let metadata = settings.metadata {
            try TagWriter.write(metadata, to: dst, format: .mp3)
        }
    }

    /// AVAudioConverter already clamps when converting float -> integer common formats,
    /// but we defensively clamp float samples in-place before any integer write to
    /// guard against out-of-range values from upstream stem processing.
    private func clampIfNeeded(_ buffer: AVAudioPCMBuffer, isFloat: Bool) {
        guard !isFloat, let floatData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        for channel in 0..<Int(buffer.format.channelCount) {
            let channelData = floatData[channel]
            for frame in 0..<frameLength {
                channelData[frame] = max(-1.0, min(1.0, channelData[frame]))
            }
        }
    }

    // MARK: - Trim / normalize / pad preprocessing

    /// Reads the whole stem into per-channel float32 arrays, applies
    /// trim → normalize → pad/truncate (in that order, only the requested
    /// ones), and writes the result to a float32 WAV sitting next to the
    /// source so the existing streaming bit-depth conversion above can
    /// read it unmodified.
    private func preprocess(_ url: URL, settings: ExportSettings) throws -> URL {
        let sourceFile: AVAudioFile
        do {
            sourceFile = try AVAudioFile(forReading: url)
        } catch {
            throw StemDropError.unreadableAudio
        }

        let sourceFormat = sourceFile.processingFormat
        let channelCount = Int(sourceFormat.channelCount)
        let sampleRate = sourceFormat.sampleRate

        guard let floatFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        ) else {
            throw StemDropError.unreadableAudio
        }

        var channels: [[Float]] = Array(repeating: [], count: channelCount)

        if sourceFormat.commonFormat == .pcmFormatFloat32 && !sourceFormat.isInterleaved {
            try readAllFrames(sourceFile: sourceFile, format: sourceFormat, channelCount: channelCount, into: &channels)
        } else {
            guard let converter = AVAudioConverter(from: sourceFormat, to: floatFormat) else {
                throw StemDropError.unreadableAudio
            }
            try convertAllFrames(
                sourceFile: sourceFile,
                converter: converter,
                sourceFormat: sourceFormat,
                outputFormat: floatFormat,
                channelCount: channelCount,
                into: &channels
            )
        }

        if settings.trimTrailingSilence {
            Self.trimTrailingSilence(&channels)
        }
        if settings.normalize {
            Self.normalize(&channels)
        }
        if let target = settings.targetFrameCount {
            Self.padOrTruncate(&channels, to: Int(target))
        }

        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-processed-\(UUID().uuidString).wav")

        let outSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true
        ]

        let outFile: AVAudioFile
        do {
            outFile = try AVAudioFile(
                forWriting: tempURL,
                settings: outSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw StemDropError.outputNotWritable
        }

        let frameCount = channels.first?.count ?? 0
        if frameCount > 0 {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
                throw StemDropError.outputNotWritable
            }
            buffer.frameLength = AVAudioFrameCount(frameCount)
            if let floatData = buffer.floatChannelData {
                for channel in 0..<channelCount {
                    channels[channel].withUnsafeBufferPointer { source in
                        guard let base = source.baseAddress else { return }
                        floatData[channel].update(from: base, count: frameCount)
                    }
                }
            }

            do {
                try outFile.write(from: buffer)
            } catch {
                throw StemDropError.outputNotWritable
            }
        }

        return tempURL
    }

    private func readAllFrames(
        sourceFile: AVAudioFile,
        format: AVAudioFormat,
        channelCount: Int,
        into channels: inout [[Float]]
    ) throws {
        let chunkSize: AVAudioFrameCount = 32_768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize) else {
            throw StemDropError.unreadableAudio
        }
        while true {
            buffer.frameLength = 0
            do {
                try sourceFile.read(into: buffer, frameCount: chunkSize)
            } catch {
                // AVAudioFile.read(into:frameCount:) throws once nothing is
                // left to read rather than returning frameLength 0 — treat
                // that the same as EOF, matching the existing streaming
                // converters elsewhere in this file.
                break
            }
            if buffer.frameLength == 0 { break }
            appendFrames(from: buffer, channelCount: channelCount, into: &channels)
        }
    }

    private func convertAllFrames(
        sourceFile: AVAudioFile,
        converter: AVAudioConverter,
        sourceFormat: AVAudioFormat,
        outputFormat: AVAudioFormat,
        channelCount: Int,
        into channels: inout [[Float]]
    ) throws {
        let chunkSize: AVAudioFrameCount = 32_768
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: chunkSize),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: chunkSize) else {
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
                    try sourceFile.read(into: inputBuffer, frameCount: chunkSize)
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
                appendFrames(from: outputBuffer, channelCount: channelCount, into: &channels)
            }

            if status == .endOfStream {
                break
            }
        }
    }

    private func appendFrames(from buffer: AVAudioPCMBuffer, channelCount: Int, into channels: inout [[Float]]) {
        guard let floatData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        for channel in 0..<channelCount {
            channels[channel].append(contentsOf: UnsafeBufferPointer(start: floatData[channel], count: frameLength))
        }
    }

    /// Drops trailing frames whose magnitude is below −80 dBFS on every channel.
    private static func trimTrailingSilence(_ channels: inout [[Float]]) {
        guard let frameCount = channels.first?.count, frameCount > 0 else { return }
        let threshold = Float(pow(10.0, -80.0 / 20.0))

        var lastNonSilentFrame = -1
        for frame in stride(from: frameCount - 1, through: 0, by: -1) {
            let isSilent = channels.allSatisfy { abs($0[frame]) < threshold }
            if !isSilent {
                lastNonSilentFrame = frame
                break
            }
        }

        let newCount = lastNonSilentFrame + 1
        guard newCount < frameCount else { return }
        for channel in channels.indices {
            channels[channel].removeSubrange(newCount..<frameCount)
        }
    }

    /// Scales every sample so the overall peak lands at −0.1 dBFS.
    private static func normalize(_ channels: inout [[Float]]) {
        var peak: Float = 0
        for channel in channels {
            for sample in channel {
                peak = max(peak, abs(sample))
            }
        }
        guard peak > 0 else { return }

        let targetPeak = Float(pow(10.0, -0.1 / 20.0))
        let gain = targetPeak / peak
        guard gain != 1 else { return }

        for channel in channels.indices {
            for frame in channels[channel].indices {
                channels[channel][frame] *= gain
            }
        }
    }

    /// Pads with digital silence or truncates so every channel has exactly
    /// `target` frames.
    private static func padOrTruncate(_ channels: inout [[Float]], to target: Int) {
        guard target >= 0 else { return }
        for channel in channels.indices {
            let count = channels[channel].count
            if count < target {
                channels[channel].append(contentsOf: repeatElement(0, count: target - count))
            } else if count > target {
                channels[channel].removeSubrange(target..<count)
            }
        }
    }
}
