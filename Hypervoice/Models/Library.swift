import AppKit
import Observation

/// Your voices and generated clips, kept in Application Support as JSON beside the audio files.
@Observable
final class Library {
    static let shared = Library()

    private(set) var voices: [Voice] = []
    private(set) var clips: [Clip] = []

    static let folder: URL = {
        #if DEBUG
        // HYPERVOICE_LIBRARY points a test run at its own voices, clips and sounds.
        if let path = ProcessInfo.processInfo.environment["HYPERVOICE_LIBRARY"] { return URL(fileURLWithPath: path, isDirectory: true) }
        #endif
        return URL.applicationSupportDirectory.appending(path: "Hypervoice", directoryHint: .isDirectory)
    }()
    static let voicesFolder = folder.appending(path: "Voices", directoryHint: .isDirectory)
    static let clipsFolder = folder.appending(path: "Clips", directoryHint: .isDirectory)
    private static let voicesFile = folder.appending(path: "voices.json")
    private static let clipsFile = folder.appending(path: "clips.json")

    init() {
        for folder in [Self.voicesFolder, Self.clipsFolder] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        voices = Self.read([Voice].self, from: Self.voicesFile) ?? []
        clips = Self.read([Clip].self, from: Self.clipsFile) ?? []
    }

    /// Your voices first, newest first, then every built-in one.
    var allVoices: [Voice] { voices + Voice.presets }

    func voice(id: String?) -> Voice? {
        guard let id else { return nil }
        return allVoices.first { $0.id == id }
    }

    /// Matches a name as typed in a script or an API call: an id, else a name, ignoring case and accents.
    func voice(named name: String) -> Voice? {
        let key = name.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !key.isEmpty else { return nil }
        return allVoices.first { $0.id == name }
            ?? allVoices.first { $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == key }
    }

    func sampleURL(of voice: Voice) -> URL? {
        voice.sample.map { Self.voicesFolder.appending(path: $0) }
    }

    func url(of clip: Clip) -> URL {
        Self.clipsFolder.appending(path: clip.file)
    }

    // MARK: - Voices

    /// Keeps a copy of the sample, so the voice survives the original file moving.
    @discardableResult
    func addVoice(name: String, origin: Voice.Origin, sample: URL, transcript: String?, prompt: String? = nil, engine: Engine) throws -> Voice {
        let id = UUID().uuidString
        let file = "\(id).\(sample.pathExtension.isEmpty ? "wav" : sample.pathExtension)"
        try FileManager.default.copyItem(at: sample, to: Self.voicesFolder.appending(path: file))
        let voice = Voice(id: id, name: name, origin: origin, engine: engine, sample: file,
                          transcript: transcript?.trimmingCharacters(in: .whitespacesAndNewlines),
                          prompt: prompt, created: .now)
        voices.insert(voice, at: 0)
        save()
        return voice
    }

    func update(_ voice: Voice) {
        guard let index = voices.firstIndex(where: { $0.id == voice.id }) else { return }
        voices[index] = voice
        save()
    }

    func delete(_ voice: Voice) {
        guard !voice.isPreset else { return }
        if let url = sampleURL(of: voice) { try? FileManager.default.removeItem(at: url) }
        voices.removeAll { $0.id == voice.id }
        save()
    }

    // MARK: - Clips

    /// Writes the samples to a WAV file and lists it in History.
    @discardableResult
    func addClip(samples: [Float], sampleRate: Int, text: String, voiceName: String, engine: Engine?, generationTime: Double?) throws -> Clip {
        let id = UUID()
        let file = "\(id.uuidString).wav"
        try WAV.write(samples, sampleRate: sampleRate, to: Self.clipsFolder.appending(path: file))
        let clip = Clip(id: id, text: text, voiceName: voiceName, engine: engine, file: file,
                        duration: Double(samples.count) / Double(sampleRate), created: .now, generationTime: generationTime)
        clips.insert(clip, at: 0)
        save()
        return clip
    }

    func delete(_ clips: some Collection<Clip.ID>) {
        let ids = Set(clips)
        for clip in self.clips where ids.contains(clip.id) {
            try? FileManager.default.removeItem(at: url(of: clip))
        }
        self.clips.removeAll { ids.contains($0.id) }
        save()
    }

    // MARK: - Files

    private func save() {
        Self.write(voices, to: Self.voicesFile)
        Self.write(clips, to: Self.clipsFile)
    }

    private static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private static func write(_ value: some Encodable, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(value).write(to: url, options: .atomic)
    }
}
