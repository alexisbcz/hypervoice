import AVFoundation
import NaturalLanguage

/// Reading and writing audio files as mono Float32 samples.
nonisolated enum WAV {
    /// 16-bit PCM: what every editor, browser and phone plays.
    static func write(_ samples: [Float], sampleRate: Int, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = buffer(samples, sampleRate: sampleRate) else { return }
        try file.write(from: buffer)
    }

    /// Any file AVFoundation opens, video included, mixed down to mono at `sampleRate`.
    @concurrent
    static func read(_ url: URL, sampleRate: Int) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "\(url.lastPathComponent) has no audio."])
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        reader.startReading()
        var samples: [Float] = []
        while let sampleBuffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sampleBuffer) {
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            samples += chunk
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
        return samples
    }

    static func buffer(_ samples: [Float], sampleRate: Int) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }

    /// Loudness envelope for drawing: the peak of each of `count` equal stretches, 0...1.
    static func peaks(_ samples: [Float], count: Int) -> [Float] {
        guard !samples.isEmpty, count > 0 else { return [] }
        let stride = max(1, samples.count / count)
        var peaks: [Float] = []
        peaks.reserveCapacity(count)
        var index = 0
        while index < samples.count, peaks.count < count {
            let end = min(samples.count, index + stride)
            var peak: Float = 0
            for i in index..<end { peak = max(peak, abs(samples[i])) }
            peaks.append(min(1, peak))
            index = end
        }
        return peaks
    }

    static func silence(seconds: Double, sampleRate: Int) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(sampleRate)))
    }
}

nonisolated enum Chunker {
    /// Sentences, with short ones joined, so each generated piece is long enough to sound natural
    /// and the first is short enough to start playing quickly.
    static func chunks(of text: String, limit: Int = 280) -> [String] {
        var chunks: [String] = []
        for paragraph in text.components(separatedBy: .newlines) where !paragraph.trimmingCharacters(in: .whitespaces).isEmpty {
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = paragraph
            var current = ""
            tokenizer.enumerateTokens(in: paragraph.startIndex..<paragraph.endIndex) { range, _ in
                let sentence = paragraph[range].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !sentence.isEmpty else { return true }
                if !current.isEmpty, current.count + sentence.count > limit || chunks.isEmpty {
                    chunks.append(current)
                    current = ""
                }
                current += (current.isEmpty ? "" : " ") + sentence
                return true
            }
            if !current.isEmpty { chunks.append(current) }
        }
        return chunks
    }
}
