import Foundation

/// Hand-rolled ID3v2.3 / RIFF-INFO tag writer (SPEC.md §12/§13). Never
/// re-encodes audio — only patches/append chunks around already-written
/// PCM (AIFF/WAV) or compressed (MP3) files.
enum TagWriter {
    enum WriterError: Error {
        case malformedFile
    }

    static func write(_ meta: StemMetadata, to url: URL, format: OutputFormat) throws {
        switch format {
        case .aiff:
            try writeAIFF(meta, to: url)
        case .wav:
            try writeWAV(meta, to: url)
        case .mp3:
            try writeMP3(meta, to: url)
        }
    }

    // MARK: - ID3v2.3 tag construction (shared by AIFF's `ID3 ` chunk and MP3's prepended tag)

    private static func syncsafe(_ size: Int) -> [UInt8] {
        var value = size
        var bytes = [UInt8](repeating: 0, count: 4)
        for index in stride(from: 3, through: 0, by: -1) {
            bytes[index] = UInt8(value & 0x7F)
            value >>= 7
        }
        return bytes
    }

    private static func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        let be = value.bigEndian
        return withUnsafeBytes(of: be) { Array($0) }
    }

    private static func littleEndianBytes(_ value: UInt32) -> [UInt8] {
        let le = value.littleEndian
        return withUnsafeBytes(of: le) { Array($0) }
    }

    /// Text frame body: encoding byte 1 (UTF-16 with BOM) + UTF-16 text.
    private static func textFrame(_ id: String, _ text: String) -> Data? {
        guard let textData = text.data(using: .utf16) else { return nil }
        var frameData = Data([0x01])
        frameData.append(textData)

        var frame = Data()
        frame.append(contentsOf: Array(id.utf8))
        frame.append(contentsOf: bigEndianBytes(UInt32(frameData.count)))
        frame.append(contentsOf: [0x00, 0x00]) // flags
        frame.append(frameData)
        return frame
    }

    /// Full ID3v2.3 tag: 10-byte header + TPE1/TALB/TIT2/TYER frames.
    private static func buildID3Tag(_ meta: StemMetadata) -> Data {
        var frames = Data()
        if let artist = meta.artist, let frame = textFrame("TPE1", artist) {
            frames.append(frame)
        }
        if let frame = textFrame("TALB", meta.album) {
            frames.append(frame)
        }
        if let frame = textFrame("TIT2", meta.title) {
            frames.append(frame)
        }
        if let year = meta.year, let frame = textFrame("TYER", year) {
            frames.append(frame)
        }

        var tag = Data()
        tag.append(contentsOf: Array("ID3".utf8))
        tag.append(contentsOf: [0x03, 0x00]) // version 2.3.0
        tag.append(0x00) // flags
        tag.append(contentsOf: syncsafe(frames.count))
        tag.append(frames)
        return tag
    }

    // MARK: - AIFF: append an `ID3 ` chunk, patch FORM size

    private static func writeAIFF(_ meta: StemMetadata, to url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }

        try handle.seek(toOffset: 0)
        guard let header = try handle.read(upToCount: 4), header.elementsEqual(Array("FORM".utf8)) else {
            throw WriterError.malformedFile
        }

        let payload = buildID3Tag(meta)
        var chunk = Data()
        chunk.append(contentsOf: Array("ID3 ".utf8))
        chunk.append(contentsOf: bigEndianBytes(UInt32(payload.count)))
        chunk.append(payload)
        if payload.count % 2 != 0 {
            chunk.append(0x00) // pad chunk to even length; not counted in size field
        }

        try handle.seekToEnd()
        try handle.write(contentsOf: chunk)

        let newFileSize = try handle.offset()
        let formSize = UInt32(newFileSize - 8)
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: bigEndianBytes(formSize))
    }

    // MARK: - WAV: append a `LIST/INFO` chunk, patch RIFF size

    private static func infoSubchunk(_ id: String, _ text: String) -> Data {
        var textData = Data(text.utf8)
        textData.append(0x00) // null terminator
        let unpaddedSize = textData.count
        if textData.count % 2 != 0 {
            textData.append(0x00)
        }

        var chunk = Data()
        chunk.append(contentsOf: Array(id.utf8))
        chunk.append(contentsOf: littleEndianBytes(UInt32(unpaddedSize)))
        chunk.append(textData)
        return chunk
    }

    private static func writeWAV(_ meta: StemMetadata, to url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }

        try handle.seek(toOffset: 0)
        guard let header = try handle.read(upToCount: 4), header.elementsEqual(Array("RIFF".utf8)) else {
            throw WriterError.malformedFile
        }

        var listPayload = Data()
        listPayload.append(contentsOf: Array("INFO".utf8))
        if let artist = meta.artist {
            listPayload.append(infoSubchunk("IART", artist))
        }
        listPayload.append(infoSubchunk("INAM", meta.title))
        listPayload.append(infoSubchunk("IPRD", meta.album))
        if let year = meta.year {
            listPayload.append(infoSubchunk("ICRD", year))
        }

        var chunk = Data()
        chunk.append(contentsOf: Array("LIST".utf8))
        chunk.append(contentsOf: littleEndianBytes(UInt32(listPayload.count)))
        chunk.append(listPayload)
        if listPayload.count % 2 != 0 {
            chunk.append(0x00)
        }

        try handle.seekToEnd()
        try handle.write(contentsOf: chunk)

        let newFileSize = try handle.offset()
        let riffSize = UInt32(newFileSize - 8)
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: littleEndianBytes(riffSize))
    }

    // MARK: - MP3: prepend an ID3v2.3 tag (audio bytes untouched)

    private static func writeMP3(_ meta: StemMetadata, to url: URL) throws {
        let tag = buildID3Tag(meta)

        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent)-tag-\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)

        let outHandle = try FileHandle(forWritingTo: tempURL)
        let inHandle = try FileHandle(forReadingFrom: url)

        do {
            try outHandle.write(contentsOf: tag)
            while true {
                let chunk = try inHandle.read(upToCount: 1 << 20) ?? Data()
                if chunk.isEmpty { break }
                try outHandle.write(contentsOf: chunk)
            }
            try inHandle.close()
            try outHandle.close()
        } catch {
            try? inHandle.close()
            try? outHandle.close()
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
    }
}
