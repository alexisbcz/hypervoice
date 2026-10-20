import Foundation
import Observation

/// Turns text into speech: sentence by sentence, playing each as soon as it's ready, then saving the whole to History.
@Observable
final class Generator {
    static let shared = Generator()

    /// One speaker's turn: a single line in Speak, one of many in a script.
    struct Line: Sendable {
        var text: String
        var request: SpeechRequest
        var voiceName: String
    }

    /// Every clip is stored at this rate, so lines from different engines join cleanly.
    static let sampleRate = 24_000

    private(set) var isGenerating = false
    /// 0...1 across the whole text.
    private(set) var progress: Double = 0
    private(set) var status = ""
    /// Loudness of what's been generated so far, for the live waveform.
    private(set) var peaks: [Float] = []
    private(set) var lastClip: Clip?
    var error: String?

    @ObservationIgnored private var task: Task<Void, Never>?
    /// Seconds spent synthesizing in the last `render`, leaving out downloads and loading.
    @ObservationIgnored private var synthesisTime: Double = 0

    func speak(_ text: String, voice: Voice, engine: Engine? = nil, direction: String? = nil) {
        let request = SpeechRequest.make(text, voice: voice, engine: engine, direction: direction)
        run([Line(text: text, request: request, voiceName: voice.name)], title: text)
    }

    /// Generates and plays; `save` keeps the result in History.
    func run(_ lines: [Line], title: String, save: Bool = true) {
        cancel()
        let lines = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !lines.isEmpty else { return }
        isGenerating = true
        progress = 0
        peaks = []
        error = nil
        lastClip = nil
        let voiceNames = Array(NSOrderedSet(array: lines.map(\.voiceName))) as? [String] ?? []
        let engines = Set(lines.map(\.request.engine))
        task = Task {
            var streaming = false
            do {
                let samples = try await render(lines) { chunk in
                    if !streaming {
                        try? Player.shared.startStream(sampleRate: Self.sampleRate)
                        streaming = true
                    }
                    Player.shared.enqueue(chunk)
                    peaks += WAV.peaks(chunk, count: max(1, chunk.count / 2400))
                }
                try Task.checkCancellation()
                Player.shared.finishStream()
                if save {
                    lastClip = try Library.shared.addClip(
                        samples: samples, sampleRate: Self.sampleRate, text: title,
                        voiceName: voiceNames.joined(separator: ", "),
                        engine: engines.count == 1 ? engines.first : nil,
                        generationTime: synthesisTime)
                }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled {
                    self.error = error.localizedDescription
                    Player.shared.stop()
                }
            }
            if !Task.isCancelled {
                isGenerating = false
                status = ""
                task = nil
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if Player.shared.isPlaying(Player.live) { Player.shared.stop() }
        isGenerating = false
        status = ""
    }

    /// Generates every line, calling `onChunk` with each piece as it's ready; returns all of it joined.
    func render(_ lines: [Line], report: Bool = true, onChunk: ([Float]) -> Void = { _ in }) async throws -> [Float] {
        let pieces = lines.enumerated().flatMap { index, line in
            Chunker.chunks(of: line.text).map { (line: index, text: $0) }
        }
        var output: [Float] = []
        if report { synthesisTime = 0 }
        for (number, piece) in pieces.enumerated() {
            try Task.checkCancellation()
            var request = lines[piece.line].request
            request.text = piece.text
            let engine = request.engine
            if await Synth.shared.loadedEngine != engine {
                if report { status = ModelStore.shared.isInstalled(engine) ? "Loading \(engine.name)…" : "Downloading \(engine.name)…" }
                _ = try await ModelStore.shared.track(.engine(engine)) { try await Synth.shared.prepare(engine) }
            }
            if report { status = pieces.count == 1 ? "Generating…" : "Generating \(number + 1) of \(pieces.count)…" }
            let rate = try await Synth.shared.prepare(engine)
            let started = Date.now
            var samples = Self.resample(try await Synth.shared.synthesize(request), from: rate, to: Self.sampleRate)
            if report { synthesisTime += Date.now.timeIntervalSince(started) }
            try Task.checkCancellation()
            // A breath between speakers in a script.
            if number + 1 < pieces.count, pieces[number + 1].line != piece.line {
                samples += WAV.silence(seconds: 0.35, sampleRate: Self.sampleRate)
            }
            output += samples
            onChunk(samples)
            if report { progress = Double(number + 1) / Double(pieces.count) }
        }
        return output
    }

    /// Linear interpolation: every engine here runs at 24 kHz, so this rarely does anything.
    nonisolated static func resample(_ samples: [Float], from source: Int, to target: Int) -> [Float] {
        guard source != target, source > 0, !samples.isEmpty else { return samples }
        let ratio = Double(source) / Double(target)
        let count = Int(Double(samples.count) / ratio)
        return (0..<count).map { index in
            let position = Double(index) * ratio
            let low = Int(position)
            let high = min(low + 1, samples.count - 1)
            let fraction = Float(position - Double(low))
            return samples[low] * (1 - fraction) + samples[high] * fraction
        }
    }
}

/// A script: one speaker per paragraph, written as "Name: what they say".
/// Paragraphs without a name continue with whoever spoke last.
struct Script {
    struct Part: Identifiable {
        let id: Int
        var speaker: String
        var text: String
        var voice: Voice?
    }

    var parts: [Part]

    init(_ text: String, library: Library, fallback: Voice?) {
        var parts: [Part] = []
        var speaker = fallback?.name ?? ""
        var voice = fallback
        for paragraph in text.components(separatedBy: .newlines) {
            var line = paragraph.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let colon = line.firstIndex(of: ":"), line.distance(from: line.startIndex, to: colon) <= 32 {
                let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, !name.contains(where: { ".!?".contains($0) }) {
                    speaker = name
                    voice = library.voice(named: name)
                    line = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                }
            }
            guard !line.isEmpty else { continue }
            if let last = parts.last, last.speaker == speaker {
                parts[parts.count - 1].text += "\n" + line
            } else {
                parts.append(Part(id: parts.count, speaker: speaker, text: line, voice: voice))
            }
        }
        self.parts = parts
    }

    var speakers: [(name: String, voice: Voice?)] {
        var seen = Set<String>()
        return parts.compactMap { part in seen.insert(part.speaker).inserted ? (part.speaker, part.voice) : nil }
    }

    var unmatched: [String] { speakers.filter { $0.voice == nil }.map(\.name) }
}
