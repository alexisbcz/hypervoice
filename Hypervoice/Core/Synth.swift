import Foundation
import MLX
import MLXAudioCore
import MLXAudioSTT
import MLXAudioTTS

/// What to say, and in which voice.
nonisolated struct SpeechRequest: Sendable {
    var text: String
    var engine: Engine
    /// A preset id, "preset, direction" for CustomVoice, or a description for voice design.
    var voice: String?
    /// The sample to clone.
    var sample: URL?
    /// The words spoken in the sample.
    var transcript: String?
    var language: String?

    /// The request that speaks `text` in `voice`, with an optional engine and direction.
    @MainActor static func make(_ text: String, voice: Voice, engine: Engine? = nil, direction: String? = nil) -> SpeechRequest {
        let engine = engine.flatMap { voice.engines.contains($0) ? $0 : nil } ?? voice.engine
        if voice.isPreset {
            let direction = direction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let id = voice.preset.flatMap(engine.voiceArgument)
            let spoken = engine.takesDirection && !direction.isEmpty ? id.map { "\($0), \(direction)" } : id
            return SpeechRequest(text: text, engine: engine, voice: spoken)
        }
        if voice.origin == .embedding {
            return SpeechRequest(text: text, engine: engine, voice: Library.shared.sampleURL(of: voice)?.path)
        }
        return SpeechRequest(text: text, engine: engine, sample: Library.shared.sampleURL(of: voice), transcript: voice.transcript)
    }
}

/// Lets a model cross into generation; `Synth` guarantees nothing else touches it meanwhile.
nonisolated private final class ModelHandle: @unchecked Sendable {
    let model: any SpeechGenerationModel
    init(_ model: any SpeechGenerationModel) { self.model = model }
}

/// Runs the speech models, one at a time: they share the GPU, and two large ones can fill a Mac's memory.
actor Synth {
    static let shared = Synth()

    private var loaded: Engine?
    private var model: (any SpeechGenerationModel)?
    /// The last reference sample, decoded at the model's rate, since a long text reuses it for every sentence.
    private var reference: (url: URL, sampleRate: Int, samples: [Float])?

    var loadedEngine: Engine? { loaded }

    /// Loads the engine, downloading it first if needed, and returns its sample rate.
    @discardableResult
    func prepare(_ engine: Engine) async throws -> Int {
        try await exclusively {
            if engine.runsOnLlama {
                try await startLlama(engine)
                return LFM3.sampleRate
            }
            return try await model(for: engine).sampleRate
        }
    }

    /// One stretch of speech as mono Float32 samples at the engine's sample rate.
    func synthesize(_ request: SpeechRequest) async throws -> [Float] {
        try await exclusively {
            if request.engine.runsOnLlama {
                try await startLlama(request.engine)
                return try await LFM3.shared.speak(request.text, voice: request.voice)
            }
            let model = try await model(for: request.engine)
            var refAudio: MLXArray?
            if request.engine.clones, let url = request.sample {
                refAudio = MLXArray(try await referenceSamples(url, sampleRate: model.sampleRate))
            }
            let refText = request.engine.needsTranscript ? request.transcript : nil
            // Safe to hand over: `exclusively` keeps every other caller off the model until this returns.
            let audio = try await Self.generate(ModelHandle(model), request, refAudio: refAudio, refText: refText)
            return audio
        }
    }

    @concurrent
    private nonisolated static func generate(_ handle: ModelHandle, _ request: SpeechRequest, refAudio: sending MLXArray?, refText: String?) async throws -> [Float] {
        let model = handle.model
        let audio = try await model.generate(
            text: request.text,
            voice: request.voice,
            refAudio: refAudio,
            refText: refText,
            language: request.language,
            generationParameters: model.defaultGenerationParameters
        )
        return audio.asArray(Float.self)
    }

    // MARK: - One at a time

    /// Actors interleave at every `await`; a model mid-generation must not be swapped out or run twice.
    private var isBusy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private func exclusively<T>(_ body: () async throws -> T) async throws -> T {
        while isBusy { await withCheckedContinuation { waiting.append($0) } }
        isBusy = true
        defer {
            isBusy = false
            if !waiting.isEmpty { waiting.removeFirst().resume() }
        }
        return try await body()
    }

    func unload() async {
        model = nil
        loaded = nil
        reference = nil
        Memory.clearCache()
        await LFM3.shared.stop()
    }

    /// LFM3 Audio's server takes the place of an MLX model, so the two don't share memory either.
    private func startLlama(_ engine: Engine) async throws {
        if loaded != engine {
            await unload()
            loaded = engine
        }
        try await LFM3.shared.start()
    }

    private func model(for engine: Engine) async throws -> any SpeechGenerationModel {
        if loaded == engine, let model { return model }
        await unload()
        let model = try await TTS.loadModel(modelRepo: engine.repository, modelType: engine.modelType)
        self.model = model
        loaded = engine
        return model
    }

    private func referenceSamples(_ url: URL, sampleRate: Int) async throws -> [Float] {
        if let reference, reference.url == url, reference.sampleRate == sampleRate { return reference.samples }
        let samples = try await WAV.read(url, sampleRate: sampleRate)
        reference = (url, sampleRate, samples)
        return samples
    }
}

/// Whisper, for Transcribe and for the words spoken in a new voice's sample.
actor Transcriber {
    static let shared = Transcriber()
    static let sampleRate = 16_000

    private var model: (any STTGenerationModel)?

    var isLoaded: Bool { model != nil }

    func prepare() async throws {
        _ = try await loadedModel()
    }

    func transcribe(_ url: URL, language: String? = nil) async throws -> Transcript {
        let samples = try await WAV.read(url, sampleRate: Self.sampleRate)
        return try await transcribe(samples, source: url, language: language)
    }

    func transcribe(_ samples: [Float], source: URL, language: String? = nil) async throws -> Transcript {
        let model = try await loadedModel()
        let parameters = STTGenerateParameters(language: language, chunkDuration: 30)
        let output = model.generate(audio: MLXArray(samples), generationParameters: parameters)
        let segments: [Transcript.Segment] = (output.segments ?? []).compactMap { segment in
            guard let text = (segment["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return Transcript.Segment(start: segment["start"] as? Double ?? 0, end: segment["end"] as? Double ?? 0, text: text)
        }
        return Transcript(source: source, text: output.text.trimmingCharacters(in: .whitespacesAndNewlines),
                          segments: segments, language: output.language)
    }

    func unload() {
        model = nil
        Memory.clearCache()
    }

    private func loadedModel() async throws -> any STTGenerationModel {
        if let model { return model }
        let loaded = try await STT.loadModel(modelRepo: Whisper.repository, modelType: "whisper")
        model = loaded
        return loaded
    }
}
