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

    /// One step of a recording: speech, a silence, or a sound file played as is.
    enum Cue: Sendable {
        case speech(Line)
        case silence(Double)
        case sound(URL)
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
        run(lines.map(Cue.speech), title: title, save: save)
    }

    func run(_ cues: [Cue], title: String, save: Bool = true) {
        cancel()
        let cues = cues.filter { cue in
            if case .speech(let line) = cue { return !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return true
        }
        let lines = cues.compactMap { cue -> Line? in
            if case .speech(let line) = cue { return line }
            return nil
        }
        guard !cues.isEmpty else { return }
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
                let samples = try await render(cues) { chunk in
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
        try await render(lines.map(Cue.speech), report: report, onChunk: onChunk)
    }

    private enum Piece {
        /// `cue` tells speakers apart, for the breath between them.
        case speech(cue: Int, request: SpeechRequest)
        case silence(Double)
        case sound(URL)
    }

    func render(_ cues: [Cue], report: Bool = true, onChunk: ([Float]) -> Void = { _ in }) async throws -> [Float] {
        let pieces: [Piece] = cues.enumerated().flatMap { index, cue -> [Piece] in
            switch cue {
            case .speech(let line):
                return Chunker.chunks(of: line.text).map { text in
                    var request = line.request
                    request.text = text
                    return .speech(cue: index, request: request)
                }
            case .silence(let seconds): return [.silence(seconds)]
            case .sound(let url): return [.sound(url)]
            }
        }
        let speechCount = pieces.filter { if case .speech = $0 { true } else { false } }.count
        var spoken = 0
        var output: [Float] = []
        if report { synthesisTime = 0 }
        for (number, piece) in pieces.enumerated() {
            try Task.checkCancellation()
            var samples: [Float]
            switch piece {
            case .silence(let seconds):
                samples = WAV.silence(seconds: seconds, sampleRate: Self.sampleRate)
            case .sound(let url):
                // Alert sounds are mastered far louder than speech; bring every sound to one level.
                samples = try await WAV.read(url, sampleRate: Self.sampleRate)
                if let peak = samples.map(abs).max(), peak > 0 {
                    let gain = 0.5 / peak
                    samples = samples.map { $0 * gain }
                }
            case .speech(let cue, let request):
                let engine = request.engine
                if await Synth.shared.loadedEngine != engine {
                    if report { status = ModelStore.shared.isInstalled(engine) ? "Loading \(engine.name)…" : "Downloading \(engine.name)…" }
                    _ = try await ModelStore.shared.track(.engine(engine)) { try await Synth.shared.prepare(engine) }
                }
                spoken += 1
                if report { status = speechCount == 1 ? "Generating…" : "Generating \(spoken) of \(speechCount)…" }
                let rate = try await Synth.shared.prepare(engine)
                let started = Date.now
                samples = Self.resample(try await Synth.shared.synthesize(request), from: rate, to: Self.sampleRate)
                if report { synthesisTime += Date.now.timeIntervalSince(started) }
                // A breath between speakers in a script, unless a pause or a sound already separates them.
                if number + 1 < pieces.count, case .speech(let next, _) = pieces[number + 1], next != cue {
                    samples += WAV.silence(seconds: 0.35, sampleRate: Self.sampleRate)
                }
            }
            try Task.checkCancellation()
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
